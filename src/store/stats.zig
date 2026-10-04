const std = @import("std");
const root = @import("root.zig");
const index_mod = @import("index.zig");
const test_support = @import("test_support.zig");

const Io = std.Io;

/// One per-pair aggregate row (owned key/value; free with freeTagStats).
/// Re-exported from the index so the row shape has one home. Plan B Task 11.
pub const TagStat = index_mod.TagStat;

pub const StatsError = error{Unexpected, OutOfMemory} || Io.Cancelable || index_mod.DbError;

test "byTag aggregates bytes per pair" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);

    const a = try ts.store.putBytes(io, "12345", .rlib); // 5 B
    const b = try ts.store.putBytes(io, "123", .rlib); // 3 B
    try ts.store.tagObject(io, a, &.{ .{ .key = "crate", .value = "serde" }, .{ .key = "crate_version", .value = "1.0.200" } });
    try ts.store.tagObject(io, b, &.{ .{ .key = "crate", .value = "serde" }, .{ .key = "crate_version", .value = "1.0.200" } });
    try ts.store.tagObject(io, b, &.{.{ .key = "profile", .value = "release" }});

    const rows = try byTag(&ts.store, io, gpa);
    defer freeTagStats(gpa, rows);
    // (crate,serde)=8 B, (crate_version,1.0.200)=8 B, (profile,release)=3 B → 3 rows, 8 B first.
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expectEqual(@as(u64, 8), rows[0].bytes);
    try std.testing.expect(rows[0].bytes >= rows[1].bytes and rows[1].bytes >= rows[2].bytes);
}

/// One row per distinct tag pair, bytes DESC (index owns every sqlite3 call).
/// `stats.byTag` calls `index.tagStats` and maps rows — no `@cImport` here.
/// Caller frees via freeTagStats. Plan B Task 11.
pub fn byTag(store: *root.Store, io: Io, gpa: std.mem.Allocator) StatsError![]TagStat {
    _ = io;
    return try index_mod.tagStats(&store.index, gpa);
}

/// Single-pair lookup, implemented as a byTag scan (CLI scale; one indexed
/// GROUP BY either way). Misses come back as a zero row carrying duped
/// key/value so callers print uniform lines. Plan B Task 11.
pub fn tagStat(store: *root.Store, io: Io, gpa: std.mem.Allocator, key: []const u8, value: []const u8) StatsError!TagStat {
    const rows = try byTag(store, io, gpa);
    defer freeTagStats(gpa, rows);
    for (rows) |r| {
        if (std.mem.eql(u8, r.key, key) and std.mem.eql(u8, r.value, value)) {
            return .{
                .key = try gpa.dupe(u8, r.key),
                .value = try gpa.dupe(u8, r.value),
                .bytes = r.bytes,
                .objects = r.objects,
            };
        }
    }
    return .{
        .key = try gpa.dupe(u8, key),
        .value = try gpa.dupe(u8, value),
        .bytes = 0,
        .objects = 0,
    };
}

pub fn freeTagStats(gpa: std.mem.Allocator, rows: []TagStat) void {
    for (rows) |r| {
        gpa.free(r.key);
        gpa.free(r.value);
    }
    gpa.free(rows);
}
