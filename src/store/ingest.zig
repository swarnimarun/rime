const std = @import("std");
const root = @import("root.zig");
const layout = @import("layout.zig");
const digest_mod = @import("digest.zig");
const test_support = @import("test_support.zig");

const Io = std.Io;
const Digest = digest_mod.Digest;

pub const PutError = error{
    DigestMismatch,
    Unexpected,
    OutOfMemory,
} || Io.Dir.StatFileError || Io.File.OpenError || Io.File.Writer.Error || Io.File.SyncError || Io.File.SetPermissionsError || Io.Dir.RenameError || Io.Dir.CreateDirPathError || Io.File.LengthError || Io.File.WritePositionalError || digest_mod.HashFileError;

const object_mode: Io.File.Permissions = .fromMode(0o444);
const store_gpa = std.heap.page_allocator;

/// Publishes `bytes` as an immutable object. Idempotent: if the object
/// already exists the temp file is discarded. Spec §8.1.
pub fn putBytes(store: *root.Store, io: Io, bytes: []const u8, kind: root.Kind) PutError!Digest {
    const d = digest_mod.hashBytes(bytes);

    var path_buf: [75]u8 = undefined;
    const full = objectFull(d, &path_buf);

    // Fast path: already present.
    if (store.dir.statFile(io, full, .{})) |_| {
        return d;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return error.Unexpected,
    }

    const tmp_name = try newTmpName(io);
    const tmp = try store.dir.createFile(io, tmp_name, .{ .exclusive = true });
    defer tmp.close(io);
    try tmp.writeStreamingAll(io, bytes);
    try tmp.sync(io);
    try tmp.setPermissions(io, object_mode);
    try publish(store, io, tmp_name, full);
    try recordKind(store, io, d, kind);
    return d;
}

/// Streams `src` to a temp file while hashing, then publishes under the hash.
/// `src` is read positionally, so its seek position is irrelevant.
pub fn putFile(store: *root.Store, io: Io, src: Io.File, kind: root.Kind) PutError!Digest {
    var h = std.crypto.hash.Blake3.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;

    const tmp_name = try newTmpName(io);
    const tmp = try store.dir.createFile(io, tmp_name, .{ .read = true, .exclusive = true });
    defer tmp.close(io);

    while (true) {
        const n = try src.readPositionalAll(io, &buf, offset);
        if (n == 0) break;
        h.update(buf[0..n]);
        try tmp.writeStreamingAll(io, buf[0..n]);
        offset += n;
    }
    try tmp.sync(io);
    try tmp.setPermissions(io, object_mode);

    var out: [32]u8 = undefined;
    h.final(&out);
    const d: Digest = .{ .bytes = out };

    var path_buf: [75]u8 = undefined;
    const full = objectFull(d, &path_buf);
    try publish(store, io, tmp_name, full);
    try recordKind(store, io, d, kind);
    return d;
}

fn newTmpName(io: Io) PutError![]const u8 {
    var rnd: [12]u8 = undefined;
    io.random(&rnd);
    const hex = std.fmt.bytesToHex(rnd, .lower);
    return std.fmt.allocPrint(store_gpa, layout.tmp_dir ++ "/{s}", .{hex[0..]}) catch error.OutOfMemory;
}

fn publish(store: *root.Store, io: Io, tmp_name: []const u8, full: []const u8) PutError!void {
    // Ensure the fanout dir exists (spec §6 layout).
    try store.dir.createDirPath(io, full[0..10]);
    store.dir.rename(tmp_name, store.dir, full, io) catch |err| switch (err) {
        error.FileNotFound => {}, // lost the race to an identical object; tmp is gone
        else => return error.Unexpected,
    };
}

fn recordKind(store: *root.Store, io: Io, d: Digest, kind: root.Kind) PutError!void {
    // Append-only journal; readers skip malformed lines (spec §5.2).
    const hex = d.toHex();
    var line_buf: [128]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "{{\"digest\":\"{s}\",\"kind\":\"{s}\"}}\n", .{ hex[0..], @tagName(kind) }) catch return error.Unexpected;
    const path = layout.state_dir ++ "/kinds.jsonl";
    const f = try store.dir.createFile(io, path, .{ .read = true, .truncate = false });
    defer f.close(io);
    const len = try f.length(io);
    try f.writePositionalAll(io, line, len);
}

/// Store-relative object path: "objects/<hex[0..2]>/<hex[2..]>"
/// (spec §5.1, §6). layout.objectPath returns the fanout-relative part.
fn objectFull(d: digest_mod.Digest, buf: *[75]u8) []const u8 {
    var rbuf: [67]u8 = undefined;
    const rel = d.relPath(&rbuf);
    @memcpy(buf[0..8], "objects/");
    @memcpy(buf[8..], rel);
    return buf[0..75];
}

test "putBytes is idempotent and read-only" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);

    const d1 = try ts.store.putBytes(io, "artifact bytes", .other);
    const d2 = try ts.store.putBytes(io, "artifact bytes", .other);
    try std.testing.expectEqual(d1.bytes, d2.bytes);

    var buf: [75]u8 = undefined;
    const st = try ts.store.dir.statFile(io, objectFull(d1, &buf), .{});
    try std.testing.expect(st.size == "artifact bytes".len);
    try std.testing.expect(st.permissions.toMode() & 0o777 == 0o444);
}

test "putFile hashes the whole file and dedups" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);

    const src = try ts.store.dir.createFile(io, "src.bin", .{ .read = true });
    defer {
        src.close(io);
        ts.store.dir.deleteFile(io, "src.bin") catch {};
    }
    try src.writeStreamingAll(io, "same bytes");

    const d1 = try ts.store.putFile(io, src, .rlib);
    const d2 = try ts.store.putBytes(io, "same bytes", .rlib);
    try std.testing.expectEqual(d1.bytes, d2.bytes);
}

test "crash window: tmp files are never objects" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);

    try ts.store.dir.writeFile(io, .{ .sub_path = "tmp/leftover", .data = "partial" });
    const d = try ts.store.putBytes(io, "whole", .other);
    // The leftover tmp file is untouched and the published object exists.
    const leftover = try ts.store.dir.readFileAlloc(io, "tmp/leftover", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(leftover);
    try std.testing.expectEqualStrings("partial", leftover);
    var buf: [75]u8 = undefined;
    _ = try ts.store.dir.statFile(io, objectFull(d, &buf), .{});
}
