const std = @import("std");
const digest = @import("digest.zig");

pub const Digest = digest.Digest;
pub const hashBytes = digest.hashBytes;
pub const hashFile = digest.hashFile;

test {
    _ = @import("digest.zig");
}
