const std = @import("std");
const digest_mod = @import("digest.zig");
const Digest = digest_mod.Digest;

pub const objects_dir = "objects";
pub const cold_dir = "cold";
pub const actions_dir = "actions";
pub const tmp_dir = "tmp";
pub const state_dir = "state";
pub const format_file = "format.json";
pub const lock_file = "format-lock";
pub const format_version: u32 = 1;

pub const FormatJson = struct { format: u32 };

pub fn objectPath(d: Digest, buf: *[65]u8) []const u8 {
    return d.relPath(buf);
}

pub fn coldPath(d: Digest, buf: *[65]u8) []const u8 {
    return d.relPath(buf);
}

pub fn actionPath(key: Digest, buf: *[65]u8) []const u8 {
    return key.relPath(buf);
}

test "object and action paths fan out identically" {
    const d = digest_mod.hashBytes("layout");
    var b1: [65]u8 = undefined;
    var b2: [65]u8 = undefined;
    try std.testing.expectEqualStrings(objectPath(d, &b1), actionPath(d, &b2));
}
