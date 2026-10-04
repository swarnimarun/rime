const std = @import("std");
const config_mod = @import("config.zig");
const disk_usage = @import("disk_usage.zig");
const index_mod = @import("index.zig");

const Io = std.Io;

/// Soft per-tag budget (storage-v2 §12.3, decision D6). Soft caps steer GC
/// eviction order only; they never cause StoreFull. The SQLite
/// `tag_budgets.soft_cap` column holds the same value; TOML key is singular
/// `store.tag_budget` per §15.
pub const TagBudget = struct { key: []const u8, value: []const u8, soft_cap: u64 };

/// Budget classes (§9.1). Shared with the `reservations.class` values;
/// aliased from the index so budget and index agree on one spelling.
pub const Class = index_mod.Class;

pub const ResolvedBudget = struct {
    total: u64,
    hot: u64,
    cold: u64,
    index_state: u64,
    spool: u64,
    reserve: u64,
};

fn clamp(v: u64, lo: u64, hi: u64) u64 {
    return @max(lo, @min(hi, v));
}

fn resolveClassCap(explicit: ?config_mod.Limit, deprecated: config_mod.Limit, share_pct: u64, total: u64) u64 {
    // Explicit `*_cap` wins; else the deprecated `hot/cold_limit.fixed`
    // pins its class per §14.7; else the default share of the total.
    if (explicit) |cap| switch (cap) {
        .fixed => |v| return v,
        .auto => {},
    };
    switch (deprecated) {
        .fixed => |v| return v,
        .auto => {},
    }
    return total * share_pct / 100;
}

/// Total budget (`store.budget`, storage-v2 §9.1): fixed or clamp(10% free, 5 GiB, 50 GiB).
/// Classes are hard splits of the total (hot 70 / cold 20 / index+state 5 / spool 5);
/// deprecated `hot_limit`/`cold_limit` pin their class per the §14.7 mapping;
/// explicit `hot_cap`/`cold_cap`/`index_state_cap`/`spool_cap` override both.
/// Leftover slack when caps sum below total is unallocated headroom no class
/// may borrow. Use `resolveBudgetChecked` for the sum <= budget validation.
pub fn resolveBudget(cfg: config_mod.Config, usage: disk_usage.DiskUsage) ResolvedBudget {
    const total = switch (cfg.budget) {
        .fixed => |v| v,
        .auto => clamp(usage.free_bytes / 10, 5 * config_mod.GiB, 50 * config_mod.GiB),
    };
    const hot = resolveClassCap(cfg.hot_cap, cfg.hot_limit, 70, total);
    const cold = resolveClassCap(cfg.cold_cap, cfg.cold_limit, 20, total);
    const index_state = if (cfg.index_state_cap) |cap| switch (cap) {
        .fixed => |v| v,
        .auto => total * 5 / 100,
    } else total * 5 / 100;
    const spool = if (cfg.spool_cap) |cap| switch (cap) {
        .fixed => |v| v,
        .auto => total * 5 / 100,
    } else total * 5 / 100;
    const reserve = switch (cfg.disk_reserve) {
        .fixed => |v| v,
        .auto => @max(5 * config_mod.GiB, usage.fs_size / 20),
    };
    return .{
        .total = total,
        .hot = hot,
        .cold = cold,
        .index_state = index_state,
        .spool = spool,
        .reserve = reserve,
    };
}

/// Checked resolution: explicit class caps must sum <= budget
/// (`error.InvalidConfig` otherwise; leftover slack is unallocated headroom).
pub fn resolveBudgetChecked(cfg: config_mod.Config, usage: disk_usage.DiskUsage) error{InvalidConfig}!ResolvedBudget {
    const b = resolveBudget(cfg, usage);
    // Overflow-safe sum: saturating add, then compare.
    var sum: u64 = 0;
    sum = sum +| b.hot;
    sum = sum +| b.cold;
    sum = sum +| b.index_state;
    sum = sum +| b.spool;
    if (sum > b.total) return error.InvalidConfig;
    return b;
}

pub const ClassUsage = struct { hot: u64, cold: u64, index_state: u64, spool: u64 };

pub const UsageError = error{Unexpected, OutOfMemory} || Io.Cancelable || index_mod.DbError;

/// Hot/cold from index SUM queries (compressed sizes for cold; §12.3 CASE measure);
/// index_state and spool from recursive walks. Best-effort: unreadable entries skip.
pub fn classUsage(store: *const @import("root.zig").Store, io: Io, gpa: std.mem.Allocator) UsageError!ClassUsage {
    _ = gpa;
    // The index takes *Index even for reads (SQLite handle); the store is
    // only borrowed for measurement, so a const-cast is safe here.
    const mut_store: *@import("root.zig").Store = @constCast(store);
    var u = ClassUsage{ .hot = 0, .cold = 0, .index_state = 0, .spool = 0 };
    u.hot = try index_mod.classSum(&mut_store.index, .hot);
    u.cold = try index_mod.classSum(&mut_store.index, .cold);
    // index_state = index.sqlite + -wal + -shm + recursive state/ (journals, backup.json); §9.3
    if (storeDirStat(io, store.dir, "index.sqlite")) |s| u.index_state += s;
    if (storeDirStat(io, store.dir, "index.sqlite-wal")) |s| u.index_state += s;
    if (storeDirStat(io, store.dir, "index.sqlite-shm")) |s| u.index_state += s;
    u.index_state += try dirBytesRecursive(io, store.dir, "state");
    u.spool = try dirBytesRecursive(io, store.dir, "tmp");
    u.spool += try index_mod.reservationSum(&mut_store.index, .spool);
    return u;
}

fn storeDirStat(io: Io, store_dir: Io.Dir, sub: []const u8) ?u64 {
    const st = store_dir.statFile(io, sub, .{}) catch return null;
    return st.size;
}

/// Recursive size walk: follows nested fanout dirs (objects/ab/…, cold/…, state/…).
/// Counts every file; skips unreadable entries. Never follows symlinks out of the store.
fn dirBytesRecursive(io: Io, store_dir: Io.Dir, sub: []const u8) UsageError!u64 {
    const page = std.heap.page_allocator;
    var total: u64 = 0;
    const d = store_dir.openDir(io, sub, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        error.Canceled => return error.Canceled,
        else => return 0,
    };
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return 0,
    }) |entry| {
        if (entry.kind == .directory) {
            const child = std.fmt.allocPrint(page, "{s}/{s}", .{ sub, entry.name }) catch return error.OutOfMemory;
            defer page.free(child);
            total += try dirBytesRecursive(io, store_dir, child);
            continue;
        }
        const child = std.fmt.allocPrint(page, "{s}/{s}", .{ sub, entry.name }) catch return error.OutOfMemory;
        defer page.free(child);
        if (store_dir.statFile(io, child, .{})) |st| total += st.size else |_| {}
    }
    return total;
}

test "auto total splits into hard classes" {
    const b = resolveBudget(.{}, .{ .free_bytes = 1000 * config_mod.GiB, .fs_size = 2000 * config_mod.GiB });
    // clamp(10% of 1000 GiB, 5 GiB, 50 GiB) = 50 GiB total; §9.1 split 70/20/5/5
    try std.testing.expectEqual(@as(u64, 50 * config_mod.GiB), b.total);
    try std.testing.expectEqual(@as(u64, 35 * config_mod.GiB), b.hot);
    try std.testing.expectEqual(@as(u64, 10 * config_mod.GiB), b.cold);
    try std.testing.expectEqual(@as(u64, 50 * config_mod.GiB / 20), b.index_state);
    try std.testing.expectEqual(@as(u64, 50 * config_mod.GiB / 20), b.spool);
    try std.testing.expectEqual(b.total, b.hot + b.cold + b.index_state + b.spool);
}

test "explicit class caps must sum to <= budget" {
    const cfg = config_mod.Config{
        .budget = .{ .fixed = 10 * config_mod.GiB },
        .hot_cap = .{ .fixed = 7 * config_mod.GiB },
        .cold_cap = .{ .fixed = 4 * config_mod.GiB }, // 7+4 already > 10 with index/spool shares
    };
    try std.testing.expectError(error.InvalidConfig, resolveBudgetChecked(cfg, .{ .free_bytes = 10 * config_mod.GiB, .fs_size = 10 * config_mod.GiB }));
}

test "fixed hot and cold limits override their classes" {
    const cfg = config_mod.Config{
        .hot_limit = .{ .fixed = 2 * config_mod.GiB },
        .cold_limit = .{ .fixed = 3 * config_mod.GiB },
        .disk_reserve = .{ .fixed = 1 * config_mod.GiB },
    };
    const b = resolveBudget(cfg, .{ .free_bytes = 10 * config_mod.GiB, .fs_size = 10 * config_mod.GiB });
    try std.testing.expectEqual(@as(u64, 2 * config_mod.GiB), b.hot);
    try std.testing.expectEqual(@as(u64, 3 * config_mod.GiB), b.cold);
    try std.testing.expectEqual(@as(u64, 1 * config_mod.GiB), b.reserve);
}

test "fixed total budget splits proportionally" {
    const cfg = config_mod.Config{ .budget = .{ .fixed = 20 * config_mod.GiB } };
    const b = resolveBudget(cfg, .{ .free_bytes = 10 * config_mod.GiB, .fs_size = 10 * config_mod.GiB });
    try std.testing.expectEqual(@as(u64, 20 * config_mod.GiB), b.total);
    try std.testing.expectEqual(@as(u64, 14 * config_mod.GiB), b.hot);
    try std.testing.expectEqual(@as(u64, 4 * config_mod.GiB), b.cold);
}

test "classUsage counts index rows plus index and spool files" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    const test_support = @import("test_support.zig");
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);

    _ = try ts.store.putBytes(io, "hello", .other); // 5 B hot
    const u = try classUsage(&ts.store, io, gpa);
    try std.testing.expectEqual(@as(u64, 5), u.hot);
    try std.testing.expectEqual(@as(u64, 0), u.cold);
    // index.sqlite exists on disk, so index_state is non-zero; tmp walk is
    // empty but reservations are zero, so spool stays 0 here.
    try std.testing.expect(u.index_state > 0);
    try std.testing.expectEqual(@as(u64, 0), u.spool);
}
