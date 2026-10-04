const std = @import("std");
const index_mod = @import("index.zig");
const layout = @import("layout.zig");
const state = @import("state.zig");
const digest_mod = @import("digest.zig");
const tags_mod = @import("tags.zig");
const disk_usage_mod = @import("disk_usage.zig");

const Io = std.Io;

pub const MigrateError = index_mod.DbError || state.StateError || disk_usage_mod.DiskUsageError || error{ Unexpected, OutOfMemory, LeasesLive, CorruptRoot, NoHeadroom };

/// Filename of the last corrupt root file seen by the strict importer.
/// Zig errors carry no payload, so the fail-closed path records the name
/// here (truncated to the buffer) for the CLI to report alongside
/// `error.CorruptRoot`; tests assert it directly. Reset on every `migrate`.
var last_bad_root_buf: [512]u8 = undefined;
var last_bad_root_len: usize = 0;

pub fn lastBadRoot() []const u8 {
    return last_bad_root_buf[0..last_bad_root_len];
}

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
    last_bad_root_len = 0;

    // §14.1 preconditions (fail-closed before touching anything): no live
    // leases (builds must drain; the caller holds the exclusive
    // `format-lock` for the whole run), free space ≥ index headroom
    // `max(256 MiB, 1% of hot bytes)`, and a publishable `state/` backup.
    // Dry run checks preconditions but writes nothing.
    try checkNoLiveLeases(io, store_dir);
    try checkHeadroom(io, store_dir);
    if (!opts.dry_run) try backupState(io, store_dir);
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

/// §14.1 live-lease gate: any unexpired lease aborts fail-closed with
/// `error.LeasesLive` (operator drains builds or re-runs with `--wait`).
/// Peek-only: expired files are left for the migration to import, never
/// reaped here.
fn checkNoLiveLeases(io: Io, store_dir: Io.Dir) MigrateError!void {
    const page = std.heap.page_allocator;
    const now_ms = Io.Timestamp.now(io, .real).toMilliseconds();
    // Missing leases dir counts as empty (bare v1 skeleton).
    var probe = store_dir.openDir(io, layout.state_dir ++ "/leases", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        error.Canceled => return error.Canceled,
        else => return error.Unexpected,
    };
    probe.close(io);
    const live = try state.peekLiveLeases(io, page, store_dir, now_ms);
    defer state.freeLeases(page, live);
    if (live.len > 0) {
        return error.LeasesLive;
    }
}

/// §14.1 headroom: free space must cover `max(256 MiB, 1% of hot bytes)`
/// for the index build (WAL + rows) before anything is written.
fn checkHeadroom(io: Io, store_dir: Io.Dir) MigrateError!void {
    const hot = try hotBytes(store_dir, io);
    const need = @max(256 * 1024 * 1024, hot / 100);
    const disk = try disk_usage_mod.readDiskUsage(io, store_dir);
    if (disk.free_bytes < need) {
        return error.NoHeadroom;
    }
}

fn hotBytes(store_dir: Io.Dir, io: Io) MigrateError!u64 {
    const page = std.heap.page_allocator;
    var total: u64 = 0;
    const top = store_dir.openDir(io, layout.objects_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        error.Canceled => return error.Canceled,
        else => return error.Unexpected,
    };
    defer top.close(io);
    var fan = top.iterate();
    while (try fan.next(io)) |fanout| {
        if (fanout.name.len != 2) continue;
        const sub = top.openDir(io, fanout.name, .{ .iterate = true }) catch continue;
        defer sub.close(io);
        var it = sub.iterate();
        while (try it.next(io)) |entry| {
            if (entry.name.len != 62) continue;
            const rel = std.fmt.allocPrint(page, "{s}/{s}/{s}", .{ layout.objects_dir, fanout.name, entry.name }) catch return error.OutOfMemory;
            defer page.free(rel);
            if (store_dir.statFile(io, rel, .{})) |st| total +|= st.size else |_| {}
        }
    }
    return total;
}

/// §14.1 backup: recursive copy of `state/` to `state/migrate-backup/`.
/// Skipped when dry_run (caller gates). Idempotent: a previous backup is
/// replaced wholesale via deleteTree + copy.
fn backupState(io: Io, store_dir: Io.Dir) MigrateError!void {
    const src = layout.state_dir;
    const dst = layout.state_dir ++ "/migrate-backup";
    // A backup inside the source tree must not recurse into itself: clear
    // any previous backup first, then copy excluding the backup dir.
    // Missing backup is fine (orelse-return inside deleteTree); any other
    // failure is best-effort too — the copy below replaces wholesale.
    store_dir.deleteTree(io, dst) catch {};
    copyDirRecursive(io, store_dir, src, dst, true) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return error.Unexpected,
    };
}

fn copyDirRecursive(io: Io, store_dir: Io.Dir, src_sub: []const u8, dst_sub: []const u8, comptime is_root: bool) (error{OutOfMemory} || Io.Cancelable || Io.Dir.OpenError || Io.Dir.Iterator.Error || Io.Dir.CreateDirPathError || Io.Dir.CopyFileError)!void {
    const page = std.heap.page_allocator;
    const src = try store_dir.openDir(io, src_sub, .{ .iterate = true });
    defer src.close(io);
    try store_dir.createDirPath(io, dst_sub);
    var it = src.iterate();
    while (try it.next(io)) |entry| {
        // Never copy the backup into itself.
        if (is_root and std.mem.eql(u8, entry.name, "migrate-backup")) continue;
        const s = try std.fmt.allocPrint(page, "{s}/{s}", .{ src_sub, entry.name });
        defer page.free(s);
        const d = try std.fmt.allocPrint(page, "{s}/{s}", .{ dst_sub, entry.name });
        defer page.free(d);
        if (entry.kind == .directory) {
            try store_dir.createDirPath(io, d);
            try copyDirRecursive(io, store_dir, s, d, false);
        } else {
            try Io.Dir.copyFile(store_dir, s, store_dir, d, io, .{ .make_path = true });
        }
    }
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
/// Strict fail-closed import (§14.5/§11.5): every root file is read and
/// validated individually; any corrupt file aborts the migration with
/// `error.CorruptRoot` and the filename in the log (v1 skip-and-ignore
/// does NOT carry over to roots). Missing root dirs count as empty (a bare
/// v1 skeleton may lack them). Expired leases are imported as-is (GC
/// expires them); corrupt shape in any file — bad JSON, non-64-hex
/// digests, missing fields — aborts before anything is committed.
fn importRoots(io: Io, store_dir: Io.Dir, idx: *index_mod.Index, dry_run: bool) MigrateError!u64 {
    const page = std.heap.page_allocator;
    const now_ms = Io.Timestamp.now(io, .real).toMilliseconds();
    var count: u64 = 0;
    count += try importPinsStrict(io, store_dir, idx, page, now_ms, dry_run);
    count += try importLeasesStrict(io, store_dir, idx, page, now_ms, dry_run);
    count += try importRetainsStrict(io, store_dir, idx, page, dry_run);
    return count;
}

const PinFile = struct { name: []const u8, digest_hex: []const u8, created_ms: i64 };
const LeaseFile = struct { build_id: []const u8, digest_hexes: []const []const u8, expires_ms: i64 };
const RetainFile = struct { project_id: []const u8, manifest_hexes: []const []const u8, updated_ms: i64 };

fn failRoot(sub_path: []const u8) MigrateError {
    // Zig errors carry no payload: record the filename for lastBadRoot()
    // (CLI reports it; tests assert it) instead of logging — the test
    // runner fails any test that emits via std.log/std.debug during the run.
    const n = @min(sub_path.len, last_bad_root_buf.len);
    @memcpy(last_bad_root_buf[0..n], sub_path[0..n]);
    last_bad_root_len = n;
    return error.CorruptRoot;
}

fn checkHex64(hex: []const u8) bool {
    if (hex.len != 64) return false;
    for (hex) |ch| {
        const ok = (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F');
        if (!ok) return false;
    }
    return true;
}

fn importPinsStrict(io: Io, store_dir: Io.Dir, idx: *index_mod.Index, gpa: std.mem.Allocator, now_ms: i64, dry_run: bool) MigrateError!u64 {
    const sub = layout.state_dir ++ "/pins";
    const dir = store_dir.openDir(io, sub, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        error.Canceled => return error.Canceled,
        else => return error.Unexpected,
    };
    defer dir.close(io);
    var count: u64 = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const rel = std.fmt.allocPrint(gpa, "{s}/{s}", .{ sub, entry.name }) catch return error.OutOfMemory;
        defer gpa.free(rel);
        const bytes = store_dir.readFileAlloc(io, rel, gpa, .unlimited) catch return failRoot(rel);
        defer gpa.free(bytes);
        const parsed = std.json.parseFromSlice(PinFile, gpa, bytes, .{ .allocate = .alloc_always }) catch return failRoot(rel);
        defer parsed.deinit();
        if (parsed.value.name.len == 0 or !checkHex64(parsed.value.digest_hex)) return failRoot(rel);
        count += 1;
        if (dry_run) continue;
        index_mod.insertPin(idx, parsed.value.name, parsed.value.digest_hex, now_ms) catch return error.Unexpected;
    }
    return count;
}

fn importLeasesStrict(io: Io, store_dir: Io.Dir, idx: *index_mod.Index, gpa: std.mem.Allocator, now_ms: i64, dry_run: bool) MigrateError!u64 {
    _ = now_ms;
    const sub = layout.state_dir ++ "/leases";
    const dir = store_dir.openDir(io, sub, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        error.Canceled => return error.Canceled,
        else => return error.Unexpected,
    };
    defer dir.close(io);
    var count: u64 = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const rel = std.fmt.allocPrint(gpa, "{s}/{s}", .{ sub, entry.name }) catch return error.OutOfMemory;
        defer gpa.free(rel);
        const bytes = store_dir.readFileAlloc(io, rel, gpa, .unlimited) catch return failRoot(rel);
        defer gpa.free(bytes);
        const parsed = std.json.parseFromSlice(LeaseFile, gpa, bytes, .{ .allocate = .alloc_always }) catch return failRoot(rel);
        defer parsed.deinit();
        if (parsed.value.build_id.len == 0) return failRoot(rel);
        for (parsed.value.digest_hexes) |h| if (!checkHex64(h)) return failRoot(rel);
        count += 1;
        if (dry_run) continue;
        index_mod.insertLease(idx, parsed.value.build_id, parsed.value.expires_ms) catch return error.Unexpected;
        for (parsed.value.digest_hexes) |h| index_mod.insertLeaseObject(idx, parsed.value.build_id, h) catch return error.Unexpected;
    }
    return count;
}

fn importRetainsStrict(io: Io, store_dir: Io.Dir, idx: *index_mod.Index, gpa: std.mem.Allocator, dry_run: bool) MigrateError!u64 {
    const sub = layout.state_dir ++ "/projects";
    const dir = store_dir.openDir(io, sub, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        error.Canceled => return error.Canceled,
        else => return error.Unexpected,
    };
    defer dir.close(io);
    var count: u64 = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const rel = std.fmt.allocPrint(gpa, "{s}/{s}", .{ sub, entry.name }) catch return error.OutOfMemory;
        defer gpa.free(rel);
        const bytes = store_dir.readFileAlloc(io, rel, gpa, .unlimited) catch return failRoot(rel);
        defer gpa.free(bytes);
        const parsed = std.json.parseFromSlice(RetainFile, gpa, bytes, .{ .allocate = .alloc_always }) catch return failRoot(rel);
        defer parsed.deinit();
        if (parsed.value.project_id.len == 0) return failRoot(rel);
        for (parsed.value.manifest_hexes) |h| if (!checkHex64(h)) return failRoot(rel);
        count += 1;
        if (dry_run) continue;
        index_mod.insertRetain(idx, parsed.value.project_id, parsed.value.updated_ms) catch return error.Unexpected;
        for (parsed.value.manifest_hexes) |m| index_mod.insertRetainManifest(idx, parsed.value.project_id, m) catch return error.Unexpected;
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
/// Dry run walks and counts without ingesting, tagging, deleting, or
/// installing the budget row.
fn rehomeIncremental(io: Io, store_dir: Io.Dir, idx: *index_mod.Index, dry_run: bool) MigrateError!u64 {
    const page = std.heap.page_allocator;
    const now_ms = Io.Timestamp.now(io, .real).toMilliseconds();
    var total: u64 = 0;
    const projs_sub = layout.state_dir ++ "/projects";
    const projs = store_dir.openDir(io, projs_sub, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            if (dry_run) return 0;
            idx.execAll("INSERT OR IGNORE INTO tag_budgets(key,value,soft_cap) VALUES('kind','incremental',4294967296);") catch return error.Unexpected;
            return 0;
        },
        error.Canceled => return error.Canceled,
        else => return error.Unexpected,
    };
    defer projs.close(io);
    var it = projs.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".json")) continue;
        if (std.mem.eql(u8, entry.name, "migrate-backup")) continue;
        const incr_sub = std.fmt.allocPrint(page, "{s}/{s}/incremental", .{ projs_sub, entry.name }) catch return error.OutOfMemory;
        defer page.free(incr_sub);
        // Missing incremental tree counts as empty (project without sessions).
        var probe = store_dir.openDir(io, incr_sub, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => continue,
            error.Canceled => return error.Canceled,
            else => continue,
        };
        probe.close(io);
        total += try rehomeOneProject(io, store_dir, idx, page, incr_sub, entry.name, now_ms, dry_run);
        if (!dry_run) store_dir.deleteTree(io, incr_sub) catch {};
    }
    if (dry_run) return total;
    idx.execAll("INSERT OR IGNORE INTO tag_budgets(key,value,soft_cap) VALUES('kind','incremental',4294967296);") catch return error.Unexpected;
    return total;
}

/// Ingests every regular file under one `incremental/` tree as a hot
/// `kind=incremental` object (content-hash dedup: identical sessions
/// collapse to one object), tagged `action=rustc` + `project=<dir id>`.
/// Returns the source bytes walked. Files are published 0o444 like any
/// ingested object; the index row seeds `last_access_ms` from the source
/// mtime so ages survive migration.
fn rehomeOneProject(io: Io, store_dir: Io.Dir, idx: *index_mod.Index, gpa: std.mem.Allocator, incr_sub: []const u8, project_id: []const u8, now_ms: i64, dry_run: bool) MigrateError!u64 {
    var total: u64 = 0;
    const incr = store_dir.openDir(io, incr_sub, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        error.Canceled => return error.Canceled,
        else => return error.Unexpected,
    };
    defer incr.close(io);
    var it = incr.iterate();
    while (try it.next(io)) |entry| {
        const rel = std.fmt.allocPrint(gpa, "{s}/{s}", .{ incr_sub, entry.name }) catch return error.OutOfMemory;
        defer gpa.free(rel);
        if (entry.kind == .directory) {
            total += try rehomeOneProject(io, store_dir, idx, gpa, rel, project_id, now_ms, dry_run);
            continue;
        }
        const st = store_dir.statFile(io, rel, .{}) catch continue;
        total += st.size;
        if (dry_run) continue;
        const bytes = store_dir.readFileAlloc(io, rel, gpa, .unlimited) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => continue,
        };
        defer gpa.free(bytes);
        const d = digest_mod.hashBytes(bytes);
        const hex = d.toHex();
        // Publish under objects/ (hot, immutable 0o444); dedup race is
        // won by whoever renames first — rename misses are ignored.
        var rbuf: [65]u8 = undefined;
        const rrel = d.relPath(&rbuf);
        var full: [73]u8 = undefined;
        @memcpy(full[0..8], "objects/");
        @memcpy(full[8..73], rrel);
        store_dir.createDirPath(io, full[0..10]) catch continue;
        const already = if (store_dir.statFile(io, full[0..73], .{})) |_| true else |_| false;
        if (!already) {
            store_dir.writeFile(io, .{ .sub_path = full[0..73], .data = bytes }) catch continue;
            if (store_dir.openFile(io, full[0..73], .{})) |f| {
                defer f.close(io);
                f.setPermissions(io, .fromMode(0o444)) catch {};
            } else |_| {}
        }
        index_mod.upsertObject(idx, .{
            .digest = hex,
            .size = st.size,
            .compressed_size = null,
            .tier = .hot,
            .kind = "incremental",
            .created_ms = now_ms,
            .last_access_ms = st.mtime.toMilliseconds(),
        }) catch return error.Unexpected;
        tags_mod.tagObject(idx, &hex, &.{ .{ .key = "action", .value = "rustc" }, .{ .key = "project", .value = project_id } }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            // Tag gate (e.g. TagLimit) must not fail migration: the bytes
            // are already published; untagged sessions are
            // evictable-first per §12.2 (accepted transient, §14.3).
            else => {},
        };
    }
    return total;
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

test "migrate refuses live leases" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "state/leases");
    try tmp.dir.writeFile(io, .{ .sub_path = "format.json", .data = "{\"format\":1}\n" });
    const now_ms = Io.Timestamp.now(io, .real).toMilliseconds();
    const lease_json = try std.fmt.allocPrint(std.testing.allocator, "{{\"build_id\":\"b1\",\"digest_hexes\":[],\"expires_ms\":{d}}}", .{now_ms + 2 * 60 * 60 * 1000});
    defer std.testing.allocator.free(lease_json);
    try tmp.dir.writeFile(io, .{ .sub_path = "state/leases/b1", .data = lease_json });
    var idx = try index_mod.Index.open(io, tmp.dir);
    defer idx.close();
    try std.testing.expectError(error.LeasesLive, migrate(io, tmp.dir, &idx, .{}));
    // Fail-closed: format untouched.
    const fmt = try tmp.dir.readFileAlloc(io, "format.json", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(fmt);
    try std.testing.expect(std.mem.indexOf(u8, fmt, "\"format\":1") != null);
}

test "migrate backs up state before importing" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "state/pins");
    try tmp.dir.writeFile(io, .{ .sub_path = "format.json", .data = "{\"format\":1}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "state/pins/keep", .data = "{\"name\":\"keep\",\"digest_hex\":\"" ++ "a" ** 64 ++ "\",\"created_ms\":1}" });
    var idx = try index_mod.Index.open(io, tmp.dir);
    defer idx.close();
    _ = try migrate(io, tmp.dir, &idx, .{});
    // Backup holds the pre-migration pin file.
    const backed = try tmp.dir.readFileAlloc(io, "state/migrate-backup/pins/keep", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(backed);
    try std.testing.expect(std.mem.indexOf(u8, backed, "keep") != null);
}

test "migrate aborts on corrupt root" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "state/pins");
    try tmp.dir.writeFile(io, .{ .sub_path = "format.json", .data = "{\"format\":1}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "state/pins/bad", .data = "{not json" });
    var idx = try index_mod.Index.open(io, tmp.dir);
    defer idx.close();
    try std.testing.expectError(error.CorruptRoot, migrate(io, tmp.dir, &idx, .{}));
    // The filename travels via lastBadRoot (errors carry no payload).
    try std.testing.expect(std.mem.indexOf(u8, lastBadRoot(), "state/pins/bad") != null);
}

test "migrate rehomes incremental trees as tagged objects" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "state/projects/proj1/incremental");
    try tmp.dir.writeFile(io, .{ .sub_path = "format.json", .data = "{\"format\":1}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "state/projects/proj1/incremental/sess.bin", .data = "session-bytes" });
    var idx = try index_mod.Index.open(io, tmp.dir);
    defer idx.close();
    const rep = try migrate(io, tmp.dir, &idx, .{});
    try std.testing.expectEqual(@as(u64, 13), rep.incremental_rehomed_bytes);
    // Object row exists with kind=incremental.
    const d = digest_mod.hashBytes("session-bytes");
    const hex = d.toHex();
    const row = try index_mod.getObject(&idx, std.testing.allocator, &hex);
    try std.testing.expect(row != null);
    try std.testing.expectEqualStrings("incremental", row.?.kind);
    std.testing.allocator.free(row.?.kind);
    // Tags carry action=rustc + project=proj1.
    const tags = try tags_mod.tagsFor(std.testing.allocator, &idx, &hex);
    defer tags_mod.freeTags(std.testing.allocator, tags);
    var has_action = false;
    var has_project = false;
    for (tags) |t| {
        if (std.mem.eql(u8, t.key, "action") and std.mem.eql(u8, t.value, "rustc")) has_action = true;
        if (std.mem.eql(u8, t.key, "project") and std.mem.eql(u8, t.value, "proj1")) has_project = true;
    }
    try std.testing.expect(has_action and has_project);
    // Source tree deleted; soft budget installed.
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "state/projects/proj1/incremental/sess.bin", .{}));
    const budgets = try index_mod.listTagBudgets(&idx, std.testing.allocator);
    defer index_mod.freeTagBudgets(std.testing.allocator, budgets);
    var found = false;
    for (budgets) |b| {
        if (std.mem.eql(u8, b.key, "kind") and std.mem.eql(u8, b.value, "incremental")) found = true;
    }
    try std.testing.expect(found);
}

test "migrate dry run counts incremental without ingesting" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "state/projects/proj1/incremental");
    try tmp.dir.writeFile(io, .{ .sub_path = "format.json", .data = "{\"format\":1}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "state/projects/proj1/incremental/sess.bin", .data = "12345" });
    var idx = try index_mod.Index.open(io, tmp.dir);
    defer idx.close();
    const rep = try migrate(io, tmp.dir, &idx, .{ .dry_run = true });
    try std.testing.expectEqual(@as(u64, 5), rep.incremental_rehomed_bytes);
    // Dry run: source stays, no object row, no budget row, format stays 1.
    _ = try tmp.dir.statFile(io, "state/projects/proj1/incremental/sess.bin", .{});
    try std.testing.expectEqual(@as(u64, 0), try index_mod.objectCount(&idx));
    const budgets = try index_mod.listTagBudgets(&idx, std.testing.allocator);
    defer index_mod.freeTagBudgets(std.testing.allocator, budgets);
    try std.testing.expectEqual(@as(usize, 0), budgets.len);
    const fmt = try tmp.dir.readFileAlloc(io, "format.json", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(fmt);
    try std.testing.expect(std.mem.indexOf(u8, fmt, "\"format\":1") != null);
}
