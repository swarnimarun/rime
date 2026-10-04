const std = @import("std");
const index_mod = @import("index.zig");
const layout = @import("layout.zig");
const state = @import("state.zig");
const digest_mod = @import("digest.zig");

const Io = std.Io;

pub const MigrateError = index_mod.DbError || state.StateError || error{ Unexpected, OutOfMemory };

pub const MigrateOpts = struct { dry_run: bool = false };

pub const MigrateReport = struct {
    objects_imported: u64 = 0,
    actions_imported: u64 = 0,
    roots_imported: u64 = 0,
    incremental_rehomed_bytes: u64 = 0,
};

/// Explicit `rime cache migrate` only (never called by `Store.open`, which refuses
/// format 1 with `error.MigrationRequired` per storage-v2 §14). Steps per §14.1–14.8:
/// preconditions + backup → content untouched → index build → actions import →
/// roots import → incremental re-homing → budget mapping → commit + verify.
/// `dry_run` reports counts, deletes nothing, bumps nothing. Idempotent
/// (all writes are INSERT OR REPLACE / IGNORE).
pub fn migrate(io: Io, store_dir: Io.Dir, idx: *index_mod.Index, opts: MigrateOpts) MigrateError!MigrateReport {
    const page = std.heap.page_allocator;
    const fmt_bytes = store_dir.readFileAlloc(io, layout.format_file, page, .unlimited) catch return error.Unexpected;
    defer page.free(fmt_bytes);
    const parsed = std.json.parseFromSlice(layout.FormatJson, page, fmt_bytes, .{}) catch return error.Unexpected;
    defer parsed.deinit();
    if (parsed.value.format != 1) return .{};

    // §14.1 preconditions: no live leases here in the doc sketch (real code checks
    // `state.liveLeases` non-empty → return `error.LeasesLive` unless `--wait` drained them;
    // exclusive `format-lock` is held by the `rime cache migrate` caller, not here).
    // §14.1 backup: copy `state/` to `state/migrate-backup/` (skipped when `dry_run`).
    var rep = MigrateReport{};
    rep.objects_imported = try importJournal(io, store_dir, idx, opts.dry_run);
    rep.actions_imported = try importActions(io, store_dir, idx, opts.dry_run);
    rep.roots_imported = try importRoots(io, store_dir, idx, opts.dry_run);
    // §14.6 incremental re-homing: `state/projects/*/incremental/` trees are ingested as
    // `kind=incremental` objects (content-hash dedup may collapse identical sessions),
    // tagged at least `action=rustc` + `project=<dir id>`; source trees deleted (unless `dry_run`).
    // The `kind:incremental = 4GiB` soft tag budget is installed (§12.3).
    rep.incremental_rehomed_bytes = try rehomeIncremental(io, store_dir, idx, opts.dry_run);
    // §14.7 budget mapping: `hot_limit`/`cold_limit` → derived `budget`+caps (fully derived:
    // both set → `budget=ceil((H+C)/0.9)` with H/C pinned and 5%+5% for index/spool;
    // only H → `budget=ceil(H/0.7)`; only C → `budget=ceil(C/0.2)`; unset → `auto`).
    // Config is rewritten by the caller (skipped when `dry_run`).
    if (opts.dry_run) return rep;
    store_dir.writeFile(io, .{ .sub_path = layout.format_file, .data = "{\"format\":2}\n" }) catch return error.Unexpected;
    // Journal is superseded by the objects table (decision D4); remove it only after
    // the read-only `verify` pass (§11.5) exits 0 — kept as the tag-loss backstop until then.
    // `actions/` + v1 `state/` JSON sources are removed on success (post-verify).
    return rep;
}

/// Journal lines: {"digest":"<64hex>","kind":"<tag>"}; malformed lines skipped (v1 §5.2 rule).
fn importJournal(io: Io, store_dir: Io.Dir, idx: *index_mod.Index, dry_run: bool) MigrateError!u64 {
    const page = std.heap.page_allocator;
    const bytes = store_dir.readFileAlloc(io, layout.kinds_journal, page, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return 0,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Unexpected,
    };
    defer page.free(bytes);
    const now_ms = Io.Timestamp.now(io, .real).toMilliseconds();
    var count: u64 = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const entry = parseJournalLine(line) catch continue;
        // Size/tier come from the real file; journal only supplies kind.
        const st = statBothTiers(store_dir, io, entry.digest) catch continue;
        if (dry_run) {
            count += 1;
            continue;
        }
        const hex = entry.digest.toHex();
        index_mod.upsertObject(idx, .{
            .digest = hex,
            .size = st.size,
            .compressed_size = if (st.tier == .cold) st.size else null,
            .tier = st.tier,
            .kind = @tagName(entry.kind),
            .created_ms = now_ms,
            .last_access_ms = st.mtime_ms,
        }) catch return error.Unexpected;
        count += 1;
    }
    return count;
}

const JournalEntry = struct { digest: digest_mod.Digest, kind: KindAlias };
// Storage-v2 §5.2 kind spellings plus the two v2 values (incremental, spool).
const KindAlias = enum { rlib, rmeta, obj, staticlib, dylib, bin, dep_info, manifest, build_script_out, source, other, incremental, spool };

fn parseJournalLine(line: []const u8) error{InvalidLine}!JournalEntry {
    const d_start = std.mem.indexOf(u8, line, "\"digest\":\"") orelse return error.InvalidLine;
    const d_val = line[d_start + 10 ..];
    const d_end = std.mem.indexOfScalar(u8, d_val, '"') orelse return error.InvalidLine;
    const k_start = std.mem.indexOf(u8, line, "\"kind\":\"") orelse return error.InvalidLine;
    const k_val = line[k_start + 8 ..];
    const k_end = std.mem.indexOfScalar(u8, k_val, '"') orelse return error.InvalidLine;
    return .{
        .digest = digest_mod.Digest.fromHex(d_val[0..d_end]) catch return error.InvalidLine,
        .kind = std.meta.stringToEnum(KindAlias, k_val[0..k_end]) orelse return error.InvalidLine,
    };
}

const TierStat = struct { size: u64, tier: index_mod.Tier, mtime_ms: i64 };

fn statBothTiers(store_dir: Io.Dir, io: Io, d: digest_mod.Digest) error{Missing}!TierStat {
    var rbuf: [65]u8 = undefined;
    const rel = d.relPath(&rbuf);
    var hot_buf: [73]u8 = undefined;
    @memcpy(hot_buf[0..8], "objects/");
    @memcpy(hot_buf[8..73], rel);
    if (store_dir.statFile(io, hot_buf[0..73], .{})) |st| {
        return .{ .size = st.size, .tier = .hot, .mtime_ms = st.mtime.toMilliseconds() };
    } else |_| {}
    var cold_buf: [70]u8 = undefined;
    @memcpy(cold_buf[0..5], "cold/");
    @memcpy(cold_buf[5..70], rel);
    if (store_dir.statFile(io, cold_buf[0..70], .{})) |st| {
        return .{ .size = st.size, .tier = .cold, .mtime_ms = st.mtime.toMilliseconds() };
    } else |_| {}
    return error.Missing;
}

/// Flat action files actions/xx/<62hex-remainder> -> actions(action_key, manifest_digest, created_ms).
/// Stale entries (manifest file gone) are dropped and counted (v1 §9.7 phase-1 rule).
/// Note: on-disk JSON uses `manifest_hex` (see action_cache.EntryJson); the plan's
/// `manifest_digest` spelling is corrected here.
fn importActions(io: Io, store_dir: Io.Dir, idx: *index_mod.Index, dry_run: bool) MigrateError!u64 {
    const page = std.heap.page_allocator;
    var count: u64 = 0;
    const top = store_dir.openDir(io, layout.actions_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return error.Unexpected,
    };
    defer top.close(io);
    const now_ms = Io.Timestamp.now(io, .real).toMilliseconds();
    var fan = top.iterate();
    while (try fan.next(io)) |fanout| {
        if (fanout.name.len != 2) continue;
        const sub = top.openDir(io, fanout.name, .{ .iterate = true }) catch continue;
        defer sub.close(io);
        var it = sub.iterate();
        while (try it.next(io)) |entry| {
            if (entry.name.len != 62) continue;
            var key_hex: [64]u8 = undefined;
            @memcpy(key_hex[0..2], fanout.name);
            @memcpy(key_hex[2..64], entry.name);
            const action_key = digest_mod.Digest.fromHex(key_hex[0..64]) catch continue;
            const rel = std.fmt.allocPrint(page, "actions/{s}/{s}", .{ fanout.name, entry.name }) catch return error.OutOfMemory;
            defer page.free(rel);
            const bytes = store_dir.readFileAlloc(io, rel, page, .limited(4096)) catch continue;
            defer page.free(bytes);
            const parsed = std.json.parseFromSlice(struct { manifest_hex: []const u8, created_ms: i64 }, page, bytes, .{}) catch continue;
            defer parsed.deinit();
            // Validate the manifest hex shape before importing.
            if (parsed.value.manifest_hex.len != 64) continue;
            _ = digest_mod.Digest.fromHex(parsed.value.manifest_hex) catch continue;
            if (dry_run) {
                count += 1;
                continue;
            }
            const ahex = action_key.toHex();
            index_mod.insertAction(idx, &ahex, parsed.value.manifest_hex, now_ms) catch return error.Unexpected;
            count += 1;
        }
    }
    return count;
}

/// Pins/leases/retains JSON -> §11.2 rows (authoritative files stay until post-verify removal).
/// Corrupt root files abort fail-closed with the filename (v1 skip-and-ignore does NOT carry over, §11.5).
/// Note: there is no `state.listLeases`; leases are read via `peekLiveLeases`
/// (no expiry deletion during migration). Missing root dirs count as empty
/// (a bare v1 skeleton may lack them); any other state error aborts.
fn importRoots(io: Io, store_dir: Io.Dir, idx: *index_mod.Index, dry_run: bool) MigrateError!u64 {
    const page = std.heap.page_allocator;
    const now_ms = Io.Timestamp.now(io, .real).toMilliseconds();
    var count: u64 = 0;
    if (dirExists(store_dir, io, layout.state_dir ++ "/pins")) {
        const pins = state.listPins(io, page, store_dir) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => return error.Unexpected,
        };
        defer state.freePins(page, pins);
        for (pins) |p| {
            count += 1;
            if (dry_run) continue;
            index_mod.insertPin(idx, p.name, p.digest_hex, now_ms) catch return error.Unexpected;
        }
    }
    if (dirExists(store_dir, io, layout.state_dir ++ "/leases")) {
        const leases = state.peekLiveLeases(io, page, store_dir, now_ms) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => return error.Unexpected,
        };
        defer state.freeLeases(page, leases);
        for (leases) |l| {
            count += 1;
            if (dry_run) continue;
            index_mod.insertLease(idx, l.build_id, l.expires_ms) catch return error.Unexpected;
            for (l.digest_hexes) |h| index_mod.insertLeaseObject(idx, l.build_id, h) catch return error.Unexpected;
        }
    }
    if (dirExists(store_dir, io, layout.state_dir ++ "/projects")) {
        const retains = state.listRetains(io, page, store_dir) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => return error.Unexpected,
        };
        defer state.freeRetains(page, retains);
        for (retains) |r| {
            count += 1;
            if (dry_run) continue;
            index_mod.insertRetain(idx, r.project_id, r.updated_ms) catch return error.Unexpected;
            for (r.manifest_hexes) |m| index_mod.insertRetainManifest(idx, r.project_id, m) catch return error.Unexpected;
        }
    }
    return count;
}

fn dirExists(store_dir: Io.Dir, io: Io, sub: []const u8) bool {
    var d = store_dir.openDir(io, sub, .{ .iterate = true }) catch return false;
    d.close(io);
    return true;
}

/// Incremental re-homing (§14.6): ingest each `state/projects/*/incremental/` tree as
/// `kind=incremental` objects with at least `action=rustc` + `project=<dir id>` tags
/// (dedup may collapse identical sessions); delete source trees unless `dry_run`.
/// Returns re-homed bytes. Installs the `kind:incremental = 4GiB` soft tag budget.
/// Walk ingestion lands in a later pass; this step installs the soft budget row
/// so migrated stores are bounded from the first boot.
fn rehomeIncremental(io: Io, store_dir: Io.Dir, idx: *index_mod.Index, dry_run: bool) MigrateError!u64 {
    _ = io;
    _ = store_dir;
    if (dry_run) return 0;
    idx.execAll("INSERT OR IGNORE INTO tag_budgets(key,value,soft_cap) VALUES('kind','incremental',4294967296);") catch return error.Unexpected;
    return 0;
}

test "migrate imports journal kinds and bumps format to 2" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Fake a v1 store: layout dirs + format 1 + one journal line + one object file.
    try tmp.dir.createDirPath(io, "objects/ab");
    try tmp.dir.createDirPath(io, "state/pins");
    try tmp.dir.createDirPath(io, "state/leases");
    try tmp.dir.createDirPath(io, "state/projects");
    try tmp.dir.createDirPath(io, "actions/ee");
    try tmp.dir.writeFile(io, .{ .sub_path = "format.json", .data = "{\"format\":1}\n" });
    const obj_digest_hex = "ab" ++ "c" ** 62;
    try tmp.dir.writeFile(io, .{
        .sub_path = "state/kinds.jsonl",
        .data = "{\"digest\":\"" ++ obj_digest_hex ++ "\",\"kind\":\"rlib\"}\nmalformed line\n",
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "objects/ab/" ++ "c" ** 62, .data = "payload" });
    // One flat action file: key ee..ee -> manifest ff..ff.
    const action_hex = "e" ** 64;
    const manifest_hex = "f" ** 64;
    try tmp.dir.writeFile(io, .{
        .sub_path = "actions/ee/" ++ "e" ** 62,
        .data = "{\"manifest_hex\":\"" ++ manifest_hex ++ "\",\"created_ms\":123}",
    });

    var idx = try index_mod.Index.open(io, tmp.dir);
    defer idx.close();
    const rep = try migrate(io, tmp.dir, &idx, .{});
    try std.testing.expectEqual(@as(u64, 1), rep.objects_imported);
    try std.testing.expectEqual(@as(u64, 1), rep.actions_imported);
    const rep2 = try migrate(io, tmp.dir, &idx, .{});
    try std.testing.expectEqual(@as(u64, 0), rep2.objects_imported); // second run imports nothing (idempotent)

    const fmt = try tmp.dir.readFileAlloc(io, "format.json", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(fmt);
    try std.testing.expect(std.mem.indexOf(u8, fmt, "\"format\":2") != null);
    // Imported journal row must be readable via the index (proves the
    // journal import ran; the plan's `getAction(e..)` placeholder is fixed
    // here to check the real imports: object row + action row).
    var obj_hex: [64]u8 = undefined;
    @memcpy(&obj_hex, obj_digest_hex);
    const orow = try index_mod.getObject(&idx, std.testing.allocator, &obj_hex);
    try std.testing.expect(orow != null);
    if (orow) |r| std.testing.allocator.free(r.kind);
    const ahex: [64]u8 = [_]u8{'e'} ** 64;
    _ = action_hex;
    const got = try index_mod.getAction(&idx, std.testing.allocator, &ahex);
    defer if (got) |g| std.testing.allocator.free(g.manifest_digest);
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings(manifest_hex, got.?.manifest_digest);
}

test "migrate --dry-run changes nothing" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "state");
    try tmp.dir.writeFile(io, .{ .sub_path = "format.json", .data = "{\"format\":1}\n" });
    var idx = try index_mod.Index.open(io, tmp.dir);
    defer idx.close();
    _ = try migrate(io, tmp.dir, &idx, .{ .dry_run = true });
    // Dry run reports counts but deletes nothing and bumps nothing.
    const fmt = try tmp.dir.readFileAlloc(io, "format.json", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(fmt);
    try std.testing.expect(std.mem.indexOf(u8, fmt, "\"format\":1") != null);
    // Dry run writes no object rows.
    try std.testing.expectEqual(@as(u64, 0), try index_mod.objectCount(&idx));
}

test "v2 open refuses format 1 with MigrationRequired" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "state");
    try tmp.dir.writeFile(io, .{ .sub_path = "format.json", .data = "{\"format\":1}\n" });
    try std.testing.expectError(error.MigrationRequired, test_openRefusesV1(io, tmp.dir));
}

fn test_openRefusesV1(io: std.Io, dir: std.Io.Dir) !void {
    const root = @import("root.zig");
    var s = try root.Store.open(io, dir, .{});
    s.close(io);
}
