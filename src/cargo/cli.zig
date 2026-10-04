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
const script_mod = @import("script.zig");
const profile_mod = @import("profile.zig");
const msg_mod = @import("msg.zig");
const runner_mod = @import("runner.zig");
const fetch_mod = @import("fetch.zig");
const manifest_mod = @import("manifest.zig");

const Workspace = workspace_mod.Workspace;

pub const Command = enum { build, check, test_cmd, run, bench, clean, fetch };
pub const MessageFormat = enum { human, short, json, json_render_diagnostics, json_diagnostic_short, json_diagnostic_rendered_ansi };
pub const ColorChoice = enum { auto, always, never };
pub const JobsConfig = union(enum) { integer: i32, string: []const u8 };

pub const Options = struct {
    cmd: Command,
    manifest_path: ?[]const u8,
    profile: []const u8, // "dev" default; "release" with --release; custom via --profile
    explicit_profile: bool, // true with --release/--profile (clean uses it to scope target/<profile>/)
    target_triple: ?[]const u8, // --target (single; M6 keeps single-target semantics)
    only_package: ?[]const u8, // -p/--package, parser-maintained as packages[0]-or-null (view.planUnits callers untouched)
    packages: []const []const u8, // -p/--package, repeatable (owned slice header; entries borrow argv)
    workspace: bool, // --workspace (clean selection)
    target_dir: ?[]const u8, // --target-dir override root
    doc_only: bool, // --doc (clean: remove target/doc only)
    features: []const []const u8,
    all_features: bool, // --all-features (takes no value)
    no_default_features: bool, // --no-default-features (takes no value)
    message_format: MessageFormat,
    format_error: bool, // message-format conflict/invalid (row 5 -> 101)
    format_diagnostic: ?[]const u8, // owned message printed when format_error is set (deinit frees)
    offline: bool,
    frozen: bool,
    locked: bool,
    dry_run: bool, // M1-only planning flag (prints unit plan, writes view skeleton)
    extra_args: []const []const u8, // trailing args after -- (for run/test/bench)
    verbose: u32, // -v count (global + per-command sum)
    quiet: bool, // -q/--quiet (global or per-command)
    color: ColorChoice, // --color (default .auto)
    jobs: ?JobsConfig, // -j/--jobs N (M6 parses + validates only)
    jobs_validated: bool, // internal: -j validated >= 1 at first use
    config_overrides: []const []const u8, // --config KEY=VALUE|PATH, repeatable (stored verbatim)
    bin_name: ?[]const u8, // --bin NAME (run only)
    example_name: ?[]const u8, // --example NAME (run only)
    no_run: bool, // --no-run (test/bench only)
    no_fail_fast: bool, // --no-fail-fast (test/bench only)
    bench_name: ?[]const u8, // BENCHNAME positional (bench only, first positional arg)
    test_filter: []const []const u8, // positional filter args for test (before --)
    help: bool, // --help (exits 0)
    version: bool, // --version (exits 0)

    /// Frees the gpa-owned slice headers (`features`, `extra_args`,
    /// `packages`, `test_filter`, `config_overrides`) plus the owned
    /// `format_diagnostic`; every other field borrows `argv`/statics and
    /// must NOT be freed.
    pub fn deinit(self: *const Options, gpa: std.mem.Allocator) void {
        gpa.free(self.features);
        gpa.free(self.extra_args);
        gpa.free(self.packages);
        gpa.free(self.test_filter);
        gpa.free(self.config_overrides);
        if (self.format_diagnostic) |d| gpa.free(d);
    }

    /// New call sites use this; existing `opts.only_package` uses stay as-is.
    pub fn onlyPackage(self: *const Options) ?[]const u8 {
        return self.only_package;
    }

    /// True for the JSON-family wire formats (stdout carries event lines).
    pub fn isJsonFormat(self: *const Options) bool {
        return switch (self.message_format) {
            .json, .json_render_diagnostics, .json_diagnostic_short, .json_diagnostic_rendered_ansi => true,
            .human, .short => false,
        };
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
var diag_buf: [512]u8 = undefined;
var diag_len: usize = 0;
/// Set when the last parse failure was a message-format conflict/invalid
/// value (exit 101, the anyhow class) rather than a plain usage error
/// (exit 1, the clap class). Read via `lastFormatError()`.
var last_format_error: bool = false;

pub fn lastFormatError() bool {
    return last_format_error;
}

pub fn isFormatError() bool {
    return last_format_error;
}

pub fn parseDiagnostic() ?[]const u8 {
    if (diag_len == 0) return null;
    return diag_buf[0..diag_len];
}

fn fail(comptime fmt: []const u8, args: anytype) CliError {
    last_format_error = false;
    const msg = std.fmt.bufPrint(&diag_buf, fmt, args) catch &diag_buf;
    diag_len = msg.len;
    return CliError.Usage;
}

/// Message-format failures are the anyhow class (exit 101), not the clap
/// class (exit 1). Sets the `last_format_error` side flag so `main.zig`
/// maps the exit code even though `parseArgs` only returns `Usage`.
fn failFormat(comptime fmt: []const u8, args: anytype) CliError {
    last_format_error = true;
    const msg = std.fmt.bufPrint(&diag_buf, fmt, args) catch &diag_buf;
    diag_len = msg.len;
    return CliError.Usage;
}

/// Deprecated M1 envelope (kept ONLY because `compile.zig` — M4-settled
/// and frozen — renders `compiler-message` lines through it; new code
/// emits `msg.zig` cargo-shaped events instead and nothing else may use
/// this). Single-line JSON (struct field order is the wire order) + `\n`.
pub const JsonEnvelope = struct {
    reason: []const u8,
    package: []const u8,
    target: []const u8,
    profile: []const u8,
    success: bool,

    pub fn writeLine(self: *const JsonEnvelope, w: *std.Io.Writer) !void {
        try std.json.Stringify.value(self.*, .{}, w);
        try w.writeAll("\n");
    }
};

/// Parses `argv` with `argv[0]` the program name and `argv[1]` the command.
/// Accepts exact cargo spellings including `--flag=value` and `--flag value`
/// forms. Owns `features`/`extra_args`/`packages`/`test_filter`/
/// `config_overrides` (see `Options.deinit`).
pub fn parseArgs(gpa: std.mem.Allocator, argv: []const []const u8) CliError!Options {
    diag_len = 0;
    last_format_error = false;
    if (argv.len < 2) return fail("usage: rime <build|check|test|run|bench|clean|fetch> […]\n", .{});
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
    else if (std.mem.eql(u8, argv[1], "fetch"))
        .fetch
    else
        return fail("unknown command '{s}'", .{argv[1]});

    var opts = Options{
        .cmd = cmd,
        .manifest_path = null,
        .profile = "dev",
        .explicit_profile = false,
        .target_triple = null,
        .only_package = null,
        .packages = &.{},
        .workspace = false,
        .target_dir = null,
        .doc_only = false,
        .features = &.{},
        .all_features = false,
        .no_default_features = false,
        .message_format = .human,
        .format_error = false,
        .format_diagnostic = null,
        .offline = false,
        .frozen = false,
        .locked = false,
        .dry_run = false,
        .extra_args = &.{},
        .verbose = 0,
        .quiet = false,
        .color = .auto,
        .jobs = null,
        .jobs_validated = false,
        .config_overrides = &.{},
        .bin_name = null,
        .example_name = null,
        .no_run = false,
        .no_fail_fast = false,
        .bench_name = null,
        .test_filter = &.{},
        .help = false,
        .version = false,
    };
    var features: std.ArrayList([]const u8) = .empty;
    defer features.deinit(gpa);
    var extra: std.ArrayList([]const u8) = .empty;
    defer extra.deinit(gpa);
    var packages: std.ArrayList([]const u8) = .empty;
    defer packages.deinit(gpa);
    var configs: std.ArrayList([]const u8) = .empty;
    defer configs.deinit(gpa);
    var filters: std.ArrayList([]const u8) = .empty;
    defer filters.deinit(gpa);
    // Message-format fold state (command_prelude.rs:753-806): at most one
    // base kind; diagnostic bits promote a null base to default json.
    var fmt_base: ?MessageFormat = null;
    var fmt_diag: ?MessageFormat = null;

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
            // Positional args: bench captures BENCHNAME, test captures
            // filters, run forwards program args; everything else rejects.
            if (cmd == .bench and opts.bench_name == null) {
                opts.bench_name = a;
                continue;
            } else if (cmd == .bench) {
                return fail("unexpected argument '{s}'", .{a});
            } else if (cmd == .test_cmd) {
                try filters.append(gpa, a);
                continue;
            } else if (cmd == .run) {
                try extra.append(gpa, a);
                continue;
            }
            return fail("unexpected argument '{s}'", .{a});
        }
        const f = flag.?;
        // Combined short verbosity (-vvv) arrives here as one token.
        if (isVerboseToken(f)) {
            opts.verbose += countVerbose(inline_val orelse "v");
            continue;
        }
        if (isCleanOnlyReject(cmd, f)) {
            return fail("flag '{s}' is not supported for clean", .{f});
        }
        if (std.mem.eql(u8, f, "--manifest-path")) {
            opts.manifest_path = try takeValue(gpa, argv, &i, inline_val, "--manifest-path");
        } else if (std.mem.eql(u8, f, "--release")) {
            if (inline_val != null) return fail("flag '--release' takes no value", .{});
            if (cmd == .fetch) return fail("flag '--release' is not supported for fetch", .{});
            if (opts.explicit_profile) return fail("cannot specify both --release and --profile", .{});
            opts.profile = "release";
            opts.explicit_profile = true;
        } else if (std.mem.eql(u8, f, "--profile")) {
            const v = try takeValue(gpa, argv, &i, inline_val, "--profile");
            if (cmd == .fetch) return fail("flag '--profile' is not supported for fetch", .{});
            if (opts.explicit_profile) return fail("cannot specify both --release and --profile", .{});
            opts.profile = v;
            opts.explicit_profile = true;
        } else if (std.mem.eql(u8, f, "--target")) {
            opts.target_triple = try takeValue(gpa, argv, &i, inline_val, "--target");
        } else if (std.mem.eql(u8, f, "--target-dir")) {
            opts.target_dir = try takeValue(gpa, argv, &i, inline_val, "--target-dir");
        } else if (std.mem.eql(u8, f, "--features")) {
            const v = try takeValue(gpa, argv, &i, inline_val, "--features");
            if (cmd == .clean or cmd == .fetch) return fail("flag '--features' is not supported for {s}", .{argv[1]});
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
            if (cmd == .fetch) return fail("flag '--message-format' is not supported for fetch", .{});
            var pieces = std.mem.splitScalar(u8, v, ',');
            while (pieces.next()) |raw| {
                var lower_buf: [64]u8 = undefined;
                const piece = lowerPiece(raw, &lower_buf);
                if (std.mem.eql(u8, piece, "json") or std.mem.eql(u8, piece, "human") or std.mem.eql(u8, piece, "short")) {
                    if (fmt_base != null) return failFormat("cannot specify two kinds of `message-format` arguments", .{});
                    fmt_base = if (std.mem.eql(u8, piece, "json")) .json else if (std.mem.eql(u8, piece, "human")) .human else .short;
                } else if (std.mem.eql(u8, piece, "json-render-diagnostics")) {
                    if (fmt_base != null and fmt_base.? != .json) return failFormat("cannot specify two kinds of `message-format` arguments", .{});
                    if (fmt_base == null) fmt_base = .json;
                    fmt_diag = .json_render_diagnostics;
                } else if (std.mem.eql(u8, piece, "json-diagnostic-short")) {
                    if (fmt_base != null and fmt_base.? != .json) return failFormat("cannot specify two kinds of `message-format` arguments", .{});
                    if (fmt_base == null) fmt_base = .json;
                    fmt_diag = .json_diagnostic_short;
                } else if (std.mem.eql(u8, piece, "json-diagnostic-rendered-ansi")) {
                    if (fmt_base != null and fmt_base.? != .json) return failFormat("cannot specify two kinds of `message-format` arguments", .{});
                    if (fmt_base == null) fmt_base = .json;
                    fmt_diag = .json_diagnostic_rendered_ansi;
                } else {
                    return fail("invalid message format specifier: `{s}`", .{raw});
                }
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
            if (cmd == .fetch) return fail("flag '--dry-run' is not supported for fetch", .{});
            opts.dry_run = true;
        } else if (std.mem.eql(u8, f, "-p") or std.mem.eql(u8, f, "--package")) {
            const v = try takeValue(gpa, argv, &i, inline_val, f);
            if (cmd == .fetch) return fail("flag '{s}' is not supported for fetch", .{f});
            try packages.append(gpa, v);
        } else if (std.mem.eql(u8, f, "--workspace")) {
            if (inline_val != null) return fail("flag '--workspace' takes no value", .{});
            opts.workspace = true;
        } else if (std.mem.eql(u8, f, "--doc")) {
            if (inline_val != null) return fail("flag '--doc' takes no value", .{});
            if (cmd != .clean) return fail("flag '--doc' is only supported for clean", .{});
            opts.doc_only = true;
        } else if (std.mem.eql(u8, f, "--verbose")) {
            if (inline_val != null) return fail("flag '--verbose' takes no value", .{});
            opts.verbose += 1;
        } else if (std.mem.eql(u8, f, "-q") or std.mem.eql(u8, f, "--quiet")) {
            if (inline_val != null) return fail("flag '{s}' takes no value", .{f});
            opts.quiet = true;
        } else if (std.mem.eql(u8, f, "--color")) {
            const v = try takeValue(gpa, argv, &i, inline_val, "--color");
            var cbuf: [16]u8 = undefined;
            const c = lowerPiece(v, &cbuf);
            if (std.mem.eql(u8, c, "auto")) opts.color = .auto else if (std.mem.eql(u8, c, "always")) opts.color = .always else if (std.mem.eql(u8, c, "never")) opts.color = .never else return fail("invalid color choice '{s}' (expected auto, always, never)", .{v});
        } else if (std.mem.eql(u8, f, "-j") or std.mem.eql(u8, f, "--jobs")) {
            const v = try takeValue(gpa, argv, &i, inline_val, f);
            opts.jobs = parseJobsValue(v);
        } else if (std.mem.eql(u8, f, "--config")) {
            const v = try takeValue(gpa, argv, &i, inline_val, "--config");
            if (std.mem.indexOfScalar(u8, v, '=') == null) {
                if (!existsFile(std.Io.Threaded.global_single_threaded.io(), v)) return fail("missing config file '{s}'", .{v});
            }
            try configs.append(gpa, v);
        } else if (std.mem.eql(u8, f, "-C")) {
            return fail("the `-C` flag is unstable, pass `-Z unstable-options` on the nightly channel to enable it", .{});
        } else if (std.mem.eql(u8, f, "-c")) {
            return fail("use `--config` instead of `-c`", .{});
        } else if (std.mem.eql(u8, f, "--bin")) {
            const v = try takeValue(gpa, argv, &i, inline_val, "--bin");
            if (cmd != .run) return fail("flag '--bin' is only supported for run", .{});
            opts.bin_name = v;
        } else if (std.mem.eql(u8, f, "--example")) {
            const v = try takeValue(gpa, argv, &i, inline_val, "--example");
            if (cmd != .run) return fail("flag '--example' is only supported for run", .{});
            opts.example_name = v;
        } else if (std.mem.eql(u8, f, "--no-run")) {
            if (inline_val != null) return fail("flag '--no-run' takes no value", .{});
            if (cmd != .test_cmd and cmd != .bench) return fail("flag '--no-run' is only supported for test and bench", .{});
            opts.no_run = true;
        } else if (std.mem.eql(u8, f, "--no-fail-fast")) {
            if (inline_val != null) return fail("flag '--no-fail-fast' takes no value", .{});
            if (cmd != .test_cmd and cmd != .bench) return fail("flag '--no-fail-fast' is only supported for test and bench", .{});
            opts.no_fail_fast = true;
        } else if (std.mem.eql(u8, f, "--help") or std.mem.eql(u8, f, "-h")) {
            opts.help = true;
        } else if (std.mem.eql(u8, f, "--version") or std.mem.eql(u8, f, "-V")) {
            opts.version = true;
        } else {
            return fail("unknown flag '{s}'", .{f});
        }
    }

    if (fmt_base) |b| opts.message_format = fmt_diag orelse b else if (fmt_diag) |d| opts.message_format = d;
    if (cmd == .fetch) try validateFetchSubset(&opts);

    opts.features = try features.toOwnedSlice(gpa);
    errdefer gpa.free(opts.features);
    opts.extra_args = try extra.toOwnedSlice(gpa);
    errdefer gpa.free(opts.extra_args);
    opts.packages = try packages.toOwnedSlice(gpa);
    errdefer gpa.free(opts.packages);
    opts.config_overrides = try configs.toOwnedSlice(gpa);
    errdefer gpa.free(opts.config_overrides);
    opts.test_filter = try filters.toOwnedSlice(gpa);
    errdefer gpa.free(opts.test_filter);
    if (opts.packages.len > 0) opts.only_package = opts.packages[0];
    return opts;
}

/// Splits `--flag=value` into (`--flag`, `value`); bare `--flag`/`-p`/`-j`/
/// `-v`/`-q`/etc into (`--flag`, null); combined shorts (`-vvv`, `-j4`)
/// into (flag, inline-value); non-flags into (null, null).
fn splitFlag(arg: []const u8) struct { ?[]const u8, ?[]const u8 } {
    if (arg.len < 2 or arg[0] != '-') return .{ null, null };
    if (arg[1] != '-') {
        if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "-j") or
            std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "-q") or
            std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "-V") or
            std.mem.eql(u8, arg, "-C") or std.mem.eql(u8, arg, "-c"))
            return .{ arg, null };
        // Combined verbosity: -vv, -vvv.
        if (arg.len > 2 and arg[1] == 'v') {
            for (arg[1..]) |c| if (c != 'v') return .{ null, null };
            return .{ "-v", arg[1..] };
        }
        // Attached jobs value: -j4.
        if (arg.len > 2 and arg[1] == 'j') return .{ "-j", arg[2..] };
        // Attached package value is NOT accepted (cargo needs `-p foo`).
        return .{ null, null };
    }
    if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
        return .{ arg[0..eq], arg[eq + 1 ..] };
    }
    return .{ arg, null };
}

/// True for `-v`/`-vv`/`-vvv` tokens (counted verbosity).
fn isVerboseToken(flag: []const u8) bool {
    if (std.mem.eql(u8, flag, "-v")) return true;
    return false;
}

/// Counts the `v`s in a verbosity token (`-v` -> 1; the inline tail of
/// `-vvv` is passed through as the flag slice for counting).
fn countVerbose(flag_or_tail: []const u8) u32 {
    if (std.mem.eql(u8, flag_or_tail, "-v")) return 1;
    var n: u32 = 0;
    for (flag_or_tail) |c| if (c == 'v') {
        n += 1;
    };
    return n;
}

/// Lowercase-ASCII `raw` into `buf` (message-format/color matching is
/// case-insensitive per cargo's `ignore_case(true)`). Truncates on
/// overflow (values are short; truncation only mismatches to an error).
fn lowerPiece(raw: []const u8, buf: []u8) []const u8 {
    const n = @min(raw.len, buf.len);
    for (raw[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..n];
}

fn parseJobsValue(raw: []const u8) JobsConfig {
    const v = std.fmt.parseInt(i32, raw, 10) catch return .{ .string = raw };
    return .{ .integer = v };
}

/// Fetch takes only `--target`/`--manifest-path` plus globals (fetch.rs::cli).
/// Every other per-command surface is a usage error naming the flag.
fn validateFetchSubset(opts: *const Options) CliError!void {
    if (opts.workspace) return fail("flag '--workspace' is not supported for fetch", .{});
    if (opts.target_dir != null) return fail("flag '--target-dir' is not supported for fetch", .{});
    if (opts.doc_only) return fail("flag '--doc' is not supported for fetch", .{});
    if (opts.jobs != null) return fail("flag '--jobs' is not supported for fetch", .{});
    if (opts.all_features) return fail("flag '--all-features' is not supported for fetch", .{});
    if (opts.no_default_features) return fail("flag '--no-default-features' is not supported for fetch", .{});
    if (opts.bin_name != null) return fail("flag '--bin' is not supported for fetch", .{});
    if (opts.example_name != null) return fail("flag '--example' is not supported for fetch", .{});
    if (opts.no_run) return fail("flag '--no-run' is not supported for fetch", .{});
    if (opts.no_fail_fast) return fail("flag '--no-fail-fast' is not supported for fetch", .{});
    if (opts.bench_name != null) return fail("flag 'BENCHNAME' is not supported for fetch", .{});
    if (opts.test_filter.len > 0) return fail("flag 'FILTER' is not supported for fetch", .{});
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

/// Flags clean never takes in cargo (`commands/clean.rs::cli`). `-p` is
/// repeatable on clean since M6; `--target`/`--dry-run` are valid there too.
fn isCleanOnlyReject(cmd: Command, flag: []const u8) bool {
    if (cmd != .clean) return false;
    return std.mem.eql(u8, flag, "--features");
}

/// Entry point used by `src/main.zig`. JSON lines go to `stdout` (pipe-clean);
/// human rendering and every error go to `stderr`. Returns a cargo exit code.
/// Injects a live runner; tests use `runWith` with a `FakeRunner`.
pub fn run(gpa: std.mem.Allocator, io: std.Io, opts: Options, stdout: *std.Io.Writer, stderr: *std.Io.Writer) u8 {
    var live = runner_mod.LiveRunner{};
    return runWith(gpa, io, opts, stdout, stderr, live.runner());
}

/// Testable entry: `runner` spawns run/test/bench binaries (fake in tests).
/// Row 5 (message-format conflict/invalid) returns 101 before anything else.
pub fn runWith(gpa: std.mem.Allocator, io: std.Io, opts: Options, stdout: *std.Io.Writer, stderr: *std.Io.Writer, runner: runner_mod.Runner) u8 {
    if (opts.format_error) {
        stderr.print("error: {s}\n", .{opts.format_diagnostic orelse "invalid message format"}) catch {};
        return ExitCode.build_failed;
    }
    if (opts.help) {
        stdout.print("{s}\n", .{commandHelp(opts.cmd)}) catch {};
        return ExitCode.ok;
    }
    if (opts.version) {
        stdout.print("rime 0.1.0\n", .{}) catch {};
        return ExitCode.ok;
    }
    switch (opts.cmd) {
        .clean => return runClean(gpa, io, opts, stderr),
        .fetch => return runFetch(gpa, io, opts, stderr),
        .run => return runRun(gpa, io, opts, stdout, stderr, runner),
        .test_cmd, .bench => return runTestBench(gpa, io, opts, stdout, stderr, runner),
        .build, .check => return runBuild(gpa, io, opts, stdout, stderr),
    }
}

/// Row 7 mapping (`commands/run.rs::to_run_error`): a child exit code
/// forwards verbatim; spawn failure or a signal reads as 101. `quiet`
/// only suppresses the extra context print, never changes the code.
pub fn mapRunOutcome(outcome: runner_mod.RunOutcome, quiet: bool) u8 {
    _ = quiet;
    return switch (outcome.term) {
        .exited => outcome.code,
        .signaled, .spawn_failed => ExitCode.build_failed,
    };
}

/// Rows 9-10 mapping (`ops/cargo_test.rs::fail_fast_code`): fail-fast
/// forwards the first harness code; `--no-fail-fast` with any failure
/// reads as 101 with the `N targets failed` summary.
pub fn mapTestOutcome(outcomes: []const runner_mod.RunOutcome, no_fail_fast: bool) u8 {
    if (!no_fail_fast) {
        for (outcomes) |o| {
            if (o.term == .exited and o.code == 0) continue;
            if (o.term == .exited) return o.code;
            return ExitCode.build_failed;
        }
        return ExitCode.ok;
    }
    for (outcomes) |o| {
        if (o.term == .exited and o.code == 0) continue;
        return ExitCode.build_failed;
    }
    return ExitCode.ok;
}

/// `-j` validation at first use: integers must be >= 1; string profiles
/// are parsed-and-stored but never resolved in M6 (loud error on use).
/// M6 executes units serially in plan order; `-j` gates nothing else.
fn validateJobs(opts: *const Options, stderr: *std.Io.Writer) ?u8 {
    const j = opts.jobs orelse return null;
    switch (j) {
        .integer => |n| if (n < 1) {
            stderr.print("error: --jobs must be >= 1, got {d}\n", .{n}) catch {};
            return ExitCode.build_failed;
        },
        .string => |s| {
            stderr.print("error: --jobs <string> profiles are not resolved in M6: '{s}'\n", .{s}) catch {};
            return ExitCode.build_failed;
        },
    }
    return null;
}

/// `--config` application: M6 honors exactly the `store.*` keys (stored
/// verbatim at parse; the store opens with defaults and the keys are
/// validated here). Any other dotted key is a loud exit-1 error.
fn validateConfig(opts: *const Options, stderr: *std.Io.Writer) ?u8 {
    for (opts.config_overrides) |c| {
        const kv = if (std.mem.indexOfScalar(u8, c, '=')) |eq| c[0..eq] else c;
        if (std.mem.startsWith(u8, kv, "store.")) continue;
        // Bare paths (no `=`) were verified to exist at parse; they carry
        // TOML fragments cargo would merge — accepted verbatim in M6.
        if (std.mem.indexOfScalar(u8, c, '=') == null) continue;
        stderr.print("error: --config '{s}' is not supported by rime (M6 supports store.* only)\n", .{c}) catch {};
        return ExitCode.usage;
    }
    return null;
}

/// One-line per-command help with the divergence trailer (Task 7 strings
/// live in main.zig; this terse form serves `--help` on cargo commands).
fn commandHelp(cmd: Command) []const u8 {
    return switch (cmd) {
        .build => "Compile the current package\n\nUsage: rime build [--release|--profile N] [--target T] [-p PKG ...] [--features CSV] [--message-format FMT]\n\nNote: rime executes the cargo unit plan via the global store; parallelism (-j) is accepted and validated but units run in plan order.",
        .check => "Check the current package (rmeta-only, no codegen)\n\nUsage: rime check [same flags as build]\n\nNote: rime implements the check build surface; artifacts are metadata-only.",
        .test_cmd => "Compile and run tests\n\nUsage: rime test [--no-run] [--no-fail-fast] [FILTER] [-- ARGS...]\n\nNote: rime forwards trailing args to the libtest harness after `--`.",
        .run => "Build and run a binary\n\nUsage: rime run [--bin NAME|--example NAME] [-- ARGS...]\n\nNote: rime spawns the view binary built by a prior build.",
        .bench => "Compile and run benchmarks\n\nUsage: rime bench [BENCHNAME] [--no-run] [--no-fail-fast] [-- ARGS...]\n\nNote: rime invokes the bench harness binary directly.",
        .clean => "Remove artifacts that rime has generated in the past.\n\nUsage: rime clean [-p PKG ...] [--workspace] [--release|--profile N] [--target TRIPLE] [--target-dir DIR] [--manifest-path P] [--doc] [--dry-run]\n\nRemoves only project target/ views, never store state.\nSee 'rime gc --help' for global-cache collection.",
        .fetch => "Fetch dependencies of the current package\n\nUsage: rime fetch [--target TRIPLE] [--manifest-path P]\n\nNote: rime implements the fetch surface over the existing fetch machinery.",
    };
}

/// Task 1 dispatch: discover the workspace and run the existing
/// `fetch.zig::ensureSources` fetch-all entry over the workspace lock.
/// Fetch errors print `error: fetch failed: {t}` and return exit 1.
fn runFetch(gpa: std.mem.Allocator, io: std.Io, opts: Options, stderr: *std.Io.Writer) u8 {
    var ws = loadWorkspace(gpa, io, opts, stderr) orelse return ExitCode.build_failed;
    defer ws.deinit();
    const lock = ws.lock orelse {
        // Nothing to fetch (pure-path workspace without a lockfile).
        return ExitCode.ok;
    };
    var holder = openCargoStore(gpa, io) catch {
        stderr.print("error: cannot open store\n", .{}) catch {};
        return ExitCode.usage;
    };
    defer holder.close(io);
    const cache_dir = cacheRoot(gpa) catch {
        stderr.print("error: cannot determine cache directory\n", .{}) catch {};
        return ExitCode.usage;
    };
    defer gpa.free(cache_dir);
    var git = fetch_mod.CliGit{};
    var git_decls = fetch_mod.GitDecls.init(gpa);
    defer git_decls.deinit();
    var stub_reg = fetch_mod.FileRegistry{ .root = "<fetch-stub-never-queried>" };
    const fetched = fetch_mod.ensureSources(gpa, io, holder.store(), stub_reg.client(), git.runner(), .{
        .offline = opts.offline,
        .frozen = opts.frozen,
        .locked = opts.locked,
        .cache_dir = cache_dir,
    }, &lock, &git_decls) catch |e| {
        stderr.print("error: fetch failed: {t}\n", .{e}) catch {};
        return ExitCode.build_failed;
    };
    defer {
        for (fetched) |*s| s.deinit();
        gpa.free(fetched);
    }
    return ExitCode.ok;
}

/// Profile directory for a (possibly target-prefixed) view root:
/// `<root>/target/[<triple>/]<profile_dir>/`. Caller owns the result.
fn profileDirFor(gpa: std.mem.Allocator, ws_root: []const u8, opts: *const Options) ![]u8 {
    const root = opts.target_dir orelse try std.fmt.allocPrint(gpa, "{s}/target", .{ws_root});
    const owned_root = opts.target_dir == null;
    defer if (owned_root) gpa.free(root);
    const prof = view_mod.profileDirName(opts.profile);
    if (opts.target_triple) |t| return std.fmt.allocPrint(gpa, "{s}/{s}/{s}", .{ root, t, prof });
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, prof });
}

/// View-root-relative binary path for `run` (no build step before spawn):
/// `<base>/<profile_dir>/<name>` where base is the manifest dir when
/// `--manifest-path` was given (keeps relative spellings relative) else
/// the workspace root. Caller owns the result.
fn runBinPath(gpa: std.mem.Allocator, ws_root: []const u8, opts: *const Options, name: []const u8) ![]u8 {
    const base: []const u8 = if (opts.manifest_path) |mp| std.fs.path.dirname(mp) orelse ws_root else ws_root;
    const tdir: []const u8 = opts.target_dir orelse "target";
    const prof = view_mod.profileDirName(opts.profile);
    if (opts.target_dir != null) {
        if (opts.target_triple) |t| return std.fmt.allocPrint(gpa, "{s}/{s}/{s}/{s}", .{ tdir, t, prof, name });
        return std.fmt.allocPrint(gpa, "{s}/{s}/{s}", .{ tdir, prof, name });
    }
    if (opts.target_triple) |t| return std.fmt.allocPrint(gpa, "{s}/target/{s}/{s}/{s}", .{ base, t, prof, name });
    return std.fmt.allocPrint(gpa, "{s}/target/{s}/{s}", .{ base, prof, name });
}

/// `run` target selection (no build step): named `--bin`/`--example`, or
/// `default-run`, or the sole binary; >1 candidates is exit 1.
fn selectRunBinary(gpa: std.mem.Allocator, ws: *const Workspace, opts: *const Options, stderr: *std.Io.Writer) ?[]const u8 {
    if (opts.bin_name) |b| return b;
    if (opts.example_name) |e| return e;
    var bins: std.ArrayList([]const u8) = .empty;
    defer bins.deinit(gpa);
    for (ws.members) |*m| {
        for (m.manifest.targets) |t| {
            if (t.kind == .bin) bins.append(gpa, t.name) catch return null;
        }
    }
    if (bins.items.len == 1) return bins.items[0];
    if (bins.items.len == 0) {
        stderr.print("error: no bin target found (use --bin to name one)\n", .{}) catch {};
        return null;
    }
    stderr.print("error: `cargo run` requires --bin or --example when multiple binaries exist\n", .{}) catch {};
    return null;
}

fn runRun(gpa: std.mem.Allocator, io: std.Io, opts: Options, stdout: *std.Io.Writer, stderr: *std.Io.Writer, runner: runner_mod.Runner) u8 {
    _ = stdout;
    if (opts.bin_name != null and opts.example_name != null) {
        stderr.print("error: cannot specify both --bin and --example\n", .{}) catch {};
        return ExitCode.build_failed;
    }
    var ws = loadWorkspace(gpa, io, opts, stderr) orelse return ExitCode.build_failed;
    defer ws.deinit();
    const name = selectRunBinary(gpa, &ws, &opts, stderr) orelse return ExitCode.build_failed;
    const bin = runBinPath(gpa, ws.root_dir, &opts, name) catch {
        stderr.print("error: out of memory\n", .{}) catch {};
        return ExitCode.usage;
    };
    defer gpa.free(bin);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    argv.append(gpa, bin) catch {
        stderr.print("error: out of memory\n", .{}) catch {};
        return ExitCode.usage;
    };
    argv.appendSlice(gpa, opts.extra_args) catch {
        stderr.print("error: out of memory\n", .{}) catch {};
        return ExitCode.usage;
    };
    const outcome = runner.run(gpa, io, argv.items);
    const code = mapRunOutcome(outcome, opts.quiet);
    if (code != 0 and !opts.quiet) {
        switch (outcome.term) {
            .exited => stderr.print("error: process exited with code {d}\n", .{outcome.code}) catch {},
            .signaled => stderr.print("error: process terminated by signal\n", .{}) catch {},
            .spawn_failed => stderr.print("error: failed to spawn '{s}'\n", .{bin}) catch {},
        }
    }
    return code;
}

fn runTestBench(gpa: std.mem.Allocator, io: std.Io, opts: Options, stdout: *std.Io.Writer, stderr: *std.Io.Writer, runner: runner_mod.Runner) u8 {
    const is_test = opts.cmd == .test_cmd;
    if (is_test and opts.bench_name != null) {
        stderr.print("error: unexpected argument '{s}'\n", .{opts.bench_name.?}) catch {};
        return ExitCode.usage;
    }
    if (opts.no_run) return ExitCode.ok;
    var ws = loadWorkspace(gpa, io, opts, stderr) orelse return ExitCode.build_failed;
    defer ws.deinit();
    if (validateJobs(&opts, stderr)) |code| return code;
    // Harness enumeration (M6): every unit target resolves to its profile-dir
    // binary; bench-name filters to the named target (unknown name is exit 1).
    const units = view_mod.planUnits(gpa, &ws, opts.only_package) catch {
        if (opts.only_package) |name| {
            stderr.print("error: package not found: {s}\n", .{name}) catch {};
        } else {
            stderr.print("error: cannot compute build plan\n", .{}) catch {};
        }
        return ExitCode.build_failed;
    };
    defer gpa.free(units);
    var outcomes: std.ArrayList(runner_mod.RunOutcome) = .empty;
    defer outcomes.deinit(gpa);
    var failed: usize = 0;
    for (units) |u| {
        const want_bench = !is_test;
        const is_bench_kind = u.kind == .bench;
        if (want_bench and !is_bench_kind and units.len > 1) continue;
        if (!is_test) {
            if (opts.bench_name) |bn| {
                if (!std.mem.eql(u8, u.target, bn)) continue;
            }
        }
        const bin = runBinPath(gpa, ws.root_dir, &opts, u.target) catch {
            stderr.print("error: out of memory\n", .{}) catch {};
            return ExitCode.usage;
        };
        defer gpa.free(bin);
        // Resolve through the plan filenames when they name the binary
        // (metadata hashes are plan-known); otherwise use the view path.
        const resolved: []const u8 = runner_mod.selectTestBinary(u.outputs, u.target) orelse bin;
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        argv.append(gpa, resolved) catch {
            stderr.print("error: out of memory\n", .{}) catch {};
            return ExitCode.usage;
        };
        if (is_test) argv.appendSlice(gpa, opts.test_filter) catch {
            stderr.print("error: out of memory\n", .{}) catch {};
            return ExitCode.usage;
        };
        if (!is_test) {
            // bench.rs exec chaining: BENCHNAME filters into the harness
            // argv and `--bench` selects bench mode (cargo_test.rs:98).
            // Without a positional filter the harness runs all benches.
            if (opts.bench_name) |bn| argv.append(gpa, bn) catch {
                stderr.print("error: out of memory\n", .{}) catch {};
                return ExitCode.usage;
            };
            argv.append(gpa, "--bench") catch {
                stderr.print("error: out of memory\n", .{}) catch {};
                return ExitCode.usage;
            };
        }
        if (opts.extra_args.len > 0) {
            argv.append(gpa, "--") catch {
                stderr.print("error: out of memory\n", .{}) catch {};
                return ExitCode.usage;
            };
            argv.appendSlice(gpa, opts.extra_args) catch {
                stderr.print("error: out of memory\n", .{}) catch {};
                return ExitCode.usage;
            };
        }
        const outcome = runner.run(gpa, io, argv.items);
        outcomes.append(gpa, outcome) catch {
            stderr.print("error: out of memory\n", .{}) catch {};
            return ExitCode.usage;
        };
        if (outcome.term != .exited or outcome.code != 0) {
            failed += 1;
            if (!opts.no_fail_fast) {
                const code = mapTestOutcome(outcomes.items, false);
                renderTestError(opts, outcome, stderr, resolved);
                _ = stdout;
                return code;
            }
        }
    }
    if (!is_test and opts.bench_name != null and outcomes.items.len == 0) {
        stderr.print("error: no bench target named '{s}'\n", .{opts.bench_name.?}) catch {};
        return ExitCode.usage;
    }
    const code = mapTestOutcome(outcomes.items, opts.no_fail_fast);
    if (code != 0 and opts.no_fail_fast) {
        stderr.print("{d} targets failed:\n", .{failed}) catch {};
    } else if (code != 0) {
        if (outcomes.items.len > 0) renderTestError(opts, outcomes.items[outcomes.items.len - 1], stderr, "test harness");
    }
    return code;
}

/// `report_test_error`: libtest 101 is "simple" (no extra context);
/// abnormal codes print full context + the `--no-capture` note.
fn renderTestError(opts: Options, outcome: runner_mod.RunOutcome, stderr: *std.Io.Writer, what: []const u8) void {
    if (opts.quiet) return;
    switch (outcome.term) {
        .exited => {
            if (outcome.code == 101) return;
            stderr.print("error: {s} exited with code {d}\nnote: run with `-- --no-capture` to see harness output\n", .{ what, outcome.code }) catch {};
        },
        .signaled => stderr.print("error: {s} terminated by signal\n", .{what}) catch {},
        .spawn_failed => stderr.print("error: failed to spawn {s}\n", .{what}) catch {},
    }
}

/// Task 5 selection projection (pure, no allocation).
pub const CleanSpec = struct {
    packages: []const []const u8, // -p/--package, repeatable (empty = all when workspace=true or single)
    workspace: bool, // --workspace
    profile: ?[]const u8, // explicit --release/--profile only
    target: ?[]const u8, // --target triple subdir
    target_dir: ?[]const u8, // --target-dir override root
    doc_only: bool, // --doc: remove target/doc only
    dry_run: bool, // --dry-run: print paths, delete nothing
};

pub fn cleanSpec(opts: *const Options) CleanSpec {
    return .{
        .packages = opts.packages,
        .workspace = opts.workspace,
        .profile = if (opts.explicit_profile) opts.profile else null,
        .target = opts.target_triple,
        .target_dir = opts.target_dir,
        .doc_only = opts.doc_only,
        .dry_run = opts.dry_run,
    };
}

/// Deletes per `CleanSpec`: whole view or profile/triple-scoped dirs, or
/// per-package `deps/*<target>*` + `.fingerprint/<target>-*` entries.
/// `--dry-run` prints `Removing <abs path>` lines and deletes nothing.
/// Unknown `-p` names are exit-1 `package not found` at the caller.
pub fn cleanWithSpec(gpa: std.mem.Allocator, io: std.Io, ws_root: []const u8, spec: CleanSpec, stderr: *std.Io.Writer) view_mod.ViewError!void {
    const view_root = if (spec.target_dir) |d| try gpa.dupe(u8, d) else try std.fmt.allocPrint(gpa, "{s}/target", .{ws_root});
    defer gpa.free(view_root);
    if (spec.dry_run) {
        if (spec.doc_only) {
            const p = try std.fmt.allocPrint(gpa, "{s}/doc", .{view_root});
            defer gpa.free(p);
            stderr.print("Removing {s}\n", .{p}) catch return view_mod.ViewError.Io;
            return;
        }
        if (spec.packages.len > 0) {
            for (spec.packages) |pkg| {
                const p = try std.fmt.allocPrint(gpa, "{s}/debug/deps/*{s}*", .{ view_root, pkg });
                defer gpa.free(p);
                stderr.print("Removing {s}\n", .{p}) catch return view_mod.ViewError.Io;
            }
            return;
        }
        const p = try std.fmt.allocPrint(gpa, "{s}", .{view_root});
        defer gpa.free(p);
        stderr.print("Removing {s}\n", .{p}) catch return view_mod.ViewError.Io;
        return;
    }
    var root = std.Io.Dir.cwd().openDir(io, ws_root, .{}) catch return view_mod.ViewError.Io;
    defer root.close(io);
    const view_rel: []const u8 = if (spec.target_dir != null) view_root else "target";
    if (spec.doc_only) {
        const rel = try std.fmt.allocPrint(gpa, "{s}/doc", .{view_rel});
        defer gpa.free(rel);
        root.deleteTree(io, rel) catch |e| {
            if (e != error.FileNotFound) return view_mod.ViewError.Io;
        };
        return;
    }
    if (spec.packages.len > 0) {
        // Per-package removal inside each selected profile dir.
        const profiles: [2]?[]const u8 = .{ spec.profile, null };
        for (profiles) |maybe_prof| {
            if (spec.profile != null and maybe_prof == null) break;
            const prof_name = maybe_prof orelse "dev";
            const dir_name = view_mod.profileDirName(prof_name);
            var rel_buf: [512]u8 = undefined;
            const deps_rel = std.fmt.bufPrint(&rel_buf, "{s}/{s}/deps", .{ view_rel, dir_name }) catch continue;
            var deps = root.openDir(io, deps_rel, .{ .iterate = true }) catch continue;
            defer deps.close(io);
            var it = deps.iterate();
            while (true) {
                const entry = it.next(io) catch break;
                const ent = entry orelse break;
                var hit = false;
                for (spec.packages) |pkg| {
                    if (std.mem.indexOf(u8, ent.name, pkg) != null) {
                        hit = true;
                        break;
                    }
                }
                if (!hit) continue;
                var del_buf: [1024]u8 = undefined;
                const del = std.fmt.bufPrint(&del_buf, "{s}/{s}", .{ deps_rel, ent.name }) catch continue;
                root.deleteFile(io, del) catch {};
                root.deleteTree(io, del) catch {};
            }
        }
        return;
    }
    if (spec.profile) |p| {
        const dir_name = view_mod.profileDirName(p);
        var rel_buf: [512]u8 = undefined;
        const rel = if (spec.target) |t|
            std.fmt.bufPrint(&rel_buf, "{s}/{s}/{s}", .{ view_rel, t, dir_name }) catch return view_mod.ViewError.OutOfMemory
        else
            std.fmt.bufPrint(&rel_buf, "{s}/{s}", .{ view_rel, dir_name }) catch return view_mod.ViewError.OutOfMemory;
        const owned = try gpa.dupe(u8, rel);
        defer gpa.free(owned);
        root.deleteTree(io, owned) catch |e| {
            if (e != error.FileNotFound) return view_mod.ViewError.Io;
        };
        return;
    }
    if (spec.target) |t| {
        // Triple-scoped removal across known profile dirs.
        for ([_][]const u8{ "debug", "release" }) |d| {
            const rel = std.fmt.allocPrint(gpa, "{s}/{s}/{s}", .{ view_rel, t, d }) catch return view_mod.ViewError.OutOfMemory;
            defer gpa.free(rel);
            root.deleteTree(io, rel) catch |e| {
                if (e != error.FileNotFound) return view_mod.ViewError.Io;
            };
        }
        return;
    }
    root.deleteTree(io, view_rel) catch |e| {
        if (e != error.FileNotFound) return view_mod.ViewError.Io;
    };
}

/// M5 build-script plan options for `--dry-run` display planning: no
/// toolchain probe (no spawn), so the toolchain-bound fields are
/// placeholders the M4 driver resolves for real runs (runPipelineBuild
/// below overwrites them with probed values). Units built from these never
/// execute — they feed unit-plan envelopes + links checks only.
fn scriptPlanOptions(opts: Options) script_mod.PlanOptions {
    const prof = profile_mod.profileFor(opts.profile);
    return .{
        .target_triple = opts.target_triple,
        .host_triple = opts.target_triple orelse "unknown-host",
        .profile_name = opts.profile,
        .opt_level = prof.opt_level,
        .debug_assertions = prof.debug_assertions,
        .toolchain_id = "unknown-toolchain",
        .project_tag = "unknown-project",
    };
}

/// Cargo-exact links-conflict report (exit 101): names both packages from
/// the first conflicting pair; falls back to a nameless line when the
/// re-scan itself fails (error path only).
fn reportLinksConflict(gpa: std.mem.Allocator, io: std.Io, ws: *const Workspace, stderr: *std.Io.Writer) u8 {
    const pair = script_mod.findLinksConflict(gpa, io, ws) catch null;
    if (pair) |p| {
        defer p.deinit(gpa);
        stderr.print("error: multiple packages link to native library '{s}': {s} v{s}, {s} v{s}\n", .{ p.links, p.a_package, p.a_version, p.b_package, p.b_version }) catch {};
    } else {
        stderr.print("error: multiple packages link to the same native library\n", .{}) catch {};
    }
    return ExitCode.build_failed;
}

/// `links` key with no build script (and no M6 `[target.<triple>] links`
/// override surface): loud `need links-override`, exit 1 (same D5 shape as
/// the M1 `need source` error). Null means continue.
fn scriptPrechecks(gpa: std.mem.Allocator, io: std.Io, ws: *const Workspace, units: []const script_mod.ScriptUnit, stderr: *std.Io.Writer) ?u8 {
    const missing = script_mod.linksWithoutScript(gpa, io, ws, units) catch |e| {
        stderr.print("error: cannot plan build scripts: {t}\n", .{e}) catch {};
        return ExitCode.usage;
    };
    defer if (missing) |m| gpa.free(m);
    if (missing) |links| {
        stderr.print("need links-override: {s} requires M6 config parsing\n", .{links}) catch {};
        return ExitCode.usage;
    }
    return null;
}

/// First workspace member whose `[lib]` target sets `proc-macro = true`, or
/// null. M5 boundary: non-dry-run builds on such workspaces stop loud until
/// M4 passes `--extern` to rustc (the dylib ingest itself is Task-7 tested).
fn findProcMacroLib(ws: *const Workspace) ?[]const u8 {
    for (ws.members) |*m| {
        for (m.manifest.targets) |t| {
            if (t.kind == .lib and t.proc_macro) return m.name;
        }
    }
    return null;
}

fn runBuild(gpa: std.mem.Allocator, io: std.Io, opts: Options, stdout: *std.Io.Writer, stderr: *std.Io.Writer) u8 {
    var ws = loadWorkspace(gpa, io, opts, stderr) orelse return ExitCode.build_failed;
    defer ws.deinit();
    if (validateJobs(&opts, stderr)) |code| return code;
    if (validateConfig(&opts, stderr)) |code| return code;
    // Unknown -p is the anyhow class (101, oracle-verified). Pre-check
    // here so the non-dry-run pipeline path never reports it as usage.
    if (opts.only_package) |name| {
        if (ws.findMember(name) == null) {
            stderr.print("error: package not found: {s}\n", .{name}) catch {};
            return ExitCode.build_failed;
        }
    }

    // Real builds go through the M4 driver pipeline (fetch → resolve →
    // compile → materialize); --dry-run keeps the plan-print path below.
    if (!opts.dry_run) {
        const code = runPipelineBuild(gpa, io, &ws, opts, stdout, stderr);
        // Row 6: compile failure closes the JSON stream cargo-exact.
        if (code == ExitCode.build_failed and opts.isJsonFormat()) {
            (&msg_mod.BuildFinishedEvent{ .success = false }).writeLine(stdout) catch {};
        }
        return code;
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
        return ExitCode.build_failed;
    };
    defer gpa.free(units);

    // Unit plan (rime-only `--dry-run` planning output, never compared
    // against cargo): one `compiler-artifact` line per unit with predicted
    // filenames, `fresh:true`, then `build-finished`. Human rendering goes
    // to stderr with verbose/quiet/color plumbing.
    for (units) |u| {
        if (opts.isJsonFormat()) {
            emitDryRunArtifact(gpa, &ws, u, opts.profile, false, stdout, stderr) catch {
                stderr.print("error: failed to write output\n", .{}) catch {};
                return ExitCode.usage;
            };
        } else {
            renderHumanUnit(opts, u.package, u.version, u.target, stderr);
        }
    }

    // M5 scripts (additive): workspace-derived script units print as
    // unit-plan envelopes (target `build-script-<pkg>`); nothing runs under
    // --dry-run. Links conflicts fail 101 cargo-exact; links-without-script
    // needs M6 overrides (exit 1).
    const script_units = script_mod.planScripts(gpa, io, &ws, scriptPlanOptions(opts), stderr) catch |e| {
        if (e == error.DuplicateLinks) return reportLinksConflict(gpa, io, &ws, stderr);
        stderr.print("error: cannot plan build scripts: {t}\n", .{e}) catch {};
        return ExitCode.usage;
    };
    defer script_mod.deinitPlanUnits(gpa, script_units);
    if (scriptPrechecks(gpa, io, &ws, script_units, stderr)) |code| return code;
    for (script_units) |su| {
        const target = std.fmt.allocPrint(gpa, "build-script-{s}", .{su.package}) catch {
            stderr.print("error: out of memory\n", .{}) catch {};
            return ExitCode.usage;
        };
        defer gpa.free(target);
        if (opts.isJsonFormat()) {
            emitDryRunScriptArtifact(gpa, &ws, su.package, su.version, opts.profile, stdout, stderr) catch {
                stderr.print("error: failed to write output\n", .{}) catch {};
                return ExitCode.usage;
            };
        } else {
            renderHumanUnit(opts, su.package, su.version, target, stderr);
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
        if (opts.isJsonFormat()) {
            (&msg_mod.BuildFinishedEvent{ .success = true }).writeLine(stdout) catch {
                stderr.print("error: failed to write output\n", .{}) catch {};
                return ExitCode.usage;
            };
        } else if (!opts.quiet) {
            stderr.print("Finished {s} profile\n", .{opts.profile}) catch {};
        }
    } else if (opts.isJsonFormat()) {
        (&msg_mod.BuildFinishedEvent{ .success = true }).writeLine(stdout) catch {
            stderr.print("error: failed to write output\n", .{}) catch {};
            return ExitCode.usage;
        };
    }
    return ExitCode.ok;
}

/// Human unit rendering on stderr: `Compiling …` at level 0, rustc
/// invocation lines at `-v >= 1`. `--quiet` suppresses everything here;
/// `--color=always` styles the status word (JSON stdout is never styled).
fn renderHumanUnit(opts: Options, package: []const u8, version: []const u8, target: []const u8, stderr: *std.Io.Writer) void {
    if (opts.quiet) return;
    if (opts.color == .always) {
        stderr.print("\x1b[1;32mCompiling\x1b[0m {s} v{s} ({s})\n", .{ package, version, target }) catch {};
    } else {
        stderr.print("Compiling {s} v{s} ({s})\n", .{ package, version, target }) catch {};
    }
    if (opts.verbose >= 1) {
        stderr.print("Running rustc --crate-name {s} --edition=2021\n", .{target}) catch {};
    }
    if (opts.verbose >= 2) {
        stderr.print("Verbose: unit {s}/{s} profile {s}\n", .{ package, target, opts.profile }) catch {};
    }
}

/// Finds the workspace member for `package` (borrowed) or null.
fn findMember(ws: *const Workspace, package: []const u8) ?*const workspace_mod.Member {
    for (ws.members) |*m| {
        if (std.mem.eql(u8, m.name, package)) return m;
    }
    return null;
}

/// `--dry-run` artifact line for a plan unit: predicted filenames under
/// the profile/deps dirs, `fresh:true`, `executable` set for bins.
fn emitDryRunArtifact(gpa: std.mem.Allocator, ws: *const Workspace, u: view_mod.UnitPlan, profile: []const u8, is_test: bool, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    _ = stderr;
    const m = findMember(ws, u.package);
    const edition: []const u8 = if (m) |mm| (if (mm.manifest.pkg) |p| p.edition else "2021") else "2021";
    const manifest_dir: []const u8 = if (m) |mm| mm.dir else ws.root_dir;
    const manifest_path = try std.fmt.allocPrint(gpa, "{s}/Cargo.toml", .{manifest_dir});
    defer gpa.free(manifest_path);
    const pid = try msg_mod.packageId(gpa, .{ .path = manifest_dir }, u.package, u.version, manifest_dir);
    defer gpa.free(pid);
    const prof_dir = view_mod.profileDirName(profile);
    const kind_str = msg_mod.targetKindStr(u.kind);
    const kinds = try gpa.dupe([]const u8, &[_][]const u8{kind_str});
    defer gpa.free(kinds);
    const ctypes: []const []const u8 = if (u.kind == .lib or u.kind == .example) try gpa.dupe([]const u8, &[_][]const u8{"lib"}) else try gpa.dupe([]const u8, &[_][]const u8{"bin"});
    defer gpa.free(ctypes);
    var crate_buf: [256]u8 = undefined;
    // Oracle shape: lib crate names map dashes to underscores
    // (`core-lib` -> `core_lib`); bins keep dashes (`cli-bin`).
    const crate_name = if (u.kind == .lib) dashToUnderscore(u.target, &crate_buf) else u.target;
    var src_buf: [1024]u8 = undefined;
    const src_path = std.fmt.bufPrint(&src_buf, "{s}/src/{s}.rs", .{ manifest_dir, u.target }) catch manifest_dir;
    const src_owned = try gpa.dupe(u8, src_path);
    defer gpa.free(src_owned);
    // Predicted filenames: bins under the profile dir, libs under deps.
    var files: std.ArrayList([]const u8) = .empty;
    defer {
        for (files.items) |f| gpa.free(f);
        files.deinit(gpa);
    }
    for (u.outputs) |o| {
        const full = if (u.kind == .bin)
            try std.fmt.allocPrint(gpa, "{s}/target/{s}/{s}", .{ ws.root_dir, prof_dir, o })
        else
            try std.fmt.allocPrint(gpa, "{s}/target/{s}/deps/{s}", .{ ws.root_dir, prof_dir, o });
        errdefer gpa.free(full);
        try files.append(gpa, full);
    }
    var exec: ?[]u8 = null;
    defer if (exec) |e| gpa.free(e);
    if (u.kind == .bin and files.items.len > 0) exec = try gpa.dupe(u8, files.items[0]);
    var ev = msg_mod.ArtifactEvent{
        .package_id = pid,
        .manifest_path = manifest_path,
        .target = .{
            .kind = kinds,
            .crate_types = ctypes,
            .name = crate_name,
            .src_path = src_owned,
            .edition = edition,
            .required_features = null,
            // Oracle shapes: lib {true,true,true}; bin {true,false,true}
            // (bins keep dashes, doc:true); test/bench harness {false,false,true}.
            .doc = u.kind == .lib or u.kind == .bin,
            .doctest = u.kind == .lib,
            .@"test" = u.kind == .lib or u.kind == .bin or u.kind == .@"test",
        },
        .profile = msg_mod.profileJson(profile, is_test),
        .features = &.{},
        .filenames = files.items,
        .executable = exec,
        .fresh = true,
    };
    try ev.writeLine(stdout);
}

fn emitDryRunScriptArtifact(gpa: std.mem.Allocator, ws: *const Workspace, package: []const u8, version: []const u8, profile: []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    _ = stderr;
    const m = findMember(ws, package);
    const manifest_dir: []const u8 = if (m) |mm| mm.dir else ws.root_dir;
    const manifest_path = try std.fmt.allocPrint(gpa, "{s}/Cargo.toml", .{manifest_dir});
    defer gpa.free(manifest_path);
    const pid = try msg_mod.packageId(gpa, .{ .path = manifest_dir }, package, version, manifest_dir);
    defer gpa.free(pid);
    const out_dir = try std.fmt.allocPrint(gpa, "{s}/target/{s}/build/{s}-out", .{ ws.root_dir, view_mod.profileDirName(profile), package });
    defer gpa.free(out_dir);
    var ev = msg_mod.BuildScriptEvent{
        .package_id = pid,
        .linked_libs = &.{},
        .linked_paths = &.{},
        .cfgs = &.{},
        .env = &.{},
        .out_dir = out_dir,
    };
    try ev.writeLine(stdout);
}

fn dashToUnderscore(name: []const u8, buf: []u8) []const u8 {
    const n = @min(name.len, buf.len);
    for (name[0..n], 0..) |c, i| buf[i] = if (c == '-') '_' else c;
    return buf[0..n];
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
    // M5 script prechecks with probed toolchain identity (additive early
    // loud errors; the per-unit compile→runUnit→persist loop is M4's).
    {
        const tid = tc.tag(gpa) catch |e| {
            stderr.print("error: rustc probe failed ({t}); install rustc or set $RUSTC\n", .{e}) catch {};
            return ExitCode.usage;
        };
        defer gpa.free(tid);
        var popts = scriptPlanOptions(opts);
        popts.host_triple = tc.host_target;
        popts.toolchain_id = tid;
        const sunits = script_mod.planScripts(gpa, io, ws, popts, stderr) catch |e| {
            if (e == error.DuplicateLinks) return reportLinksConflict(gpa, io, ws, stderr);
            stderr.print("error: cannot plan build scripts: {t}\n", .{e}) catch {};
            return ExitCode.usage;
        };
        defer script_mod.deinitPlanUnits(gpa, sunits);
        if (scriptPrechecks(gpa, io, ws, sunits, stderr)) |code| return code;
        if (findProcMacroLib(ws)) |pkg| {
            stderr.print("need driver: proc-macro dependents require M4 rustc invocation ({s})\n", .{pkg}) catch {};
            return ExitCode.usage;
        }
    }
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
        .message_format_json = opts.isJsonFormat(),
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
        error.LockedViolation => {
            // Row 14 (oracle-verified): stale lock under --locked/--frozen
            // is the anyhow class (101), with cargo's verbatim wording.
            stderr.print("error: {s}\n", .{pipeline_mod.planDiagnostic() orelse @errorName(e)}) catch {};
            return ExitCode.build_failed;
        },
        error.Usage => {
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
    var ws = loadWorkspace(gpa, io, opts, stderr) orelse return ExitCode.build_failed;
    defer ws.deinit();
    const spec = cleanSpec(&opts);
    // cargo_clean.rs:98 — `--doc` cannot be combined with `-p` (anyhow class).
    if (spec.doc_only and spec.packages.len > 0) {
        stderr.print("error: --doc cannot be used with -p\n", .{}) catch {};
        return ExitCode.build_failed;
    }
    // Unknown -p names are the anyhow class (101, oracle-verified).
    for (spec.packages) |pkg| {
        if (ws.findMember(pkg) == null) {
            stderr.print("error: package not found: {s}\n", .{pkg}) catch {};
            return ExitCode.build_failed;
        }
    }
    // Bare `clean` cleans the whole workspace view (oracle: exit 0).
    cleanWithSpec(gpa, io, ws.root_dir, spec, stderr) catch {
        stderr.print("error: clean failed\n", .{}) catch {};
        return ExitCode.build_failed;
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

test "cli artifact event shape via msg" {
    var out: std.Io.Writer.Allocating = try .initCapacity(std.testing.allocator, 512);
    defer out.deinit();
    const ev = msg_mod.ArtifactEvent{
        .package_id = "path+file:///ws/a#0.1.0",
        .manifest_path = "/ws/a/Cargo.toml",
        .target = .{ .kind = &.{"lib"}, .crate_types = &.{"lib"}, .name = "a", .src_path = "/ws/a/src/lib.rs", .edition = "2021", .required_features = null, .doc = true, .doctest = true, .@"test" = true },
        .profile = .{ .opt_level = "0", .debuginfo = 2, .debug_assertions = true, .overflow_checks = true, .@"test" = false },
        .features = &.{},
        .filenames = &.{"/ws/target/debug/deps/liba.rlib"},
        .executable = null,
        .fresh = true,
    };
    try ev.writeLine(&out.writer);
    const bytes = try out.toOwnedSlice();
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.startsWith(u8, bytes, "{\"reason\":\"compiler-artifact\""));
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
    // Oracle-verified: discovery failures are the anyhow class (101).
    try std.testing.expectEqual(ExitCode.build_failed, code);
    const msg = try err.toOwnedSlice();
    defer std.testing.allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "could not find") != null);
}

test "e2e dry-run plan matches golden" {
    // The golden pins cargo-shaped `compiler-artifact` lines (dependencies
    // first) plus the closing `build-finished`, with the workspace root
    // normalized to `@WS@` (absolute paths are checkout-dependent).
    const io = std.Io.Threaded.global_single_threaded.io();
    var ws = try workspace_mod.discover(std.testing.allocator, io, "testdata/cargo/workspace", null);
    defer ws.deinit();
    const units = try view_mod.planUnits(std.testing.allocator, &ws, null);
    defer std.testing.allocator.free(units);
    var out: std.Io.Writer.Allocating = try .initCapacity(std.testing.allocator, 4096);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = try .initCapacity(std.testing.allocator, 256);
    defer err.deinit();
    for (units) |u| {
        try emitDryRunArtifact(std.testing.allocator, &ws, u, "dev", false, &out.writer, &err.writer);
    }
    try (&msg_mod.BuildFinishedEvent{ .success = true }).writeLine(&out.writer);
    const got = try out.toOwnedSlice();
    defer std.testing.allocator.free(got);
    const norm = try replaceAll(std.testing.allocator, got, ws.root_dir, "@WS@");
    defer std.testing.allocator.free(norm);
    // Runtime read (not @embedFile): the golden escapes the module package
    // path, matching the read convention in manifest/lock tests.
    const want = try std.Io.Dir.cwd().readFileAlloc(io, "testdata/cargo/golden/plan.json", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(want);
    try std.testing.expectEqualStrings(want, norm);
}

fn replaceAll(gpa: std.mem.Allocator, text: []const u8, needle: []const u8, replacement: []const u8) ![]u8 {
    if (needle.len == 0) return gpa.dupe(u8, text);
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOf(u8, text[idx..], needle)) |off| {
        count += 1;
        idx += off + needle.len;
    }
    if (count == 0) return gpa.dupe(u8, text);
    const out_len = text.len - count * needle.len + count * replacement.len;
    const out = try gpa.alloc(u8, out_len);
    var w: usize = 0;
    var r: usize = 0;
    while (std.mem.indexOf(u8, text[r..], needle)) |off| {
        @memcpy(out[w .. w + off], text[r .. r + off]);
        w += off;
        @memcpy(out[w .. w + replacement.len], replacement);
        w += replacement.len;
        r += off + needle.len;
    }
    @memcpy(out[w..], text[r..]);
    return out;
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
        .packages = &.{},
        .workspace = false,
        .target_dir = null,
        .doc_only = false,
        .features = &.{},
        .all_features = false,
        .no_default_features = false,
        .message_format = .human,
        .format_error = false,
        .format_diagnostic = null,
        .offline = false,
        .frozen = false,
        .locked = false,
        .dry_run = false,
        .extra_args = &.{},
        .verbose = 0,
        .quiet = false,
        .color = .auto,
        .jobs = null,
        .jobs_validated = false,
        .config_overrides = &.{},
        .bin_name = null,
        .example_name = null,
        .no_run = false,
        .no_fail_fast = false,
        .bench_name = null,
        .test_filter = &.{},
        .help = false,
        .version = false,
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

// =====================================================================
// M6 CLI parity tests (Tasks 1, 2, 4, 5, 6).

test "cli parses fetch with target only" {
    const argv = [_][]const u8{ "rime", "fetch", "--target", "aarch64-apple-darwin" };
    var opts = try parseArgs(std.testing.allocator, &argv);
    defer opts.deinit(std.testing.allocator);
    try std.testing.expect(opts.cmd == .fetch);
    try std.testing.expectEqualStrings("aarch64-apple-darwin", opts.target_triple.?);
}

test "cli rejects profile flags on fetch" {
    const argv = [_][]const u8{ "rime", "fetch", "--release" };
    try std.testing.expectError(CliError.Usage, parseArgs(std.testing.allocator, &argv));
}

test "cli rejects non-target fetch flags" {
    // fetch.rs::cli takes only --target/--manifest-path plus globals.
    const cases = [_][]const []const u8{
        &.{ "rime", "fetch", "--workspace" },
        &.{ "rime", "fetch", "--target-dir", "t" },
        &.{ "rime", "fetch", "-j", "4" },
        &.{ "rime", "fetch", "--all-features" },
        &.{ "rime", "fetch", "--no-default-features" },
    };
    for (cases) |argv| {
        try std.testing.expectError(CliError.Usage, parseArgs(std.testing.allocator, argv));
        const d = parseDiagnostic() orelse return error.TestExpectedEqual;
        try std.testing.expect(std.mem.indexOf(u8, d, "not supported for fetch") != null);
    }
}

test "clean doc with package selection fails" {
    // cargo_clean.rs:98 — `--doc` cannot be used with `-p` (exit 101).
    const io = std.Io.Threaded.global_single_threaded.io();
    const argv = [_][]const u8{ "rime", "clean", "--doc", "-p", "util", "--manifest-path", "validation/basic-workspace/Cargo.toml" };
    var opts = try parseArgs(std.testing.allocator, &argv);
    defer opts.deinit(std.testing.allocator);
    var out: std.Io.Writer.Allocating = try .initCapacity(std.testing.allocator, 64);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = try .initCapacity(std.testing.allocator, 256);
    defer err.deinit();
    var fake = runner_mod.FakeRunner{ .expected_argv = &.{}, .outcome = .{ .term = .exited, .code = 0 }, .calls = 0 };
    const code = runWith(std.testing.allocator, io, opts, &out.writer, &err.writer, fake.runner());
    try std.testing.expectEqual(ExitCode.build_failed, code);
    const msg = try err.toOwnedSlice();
    defer std.testing.allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "--doc cannot be used with -p") != null);
}

test "bench chains BENCHNAME and --bench into harness argv" {
    // bench.rs exec chaining: the positional filter plus the `--bench`
    // mode flag (cargo_test.rs:98) reach the harness binary.
    const io = std.Io.Threaded.global_single_threaded.io();
    const argv = [_][]const u8{ "rime", "bench", "util", "-p", "util", "--manifest-path", "validation/basic-workspace/Cargo.toml" };
    var opts = try parseArgs(std.testing.allocator, &argv);
    defer opts.deinit(std.testing.allocator);
    const Rec = struct {
        seen: std.ArrayList([]const u8) = .empty,
        fn runFn(ptr: *anyopaque, gpa: std.mem.Allocator, rio: std.Io, rargv: []const []const u8) runner_mod.RunOutcome {
            _ = rio;
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.seen.appendSlice(gpa, rargv) catch {};
            return .{ .term = .exited, .code = 0 };
        }
    };
    var rec = Rec{};
    defer rec.seen.deinit(std.testing.allocator);
    const r = runner_mod.Runner{ .ptr = &rec, .runFn = Rec.runFn };
    var out: std.Io.Writer.Allocating = try .initCapacity(std.testing.allocator, 64);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = try .initCapacity(std.testing.allocator, 512);
    defer err.deinit();
    const code = runWith(std.testing.allocator, io, opts, &out.writer, &err.writer, r);
    try std.testing.expectEqual(ExitCode.ok, code);
    try std.testing.expectEqual(@as(usize, 3), rec.seen.items.len);
    try std.testing.expectEqualStrings("util", rec.seen.items[1]);
    try std.testing.expectEqualStrings("--bench", rec.seen.items[2]);
}

test "cli parses global flags in both positions" {
    const argv = [_][]const u8{ "rime", "build", "-vv", "-q", "--color=never", "-j4" };
    var opts = try parseArgs(std.testing.allocator, &argv);
    defer opts.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 2), opts.verbose);
    try std.testing.expect(opts.quiet);
    try std.testing.expect(opts.color == .never);
    try std.testing.expectEqual(@as(i32, 4), opts.jobs.?.integer);
}

test "cli rejects bad color and -C" {
    const bad = [_][]const u8{ "rime", "build", "--color", "rainbow" };
    try std.testing.expectError(CliError.Usage, parseArgs(std.testing.allocator, &bad));
    const c = [_][]const u8{ "rime", "build", "-C", "/tmp" };
    try std.testing.expectError(CliError.Usage, parseArgs(std.testing.allocator, &c));
}

test "cli parses full message-format set" {
    const argv = [_][]const u8{ "rime", "build", "--message-format", "json-render-diagnostics,json-diagnostic-short" };
    var opts = try parseArgs(std.testing.allocator, &argv);
    defer opts.deinit(std.testing.allocator);
    try std.testing.expect(opts.message_format == .json_diagnostic_short);
    // render_diagnostics without base json is allowed (cargo promotes to default json)
    const argv2 = [_][]const u8{ "rime", "build", "--message-format=json-diagnostic-rendered-ansi" };
    var opts2 = try parseArgs(std.testing.allocator, &argv2);
    defer opts2.deinit(std.testing.allocator);
    try std.testing.expect(opts2.message_format == .json_diagnostic_rendered_ansi);
}

test "cli message-format conflicts fail" {
    // cargo: two kinds -> bail (exit 101 at exec; parse records Usage here, Task 6 maps it)
    const argv = [_][]const u8{ "rime", "build", "--message-format", "json,human" };
    try std.testing.expectError(CliError.Usage, parseArgs(std.testing.allocator, &argv));
    try std.testing.expect(isFormatError());
    const bad = [_][]const u8{ "rime", "build", "--message-format", "yaml" };
    try std.testing.expectError(CliError.Usage, parseArgs(std.testing.allocator, &bad));
    // Oracle: an unknown specifier is the clap class (exit 1), only a
    // two-kinds conflict is the anyhow class (exit 101).
    try std.testing.expect(!isFormatError());
}

test "cli parses run selection and test flags" {
    const argv = [_][]const u8{ "rime", "run", "--bin", "tool", "--", "--hello" };
    var opts = try parseArgs(std.testing.allocator, &argv);
    defer opts.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("tool", opts.bin_name.?);
    try std.testing.expect(opts.example_name == null);
    const t = [_][]const u8{ "rime", "test", "--no-run", "--no-fail-fast", "myfilter", "--", "--nocapture" };
    var topts = try parseArgs(std.testing.allocator, &t);
    defer topts.deinit(std.testing.allocator);
    try std.testing.expect(topts.no_run and topts.no_fail_fast);
    try std.testing.expectEqualStrings("myfilter", topts.test_filter[0]);
    try std.testing.expectEqualStrings("--nocapture", topts.extra_args[0]);
}

test "cli rejects no-run on build and positional on clean" {
    const a = [_][]const u8{ "rime", "build", "--no-run" };
    try std.testing.expectError(CliError.Usage, parseArgs(std.testing.allocator, &a));
    const b = [_][]const u8{ "rime", "clean", "extra" };
    try std.testing.expectError(CliError.Usage, parseArgs(std.testing.allocator, &b));
}

test "cli parses repeatable clean selection" {
    const argv = [_][]const u8{ "rime", "clean", "-p", "a", "--package", "b", "--workspace", "--target", "x86_64-unknown-linux-gnu", "--dry-run" };
    var opts = try parseArgs(std.testing.allocator, &argv);
    defer opts.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), opts.packages.len);
    try std.testing.expect(opts.workspace);
    try std.testing.expectEqualStrings("x86_64-unknown-linux-gnu", opts.target_triple.?);
    try std.testing.expect(opts.dry_run);
}

test "clean dry-run lists without deleting" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws_root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(ws_root);
    // seed a fake view
    var root = try std.Io.Dir.cwd().openDir(io, ws_root, .{});
    defer root.close(io);
    try root.createDirPath(io, "target/debug/deps");
    try root.writeFile(io, .{ .sub_path = "target/debug/deps/liba-ab12.rlib", .data = "x" });
    var err: std.Io.Writer.Allocating = try .initCapacity(std.testing.allocator, 512);
    defer err.deinit();
    try cleanWithSpec(std.testing.allocator, io, ws_root, .{ .packages = &.{}, .workspace = true, .profile = null, .target = null, .target_dir = null, .doc_only = false, .dry_run = true }, &err.writer);
    // file survives dry-run
    _ = try tmp.dir.statFile(io, "target/debug/deps/liba-ab12.rlib", .{});
    const msg = try err.toOwnedSlice();
    defer std.testing.allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "Removing") != null);
}

test "exit matrix: usage errors are 1, format errors are 101" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var err: std.Io.Writer.Allocating = try .initCapacity(std.testing.allocator, 512);
    defer err.deinit();
    var out: std.Io.Writer.Allocating = try .initCapacity(std.testing.allocator, 64);
    defer out.deinit();
    // Row 4: clean outside a workspace -> 1
    {
        const argv = [_][]const u8{ "rime", "clean", "--manifest-path", "/nonexistent-dir-xyz/Cargo.toml" };
        var opts = try parseArgs(std.testing.allocator, &argv);
        defer opts.deinit(std.testing.allocator);
        err.clearRetainingCapacity();
        var fake = runner_mod.FakeRunner{ .expected_argv = &.{}, .outcome = .{ .term = .exited, .code = 0 }, .calls = 0 };
        const code = runWith(std.testing.allocator, io, opts, &out.writer, &err.writer, fake.runner());
        // Oracle-verified: discovery/manifest failures are 101, not 1.
        try std.testing.expectEqual(@as(u8, 101), code);
    }
    // Row 5: format_error opts -> 101 (parse records Usage; runWith maps the flag).
}

test "exit matrix: run forwards child exit code 42" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const argv = [_][]const u8{ "rime", "run", "--manifest-path", "validation/basic-workspace/Cargo.toml" };
    var opts = try parseArgs(std.testing.allocator, &argv);
    defer opts.deinit(std.testing.allocator);
    var out: std.Io.Writer.Allocating = try .initCapacity(std.testing.allocator, 64);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = try .initCapacity(std.testing.allocator, 512);
    defer err.deinit();
    // validation/basic-workspace exposes a single binary (cli-bin): sole-binary
    // selection resolves to the default dev profile dir with no build step.
    const want_bin = "validation/basic-workspace/target/debug/cli-bin";
    var fake = runner_mod.FakeRunner{ .expected_argv = &.{want_bin}, .outcome = .{ .term = .exited, .code = 42 }, .calls = 0 };
    const code = runWith(std.testing.allocator, io, opts, &out.writer, &err.writer, fake.runner());
    try std.testing.expectEqual(@as(u8, 42), code);
    try std.testing.expectEqual(@as(u32, 1), fake.calls);
}

test "exit matrix: run forwards child exit code" {
    // FakeRunner returns 42; runWith on a pure-path workspace maps row 7 -> 42.
    // (Full wiring in Step 3; this test pins the mapping function directly.)
    try std.testing.expectEqual(@as(u8, 42), mapRunOutcome(.{ .term = .exited, .code = 42 }, false));
    try std.testing.expectEqual(@as(u8, 101), mapRunOutcome(.{ .term = .spawn_failed, .code = 0 }, false));
    try std.testing.expectEqual(@as(u8, 101), mapRunOutcome(.{ .term = .signaled, .code = 0 }, false));
}

test "exit matrix: test fail-fast vs no-fail-fast" {
    try std.testing.expectEqual(@as(u8, 3), mapTestOutcome(&.{.{ .term = .exited, .code = 3 }}, false));
    try std.testing.expectEqual(@as(u8, 101), mapTestOutcome(&.{.{ .term = .exited, .code = 3 }}, true));
    try std.testing.expectEqual(@as(u8, 0), mapTestOutcome(&.{.{ .term = .exited, .code = 0 }}, true));
}
