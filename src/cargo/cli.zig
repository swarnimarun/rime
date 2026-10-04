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
const pipeline_mod = @import("pipeline.zig");
const toolchain_mod = @import("toolchain.zig");

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
    all_features: bool, // --all-features (takes no value)
    no_default_features: bool, // --no-default-features (takes no value)
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
    reason: []const u8, // "unit-plan" | "build-finished" | "compiler-message" | "compiler-artifact"
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
        .all_features = false,
        .no_default_features = false,
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
        } else if (std.mem.eql(u8, f, "--all-features")) {
            if (inline_val != null) return fail("flag '--all-features' takes no value", .{});
            opts.all_features = true;
        } else if (std.mem.eql(u8, f, "--no-default-features")) {
            if (inline_val != null) return fail("flag '--no-default-features' takes no value", .{});
            opts.no_default_features = true;
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

    // Real builds go through the M4 driver pipeline (fetch → resolve →
    // compile → materialize); --dry-run keeps the M1 plan-print path below.
    if (!opts.dry_run) {
        return runPipelineBuild(gpa, io, &ws, opts, stdout, stderr);
    }

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

    // --dry-run prints only the unit plan above (the golden byte-compares
    // it); the finished envelope belongs to real runs.
    if (!opts.dry_run) {
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
    }
    return ExitCode.ok;
}

/// M4 driver dispatch (Tasks 10–11): `build`/`test`/`run`/`bench` compile
/// through the pipeline in build mode, `check` in rmeta-only check mode.
/// (Binary execution for `run` stays M6; `run` currently verifies the build.)
/// Exit codes: 0 ok, 101 rustc failure (diagnostics already emitted),
/// 1 usage/config/fetch/lock failures.
fn runPipelineBuild(gpa: std.mem.Allocator, io: std.Io, ws: *const Workspace, opts: Options, stdout: *std.Io.Writer, stderr: *std.Io.Writer) u8 {
    var holder = openCargoStore(gpa, io) catch {
        stderr.print("error: cannot open store\n", .{}) catch {};
        return ExitCode.usage;
    };
    defer holder.close(io);
    var tc = toolchain_mod.probeToolchain(gpa, io, null) catch |e| {
        stderr.print("error: rustc probe failed ({t}); install rustc or set $RUSTC\n", .{e}) catch {};
        return ExitCode.usage;
    };
    defer tc.deinit(gpa);
    const cache_dir = cacheRoot(gpa) catch {
        stderr.print("error: cannot determine cache directory\n", .{}) catch {};
        return ExitCode.usage;
    };
    defer gpa.free(cache_dir);
    const popts = pipeline_mod.PipelineOptions{
        .manifest_path = opts.manifest_path,
        .profile_name = opts.profile,
        .target_triple = opts.target_triple,
        .features_cli = opts.features,
        .all_features = opts.all_features,
        .no_default = opts.no_default_features,
        .mode = if (opts.cmd == .check) .check else .build,
        .message_format_json = opts.message_format == .json,
        .offline = opts.offline,
        .frozen = opts.frozen,
        .locked = opts.locked,
        .only_package = opts.only_package,
        .cache_dir = cache_dir,
    };
    const code = pipeline_mod.buildWorkspace(gpa, io, holder.store(), ws.root_dir, ws, &tc, popts, stdout, stderr) catch |e| {
        return renderPipelineError(e, stderr);
    };
    return code;
}

fn renderPipelineError(e: pipeline_mod.PipelineError, stderr: *std.Io.Writer) u8 {
    switch (e) {
        // Diagnostics already emitted; the code IS the message.
        error.RustcFailed => return ExitCode.build_failed,
        error.NeedFetch => {
            stderr.print("need source: {s}\n", .{pipeline_mod.planDiagnostic() orelse "unknown crate"}) catch {};
            return ExitCode.usage;
        },
        error.LockedViolation, error.Usage => {
            stderr.print("error: {s}\n", .{pipeline_mod.planDiagnostic() orelse @errorName(e)}) catch {};
            return ExitCode.usage;
        },
        else => {
            stderr.print("error: build failed: {t}\n", .{e}) catch {};
            return ExitCode.usage;
        },
    }
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

/// Cache root (the rime dir itself): `$RIME_CACHE_DIR`, else
/// `<cache home>/rime`. gpa-owned (caller frees). The store opens here
/// and the pipeline derives its spool + fetch-cache dirs from it.
fn cacheRoot(gpa: std.mem.Allocator) ![]u8 {
    if (std.c.getenv("RIME_CACHE_DIR")) |p| {
        return try gpa.dupe(u8, std.mem.span(p));
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
    return try std.fmt.allocPrint(gpa, "{s}/rime", .{base});
}

fn openStoreDir(gpa: std.mem.Allocator, io: std.Io) !std.Io.Dir {
    const root = try cacheRoot(gpa);
    defer gpa.free(root);
    return std.Io.Dir.cwd().createDirPathOpen(io, root, .{});
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

test "cli check dispatches check mode" {
    const argv = [_][]const u8{ "rime", "check", "--message-format=json" };
    var opts = try parseArgs(std.testing.allocator, &argv);
    defer opts.deinit(std.testing.allocator);
    try std.testing.expect(opts.cmd == .check);
    try std.testing.expect(opts.message_format == .json);
}

test "cli parses all-features flags" {
    const argv = [_][]const u8{ "rime", "build", "--all-features", "--no-default-features", "--features", "a,b" };
    var opts = try parseArgs(std.testing.allocator, &argv);
    defer opts.deinit(std.testing.allocator);
    try std.testing.expect(opts.all_features);
    try std.testing.expect(opts.no_default_features);
    try std.testing.expectEqual(@as(usize, 2), opts.features.len);
    const bad = [_][]const u8{ "rime", "build", "--all-features=x" };
    try std.testing.expectError(CliError.Usage, parseArgs(std.testing.allocator, &bad));
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

test "e2e dry-run plan matches golden" {
    // The golden pins the wire order (dependencies first, envelope field
    // order as JsonEnvelope.writeLine emits). It carries the profile NAME
    // (dev); the DIR mapping (debug) lives in view.profileDirName.
    const io = std.Io.Threaded.global_single_threaded.io();
    var ws = try workspace_mod.discover(std.testing.allocator, io, "testdata/cargo/workspace", null);
    defer ws.deinit();
    const units = try view_mod.planUnits(std.testing.allocator, &ws, null);
    defer std.testing.allocator.free(units);
    var out: std.Io.Writer.Allocating = try .initCapacity(std.testing.allocator, 256);
    defer out.deinit();
    for (units) |u| {
        const env = JsonEnvelope{ .reason = "unit-plan", .package = u.package, .target = u.target, .profile = "dev", .success = true };
        try env.writeLine(&out.writer);
    }
    const got = try out.toOwnedSlice();
    defer std.testing.allocator.free(got);
    // Runtime read (not @embedFile): the golden escapes the module package
    // path, matching the read convention in manifest/lock tests.
    const want = try std.Io.Dir.cwd().readFileAlloc(io, "testdata/cargo/golden/plan.json", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(want);
    try std.testing.expectEqualStrings(want, got);
}

test "e2e dry-run human order lists dependencies first" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var ws = try workspace_mod.discover(std.testing.allocator, io, "testdata/cargo/workspace", null);
    defer ws.deinit();
    const units = try view_mod.planUnits(std.testing.allocator, &ws, null);
    defer std.testing.allocator.free(units);
    var out: std.Io.Writer.Allocating = try .initCapacity(std.testing.allocator, 256);
    defer out.deinit();
    for (units) |u| {
        try out.writer.print("Compiling {s} v{s}\n", .{ u.package, u.version });
    }
    const got = try out.toOwnedSlice();
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("Compiling b v0.1.0\nCompiling a v0.1.0\n", got);
}

test "run build without dry-run reports need source" {
    // Registry-only scratch fixture (minimal/ also declares a DANGLING
    // path dep, which correctly fails earlier — see the next test):
    // building must fail loud with exit 1 naming the registry crate.
    const gpa = std.testing.allocator;
    // Spawn-capable io: runPipelineBuild probes the real toolchain, and
    // `global_single_threaded` cannot spawn (failing allocator).
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = "/tmp/rime-cli-needfetch";
    std.Io.Dir.cwd().createDirPath(io, dir) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return error.Io;
    };
    const manifest_path = try std.fmt.allocPrint(gpa, "{s}/Cargo.toml", .{dir});
    defer gpa.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = manifest_path,
        .data = "[package]\nname = \"cli-needfetch\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n[dependencies]\nserde = \"1\"\n\n[lib]\nname = \"cli_needfetch\"\npath = \"src/lib.rs\"\n",
    });
    const src_dir = try std.fmt.allocPrint(gpa, "{s}/src", .{dir});
    defer gpa.free(src_dir);
    std.Io.Dir.cwd().createDirPath(io, src_dir) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return error.Io;
    };
    const lib_path = try std.fmt.allocPrint(gpa, "{s}/src/lib.rs", .{dir});
    defer gpa.free(lib_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = lib_path, .data = "pub fn f() {}\n" });
    const argv = [_][]const u8{ "rime", "build", "--manifest-path", manifest_path };
    var opts = try parseArgs(std.testing.allocator, &argv);
    defer opts.deinit(std.testing.allocator);
    var err: std.Io.Writer.Allocating = try .initCapacity(std.testing.allocator, 512);
    defer err.deinit();
    var out: std.Io.Writer.Allocating = try .initCapacity(std.testing.allocator, 64);
    defer out.deinit();
    const code = run(std.testing.allocator, io, opts, &out.writer, &err.writer);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.testing.expectEqual(ExitCode.usage, code);
    const msg = try err.toOwnedSlice();
    defer std.testing.allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "need source: serde") != null);
}

test "run build reports dangling path dependencies" {
    // minimal/ declares path `../rime-dep`, which does not exist: the M4
    // driver fails loud (exit 1) naming it instead of attempting a build.
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
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
    try std.testing.expect(std.mem.indexOf(u8, msg, "rime-dep") != null);
}

// =====================================================================
// Task 9 (CLI half): --locked/--frozen/--offline enforcement + lock check.
//
// Reference pins:
// - `ops/lockfile.rs::write_pkg_lockfile` (order: equality check FIRST --
//   up-to-date + `--locked` = success, not error -- then the locked bail;
//   copy of the `cannot {update,create} the lock file {path} because
//   {flag} was passed to prevent this` wording, which the M4 driver
//   renders; this module owns the MODE taxonomy + the semantic compare).
// - `are_equal_lockfiles` (semantic compare: decoded-graph equality, NOT
//   bytes -- comment/whitespace/edge-shortening diffs stay up_to_date).
// - `ops/resolve.rs::lock_update_allowed` + `generate_lockfile.rs`
//   testsuite (`--locked` failure exit + message; `--offline` success with
//   a complete lock).
// - `dep_cache.rs::describe_path_in_context` + `resolver/errors.rs`
//   (resolve-side `Diag` text lives in `resolve.zig::formatDiag`, settled;
//   the offline-missing DIAGNOSIS is produced by the M4 resolve driver
//   when the registry seam serves zero candidates under offline/frozen).

const resolve_mod = @import("resolve.zig");
const lock_mod = @import("lock.zig");
const semver_mod = @import("semver.zig");
const sources_mod = @import("sources.zig");

/// `--locked` reproduces the existing lock exactly (mismatch = bail, no
/// write); `--frozen` = `--locked` + `--offline`; `--offline` resolves
/// freely but never hits the network seam.
pub const LockMode = enum { normal, locked, frozen, offline };

/// Frozen is its own flag but semantically locked+offline: an explicit
/// `--locked --offline` pair maps to `.frozen` too (equivalent behavior,
/// one taxonomy).
pub fn lockModeFrom(opts: Options) LockMode {
    if (opts.frozen or (opts.locked and opts.offline)) return .frozen;
    if (opts.locked) return .locked;
    if (opts.offline) return .offline;
    return .normal;
}

/// Only normal|locked may touch the network seam (frozen/offline never do).
pub fn needsNetwork(mode: LockMode) bool {
    return mode == .normal or mode == .locked;
}

pub const LockCheck = enum { up_to_date, would_change, offline_missing };

/// Semantic lock comparison (`are_equal_lockfiles`): null or malformed
/// previous text is `would_change` (cargo picks the "create" wording when
/// the file is missing); otherwise both sides decode to (name, version,
/// source) node sets with per-node (dep-name, dep-version) edge sets and
/// compare -- so comment/whitespace/edge-shortening-only diffs stay
/// `up_to_date`. Ambiguous short edges on the previous side are DROPPED
/// (cargo's `into_resolve` bad-merge tolerance); a graph edge the previous
/// side dropped therefore reads as `would_change`, matching cargo (it would
/// rewrite the file). Allocation failure also reads as `would_change`
/// (equality unprovable -- fail toward rewriting, never toward a false
/// `--locked` success). `offline_missing` is never returned here: it is
/// produced by the M4 resolve driver when the seam serves zero candidates
/// under offline/frozen (see `resolve.formatDiag`).
pub fn checkLock(gpa: std.mem.Allocator, previous: ?[]const u8, new_graph: *const resolve_mod.ResolveGraph) LockCheck {
    const text = previous orelse return .would_change;
    var lf = lock_mod.parseLock(gpa, text) catch return .would_change;
    defer lf.deinit();
    const prev_sig = lockSignature(gpa, lf.packages) catch return .would_change;
    defer {
        for (prev_sig) |*s| {
            gpa.free(s.node);
            for (s.deps) |d| gpa.free(d);
            gpa.free(s.deps);
        }
        gpa.free(prev_sig);
    }
    const graph_sig = graphSignature(gpa, new_graph) catch return .would_change;
    defer {
        for (graph_sig) |*s| {
            gpa.free(s.node);
            for (s.deps) |d| gpa.free(d);
            gpa.free(s.deps);
        }
        gpa.free(graph_sig);
    }
    if (prev_sig.len != graph_sig.len) return .would_change;
    for (prev_sig) |ps| {
        var found = false;
        for (graph_sig) |gs| {
            if (std.mem.eql(u8, ps.node, gs.node)) {
                found = true;
                if (ps.deps.len != gs.deps.len) return .would_change;
                for (ps.deps) |pd| {
                    var dfound = false;
                    for (gs.deps) |gd| {
                        if (std.mem.eql(u8, pd, gd)) {
                            dfound = true;
                            break;
                        }
                    }
                    if (!dfound) return .would_change;
                }
                break;
            }
        }
        if (!found) return .would_change;
    }
    return .up_to_date;
}

const NodeSig = struct { node: []u8, deps: [][]u8 };

/// Canonical `Version` rendering `M.m.p[-pre][+build]` (cargo's `Version`
/// Display -- the form lockfiles carry, including build metadata such as
/// `0.11.1+wasi-snapshot-preview1`).
fn renderVersionText(gpa: std.mem.Allocator, v: semver_mod.Version) std.mem.Allocator.Error![]u8 {
    if (v.pre.len == 0 and v.build.len == 0)
        return std.fmt.allocPrint(gpa, "{d}.{d}.{d}", .{ v.major, v.minor, v.patch });
    if (v.pre.len == 0)
        return std.fmt.allocPrint(gpa, "{d}.{d}.{d}+{s}", .{ v.major, v.minor, v.patch, v.build });
    if (v.build.len == 0)
        return std.fmt.allocPrint(gpa, "{d}.{d}.{d}-{s}", .{ v.major, v.minor, v.patch, v.pre });
    return std.fmt.allocPrint(gpa, "{d}.{d}.{d}-{s}+{s}", .{ v.major, v.minor, v.patch, v.pre, v.build });
}

/// Graph-side source rendering for the signature key (v4 form; only the
/// registry/git identity feeds the key, and path never reaches here).
fn renderSourceText(gpa: std.mem.Allocator, src: sources_mod.SourceId) std.mem.Allocator.Error![]u8 {
    switch (src) {
        .path => |p| return std.fmt.allocPrint(gpa, "path:{s}", .{p}),
        .registry => |u| return std.fmt.allocPrint(gpa, "registry+{s}", .{srcNormRegistry(u)}),
        .git => {
            // Only OOM is reachable here (git lines are never null);
            // LockLineError coerces into the caller's Allocator.Error.
            const line = try sources_mod.SourceId.lockSourceLine(gpa, src, .v4);
            return line.?;
        },
    }
}

fn srcNormRegistry(url: []const u8) []const u8 {
    // cargo's lock writes `registry+<url>` while the resolver keys
    // `sparse+<url>`: compare the URL past any `<scheme>+` prefix.
    if (std.mem.indexOfScalar(u8, url, '+')) |i| return url[i + 1 ..];
    return url;
}

/// Canonical node key `name\0version\0source-class\0source-rest`. Path (lock
/// `source` absent, graph `.path`) keys identically; registry compares past
/// the `sparse+`/`registry+` scheme split; git compares the full line.
fn nodeKey(gpa: std.mem.Allocator, name: []const u8, version: []const u8, source: ?[]const u8, is_path: bool) std.mem.Allocator.Error![]u8 {
    if (is_path) return std.fmt.allocPrint(gpa, "{s}\x00{s}\x00path:", .{ name, version });
    const s = source orelse return std.fmt.allocPrint(gpa, "{s}\x00{s}\x00path:", .{ name, version });
    if (std.mem.startsWith(u8, s, "git+")) return std.fmt.allocPrint(gpa, "{s}\x00{s}\x00git:{s}", .{ name, version, s });
    return std.fmt.allocPrint(gpa, "{s}\x00{s}\x00reg:{s}", .{ name, version, srcNormRegistry(s) });
}

/// Graph side: versions render canonically `M.m.p[-pre][+build]` (cargo's
/// `Version` Display -- the form lockfiles carry), sources key by variant.
fn graphSignature(gpa: std.mem.Allocator, graph: *const resolve_mod.ResolveGraph) std.mem.Allocator.Error![]NodeSig {
    var out: std.ArrayList(NodeSig) = .empty;
    errdefer {
        for (out.items) |*s| {
            gpa.free(s.node);
            for (s.deps) |d| gpa.free(d);
            gpa.free(s.deps);
        }
        out.deinit(gpa);
    }
    for (graph.nodes) |n| {
        const ver = try renderVersionText(gpa, n.version);
        defer gpa.free(ver);
        const is_path = n.source == .path;
        var src_buf: ?[]u8 = null;
        defer if (src_buf) |b| gpa.free(b);
        if (!is_path) {
            src_buf = try renderSourceText(gpa, n.source);
        }
        const node = try nodeKey(gpa, n.name, ver, src_buf, is_path);
        errdefer gpa.free(node);
        var deps: std.ArrayList([]u8) = .empty;
        errdefer {
            for (deps.items) |d| gpa.free(d);
            deps.deinit(gpa);
        }
        for (n.deps) |r| {
            const rv = try renderVersionText(gpa, r.version);
            defer gpa.free(rv);
            const rk = try std.fmt.allocPrint(gpa, "{s}\x00{s}", .{ r.name, rv });
            errdefer gpa.free(rk);
            try deps.append(gpa, rk);
        }
        std.mem.sort([]u8, deps.items, {}, struct {
            fn lt(_: void, a: []u8, b: []u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lt);
        try out.append(gpa, .{ .node = node, .deps = try deps.toOwnedSlice(gpa) });
    }
    std.mem.sort(NodeSig, out.items, {}, struct {
        fn lt(_: void, a: NodeSig, b: NodeSig) bool {
            return std.mem.order(u8, a.node, b.node) == .lt;
        }
    }.lt);
    return out.toOwnedSlice(gpa);
}

/// Previous-lock side: edge strings (`name [version] [(source)]`) resolve
/// against the package list with `into_resolve` tolerance (ambiguous or
/// dangling edges are DROPPED, never errors).
fn lockSignature(gpa: std.mem.Allocator, packages: []lock_mod.LockPackage) std.mem.Allocator.Error![]NodeSig {
    var out: std.ArrayList(NodeSig) = .empty;
    errdefer {
        for (out.items) |*s| {
            gpa.free(s.node);
            for (s.deps) |d| gpa.free(d);
            gpa.free(s.deps);
        }
        out.deinit(gpa);
    }
    for (packages) |*p| {
        const node = try nodeKey(gpa, p.name, p.version, p.source, p.source == null);
        errdefer gpa.free(node);
        var deps: std.ArrayList([]u8) = .empty;
        errdefer {
            for (deps.items) |d| gpa.free(d);
            deps.deinit(gpa);
        }
        for (p.dependencies) |e| {
            const resolved = resolveLockEdgeForSig(packages, e) orelse continue;
            const rk = try std.fmt.allocPrint(gpa, "{s}\x00{s}", .{ resolved.name, resolved.version });
            errdefer gpa.free(rk);
            try deps.append(gpa, rk);
        }
        std.mem.sort([]u8, deps.items, {}, struct {
            fn lt(_: void, a: []u8, b: []u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lt);
        try out.append(gpa, .{ .node = node, .deps = try deps.toOwnedSlice(gpa) });
    }
    std.mem.sort(NodeSig, out.items, {}, struct {
        fn lt(_: void, a: NodeSig, b: NodeSig) bool {
            return std.mem.order(u8, a.node, b.node) == .lt;
        }
    }.lt);
    return out.toOwnedSlice(gpa);
}

const SigEdge = struct { name: []const u8, version: []const u8 };

/// `into_resolve` edge tolerance for the compare: bare `name` needs a
/// single distinct version for the name; `name version` needs that package
/// to exist (a trailing `(source)` is accepted and ignored for the version
/// key -- source drift already shows in the node keys).
fn resolveLockEdgeForSig(packages: []lock_mod.LockPackage, edge: []const u8) ?SigEdge {
    const sp = std.mem.indexOfScalar(u8, edge, ' ') orelse {
        var first: ?[]const u8 = null;
        for (packages) |*p| {
            if (!std.mem.eql(u8, p.name, edge)) continue;
            if (first) |f| {
                if (!std.mem.eql(u8, f, p.version)) return null;
            } else first = p.version;
        }
        const v = first orelse return null;
        return .{ .name = edge, .version = v };
    };
    const name = edge[0..sp];
    const rest = edge[sp + 1 ..];
    const ver = if (std.mem.indexOfScalar(u8, rest, ' ')) |sp2| rest[0..sp2] else rest;
    for (packages) |*p| {
        if (std.mem.eql(u8, p.name, name) and std.mem.eql(u8, p.version, ver)) return .{ .name = name, .version = ver };
    }
    return null;
}

test "lockModeFrom maps flag combinations" {
    const base = Options{
        .cmd = .build,
        .manifest_path = null,
        .profile = "dev",
        .explicit_profile = false,
        .target_triple = null,
        .only_package = null,
        .features = &.{},
        .all_features = false,
        .no_default_features = false,
        .message_format = .human,
        .offline = false,
        .frozen = false,
        .locked = false,
        .dry_run = false,
        .extra_args = &.{},
    };
    try std.testing.expectEqual(LockMode.normal, lockModeFrom(base));
    var locked = base;
    locked.locked = true;
    try std.testing.expectEqual(LockMode.locked, lockModeFrom(locked));
    var offline = base;
    offline.offline = true;
    try std.testing.expectEqual(LockMode.offline, lockModeFrom(offline));
    var frozen = base;
    frozen.frozen = true;
    try std.testing.expectEqual(LockMode.frozen, lockModeFrom(frozen));
    // frozen wins over everything; locked+offline without --frozen is frozen.
    var both = base;
    both.locked = true;
    both.offline = true;
    try std.testing.expectEqual(LockMode.frozen, lockModeFrom(both));
    var all = base;
    all.locked = true;
    all.offline = true;
    all.frozen = true;
    try std.testing.expectEqual(LockMode.frozen, lockModeFrom(all));
}

test "needsNetwork is false only for offline modes" {
    try std.testing.expect(needsNetwork(.normal));
    try std.testing.expect(needsNetwork(.locked));
    try std.testing.expect(!needsNetwork(.offline));
    try std.testing.expect(!needsNetwork(.frozen));
}

test "locked mode bails only when the graph would change" {
    // Plan Task-9 shape (adapted: the settled `formatDiag` renders the
    // cargo-verbatim `name = \"req\"` leading line, so the bail-text
    // assertion lives with the M4 driver; here the checkLock halves).
    const gpa = std.testing.allocator;
    const path: sources_mod.SourceId = .{ .path = "/repo/app" };
    const v010 = try semver_mod.Version.parse("0.1.0");
    const nodes = [_]resolve_mod.ResolvedNode{
        .{ .name = "app", .version = v010, .source = path, .deps = &.{} },
    };
    var graph = resolve_mod.ResolveGraph{ .arena = std.heap.ArenaAllocator.init(gpa), .nodes = &nodes };
    defer graph.deinit();
    var cksums = std.StringHashMap(?[]const u8).init(gpa);
    defer cksums.deinit();
    const bytes = try lock_mod.writeLock(gpa, &graph, &cksums, .v4);
    defer gpa.free(bytes);
    try std.testing.expectEqual(LockCheck.up_to_date, checkLock(gpa, bytes, &graph));
    try std.testing.expectEqual(LockCheck.would_change, checkLock(gpa, null, &graph));
    const v020 = try semver_mod.Version.parse("0.2.0");
    const moved = [_]resolve_mod.ResolvedNode{
        .{ .name = "app", .version = v020, .source = path, .deps = &.{} },
    };
    var graph2 = resolve_mod.ResolveGraph{ .arena = std.heap.ArenaAllocator.init(gpa), .nodes = &moved };
    defer graph2.deinit();
    try std.testing.expectEqual(LockCheck.would_change, checkLock(gpa, bytes, &graph2));
}

test "checkLock ignores comments and edge shortening" {
    // Semantic compare (are_equal_lockfiles): a comment-only diff and a
    // shortened-vs-explicit edge diff both stay up_to_date.
    const gpa = std.testing.allocator;
    const path: sources_mod.SourceId = .{ .path = "/repo/app" };
    const reg: sources_mod.SourceId = .{ .registry = "sparse+https://github.com/rust-lang/crates.io-index" };
    const v010 = try semver_mod.Version.parse("0.1.0");
    const v100 = try semver_mod.Version.parse("1.0.0");
    const app_refs = [_]resolve_mod.ResolvedRef{.{ .name = "lib", .version = v100, .source = reg }};
    const nodes = [_]resolve_mod.ResolvedNode{
        .{ .name = "app", .version = v010, .source = path, .deps = &app_refs },
        .{ .name = "lib", .version = v100, .source = reg, .deps = &.{} },
    };
    var graph = resolve_mod.ResolveGraph{ .arena = std.heap.ArenaAllocator.init(gpa), .nodes = &nodes };
    defer graph.deinit();
    const src = "registry+https://github.com/rust-lang/crates.io-index";
    const ck = try lock_mod.checksumKey(gpa, "lib", "1.0.0", src);
    defer gpa.free(ck);
    var cksums = std.StringHashMap(?[]const u8).init(gpa);
    defer cksums.deinit();
    try cksums.put(ck, "e" ** 64);
    const bytes = try lock_mod.writeLock(gpa, &graph, &cksums, .v4);
    defer gpa.free(bytes);
    try std.testing.expectEqual(LockCheck.up_to_date, checkLock(gpa, bytes, &graph));
    // Comment-only diff: still up_to_date (bytes differ, semantics don't).
    const commented = try std.fmt.allocPrint(gpa, "# vendored for offline builds\n{s}", .{bytes});
    defer gpa.free(commented);
    try std.testing.expectEqual(LockCheck.up_to_date, checkLock(gpa, commented, &graph));
    // Malformed previous: would_change (cargo's "create" wording path).
    try std.testing.expectEqual(LockCheck.would_change, checkLock(gpa, "[[[not toml", &graph));
}

test "checkLock resolves bare edges before comparing" {
    // The writer shortens single-version names to bare `"lib"`; the graph
    // ref stays versioned. checkLock must resolve the bare edge through
    // the package list (into_resolve tolerance) instead of byte-matching.
    const gpa = std.testing.allocator;
    const text =
        "# This file is automatically @generated by Cargo.\n" ++
        "# It is not intended for manual editing.\n" ++
        "version = 4\n\n" ++
        "[[package]]\nname = \"app\"\nversion = \"0.1.0\"\ndependencies = [\n \"lib\",\n]\n\n" ++
        "[[package]]\nname = \"lib\"\nversion = \"1.0.0\"\nsource = \"registry+https://github.com/rust-lang/crates.io-index\"\nchecksum = \"" ++ "e" ** 64 ++ "\"\n";
    const path: sources_mod.SourceId = .{ .path = "/repo/app" };
    const reg: sources_mod.SourceId = .{ .registry = "sparse+https://github.com/rust-lang/crates.io-index" };
    const app_refs = [_]resolve_mod.ResolvedRef{.{ .name = "lib", .version = try semver_mod.Version.parse("1.0.0"), .source = reg }};
    const nodes = [_]resolve_mod.ResolvedNode{
        .{ .name = "app", .version = try semver_mod.Version.parse("0.1.0"), .source = path, .deps = &app_refs },
        .{ .name = "lib", .version = try semver_mod.Version.parse("1.0.0"), .source = reg, .deps = &.{} },
    };
    var graph = resolve_mod.ResolveGraph{ .arena = std.heap.ArenaAllocator.init(gpa), .nodes = &nodes };
    defer graph.deinit();
    try std.testing.expectEqual(LockCheck.up_to_date, checkLock(gpa, text, &graph));
}
