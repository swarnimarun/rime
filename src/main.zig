const std = @import("std");
const builtin = @import("builtin");
const store = @import("store");
const cargo = @import("cargo");

/// `cache stat` options: `--by-tag` prints the per-pair table, optionally
/// narrowed to exact `k=v` pairs. Plan B Task 11.
pub const StatOpts = struct { by_tag: bool = false, filters: []const []const u8 = &.{} };
/// One `--tag k=v` scope (repeatable, conjunctive). Plan B Task 11.
pub const TagFilter = struct { key: []const u8, value: []const u8 };
pub const GcOpts = struct { dry_run: bool = false, target_bytes: ?u64 = null, older_than_ns: ?u64 = null, tags: []const TagFilter = &.{} };
pub const MigrateOpts = struct { dry_run: bool = false };
pub const PinArgs = struct { name: []const u8, digest: []const u8 };
pub const UnpinArgs = struct { name: []const u8 };
pub const StorePutArgs = struct { name: []const u8, file: []const u8 };
pub const StoreGetArgs = struct { name: []const u8, out_file: []const u8 };

pub const CargoOpts = struct {
    opts: cargo.cli.Options,
    argv: []const []const u8, // ["rime"] ++ rest shim; freed with gpa
};

pub const Command = union(enum) {
    cargo: CargoOpts,
    stat: StatOpts,
    migrate: MigrateOpts,
    gc: GcOpts,
    pin: PinArgs,
    unpin: UnpinArgs,
    store_put: StorePutArgs,
    store_get: StoreGetArgs,
    verify,
};

pub fn parseCommand(gpa: std.mem.Allocator, args: []const []const u8) error{ Usage, OutOfMemory }!Command {
    if (args.len == 0) return error.Usage;
    // Cargo frontend (Plan C): build/check/test/run/bench/clean dispatch to
    // cli.parseArgs, which expects argv[0] to be the program name.
    if (isCargoCommand(args[0])) {
        const shim = try gpa.alloc([]const u8, args.len + 1);
        shim[0] = "rime";
        @memcpy(shim[1..], args);
        const opts = cargo.cli.parseArgs(gpa, shim) catch |e| {
            gpa.free(shim);
            return e;
        };
        return .{ .cargo = .{ .opts = opts, .argv = shim } };
    }
    if (std.mem.eql(u8, args[0], "cache")) {
        if (args.len >= 2 and std.mem.eql(u8, args[1], "stat")) return try parseStat(gpa, args[2..]);
        if (args.len == 2 and std.mem.eql(u8, args[1], "verify")) return .verify;
        // Explicit v1→v2 migration (storage-v2 §14); never auto-runs on open.
        if (args.len >= 2 and std.mem.eql(u8, args[1], "migrate")) {
            var opts = MigrateOpts{};
            for (args[2..]) |a| {
                if (std.mem.eql(u8, a, "--dry-run")) {
                    opts.dry_run = true;
                } else return error.Usage;
            }
            return .{ .migrate = opts };
        }
        return error.Usage;
    }
    if (std.mem.eql(u8, args[0], "gc")) {
        var cmd: Command = .{ .gc = .{} };
        // Owned only when non-empty, so tagless call sites allocate nothing.
        var tag_list: std.ArrayList(TagFilter) = .empty;
        defer tag_list.deinit(gpa);
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
            } else if (std.mem.eql(u8, args[i], "--tag") and i + 1 < args.len) {
                i += 1;
                const a = args[i];
                const eq = std.mem.indexOfScalar(u8, a, '=') orelse return error.Usage;
                if (eq == 0 or eq == a.len - 1) return error.Usage;
                try tag_list.append(gpa, .{ .key = a[0..eq], .value = a[eq + 1 ..] });
            } else return error.Usage;
        }
        if (tag_list.items.len > 0) cmd.gc.tags = try tag_list.toOwnedSlice(gpa);
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

/// `cache stat [--by-tag [k=v ...]]`. Bare `cache stat` keeps StatOpts{}
/// defaults; filters borrow the argv slices (the array is caller-owned via
/// gpa — allocated only when filters are present, so existing no-filter
/// call sites allocate nothing). Plan B Task 11.
fn parseStat(gpa: std.mem.Allocator, rest: []const []const u8) error{ Usage, OutOfMemory }!Command {
    var opts = StatOpts{};
    if (rest.len == 0) return .{ .stat = opts };
    if (!std.mem.eql(u8, rest[0], "--by-tag")) return error.Usage;
    opts.by_tag = true;
    if (rest.len == 1) return .{ .stat = opts };
    const fs = try gpa.alloc([]const u8, rest.len - 1);
    errdefer gpa.free(fs);
    for (rest[1..], 0..) |a, i| {
        const eq = std.mem.indexOfScalar(u8, a, '=') orelse return error.Usage;
        if (eq == 0 or eq == a.len - 1) return error.Usage;
        fs[i] = a;
    }
    opts.filters = fs;
    return .{ .stat = opts };
}

/// Plan C cargo subcommands (build/check/test/run/bench/clean/fetch).
fn isCargoCommand(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "build") or std.mem.eql(u8, arg, "check") or std.mem.eql(u8, arg, "test") or std.mem.eql(u8, arg, "run") or std.mem.eql(u8, arg, "bench") or std.mem.eql(u8, arg, "clean") or std.mem.eql(u8, arg, "fetch");
}

/// Leading-globals prescan (Task 2): `rime -v build`, `rime --quiet check`,
/// `rime --color=never test` parse identically to trailing position. Moves
/// recognized leading globals (before the command word) to just after it.
/// Unknown leading flags are NOT prescanned (fall through to usage errors).
/// Caller owns the returned slice (each entry borrows `args`).
pub fn hoistLeadingGlobals(gpa: std.mem.Allocator, args: []const []const u8) ![][]const u8 {
    var cmd_idx: ?usize = null;
    for (args, 0..) |a, i| {
        if (isCargoCommand(a)) {
            cmd_idx = i;
            break;
        }
        // A positional that is not a command stops the prescan (cargo
        // would reject it too); leave everything as-is.
        if (a.len == 0 or a[0] != '-') break;
    }
    const ci = cmd_idx orelse return gpa.dupe([]const u8, args);
    if (ci == 0) return gpa.dupe([]const u8, args);
    // Verify every leading token is a recognized global (values included).
    var i: usize = 0;
    while (i < ci) {
        const a = args[i];
        if (isLeadingGlobalFlag(a)) {
            if (takesLeadingValue(a)) i += 1;
        } else if (isVerboseLeading(a) or std.mem.eql(u8, a, "-q") or std.mem.eql(u8, a, "--quiet") or
            std.mem.eql(u8, a, "--offline") or std.mem.eql(u8, a, "--frozen") or std.mem.eql(u8, a, "--locked") or
            std.mem.eql(u8, a, "-v") or std.mem.eql(u8, a, "--verbose"))
        {
            // value-less globals
        } else return gpa.dupe([]const u8, args);
        i += 1;
    }
    // Splice: [cmd] ++ leading ++ rest.
    const out = try gpa.alloc([]const u8, args.len);
    out[0] = args[ci];
    @memcpy(out[1 .. 1 + ci], args[0..ci]);
    @memcpy(out[1 + ci ..], args[ci + 1 ..]);
    return out;
}

fn isVerboseLeading(a: []const u8) bool {
    if (a.len < 2 or a[0] != '-' or a[1] == '-') return false;
    for (a[1..]) |c| if (c != 'v') return false;
    return true;
}

/// Leading globals that take a separate value token (`--color never`,
/// `-j 4`, `--jobs 4`, `--config KEY=VAL`). `--flag=value` forms need no
/// skipping (single token, handled by the flag check itself).
fn takesLeadingValue(a: []const u8) bool {
    if (std.mem.eql(u8, a, "--color") or std.mem.eql(u8, a, "--config") or
        std.mem.eql(u8, a, "-j") or std.mem.eql(u8, a, "--jobs")) return true;
    return false;
}

fn isLeadingGlobalFlag(a: []const u8) bool {
    if (takesLeadingValue(a)) return true;
    if (std.mem.startsWith(u8, a, "--color=") or std.mem.startsWith(u8, a, "--jobs=") or
        std.mem.startsWith(u8, a, "--config=")) return true;
    if (a.len > 2 and a[0] == '-' and a[1] != '-' and a[1] == 'j') return true; // -j4
    return false;
}

pub fn gcHelp() []const u8 {
    return
        \\Collect unrooted objects from the global store.
        \\
        \\Usage: rime gc [--dry-run] [--to-size BYTES] [--older-than DUR] [--tag K=V ...]
        \\
        \\Does not touch project target/ views; use 'rime clean' for those.
        \\See 'rime cache stat --by-tag' for per-tag usage.
        \\
    ;
}

pub fn cargoCleanHelp() []const u8 {
    return
        \\Remove artifacts that rime has generated in the past.
        \\
        \\Usage: rime clean [-p PKG ...] [--workspace] [--release|--profile N] [--target TRIPLE] [--target-dir DIR] [--manifest-path P] [--doc] [--dry-run]
        \\
        \\Removes only project target/ views, never store state.
        \\See 'rime gc --help' for global-cache collection.
        \\
    ;
}

pub fn cargoBuildHelp() []const u8 {
    return
        \\Compile the current package.
        \\
        \\Usage: rime build [--release|--profile N] [--target T] [-p PKG ...] [--features CSV] [--message-format FMT] [--target-dir DIR]
        \\
        \\Note: rime implements the build surface; parallelism (-j) is accepted and validated but units run in plan order.
        \\
    ;
}

pub fn cargoCheckHelp() []const u8 {
    return
        \\Check the current package (rmeta-only, no codegen).
        \\
        \\Usage: rime check [same flags as build]
        \\
        \\Note: rime implements the check surface; artifacts are metadata-only.
        \\
    ;
}

pub fn cargoTestHelp() []const u8 {
    return
        \\Compile and run tests.
        \\
        \\Usage: rime test [--no-run] [--no-fail-fast] [FILTER ...] [-- ARGS ...]
        \\
        \\Note: rime forwards trailing args to the libtest harness after `--`.
        \\
    ;
}

pub fn cargoRunHelp() []const u8 {
    return
        \\Build and run a binary.
        \\
        \\Usage: rime run [--bin NAME|--example NAME] [-- ARGS ...]
        \\
        \\Note: rime spawns the view binary built by a prior build.
        \\
    ;
}

pub fn cargoBenchHelp() []const u8 {
    return
        \\Compile and run benchmarks.
        \\
        \\Usage: rime bench [BENCHNAME] [--no-run] [--no-fail-fast] [-- ARGS ...]
        \\
        \\Note: rime invokes the bench harness binary directly.
        \\
    ;
}

pub fn cargoFetchHelp() []const u8 {
    return
        \\Fetch dependencies of the current package.
        \\
        \\Usage: rime fetch [--target TRIPLE] [--manifest-path P]
        \\
        \\Note: rime implements the fetch surface over the existing fetch machinery.
        \\
    ;
}

pub fn cacheStatHelp() []const u8 {
    return
        \\Show global store usage.
        \\
        \\Usage: rime cache stat [--by-tag [K=V ...]]
        \\
        \\Reports budget lines and per-tag usage; project views are out of scope.
        \\See 'rime gc --help' for reclaiming space.
        \\
    ;
}

/// Cargo usage line (exit 1 per decision D4; the store path keeps exit 2).
/// Message-format failures are the anyhow class (exit 101).
fn printCargoUsage() void {
    if (cargo.cli.parseDiagnostic()) |d| {
        std.debug.print("error: {s}\n", .{d});
    }
    std.debug.print("usage: rime <build|check|test|run|bench|clean|fetch> [--manifest-path P] [--release|--profile N] [--target T] [--features CSV] [--message-format=json|human] [--offline|--frozen|--locked] [--dry-run] [-p PKG] [-- ARGS…]\n", .{});
}

fn cargoExitForUsage() u8 {
    // Row 5: message-format conflict/invalid specifier is exit 101.
    if (cargo.cli.isFormatError()) return 101;
    return 1;
}

/// Top-level and rime-native `--help`/`--version` handling. Returns the
/// exit code when handled, null to continue normal dispatch. Help and
/// version text go to stdout (matrix row 3); only errors use stderr.
fn tryHandleHelp(gpa: std.mem.Allocator, io: std.Io, rest: []const []const u8) ?u8 {
    _ = gpa;
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const out = &w.interface;
    if (rest.len == 1 and (std.mem.eql(u8, rest[0], "--help") or std.mem.eql(u8, rest[0], "-h"))) {
        out.print("usage: rime <build|check|test|run|bench|clean|fetch> …\n       rime <cache stat [--by-tag [k=v …]]|cache verify|cache migrate [--dry-run]|gc [--tag k=v …]|pin|unpin|store> …\n", .{}) catch return 0;
        w.flush() catch {};
        return 0;
    }
    if (rest.len == 1 and (std.mem.eql(u8, rest[0], "--version") or std.mem.eql(u8, rest[0], "-V"))) {
        out.print("rime 0.1.0\n", .{}) catch return 0;
        w.flush() catch {};
        return 0;
    }
    if (rest.len == 2 and std.mem.eql(u8, rest[0], "gc") and (std.mem.eql(u8, rest[1], "--help") or std.mem.eql(u8, rest[1], "-h"))) {
        out.print("{s}\n", .{gcHelp()}) catch return 0;
        w.flush() catch {};
        return 0;
    }
    if (rest.len >= 2 and std.mem.eql(u8, rest[0], "cache") and std.mem.eql(u8, rest[1], "stat")) {
        for (rest[2..]) |a| {
            if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
                out.print("{s}\n", .{cacheStatHelp()}) catch return 0;
                w.flush() catch {};
                return 0;
            }
        }
    }
    return null;
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    var it = std.process.Args.Iterator.init(init.minimal.args);
    while (it.next()) |arg| try argv.append(gpa, arg);

    const rest: []const []const u8 = if (argv.items.len > 1) argv.items[1..] else &.{};
    if (tryHandleHelp(gpa, io, rest)) |code| return code;
    // Leading globals (`rime -v build`) splice after the command word.
    const routed: []const []const u8 = hoistLeadingGlobals(gpa, rest) catch rest;
    defer if (routed.ptr != rest.ptr) gpa.free(routed);
    const cmd = parseCommand(gpa, routed) catch {
        // Cargo usage errors exit 1 with the flag named (decision D4); the
        // store path keeps its historical exit 2. Message-format failures
        // are the anyhow class (exit 101).
        if (routed.len > 0 and isCargoCommand(routed[0])) {
            printCargoUsage();
            return cargoExitForUsage();
        }
        // NOTE (plan adjustment, reported): the plan's replacement usage
        // string dropped `cache migrate`; kept here (still a command).
        std.debug.print("usage: rime <cache stat [--by-tag [k=v …]]|cache verify|cache migrate [--dry-run]|gc [--tag k=v …]|pin|unpin|store> …\n", .{});
        return 2;
    };
    // parseCommand-owned arrays (stat filters / gc tags / cargo opts;
    // allocated only when non-empty). Freed here so Debug-allocator runs
    // stay clean.
    defer {
        switch (cmd) {
            .stat => |o| if (o.filters.len > 0) gpa.free(o.filters),
            .gc => |o| if (o.tags.len > 0) gpa.free(o.tags),
            .cargo => |c| {
                c.opts.deinit(gpa);
                gpa.free(c.argv);
            },
            else => {},
        }
    }

    // Cargo commands own their store lifecycle (lazy open inside cli.run);
    // the global store opens only for the store-management commands.
    if (cmd == .cargo) {
        var out_buf: [8192]u8 = undefined;
        var out_w = std.Io.File.stdout().writer(io, &out_buf);
        var err_buf: [8192]u8 = undefined;
        var err_w = std.Io.File.stderr().writer(io, &err_buf);
        const code = cargo.cli.run(gpa, io, cmd.cargo.opts, &out_w.interface, &err_w.interface);
        out_w.flush() catch {};
        err_w.flush() catch {};
        return code;
    }

    var store_dir = try openStoreDir(init, io, gpa);
    defer store_dir.close(io);
    // Migration runs without Store.open (which refuses format 1 with
    // MigrationRequired); it holds the exclusive format-lock itself (§14.1).
    if (cmd == .migrate) return cmdMigrate(io, store_dir, cmd.migrate);
    var s = store.Store.open(io, store_dir, .{}) catch |e| {
        std.debug.print("rime: cannot open store: {t}\n", .{e});
        return 1;
    };
    defer s.close(io);

    switch (cmd) {
        .cargo => unreachable, // dispatched before the store opens above
        .stat => |o| return cmdStat(io, gpa, &s, o),
        .migrate => unreachable, // handled before Store.open above
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

/// Explicit v1→v2 migration (storage-v2 §14). Holds the exclusive
/// format-lock for the whole run; `Store.open` never migrates.
fn cmdMigrate(io: std.Io, store_dir: std.Io.Dir, opts: MigrateOpts) u8 {
    const lock = store_dir.createFile(io, "format-lock", .{ .read = true, .truncate = false }) catch {
        std.debug.print("rime: cannot open format-lock\n", .{});
        return 1;
    };
    defer lock.close(io);
    lock.lock(io, .exclusive) catch {
        std.debug.print("rime: cannot hold exclusive format-lock\n", .{});
        return 1;
    };
    defer lock.unlock(io);
    var idx = store.Index.open(io, store_dir) catch |e| {
        std.debug.print("rime: cannot open index: {t}\n", .{e});
        return 1;
    };
    defer idx.close();
    const rep = store.migrate_mod.migrate(io, store_dir, &idx, .{ .dry_run = opts.dry_run }) catch |e| {
        // Fail-closed roots carry the filename via lastBadRoot (errors have
        // no payload); surface it so the operator knows which file to fix.
        if (e == error.CorruptRoot) {
            const bad = store.migrate_mod.lastBadRoot();
            if (bad.len > 0) std.debug.print("rime: migrate failed: {t}: corrupt root file {s}\n", .{ e, bad });
        } else std.debug.print("rime: migrate failed: {t}\n", .{e});
        return 1;
    };
    std.debug.print(
        "migrated objects {d} actions {d} roots {d} incremental bytes {d} dry-run {}\n",
        .{ rep.objects_imported, rep.actions_imported, rep.roots_imported, rep.incremental_rehomed_bytes, opts.dry_run },
    );
    return 0;
}

fn cmdStat(io: std.Io, gpa: std.mem.Allocator, s: *store.Store, opts: StatOpts) u8 {
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
    // Budget line (§9.1/§12.2): total cap, per-class usage, in-flight
    // reservations. Plan B Task 11.
    const u = store.budget_mod.classUsage(s, io, gpa) catch |e| {
        std.debug.print("rime: stat failed: {t}\n", .{e});
        return 1;
    };
    const reserved = s.reservedBytes() catch |e| {
        std.debug.print("rime: stat failed: {t}\n", .{e});
        return 1;
    };
    std.debug.print("budget: total {d} (hot {d} cold {d} index+state {d} spool {d}) reservations {d}\n", .{ s.budget.total, u.hot, u.cold, u.index_state, u.spool, reserved });
    if (opts.by_tag) {
        const rows = store.stats_mod.byTag(s, io, gpa) catch |e| {
            std.debug.print("rime: stat failed: {t}\n", .{e});
            return 1;
        };
        defer store.stats_mod.freeTagStats(gpa, rows);
        for (rows) |r| {
            if (opts.filters.len > 0 and !statFilterMatch(opts.filters, r.key, r.value)) continue;
            std.debug.print("tag {s}={s}: {d} bytes in {d} objects\n", .{ r.key, r.value, r.bytes, r.objects });
        }
    }
    return 0;
}

/// Renders the last admission diagnostic with the §10.4 exact fields
/// verbatim (`admitting N to <class> (budget B, <class> used/cap,
/// reserved R, reclaimable Q): <hint>`). Plan B Task 9.
fn renderStoreFull(s: *store.Store) void {
    const bd = s.lastFull();
    std.debug.print("rime: store full admitting {d} to {s} (budget {d}, {s} {d}/{d}, reserved {d}, reclaimable {d}): {s}\n", .{
        bd.requested_bytes,
        @tagName(bd.class),
        bd.budget,
        @tagName(bd.class),
        bd.used_class,
        bd.cap_class,
        bd.reserved_class,
        bd.reclaimable_class,
        @tagName(bd.hint),
    });
}

/// True when (key, value) exactly equals any `k=v` filter (§12.1).
fn statFilterMatch(filters: []const []const u8, key: []const u8, value: []const u8) bool {
    for (filters) |f| {
        const eq = std.mem.indexOfScalar(u8, f, '=') orelse continue;
        if (std.mem.eql(u8, f[0..eq], key) and std.mem.eql(u8, f[eq + 1 ..], value)) return true;
    }
    return false;
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
    // `--tag k=v` scopes map to store.Tag; empty stays unscoped (null) so
    // plain `gc` never hits the tag-query newest-1,000 bound. Plan B Task 11.
    const tf = gpa.alloc(store.Tag, p.tags.len) catch |e| {
        std.debug.print("rime: gc failed: {t}\n", .{e});
        return 1;
    };
    defer gpa.free(tf);
    for (p.tags, 0..) |t, i| tf[i] = .{ .key = t.key, .value = t.value };
    const report = s.gc(io, gpa, .{
        .dry_run = p.dry_run,
        .target_bytes = p.target_bytes,
        .older_than_ns = p.older_than_ns,
        .tag_filter = if (tf.len == 0) null else tf,
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
        // Admission detail (§10.4 exact fields verbatim). A cache-write
        // StoreFull never fails a build (callers fall back to spool), but
        // the CLI surfaces what is full and what would free space.
        // Plan B Task 9.
        if (e == error.StoreFull) renderStoreFull(s);
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

test "parseCommand routes cargo subcommands" {
    const gpa = std.testing.allocator;
    const c = try parseCommand(gpa, &.{ "build", "--dry-run" });
    defer {
        c.cargo.opts.deinit(gpa);
        gpa.free(c.cargo.argv);
    }
    try std.testing.expect(c == .cargo);
    try std.testing.expect(c.cargo.opts.dry_run);
    try std.testing.expectError(error.Usage, parseCommand(gpa, &.{"build", "--warp-drive"}));
}

test "parseCommand covers the surface" {
    const gpa = std.testing.allocator;
    try std.testing.expect((try parseCommand(gpa, &.{ "cache", "stat" })) == .stat);
    const c = try parseCommand(gpa, &.{ "gc", "--dry-run", "--to-size", "5GiB" });
    try std.testing.expect(c.gc.dry_run);
    try std.testing.expectEqual(@as(?u64, 5 * store.config.GiB), c.gc.target_bytes);
    try std.testing.expectError(error.Usage, parseCommand(gpa, &.{"nonsense"}));
    // Plan B Task 11: `cache stat --by-tag [k=v]` and repeatable `gc --tag`.
    // (Owned filter/tag arrays are freed; tagless commands allocate nothing.)
    const st = try parseCommand(gpa, &.{ "cache", "stat", "--by-tag", "profile=release" });
    defer gpa.free(st.stat.filters);
    try std.testing.expect(st == .stat);
    try std.testing.expect(st.stat.by_tag);
    try std.testing.expectEqual(@as(usize, 1), st.stat.filters.len);
    const gt = try parseCommand(gpa, &.{ "gc", "--tag", "project=projA", "--tag", "user.a=b" });
    defer gpa.free(gt.gc.tags);
    try std.testing.expectEqual(@as(usize, 2), gt.gc.tags.len);
}

test "leading globals hoist after the command" {
    const gpa = std.testing.allocator;
    const hoisted = try hoistLeadingGlobals(gpa, &.{ "-v", "build", "--dry-run" });
    defer gpa.free(hoisted);
    try std.testing.expectEqualStrings("build", hoisted[0]);
    try std.testing.expectEqualStrings("-v", hoisted[1]);
    try std.testing.expectEqualStrings("--dry-run", hoisted[2]);
    const c = try parseCommand(gpa, hoisted);
    defer {
        c.cargo.opts.deinit(gpa);
        gpa.free(c.cargo.argv);
    }
    try std.testing.expectEqual(@as(u32, 1), c.cargo.opts.verbose);
}

test "leading unknown flags fall through to usage" {
    const gpa = std.testing.allocator;
    const hoisted = try hoistLeadingGlobals(gpa, &.{ "--warp-drive", "build" });
    defer gpa.free(hoisted);
    try std.testing.expectEqualStrings("--warp-drive", hoisted[0]);
    try std.testing.expectError(error.Usage, parseCommand(gpa, hoisted));
}

test "gc help points at clean and stat" {
    const text = gcHelp();
    try std.testing.expect(std.mem.indexOf(u8, text, "rime clean") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Does not touch project target/ views") != null);
}

test "clean help points at gc" {
    const text = cargoCleanHelp();
    try std.testing.expect(std.mem.indexOf(u8, text, "rime gc --help") != null);
}

test "cargo helps carry divergence trailers" {
    try std.testing.expect(std.mem.indexOf(u8, cargoBuildHelp(), "Note:") != null);
    try std.testing.expect(std.mem.indexOf(u8, cargoTestHelp(), "Note:") != null);
    try std.testing.expect(std.mem.indexOf(u8, cargoRunHelp(), "Note:") != null);
    try std.testing.expect(std.mem.indexOf(u8, cargoBenchHelp(), "Note:") != null);
    try std.testing.expect(std.mem.indexOf(u8, cargoFetchHelp(), "Note:") != null);
    try std.testing.expect(std.mem.indexOf(u8, cargoCheckHelp(), "Note:") != null);
}
