const std = @import("std");
const config_mod = @import("config.zig");
const root = @import("root.zig");

pub const TestStore = struct {
    tmp: std.testing.TmpDir,
    store: root.Store,

    pub fn deinit(ts: *TestStore, io: std.Io) void {
        ts.store.close(io);
        ts.tmp.cleanup();
    }
};

pub fn openTestStore(io: std.Io, cfg: config_mod.Config) TestStore {
    var tmp = std.testing.tmpDir(.{});
    const store = root.Store.open(io, tmp.dir, cfg) catch |e| {
        tmp.cleanup();
        std.debug.panic("openTestStore: {t}", .{e});
    };
    return .{ .tmp = tmp, .store = store };
}

/// Test aid: true when the hot-tier copy of an object exists. Objects live
/// at "objects/ab/<hex>" (spec §6), so the fanout prefix is required.
pub fn dirHasHot(store: *root.Store, io: std.Io, d: root.Digest) bool {
    var rbuf: [65]u8 = undefined;
    const rel = d.relPath(&rbuf);
    var full: [73]u8 = undefined;
    @memcpy(full[0..8], "objects/");
    @memcpy(full[8..], rel);
    _ = store.dir.statFile(io, full[0..73], .{}) catch return false;
    return true;
}
