const std = @import("std");
const digest = @import("digest.zig");

pub const Digest = digest.Digest;
pub const hashBytes = digest.hashBytes;
pub const hashFile = digest.hashFile;

pub const config = @import("config.zig");
pub const disk_usage = @import("disk_usage.zig");

test {
    _ = @import("digest.zig");
    _ = @import("config.zig");
    _ = @import("disk_usage.zig");
}
