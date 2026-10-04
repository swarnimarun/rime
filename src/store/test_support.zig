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
