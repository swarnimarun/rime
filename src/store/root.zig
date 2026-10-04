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
const state = @import("state.zig");
const gc_mod = @import("gc.zig");
const action_cache = @import("action_cache.zig");
const cold_mod = @import("cold.zig");

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

    pub const OpenError = error{
        UnknownFormat,
        StatFsFailed,
        Unexpected,
        OutOfMemory,
    } || Io.Cancelable || Io.Dir.CreateDirPathError || Io.File.OpenError || Io.File.Writer.Error || Io.Dir.ReadFileAllocError || Io.Dir.WriteFileError || Io.Dir.OpenError || Io.File.LockError || Io.Dir.StatFileError || Io.Dir.DeleteFileError || Io.Dir.Iterator.Error || disk_usage_mod.DiskUsageError;

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

        const usage = try disk_usage_mod.readDiskUsage(io, dir);
        return .{
            .dir = dir,
            .config = cfg,
            .limits = config_mod.resolveLimits(cfg, usage),
            .lock_file = lock,
        };
    }

    pub fn close(store: *Store, io: Io) void {
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
        return state.putPin(io, store.dir, name, d, Io.Timestamp.now(io, .real).toMilliseconds());
    }

    pub fn unpin(store: *Store, io: Io, name: []const u8) StateError!void {
        return state.removePin(io, store.dir, name);
    }

    pub fn leasePut(store: *Store, io: Io, build_id: []const u8, digests: []const Digest) StateError!void {
        return state.putLease(io, store.dir, build_id, digests, Io.Timestamp.now(io, .real).toMilliseconds());
    }

    pub fn leaseRenew(store: *Store, io: Io, build_id: []const u8) StateError!void {
        return state.renewLease(io, store.dir, build_id, Io.Timestamp.now(io, .real).toMilliseconds());
    }

    pub fn leaseDrop(store: *Store, io: Io, build_id: []const u8) StateError!void {
        return state.dropLease(io, store.dir, build_id);
    }

    pub fn retainProject(store: *Store, io: Io, project_id: []const u8, manifests: []const Digest) StateError!void {
        return state.putRetain(io, std.heap.page_allocator, store.dir, project_id, manifests, Io.Timestamp.now(io, .real).toMilliseconds());
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

    pub const ActionEntry = action_cache.ActionEntry;

    pub fn putAction(store: *Store, io: Io, key: Digest, manifest: Digest) action_cache.PutError!void {
        return action_cache.putAction(io, store.dir, key, manifest, Io.Timestamp.now(io, .real).toMilliseconds());
    }

    pub fn getAction(store: *Store, io: Io, gpa: std.mem.Allocator, key: Digest) action_cache.GetError!?action_cache.ActionEntry {
        return action_cache.getAction(io, gpa, store.dir, key);
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
}
