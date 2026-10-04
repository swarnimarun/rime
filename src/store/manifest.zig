const std = @import("std");
const root = @import("root.zig");
const digest_mod = @import("digest.zig");
const test_support = @import("test_support.zig");

const Io = std.Io;

pub const Output = struct {
    path: []const u8,
    digest: digest_mod.Digest,
    size: u64,
    mode: u32,
};

pub const Manifest = struct {
    format: u32 = 1,
    kind: root.Kind,
    outputs: []Output,

    pub fn deinit(man: *const Manifest, gpa: std.mem.Allocator) void {
        for (man.outputs) |o| gpa.free(o.path);
        gpa.free(man.outputs);
    }
};

const OutputJson = struct { path: []const u8, digest: []const u8, size: u64, mode: u32 };
const ManifestJson = struct { format: u32, kind: []const u8, outputs: []OutputJson };

pub const DecodeError = error{ InvalidManifest, InvalidKind, InvalidDigest, OutOfMemory };

pub fn encodeAlloc(gpa: std.mem.Allocator, man: Manifest) error{OutOfMemory}![]u8 {
    const outputs = try gpa.alloc(OutputJson, man.outputs.len);
    defer gpa.free(outputs);
    for (man.outputs, outputs) |src, *dst| {
        const hex = src.digest.toHex();
        dst.* = .{
            .path = src.path,
            .digest = try gpa.dupe(u8, hex[0..]),
            .size = src.size,
            .mode = src.mode,
        };
    }
    defer for (outputs) |o| gpa.free(o.digest);
    return std.json.Stringify.valueAlloc(gpa, ManifestJson{
        .format = man.format,
        .kind = @tagName(man.kind),
        .outputs = outputs,
    }, .{});
}

pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) DecodeError!Manifest {
    const parsed = std.json.parseFromSlice(ManifestJson, gpa, bytes, .{ .allocate = .alloc_always }) catch return error.InvalidManifest;
    defer parsed.deinit();
    const dto = parsed.value;

    const kind = std.meta.stringToEnum(root.Kind, dto.kind) orelse return error.InvalidKind;
    const outputs = try gpa.alloc(Output, dto.outputs.len);
    errdefer gpa.free(outputs);
    for (dto.outputs, outputs) |src, *dst| {
        dst.* = .{
            .path = try gpa.dupe(u8, src.path),
            .digest = digest_mod.Digest.fromHex(src.digest) catch return error.InvalidDigest,
            .size = src.size,
            .mode = src.mode,
        };
    }
    return .{ .format = dto.format, .kind = kind, .outputs = outputs };
}

test "manifest encode decode round trip" {
    const gpa = std.testing.allocator;
    const d = root.hashBytes("obj");
    var outputs = [_]Output{.{ .path = "libfoo.rlib", .digest = d, .size = 3, .mode = 420 }};
    const man = Manifest{
        .kind = .rlib,
        .outputs = &outputs,
    };
    const bytes = try encodeAlloc(gpa, man);
    defer gpa.free(bytes);
    const back = try decode(gpa, bytes);
    defer back.deinit(gpa);
    try std.testing.expectEqual(root.Kind.rlib, back.kind);
    try std.testing.expectEqual(d.bytes, back.outputs[0].digest.bytes);
    try std.testing.expectEqualStrings("libfoo.rlib", back.outputs[0].path);
}

test "putManifest getManifest round trip through the store" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);

    var outputs = [_]Output{.{ .path = "app", .digest = root.hashBytes("app"), .size = 3, .mode = 493 }};
    const man = Manifest{
        .kind = .bin,
        .outputs = &outputs,
    };
    const md = try ts.store.putManifest(io, man);
    const back = try ts.store.getManifest(io, gpa, md);
    defer back.deinit(gpa);
    try std.testing.expectEqualStrings("app", back.outputs[0].path);
}
