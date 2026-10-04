const std = @import("std");
const root = @import("root.zig");
const scan = @import("scan.zig");
const state = @import("state.zig");
const objects = @import("objects.zig");
const manifest_mod = @import("manifest.zig");
const disk_usage = @import("disk_usage.zig");
const digest_mod = @import("digest.zig");

const Io = std.Io;

pub const GcPolicy = struct {
    dry_run: bool = false,
    target_bytes: ?u64 = null,
    older_than_ns: ?u64 = null,
};

pub const GcReport = struct {
    scanned_objects: u64 = 0,
    evicted_objects: u64 = 0,
    freed_bytes_hot: u64 = 0,
    freed_bytes_cold: u64 = 0,
    demoted_objects: u64 = 0,
    expired_leases: u64 = 0,
    stale_action_entries: u64 = 0,
    dry_run: bool = false,
};

pub const GcError = error{Unexpected, OutOfMemory} || Io.Cancelable ||
    scan.ScanError || state.StateError || disk_usage.DiskUsageError;

const LiveSet = std.AutoHashMap([32]u8, void);

/// Spec §9.7 reclaim order. Never deletes rooted objects. Never deletes
/// anything when policy.dry_run is set.
pub fn gc(store: *root.Store, io: Io, gpa: std.mem.Allocator, policy: GcPolicy) GcError!GcReport {
    var report = GcReport{ .dry_run = policy.dry_run };
    const now_ms = Io.Timestamp.now(io, .real).toMilliseconds();

    // -- Phase 0: roots (pins, live leases, project retains + manifests). --
    // liveLeases deletes expired lease files as a side effect (expiry).
    // Stale action entries are swept here once Task 11 wires sweepStale in.
    var live = LiveSet.init(gpa);
    defer live.deinit();

    const leases = try state.liveLeases(io, gpa, store.dir, now_ms);
    defer state.freeLeases(gpa, leases);
    for (leases) |lease| {
        for (lease.digest_hexes) |hex| {
            const d = digest_mod.Digest.fromHex(hex) catch continue;
            try live.put(d.bytes, {});
        }
    }

    const pins = try state.listPins(io, gpa, store.dir);
    defer state.freePins(gpa, pins);
    for (pins) |pin| {
        const d = digest_mod.Digest.fromHex(pin.digest_hex) catch continue;
        try live.put(d.bytes, {});
    }

    const retains = try state.listRetains(io, gpa, store.dir);
    defer state.freeRetains(gpa, retains);
    for (retains) |retain| {
        for (retain.manifest_hexes) |hex| {
            const md = digest_mod.Digest.fromHex(hex) catch continue;
            try live.put(md.bytes, {});
            if (store.readObject(io, md, gpa)) |bytes| {
                defer gpa.free(bytes);
                if (manifest_mod.decode(gpa, bytes)) |man| {
                    defer man.deinit(gpa);
                    for (man.outputs) |o| try live.put(o.digest.bytes, {});
                } else |_| {} // corrupt manifest: only the manifest itself is rooted
            } else |_| {}
        }
    }

    // -- Phase 1: inventory. --
    const infos = try scan.scan(store, io, gpa);
    defer gpa.free(infos);
    report.scanned_objects = infos.len;

    // Sort LRU-first (oldest mtime first).
    const sorted = try gpa.dupe(scan.ObjectInfo, infos);
    defer gpa.free(sorted);
    std.sort.heap(scan.ObjectInfo, sorted, {}, struct {
        fn lt(_: void, x: scan.ObjectInfo, y: scan.ObjectInfo) bool {
            return x.mtime_ms < y.mtime_ms;
        }
    }.lt);

    // -- Phase 2: age trim (policy.older_than_ns overrides max_age_ns). --
    const max_age_ns = policy.older_than_ns orelse store.config.max_age_ns;
    for (sorted) |obj| {
        if (live.contains(obj.digest.bytes)) continue;
        if (!isOlderThan(obj, now_ms, max_age_ns)) continue;
        try evict(store, io, &report, obj, policy.dry_run);
    }

    // -- Phase 3: quota sweep to 90% hysteresis (spec §9.1). --
    // Evict oldest unrooted hot objects first until hot usage is at target.
    const hot_target = policy.target_bytes orelse store.limits.hot * 90 / 100;
    var hot_used: u64 = 0;
    for (sorted) |obj| {
        if (obj.tier != .hot) continue;
        // In real runs age-trimmed objects are already gone; skip them so
        // they are not counted as still using quota. In dry runs they are
        // still on disk, so count them (report approximate by that overlap).
        if (!policy.dry_run and !live.contains(obj.digest.bytes) and isOlderThan(obj, now_ms, max_age_ns)) continue;
        hot_used += obj.size;
    }
    for (sorted) |obj| {
        if (hot_used <= hot_target) break;
        if (obj.tier != .hot) continue;
        if (live.contains(obj.digest.bytes)) continue;
        if (!policy.dry_run and isOlderThan(obj, now_ms, max_age_ns)) continue; // evicted in phase 2
        try evict(store, io, &report, obj, policy.dry_run);
        hot_used -= @min(hot_used, obj.size);
    }

    // -- Phase 4: emergency trim to restore disk_reserve. --
    const usage = try disk_usage.readDiskUsage(io, store.dir);
    if (usage.free_bytes < store.limits.reserve) {
        for (sorted) |obj| {
            if (live.contains(obj.digest.bytes)) continue;
            if (!policy.dry_run and isOlderThan(obj, now_ms, max_age_ns)) continue; // already gone
            // Objects evicted by an earlier phase report FileNotFound here;
            // evict tolerates the race and does not double-count.
            try evict(store, io, &report, obj, policy.dry_run);
            const after = try disk_usage.readDiskUsage(io, store.dir);
            if (after.free_bytes >= store.limits.reserve) break;
        }
    }

    return report;
}

fn isOlderThan(obj: scan.ObjectInfo, now_ms: i64, max_age_ns: u64) bool {
    const age_ns = @as(u64, @intCast(@max(0, now_ms - obj.mtime_ms))) * std.time.ns_per_ms;
    return age_ns > max_age_ns;
}

/// Store-relative tier path: "objects/ab/<hex>" or "cold/ab/<hex>".
fn tierFullPath(digest: digest_mod.Digest, tier: scan.Tier, buf: *[75]u8) []const u8 {
    var rbuf: [67]u8 = undefined;
    const rel = digest.relPath(&rbuf);
    switch (tier) {
        .hot => {
            @memcpy(buf[0..8], "objects/");
            @memcpy(buf[8..75], rel);
            return buf[0..75];
        },
        .cold => {
            @memcpy(buf[0..5], "cold/");
            @memcpy(buf[5..72], rel);
            return buf[0..72];
        },
    }
}

fn evict(store: *root.Store, io: Io, report: *GcReport, obj: scan.ObjectInfo, dry_run: bool) GcError!void {
    if (dry_run) {
        report.evicted_objects += 1;
        switch (obj.tier) {
            .hot => report.freed_bytes_hot += obj.size,
            .cold => report.freed_bytes_cold += obj.size,
        }
        return;
    }
    var buf: [75]u8 = undefined;
    const full = tierFullPath(obj.digest, obj.tier, &buf);
    store.dir.deleteFile(io, full) catch |err| switch (err) {
        error.FileNotFound => return, // raced with another GC or the owner
        else => return error.Unexpected,
    };
    report.evicted_objects += 1;
    switch (obj.tier) {
        .hot => report.freed_bytes_hot += obj.size,
        .cold => report.freed_bytes_cold += obj.size,
    }
}

const test_support = @import("test_support.zig");

fn fixedConfig(hot: u64) root.config.Config {
    return .{
        .hot_limit = .{ .fixed = hot },
        .cold_limit = .{ .fixed = 100 * root.config.GiB },
        .disk_reserve = .{ .fixed = 0 },
    };
}

/// Store-relative object path "objects/ab/<hex>" (spec §5.1, §6).
fn objectFull(d: root.Digest, buf: *[75]u8) []const u8 {
    var rbuf: [67]u8 = undefined;
    const rel = d.relPath(&rbuf);
    @memcpy(buf[0..8], "objects/");
    @memcpy(buf[8..], rel);
    return buf[0..75];
}

fn setMtime(io: std.Io, store: *root.Store, d: root.Digest, ms: i64) !void {
    var buf: [75]u8 = undefined;
    const f = try store.dir.openFile(io, objectFull(d, &buf), .{});
    defer f.close(io);
    try f.setTimestamps(io, .{ .modify_timestamp = .{ .new = .fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms) } });
}

test "quota sweep evicts oldest unrooted first and stops at 90 percent" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var ts = test_support.openTestStore(io, fixedConfig(10));
    defer ts.deinit(io);
    // limits.resolveLimits is not re-run by open with .fixed values:
    ts.store.limits = .{ .hot = 10, .cold = 100 * root.config.GiB, .reserve = 0 };
    // Disable age trim for this test: the backdated mtimes below are only
    // meant to fix LRU order, and 1970 timestamps would otherwise age-trim.
    ts.store.config.max_age_ns = std.math.maxInt(u64);

    const a = try ts.store.putBytes(io, "aaaa", .other); // 4 B
    const b = try ts.store.putBytes(io, "bbbb", .other); // 4 B
    const c = try ts.store.putBytes(io, "cccc", .other); // 4 B
    try ts.store.pin(io, "keep-b", b);

    // Make `a` the LRU by backdating its mtime.
    try setMtime(io, &ts.store, a, 1_000);
    try setMtime(io, &ts.store, b, 2_000);
    try setMtime(io, &ts.store, c, 3_000);

    const report = try ts.store.gc(io, gpa, .{});
    try std.testing.expect(report.evicted_objects >= 1);
    try std.testing.expect(!ts.store.exists(io, a)); // oldest unrooted gone
    try std.testing.expect(ts.store.exists(io, b)); // pinned survives
    try std.testing.expect(ts.store.exists(io, c)); // newer unrooted kept
}

test "dry run deletes nothing" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);
    ts.store.limits = .{ .hot = 1, .cold = 1, .reserve = 0 };

    const a = try ts.store.putBytes(io, "doomed", .other);
    const report = try ts.store.gc(io, gpa, .{ .dry_run = true });
    try std.testing.expect(report.dry_run);
    try std.testing.expect(report.evicted_objects >= 1);
    try std.testing.expect(ts.store.exists(io, a)); // nothing actually deleted
}

test "age trim removes unrooted objects older than max_age" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);
    ts.store.limits = .{ .hot = 100 * root.config.GiB, .cold = 100 * root.config.GiB, .reserve = 0 };
    ts.store.config.max_age_ns = std.time.ns_per_hour;

    const a = try ts.store.putBytes(io, "old", .other);
    try setMtime(io, &ts.store, a, 1_000); // far older than 1h
    const report = try ts.store.gc(io, gpa, .{});
    try std.testing.expect(report.evicted_objects >= 1);
    try std.testing.expect(!ts.store.exists(io, a));
}
