const std = @import("std");
const root = @import("root.zig");
const layout = @import("layout.zig");
const digest_mod = @import("digest.zig");
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

pub fn exists(store: *root.Store, io: Io, digest: Digest) bool {
    var path_buf: [75]u8 = undefined;
    _ = store.dir.statFile(io, objectFull(digest, &path_buf), .{}) catch return false;
    return true;
}

/// Reads a whole object. Verifies length only; use verifyObject for hashing.
pub fn readObject(store: *root.Store, io: Io, digest: Digest, gpa: std.mem.Allocator) ReadError![]u8 {
    var path_buf: [75]u8 = undefined;
    return store.dir.readFileAlloc(io, objectFull(digest, &path_buf), gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => error.ObjectNotFound,
        else => error.Unexpected,
    };
}

/// Full integrity check: re-hashes the stored bytes. Spec §5.2 invariant 2.
pub fn verifyObject(store: *root.Store, io: Io, digest: Digest) VerifyError!void {
    var path_buf: [75]u8 = undefined;
    const full = objectFull(digest, &path_buf);
    const f = store.dir.openFile(io, full, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.ObjectNotFound,
        else => return error.Unexpected,
    };
    defer f.close(io);
    const actual = digest_mod.hashFile(f, io) catch return error.Unexpected;
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
