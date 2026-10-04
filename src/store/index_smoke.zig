const std = @import("std");

const c = @cImport(@cInclude("sqlite3.h"));

test "sqlite3 amalgamation links and opens an in-memory db" {
    var db: ?*c.sqlite3 = null;
    try std.testing.expectEqual(@as(c_int, 0), c.sqlite3_open_v2(
        ":memory:",
        &db,
        c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE,
        null,
    ));
    defer _ = c.sqlite3_close(db);
    try std.testing.expectEqual(@as(c_int, 0), c.sqlite3_exec(
        db,
        "CREATE TABLE smoke(id INTEGER PRIMARY KEY, v TEXT);",
        null,
        null,
        null,
    ));
}
