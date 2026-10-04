const std = @import("std");
const digest = @import("digest.zig");
const config_mod = @import("config.zig");
const disk_usage_mod = @import("disk_usage.zig");
const layout = @import("layout.zig");
const test_support = @import("test_support.zig");
const ingest = @import("ingest.zig");

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
}
