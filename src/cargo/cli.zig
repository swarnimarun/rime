/// Cargo CLI surface (Plan C Task 5): commands, flags, exit codes, and the
/// `--message-format=json` envelope. Build-like commands (`build`, `check`,
/// `test`, `run`, `bench`) share one M1 path: discover the workspace,
/// print the unit plan, and materialize the view skeleton. `run` arg
/// forwarding and real execution land in M6; until then extra args parse
/// and are ignored.

const std = @import("std");
const builtin = @import("builtin");
const store_mod = @import("store");
const workspace_mod = @import("workspace.zig");
const view_mod = @import("view.zig");

const Workspace = workspace_mod.Workspace;

pub const Command = enum { build, check, test_cmd, run, bench, clean };
pub const MessageFormat = enum { human, json };

pub const Options = struct {
    cmd: Command,
    manifest_path: ?[]const u8,
    profile: []const u8, // "dev" default; "release" with --release; custom via --profile
    explicit_profile: bool, // true with --release/--profile (clean uses it to scope target/<profile>/)
    target_triple: ?[]const u8, // --target
    only_package: ?[]const u8, // -p/--package (limits the plan to the member + its path-deps)
    features: []const []const u8,
    message_format: MessageFormat,
    offline: bool,
    frozen: bool,
    locked: bool,
    dry_run: bool, // M1-only planning flag (prints unit plan, writes view skeleton)
    extra_args: []const []const u8, // trailing args after -- (for run/test/bench)

    /// Frees the two gpa-owned slices (`features`, `extra_args`); every
    /// other field borrows `argv`/statics and must NOT be freed.
    pub fn deinit(self: *const Options, gpa: std.mem.Allocator) void {
        gpa.free(self.features);
        gpa.free(self.extra_args);
    }
};

pub const CliError = error{ Usage, OutOfMemory };
pub const ExitCode = struct {
    pub const ok: u8 = 0;
    pub const usage: u8 = 1;
    pub const build_failed: u8 = 101;
};

/// Last `parseArgs` failure detail (the plan requires `error: unknown flag
/// '--foo'` on stderr, but `CliError.Usage` carries no payload). Fixed
/// buffer, truncated on overflow; read via `parseDiagnostic()`.
var diag_buf: [256]u8 = undefined;
var diag_len: usize = 0;

pub fn parseDiagnostic() ?[]const u8 {
    if (diag_len == 0) return null;
    return diag_buf[0..diag_len];
}

fn fail(comptime fmt: []const u8, args: anytype) CliError {
    const msg = std.fmt.bufPrint(&diag_buf, fmt, args) catch &diag_buf;
    diag_len = msg.len;
    return CliError.Usage;
}

pub const JsonEnvelope = struct {
    reason: []const u8, // "unit-plan" | "build-finished" | "compiler-message"
    package: []const u8,
    target: []const u8,
    profile: []const u8,
    success: bool,

    /// Single-line JSON (struct field order above is the wire order) + `\n`.
    pub fn writeLine(self: *const JsonEnvelope, w: *std.Io.Writer) !void {
        try std.json.Stringify.value(self.*, .{}, w);
        try w.writeAll("\n");
    }
};

/// Parses `argv` with `argv[0]` the program name and `argv[1]` the command.
/// Accepts exact cargo spellings including `--flag=value` and `--flag value`
/// forms. Owns `features`/`extra_args` (see `Options.deinit`).
pub fn parseArgs(gpa: std.mem.Allocator, argv: []const []const u8) CliError!Options {
    diag_len = 0;
    if (argv.len < 2) return fail("usage: rime <build|check|test|run|bench|clean> […]\n", .{});
    const cmd: Command = if (std.mem.eql(u8, argv[1], "build"))
        .build
    else if (std.mem.eql(u8, argv[1], "check"))
        .check
    else if (std.mem.eql(u8, argv[1], "test"))
        .test_cmd
    else if (std.mem.eql(u8, argv[1], "run"))
        .run
    else if (std.mem.eql(u8, argv[1], "bench"))
        .bench
    else if (std.mem.eql(u8, argv[1], "clean"))
        .clean
    else
        return fail("unknown command '{s}'", .{argv[1]});

    var opts = Options{
        .cmd = cmd,
        .manifest_path = null,
        .profile = "dev",
        .explicit_profile = false,
        .target_triple = null,
        .only_package = null,
        .features = &.{},
        .message_format = .human,
        .offline = false,
        .frozen = false,
        .locked = false,
        .dry_run = false,
        .extra_args = &.{},
    };
    var features: std.ArrayList([]const u8) = .empty;
    defer features.deinit(gpa);
    var extra: std.ArrayList([]const u8) = .empty;
    defer extra.deinit(gpa);

    var i: usize = 2;
    var passthrough = false;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (passthrough) {
            try extra.append(gpa, a);
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            passthrough = true;
            continue;
        }
        const flag, const inline_val = splitFlag(a);
        if (flag == null) {
            return fail("unexpected argument '{s}'", .{a});
        }
        const f = flag.?;
        if (isCleanOnlyReject(cmd, f)) {
            return fail("flag '{s}' is not supported for clean in M1", .{f});
        }
        if (std.mem.eql(u8, f, "--manifest-path")) {
            opts.manifest_path = try takeValue(gpa, argv, &i, inline_val, "--manifest-path");
        } else if (std.mem.eql(u8, f, "--release")) {
            if (inline_val != null) return fail("flag '--release' takes no value", .{});
            if (opts.explicit_profile) return fail("cannot specify both --release and --profile", .{});
            opts.profile = "release";
            opts.explicit_profile = true;
        } else if (std.mem.eql(u8, f, "--profile")) {
            const v = try takeValue(gpa, argv, &i, inline_val, "--profile");
            if (opts.explicit_profile) return fail("cannot specify both --release and --profile", .{});
            opts.profile = v;
            opts.explicit_profile = true;
        } else if (std.mem.eql(u8, f, "--target")) {
            opts.target_triple = try takeValue(gpa, argv, &i, inline_val, "--target");
        } else if (std.mem.eql(u8, f, "--features")) {
            const v = try takeValue(gpa, argv, &i, inline_val, "--features");
            var csv = std.mem.splitScalar(u8, v, ',');
            while (csv.next()) |feat| try features.append(gpa, feat);
        } else if (std.mem.eql(u8, f, "--message-format")) {
            const v = try takeValue(gpa, argv, &i, inline_val, "--message-format");
            if (std.mem.eql(u8, v, "json")) {
                opts.message_format = .json;
            } else if (std.mem.eql(u8, v, "human")) {
                opts.message_format = .human;
            } else {
                return fail("unknown message format '{s}'", .{v});
            }
        } else if (std.mem.eql(u8, f, "--offline")) {
            if (inline_val != null) return fail("flag '--offline' takes no value", .{});
            opts.offline = true;
        } else if (std.mem.eql(u8, f, "--frozen")) {
            if (inline_val != null) return fail("flag '--frozen' takes no value", .{});
            opts.frozen = true;
        } else if (std.mem.eql(u8, f, "--locked")) {
            if (inline_val != null) return fail("flag '--locked' takes no value", .{});
            opts.locked = true;
        } else if (std.mem.eql(u8, f, "--dry-run")) {
            if (inline_val != null) return fail("flag '--dry-run' takes no value", .{});
            opts.dry_run = true;
        } else if (std.mem.eql(u8, f, "-p") or std.mem.eql(u8, f, "--package")) {
            opts.only_package = try takeValue(gpa, argv, &i, inline_val, f);
        } else {
            return fail("unknown flag '{s}'", .{f});
        }
    }

    opts.features = try features.toOwnedSlice(gpa);
    opts.extra_args = try extra.toOwnedSlice(gpa);
    return opts;
}

/// Splits `--flag=value` into (`--flag`, `value`); bare `--flag`/`-p` into
/// (`--flag`, null); non-flags into (null, null).
fn splitFlag(arg: []const u8) struct { ?[]const u8, ?[]const u8 } {
    if (arg.len < 2 or arg[0] != '-') return .{ null, null };
    if (arg[1] != '-') {
        // Short flags: only -p takes a value in M1.
        if (std.mem.eql(u8, arg, "-p")) return .{ "-p", null };
        if (arg.len > 2 and std.mem.eql(u8, arg[0..2], "-p")) return .{ null, null };
        return .{ null, null };
    }
    if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
        return .{ arg[0..eq], arg[eq + 1 ..] };
    }
    return .{ arg, null };
}

fn takeValue(gpa: std.mem.Allocator, argv: []const []const u8, i: *usize, inline_val: ?[]const u8, flag: []const u8) CliError![]const u8 {
    _ = gpa;
    if (inline_val) |v| {
        if (v.len == 0) return fail("missing value for '{s}'", .{flag});
        return v;
    }
    i.* += 1;
    if (i.* >= argv.len) return fail("missing value for '{s}'", .{flag});
    return argv[i.*];
}

/// Flags clean rejects in M1 (`-p` arrives properly in M6).
fn isCleanOnlyReject(cmd: Command, flag: []const u8) bool {
    if (cmd != .clean) return false;
    return std.mem.eql(u8, flag, "-p") or std.mem.eql(u8, flag, "--package") or
        std.mem.eql(u8, flag, "--features") or std.mem.eql(u8, flag, "--target") or
        std.mem.eql(u8, flag, "--dry-run");
}

/// Entry point used by `src/main.zig`. JSON lines go to `stdout` (pipe-clean);
/// human rendering and every error go to `stderr`. Returns a cargo exit code.
pub fn run(gpa: std.mem.Allocator, io: std.Io, opts: Options, stdout: *std.Io.Writer, stderr: *std.Io.Writer) u8 {
    if (opts.cmd == .clean) return runClean(gpa, io, opts, stderr);
    return runBuild(gpa, io, opts, stdout, stderr);
}

fn runBuild(gpa: std.mem.Allocator, io: std.Io, opts: Options, stdout: *std.Io.Writer, stderr: *std.Io.Writer) u8 {
    var ws = loadWorkspace(gpa, io, opts, stderr) orelse return ExitCode.usage;
    defer ws.deinit();

    // --frozen/--locked (M1): require the lockfile only when the workspace
    // actually has registry deps; pure-path workspaces are unaffected.
    if ((opts.frozen or opts.locked) and ws.lock == null and hasExternalDeps(&ws)) {
        stderr.print("error: --frozen/--locked requires Cargo.lock, but none was found\n", .{}) catch {};
        return ExitCode.usage;
    }

    const units = view_mod.planUnits(gpa, &ws, opts.only_package) catch |e| {
        if (e == error.OutOfMemory) {
            stderr.print("error: out of memory\n", .{}) catch {};
            return ExitCode.usage;
        }
        if (opts.only_package) |name| {
            stderr.print("error: package not found: {s}\n", .{name}) catch {};
        } else {
            stderr.print("error: cannot compute build plan\n", .{}) catch {};
        }
        return ExitCode.usage;
    };
    defer gpa.free(units);

    // Unit plan: one envelope line per unit (json/stdout) or Compiling lines
    // (human/stderr), dependencies first.
    for (units) |u| {
        if (opts.message_format == .json) {
            const env = JsonEnvelope{
                .reason = "unit-plan",
                .package = u.package,
                .target = u.target,
                .profile = opts.profile,
                .success = true,
            };
            env.writeLine(stdout) catch {
                stderr.print("error: failed to write output\n", .{}) catch {};
                return ExitCode.usage;
            };
        } else {
            stderr.print("Compiling {s} v{s} ({s})\n", .{ u.package, u.version, u.target }) catch {};
        }
    }

    // D5: declarations parse, but any command needing the source errors
    // `need source` (exit 1). --dry-run only inspects the plan.
    if (!opts.dry_run) {
        if (firstExternalDep(gpa, &ws)) |name| {
            stderr.print("need source: {s} requires M2 fetch; re-run with --dry-run to inspect the plan\n", .{name}) catch {};
            return ExitCode.usage;
        }
    }

    // View skeleton (M1: null digests, so fingerprint stubs + metas only).
    // The store opens lazily here: plan inspection never touches it.
    var holder = openCargoStore(gpa, io) catch {
        stderr.print("error: cannot open store\n", .{}) catch {};
        return ExitCode.usage;
    };
    defer holder.close(io);
    view_mod.materializeOutputs(gpa, io, holder.store(), ws.root_dir, opts.profile, units) catch |e| {
        stderr.print("error: failed to materialize target view: {t}\n", .{e}) catch {};
        return ExitCode.usage;
    };
    view_mod.writeViewMeta(gpa, io, ws.root_dir, opts.profile, units) catch |e| {
        stderr.print("error: failed to write view metadata: {t}\n", .{e}) catch {};
        return ExitCode.usage;
    };

    if (opts.message_format == .json) {
        const done = JsonEnvelope{
            .reason = "build-finished",
            .package = "",
            .target = "",
            .profile = opts.profile,
            .success = true,
        };
        done.writeLine(stdout) catch {
            stderr.print("error: failed to write output\n", .{}) catch {};
            return ExitCode.usage;
        };
    } else {
        stderr.print("Finished {s} profile\n", .{opts.profile}) catch {};
    }
    return ExitCode.ok;
}

fn runClean(gpa: std.mem.Allocator, io: std.Io, opts: Options, stderr: *std.Io.Writer) u8 {
    var ws = loadWorkspace(gpa, io, opts, stderr) orelse return ExitCode.usage;
    defer ws.deinit();
    const profile: ?[]const u8 = if (opts.explicit_profile) opts.profile else null;
    view_mod.clean(gpa, io, ws.root_dir, profile) catch {
        stderr.print("error: clean failed\n", .{}) catch {};
        return ExitCode.usage;
    };
    return ExitCode.ok;
}

/// Discovers the workspace for `run`/`clean`. All failures carry exit code
/// 1 with the reason on stderr; null means "already reported".
fn loadWorkspace(gpa: std.mem.Allocator, io: std.Io, opts: Options, stderr: *std.Io.Writer) ?Workspace {
    if (opts.manifest_path) |mp| {
        const ws = workspace_mod.discover(gpa, io, ".", mp) catch |e| {
            // Explicit path that names no file reads as "could not find";
            // genuine parse failures read as invalid.
            if (e == error.InvalidManifest and !existsFile(io, mp)) {
                stderr.print("error: could not find Cargo.toml: {s}\n", .{mp}) catch {};
            } else {
                stderr.print("error: invalid manifest: {s}: {t}\n", .{ mp, e }) catch {};
            }
            return null;
        };
        return ws;
    }
    const cwd = std.process.currentPathAlloc(io, gpa) catch {
        stderr.print("error: cannot determine current directory\n", .{}) catch {};
        return null;
    };
    defer gpa.free(cwd);
    const ws = workspace_mod.discover(gpa, io, cwd, null) catch |e| {
        switch (e) {
            error.NoWorkspace => stderr.print("error: could not find Cargo.toml in '{s}' or any parent directory\n", .{cwd}) catch {},
            error.Cycle => stderr.print("error: cyclic package dependency between workspace members\n", .{}) catch {},
            error.UnsupportedKey => stderr.print("error: unsupported manifest key (outside the M1 surface)\n", .{}) catch {},
            else => stderr.print("error: invalid manifest near '{s}': {t}\n", .{ cwd, e }) catch {},
        }
        return null;
    };
    return ws;
}

fn existsFile(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

/// True when any member declares a non-path dependency (registry, git, or
/// still-unresolved workspace-inherit — the latter cannot survive discover,
/// so this is belt-and-braces).
fn hasExternalDeps(ws: *const Workspace) bool {
    for (ws.members) |*m| {
        var it = m.manifest.deps.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.* != .path) return true;
        }
    }
    return false;
}

/// Deterministically first external dep name (sorted; map order is not).
fn firstExternalDep(gpa: std.mem.Allocator, ws: *const Workspace) ?[]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    for (ws.members) |*m| {
        var it = m.manifest.deps.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.* == .path) continue;
            names.append(gpa, kv.key_ptr.*) catch return null;
        }
    }
    if (names.items.len == 0) return null;
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return names.items[0];
}

const StoreHolder = struct {
    dir: std.Io.Dir,
    s: store_mod.Store,

    pub fn store(self: *StoreHolder) *store_mod.Store {
        return &self.s;
    }

    pub fn close(self: *StoreHolder, io: std.Io) void {
        self.s.close(io);
        self.dir.close(io);
    }
};

/// Lazily opens the global store (same location rule as main.zig's
/// `openStoreDir`, but driven by libc env since `run` receives no env map).
fn openCargoStore(gpa: std.mem.Allocator, io: std.Io) !StoreHolder {
    const dir = try openStoreDir(gpa, io);
    errdefer dir.close(io);
    const s = try store_mod.Store.open(io, dir, .{});
    return .{ .dir = dir, .s = s };
}

fn openStoreDir(gpa: std.mem.Allocator, io: std.Io) !std.Io.Dir {
    if (std.c.getenv("RIME_CACHE_DIR")) |p| {
        return std.Io.Dir.cwd().createDirPathOpen(io, std.mem.span(p), .{});
    }
    const home_z = std.c.getenv("HOME");
    const home: []const u8 = if (home_z) |h| std.mem.span(h) else ".";
    const base: []const u8 = switch (builtin.os.tag) {
        .macos => try std.fmt.allocPrint(gpa, "{s}/Library/Caches", .{home}),
        .linux => if (std.c.getenv("XDG_CACHE_HOME")) |x|
            try gpa.dupe(u8, std.mem.span(x))
        else
            try std.fmt.allocPrint(gpa, "{s}/.cache", .{home}),
        else => @compileError("rime supports macOS and Linux only"),
    };
    defer gpa.free(base);
    const full = try std.fmt.allocPrint(gpa, "{s}/rime", .{base});
    defer gpa.free(full);
    return std.Io.Dir.cwd().createDirPathOpen(io, full, .{});
}

test "cli parses build with release and json" {
    const argv = [_][]const u8{ "rime", "build", "--release", "--message-format=json" };
    var opts = try parseArgs(std.testing.allocator, &argv);
    defer opts.deinit(std.testing.allocator);
    try std.testing.expect(opts.cmd == .build);
    try std.testing.expectEqualStrings("release", opts.profile);
    try std.testing.expect(opts.message_format == .json);
}

test "cli rejects unknown flags with usage error" {
    const argv = [_][]const u8{ "rime", "build", "--warp-drive" };
    try std.testing.expectError(CliError.Usage, parseArgs(std.testing.allocator, &argv));
    try std.testing.expect(parseDiagnostic() != null);
    try std.testing.expect(std.mem.indexOf(u8, parseDiagnostic().?, "--warp-drive") != null);
}

test "cli splits run passthrough args" {
    const argv = [_][]const u8{ "rime", "run", "-p", "a", "--", "--hello", "world" };
    var opts = try parseArgs(std.testing.allocator, &argv);
    defer opts.deinit(std.testing.allocator);
    try std.testing.expect(opts.cmd == .run);
    try std.testing.expectEqual(@as(usize, 2), opts.extra_args.len);
    try std.testing.expectEqualStrings("a", opts.only_package.?);
}

test "cli parses equals forms and csv features" {
    const argv = [_][]const u8{ "rime", "check", "--profile=release", "--target=x86_64-unknown-linux-gnu", "--features=a,b", "--features", "c", "--manifest-path", "x/Cargo.toml" };
    var opts = try parseArgs(std.testing.allocator, &argv);
    defer opts.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("release", opts.profile);
    try std.testing.expect(opts.explicit_profile);
    try std.testing.expectEqualStrings("x86_64-unknown-linux-gnu", opts.target_triple.?);
    try std.testing.expectEqual(@as(usize, 3), opts.features.len);
    try std.testing.expectEqualStrings("x/Cargo.toml", opts.manifest_path.?);
}

test "cli envelope writes one line of json" {
    var out: std.Io.Writer.Allocating = try .initCapacity(std.testing.allocator, 128);
    defer out.deinit();
    const env = JsonEnvelope{ .reason = "unit-plan", .package = "b", .target = "b", .profile = "dev", .success = true };
    try env.writeLine(&out.writer);
    const bytes = try out.toOwnedSlice();
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("{\"reason\":\"unit-plan\",\"package\":\"b\",\"target\":\"b\",\"profile\":\"dev\",\"success\":true}\n", bytes);
}

test "run clean on empty dir reports no workspace" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);
    const mp = try std.fmt.allocPrint(std.testing.allocator, "{s}/Cargo.toml", .{dir_path});
    defer std.testing.allocator.free(mp);
    const argv = [_][]const u8{ "rime", "clean", "--manifest-path", mp };
    var opts = try parseArgs(std.testing.allocator, &argv);
    defer opts.deinit(std.testing.allocator);
    var err: std.Io.Writer.Allocating = try .initCapacity(std.testing.allocator, 256);
    defer err.deinit();
    var out: std.Io.Writer.Allocating = try .initCapacity(std.testing.allocator, 64);
    defer out.deinit();
    const code = run(std.testing.allocator, io, opts, &out.writer, &err.writer);
    try std.testing.expectEqual(ExitCode.usage, code);
    const msg = try err.toOwnedSlice();
    defer std.testing.allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "could not find") != null);
}

test "run build without dry-run reports need source" {
    const io = std.Io.Threaded.global_single_threaded.io();
    // The minimal fixture declares registry `serde`: building (not planning)
    // must fail loud with exit 1 before touching the store.
    const argv = [_][]const u8{ "rime", "build", "--manifest-path", "testdata/cargo/minimal/Cargo.toml" };
    var opts = try parseArgs(std.testing.allocator, &argv);
    defer opts.deinit(std.testing.allocator);
    var err: std.Io.Writer.Allocating = try .initCapacity(std.testing.allocator, 512);
    defer err.deinit();
    var out: std.Io.Writer.Allocating = try .initCapacity(std.testing.allocator, 64);
    defer out.deinit();
    const code = run(std.testing.allocator, io, opts, &out.writer, &err.writer);
    try std.testing.expectEqual(ExitCode.usage, code);
    const msg = try err.toOwnedSlice();
    defer std.testing.allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "need source: serde") != null);
}
