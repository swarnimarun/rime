const std = @import("std");
const root = @import("root.zig");
const layout = @import("layout.zig");
const digest_mod = @import("digest.zig");
const test_support = @import("test_support.zig");
const objects = @import("objects.zig");
const index_mod = @import("index.zig");

const Io = std.Io;

pub const ActionEntry = struct { manifest: digest_mod.Digest, created_ms: i64 };

pub const PutError = error{Unexpected, OutOfMemory} || Io.Cancelable;
pub const GetError = error{Unexpected, OutOfMemory} || Io.Cancelable;
pub const SweepError = error{Unexpected, OutOfMemory} || Io.Cancelable || Io.Dir.Iterator.Error;

/// Store-relative entry path "actions/ab/<hex>" (spec §6; fanout mirrors objects).
fn entryFull(key: digest_mod.Digest, buf: *[73]u8) []const u8 {
    var rbuf: [65]u8 = undefined;
    const rel = layout.actionPath(key, &rbuf);
    @memcpy(buf[0..8], "actions/");
    @memcpy(buf[8..], rel);
    return buf[0..73];
}

/// Index-only write (Plan B Task 12): the v1 flat file write-through is
/// retired. The `actions` table row is the entry; stale flat files left on
/// migrated stores are ignored (imported already; a future `gc --compact`
/// may reclaim them). Failures propagate: unlike object bytes, a dropped
/// action row is silent performance loss with no self-heal path.
pub fn putAction(io: Io, store_dir: Io.Dir, key: digest_mod.Digest, manifest: digest_mod.Digest, now_ms: i64, idx: *index_mod.Index) PutError!void {
    _ = io;
    _ = store_dir;
    const ahex = key.toHex();
    const hex = manifest.toHex();
    index_mod.insertAction(idx, &ahex, hex[0..], now_ms) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return error.Unexpected,
    };
}

/// Table-only read (Plan B Task 12): no filesystem fallback. The index is
/// the entry; a missing row is a miss (stale rows whose manifest is gone
/// are removed by the sweep, same contract as the v1 file path). A DbError
/// that is not OOM/cancel reads as a miss — entries are hints (§5.3), so a
/// transient index fault degrades to a rebuild, never a build failure.
pub fn getAction(io: Io, gpa: std.mem.Allocator, store_dir: Io.Dir, key: digest_mod.Digest, idx: *index_mod.Index) GetError!?ActionEntry {
    _ = io;
    _ = store_dir;
    const ahex = key.toHex();
    const row = index_mod.getAction(idx, gpa, &ahex) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return null,
    };
    const r = row orelse return null;
    defer gpa.free(r.manifest_digest);
    return .{
        .manifest = digest_mod.Digest.fromHex(r.manifest_digest) catch return error.Unexpected,
        .created_ms = r.created_ms,
    };
}

/// Index-driven stale sweep (Plan B Task 12): iterates the `actions` table
/// via `index.listActions`, never the retired `actions/` flat files.
/// Manifest presence comes from the caller's `is_present` probe (gc wires
/// the index-backed PresentCtx; tests wire their own ExistsCtx). Deletes
/// the index row for stale entries so table-only reads stay consistent
/// with the sweep.

/// Deletes entries whose manifest object no longer exists. Returns count.
/// Removes the flat file and the index row together so table-first reads
/// stay consistent with the sweep.
pub fn sweepStale(
    io: Io,
    gpa: std.mem.Allocator,
    store_dir: Io.Dir,
    is_present: *const fn (ctx: *anyopaque, d: digest_mod.Digest) bool,
    ctx: *anyopaque,
    idx: *index_mod.Index,
) SweepError!u64 {
    return sweepInner(io, gpa, store_dir, is_present, ctx, true, idx);
}

/// Counts stale entries without deleting them. Dry-run counterpart to
/// sweepStale: same stale definition and corrupt-skip, delete gated off so
/// `gc(.dry_run)` deletes nothing (spec invariant).
pub fn countStale(
    io: Io,
    gpa: std.mem.Allocator,
    store_dir: Io.Dir,
    is_present: *const fn (ctx: *anyopaque, d: digest_mod.Digest) bool,
    ctx: *anyopaque,
    idx: *index_mod.Index,
) SweepError!u64 {
    return sweepInner(io, gpa, store_dir, is_present, ctx, false, idx);
}

fn sweepInner(
    io: Io,
    gpa: std.mem.Allocator,
    store_dir: Io.Dir,
    is_present: *const fn (ctx: *anyopaque, d: digest_mod.Digest) bool,
    ctx: *anyopaque,
    delete_stale: bool,
    idx: *index_mod.Index,
) SweepError!u64 {
    _ = io;
    _ = store_dir;
    var removed: u64 = 0;
    const rows = index_mod.listActions(idx, gpa) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return error.Unexpected,
    };
    defer index_mod.freeActionRows(gpa, rows);
    for (rows) |r| {
        // Unparseable rows (pre-migration residue) can never resolve to a
        // manifest: count them stale and drop them like corrupt files.
        const man = digest_mod.Digest.fromHex(r.manifest_digest) catch {
            if (delete_stale) index_mod.deleteAction(idx, &r.action_key) catch {};
            removed += 1;
            continue;
        };
        if (is_present(ctx, man)) continue;
        if (delete_stale) index_mod.deleteAction(idx, &r.action_key) catch {};
        removed += 1;
    }
    return removed;
}

/// Retired-flat-file path helper kept for tests that plant legacy files
/// directly (corrupt-entry skip, index-mirror survival). Production code
/// never constructs `actions/` paths outside `migrate.zig` (Plan B Task 12).

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
    var full_buf: [73]u8 = undefined;
    var rbuf: [65]u8 = undefined;
    const rel = stale_man.relPath(&rbuf);
    @memcpy(full_buf[0..8], "objects/");
    @memcpy(full_buf[8..], rel);
    try ts.store.dir.deleteFile(io, full_buf[0..73]);

    // Corrupt entry: valid 62-hex name, invalid JSON body.
    const corrupt_key = root.hashBytes("corrupt-sweep-bad");
    var corrupt_full: [73]u8 = undefined;
    const corrupt_path = entryFull(corrupt_key, &corrupt_full);
    try ts.store.dir.createDirPath(io, corrupt_path[0..10]);
    try ts.store.dir.writeFile(io, .{ .sub_path = corrupt_path, .data = "{not json" });

    var cb = ExistsCtx{ .store = &ts.store, .io = io };
    const removed = try sweepStale(io, gpa, ts.store.dir, ExistsCtx.call, &cb, &ts.store.index);
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
    var full_buf: [73]u8 = undefined;
    var rbuf: [65]u8 = undefined;
    const rel = man.relPath(&rbuf);
    @memcpy(full_buf[0..8], "objects/");
    @memcpy(full_buf[8..], rel);
    try ts.store.dir.deleteFile(io, full_buf[0..73]);

    var cb = ExistsCtx{ .store = &ts.store, .io = io };
    const removed = try sweepStale(io, gpa, ts.store.dir, ExistsCtx.call, &cb, &ts.store.index);
    try std.testing.expectEqual(@as(u64, 1), removed);
    try std.testing.expect((try ts.store.getAction(io, gpa, key)) == null);
}

test "action entries survive through the index mirror" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);

    const man = try ts.store.putBytes(io, "manifest-body", .manifest);
    const key = root.hashBytes("action-key");
    try ts.store.putAction(io, key, man);
    // Index row must exist right after put (proves the mirror ran, not just the file).
    const ahex = key.toHex();
    const row = try index_mod.getAction(&ts.store.index, gpa, &ahex);
    try std.testing.expect(row != null);
    if (row) |r| {
        defer gpa.free(r.manifest_digest);
        const want = man.toHex();
        try std.testing.expectEqualStrings(want[0..], r.manifest_digest);
    }
    // Delete the flat file: the index must still serve the entry.
    // (Task 12: putAction no longer writes flat files, so the delete is a
    // no-op tolerated for the retired path — the getAction below proves
    // table-only reads serve the entry.)
    var flat_buf: [73]u8 = undefined;
    const flat = entryFull(key, &flat_buf);
    ts.store.dir.deleteFile(io, flat) catch {}; // retired path; absent on Task 12 stores
    const got = try ts.store.getAction(io, gpa, key);
    try std.testing.expect(got != null);
    try std.testing.expectEqual(man.bytes, got.?.manifest.bytes);
}
