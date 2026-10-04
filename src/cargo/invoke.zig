//! rustc invocation construction (M4 Task 6): cargo-shaped argv per unit
//! (`mod.rs::build_base_args` + `build_deps_args` order; comments cite the
//! cargo role each step plays).
//!
//! `RUSTFLAGS` is NOT passed on the command line — it enters the key via
//! the fingerprint's `rustflags_hash` and is inherited from the process env
//! (cargo reads it from config/env at arg-build time; rime inherits +
//! hashes).
//!
//! Ownership: EVERY argv element is a gpa-owned dup (borrowed inputs are
//! copied, so the invocation never aliases the `Toolchain`/`Unit`/caller
//! strings); `deinit` frees each element, both slices, and `dep_info_path`.
//! `out_dir` borrows the caller's spool dir (also present as an argv value
//! copy). `dep_info_path` (`out_dir/<target>.d`) is gpa-owned.

const std = @import("std");
const driver_mod = @import("driver.zig");
const profile_mod = @import("profile.zig");
const toolchain_mod = @import("toolchain.zig");

const Unit = driver_mod.Unit;
const Profile = profile_mod.Profile;
const Toolchain = toolchain_mod.Toolchain;

pub const InvokeError = error{ OutOfMemory } || std.mem.Allocator.Error;

pub const DepLib = struct {
    extern_name: []const u8, // borrowed from Unit.deps
    rlib_path: []const u8, // absolute spool path of the dep artifact (borrowed)
    is_rmeta: bool, // check-mode deps pass .rmeta (rlib_path already points at it)
};

pub const RustcInvocation = struct {
    argv: []const []const u8, // gpa-owned; argv[0] = rustc path (duped from Toolchain)
    env_extra: []const []const u8, // gpa-owned "K=V" additions (RUSTC_BOOTSTRAP=1 for abort)
    out_dir: []const u8, // borrowed spool unit dir (also present in argv as a dup)
    dep_info_path: []const u8, // gpa-owned: out_dir + "/<target>.d"

    pub fn deinit(self: *RustcInvocation, gpa: std.mem.Allocator) void {
        for (self.argv) |s| gpa.free(s);
        gpa.free(self.argv);
        for (self.env_extra) |s| gpa.free(s);
        gpa.free(self.env_extra);
        gpa.free(self.dep_info_path);
    }
};

/// Builds the cargo-shaped rustc argv for one unit. Codegen flags come from
/// the `profile` param (the pipeline may overlay workspace `[profile.*]`
/// onto `unit.profile` before calling); features from `unit`. `crate_root`
/// is the absolute crate-root source file (last argv element — rustc's
/// required source operand). See the step comments for the cargo pins.
pub fn buildRustcArgs(
    gpa: std.mem.Allocator,
    tc: *const Toolchain,
    unit: *const Unit,
    profile: Profile,
    deps: []const DepLib,
    out_dir: []const u8,
    crate_root: []const u8,
    edition_override: ?[]const u8,
) InvokeError!RustcInvocation {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (argv.items) |s| gpa.free(s);
        argv.deinit(gpa);
    }
    var env: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (env.items) |s| gpa.free(s);
        env.deinit(gpa);
    }

    // argv[0]: the rustc binary.
    try argv.append(gpa, try gpa.dupe(u8, tc.rustc_path));
    // 1. --crate-name <extern_name_of_self> (unit_graph.rs extern_crate_name).
    try argv.append(gpa, try gpa.dupe(u8, "--crate-name"));
    // externName only fails on OOM in practice (dup + byte map); the other
    // DriverError arms are unreachable here.
    try argv.append(gpa, driver_mod.externName(gpa, unit.target_name) catch return InvokeError.OutOfMemory);
    // 2. --edition=<edition> (Edition::cmd_edition_arg role; `=` keeps one
    // argv element for the normalizer).
    try argv.append(gpa, try std.fmt.allocPrint(gpa, "--edition={s}", .{edition_override orelse unit.edition}));
    // 3. --crate-type=<t> per crate_types (rustc_crate_types role).
    for (unit.crate_types) |t| {
        try argv.append(gpa, try std.fmt.allocPrint(gpa, "--crate-type={s}", .{t}));
    }
    // 4. --emit ladder (build_base_args): check → metadata only; lib-build
    // → metadata+link; bin-build → link only. (M4 omits cargo's
    // -Z embed-metadata=no nightly arm and the requires_upstream_objects
    // split — no dylib/proc-macro units in scope, so lib-vs-bin coincides.)
    const emit: []const u8 = if (unit.mode == .check)
        "--emit=dep-info,metadata"
    else if (unit.kind == .lib)
        "--emit=dep-info,metadata,link"
    else
        "--emit=dep-info,link";
    try argv.append(gpa, try gpa.dupe(u8, emit));
    // 5. -C prefer-dynamic for host-kind units (M5 build-script/proc-macro
    // hook; cargo ALSO fires it for contains_dylib && !is_primary_package —
    // M4 has no dylib/non-primary units so the conditions coincide).
    if (unit.compile_kind == .host) {
        try argv.append(gpa, try gpa.dupe(u8, "-C"));
        try argv.append(gpa, try gpa.dupe(u8, "prefer-dynamic"));
    }
    // 6. Profile -C flags.
    if (!std.mem.eql(u8, profile.opt_level, "0")) {
        try argv.append(gpa, try gpa.dupe(u8, "-C"));
        try argv.append(gpa, try std.fmt.allocPrint(gpa, "opt-level={s}", .{profile.opt_level}));
    }
    // Numeric debuginfo form (cargo spells -C debuginfo=full for 2 — same
    // meaning; normalize in oracle argv diffs).
    if (profile.debug_info > 0) {
        try argv.append(gpa, try gpa.dupe(u8, "-C"));
        try argv.append(gpa, try std.fmt.allocPrint(gpa, "debuginfo={d}", .{profile.debug_info}));
    }
    // debug-assertions ALWAYS (cargo elides it when implied by opt-level;
    // rime always emits it — expected oracle argv diff, Task-12 normalizes).
    try argv.append(gpa, try gpa.dupe(u8, "-C"));
    try argv.append(gpa, try gpa.dupe(u8, if (profile.debug_assertions) "debug-assertions=on" else "debug-assertions=off"));
    // overflow-checks ONLY when it differs from debug_assertions
    // (mod.rs:1367-1385 differs-rule).
    if (profile.overflow_checks != profile.debug_assertions) {
        try argv.append(gpa, try gpa.dupe(u8, "-C"));
        try argv.append(gpa, try gpa.dupe(u8, if (profile.overflow_checks) "overflow-checks=on" else "overflow-checks=off"));
    }
    if (profile.panic_strategy == .abort) {
        try argv.append(gpa, try gpa.dupe(u8, "-C"));
        try argv.append(gpa, try gpa.dupe(u8, "panic=abort"));
        // build_base_args ImmediateAbort rule: bootstrapping rustc past its
        // stability gate for -C panic=abort on stable-adjacent toolchains.
        try env.append(gpa, try gpa.dupe(u8, "RUSTC_BOOTSTRAP=1"));
    }
    if (profile.lto_off) {
        try argv.append(gpa, try gpa.dupe(u8, "-C"));
        try argv.append(gpa, try gpa.dupe(u8, "lto=off"));
        try argv.append(gpa, try gpa.dupe(u8, "-C"));
        try argv.append(gpa, try gpa.dupe(u8, "embed-bitcode=no"));
    }
    // 7. --error-format=json always (rime only speaks JSON diagnostics;
    // add_error_format_and_color role). Deliberately OMITS cargo's
    // --json=diagnostic-rendered-ansi,artifacts,future-incompat (envelope
    // detection is line-based on error-format=json output) — normalize in
    // oracle diffs.
    try argv.append(gpa, try gpa.dupe(u8, "--error-format=json"));
    // 8. --out-dir <out_dir>.
    try argv.append(gpa, try gpa.dupe(u8, "--out-dir"));
    try argv.append(gpa, try gpa.dupe(u8, out_dir));
    // 9. -L dependency=<deps_dir> (lib_search_paths role; all dep rlibs
    // live in one spool deps dir — dirname of the first dep artifact).
    if (deps.len > 0) {
        try argv.append(gpa, try gpa.dupe(u8, "-L"));
        try argv.append(gpa, try std.fmt.allocPrint(gpa, "dependency={s}", .{std.fs.path.dirname(deps[0].rlib_path) orelse "."}));
    }
    // 10. --extern <name>=<rlib_path> per dep (build_deps_args role).
    for (deps) |d| {
        try argv.append(gpa, try gpa.dupe(u8, "--extern"));
        try argv.append(gpa, try std.fmt.allocPrint(gpa, "{s}={s}", .{ d.extern_name, d.rlib_path }));
    }
    // 11. --cfg feature="f" per sorted feature (build_base_args feature
    // loop; two argv elements like cargo).
    for (unit.features_sorted) |f| {
        try argv.append(gpa, try gpa.dupe(u8, "--cfg"));
        try argv.append(gpa, try std.fmt.allocPrint(gpa, "feature=\"{s}\"", .{f}));
    }
    // 12. Crate-root source file LAST (rustc's source operand).
    try argv.append(gpa, try gpa.dupe(u8, crate_root));

    const dep_info_path = try std.fmt.allocPrint(gpa, "{s}/{s}.d", .{ out_dir, unit.target_name });
    errdefer gpa.free(dep_info_path);
    return .{
        .argv = try argv.toOwnedSlice(gpa),
        .env_extra = try env.toOwnedSlice(gpa),
        .out_dir = out_dir,
        .dep_info_path = dep_info_path,
    };
}

fn hasArg(argv: []const []const u8, needle: []const u8) bool {
    for (argv) |a| if (std.mem.eql(u8, a, needle)) return true;
    return false;
}

// Runtime helper (not a const): BLAKE3 compress is runtime-only in 0.16,
// so hashBytes cannot run at comptime inside a const initializer.
fn tcStub() toolchain_mod.Toolchain {
    return .{
        .rustc_path = "rustc",
        .version = "1.99.0",
        .host_target = "aarch64-apple-darwin",
        .commit_hash = "stub",
        .sysroot = "/nonexistent",
        .digest = @import("store").hashBytes("stub"),
    };
}

test "invoke builds cargo-shaped argv for a lib" {
    const unit = driver_mod.Unit{
        .pkg_name = "serde",
        .version = "1.0.0",
        .target_name = "serde",
        .kind = .lib,
        .edition = "2021",
        .crate_types = &.{"rlib"},
        .profile = profile_mod.profileFor("dev"),
        .features_sorted = &.{"std"},
        .target_triple = "aarch64-apple-darwin",
        .compile_kind = .target,
        .mode = .build,
        .src_path = "/ws/serde",
        .deps = &.{},
    };
    var tc = tcStub();
    var inv = try buildRustcArgs(std.testing.allocator, &tc, &unit, unit.profile, &.{}, "/spool/serde", "/ws/serde/src/lib.rs", null);
    defer inv.deinit(std.testing.allocator);
    // argv[0] rustc, then --crate-name serde, --edition=2021,
    // --crate-type=rlib, --emit=dep-info,metadata,link, …,
    // --error-format=json, crate root last.
    try std.testing.expectEqualStrings("--crate-name", inv.argv[1]);
    try std.testing.expectEqualStrings("serde", inv.argv[2]);
    try std.testing.expectEqualStrings("--edition=2021", inv.argv[3]);
    try std.testing.expectEqualStrings("--crate-type=rlib", inv.argv[4]);
    try std.testing.expectEqualStrings("--emit=dep-info,metadata,link", inv.argv[5]);
    try std.testing.expect(hasArg(inv.argv, "--error-format=json"));
    try std.testing.expectEqualStrings("/ws/serde/src/lib.rs", inv.argv[inv.argv.len - 1]);
    // Dev profile: no opt-level flag (it IS "0"), debuginfo=2 present,
    // both assertions flags on, feature cfg pair present, out-dir pair.
    try std.testing.expect(!hasArg(inv.argv, "opt-level=0"));
    try std.testing.expect(hasArg(inv.argv, "debuginfo=2"));
    try std.testing.expect(hasArg(inv.argv, "debug-assertions=on"));
    try std.testing.expect(!hasArg(inv.argv, "overflow-checks=on")); // differs-rule: elided when equal
    try std.testing.expect(hasArg(inv.argv, "--cfg"));
    try std.testing.expect(hasArg(inv.argv, "feature=\"std\""));
    try std.testing.expect(hasArg(inv.argv, "--out-dir"));
    try std.testing.expect(hasArg(inv.argv, "/spool/serde"));
    try std.testing.expectEqualStrings("/spool/serde/serde.d", inv.dep_info_path);
    try std.testing.expectEqual(@as(usize, 0), inv.env_extra.len);
}

test "check mode emits metadata only" {
    var unit = driver_mod.Unit{
        .pkg_name = "serde",
        .version = "1.0.0",
        .target_name = "serde",
        .kind = .lib,
        .edition = "2021",
        .crate_types = &.{"rlib"},
        .profile = profile_mod.profileFor("dev"),
        .features_sorted = &.{},
        .target_triple = "aarch64-apple-darwin",
        .compile_kind = .target,
        .mode = .check,
        .src_path = "/ws/serde",
        .deps = &.{},
    };
    var tc = tcStub();
    var inv = try buildRustcArgs(std.testing.allocator, &tc, &unit, unit.profile, &.{}, "/spool/serde", "/ws/serde/src/lib.rs", null);
    defer inv.deinit(std.testing.allocator);
    try std.testing.expect(hasArg(inv.argv, "--emit=dep-info,metadata"));
    try std.testing.expect(!hasArg(inv.argv, "--emit=dep-info,metadata,link"));
}

test "bin units emit link-only and host units prefer dynamic" {
    var unit = driver_mod.Unit{
        .pkg_name = "tool",
        .version = "0.1.0",
        .target_name = "tool",
        .kind = .bin,
        .edition = "2021",
        .crate_types = &.{"bin"},
        .profile = profile_mod.releaseProfile(),
        .features_sorted = &.{},
        .target_triple = "aarch64-apple-darwin",
        .compile_kind = .host,
        .mode = .build,
        .src_path = "/ws/tool",
        .deps = &.{},
    };
    const dep_libs = [_]DepLib{.{ .extern_name = "b", .rlib_path = "/spool/deps/libb-0123456789abcdef.rlib", .is_rmeta = false }};
    var tc = tcStub();
    var inv = try buildRustcArgs(std.testing.allocator, &tc, &unit, unit.profile, &dep_libs, "/spool/tool", "/ws/tool/src/main.rs", null);
    defer inv.deinit(std.testing.allocator);
    try std.testing.expect(hasArg(inv.argv, "--emit=dep-info,link"));
    try std.testing.expect(hasArg(inv.argv, "prefer-dynamic"));
    // Release profile: opt-level=3, no debuginfo, assertions off, extern +
    // -L wiring present.
    try std.testing.expect(hasArg(inv.argv, "opt-level=3"));
    try std.testing.expect(!hasArg(inv.argv, "debuginfo=0"));
    try std.testing.expect(hasArg(inv.argv, "debug-assertions=off"));
    try std.testing.expect(hasArg(inv.argv, "--extern"));
    try std.testing.expect(hasArg(inv.argv, "b=/spool/deps/libb-0123456789abcdef.rlib"));
    try std.testing.expect(hasArg(inv.argv, "-L"));
    try std.testing.expect(hasArg(inv.argv, "dependency=/spool/deps"));
    try std.testing.expectEqualStrings("/ws/tool/src/main.rs", inv.argv[inv.argv.len - 1]);
}

test "abort panic sets bootstrap env and edition override wins" {
    var unit = driver_mod.Unit{
        .pkg_name = "tool",
        .version = "0.1.0",
        .target_name = "my-tool",
        .kind = .bin,
        .edition = "2018",
        .crate_types = &.{"bin"},
        .profile = profile_mod.devProfile(),
        .features_sorted = &.{},
        .target_triple = "aarch64-apple-darwin",
        .compile_kind = .target,
        .mode = .build,
        .src_path = "/ws/tool",
        .deps = &.{},
    };
    var abort_profile = unit.profile;
    abort_profile.panic_strategy = .abort;
    abort_profile.lto_off = true;
    var tc = tcStub();
    var inv = try buildRustcArgs(std.testing.allocator, &tc, &unit, abort_profile, &.{}, "/spool/tool", "/ws/tool/src/main.rs", "2021");
    defer inv.deinit(std.testing.allocator);
    // Crate name maps dashes; edition override replaces the unit edition.
    try std.testing.expectEqualStrings("my_tool", inv.argv[2]);
    try std.testing.expect(hasArg(inv.argv, "--edition=2021"));
    try std.testing.expect(hasArg(inv.argv, "panic=abort"));
    try std.testing.expect(hasArg(inv.argv, "lto=off"));
    try std.testing.expect(hasArg(inv.argv, "embed-bitcode=no"));
    try std.testing.expectEqual(@as(usize, 1), inv.env_extra.len);
    try std.testing.expectEqualStrings("RUSTC_BOOTSTRAP=1", inv.env_extra[0]);
}
