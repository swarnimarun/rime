const std = @import("std");
const root = @import("root.zig");
const layout = @import("layout.zig");
const digest_mod = @import("digest.zig");
const cold = @import("cold.zig");
const test_support = @import("test_support.zig");

const Io = std.Io;
const Digest = digest_mod.Digest;

pub const ReadError = error{
    ObjectNotFound,
    Unexpected,
    OutOfMemory,
} || Io.Cancelable || Io.Dir.ReadFileAllocError;

pub const VerifyError = error{ ObjectNotFound, DigestMismatch, Unexpected } ||
    Io.Cancelable || Io.Dir.ReadFileAllocError;

/// Store-relative object path "objects/ab/cdef…" (spec §5.1, §6).
fn objectFull(digest: Digest, buf: *[75]u8) []const u8 {
    var rbuf: [67]u8 = undefined;
    const rel = digest.relPath(&rbuf);
    @memcpy(buf[0..8], "objects/");
    @memcpy(buf[8..], rel);
    return buf[0..75];
}

/// Store-relative cold path "cold/ab/cdef…" (spec §9.4).
fn coldFull(digest: Digest, buf: *[75]u8) []const u8 {
    var rbuf: [67]u8 = undefined;
    const rel = digest.relPath(&rbuf);
    @memcpy(buf[0..5], "cold/");
    @memcpy(buf[5..72], rel);
    return buf[0..72];
}

/// Cold-aware: an object exists when either tier holds it.
pub fn exists(store: *root.Store, io: Io, digest: Digest) bool {
    var hot_buf: [75]u8 = undefined;
    if (store.dir.statFile(io, objectFull(digest, &hot_buf), .{})) |_| {
        return true;
    } else |_| {}
    var cold_buf: [75]u8 = undefined;
    const cold_full = coldFull(digest, &cold_buf);
    _ = store.dir.statFile(io, cold_full, .{}) catch return false;
    return true;
}

/// Reads a whole object. Hot tier first; cold tier is gunzipped
/// transparently (spec §9.4). Use verifyObject for hashing.
pub fn readObject(store: *root.Store, io: Io, digest: Digest, gpa: std.mem.Allocator) ReadError![]u8 {
    var hot_buf: [75]u8 = undefined;
    if (store.dir.readFileAlloc(io, objectFull(digest, &hot_buf), gpa, .unlimited)) |bytes| {
        return bytes;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return error.Unexpected,
    }
    var cold_buf: [75]u8 = undefined;
    const cold_full = coldFull(digest, &cold_buf);
    const z = store.dir.readFileAlloc(io, cold_full, gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return error.ObjectNotFound,
        else => return error.Unexpected,
    };
    defer gpa.free(z);
    return cold.gunzipAlloc(gpa, z) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidGzip => return error.Unexpected,
    };
}

/// Full integrity check: re-hashes the stored bytes. Spec §5.2 invariant 2.
/// Tier-transparent: reads through `readObject`, so cold objects verify.
pub fn verifyObject(store: *root.Store, io: Io, digest: Digest) VerifyError!void {
    const bytes = readObject(store, io, digest, std.heap.page_allocator) catch |err| switch (err) {
        error.ObjectNotFound => return error.ObjectNotFound,
        error.OutOfMemory => return error.Unexpected,
        else => return error.Unexpected,
    };
    defer std.heap.page_allocator.free(bytes);
    const actual = digest_mod.hashBytes(bytes);
    if (!std.meta.eql(actual.bytes, digest.bytes)) return error.DigestMismatch;
}

test "exists and readObject round trip" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);

    const d = try ts.store.putBytes(io, "payload", .other);
    try std.testing.expect(ts.store.exists(io, d));
    const got = try ts.store.readObject(io, d, std.testing.allocator);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("payload", got);
}

test "verifyObject detects corruption" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);

    const d = try ts.store.putBytes(io, "payload", .other);
    try ts.store.verifyObject(io, d);

    // Simulate bit rot by writing directly into the object path. Objects
    // are 0444, so relax permissions first (a test-only chmod).
    var rel_buf: [67]u8 = undefined;
    const rel = d.relPath(&rel_buf);
    var full_buf: [75]u8 = undefined;
    @memcpy(full_buf[0..8], "objects/");
    @memcpy(full_buf[8..], rel);
    const f = try ts.store.dir.openFile(io, full_buf[0..75], .{});
    try f.setPermissions(io, .fromMode(0o644));
    f.close(io);
    try ts.store.dir.writeFile(io, .{ .sub_path = full_buf[0..75], .data = "corrupted!" });
    try std.testing.expectError(error.DigestMismatch, ts.store.verifyObject(io, d));
}
