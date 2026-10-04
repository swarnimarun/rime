//! Cargo machine-message event protocol (M6 Task 3).
//!
//! Cargo-shaped streaming JSON events for `--message-format=json`.
//! Normative pins: `src/cargo/util/machine_message.rs` (event shapes +
//! field order) and `src/doc/src/reference/external-tools.md` (JSON
//! messages chapter). Wire order = struct field order; `reason` first.
//!
//! Only `required-features` is omitted when unset (cargo omits the key);
//! `debuginfo:null` IS emitted (null is meaningful per external-tools.md).

const std = @import("std");
const manifest_mod = @import("manifest.zig");
const sources_mod = @import("sources.zig");
const profile_mod = @import("profile.zig");

const TargetKind = manifest_mod.TargetKind;
const SourceId = sources_mod.SourceId;

pub const TargetJson = struct {
    kind: []const []const u8, // ["lib"] | ["bin"] | ["example"] | ["test"] | ["bench"]
    crate_types: []const []const u8, // lib/example: manifest list (default ["lib"]); others ["bin"]
    name: []const u8, // lib target: dashes -> underscores
    src_path: []const u8, // absolute root source file
    edition: []const u8, // package edition, default "2021" (manifest.zig)
    required_features: ?[]const []const u8 = null, // omitted (null) when empty
    doc: bool,
    doctest: bool,
    @"test": bool,

    pub fn writeInto(self: *const TargetJson, w: *std.Io.Writer) !void {
        try w.writeAll("{\"kind\":");
        try writeStrArray(w, self.kind);
        try w.writeAll(",\"crate_types\":");
        try writeStrArray(w, self.crate_types);
        try w.writeAll(",\"name\":");
        try std.json.Stringify.value(self.name, .{}, w);
        try w.writeAll(",\"src_path\":");
        try std.json.Stringify.value(self.src_path, .{}, w);
        try w.writeAll(",\"edition\":");
        try std.json.Stringify.value(self.edition, .{}, w);
        if (self.required_features) |rf| {
            try w.writeAll(",\"required-features\":");
            try writeStrArray(w, rf);
        }
        try w.writeAll(",\"doc\":");
        try std.json.Stringify.value(self.doc, .{}, w);
        try w.writeAll(",\"doctest\":");
        try std.json.Stringify.value(self.doctest, .{}, w);
        try w.writeAll(",\"test\":");
        try std.json.Stringify.value(self.@"test", .{}, w);
        try w.writeAll("}");
    }
};

pub const ProfileJson = struct {
    opt_level: []const u8, // "0" dev, "3" release (custom profiles: their opt-level)
    debuginfo: ?u32, // 2 dev, null release (rustc default 0); null is meaningful
    debug_assertions: bool,
    overflow_checks: bool,
    @"test": bool, // --test flag used (true for test/bench unit artifacts)

    pub fn writeInto(self: *const ProfileJson, w: *std.Io.Writer) !void {
        try w.writeAll("{\"opt_level\":");
        try std.json.Stringify.value(self.opt_level, .{}, w);
        try w.writeAll(",\"debuginfo\":");
        try std.json.Stringify.value(self.debuginfo, .{}, w);
        try w.writeAll(",\"debug_assertions\":");
        try std.json.Stringify.value(self.debug_assertions, .{}, w);
        try w.writeAll(",\"overflow_checks\":");
        try std.json.Stringify.value(self.overflow_checks, .{}, w);
        try w.writeAll(",\"test\":");
        try std.json.Stringify.value(self.@"test", .{}, w);
        try w.writeAll("}");
    }
};

pub const ArtifactEvent = struct {
    package_id: []const u8,
    manifest_path: []const u8, // absolute
    target: TargetJson,
    profile: ProfileJson,
    features: []const []const u8,
    filenames: []const []const u8, // absolute view paths
    executable: ?[]const u8, // bin/test-harness path or null
    fresh: bool,

    pub fn writeLine(self: *const ArtifactEvent, w: *std.Io.Writer) !void {
        try w.writeAll("{\"reason\":\"compiler-artifact\",\"package_id\":");
        try std.json.Stringify.value(self.package_id, .{}, w);
        try w.writeAll(",\"manifest_path\":");
        try std.json.Stringify.value(self.manifest_path, .{}, w);
        try w.writeAll(",\"target\":");
        try self.target.writeInto(w);
        try w.writeAll(",\"profile\":");
        try self.profile.writeInto(w);
        try w.writeAll(",\"features\":");
        try writeStrArray(w, self.features);
        try w.writeAll(",\"filenames\":");
        try writeStrArray(w, self.filenames);
        try w.writeAll(",\"executable\":");
        try std.json.Stringify.value(self.executable, .{}, w);
        try w.writeAll(",\"fresh\":");
        try std.json.Stringify.value(self.fresh, .{}, w);
        try w.writeAll("}\n");
    }
};

pub const BuildScriptEvent = struct {
    package_id: []const u8,
    linked_libs: []const []const u8,
    linked_paths: []const []const u8,
    cfgs: []const []const u8,
    env: []const [2][]const u8, // [KEY, VALUE] pairs
    out_dir: []const u8, // absolute

    pub fn writeLine(self: *const BuildScriptEvent, w: *std.Io.Writer) !void {
        try w.writeAll("{\"reason\":\"build-script-executed\",\"package_id\":");
        try std.json.Stringify.value(self.package_id, .{}, w);
        try w.writeAll(",\"linked_libs\":");
        try writeStrArray(w, self.linked_libs);
        try w.writeAll(",\"linked_paths\":");
        try writeStrArray(w, self.linked_paths);
        try w.writeAll(",\"cfgs\":");
        try writeStrArray(w, self.cfgs);
        try w.writeAll(",\"env\":[");
        for (self.env, 0..) |pair, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll("[");
            try std.json.Stringify.value(pair[0], .{}, w);
            try w.writeAll(",");
            try std.json.Stringify.value(pair[1], .{}, w);
            try w.writeAll("]");
        }
        try w.writeAll("],\"out_dir\":");
        try std.json.Stringify.value(self.out_dir, .{}, w);
        try w.writeAll("}\n");
    }
};

pub const CompilerMessageEvent = struct {
    package_id: []const u8,
    manifest_path: []const u8,
    target: TargetJson,
    message: std.json.Value, // rustc JSON message object, embedded verbatim

    pub fn writeLine(self: *const CompilerMessageEvent, w: *std.Io.Writer) !void {
        try w.writeAll("{\"reason\":\"compiler-message\",\"package_id\":");
        try std.json.Stringify.value(self.package_id, .{}, w);
        try w.writeAll(",\"manifest_path\":");
        try std.json.Stringify.value(self.manifest_path, .{}, w);
        try w.writeAll(",\"target\":");
        try self.target.writeInto(w);
        try w.writeAll(",\"message\":");
        try std.json.Stringify.value(self.message, .{}, w);
        try w.writeAll("}\n");
    }
};

pub const BuildFinishedEvent = struct {
    success: bool,

    pub fn writeLine(self: *const BuildFinishedEvent, w: *std.Io.Writer) !void {
        try w.writeAll("{\"reason\":\"build-finished\",\"success\":");
        try std.json.Stringify.value(self.success, .{}, w);
        try w.writeAll("}\n");
    }
};

fn writeStrArray(w: *std.Io.Writer, items: []const []const u8) !void {
    try w.writeAll("[");
    for (items, 0..) |s, i| {
        if (i > 0) try w.writeAll(",");
        try std.json.Stringify.value(s, .{}, w);
    }
    try w.writeAll("]");
}

/// Package ID wire form (normative per the 1.99.0-nightly oracle,
/// `cargo metadata` + `cargo build --message-format=json` on
/// `validation/basic-workspace`): registry sources emit
/// `registry+<url>#<name>@<version>`; path sources emit
/// `path+file://<abs-dir>#<version>` (no name — the name is redundant
/// with the path); git sources emit `git+<url>#<name>@<version>`
/// (precise omitted on the wire; the lock carries it).
pub fn packageId(gpa: std.mem.Allocator, source: SourceId, name: []const u8, version: []const u8, manifest_dir_abs: []const u8) ![]u8 {
    switch (source) {
        .registry => |url| {
            // The resolver keys `sparse+<url>` while the wire carries the
            // single-prefix `registry+<url>` (oracle golden +
            // README; `sources.zig::lockSourceLine` strips identically).
            var rest = url;
            if (std.mem.startsWith(u8, rest, "sparse+")) rest = rest["sparse+".len..];
            if (std.mem.startsWith(u8, rest, "registry+")) rest = rest["registry+".len..];
            return std.fmt.allocPrint(gpa, "registry+{s}#{s}@{s}", .{ rest, name, version });
        },
        .path => return std.fmt.allocPrint(gpa, "path+file://{s}#{s}", .{ manifest_dir_abs, version }),
        .git => |g| return std.fmt.allocPrint(gpa, "git+{s}#{s}@{s}", .{ g.url, name, version }),
    }
}

/// Cargo target-kind vocabulary. rime's `TargetKind` has no
/// `custom-build` variant (build scripts are plan-level units, never
/// targets), so that arm is absent by construction.
pub fn targetKindStr(kind: TargetKind) []const u8 {
    return switch (kind) {
        .lib => "lib",
        .bin => "bin",
        .example => "example",
        .@"test" => "test",
        .bench => "bench",
    };
}

/// M6 profile mapping: `dev`/`check`/`test` inherit the dev shape
/// (`opt 0`, `debuginfo 2`, assertions + overflow on); every other name is
/// release-shaped (`opt 3`, `debuginfo null`, both off). `is_test` marks
/// artifacts built with `--test` (test/bench harness binaries).
pub fn profileJson(profile: []const u8, is_test: bool) ProfileJson {
    const p = profile_mod.profileFor(profile);
    const dbg: ?u32 = if (p.debug_info == 0) null else p.debug_info;
    return .{
        .opt_level = p.opt_level,
        .debuginfo = dbg,
        .debug_assertions = p.debug_assertions,
        .overflow_checks = p.overflow_checks,
        .@"test" = is_test,
    };
}

test "artifact event matches cargo wire order" {
    var out: std.Io.Writer.Allocating = try .initCapacity(std.testing.allocator, 1024);
    defer out.deinit();
    const ev = ArtifactEvent{
        .package_id = "path+file:///ws/a#0.1.0",
        .manifest_path = "/ws/a/Cargo.toml",
        .target = .{ .kind = &.{"lib"}, .crate_types = &.{"lib"}, .name = "a", .src_path = "/ws/a/src/lib.rs", .edition = "2021", .required_features = null, .doc = true, .doctest = true, .@"test" = true },
        .profile = .{ .opt_level = "0", .debuginfo = 2, .debug_assertions = true, .overflow_checks = true, .@"test" = false },
        .features = &.{},
        .filenames = &.{"/ws/target/debug/deps/liba-ab12.rlib"},
        .executable = null,
        .fresh = true,
    };
    try ev.writeLine(&out.writer);
    const bytes = try out.toOwnedSlice();
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("{\"reason\":\"compiler-artifact\",\"package_id\":\"path+file:///ws/a#0.1.0\",\"manifest_path\":\"/ws/a/Cargo.toml\",\"target\":{\"kind\":[\"lib\"],\"crate_types\":[\"lib\"],\"name\":\"a\",\"src_path\":\"/ws/a/src/lib.rs\",\"edition\":\"2021\",\"doc\":true,\"doctest\":true,\"test\":true},\"profile\":{\"opt_level\":\"0\",\"debuginfo\":2,\"debug_assertions\":true,\"overflow_checks\":true,\"test\":false},\"features\":[],\"filenames\":[\"/ws/target/debug/deps/liba-ab12.rlib\"],\"executable\":null,\"fresh\":true}\n", bytes);
}

test "build-finished event shape" {
    var out: std.Io.Writer.Allocating = try .initCapacity(std.testing.allocator, 64);
    defer out.deinit();
    try (&BuildFinishedEvent{ .success = true }).writeLine(&out.writer);
    const bytes = try out.toOwnedSlice();
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("{\"reason\":\"build-finished\",\"success\":true}\n", bytes);
}

test "build-script event shape pins env pairs" {
    var out: std.Io.Writer.Allocating = try .initCapacity(std.testing.allocator, 512);
    defer out.deinit();
    const ev = BuildScriptEvent{
        .package_id = "path+file:///ws/a#0.1.0",
        .linked_libs = &.{"foo"},
        .linked_paths = &. {"/ws/a/native"},
        .cfgs = &.{"feature=\"x\""},
        .env = &.{.{ "OUT_DIR", "/ws/target/debug/build/a-out" }},
        .out_dir = "/ws/target/debug/build/a-out",
    };
    try ev.writeLine(&out.writer);
    const bytes = try out.toOwnedSlice();
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("{\"reason\":\"build-script-executed\",\"package_id\":\"path+file:///ws/a#0.1.0\",\"linked_libs\":[\"foo\"],\"linked_paths\":[\"/ws/a/native\"],\"cfgs\":[\"feature=\\\"x\\\"\"],\"env\":[[\"OUT_DIR\",\"/ws/target/debug/build/a-out\"]],\"out_dir\":\"/ws/target/debug/build/a-out\"}\n", bytes);
}

test "packageId uses oracle path form" {
    const pid = try packageId(std.testing.allocator, .{ .path = "/ws/a" }, "a", "0.1.0", "/ws/a");
    defer std.testing.allocator.free(pid);
    try std.testing.expectEqualStrings("path+file:///ws/a#0.1.0", pid);
    const rid = try packageId(std.testing.allocator, .{ .registry = "sparse+https://github.com/rust-lang/crates.io-index" }, "serde", "1.0.228", "/unused");
    defer std.testing.allocator.free(rid);
    try std.testing.expectEqualStrings("registry+https://github.com/rust-lang/crates.io-index#serde@1.0.228", rid);
    // Already-normalized and bare inputs collapse to the same single prefix.
    const rid2 = try packageId(std.testing.allocator, .{ .registry = "registry+https://github.com/rust-lang/crates.io-index" }, "serde", "1.0.228", "/unused");
    defer std.testing.allocator.free(rid2);
    try std.testing.expectEqualStrings(rid, rid2);
    const rid3 = try packageId(std.testing.allocator, .{ .registry = "https://github.com/rust-lang/crates.io-index" }, "serde", "1.0.228", "/unused");
    defer std.testing.allocator.free(rid3);
    try std.testing.expectEqualStrings(rid, rid3);
}

test "targetKindStr covers all rime variants" {
    try std.testing.expectEqualStrings("lib", targetKindStr(.lib));
    try std.testing.expectEqualStrings("bin", targetKindStr(.bin));
    try std.testing.expectEqualStrings("example", targetKindStr(.example));
    try std.testing.expectEqualStrings("test", targetKindStr(.@"test"));
    try std.testing.expectEqualStrings("bench", targetKindStr(.bench));
}

test "profileJson maps dev and release" {
    const dev = profileJson("dev", false);
    try std.testing.expectEqualStrings("0", dev.opt_level);
    try std.testing.expectEqual(@as(?u32, 2), dev.debuginfo);
    try std.testing.expect(dev.debug_assertions and dev.overflow_checks and !dev.@"test");
    const rel = profileJson("release", false);
    try std.testing.expectEqualStrings("3", rel.opt_level);
    try std.testing.expect(rel.debuginfo == null);
    const t = profileJson("dev", true);
    try std.testing.expect(t.@"test");
}
