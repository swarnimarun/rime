const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;

pub const DiskUsage = struct { free_bytes: u64, fs_size: u64 };

pub const DiskUsageError = error{StatFsFailed} || Io.Dir.RealPathFileError;

const DarwinStatFsHead = extern struct {
    f_bsize: u32,
    f_iosize: i32,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
};

const LinuxStatFsHead = extern struct {
    f_type: i64,
    f_bsize: i64,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
};

extern "c" fn statfs(path: [*:0]const u8, buf: *anyopaque) c_int;

pub fn readDiskUsage(io: Io, dir: Io.Dir) DiskUsageError!DiskUsage {
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const len = try dir.realPathFile(io, ".", &path_buf);
    var path_z: [Io.Dir.max_path_bytes + 1]u8 = undefined;
    @memcpy(path_z[0..len], path_buf[0..len]);
    path_z[len] = 0;

    var raw: [4096]u8 align(8) = undefined;
    if (statfs(path_z[0..len :0], &raw) != 0) return error.StatFsFailed;

    return switch (builtin.os.tag) {
        .macos => blk: {
            const s: *const DarwinStatFsHead = @ptrCast(@alignCast(&raw));
            break :blk .{
                .free_bytes = s.f_bfree * s.f_bsize,
                .fs_size = s.f_blocks * s.f_bsize,
            };
        },
        .linux => blk: {
            const s: *const LinuxStatFsHead = @ptrCast(@alignCast(&raw));
            const bsize: u64 = @intCast(s.f_bsize);
            break :blk .{
                .free_bytes = s.f_bfree * bsize,
                .fs_size = s.f_blocks * bsize,
            };
        },
        else => @compileError("rime supports macOS and Linux only"),
    };
}
