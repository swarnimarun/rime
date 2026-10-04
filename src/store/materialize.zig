const std = @import("std");
const root = @import("root.zig");
const clone_mod = @import("clone.zig");
const digest_mod = @import("digest.zig");
const test_support = @import("test_support.zig");

const Io = std.Io;

pub const MaterializeMethod = enum { cloned, copied };
pub const Strategy = enum { clone_first, copy_only };

pub const MaterializeError = error{
    ObjectNotFound,
    Unexpected,
    OutOfMemory,
} || Io.Cancelable || Io.File.OpenError || Io.Dir.OpenError ||
    Io.File.Writer.Error || Io.Dir.RenameError || Io.Dir.RealPathFileError ||
    Io.Dir.CreateDirPathError || Io.File.SetPermissionsError || Io.File.SyncError ||
    Io.File.ReadPositionalError;

/// Materializes an object at `dest_path`. Relative paths resolve under the
/// store directory (creating parent dirs); absolute paths are used as-is.
/// The destination is written via temp + rename for atomicity, clone-or-copy;
/// never hardlink (spec §7.1).
pub fn materialize(
    store: *root.Store,
    io: Io,
    digest: root.Digest,
    dest_path: []const u8,
    mode: u32,
    strategy: Strategy,
) MaterializeError!MaterializeMethod {
    if (std.fs.path.isAbsolute(dest_path)) {
        const parent = std.fs.path.dirname(dest_path) orelse return error.Unexpected;
        const base = std.fs.path.basename(dest_path);
        const dest_dir = Io.Dir.cwd().openDir(io, parent, .{}) catch return error.Unexpected;
        defer dest_dir.close(io);
        return materializeInto(store, io, digest, dest_dir, base, mode, strategy);
    }
    if (std.mem.lastIndexOfScalar(u8, dest_path, '/')) |sep| {
        store.dir.createDirPath(io, dest_path[0..sep]) catch return error.Unexpected;
    }
    return materializeInto(store, io, digest, store.dir, dest_path, mode, strategy);
}

fn materializeInto(
    store: *root.Store,
    io: Io,
    digest: root.Digest,
    dest_dir: Io.Dir,
    dest_rel: []const u8,
    mode: u32,
    strategy: Strategy,
) MaterializeError!MaterializeMethod {
    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    const rand_hex = std.fmt.bytesToHex(rnd, .lower);
    var tmp_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_rel = std.fmt.bufPrint(&tmp_buf, "{s}.rime-tmp-{s}", .{ dest_rel, rand_hex }) catch return error.Unexpected;

    // Absolute z-paths for the clone shim.
    var parent_abs_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const parent_abs_len = dest_dir.realPathFile(io, ".", &parent_abs_buf) catch return error.Unexpected;
    var store_abs_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const store_abs_len = store.dir.realPathFile(io, ".", &store_abs_buf) catch return error.Unexpected;

    var obj_rel_buf: [75]u8 = undefined;
    const obj_rel = objectFull(digest, &obj_rel_buf);

    var src_path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const src_path = std.fmt.bufPrint(&src_path_buf, "{s}/{s}", .{ store_abs_buf[0..store_abs_len], obj_rel }) catch return error.Unexpected;
    var tmp_path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_path_buf, "{s}/{s}", .{ parent_abs_buf[0..parent_abs_len], tmp_rel }) catch return error.Unexpected;
    var src_z_buf: [Io.Dir.max_path_bytes + 1]u8 = undefined;
    @memcpy(src_z_buf[0..src_path.len], src_path);
    src_z_buf[src_path.len] = 0;
    var tmp_z_buf: [Io.Dir.max_path_bytes + 1]u8 = undefined;
    @memcpy(tmp_z_buf[0..tmp_path.len], tmp_path);
    tmp_z_buf[tmp_path.len] = 0;

    const method: MaterializeMethod = switch (strategy) {
        .copy_only => try copyToTmp(store, io, digest, dest_dir, tmp_rel),
        .clone_first => blk: {
            clone_mod.clone(src_z_buf[0..src_path.len :0], tmp_z_buf[0..tmp_path.len :0]) catch
                break :blk try copyToTmp(store, io, digest, dest_dir, tmp_rel);
            break :blk .cloned;
        },
    };

    // Set final mode on the temp file, then atomically publish.
    const tmp_file = dest_dir.openFile(io, tmp_rel, .{}) catch return error.Unexpected;
    defer tmp_file.close(io);
    tmp_file.setPermissions(io, .fromMode(@intCast(mode))) catch return error.Unexpected;
    dest_dir.rename(tmp_rel, dest_dir, dest_rel, io) catch return error.Unexpected;
    return method;
}

fn copyToTmp(
    store: *root.Store,
    io: Io,
    digest: root.Digest,
    dest_dir: Io.Dir,
    tmp_rel: []const u8,
) MaterializeError!MaterializeMethod {
    var obj_buf: [75]u8 = undefined;
    const src = store.dir.openFile(io, objectFull(digest, &obj_buf), .{}) catch |err| switch (err) {
        error.FileNotFound => return error.ObjectNotFound,
        else => return error.Unexpected,
    };
    defer src.close(io);
    const dst = dest_dir.createFile(io, tmp_rel, .{ .exclusive = true }) catch return error.Unexpected;
    defer dst.close(io);

    var buf: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = src.readPositionalAll(io, &buf, offset) catch return error.Unexpected;
        if (n == 0) break;
        dst.writeStreamingAll(io, buf[0..n]) catch return error.Unexpected;
        offset += n;
    }
    dst.sync(io) catch return error.Unexpected;
    return .copied;
}

/// Store-relative object path: "objects/<hex[0..2]>/<hex[2..]>".
fn objectFull(d: digest_mod.Digest, buf: *[75]u8) []const u8 {
    var rbuf: [67]u8 = undefined;
    const rel = d.relPath(&rbuf);
    @memcpy(buf[0..8], "objects/");
    @memcpy(buf[8..], rel);
    return buf[0..75];
}

test "copy_only strategy writes identical bytes atomically" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);

    const d = try ts.store.putBytes(io, "materialize me", .bin);
    const got = try materialize(&ts.store, io, d, "out/app", 0o755, .copy_only);
    try std.testing.expectEqual(MaterializeMethod.copied, got);

    const bytes = try ts.store.dir.readFileAlloc(io, "out/app", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("materialize me", bytes);
}

test "mutating the destination never mutates the object" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);

    const d = try ts.store.putBytes(io, "original", .other);
    _ = try materialize(&ts.store, io, d, "out/copy", 0o644, .copy_only);

    try ts.store.dir.writeFile(io, .{ .sub_path = "out/copy", .data = "tampered" });
    try ts.store.verifyObject(io, d); // object must still verify

    const got = try ts.store.readObject(io, d, std.testing.allocator);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("original", got);
}

test "clone_first falls back cleanly" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);

    const d = try ts.store.putBytes(io, "clone or copy", .other);
    const got = try materialize(&ts.store, io, d, "out/either", 0o644, .clone_first);
    try std.testing.expect(got == .cloned or got == .copied);
}
