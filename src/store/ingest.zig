const std = @import("std");
const root = @import("root.zig");
const layout = @import("layout.zig");
const digest_mod = @import("digest.zig");
const test_support = @import("test_support.zig");
const index_mod = @import("index.zig");
const admission_mod = @import("admission.zig");

const Io = std.Io;
const Digest = digest_mod.Digest;

/// StoreFull is new in v2 (additive): admission refuses the put when
/// eviction + demotion cannot free a full reservation (storage-v2 §10).
/// The admission error constituents ride along so reserve/checkSpoolFit
/// failures surface honestly; lastFull()/breakdown carry the detail.
/// Plan B Task 9. v1 signatures are unchanged (no new parameters).
pub const PutError = error{
    DigestMismatch,
    Unexpected,
    OutOfMemory,
} || admission_mod.AdmitError || Io.Dir.StatFileError || Io.File.OpenError || Io.File.Writer.Error || Io.File.SyncError || Io.File.SetPermissionsError || Io.Dir.RenameError || Io.Dir.CreateDirPathError || Io.File.LengthError || Io.File.WritePositionalError || digest_mod.HashFileError;

const object_mode: Io.File.Permissions = .fromMode(0o444);
const store_gpa = std.heap.page_allocator;

/// Index mirror (Plan B Task 6): every published object gets an `objects` row
/// (hot tier, `created_ms = last_access_ms = now`). Best-effort: the bytes
/// are authoritative, the index rebuildable, so ingest never fails on index
/// errors. Dedup fast paths re-upsert (refreshing size/tier/kind and
/// `last_access_ms`); the upsert doubles as self-heal for rows lost to a
/// deleted or pre-index store.
fn indexUpsert(store: *root.Store, io: Io, d: Digest, size: u64, kind: root.Kind) void {
    const now_ms = Io.Timestamp.now(io, .real).toMilliseconds();
    const hex = d.toHex();
    index_mod.upsertObject(&store.index, .{
        .digest = hex,
        .size = size,
        .compressed_size = null,
        .tier = .hot,
        .kind = @tagName(kind),
        .created_ms = now_ms,
        .last_access_ms = now_ms,
    }) catch {};
}

/// Publishes `bytes` as an immutable object. Idempotent: if the object
/// already exists the temp file is discarded. Spec §8.1.
pub fn putBytes(store: *root.Store, io: Io, bytes: []const u8, kind: root.Kind) PutError!Digest {
    const d = digest_mod.hashBytes(bytes);

    var path_buf: [73]u8 = undefined;
    const full = objectFull(d, &path_buf);

    // Fast path: already present. A dedup hit is a cache hit: refresh LRU
    // (spec §9.2) instead of rewriting identical bytes.
    if (store.dir.statFile(io, full, .{})) |st| {
        store.touch(io, d);
        indexUpsert(store, io, d, st.size, kind);
        return d;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return error.Unexpected,
    }

    // Cold-only hit: promote back to hot rather than duplicating tiers.
    // A missing or unreadable cold copy falls through to a normal store.
    store.promote(io, d) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
    if (store.dir.statFile(io, full, .{})) |st| {
        store.touch(io, d);
        indexUpsert(store, io, d, st.size, kind);
        return d;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return error.Unexpected,
    }

    // Admission (§10.1): spool fast-fail, then reserve hot before writing.
    // The dedup hits above took the reservation-free fast path (§10.5).
    // Staging double-count note: the hot ledger row plus the tmp file (seen
    // by the spool walk) count the same bytes twice during the staging
    // window. That errs toward early StoreFull, never toward breaching
    // I-TOTAL. Plan B Task 9.
    try admission_mod.checkSpoolFit(store, io, bytes.len);
    const r = try admission_mod.reserve(store, io, .hot, bytes.len, null, null);
    errdefer admission_mod.abort(store, io, r);

    const tmp_name = try newTmpName(io);
    const tmp = try store.dir.createFile(io, tmp_name, .{ .exclusive = true });
    defer tmp.close(io);
    try tmp.writeStreamingAll(io, bytes);
    try tmp.sync(io);
    try tmp.setPermissions(io, object_mode);
    try publish(store, io, tmp_name, full);
    indexUpsert(store, io, d, bytes.len, kind);
    admission_mod.commit(store, io, r, d);
    return d;
}

/// Streams `src` to a temp file while hashing, then publishes under the hash.
/// `src` is read positionally, so its seek position is irrelevant.
pub fn putFile(store: *root.Store, io: Io, src: Io.File, kind: root.Kind) PutError!Digest {
    // Spool fast-fail before staging anything: a source that alone exceeds
    // spool_cap can never be admitted (§10.2). Unknown lengths (length
    // errors) skip the pre-check; the exact post-stream check below still
    // applies. Plan B Task 9.
    const staged_hint: ?u64 = src.length(io) catch null;
    if (staged_hint) |n| try admission_mod.checkSpoolFit(store, io, n);

    var h = std.crypto.hash.Blake3.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;

    const tmp_name = try newTmpName(io);
    const tmp = try store.dir.createFile(io, tmp_name, .{ .read = true, .exclusive = true });
    defer tmp.close(io);

    while (true) {
        const n = try src.readPositionalAll(io, &buf, offset);
        if (n == 0) break;
        h.update(buf[0..n]);
        try tmp.writeStreamingAll(io, buf[0..n]);
        offset += n;
    }
    try tmp.sync(io);
    try tmp.setPermissions(io, object_mode);

    var out: [32]u8 = undefined;
    h.final(&out);
    const d: Digest = .{ .bytes = out };

    var path_buf: [73]u8 = undefined;
    const full = objectFull(d, &path_buf);
    // Dedup hit: the tmp copy is redundant. Drop it and refresh LRU
    // (spec §9.2) instead of rewriting identical bytes; a cold-only hit
    // promotes back to hot rather than duplicating tiers.
    const hot_present = if (store.dir.statFile(io, full, .{})) |_| true else |err| switch (err) {
        error.FileNotFound => false,
        else => return error.Unexpected,
    };
    if (!hot_present) {
        store.promote(io, d) catch |perr| switch (perr) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {}, // absent/unreadable cold copy; publish below
        };
    }
    if (store.dir.statFile(io, full, .{})) |st| {
        store.dir.deleteFile(io, tmp_name) catch {};
        store.touch(io, d);
        indexUpsert(store, io, d, st.size, kind);
        return d;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return error.Unexpected,
    }
    // Admission on the exact streamed size (known only now). The staged tmp
    // file is visible to the spool walk during reserve, so the check is
    // conservative (see the staging note in putBytes). A failed reserve
    // deletes the staged tmp so the op leaves no residue. Plan B Task 9.
    admission_mod.checkSpoolFit(store, io, offset) catch |err| {
        store.dir.deleteFile(io, tmp_name) catch {};
        return err;
    };
    const r = admission_mod.reserve(store, io, .hot, offset, null, null) catch |err| {
        store.dir.deleteFile(io, tmp_name) catch {};
        return err;
    };
    errdefer admission_mod.abort(store, io, r);
    try publish(store, io, tmp_name, full);
    indexUpsert(store, io, d, offset, kind);
    admission_mod.commit(store, io, r, d);
    return d;
}

fn newTmpName(io: Io) PutError![]const u8 {
    var rnd: [12]u8 = undefined;
    io.random(&rnd);
    const hex = std.fmt.bytesToHex(rnd, .lower);
    return std.fmt.allocPrint(store_gpa, layout.tmp_dir ++ "/{s}", .{hex[0..]}) catch error.OutOfMemory;
}

fn publish(store: *root.Store, io: Io, tmp_name: []const u8, full: []const u8) PutError!void {
    // Ensure the fanout dir exists (spec §6 layout).
    try store.dir.createDirPath(io, full[0..10]);
    store.dir.rename(tmp_name, store.dir, full, io) catch |err| switch (err) {
        error.FileNotFound => {}, // lost the race to an identical object; tmp is gone
        else => return error.Unexpected,
    };
}

/// Store-relative object path: "objects/<hex[0..2]>/<hex[2..]>"
/// (spec §5.1, §6). layout.objectPath returns the fanout-relative part.
fn objectFull(d: digest_mod.Digest, buf: *[73]u8) []const u8 {
    var rbuf: [65]u8 = undefined;
    const rel = d.relPath(&rbuf);
    @memcpy(buf[0..8], "objects/");
    @memcpy(buf[8..], rel);
    return buf[0..73];
}

test "putBytes is idempotent and read-only" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);

    const d1 = try ts.store.putBytes(io, "artifact bytes", .other);
    const d2 = try ts.store.putBytes(io, "artifact bytes", .other);
    try std.testing.expectEqual(d1.bytes, d2.bytes);

    var buf: [73]u8 = undefined;
    const st = try ts.store.dir.statFile(io, objectFull(d1, &buf), .{});
    try std.testing.expect(st.size == "artifact bytes".len);
    try std.testing.expect(st.permissions.toMode() & 0o777 == 0o444);
}

test "putFile hashes the whole file and dedups" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);

    const src = try ts.store.dir.createFile(io, "src.bin", .{ .read = true });
    defer {
        src.close(io);
        ts.store.dir.deleteFile(io, "src.bin") catch {};
    }
    try src.writeStreamingAll(io, "same bytes");

    const d1 = try ts.store.putFile(io, src, .rlib);
    const d2 = try ts.store.putBytes(io, "same bytes", .rlib);
    try std.testing.expectEqual(d1.bytes, d2.bytes);
}

fn backdate(io: std.Io, store: *root.Store, d: Digest) !void {
    var buf: [73]u8 = undefined;
    const f = try store.dir.openFile(io, objectFull(d, &buf), .{});
    defer f.close(io);
    try f.setTimestamps(io, .{ .modify_timestamp = .{ .new = .fromNanoseconds(1_000_000_000) } });
}

test "putBytes dedup hit refreshes LRU" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);

    const d = try ts.store.putBytes(io, "hot again", .other);
    // Age the object past the touch throttle, then re-put identical bytes.
    try backdate(io, &ts.store, d);
    const d2 = try ts.store.putBytes(io, "hot again", .other);
    try std.testing.expectEqual(d.bytes, d2.bytes);

    var buf: [73]u8 = undefined;
    const st = try ts.store.dir.statFile(io, objectFull(d, &buf), .{});
    try std.testing.expect(st.mtime.toMilliseconds() > 60_000);
}

test "putBytes cold hit promotes back to hot" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);

    const d = try ts.store.putBytes(io, "returning", .other);
    try ts.store.demote(io, d);
    try std.testing.expect(!ts.store.dirHasHot(io, d));

    const d2 = try ts.store.putBytes(io, "returning", .other);
    try std.testing.expectEqual(d.bytes, d2.bytes);
    try std.testing.expect(ts.store.dirHasHot(io, d));
    // Exactly one tier copy, still intact.
    const infos = try ts.store.scan(io, gpa);
    defer gpa.free(infos);
    try std.testing.expectEqual(@as(usize, 1), infos.len);
    try std.testing.expect(infos[0].tier == .hot);
}

test "putFile dedup hit refreshes LRU without rewrite" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);

    const src = try ts.store.dir.createFile(io, "src.bin", .{ .read = true });
    defer {
        src.close(io);
        ts.store.dir.deleteFile(io, "src.bin") catch {};
    }
    try src.writeStreamingAll(io, "same bytes");

    const d1 = try ts.store.putFile(io, src, .rlib);
    try backdate(io, &ts.store, d1);
    const d2 = try ts.store.putFile(io, src, .rlib);
    try std.testing.expectEqual(d1.bytes, d2.bytes);

    var buf: [73]u8 = undefined;
    const st = try ts.store.dir.statFile(io, objectFull(d1, &buf), .{});
    try std.testing.expect(st.mtime.toMilliseconds() > 60_000);
    try ts.store.verifyObject(io, d1);
}

test "crash window: tmp files are never objects" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);

    try ts.store.dir.writeFile(io, .{ .sub_path = "tmp/leftover", .data = "partial" });
    const d = try ts.store.putBytes(io, "whole", .other);
    // The leftover tmp file is untouched and the published object exists.
    const leftover = try ts.store.dir.readFileAlloc(io, "tmp/leftover", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(leftover);
    try std.testing.expectEqualStrings("partial", leftover);
    var buf: [73]u8 = undefined;
    _ = try ts.store.dir.statFile(io, objectFull(d, &buf), .{});
}

test "ingest writes no journal file" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);

    _ = try ts.store.putBytes(io, "no journal", .rlib);
    try std.testing.expectError(error.FileNotFound, ts.store.dir.statFile(io, "state/kinds.jsonl", .{}));
}
