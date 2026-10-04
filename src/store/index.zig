const std = @import("std");

/// Shared C namespace for the vendored amalgamation. Sibling store modules
/// must alias this (`const c = index_mod.c;`) rather than running their own
/// `@cImport`: each `@cImport` evaluation mints distinct Zig types, so a
/// second import's `sqlite3_*` functions reject `Index.db` with a
/// same-spelling `expected X, found X` error.
pub const c = @cImport(@cInclude("sqlite3.h"));

const Io = std.Io;

/// Local stand-in for the C macro `SQLITE_TRANSIENT` (((sqlite3_destructor_type)-1)):
/// `@cImport` cannot translate that cast, and Zig's safe pointer casts
/// reject the unaligned -1 address, so we plant the exact bits with
/// `@memcpy` (never dereferenced — SQLite only compares the sentinel).
/// Tells SQLite to copy bound text immediately.
/// Pub so sibling store modules (which never touch `sqlite3_*` themselves
/// except through index-owned helpers... except tags.zig, which prepares
/// its own tag statements per Plan B Task 5) can bind text the same way.
pub fn sqliteTransient() c.sqlite3_destructor_type {
    var d: c.sqlite3_destructor_type = undefined;
    const bits: usize = @bitCast(@as(isize, -1));
    @memcpy(std.mem.asBytes(&d), std.mem.asBytes(&bits));
    return d;
}

pub const DbError = error{ DbOpen, DbExec, DbPrepare, DbStep, DbBusy, OutOfMemory, Unexpected } || Io.Cancelable;

pub const schema_version: u32 = 1;

/// Storage-v2 §11.2 DDL verbatim. Digests are 64-char lowercase hex `TEXT`;
/// `tier` includes 'both' for the demote/promote staging window; `STRICT` required.
/// Every connection must run `PRAGMA foreign_keys = ON;` (cascades depend on it).
pub const schema_sql: [:0]const u8 =
    \\CREATE TABLE IF NOT EXISTS objects(
    \\  digest         TEXT PRIMARY KEY CHECK(length(digest)=64),
    \\  size           INTEGER NOT NULL CHECK(size>=0),
    \\  compressed_size INTEGER NULL CHECK(compressed_size IS NULL OR compressed_size>=0),
    \\  tier           TEXT NOT NULL CHECK(tier IN ('hot','cold','both')),
    \\  kind           TEXT NOT NULL,
    \\  created_ms     INTEGER NOT NULL,
    \\  last_access_ms INTEGER NOT NULL
    \\) STRICT;
    \\CREATE TABLE IF NOT EXISTS object_tags(
    \\  digest TEXT NOT NULL REFERENCES objects(digest) ON DELETE CASCADE,
    \\  key    TEXT NOT NULL CHECK(length(key)<=32),
    \\  value  TEXT NOT NULL CHECK(length(value)<=256),
    \\  PRIMARY KEY(digest, key, value)
    \\) STRICT;
    \\CREATE TABLE IF NOT EXISTS actions(
    \\  action_key     TEXT PRIMARY KEY CHECK(length(action_key)=64),
    \\  manifest_digest TEXT NOT NULL,
    \\  created_ms     INTEGER NOT NULL
    \\) STRICT;
    \\CREATE TABLE IF NOT EXISTS pins(
    \\  name         TEXT PRIMARY KEY,
    \\  digest       TEXT NOT NULL CHECK(length(digest)=64),
    \\  created_ms   INTEGER NOT NULL
    \\) STRICT;
    \\CREATE TABLE IF NOT EXISTS leases(
    \\  build_id   TEXT PRIMARY KEY,
    \\  expires_ms INTEGER NOT NULL
    \\) STRICT;
    \\CREATE TABLE IF NOT EXISTS lease_objects(
    \\  build_id TEXT NOT NULL REFERENCES leases(build_id) ON DELETE CASCADE,
    \\  digest   TEXT NOT NULL CHECK(length(digest)=64),
    \\  PRIMARY KEY(build_id, digest)
    \\) STRICT;
    \\CREATE TABLE IF NOT EXISTS retains(
    \\  project_id   TEXT PRIMARY KEY,
    \\  updated_ms   INTEGER NOT NULL
    \\) STRICT;
    \\CREATE TABLE IF NOT EXISTS retain_manifests(
    \\  project_id TEXT NOT NULL REFERENCES retains(project_id) ON DELETE CASCADE,
    \\  manifest   TEXT NOT NULL CHECK(length(manifest)=64),
    \\  PRIMARY KEY(project_id, manifest)
    \\) STRICT;
    \\CREATE TABLE IF NOT EXISTS reservations(
    \\  reservation_id TEXT PRIMARY KEY,
    \\  class          TEXT NOT NULL CHECK(class IN ('hot','cold','index_state','spool')),
    \\  bytes          INTEGER NOT NULL CHECK(bytes>=0),
    \\  created_ms     INTEGER NOT NULL,
    \\  expires_ms     INTEGER NOT NULL,
    \\  owner_build_id TEXT NULL
    \\) STRICT;
    \\CREATE TABLE IF NOT EXISTS tag_budgets(
    \\  key          TEXT NOT NULL,
    \\  value        TEXT NOT NULL,
    \\  soft_cap     INTEGER NOT NULL CHECK(soft_cap>0),
    \\  PRIMARY KEY(key, value)
    \\) STRICT;
    \\CREATE INDEX IF NOT EXISTS idx_tags_kv ON object_tags(key, value);
    \\CREATE INDEX IF NOT EXISTS idx_tags_digest ON object_tags(digest);
    \\CREATE INDEX IF NOT EXISTS idx_objects_access ON objects(last_access_ms);
    \\CREATE INDEX IF NOT EXISTS idx_objects_tier_access ON objects(tier, last_access_ms);
    \\CREATE INDEX IF NOT EXISTS idx_reservations_expiry ON reservations(expires_ms);
    \\CREATE INDEX IF NOT EXISTS idx_leases_expiry ON leases(expires_ms);
;

pub const Index = struct {
    db: ?*c.sqlite3,

    pub const OpenError = DbError || Io.Dir.CreateDirPathError || Io.Dir.WriteFileError || Io.Dir.RealPathError;

    /// Opens (creating) `index.sqlite` at the store root, applies
    /// pragmas + schema. One handle per Store (decision D1).
    pub fn open(io: Io, store_dir: Io.Dir) OpenError!Index {
        try store_dir.createDirPath(io, ".");
        var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const dir_len = try store_dir.realPath(io, &path_buf);
        var db_path: [Io.Dir.max_path_bytes + 32]u8 = undefined;
        const full = try std.fmt.bufPrintZ(&db_path, "{s}/index.sqlite", .{path_buf[0..dir_len]});

        var db: ?*c.sqlite3 = null;
        if (c.sqlite3_open_v2(
            full.ptr,
            &db,
            c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX,
            null,
        ) != c.SQLITE_OK) {
            // SQLite allocates the handle even on failure; close(NULL) is safe.
            _ = c.sqlite3_close(db);
            return error.DbOpen;
        }
        errdefer _ = c.sqlite3_close(db);

        var idx = Index{ .db = db };
        try idx.execAll("PRAGMA journal_mode=WAL;");
        try idx.execAll("PRAGMA synchronous=NORMAL;");
        try idx.execAll("PRAGMA busy_timeout=5000;");
        try idx.execAll("PRAGMA foreign_keys=ON;");
        try idx.execAll(schema_sql);
        return idx;
    }

    pub fn close(idx: *Index) void {
        _ = c.sqlite3_close(idx.db);
        idx.db = null;
    }

    pub fn execAll(idx: *Index, sql: [:0]const u8) DbError!void {
        const rc = c.sqlite3_exec(idx.db, sql.ptr, null, null, null);
        if (rc != c.SQLITE_OK) return error.DbExec;
    }

    pub fn tableExists(idx: *Index, name: []const u8) DbError!bool {
        var name_z: [64]u8 = undefined;
        const z = std.fmt.bufPrintZ(&name_z, "{s}", .{name}) catch return error.Unexpected;
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(idx.db, "SELECT 1 FROM sqlite_master WHERE name=?1;", -1, &stmt, null) != c.SQLITE_OK)
            return error.DbPrepare;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, z.ptr, -1, sqliteTransient());
        const rc = c.sqlite3_step(stmt);
        return rc == c.SQLITE_ROW;
    }
};

pub const Tier = enum { hot, cold, both };

pub const ObjectRow = struct {
    digest: [64]u8,
    size: u64,
    compressed_size: ?u64,
    tier: Tier,
    kind: []const u8,
    created_ms: i64,
    last_access_ms: i64,
};

fn bindText(stmt: ?*c.sqlite3_stmt, col: c_int, text: []const u8) void {
    _ = c.sqlite3_bind_text(stmt, col, text.ptr, @intCast(text.len), sqliteTransient());
}

/// INSERT ... ON CONFLICT DO UPDATE: ingest is idempotent, so re-put of the same digest
/// refreshes size/tier/kind but never duplicates the row. ON CONFLICT preserves
/// object_tags rows; INSERT OR REPLACE would delete + re-insert and cascade-wipe tags.
pub fn upsertObject(idx: *Index, row: ObjectRow) DbError!void {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db,
        "INSERT INTO objects(digest,size,compressed_size,tier,kind,created_ms,last_access_ms)" ++
        " VALUES(?1,?2,?3,?4,?5,?6,?7)" ++
        " ON CONFLICT(digest) DO UPDATE SET size=excluded.size,compressed_size=excluded.compressed_size," ++
        "tier=excluded.tier,kind=excluded.kind,created_ms=excluded.created_ms,last_access_ms=excluded.last_access_ms;", -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt, 1, &row.digest);
    _ = c.sqlite3_bind_int64(stmt, 2, @intCast(row.size));
    if (row.compressed_size) |cs| {
        _ = c.sqlite3_bind_int64(stmt, 3, @intCast(cs));
    } else {
        _ = c.sqlite3_bind_null(stmt, 3);
    }
    bindText(stmt, 4, if (row.tier == .hot) "hot" else if (row.tier == .cold) "cold" else "both");
    bindText(stmt, 5, row.kind);
    _ = c.sqlite3_bind_int64(stmt, 6, row.created_ms);
    _ = c.sqlite3_bind_int64(stmt, 7, row.last_access_ms);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DbStep;
}

pub fn touchObject(idx: *Index, digest: *const [64]u8, now_ms: i64) DbError!void {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db,
        "UPDATE objects SET last_access_ms=?1 WHERE digest=?2;", -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, now_ms);
    bindText(stmt, 2, digest);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DbStep;
}

/// Oldest-first candidate rows for one tier (null tier = both tiers).
/// Caller frees the slice with freeRows (per-row kind strings are duped).
pub fn lruCandidates(idx: *Index, gpa: std.mem.Allocator, tier: ?Tier, limit: u32) DbError![]ObjectRow {
    const sql: [:0]const u8 = if (tier == null)
        "SELECT digest,size,compressed_size,tier,kind,created_ms,last_access_ms FROM objects ORDER BY last_access_ms ASC LIMIT ?1;"
    else
        "SELECT digest,size,compressed_size,tier,kind,created_ms,last_access_ms FROM objects WHERE tier=?2 ORDER BY last_access_ms ASC LIMIT ?1;";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db, sql.ptr, -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, @intCast(limit));
    if (tier) |t| bindText(stmt, 2, if (t == .hot) "hot" else if (t == .cold) "cold" else "both");

    var list: std.ArrayList(ObjectRow) = .empty;
    errdefer {
        for (list.items) |r| gpa.free(r.kind);
        list.deinit(gpa);
    }
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        var row = ObjectRow{
            .digest = undefined,
            .size = @intCast(c.sqlite3_column_int64(stmt, 1)),
            .compressed_size = if (c.sqlite3_column_type(stmt, 2) == c.SQLITE_NULL)
                null
            else
                @intCast(c.sqlite3_column_int64(stmt, 2)),
            .tier = if (std.mem.eql(u8, std.mem.span(c.sqlite3_column_text(stmt, 3)), "hot")) .hot else if (std.mem.eql(u8, std.mem.span(c.sqlite3_column_text(stmt, 3)), "cold")) .cold else .both,
            .kind = "",
            .created_ms = c.sqlite3_column_int64(stmt, 5),
            .last_access_ms = c.sqlite3_column_int64(stmt, 6),
        };
        const hex_ptr = c.sqlite3_column_text(stmt, 0);
        @memcpy(&row.digest, std.mem.span(hex_ptr)[0..64]);
        row.kind = try gpa.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 4)));
        // NOTE: kind strings are one dupe per row; freed by freeRows below.
        list.append(gpa, row) catch |append_err| {
            gpa.free(row.kind);
            return append_err;
        };
    }
    return try list.toOwnedSlice(gpa);
}

/// Frees a slice from lruCandidates (including per-row kind dupes).
pub fn freeRows(gpa: std.mem.Allocator, rows: []ObjectRow) void {
    for (rows) |r| gpa.free(r.kind);
    gpa.free(rows);
}

pub fn objectCount(idx: *Index) DbError!u64 {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db, "SELECT COUNT(*) FROM objects;", -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.DbStep;
    return @intCast(c.sqlite3_column_int64(stmt, 0));
}

pub fn deleteObject(idx: *Index, digest: *const [64]u8) DbError!void {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db, "DELETE FROM objects WHERE digest=?1;", -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt, 1, digest);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DbStep;
}

pub fn setTier(idx: *Index, digest: *const [64]u8, tier: Tier, compressed_size: ?u64) DbError!void {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db,
        "UPDATE objects SET tier=?1, compressed_size=?2 WHERE digest=?3;", -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt, 1, if (tier == .hot) "hot" else if (tier == .cold) "cold" else "both");
    if (compressed_size) |cs| {
        _ = c.sqlite3_bind_int64(stmt, 2, @intCast(cs));
    } else {
        _ = c.sqlite3_bind_null(stmt, 2);
    }
    bindText(stmt, 3, digest);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DbStep;
}

/// Null when the digest is not indexed. Caller frees `row.kind` with `gpa.free`.
pub fn getObject(idx: *Index, gpa: std.mem.Allocator, digest: *const [64]u8) DbError!?ObjectRow {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db,
        "SELECT size,compressed_size,tier,kind,created_ms,last_access_ms FROM objects WHERE digest=?1;",
        -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt, 1, digest);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    return ObjectRow{
        .digest = digest.*,
        .size = @intCast(c.sqlite3_column_int64(stmt, 0)),
        .compressed_size = if (c.sqlite3_column_type(stmt, 1) == c.SQLITE_NULL)
            null
        else
            @intCast(c.sqlite3_column_int64(stmt, 1)),
        .tier = if (std.mem.eql(u8, std.mem.span(c.sqlite3_column_text(stmt, 2)), "hot")) .hot else if (std.mem.eql(u8, std.mem.span(c.sqlite3_column_text(stmt, 2)), "cold")) .cold else .both,
        .kind = try gpa.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 3))),
        .created_ms = c.sqlite3_column_int64(stmt, 4),
        .last_access_ms = c.sqlite3_column_int64(stmt, 5),
    };
}

test "index opens inside a store dir and creates the schema" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var idx = try Index.open(io, tmp.dir);
    defer idx.close();
    try std.testing.expect(try idx.tableExists("objects"));
    try std.testing.expect(try idx.tableExists("object_tags"));
    try std.testing.expect(try idx.tableExists("actions"));
    try std.testing.expect(try idx.tableExists("pins"));
    try std.testing.expect(try idx.tableExists("leases"));
    try std.testing.expect(try idx.tableExists("lease_objects"));
    try std.testing.expect(try idx.tableExists("retains"));
    try std.testing.expect(try idx.tableExists("retain_manifests"));
    try std.testing.expect(try idx.tableExists("reservations"));
    try std.testing.expect(try idx.tableExists("tag_budgets"));
}

test "index reopen is idempotent (IF NOT EXISTS)" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var a = try Index.open(io, tmp.dir);
    a.close();
    var b = try Index.open(io, tmp.dir);
    defer b.close();
    try std.testing.expect(try b.tableExists("objects"));
}

test "upsert then lru order follows last_access" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var idx = try Index.open(io, tmp.dir);
    defer idx.close();

    try upsertObject(&idx, .{
        .digest = [_]u8{'a'} ** 64,
        .size = 10,
        .compressed_size = null,
        .tier = .hot,
        .kind = "rlib",
        .created_ms = 1000,
        .last_access_ms = 3000,
    });
    try upsertObject(&idx, .{
        .digest = [_]u8{'b'} ** 64,
        .size = 20,
        .compressed_size = null,
        .tier = .hot,
        .kind = "bin",
        .created_ms = 1000,
        .last_access_ms = 1000,
    });
    const rows = try lruCandidates(&idx, std.testing.allocator, .hot, 10);
    defer freeRows(std.testing.allocator, rows);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqual([_]u8{'b'} ** 64, rows[0].digest);
    try std.testing.expectEqual(@as(u64, 2), try objectCount(&idx));
}

test "touchObject moves the row to the back of lru" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var idx = try Index.open(io, tmp.dir);
    defer idx.close();

    try upsertObject(&idx, .{
        .digest = [_]u8{'c'} ** 64,
        .size = 5,
        .compressed_size = null,
        .tier = .cold,
        .kind = "other",
        .created_ms = 1000,
        .last_access_ms = 1000,
    });
    const digest_c: [64]u8 = [_]u8{'c'} ** 64;
    try touchObject(&idx, &digest_c, 9999);
    const rows = try lruCandidates(&idx, std.testing.allocator, .cold, 10);
    defer freeRows(std.testing.allocator, rows);
    try std.testing.expectEqual(@as(i64, 9999), rows[0].last_access_ms);
}

test "deleteObject and setTier round trip" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var idx = try Index.open(io, tmp.dir);
    defer idx.close();

    const digest_d: [64]u8 = [_]u8{'d'} ** 64;
    try upsertObject(&idx, .{
        .digest = digest_d,
        .size = 100,
        .compressed_size = null,
        .tier = .hot,
        .kind = "obj",
        .created_ms = 1000,
        .last_access_ms = 1000,
    });
    try setTier(&idx, &digest_d, .cold, 30);
    const got = try getObject(&idx, std.testing.allocator, &digest_d);
    try std.testing.expect(got != null);
    defer if (got) |r| std.testing.allocator.free(r.kind);
    try std.testing.expect(got.?.tier == .cold);
    try std.testing.expectEqual(@as(?u64, 30), got.?.compressed_size);
    try deleteObject(&idx, &digest_d);
    const gone = try getObject(&idx, std.testing.allocator, &digest_d);
    try std.testing.expect(gone == null);
}
