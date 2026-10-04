const std = @import("std");
const root = @import("root.zig");
const layout = @import("layout.zig");
const digest_mod = @import("digest.zig");
const test_support = @import("test_support.zig");
const index_mod = @import("index.zig");

const Io = std.Io;

pub const Tier = enum { hot, cold };

pub const ObjectInfo = struct {
    digest: digest_mod.Digest,
    tier: Tier,
    size: u64,
    mtime_ms: i64,
    kind: root.Kind,
};

pub const ScanError = error{Unexpected, OutOfMemory} || Io.Cancelable ||
    Io.Dir.OpenError || Io.Dir.StatFileError || Io.Dir.ReadFileAllocError ||
    Io.Dir.Iterator.Error || Io.File.OpenError;

/// Enumerates both tiers. Journal-less objects get kind `.other` (spec §5.2:
/// kind is best-effort performance metadata, never correctness).
///
/// Index-first (Plan B Task 6): object rows are served from the index when
/// present, with each digest's file verified in either tier. Values are
/// identical to the filesystem walk — tier/size/mtime come from the stat
/// (bytes are authoritative, decision D4), kind comes from the index row
/// (parsed via `stringToEnum`, `.other` fallback) instead of the journal.
/// Digests indexed but missing on disk self-heal by row delete. When the
/// index holds no rows but the walk finds objects (pre-migration store),
/// the walk results are returned and every found object is upserted so the
/// next scan hits the index path. The `scanTier`/`loadKinds` walk below is
/// kept untouched as that fallback.
pub fn scan(store: *root.Store, io: Io, gpa: std.mem.Allocator) ScanError![]ObjectInfo {
    if (scanIndex(store, io, gpa)) |maybe| {
        if (maybe) |infos| return infos;
    } else |_| {}
    return scanFilesystem(store, io, gpa);
}

/// Index path. Returns null when the index is empty (caller falls back to
/// the walk) or unreadable (bytes stay authoritative). Only OutOfMemory and
/// cancellation propagate; every other index error falls back to the walk.
fn scanIndex(store: *root.Store, io: Io, gpa: std.mem.Allocator) (error{OutOfMemory} || Io.Cancelable)!?[]ObjectInfo {
    const rows = index_mod.lruCandidates(&store.index, gpa, null, 1_000_000) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return null,
    };
    defer index_mod.freeRows(gpa, rows);
    if (rows.len == 0) return null;

    // Reconcile: the index may be partial (best-effort upsert dropped in a
    // crash window, external copy, pre-migration residue). Any file on disk
    // without an index row must not be silently omitted: fall back to the
    // filesystem walk, which backfills the index and returns the full set.
    if (try diskHasUnindexed(store, io, gpa, rows)) return null;

    var list: std.ArrayList(ObjectInfo) = .empty;
    errdefer list.deinit(gpa);
    for (rows) |r| {
        const d = digest_mod.Digest.fromHex(&r.digest) catch continue;
        // Authoritative stat: tier/size/mtime from the file that exists.
        // mtime_ms stays file-based (v1 §9.2 touch/age semantics): demote
        // and promote mint fresh files without bumping the index row, so
        // the file is the correct access-age source on this path.
        const found = statEitherTier(store, io, d) catch continue;
        if (found == null) {
            index_mod.deleteObject(&store.index, &r.digest) catch {};
            continue;
        }
        try list.append(gpa, .{
            .digest = d,
            .tier = found.?.tier,
            .size = found.?.size,
            .mtime_ms = found.?.mtime_ms,
            .kind = std.meta.stringToEnum(root.Kind, r.kind) orelse .other,
        });
    }
    return try list.toOwnedSlice(gpa);
}

const TierStat = struct { tier: Tier, size: u64, mtime_ms: i64 };

/// True when any file under objects/ or cold/ lacks an index row. Missing
/// tier dirs count as empty; any other unreadable dir/entry is treated as
/// missing so the caller falls back to the authoritative filesystem walk.
fn diskHasUnindexed(store: *root.Store, io: Io, gpa: std.mem.Allocator, rows: []const index_mod.ObjectRow) (error{OutOfMemory} || Io.Cancelable)!bool {
    var set: std.AutoHashMap([64]u8, void) = .init(gpa);
    defer set.deinit();
    for (rows) |r| try set.put(r.digest, {});
    const tier_dirs = [_][]const u8{ layout.objects_dir, layout.cold_dir };
    for (tier_dirs) |tier_dir| {
        const top = store.dir.openDir(io, tier_dir, .{ .iterate = true }) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            if (err == error.Canceled) return error.Canceled;
            if (err == error.FileNotFound) continue;
            return true;
        };
        defer top.close(io);
        var fan = top.iterate();
        while (true) {
            const fanout = (fan.next(io) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                if (err == error.Canceled) return error.Canceled;
                return true;
            }) orelse break;
            if (fanout.name.len != 2) continue;
            const sub = top.openDir(io, fanout.name, .{ .iterate = true }) catch continue;
            defer sub.close(io);
            var it = sub.iterate();
            while (true) {
                const entry = (it.next(io) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    if (err == error.Canceled) return error.Canceled;
                    return true;
                }) orelse break;
                if (entry.name.len != 62) continue;
                var hex: [64]u8 = undefined;
                @memcpy(hex[0..2], fanout.name);
                @memcpy(hex[2..64], entry.name);
                _ = digest_mod.Digest.fromHex(hex[0..64]) catch continue;
                if (set.get(hex) == null) return true;
            }
        }
    }
    return false;
}

/// Stats the hot copy first, then the cold copy. Null when neither exists.
fn statEitherTier(store: *root.Store, io: Io, d: digest_mod.Digest) ScanError!?TierStat {
    var rbuf: [65]u8 = undefined;
    const rel = d.relPath(&rbuf);
    var hot_buf: [73]u8 = undefined;
    @memcpy(hot_buf[0..8], "objects/");
    @memcpy(hot_buf[8..], rel);
    if (store.dir.statFile(io, hot_buf[0..73], .{})) |st| {
        return .{ .tier = .hot, .size = st.size, .mtime_ms = st.mtime.toMilliseconds() };
    } else |_| {}
    var cold_buf: [70]u8 = undefined;
    @memcpy(cold_buf[0..5], "cold/");
    @memcpy(cold_buf[5..70], rel);
    if (store.dir.statFile(io, cold_buf[0..70], .{})) |st| {
        return .{ .tier = .cold, .size = st.size, .mtime_ms = st.mtime.toMilliseconds() };
    } else |_| {}
    return null;
}

/// Filesystem walk with index backfill: every found object is upserted
/// (file mtime seeds `last_access_ms` so ages survive migration; cold rows
/// record the on-disk (compressed) size in both size fields as the
/// uncompressed size is unknowable from the walk).
fn scanFilesystem(store: *root.Store, io: Io, gpa: std.mem.Allocator) ScanError![]ObjectInfo {
    var kinds = try loadKinds(store, io, gpa);
    defer kinds.deinit();

    var list: std.ArrayList(ObjectInfo) = .empty;
    errdefer list.deinit(gpa);

    try scanTier(io, gpa, store.dir, layout.objects_dir, .hot, &kinds, &list);
    try scanTier(io, gpa, store.dir, layout.cold_dir, .cold, &kinds, &list);
    for (list.items) |obj| {
        const hex = obj.digest.toHex();
        index_mod.upsertObject(&store.index, .{
            .digest = hex,
            .size = obj.size,
            .compressed_size = if (obj.tier == .cold) obj.size else null,
            .tier = if (obj.tier == .hot) .hot else .cold,
            .kind = @tagName(obj.kind),
            .created_ms = obj.mtime_ms,
            .last_access_ms = obj.mtime_ms,
        }) catch {};
    }
    return try list.toOwnedSlice(gpa);
}

fn scanTier(
    io: Io,
    gpa: std.mem.Allocator,
    store_dir: Io.Dir,
    tier_dir: []const u8,
    tier: Tier,
    kinds: *const KindMap,
    list: *std.ArrayList(ObjectInfo),
) ScanError!void {
    const top = store_dir.openDir(io, tier_dir, .{ .iterate = true }) catch return error.Unexpected;
    defer top.close(io);
    var fan = top.iterate();
    while (try fan.next(io)) |fanout| {
        if (fanout.name.len != 2) continue;
        const sub = top.openDir(io, fanout.name, .{ .iterate = true }) catch continue;
        defer sub.close(io);
        var it = sub.iterate();
        while (try it.next(io)) |entry| {
            // Object files are named by the 62-char hex remainder
            // (spec §6: "objects/<hex[0..2]>/<hex[2..]>"); the fanout
            // dir supplies the first byte.
            if (entry.name.len != 62) continue;
            var hex_buf: [64]u8 = undefined;
            @memcpy(hex_buf[0..2], fanout.name);
            @memcpy(hex_buf[2..64], entry.name);
            const d = digest_mod.Digest.fromHex(hex_buf[0..64]) catch continue;
            const st = sub.statFile(io, entry.name, .{}) catch continue;
            try list.append(gpa, .{
                .digest = d,
                .tier = tier,
                .size = st.size,
                .mtime_ms = st.mtime.toMilliseconds(),
                .kind = kinds.get(d.bytes) orelse .other,
            });
        }
    }
}

const KindMap = std.AutoHashMap([32]u8, root.Kind);

fn loadKinds(store: *root.Store, io: Io, gpa: std.mem.Allocator) ScanError!KindMap {
    var map = KindMap.init(gpa);
    errdefer map.deinit();
    const path = layout.state_dir ++ "/kinds.jsonl";
    const bytes = store.dir.readFileAlloc(io, path, gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return map,
        else => return error.Unexpected,
    };
    defer gpa.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const kv = parseKindLine(line) catch continue;
        try map.put(kv.digest, kv.kind);
    }
    return map;
}

const KindEntry = struct { digest: [32]u8, kind: root.Kind };

fn parseKindLine(line: []const u8) error{InvalidLine}!KindEntry {
    const d_start = std.mem.indexOf(u8, line, "\"digest\":\"") orelse return error.InvalidLine;
    const d_val = line[d_start + 10 ..];
    const d_end = std.mem.indexOfScalar(u8, d_val, '"') orelse return error.InvalidLine;
    const d = digest_mod.Digest.fromHex(d_val[0..d_end]) catch return error.InvalidLine;
    const k_start = std.mem.indexOf(u8, line, "\"kind\":\"") orelse return error.InvalidLine;
    const k_val = line[k_start + 8 ..];
    const k_end = std.mem.indexOfScalar(u8, k_val, '"') orelse return error.InvalidLine;
    const kind = std.meta.stringToEnum(root.Kind, k_val[0..k_end]) orelse return error.InvalidLine;
    return .{ .digest = d.bytes, .kind = kind };
}

/// Updates mtime on cache hits at most once per touch_interval_ns (spec §9.2).
pub fn touch(store: *root.Store, io: Io, digest: digest_mod.Digest) void {
    var path_buf: [73]u8 = undefined;
    const f = store.dir.openFile(io, objectFull(digest, &path_buf), .{}) catch return;
    defer f.close(io);
    const st = f.stat(io) catch return;
    const now_ms = Io.Timestamp.now(io, .real).toMilliseconds();
    const age_ns = @as(u64, @intCast(@max(0, now_ms - st.mtime.toMilliseconds()))) * std.time.ns_per_ms;
    if (age_ns < store.config.touch_interval_ns) return;
    f.setTimestampsNow(io) catch {};
}

/// Store-relative object path: "objects/<hex[0..2]>/<hex[2..]>".
fn objectFull(d: digest_mod.Digest, buf: *[73]u8) []const u8 {
    var rbuf: [65]u8 = undefined;
    const rel = d.relPath(&rbuf);
    @memcpy(buf[0..8], "objects/");
    @memcpy(buf[8..], rel);
    return buf[0..73];
}

test "scan reports tier size mtime and kind" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);

    const d = try ts.store.putBytes(io, "12345", .rlib);
    const infos = try ts.store.scan(io, gpa);
    defer gpa.free(infos);
    try std.testing.expectEqual(@as(usize, 1), infos.len);
    try std.testing.expectEqual(root.Digest{ .bytes = d.bytes }, infos[0].digest);
    try std.testing.expectEqual(Tier.hot, infos[0].tier);
    try std.testing.expectEqual(@as(u64, 5), infos[0].size);
    try std.testing.expectEqual(root.Kind.rlib, infos[0].kind);
    try std.testing.expect(infos[0].mtime_ms > 0);
}

test "touch refreshes mtime only after the throttle interval" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);

    const d = try ts.store.putBytes(io, "touched", .other);
    var pre_buf: [73]u8 = undefined;
    const pre_mtime = (try ts.store.dir.statFile(io, objectFull(d, &pre_buf), .{})).mtime.toMilliseconds();
    ts.store.touch(io, d); // within 1h of ingest: no change
    var post_buf: [73]u8 = undefined;
    const post_mtime = (try ts.store.dir.statFile(io, objectFull(d, &post_buf), .{})).mtime.toMilliseconds();
    try std.testing.expectEqual(pre_mtime, post_mtime);

    // Backdate the object beyond the throttle, then touch must refresh it.
    var buf: [73]u8 = undefined;
    const f = try ts.store.dir.openFile(io, objectFull(d, &buf), .{});
    defer f.close(io);
    const old = std.Io.Timestamp.fromNanoseconds(1_000_000_000);
    try f.setTimestamps(io, .{ .modify_timestamp = .{ .new = old } });

    ts.store.touch(io, d);
    const st = try ts.store.dir.statFile(io, objectFull(d, &buf), .{});
    try std.testing.expect(st.mtime.toMilliseconds() > 60_000);
}

test "scan serves indexed objects (index row present; fallback disabled)" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);

    const d = try ts.store.putBytes(io, "indexed", .rlib);
    // Failing-first gate: the index row must exist (proves the ingest mirror ran).
    const hex = d.toHex();
    const row = try index_mod.getObject(&ts.store.index, gpa, &hex);
    try std.testing.expect(row != null);
    if (row) |r| gpa.free(r.kind);
    // Disable the filesystem fallback: without kinds.jsonl the walk can only
    // report kind .other, so kind rlib below proves the index path served it.
    try ts.store.dir.deleteFile(io, "state/kinds.jsonl");
    const infos = try ts.store.scan(io, gpa);
    defer gpa.free(infos);
    try std.testing.expectEqual(@as(usize, 1), infos.len);
    try std.testing.expectEqual(d.bytes, infos[0].digest.bytes);
    try std.testing.expectEqual(root.Kind.rlib, infos[0].kind);
}

test "scan reconciles disk objects missing from the index" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);

    const a = try ts.store.putBytes(io, "first", .rlib);
    const b = try ts.store.putBytes(io, "second", .bin);
    // Evict one row behind the filesystem's back: the file stays on disk.
    const bhex = b.toHex();
    try index_mod.deleteObject(&ts.store.index, &bhex);
    try std.testing.expect((try index_mod.getObject(&ts.store.index, gpa, &bhex)) == null);
    // Index holds one row but disk holds two files: scan must return both
    // via the fallback walk and backfill the missing row.
    const infos = try ts.store.scan(io, gpa);
    defer gpa.free(infos);
    try std.testing.expectEqual(@as(usize, 2), infos.len);
    const backfilled = try index_mod.getObject(&ts.store.index, gpa, &bhex);
    try std.testing.expect(backfilled != null);
    if (backfilled) |r| gpa.free(r.kind);
    _ = a;
}
