const std = @import("std");
const root = @import("root.zig");
const layout = @import("layout.zig");
const digest_mod = @import("digest.zig");
const test_support = @import("test_support.zig");

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
pub fn scan(store: *root.Store, io: Io, gpa: std.mem.Allocator) ScanError![]ObjectInfo {
    var kinds = try loadKinds(store, io, gpa);
    defer kinds.deinit();

    var list: std.ArrayList(ObjectInfo) = .empty;
    errdefer list.deinit(gpa);

    try scanTier(io, gpa, store.dir, layout.objects_dir, .hot, &kinds, &list);
    try scanTier(io, gpa, store.dir, layout.cold_dir, .cold, &kinds, &list);
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
            // Object files are named by the full 64-char hex digest
            // (Digest.relPath duplicates the first byte after the slash).
            if (entry.name.len != 64) continue;
            const d = digest_mod.Digest.fromHex(entry.name) catch continue;
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
    var path_buf: [75]u8 = undefined;
    const f = store.dir.openFile(io, objectFull(digest, &path_buf), .{}) catch return;
    defer f.close(io);
    const st = f.stat(io) catch return;
    const now_ms = Io.Timestamp.now(io, .real).toMilliseconds();
    const age_ns = @as(u64, @intCast(@max(0, now_ms - st.mtime.toMilliseconds()))) * std.time.ns_per_ms;
    if (age_ns < store.config.touch_interval_ns) return;
    f.setTimestampsNow(io) catch {};
}

/// Store-relative object path: "objects/<hex[0..2]>/<hex[2..]>".
fn objectFull(d: digest_mod.Digest, buf: *[75]u8) []const u8 {
    var rbuf: [67]u8 = undefined;
    const rel = d.relPath(&rbuf);
    @memcpy(buf[0..8], "objects/");
    @memcpy(buf[8..], rel);
    return buf[0..75];
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
    var pre_buf: [75]u8 = undefined;
    const pre_mtime = (try ts.store.dir.statFile(io, objectFull(d, &pre_buf), .{})).mtime.toMilliseconds();
    ts.store.touch(io, d); // within 1h of ingest: no change
    var post_buf: [75]u8 = undefined;
    const post_mtime = (try ts.store.dir.statFile(io, objectFull(d, &post_buf), .{})).mtime.toMilliseconds();
    try std.testing.expectEqual(pre_mtime, post_mtime);

    // Backdate the object beyond the throttle, then touch must refresh it.
    var buf: [75]u8 = undefined;
    const f = try ts.store.dir.openFile(io, objectFull(d, &buf), .{});
    defer f.close(io);
    const old = std.Io.Timestamp.fromNanoseconds(1_000_000_000);
    try f.setTimestamps(io, .{ .modify_timestamp = .{ .new = old } });

    ts.store.touch(io, d);
    const st = try ts.store.dir.statFile(io, objectFull(d, &buf), .{});
    try std.testing.expect(st.mtime.toMilliseconds() > 60_000);
}
