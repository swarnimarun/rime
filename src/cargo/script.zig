//! Build-script lifecycle (Plan C M5, Tasks 1–6): directive parsing,
//! `links` metadata propagation, rerun fingerprints, action keys + store
//! ingest + OUT_DIR materialization, compile-then-run + sandbox, and
//! `links` validation + the M4 unit-graph seam.
//!
//! The pure core takes no `io`/Store so protocol tests run without
//! fixtures. Ownership: every `BuildOutput` slice borrows `input` (the
//! struct is valid only while `input` lives); only the outer slices are
//! gpa-owned and freed by `BuildOutput.deinit`. `propagateMetadata` values
//! borrow the `BuildOutput` slices; keys are gpa-owned.

const std = @import("std");
const builtin = @import("builtin");
const store_mod = @import("store");
const manifest_mod = @import("manifest.zig");
const workspace_mod = @import("workspace.zig");
const toolchain_mod = @import("toolchain.zig");

const Io = std.Io;
const Store = store_mod.Store;
const Digest = store_mod.Digest;
const Tag = store_mod.Tag;

// =====================================================================
// Task 1: directive parser (`parseBuildOutput`)
// =====================================================================

pub const DirectiveError = error{ InvalidDirective, UnknownKey } || std.mem.Allocator.Error;

pub const LinkArgTarget = enum { all, cdylib, bin, single_bin, @"test", bench, example };

pub const LinkArg = struct { target: LinkArgTarget, bin_name: ?[]const u8, arg: []const u8 };

pub const KeyValue = struct { key: []const u8, value: []const u8 };

pub const BuildOutput = struct {
    cfgs: []const []const u8, // cargo::rustc-cfg=FLAG (accumulates)
    check_cfgs: []const []const u8, // cargo::rustc-check-cfg=…
    link_libs: []const []const u8, // cargo::rustc-link-lib=… (+ -l from rustc-flags)
    link_search: []const []const u8, // cargo::rustc-link-search=… (+ paths from rustc-flags)
    link_args: []const LinkArg, // cargo::rustc-link-arg* family
    rustc_flags_raw: []const []const u8, // cargo::rustc-flags=VALUE verbatim (kept for diagnostics)
    env: []const KeyValue, // cargo::rustc-env=KEY=VALUE
    metadata: []const KeyValue, // cargo::KEY=VALUE unreserved (old) / cargo::metadata=KEY=VALUE (new)
    rerun_if_changed: []const []const u8, // cargo::rerun-if-changed=PATH
    rerun_if_env_changed: []const []const u8, // cargo::rerun-if-env-changed=NAME
    warnings: []const []const u8, // cargo::warning=… (new) / cargo:warning=… (old)
    errors: []const []const u8, // cargo::error=… (new syntax only)
    pub fn deinit(self: *const BuildOutput, gpa: std.mem.Allocator) void {
        gpa.free(self.cfgs);
        gpa.free(self.check_cfgs);
        gpa.free(self.link_libs);
        gpa.free(self.link_search);
        gpa.free(self.link_args);
        gpa.free(self.rustc_flags_raw);
        gpa.free(self.env);
        gpa.free(self.metadata);
        gpa.free(self.rerun_if_changed);
        gpa.free(self.rerun_if_env_changed);
        gpa.free(self.warnings);
        gpa.free(self.errors);
    }
};

pub const ParseOptions = struct {
    /// True when nightly features are allowed for this unit OR the parent
    /// process env already allowlists this crate in `RUSTC_BOOTSTRAP`
    /// (cargo `custom_build.rs:1074-1095` `rustc_bootstrap_allows`). Gates the
    /// `RUSTC_BOOTSTRAP` warn-vs-bail below.
    allow_rustc_bootstrap: bool = false,
    /// Target inventory for link-arg validation (cargo `check_and_add_target!`,
    /// `custom_build.rs:959-977`). `bin_names` holds every bin target name.
    has_cdylib: bool = false,
    bin_names: []const []const u8 = &.{},
    has_test: bool = false,
    has_bench: bool = false,
    has_example: bool = false,
};

fn isReservedNew(key: []const u8) bool {
    const reserved = [_][]const u8{
        "rustc-flags",           "rustc-link-lib",     "rustc-link-search",
        "rustc-link-arg-cdylib", "rustc-cdylib-link-arg",
        "rustc-link-arg-bins",   "rustc-link-arg-bin",
        "rustc-link-arg-tests",  "rustc-link-arg-benches",
        "rustc-link-arg-examples", "rustc-link-arg",
        "rustc-cfg",             "rustc-check-cfg",    "rustc-env",
        "warning",               "error",              "rerun-if-changed",
        "rerun-if-env-changed",  "metadata",
    };
    for (reserved) |r| if (std.mem.eql(u8, r, key)) return true;
    return false;
}

fn isReservedOld(data: []const u8) bool {
    // cargo RESERVED_PREFIXES (custom_build.rs): prefix match on "key=" form.
    const prefixes = [_][]const u8{
        "rustc-flags=",           "rustc-link-lib=",     "rustc-link-search=",
        "rustc-link-arg-cdylib=", "rustc-cdylib-link-arg=",
        "rustc-link-arg-bins=",   "rustc-link-arg-bin=",
        "rustc-link-arg-tests=",  "rustc-link-arg-benches=",
        "rustc-link-arg-examples=", "rustc-link-arg=",
        "rustc-cfg=",             "rustc-check-cfg=",    "rustc-env=",
        "warning=",               "rerun-if-changed=",  "rerun-if-env-changed=",
    };
    for (prefixes) |p| if (std.mem.startsWith(u8, data, p)) return true;
    return false;
}

fn splitKeyValue(data: []const u8) DirectiveError!struct { key: []const u8, value: []const u8 } {
    const eq = std.mem.indexOfScalar(u8, data, '=') orelse return DirectiveError.InvalidDirective;
    return .{
        .key = data[0..eq],
        .value = std.mem.trimEnd(u8, data[eq + 1 ..], " \t\r"),
    };
}

pub fn parseBuildOutput(gpa: std.mem.Allocator, input: []const u8, opts: ParseOptions) DirectiveError!BuildOutput {
    var cfgs: std.ArrayList([]const u8) = .empty;
    var check_cfgs: std.ArrayList([]const u8) = .empty;
    var link_libs: std.ArrayList([]const u8) = .empty;
    var link_search: std.ArrayList([]const u8) = .empty;
    var link_args: std.ArrayList(LinkArg) = .empty;
    var rustc_flags_raw: std.ArrayList([]const u8) = .empty;
    var env: std.ArrayList(KeyValue) = .empty;
    var metadata: std.ArrayList(KeyValue) = .empty;
    var rerun_if_changed: std.ArrayList([]const u8) = .empty;
    var rerun_if_env_changed: std.ArrayList([]const u8) = .empty;
    var warnings: std.ArrayList([]const u8) = .empty;
    var errors: std.ArrayList([]const u8) = .empty;
    errdefer {
        cfgs.deinit(gpa);
        check_cfgs.deinit(gpa);
        link_libs.deinit(gpa);
        link_search.deinit(gpa);
        link_args.deinit(gpa);
        rustc_flags_raw.deinit(gpa);
        env.deinit(gpa);
        metadata.deinit(gpa);
        rerun_if_changed.deinit(gpa);
        rerun_if_env_changed.deinit(gpa);
        warnings.deinit(gpa);
        errors.deinit(gpa);
    }
    var acc = Acc{
        .gpa = gpa,
        .opts = opts,
        .cfgs = &cfgs,
        .check_cfgs = &check_cfgs,
        .link_libs = &link_libs,
        .link_search = &link_search,
        .link_args = &link_args,
        .rustc_flags_raw = &rustc_flags_raw,
        .env = &env,
        .metadata = &metadata,
        .rerun_if_changed = &rerun_if_changed,
        .rerun_if_env_changed = &rerun_if_env_changed,
        .warnings = &warnings,
        .errors = &errors,
    };
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw| {
        // Byte-wise matching with no UTF-8 decode: a non-UTF8 line can never
        // equal the ASCII `cargo:` prefixes or keys, so it is skipped — the
        // same observable outcome as cargo's `str::from_utf8 … Err(..) => continue`.
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "cargo::")) {
            const kv = try splitKeyValue(line["cargo::".len..]);
            if (!isReservedNew(kv.key)) return DirectiveError.UnknownKey;
            try dispatchNew(&acc, kv.key, kv.value);
        } else if (std.mem.startsWith(u8, line, "cargo:")) {
            const data = line["cargo:".len..];
            if (isReservedOld(data)) {
                const kv = try splitKeyValue(data);
                try dispatchOld(&acc, kv.key, kv.value);
            } else {
                // ("metadata", data): unreserved old-syntax line; split metadata KEY=VALUE lazily.
                const kv = try splitKeyValue(data);
                try metadata.append(gpa, .{ .key = kv.key, .value = kv.value });
            }
        }
        // else: skip (not a directive)
    }
    return .{
        .cfgs = try cfgs.toOwnedSlice(gpa),
        .check_cfgs = try check_cfgs.toOwnedSlice(gpa),
        .link_libs = try link_libs.toOwnedSlice(gpa),
        .link_search = try link_search.toOwnedSlice(gpa),
        .link_args = try link_args.toOwnedSlice(gpa),
        .rustc_flags_raw = try rustc_flags_raw.toOwnedSlice(gpa),
        .env = try env.toOwnedSlice(gpa),
        .metadata = try metadata.toOwnedSlice(gpa),
        .rerun_if_changed = try rerun_if_changed.toOwnedSlice(gpa),
        .rerun_if_env_changed = try rerun_if_env_changed.toOwnedSlice(gpa),
        .warnings = try warnings.toOwnedSlice(gpa),
        .errors = try errors.toOwnedSlice(gpa),
    };
}

const Acc = struct {
    gpa: std.mem.Allocator,
    opts: ParseOptions,
    cfgs: *std.ArrayList([]const u8),
    check_cfgs: *std.ArrayList([]const u8),
    link_libs: *std.ArrayList([]const u8),
    link_search: *std.ArrayList([]const u8),
    link_args: *std.ArrayList(LinkArg),
    rustc_flags_raw: *std.ArrayList([]const u8),
    env: *std.ArrayList(KeyValue),
    metadata: *std.ArrayList(KeyValue),
    rerun_if_changed: *std.ArrayList([]const u8),
    rerun_if_env_changed: *std.ArrayList([]const u8),
    warnings: *std.ArrayList([]const u8),
    errors: *std.ArrayList([]const u8),
};

fn dispatchNew(acc: *Acc, key: []const u8, value: []const u8) DirectiveError!void {
    const gpa = acc.gpa;
    if (std.mem.eql(u8, key, "rustc-flags")) {
        try acc.rustc_flags_raw.append(gpa, value);
        var it = std.mem.tokenizeAny(u8, value, " \t");
        while (it.next()) |flag| {
            if (std.mem.eql(u8, flag, "-l")) {
                const lib = it.next() orelse return DirectiveError.InvalidDirective;
                try acc.link_libs.append(gpa, lib);
            } else if (std.mem.eql(u8, flag, "-L")) {
                const path = it.next() orelse return DirectiveError.InvalidDirective;
                try acc.link_search.append(gpa, path);
            } else if (flag.len > 2 and std.mem.startsWith(u8, flag, "-l")) {
                try acc.link_libs.append(gpa, flag[2..]);
            } else if (flag.len > 2 and std.mem.startsWith(u8, flag, "-L")) {
                try acc.link_search.append(gpa, flag[2..]);
            } else {
                return DirectiveError.InvalidDirective;
            }
        }
    } else if (std.mem.eql(u8, key, "rustc-link-lib")) {
        try acc.link_libs.append(gpa, value);
    } else if (std.mem.eql(u8, key, "rustc-link-search")) {
        try acc.link_search.append(gpa, value);
    } else if (std.mem.eql(u8, key, "rustc-link-arg-cdylib") or std.mem.eql(u8, key, "rustc-cdylib-link-arg")) {
        if (!acc.opts.has_cdylib) {
            try acc.warnings.append(gpa, "rustc-link-arg-cdylib was specified but the package does not contain a cdylib target");
        }
        try acc.link_args.append(gpa, .{ .target = .cdylib, .bin_name = null, .arg = value });
    } else if (std.mem.eql(u8, key, "rustc-link-arg-bins")) {
        if (acc.opts.bin_names.len == 0) return DirectiveError.InvalidDirective;
        try acc.link_args.append(gpa, .{ .target = .bin, .bin_name = null, .arg = value });
    } else if (std.mem.eql(u8, key, "rustc-link-arg-bin")) {
        const eq = std.mem.indexOfScalar(u8, value, '=') orelse return DirectiveError.InvalidDirective;
        const bin_name = value[0..eq];
        var known = false;
        for (acc.opts.bin_names) |n| if (std.mem.eql(u8, n, bin_name)) {
            known = true;
            break;
        };
        if (!known) return DirectiveError.InvalidDirective;
        try acc.link_args.append(gpa, .{ .target = .single_bin, .bin_name = bin_name, .arg = value[eq + 1 ..] });
    } else if (std.mem.eql(u8, key, "rustc-link-arg-tests")) {
        if (!acc.opts.has_test) return DirectiveError.InvalidDirective;
        try acc.link_args.append(gpa, .{ .target = .@"test", .bin_name = null, .arg = value });
    } else if (std.mem.eql(u8, key, "rustc-link-arg-benches")) {
        if (!acc.opts.has_bench) return DirectiveError.InvalidDirective;
        try acc.link_args.append(gpa, .{ .target = .bench, .bin_name = null, .arg = value });
    } else if (std.mem.eql(u8, key, "rustc-link-arg-examples")) {
        if (!acc.opts.has_example) return DirectiveError.InvalidDirective;
        try acc.link_args.append(gpa, .{ .target = .example, .bin_name = null, .arg = value });
    } else if (std.mem.eql(u8, key, "rustc-link-arg")) {
        try acc.link_args.append(gpa, .{ .target = .all, .bin_name = null, .arg = value });
    } else if (std.mem.eql(u8, key, "rustc-cfg")) {
        try acc.cfgs.append(gpa, value);
    } else if (std.mem.eql(u8, key, "rustc-check-cfg")) {
        try acc.check_cfgs.append(gpa, value);
    } else if (std.mem.eql(u8, key, "rustc-env")) {
        const eq = std.mem.indexOfScalar(u8, value, '=') orelse return DirectiveError.InvalidDirective;
        const name = value[0..eq];
        if (std.mem.eql(u8, name, "RUSTC_BOOTSTRAP")) {
            if (acc.opts.allow_rustc_bootstrap) {
                try acc.warnings.append(gpa, value);
            } else {
                return DirectiveError.InvalidDirective;
            }
        } else {
            try acc.env.append(gpa, .{ .key = name, .value = value[eq + 1 ..] });
        }
    } else if (std.mem.eql(u8, key, "warning")) {
        try acc.warnings.append(gpa, value);
    } else if (std.mem.eql(u8, key, "error")) {
        try acc.errors.append(gpa, value);
    } else if (std.mem.eql(u8, key, "rerun-if-changed")) {
        try acc.rerun_if_changed.append(gpa, value);
    } else if (std.mem.eql(u8, key, "rerun-if-env-changed")) {
        try acc.rerun_if_env_changed.append(gpa, value);
    } else if (std.mem.eql(u8, key, "metadata")) {
        const eq = std.mem.indexOfScalar(u8, value, '=') orelse return DirectiveError.InvalidDirective;
        try acc.metadata.append(gpa, .{ .key = value[0..eq], .value = value[eq + 1 ..] });
    } else {
        return DirectiveError.UnknownKey;
    }
}

fn dispatchOld(acc: *Acc, key: []const u8, value: []const u8) DirectiveError!void {
    // Old syntax reaches here only for reserved keys, a subset of the new arms
    // (`error`/`metadata` are not in RESERVED_PREFIXES, so they never arrive).
    // `warning` appends to `warnings`, exactly like the new arm.
    return dispatchNew(acc, key, value);
}

/// Reads a script-protocol fixture relative to the repo root (tests run with
/// cwd = repo root; the plan's `@embedFile("../../testdata/…")` spelling
/// escapes the module package path, so runtime reads match the M1
/// manifest-test convention instead).
fn readFixture(gpa: std.mem.Allocator, rel: []const u8) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(io, rel, gpa, .limited(1 << 20));
}

test "directive parser handles mixed syntaxes" {
    const text = try readFixture(std.testing.allocator, "testdata/cargo/script-protocol/basic.txt");
    defer std.testing.allocator.free(text);
    var out = try parseBuildOutput(std.testing.allocator, text, .{});
    defer out.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), out.cfgs.len);
    try std.testing.expectEqualStrings("has_build_script", out.cfgs[0]);
    try std.testing.expectEqual(@as(usize, 1), out.link_libs.len);
    try std.testing.expectEqualStrings("foo", out.link_libs[0]);
    try std.testing.expectEqual(@as(usize, 1), out.metadata.len);
    try std.testing.expectEqualStrings("mykey", out.metadata[0].key);
    try std.testing.expectEqualStrings("myvalue", out.metadata[0].value);
    try std.testing.expectEqual(@as(usize, 1), out.rerun_if_changed.len);
    try std.testing.expectEqualStrings("build.rs", out.rerun_if_changed[0]);
    try std.testing.expectEqual(@as(usize, 1), out.warnings.len);
}

test "directive parser rejects unknown new keys and malformed lines" {
    try std.testing.expectError(DirectiveError.UnknownKey, parseBuildOutput(std.testing.allocator, "cargo::frobnicate=1\n", .{}));
    try std.testing.expectError(DirectiveError.InvalidDirective, parseBuildOutput(std.testing.allocator, "cargo::rustc-cfg\n", .{}));
    try std.testing.expectError(DirectiveError.InvalidDirective, parseBuildOutput(std.testing.allocator, "cargo::rustc-env=NOEQUALS\n", .{}));
}

test "directive parser treats cargo:error as metadata" {
    var out = try parseBuildOutput(std.testing.allocator, "cargo:error=boom\n", .{});
    defer out.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), out.errors.len);
    try std.testing.expectEqual(@as(usize, 1), out.metadata.len);
    try std.testing.expectEqualStrings("error", out.metadata[0].key);
}

test "directive parser expands rustc-flags -l/-L and rejects other flags" {
    var out = try parseBuildOutput(std.testing.allocator, "cargo::rustc-flags=-l foo -L /tmp/x\n", .{});
    defer out.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("foo", out.link_libs[0]);
    try std.testing.expectEqualStrings("/tmp/x", out.link_search[0]);
    try std.testing.expectEqual(@as(usize, 1), out.rustc_flags_raw.len);
    try std.testing.expectError(DirectiveError.InvalidDirective, parseBuildOutput(std.testing.allocator, "cargo::rustc-flags=-C opt-level=2\n", .{}));
    try std.testing.expectError(DirectiveError.InvalidDirective, parseBuildOutput(std.testing.allocator, "cargo::rustc-flags=-l\n", .{}));
}

test "directive parser gates RUSTC_BOOTSTRAP on the allow flag" {
    try std.testing.expectError(DirectiveError.InvalidDirective, parseBuildOutput(std.testing.allocator, "cargo::rustc-env=RUSTC_BOOTSTRAP=1\n", .{}));
    var out = try parseBuildOutput(std.testing.allocator, "cargo::rustc-env=RUSTC_BOOTSTRAP=1\n", .{ .allow_rustc_bootstrap = true });
    defer out.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), out.env.len);
    try std.testing.expectEqual(@as(usize, 1), out.warnings.len);
}

test "directive parser bails on link-arg targets that do not exist" {
    try std.testing.expectError(DirectiveError.InvalidDirective, parseBuildOutput(std.testing.allocator, "cargo::rustc-link-arg-bins=--foo\n", .{}));
    const bins = [_][]const u8{"app"};
    var out = try parseBuildOutput(std.testing.allocator, "cargo::rustc-link-arg-bin=app=--foo\n", .{ .bin_names = &bins });
    defer out.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), out.link_args.len);
    try std.testing.expectEqualStrings("app", out.link_args[0].bin_name.?);
    try std.testing.expectError(DirectiveError.InvalidDirective, parseBuildOutput(std.testing.allocator, "cargo::rustc-link-arg-bin=other=--foo\n", .{ .bin_names = &bins }));
    var warn_out = try parseBuildOutput(std.testing.allocator, "cargo::rustc-link-arg-cdylib=--foo\n", .{});
    defer warn_out.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), warn_out.warnings.len);
    try std.testing.expectEqual(@as(usize, 1), warn_out.link_args.len);
}

// =====================================================================
// Task 2: `envify` + `links` metadata propagation
// =====================================================================

pub const PropagationError = std.mem.Allocator.Error; // no fallible cases: links==null still emits CARGO_DEP_ (see below)

pub fn envify(gpa: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error![]u8 {
    // cargo mod.rs:2035: uppercase, then map only '-' to '_'. '.' and all
    // other bytes pass through unchanged (so "native-foo.bar2" -> "NATIVE_FOO.BAR2").
    const out = try gpa.alloc(u8, name.len);
    for (name, out) |c, *o| {
        if (c >= 'a' and c <= 'z') {
            o.* = c - ('a' - 'A');
        } else if (c == '-') {
            o.* = '_';
        } else {
            o.* = c;
        }
    }
    return out;
}

pub fn depEnvName(gpa: std.mem.Allocator, prefix: []const u8, links: []const u8, key: []const u8) std.mem.Allocator.Error![]u8 {
    const e_links = try envify(gpa, links);
    defer gpa.free(e_links);
    const e_key = try envify(gpa, key);
    defer gpa.free(e_key);
    return std.fmt.allocPrint(gpa, "{s}_{s}_{s}", .{ prefix, e_links, e_key });
}

pub fn propagateMetadata(gpa: std.mem.Allocator, links: ?[]const u8, package_name: []const u8, metadata: []const KeyValue) PropagationError![]KeyValue {
    // cargo custom_build.rs:560-577: DEP_<links>_<key> is inside
    // `if let Some(ref links)`; CARGO_DEP_<name>_<key> is OUTSIDE it, so
    // links == null still emits the CARGO_DEP_ forms.
    var vars: std.ArrayList(KeyValue) = .empty;
    errdefer {
        for (vars.items) |v| gpa.free(v.key);
        vars.deinit(gpa);
    }
    for (metadata) |m| {
        if (links) |l| {
            const dep_name = try depEnvName(gpa, "DEP", l, m.key);
            errdefer gpa.free(dep_name);
            try vars.append(gpa, .{ .key = dep_name, .value = m.value });
        }
        const cargo_name = try depEnvName(gpa, "CARGO_DEP", package_name, m.key);
        errdefer gpa.free(cargo_name);
        try vars.append(gpa, .{ .key = cargo_name, .value = m.value });
    }
    return vars.toOwnedSlice(gpa);
}

test "dep metadata propagates to DEP_ and CARGO_DEP_ env names" {
    const text = try readFixture(std.testing.allocator, "testdata/cargo/script-protocol/links.txt");
    defer std.testing.allocator.free(text);
    var out = try parseBuildOutput(std.testing.allocator, text, .{});
    defer out.deinit(std.testing.allocator);
    const vars = try propagateMetadata(std.testing.allocator, "native-foo", "foo-sys", out.metadata);
    defer {
        for (vars) |v| std.testing.allocator.free(v.key);
        std.testing.allocator.free(vars);
    }
    // links="native-foo" -> ENVIFY -> "NATIVE_FOO"; key "root" stays "ROOT".
    try std.testing.expectEqual(@as(usize, 4), vars.len);
    try std.testing.expectEqualStrings("DEP_NATIVE_FOO_ROOT", vars[0].key);
    try std.testing.expectEqualStrings("CARGO_DEP_FOO_SYS_ROOT", vars[1].key);
}

test "envify uppercases and maps only '-' to '_'" {
    const e = try envify(std.testing.allocator, "native-foo.bar2");
    defer std.testing.allocator.free(e);
    try std.testing.expectEqualStrings("NATIVE_FOO.BAR2", e);
}

test "propagate without links emits only CARGO_DEP_" {
    const md = [_]KeyValue{.{ .key = "root", .value = "x" }};
    const vars = try propagateMetadata(std.testing.allocator, null, "foo-sys", &md);
    defer {
        for (vars) |v| std.testing.allocator.free(v.key);
        std.testing.allocator.free(vars);
    }
    try std.testing.expectEqual(@as(usize, 1), vars.len);
    try std.testing.expectEqualStrings("CARGO_DEP_FOO_SYS_ROOT", vars[0].key);
}

// =====================================================================
// Task 3: rerun fingerprint (`shouldRerun`)
// =====================================================================

pub const RerunError = error{ OldStyleFallback } || std.mem.Allocator.Error || Io.Dir.StatFileError;

pub const RerunDecision = enum { rerun, fresh };

pub const RerunInputs = struct {
    /// Previous run's rerun-if lists (parsed from the stored BuildOutput; null = never ran).
    prev_changed: ?[]const []const u8,
    prev_env_changed: ?[]const []const u8,
    /// mtime anchor: the stored "output" time of the previous run, as i96 nanos.
    /// Absent (null) on first run -> rerun.
    prev_output_ns: ?i96,
    /// Current values of the env names in prev_env_changed, same order; null entry = currently unset.
    current_env: []const ?[]const u8,
    /// Stored values of those env names from the previous run, same order; null entry = was unset.
    prev_env_values: []const ?[]const u8,
};

pub fn mtimeNsOf(io: Io, dir: Io.Dir, rel_path: []const u8) Io.Dir.StatFileError!?i96 {
    const st = dir.statFile(io, rel_path, .{}) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    return st.mtime.nanoseconds;
}

pub fn shouldRerun(gpa: std.mem.Allocator, io: Io, pkg_dir_abs: []const u8, inputs: RerunInputs) RerunError!RerunDecision {
    _ = gpa;
    const anchor = inputs.prev_output_ns orelse return .rerun;
    const changed = inputs.prev_changed orelse return .rerun;
    const env_names = inputs.prev_env_changed orelse return .rerun;
    if (changed.len == 0 and env_names.len == 0) return RerunError.OldStyleFallback;
    // Caller passes the CURRENT script lists separately? No — by contract the
    // caller compares current lists to prev lists BEFORE calling (Task 8:
    // watch-set mismatch => rerun without calling). Documented at the call site.
    // No `Io.Dir.openPath` (does not exist in 0.16): the package root opens via
    // `Io.Dir.cwd().createDirPathOpen` (repo-verified absolute-dir shape,
    // `fetch.zig:247`, `cli.zig:433`); unreadable root => rerun, never crash.
    var pkg_dir = Io.Dir.cwd().createDirPathOpen(io, pkg_dir_abs, .{}) catch return .rerun;
    defer pkg_dir.close(io);
    for (changed) |rel| {
        // Absolute watched paths stat through the cwd handle with the absolute
        // path verbatim (same shape as `workspace.zig` `existsFile`, which
        // calls `Io.Dir.cwd().statFile(io, path, .{})` on absolute paths);
        // relative paths stat through the package-root handle.
        const ns: ?i96 = if (std.fs.path.isAbsolute(rel))
            try mtimeNsOf(io, Io.Dir.cwd(), rel)
        else
            try mtimeNsOf(io, pkg_dir, rel);
        const file_ns = ns orelse return .rerun; // missing => dirty
        if (file_ns > anchor) return .rerun;
    }
    std.debug.assert(inputs.current_env.len == env_names.len);
    std.debug.assert(inputs.prev_env_values.len == env_names.len);
    for (env_names, inputs.current_env, inputs.prev_env_values) |_, cur, prv| {
        const same = if (cur == null and prv == null) true else if (cur == null or prv == null) false else std.mem.eql(u8, cur.?, prv.?);
        if (!same) return .rerun;
    }
    return .fresh;
}

test "rerun fires on changed file and changed env, quiet otherwise" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "watched.txt", .data = "v1" });
    const pkg_abs = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(pkg_abs);
    const st = try tmp.dir.statFile(io, "watched.txt", .{});
    const anchor: i96 = st.mtime.nanoseconds - 1; // file is newer than anchor

    const changed = [_][]const u8{"watched.txt"};
    const env_names = [_][]const u8{"MY_ENV"};
    const cur = [_]?[]const u8{"1"};
    const prev = [_]?[]const u8{"1"};
    const d1 = try shouldRerun(std.testing.allocator, io, pkg_abs, .{
        .prev_changed = &changed,
        .prev_env_changed = &env_names,
        .prev_output_ns = anchor,
        .current_env = &cur,
        .prev_env_values = &prev,
    });
    try std.testing.expect(d1 == .rerun);

    const st2 = try tmp.dir.statFile(io, "watched.txt", .{});
    const fresh_anchor: i96 = st2.mtime.nanoseconds + 1; // anchor newer than file
    const d2 = try shouldRerun(std.testing.allocator, io, pkg_abs, .{
        .prev_changed = &changed,
        .prev_env_changed = &env_names,
        .prev_output_ns = fresh_anchor,
        .current_env = &cur,
        .prev_env_values = &prev,
    });
    try std.testing.expect(d2 == .fresh);
}

test "rerun old-style falls back loudly" {
    const empty = [_][]const u8{};
    const novars = [_]?[]const u8{};
    try std.testing.expectError(RerunError.OldStyleFallback, shouldRerun(
        std.testing.allocator,
        std.Io.Threaded.global_single_threaded.io(),
        "/tmp",
        .{ .prev_changed = &empty, .prev_env_changed = &empty, .prev_output_ns = 0, .current_env = &novars, .prev_env_values = &novars },
    ));
}

test "rerun fires on missing watched file and on env change" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const changed = [_][]const u8{"does-not-exist.txt"};
    const env_names = [_][]const u8{"MY_ENV"};
    const cur = [_]?[]const u8{"2"};
    const prev = [_]?[]const u8{"1"};
    const d = try shouldRerun(std.testing.allocator, io, "/tmp", .{
        .prev_changed = &changed,
        .prev_env_changed = &env_names,
        .prev_output_ns = 0,
        .current_env = &cur,
        .prev_env_values = &prev,
    });
    try std.testing.expect(d == .rerun);
}

// =====================================================================
// Task 4: action key + store ingest + OUT_DIR materialization
// =====================================================================

pub const KeyError = error{StoreFull} || std.mem.Allocator.Error;

pub const ScriptFingerprint = struct {
    script_bin_digest: Digest, // content digest of the COMPILED script binary (Task 5 compiles first)
    package_name: []const u8,
    package_version: []const u8,
    links: ?[]const u8, // [package] links key or null
    features: []const []const u8, // sorted enabled features for this unit
    profile_name: []const u8, // "dev" | "release" | custom
    opt_level: []const u8, // "0".."3"/"s"/"z" (cargo profile field, in the key)
    debug_assertions: bool,
    target_triple: []const u8, // --target or host triple
    host_triple: []const u8,
    toolchain_id: []const u8, // "rustc <version> <sysroot-digest8>" (storage-v2 §11.3 shape)
    watched_env_values: []const ?[]const u8, // CURRENT values of rerun-if-env-changed names, same order as names
    watched_env_names: []const []const u8,
    rustflags_relevant: []const u8, // CARGO_ENCODED_RUSTFLAGS content (0x1f-joined, cargo build_work line ~463)
};

/// Serializes the fingerprint in FIXED order with u64le length prefixes
/// (0xFF marker for null links; 0x00/0x01 tag byte for unset/set env
/// values) and returns `store_mod.hashBytes(buf)` (BLAKE3).
/// IN the key: script binary digest, package name+version, links, sorted
/// features, profile + opt-level + debug-assertions, target + host
/// triples, toolchain id, CURRENT watched-env values.
/// NOT in the key: rerun-if-changed PATHS/mtimes (cargo never hashes
/// mtimes into fingerprints), absolute dir paths, OUT_DIR itself.
pub fn scriptActionKey(gpa: std.mem.Allocator, fp: ScriptFingerprint) KeyError!Digest {
    // NOTE (plan deviation, 0.16 fix): the plan spells this with
    // `buf.writer(gpa)`; `ArrayList.writer` does not exist in 0.16, so the
    // buffer is built with append/appendSlice directly (same bytes).
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try writeField(&buf, gpa, fp.script_bin_digest.bytes[0..]);
    try writeField(&buf, gpa, fp.package_name);
    try writeField(&buf, gpa, fp.package_version);
    if (fp.links) |l| {
        try buf.append(gpa, 0x00);
        try writeField(&buf, gpa, l);
    } else {
        try buf.append(gpa, 0xFF); // null-links marker
    }
    for (fp.features, 0..) |f, i| {
        if (i > 0) std.debug.assert(std.mem.order(u8, fp.features[i - 1], f) != .gt); // caller pre-sorts
        try writeField(&buf, gpa, f);
    }
    try buf.append(gpa, 0x00); // features terminator
    try writeField(&buf, gpa, fp.profile_name);
    try writeField(&buf, gpa, fp.opt_level);
    try buf.append(gpa, if (fp.debug_assertions) 0x01 else 0x00);
    try writeField(&buf, gpa, fp.target_triple);
    try writeField(&buf, gpa, fp.host_triple);
    try writeField(&buf, gpa, fp.toolchain_id);
    std.debug.assert(fp.watched_env_names.len == fp.watched_env_values.len);
    for (fp.watched_env_names, fp.watched_env_values) |n, v| {
        try writeField(&buf, gpa, n);
        if (v) |val| {
            try buf.append(gpa, 0x01);
            try writeField(&buf, gpa, val);
        } else {
            try buf.append(gpa, 0x00); // was-unset marker (distinct from empty)
        }
    }
    try writeField(&buf, gpa, fp.rustflags_relevant);
    return store_mod.hashBytes(buf.items);
}

fn writeField(list: *std.ArrayList(u8), gpa: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error!void {
    var len: [8]u8 = undefined;
    std.mem.writeInt(u64, &len, bytes.len, .little);
    try list.appendSlice(gpa, &len);
    try list.appendSlice(gpa, bytes);
}

/// Generating-machine OUT_DIR rewrite at READ time (cargo
/// `value.replace(script_out_dir_when_generated, script_out_dir)` in
/// `BuildOutput::parse`): bytes are stored verbatim, the replace applies
/// when the consuming OUT_DIR differs from the generating one.
pub fn rewriteOutDir(gpa: std.mem.Allocator, bytes: []const u8, from: []const u8, to: []const u8) std.mem.Allocator.Error![]u8 {
    if (from.len == 0) return gpa.dupe(u8, bytes);
    return std.mem.replaceOwned(u8, gpa, bytes, from, to);
}

test "script action key binds env values and ignores paths" {
    const d_script = store_mod.hashBytes("fake-binary");
    const names = [_][]const u8{"MY_ENV"};
    const v1 = [_]?[]const u8{"1"};
    const v2 = [_]?[]const u8{"2"};
    const base = ScriptFingerprint{
        .script_bin_digest = d_script,
        .package_name = "p",
        .package_version = "0.1.0",
        .links = null,
        .features = &.{},
        .profile_name = "dev",
        .opt_level = "0",
        .debug_assertions = true,
        .target_triple = "aarch64-apple-darwin",
        .host_triple = "aarch64-apple-darwin",
        .toolchain_id = "rustc 1.99.0-nightly abc12345",
        .watched_env_values = &v1,
        .watched_env_names = &names,
        .rustflags_relevant = "",
    };
    var changed = base;
    changed.watched_env_values = &v2;
    const k1 = try scriptActionKey(std.testing.allocator, base);
    const k2 = try scriptActionKey(std.testing.allocator, changed);
    // NOTE (plan deviation, 0.16 fix): the plan spells this
    // `timing_safe.eql(u8, &k1.bytes, &k2.bytes)`; the real 0.16 shape is
    // `eql(T, a, b)` with T = [32]u8 by value.
    try std.testing.expect(!std.crypto.timing_safe.eql([32]u8, k1.bytes, k2.bytes));
    const k1b = try scriptActionKey(std.testing.allocator, base);
    try std.testing.expect(std.crypto.timing_safe.eql([32]u8, k1.bytes, k1b.bytes));
}

test "rewriteOutDir swaps the generating prefix" {
    const got = try rewriteOutDir(std.testing.allocator, "out=/gen/out/x", "/gen/out", "/now/out");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("out=/now/out/x", got);
}

/// NOTE (plan deviation): the plan unions only `Store.PutError` /
/// `Store.GetManifestError` here, but `materializeOutDir` (same return
/// type) must surface `store.materialize` failures and `tagObject` index
/// errors, so the real `Store.MaterializeError` and `store_mod.TagError`
/// sets ride along. Local-FS handling failures (open/iterate/stat/read/
/// create/delete around OUT_DIR) map to `error.Io` (OOM preserved); store
/// bytes/tag/manifest errors propagate verbatim.
pub const IngestError = error{ StoreFull, TagMismatch, TagLimit, UnknownTagKey, Io } ||
    std.mem.Allocator.Error || Store.PutError || Store.GetManifestError || Store.MaterializeError || store_mod.TagError;

fn mapFsErr(err: anyerror) IngestError {
    return switch (err) {
        error.OutOfMemory => IngestError.OutOfMemory,
        else => IngestError.Io,
    };
}

/// Ingests every regular file directly under `out_dir_abs` (top level
/// only — cargo's contract is a flat OUT_DIR; a subdirectory or any
/// non-file entry is `IngestError.Io`, loud) as `.build_script_out`
/// (storage-v2 §5.2, demotable), then ONE `.build_script_out` manifest
/// (per-file `mode = 0o444`), then `store.tagObject` with the caller's
/// full §11.3 tag set. Manifest outputs are sorted by path so re-ingesting
/// identical bytes is reservation-free (§10.5 idempotency).
pub fn ingestOutputs(
    gpa: std.mem.Allocator,
    io: Io,
    store: *Store,
    out_dir_abs: []const u8,
    output: *const BuildOutput,
    tags: []const Tag,
) IngestError!Digest {
    _ = output;
    var dir = Io.Dir.openDirAbsolute(io, out_dir_abs, .{ .iterate = true }) catch |e| return mapFsErr(e);
    defer dir.close(io);
    var collected: std.ArrayList(Store.ManifestOutput) = .empty;
    errdefer {
        for (collected.items) |o| gpa.free(o.path);
        collected.deinit(gpa);
    }
    var it = dir.iterate();
    while (it.next(io) catch |e| return mapFsErr(e)) |entry| {
        if (entry.kind != .file) {
            // Flat OUT_DIR contract: subdirectories and other non-file
            // entries are loud — the error set carries no payload, so the
            // offending path is named via the log alongside the Io error.
            std.log.err("ingestOutputs: non-file entry in OUT_DIR {s}: {s}", .{ out_dir_abs, entry.name });
            return IngestError.Io;
        }
        const bytes = dir.readFileAlloc(io, entry.name, gpa, .unlimited) catch |e| return mapFsErr(e);
        defer gpa.free(bytes);
        const digest = try store.putBytes(io, bytes, .build_script_out);
        const path = gpa.dupe(u8, entry.name) catch return IngestError.OutOfMemory;
        // No errdefer on `path` here: once appended, the top-of-function
        // errdefer owns every collected path, and a second freer would
        // double-free on any later ingest error (putManifest/tagObject).
        // Free only when the append itself fails.
        collected.append(gpa, .{
            .path = path,
            .digest = digest,
            .size = @as(u64, @intCast(bytes.len)),
            .mode = 0o444,
        }) catch {
            gpa.free(path);
            return IngestError.OutOfMemory;
        };
    }
    std.mem.sort(Store.ManifestOutput, collected.items, {}, struct {
        fn lessThan(_: void, a: Store.ManifestOutput, b: Store.ManifestOutput) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.lessThan);
    const man = try store.putManifest(io, .{ .kind = .build_script_out, .outputs = collected.items });
    // Tag BEFORE freeing: every fallible call must precede the success-path
    // cleanup, otherwise a tagObject failure unwinds through the errdefer
    // and double-frees the collected paths (StoreFull on tagging is a
    // routine production event under tight budgets, not just a test stage).
    try store.tagObject(io, man, tags);
    for (collected.items) |o| gpa.free(o.path);
    collected.deinit(gpa);
    return man;
}

/// Recreates `out_dir_abs` (delete, because the store manifest is the
/// backup — cargo moves old dirs aside, rime deletes), then materializes
/// each manifest entry read-only (`0o444`) via clone-or-copy, never
/// hardlink. On a cache HIT the runner materializes instead of executing.
pub fn materializeOutDir(
    gpa: std.mem.Allocator,
    io: Io,
    store: *Store,
    manifest_digest: Digest,
    out_dir_abs: []const u8,
) IngestError!void {
    Io.Dir.cwd().deleteTree(io, out_dir_abs) catch |e| return mapFsErr(e);
    var dir = Io.Dir.cwd().createDirPathOpen(io, out_dir_abs, .{}) catch |e| return mapFsErr(e);
    dir.close(io);
    const man = try store.getManifest(io, gpa, manifest_digest);
    defer man.deinit(gpa);
    for (man.outputs) |o| {
        const dest = std.fs.path.join(gpa, &.{ out_dir_abs, o.path }) catch return IngestError.OutOfMemory;
        defer gpa.free(dest);
        _ = try store.materialize(io, o.digest, dest, 0o444);
    }
}

test "ingest stores OUT_DIR files and materializes them back" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var ts = store_mod.test_support.openTestStore(io, .{});
    defer ts.deinit(io);
    var out_tmp = std.testing.tmpDir(.{});
    defer out_tmp.cleanup();
    try out_tmp.dir.writeFile(io, .{ .sub_path = "bindings.rs", .data = "pub const X: u32 = 1;\n" });
    const out_abs = try out_tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(out_abs);

    var parsed = try parseBuildOutput(gpa, "cargo::rerun-if-changed=build.rs\n", .{});
    defer parsed.deinit(gpa);
    const reserved_before = try ts.store.reservedBytes();
    const tags = [_]Tag{
        .{ .key = "crate", .value = "full-manifest" },
        .{ .key = "crate_version", .value = "0.1.0" },
        .{ .key = "profile", .value = "dev" },
        .{ .key = "action", .value = "build-script" },
    };
    const man = try ingestOutputs(gpa, io, &ts.store, out_abs, &parsed, &tags);
    // §10.5 idempotency: re-ingesting identical bytes is reservation-free.
    _ = try ingestOutputs(gpa, io, &ts.store, out_abs, &parsed, &tags);
    try std.testing.expectEqual(reserved_before, try ts.store.reservedBytes());

    var dst_tmp = std.testing.tmpDir(.{});
    defer dst_tmp.cleanup();
    const dst_abs = try dst_tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dst_abs);
    const dst_out = try std.fs.path.join(gpa, &.{ dst_abs, "out" });
    defer gpa.free(dst_out);
    try materializeOutDir(gpa, io, &ts.store, man, dst_out);
    const got = try dst_tmp.dir.readFileAlloc(io, "out/bindings.rs", gpa, .unlimited);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("pub const X: u32 = 1;\n", got);
    // Store object is read-only; view copy is read-only too (generated code is an input).
    const vst = try dst_tmp.dir.statFile(io, "out/bindings.rs", .{});
    try std.testing.expectEqual(@as(u32, 0o444), vst.permissions.toMode() & 0o777);
}

// =====================================================================
// Task 5: compile-then-run + sandbox
// =====================================================================

pub const RunError = error{ CompileFailed, ScriptFailed, SandboxDenied, StoreFull, Io } ||
    std.mem.Allocator.Error || std.process.SpawnError || IngestError || DirectiveError;

pub const SandboxKind = enum { macos_seatbelt, linux_namespaces, none_loud };

/// macOS: seatbelt is REQUIRED (always available there). Linux: `unshare`
/// present AND functional (`unshare --help` exits 0 — no namespaces taken
/// by the probe). Otherwise loud-unsandboxed. Other OSes: compile error
/// (repo Windows posture: storage-v2 §3 non-goal, macOS + Linux only).
pub fn probeSandbox(io: Io) SandboxKind {
    if (comptime builtin.os.tag == .macos) return .macos_seatbelt;
    if (comptime builtin.os.tag != .linux) @compileError("build scripts sandbox only on macos/linux");
    // Linux: unshare present AND functional? Probe with `unshare --help` (no namespaces taken).
    var probe = std.process.spawn(io, .{
        .argv = &.{ "unshare", "--help" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return .none_loud;
    defer probe.kill(io);
    const st = probe.wait(io) catch return .none_loud;
    return if (st == .exited and st.exited == 0) .linux_namespaces else .none_loud;
}

pub fn renderSandboxWarning(stderr: *Io.Writer, reason: []const u8) Io.Writer.Error!void {
    try stderr.writeAll("warning: rime: build-script sandbox unavailable (");
    try stderr.writeAll(reason);
    try stderr.writeAll("); running unsandboxed\n");
}

/// Clones the caller-supplied parent map (production passes
/// `init.environ_map`; tests pass a hand-built map — no process-env getter
/// exists in 0.16), applies cargo's removals (`RUSTFLAGS`,
/// `RUSTC_WRAPPER`, `RUSTC_WORKSPACE_WRAPPER`), then layers `extra` on top.
/// Returned map owns duped keys+values (caller deinits).
pub fn scriptEnv(
    gpa: std.mem.Allocator,
    base: *const std.process.Environ.Map,
    extra: []const KeyValue,
) std.mem.Allocator.Error!std.process.Environ.Map {
    var m = try base.clone(gpa);
    errdefer m.deinit();
    _ = m.orderedRemove("RUSTFLAGS");
    _ = m.orderedRemove("RUSTC_WRAPPER");
    _ = m.orderedRemove("RUSTC_WORKSPACE_WRAPPER");
    for (extra) |kv| try m.put(kv.key, kv.value);
    return m;
}

/// Deterministic compiled-script path so Task 8 and M4 agree on where the
/// driver-seam binary lives: `<spool>/scripts/<package>-<meta8>/build-script`.
pub fn scriptBinPath(
    gpa: std.mem.Allocator,
    spool_abs: []const u8,
    package_name: []const u8,
    unit_meta_hash: []const u8,
) std.mem.Allocator.Error![]u8 {
    std.debug.assert(unit_meta_hash.len >= 8); // caller passes a hex digest
    const mid = try std.fmt.allocPrint(gpa, "{s}-{s}", .{ package_name, unit_meta_hash[0..8] });
    defer gpa.free(mid);
    return std.fs.path.join(gpa, &.{ spool_abs, "scripts", mid, "build-script" });
}

pub const RunConfig = struct {
    base_env: *const std.process.Environ.Map, // parent env (production: init.environ_map; tests: hand-built map). Supplies PATH and every var cargo inherits.
    script_bin_abs: []const u8, // compiled binary (Task 8 compiles via the driver seam; tests pass a stub)
    pkg_dir_abs: []const u8,
    out_dir_abs: []const u8, // exists before spawn (created under spool reservation)
    out_dir_when_generated: ?[]const u8, // previous-run OUT_DIR for the read-time rewrite (null = no rewrite)
    manifest_dir: []const u8, // CARGO_MANIFEST_DIR
    manifest_path: []const u8, // CARGO_MANIFEST_PATH
    links: ?[]const u8, // CARGO_MANIFEST_LINKS when non-null
    features: []const []const u8, // CARGO_FEATURE_<envify> = 1 each
    target_triple: []const u8, // TARGET
    host_triple: []const u8, // HOST
    profile_name: []const u8, // PROFILE ("release"/"debug" mapped form)
    opt_level: []const u8, // OPT_LEVEL
    debug_assertions: bool, // DEBUG ("true"/"false")
    rustc_abs: []const u8, // RUSTC
    encoded_rustflags: []const u8, // CARGO_ENCODED_RUSTFLAGS (0x1f-joined)
    dep_env: []const KeyValue, // Task-2 DEP_ vars from already-run deps
    cfg_env: []const KeyValue, // pre-rendered CARGO_CFG_… vars from the driver seam (Task 6)
    nightly_features_allowed: bool = false, // toolchain-channel half of the Task-1 RUSTC_BOOTSTRAP gate (cargo custom_build.rs:1074-1095); ORed with the parent-env allowlist below
    stderr: *Io.Writer, // loud-sandbox warnings land here
};

/// Deep-copies a borrow-based `BuildOutput` into fully gpa-owned strings.
///
/// `parseBuildOutput` results borrow their input buffer, but `runScript`
/// must return an owned value (the capture buffer cannot outlive the
/// call). Every string below is duped; free with `deinitRunOutput` (NOT
/// the Task-1 `deinit`, which frees outer slices only and would leak).
/// NOTE (plan deviation): the plan's `runScript` test uses
/// `deinit(gpa)`; that leaks under `std.testing.allocator`, so this task's
/// tests (and Task 8's `runUnit`) use `deinitRunOutput`.
fn dupeRunOutput(gpa: std.mem.Allocator, src: *const BuildOutput) std.mem.Allocator.Error!BuildOutput {
    var out = BuildOutput{
        .cfgs = &.{}, .check_cfgs = &.{}, .link_libs = &.{}, .link_search = &.{},
        .link_args = &.{}, .rustc_flags_raw = &.{}, .env = &.{}, .metadata = &.{},
        .rerun_if_changed = &.{}, .rerun_if_env_changed = &.{}, .warnings = &.{}, .errors = &.{},
    };
    errdefer deinitRunOutput(gpa, &out);
    out.cfgs = try dupeStrings(gpa, src.cfgs);
    out.check_cfgs = try dupeStrings(gpa, src.check_cfgs);
    out.link_libs = try dupeStrings(gpa, src.link_libs);
    out.link_search = try dupeStrings(gpa, src.link_search);
    out.rustc_flags_raw = try dupeStrings(gpa, src.rustc_flags_raw);
    out.rerun_if_changed = try dupeStrings(gpa, src.rerun_if_changed);
    out.rerun_if_env_changed = try dupeStrings(gpa, src.rerun_if_env_changed);
    out.warnings = try dupeStrings(gpa, src.warnings);
    out.errors = try dupeStrings(gpa, src.errors);
    out.env = try dupePairs(gpa, src.env);
    out.metadata = try dupePairs(gpa, src.metadata);
    {
        var args: std.ArrayList(LinkArg) = .empty;
        errdefer {
            for (args.items) |a| {
                gpa.free(a.arg);
                if (a.bin_name) |b| gpa.free(b);
            }
            args.deinit(gpa);
        }
        for (src.link_args) |a| {
            const arg = try gpa.dupe(u8, a.arg);
            errdefer gpa.free(arg);
            const bin: ?[]const u8 = if (a.bin_name) |b| try gpa.dupe(u8, b) else null;
            try args.append(gpa, .{ .target = a.target, .bin_name = bin, .arg = arg });
        }
        out.link_args = try args.toOwnedSlice(gpa);
    }
    return out;
}

fn dupeStrings(gpa: std.mem.Allocator, in: []const []const u8) std.mem.Allocator.Error![]const []const u8 {
    var arr = try gpa.alloc([]const u8, in.len);
    var done: usize = 0;
    errdefer {
        for (arr[0..done]) |s| gpa.free(s);
        gpa.free(arr);
    }
    for (in) |s| {
        arr[done] = try gpa.dupe(u8, s);
        done += 1;
    }
    return arr;
}

fn dupePairs(gpa: std.mem.Allocator, in: []const KeyValue) std.mem.Allocator.Error![]KeyValue {
    var arr = try gpa.alloc(KeyValue, in.len);
    var done: usize = 0;
    errdefer {
        for (arr[0..done]) |kv| {
            gpa.free(kv.key);
            gpa.free(kv.value);
        }
        gpa.free(arr);
    }
    for (in) |kv| {
        const k = try gpa.dupe(u8, kv.key);
        errdefer gpa.free(k);
        const v = try gpa.dupe(u8, kv.value);
        arr[done] = .{ .key = k, .value = v };
        done += 1;
    }
    return arr;
}

/// Frees a `runScript`-owned `BuildOutput` (every string, then the outer
/// slices via the Task-1 `deinit`).
pub fn deinitRunOutput(gpa: std.mem.Allocator, out: *const BuildOutput) void {
    for (out.cfgs) |s| gpa.free(s);
    for (out.check_cfgs) |s| gpa.free(s);
    for (out.link_libs) |s| gpa.free(s);
    for (out.link_search) |s| gpa.free(s);
    for (out.rustc_flags_raw) |s| gpa.free(s);
    for (out.rerun_if_changed) |s| gpa.free(s);
    for (out.rerun_if_env_changed) |s| gpa.free(s);
    for (out.warnings) |s| gpa.free(s);
    for (out.errors) |s| gpa.free(s);
    for (out.env) |kv| {
        gpa.free(kv.key);
        gpa.free(kv.value);
    }
    for (out.metadata) |kv| {
        gpa.free(kv.key);
        gpa.free(kv.value);
    }
    for (out.link_args) |a| {
        gpa.free(a.arg);
        if (a.bin_name) |b| gpa.free(b);
    }
    out.deinit(gpa);
}

/// Seatbelt profile: deny-by-default; no network; `file-read*` everywhere;
/// `file-write*` only under the OUT_DIR, its parent build dir, and TMPDIR;
/// `process-exec` allowed (scripts exec `cc` et al).
fn seatbeltProfile(gpa: std.mem.Allocator, out_dir_abs: []const u8, tmpdir: []const u8) std.mem.Allocator.Error![]u8 {
    const parent = std.fs.path.dirname(out_dir_abs) orelse out_dir_abs;
    return std.fmt.allocPrint(gpa,
        \\(version 1)
        \\(deny default)
        \\(deny network*)
        \\(allow process-exec)
        \\(allow file-read*)
        \\(allow file-write* (subpath "{s}") (subpath "{s}") (subpath "{s}"))
        \\(allow sysctl-read)
        \\(allow mach-lookup)
        \\(allow signal)
        \\
    , .{ out_dir_abs, parent, tmpdir });
}

/// Runs one compiled build script: creates OUT_DIR (cargo
/// `paths::create_dir_all`), captures the mtime anchor BEFORE spawn
/// (returned as `started_ns`), assembles cargo's exact env chain, wraps in
/// the platform sandbox, captures stdout (directive channel) while
/// streaming stderr to the build log, parses directives, ingests outputs
/// (empty tag set — Task 8 re-ingests with the full §11.3 set, same digest
/// by §10.5 idempotency), and returns the owned output + manifest.
/// Exit ≠ 0 → `ScriptFailed` with the first 2 KiB of stdout in
/// `diagnostic`/`diagnostic_len`.
pub fn runScript(
    gpa: std.mem.Allocator,
    io: Io,
    store: *Store,
    cfg: RunConfig,
    diagnostic: ?*[2048]u8,
    diagnostic_len: *usize,
) RunError!RunResult {
    diagnostic_len.* = 0;
    // OUT_DIR exists before spawn (repo-verified absolute-dir shape).
    var out_dir = Io.Dir.cwd().createDirPathOpen(io, cfg.out_dir_abs, .{}) catch return RunError.Io;
    out_dir.close(io);
    const started_ns: i96 = Io.Timestamp.now(io, .real).nanoseconds;

    var child_env = try scriptEnv(gpa, cfg.base_env, &.{});
    defer child_env.deinit();
    try child_env.put("OUT_DIR", cfg.out_dir_abs);
    try child_env.put("CARGO_MANIFEST_DIR", cfg.manifest_dir);
    try child_env.put("CARGO_MANIFEST_PATH", cfg.manifest_path);
    try child_env.put("NUM_JOBS", "1"); // M5 runs units sequentially; the jobserver is M4's
    try child_env.put("TARGET", cfg.target_triple);
    try child_env.put("DEBUG", if (cfg.debug_assertions) "true" else "false");
    try child_env.put("OPT_LEVEL", cfg.opt_level);
    try child_env.put("PROFILE", cfg.profile_name);
    try child_env.put("HOST", cfg.host_triple);
    try child_env.put("RUSTC", cfg.rustc_abs);
    // RUSTDOC: passthrough when the parent env sets it, else unset — the
    // clone already carries exactly that, so nothing to do (documented).
    if (cfg.links) |links| try child_env.put("CARGO_MANIFEST_LINKS", links);
    for (cfg.features) |feat| {
        const env_feat = try envify(gpa, feat);
        defer gpa.free(env_feat);
        const key = try std.fmt.allocPrint(gpa, "CARGO_FEATURE_{s}", .{env_feat});
        defer gpa.free(key);
        try child_env.put(key, "1");
    }
    for (cfg.cfg_env) |kv| try child_env.put(kv.key, kv.value);
    try child_env.put("CARGO_ENCODED_RUSTFLAGS", cfg.encoded_rustflags);
    for (cfg.dep_env) |kv| try child_env.put(kv.key, kv.value);

    // RUSTC_BOOTSTRAP warn-vs-bail (Task 1 gate, cargo custom_build.rs:1074-1095):
    // the toolchain-channel half arrives as cfg.nightly_features_allowed;
    // the parent-env half is cargo's `rustc_bootstrap_allows` allowlist
    // (coarse here: any set value warns instead of bailing).
    const allow_bootstrap: bool = cfg.nightly_features_allowed or cfg.base_env.get("RUSTC_BOOTSTRAP") != null;

    // Sandbox argv. Bare wrapper names resolve via the parent PATH inside
    // spawn; sandbox-exec is pre-resolved so absence is a hard SandboxDenied
    // on macOS (never silently unsandboxed).
    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(gpa);
    var owned_paths: std.ArrayList([]u8) = .empty;
    defer {
        for (owned_paths.items) |p| gpa.free(p);
        owned_paths.deinit(gpa);
    }
    const sandbox = probeSandbox(io);
    // Single-use seatbelt profile beside OUT_DIR (plan spool-dir placement):
    // remembered on the macOS arm, deleted once the child below is waited
    // (drainSpawned waits before returning) so runs never leak profiles.
    var seatbelt_profile_abs: ?[]const u8 = null;
    switch (sandbox) {
        .macos_seatbelt => {
            const exec_abs = try toolchain_mod.resolveBinPath(gpa, io, "sandbox-exec") orelse return RunError.SandboxDenied;
            try owned_paths.append(gpa, exec_abs);
            const profile_rel = try std.fmt.allocPrint(gpa, "{s}.sb", .{cfg.out_dir_abs});
            defer gpa.free(profile_rel);
            const tmpdir = cfg.base_env.get("TMPDIR") orelse "/tmp";
            const profile_text = try seatbeltProfile(gpa, cfg.out_dir_abs, tmpdir);
            defer gpa.free(profile_text);
            Io.Dir.cwd().writeFile(io, .{ .sub_path = profile_rel, .data = profile_text }) catch return RunError.Io;
            const profile_dup = try gpa.dupe(u8, profile_rel);
            try owned_paths.append(gpa, profile_dup);
            seatbelt_profile_abs = profile_dup;
            try argv_list.appendSlice(gpa, &.{ exec_abs, "-f", profile_dup, "--", cfg.script_bin_abs });
        },
        .linux_namespaces => {
            if (try toolchain_mod.resolveBinPath(gpa, io, "unshare")) |unshare_abs| {
                try owned_paths.append(gpa, unshare_abs);
                try argv_list.appendSlice(gpa, &.{ unshare_abs, "-rn", cfg.script_bin_abs });
            } else {
                // Vanished between probe and spawn: loud-unsandboxed, same as none_loud.
                renderSandboxWarning(cfg.stderr, "unshare missing") catch return RunError.Io;
                try argv_list.append(gpa, cfg.script_bin_abs);
            }
        },
        .none_loud => {
            const reason: []const u8 = if (builtin.os.tag == .linux) "unshare unavailable" else "unsupported platform";
            renderSandboxWarning(cfg.stderr, reason) catch return RunError.Io;
            try argv_list.append(gpa, cfg.script_bin_abs);
        },
    }

    // Spawn + capture, line-for-line the fetch.zig CliGit.cliRun shape.
    // cwd = package root (cargo runs scripts with the package dir as cwd).
    // Best-effort Linux sandbox: a spawn failure under the wrapper degrades
    // to a loud direct run (the wrapper, not the script, failed).
    const spawn_opts = std.process.SpawnOptions{
        .argv = argv_list.items,
        .environ_map = &child_env,
        .cwd = .{ .path = cfg.pkg_dir_abs },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    };
    var child = std.process.spawn(io, spawn_opts) catch |e| {
        // Spawn never started the child, so the seatbelt profile (if any)
        // was never read: unlink it before returning.
        if (seatbelt_profile_abs) |p| Io.Dir.deleteFileAbsolute(io, p) catch {};
        if (sandbox != .linux_namespaces) return e;
        renderSandboxWarning(cfg.stderr, "unshare spawn failed") catch return RunError.Io;
        argv_list.clearRetainingCapacity();
        try argv_list.append(gpa, cfg.script_bin_abs);
        var opts2 = spawn_opts;
        opts2.argv = argv_list.items;
        var child2 = std.process.spawn(io, opts2) catch |e2| return e2;
        defer child2.kill(io);
        return drainSpawned(gpa, io, store, cfg, &child2, started_ns, allow_bootstrap, diagnostic, diagnostic_len);
    };
    defer child.kill(io);
    const res = drainSpawned(gpa, io, store, cfg, &child, started_ns, allow_bootstrap, diagnostic, diagnostic_len);
    // drainSpawned waited the child, so sandbox-exec (if any) already read
    // the profile: unlink the single-use file instead of leaking it.
    if (seatbelt_profile_abs) |p| Io.Dir.deleteFileAbsolute(io, p) catch {};
    return res;
}

pub const RunResult = struct { output: BuildOutput, manifest: Digest, started_ns: i96 };

fn drainSpawned(
    gpa: std.mem.Allocator,
    io: Io,
    store: *Store,
    cfg: RunConfig,
    child: *std.process.Child,
    started_ns: i96,
    allow_bootstrap: bool,
    diagnostic: ?*[2048]u8,
    diagnostic_len: *usize,
) RunError!RunResult {
    var mr_buf: std.Io.File.MultiReader.Buffer(2) = undefined;
    var mr: std.Io.File.MultiReader = undefined;
    mr.init(gpa, io, mr_buf.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer mr.deinit();
    const out_r = mr.reader(0);
    const err_r = mr.reader(1);
    while (mr.fill(4096, .none)) |_| {} else |e| if (e != error.EndOfStream) return RunError.ScriptFailed;
    const term = child.wait(io) catch return RunError.ScriptFailed;
    if (term != .exited or term.exited != 0) {
        const out = out_r.buffered();
        const n: usize = @min(out.len, 2048);
        if (diagnostic) |d| @memcpy(d[0..n], out[0..n]);
        diagnostic_len.* = n;
        return RunError.ScriptFailed;
    }
    // Script stderr streams to the build log (cargo streams script stderr).
    cfg.stderr.writeAll(err_r.buffered()) catch return RunError.Io;
    const out_bytes = out_r.buffered();
    // Generated-path rewrite at READ time (Task 4): previous OUT_DIR prefix
    // becomes the current one before parsing.
    var owned: ?[]u8 = null;
    defer if (owned) |b| gpa.free(b);
    const parse_input: []const u8 = if (cfg.out_dir_when_generated) |gen|
        if (!std.mem.eql(u8, gen, cfg.out_dir_abs)) blk: {
            owned = try rewriteOutDir(gpa, out_bytes, gen, cfg.out_dir_abs);
            break :blk owned.?;
        } else out_bytes
    else
        out_bytes;
    var parsed = try parseBuildOutput(gpa, parse_input, .{ .allow_rustc_bootstrap = allow_bootstrap });
    defer parsed.deinit(gpa);
    var owned_out = try dupeRunOutput(gpa, &parsed);
    errdefer deinitRunOutput(gpa, &owned_out);
    const manifest = try ingestOutputs(gpa, io, store, cfg.out_dir_abs, &owned_out, &.{});
    return .{ .output = owned_out, .manifest = manifest, .started_ns = started_ns };
}

test "sandbox probe reports a kind on every platform" {
    // NOTE (plan deviation): the plan uses global_single_threaded io here,
    // but that backend cannot spawn (.allocator=.failing); the probe spawns
    // on Linux, so this test owns a real Threaded pool.
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const k = probeSandbox(io);
    // Must be exactly one of the three; on macOS CI never none_loud.
    if (comptime builtin.os.tag == .macos) {
        try std.testing.expect(k == .macos_seatbelt);
    } else {
        try std.testing.expect(k == .linux_namespaces or k == .none_loud);
    }
}

test "unsandboxed runs always warn loudly" {
    const io = std.Io.Threaded.global_single_threaded.io();
    _ = io;
    var err_buf: [4096]u8 = undefined;
    var err_w: Io.Writer = .fixed(&err_buf);
    // drive the none_loud arm directly: try renderSandboxWarning(&err_w, "unshare missing")
    try renderSandboxWarning(&err_w, "unshare missing");
    try err_w.flush();
    try std.testing.expect(std.mem.indexOf(u8, err_w.buffered(), "running unsandboxed") != null);
}

test "runScript captures directives from a stub executable" {
    // NOTE (plan deviation): real Threaded pool — global_single_threaded io
    // cannot spawn (see probe test above).
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = std.testing.allocator;
    var ts = store_mod.test_support.openTestStore(io, .{});
    defer ts.deinit(io);
    var pkg_tmp = std.testing.tmpDir(.{});
    defer pkg_tmp.cleanup();
    // Stub "compiled script": a POSIX sh script emitting directives.
    try pkg_tmp.dir.writeFile(io, .{ .sub_path = "stub.sh", .data = "#!/bin/sh\necho 'cargo::rustc-cfg=stub_cfg'\n" });
    try pkg_tmp.dir.setFilePermissions(io, "stub.sh", .fromMode(0o755), .{});
    const stub_abs = try pkg_tmp.dir.realPathFileAlloc(io, "stub.sh", gpa);
    defer gpa.free(stub_abs);
    const pkg_abs = try pkg_tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(pkg_abs);
    const out_abs = try std.fs.path.join(gpa, &.{ pkg_abs, "out" });
    defer gpa.free(out_abs);
    const manifest_path = try std.fs.path.join(gpa, &.{ pkg_abs, "Cargo.toml" });
    defer gpa.free(manifest_path);
    var base_env = std.process.Environ.Map.init(gpa);
    defer base_env.deinit();
    var err_buf: [4096]u8 = undefined;
    var err_w: Io.Writer = .fixed(&err_buf);
    var diag: [2048]u8 = undefined;
    var diag_len: usize = 0;
    const res = try runScript(gpa, io, &ts.store, .{
        .base_env = &base_env,
        .script_bin_abs = stub_abs,
        .pkg_dir_abs = pkg_abs,
        .out_dir_abs = out_abs,
        .out_dir_when_generated = null,
        .manifest_dir = pkg_abs,
        .manifest_path = manifest_path,
        .links = null,
        .features = &.{},
        .target_triple = "aarch64-apple-darwin",
        .host_triple = "aarch64-apple-darwin",
        .profile_name = "debug",
        .opt_level = "0",
        .debug_assertions = true,
        .rustc_abs = "rustc",
        .encoded_rustflags = "",
        .dep_env = &.{},
        .cfg_env = &.{},
        .stderr = &err_w,
    }, &diag, &diag_len);
    defer deinitRunOutput(gpa, &res.output);
    try std.testing.expectEqualStrings("stub_cfg", res.output.cfgs[0]);
}

// =====================================================================
// Task 6: `links` validation + M4 unit-graph seam
// =====================================================================

/// Across the whole unit graph, two different packages must not declare the
/// same `links` value (cargo `links.rs:20` `validate_links`). Same package
/// appearing twice (e.g. host+target units) is fine: the conflict is on
/// differing package names. Task 8 renders the message and exit 101.
/// `[target.<triple>] links` config overrides are NOT implemented (M6): a
/// `links` key with no build script and no override maps to a loud
/// `need links-override` stderr line + exit 1 at the Task-8 call site.
pub const LinksError = error{DuplicateLinks};

pub const LinksEntry = struct { package: []const u8, version: []const u8, links: ?[]const u8 };

pub fn validateLinks(packages: []const LinksEntry) LinksError!void {
    for (packages, 0..) |a, i| {
        const la = a.links orelse continue;
        for (packages[0..i]) |b| {
            const lb = b.links orelse continue;
            if (std.mem.eql(u8, la, lb) and !std.mem.eql(u8, a.package, b.package)) return LinksError.DuplicateLinks;
        }
    }
}

test "duplicate links keys are rejected" {
    const pkgs = [_]LinksEntry{
        .{ .package = "a", .version = "1.0.0", .links = "foo" },
        .{ .package = "b", .version = "2.0.0", .links = "foo" },
    };
    try std.testing.expectError(LinksError.DuplicateLinks, validateLinks(&pkgs));
}

test "same package twice is fine" {
    const pkgs = [_]LinksEntry{
        .{ .package = "a", .version = "1.0.0", .links = "foo" },
        .{ .package = "a", .version = "1.0.0", .links = "foo" },
    };
    try validateLinks(&pkgs);
}

/// Everything the action key needs that the workspace cannot know.
/// Carried per plan so M4 keeps the `planScripts` signature below and
/// swaps only the body for a unit-graph projection.
pub const PlanOptions = struct {
    target_triple: ?[]const u8,
    host_triple: []const u8,
    profile_name: []const u8,
    opt_level: []const u8,
    debug_assertions: bool,
    toolchain_id: []const u8,
    project_tag: []const u8, // pb3-<hex> workspace id
};

/// NOTE (plan deviation): the plan unions only `LinksError`, Alloc OOM,
/// `Io.Dir.ReadFileAllocError`, and `ManifestSurfaceError`, but the
/// prescribed body also opens the package dir (`CreateDirPathOpenError`)
/// and warns via `stderr` (`Writer.Error`) — both ride along honestly here.
pub const PlanError = LinksError || std.mem.Allocator.Error || Io.Dir.ReadFileAllocError || manifest_mod.ManifestSurfaceError || Io.Dir.CreateDirPathOpenError || Io.Writer.Error;

/// One build-script unit: the M4 driver seam. `links` is gpa-owned iff
/// produced by `planScripts` (freed by `deinitPlanUnits`); borrowed when M4
/// projects from the unit graph. `script_rel` borrows the member manifest
/// arena (or is the `"build.rs"` literal); every other slice borrows the
/// caller's `PlanOptions`/workspace and outlives the plan.
pub const ScriptUnit = struct {
    package: []const u8,
    version: []const u8,
    pkg_dir_abs: []const u8, // package root (rerun-if-changed anchor)
    script_rel: []const u8, // build script path relative to pkg root ("build.rs" default)
    links: ?[]const u8, // [package] links key; gpa-owned iff produced by planScripts (see deinitPlanUnits), else borrowed
    features: []const []const u8, // sorted enabled features
    profile_name: []const u8,
    opt_level: []const u8,
    debug_assertions: bool,
    target_triple: []const u8,
    host_triple: []const u8,
    toolchain_id: []const u8,
    rustflags_encoded: []const u8,
    cfg_env: []const KeyValue, // pre-rendered CARGO_CFG_… vars (Task 5 consumes)
    project_tag: []const u8, // pb3-<hex> workspace id
};

/// One finished unit run. `unit` borrows the plan (the plan outlives the
/// result); `output` is owned (caller deinits); `out_dir_abs` is owned.
pub const ScriptResult = struct {
    unit: ScriptUnit, // borrowed from the plan (lifetime: plan outlives result)
    output: BuildOutput, // parsed directives (owned; caller deinits)
    manifest: Digest, // store manifest of OUT_DIR files (Task 4)
    out_dir_abs: []const u8, // materialized OUT_DIR (owned)
    started_ns: i96, // spawn anchor for Task-3 freshness
    from_cache: bool, // true = materialized, script never ran
    store_skipped: bool, // true = StoreFull degraded path (Task 8; manifest is prev manifest, outputs verified identical)
    pub fn deinit(self: *const ScriptResult, gpa: std.mem.Allocator) void {
        // Deep free: every runUnit output is dupeRunOutput-owned (strings
        // duped, not borrowed), including cache-hit outputs moved from a
        // StoredScriptState (readScriptState deep-dupes). The Task-1 shallow
        // `deinit` would leak the duped strings — never use it here.
        deinitRunOutput(gpa, &self.output);
        gpa.free(self.out_dir_abs);
    }
};

/// Host-compiled proc-macro dylib handle. Strings borrow the caller;
/// `extern_arg` is gpa-owned. rime never dlopens the dylib (M5 boundary:
/// expansion is performed by rustc itself when it loads `--extern <dylib>`).
pub const ProcMacroArtifact = struct {
    package: []const u8,
    version: []const u8,
    dylib_digest: Digest, // Kind.dylib object in store (Task 7 ingests)
    host_triple: []const u8,
    extern_arg: []const u8, // "--extern <crate>=<store-rel-path>" rendered for rustc (owned)
    pub fn deinit(self: *const ProcMacroArtifact, gpa: std.mem.Allocator) void {
        gpa.free(self.extern_arg);
    }
};

/// Workspace-derived provider until the M4 unit graph lands: one
/// `ScriptUnit` per member that has a build script. M4 keeps this
/// signature and swaps the body for a unit-graph projection.
///
/// Member→surface→probe logic: `Member.manifest` is the M1 Manifest (it
/// HAS `pkg.build_script` via `optionalBuildScript`: string verbatim,
/// `true` -> "build.rs", `false`/absent -> null). `links` lives ONLY on
/// `ManifestExt`, so each member surface is re-parsed with
/// `parseManifestExt` here. Absent/false (null) + existing build.rs ->
/// default unit, silent when missing (a normal package); an explicit path
/// that is missing -> loud skip (cargo errors; rime M5 warns-and-skips
/// because the driver cannot yet attribute the failure to the right unit).
pub fn planScripts(gpa: std.mem.Allocator, io: Io, ws: *const workspace_mod.Workspace, opts: PlanOptions, stderr: *Io.Writer) PlanError![]ScriptUnit {
    var units: std.ArrayList(ScriptUnit) = .empty;
    errdefer units.deinit(gpa);
    for (ws.members) |*m| {
        const manifest_abs = try std.fs.path.join(gpa, &.{ m.dir, "Cargo.toml" });
        defer gpa.free(manifest_abs);
        const text = try Io.Dir.cwd().readFileAlloc(io, manifest_abs, gpa, .limited(1 << 20));
        defer gpa.free(text);
        var ext = try manifest_mod.parseManifestExt(gpa, text, manifest_abs);
        defer ext.deinit();
        const declared: ?[]const u8 = if (m.manifest.pkg) |pkg| pkg.build_script else null;
        var pkg_dir = try Io.Dir.cwd().createDirPathOpen(io, m.dir, .{});
        defer pkg_dir.close(io);
        const script_rel: []const u8 = if (declared) |d| rel: {
            // Probe only: the Stat value is intentionally discarded.
            _ = pkg_dir.statFile(io, d, .{}) catch {
                const msg = try std.fmt.allocPrint(gpa, "warning: {s} declares build script {s} but the file is missing; skipping\n", .{ m.name, d });
                defer gpa.free(msg);
                try stderr.writeAll(msg);
                break :rel "";
            };
            break :rel d;
        } else if (pkg_dir.statFile(io, "build.rs", .{})) |_| "build.rs" else |_| "";
        if (script_rel.len == 0) continue;
        // ext.links borrows ext's arena (freed by the defer above): dupe it
        // into gpa (see ScriptUnit.links ownership).
        const links: ?[]const u8 = if (ext.links) |l| try gpa.dupe(u8, l) else null;
        errdefer if (links) |l| gpa.free(l);
        try units.append(gpa, .{
            .package = m.name,
            .version = m.version,
            .pkg_dir_abs = m.dir,
            .script_rel = script_rel,
            .links = links,
            .features = &.{},
            .profile_name = opts.profile_name,
            .opt_level = opts.opt_level,
            .debug_assertions = opts.debug_assertions,
            .target_triple = opts.target_triple orelse opts.host_triple,
            .host_triple = opts.host_triple,
            .toolchain_id = opts.toolchain_id,
            .rustflags_encoded = "",
            .cfg_env = &.{},
            .project_tag = opts.project_tag,
        });
    }
    // Conflict check over the derived units (Task 8 re-runs it pre-build; same call).
    var entries: std.ArrayList(LinksEntry) = .empty;
    defer entries.deinit(gpa);
    for (units.items) |*u| try entries.append(gpa, .{ .package = u.package, .version = u.version, .links = u.links });
    try validateLinks(entries.items);
    return units.toOwnedSlice(gpa);
}

pub fn deinitPlanUnits(gpa: std.mem.Allocator, units: []ScriptUnit) void {
    for (units) |u| if (u.links) |l| gpa.free(l);
    gpa.free(units);
}

test "planScripts finds members with build scripts" {
    // Fixture testdata/cargo/script-protocol/ws: sys declares
    // [package] links="native-sys" + build="build.rs"; app is a plain bin.
    const io = std.Io.Threaded.global_single_threaded.io();
    var ws = try workspace_mod.discover(std.testing.allocator, io, "testdata/cargo/script-protocol/ws", null);
    defer ws.deinit();
    var err_buf: [1024]u8 = undefined;
    var err_w: Io.Writer = .fixed(&err_buf);
    const units = try planScripts(std.testing.allocator, io, &ws, .{
        .target_triple = null,
        .host_triple = "aarch64-apple-darwin",
        .profile_name = "dev",
        .opt_level = "0",
        .debug_assertions = true,
        .toolchain_id = "rustc 1.99.0-nightly test",
        .project_tag = "pb3-test",
    }, &err_w);
    defer deinitPlanUnits(std.testing.allocator, units);
    try std.testing.expectEqual(@as(usize, 1), units.len);
    try std.testing.expectEqualStrings("sys", units[0].package);
    try std.testing.expectEqualStrings("native-sys", units[0].links.?);
}

// =====================================================================
// Task 7: proc-macro crates (host dylib ingest + explicit boundary)
// =====================================================================
//
// WORKS IN M5 — (a) `[lib] proc-macro = true` parses (manifest.zig
// `TargetDesc.proc_macro`); (b) the driver seam exposes the dylib for host
// compilation via `ProcMacroArtifact` (path + `--extern` rendering); (c) the
// compiled `.so`/`.dylib` is ingested as `Kind.dylib` with tags and is
// re-materializable by digest. DOES NOT WORK IN M5 — (d) rime NEVER dlopens
// the dylib (no macro-expansion code exists in rime; expansion is performed
// by rustc itself when it loads `--extern <dylib>`); (e) compiling a
// DEPENDENT crate that uses the macro still waits on the M4 driver passing
// `extern_arg` to rustc — `rime build` on a macro-using workspace reports
// `need driver: proc-macro dependents require M4 rustc invocation`
// (exit 1, same D5 shape as the M1 `need source` error).

/// Error-set honesty, verified against the calls below: `openFileAbsolute`
/// fails with `Io.File.OpenError` (`lib/std/Io/Dir.zig:581` namespace-level
/// open); `store.putFile` with `Store.PutError` (hashes while writing per
/// storage-v2 §8.1); `store.tagObject` with `store_mod.TagError`. `StoreFull`
/// arrives via `PutError`/`AdmitError` and via `TagError` (the plan's
/// Interfaces name it explicitly; both carriers union it in).
pub const ProcMacroError = error{StoreFull} || std.mem.Allocator.Error || Store.PutError || store_mod.TagError || Io.File.OpenError;

pub fn ingestProcMacroDylib(
    gpa: std.mem.Allocator,
    io: Io,
    store: *Store,
    dylib_abs: []const u8,
    package: []const u8,
    version: []const u8,
    host_triple: []const u8,
    project_tag: []const u8,
    toolchain_id: []const u8,
) ProcMacroError!ProcMacroArtifact {
    // No `Io.Dir.openPath` (does not exist in 0.16): namespace-level
    // absolute open + putFile.
    var f = try Io.Dir.openFileAbsolute(io, dylib_abs, .{});
    defer f.close(io);
    const digest = try store.putFile(io, f, .dylib);
    // The `target` tag carries the HOST triple: the bytes were built with
    // the host toolchain even under `--target` (cargo `unit.rs:70-74`
    // `CompileKind::Host`; `mod.rs:1311` host dylib preference).
    const tags = [_]Tag{
        .{ .key = "crate", .value = package },
        .{ .key = "crate_version", .value = version },
        .{ .key = "toolchain", .value = toolchain_id },
        .{ .key = "target", .value = host_triple },
        .{ .key = "profile", .value = "host" },
        .{ .key = "project", .value = project_tag },
        .{ .key = "action", .value = "proc-macro" },
    };
    try store.tagObject(io, digest, &tags);
    var hex_buf: [65]u8 = undefined;
    const rel = digest.relPath(&hex_buf);
    const extern_arg = try std.fmt.allocPrint(gpa, "--extern {s}={s}", .{ package, rel });
    errdefer gpa.free(extern_arg);
    return .{
        .package = package,
        .version = version,
        .dylib_digest = digest,
        .host_triple = host_triple,
        .extern_arg = extern_arg,
    };
}

test "proc-macro dylib ingests as never-demoted dylib with tags" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var ts = store_mod.test_support.openTestStore(io, .{});
    defer ts.deinit(io);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "libmac.so", .data = "fake-dylib-bytes" });
    const abs = try tmp.dir.realPathFileAlloc(io, "libmac.so", gpa);
    defer gpa.free(abs);
    const art = try ingestProcMacroDylib(gpa, io, &ts.store, abs, "mac", "0.1.0", "aarch64-apple-darwin", "pb3-test", "rustc 1.99.0-nightly test");
    defer art.deinit(gpa);
    try std.testing.expect(std.mem.startsWith(u8, art.extern_arg, "--extern mac="));
    try ts.store.verifyObject(io, art.dylib_digest);
    // `Kind.dylib` is NEVER demoted (storage-v2 §9.4; `cold.isDemotable`
    // returns false for `.dylib`). `cold.zig` is not importable here
    // (parent-dir `@import("../store/…")` is rejected under bare `zig
    // test`, same rule as `script.zig` itself), so the invariant is pinned
    // through the Store surface instead: demote must leave the hot copy in
    // place. A store regression that demotes dylibs breaks this test loudly.
    try ts.store.demote(io, art.dylib_digest);
    try std.testing.expect(store_mod.test_support.dirHasHot(&ts.store, io, art.dylib_digest));
    // Full §11.3 tag set with action=proc-macro landed on the object.
    const got_tags = try ts.store.tagsFor(io, gpa, art.dylib_digest);
    defer {
        for (got_tags) |t| {
            gpa.free(t.key);
            gpa.free(t.value);
        }
        gpa.free(got_tags);
    }
    var seen_action = false;
    var seen_target = false;
    for (got_tags) |t| {
        if (std.mem.eql(u8, t.key, "action") and std.mem.eql(u8, t.value, "proc-macro")) seen_action = true;
        if (std.mem.eql(u8, t.key, "target") and std.mem.eql(u8, t.value, "aarch64-apple-darwin")) seen_target = true;
    }
    try std.testing.expect(seen_action);
    try std.testing.expect(seen_target);
}

// =====================================================================
// Task 8: CLI wiring + caching (freshness gate, cache-hit path, loud errors)
// =====================================================================
//
// Orchestration (the caching contract, exact order):
// 1. `validateLinks` over the whole plan BEFORE any `runUnit` call (the CLI
//    loop validates once; conflict aborts with exit 101 and cargo's
//    message). `LinksError.DuplicateLinks` maps to
//    `UnitRunError.LinksConflict` at that call site only — `runUnit` itself
//    never validates, it runs one unit.
// 2. `scriptActionKey` (Task 4) from current inputs (script binary digest
//    via `store_mod.hashFile`, watched env CURRENT values from the process
//    env). `rerun-if-changed` PATHS and mtimes stay a Task-3 freshness
//    check, never key inputs.
// 3. Freshness gate on PREVIOUS-run data only (cargo `fingerprint/mod.rs`:
//    "The 'rerun-if' statements from a *previous* build are stored…"):
//    no prev → run; `shouldRerun` fresh → `store.getAction(prev key)` →
//    hit: `materializeOutDir`, return `from_cache = true` WITHOUT spawning
//    (action-cache read errors degrade to a MISS with a loud warning — a
//    miss is always safe); rerun (or action miss) → spawn → new key →
//    `putAction` → fresh result. Watch-set comparison (`watchSetChanged`)
//    happens AFTER the run only to decide what to STORE, never to skip.
// 4. `OldStyleFallback` never propagates: catch it, warn loudly, RUN.
//    (`UnitRunError.OldStyleAlwaysRerun` exists for the CLI to count
//    old-style units in diagnostics; `runUnit` itself never returns it.)
// 5. `StoreFull` on the POST-RUN full-tag ingest never fails the build
//    (storage-v2 §10.4): catch, emit the `lastFull()` breakdown verbatim,
//    compare the live OUT_DIR against the previous manifest with
//    `outDirsIdentical`. Identical → parsed output with prev manifest,
//    `store_skipped = true`. Changed → propagate `StoreFull`. (A StoreFull
//    from runScript's OWN internal ingest propagates: the parsed output is
//    lost with it, so there is nothing identical to compare. The degraded
//    path covers the post-run tagging ingest, which writes NEW tag rows.)
// 6. warnings → stderr `warning: <pkg>: <msg>`; any `errors` entry fails
//    with `ScriptFailed` (diagnostic = first error string), exit 101.

/// `LinksConflict`/`OldStyleAlwaysRerun` are CALL-SITE mappings (see above),
/// never returned by `runUnit` itself. `error{Unexpected, Canceled}` covers
/// `putAction`'s `PutError` (`action_cache.zig:13`: no StoreFull there —
/// action rows admit without a budget check); `getAction` read errors are
/// caught and degraded, except OOM/Cancel which propagate honestly.
pub const UnitRunError = error{ LinksConflict, OldStyleAlwaysRerun } || RunError || RerunError || KeyError || std.mem.Allocator.Error || Io.Writer.Error || Io.File.OpenError || std.Io.File.ReadPositionalError || error{ Unexpected, Canceled };

/// Previous-run state: the freshness gate reads THIS, never recomputes.
/// All strings/slices gpa-owned (deep); `output` is a `dupeRunOutput`-style
/// deep copy (free with `output.deinit`?? NO — with `deinitRunOutput`, which
/// frees the duped strings; the Task-1 `deinit` would leak them).
pub const StoredScriptState = struct {
    action_key: Digest, // stored action key: the freshness gate looks THIS up
    output: BuildOutput, // previous directives (owns; deep — free with deinitRunOutput)
    manifest: Digest, // previous OUT_DIR manifest
    out_dir_when_generated: []const u8, // absolute OUT_DIR of the previous run (owned)
    started_ns: i96,
    watched_env_values: []const ?[]const u8, // stored env values, emission order (owned deep)
    pub fn deinit(self: *const StoredScriptState, gpa: std.mem.Allocator) void {
        deinitRunOutput(gpa, &self.output);
        gpa.free(self.out_dir_when_generated);
        for (self.watched_env_values) |v| if (v) |s| gpa.free(s);
        gpa.free(self.watched_env_values);
    }
};

pub fn watchSetChanged(prev_changed: []const []const u8, prev_env: []const []const u8, cur: *const BuildOutput) bool {
    if (prev_changed.len != cur.rerun_if_changed.len) return true;
    if (prev_env.len != cur.rerun_if_env_changed.len) return true;
    for (prev_changed, cur.rerun_if_changed) |a, b| if (!std.mem.eql(u8, a, b)) return true;
    for (prev_env, cur.rerun_if_env_changed) |a, b| if (!std.mem.eql(u8, a, b)) return true;
    return false;
}

/// True when every file recorded in `prev_manifest` exists under
/// `out_dir_abs` with identical bytes. Extra live files are harmless (the
/// live dir is used as-is on the StoreFull-degraded path). Never fails: any
/// read/manifest error is "not identical" (safe direction — the caller then
/// propagates StoreFull instead of trusting a guess).
pub fn outDirsIdentical(gpa: std.mem.Allocator, io: Io, store: *Store, out_dir_abs: []const u8, prev_manifest: Digest) bool {
    const pm = store.getManifest(io, gpa, prev_manifest) catch return false;
    defer pm.deinit(gpa);
    var dir = Io.Dir.cwd().createDirPathOpen(io, out_dir_abs, .{}) catch return false;
    defer dir.close(io);
    for (pm.outputs) |o| {
        const bytes = dir.readFileAlloc(io, o.path, gpa, .unlimited) catch return false;
        defer gpa.free(bytes);
        if (!std.meta.eql(store_mod.hashBytes(bytes), o.digest)) return false;
    }
    return true;
}

pub fn runUnit(
    gpa: std.mem.Allocator,
    io: Io,
    store: *Store,
    unit: ScriptUnit,
    script_bin_abs: []const u8,
    prev: ?StoredScriptState,
    spool_abs: []const u8,
    base_env: *const std.process.Environ.Map,
    stderr: *Io.Writer,
) UnitRunError!ScriptResult {
    // Phase 1: gate on previous-run data (prev lists + current env values +
    // file mtimes). First run (null prev) always runs.
    if (prev) |*p| {
        const cur_env = try gpa.alloc(?[]const u8, p.output.rerun_if_env_changed.len);
        defer gpa.free(cur_env);
        for (p.output.rerun_if_env_changed, cur_env) |n, *slot| slot.* = base_env.get(n);
        const gate = shouldRerun(gpa, io, unit.pkg_dir_abs, .{
            .prev_changed = p.output.rerun_if_changed,
            .prev_env_changed = p.output.rerun_if_env_changed,
            .prev_output_ns = p.started_ns,
            .current_env = cur_env,
            .prev_env_values = p.watched_env_values,
        }) catch |e| blk: {
            if (e != error.OldStyleFallback) {
                p.deinit(gpa);
                return e;
            }
            try stderr.writeAll("warning: ");
            try stderr.writeAll(unit.package);
            try stderr.writeAll(" build script uses old-style rerun detection; always re-running (package mtime walk not implemented)\n");
            break :blk RerunDecision.rerun;
        };
        if (gate == .fresh) {
            const hit: ?Store.ActionEntry = if (store.getAction(io, gpa, p.action_key)) |h| h else |e| blk: {
                if (e == error.OutOfMemory or e == error.Canceled) {
                    p.deinit(gpa);
                    return e;
                }
                try stderr.writeAll("warning: ");
                try stderr.writeAll(unit.package);
                try stderr.writeAll(": action cache unreadable (");
                try stderr.writeAll(@errorName(e));
                try stderr.writeAll("); re-running\n");
                break :blk null;
            };
            if (hit) |entry| {
                const out_dir_abs = try std.fs.path.join(gpa, &.{ spool_abs, "build", unit.package, "out" });
                materializeOutDir(gpa, io, store, entry.manifest, out_dir_abs) catch |e| {
                    gpa.free(out_dir_abs);
                    p.deinit(gpa);
                    return e;
                };
                // HIT: the script never runs; OUT_DIR is byte-identical via
                // the store. Move the stored output into the result and free
                // the rest of prev (the gate borrows nothing afterwards).
                const output = p.output;
                const started = p.started_ns;
                gpa.free(p.out_dir_when_generated);
                for (p.watched_env_values) |v| if (v) |s| gpa.free(s);
                gpa.free(p.watched_env_values);
                return .{
                    .unit = unit,
                    .output = output,
                    .manifest = entry.manifest,
                    .out_dir_abs = out_dir_abs,
                    .started_ns = started,
                    .from_cache = true,
                    .store_skipped = false,
                };
            }
        }
    }
    // Phase 2: run. The binary was compiled by the driver seam (Task 8
    // receives its path); the digest binds recompiles into the action key.
    const bin_file = try Io.Dir.openFileAbsolute(io, script_bin_abs, .{});
    defer bin_file.close(io);
    const bin_digest = try store_mod.hashFile(bin_file, io);
    const out_dir_abs = try std.fs.path.join(gpa, &.{ spool_abs, "build", unit.package, "out" });
    errdefer gpa.free(out_dir_abs);
    const manifest_path = try std.fs.path.join(gpa, &.{ unit.pkg_dir_abs, "Cargo.toml" });
    defer gpa.free(manifest_path);
    var diag: [2048]u8 = undefined;
    var diag_len: usize = 0;
    var run_res = runScript(gpa, io, store, .{
        .base_env = base_env,
        .script_bin_abs = script_bin_abs,
        .pkg_dir_abs = unit.pkg_dir_abs,
        .out_dir_abs = out_dir_abs,
        .out_dir_when_generated = if (prev) |*p| p.out_dir_when_generated else null,
        .manifest_dir = unit.pkg_dir_abs,
        .manifest_path = manifest_path,
        .links = unit.links,
        .features = unit.features,
        .target_triple = unit.target_triple,
        .host_triple = unit.host_triple,
        .profile_name = unit.profile_name,
        .opt_level = unit.opt_level,
        .debug_assertions = unit.debug_assertions,
        .rustc_abs = "rustc", // M4 resolves the real toolchain path; M5 stubs it (documented)
        .encoded_rustflags = unit.rustflags_encoded,
        .dep_env = &.{}, // M4 orders units and threads Task-2 DEP_ vars; M5 runs one unit (documented)
        .cfg_env = unit.cfg_env,
        .stderr = stderr,
    }, &diag, &diag_len) catch |e| {
        if (prev) |*p| p.deinit(gpa);
        return e;
    };
    errdefer deinitRunOutput(gpa, &run_res.output);
    // The rewrite already consumed prev's OUT_DIR during the run; the rest
    // of prev is dead. Keep the previous manifest DIGEST (a value copy) for
    // the StoreFull-degraded compare below.
    const prev_manifest: ?Digest = if (prev) |*p| blk: {
        const m = p.manifest;
        p.deinit(gpa);
        break :blk m;
    } else null;
    for (run_res.output.warnings) |w| {
        try stderr.writeAll("warning: ");
        try stderr.writeAll(unit.package);
        try stderr.writeAll(": ");
        try stderr.writeAll(w);
        try stderr.writeAll("\n");
    }
    if (run_res.output.errors.len > 0) {
        for (run_res.output.errors) |e| {
            try stderr.writeAll("error: ");
            try stderr.writeAll(unit.package);
            try stderr.writeAll(": ");
            try stderr.writeAll(e);
            try stderr.writeAll("\n");
        }
        return UnitRunError.ScriptFailed;
    }
    // Watch-set check happens AFTER the run, only to decide what to store
    // (the new lists ride along in the returned output): never a skip.
    // It must run BEFORE the prev deinit below — it borrows prev's lists.
    const watch_changed: bool = if (prev) |*p|
        watchSetChanged(p.output.rerun_if_changed, p.output.rerun_if_env_changed, &run_res.output)
    else
        false;
    _ = watch_changed;
    // Fresh key from the NEW output's names + current values.
    const new_names = run_res.output.rerun_if_env_changed;
    const new_vals = try gpa.alloc(?[]const u8, new_names.len);
    defer gpa.free(new_vals);
    for (new_names, new_vals) |n, *slot| slot.* = base_env.get(n);
    const key = try scriptActionKey(gpa, .{
        .script_bin_digest = bin_digest,
        .package_name = unit.package,
        .package_version = unit.version,
        .links = unit.links,
        .features = unit.features,
        .profile_name = unit.profile_name,
        .opt_level = unit.opt_level,
        .debug_assertions = unit.debug_assertions,
        .target_triple = unit.target_triple,
        .host_triple = unit.host_triple,
        .toolchain_id = unit.toolchain_id,
        .watched_env_values = new_vals,
        .watched_env_names = new_names,
        .rustflags_relevant = unit.rustflags_encoded,
    });
    // Full §11.3 tag set (runScript ingested with the empty set; this
    // re-ingest is reservation-free by §10.5 idempotency and applies the
    // tags under the same manifest digest).
    const tags = [_]Tag{
        .{ .key = "crate", .value = unit.package },
        .{ .key = "crate_version", .value = unit.version },
        .{ .key = "toolchain", .value = unit.toolchain_id },
        .{ .key = "target", .value = unit.target_triple },
        .{ .key = "profile", .value = unit.profile_name },
        .{ .key = "project", .value = unit.project_tag },
        .{ .key = "action", .value = "build-script" },
    };
    const manifest = ingestOutputs(gpa, io, store, out_dir_abs, &run_res.output, &tags) catch |e| {
        if (e != error.StoreFull) return e;
        // Ownership: the handler borrows output/out_dir_abs on its error
        // path (this function's errdefers still own them) and moves both
        // into the result on success (this function then returns it, so the
        // errdefers never fire). No disarm flags needed.
        return try degradedOnFull(gpa, io, store, unit, out_dir_abs, &run_res.output, run_res.started_ns, prev_manifest, stderr);
    };
    try store.putAction(io, key, manifest);
    const output = run_res.output;
    return .{
        .unit = unit,
        .output = output,
        .manifest = manifest,
        .out_dir_abs = out_dir_abs,
        .started_ns = run_res.started_ns,
        .from_cache = false,
        .store_skipped = false,
    };
}

/// StoreFull-degraded commit (storage-v2 §10.4 build-driver rule): the
/// post-run ingest failed with a full store. Emit the `lastFull()`
/// breakdown verbatim, then compare the live OUT_DIR against the previous
/// manifest: identical → keep the parsed output with the previous manifest
/// (`store_skipped = true`); changed (or first run, null prev) → propagate
/// StoreFull. (A StoreFull from runScript's OWN internal ingest
/// propagates instead: the parsed output is lost with it, so there is
/// nothing identical to compare. The degraded path covers the post-run
/// full-tag ingest, which writes NEW tag rows.)
///
/// Factored out of runUnit (not inlined) because staging a full store
/// inside runUnit's atomic run-then-ingest flow is not byte-tunable:
/// sqlite page growth from the dedup upserts between the two ingests
/// exceeds any estimate window, so a clamped-budget end-to-end test is
/// nondeterministic. The handler is covered deterministically by direct
/// tests below; the 3-line catch-and-delegate in runUnit is review-verified.
///
/// Ownership: borrows `output`/`out_dir_abs` on the error path (the caller
/// retains them), moves both into the returned result on success.
fn degradedOnFull(
    gpa: std.mem.Allocator,
    io: Io,
    store: *Store,
    unit: ScriptUnit,
    out_dir_abs: []u8,
    output: *BuildOutput,
    started_ns: i96,
    prev_manifest: ?Digest,
    stderr: *Io.Writer,
) UnitRunError!ScriptResult {
    const full = store.lastFull();
    const full_line = try std.fmt.allocPrint(gpa, "warning: store full during script ingest: class={s} requested={d} used_total={d} hint={s}\n", .{ @tagName(full.class), full.requested_bytes, full.used_total, @tagName(full.hint) });
    defer gpa.free(full_line);
    try stderr.writeAll(full_line);
    if (prev_manifest) |pm| {
        if (outDirsIdentical(gpa, io, store, out_dir_abs, pm)) {
            return .{
                .unit = unit,
                .output = output.*,
                .manifest = pm,
                .out_dir_abs = out_dir_abs,
                .started_ns = started_ns,
                .from_cache = false,
                .store_skipped = true,
            };
        }
    }
    return UnitRunError.StoreFull;
}

// State files (`target/<profile>/.fingerprint/<pkg>-script.json`) are a
// VIEW-local hint, same class as M1 `last-build.json`: regenerable, while
// the store stays authoritative via action keys. Only the rerun-relevant
// slices survive the round trip (rerun-if lists + watched values); cfgs,
// env, metadata and link args are rebuild inputs, not freshness inputs, so
// they persist as empty and are re-parsed on every real run.

/// Honest set: `createDirPath` (parent creation) rides along with the
/// plan's read/write errors. OOM maps to itself, never to InvalidState.
pub const ScriptStateError = error{InvalidState} || std.mem.Allocator.Error || Io.Dir.ReadFileAllocError || Io.Dir.WriteFileError || Io.Dir.CreateDirPathError;

const ScriptStateJson = struct {
    action_key: []const u8, // 64 lowercase hex (Digest.toHex form, no b3- prefix)
    manifest: []const u8, // 64 lowercase hex
    out_dir_when_generated: []const u8,
    started_ns: []const u8, // i96 decimal
    rerun_if_changed: []const []const u8,
    rerun_if_env_changed: []const []const u8,
    env_values: []const ?[]const u8,
};

pub fn writeScriptState(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, pkg: []const u8, st: *const StoredScriptState) ScriptStateError!void {
    const rel = try std.fmt.allocPrint(gpa, ".fingerprint/{s}-script.json", .{pkg});
    defer gpa.free(rel);
    // toHex returns a [64]u8 VALUE: bind before slicing (a method call
    // result has no addressable lifetime for a direct [0..] slice).
    const action_hex = st.action_key.toHex();
    const man_hex = st.manifest.toHex();
    const ns_str = try std.fmt.allocPrint(gpa, "{d}", .{st.started_ns});
    defer gpa.free(ns_str);
    const bytes = try std.json.Stringify.valueAlloc(gpa, ScriptStateJson{
        .action_key = action_hex[0..],
        .manifest = man_hex[0..],
        .out_dir_when_generated = st.out_dir_when_generated,
        .started_ns = ns_str,
        .rerun_if_changed = st.output.rerun_if_changed,
        .rerun_if_env_changed = st.output.rerun_if_env_changed,
        .env_values = st.watched_env_values,
    }, .{});
    defer gpa.free(bytes);
    try dir.createDirPath(io, ".fingerprint");
    try dir.writeFile(io, .{ .sub_path = rel, .data = bytes });
}

pub fn readScriptState(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, pkg: []const u8) ScriptStateError!?StoredScriptState {
    const rel = try std.fmt.allocPrint(gpa, ".fingerprint/{s}-script.json", .{pkg});
    defer gpa.free(rel);
    const bytes = dir.readFileAlloc(io, rel, gpa, .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    defer gpa.free(bytes);
    const parsed = std.json.parseFromSlice(ScriptStateJson, gpa, bytes, .{ .allocate = .alloc_always }) catch |e| {
        if (e == error.OutOfMemory) return ScriptStateError.OutOfMemory;
        return ScriptStateError.InvalidState;
    };
    defer parsed.deinit();
    const dto = parsed.value;
    if (dto.rerun_if_env_changed.len != dto.env_values.len) return ScriptStateError.InvalidState;
    // Deep-dupe every string: `dto` arrays borrow the parse arena, freed by
    // `parsed.deinit()` above, so slice-header dupes alone would dangle.
    var changed: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (changed.items) |s| gpa.free(s);
        changed.deinit(gpa);
    }
    for (dto.rerun_if_changed) |s| try changed.append(gpa, try gpa.dupe(u8, s));
    var env_names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (env_names.items) |s| gpa.free(s);
        env_names.deinit(gpa);
    }
    for (dto.rerun_if_env_changed) |s| try env_names.append(gpa, try gpa.dupe(u8, s));
    var env_vals: std.ArrayList(?[]const u8) = .empty;
    errdefer {
        for (env_vals.items) |v| if (v) |s| gpa.free(s);
        env_vals.deinit(gpa);
    }
    for (dto.env_values) |v| try env_vals.append(gpa, if (v) |s| try gpa.dupe(u8, s) else null);
    return StoredScriptState{
        .action_key = store_mod.Digest.fromHex(dto.action_key) catch return ScriptStateError.InvalidState,
        .output = .{
            .cfgs = &.{},
            .check_cfgs = &.{},
            .link_libs = &.{},
            .link_search = &.{},
            .link_args = &.{},
            .rustc_flags_raw = &.{},
            .env = &.{},
            .metadata = &.{},
            .rerun_if_changed = try changed.toOwnedSlice(gpa),
            .rerun_if_env_changed = try env_names.toOwnedSlice(gpa),
            .warnings = &.{},
            .errors = &.{},
        },
        .manifest = store_mod.Digest.fromHex(dto.manifest) catch return ScriptStateError.InvalidState,
        .out_dir_when_generated = try gpa.dupe(u8, dto.out_dir_when_generated),
        .started_ns = std.fmt.parseInt(i96, dto.started_ns, 10) catch return ScriptStateError.InvalidState,
        .watched_env_values = try env_vals.toOwnedSlice(gpa),
    };
}

/// First `[package] links` value whose package has NO script unit, duped
/// (caller frees), or null when every links key has a script. Backs the CLI
/// `need links-override` loud error: a links key with no build script (and
/// no `[target.<triple>] links` override, which M6 owns) leaves dependents
/// with no DEP_ vars. Reads each member surface directly — no package-dir
/// probe needed (only the manifest text matters, never file existence).
pub fn linksWithoutScript(
    gpa: std.mem.Allocator,
    io: Io,
    ws: *const workspace_mod.Workspace,
    units: []const ScriptUnit,
) (std.mem.Allocator.Error || Io.Dir.ReadFileAllocError || manifest_mod.ManifestSurfaceError)!?[]u8 {
    for (ws.members) |*m| {
        const manifest_abs = try std.fs.path.join(gpa, &.{ m.dir, "Cargo.toml" });
        defer gpa.free(manifest_abs);
        const text = try Io.Dir.cwd().readFileAlloc(io, manifest_abs, gpa, .limited(1 << 20));
        defer gpa.free(text);
        var ext = try manifest_mod.parseManifestExt(gpa, text, manifest_abs);
        defer ext.deinit();
        const links = ext.links orelse continue;
        var has_unit = false;
        for (units) |*u| if (std.mem.eql(u8, u.package, m.name)) {
            has_unit = true;
            break;
        };
        if (!has_unit) return try gpa.dupe(u8, links);
    }
    return null;
}

// ---- Task 8 tests: cache-hit gate, StoreFull degradation, state files ----

// Shared runUnit fixture: a package dir with an executable stub "compiled
// script" + a watched file, a spool dir, a hand-built base env, and a real
// store. NOTE (plan correction): the plan's cache-hit sketch smuggles the
// sentinel via `dep_env`, but runUnit owns its RunConfig (dep_env is M4's
// cross-unit channel, empty in M5). The sentinel rides in `base_env`
// instead — `scriptEnv` clones the base map verbatim, so the child observes
// it identically. No RunConfig change needed.
const CacheTestCtx = struct {
    threaded: std.Io.Threaded,
    ts: store_mod.test_support.TestStore,
    pkg_tmp: std.testing.TmpDir,
    spool_tmp: std.testing.TmpDir,
    // realPathFileAlloc returns sentinel-terminated slices; keep the [:0]
    // type so gpa.free sees the true (len+1) allocation (stripping to []u8
    // mis-sizes the free and aborts under the testing allocator).
    pkg_abs: [:0]u8,
    spool_abs: [:0]u8,
    stub_abs: [:0]u8,
    base_env: std.process.Environ.Map,

    fn tio(self: *CacheTestCtx) Io {
        return self.threaded.io();
    }

    fn deinit(self: *CacheTestCtx, gpa: std.mem.Allocator) void {
        const io = self.threaded.io();
        self.base_env.deinit();
        gpa.free(self.stub_abs);
        gpa.free(self.spool_abs);
        gpa.free(self.pkg_abs);
        self.spool_tmp.cleanup();
        self.pkg_tmp.cleanup();
        self.ts.deinit(io);
        self.threaded.deinit();
    }
};

fn cacheTestSetup(gpa: std.mem.Allocator, stub_text: []const u8) !CacheTestCtx {
    var ctx: CacheTestCtx = undefined;
    ctx.threaded = std.Io.Threaded.init(gpa, .{});
    errdefer ctx.threaded.deinit();
    const io = ctx.threaded.io();
    ctx.ts = store_mod.test_support.openTestStore(io, .{});
    errdefer ctx.ts.deinit(io);
    ctx.pkg_tmp = std.testing.tmpDir(.{});
    errdefer ctx.pkg_tmp.cleanup();
    ctx.spool_tmp = std.testing.tmpDir(.{});
    errdefer ctx.spool_tmp.cleanup();
    try ctx.pkg_tmp.dir.writeFile(io, .{ .sub_path = "stub.sh", .data = stub_text });
    try ctx.pkg_tmp.dir.setFilePermissions(io, "stub.sh", .fromMode(0o755), .{});
    try ctx.pkg_tmp.dir.writeFile(io, .{ .sub_path = "watched.txt", .data = "v1" });
    ctx.pkg_abs = try ctx.pkg_tmp.dir.realPathFileAlloc(io, ".", gpa);
    errdefer gpa.free(ctx.pkg_abs);
    ctx.spool_abs = try ctx.spool_tmp.dir.realPathFileAlloc(io, ".", gpa);
    errdefer gpa.free(ctx.spool_abs);
    ctx.stub_abs = try ctx.pkg_tmp.dir.realPathFileAlloc(io, "stub.sh", gpa);
    errdefer gpa.free(ctx.stub_abs);
    ctx.base_env = std.process.Environ.Map.init(gpa);
    errdefer ctx.base_env.deinit();
    return ctx;
}

fn cacheTestUnit(ctx: *CacheTestCtx, package: []const u8) ScriptUnit {
    return .{
        .package = package,
        .version = "0.1.0",
        .pkg_dir_abs = ctx.pkg_abs,
        .script_rel = "stub.sh",
        .links = null,
        .features = &.{},
        .profile_name = "dev",
        .opt_level = "0",
        .debug_assertions = true,
        .target_triple = "aarch64-apple-darwin",
        .host_triple = "aarch64-apple-darwin",
        .toolchain_id = "rustc 1.99.0-nightly test",
        .rustflags_encoded = "",
        .cfg_env = &.{},
        .project_tag = "pb3-test",
    };
}

/// Builds the next run's `prev` from a finished result: takes `res` BY VALUE
// (ownership — frees `out_dir_abs`, moves `output`), recomputing the action
// key from the EXACT inputs runUnit used (bin digest + current env values;
// comment pins the mirror — if runUnit's key inputs change, this helper and
// its callers must change with it).
fn cachePrevFromResult(
    gpa: std.mem.Allocator,
    io: Io,
    unit: *const ScriptUnit,
    bin_abs: []const u8,
    base_env: *const std.process.Environ.Map,
    res: ScriptResult,
) !StoredScriptState {
    defer gpa.free(res.out_dir_abs);
    var out_moved = false;
    errdefer if (!out_moved) deinitRunOutput(gpa, &res.output);
    var bin = try Io.Dir.openFileAbsolute(io, bin_abs, .{});
    defer bin.close(io);
    const bin_digest = try store_mod.hashFile(bin, io);
    const names = res.output.rerun_if_env_changed;
    var vals: std.ArrayList(?[]const u8) = .empty;
    errdefer {
        for (vals.items) |v| if (v) |s| gpa.free(s);
        vals.deinit(gpa);
    }
    for (names) |n| {
        const cur = base_env.get(n);
        try vals.append(gpa, if (cur) |s| try gpa.dupe(u8, s) else null);
    }
    const key = try scriptActionKey(gpa, .{
        .script_bin_digest = bin_digest,
        .package_name = unit.package,
        .package_version = unit.version,
        .links = unit.links,
        .features = unit.features,
        .profile_name = unit.profile_name,
        .opt_level = unit.opt_level,
        .debug_assertions = unit.debug_assertions,
        .target_triple = unit.target_triple,
        .host_triple = unit.host_triple,
        .toolchain_id = unit.toolchain_id,
        .watched_env_values = vals.items,
        .watched_env_names = names,
        .rustflags_relevant = unit.rustflags_encoded,
    });
    const state = StoredScriptState{
        .action_key = key,
        .output = res.output,
        .manifest = res.manifest,
        .out_dir_when_generated = try gpa.dupe(u8, res.out_dir_abs),
        .started_ns = res.started_ns,
        .watched_env_values = try vals.toOwnedSlice(gpa),
    };
    out_moved = true;
    return state;
}

fn countSentinelLines(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, name: []const u8) !usize {
    const bytes = dir.readFileAlloc(io, name, gpa, .unlimited) catch |e| {
        if (e == error.FileNotFound) return 0;
        return e;
    };
    defer gpa.free(bytes);
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        if (line.len > 0) n += 1;
    }
    return n;
}

test "unchanged script does not rerun: second run is from_cache" {
    // Stub appends "ran" to $RIME_SENTINEL on every exec, then emits fixed
    // directives. Run 1 (no prev) executes; run 2 (prev, untouched
    // files/env) is from_cache and never spawns (sentinel stays 1 line);
    // run 3 (watched file rewritten) executes again (2 lines).
    const gpa = std.testing.allocator;
    var ctx = try cacheTestSetup(gpa,
        \\#!/bin/sh
        \\echo ran >> "$RIME_SENTINEL"
        \\echo 'cargo::rustc-cfg=sentinel_cfg'
        \\echo 'cargo::rerun-if-changed=watched.txt'
        \\echo 'cargo::rerun-if-env-changed=RIME_SENTINEL'
        \\
    );
    defer ctx.deinit(gpa);
    const io = ctx.tio();
    const sentinel_abs = try std.fs.path.join(gpa, &.{ ctx.pkg_abs, "sentinel" });
    defer gpa.free(sentinel_abs);
    try ctx.base_env.put("RIME_SENTINEL", sentinel_abs);
    // The seatbelt profile (macOS) allows file writes only under OUT_DIR,
    // OUT_DIR's parent (the spool tree), and $TMPDIR. The sentinel lives in
    // the package tree — outside the first two — so point TMPDIR at the
    // package dir: writing temp files under TMPDIR is exactly the allowed
    // pattern (production inherits the real TMPDIR the same way).
    try ctx.base_env.put("TMPDIR", ctx.pkg_abs);
    var err_buf: [4096]u8 = undefined;
    var err_w: Io.Writer = .fixed(&err_buf);
    const unit = cacheTestUnit(&ctx, "sentinel-pkg");

    const r1 = try runUnit(gpa, io, &ctx.ts.store, unit, ctx.stub_abs, null, ctx.spool_abs, &ctx.base_env, &err_w);
    try std.testing.expect(!r1.from_cache);
    try std.testing.expect(!r1.store_skipped);
    try std.testing.expectEqualStrings("sentinel_cfg", r1.output.cfgs[0]);
    try std.testing.expectEqual(@as(usize, 1), try countSentinelLines(gpa, io, ctx.pkg_tmp.dir, "sentinel"));
    const prev = try cachePrevFromResult(gpa, io, &unit, ctx.stub_abs, &ctx.base_env, r1);

    const r2 = try runUnit(gpa, io, &ctx.ts.store, unit, ctx.stub_abs, prev, ctx.spool_abs, &ctx.base_env, &err_w);
    try std.testing.expect(r2.from_cache);
    try std.testing.expect(!r2.store_skipped);
    try std.testing.expectEqualStrings("sentinel_cfg", r2.output.cfgs[0]);
    try std.testing.expectEqual(@as(usize, 1), try countSentinelLines(gpa, io, ctx.pkg_tmp.dir, "sentinel"));
    const prev2 = try cachePrevFromResult(gpa, io, &unit, ctx.stub_abs, &ctx.base_env, r2);

    // Rewrite the watched file with new bytes (mtime newer than the stored
    // anchor) -> the gate fires and the script runs again.
    try ctx.pkg_tmp.dir.writeFile(io, .{ .sub_path = "watched.txt", .data = "v2-new-bytes" });
    var r3 = try runUnit(gpa, io, &ctx.ts.store, unit, ctx.stub_abs, prev2, ctx.spool_abs, &ctx.base_env, &err_w);
    defer r3.deinit(gpa);
    try std.testing.expect(!r3.from_cache);
    try std.testing.expectEqual(@as(usize, 2), try countSentinelLines(gpa, io, ctx.pkg_tmp.dir, "sentinel"));
}

test "store-full ingest degrades to skipped when OUT_DIR is identical" {
    // Direct degradedOnFull coverage on a NORMAL store (no budget staging
    // — see the handler docs): the previous manifest records the same bytes
    // the live OUT_DIR holds, so the parsed output is kept with the previous
    // manifest and store_skipped = true. Spawn-free and deterministic.
    const gpa = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var ts = store_mod.test_support.openTestStore(io, .{});
    defer ts.deinit(io);
    var prev_tmp = std.testing.tmpDir(.{});
    defer prev_tmp.cleanup();
    try prev_tmp.dir.writeFile(io, .{ .sub_path = "gen.txt", .data = "payload\n" });
    const prev_abs = try prev_tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(prev_abs);
    var live_tmp = std.testing.tmpDir(.{});
    defer live_tmp.cleanup();
    try live_tmp.dir.writeFile(io, .{ .sub_path = "gen.txt", .data = "payload\n" });
    const live_abs = try live_tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(live_abs);
    var seed = try parseBuildOutput(gpa, "cargo::rerun-if-changed=build.rs\n", .{});
    defer seed.deinit(gpa);
    const prev_man = try ingestOutputs(gpa, io, &ts.store, prev_abs, &seed, &.{});
    var parsed = try parseBuildOutput(gpa, "cargo::rustc-cfg=gen_cfg\n", .{});
    defer parsed.deinit(gpa);
    var owned = try dupeRunOutput(gpa, &parsed);
    var err_buf: [4096]u8 = undefined;
    var err_w: Io.Writer = .fixed(&err_buf);
    const live_duped = try gpa.dupe(u8, live_abs);
    const unit = ScriptUnit{
        .package = "gen-pkg", .version = "0.1.0",
        .pkg_dir_abs = live_abs, .script_rel = "build.rs",
        .links = null, .features = &.{},
        .profile_name = "dev", .opt_level = "0", .debug_assertions = true,
        .target_triple = "aarch64-apple-darwin", .host_triple = "aarch64-apple-darwin",
        .toolchain_id = "rustc 1.99.0-nightly test",
        .rustflags_encoded = "", .cfg_env = &.{} , .project_tag = "pb3-test",
    };
    var r = try degradedOnFull(gpa, io, &ts.store, unit, live_duped, &owned, 999, prev_man, &err_w);
    defer r.deinit(gpa);
    try std.testing.expect(!r.from_cache);
    try std.testing.expect(r.store_skipped);
    try std.testing.expect(std.meta.eql(prev_man, r.manifest));
    try std.testing.expectEqualStrings("gen_cfg", r.output.cfgs[0]);
    try err_w.flush();
    try std.testing.expect(std.mem.indexOf(u8, err_w.buffered(), "store full during script ingest") != null);
}

test "store-full ingest fails when OUT_DIR changed" {
    // Same handler, but the live OUT_DIR differs from the previous manifest
    // (and once more with no previous manifest at all): the handler cannot
    // vouch for the live dir, so StoreFull propagates. The handler borrows
    // on its error path, so the test still owns its copies afterwards.
    const gpa = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var ts = store_mod.test_support.openTestStore(io, .{});
    defer ts.deinit(io);
    var prev_tmp = std.testing.tmpDir(.{});
    defer prev_tmp.cleanup();
    try prev_tmp.dir.writeFile(io, .{ .sub_path = "gen.txt", .data = "stale-bytes\n" });
    const prev_abs = try prev_tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(prev_abs);
    var live_tmp = std.testing.tmpDir(.{});
    defer live_tmp.cleanup();
    try live_tmp.dir.writeFile(io, .{ .sub_path = "gen.txt", .data = "payload\n" });
    const live_abs = try live_tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(live_abs);
    var seed = try parseBuildOutput(gpa, "cargo::rerun-if-changed=build.rs\n", .{});
    defer seed.deinit(gpa);
    const prev_man = try ingestOutputs(gpa, io, &ts.store, prev_abs, &seed, &.{});
    var parsed = try parseBuildOutput(gpa, "cargo::rustc-cfg=gen_cfg\n", .{});
    defer parsed.deinit(gpa);
    var owned = try dupeRunOutput(gpa, &parsed);
    errdefer deinitRunOutput(gpa, &owned);
    const live_duped = try gpa.dupe(u8, live_abs);
    errdefer gpa.free(live_duped);
    var err_buf: [4096]u8 = undefined;
    var err_w: Io.Writer = .fixed(&err_buf);
    const unit = ScriptUnit{
        .package = "gen-pkg", .version = "0.1.0",
        .pkg_dir_abs = live_abs, .script_rel = "build.rs",
        .links = null, .features = &.{},
        .profile_name = "dev", .opt_level = "0", .debug_assertions = true,
        .target_triple = "aarch64-apple-darwin", .host_triple = "aarch64-apple-darwin",
        .toolchain_id = "rustc 1.99.0-nightly test",
        .rustflags_encoded = "", .cfg_env = &.{} , .project_tag = "pb3-test",
    };
    {
        const got = degradedOnFull(gpa, io, &ts.store, unit, live_duped, &owned, 999, prev_man, &err_w);
        if (got) |*res| {
            var res_mut = res.*;
            defer res_mut.deinit(gpa);
            try std.testing.expect(false); // must not succeed on changed bytes
        } else |e| {
            try std.testing.expectEqual(error.StoreFull, e);
        }
    }
    {
        // First run under a full store (no previous manifest): also StoreFull.
        const got = degradedOnFull(gpa, io, &ts.store, unit, live_duped, &owned, 999, null, &err_w);
        if (got) |*res| {
            var res_mut = res.*;
            defer res_mut.deinit(gpa);
            try std.testing.expect(false); // must not succeed without a prev manifest
        } else |e| {
            try std.testing.expectEqual(error.StoreFull, e);
        }
    }
    gpa.free(live_duped);
    deinitRunOutput(gpa, &owned);
}

test "script state round-trips through json" {
    const gpa = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var parsed = try parseBuildOutput(gpa, "cargo::rerun-if-changed=build.rs\ncargo::rerun-if-env-changed=MY_ENV\n", .{});
    defer parsed.deinit(gpa);
    const owned = try dupeRunOutput(gpa, &parsed);
    const v1 = try gpa.dupe(u8, "1");
    const vals = try gpa.alloc(?[]const u8, 1);
    vals[0] = v1;
    const st = StoredScriptState{
        .action_key = store_mod.hashBytes("key"),
        .output = owned,
        .manifest = store_mod.hashBytes("man"),
        .out_dir_when_generated = try gpa.dupe(u8, "/prev/out"),
        .started_ns = 123456789,
        .watched_env_values = vals,
    };
    defer st.deinit(gpa);
    try writeScriptState(gpa, io, tmp.dir, "u1", &st);
    var back = (try readScriptState(gpa, io, tmp.dir, "u1")).?;
    defer back.deinit(gpa);
    try std.testing.expect(std.meta.eql(st.action_key, back.action_key));
    try std.testing.expect(std.meta.eql(st.manifest, back.manifest));
    try std.testing.expectEqualStrings(st.out_dir_when_generated, back.out_dir_when_generated);
    try std.testing.expectEqual(st.started_ns, back.started_ns);
    try std.testing.expectEqual(@as(usize, 1), back.output.rerun_if_changed.len);
    try std.testing.expectEqualStrings("build.rs", back.output.rerun_if_changed[0]);
    try std.testing.expectEqualStrings("MY_ENV", back.output.rerun_if_env_changed[0]);
    try std.testing.expectEqualStrings("1", back.watched_env_values[0].?);
    // Missing file reads as null (first run); corrupt bytes read as InvalidState.
    try std.testing.expect((try readScriptState(gpa, io, tmp.dir, "nope")) == null);
    try tmp.dir.writeFile(io, .{ .sub_path = ".fingerprint/u1-script.json", .data = "{bad json" });
    try std.testing.expectError(error.InvalidState, readScriptState(gpa, io, tmp.dir, "u1"));
}

// =====================================================================
// Task 9: validation corpus (e2e, protocol, cache-hit goldens)
// =====================================================================
//
// Validation harness contract (CARGO CONFORMANCE MANDATE): the real cargo
// binary (1.99.0-nightly) is the oracle; paths are parameterized as
// `@VALIDATION_ROOT@` (= repo `validation/` dir; tests resolve via the
// testing cwd = repo root, so literal `validation/…` relatives — the
// `@VALIDATION_ROOT@` spelling appears in committed goldens only,
// substituted at compare time). Goldens are hand-written FROM oracle output
// in the NORMALIZED shape below (absolute paths differ per machine, so
// bytes are never copied verbatim); the normalization (sort +
// `@VALIDATION_ROOT@` substitution) lives in `normalizeScriptOutput`.
// Golden-authority rule (same as M1 Task 7): if rime's output differs, fix
// rime. If the golden is wrong, regenerate FROM the oracle and re-verify
// by hand. Never edit the fixture script to make the test pass.

pub const NormalizedOutput = struct {
    package: []const u8, // borrowed from the caller
    cfgs: []const []const u8, // gpa-owned array, strings borrowed, sorted
    rerun_if_changed: []const []const u8, // gpa-owned array, strings borrowed, sorted
    link_libs: []const []const u8, // gpa-owned array, strings borrowed, sorted
    metadata: []KeyValue, // gpa-owned array, keys borrowed, values gpa-owned (root-substituted), sorted by key
    pub fn deinit(self: *const NormalizedOutput, gpa: std.mem.Allocator) void {
        gpa.free(self.cfgs);
        gpa.free(self.rerun_if_changed);
        gpa.free(self.link_libs);
        for (self.metadata) |m| gpa.free(m.value);
        gpa.free(self.metadata);
    }
};

fn sortBorrowed(gpa: std.mem.Allocator, in: []const []const u8) std.mem.Allocator.Error![]const []const u8 {
    const arr = try gpa.dupe([]const u8, in);
    errdefer gpa.free(arr);
    std.mem.sort([]const u8, arr, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    return arr;
}

pub fn normalizeScriptOutput(gpa: std.mem.Allocator, output: *const BuildOutput, package: []const u8, validation_root_abs: []const u8) std.mem.Allocator.Error!NormalizedOutput {
    const cfgs = try sortBorrowed(gpa, output.cfgs);
    errdefer gpa.free(cfgs);
    const changed = try sortBorrowed(gpa, output.rerun_if_changed);
    errdefer gpa.free(changed);
    const libs = try sortBorrowed(gpa, output.link_libs);
    errdefer gpa.free(libs);
    var md: std.ArrayList(KeyValue) = .empty;
    errdefer {
        for (md.items) |m| gpa.free(m.value);
        md.deinit(gpa);
    }
    for (output.metadata) |m| {
        const v = try std.mem.replaceOwned(u8, gpa, m.value, validation_root_abs, "@VALIDATION_ROOT@");
        errdefer gpa.free(v);
        try md.append(gpa, .{ .key = m.key, .value = v });
    }
    std.mem.sort(KeyValue, md.items, {}, struct {
        fn lessThan(_: void, a: KeyValue, b: KeyValue) bool {
            return std.mem.order(u8, a.key, b.key) == .lt;
        }
    }.lessThan);
    return .{
        .package = package,
        .cfgs = cfgs,
        .rerun_if_changed = changed,
        .link_libs = libs,
        .metadata = try md.toOwnedSlice(gpa),
    };
}

test "normalizeScriptOutput sorts and substitutes the root" {
    var out = try parseBuildOutput(std.testing.allocator, "cargo::rustc-cfg=b_cfg\ncargo::rustc-cfg=a_cfg\ncargo::metadata=root=/tmp/xyz\n", .{});
    defer out.deinit(std.testing.allocator);
    var norm = try normalizeScriptOutput(std.testing.allocator, &out, "demo-pkg", "/tmp/xyz");
    defer norm.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("demo-pkg", norm.package);
    try std.testing.expectEqualStrings("a_cfg", norm.cfgs[0]);
    try std.testing.expectEqualStrings("b_cfg", norm.cfgs[1]);
    try std.testing.expectEqualStrings("@VALIDATION_ROOT@", norm.metadata[0].value);
}

test "protocol DEP_ propagation end-to-end: sys metadata reaches app script env" {
    // Feed testdata/cargo/script-protocol/links.txt through parse +
    // propagate (links="native-sys", package="sys"), then assemble a child
    // env via scriptEnv over a hand-built base map and assert the exact
    // 4-var Task-2 sequence (DEP_ immediately followed by its CARGO_DEP_
    // sibling, emission order) lands verbatim in the child env.
    const gpa = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const text = try Io.Dir.cwd().readFileAlloc(io, "testdata/cargo/script-protocol/links.txt", gpa, .limited(1 << 20));
    defer gpa.free(text);
    var out = try parseBuildOutput(gpa, text, .{});
    defer out.deinit(gpa);
    const vars = try propagateMetadata(gpa, "native-sys", "sys", out.metadata);
    defer {
        for (vars) |v| gpa.free(v.key);
        gpa.free(vars);
    }
    try std.testing.expectEqual(@as(usize, 4), vars.len);
    try std.testing.expectEqualStrings("DEP_NATIVE_SYS_ROOT", vars[0].key);
    try std.testing.expectEqualStrings("CARGO_DEP_SYS_ROOT", vars[1].key);
    try std.testing.expectEqualStrings("DEP_NATIVE_SYS_INCLUDEDIR", vars[2].key);
    try std.testing.expectEqualStrings("CARGO_DEP_SYS_INCLUDEDIR", vars[3].key);
    var base = std.process.Environ.Map.init(gpa);
    defer base.deinit();
    var child = try scriptEnv(gpa, &base, vars);
    defer child.deinit();
    try std.testing.expectEqualStrings("/tmp/native-root", child.get("DEP_NATIVE_SYS_ROOT").?);
    try std.testing.expectEqualStrings("/tmp/native-root", child.get("CARGO_DEP_SYS_ROOT").?);
    try std.testing.expectEqualStrings("/tmp/native-root/include", child.get("DEP_NATIVE_SYS_INCLUDEDIR").?);
    try std.testing.expectEqualStrings("/tmp/native-root/include", child.get("CARGO_DEP_SYS_INCLUDEDIR").?);
}

test "links without a script maps to the M6 override error" {
    // links-override-ws/lone declares links but has no build script (and no
    // override surface): planScripts yields no units and linksWithoutScript
    // names the key for the CLI's loud `need links-override` error.
    // Negative: script-protocol/ws sys HAS a script, so nothing is missing.
    const gpa = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var err_buf: [1024]u8 = undefined;
    var err_w: Io.Writer = .fixed(&err_buf);
    var ws = try workspace_mod.discover(gpa, io, "testdata/cargo/script-protocol/links-override-ws", null);
    defer ws.deinit();
    const units = try planScripts(gpa, io, &ws, .{
        .target_triple = null, .host_triple = "aarch64-apple-darwin",
        .profile_name = "dev", .opt_level = "0", .debug_assertions = true,
        .toolchain_id = "rustc 1.99.0-nightly test", .project_tag = "pb3-test",
    }, &err_w);
    defer deinitPlanUnits(gpa, units);
    try std.testing.expectEqual(@as(usize, 0), units.len);
    const missing = try linksWithoutScript(gpa, io, &ws, units);
    defer if (missing) |m| gpa.free(m);
    try std.testing.expectEqualStrings("native-lone", missing.?);

    var ws2 = try workspace_mod.discover(gpa, io, "testdata/cargo/script-protocol/ws", null);
    defer ws2.deinit();
    const units2 = try planScripts(gpa, io, &ws2, .{
        .target_triple = null, .host_triple = "aarch64-apple-darwin",
        .profile_name = "dev", .opt_level = "0", .debug_assertions = true,
        .toolchain_id = "rustc 1.99.0-nightly test", .project_tag = "pb3-test",
    }, &err_w);
    defer deinitPlanUnits(gpa, units2);
    try std.testing.expect((try linksWithoutScript(gpa, io, &ws2, units2)) == null);
}

// ---- e2e: real rustc compiles the validation build scripts (gated: skip
// when rustc is absent), rime runs the binary through runScript, and the
// normalized directives must equal the oracle-derived goldens. The fixture
// build scripts are dependency-free, so no network or registry access is
// involved at any step; the repo validation/ trees are never built in
// place (fresh tmp copies every run, nothing committed under target/).

// Metadata stays a `std.json.Value` (object): `static.zig` cannot parse
// into a `StringHashMap` field directly, and a dedicated KeyValue-array
// shape would drift from the committed golden object form.
const GoldenOutput = struct {
    package: []const u8,
    cfgs: []const []const u8,
    rerun_if_changed: []const []const u8,
    link_libs: []const []const u8,
    metadata: std.json.Value,
};

fn expectGoldenMatches(gpa: std.mem.Allocator, norm: *const NormalizedOutput, golden_bytes: []const u8) !void {
    const parsed = std.json.parseFromSlice(GoldenOutput, gpa, golden_bytes, .{ .allocate = .alloc_always }) catch {
        return error.TestUnexpectedResult;
    };
    defer parsed.deinit();
    const want = parsed.value;
    try std.testing.expectEqualStrings(want.package, norm.package);
    try std.testing.expectEqual(want.cfgs.len, norm.cfgs.len);
    for (want.cfgs, norm.cfgs) |a, b| try std.testing.expectEqualStrings(a, b);
    try std.testing.expectEqual(want.rerun_if_changed.len, norm.rerun_if_changed.len);
    for (want.rerun_if_changed, norm.rerun_if_changed) |a, b| try std.testing.expectEqualStrings(a, b);
    try std.testing.expectEqual(want.link_libs.len, norm.link_libs.len);
    for (want.link_libs, norm.link_libs) |a, b| try std.testing.expectEqualStrings(a, b);
    if (want.metadata != .object) return error.TestUnexpectedResult;
    try std.testing.expectEqual(want.metadata.object.count(), norm.metadata.len);
    for (norm.metadata) |m| {
        const wv = want.metadata.object.get(m.key) orelse return error.TestUnexpectedResult;
        if (wv != .string) return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(wv.string, m.value);
    }
}

fn rustcBin(gpa: std.mem.Allocator, io: Io) !?[]u8 {
    // Bare argv[0] resolution goes through the toolchain helper (repo rule);
    // a missing rustc is SkipZigTest, never a failure.
    return toolchain_mod.resolveBinPath(gpa, io, "rustc") catch null;
}

/// Forwards the handful of parent vars a toolchain child needs.
/// `std.process.spawn` WITHOUT `environ_map` starts the child with an empty
/// environment (no PATH/HOME/SDKROOT), so even a present rustc fails when
/// its linker driver looks up `cc`. There is no whole-env getter in 0.16
/// (verified: no getEnvironMap), so forward per-key via `std.c.getenv`
/// (cli.zig precedent) — only what compilation needs, nothing more.
fn forwardParentEnv(gpa: std.mem.Allocator, map: *std.process.Environ.Map, names: []const []const u8) std.mem.Allocator.Error!void {
    for (names) |name| {
        const zname = try gpa.dupeZ(u8, name);
        defer gpa.free(zname);
        if (std.c.getenv(zname)) |z| try map.put(name, std.mem.span(z));
    }
}

const toolchain_env_names = [_][]const u8{ "PATH", "DEVELOPER_DIR", "SDKROOT", "TMPDIR", "HOME" };
const cargo_env_names = [_][]const u8{ "PATH", "HOME", "CARGO_HOME", "RUSTUP_HOME", "RUSTC", "DEVELOPER_DIR", "SDKROOT", "TMPDIR" };

fn e2eScriptOutputMatchesGolden(gpa: std.mem.Allocator, io: Io, build_rs_repo_rel: []const u8, package: []const u8, golden_repo_rel: []const u8) !void {
    const rustc = (try rustcBin(gpa, io)) orelse return error.SkipZigTest;
    defer gpa.free(rustc);
    var pkg_tmp = std.testing.tmpDir(.{});
    defer pkg_tmp.cleanup();
    const src_bytes = try Io.Dir.cwd().readFileAlloc(io, build_rs_repo_rel, gpa, .limited(1 << 20));
    defer gpa.free(src_bytes);
    try pkg_tmp.dir.writeFile(io, .{ .sub_path = "build.rs", .data = src_bytes });
    // A Cargo.toml beside the script: only its PATH is observed (as
    // CARGO_MANIFEST_PATH); content is irrelevant to directive capture.
    try pkg_tmp.dir.writeFile(io, .{ .sub_path = "Cargo.toml", .data = "[package]\nname = \"e2e\"\nversion = \"0.1.0\"\n" });
    const src_abs = try pkg_tmp.dir.realPathFileAlloc(io, "build.rs", gpa);
    defer gpa.free(src_abs);
    const bin_abs = try pkg_tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(bin_abs);
    const bin_path = try std.fs.path.join(gpa, &.{ bin_abs, "build-script-test" });
    defer gpa.free(bin_path);
    const pkg_abs = try pkg_tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(pkg_abs);
    const out_abs = try std.fs.path.join(gpa, &.{ pkg_abs, "out" });
    defer gpa.free(out_abs);
    const manifest_path = try std.fs.path.join(gpa, &.{ pkg_abs, "Cargo.toml" });
    defer gpa.free(manifest_path);
    // Compile the script with the real toolchain (a compile FAILURE here is
    // a genuine red: the fixture script is trivial and dependency-free).
    // The child gets a forwarded parent env (PATH for `cc`, SDKROOT/ TMPDIR
    // for the linker): an empty env fails the link even with rustc present.
    var compile_env = std.process.Environ.Map.init(gpa);
    defer compile_env.deinit();
    try forwardParentEnv(gpa, &compile_env, &toolchain_env_names);
    var child = try std.process.spawn(io, .{
        .argv = &.{ rustc, "--edition=2021", src_abs, "-o", bin_path },
        .environ_map = &compile_env,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);
    var mr_buf: std.Io.File.MultiReader.Buffer(2) = undefined;
    var mr: std.Io.File.MultiReader = undefined;
    mr.init(gpa, io, mr_buf.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer mr.deinit();
    while (mr.fill(4096, .none)) |_| {} else |e| if (e != error.EndOfStream) return e;
    const term = try child.wait(io);
    try std.testing.expect(term == .exited and term.exited == 0);

    var tstore = store_mod.test_support.openTestStore(io, .{});
    defer tstore.deinit(io);
    var base_env = std.process.Environ.Map.init(gpa);
    defer base_env.deinit();
    var err_buf: [4096]u8 = undefined;
    var err_w: Io.Writer = .fixed(&err_buf);
    var diag: [2048]u8 = undefined;
    var diag_len: usize = 0;
    var res = try runScript(gpa, io, &tstore.store, .{
        .base_env = &base_env,
        .script_bin_abs = bin_path,
        .pkg_dir_abs = pkg_abs,
        .out_dir_abs = out_abs,
        .out_dir_when_generated = null,
        .manifest_dir = pkg_abs,
        .manifest_path = manifest_path,
        .links = null,
        .features = &.{},
        .target_triple = "aarch64-apple-darwin",
        .host_triple = "aarch64-apple-darwin",
        .profile_name = "debug",
        .opt_level = "0",
        .debug_assertions = true,
        .rustc_abs = rustc,
        .encoded_rustflags = "",
        .dep_env = &.{},
        .cfg_env = &.{},
        .stderr = &err_w,
    }, &diag, &diag_len);
    defer deinitRunOutput(gpa, &res.output);
    var norm = try normalizeScriptOutput(gpa, &res.output, package, pkg_abs);
    defer norm.deinit(gpa);
    const golden = try Io.Dir.cwd().readFileAlloc(io, golden_repo_rel, gpa, .limited(1 << 20));
    defer gpa.free(golden);
    try expectGoldenMatches(gpa, &norm, golden);
}

test "e2e basic-workspace script output matches oracle golden" {
    // Spawn-capable io: compiling + running needs a real Threaded pool.
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    try e2eScriptOutputMatchesGolden(
        std.testing.allocator,
        threaded.io(),
        "validation/basic-workspace/crates/core-lib/build.rs",
        "core-lib",
        "validation/basic-workspace/golden.script-output.json",
    );
}

test "e2e full-manifest script output matches oracle golden" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    try e2eScriptOutputMatchesGolden(
        std.testing.allocator,
        threaded.io(),
        "validation/full-manifest/build.rs",
        "full-manifest",
        "validation/full-manifest/golden.script-output.json",
    );
}

test "cache-hit: validation-level runUnit over a full-manifest copy" {
    // Two consecutive runUnit calls over a tmp copy of
    // validation/full-manifest (Cargo.toml + build.rs only; the committed
    // target/ dir is never touched) with no changes between them: the
    // second is from_cache, and its normalized output still matches the
    // committed golden.
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tstore = store_mod.test_support.openTestStore(io, .{});
    defer tstore.deinit(io);
    var pkg_tmp = std.testing.tmpDir(.{});
    defer pkg_tmp.cleanup();
    var spool_tmp = std.testing.tmpDir(.{});
    defer spool_tmp.cleanup();
    for ([_][]const u8{ "validation/full-manifest/Cargo.toml", "validation/full-manifest/build.rs" }) |rel| {
        const bytes = try Io.Dir.cwd().readFileAlloc(io, rel, gpa, .limited(1 << 20));
        defer gpa.free(bytes);
        const base = std.fs.path.basename(rel);
        try pkg_tmp.dir.writeFile(io, .{ .sub_path = base, .data = bytes });
    }
    // The "compiled script" is a stub emitting the fixture's exact
    // directives (M4 owns real compilation). Freshness is anchored by a
    // Task-3 env watch, NOT a file watch: NormalizedOutput (and the golden)
    // carry rerun_if_changed but no rerun_if_env_changed field, so the
    // watch directive below leaves the golden comparison bit-exact while
    // still engaging the new-style gate (empty changed + non-empty env is
    // new-style; only both-empty falls back to OldStyleFallback).
    try pkg_tmp.dir.writeFile(io, .{ .sub_path = "stub.sh", .data = "#!/bin/sh\necho 'cargo::rustc-check-cfg=cfg(has_build_script)'\necho 'cargo::rustc-cfg=has_build_script'\necho 'cargo::rerun-if-env-changed=RIME_VALIDATION_ANCHOR'\n" });
    try pkg_tmp.dir.setFilePermissions(io, "stub.sh", .fromMode(0o755), .{});
    const pkg_abs = try pkg_tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(pkg_abs);
    const spool_abs = try spool_tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(spool_abs);
    const stub_abs = try pkg_tmp.dir.realPathFileAlloc(io, "stub.sh", gpa);
    defer gpa.free(stub_abs);
    var base_env = std.process.Environ.Map.init(gpa);
    defer base_env.deinit();
    // Stable env-watch value: identical across both runs, so the gate
    // stays fresh and the action key stays stable.
    try base_env.put("RIME_VALIDATION_ANCHOR", "1");
    var err_buf: [4096]u8 = undefined;
    var err_w: Io.Writer = .fixed(&err_buf);
    const unit = ScriptUnit{
        .package = "full-manifest", .version = "0.3.1",
        .pkg_dir_abs = pkg_abs, .script_rel = "build.rs",
        .links = null, .features = &.{},
        .profile_name = "dev", .opt_level = "0", .debug_assertions = true,
        .target_triple = "aarch64-apple-darwin", .host_triple = "aarch64-apple-darwin",
        .toolchain_id = "rustc 1.99.0-nightly test",
        .rustflags_encoded = "", .cfg_env = &.{}, .project_tag = "pb3-test",
    };
    const r1 = try runUnit(gpa, io, &tstore.store, unit, stub_abs, null, spool_abs, &base_env, &err_w);
    try std.testing.expect(!r1.from_cache);
    const prev = try cachePrevFromResult(gpa, io, &unit, stub_abs, &base_env, r1);
    var r2 = try runUnit(gpa, io, &tstore.store, unit, stub_abs, prev, spool_abs, &base_env, &err_w);
    defer r2.deinit(gpa);
    try std.testing.expect(r2.from_cache);
    var norm = try normalizeScriptOutput(gpa, &r2.output, "full-manifest", pkg_abs);
    defer norm.deinit(gpa);
    const golden = try Io.Dir.cwd().readFileAlloc(io, "validation/full-manifest/golden.script-output.json", gpa, .limited(1 << 20));
    defer gpa.free(golden);
    try expectGoldenMatches(gpa, &norm, golden);
}

// Oracle conformance (opt-in only): with RIME_CARGO_ORACLE=1 AND a working
// cargo, rebuild each validation project from a tmp copy (never in-repo,
// --target-dir inside tmp, --offline so no network) and assert cargo's own
// recorded script stdout normalizes to the same committed goldens. ANY
// environmental failure (no cargo, offline resolution impossible, layout
// drift in cargo's build dir) is SkipZigTest: the oracle is advisory, never
// a false red. The hermetic e2e tests above (rustc-direct) are the CI
// authority; this test pins the goldens to the oracle where possible.

fn scriptOracleEnabled() bool {
    // Same shape as the fetch.zig oracle gate: std.c.getenv (no env-getter
    // exists in 0.16), explicit opt-in, never on by default.
    const v = std.c.getenv("RIME_CARGO_ORACLE") orelse return false;
    return std.mem.eql(u8, std.mem.span(v), "1");
}

fn copyTreeNoTarget(gpa: std.mem.Allocator, io: Io, src_dir: Io.Dir, dst_dir: Io.Dir) !void {
    var it = src_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) {
            // Never copy build residue (or it would pin stale oracle
            // output); the oracle rebuilds from scratch in tmp.
            if (std.mem.eql(u8, entry.name, "target")) continue;
            try dst_dir.createDirPath(io, entry.name);
            var s = try src_dir.openDir(io, entry.name, .{ .iterate = true });
            defer s.close(io);
            var d = try dst_dir.openDir(io, entry.name, .{ .iterate = true });
            defer d.close(io);
            try copyTreeNoTarget(gpa, io, s, d);
        } else if (entry.kind == .file) {
            const bytes = try src_dir.readFileAlloc(io, entry.name, gpa, .unlimited);
            defer gpa.free(bytes);
            try dst_dir.writeFile(io, .{ .sub_path = entry.name, .data = bytes });
        }
    }
}

fn oracleScriptStdout(gpa: std.mem.Allocator, io: Io, target_dir_abs: []const u8, package: []const u8) error{ SkipZigTest, OutOfMemory }![]u8 {
    // Cargo records each script's stdout per unit. Layout is
    // version-dependent: this oracle (1.99.0-nightly) nests
    // `target/<t>/build/<pkg>/<hash>/run/stdout`; older cargo used a flat
    // `build/<pkg>-<hash>/output` file. Try the nested layout first, then
    // the flat one; any layout drift is environmental (SkipZigTest), never
    // a failure. Within one layout the FIRST match wins (a package has one
    // build-script unit per profile here).
    const build_abs = std.fs.path.join(gpa, &.{ target_dir_abs, "debug", "build" }) catch return error.OutOfMemory;
    defer gpa.free(build_abs);
    var build = Io.Dir.openDirAbsolute(io, build_abs, .{ .iterate = true }) catch return error.SkipZigTest;
    defer build.close(io);
    const cands = [_][]const u8{ "run/stdout", "output" };
    var it = build.iterate();
    while (it.next(io) catch return error.SkipZigTest) |e| {
        if (e.kind != .directory) continue;
        // Nested layout: build/<pkg>/<hash>/…
        if (std.mem.eql(u8, e.name, package)) {
            const pkg_abs = std.fs.path.join(gpa, &.{ build_abs, e.name }) catch return error.OutOfMemory;
            defer gpa.free(pkg_abs);
            var pkg = Io.Dir.openDirAbsolute(io, pkg_abs, .{ .iterate = true }) catch continue;
            var it2 = pkg.iterate();
            while (it2.next(io) catch break) |h| {
                if (h.kind != .directory) continue;
                for (cands) |rel| {
                    const full = std.fs.path.join(gpa, &.{ pkg_abs, h.name, rel }) catch return error.OutOfMemory;
                    defer gpa.free(full);
                    const bytes = Io.Dir.cwd().readFileAlloc(io, full, gpa, .unlimited) catch continue;
                    pkg.close(io);
                    return bytes;
                }
            }
            pkg.close(io);
            continue;
        }
        // Flat layout: build/<pkg>-<hash>/…
        if (std.mem.startsWith(u8, e.name, package) and e.name.len > package.len and e.name[package.len] == '-') {
            for (cands) |rel| {
                const full = std.fs.path.join(gpa, &.{ build_abs, e.name, rel }) catch return error.OutOfMemory;
                defer gpa.free(full);
                const bytes = Io.Dir.cwd().readFileAlloc(io, full, gpa, .unlimited) catch continue;
                return bytes;
            }
        }
    }
    return error.SkipZigTest;
}

fn oracleProjectMatchesGolden(gpa: std.mem.Allocator, io: Io, project_repo_rel: []const u8, package: []const u8, golden_repo_rel: []const u8) !void {
    const cargo = (toolchain_mod.resolveBinPath(gpa, io, "cargo") catch null) orelse return error.SkipZigTest;
    defer gpa.free(cargo);
    var ws_tmp = std.testing.tmpDir(.{});
    defer ws_tmp.cleanup();
    // project_repo_rel is repo-relative; resolve it against the test cwd.
    const cwd = std.process.currentPathAlloc(io, gpa) catch return error.SkipZigTest;
    defer gpa.free(cwd);
    const src_abs = std.fs.path.join(gpa, &.{ cwd, project_repo_rel }) catch return error.SkipZigTest;
    defer gpa.free(src_abs);
    var src_abs_dir = Io.Dir.openDirAbsolute(io, src_abs, .{ .iterate = true }) catch return error.SkipZigTest;
    defer src_abs_dir.close(io);
    try copyTreeNoTarget(gpa, io, src_abs_dir, ws_tmp.dir);
    const ws_abs = try ws_tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(ws_abs);
    const target_abs = try std.fs.path.join(gpa, &.{ ws_abs, "target" });
    defer gpa.free(target_abs);
    const manifest_abs = try std.fs.path.join(gpa, &.{ ws_abs, "Cargo.toml" });
    defer gpa.free(manifest_abs);
    // Cargo resolves its registry cache via HOME/CARGO_HOME and shells out
    // to rustc (PATH) + the linker (SDKROOT): forward the parent env like
    // the e2e compile above. An empty env is an environmental skip.
    var cargo_env = std.process.Environ.Map.init(gpa);
    defer cargo_env.deinit();
    try forwardParentEnv(gpa, &cargo_env, &cargo_env_names);
    var child = std.process.spawn(io, .{
        .argv = &.{ cargo, "build", "--offline", "--manifest-path", manifest_abs, "--target-dir", target_abs },
        .environ_map = &cargo_env,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch return error.SkipZigTest;
    defer child.kill(io);
    var mr_buf: std.Io.File.MultiReader.Buffer(2) = undefined;
    var mr: std.Io.File.MultiReader = undefined;
    mr.init(gpa, io, mr_buf.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer mr.deinit();
    while (mr.fill(4096, .none)) |_| {} else |e| if (e != error.EndOfStream) return error.SkipZigTest;
    const term = child.wait(io) catch return error.SkipZigTest;
    if (term != .exited or term.exited != 0) {
        std.debug.print("oracle cargo build --offline failed in tmp copy; skipping (environmental)\n", .{});
        return error.SkipZigTest;
    }
    const stdout_bytes = try oracleScriptStdout(gpa, io, target_abs, package);
    defer gpa.free(stdout_bytes);
    var parsed = try parseBuildOutput(gpa, stdout_bytes, .{});
    defer parsed.deinit(gpa);
    var norm = try normalizeScriptOutput(gpa, &parsed, package, ws_abs);
    defer norm.deinit(gpa);
    const golden = try Io.Dir.cwd().readFileAlloc(io, golden_repo_rel, gpa, .limited(1 << 20));
    defer gpa.free(golden);
    try expectGoldenMatches(gpa, &norm, golden);
}

test "oracle cargo script outputs match goldens when oracle enabled" {
    if (!scriptOracleEnabled()) return error.SkipZigTest;
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = std.testing.allocator;
    try oracleProjectMatchesGolden(gpa, io, "validation/basic-workspace", "core-lib", "validation/basic-workspace/golden.script-output.json");
    try oracleProjectMatchesGolden(gpa, io, "validation/full-manifest", "full-manifest", "validation/full-manifest/golden.script-output.json");
}

/// First conflicting `links` pair across workspace members (two DIFFERENT
/// packages sharing one links key), all strings duped (caller deinits via
/// `deinit`), or null when clean. The CLI maps planScripts' DuplicateLinks
/// to cargo's exit-101 message with this pair: planScripts returns the bare
/// error by M4 contract, so the names live here, parsed once per member
/// (error path only — the happy path parses in planScripts).
pub const LinksConflictPair = struct {
    links: []u8,
    a_package: []u8,
    a_version: []u8,
    b_package: []u8,
    b_version: []u8,
    pub fn deinit(self: *const LinksConflictPair, gpa: std.mem.Allocator) void {
        gpa.free(self.links);
        gpa.free(self.a_package);
        gpa.free(self.a_version);
        gpa.free(self.b_package);
        gpa.free(self.b_version);
    }
};

pub fn findLinksConflict(
    gpa: std.mem.Allocator,
    io: Io,
    ws: *const workspace_mod.Workspace,
) (std.mem.Allocator.Error || Io.Dir.ReadFileAllocError || manifest_mod.ManifestSurfaceError)!?LinksConflictPair {
    // `seen` entries borrow member names/versions (workspace-owned, outlive
    // the call) but OWN their links (each member surface arena dies per
    // iteration, so compare eagerly and dupe on the way in).
    var seen: std.ArrayList(struct { links: []u8, package: []const u8, version: []const u8 }) = .empty;
    defer {
        for (seen.items) |s| gpa.free(s.links);
        seen.deinit(gpa);
    }
    for (ws.members) |*m| {
        const manifest_abs = try std.fs.path.join(gpa, &.{ m.dir, "Cargo.toml" });
        defer gpa.free(manifest_abs);
        const text = try Io.Dir.cwd().readFileAlloc(io, manifest_abs, gpa, .limited(1 << 20));
        defer gpa.free(text);
        var ext = try manifest_mod.parseManifestExt(gpa, text, manifest_abs);
        defer ext.deinit();
        const links = ext.links orelse continue;
        for (seen.items) |s| {
            if (std.mem.eql(u8, s.links, links) and !std.mem.eql(u8, s.package, m.name)) {
                var pair: LinksConflictPair = undefined;
                pair.links = try gpa.dupe(u8, links);
                errdefer gpa.free(pair.links);
                pair.a_package = try gpa.dupe(u8, s.package);
                errdefer gpa.free(pair.a_package);
                pair.a_version = try gpa.dupe(u8, s.version);
                errdefer gpa.free(pair.a_version);
                pair.b_package = try gpa.dupe(u8, m.name);
                errdefer gpa.free(pair.b_package);
                pair.b_version = try gpa.dupe(u8, m.version);
                return pair;
            }
        }
        try seen.append(gpa, .{ .links = try gpa.dupe(u8, links), .package = m.name, .version = m.version });
    }
    return null;
}

test "findLinksConflict names both packages" {
    const gpa = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var ws = try workspace_mod.discover(gpa, io, "testdata/cargo/script-protocol/links-conflict", null);
    defer ws.deinit();
    const pair = (try findLinksConflict(gpa, io, &ws)).?;
    defer pair.deinit(gpa);
    try std.testing.expectEqualStrings("native-dup", pair.links);
    try std.testing.expectEqualStrings("a", pair.a_package);
    try std.testing.expectEqualStrings("1.0.0", pair.a_version);
    try std.testing.expectEqualStrings("b", pair.b_package);
    try std.testing.expectEqualStrings("2.0.0", pair.b_version);
    // And the no-script ws fixture is conflict-free.
    var ws2 = try workspace_mod.discover(gpa, io, "testdata/cargo/script-protocol/ws", null);
    defer ws2.deinit();
    try std.testing.expect((try findLinksConflict(gpa, io, &ws2)) == null);
}
