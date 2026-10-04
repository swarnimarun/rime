const std = @import("std");
const toml = @import("toml.zig"); // wired via the cargo module; see build.zig note in Plan C Task 5
const semver = @import("semver.zig");
const sources = @import("sources.zig");

pub const ManifestError = error{ InvalidManifest, UnsupportedKey, OutOfMemory, ParseError, UnsupportedType };
pub const DependencyKind = union(enum) {
    version_req: []const u8, // "1.0" (owns no memory; borrows doc arena)
    path: []const u8, // { path = "../x" }
    git: GitSpec, // { git = "url", rev/branch/tag = … }
    workspace_inherit: void, // { workspace = true }
};
pub const GitSpec = struct { url: []const u8, ref: ?[]const u8 };
pub const TargetDesc = struct { name: []const u8, path: ?[]const u8, kind: TargetKind };
// `test` is a Zig keyword, so the field is declared escaped: its identifier
// is still `test` (@tagName returns "test"), spelled `.@"test"` at use sites.
pub const TargetKind = enum { lib, bin, example, @"test", bench };
pub const Package = struct {
    name: []const u8,
    version: []const u8,
    edition: []const u8, // default "2021" when absent
    build_script: ?[]const u8, // None, "build.rs" default when file exists (checked by workspace task)
};
pub const Manifest = struct {
    arena: std.heap.ArenaAllocator, // owns ALL borrowed strings/slices below; deinit frees arena + deps map header
    pkg: ?Package, // null for virtual workspace roots
    deps: std.StringHashMap(DependencyKind),
    targets: []TargetDesc, // explicit [lib]/[[bin]] or defaults
    workspace_members: ?[]const []const u8, // [workspace] members globs, if present
    workspace_exclude: []const []const u8,
    // Workspace inheritance (same-file [workspace.package] /.
    // [workspace.dependencies]). `version_inherited`/`edition_inherited`
    // mark a `{ workspace = true }` field the same file could not satisfy
    // (version is then the `""` placeholder); `workspace.discover`
    // fills those from the root manifest. `ws_deps` holds the same-file
    // [workspace.dependencies] entries for that lookup.
    version_inherited: bool,
    edition_inherited: bool,
    // `rust-version` inheritance (`rust-version.workspace = true`). M1 fills
    // the same-file form from [workspace.package]; cross-file members leave
    // `rust_version_inherited` set for Task-12 `resolveInheritance` (M1
    // `workspace.discover` does not fill it -- only version/edition are
    // member-critical there). `description`/`license`/etc. workspace
    // inheritance needs no field: they carry no resolution semantics and stay
    // parsed-and-ignored per `checkPackageKeys`.
    rust_version: ?[]const u8,
    rust_version_inherited: bool,
    ws_version: ?[]const u8,
    ws_edition: ?[]const u8,
    ws_rust_version: ?[]const u8,
    ws_deps: std.StringHashMap(DependencyKind),
    pub fn deinit(self: *Manifest) void {
        self.deps.deinit();
        self.ws_deps.deinit();
        self.arena.deinit();
    }
};

pub fn parseManifest(gpa: std.mem.Allocator, text: []const u8) ManifestError!Manifest {
    const doc = toml.parseDocument(gpa, text) catch |e| return switch (e) {
        toml.TomlError.ParseError => ManifestError.ParseError,
        toml.TomlError.UnsupportedType => ManifestError.UnsupportedType,
        toml.TomlError.OutOfMemory => ManifestError.OutOfMemory,
    };
    // NOTE: doc.arena outlives the Manifest — Manifest borrows strings from it.
    // Ownership transfer (exact): move doc.arena into the returned Manifest; Manifest.deinit frees it.
    // `doc` itself is never deinitialized; only the moved arena is.
    var m = Manifest{
        .arena = doc.arena,
        .pkg = null,
        .deps = std.StringHashMap(DependencyKind).init(gpa),
        .targets = &.{},
        .workspace_members = null,
        .workspace_exclude = &.{},
        .version_inherited = false,
        .edition_inherited = false,
        .rust_version = null,
        .rust_version_inherited = false,
        .ws_version = null,
        .ws_edition = null,
        .ws_rust_version = null,
        .ws_deps = std.StringHashMap(DependencyKind).init(gpa),
    };
    errdefer {
        m.deps.deinit();
        m.ws_deps.deinit();
        m.arena.deinit();
    }
    const alloc = m.arena.allocator();
    // [workspace.package] + [workspace.dependencies] first: member manifests
    // inherit from these (directly when self-contained, via discover when
    // the values live in the workspace root).
    if (doc.root.get("workspace")) |wv| {
        if (wv.* != .table) return ManifestError.InvalidManifest;
        const wt = &wv.table;
        if (wt.get("package")) |wp| {
            if (wp.* != .table) return ManifestError.InvalidManifest;
            const pt = &wp.table;
            if (pt.get("version")) |vv| {
                if (vv.* != .string) return ManifestError.InvalidManifest;
                m.ws_version = vv.string;
            }
            if (pt.get("edition")) |ev| {
                if (ev.* != .string) return ManifestError.InvalidManifest;
                m.ws_edition = ev.string;
            }
            if (pt.get("rust-version")) |rv| {
                if (rv.* != .string) return ManifestError.InvalidManifest;
                m.ws_rust_version = rv.string;
            }
        }
        if (wt.get("dependencies")) |wd| {
            if (wd.* != .table) return ManifestError.InvalidManifest;
            const wdt = &wd.table;
            var wit = wdt.entries.iterator();
            while (wit.next()) |kv| {
                const dep = try parseDep(&kv.value_ptr.value);
                if (dep == .workspace_inherit) return ManifestError.InvalidManifest;
                try m.ws_deps.put(kv.key_ptr.*, dep);
            }
        }
    }
    if (doc.root.get("package")) |pv| {
        if (pv.* != .table) return ManifestError.InvalidManifest;
        const pt = &pv.table; // *const TomlTable: no map-header copy (pv is *const TomlValue)
        try checkPackageKeys(pt);
        const vf = try packageField(pt, "version");
        const ef = try packageField(pt, "edition");
        m.pkg = Package{
            .name = try requiredString(pt, "name"),
            .version = vf.value,
            .edition = ef.value,
            .build_script = try optionalBuildScript(pt),
        };
        m.version_inherited = vf.inherited;
        m.edition_inherited = ef.inherited;
        // Self-contained roots resolve immediately; member files leave the
        // flags set for discover to fill from the workspace root.
        if (m.version_inherited and m.ws_version != null) {
            m.pkg.?.version = m.ws_version.?;
            m.version_inherited = false;
        }
        if (m.edition_inherited) {
            if (m.ws_edition) |e| {
                m.pkg.?.edition = e;
                m.edition_inherited = false;
            }
        }
        // `rust-version`: plain string, absent (null -- no MSRV floor), or
        // `{ workspace = true }` (same-file values resolve immediately;
        // cross-file stays pending for `resolveInheritance`). Any other
        // table is InvalidManifest, mirroring `packageField`.
        if (pt.get("rust-version")) |rv| {
            if (rv.* == .string) {
                m.rust_version = rv.string;
            } else if (rv.* == .table and isWorkspaceTrue(&rv.table)) {
                m.rust_version_inherited = true;
                if (m.ws_rust_version) |w| {
                    m.rust_version = w;
                    m.rust_version_inherited = false;
                }
            } else {
                return ManifestError.InvalidManifest;
            }
        }
    }
    if (doc.root.get("dependencies")) |dv| {
        if (dv.* != .table) return ManifestError.InvalidManifest;
        const dt = &dv.table; // *const TomlTable: no map-header copy
        var it = dt.entries.iterator();
        while (it.next()) |kv| {
            // Pointer, not a copy: TomlValue holds a TomlTable holding a map header.
            const dep = try parseDep(&kv.value_ptr.value);
            try m.deps.put(kv.key_ptr.*, dep);
        }
    }
    // Explicit [lib] / [[bin]] targets. When absent, targets stays empty and
    // the workspace task resolves the default single lib-or-bin via file probe.
    // M1 models lib/bin only: [example]/[test]/[bench] sections are ignored.
    var targets: std.ArrayList(TargetDesc) = .empty;
    if (doc.root.get("lib")) |lv| {
        if (lv.* != .table) return ManifestError.InvalidManifest;
        const lt = &lv.table;
        try targets.append(alloc, .{
            .name = try targetName(alloc, lt, m.pkg, .lib),
            .path = optionalString(lt, "path"),
            .kind = .lib,
        });
    }
    if (doc.root.get("bin")) |bv| {
        if (bv.* != .array) return ManifestError.InvalidManifest;
        for (bv.array) |*bval| {
            if (bval.* != .table) return ManifestError.InvalidManifest;
            const bt = &bval.table;
            try targets.append(alloc, .{
                .name = try targetName(alloc, bt, m.pkg, .bin),
                .path = optionalString(bt, "path"),
                .kind = .bin,
            });
        }
    }
    m.targets = try targets.toOwnedSlice(alloc);
    // [workspace] members/exclude string arrays when present. Other workspace
    // keys (e.g. resolver) and non-dependencies sections ([dev-dependencies],
    // [build-dependencies], [features], [profile.*]) are ignored in M1: the
    // Manifest model has no fields for them yet (M3 owns features/profiles).
    if (doc.root.get("workspace")) |wv| {
        if (wv.* != .table) return ManifestError.InvalidManifest;
        const wt = &wv.table;
        if (wt.get("members")) |mv| {
            m.workspace_members = try stringArray(alloc, mv);
        }
        if (wt.get("exclude")) |ev| {
            m.workspace_exclude = try stringArray(alloc, ev);
        }
    }
    return m;
}

/// A `version`/`edition` field: plain string, absent (edition defaults to
/// "2021"; version is required), or `{ workspace = true }` (inherited:
/// value is the "" placeholder for discover to fill). Any other table is
/// InvalidManifest — cargo forbids inheritance for `name`, enforced by
/// keeping `requiredString` for it.
fn packageField(t: *const toml.TomlTable, key: []const u8) ManifestError!struct { value: []const u8, inherited: bool } {
    const v = t.get(key) orelse return .{
        .value = if (std.mem.eql(u8, key, "edition")) "2021" else return ManifestError.InvalidManifest,
        .inherited = false,
    };
    if (v.* == .string) return .{ .value = v.string, .inherited = false };
    if (v.* == .table) {
        const it = &v.table;
        if (it.get("workspace")) |w| {
            if (w.* == .boolean and w.boolean) return .{ .value = "", .inherited = true };
        }
    }
    return ManifestError.InvalidManifest;
}

/// True when a table is exactly `{ workspace = true }` (the inheritance
/// marker; shared by `packageField` and the Task-12 `rust-version` read).
fn isWorkspaceTrue(t: *const toml.TomlTable) bool {
    const w = t.get("workspace") orelse return false;
    return w.* == .boolean and w.boolean;
}

fn requiredString(t: *const toml.TomlTable, key: []const u8) ManifestError![]const u8 {
    const v = t.get(key) orelse return ManifestError.InvalidManifest;
    if (v.* != .string) return ManifestError.InvalidManifest;
    return v.string;
}

fn optionalString(t: *const toml.TomlTable, key: []const u8) ?[]const u8 {
    const v = t.get(key) orelse return null;
    if (v.* != .string) return null;
    return v.string;
}

/// `build` / `build-script`: path string verbatim; `false` disables (null);
/// `true` selects the conventional default; absent stays null so the
/// workspace task can probe for build.rs.
fn optionalBuildScript(t: *const toml.TomlTable) ManifestError! ?[]const u8 {
    const v = t.get("build") orelse t.get("build-script") orelse return null;
    switch (v.*) {
        .string => |s| return s,
        .boolean => |b| return if (b) "build.rs" else null,
        else => return ManifestError.InvalidManifest,
    }
}

fn checkPackageKeys(t: *const toml.TomlTable) ManifestError!void {
    // Harmless metadata cargo accepts (description, repository, …) parses
    // and is ignored: the M1 model has no fields for it. `resolver` (the
    // "1"/"2" version selector, valid under [package] and [workspace])
    // is likewise tolerated: it only affects version/feature resolution,
    // which M3 owns — M1 plans workspace path members only. Anything else
    // is still loud (decision D2) — silent divergence is forbidden.
    const allowed = [_][]const u8{ "name", "version", "edition", "build", "build-script", "rust-version", "description", "license", "authors", "repository", "homepage", "documentation", "readme", "keywords", "categories", "publish", "exclude", "include", "links", "default-run", "autobins", "autoexamples", "autotests", "autobenches", "autolib", "metadata", "resolver" };
    var it = t.entries.iterator();
    while (it.next()) |kv| {
        var ok = false;
        for (allowed) |a| {
            if (std.mem.eql(u8, kv.key_ptr.*, a)) {
                ok = true;
                break;
            }
        }
        if (!ok) return ManifestError.UnsupportedKey;
    }
}

/// Pointer, not a copy (see parseManifest call site). Precedence for combined
/// forms (e.g. `{ version, path }`): path, then git, then workspace-inherit,
/// then version. `optional`/`features`/`default-features` keys are accepted
/// and ignored: parsed, never resolved (resolution is M3).
fn parseDep(val: *const toml.TomlValue) ManifestError!DependencyKind {
    if (val.* == .string) return .{ .version_req = val.string };
    if (val.* != .table) return ManifestError.InvalidManifest;
    const t = &val.table; // *const TomlTable: no map-header copy
    if (t.get("path")) |pv| {
        if (pv.* != .string) return ManifestError.InvalidManifest;
        return .{ .path = pv.string };
    }
    if (t.get("git")) |gv| {
        if (gv.* != .string) return ManifestError.InvalidManifest;
        // rev wins over branch wins over tag; absent means the default branch.
        var ref: ?[]const u8 = null;
        if (t.get("rev")) |rv| {
            if (rv.* != .string) return ManifestError.InvalidManifest;
            ref = rv.string;
        } else if (t.get("branch")) |bv| {
            if (bv.* != .string) return ManifestError.InvalidManifest;
            ref = bv.string;
        } else if (t.get("tag")) |tv| {
            if (tv.* != .string) return ManifestError.InvalidManifest;
            ref = tv.string;
        }
        return .{ .git = .{ .url = gv.string, .ref = ref } };
    }
    if (t.get("workspace")) |wv| {
        if (wv.* != .boolean or !wv.boolean) return ManifestError.InvalidManifest;
        return .workspace_inherit;
    }
    if (t.get("version")) |vv| {
        if (vv.* != .string) return ManifestError.InvalidManifest;
        return .{ .version_req = vv.string };
    }
    return ManifestError.InvalidManifest;
}

/// Explicit target name, else the package name. Default lib names map `-` to
/// `_` per cargo (bins keep dashes). Requires [package] when unnamed.
fn targetName(alloc: std.mem.Allocator, t: *const toml.TomlTable, pkg: ?Package, kind: TargetKind) ManifestError![]const u8 {
    if (optionalString(t, "name")) |n| return n;
    const p = pkg orelse return ManifestError.InvalidManifest;
    if (kind == .lib and std.mem.indexOfScalar(u8, p.name, '-') != null) {
        const buf = try alloc.dupe(u8, p.name);
        for (buf) |*c| {
            if (c.* == '-') c.* = '_';
        }
        return buf;
    }
    return p.name;
}

fn stringArray(alloc: std.mem.Allocator, val: *const toml.TomlValue) ManifestError![]const []const u8 {
    if (val.* != .array) return ManifestError.InvalidManifest;
    var list: std.ArrayList([]const u8) = .empty;
    for (val.array) |*item| {
        if (item.* != .string) return ManifestError.InvalidManifest;
        try list.append(alloc, item.string);
    }
    return try list.toOwnedSlice(alloc);
}

test "manifest parses minimal package" {
    // Runtime read (not @embedFile): the plan's snippet embeds
    // "../../testdata/…", but that escapes the module package path, so it
    // cannot compile under standalone `zig test src/cargo/manifest.zig`.
    // Repo-root-relative reads match the plan's own Task 4 test convention
    // (tests run with cwd = repo root).
    const io = std.Io.Threaded.global_single_threaded.io();
    const text = try std.Io.Dir.cwd().readFileAlloc(io, "testdata/cargo/minimal/Cargo.toml", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(text);
    var m = try parseManifest(std.testing.allocator, text);
    defer m.deinit();
    try std.testing.expectEqualStrings("rime-minimal", m.pkg.?.name);
    try std.testing.expectEqualStrings("1.0", m.deps.get("serde").?.version_req);
    try std.testing.expectEqualStrings("../rime-dep", m.deps.get("rime-dep").?.path);
}

test "manifest resolves same-file workspace inheritance" {
    const text = "[workspace.package]\nversion = \"0.9.0\"\nedition = \"2021\"\n[workspace.dependencies]\nserde = \"1\"\n[package]\nname = \"a\"\nversion.workspace = true\nedition.workspace = true\n[dependencies]\nserde.workspace = true\n";
    var m = try parseManifest(std.testing.allocator, text);
    defer m.deinit();
    // Same-file values resolve immediately (self-contained root).
    try std.testing.expectEqualStrings("0.9.0", m.pkg.?.version);
    try std.testing.expectEqualStrings("2021", m.pkg.?.edition);
    try std.testing.expect(!m.version_inherited);
    try std.testing.expect(!m.edition_inherited);
    // Member-level dep inheritance stays marked for discover to resolve.
    try std.testing.expect(m.deps.get("serde").? == .workspace_inherit);
    try std.testing.expectEqualStrings("1", m.ws_deps.get("serde").?.version_req);
}

test "manifest marks cross-file inheritance pending" {
    const text = "[package]\nname = \"a\"\nversion.workspace = true\n";
    var m = try parseManifest(std.testing.allocator, text);
    defer m.deinit();
    try std.testing.expect(m.version_inherited);
    try std.testing.expectEqualStrings("", m.pkg.?.version);
    // cargo forbids name inheritance: a table here is invalid, not pending.
    try std.testing.expectError(ManifestError.InvalidManifest, parseManifest(std.testing.allocator, "[package]\nname.workspace = true\nversion = \"0.1.0\"\n"));
}

test "manifest rejects unknown package keys loudly" {
    try std.testing.expectError(ManifestError.UnsupportedKey, parseManifest(std.testing.allocator, "[package]\nname = \"a\"\nversion = \"0.1.0\"\nflux-capacitor = true\n"));
}

test "manifest tolerates resolver version selector" {
    // validation/feature-matrix sets `resolver = "2"` under [package];
    // M1 plans path members only, so the selector parses and is ignored
    // (resolution semantics belong to M3).
    var m = try parseManifest(std.testing.allocator, "[package]\nname = \"a\"\nversion = \"0.1.0\"\nresolver = \"2\"\n");
    defer m.deinit();
    try std.testing.expectEqualStrings("a", m.pkg.?.name);
}

test "manifest parses git and workspace-inherit deps" {
    const text = "[package]\nname = \"a\"\nversion = \"0.1.0\"\n[dependencies]\ng = { git = \"https://example.com/r.git\", rev = \"abc123\" }\nw = { workspace = true }\n";
    var m = try parseManifest(std.testing.allocator, text);
    defer m.deinit();
    try std.testing.expectEqualStrings("https://example.com/r.git", m.deps.get("g").?.git.url);
    try std.testing.expect(m.deps.get("w").? == .workspace_inherit);
}

test "manifest defaults edition and parses workspace and targets" {
    const text =
        \\[package]
        \\name = "my-crate"
        \\version = "0.2.0"
        \\
        \\[lib]
        \\path = "src/mylib.rs"
        \\
        \\[[bin]]
        \\name = "tool"
        \\
        \\[[bin]]
        \\name = "other"
        \\path = "src/other.rs"
        \\
        \\[workspace]
        \\members = ["crates/*"]
        \\exclude = ["crates/skip"]
        \\
    ;
    var m = try parseManifest(std.testing.allocator, text);
    defer m.deinit();
    try std.testing.expectEqualStrings("2021", m.pkg.?.edition);
    try std.testing.expect(m.pkg.?.build_script == null);
    try std.testing.expectEqual(@as(usize, 3), m.targets.len);
    // Default lib name maps '-' to '_' per cargo.
    try std.testing.expectEqualStrings("my_crate", m.targets[0].name);
    try std.testing.expect(m.targets[0].kind == .lib);
    try std.testing.expectEqualStrings("src/mylib.rs", m.targets[0].path.?);
    try std.testing.expectEqualStrings("tool", m.targets[1].name);
    try std.testing.expect(m.targets[1].path == null);
    try std.testing.expectEqualStrings("src/other.rs", m.targets[2].path.?);
    try std.testing.expectEqual(@as(usize, 1), m.workspace_members.?.len);
    try std.testing.expectEqualStrings("crates/*", m.workspace_members.?[0]);
    try std.testing.expectEqual(@as(usize, 1), m.workspace_exclude.len);
    try std.testing.expectEqualStrings("crates/skip", m.workspace_exclude[0]);
}

test "manifest parses virtual workspace root and versioned table deps" {
    const text =
        \\[workspace]
        \\members = ["a", "b"]
        \\
        \\[dependencies]
        \\serde = { version = "1.0", optional = true }
        \\
    ;
    var m = try parseManifest(std.testing.allocator, text);
    defer m.deinit();
    try std.testing.expect(m.pkg == null);
    try std.testing.expectEqualStrings("1.0", m.deps.get("serde").?.version_req);
    try std.testing.expectEqual(@as(usize, 2), m.workspace_members.?.len);
    try std.testing.expectEqual(@as(usize, 0), m.targets.len);
}

// =====================================================================
// Task 12: Broad Cargo.toml surface -- renames, target tables, workspace
// inheritance, [patch]/[replace] (+ `resolver` field).
//
// Reference pins:
// - manifest grammar: `references/cargo/src/cargo/core/manifest.rs` +
//   `cargo-util-schemas` manifest schema (which keys exist per table).
// - inheritance merge: `references/cargo/src/cargo/util/toml/mod.rs`
//   `inner_dependency_inherit_with` (features CONCATENATED workspace ++
//   member; `default-features = true` overrides workspace `false`; an
//   explicit member `false` never overrides workspace `true` pre-2024 --
//   rime keeps the workspace value and documents the edition-2024 hard
//   error as a known limitation, see `mergeInheritedDep`).
//   `optional` needs no merge subtlety: cargo REJECTS `optional = true`
//   inside `[workspace.dependencies]` outright (verified against the
//   pinned cargo: "X is optional, but workspace dependencies cannot be
//   optional"), so the workspace side is always false and the member's
//   explicit value (OR default false) is exact.
// - `[patch]`: `ops/resolve.rs::register_patch_entries` (preferences +
//   `avoid_patch_ids` + `registry.lock_patches()`).
// - `[replace]`: `core/resolver/dep_cache.rs` replacement block (the three
//   error wordings are replicated by `replace*Message` below).
// - rename split: `registry_dependency_into_dep` (`package` vs `name`).
// - `resolver` validation: `core/resolver/types.rs`
//   `ResolveBehavior::from_manifest` (message copied verbatim).
//
// DESIGN DEVIATIONS from the plan's Interfaces (both forced, both loud):
// 1. `DepRef.kind` reuses the M1 `DependencyKind` union UNEXTENDED: adding
//    the planned `registry` variant would break the EXHAUSTIVE switch in
//    `workspace.zig::dupeDep` (a settled file outside Task-12 ownership).
//    Registry-keyed tables map to `.version_req` here with the URL in the
//    `registry_url` sidecar -- no information is lost.
// 2. `patchPreferences` takes a third `patch_versions` parameter: exact
//    patch versions live in the patch manifests (FS), unknowable from the
//    `[patch]` tables alone, and both outputs (`prefer` pins and the
//    `avoid_locked` set-difference) need them.

const index_mod = @import("index.zig");
const resolve_mod = @import("resolve.zig");

pub const ManifestSurfaceError = error{
    UnsupportedKey,
    UnsupportedManifestForm,
    UnknownInherit,
    InvalidManifest,
    OutOfMemory,
    ParseError,
    UnsupportedType,
};

/// Last loud-surface failure detail (mirrors `cli.zig::parseDiagnostic`):
/// codes above carry no payload, so every `UnsupportedKey`,
/// `UnsupportedManifestForm`, `UnknownInherit`, and `InvalidManifest`
/// raised below records `file:line: message` here. Fixed buffer,
/// truncated on overflow; read via `surfaceDiagnostic()`.
var surface_diag_buf: [512]u8 = undefined;
var surface_diag_len: usize = 0;

pub fn surfaceDiagnostic() ?[]const u8 {
    if (surface_diag_len == 0) return null;
    return surface_diag_buf[0..surface_diag_len];
}

fn surfaceFail(comptime fmt: []const u8, args: anytype) void {
    // This only records the detail; the caller returns its own code, so a
    // bare `return ManifestSurfaceError.X` with no diagnostic never ships.
    const msg = std.fmt.bufPrint(&surface_diag_buf, fmt, args) catch &surface_diag_buf;
    surface_diag_len = msg.len;
}

pub const DepTableKind = enum { normal, dev, build };

pub const DepRef = struct {
    key: []const u8, // manifest key (the RENAME when package != null)
    package: ?[]const u8, // real crate name; null when key is the real name
    kind: DependencyKind, // M1 union (see deviation 1 above)
    version: ?[]const u8, // raw `version = "…"` text when the table had one (path/git reqs + inheritance)
    registry_url: ?[]const u8, // `registry = "…"` value; null otherwise
    optional: bool,
    default_features: bool, // default true
    features: []const []const u8,
    target: ?[]const u8, // raw target selector text from the table header
    dep_kind: DepTableKind, // which [..-dependencies] table it came from
    pub fn realName(self: DepRef) []const u8 {
        return self.package orelse self.key;
    }
};

pub const PatchEntry = struct { source: []const u8, deps: []DepRef };
pub const ReplaceEntry = struct { spec: []const u8, dep: DepRef };

pub const ManifestExt = struct {
    base: Manifest, // M1 model (unchanged)
    doc_arena: std.heap.ArenaAllocator, // owns ALL ext strings/slices below
    filename: []const u8, // manifest path for diagnostics (borrowed from doc_arena)
    renamed: []DepRef, // ALL direct deps, sorted by (dep_kind, key)
    target_deps: []DepRef, // [target.<sel>.*] merged, sorted likewise
    patches: []PatchEntry,
    replaces: []ReplaceEntry,
    resolver: ?[]const u8, // [workspace] wins over [package]; validated "1"|"2"|"3"
    workspace_deps: []DepRef, // [workspace.dependencies] (inheritance source)
    links: ?[]const u8, // `[package] links = "…"` native-lib key (Task-3 conflict check)
    features: []index_mod.FeatureDef, // [features] table (Task-5/6 maps; values are raw strings)
    pub fn deinit(self: *ManifestExt) void {
        self.base.deinit();
        self.doc_arena.deinit();
    }
    /// `[patch]` resolution projection (`register_patch_entries`): patch
    /// candidate versions become Task-2 `preferred` pins; previous-locked
    /// versions shadowed by a patch table (same name, version NOT among the
    /// patch versions) lose `keep` and re-resolve. `patch_versions` carries
    /// the exact patch-manifest versions (FS read by the caller); entries
    /// for names outside every patch table are ignored. Returned slices are
    /// gpa-owned (caller frees both, even when empty).
    pub fn patchPreferences(
        self: *const ManifestExt,
        gpa: std.mem.Allocator,
        previous: []const resolve_mod.ResolvedNode,
        patch_versions: []const PatchVersion,
    ) ManifestSurfaceError!PatchPrefs {
        var prefer: std.ArrayList(index_mod.PreferredId) = .empty;
        errdefer prefer.deinit(gpa);
        var avoid: std.ArrayList(semver.Version) = .empty;
        errdefer avoid.deinit(gpa);
        for (patch_versions) |pv| {
            if (!self.isPatched(pv.name)) continue;
            try prefer.append(gpa, .{ .name = pv.name, .version = pv.version });
        }
        for (previous) |pn| {
            if (!self.isPatched(pn.name)) continue;
            var shadowed = true;
            for (patch_versions) |pv| {
                if (std.mem.eql(u8, pv.name, pn.name) and pv.version.eql(pn.version)) {
                    shadowed = false;
                    break;
                }
            }
            if (shadowed) try avoid.append(gpa, pn.version);
        }
        return .{
            .prefer = try prefer.toOwnedSlice(gpa),
            .avoid_locked = try avoid.toOwnedSlice(gpa),
        };
    }
    /// True when `name` (real crate name) appears in any `[patch]` table.
    pub fn isPatched(self: *const ManifestExt, name: []const u8) bool {
        for (self.patches) |p| {
            for (p.deps) |d| {
                if (std.mem.eql(u8, d.realName(), name)) return true;
            }
        }
        return false;
    }
};

pub const PatchVersion = struct { name: []const u8, version: semver.Version };
pub const PatchPrefs = struct {
    prefer: []index_mod.PreferredId,
    avoid_locked: []semver.Version,
};

/// Cargo's `UNUSED_PATCH_WARNING` first line is asserted by oracle tests;
/// the full text (from `ops/resolve.rs`, Rust `\`-continuations resolved)
/// is the M4 driver's stderr warning for unused `[patch]` entries.
pub const unused_patch_warning: []const u8 =
    "Check that the patched package version and available features are compatible\n" ++
    "with the dependency requirements. If the patch has a different version from\n" ++
    "what is locked in the Cargo.lock file, run `cargo update` to use the new\n" ++
    "version. This may also occur with an optional dependency that is not enabled.";

/// Broad-surface parse: runs the M1 `parseManifest` first (all M1 validation
/// kept), then a second pass over the same text for the M3 tables. Unknown
/// keys ANYWHERE in a supported table are loud (`UnsupportedKey`
/// `file:line: unknown key` per M1 D2); deferred-unstable manifest keys
/// (`artifact`, `public`, `bindep-target`, `lib`) are loud
/// `UnsupportedManifestForm` naming the key (index lines carrying the same
/// data NEVER error -- plan section 0.6 -- but manifest-side keys pass
/// cargo's unstable gate, so rime fails instead of diverging).
pub fn parseManifestExt(gpa: std.mem.Allocator, text: []const u8, filename: []const u8) ManifestSurfaceError!ManifestExt {
    surface_diag_len = 0;
    var base = parseManifest(gpa, text) catch |e| return switch (e) {
        ManifestError.InvalidManifest => ManifestSurfaceError.InvalidManifest,
        ManifestError.UnsupportedKey => ManifestSurfaceError.UnsupportedKey,
        ManifestError.OutOfMemory => ManifestSurfaceError.OutOfMemory,
        ManifestError.ParseError => ManifestSurfaceError.ParseError,
        ManifestError.UnsupportedType => ManifestSurfaceError.UnsupportedType,
    };
    // No errdefer on `base` alone: it moves into `ext` below, whose errdefer
    // owns it from there. The only pre-move failure (parseDocument) frees
    // it manually.
    var doc = toml.parseDocument(gpa, text) catch |e| {
        base.deinit();
        return switch (e) {
            toml.TomlError.ParseError => ManifestSurfaceError.ParseError,
            toml.TomlError.UnsupportedType => ManifestSurfaceError.UnsupportedType,
            toml.TomlError.OutOfMemory => ManifestSurfaceError.OutOfMemory,
        };
    };
    // NOTE: doc.arena outlives the ManifestExt (same transfer as M1).
    var ext = ManifestExt{
        .base = base,
        .doc_arena = doc.arena,
        .filename = undefined,
        .renamed = &.{},
        .target_deps = &.{},
        .patches = &.{},
        .replaces = &.{},
        .resolver = null,
        .workspace_deps = &.{},
        .links = null,
        .features = &.{},
    };
    errdefer {
        ext.base.deinit();
        ext.doc_arena.deinit();
    }
    const alloc = ext.doc_arena.allocator();
    ext.filename = try alloc.dupe(u8, filename);
    const ctx = ParseCtx{ .alloc = alloc, .filename = ext.filename };
    var renamed: std.ArrayList(DepRef) = .empty;
    var targets: std.ArrayList(DepRef) = .empty;
    if (doc.root.get("dependencies")) |dv| {
        if (dv.* != .table) return ManifestSurfaceError.InvalidManifest;
        try parseDepTable(ctx, &dv.table, null, .normal, &renamed);
    }
    if (doc.root.get("dev-dependencies")) |dv| {
        if (dv.* != .table) return ManifestSurfaceError.InvalidManifest;
        try parseDepTable(ctx, &dv.table, null, .dev, &renamed);
    }
    if (doc.root.get("build-dependencies")) |dv| {
        if (dv.* != .table) return ManifestSurfaceError.InvalidManifest;
        try parseDepTable(ctx, &dv.table, null, .build, &renamed);
    }
    if (doc.root.get("target")) |tv| {
        if (tv.* != .table) return ManifestSurfaceError.InvalidManifest;
        try parseTargetTables(ctx, &tv.table, &targets);
    }
    if (doc.root.get("patch")) |pv| {
        if (pv.* != .table) return ManifestSurfaceError.InvalidManifest;
        ext.patches = try parsePatchTables(ctx, &pv.table);
    }
    if (doc.root.get("replace")) |rv| {
        if (rv.* != .table) return ManifestSurfaceError.InvalidManifest;
        ext.replaces = try parseReplaceTable(ctx, &rv.table);
    }
    if (doc.root.get("features")) |fv| {
        if (fv.* != .table) return ManifestSurfaceError.InvalidManifest;
        var feats: std.ArrayList(index_mod.FeatureDef) = .empty;
        var fit = fv.table.entries.iterator();
        while (fit.next()) |kv| {
            if (kv.value_ptr.value != .array) {
                surfaceFail("{s}:{d}: feature `{s}` must be an array of strings", .{ ctx.filename, kv.value_ptr.span.line, kv.key_ptr.* });
                return ManifestSurfaceError.InvalidManifest;
            }
            var vals: std.ArrayList([]const u8) = .empty;
            for (kv.value_ptr.value.array) |*item| {
                if (item.* != .string) {
                    surfaceFail("{s}: feature `{s}` must be an array of strings", .{ ctx.filename, kv.key_ptr.* });
                    return ManifestSurfaceError.InvalidManifest;
                }
                try vals.append(alloc, item.string);
            }
            try feats.append(alloc, .{ .name = kv.key_ptr.*, .values = try vals.toOwnedSlice(alloc) });
        }
        ext.features = try feats.toOwnedSlice(alloc);
    }
    if (doc.root.get("workspace")) |wv| {
        if (wv.* != .table) return ManifestSurfaceError.InvalidManifest;
        try checkWorkspaceKeys(ctx, &wv.table);
        if (wv.table.get("dependencies")) |wd| {
            if (wd.* != .table) return ManifestSurfaceError.InvalidManifest;
            var ws_deps: std.ArrayList(DepRef) = .empty;
            try parseDepTable(ctx, &wd.table, null, .normal, &ws_deps);
            // Cargo rejects `optional` inside [workspace.dependencies]
            // outright (pinned-cargo probe: "X is optional, but workspace
            // dependencies cannot be optional").
            for (ws_deps.items) |d| {
                if (d.optional) {
                    surfaceFail("{s}: workspace dependency `{s}` cannot be optional", .{ ctx.filename, d.key });
                    return ManifestSurfaceError.InvalidManifest;
                }
                if (d.kind == .workspace_inherit) {
                    surfaceFail("{s}: workspace dependency `{s}` cannot inherit from itself", .{ ctx.filename, d.key });
                    return ManifestSurfaceError.InvalidManifest;
                }
            }
            ext.workspace_deps = try ws_deps.toOwnedSlice(alloc);
        }
        if (wv.table.get("resolver")) |rv| {
            if (rv.* != .string) return ManifestSurfaceError.InvalidManifest;
            ext.resolver = try validatedResolver(ctx, rv.string);
        }
    }
    if (doc.root.get("package")) |pv| {
        if (pv.* == .table) {
            if (pv.table.get("links")) |lv| {
                if (lv.* != .string) return ManifestSurfaceError.InvalidManifest;
                ext.links = lv.string;
            }
        }
    }
    // `[package] resolver` is the fallback (workspace wins when both are
    // present; cargo deprecates the package-level form).
    if (ext.resolver == null) {
        if (doc.root.get("package")) |pv| {
            if (pv.* == .table) {
                if (pv.table.get("resolver")) |rv| {
                    if (rv.* != .string) return ManifestSurfaceError.InvalidManifest;
                    ext.resolver = try validatedResolver(ctx, rv.string);
                }
            }
        }
    }
    sortDepRefs(renamed.items);
    ext.renamed = try renamed.toOwnedSlice(alloc);
    sortDepRefs(targets.items);
    ext.target_deps = try targets.toOwnedSlice(alloc);
    return ext;
}

const ParseCtx = struct { alloc: std.mem.Allocator, filename: []const u8 };

fn sortDepRefs(items: []DepRef) void {
    std.mem.sort(DepRef, items, {}, struct {
        fn lt(_: void, a: DepRef, b: DepRef) bool {
            if (@intFromEnum(a.dep_kind) != @intFromEnum(b.dep_kind))
                return @intFromEnum(a.dep_kind) < @intFromEnum(b.dep_kind);
            return std.mem.order(u8, a.key, b.key) == .lt;
        }
    }.lt);
}

/// `ResolveBehavior::from_manifest` (`core/resolver/types.rs`): only
/// `"1"|"2"|"3"` are valid; the message is copied verbatim.
fn validatedResolver(ctx: ParseCtx, value: []const u8) ManifestSurfaceError![]const u8 {
    if (std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "2") or std.mem.eql(u8, value, "3"))
        return value;
    surfaceFail("{s}: `resolver` setting `{s}` is not valid, valid options are \"1\", \"2\" or \"3\"", .{ ctx.filename, value });
    return ManifestSurfaceError.InvalidManifest;
}

fn checkWorkspaceKeys(ctx: ParseCtx, t: *const toml.TomlTable) ManifestSurfaceError!void {
    const allowed = [_][]const u8{ "members", "exclude", "resolver", "package", "dependencies", "metadata", "default-members" };
    var it = t.entries.iterator();
    while (it.next()) |kv| {
        var ok = false;
        for (allowed) |a| {
            if (std.mem.eql(u8, kv.key_ptr.*, a)) {
                ok = true;
                break;
            }
        }
        if (!ok) {
            surfaceFail("{s}:{d}: unknown key `{s}` in [workspace]", .{ ctx.filename, kv.value_ptr.span.line, kv.key_ptr.* });
            return ManifestSurfaceError.UnsupportedKey;
        }
    }
}

fn parseDepTable(ctx: ParseCtx, t: *const toml.TomlTable, target: ?[]const u8, kind: DepTableKind, out: *std.ArrayList(DepRef)) ManifestSurfaceError!void {
    var it = t.entries.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.value != .string and kv.value_ptr.value != .table) {
            surfaceFail("{s}:{d}: invalid dependency `{s}` (must be a version string or table)", .{ ctx.filename, kv.value_ptr.span.line, kv.key_ptr.* });
            return ManifestSurfaceError.InvalidManifest;
        }
        try out.append(ctx.alloc, try parseDepRef(ctx, kv.key_ptr.*, &kv.value_ptr.value, target, kind));
    }
}

/// `[target.<sel>.{dependencies,dev-dependencies,build-dependencies}]`.
/// The selector is validated NOW: `cfg(…)` forms through
/// `sources.parseCfg` (invalid cfg = `InvalidManifest`, never deferred);
/// bare triples/names (e.g. `x86_64-unknown-linux-gnu`, `windows`) are
/// accepted non-empty (matching against the build target is Task-7
/// `Platform.matches`, the consumer's job).
fn parseTargetTables(ctx: ParseCtx, t: *const toml.TomlTable, out: *std.ArrayList(DepRef)) ManifestSurfaceError!void {
    var it = t.entries.iterator();
    while (it.next()) |kv| {
        const sel = kv.key_ptr.*;
        if (kv.value_ptr.value != .table) {
            surfaceFail("{s}:{d}: invalid [target.{s}] (must be a table)", .{ ctx.filename, kv.value_ptr.span.line, sel });
            return ManifestSurfaceError.InvalidManifest;
        }
        if (std.mem.startsWith(u8, sel, "cfg(")) {
            _ = sources.parseCfg(ctx.alloc, sel) catch |e| switch (e) {
                sources.CfgError.InvalidCfg => {
                    surfaceFail("{s}:{d}: invalid target cfg `{s}`", .{ ctx.filename, kv.value_ptr.span.line, sel });
                    return ManifestSurfaceError.InvalidManifest;
                },
                sources.CfgError.OutOfMemory => return ManifestSurfaceError.OutOfMemory,
            };
        } else if (sel.len == 0) {
            surfaceFail("{s}:{d}: empty target selector", .{ ctx.filename, kv.value_ptr.span.line });
            return ManifestSurfaceError.InvalidManifest;
        }
        const st = &kv.value_ptr.value.table;
        var sit = st.entries.iterator();
        while (sit.next()) |skv| {
            const dk: DepTableKind = if (std.mem.eql(u8, skv.key_ptr.*, "dependencies"))
                .normal
            else if (std.mem.eql(u8, skv.key_ptr.*, "dev-dependencies"))
                .dev
            else if (std.mem.eql(u8, skv.key_ptr.*, "build-dependencies"))
                .build
            else {
                surfaceFail("{s}:{d}: unknown key `{s}` in [target.{s}]", .{ ctx.filename, skv.value_ptr.span.line, skv.key_ptr.*, sel });
                return ManifestSurfaceError.UnsupportedKey;
            };
            if (skv.value_ptr.value != .table) {
                surfaceFail("{s}:{d}: invalid [target.{s}.{s}] (must be a table)", .{ ctx.filename, skv.value_ptr.span.line, sel, skv.key_ptr.* });
                return ManifestSurfaceError.InvalidManifest;
            }
            try parseDepTable(ctx, &skv.value_ptr.value.table, sel, dk, out);
        }
    }
}

/// One `[patch.<source>]` table per key. Unparseable source keys are
/// `InvalidManifest` ("crates-io" plus URL-ish forms are accepted).
fn parsePatchTables(ctx: ParseCtx, t: *const toml.TomlTable) ManifestSurfaceError![]PatchEntry {
    var entries: std.ArrayList(PatchEntry) = .empty;
    var it = t.entries.iterator();
    while (it.next()) |kv| {
        const src = kv.key_ptr.*;
        if (!(std.mem.eql(u8, src, "crates-io") or std.mem.indexOf(u8, src, "://") != null or std.mem.indexOfScalar(u8, src, '+') != null)) {
            surfaceFail("{s}:{d}: invalid [patch] source `{s}`", .{ ctx.filename, kv.value_ptr.span.line, src });
            return ManifestSurfaceError.InvalidManifest;
        }
        if (kv.value_ptr.value != .table) {
            surfaceFail("{s}:{d}: invalid [patch.{s}] (must be a table)", .{ ctx.filename, kv.value_ptr.span.line, src });
            return ManifestSurfaceError.InvalidManifest;
        }
        var deps: std.ArrayList(DepRef) = .empty;
        try parseDepTable(ctx, &kv.value_ptr.value.table, null, .normal, &deps);
        sortDepRefs(deps.items);
        try entries.append(ctx.alloc, .{ .source = src, .deps = try deps.toOwnedSlice(ctx.alloc) });
    }
    std.mem.sort(PatchEntry, entries.items, {}, struct {
        fn lt(_: void, a: PatchEntry, b: PatchEntry) bool {
            return std.mem.order(u8, a.source, b.source) == .lt;
        }
    }.lt);
    return try entries.toOwnedSlice(ctx.alloc);
}

/// One `[replace."spec"]` entry per key. Specs are `name` or `name:version`
/// (cargo's `PackageIdSpec` surface used by `[replace]`); anything else is
/// `InvalidManifest`. Matching itself is `matchReplaceSpec` (query time).
fn parseReplaceTable(ctx: ParseCtx, t: *const toml.TomlTable) ManifestSurfaceError![]ReplaceEntry {
    var entries: std.ArrayList(ReplaceEntry) = .empty;
    var it = t.entries.iterator();
    while (it.next()) |kv| {
        if (!validReplaceSpec(kv.key_ptr.*)) {
            surfaceFail("{s}:{d}: invalid [replace] spec `{s}` (must be `name` or `name:version`)", .{ ctx.filename, kv.value_ptr.span.line, kv.key_ptr.* });
            return ManifestSurfaceError.InvalidManifest;
        }
        if (kv.value_ptr.value != .table) {
            surfaceFail("{s}:{d}: invalid [replace.\"{s}\"] (must be a table)", .{ ctx.filename, kv.value_ptr.span.line, kv.key_ptr.* });
            return ManifestSurfaceError.InvalidManifest;
        }
        const dep = try parseDepRef(ctx, kv.key_ptr.*, &kv.value_ptr.value, null, .normal);
        try entries.append(ctx.alloc, .{ .spec = kv.key_ptr.*, .dep = dep });
    }
    return try entries.toOwnedSlice(ctx.alloc);
}

fn validReplaceSpec(spec: []const u8) bool {
    if (spec.len == 0) return false;
    var parts: usize = 0;
    var it = std.mem.splitScalar(u8, spec, ':');
    while (it.next()) |p| {
        parts += 1;
        if (parts > 2 or p.len == 0) return false;
        for (p) |c| {
            if (c == ' ' or c == '\t') return false;
        }
    }
    return true;
}

/// Query-time spec test (`dep_cache.rs` replacement block): `name` matches
/// any version; `name:version` matches that rendered version exactly.
pub fn matchReplaceSpec(spec: []const u8, name: []const u8, version: ?[]const u8) bool {
    if (std.mem.indexOfScalar(u8, spec, ':')) |i| {
        const v = version orelse return false;
        return std.mem.eql(u8, spec[0..i], name) and std.mem.eql(u8, spec[i + 1 ..], v);
    }
    return std.mem.eql(u8, spec, name);
}

/// `dep_cache.rs` replacement-block wordings, copied verbatim. Produced at
/// query time by the resolver driver (Task-10 oracle); constructors here so
/// the text is pinned by unit tests next to the parser.
pub fn replaceNoMatchMessage(gpa: std.mem.Allocator, spec: []const u8, source: []const u8, req: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "no matching package for override `{s}` found\nlocation searched: {s}\nversion required: {s}", .{ spec, source, req });
}

pub fn replaceMultipleMessage(gpa: std.mem.Allocator, spec: []const u8, first_id: []const u8, rest_ids: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const head = try std.fmt.allocPrint(gpa, "the replacement specification `{s}` matched multiple packages:\n  * {s}\n", .{ spec, first_id });
    defer gpa.free(head);
    try out.appendSlice(gpa, head);
    for (rest_ids) |id| {
        const line = try std.fmt.allocPrint(gpa, "  * {s}\n", .{id});
        defer gpa.free(line);
        try out.appendSlice(gpa, line);
    }
    return out.toOwnedSlice(gpa);
}

pub fn replaceDriftMessage(gpa: std.mem.Allocator, spec: []const u8, matched_version: []const u8, replacement_version: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "replacement specification `{s}` matched {s} and tried to override it with {s}\navoid matching unrelated packages by being more specific", .{ spec, matched_version, replacement_version });
}

/// One entry of a `[dependencies]`-shaped table (normal, dev, build,
/// target-scoped, `[patch.*]`, `[replace.*]`, `[workspace.dependencies]`).
/// String form is a bare version req; table form carries the full Trio
/// (rename via `package`, source via `version`/`path`/`git`/`registry`,
/// `optional`, `default-features`, `features`, `workspace` inheritance).
/// Precedence matches M1 `parseDep` (path, git, workspace-inherit,
/// version) so `base.deps` and `renamed` never disagree on the source.
fn parseDepRef(ctx: ParseCtx, key: []const u8, val: *const toml.TomlValue, target: ?[]const u8, dep_kind: DepTableKind) ManifestSurfaceError!DepRef {
    if (val.* == .string) {
        try validatedReq(ctx, key, val.string);
        return .{
            .key = key,
            .package = null,
            .kind = .{ .version_req = val.string },
            .version = null,
            .registry_url = null,
            .optional = false,
            .default_features = true,
            .features = &.{},
            .target = target,
            .dep_kind = dep_kind,
        };
    }
    const t = &val.table;
    // Key audit FIRST (loud-before-anything: silent divergence is a
    // conformance bug, plan section 0.7). Deferred-unstable manifest keys
    // fail as UnsupportedManifestForm; anything else unknown fails as
    // UnsupportedKey. Both name the key (M1 D2 rule).
    var it = t.entries.iterator();
    while (it.next()) |kv| {
        switch (keyClass(kv.key_ptr.*)) {
            .known => {},
            .unstable => {
                surfaceFail("{s}:{d}: unsupported manifest form `{s}` on dependency `{s}` (names `-Zbindeps`)", .{ ctx.filename, kv.value_ptr.span.line, kv.key_ptr.*, key });
                return ManifestSurfaceError.UnsupportedManifestForm;
            },
            .unknown => {
                surfaceFail("{s}:{d}: unknown key `{s}` on dependency `{s}`", .{ ctx.filename, kv.value_ptr.span.line, kv.key_ptr.*, key });
                return ManifestSurfaceError.UnsupportedKey;
            },
        }
    }
    // Type audit for known keys (wrong-typed values are InvalidManifest,
    // never silent -- e.g. `workspace = "yes"` must not read as absent).
    const string_keys = [_][]const u8{ "version", "path", "git", "branch", "tag", "rev", "registry", "package" };
    for (string_keys) |sk| {
        if (t.get(sk)) |v| {
            if (v.* != .string) {
                surfaceFail("{s}: dependency `{s}` key `{s}` must be a string", .{ ctx.filename, key, sk });
                return ManifestSurfaceError.InvalidManifest;
            }
        }
    }
    const bool_keys = [_][]const u8{ "workspace", "optional", "default-features", "default_features" };
    for (bool_keys) |bk| {
        if (t.get(bk)) |v| {
            if (v.* != .boolean) {
                surfaceFail("{s}: dependency `{s}` key `{s}` must be a boolean", .{ ctx.filename, key, bk });
                return ManifestSurfaceError.InvalidManifest;
            }
        }
    }
    const workspace = boolKey(t, "workspace");
    const package = stringKey(t, "package");
    const version = stringKey(t, "version");
    const path = stringKey(t, "path");
    const git = stringKey(t, "git");
    const registry = stringKey(t, "registry");
    if (workspace) {
        // `{ workspace = true }` accepts ONLY feature/optional overrides
        // alongside (cargo's `TomlInheritedDependency` has no source or
        // rename fields); anything else is an unknown-key-class error.
        for ([_]?[]const u8{ version, path, git, registry, package }) |present| {
            if (present != null) {
                surfaceFail("{s}: dependency `{s}` cannot combine `workspace = true` with an explicit source", .{ ctx.filename, key });
                return ManifestSurfaceError.UnsupportedKey;
            }
        }
        if (t.get("branch") != null or t.get("tag") != null or t.get("rev") != null) {
            surfaceFail("{s}: dependency `{s}` cannot combine `workspace = true` with an explicit source", .{ ctx.filename, key });
            return ManifestSurfaceError.UnsupportedKey;
        }
        return .{
            .key = key,
            .package = null,
            .kind = .workspace_inherit,
            .version = null,
            .registry_url = null,
            .optional = optFlag(t, "optional"),
            .default_features = dfFlag(t),
            .features = try stringList(ctx, t, "features", key),
            .target = target,
            .dep_kind = dep_kind,
        };
    }
    if (package != null and version == null and path == null and git == null) {
        surfaceFail("{s}: dependency `{s}` renames `{s}` without a source (needs `version`, `path`, or `git`)", .{ ctx.filename, key, package.? });
        return ManifestSurfaceError.InvalidManifest;
    }
    if (registry != null and version == null) {
        surfaceFail("{s}: dependency `{s}` sets `registry` without `version`", .{ ctx.filename, key });
        return ManifestSurfaceError.InvalidManifest;
    }
    const kind: DependencyKind = if (path) |p|
        .{ .path = p }
    else if (git) |u|
        .{ .git = .{ .url = u, .ref = try gitRefOf(t) } }
    else if (version) |v| blk: {
        try validatedReq(ctx, key, v);
        break :blk .{ .version_req = v };
    } else {
        surfaceFail("{s}: dependency `{s}` has no source (needs `version`, `path`, `git`, or `workspace = true`)", .{ ctx.filename, key });
        return ManifestSurfaceError.InvalidManifest;
    };
    return .{
        .key = key,
        .package = package,
        .kind = kind,
        .version = version,
        .registry_url = registry,
        .optional = optFlag(t, "optional"),
        .default_features = dfFlag(t),
        .features = try stringList(ctx, t, "features", key),
        .target = target,
        .dep_kind = dep_kind,
    };
}

const DepKeyClass = enum { known, unstable, unknown };

fn keyClass(key: []const u8) DepKeyClass {
    const known = [_][]const u8{ "version", "path", "git", "branch", "tag", "rev", "registry", "package", "optional", "default-features", "default_features", "features", "workspace" };
    for (known) |k| {
        if (std.mem.eql(u8, key, k)) return .known;
    }
    // Deferred-unstable surface (plan section 0.6/Task-12 table): NEVER a
    // parse error on INDEX lines (carried verbatim there), but manifest-side
    // keys pass cargo's unstable gate, so rime fails loudly instead of
    // diverging. NOTE: stable-cargo `public` (RFC 1977) is intentionally
    // loud here too -- rime M3 implements no public-dep semantics, and a
    // loud rejection beats silent divergence; a later lane can relax this
    // single arm to passthrough without touching the parser.
    const unstable = [_][]const u8{ "artifact", "public", "bindep-target", "bindep_target", "lib" };
    for (unstable) |k| {
        if (std.mem.eql(u8, key, k)) return .unstable;
    }
    return .unknown;
}

fn validatedReq(ctx: ParseCtx, key: []const u8, req: []const u8) ManifestSurfaceError!void {
    _ = semver.VersionReq.parse(req) catch |e| switch (e) {
        error.OutOfMemory => return ManifestSurfaceError.OutOfMemory,
        error.InvalidVersion, error.InvalidReq => {
            surfaceFail("{s}: dependency `{s}` has an invalid version requirement `{s}`", .{ ctx.filename, key, req });
            return ManifestSurfaceError.InvalidManifest;
        },
    };
}

fn stringKey(t: *const toml.TomlTable, key: []const u8) ?[]const u8 {
    const v = t.get(key) orelse return null;
    if (v.* != .string) return null;
    return v.string;
}

fn boolKey(t: *const toml.TomlTable, key: []const u8) bool {
    const v = t.get(key) orelse return false;
    if (v.* != .boolean) return false;
    return v.boolean;
}

/// `optional = true` iff explicitly set (absent is false, cargo default).
fn optFlag(t: *const toml.TomlTable, key: []const u8) bool {
    return boolKey(t, key);
}

/// `default-features` (hyphen wins over underscore when both present, per
/// cargo-util-schemas `default_features.or(default_features2)`); absent is
/// true (cargo default).
fn dfFlag(t: *const toml.TomlTable) bool {
    if (t.get("default-features")) |v| {
        if (v.* == .boolean) return v.boolean;
    }
    if (t.get("default_features")) |v| {
        if (v.* == .boolean) return v.boolean;
    }
    return true;
}

fn gitRefOf(t: *const toml.TomlTable) ManifestSurfaceError!?[]const u8 {
    if (t.get("rev")) |v| {
        if (v.* != .string) return ManifestSurfaceError.InvalidManifest;
        return v.string;
    }
    if (t.get("branch")) |v| {
        if (v.* != .string) return ManifestSurfaceError.InvalidManifest;
        return v.string;
    }
    if (t.get("tag")) |v| {
        if (v.* != .string) return ManifestSurfaceError.InvalidManifest;
        return v.string;
    }
    return null;
}

fn stringList(ctx: ParseCtx, t: *const toml.TomlTable, key: []const u8, dep_key: []const u8) ManifestSurfaceError![]const []const u8 {
    const v = t.get(key) orelse return &.{};
    if (v.* != .array) {
        surfaceFail("{s}: dependency `{s}` key `{s}` must be an array of strings", .{ ctx.filename, dep_key, key });
        return ManifestSurfaceError.InvalidManifest;
    }
    var list: std.ArrayList([]const u8) = .empty;
    for (v.array) |*item| {
        if (item.* != .string) {
            surfaceFail("{s}: dependency `{s}` key `{s}` must be an array of strings", .{ ctx.filename, dep_key, key });
            return ManifestSurfaceError.InvalidManifest;
        }
        try list.append(ctx.alloc, item.string);
    }
    return try list.toOwnedSlice(ctx.alloc);
}

/// `{ workspace = true }` expansion (`core/workspace.rs` inheritance +
/// `util/toml/mod.rs::inner_dependency_inherit_with` merge: features are
/// CONCATENATED workspace-then-member; `optional`/`default-features` take
/// the member-explicit-true over workspace-false, never the reverse --
/// plain OR, which is exact here because workspace deps can never be
/// optional and the only divergence is cargo's edition-2024 hard error on
/// explicit member `default-features = false`, documented as a known
/// limitation). Consumes `member` (mutated and returned); `root` is
/// read-only -- despite the by-value shape the caller retains ownership
/// and deinits the original root exactly once (copies share arenas; never
/// deinit the passed copy). Package version/edition/rust-version fill from
/// `[workspace.package]`; anything the workspace lacks is `UnknownInherit`
/// naming the key and the member file.
pub fn resolveInheritance(gpa: std.mem.Allocator, member: ManifestExt, root: ManifestExt) ManifestSurfaceError!ManifestExt {
    _ = gpa;
    var m = member;
    // `member` is consumed: success transfers ownership to the caller (who
    // deinits the result); failure frees it here (the caller cannot -- it
    // was moved). `root` is never consumed either way.
    errdefer {
        m.base.deinit();
        m.doc_arena.deinit();
    }
    const alloc = m.doc_arena.allocator();
    if (m.base.pkg != null) {
        if (m.base.version_inherited) {
            const w = root.base.ws_version orelse {
                surfaceFail("{s}: cannot inherit `version`: workspace has no `[workspace.package] version`", .{m.filename});
                return ManifestSurfaceError.UnknownInherit;
            };
            m.base.pkg.?.version = try alloc.dupe(u8, w);
            m.base.version_inherited = false;
        }
        if (m.base.edition_inherited) {
            const w = root.base.ws_edition orelse {
                surfaceFail("{s}: cannot inherit `edition`: workspace has no `[workspace.package] edition`", .{m.filename});
                return ManifestSurfaceError.UnknownInherit;
            };
            m.base.pkg.?.edition = try alloc.dupe(u8, w);
            m.base.edition_inherited = false;
        }
        if (m.base.rust_version_inherited) {
            const w = root.base.ws_rust_version orelse {
                surfaceFail("{s}: cannot inherit `rust-version`: workspace has no `[workspace.package] rust-version`", .{m.filename});
                return ManifestSurfaceError.UnknownInherit;
            };
            m.base.rust_version = try alloc.dupe(u8, w);
            m.base.rust_version_inherited = false;
        }
    }
    // `[workspace.dependencies]` path values are relative to the
    // WORKSPACE ROOT manifest, while member-level `path` values are relative
    // to the member manifest. After the merge the origin is lost, so
    // inherited path deps are rebased to root-joined form HERE (member-local
    // ones are joined at walk time by the consumer). Root-joined form is
    // still correct for every consumer: joining is idempotent on joined
    // paths and absolute paths pass through.
    const ws_dir = std.fs.path.dirname(root.filename);
    for (m.renamed) |*d| try inheritDepRef(alloc, d, &root, m.filename, ws_dir);
    for (m.target_deps) |*d| try inheritDepRef(alloc, d, &root, m.filename, ws_dir);
    for (m.patches) |*p| {
        for (p.deps) |*d| try inheritDepRef(alloc, d, &root, m.filename, ws_dir);
    }
    return m;
}

fn inheritDepRef(alloc: std.mem.Allocator, d: *DepRef, root: *const ManifestExt, filename: []const u8, ws_dir: ?[]const u8) ManifestSurfaceError!void {
    if (d.kind != .workspace_inherit) return;
    var found: ?DepRef = null;
    for (root.workspace_deps) |w| {
        if (std.mem.eql(u8, w.key, d.key)) {
            found = w;
            break;
        }
    }
    const w = found orelse {
        surfaceFail("{s}: cannot inherit dependency `{s}`: workspace has no `[workspace.dependencies.{s}]`", .{ filename, d.key, d.key });
        return ManifestSurfaceError.UnknownInherit;
    };
    // Merge (workspace base, member overlay): features concatenate
    // workspace-then-member; optional/default-features OR (exact per the
    // resolveInheritance doc comment). Everything dupes into the member
    // arena; the member key/target/dep_kind are kept.
    var feats: std.ArrayList([]const u8) = .empty;
    try feats.appendSlice(alloc, w.features);
    try feats.appendSlice(alloc, d.features);
    d.package = if (w.package) |p| try alloc.dupe(u8, p) else null;
    d.kind = try dupeKind(alloc, w.kind);
    if (d.kind == .path) {
        if (ws_dir) |base| {
            if (!std.fs.path.isAbsolute(d.kind.path)) {
                d.kind.path = try std.fs.path.join(alloc, &.{ base, d.kind.path });
            }
        }
    }
    d.version = if (w.version) |v| try alloc.dupe(u8, v) else null;
    d.registry_url = if (w.registry_url) |u| try alloc.dupe(u8, u) else null;
    d.optional = d.optional or w.optional;
    d.default_features = d.default_features or w.default_features;
    d.features = try feats.toOwnedSlice(alloc);
}

fn dupeKind(alloc: std.mem.Allocator, kind: DependencyKind) ManifestSurfaceError!DependencyKind {
    return switch (kind) {
        .version_req => |s| .{ .version_req = try alloc.dupe(u8, s) },
        .path => |s| .{ .path = try alloc.dupe(u8, s) },
        .git => |g| .{ .git = .{
            .url = try alloc.dupe(u8, g.url),
            .ref = if (g.ref) |r| try alloc.dupe(u8, r) else null,
        } },
        .workspace_inherit => ManifestSurfaceError.InvalidManifest,
    };
}

test "manifest parses renames and target tables" {
    const text =
        "[package]\nname = \"a\"\nversion = \"0.1.0\"\nedition = \"2021\"\n" ++
        "[dependencies]\nold = { package = \"real-crate\", version = \"^1\", optional = true }\n" ++
        "[target.'cfg(windows)'.dependencies]\nwin-only = \"2.0\"\n";
    var m = try parseManifestExt(std.testing.allocator, text, "Cargo.toml");
    defer m.deinit();
    try std.testing.expectEqualStrings("real-crate", m.renamed[0].realName());
    try std.testing.expect(m.renamed[0].optional);
    try std.testing.expectEqualStrings("cfg(windows)", m.target_deps[0].target.?);
}

test "manifest inheritance expands workspace deps" {
    const root_text = "[workspace]\n[workspace.package]\nversion = \"0.2.0\"\nedition = \"2021\"\n[workspace.dependencies]\nserde = \"1.0\"\n";
    const mem_text = "[package]\nname = \"m\"\nversion.workspace = true\nedition.workspace = true\n[dependencies]\nserde.workspace = true\n";
    var root = try parseManifestExt(std.testing.allocator, root_text, "root/Cargo.toml");
    defer root.deinit();
    const mem = try parseManifestExt(std.testing.allocator, mem_text, "root/m/Cargo.toml");
    var resolved = try resolveInheritance(std.testing.allocator, mem, root);
    defer resolved.deinit();
    try std.testing.expectEqualStrings("0.2.0", resolved.base.pkg.?.version);
    try std.testing.expectEqualStrings("2021", resolved.base.pkg.?.edition);
    try std.testing.expect(!resolved.base.version_inherited);
    try std.testing.expectEqualStrings("1.0", resolved.renamed[0].kind.version_req);
    try std.testing.expectEqualStrings("serde", resolved.renamed[0].realName());
}

test "manifest rejects unknown keys loudly" {
    surface_diag_len = 0;
    const err = parseManifestExt(std.testing.allocator, "[package]\nname = \"a\"\nversion = \"0.1.0\"\n[dependencies]\nx = { version = \"1\", artifact = [\"bin\"] }\n", "Cargo.toml");
    try std.testing.expectError(ManifestSurfaceError.UnsupportedManifestForm, err);
    const diag = surfaceDiagnostic().?;
    try std.testing.expect(std.mem.indexOf(u8, diag, "artifact") != null);
    try std.testing.expect(std.mem.indexOf(u8, diag, "Cargo.toml") != null);
}

test "manifest rejects unknown dep keys as UnsupportedKey" {
    const err = parseManifestExt(std.testing.allocator, "[package]\nname = \"a\"\nversion = \"0.1.0\"\n[dependencies]\nx = { version = \"1\", warp = true }\n", "Cargo.toml");
    try std.testing.expectError(ManifestSurfaceError.UnsupportedKey, err);
    try std.testing.expect(std.mem.indexOf(u8, surfaceDiagnostic().?, "warp") != null);
}

test "manifest validates version reqs and cfgs at parse time" {
    try std.testing.expectError(ManifestSurfaceError.InvalidManifest, parseManifestExt(std.testing.allocator, "[package]\nname = \"a\"\nversion = \"0.1.0\"\n[dependencies]\nx = \"not a req!!!\"\n", "Cargo.toml"));
    try std.testing.expectError(ManifestSurfaceError.InvalidManifest, parseManifestExt(std.testing.allocator, "[package]\nname = \"a\"\nversion = \"0.1.0\"\n[target.'cfg(all( windows)'.dependencies]\nx = \"1\"\n", "Cargo.toml"));
}

test "manifest rejects workspace-optional deps" {
    // Pinned-cargo wording ("X is optional, but workspace dependencies
    // cannot be optional") is recorded in the diagnostic; the code is
    // InvalidManifest (a semantic rule, not unknown surface).
    const err = parseManifestExt(std.testing.allocator, "[workspace]\n[workspace.dependencies]\nx = { version = \"1\", optional = true }\n", "Cargo.toml");
    try std.testing.expectError(ManifestSurfaceError.InvalidManifest, err);
    try std.testing.expect(std.mem.indexOf(u8, surfaceDiagnostic().?, "cannot be optional") != null);
}

test "manifest unknown inherit names the key and member file" {
    var root = try parseManifestExt(std.testing.allocator, "[workspace]\n", "root/Cargo.toml");
    defer root.deinit();
    const mem = try parseManifestExt(std.testing.allocator, "[package]\nname = \"m\"\nversion.workspace = true\n", "root/m/Cargo.toml");
    const err = resolveInheritance(std.testing.allocator, mem, root);
    try std.testing.expectError(ManifestSurfaceError.UnknownInherit, err);
    try std.testing.expect(std.mem.indexOf(u8, surfaceDiagnostic().?, "version") != null);
    try std.testing.expect(std.mem.indexOf(u8, surfaceDiagnostic().?, "root/m/Cargo.toml") != null);
}

test "manifest merges inherited dep features workspace-first" {
    const root_text = "[workspace]\n[workspace.dependencies]\nserde = { version = \"1\", features = [\"derive\"], default-features = false }\n";
    const mem_text = "[package]\nname = \"m\"\nversion = \"0.1.0\"\n[dependencies]\nserde = { workspace = true, features = [\"std\"] }\n";
    var root = try parseManifestExt(std.testing.allocator, root_text, "root/Cargo.toml");
    defer root.deinit();
    const mem = try parseManifestExt(std.testing.allocator, mem_text, "root/m/Cargo.toml");
    var resolved = try resolveInheritance(std.testing.allocator, mem, root);
    defer resolved.deinit();
    const d = resolved.renamed[0];
    try std.testing.expectEqualStrings("1", d.kind.version_req);
    // Workspace features first, then the member overlay.
    try std.testing.expectEqual(@as(usize, 2), d.features.len);
    try std.testing.expectEqualStrings("derive", d.features[0]);
    try std.testing.expectEqualStrings("std", d.features[1]);
    // Member `default-features = true` (default) overrides workspace false.
    try std.testing.expect(d.default_features);
}

test "patch preferences avoid non-patch locked versions" {
    const gpa = std.testing.allocator;
    var m = try parseManifestExt(gpa, "[package]\nname = \"app\"\nversion = \"0.1.0\"\n[dependencies]\nlog = \"1\"\n[patch.crates-io]\nlog = { path = \"vendor-log\" }\n", "Cargo.toml");
    defer m.deinit();
    try std.testing.expectEqual(@as(usize, 1), m.patches.len);
    try std.testing.expectEqualStrings("crates-io", m.patches[0].source);
    const reg: sources.SourceId = .{ .registry = "sparse+https://github.com/rust-lang/crates.io-index" };
    const log_prev_deps = [_]resolve_mod.ResolvedRef{};
    const previous = [_]resolve_mod.ResolvedNode{
        .{ .name = "log", .version = try semver.Version.parse("1.0.0"), .source = reg, .deps = &log_prev_deps },
    };
    const pvs = [_]PatchVersion{.{ .name = "log", .version = try semver.Version.parse("1.0.5") }};
    const prefs = try m.patchPreferences(gpa, &previous, &pvs);
    defer gpa.free(prefs.prefer);
    defer gpa.free(prefs.avoid_locked);
    // previous log=1.0.0 shadowed by the patch table; 1.0.5 preferred.
    try std.testing.expectEqual(@as(usize, 1), prefs.prefer.len);
    try std.testing.expect(prefs.prefer[0].version.eql(try semver.Version.parse("1.0.5")));
    try std.testing.expectEqualStrings("log", prefs.prefer[0].name);
    try std.testing.expectEqual(@as(usize, 1), prefs.avoid_locked.len);
    try std.testing.expect(prefs.avoid_locked[0].eql(try semver.Version.parse("1.0.0")));
}

test "patch preferences keep the locked version when it is the patch" {
    const gpa = std.testing.allocator;
    var m = try parseManifestExt(gpa, "[package]\nname = \"app\"\nversion = \"0.1.0\"\n[dependencies]\nlog = \"1\"\n[patch.crates-io]\nlog = { path = \"vendor-log\" }\n", "Cargo.toml");
    defer m.deinit();
    const reg: sources.SourceId = .{ .registry = "sparse+https://github.com/rust-lang/crates.io-index" };
    const previous = [_]resolve_mod.ResolvedNode{
        .{ .name = "log", .version = try semver.Version.parse("1.0.5"), .source = .{ .path = "" }, .deps = &.{} },
    };
    const pvs = [_]PatchVersion{.{ .name = "log", .version = try semver.Version.parse("1.0.5") }};
    const prefs = try m.patchPreferences(gpa, &previous, &pvs);
    defer gpa.free(prefs.prefer);
    defer gpa.free(prefs.avoid_locked);
    try std.testing.expectEqual(@as(usize, 0), prefs.avoid_locked.len);
    _ = reg;
}

test "replace spec matching and messages name the spec" {
    // Two replacement candidates -> the dep_cache.rs "matched multiple
    // packages" wording; no candidates -> "no matching package for
    // override"; version drift -> "tried to override it with".
    const gpa = std.testing.allocator;
    try std.testing.expect(matchReplaceSpec("serde", "serde", "1.0.0"));
    try std.testing.expect(matchReplaceSpec("serde:1.0.0", "serde", "1.0.0"));
    try std.testing.expect(!matchReplaceSpec("serde:1.0.0", "serde", "1.0.1"));
    try std.testing.expect(!matchReplaceSpec("log", "serde", "1.0.0"));
    try std.testing.expect(!matchReplaceSpec("serde:1.0.0", "serde", null));
    const multi = try replaceMultipleMessage(gpa, "log:1.0", "log 1.0.0", &.{ "log 1.0.0 (other-source)" });
    defer gpa.free(multi);
    try std.testing.expect(std.mem.indexOf(u8, multi, "matched multiple packages") != null);
    try std.testing.expect(std.mem.indexOf(u8, multi, "log:1.0") != null);
    const nomatch = try replaceNoMatchMessage(gpa, "log:9.9", "sparse+https://x", "^9.9");
    defer gpa.free(nomatch);
    try std.testing.expect(std.mem.indexOf(u8, nomatch, "no matching package for override `log:9.9` found") != null);
    const drift = try replaceDriftMessage(gpa, "log", "1.0.0", "2.0.0");
    defer gpa.free(drift);
    try std.testing.expect(std.mem.indexOf(u8, drift, "tried to override it with 2.0.0") != null);
    // And the table itself parses (spec + replacement dep).
    var m = try parseManifestExt(gpa, "[package]\nname = \"a\"\nversion = \"0.1.0\"\n[dependencies]\nlog = \"1\"\n[replace.\"log:1.0.0\"]\npath = \"vendor-log\"\n", "Cargo.toml");
    defer m.deinit();
    try std.testing.expectEqual(@as(usize, 1), m.replaces.len);
    try std.testing.expectEqualStrings("log:1.0.0", m.replaces[0].spec);
    try std.testing.expectError(ManifestSurfaceError.InvalidManifest, parseManifestExt(gpa, "[package]\nname = \"a\"\nversion = \"0.1.0\"\n[replace.\"bad spec\"]\npath = \"x\"\n", "Cargo.toml"));
}

test "resolver field validates" {
    const gpa = std.testing.allocator;
    var ok = try parseManifestExt(gpa, "[workspace]\nresolver = \"2\"\n", "Cargo.toml");
    defer ok.deinit();
    try std.testing.expectEqualStrings("2", ok.resolver.?);
    var pkg = try parseManifestExt(gpa, "[package]\nname = \"a\"\nversion = \"0.1.0\"\nresolver = \"3\"\n", "Cargo.toml");
    defer pkg.deinit();
    try std.testing.expectEqualStrings("3", pkg.resolver.?);
    try std.testing.expectError(ManifestSurfaceError.InvalidManifest, parseManifestExt(gpa, "[workspace]\nresolver = \"4\"\n", "Cargo.toml"));
    // from_manifest wording, verbatim.
    try std.testing.expect(std.mem.indexOf(u8, surfaceDiagnostic().?, "`resolver` setting `4` is not valid, valid options are \"1\", \"2\" or \"3\"") != null);
}

test "manifest parses the validation corpus roots" {
    // parseManifestExt must tolerate the full breadth of the committed
    // validation manifests (profiles, package.metadata, target tables,
    // patch tables, dotted dependency subtables).
    const io = std.Io.Threaded.global_single_threaded.io();
    const cases = [_]struct { path: []const u8, resolver: ?[]const u8, patches: usize }{
        .{ .path = "validation/basic-workspace/Cargo.toml", .resolver = "2", .patches = 0 },
        .{ .path = "validation/feature-matrix/Cargo.toml", .resolver = "2", .patches = 0 },
        .{ .path = "validation/lockfile-golden/Cargo.toml", .resolver = null, .patches = 0 },
        .{ .path = "validation/full-manifest/Cargo.toml", .resolver = null, .patches = 1 },
    };
    for (cases) |c| {
        const text = try std.Io.Dir.cwd().readFileAlloc(io, c.path, std.testing.allocator, .limited(1 << 20));
        defer std.testing.allocator.free(text);
        var m = try parseManifestExt(std.testing.allocator, text, c.path);
        defer m.deinit();
        if (c.resolver) |r| {
            try std.testing.expectEqualStrings(r, m.resolver.?);
        } else {
            try std.testing.expect(m.resolver == null);
        }
        try std.testing.expectEqual(c.patches, m.patches.len);
    }
    // feature-matrix renames + target tables + dotted optional dep.
    const fm_text = try std.Io.Dir.cwd().readFileAlloc(io, "validation/feature-matrix/Cargo.toml", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(fm_text);
    var fm = try parseManifestExt(std.testing.allocator, fm_text, "validation/feature-matrix/Cargo.toml");
    defer fm.deinit();
    var saw_ureq = false;
    var saw_json_opt = false;
    var saw_json_dev = false;
    for (fm.renamed) |d| {
        if (std.mem.eql(u8, d.key, "http_client")) {
            try std.testing.expectEqualStrings("ureq", d.realName());
            try std.testing.expect(d.optional);
            saw_ureq = true;
        }
        if (std.mem.eql(u8, d.key, "serde_json") and d.dep_kind == .normal) {
            try std.testing.expect(d.optional);
            saw_json_opt = true;
        }
        if (std.mem.eql(u8, d.key, "serde_json") and d.dep_kind == .dev) {
            try std.testing.expect(!d.optional);
            saw_json_dev = true;
        }
    }
    try std.testing.expect(saw_ureq);
    try std.testing.expect(saw_json_opt);
    try std.testing.expect(saw_json_dev);
    try std.testing.expectEqual(@as(usize, 2), fm.target_deps.len);
    // full-manifest patch table + dotted serde_json optional dep.
    const full_text = try std.Io.Dir.cwd().readFileAlloc(io, "validation/full-manifest/Cargo.toml", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(full_text);
    var full = try parseManifestExt(std.testing.allocator, full_text, "validation/full-manifest/Cargo.toml");
    defer full.deinit();
    try std.testing.expectEqualStrings("crates-io", full.patches[0].source);
    try std.testing.expectEqualStrings("smallvec", full.patches[0].deps[0].key);
    var saw_json = false;
    for (full.renamed) |d| {
        if (std.mem.eql(u8, d.key, "serde_json") and d.dep_kind == .normal) saw_json = true;
    }
    try std.testing.expect(saw_json);
}

test "manifest inherits rust-version from workspace package" {
    const root_text = "[workspace]\n[workspace.package]\nversion = \"0.1.0\"\nedition = \"2021\"\nrust-version = \"1.77\"\n";
    const mem_text = "[package]\nname = \"m\"\nversion.workspace = true\nedition.workspace = true\nrust-version.workspace = true\n";
    var root = try parseManifestExt(std.testing.allocator, root_text, "root/Cargo.toml");
    defer root.deinit();
    try std.testing.expectEqualStrings("1.77", root.base.ws_rust_version.?);
    const mem = try parseManifestExt(std.testing.allocator, mem_text, "root/m/Cargo.toml");
    var resolved = try resolveInheritance(std.testing.allocator, mem, root);
    defer resolved.deinit();
    try std.testing.expectEqualStrings("1.77", resolved.base.rust_version.?);
}

test "manifest rejects bad patch sources and invalid specs" {
    try std.testing.expectError(ManifestSurfaceError.InvalidManifest, parseManifestExt(std.testing.allocator, "[package]\nname = \"a\"\nversion = \"0.1.0\"\n[patch.nosuchsource]\nx = \"1\"\n", "Cargo.toml"));
    try std.testing.expectError(ManifestSurfaceError.UnsupportedKey, parseManifestExt(std.testing.allocator, "[package]\nname = \"a\"\nversion = \"0.1.0\"\n[dependencies]\nx = { workspace = true, version = \"1\" }\n", "Cargo.toml"));
}

test "manifest parses registry-keyed deps with the url sidecar" {
    // The M1 union has no registry variant (workspace.zig dupeDep is
    // exhaustive), so the URL rides in `registry_url` while `kind` stays
    // `.version_req` -- no information lost, base.deps compatible.
    var m = try parseManifestExt(std.testing.allocator, "[package]\nname = \"a\"\nversion = \"0.1.0\"\n[dependencies]\nx = { version = \"1\", registry = \"https://example.com/index\" }\n", "Cargo.toml");
    defer m.deinit();
    try std.testing.expectEqualStrings("1", m.renamed[0].kind.version_req);
    try std.testing.expectEqualStrings("https://example.com/index", m.renamed[0].registry_url.?);
    try std.testing.expectError(ManifestSurfaceError.InvalidManifest, parseManifestExt(std.testing.allocator, "[package]\nname = \"a\"\nversion = \"0.1.0\"\n[dependencies]\nx = { registry = \"https://example.com/index\" }\n", "Cargo.toml"));
}

test "manifest parses feature tables" {
    var m = try parseManifestExt(std.testing.allocator, "[package]\nname = \"a\"\nversion = \"0.1.0\"\n[features]\ndefault = [\"std\"]\nfull = [\"dep:opt\", \"other/feat\", \"weak?/wfeat\", \"own-feat\"]\n[dependencies]\nopt = { version = \"1\", optional = true }\n", "Cargo.toml");
    defer m.deinit();
    try std.testing.expectEqual(@as(usize, 2), m.features.len);
    try std.testing.expectError(ManifestSurfaceError.InvalidManifest, parseManifestExt(std.testing.allocator, "[package]\nname = \"a\"\nversion = \"0.1.0\"\n[features]\nbad = \"nope\"\n", "Cargo.toml"));
}
