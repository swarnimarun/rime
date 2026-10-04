const std = @import("std");

pub const Digest = struct {
    bytes: [32]u8,

    pub fn toHex(d: Digest) [64]u8 {
        return std.fmt.bytesToHex(d.bytes, .lower);
    }

    pub fn fromHex(hex: []const u8) error{InvalidDigest}!Digest {
        if (hex.len != 64) return error.InvalidDigest;
        var out: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&out, hex) catch return error.InvalidDigest;
        return .{ .bytes = out };
    }

    /// Relative object path inside the store, e.g. "ab/cdef…".
    pub fn relPath(d: Digest, buf: *[67]u8) []const u8 {
        const hex = d.toHex();
        buf[0] = hex[0];
        buf[1] = hex[1];
        buf[2] = '/';
        @memcpy(buf[3..], &hex);
        return buf[0..67];
    }
};

test "digest hex round trip" {
    const d = hashBytes("hello");
    const hex = d.toHex();
    const back = try Digest.fromHex(&hex);
    try std.testing.expectEqual(d.bytes, back.bytes);
}

test "blake3 known answer for empty input" {
    const d = hashBytes("");
    try std.testing.expectEqualStrings(
        "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262",
        &d.toHex(),
    );
}

test "rel path fans out on first byte" {
    const d = hashBytes("x");
    var buf: [67]u8 = undefined;
    const p = d.relPath(&buf);
    try std.testing.expectEqual(@as(u8, '/'), p[2]);
    try std.testing.expectEqual(@as(usize, 67), p.len);
}

pub const HashFileError = std.Io.File.ReadPositionalError;

pub fn hashBytes(bytes: []const u8) Digest {
    var h = std.crypto.hash.Blake3.init(.{});
    h.update(bytes);
    var out: [32]u8 = undefined;
    h.final(&out);
    return .{ .bytes = out };
}

/// Streams the file positionally; works on any file without rewinding.
pub fn hashFile(file: std.Io.File, io: std.Io) HashFileError!Digest {
    var h = std.crypto.hash.Blake3.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = try file.readPositionalAll(io, &buf, offset);
        if (n == 0) break;
        h.update(buf[0..n]);
        offset += n;
    }
    var out: [32]u8 = undefined;
    h.final(&out);
    return .{ .bytes = out };
}
