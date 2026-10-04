const std = @import("std");
const root = @import("root.zig");
const digest_mod = @import("digest.zig");
const test_support = @import("test_support.zig");
const index_mod = @import("index.zig");

const Io = std.Io;
const flate = std.compress.flate;

pub const ColdError = error{
    ObjectNotFound,
    DigestMismatch,
    InvalidGzip,
    StoreFull,
    UnknownTagKey,
    TagMismatch,
    TagLimit,
    Unexpected,
    OutOfMemory,
} || Io.Cancelable || Io.Dir.ReadFileAllocError || Io.Dir.WriteFileError || Io.Dir.OpenError || Io.Dir.CreateDirPathError || Io.Dir.DeleteFileError || Io.File.SetPermissionsError || index_mod.DbError || @import("disk_usage.zig").DiskUsageError || @import("state.zig").StateError;

/// gzip-compress in memory (level 6, `flate.Compress.Options.default`).
pub fn gzipAlloc(gpa: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, 4096);
    defer out.deinit();
    var window: [flate.max_window_len]u8 = undefined;
    var c = flate.Compress.init(&out.writer, &window, .gzip, flate.Compress.Options.default) catch return error.OutOfMemory;
    c.writer.writeAll(bytes) catch return error.OutOfMemory;
    c.finish() catch return error.OutOfMemory;
    return try out.toOwnedSlice();
}

pub fn gunzipAlloc(gpa: std.mem.Allocator, bytes: []const u8) error{OutOfMemory, InvalidGzip}![]u8 {
    var input = Io.Reader.fixed(bytes);
    var window: [flate.max_window_len]u8 = undefined;
    var d = flate.Decompress.init(&input, .gzip, &window);
    return d.reader.allocRemaining(gpa, .unlimited) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidGzip,
    };
}

/// Hot -> cold. Round-trip verified before the hot copy is deleted (spec §9.4).
/// No-op when the object is already cold-only (missing hot copy reports
/// ObjectNotFound) or when its kind is not demotable (bins stay hot).
pub fn demote(store: *root.Store, io: Io, digest: digest_mod.Digest) ColdError!void {
    // Cheap gate first: executable-ish kinds never leave hot (spec §9.4).
    if (!isDemotable(kindOf(store, io, digest))) return;

    var hot_buf: [73]u8 = undefined;
    const hot_full = objectFull(digest, &hot_buf);
    const hot_bytes = store.dir.readFileAlloc(io, hot_full, std.heap.page_allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return error.ObjectNotFound,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Unexpected,
    };
    defer std.heap.page_allocator.free(hot_bytes);

    const z = try gzipAlloc(std.heap.page_allocator, hot_bytes);
    defer std.heap.page_allocator.free(z);

    const back = try gunzipAlloc(std.heap.page_allocator, z);
    defer std.heap.page_allocator.free(back);
    if (!std.mem.eql(u8, back, hot_bytes)) return error.DigestMismatch;

    // §10.1 demote staging reserves cold (estimated gzip bytes) before the
    // copy is published, evicting cold LRU first when full. The reservation
    // is committed once the hot copy is deleted (ledger → file atom swap)
    // and aborted on any failure, so I-TOTAL holds through the staging
    // window where both copies exist. Via Store.reserve so the full
    // admit pipeline (evict → StoreFull with breakdown in lastFull) runs.
    const staging = try store.reserve(io, .cold, @as(u64, @intCast(z.len)), null, null);
    errdefer store.abort(io, staging);

    var cold_buf: [70]u8 = undefined;
    const cold_full = coldFull(digest, &cold_buf);
    try store.dir.createDirPath(io, cold_full[0..7]);
    try store.dir.writeFile(io, .{ .sub_path = cold_full, .data = z });
    // Tier copies are immutable store objects: publish read-only (0o444),
    // matching ingest (spec §11).
    {
        const cf = try store.dir.openFile(io, cold_full, .{});
        defer cf.close(io);
        try cf.setPermissions(io, .fromMode(0o444));
    }
    // Index mirror (Plan B Task 6): tier column follows the bytes, counting
    // the compressed size. Best-effort — bytes are authoritative.
    {
        const hex = digest.toHex();
        index_mod.setTier(&store.index, &hex, .cold, @intCast(z.len)) catch {};
    }

    store.dir.deleteFile(io, hot_full) catch {};
    store.commit(io, staging, digest);
}

/// Cold -> hot (used by materialize when a cold object must be executed).
/// The decompressed bytes are digest-checked before the cold copy is
/// deleted, mirroring demote's verify-before-delete.
pub fn promote(store: *root.Store, io: Io, digest: digest_mod.Digest) ColdError!void {
    var cold_buf: [70]u8 = undefined;
    const cold_full = coldFull(digest, &cold_buf);
    const z = store.dir.readFileAlloc(io, cold_full, std.heap.page_allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return error.ObjectNotFound,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Unexpected,
    };
    defer std.heap.page_allocator.free(z);

    const bytes = try gunzipAlloc(std.heap.page_allocator, z);
    defer std.heap.page_allocator.free(bytes);
    if (!std.meta.eql(digest_mod.hashBytes(bytes).bytes, digest.bytes)) return error.DigestMismatch;

    var hot_buf: [73]u8 = undefined;
    const hot_full = objectFull(digest, &hot_buf);
    try store.dir.createDirPath(io, hot_full[0..10]);
    try store.dir.writeFile(io, .{ .sub_path = hot_full, .data = bytes });
    // Restored hot copies are immutable store objects: read-only (0o444),
    // matching ingest (spec §11).
    {
        const hf = try store.dir.openFile(io, hot_full, .{});
        defer hf.close(io);
        try hf.setPermissions(io, .fromMode(0o444));
    }
    // Index mirror: back to hot, no compressed copy. Best-effort.
    {
        const hex = digest.toHex();
        index_mod.setTier(&store.index, &hex, .hot, null) catch {};
    }
    store.dir.deleteFile(io, cold_full) catch {};
}

/// Spec §9.4: executable-ish kinds stay hot. Incremental sessions demote
/// like any other object (M4 Task 9: `kind=incremental` is a bounded
/// global class under the soft tag budget, never pinned hot).
pub fn isDemotable(kind: root.Kind) bool {
    return switch (kind) {
        .bin, .dylib => false,
        .incremental => true,
        else => true,
    };
}

/// Best-effort kind lookup from the index row (Plan B Task 12: the v1
/// `kinds.jsonl` journal is retired — kind lives only in `objects.kind`).
/// Unknown digests default to `.other` (demotable). Never fails: on any
/// index or parse problem the caller gets the permissive default.
fn kindOf(store: *root.Store, io: Io, digest: digest_mod.Digest) root.Kind {
    _ = io;
    const hex = digest.toHex();
    const row = index_mod.getObject(&store.index, std.heap.page_allocator, &hex) catch return .other;
    const r = row orelse return .other;
    defer std.heap.page_allocator.free(r.kind);
    return std.meta.stringToEnum(root.Kind, r.kind) orelse .other;
}

/// Store-relative tier paths: "objects/ab/<hex>" / "cold/ab/<hex>" (spec §6).
fn objectFull(d: digest_mod.Digest, buf: *[73]u8) []const u8 {
    var rbuf: [65]u8 = undefined;
    const rel = d.relPath(&rbuf);
    @memcpy(buf[0..8], "objects/");
    @memcpy(buf[8..], rel);
    return buf[0..73];
}

fn coldFull(d: digest_mod.Digest, buf: *[70]u8) []const u8 {
    var rbuf: [65]u8 = undefined;
    const rel = d.relPath(&rbuf);
    @memcpy(buf[0..5], "cold/");
    @memcpy(buf[5..70], rel);
    return buf[0..70];
}

test "gzip round trip" {
    const gpa = std.testing.allocator;
    const payload = "hello rime hello rime hello rime";
    const z = try gzipAlloc(gpa, payload);
    defer gpa.free(z);
    const back = try gunzipAlloc(gpa, z);
    defer gpa.free(back);
    try std.testing.expectEqualStrings(payload, back);
}

test "demote and promote preserve object bytes" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);

    const d = try ts.store.putBytes(io, "cold-storage payload", .rlib);
    try ts.store.demote(io, d);
    try std.testing.expect(!ts.store.dirHasHot(io, d));
    try ts.store.verifyObject(io, d); // transparent read through cold tier

    const got = try ts.store.readObject(io, d, gpa);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("cold-storage payload", got);

    try ts.store.promote(io, d);
    try ts.store.verifyObject(io, d);
}

test "bins are never demoted" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);

    const d = try ts.store.putBytes(io, "executable", .bin);
    try ts.store.demote(io, d);
    try std.testing.expect(ts.store.dirHasHot(io, d));
}

test "demote fails StoreFull when cold has no room" {
    // §10.1 staging reserves cold: a 1 B cold cap cannot stage any gzip
    // copy, so demote admits nothing and the hot copy stays put.
    const io = std.Io.Threaded.global_single_threaded.io();
    var ts = test_support.openTestStore(io, .{
        .budget = .{ .fixed = 10_000_000 },
        .cold_cap = .{ .fixed = 1 },
    });
    defer ts.deinit(io);

    const d = try ts.store.putBytes(io, "no room to demote", .rlib);
    try std.testing.expectError(error.StoreFull, ts.store.demote(io, d));
    try std.testing.expect(ts.store.dirHasHot(io, d));
}

test "tier copies are read-only" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);

    const d = try ts.store.putBytes(io, "perm payload", .rlib);
    try ts.store.demote(io, d);
    var cbuf: [70]u8 = undefined;
    const cst = try ts.store.dir.statFile(io, coldFull(d, &cbuf), .{});
    try std.testing.expect(cst.permissions.toMode() & 0o777 == 0o444);

    try ts.store.promote(io, d);
    var hbuf: [73]u8 = undefined;
    const hst = try ts.store.dir.statFile(io, objectFull(d, &hbuf), .{});
    try std.testing.expect(hst.permissions.toMode() & 0o777 == 0o444);
}
