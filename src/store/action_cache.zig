const std = @import("std");
const root = @import("root.zig");
const layout = @import("layout.zig");
const digest_mod = @import("digest.zig");
const test_support = @import("test_support.zig");
const objects = @import("objects.zig");

const Io = std.Io;

pub const ActionEntry = struct { manifest: digest_mod.Digest, created_ms: i64 };

pub const PutError = error{Unexpected, OutOfMemory} || Io.Cancelable;
pub const GetError = error{Unexpected, OutOfMemory} || Io.Cancelable;
pub const SweepError = error{Unexpected, OutOfMemory} || Io.Cancelable || Io.Dir.Iterator.Error;

const EntryJson = struct { manifest_hex: []const u8, created_ms: i64 };

/// Store-relative entry path "actions/ab/<hex>" (spec §6; fanout mirrors objects).
fn entryFull(key: digest_mod.Digest, buf: *[75]u8) []const u8 {
    var rbuf: [67]u8 = undefined;
    const rel = layout.actionPath(key, &rbuf);
    @memcpy(buf[0..8], "actions/");
    @memcpy(buf[8..], rel);
    return buf[0..75];
}

pub fn putAction(io: Io, store_dir: Io.Dir, key: digest_mod.Digest, manifest: digest_mod.Digest, now_ms: i64) PutError!void {
    var full_buf: [75]u8 = undefined;
    const full = entryFull(key, &full_buf);
    const hex = manifest.toHex();
    const bytes = std.json.Stringify.valueAlloc(std.heap.page_allocator, EntryJson{
        .manifest_hex = hex[0..],
        .created_ms = now_ms,
    }, .{}) catch return error.OutOfMemory;
    defer std.heap.page_allocator.free(bytes);
    try writeEntryAtomic(io, store_dir, full, bytes);
}

pub fn getAction(io: Io, gpa: std.mem.Allocator, store_dir: Io.Dir, key: digest_mod.Digest) GetError!?ActionEntry {
    var full_buf: [75]u8 = undefined;
    const full = entryFull(key, &full_buf);
    const bytes = store_dir.readFileAlloc(io, full, gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Unexpected,
    };
    defer gpa.free(bytes);
    const parsed = std.json.parseFromSlice(EntryJson, gpa, bytes, .{ .allocate = .alloc_always }) catch return error.Unexpected;
    defer parsed.deinit();
    return .{
        .manifest = digest_mod.Digest.fromHex(parsed.value.manifest_hex) catch return error.Unexpected,
        .created_ms = parsed.value.created_ms,
    };
}

/// Deletes entries whose manifest object no longer exists. Returns count.
pub fn sweepStale(
    io: Io,
    gpa: std.mem.Allocator,
    store_dir: Io.Dir,
    is_present: *const fn (ctx: *anyopaque, d: digest_mod.Digest) bool,
    ctx: *anyopaque,
) SweepError!u64 {
    var removed: u64 = 0;
    const top = store_dir.openDir(io, layout.actions_dir, .{ .iterate = true }) catch return error.Unexpected;
    defer top.close(io);
    var fan = top.iterate();
    while (try fan.next(io)) |fanout| {
        if (fanout.name.len != 2) continue;
        const sub = top.openDir(io, fanout.name, .{ .iterate = true }) catch continue;
        defer sub.close(io);
        var it = sub.iterate();
        while (try it.next(io)) |entry| {
            // Entry files are named by the full 64-char hex key.
            if (entry.name.len != 64) continue;
            const key = digest_mod.Digest.fromHex(entry.name) catch continue;
            // Corrupt entries must not abort the sweep (or gc); skip them
            // like other unreadable state files. Propagate OOM/cancel.
            const got = getAction(io, gpa, store_dir, key) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                error.Unexpected => continue,
            };
            const e = got orelse continue;
            if (is_present(ctx, e.manifest)) continue;
            sub.deleteFile(io, entry.name) catch {};
            removed += 1;
        }
    }
    return removed;
}

fn writeEntryAtomic(io: Io, store_dir: Io.Dir, full: []const u8, bytes: []const u8) PutError!void {
    // Ensure the fanout dir exists (same layout rule as object publish).
    store_dir.createDirPath(io, full[0..10]) catch return error.Unexpected;
    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    const rand_hex = std.fmt.bytesToHex(rnd, .lower);
    var tmp_buf: [80]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buf, "{s}/a-{s}", .{ layout.tmp_dir, rand_hex[0..] }) catch return error.Unexpected;
    store_dir.writeFile(io, .{ .sub_path = tmp, .data = bytes }) catch return error.Unexpected;
    store_dir.rename(tmp, store_dir, full, io) catch return error.Unexpected;
}

const ExistsCtx = struct {
    store: *root.Store,
    io: std.Io,

    fn call(ctx: *anyopaque, d: root.Digest) bool {
        const self: *ExistsCtx = @ptrCast(@alignCast(ctx));
        return objects.exists(self.store, self.io, d);
    }
};

test "putAction getAction round trip" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);

    const key = root.hashBytes("action-key");
    var no_outputs: [0]root.Store.ManifestOutput = .{};
    const man = try ts.store.putManifest(io, .{ .kind = .rlib, .outputs = &no_outputs });
    try ts.store.putAction(io, key, man);
    const entry = (try ts.store.getAction(io, gpa, key)).?;
    try std.testing.expectEqual(man.bytes, entry.manifest.bytes);
}

test "sweepStale skips corrupt entries without aborting" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);

    const stale_key = root.hashBytes("corrupt-sweep-stale");
    var no_outputs: [0]root.Store.ManifestOutput = .{};
    const stale_man = try ts.store.putManifest(io, .{ .kind = .bin, .outputs = &no_outputs });
    try ts.store.putAction(io, stale_key, stale_man);

    // Delete the manifest so the valid entry is stale.
    var full_buf: [75]u8 = undefined;
    var rbuf: [67]u8 = undefined;
    const rel = stale_man.relPath(&rbuf);
    @memcpy(full_buf[0..8], "objects/");
    @memcpy(full_buf[8..], rel);
    try ts.store.dir.deleteFile(io, full_buf[0..75]);

    // Corrupt entry: valid 64-hex name, invalid JSON body.
    const corrupt_key = root.hashBytes("corrupt-sweep-bad");
    var corrupt_full: [75]u8 = undefined;
    const corrupt_path = entryFull(corrupt_key, &corrupt_full);
    try ts.store.dir.createDirPath(io, corrupt_path[0..10]);
    try ts.store.dir.writeFile(io, .{ .sub_path = corrupt_path, .data = "{not json" });

    var cb = ExistsCtx{ .store = &ts.store, .io = io };
    const removed = try sweepStale(io, gpa, ts.store.dir, ExistsCtx.call, &cb);
    try std.testing.expectEqual(@as(u64, 1), removed);
    try std.testing.expect((try ts.store.getAction(io, gpa, stale_key)) == null);
}

test "sweepStale removes entries whose manifest object is gone" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);

    const key = root.hashBytes("stale-key");
    var no_outputs: [0]root.Store.ManifestOutput = .{};
    const man = try ts.store.putManifest(io, .{ .kind = .bin, .outputs = &no_outputs });
    try ts.store.putAction(io, key, man);

    // Delete the manifest object behind the entry's back.
    var full_buf: [75]u8 = undefined;
    var rbuf: [67]u8 = undefined;
    const rel = man.relPath(&rbuf);
    @memcpy(full_buf[0..8], "objects/");
    @memcpy(full_buf[8..], rel);
    try ts.store.dir.deleteFile(io, full_buf[0..75]);

    var cb = ExistsCtx{ .store = &ts.store, .io = io };
    const removed = try sweepStale(io, gpa, ts.store.dir, ExistsCtx.call, &cb);
    try std.testing.expectEqual(@as(u64, 1), removed);
    try std.testing.expect((try ts.store.getAction(io, gpa, key)) == null);
}
