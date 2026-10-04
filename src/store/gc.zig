const std = @import("std");
const root = @import("root.zig");
const scan = @import("scan.zig");
const state = @import("state.zig");
const objects = @import("objects.zig");
const action_cache = @import("action_cache.zig");
const cold = @import("cold.zig");
const layout = @import("layout.zig");
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
    freed_bytes_incremental: u64 = 0,
    demoted_objects: u64 = 0,
    expired_leases: u64 = 0,
    stale_action_entries: u64 = 0,
    dry_run: bool = false,
};

pub const GcError = error{Unexpected, OutOfMemory} || Io.Cancelable ||
    Io.Dir.Iterator.Error || scan.ScanError || state.StateError ||
    action_cache.SweepError || disk_usage.DiskUsageError;

const LiveSet = std.AutoHashMap([32]u8, void);

/// Spec §9.7 reclaim order. Never deletes rooted objects. Never deletes
/// anything when policy.dry_run is set.
pub fn gc(store: *root.Store, io: Io, gpa: std.mem.Allocator, policy: GcPolicy) GcError!GcReport {
    var report = GcReport{ .dry_run = policy.dry_run };
    const now_ms = Io.Timestamp.now(io, .real).toMilliseconds();

    // -- Phase 0: roots (pins, live leases, project retains + manifests). --
    // liveLeases deletes expired lease files as a side effect (expiry), so
    // dry runs peek without deleting. Count first: after liveLeases the
    // expired files are gone.
    report.expired_leases = try state.countExpiredLeases(io, gpa, store.dir, now_ms);
    var live = LiveSet.init(gpa);
    defer live.deinit();

    const leases = if (policy.dry_run)
        try state.peekLiveLeases(io, gpa, store.dir, now_ms)
    else
        try state.liveLeases(io, gpa, store.dir, now_ms);
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

    // -- Phase 1: inventory + stale action sweep. --
    // Dry runs count stale entries without deleting them.
    var present_cb = PresentCtx{ .store = store, .io = io };
    report.stale_action_entries = if (policy.dry_run)
        try action_cache.countStale(io, gpa, store.dir, PresentCtx.call, &present_cb)
    else
        try action_cache.sweepStale(io, gpa, store.dir, PresentCtx.call, &present_cb);

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

    // -- Phase 2b: incremental class sweep (spec §9.5). Project-local rustc
    // sessions live outside the shared object space
    // (`state/projects/<id>/incremental/`) with their own age/size bounds.
    report.freed_bytes_incremental = try sweepIncremental(store, io, gpa, policy.dry_run);

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
    // Cold-tier usage at compressed sizes (spec §9.4 counts demoted bytes
    // compressed). Same real-run age-trim adjustment as hot_used above.
    var cold_used: u64 = 0;
    for (sorted) |obj| {
        if (obj.tier != .cold) continue;
        if (!policy.dry_run and !live.contains(obj.digest.bytes) and isOlderThan(obj, now_ms, max_age_ns)) continue;
        cold_used += obj.size;
    }
    const cold_target = store.limits.cold * 90 / 100;
    for (sorted) |obj| {
        if (hot_used <= hot_target) break;
        if (obj.tier != .hot) continue;
        if (live.contains(obj.digest.bytes)) continue;
        if (!policy.dry_run and isOlderThan(obj, now_ms, max_age_ns)) continue; // evicted in phase 2
        // Demote before evicting: demotable hot objects move to cold while
        // the cold tier has headroom (spec §9.7 order, step 3 before 4).
        if (cold.isDemotable(obj.kind) and cold_used < cold_target) {
            if (!policy.dry_run) {
                cold.demote(store, io, obj.digest) catch |err| switch (err) {
                    error.ObjectNotFound => continue, // raced; treat as gone
                    error.Canceled => return error.Canceled,
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.Unexpected,
                };
                cold_used += coldByteSize(store, io, obj.digest);
            }
            report.demoted_objects += 1;
            hot_used -= @min(hot_used, obj.size);
            continue;
        }
        try evict(store, io, &report, obj, policy.dry_run);
        hot_used -= @min(hot_used, obj.size);
    }

    // -- Phase 3b: cold-tier quota sweep to 90% hysteresis (spec §9.1,
    // invariant §11.4). Oldest unrooted cold objects first; the demote
    // gate above keeps post-demotion cold usage near target, and this
    // pass trims whatever remains over it.
    for (sorted) |obj| {
        if (cold_used <= cold_target) break;
        if (obj.tier != .cold) continue;
        if (live.contains(obj.digest.bytes)) continue;
        if (!policy.dry_run and isOlderThan(obj, now_ms, max_age_ns)) continue; // evicted in phase 2
        try evict(store, io, &report, obj, policy.dry_run);
        cold_used -= @min(cold_used, obj.size);
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

/// Project-local incremental state: `state/projects/<id>/incremental/`
/// (spec §9.5). Deletes files older than `incremental_max_age_ns`, then
/// trims oldest-first past `incremental_limit` per project. Dry runs count
/// without deleting.
fn sweepIncremental(store: *root.Store, io: Io, gpa: std.mem.Allocator, dry_run: bool) GcError!u64 {
    var freed: u64 = 0;
    const now_ms = Io.Timestamp.now(io, .real).toMilliseconds();
    const projs = store.dir.openDir(io, layout.state_dir ++ "/projects", .{ .iterate = true }) catch return error.Unexpected;
    defer projs.close(io);
    var it = projs.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".json")) continue;
        const incr_path = std.fmt.allocPrint(gpa, "{s}/projects/{s}/incremental", .{ layout.state_dir, entry.name }) catch return error.OutOfMemory;
        defer gpa.free(incr_path);
        const incr = store.dir.openDir(io, incr_path, .{ .iterate = true }) catch continue;
        defer incr.close(io);
        freed += try sweepOneIncremental(store, io, gpa, incr, now_ms, dry_run);
    }
    return freed;
}

fn sweepOneIncremental(store: *root.Store, io: Io, gpa: std.mem.Allocator, incr: Io.Dir, now_ms: i64, dry_run: bool) GcError!u64 {
    var files: std.ArrayList(IncrEntry) = .empty;
    defer {
        for (files.items) |f| gpa.free(f.rel);
        files.deinit(gpa);
    }
    collectFiles(io, gpa, incr, "", &files) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Unexpected,
    };
    std.sort.heap(IncrEntry, files.items, {}, struct {
        fn lt(_: void, x: IncrEntry, y: IncrEntry) bool {
            return x.mtime_ms < y.mtime_ms;
        }
    }.lt);

    var freed: u64 = 0;
    var live_total: u64 = 0;
    for (files.items) |f| live_total += f.size;
    for (files.items) |f| {
        const age_ns = @as(u64, @intCast(@max(0, now_ms - f.mtime_ms))) * std.time.ns_per_ms;
        const too_old = age_ns > store.config.incremental_max_age_ns;
        if (!too_old and live_total <= store.config.incremental_limit) continue;
        if (!dry_run) incr.deleteFile(io, f.rel) catch continue;
        freed += f.size;
        live_total -= @min(live_total, f.size);
    }
    return freed;
}

const IncrEntry = struct { rel: []u8, size: u64, mtime_ms: i64 };

const CollectError = error{OutOfMemory} || Io.Cancelable || Io.Dir.Iterator.Error;

/// Recursively collects files under `dir`; `rel` paths are relative to the
/// incremental root. Unreadable entries are skipped (best effort).
fn collectFiles(io: Io, gpa: std.mem.Allocator, dir: Io.Dir, prefix: []const u8, out: *std.ArrayList(IncrEntry)) CollectError!void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const sep: []const u8 = if (prefix.len == 0) "" else "/";
        const rel = try std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ prefix, sep, entry.name });
        errdefer gpa.free(rel);
        const st = dir.statFile(io, entry.name, .{}) catch {
            gpa.free(rel);
            continue;
        };
        if (st.kind == .directory) {
            const sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch {
                gpa.free(rel);
                continue;
            };
            defer sub.close(io);
            try collectFiles(io, gpa, sub, rel, out);
            gpa.free(rel);
            continue;
        }
        try out.append(gpa, .{ .rel = rel, .size = st.size, .mtime_ms = st.mtime.toMilliseconds() });
    }
}

/// Sums bytes under `state/projects/*/incremental/` (spec §9.5) for `stats`.
/// Shares the best-effort walk with the sweep above.
pub fn incrementalBytes(store: *root.Store, io: Io, gpa: std.mem.Allocator) GcError!u64 {
    var total: u64 = 0;
    const projs = store.dir.openDir(io, layout.state_dir ++ "/projects", .{ .iterate = true }) catch return error.Unexpected;
    defer projs.close(io);
    var it = projs.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".json")) continue;
        const incr_path = std.fmt.allocPrint(gpa, "{s}/projects/{s}/incremental", .{ layout.state_dir, entry.name }) catch return error.OutOfMemory;
        defer gpa.free(incr_path);
        const incr = store.dir.openDir(io, incr_path, .{ .iterate = true }) catch continue;
        defer incr.close(io);
        var files: std.ArrayList(IncrEntry) = .empty;
        defer {
            for (files.items) |f| gpa.free(f.rel);
            files.deinit(gpa);
        }
        collectFiles(io, gpa, incr, "", &files) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Unexpected,
        };
        for (files.items) |f| total += f.size;
    }
    return total;
}

/// Callback adapter: action entries are stale when their manifest object
/// no longer exists in either tier.
const PresentCtx = struct {
    store: *root.Store,
    io: Io,

    fn call(ctx: *anyopaque, d: digest_mod.Digest) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return objects.exists(self.store, self.io, d);
    }
};

fn isOlderThan(obj: scan.ObjectInfo, now_ms: i64, max_age_ns: u64) bool {
    const age_ns = @as(u64, @intCast(@max(0, now_ms - obj.mtime_ms))) * std.time.ns_per_ms;
    return age_ns > max_age_ns;
}

/// Store-relative tier path: "objects/ab/<hex>" or "cold/ab/<hex>".
fn tierFullPath(digest: digest_mod.Digest, tier: scan.Tier, buf: *[73]u8) []const u8 {
    var rbuf: [65]u8 = undefined;
    const rel = digest.relPath(&rbuf);
    switch (tier) {
        .hot => {
            @memcpy(buf[0..8], "objects/");
            @memcpy(buf[8..73], rel);
            return buf[0..73];
        },
        .cold => {
            @memcpy(buf[0..5], "cold/");
            @memcpy(buf[5..70], rel);
            return buf[0..70];
        },
    }
}

/// Compressed size of a cold-tier copy; 0 when the copy is absent.
/// Used to account demotions against the cold quota (spec §9.4).
fn coldByteSize(store: *root.Store, io: Io, digest: digest_mod.Digest) u64 {
    var rbuf: [65]u8 = undefined;
    const rel = digest.relPath(&rbuf);
    var buf: [73]u8 = undefined;
    @memcpy(buf[0..5], "cold/");
    @memcpy(buf[5..70], rel);
    if (store.dir.statFile(io, buf[0..70], .{})) |st| {
        return st.size;
    } else |_| {
        return 0;
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
    var buf: [73]u8 = undefined;
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
fn objectFull(d: root.Digest, buf: *[73]u8) []const u8 {
    var rbuf: [65]u8 = undefined;
    const rel = d.relPath(&rbuf);
    @memcpy(buf[0..8], "objects/");
    @memcpy(buf[8..], rel);
    return buf[0..73];
}

fn setMtime(io: std.Io, store: *root.Store, d: root.Digest, ms: i64) !void {
    var buf: [73]u8 = undefined;
    const f = try store.dir.openFile(io, objectFull(d, &buf), .{});
    defer f.close(io);
    try f.setTimestamps(io, .{ .modify_timestamp = .{ .new = .fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms) } });
}

fn setColdMtime(io: std.Io, store: *root.Store, d: root.Digest, ms: i64) !void {
    var rbuf: [65]u8 = undefined;
    const rel = d.relPath(&rbuf);
    var buf: [73]u8 = undefined;
    @memcpy(buf[0..5], "cold/");
    @memcpy(buf[5..70], rel);
    const f = try store.dir.openFile(io, buf[0..70], .{});
    defer f.close(io);
    try f.setTimestamps(io, .{ .modify_timestamp = .{ .new = .fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms) } });
}

test "quota sweep evicts oldest unrooted first and stops at 90 percent" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var ts = test_support.openTestStore(io, fixedConfig(10));
    defer ts.deinit(io);
    // limits.resolveLimits is not re-run by open with .fixed values:
    // Cold is full here so the sweep evicts instead of demoting (spec §9.7
    // demote-before-evict is covered by the demotion test below).
    ts.store.limits = .{ .hot = 10, .cold = 1, .reserve = 0 };
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

test "quota pressure demotes demotable objects before evicting" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var ts = test_support.openTestStore(io, fixedConfig(10));
    defer ts.deinit(io);
    ts.store.limits = .{ .hot = 10, .cold = 100 * root.config.GiB, .reserve = 0 };
    ts.store.config.max_age_ns = std.math.maxInt(u64);

    const a = try ts.store.putBytes(io, "aaaa", .other); // 4 B
    _ = try ts.store.putBytes(io, "bbbb", .other); // 4 B
    _ = try ts.store.putBytes(io, "cccc", .other); // 4 B
    // 12 B hot over the 9 B target: the oldest unrooted object demotes.
    try setMtime(io, &ts.store, a, 1_000);

    const report = try ts.store.gc(io, gpa, .{});
    try std.testing.expectEqual(@as(u64, 1), report.demoted_objects);
    try std.testing.expectEqual(@as(u64, 0), report.evicted_objects);
    // Still readable through the cold tier; the hot copy is gone.
    try std.testing.expect(ts.store.exists(io, a));
    try std.testing.expect(!ts.store.dirHasHot(io, a));
    const got = try ts.store.readObject(io, a, gpa);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("aaaa", got);
}

test "cold quota sweep evicts oldest unrooted first" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var ts = test_support.openTestStore(io, fixedConfig(10));
    defer ts.deinit(io);
    ts.store.limits = .{ .hot = 100 * root.config.GiB, .cold = 100 * root.config.GiB, .reserve = 0 };
    ts.store.config.max_age_ns = std.math.maxInt(u64);

    const a = try ts.store.putBytes(io, "aaaa", .other);
    const b = try ts.store.putBytes(io, "bbbb", .other);
    const c = try ts.store.putBytes(io, "cccc", .other);
    try ts.store.pin(io, "keep-b", b);
    try ts.store.demote(io, a);
    try ts.store.demote(io, b);
    try ts.store.demote(io, c);
    // Size the cold limit at exactly current cold usage: the 90%
    // hysteresis target then forces one eviction (the oldest unrooted).
    const pre = try ts.store.scan(io, gpa);
    defer gpa.free(pre);
    var cold_total: u64 = 0;
    for (pre) |obj| {
        if (obj.tier == .cold) cold_total += obj.size;
    }
    try std.testing.expect(cold_total > 0);
    ts.store.limits.cold = cold_total;
    // LRU order fixed by backdating (demote stamps fresh mtimes).
    try setColdMtime(io, &ts.store, a, 1_000);
    try setColdMtime(io, &ts.store, b, 2_000);
    try setColdMtime(io, &ts.store, c, 3_000);

    const report = try ts.store.gc(io, gpa, .{});
    try std.testing.expect(report.evicted_objects >= 1);
    try std.testing.expect(!ts.store.exists(io, a)); // oldest unrooted gone
    try std.testing.expect(ts.store.exists(io, b)); // pinned survives
    try std.testing.expect(ts.store.exists(io, c)); // newer unrooted kept
}

test "incremental sweep trims old files and counts freed bytes" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);
    ts.store.limits = .{ .hot = 100 * root.config.GiB, .cold = 100 * root.config.GiB, .reserve = 0 };
    ts.store.config.max_age_ns = std.math.maxInt(u64);

    try ts.store.dir.createDirPath(io, "state/projects/proj1/incremental");
    try ts.store.dir.writeFile(io, .{ .sub_path = "state/projects/proj1/incremental/old.bin", .data = "0123456789" });
    try ts.store.dir.writeFile(io, .{ .sub_path = "state/projects/proj1/incremental/new.bin", .data = "abc" });
    // Backdate one file beyond the default 5-day incremental max age.
    const f = try ts.store.dir.openFile(io, "state/projects/proj1/incremental/old.bin", .{});
    defer f.close(io);
    try f.setTimestamps(io, .{ .modify_timestamp = .{ .new = .fromNanoseconds(1_000_000_000) } });

    const dry = try ts.store.gc(io, gpa, .{ .dry_run = true });
    try std.testing.expectEqual(@as(u64, 10), dry.freed_bytes_incremental);
    // Dry run deletes nothing.
    _ = try ts.store.dir.statFile(io, "state/projects/proj1/incremental/old.bin", .{});

    const real = try ts.store.gc(io, gpa, .{});
    try std.testing.expectEqual(@as(u64, 10), real.freed_bytes_incremental);
    try std.testing.expectError(error.FileNotFound, ts.store.dir.statFile(io, "state/projects/proj1/incremental/old.bin", .{}));
    _ = try ts.store.dir.statFile(io, "state/projects/proj1/incremental/new.bin", .{});
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

test "gc counts and expires leases" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);
    ts.store.limits = .{ .hot = 100 * root.config.GiB, .cold = 100 * root.config.GiB, .reserve = 0 };
    ts.store.config.max_age_ns = std.math.maxInt(u64);

    const d = try ts.store.putBytes(io, "leased", .other);
    // Expired relative to gc wall clock (1970 + TTL vs now).
    try state.putLease(io, ts.store.dir, "old-build", &.{d}, 1000);
    const report = try ts.store.gc(io, gpa, .{});
    try std.testing.expectEqual(@as(u64, 1), report.expired_leases);
    const remaining = try state.liveLeases(io, gpa, ts.store.dir, std.Io.Timestamp.now(io, .real).toMilliseconds());
    defer state.freeLeases(gpa, remaining);
    try std.testing.expectEqual(@as(usize, 0), remaining.len);
}

test "dry run counts expiry without deleting leases or actions" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);
    ts.store.limits = .{ .hot = 1, .cold = 1, .reserve = 0 };

    const a = try ts.store.putBytes(io, "doomed", .other);
    // Expired lease (1970 + TTL vs wall clock now).
    try state.putLease(io, ts.store.dir, "old-build", &.{a}, 1000);

    // Stale action entry: manifest object deleted behind its back.
    var no_outputs: [0]root.Store.ManifestOutput = .{};
    const man = try ts.store.putManifest(io, .{ .kind = .bin, .outputs = &no_outputs });
    const key = root.hashBytes("dry-run-stale");
    try ts.store.putAction(io, key, man);
    var mbuf: [73]u8 = undefined;
    var rbuf: [65]u8 = undefined;
    const mrel = man.relPath(&rbuf);
    @memcpy(mbuf[0..8], "objects/");
    @memcpy(mbuf[8..], mrel);
    try ts.store.dir.deleteFile(io, mbuf[0..73]);

    const report = try ts.store.gc(io, gpa, .{ .dry_run = true });
    try std.testing.expect(report.dry_run);
    try std.testing.expectEqual(@as(u64, 1), report.expired_leases);
    try std.testing.expectEqual(@as(u64, 1), report.stale_action_entries);
    try std.testing.expect(report.evicted_objects >= 1);
    // Nothing deleted: object, expired lease file, and stale entry remain.
    try std.testing.expect(ts.store.exists(io, a));
    try std.testing.expectEqual(@as(u64, 1), try state.countExpiredLeases(io, gpa, ts.store.dir, std.Io.Timestamp.now(io, .real).toMilliseconds()));
    try std.testing.expect((try ts.store.getAction(io, gpa, key)) != null);
}
