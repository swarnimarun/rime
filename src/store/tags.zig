const std = @import("std");
const index_mod = @import("index.zig");
const digest_mod = @import("digest.zig");

pub const Tag = struct { key: []const u8, value: []const u8 };

pub const Predicate = struct { tags: []Tag, limit: u32 = 10 };

pub const TagError = index_mod.DbError || error{ UnknownTagKey, TagMismatch, TagLimit };

const c = index_mod.c;

fn bindText(stmt: ?*c.sqlite3_stmt, col: c_int, text: []const u8) void {
    _ = c.sqlite3_bind_text(stmt, col, text.ptr, @intCast(text.len), index_mod.sqliteTransient());
}

fn isKnownKey(key: []const u8) bool {
    const fixed = [_][]const u8{ "crate", "crate_version", "toolchain", "target", "profile", "features", "project", "action" };
    for (fixed) |k| if (std.mem.eql(u8, k, key)) return true;
    return std.mem.startsWith(u8, key, "user.");
}

fn validateTags(tags: []const Tag) TagError!void {
    if (tags.len > 32) return error.TagLimit;
    var total: usize = 0;
    var has_crate = false;
    var has_crate_version = false;
    for (tags) |t| {
        if (t.key.len == 0 or t.key.len > 32 or t.value.len > 256) return error.TagLimit;
        if (std.mem.eql(u8, t.key, "kind")) return error.UnknownTagKey;
        if (!isKnownKey(t.key)) return error.UnknownTagKey;
        if (std.mem.eql(u8, t.key, "crate")) has_crate = true;
        if (std.mem.eql(u8, t.key, "crate_version")) has_crate_version = true;
        total += t.key.len + t.value.len;
    }
    if (total > 8 * 1024) return error.TagLimit;
    if (has_crate != has_crate_version) return error.TagMismatch;
}

/// §16 `tagObject`: validates per §11.3, then writes one `object_tags` row per pair.
pub fn tagObject(idx: *index_mod.Index, digest: *const [64]u8, tags: []const Tag) TagError!void {
    try validateTags(tags);
    for (tags) |t| {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(idx.db, "INSERT OR IGNORE INTO object_tags(digest,key,value) VALUES(?1,?2,?3);", -1, &stmt, null) != c.SQLITE_OK)
            return error.DbPrepare;
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, digest);
        bindText(stmt, 2, t.key);
        bindText(stmt, 3, t.value);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DbStep;
    }
}

pub fn untag(idx: *index_mod.Index, digest: *const [64]u8, key: []const u8, value: []const u8) index_mod.DbError!void {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db, "DELETE FROM object_tags WHERE digest=?1 AND key=?2 AND value=?3;", -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt, 1, digest);
    bindText(stmt, 2, key);
    bindText(stmt, 3, value);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DbStep;
}

pub fn tagsFor(gpa: std.mem.Allocator, idx: *index_mod.Index, digest: *const [64]u8) index_mod.DbError![]Tag {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db, "SELECT key,value FROM object_tags WHERE digest=?1 ORDER BY key,value;", -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt, 1, digest);
    var list: std.ArrayList(Tag) = .empty;
    errdefer {
        for (list.items) |t| {
            gpa.free(t.key);
            gpa.free(t.value);
        }
        list.deinit(gpa);
    }
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const k = try gpa.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 0)));
        errdefer gpa.free(k);
        const v = try gpa.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1)));
        try list.append(gpa, .{ .key = k, .value = v });
    }
    return try list.toOwnedSlice(gpa);
}

pub fn freeTags(gpa: std.mem.Allocator, tags: []Tag) void {
    for (tags) |t| {
        gpa.free(t.key);
        gpa.free(t.value);
    }
    gpa.free(tags);
}

/// Conjunction query: objects carrying ALL pairs, newest-first. One SELECT per pair
/// INTERSECTed and joined to `objects` for `last_access_ms DESC` + `LIMIT` (§12.1).
/// Empty filter returns newest-first up to `pred.limit` (default 10, max 1,000).
pub fn query(gpa: std.mem.Allocator, idx: *index_mod.Index, pred: Predicate) index_mod.DbError![][64]u8 {
    const filt = pred.tags;
    const limit = @min(@max(pred.limit, 1), 1000);
    if (filt.len == 0) {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(idx.db, "SELECT digest FROM objects ORDER BY last_access_ms DESC LIMIT ?1;", -1, &stmt, null) != c.SQLITE_OK)
            return error.DbPrepare;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, @intCast(limit));
        var all: std.ArrayList([64]u8) = .empty;
        errdefer all.deinit(gpa);
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            var hex: [64]u8 = undefined;
            @memcpy(&hex, std.mem.span(c.sqlite3_column_text(stmt, 0))[0..64]);
            try all.append(gpa, hex);
        }
        return try all.toOwnedSlice(gpa);
    }
    var sql_buf: [1024]u8 = undefined;
    var sql = std.Io.Writer.fixed(&sql_buf);
    for (filt, 0..) |_, i| {
        if (i > 0) sql.print(" INTERSECT ", .{}) catch return error.Unexpected;
        sql.print("SELECT digest FROM object_tags WHERE key=?{d} AND value=?{d}", .{ 2 * i + 1, 2 * i + 2 }) catch return error.Unexpected;
    }
    var sql_z: [1088]u8 = undefined;
    const z = std.fmt.bufPrintZ(&sql_z, "{s}", .{sql_buf[0..sql.end]}) catch return error.Unexpected;
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db, z.ptr, -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    for (filt, 0..) |t, i| {
        bindText(stmt, @intCast(2 * i + 1), t.key);
        bindText(stmt, @intCast(2 * i + 2), t.value);
    }
    var out: std.ArrayList([64]u8) = .empty;
    errdefer out.deinit(gpa);
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        var hex: [64]u8 = undefined;
        @memcpy(&hex, std.mem.span(c.sqlite3_column_text(stmt, 0))[0..64]);
        try out.append(gpa, hex);
    }
    return try out.toOwnedSlice(gpa);
}

test "tag query conjunction narrows results" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var idx = try index_mod.Index.open(io, tmp.dir);
    defer idx.close();

    const a: [64]u8 = [_]u8{'a'} ** 64;
    const b: [64]u8 = [_]u8{'b'} ** 64;
    try index_mod.upsertObject(&idx, .{ .digest = a, .size = 1, .compressed_size = null, .tier = .hot, .kind = "rlib", .created_ms = 1, .last_access_ms = 1 });
    try index_mod.upsertObject(&idx, .{ .digest = b, .size = 1, .compressed_size = null, .tier = .hot, .kind = "rlib", .created_ms = 1, .last_access_ms = 1 });
    try tagObject(&idx, &a, &.{ .{ .key = "crate", .value = "serde" }, .{ .key = "crate_version", .value = "1.0.200" } });
    try tagObject(&idx, &a, &.{.{ .key = "profile", .value = "release" }});
    try tagObject(&idx, &b, &.{ .{ .key = "crate", .value = "serde" }, .{ .key = "crate_version", .value = "1.0.200" } });

    var both_q = [_]Tag{.{ .key = "crate", .value = "serde" }};
    const both = try query(std.testing.allocator, &idx, .{ .tags = &both_q });
    defer std.testing.allocator.free(both);
    try std.testing.expectEqual(@as(usize, 2), both.len);

    var narrow_q = [_]Tag{
        .{ .key = "crate", .value = "serde" },
        .{ .key = "profile", .value = "release" },
    };
    const narrow = try query(std.testing.allocator, &idx, .{ .tags = &narrow_q });
    defer std.testing.allocator.free(narrow);
    try std.testing.expectEqual(@as(usize, 1), narrow.len);
    try std.testing.expectEqual(a, narrow[0]);
}

test "untag removes the pair and tagsFor lists the rest" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var idx = try index_mod.Index.open(io, tmp.dir);
    defer idx.close();

    const a: [64]u8 = [_]u8{'a'} ** 64;
    try index_mod.upsertObject(&idx, .{ .digest = a, .size = 1, .compressed_size = null, .tier = .hot, .kind = "other", .created_ms = 1, .last_access_ms = 1 });
    try tagObject(&idx, &a, &.{.{ .key = "user.custom", .value = "x" }});
    try tagObject(&idx, &a, &.{.{ .key = "user.custom", .value = "y" }});
    try untag(&idx, &a, "user.custom", "x");
    const left = try tagsFor(std.testing.allocator, &idx, &a);
    defer freeTags(std.testing.allocator, left);
    try std.testing.expectEqual(@as(usize, 1), left.len);
    try std.testing.expectEqualStrings("y", left[0].value);
}

test "tag validation rejects unknown keys, half crates, and over-limit sets" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var idx = try index_mod.Index.open(io, tmp.dir);
    defer idx.close();

    const a: [64]u8 = [_]u8{'a'} ** 64;
    try index_mod.upsertObject(&idx, .{ .digest = a, .size = 1, .compressed_size = null, .tier = .hot, .kind = "other", .created_ms = 1, .last_access_ms = 1 });
    try std.testing.expectError(error.UnknownTagKey, tagObject(&idx, &a, &.{.{ .key = "bogus", .value = "v" }}));
    try std.testing.expectError(error.UnknownTagKey, tagObject(&idx, &a, &.{.{ .key = "kind", .value = "rlib" }}));
    try std.testing.expectError(error.TagMismatch, tagObject(&idx, &a, &.{.{ .key = "crate", .value = "serde" }}));
    try std.testing.expectError(error.TagMismatch, tagObject(&idx, &a, &.{.{ .key = "crate_version", .value = "1.0" }}));
    var too_many: [33]Tag = undefined;
    for (&too_many) |*t| t.* = .{ .key = "user.k", .value = "v" };
    try std.testing.expectError(error.TagLimit, tagObject(&idx, &a, &too_many));
}
