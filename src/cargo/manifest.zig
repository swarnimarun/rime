const std = @import("std");
const toml = @import("toml.zig"); // wired via the cargo module; see build.zig note in Plan C Task 5

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
    ws_version: ?[]const u8,
    ws_edition: ?[]const u8,
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
        .ws_version = null,
        .ws_edition = null,
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
