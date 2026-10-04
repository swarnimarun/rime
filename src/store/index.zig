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

/// One `INSERT OR REPLACE INTO actions(action_key, manifest_digest, created_ms)`
/// prepared statement. Manifest digests are hints (§5.3): no FK, stale rows
/// are found by absence.
pub fn insertAction(idx: *Index, action_key: *const [64]u8, manifest_digest: []const u8, created_ms: i64) DbError!void {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db,
        "INSERT OR REPLACE INTO actions(action_key,manifest_digest,created_ms) VALUES(?1,?2,?3);",
        -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt, 1, action_key);
    bindText(stmt, 2, manifest_digest);
    _ = c.sqlite3_bind_int64(stmt, 3, created_ms);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DbStep;
}

pub fn deleteAction(idx: *Index, action_key: *const [64]u8) DbError!void {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db, "DELETE FROM actions WHERE action_key=?1;", -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt, 1, action_key);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DbStep;
}

pub const ActionRow = struct { manifest_digest: []u8, created_ms: i64 };

/// Null when the action key is not indexed. Caller frees `row.manifest_digest`.
pub fn getAction(idx: *Index, gpa: std.mem.Allocator, action_key: *const [64]u8) DbError!?ActionRow {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db,
        "SELECT manifest_digest,created_ms FROM actions WHERE action_key=?1;",
        -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt, 1, action_key);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    return ActionRow{
        .manifest_digest = try gpa.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 0))),
        .created_ms = c.sqlite3_column_int64(stmt, 1),
    };
}

/// One actions-table row for the stale sweep (Plan B Task 12): the sweep
/// iterates the index, never the retired `actions/` flat files. Owned
/// manifest_digest strings; caller frees via freeActionRows.
/// Manifest digests may be short/invalid (pre-migration residue); the
/// caller skips unparseable rows, same leniency as the old file walk.
/// Only index.zig calls sqlite3_* directly.
pub const ActionKeyRow = struct { action_key: [64]u8, manifest_digest: []u8, created_ms: i64 };

pub fn listActions(idx: *Index, gpa: std.mem.Allocator) DbError![]ActionKeyRow {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db,
        "SELECT action_key,manifest_digest,created_ms FROM actions;",
        -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    var list: std.ArrayList(ActionKeyRow) = .empty;
    errdefer {
        for (list.items) |r| gpa.free(r.manifest_digest);
        list.deinit(gpa);
    }
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        var key: [64]u8 = undefined;
        @memcpy(&key, std.mem.span(c.sqlite3_column_text(stmt, 0))[0..64]);
        const m = try gpa.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1)));
        list.append(gpa, .{
            .action_key = key,
            .manifest_digest = m,
            .created_ms = c.sqlite3_column_int64(stmt, 2),
        }) catch |append_err| {
            gpa.free(m);
            return append_err;
        };
    }
    return try list.toOwnedSlice(gpa);
}

pub fn freeActionRows(gpa: std.mem.Allocator, rows: []ActionKeyRow) void {
    for (rows) |r| gpa.free(r.manifest_digest);
    gpa.free(rows);
}

/// Pins mirror: JSON stays authoritative (decision D4); the row is rewritten
/// in the same call. No children, so REPLACE is cascade-safe.
pub fn insertPin(idx: *Index, name: []const u8, digest_hex: []const u8, created_ms: i64) DbError!void {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db,
        "INSERT OR REPLACE INTO pins(name,digest,created_ms) VALUES(?1,?2,?3);",
        -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt, 1, name);
    bindText(stmt, 2, digest_hex);
    _ = c.sqlite3_bind_int64(stmt, 3, created_ms);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DbStep;
}

pub fn deletePin(idx: *Index, name: []const u8) DbError!void {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db, "DELETE FROM pins WHERE name=?1;", -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt, 1, name);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DbStep;
}

/// Lease mirror. Callers always follow `insertLease` with a full member
/// rewrite (`deleteLeaseObjects` + one `insertLeaseObject` per member):
/// REPLACE on the parent would cascade-wipe members, so the member list is
/// re-asserted in the same call and never trusted across calls.
pub fn insertLease(idx: *Index, build_id: []const u8, expires_ms: i64) DbError!void {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db,
        "INSERT OR REPLACE INTO leases(build_id,expires_ms) VALUES(?1,?2);",
        -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt, 1, build_id);
    _ = c.sqlite3_bind_int64(stmt, 2, expires_ms);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DbStep;
}

pub fn deleteLease(idx: *Index, build_id: []const u8) DbError!void {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db, "DELETE FROM leases WHERE build_id=?1;", -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt, 1, build_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DbStep;
}

pub fn insertLeaseObject(idx: *Index, build_id: []const u8, digest_hex: []const u8) DbError!void {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db,
        "INSERT OR IGNORE INTO lease_objects(build_id,digest) VALUES(?1,?2);",
        -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt, 1, build_id);
    bindText(stmt, 2, digest_hex);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DbStep;
}

pub fn deleteLeaseObjects(idx: *Index, build_id: []const u8) DbError!void {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db, "DELETE FROM lease_objects WHERE build_id=?1;", -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt, 1, build_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DbStep;
}

/// Retain mirror: same full-rewrite discipline as leases (REPLACE the parent,
/// then re-assert every member row in the same call).
pub fn insertRetain(idx: *Index, project_id: []const u8, updated_ms: i64) DbError!void {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db,
        "INSERT OR REPLACE INTO retains(project_id,updated_ms) VALUES(?1,?2);",
        -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt, 1, project_id);
    _ = c.sqlite3_bind_int64(stmt, 2, updated_ms);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DbStep;
}

pub fn insertRetainManifest(idx: *Index, project_id: []const u8, manifest_hex: []const u8) DbError!void {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db,
        "INSERT OR IGNORE INTO retain_manifests(project_id,manifest) VALUES(?1,?2);",
        -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt, 1, project_id);
    bindText(stmt, 2, manifest_hex);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DbStep;
}

pub fn deleteRetainManifests(idx: *Index, project_id: []const u8) DbError!void {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db, "DELETE FROM retain_manifests WHERE project_id=?1;", -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt, 1, project_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DbStep;
}

/// Storage-v2 §9.3 class tags for budget accounting. Object bytes only ever
/// count toward hot/cold; index_state/spool usage comes from file walks +
/// live reservations (see budget.classUsage). The strings match the
/// `reservations.class` CHECK values.
pub const Class = enum { hot, cold, index_state, spool };

fn className(class: Class) []const u8 {
    return switch (class) {
        .hot => "hot",
        .cold => "cold",
        .index_state => "index_state",
        .spool => "spool",
    };
}

/// §9.3/§12.3 CASE measure split per class. Hot counts uncompressed sizes
/// (tier hot + the hot copy of `both` staging rows); cold counts compressed
/// sizes (tier cold + the cold copy of `both` rows); index_state/spool hold
/// no object bytes and return 0 (callers add file walks + reservations).
pub fn classSum(idx: *Index, class: Class) DbError!u64 {
    const sql: [:0]const u8 = switch (class) {
        .hot => "SELECT COALESCE(SUM(CASE WHEN tier='hot' THEN size WHEN tier='both' THEN size ELSE 0 END),0) FROM objects;",
        .cold => "SELECT COALESCE(SUM(CASE WHEN tier='cold' THEN COALESCE(compressed_size,size) WHEN tier='both' THEN COALESCE(compressed_size,0) ELSE 0 END),0) FROM objects;",
        .index_state, .spool => return 0,
    };
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db, sql.ptr, -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.DbStep;
    return @intCast(c.sqlite3_column_int64(stmt, 0));
}

/// SUM(bytes) over live `reservations` rows for one class (§9.3
/// double-entry rule: reservations count until commit/abort/expiry).
pub fn reservationSum(idx: *Index, class: Class) DbError!u64 {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db, "SELECT COALESCE(SUM(bytes),0) FROM reservations WHERE class=?1;", -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt, 1, className(class));
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.DbStep;
    return @intCast(c.sqlite3_column_int64(stmt, 0));
}

/// Admission ledger (storage-v2 §10.2). Reservation ids are 128-bit random,
/// stored as 32 lowercase hex chars. Plain INSERT: a collision fails the
/// put with DbStep (128-bit random makes this a never-happens path, and
/// silently replacing another live reservation would corrupt accounting).
/// Timestamps are passed in (Unix millis); the owner lease extension to the
/// lease TTL is computed by the admission caller via leaseExpiry below.
/// Plan B Task 9.
pub fn insertReservation(idx: *Index, id: [16]u8, class: Class, bytes: u64, created_ms: i64, expires_ms: i64, owner: ?[]const u8) DbError!void {
    const hex = std.fmt.bytesToHex(id, .lower);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db,
        "INSERT INTO reservations(reservation_id,class,bytes,created_ms,expires_ms,owner_build_id)" ++
        " VALUES(?1,?2,?3,?4,?5,?6);", -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt, 1, &hex);
    bindText(stmt, 2, className(class));
    _ = c.sqlite3_bind_int64(stmt, 3, @intCast(bytes));
    _ = c.sqlite3_bind_int64(stmt, 4, created_ms);
    _ = c.sqlite3_bind_int64(stmt, 5, expires_ms);
    if (owner) |o| {
        bindText(stmt, 6, o);
    } else {
        _ = c.sqlite3_bind_null(stmt, 6);
    }
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DbStep;
}

/// Ledger -> file atom swap completion (success and failure alike: both
/// just delete the row; the bytes are authoritative either way).
/// Plan B Task 9.
pub fn deleteReservation(idx: *Index, id: [16]u8) DbError!void {
    const hex = std.fmt.bytesToHex(id, .lower);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db, "DELETE FROM reservations WHERE reservation_id=?1;", -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt, 1, &hex);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DbStep;
}

/// Reaps expired reservation rows (§10.2 TTL). Run on open and on every
/// admission so the ledger never counts garbage (§8.1 sweep discipline).
/// Plan B Task 9.
pub fn sweepExpiredReservations(idx: *Index, now_ms: i64) DbError!void {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db, "DELETE FROM reservations WHERE expires_ms<?1;", -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, now_ms);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DbStep;
}

/// Lease expiry for an owner build id, if a row exists. Lets admission
/// extend a matching reservation to the lease TTL (§10.2). Plan B Task 9.
pub fn leaseExpiry(idx: *Index, build_id: []const u8) DbError!?i64 {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db, "SELECT expires_ms FROM leases WHERE build_id=?1;", -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt, 1, build_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    return c.sqlite3_column_int64(stmt, 0);
}

/// §12.3 per-tag-value byte measure (hot sizes, cold compressed, both = sum
/// of both copies). Joins object_tags to objects; misses (no such pair)
/// read as 0. Plan B Task 10.
pub fn tagUsage(idx: *Index, key: []const u8, value: []const u8) DbError!u64 {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db,
        "SELECT COALESCE(SUM(CASE WHEN o.tier='hot' THEN o.size WHEN o.tier='both' THEN o.size + COALESCE(o.compressed_size, 0) ELSE COALESCE(o.compressed_size,o.size) END),0)" ++
        " FROM object_tags t JOIN objects o ON o.digest=t.digest WHERE t.key=?1 AND t.value=?2;",
        -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt, 1, key);
    bindText(stmt, 2, value);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.DbStep;
    return @intCast(c.sqlite3_column_int64(stmt, 0));
}

/// §12.3 `kind:` budget sibling: the same CASE summed over
/// `objects WHERE kind=?1` with no tag join (`kind` is an objects column,
/// never an object tag, §11.3). Plan B Task 10.
pub fn kindUsage(idx: *Index, kind: []const u8) DbError!u64 {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db,
        "SELECT COALESCE(SUM(CASE WHEN tier='hot' THEN size WHEN tier='both' THEN size + COALESCE(compressed_size, 0) ELSE COALESCE(compressed_size,size) END),0)" ++
        " FROM objects WHERE kind=?1;",
        -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt, 1, kind);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.DbStep;
    return @intCast(c.sqlite3_column_int64(stmt, 0));
}

/// One soft-cap row (§12.3, decision D6). Owned strings: free the slice
/// with freeTagBudgets. Plan B Task 10.
pub const TagBudgetRow = struct { key: []u8, value: []u8, soft_cap: u64 };

pub fn listTagBudgets(idx: *Index, gpa: std.mem.Allocator) DbError![]TagBudgetRow {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db, "SELECT key,value,soft_cap FROM tag_budgets;", -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    var list: std.ArrayList(TagBudgetRow) = .empty;
    errdefer {
        for (list.items) |b| {
            gpa.free(b.key);
            gpa.free(b.value);
        }
        list.deinit(gpa);
    }
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const k = try gpa.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 0)));
        errdefer gpa.free(k);
        const v = try gpa.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1)));
        list.append(gpa, .{ .key = k, .value = v, .soft_cap = @intCast(c.sqlite3_column_int64(stmt, 2)) }) catch |append_err| {
            gpa.free(k);
            gpa.free(v);
            return append_err;
        };
    }
    return try list.toOwnedSlice(gpa);
}

pub fn freeTagBudgets(gpa: std.mem.Allocator, rows: []TagBudgetRow) void {
    for (rows) |b| {
        gpa.free(b.key);
        gpa.free(b.value);
    }
    gpa.free(rows);
}

/// One per-pair aggregate for `stat --by-tag` (§12.2). Defined here (not in
/// stats.zig) so the index owns the row shape while stats.zig re-exports it
/// — no import cycle, no sqlite3 outside the index. Owned key/value
/// strings. Plan B Task 11.
pub const TagStat = struct { key: []u8, value: []u8, bytes: u64, objects: u64 };

/// One row per distinct tag pair, bytes DESC, using the §12.3 CASE measure
/// (hot sizes, cold compressed, both = both copies) with COUNT(*) objects
/// per pair (PRIMARY KEY digest,key,value: one row per object per pair).
/// Caller frees keys/values + slice (see stats.freeTagStats). Plan B Task 11.
pub fn tagStats(idx: *Index, gpa: std.mem.Allocator) DbError![]TagStat {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db,
        "SELECT key,value," ++
        "COALESCE(SUM(CASE WHEN o.tier='hot' THEN o.size WHEN o.tier='both' THEN o.size + COALESCE(o.compressed_size,0) ELSE COALESCE(o.compressed_size,o.size) END),0)," ++
        "COUNT(*) FROM object_tags t JOIN objects o ON o.digest=t.digest GROUP BY key,value ORDER BY 3 DESC;",
        -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    var list: std.ArrayList(TagStat) = .empty;
    errdefer {
        for (list.items) |r| {
            gpa.free(r.key);
            gpa.free(r.value);
        }
        list.deinit(gpa);
    }
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const k = try gpa.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 0)));
        errdefer gpa.free(k);
        const v = try gpa.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1)));
        list.append(gpa, .{
            .key = k,
            .value = v,
            .bytes = @intCast(c.sqlite3_column_int64(stmt, 2)),
            .objects = @intCast(c.sqlite3_column_int64(stmt, 3)),
        }) catch |append_err| {
            gpa.free(k);
            gpa.free(v);
            return append_err;
        };
    }
    return try list.toOwnedSlice(gpa);
}

/// Bounded oldest-first eviction candidates for one object class (§10.2
/// bounded effort): at most max_objects rows AND at most max_bytes of class
/// measure (hot: size; cold: compressed size), whichever bound hits first —
/// never a full-table fetch. Rows carry duped kind strings: free with
/// freeRows. index_state/spool hold no object bytes, so they yield zero
/// candidates (their admit paths fail fast with StoreFull). Plan B Task 9.
pub fn evictionCandidates(idx: *Index, gpa: std.mem.Allocator, class: Class, max_objects: u32, max_bytes: u64) DbError![]ObjectRow {
    var list: std.ArrayList(ObjectRow) = .empty;
    errdefer {
        for (list.items) |r| gpa.free(r.kind);
        list.deinit(gpa);
    }
    switch (class) {
        .hot, .cold => {
            const tier_text: []const u8 = if (class == .hot) "hot" else "cold";
            var stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(idx.db,
                "SELECT digest,size,compressed_size,tier,kind,created_ms,last_access_ms FROM objects" ++
                " WHERE tier=?1 ORDER BY last_access_ms ASC LIMIT ?2;", -1, &stmt, null) != c.SQLITE_OK)
                return error.DbPrepare;
            defer _ = c.sqlite3_finalize(stmt);
            bindText(stmt, 1, tier_text);
            _ = c.sqlite3_bind_int64(stmt, 2, @intCast(max_objects));
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
                @memcpy(&row.digest, std.mem.span(c.sqlite3_column_text(stmt, 0))[0..64]);
                row.kind = try gpa.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 4)));
                list.append(gpa, row) catch |append_err| {
                    gpa.free(row.kind);
                    return append_err;
                };
            }
        },
        .index_state, .spool => {},
    }
    // Byte bound: keep the oldest prefix whose cumulative class measure
    // stays within max_bytes. Stop at the first row that would exceed —
    // later rows are newer by LRU order, so skipping ahead would break LRU.
    // Zero-byte objects always fit (eviction must make progress on them).
    var kept: usize = 0;
    var accum: u64 = 0;
    for (list.items) |r| {
        const m = if (class == .cold) (r.compressed_size orelse r.size) else r.size;
        if (accum +| m > max_bytes) break;
        accum += m;
        kept += 1;
    }
    for (list.items[kept..]) |r| gpa.free(r.kind);
    list.items = list.items[0..kept];
    return try list.toOwnedSlice(gpa);
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
