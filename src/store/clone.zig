const std = @import("std");
const builtin = @import("builtin");

pub const CloneError = error{CloneFailed};

/// Best-effort copy-on-write clone. APFS clonefile on macOS, FICLONE on
/// Linux. Failure means "fall back to byte copy", never a hardlink
/// (spec §7.1). `dest_z` must not already exist.
pub fn clone(src_z: [*:0]const u8, dest_z: [*:0]const u8) CloneError!void {
    switch (builtin.os.tag) {
        .macos => {
            if (clonefile(src_z, dest_z, 0) != 0) return error.CloneFailed;
        },
        .linux => {
            const src_fd = cOpen(src_z, O_RDONLY, 0);
            if (src_fd < 0) return error.CloneFailed;
            defer _ = cClose(src_fd);
            const dest_fd = cOpen(dest_z, O_WRONLY | O_CREAT | O_EXCL, 0o600);
            if (dest_fd < 0) return error.CloneFailed;
            defer _ = cClose(dest_fd);
            if (cIoctl(dest_fd, FICLONE, src_fd) != 0) return error.CloneFailed;
        },
        else => @compileError("rime supports macOS and Linux only"),
    }
}

const O_RDONLY = 0;
const O_WRONLY = 1;
const O_CREAT = 0o100;
const O_EXCL = 0o200;
const FICLONE: c_ulong = 0x40049409;

extern "c" fn clonefile(old: [*:0]const u8, new: [*:0]const u8, flags: c_int) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;

fn cOpen(path: [*:0]const u8, flags: c_int, mode: c_int) c_int {
    return open(path, flags, mode);
}
fn cClose(fd: c_int) c_int {
    return close(fd);
}
fn cIoctl(fd: c_int, request: c_ulong, arg: c_int) c_int {
    return ioctl(fd, request, arg);
}
