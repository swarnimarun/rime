const std = @import("std");

const c = @cImport(@cInclude("sqlite3.h"));

const Io = std.Io;

/// Local stand-in for the C macro `SQLITE_TRANSIENT` (((sqlite3_destructor_type)-1)):
/// `@cImport` cannot translate that cast, and Zig's safe pointer casts
/// reject the unaligned -1 address, so we plant the exact bits with
/// `@memcpy` (never dereferenced — SQLite only compares the sentinel).
/// Tells SQLite to copy bound text immediately.
fn sqliteTransient() c.sqlite3_destructor_type {
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
        ) != c.SQLITE_OK) return error.DbOpen;
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
