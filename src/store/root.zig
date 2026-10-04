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
const gc_mod = @import("gc.zig");
const action_cache = @import("action_cache.zig");
const cold_mod = @import("cold.zig");
const index_mod = @import("index.zig");
const tags_mod = @import("tags.zig");

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

pub const Store = struct {
    dir: Io.Dir,
    config: config_mod.Config,
    limits: config_mod.ResolvedLimits,
    lock_file: Io.File,
    index: index_mod.Index,

    pub const OpenError = error{
        UnknownFormat,
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

        // format.json: create or validate.
        if (dir.readFileAlloc(io, layout.format_file, std.heap.page_allocator, .unlimited)) |bytes| {
            defer std.heap.page_allocator.free(bytes);
            const parsed = std.json.parseFromSlice(
                layout.FormatJson,
                std.heap.page_allocator,
                bytes,
                .{},
            ) catch return error.UnknownFormat;
            defer parsed.deinit();
            if (parsed.value.format != layout.format_version) return error.UnknownFormat;
        } else |err| switch (err) {
            error.FileNotFound => try dir.writeFile(io, .{
                .sub_path = layout.format_file,
                .data = "{\"format\":1}\n",
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
        return .{
            .dir = dir,
            .config = cfg,
            .limits = config_mod.resolveLimits(cfg, usage),
            .lock_file = lock,
            .index = index,
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
        return state.putPin(io, store.dir, name, d, Io.Timestamp.now(io, .real).toMilliseconds(), &store.index);
    }

    pub fn unpin(store: *Store, io: Io, name: []const u8) StateError!void {
        return state.removePin(io, store.dir, name, &store.index);
    }

    pub fn leasePut(store: *Store, io: Io, build_id: []const u8, digests: []const Digest) StateError!void {
        return state.putLease(io, store.dir, build_id, digests, Io.Timestamp.now(io, .real).toMilliseconds(), &store.index);
    }

    pub fn leaseRenew(store: *Store, io: Io, build_id: []const u8) StateError!void {
        return state.renewLease(io, store.dir, build_id, Io.Timestamp.now(io, .real).toMilliseconds(), &store.index);
    }

    pub fn leaseDrop(store: *Store, io: Io, build_id: []const u8) StateError!void {
        return state.dropLease(io, store.dir, build_id, &store.index);
    }

    pub fn retainProject(store: *Store, io: Io, project_id: []const u8, manifests: []const Digest) StateError!void {
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

    pub const Tag = tags_mod.Tag;
    pub const Predicate = tags_mod.Predicate;
    pub const TagError = tags_mod.TagError;

    pub fn tagObject(store: *Store, io: Io, d: Digest, tags: []const Tag) TagError!void {
        _ = io;
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

    /// Storage-v2 §16 canonical lookup: conjunctive tag predicate, newest-first, bounded LIMIT.
    pub fn lookupObjects(store: *Store, io: Io, gpa: std.mem.Allocator, pred: Predicate) TagError![]Digest {
        _ = io;
        const hexes = try tags_mod.query(gpa, &store.index, pred);
        defer gpa.free(hexes);
        const out = try gpa.alloc(Digest, hexes.len);
        errdefer gpa.free(out);
        for (hexes, out) |h, slot| slot.* = Digest.fromHex(&h) catch return error.Unexpected;
        return out;
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
    try std.testing.expect(std.mem.indexOf(u8, fmt, "\"format\"") != null);
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
}
