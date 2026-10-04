const std = @import("std");
const digest = @import("digest.zig");
const config_mod = @import("config.zig");
const disk_usage_mod = @import("disk_usage.zig");
const layout = @import("layout.zig");
const test_support = @import("test_support.zig");
const ingest = @import("ingest.zig");
const objects = @import("objects.zig");
const manifest_mod = @import("manifest.zig");
const clone_mod = @import("clone.zig");
const materialize_mod = @import("materialize.zig");
const scan_mod = @import("scan.zig");
/// State file helpers (pins/leases/retains); the CLI lists pins through here.
pub const state = @import("state.zig");
/// SQLite index handle; the CLI opens it directly for `cache migrate`
/// (Store.open refuses format 1, so migration cannot go through Store).
pub const Index = index_mod.Index;
const gc_mod = @import("gc.zig");
const action_cache = @import("action_cache.zig");
const cold_mod = @import("cold.zig");
const index_mod = @import("index.zig");
const tags_mod = @import("tags.zig");
/// Budget resolution + class usage (classUsage feeds the `stat` budget
/// line). Public so the CLI reads usage without a Store wrapper.
/// Plan B Task 11.
pub const budget_mod = @import("budget.zig");
const admission_mod = @import("admission.zig");
/// Explicit v1→v2 migration (storage-v2 §14); invoked only by
/// `rime cache migrate`, never by `Store.open`.
pub const migrate_mod = @import("migrate.zig");
/// Per-tag aggregates for `cache stat --by-tag` (storage-v2 §12.2).
/// Plan B Task 11.
pub const stats_mod = @import("stats.zig");

const Io = std.Io;

pub const Digest = digest.Digest;
pub const hashBytes = digest.hashBytes;
pub const hashFile = digest.hashFile;
pub const config = config_mod;
pub const disk_usage = disk_usage_mod;
pub const disk_usage_pub = disk_usage_mod;

pub const Kind = enum {
    rlib, rmeta, obj, staticlib, dylib, bin, dep_info, manifest, build_script_out, source, other,
};

/// Storage-v2 §16 tag surface at module level (single spelling; Store
/// methods resolve these names directly). Plan B Task 10 needs root.Tag
/// for GcPolicy.tag_filter.
pub const Tag = tags_mod.Tag;
pub const Predicate = tags_mod.Predicate;
pub const TagError = tags_mod.TagError;

/// Write-admission class (storage-v2 §16). disk_reserve is report-only:
/// reserve() is never *called* with it, but a breached disk_reserve floor
/// reports StoreFull{ class = "disk_reserve" } per §10.3 (the plan sketch
/// reused .spool there; the spec's explicit class value wins). The four
/// ledger classes match index.Class / the reservations CHECK exactly.
/// Plan B Task 9.
pub const Class = enum { hot, cold, index_state, spool, disk_reserve };

/// Opaque build identifier (lease owner) for reservations (§16).
/// Plan B Task 9.
pub const BuildId = []const u8;

/// Admission token: 128-bit random id, issuing class, counted bytes (§16).
/// Plan B Task 9.
pub const Reservation = struct { id: [16]u8, class: Class, bytes: u64 };

/// What would free space, per §10.4. Plan B Task 9.
pub const Hint = enum { run_gc, unpin_named, raise_budget, free_disk };

/// Per-call StoreFull detail (§10.4 fields verbatim). All fields defaulted
/// so Store.open can init with .{}. Plan B Task 9.
pub const BudgetBreakdown = struct {
    requested_bytes: u64 = 0,
    class: Class = .hot,
    budget: u64 = 0,
    used_total: u64 = 0,
    used_class: u64 = 0,
    cap_class: u64 = 0,
    reserved_class: u64 = 0,
    reclaimable_class: u64 = 0,
    hint: Hint = .run_gc,
};

/// Admission failures (§16): StoreFull plus the §11.3 tag errors (reserve
/// paths that tag), layered over index/disk/state I/O. Plan B Task 9.
pub const AdmitError = error{ StoreFull, UnknownTagKey, TagMismatch, TagLimit } || index_mod.DbError || disk_usage_mod.DiskUsageError || state.StateError;

/// The StoreFull error value, re-exported for CLI/tests (§10.4).
/// (Zig error sets are global; this is spelling convenience only.)
/// Plan B Task 9.
pub const StoreFull = error.StoreFull;

pub const Store = struct {
    dir: Io.Dir,
    config: config_mod.Config,
    limits: config_mod.ResolvedLimits,
    /// Resolved total budget + hard 70/20/5/5 class caps (storage-v2 §9.1).
    /// Kept alongside `limits` (still populated; v1 GC paths use it until
    /// tag-aware GC replaces them). Invariant: total usage incl.
    /// reservations <= budget.total at all times.
    budget: budget_mod.ResolvedBudget,
    lock_file: Io.File,
    index: index_mod.Index,
    /// Last admission diagnostic, overwritten by the next admission (racy
    /// under concurrent puts — concurrent callers must use the per-call
    /// `breakdown` out-param). Read via lastFull(). Plan B Task 9.
    last_breakdown: BudgetBreakdown,

    pub const OpenError = error{
        UnknownFormat,
        MigrationRequired,
        StatFsFailed,
        Unexpected,
        OutOfMemory,
    } || Io.Cancelable || Io.Dir.CreateDirPathError || Io.File.OpenError || Io.File.Writer.Error || Io.Dir.ReadFileAllocError || Io.Dir.WriteFileError || Io.Dir.OpenError || Io.File.LockError || Io.Dir.StatFileError || Io.Dir.DeleteFileError || Io.Dir.Iterator.Error || Io.Dir.RealPathError || disk_usage_mod.DiskUsageError || index_mod.DbError;

    /// Opens (creating if needed) a store rooted at `dir`. Holds a shared
    /// advisory lock on format-lock until close. Spec: docs/design/storage.md §6, §8.
    pub fn open(io: Io, dir: Io.Dir, cfg: config_mod.Config) OpenError!Store {
        try dir.createDirPath(io, layout.objects_dir);
        try dir.createDirPath(io, layout.cold_dir);
        try dir.createDirPath(io, layout.actions_dir);
        try dir.createDirPath(io, layout.tmp_dir);
        try dir.createDirPath(io, layout.state_dir);
        try dir.createDirPath(io, layout.state_dir ++ "/pins");
        try dir.createDirPath(io, layout.state_dir ++ "/leases");
        try dir.createDirPath(io, layout.state_dir ++ "/projects");

        // format.json: create or validate. Format-to-error table per
        // storage-v2 §14: 1 → MigrationRequired on v2 open (run
        // `rime cache migrate`), 2 → ok, missing dir state creates 2,
        // corrupt/other → UnknownFormat. v1 binaries refuse 2 the same way.
        if (dir.readFileAlloc(io, layout.format_file, std.heap.page_allocator, .unlimited)) |bytes| {
            defer std.heap.page_allocator.free(bytes);
            const parsed = std.json.parseFromSlice(
                layout.FormatJson,
                std.heap.page_allocator,
                bytes,
                .{},
            ) catch return error.UnknownFormat;
            defer parsed.deinit();
            if (parsed.value.format == 1) return error.MigrationRequired;
            if (parsed.value.format != layout.format_version) return error.UnknownFormat;
        } else |err| switch (err) {
            error.FileNotFound => try dir.writeFile(io, .{
                .sub_path = layout.format_file,
                .data = "{\"format\":2}\n",
            }),
            else => return error.Unexpected,
        }

        // Sweep tmp files left by dead processes (older than 1 h).
        try sweepTmp(io, dir);

        const lock = try dir.createFile(io, layout.lock_file, .{ .read = true, .truncate = false });
        try lock.lock(io, .shared);

        var index = try index_mod.Index.open(io, dir);
        errdefer index.close();

        const usage = try disk_usage_mod.readDiskUsage(io, dir);
        // Reap expired reservation rows on open (§10.2 TTL, §8.1 sweep
        // discipline). Best-effort: the ledger is derived state.
        // Plan B Task 9.
        {
            const now_ms = Io.Timestamp.now(io, .real).toMilliseconds();
            index_mod.sweepExpiredReservations(&index, now_ms) catch {};
        }
        return .{
            .dir = dir,
            .config = cfg,
            .limits = config_mod.resolveLimits(cfg, usage),
            .budget = budget_mod.resolveBudget(cfg, usage),
            .lock_file = lock,
            .index = index,
            .last_breakdown = .{},
        };
    }

    pub fn close(store: *Store, io: Io) void {
        store.index.close();
        store.lock_file.unlock(io);
        store.lock_file.close(io);
        store.* = undefined;
    }

    pub const PutError = ingest.PutError;

    pub fn putBytes(store: *Store, io: Io, bytes: []const u8, kind: Kind) PutError!Digest {
        return ingest.putBytes(store, io, bytes, kind);
    }

    pub fn putFile(store: *Store, io: Io, src: Io.File, kind: Kind) PutError!Digest {
        return ingest.putFile(store, io, src, kind);
    }

    pub const ReadError = objects.ReadError;
    pub const VerifyError = objects.VerifyError;

    pub fn exists(store: *Store, io: Io, d: Digest) bool {
        return objects.exists(store, io, d);
    }

    pub fn readObject(store: *Store, io: Io, d: Digest, gpa: std.mem.Allocator) ReadError![]u8 {
        return objects.readObject(store, io, d, gpa);
    }

    pub fn verifyObject(store: *Store, io: Io, d: Digest) VerifyError!void {
        return objects.verifyObject(store, io, d);
    }

    pub const MaterializeMethod = materialize_mod.MaterializeMethod;
    pub const MaterializeError = materialize_mod.MaterializeError;

    /// Clone-or-copy materialization; relative paths resolve under the store.
    pub fn materialize(store: *Store, io: Io, d: Digest, dest_path: []const u8, mode: u32) MaterializeError!MaterializeMethod {
        return materialize_mod.materialize(store, io, d, dest_path, mode, .clone_first);
    }

    pub const ObjectInfo = scan_mod.ObjectInfo;
    pub const ScanError = scan_mod.ScanError;

    pub fn scan(store: *Store, io: Io, gpa: std.mem.Allocator) ScanError![]scan_mod.ObjectInfo {
        return scan_mod.scan(store, io, gpa);
    }

    pub fn touch(store: *Store, io: Io, d: Digest) void {
        return scan_mod.touch(store, io, d);
    }

    pub const Pin = state.Pin;
    pub const Lease = state.Lease;
    pub const ProjectRetain = state.ProjectRetain;
    pub const StateError = state.StateError;
    pub const lease_ttl_ms = state.lease_ttl_ms;

    pub fn pin(store: *Store, io: Io, name: []const u8, d: Digest) StateError!void {
        // §9.2 roots count: a pin that would breach index_state or I-TOTAL
        // fails with StoreFull (never pushes the store over limit). JSON +
        // index row estimate covers the file plus the pins row.
        try checkRootBudget(store, io, @as(u64, @intCast(name.len)) + 256);
        return state.putPin(io, store.dir, name, d, Io.Timestamp.now(io, .real).toMilliseconds(), &store.index);
    }

    pub fn unpin(store: *Store, io: Io, name: []const u8) StateError!void {
        return state.removePin(io, store.dir, name, &store.index);
    }

    pub fn leasePut(store: *Store, io: Io, build_id: []const u8, digests: []const Digest) StateError!void {
        // Same §9.2 gate as pin: lease JSON (one row per member) counts in
        // index_state. Estimate covers the file plus member rows.
        try checkRootBudget(store, io, @as(u64, @intCast(build_id.len)) + @as(u64, @intCast(digests.len)) * 96 + 256);
        return state.putLease(io, store.dir, build_id, digests, Io.Timestamp.now(io, .real).toMilliseconds(), &store.index);
    }

    pub fn leaseRenew(store: *Store, io: Io, build_id: []const u8) StateError!void {
        // Renew rewrites the lease file in place (same members, fresh
        // expiry): still a root write, still gated so a breached store
        // cannot grow roots. Estimate is the rewritten file alone.
        try checkRootBudget(store, io, @as(u64, @intCast(build_id.len)) + 256);
        return state.renewLease(io, store.dir, build_id, Io.Timestamp.now(io, .real).toMilliseconds(), &store.index);
    }

    pub fn leaseDrop(store: *Store, io: Io, build_id: []const u8) StateError!void {
        return state.dropLease(io, store.dir, build_id, &store.index);
    }

    pub fn retainProject(store: *Store, io: Io, project_id: []const u8, manifests: []const Digest) StateError!void {
        try checkRootBudget(store, io, @as(u64, @intCast(project_id.len)) + @as(u64, @intCast(manifests.len)) * 96 + 256);
        return state.putRetain(io, std.heap.page_allocator, store.dir, project_id, manifests, Io.Timestamp.now(io, .real).toMilliseconds(), &store.index);
    }

    pub const Manifest = manifest_mod.Manifest;
    pub const ManifestOutput = manifest_mod.Output;
    pub const GetManifestError = ReadError || manifest_mod.DecodeError;

    pub fn putManifest(store: *Store, io: Io, man: manifest_mod.Manifest) PutError!Digest {
        const bytes = try manifest_mod.encodeAlloc(std.heap.page_allocator, man);
        defer std.heap.page_allocator.free(bytes);
        return store.putBytes(io, bytes, .manifest);
    }

    pub fn getManifest(store: *Store, io: Io, gpa: std.mem.Allocator, d: Digest) GetManifestError!manifest_mod.Manifest {
        const bytes = try store.readObject(io, d, gpa);
        defer gpa.free(bytes);
        return manifest_mod.decode(gpa, bytes);
    }

    pub const GcPolicy = gc_mod.GcPolicy;
    pub const GcReport = gc_mod.GcReport;
    pub const GcError = gc_mod.GcError;

    pub fn gc(store: *Store, io: Io, gpa: std.mem.Allocator, policy: GcPolicy) GcError!GcReport {
        return gc_mod.gc(store, io, gpa, policy);
    }

    /// Takes the exclusive GC lock. Returns false if a build holds the
    /// shared lock (spec §8.2). Callers must `unlock` after a true result.
    pub fn tryGcLock(store: *Store, io: Io) bool {
        return store.lock_file.tryLock(io, .exclusive) catch false;
    }
    pub fn unlock(store: *Store, io: Io) void {
        store.lock_file.unlock(io);
    }

    pub const ColdError = cold_mod.ColdError;

    pub fn demote(store: *Store, io: Io, d: Digest) ColdError!void {
        return cold_mod.demote(store, io, d);
    }

    pub fn promote(store: *Store, io: Io, d: Digest) ColdError!void {
        return cold_mod.promote(store, io, d);
    }

    /// Test aid: true when the hot-tier copy of an object exists.
    pub fn dirHasHot(store: *Store, io: Io, d: Digest) bool {
        return test_support.dirHasHot(store, io, d);
    }

    pub const Stats = struct {
        hot_bytes: u64,
        hot_objects: u64,
        cold_bytes: u64,
        cold_objects: u64,
        incremental_bytes: u64,
        pinned_bytes: u64,
        lease_count: u64,
        limits: config_mod.ResolvedLimits,
        free_bytes: u64,
    };

    pub const StatsError = error{Unexpected, OutOfMemory} || Io.Cancelable ||
        scan_mod.ScanError || state.StateError || disk_usage_mod.DiskUsageError || gc_mod.GcError;

    /// Tier usage vs limits, root usage, and free space (spec §9.7).
    /// Read-only: expired leases are peeked, never reaped.
    pub fn stats(store: *Store, io: Io, gpa: std.mem.Allocator) StatsError!Stats {
        var s = Stats{
            .hot_bytes = 0,
            .hot_objects = 0,
            .cold_bytes = 0,
            .cold_objects = 0,
            .incremental_bytes = 0,
            .pinned_bytes = 0,
            .lease_count = 0,
            .limits = store.limits,
            .free_bytes = 0,
        };
        const infos = try scan_mod.scan(store, io, gpa);
        defer gpa.free(infos);
        for (infos) |obj| switch (obj.tier) {
            .hot => {
                s.hot_bytes += obj.size;
                s.hot_objects += 1;
            },
            .cold => {
                s.cold_bytes += obj.size;
                s.cold_objects += 1;
            },
        };
        s.incremental_bytes = try gc_mod.incrementalBytes(store, io, gpa);
        const pins = try state.listPins(io, gpa, store.dir);
        defer state.freePins(gpa, pins);
        for (pins) |entry| {
            const d = Digest.fromHex(entry.digest_hex) catch continue;
            s.pinned_bytes += objectByteSize(store, io, d);
        }
        const now_ms = Io.Timestamp.now(io, .real).toMilliseconds();
        const leases = try state.peekLiveLeases(io, gpa, store.dir, now_ms);
        defer state.freeLeases(gpa, leases);
        s.lease_count = @intCast(leases.len);
        const usage = try disk_usage_mod.readDiskUsage(io, store.dir);
        s.free_bytes = usage.free_bytes;
        return s;
    }

    pub const ActionEntry = action_cache.ActionEntry;

    pub fn putAction(store: *Store, io: Io, key: Digest, manifest: Digest) action_cache.PutError!void {
        return action_cache.putAction(io, store.dir, key, manifest, Io.Timestamp.now(io, .real).toMilliseconds(), &store.index);
    }

    /// Storage-v2 §16 index-backed action read. v1 `getAction` delegates to it.
    pub fn lookupAction(store: *Store, io: Io, gpa: std.mem.Allocator, key: Digest) action_cache.GetError!?action_cache.ActionEntry {
        return action_cache.getAction(io, gpa, store.dir, key, &store.index);
    }

    pub fn getAction(store: *Store, io: Io, gpa: std.mem.Allocator, key: Digest) action_cache.GetError!?action_cache.ActionEntry {
        return store.lookupAction(io, gpa, key);
    }

    // Tag surface aliases live at module level (root.Tag/Predicate/
    // TagError); Store methods resolve those names directly.
    /// Storage-v2 §11.4 index admission: tag rows grow `index.sqlite`, so
    /// the index_state class (plus I-TOTAL) is checked before writing.
    /// Over cap, a best-effort `incremental_vacuum` runs first, then a
    /// spool-reserved `VACUUM` (scratch counted in spool so I-TOTAL holds
    /// through compaction); still over afterwards returns
    /// `StoreFull{ class = index_state }` with `lastFull` populated.
    pub fn tagObject(store: *Store, io: Io, d: Digest, tags: []const Tag) TagError!void {
        var estimate: u64 = 128;
        for (tags) |t| estimate += @as(u64, @intCast(t.key.len + t.value.len + 64));
        try ensureIndexStateBudget(store, io, estimate);
        const hex = d.toHex();
        return tags_mod.tagObject(&store.index, &hex, tags);
    }

    pub fn untag(store: *Store, io: Io, d: Digest, key: []const u8, value: []const u8) TagError!void {
        _ = io;
        const hex = d.toHex();
        return tags_mod.untag(&store.index, &hex, key, value);
    }

    pub fn tagsFor(store: *Store, io: Io, gpa: std.mem.Allocator, d: Digest) TagError![]Tag {
        _ = io;
        const hex = d.toHex();
        return tags_mod.tagsFor(gpa, &store.index, &hex);
    }

    /// Write-time admission (§16): reserve -> evict -> demote -> StoreFull.
    /// Thin delegates to admission.zig; breakdown carries the per-call
    /// StoreFull detail (lastFull() is the racy convenience). Plan B Task 9.
    pub fn reserve(store: *Store, io: Io, class: Class, bytes: u64, owner: ?BuildId, breakdown: ?*BudgetBreakdown) AdmitError!Reservation {
        return admission_mod.reserve(store, io, class, bytes, owner, breakdown);
    }

    /// Ledger -> file atom swap completion (never fails). Plan B Task 9.
    /// (Param is named `d`: `digest` is taken by the digest module import.)
    pub fn commit(store: *Store, io: Io, r: Reservation, d: Digest) void {
        admission_mod.commit(store, io, r, d);
    }

    /// Release a reservation without publishing (never fails). Plan B Task 9.
    pub fn abort(store: *Store, io: Io, r: Reservation) void {
        admission_mod.abort(store, io, r);
    }

    /// Last admission diagnostic on this handle (see last_breakdown).
    /// Plan B Task 9.
    pub fn lastFull(store: *Store) BudgetBreakdown {
        return store.last_breakdown;
    }

    /// Total in-flight reservation bytes across all classes (§9.3 ledger).
    /// Feeds the `stat` budget line (keeps the index module encapsulated:
    /// main.zig cannot name index free functions). Plan B Task 11.
    pub fn reservedBytes(store: *Store) index_mod.DbError!u64 {
        var total: u64 = 0;
        for ([_]index_mod.Class{ .hot, .cold, .index_state, .spool }) |c| {
            total += try index_mod.reservationSum(&store.index, c);
        }
        return total;
    }

    /// Storage-v2 §16 canonical lookup: conjunctive tag predicate, newest-first, bounded LIMIT.
    pub fn lookupObjects(store: *Store, io: Io, gpa: std.mem.Allocator, pred: Predicate) TagError![]Digest {
        _ = io;
        const hexes = try tags_mod.query(gpa, &store.index, pred);
        defer gpa.free(hexes);
        const out = try gpa.alloc(Digest, hexes.len);
        errdefer gpa.free(out);
        for (hexes, out) |h, *slot| slot.* = Digest.fromHex(&h) catch return error.Unexpected;
        return out;
    }

    /// §11.4 index_state admission for index-growing writes (tags here;
    /// roots share it via checkRootBudget below). Checks class usage plus
    /// live reservations against the index_state cap and I-TOTAL before
    /// growth. Over cap: `incremental_vacuum` first (frees freelist pages
    /// when GC churn left >1,024), then a spool-reserved `VACUUM` whose
    /// scratch copy is spool-counted (StoreFull spool if the scratch alone
    /// does not fit). Still over afterwards → StoreFull index_state with
    /// `last_breakdown` populated. Steady-state puts (one row + ≤10 tag
    /// rows) cannot hit this on any budget ≥ 5 GiB floor; the path exists
    /// so the invariant has no hole.
    fn ensureIndexStateBudget(store: *Store, io: Io, estimate: u64) TagError!void {
        const page = std.heap.page_allocator;
        const usage = budget_mod.classUsage(store, io, page) catch return error.Unexpected;
        const r_hot = index_mod.reservationSum(&store.index, .hot) catch return error.Unexpected;
        const r_cold = index_mod.reservationSum(&store.index, .cold) catch return error.Unexpected;
        const r_is = index_mod.reservationSum(&store.index, .index_state) catch return error.Unexpected;
        _ = index_mod.reservationSum(&store.index, .spool) catch return error.Unexpected;
        const used_class = usage.index_state +| r_is;
        const used_total = usage.hot +| usage.cold +| usage.index_state +| usage.spool +| r_hot +| r_cold +| r_is;
        if (used_class +| estimate <= store.budget.index_state and used_total +| estimate <= store.budget.total) return;
        // Best-effort freelist return before the heavy path.
        store.index.execAll("PRAGMA incremental_vacuum;") catch {};
        const usage2 = budget_mod.classUsage(store, io, page) catch return error.Unexpected;
        const r2 = index_mod.reservationSum(&store.index, .index_state) catch return error.Unexpected;
        const t_hot = index_mod.reservationSum(&store.index, .hot) catch return error.Unexpected;
        const t_cold = index_mod.reservationSum(&store.index, .cold) catch return error.Unexpected;
        const t_spool = index_mod.reservationSum(&store.index, .spool) catch return error.Unexpected;
        const used_c2 = usage2.index_state +| r2;
        const used_t2 = usage2.hot +| usage2.cold +| usage2.index_state +| usage2.spool +| t_hot +| t_cold +| r2;
        if (used_c2 +| estimate <= store.budget.index_state and used_t2 +| estimate <= store.budget.total) return;
        // Spool-reserved VACUUM: scratch ≈ current db file size.
        const db_size: u64 = if (store.dir.statFile(io, "index.sqlite", .{})) |st| st.size else |_| estimate;
        // Spool fast-fail mirrors admission.checkSpoolFit: a scratch copy
        // that alone exceeds the spool cap can never be staged.
        if (db_size > store.budget.spool) {
            const bd = BudgetBreakdown{
                .requested_bytes = estimate,
                .class = .spool,
                .budget = store.budget.total,
                .used_total = used_t2,
                .used_class = usage2.spool,
                .cap_class = store.budget.spool,
                .reserved_class = t_spool,
                .reclaimable_class = 0,
                .hint = .raise_budget,
            };
            store.last_breakdown = bd;
            return error.StoreFull;
        }
        const vr = store.reserve(io, .spool, db_size, null, null) catch |e| {
            if (e == error.StoreFull) return error.StoreFull;
            return error.Unexpected;
        };
        defer store.abort(io, vr);
        store.index.execAll("VACUUM;") catch {};
        store.abort(io, vr);
        const usage3 = budget_mod.classUsage(store, io, page) catch return error.Unexpected;
        const r3 = index_mod.reservationSum(&store.index, .index_state) catch return error.Unexpected;
        const hot3 = index_mod.reservationSum(&store.index, .hot) catch return error.Unexpected;
        const cold3 = index_mod.reservationSum(&store.index, .cold) catch return error.Unexpected;
        const used_c3 = usage3.index_state +| r3;
        const used_t3 = usage3.hot +| usage3.cold +| usage3.index_state +| usage3.spool +| hot3 +| cold3 +| r3;
        if (used_c3 +| estimate <= store.budget.index_state and used_t3 +| estimate <= store.budget.total) return;
        const bd = BudgetBreakdown{
            .requested_bytes = estimate,
            .class = .index_state,
            .budget = store.budget.total,
            .used_total = used_t3,
            .used_class = used_c3,
            .cap_class = store.budget.index_state,
            .reserved_class = r3,
            .reclaimable_class = 0,
            .hint = .raise_budget,
        };
        store.last_breakdown = bd;
        return error.StoreFull;
    }

    /// §9.2 root admission: pins/leases/retains count in index_state and
    /// I-TOTAL. Checks class usage plus live reservations against the
    /// budget before the JSON write; breach returns StoreFull with a
    /// populated breakdown (also in `lastFull`). No eviction is attempted
    /// (roots are never auto-evicted; index_state holds no LRU), so the
    /// hint is `raise_budget` on a class breach and `run_gc` only when
    /// total breached while the class still fits (unrooted bytes elsewhere
    /// could be reclaimed). State helpers stay low-level writers; the gate
    /// lives here where the resolved budget lives.
    fn checkRootBudget(store: *Store, io: Io, estimate: u64) StateError!void {
        const page = std.heap.page_allocator;
        const usage = budget_mod.classUsage(store, io, page) catch return error.Unexpected;
        const r_hot = index_mod.reservationSum(&store.index, .hot) catch return error.Unexpected;
        const r_cold = index_mod.reservationSum(&store.index, .cold) catch return error.Unexpected;
        const r_is = index_mod.reservationSum(&store.index, .index_state) catch return error.Unexpected;
        const used_class = usage.index_state +| r_is;
        const used_total = usage.hot +| usage.cold +| usage.index_state +| usage.spool +| r_hot +| r_cold +| r_is;
        if (used_class +| estimate <= store.budget.index_state and used_total +| estimate <= store.budget.total) return;
        const bd = BudgetBreakdown{
            .requested_bytes = estimate,
            .class = .index_state,
            .budget = store.budget.total,
            .used_total = used_total,
            .used_class = used_class,
            .cap_class = store.budget.index_state,
            .reserved_class = r_is,
            .reclaimable_class = 0,
            .hint = .raise_budget,
        };
        store.last_breakdown = bd;
        return error.StoreFull;
    }

    /// Size of either tier copy of an object; 0 when absent. Pinned-byte
    /// accounting counts cold copies at their compressed size (spec §9.4).
    fn objectByteSize(store: *Store, io: Io, d: Digest) u64 {
        var rbuf: [65]u8 = undefined;
        const rel = d.relPath(&rbuf);
        var hot_buf: [73]u8 = undefined;
        @memcpy(hot_buf[0..8], "objects/");
        @memcpy(hot_buf[8..], rel);
        if (store.dir.statFile(io, hot_buf[0..73], .{})) |st| {
            return st.size;
        } else |_| {}
        var cold_buf: [73]u8 = undefined;
        @memcpy(cold_buf[0..5], "cold/");
        @memcpy(cold_buf[5..70], rel);
        if (store.dir.statFile(io, cold_buf[0..70], .{})) |st| {
            return st.size;
        } else |_| {
            return 0;
        }
    }

    fn sweepTmp(io: Io, dir: Io.Dir) OpenError!void {
        const tmp = try dir.openDir(io, layout.tmp_dir, .{ .iterate = true });
        defer tmp.close(io);
        const now_ms = Io.Timestamp.now(io, .real).toMilliseconds();
        var it = tmp.iterate();
        while (try it.next(io)) |entry| {
            const st = tmp.statFile(io, entry.name, .{}) catch continue;
            const age_ms = now_ms - st.mtime.toMilliseconds();
            if (age_ms > std.time.ns_per_hour / std.time.ns_per_ms) {
                tmp.deleteFile(io, entry.name) catch {};
            }
        }
    }
};

test "store open creates layout and format" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);

    try std.testing.expect(ts.store.limits.hot >= 5 * config.GiB);
    const fmt = try ts.store.dir.readFileAlloc(io, "format.json", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(fmt);
    try std.testing.expect(std.mem.indexOf(u8, fmt, "\"format\":2") != null);
}

test "store open refuses unknown format version" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "format.json", .data = "{\"format\":99}" });
    try std.testing.expectError(error.UnknownFormat, Store.open(io, tmp.dir, .{}));
}

test "v2 store open wires the index" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);
    try std.testing.expect(try ts.store.index.tableExists("objects"));
}

test "pin fails StoreFull when index_state is full" {
    // §9.2 roots count: a 1 B index_state cap is already breached by the
    // real index file, so even the first pin is refused with a populated
    // breakdown instead of pushing the store over limit.
    const io = std.Io.Threaded.global_single_threaded.io();
    var ts = test_support.openTestStore(io, .{
        .budget = .{ .fixed = 10_000_000 },
        .index_state_cap = .{ .fixed = 1 },
    });
    defer ts.deinit(io);

    const d = try ts.store.putBytes(io, "rooted", .other);
    try std.testing.expectError(error.StoreFull, ts.store.pin(io, "r", d));
    try std.testing.expectEqual(Class.index_state, ts.store.lastFull().class);
}

test "tagObject fails StoreFull when index_state is full" {
    // §11.4 index admission: tag rows grow the index, so the same 1 B
    // index_state cap refuses tag growth with class index_state.
    const io = std.Io.Threaded.global_single_threaded.io();
    var ts = test_support.openTestStore(io, .{
        .budget = .{ .fixed = 10_000_000 },
        .index_state_cap = .{ .fixed = 1 },
    });
    defer ts.deinit(io);

    const d = try ts.store.putBytes(io, "tagged", .other);
    try std.testing.expectError(error.StoreFull, ts.store.tagObject(io, d, &.{.{ .key = "profile", .value = "release" }}));
}

test {
    _ = @import("digest.zig");
    _ = @import("config.zig");
    _ = @import("disk_usage.zig");
    _ = @import("layout.zig");
    _ = @import("test_support.zig");
    _ = @import("ingest.zig");
    _ = @import("objects.zig");
    _ = @import("manifest.zig");
    _ = @import("clone.zig");
    _ = @import("materialize.zig");
    _ = @import("scan.zig");
    _ = @import("state.zig");
    _ = @import("gc.zig");
    _ = @import("action_cache.zig");
    _ = @import("cold.zig");
    _ = @import("index.zig");
    _ = @import("tags.zig");
    _ = @import("migrate.zig");
    _ = @import("budget.zig");
    _ = @import("admission.zig");
    _ = @import("stats.zig");
}
