const std = @import("std");
const builtin = @import("builtin");
const store = @import("store");

pub const GcOpts = struct { dry_run: bool = false, target_bytes: ?u64 = null, older_than_ns: ?u64 = null };
pub const PinArgs = struct { name: []const u8, digest: []const u8 };
pub const UnpinArgs = struct { name: []const u8 };
pub const StorePutArgs = struct { name: []const u8, file: []const u8 };
pub const StoreGetArgs = struct { name: []const u8, out_file: []const u8 };

pub const Command = union(enum) {
    stat,
    gc: GcOpts,
    pin: PinArgs,
    unpin: UnpinArgs,
    store_put: StorePutArgs,
    store_get: StoreGetArgs,
    verify,
};

pub fn parseCommand(gpa: std.mem.Allocator, args: []const []const u8) error{Usage}!Command {
    _ = gpa;
    if (args.len == 0) return error.Usage;
    if (std.mem.eql(u8, args[0], "cache")) {
        if (args.len == 2 and std.mem.eql(u8, args[1], "stat")) return .stat;
        if (args.len == 2 and std.mem.eql(u8, args[1], "verify")) return .verify;
        return error.Usage;
    }
    if (std.mem.eql(u8, args[0], "gc")) {
        var cmd: Command = .{ .gc = .{} };
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--dry-run")) {
                cmd.gc.dry_run = true;
            } else if (std.mem.eql(u8, args[i], "--to-size") and i + 1 < args.len) {
                i += 1;
                cmd.gc.target_bytes = store.config.parseSize(args[i]) catch return error.Usage;
            } else if (std.mem.eql(u8, args[i], "--older-than") and i + 1 < args.len) {
                i += 1;
                cmd.gc.older_than_ns = store.config.parseDuration(args[i]) catch return error.Usage;
            } else return error.Usage;
        }
        return cmd;
    }
    if (std.mem.eql(u8, args[0], "pin") and args.len == 3)
        return .{ .pin = .{ .name = args[1], .digest = args[2] } };
    if (std.mem.eql(u8, args[0], "unpin") and args.len == 2)
        return .{ .unpin = .{ .name = args[1] } };
    if (std.mem.eql(u8, args[0], "store")) {
        if (args.len == 4 and std.mem.eql(u8, args[1], "put"))
            return .{ .store_put = .{ .name = args[2], .file = args[3] } };
        if (args.len == 4 and std.mem.eql(u8, args[1], "get"))
            return .{ .store_get = .{ .name = args[2], .out_file = args[3] } };
    }
    return error.Usage;
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    var it = std.process.Args.Iterator.init(init.minimal.args);
    while (it.next()) |arg| try argv.append(gpa, arg);

    const rest: []const []const u8 = if (argv.items.len > 1) argv.items[1..] else &.{};
    const cmd = parseCommand(gpa, rest) catch {
        std.debug.print("usage: rime <cache stat|cache verify|gc|pin|unpin|store> …\n", .{});
        return 2;
    };

    var store_dir = try openStoreDir(init, io, gpa);
    defer store_dir.close(io);
    var s = store.Store.open(io, store_dir, .{}) catch |e| {
        std.debug.print("rime: cannot open store: {t}\n", .{e});
        return 1;
    };
    defer s.close(io);

    switch (cmd) {
        .stat => return cmdStat(io, gpa, &s),
        .gc => |p| return cmdGc(io, gpa, &s, p),
        .pin => |p| return cmdPin(io, &s, p),
        .unpin => |p| return cmdUnpin(io, &s, p),
        .store_put => |p| return cmdStorePut(io, &s, p),
        .store_get => |p| return cmdStoreGet(io, gpa, &s, p),
        .verify => return cmdVerify(io, gpa, &s),
    }
}

/// Store location: $RIME_CACHE_DIR, else <cache home>/rime ($HOME/Library/Caches
/// on macOS, $XDG_CACHE_HOME or $HOME/.cache on Linux). Created on demand.
fn openStoreDir(init: std.process.Init, io: std.Io, gpa: std.mem.Allocator) !std.Io.Dir {
    const env = init.environ_map;
    if (env.get("RIME_CACHE_DIR")) |dir_path| {
        return std.Io.Dir.cwd().createDirPathOpen(io, dir_path, .{});
    }
    const home = env.get("HOME") orelse ".";
    const base: []const u8 = switch (builtin.os.tag) {
        .macos => try std.fmt.allocPrint(gpa, "{s}/Library/Caches", .{home}),
        .linux => if (env.get("XDG_CACHE_HOME")) |x|
            try gpa.dupe(u8, x)
        else
            try std.fmt.allocPrint(gpa, "{s}/.cache", .{home}),
        else => @compileError("rime supports macOS and Linux only"),
    };
    defer gpa.free(base);
    const full = try std.fmt.allocPrint(gpa, "{s}/rime", .{base});
    defer gpa.free(full);
    return std.Io.Dir.cwd().createDirPathOpen(io, full, .{});
}

fn cmdStat(io: std.Io, gpa: std.mem.Allocator, s: *store.Store) u8 {
    const st = s.stats(io, gpa) catch |e| {
        std.debug.print("rime: stat failed: {t}\n", .{e});
        return 1;
    };
    std.debug.print("hot: {d} bytes in {d} objects (limit {d})\n", .{ st.hot_bytes, st.hot_objects, st.limits.hot });
    std.debug.print("cold: {d} bytes in {d} objects (limit {d})\n", .{ st.cold_bytes, st.cold_objects, st.limits.cold });
    std.debug.print("incremental: {d} bytes\n", .{st.incremental_bytes});
    std.debug.print("roots: {d} pinned bytes, {d} live leases\n", .{ st.pinned_bytes, st.lease_count });
    std.debug.print("free: {d} bytes (reserve {d})\n", .{ st.free_bytes, st.limits.reserve });
    std.debug.print("binding: {s}\n", .{bindingConstraint(&st)});
    return 0;
}

/// What would block the next build: free space below reserve, roots alone
/// filling the hot quota (gc cannot free), otherwise the quota itself.
fn bindingConstraint(st: *const store.Store.Stats) []const u8 {
    if (st.free_bytes < st.limits.reserve) return "free-space";
    if (st.pinned_bytes >= st.limits.hot) return "roots";
    return "limit";
}

fn cmdGc(
    io: std.Io,
    gpa: std.mem.Allocator,
    s: *store.Store,
    p: GcOpts,
) u8 {
    if (!s.tryGcLock(io)) {
        std.debug.print("gc deferred: build in progress\n", .{});
        return 0;
    }
    defer s.unlock(io);
    const report = s.gc(io, gpa, .{
        .dry_run = p.dry_run,
        .target_bytes = p.target_bytes,
        .older_than_ns = p.older_than_ns,
    }) catch |e| {
        std.debug.print("rime: gc failed: {t}\n", .{e});
        return 1;
    };
    std.debug.print(
        "scanned {d} evicted {d} freed hot {d} cold {d} incremental {d} demoted {d} expired leases {d} stale actions {d} dry-run {}\n",
        .{
            report.scanned_objects,
            report.evicted_objects,
            report.freed_bytes_hot,
            report.freed_bytes_cold,
            report.freed_bytes_incremental,
            report.demoted_objects,
            report.expired_leases,
            report.stale_action_entries,
            report.dry_run,
        },
    );
    return 0;
}

/// Accepts digests with or without the `b3-` text-form prefix.
fn parseDigestHex(text: []const u8) error{InvalidDigest}!store.Digest {
    const hex = if (std.mem.startsWith(u8, text, "b3-")) text[3..] else text;
    return store.Digest.fromHex(hex);
}

fn cmdPin(io: std.Io, s: *store.Store, p: PinArgs) u8 {
    const d = parseDigestHex(p.digest) catch {
        std.debug.print("rime: invalid digest: {s}\n", .{p.digest});
        return 1;
    };
    s.pin(io, p.name, d) catch |e| {
        std.debug.print("rime: pin failed: {t}\n", .{e});
        return 1;
    };
    const hex = d.toHex();
    std.debug.print("pinned {s} b3-{s}\n", .{ p.name, hex[0..] });
    return 0;
}

fn cmdUnpin(io: std.Io, s: *store.Store, p: UnpinArgs) u8 {
    s.unpin(io, p.name) catch |e| {
        std.debug.print("rime: unpin failed: {t}\n", .{e});
        return 1;
    };
    std.debug.print("unpinned {s}\n", .{p.name});
    return 0;
}

fn cmdStorePut(io: std.Io, s: *store.Store, p: StorePutArgs) u8 {
    const f = std.Io.Dir.cwd().openFile(io, p.file, .{}) catch {
        std.debug.print("rime: cannot open file: {s}\n", .{p.file});
        return 1;
    };
    defer f.close(io);
    const d = s.putFile(io, f, .other) catch |e| {
        std.debug.print("rime: ingest failed: {t}\n", .{e});
        return 1;
    };
    s.pin(io, p.name, d) catch |e| {
        std.debug.print("rime: pin failed: {t}\n", .{e});
        return 1;
    };
    const hex = d.toHex();
    std.debug.print("b3-{s}\n", .{hex[0..]});
    return 0;
}

fn cmdStoreGet(
    io: std.Io,
    gpa: std.mem.Allocator,
    s: *store.Store,
    p: StoreGetArgs,
) u8 {
    const pins = store.state.listPins(io, gpa, s.dir) catch |e| {
        std.debug.print("rime: cannot list pins: {t}\n", .{e});
        return 1;
    };
    defer store.state.freePins(gpa, pins);
    for (pins) |pin| {
        if (!std.mem.eql(u8, pin.name, p.name)) continue;
        const d = parseDigestHex(pin.digest_hex) catch {
            std.debug.print("rime: corrupt pin entry: {s}\n", .{p.name});
            return 1;
        };
        // Materialize resolves relative paths under the store, so anchor
        // relative outputs at the invocation directory first.
        const dest = absolutize(io, gpa, p.out_file) catch {
            std.debug.print("rime: bad output path: {s}\n", .{p.out_file});
            return 1;
        };
        defer gpa.free(dest);
        _ = s.materialize(io, d, dest, 0o644) catch |e| {
            std.debug.print("rime: materialize failed: {t}\n", .{e});
            return 1;
        };
        return 0;
    }
    std.debug.print("rime: no such pin: {s}\n", .{p.name});
    return 1;
}

/// Joins a possibly-relative path onto the current directory.
fn absolutize(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return gpa.dupe(u8, path);
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ cwd, path });
}

fn cmdVerify(io: std.Io, gpa: std.mem.Allocator, s: *store.Store) u8 {
    const infos = s.scan(io, gpa) catch |e| {
        std.debug.print("rime: scan failed: {t}\n", .{e});
        return 1;
    };
    defer gpa.free(infos);
    var checked: u64 = 0;
    var bad: u64 = 0;
    for (infos, 0..) |obj, i| {
        if (i % 10 != 0) continue;
        checked += 1;
        s.verifyObject(io, obj.digest) catch {
            bad += 1;
        };
    }
    std.debug.print("verified {d} of {d} objects, {d} mismatches\n", .{ checked, infos.len, bad });
    return if (bad == 0) 0 else 1;
}

test "parseCommand covers the surface" {
    const gpa = std.testing.allocator;
    try std.testing.expect((try parseCommand(gpa, &.{ "cache", "stat" })) == .stat);
    const c = try parseCommand(gpa, &.{ "gc", "--dry-run", "--to-size", "5GiB" });
    try std.testing.expect(c.gc.dry_run);
    try std.testing.expectEqual(@as(?u64, 5 * store.config.GiB), c.gc.target_bytes);
    try std.testing.expectError(error.Usage, parseCommand(gpa, &.{"nonsense"}));
}
