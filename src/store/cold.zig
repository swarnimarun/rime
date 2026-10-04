const std = @import("std");
const root = @import("root.zig");
const layout = @import("layout.zig");
const digest_mod = @import("digest.zig");
const test_support = @import("test_support.zig");

const Io = std.Io;
const flate = std.compress.flate;

pub const ColdError = error{
    ObjectNotFound,
    DigestMismatch,
    InvalidGzip,
    Unexpected,
    OutOfMemory,
} || Io.Cancelable || Io.Dir.ReadFileAllocError || Io.Dir.WriteFileError || Io.Dir.OpenError || Io.Dir.CreateDirPathError || Io.Dir.DeleteFileError;

/// gzip-compress in memory (level 6, `flate.Compress.Options.default`).
pub fn gzipAlloc(gpa: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, 4096);
    defer out.deinit();
    var window: [flate.max_window_len]u8 = undefined;
    var c = flate.Compress.init(&out.writer, &window, .gzip, flate.Compress.Options.default) catch return error.OutOfMemory;
    c.writer.writeAll(bytes) catch return error.OutOfMemory;
    c.finish() catch return error.OutOfMemory;
    return try out.toOwnedSlice();
}

pub fn gunzipAlloc(gpa: std.mem.Allocator, bytes: []const u8) error{OutOfMemory, InvalidGzip}![]u8 {
    var input = Io.Reader.fixed(bytes);
    var window: [flate.max_window_len]u8 = undefined;
    var d = flate.Decompress.init(&input, .gzip, &window);
    return d.reader.allocRemaining(gpa, .unlimited) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidGzip,
    };
}

/// Hot -> cold. Round-trip verified before the hot copy is deleted (spec §9.4).
/// No-op when the object is already cold-only (missing hot copy reports
/// ObjectNotFound) or when its kind is not demotable (bins stay hot).
pub fn demote(store: *root.Store, io: Io, digest: digest_mod.Digest) ColdError!void {
    // Cheap gate first: executable-ish kinds never leave hot (spec §9.4).
    if (!isDemotable(kindOf(store, io, digest))) return;

    var hot_buf: [75]u8 = undefined;
    const hot_full = objectFull(digest, &hot_buf);
    const hot_bytes = store.dir.readFileAlloc(io, hot_full, std.heap.page_allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return error.ObjectNotFound,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Unexpected,
    };
    defer std.heap.page_allocator.free(hot_bytes);

    const z = try gzipAlloc(std.heap.page_allocator, hot_bytes);
    defer std.heap.page_allocator.free(z);

    const back = try gunzipAlloc(std.heap.page_allocator, z);
    defer std.heap.page_allocator.free(back);
    if (!std.mem.eql(u8, back, hot_bytes)) return error.DigestMismatch;

    var cold_buf: [75]u8 = undefined;
    const cold_full = coldFull(digest, &cold_buf);
    try store.dir.createDirPath(io, cold_full[0..7]);
    try store.dir.writeFile(io, .{ .sub_path = cold_full, .data = z });

    store.dir.deleteFile(io, hot_full) catch {};
}

/// Cold -> hot (used by materialize when a cold object must be executed).
/// The decompressed bytes are digest-checked before the cold copy is
/// deleted, mirroring demote's verify-before-delete.
pub fn promote(store: *root.Store, io: Io, digest: digest_mod.Digest) ColdError!void {
    var cold_buf: [75]u8 = undefined;
    const cold_full = coldFull(digest, &cold_buf);
    const z = store.dir.readFileAlloc(io, cold_full, std.heap.page_allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return error.ObjectNotFound,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Unexpected,
    };
    defer std.heap.page_allocator.free(z);

    const bytes = try gunzipAlloc(std.heap.page_allocator, z);
    defer std.heap.page_allocator.free(bytes);
    if (!std.meta.eql(digest_mod.hashBytes(bytes).bytes, digest.bytes)) return error.DigestMismatch;

    var hot_buf: [75]u8 = undefined;
    const hot_full = objectFull(digest, &hot_buf);
    try store.dir.createDirPath(io, hot_full[0..10]);
    try store.dir.writeFile(io, .{ .sub_path = hot_full, .data = bytes });
    store.dir.deleteFile(io, cold_full) catch {};
}

/// Spec §9.4: executable-ish kinds stay hot.
pub fn isDemotable(kind: root.Kind) bool {
    return switch (kind) {
        .bin, .dylib => false,
        else => true,
    };
}

/// Best-effort kind lookup from the ingest journal; unknown digests default
/// to `.other` (demotable). Never fails: on any I/O or parse problem the
/// caller gets the permissive default.
fn kindOf(store: *root.Store, io: Io, digest: digest_mod.Digest) root.Kind {
    const bytes = store.dir.readFileAlloc(io, layout.state_dir ++ "/kinds.jsonl", std.heap.page_allocator, .unlimited) catch return .other;
    defer std.heap.page_allocator.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const entry = parseKindLine(line) catch continue;
        if (std.meta.eql(entry.digest, digest.bytes)) return entry.kind;
    }
    return .other;
}

const KindEntry = struct { digest: [32]u8, kind: root.Kind };

fn parseKindLine(line: []const u8) error{InvalidLine}!KindEntry {
    const d_start = std.mem.indexOf(u8, line, "\"digest\":\"") orelse return error.InvalidLine;
    const d_val = line[d_start + 10 ..];
    const d_end = std.mem.indexOfScalar(u8, d_val, '"') orelse return error.InvalidLine;
    const d = digest_mod.Digest.fromHex(d_val[0..d_end]) catch return error.InvalidLine;
    const k_start = std.mem.indexOf(u8, line, "\"kind\":\"") orelse return error.InvalidLine;
    const k_val = line[k_start + 8 ..];
    const k_end = std.mem.indexOfScalar(u8, k_val, '"') orelse return error.InvalidLine;
    const kind = std.meta.stringToEnum(root.Kind, k_val[0..k_end]) orelse return error.InvalidLine;
    return .{ .digest = d.bytes, .kind = kind };
}

/// Store-relative tier paths: "objects/ab/<hex>" / "cold/ab/<hex>" (spec §6).
fn objectFull(d: digest_mod.Digest, buf: *[75]u8) []const u8 {
    var rbuf: [67]u8 = undefined;
    const rel = d.relPath(&rbuf);
    @memcpy(buf[0..8], "objects/");
    @memcpy(buf[8..], rel);
    return buf[0..75];
}

fn coldFull(d: digest_mod.Digest, buf: *[75]u8) []const u8 {
    var rbuf: [67]u8 = undefined;
    const rel = d.relPath(&rbuf);
    @memcpy(buf[0..5], "cold/");
    @memcpy(buf[5..72], rel);
    return buf[0..72];
}

test "gzip round trip" {
    const gpa = std.testing.allocator;
    const payload = "hello rime hello rime hello rime";
    const z = try gzipAlloc(gpa, payload);
    defer gpa.free(z);
    const back = try gunzipAlloc(gpa, z);
    defer gpa.free(back);
    try std.testing.expectEqualStrings(payload, back);
}

test "demote and promote preserve object bytes" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);

    const d = try ts.store.putBytes(io, "cold-storage payload", .rlib);
    try ts.store.demote(io, d);
    try std.testing.expect(!ts.store.dirHasHot(io, d));
    try ts.store.verifyObject(io, d); // transparent read through cold tier

    const got = try ts.store.readObject(io, d, gpa);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("cold-storage payload", got);

    try ts.store.promote(io, d);
    try ts.store.verifyObject(io, d);
}

test "bins are never demoted" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);

    const d = try ts.store.putBytes(io, "executable", .bin);
    try ts.store.demote(io, d);
    try std.testing.expect(ts.store.dirHasHot(io, d));
}
