const std = @import("std");
const root = @import("root.zig");
const budget_mod = @import("budget.zig");
const index_mod = @import("index.zig");
const digest_mod = @import("digest.zig");
const disk_usage_mod = @import("disk_usage.zig");
const cold_mod = @import("cold.zig");
const gc_mod = @import("gc.zig");
const test_support = @import("test_support.zig");

const Io = std.Io;

pub const Class = root.Class;
pub const Hint = root.Hint;
pub const BudgetBreakdown = root.BudgetBreakdown;
pub const AdmitError = root.AdmitError;
pub const Reservation = root.Reservation;

test "reserve fails StoreFull when roots alone fill the budget" {
    // NOTE (plan deviation, reported): the opening budget must first admit
    // the put AND the real index+state bytes (~110 KiB fresh index.sqlite)
    // under honest I-TOTAL accounting, so it starts at 1 MiB and is shrunk
    // below usage only after pinning. The plan's fixed=100 cannot admit
    // even the empty index, let alone the object.
    // NOTE (§9.2 root gate): the pin itself is index_state-admitted, so the
    // opening total is 10 MiB (index_state cap 512 KiB clears the real
    // ~251 KiB fresh index); 1 MiB would fail the pin before the shrink.
    const io = std.Io.Threaded.global_single_threaded.io();
    var ts = test_support.openTestStore(io, .{ .budget = .{ .fixed = 10_000_000 } });
    defer ts.deinit(io);

    const d = try ts.store.putBytes(io, "0123456789", .other); // 10 B
    try ts.store.pin(io, "root", d);
    // Shrink the budget below the pinned bytes: nothing evictable.
    ts.store.budget.total = 5;
    var bd: root.BudgetBreakdown = undefined;
    const r = reserve(&ts.store, io, .hot, 50, null, &bd);
    try std.testing.expectError(error.StoreFull, r);
    try std.testing.expectEqual(root.Class.hot, bd.class);
    try std.testing.expect(bd.used_total >= 10);
    try std.testing.expect(ts.store.lastFull().used_total >= 10);
}

test "reserve evicts unrooted lru before failing" {
    // NOTE (plan deviation, reported): budgets must clear the real
    // index+state (~110 KiB), keep every object within the 10%-of-class
    // bounded eviction window, and leave hot headroom for the request — so
    // this runs at 1 MiB total / 30 KiB objects / 660 KiB request instead of
    // the plan's 24 B / 4 B / 20 B (which can neither admit the index nor
    // fit 20 B in the resulting 16 B hot class).
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var ts = test_support.openTestStore(io, .{ .budget = .{ .fixed = 1_000_000 } });
    defer ts.deinit(io);

    const pa = try gpa.alloc(u8, 30_000);
    defer gpa.free(pa);
    @memset(pa, 'a');
    const pb = try gpa.alloc(u8, 30_000);
    defer gpa.free(pb);
    @memset(pb, 'b');
    _ = try ts.store.putBytes(io, pa, .other); // oldest
    _ = try ts.store.putBytes(io, pb, .other);
    const before = try index_mod.objectCount(&ts.store.index);
    try std.testing.expectEqual(@as(u64, 2), before);
    const r = try reserve(&ts.store, io, .hot, 660_000, null, null);
    defer abort(&ts.store, io, r);
    // 60 KiB used + 660 KiB > 700 KiB hot class: oldest unrooted evicted.
    try std.testing.expect(try index_mod.objectCount(&ts.store.index) < 2);
}

test "abort clears the in-flight reservation" {
    // NOTE (plan deviation, reported): budget scaled to 1 MiB so the put
    // admits under honest index+state accounting (see above). The body
    // exercises abort (not commit); titled accordingly.
    const io = std.Io.Threaded.global_single_threaded.io();
    var ts = test_support.openTestStore(io, .{ .budget = .{ .fixed = 1_000_000 } });
    defer ts.deinit(io);

    _ = try ts.store.putBytes(io, "x", .other);
    const r = try reserve(&ts.store, io, .hot, 100, null, null);
    try std.testing.expectEqual(@as(u64, 100), try index_mod.reservationSum(&ts.store.index, .hot));
    abort(&ts.store, io, r);
    try std.testing.expectEqual(@as(u64, 0), try index_mod.reservationSum(&ts.store.index, .hot));
}

/// Write-time admission control (storage-v2 §10.1 order): reserve → evict unrooted LRU
/// → demote hot→cold (only when admitting to hot and cold has room) → StoreFull | commit token.
/// Scoped to the issuing class cap AND I-TOTAL AND the disk_reserve floor.
/// Bounded effort: at most 1,000 objects AND at most 10% of the class cap per admit
/// (whichever bound hits first) via bounded SUM candidate queries. Roots are never touched.
/// In-flight `reservations`-table bytes count toward the class (TTL 10 min, renewable; live
/// `owner_build_id` lease extends to the lease TTL). Spool coupling: staged tmp bytes count
/// against spool_cap via the tmp walk; a put whose staged bytes alone exceed spool_cap fails
/// fast with `StoreFull{ class = "spool" }` before writing (see checkSpoolFit).
pub fn reserve(store: *root.Store, io: Io, class: Class, bytes: u64, owner: ?root.BuildId, breakdown: ?*BudgetBreakdown) AdmitError!Reservation {
    const page = std.heap.page_allocator;
    const now_ms = Io.Timestamp.now(io, .real).toMilliseconds();

    // Ledger hygiene: expired reservations are garbage counted against the
    // budget (§8.1/§10.2). Best-effort — a broken ledger surfaces below.
    index_mod.sweepExpiredReservations(&store.index, now_ms) catch {};

    // Class-scoped admit: binding cap is the issuing class cap; I-TOTAL still binds the sum (§9.2).
    // disk_reserve floor checked first (§10.3) via statfs free space.
    const disk = try disk_usage_mod.readDiskUsage(io, store.dir);
    if (disk.free_bytes < store.budget.reserve +| bytes) {
        const usage = try budget_mod.classUsage(store, io, page);
        const r = try reservedSums(&store.index);
        const bd = BudgetBreakdown{
            .requested_bytes = bytes,
            .class = .disk_reserve,
            .budget = store.budget.total,
            .used_total = totalUsed(usage, r),
            .used_class = 0,
            .cap_class = store.budget.reserve,
            .reserved_class = 0,
            .reclaimable_class = 0,
            .hint = .free_disk,
        };
        if (breakdown) |b| b.* = bd;
        store.last_breakdown = bd;
        return error.StoreFull;
    }

    const cap = classCap(store.budget, class);
    var usage = try budget_mod.classUsage(store, io, page);
    var r = try reservedSums(&store.index);
    if (classUsed(class, usage, r) +| bytes <= cap and
        totalUsed(usage, r) +| bytes <= store.budget.total)
    {
        return insertFresh(store, io, class, bytes, owner, now_ms);
    }

    var live = try gc_mod.liveSet(store, io, page, true);
    defer live.deinit();
    const ledger = toLedgerClass(class);
    // Bounded eviction candidates: oldest-first, at most 1,000 objects AND at most
    // 10% of the class cap (whichever bound hits first) — one bounded query, never a full fetch.
    const cands = try index_mod.evictionCandidates(&store.index, page, ledger, 1000, cap / 10);
    defer index_mod.freeRows(page, cands);

    // Reclaimable (§10.4): unrooted candidate bytes, computed BEFORE the
    // passes consume them. (The plan sketch placed this in the index; the
    // index cannot know the root set, so it is computed here from the
    // candidate + live sets.)
    var reclaimable: u64 = 0;
    for (cands) |cand| {
        const d32 = digest_mod.Digest.fromHex(&cand.digest) catch continue;
        if (live.contains(d32.bytes)) continue;
        reclaimable +|= classMeasure(ledger, cand);
    }

    // usage/r are the pre-pass snapshot; freed_* track this pass's relief so
    // the loop stops as soon as the estimates fit (post-check below is
    // authoritative with fresh numbers).
    var freed_class: u64 = 0;
    var freed_total: u64 = 0;
    // Pass 1: evict oldest unrooted of the issuing class, deleting bytes + rows.
    for (cands) |cand| {
        if (fitsAfter(store.budget, class, usage, r, bytes, freed_class, freed_total)) break;
        const d32 = digest_mod.Digest.fromHex(&cand.digest) catch continue;
        if (live.contains(d32.bytes)) continue;
        const m = classMeasure(ledger, cand);
        evictRow(store, io, cand.tier, d32);
        freed_class +|= m;
        freed_total +|= m;
    }
    // Pass 2: demote demotable hot survivors (only when admitting to hot and cold has room).
    var cold_added: u64 = 0;
    if (class == .hot) {
        for (cands) |cand| {
            if (fitsAfter(store.budget, class, usage, r, bytes, freed_class, freed_total)) break;
            if (cand.tier != .hot) continue;
            const d32 = digest_mod.Digest.fromHex(&cand.digest) catch continue;
            if (live.contains(d32.bytes)) continue;
            const kind = std.meta.stringToEnum(root.Kind, cand.kind) orelse .other;
            if (!cold_mod.isDemotable(kind)) continue;
            // Cold room gate on estimated gzip bytes (raw size + framing
            // upper-bounds the compressed copy).
            if (usage.cold +| r.cold +| cold_added +| cand.size +| 64 > store.budget.cold) continue;
            cold_mod.demote(store, io, d32) catch continue;
            const added: u64 = coldCopySize(store, io, d32) catch continue;
            cold_added +|= added;
            freed_class +|= cand.size;
            freed_total +|= cand.size -| added;
        }
    }

    usage = try budget_mod.classUsage(store, io, page);
    r = try reservedSums(&store.index);
    if (classUsed(class, usage, r) +| bytes <= cap and
        totalUsed(usage, r) +| bytes <= store.budget.total)
    {
        return insertFresh(store, io, class, bytes, owner, now_ms);
    }
    const bd = BudgetBreakdown{
        .requested_bytes = bytes,
        .class = class,
        .budget = store.budget.total,
        .used_total = totalUsed(usage, r),
        .used_class = classUsed(class, usage, r),
        .cap_class = cap,
        .reserved_class = classReserved(class, r),
        .reclaimable_class = reclaimable,
        .hint = if (reclaimable == 0) .unpin_named else .run_gc,
    };
    if (breakdown) |b| b.* = bd;
    store.last_breakdown = bd;
    return error.StoreFull;
}

pub fn commit(store: *root.Store, io: Io, res: Reservation, digest: digest_mod.Digest) void {
    _ = digest;
    _ = io;
    index_mod.deleteReservation(&store.index, res.id) catch {};
}

pub fn abort(store: *root.Store, io: Io, res: Reservation) void {
    _ = io;
    index_mod.deleteReservation(&store.index, res.id) catch {};
}

/// §10.2 spool fast-fail: staged bytes alone exceeding spool_cap can never be
/// admitted (no eviction frees spool staging). Populates last_breakdown and
/// returns StoreFull before the caller writes anything.
pub fn checkSpoolFit(store: *root.Store, io: Io, bytes: u64) AdmitError!void {
    if (bytes <= store.budget.spool) return;
    const page = std.heap.page_allocator;
    const usage = try budget_mod.classUsage(store, io, page);
    const r = try reservedSums(&store.index);
    const bd = BudgetBreakdown{
        .requested_bytes = bytes,
        .class = .spool,
        .budget = store.budget.total,
        .used_total = totalUsed(usage, r),
        .used_class = usage.spool,
        .cap_class = store.budget.spool,
        .reserved_class = r.spool,
        .reclaimable_class = 0, // spool holds staging only; there is no LRU to free
        .hint = .raise_budget, // the object alone exceeds the cap: gc cannot help
    };
    store.last_breakdown = bd;
    return error.StoreFull;
}

const ReservedSums = struct { hot: u64, cold: u64, index_state: u64, spool: u64 };

fn reservedSums(idx: *index_mod.Index) index_mod.DbError!ReservedSums {
    return .{
        .hot = try index_mod.reservationSum(idx, .hot),
        .cold = try index_mod.reservationSum(idx, .cold),
        .index_state = try index_mod.reservationSum(idx, .index_state),
        .spool = try index_mod.reservationSum(idx, .spool),
    };
}

fn classCap(b: budget_mod.ResolvedBudget, class: Class) u64 {
    return switch (class) {
        .hot => b.hot,
        .cold => b.cold,
        .index_state => b.index_state,
        .spool => b.spool,
        .disk_reserve => b.reserve,
    };
}

/// Class usage including in-flight ledger bytes for that class. Spool is the
/// exception: classUsage.spool already contains spool reservations (§9.3),
/// so adding them again would double-count.
fn classUsed(class: Class, u: budget_mod.ClassUsage, r: ReservedSums) u64 {
    return switch (class) {
        .hot => u.hot +| r.hot,
        .cold => u.cold +| r.cold,
        .index_state => u.index_state +| r.index_state,
        .spool => u.spool,
        .disk_reserve => 0, // governed by the floor check, not a cap
    };
}

fn classReserved(class: Class, r: ReservedSums) u64 {
    return switch (class) {
        .hot => r.hot,
        .cold => r.cold,
        .index_state => r.index_state,
        .spool => r.spool,
        .disk_reserve => 0,
    };
}

/// I-TOTAL usage: every class plus every in-flight reservation. Spool
/// reservations are already inside u.spool; the other three classes'
/// reservations live only in the ledger until commit.
fn totalUsed(u: budget_mod.ClassUsage, r: ReservedSums) u64 {
    return u.hot +| u.cold +| u.index_state +| u.spool +| r.hot +| r.cold +| r.index_state;
}

fn fitsAfter(b: budget_mod.ResolvedBudget, class: Class, u: budget_mod.ClassUsage, r: ReservedSums, bytes: u64, freed_class: u64, freed_total: u64) bool {
    return classUsed(class, u, r) +| bytes <= classCap(b, class) +| freed_class and
        totalUsed(u, r) +| bytes <= b.total +| freed_total;
}

/// The report-only disk_reserve class never reaches the ledger (reserve is
/// never called with it); map it to spool so the switch stays total.
/// Documented; no caller constructs it.
fn toLedgerClass(class: Class) index_mod.Class {
    return switch (class) {
        .hot => .hot,
        .cold => .cold,
        .index_state => .index_state,
        .spool => .spool,
        .disk_reserve => .spool,
    };
}

fn classMeasure(ledger: index_mod.Class, row: index_mod.ObjectRow) u64 {
    return switch (ledger) {
        .cold => row.compressed_size orelse row.size,
        .hot => row.size,
        .index_state, .spool => 0,
    };
}

fn insertFresh(store: *root.Store, io: Io, class: Class, bytes: u64, owner: ?root.BuildId, now_ms: i64) AdmitError!Reservation {
    var id: [16]u8 = undefined;
    io.random(&id);
    const ttl_ms: i64 = @intCast(store.config.reservation_ttl_ns / std.time.ns_per_ms);
    var expires = now_ms + ttl_ms;
    // A live owner lease extends the matching reservation to the lease TTL
    // so long builds with large outputs keep their reservation (§10.2).
    if (owner) |o| {
        if (try index_mod.leaseExpiry(&store.index, o)) |lease_exp| {
            if (lease_exp > expires) expires = lease_exp;
        }
    }
    try index_mod.insertReservation(&store.index, id, toLedgerClass(class), bytes, now_ms, expires, owner);
    return .{ .id = id, .class = class, .bytes = bytes };
}

/// Deletes the tier file(s) + index row for one eviction candidate.
/// Best-effort throughout: bytes are authoritative, the post-pass usage
/// re-check is authoritative, this helper is just labor.
fn evictRow(store: *root.Store, io: Io, tier: index_mod.Tier, d: digest_mod.Digest) void {
    var rbuf: [65]u8 = undefined;
    const rel = d.relPath(&rbuf);
    if (tier == .hot or tier == .both) {
        var buf: [73]u8 = undefined;
        @memcpy(buf[0..8], "objects/");
        @memcpy(buf[8..], rel);
        store.dir.deleteFile(io, buf[0..73]) catch {};
    }
    if (tier == .cold or tier == .both) {
        var buf: [70]u8 = undefined;
        @memcpy(buf[0..5], "cold/");
        @memcpy(buf[5..70], rel);
        store.dir.deleteFile(io, buf[0..70]) catch {};
    }
    const hex = d.toHex();
    index_mod.deleteObject(&store.index, &hex) catch {};
}

fn coldCopySize(store: *root.Store, io: Io, d: digest_mod.Digest) Io.Dir.StatFileError!u64 {
    var rbuf: [65]u8 = undefined;
    const rel = d.relPath(&rbuf);
    var buf: [70]u8 = undefined;
    @memcpy(buf[0..5], "cold/");
    @memcpy(buf[5..70], rel);
    const st = try store.dir.statFile(io, buf[0..70], .{});
    return st.size;
}
