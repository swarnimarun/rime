const std = @import("std");
const disk_usage = @import("disk_usage.zig");

pub const GiB: u64 = 1024 * 1024 * 1024;
const ns_per_day: u64 = 24 * std.time.ns_per_hour;

pub const Limit = union(enum) { auto, fixed: u64 };

pub const Config = struct {
    hot_limit: Limit = .auto,
    cold_limit: Limit = .auto,
    disk_reserve: Limit = .auto,
    cold_after_ns: u64 = 7 * ns_per_day,
    max_age_ns: u64 = 90 * ns_per_day,
    touch_interval_ns: u64 = std.time.ns_per_hour,
    incremental_limit: u64 = 4 * GiB,
    incremental_max_age_ns: u64 = 5 * ns_per_day,
    retain_last_build: bool = true,
};

pub const ResolvedLimits = struct { hot: u64, cold: u64, reserve: u64 };

test "parseSize accepts binary units" {
    try std.testing.expectEqual(@as(u64, 5 * GiB), try parseSize("5GiB"));
    try std.testing.expectEqual(@as(u64, 512 * 1024 * 1024), try parseSize("512MiB"));
    try std.testing.expectEqual(@as(u64, 4096), try parseSize("4096"));
}

test "parseDuration accepts day hour units" {
    try std.testing.expectEqual(@as(u64, 7 * ns_per_day), try parseDuration("7d"));
    try std.testing.expectEqual(@as(u64, 12 * std.time.ns_per_hour), try parseDuration("12h"));
}

test "auto limits clamp and derive" {
    const cfg = Config{};
    const limits = resolveLimits(cfg, .{ .free_bytes = 1000 * GiB, .fs_size = 2000 * GiB });
    // clamp(10% of 1000 GiB = 100 GiB, 5 GiB, 50 GiB) = 50 GiB
    try std.testing.expectEqual(@as(u64, 50 * GiB), limits.hot);
    try std.testing.expectEqual(@as(u64, 100 * GiB), limits.cold);
    // max(5 GiB, 5% of 2000 GiB = 100 GiB) = 100 GiB
    try std.testing.expectEqual(@as(u64, 100 * GiB), limits.reserve);
}

test "fixed limits win over auto" {
    const cfg = Config{ .hot_limit = .{ .fixed = 2 * GiB }, .cold_limit = .{ .fixed = 3 * GiB }, .disk_reserve = .{ .fixed = 1 * GiB } };
    const limits = resolveLimits(cfg, .{ .free_bytes = 10 * GiB, .fs_size = 10 * GiB });
    try std.testing.expectEqual(@as(u64, 2 * GiB), limits.hot);
    try std.testing.expectEqual(@as(u64, 3 * GiB), limits.cold);
    try std.testing.expectEqual(@as(u64, 1 * GiB), limits.reserve);
}

test "disk usage is sane on the real filesystem" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    const io = threaded.io();
    const usage = try disk_usage.readDiskUsage(io, std.Io.Dir.cwd());
    try std.testing.expect(usage.fs_size > 0);
    try std.testing.expect(usage.free_bytes <= usage.fs_size);
}

fn clamp(v: u64, lo: u64, hi: u64) u64 {
    return @max(lo, @min(hi, v));
}

/// "4096" | "512MiB" | "5GiB" (MiB/GiB binary units only).
pub fn parseSize(text: []const u8) error{InvalidSize}!u64 {
    const mib = 1024 * 1024;
    if (std.mem.endsWith(u8, text, "GiB")) {
        const n = std.fmt.parseInt(u64, text[0 .. text.len - 3], 10) catch return error.InvalidSize;
        return n * GiB;
    }
    if (std.mem.endsWith(u8, text, "MiB")) {
        const n = std.fmt.parseInt(u64, text[0 .. text.len - 3], 10) catch return error.InvalidSize;
        return n * mib;
    }
    return std.fmt.parseInt(u64, text, 10) catch error.InvalidSize;
}

/// "45s" | "30m" | "12h" | "7d".
pub fn parseDuration(text: []const u8) error{InvalidDuration}!u64 {
    if (text.len < 2) return error.InvalidDuration;
    const n = std.fmt.parseInt(u64, text[0 .. text.len - 1], 10) catch return error.InvalidDuration;
    return switch (text[text.len - 1]) {
        's' => n * std.time.ns_per_s,
        'm' => n * std.time.ns_per_min,
        'h' => n * std.time.ns_per_hour,
        'd' => n * ns_per_day,
        else => error.InvalidDuration,
    };
}

/// Spec §9.1 defaults: hot = clamp(10% free, 5 GiB, 50 GiB),
/// cold = 2 x hot, reserve = max(5 GiB, 5% of fs size).
pub fn resolveLimits(cfg: Config, usage: disk_usage.DiskUsage) ResolvedLimits {
    const hot = switch (cfg.hot_limit) {
        .fixed => |v| v,
        .auto => clamp(usage.free_bytes / 10, 5 * GiB, 50 * GiB),
    };
    const cold = switch (cfg.cold_limit) {
        .fixed => |v| v,
        .auto => 2 * hot,
    };
    const reserve = switch (cfg.disk_reserve) {
        .fixed => |v| v,
        .auto => @max(5 * GiB, usage.fs_size / 20),
    };
    return .{ .hot = hot, .cold = cold, .reserve = reserve };
}
