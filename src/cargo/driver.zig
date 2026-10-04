//! Unit graph construction (M4 Task 3): workspace members × targets →
//! compile units with resolved inter-member edges.
//!
//! Mirrors cargo's `core/compiler/unit.rs::Unit` field-for-field (`pkg`,
//! `target`, `profile`, `CompileKind`, `CompileMode`, sorted `features`),
//! with `deps` as resolved `UnitDep`s carrying `unit_graph.rs`'s
//! `{ unit, extern_crate_name, dep_name }` triple.
//!
//! Scope: workspace members only (registry refs are SOURCES, not units —
//! their rlibs arrive via fetch + prior compilation; a registry dep with no
//! store entry errors at invoke time in Task 10, never here). Every M4 unit
//! is `CompileKind.target`; the `CompileKind` field, `forHostTarget`, and
//! the Task-6 `prefer-dynamic` hook exist so M5 can wire build-script /
//! proc-macro host units without changing unit identity.
//!
//! Ownership: `UnitGraph.arena` owns every `deps` slice, `extern_name`,
//! `features_sorted` copy (slice plus each duped feature string), and
//! default-target name (`deinit` frees all).
//! All other strings borrow the `Workspace` (member manifests/arena), the
//! `Unified` maps (copied into the arena — the graph outlives them), the
//! `Toolchain` (`target_triple` fallback), or statics (`crate_types`).

const std = @import("std");
const manifest_mod = @import("manifest.zig");
const workspace_mod = @import("workspace.zig");
const resolve_mod = @import("resolve.zig");
const features_mod = @import("features.zig");
const profile_mod = @import("profile.zig");
const toolchain_mod = @import("toolchain.zig");

const Workspace = workspace_mod.Workspace;
const ResolveGraph = resolve_mod.ResolveGraph;
const Unified = features_mod.Unified;
const Profile = profile_mod.Profile;
const Toolchain = toolchain_mod.Toolchain;
const TargetKind = manifest_mod.TargetKind;

pub const DriverError = error{ UnknownTarget, NoLibOrBin, OutOfMemory };
pub const CompileKind = enum { host, target }; // compile_kind.rs::{Host, Target}
pub const CompileMode = enum { build, check }; // CompileMode::{Build, Check}

pub const UnitDep = struct {
    unit: usize, // index into UnitGraph.units
    extern_name: []const u8, // crate name with '-' -> '_' (unit_graph.rs extern_crate_name)
    dep_name: []const u8, // original package name
};

pub const Unit = struct {
    pkg_name: []const u8, // borrowed from Workspace
    version: []const u8, // borrowed from Workspace
    target_name: []const u8, // lib name or bin name (borrowed)
    kind: TargetKind, // lib | bin (example/test/bench rejected: UnknownTarget in M4)
    edition: []const u8, // borrowed ("2021")
    crate_types: []const []const u8, // lib -> &.{"rlib"}; bin -> &.{"bin"} (static)
    profile: Profile, // copied by value (name/opt_level borrow workspace/profile statics)
    features_sorted: []const []const u8, // unified enabled features, sorted (copied into graph arena)
    target_triple: []const u8, // --target or toolchain.host_target (borrowed)
    compile_kind: CompileKind, // target always in M4 (host wired by M5)
    mode: CompileMode, // build; check mode flips it in Task 11
    src_path: []const u8, // absolute crate root dir (borrowed from Workspace member dir)
    deps: []UnitDep, // owned by the UnitGraph arena
};

pub const UnitGraph = struct {
    arena: std.heap.ArenaAllocator, // owns deps slices + features_sorted copies
    units: []Unit,
    pub fn deinit(self: *UnitGraph) void {
        self.arena.deinit();
    }
    /// Kahn topological order over unit deps (deps first; alphabetical
    /// tie-break on (pkg_name, target_name), the `view.planUnits`
    /// precedent). gpa-owned indices. A stall is impossible (member cycles
    /// are rejected at discovery and only member edges become unit edges);
    /// the loud fallback is `UnknownTarget`, never a hang.
    pub fn topoOrder(self: *const UnitGraph, gpa: std.mem.Allocator) DriverError![]usize {
        const n = self.units.len;
        const indeg = gpa.alloc(usize, n) catch return DriverError.OutOfMemory;
        defer gpa.free(indeg);
        const emitted = gpa.alloc(bool, n) catch return DriverError.OutOfMemory;
        defer gpa.free(emitted);
        for (self.units, 0..) |*u, i| indeg[i] = u.deps.len;
        @memset(emitted, false);
        var order: std.ArrayList(usize) = .empty;
        errdefer order.deinit(gpa);
        while (order.items.len < n) {
            var best: ?usize = null;
            for (self.units, 0..) |*u, i| {
                if (emitted[i] or indeg[i] != 0) continue;
                if (best == null or unitLess(u, &self.units[best.?])) best = i;
            }
            const next = best orelse return DriverError.UnknownTarget;
            emitted[next] = true;
            order.append(gpa, next) catch return DriverError.OutOfMemory;
            for (self.units, 0..) |*u, i| {
                if (emitted[i]) continue;
                for (u.deps) |d| {
                    if (d.unit == next) {
                        indeg[i] -= 1;
                        break;
                    }
                }
            }
        }
        return order.toOwnedSlice(gpa) catch return DriverError.OutOfMemory;
    }
};

fn unitLess(a: *const Unit, b: *const Unit) bool {
    const pc = std.mem.order(u8, a.pkg_name, b.pkg_name);
    if (pc != .eq) return pc == .lt;
    return std.mem.order(u8, a.target_name, b.target_name) == .lt;
}

/// Host/target triple selection (`compile_kind.rs` role): host-kind units
/// compile for the toolchain host, target-kind units for `--target`.
pub fn forHostTarget(kind: CompileKind, triple: []const u8, host_target: []const u8) []const u8 {
    return switch (kind) {
        .host => host_target,
        .target => triple,
    };
}

/// `-` → `_` crate-name mapping (cargo's default-lib-name rule, also the
/// `extern_crate_name` spelling). gpa-owned dup.
pub fn externName(gpa: std.mem.Allocator, name: []const u8) DriverError![]u8 {
    const buf = gpa.dupe(u8, name) catch return DriverError.OutOfMemory;
    for (buf) |*c| {
        if (c.* == '-') c.* = '_';
    }
    return buf;
}

/// Cargo's default lib target name (copied from `view.zig`, which owns view
/// paths; driver owns unit names — 6 lines, not an import).
fn defaultLibName(alloc: std.mem.Allocator, pkg_name: []const u8) std.mem.Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, pkg_name, '-') == null) return pkg_name;
    const buf = try alloc.dupe(u8, pkg_name);
    for (buf) |*c| if (c.* == '-') {
        c.* = '_';
    };
    return buf;
}

const lib_crate_types: []const []const u8 = &.{"rlib"};
const bin_crate_types: []const []const u8 = &.{"bin"};

/// One `Unit` per workspace member target (`unit.rs::Unit`). Explicit
/// `[lib]`/`[[bin]]` targets expand in manifest order, else a single
/// default lib unit. `example`/`test`/`bench` targets → `UnknownTarget`
/// (M4 compiles lib+bin only, limitation L2); a member yielding zero
/// units → `NoLibOrBin` (unreachable through the current manifest surface,
/// which always defaults — defensive, loud).
///
/// Edges: each unit depends on the LIB unit of every dep member named by
/// the (already pruned) resolve graph (first unit when the dep member has
/// no lib — e.g. bin-only members), in graph-ref order, deduplicated.
/// Registry (non-member) refs are recorded NOWHERE on the unit (their
/// `--extern` paths resolve at invoke time from the store — Task 6). No
/// intra-member edges in M4 (a bin unit does not edge its sibling lib;
/// both list the same external deps — recorded simplification, revisited
/// if cargo-compat diffs ever show it).
pub fn buildUnitGraph(
    gpa: std.mem.Allocator,
    ws: *const Workspace,
    graph: *const ResolveGraph,
    unified: *const Unified,
    profile: Profile,
    triple: ?[]const u8,
    tc: *const Toolchain,
) DriverError!UnitGraph {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    const target_triple = triple orelse tc.host_target;

    // Member → unit index ranges (first_unit[i], unit_count[i]).
    const first_unit = alloc.alloc(usize, ws.members.len) catch return DriverError.OutOfMemory;
    const unit_count = alloc.alloc(usize, ws.members.len) catch return DriverError.OutOfMemory;
    var units: std.ArrayList(Unit) = .empty;

    for (ws.members, 0..) |*m, mi| {
        first_unit[mi] = units.items.len;
        const pkg = m.manifest.pkg orelse return DriverError.NoLibOrBin;
        if (m.manifest.targets.len == 0) {
            const tname = defaultLibName(alloc, m.name) catch return DriverError.OutOfMemory;
            try units.append(alloc, baseUnit(m, pkg.edition, tname, .lib, lib_crate_types, profile, target_triple));
        } else {
            for (m.manifest.targets) |t| {
                switch (t.kind) {
                    .lib => try units.append(alloc, baseUnit(m, pkg.edition, t.name, .lib, lib_crate_types, profile, target_triple)),
                    .bin => try units.append(alloc, baseUnit(m, pkg.edition, t.name, .bin, bin_crate_types, profile, target_triple)),
                    .example, .@"test", .bench => return DriverError.UnknownTarget,
                }
            }
        }
        unit_count[mi] = units.items.len - first_unit[mi];
        if (unit_count[mi] == 0) return DriverError.NoLibOrBin;
    }

    // Edges + features per unit (member's pruned-graph refs → member units).
    // Every list below grows from the graph arena (never deinited piecemeal;
    // the arena owns all buffers and UnitGraph.deinit frees them at once).
    for (ws.members, 0..) |*m, mi| {
        const refs = graphRefsFor(graph, m.name);
        var deps: std.ArrayList(UnitDep) = .empty;
        for (refs) |r| {
            const di = indexOfMember(ws, r.name) orelse continue; // registry ref: not a unit (Task 6 resolves it from the store)
            if (di == mi) continue; // self ref: no intra-member edges in M4
            const target_unit = libUnitOf(units.items, first_unit[di], unit_count[di]);
            var seen = false;
            for (deps.items) |d| {
                if (d.unit == target_unit) {
                    seen = true;
                    break;
                }
            }
            if (seen) continue;
            const ename = externName(alloc, ws.members[di].name) catch return DriverError.OutOfMemory;
            try deps.append(alloc, .{ .unit = target_unit, .extern_name = ename, .dep_name = ws.members[di].name });
        }
        const owned_deps = deps.toOwnedSlice(alloc) catch return DriverError.OutOfMemory;
        const feats = sortedFeatures(alloc, unified, m.name) catch return DriverError.OutOfMemory;
        for (first_unit[mi]..first_unit[mi] + unit_count[mi]) |ui| {
            // All units of one member share the same dep set (M4: no
            // intra-member edges); the arena owns the single copy.
            units.items[ui].deps = owned_deps;
            units.items[ui].features_sorted = feats;
        }
    }

    return .{ .arena = arena, .units = units.toOwnedSlice(alloc) catch return DriverError.OutOfMemory };
}

fn baseUnit(
    m: *const workspace_mod.Member,
    edition: []const u8,
    target_name: []const u8,
    kind: TargetKind,
    crate_types: []const []const u8,
    profile: Profile,
    target_triple: []const u8,
) Unit {
    return .{
        .pkg_name = m.name,
        .version = m.version,
        .target_name = target_name,
        .kind = kind,
        .edition = edition,
        .crate_types = crate_types,
        .profile = profile,
        .features_sorted = &.{},
        .target_triple = target_triple,
        .compile_kind = .target,
        .mode = .build,
        .src_path = m.dir,
        .deps = &.{},
    };
}

/// Pruned-graph dep names for one member (empty when the member is absent
/// from the graph — path-only members resolve without registry entries).
fn graphRefsFor(graph: *const ResolveGraph, name: []const u8) []const resolve_mod.ResolvedRef {
    for (graph.nodes) |*n| {
        if (std.mem.eql(u8, n.name, name)) return n.deps;
    }
    return &.{};
}

fn indexOfMember(ws: *const Workspace, name: []const u8) ?usize {
    for (ws.members, 0..) |*m, i| {
        if (std.mem.eql(u8, m.name, name)) return i;
    }
    return null;
}

/// The member's lib unit when it has one, else its first unit (bin-only
/// members still satisfy `--extern` from their first output).
fn libUnitOf(units: []const Unit, first: usize, count: usize) usize {
    for (first..first + count) |ui| {
        if (units[ui].kind == .lib) return ui;
    }
    return first;
}

/// Unified enabled features for one package, sorted (the
/// `Fingerprint.features` sorted-cfg-list role). Arena-owned copy: the
/// slice AND each feature string are duped into the graph arena, so the
/// graph outlives `Unified` (whose map keys borrow feature-table/callers).
fn sortedFeatures(alloc: std.mem.Allocator, unified: *const Unified, pkg: []const u8) std.mem.Allocator.Error![]const []const u8 {
    const set = unified.features.get(pkg) orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);
    var it = set.iterator();
    while (it.next()) |kv| try out.append(alloc, try alloc.dupe(u8, kv.key_ptr.*));
    const slice = try out.toOwnedSlice(alloc);
    std.mem.sort([]const u8, slice, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return slice;
}

test "unit graph builds one unit per member target in dep order" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var ws = try workspace_mod.discover(gpa, io, "testdata/cargo/workspace", null);
    defer ws.deinit();
    try std.testing.expectEqual(@as(usize, 2), ws.members.len);

    // Hand-built pruned resolve graph: a -> b (path members).
    const va = try @import("semver.zig").Version.parse("0.1.0");
    const vb = try @import("semver.zig").Version.parse("0.1.0");
    const path: @import("sources.zig").SourceId = .{ .path = "" };
    const a_refs = [_]resolve_mod.ResolvedRef{.{ .name = "b", .version = vb, .source = path }};
    const nodes = [_]resolve_mod.ResolvedNode{
        .{ .name = "a", .version = va, .source = path, .deps = &a_refs },
        .{ .name = "b", .version = vb, .source = path, .deps = &.{} },
    };
    var rg = resolve_mod.ResolveGraph{ .arena = std.heap.ArenaAllocator.init(gpa), .nodes = &nodes };
    defer rg.deinit();

    // Empty unified maps (the graph is already pruned, so no filtering is
    // needed; features_sorted is empty for both units).
    var u = features_mod.Unified{
        .gpa = gpa,
        .features = std.StringHashMap(std.StringHashMap(void)).init(gpa),
        .enabled_deps = std.StringHashMap(std.StringHashMap(void)).init(gpa),
    };
    defer u.deinit();

    const tc = toolchain_mod.Toolchain{
        .rustc_path = "rustc",
        .version = "1.99.0-nightly",
        .host_target = "aarch64-apple-darwin",
        .commit_hash = "1ed2df61a19042f231709eb05d032ae9e2cb2084",
        .sysroot = "/nonexistent",
        .digest = @import("store").hashBytes("stub"),
    };
    var ug = try buildUnitGraph(gpa, &ws, &rg, &u, profile_mod.devProfile(), null, &tc);
    defer ug.deinit();
    try std.testing.expectEqual(@as(usize, 2), ug.units.len);
    const order = try ug.topoOrder(gpa);
    defer gpa.free(order);
    try std.testing.expectEqualStrings("b", ug.units[order[0]].pkg_name);
    try std.testing.expectEqualStrings("a", ug.units[order[1]].pkg_name);
    try std.testing.expectEqualStrings("rlib", ug.units[order[0]].crate_types[0]);
    // a's unit edges b's unit with the extern/dep names pinned.
    try std.testing.expectEqual(@as(usize, 1), ug.units[order[1]].deps.len);
    try std.testing.expectEqual(order[0], ug.units[order[1]].deps[0].unit);
    try std.testing.expectEqualStrings("b", ug.units[order[1]].deps[0].extern_name);
    try std.testing.expectEqualStrings("b", ug.units[order[1]].deps[0].dep_name);
    // Triple falls back to the toolchain host when --target is unset.
    try std.testing.expectEqualStrings("aarch64-apple-darwin", ug.units[order[0]].target_triple);
}

test "host units resolve the host triple" {
    try std.testing.expectEqualStrings("aarch64-apple-darwin", forHostTarget(.host, "x86_64-unknown-linux-gnu", "aarch64-apple-darwin"));
    try std.testing.expectEqualStrings("x86_64-unknown-linux-gnu", forHostTarget(.target, "x86_64-unknown-linux-gnu", "aarch64-apple-darwin"));
}

test "extern names map dashes to underscores" {
    const e = try externName(std.testing.allocator, "my-crate");
    defer std.testing.allocator.free(e);
    try std.testing.expectEqualStrings("my_crate", e);
}

test "unit graph sorts features and honors explicit triples" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var ws = try workspace_mod.discover(gpa, io, "testdata/cargo/workspace", null);
    defer ws.deinit();

    const v = try @import("semver.zig").Version.parse("0.1.0");
    const path: @import("sources.zig").SourceId = .{ .path = "" };
    const nodes = [_]resolve_mod.ResolvedNode{
        .{ .name = "a", .version = v, .source = path, .deps = &.{} },
        .{ .name = "b", .version = v, .source = path, .deps = &.{} },
    };
    var rg = resolve_mod.ResolveGraph{ .arena = std.heap.ArenaAllocator.init(gpa), .nodes = &nodes };
    defer rg.deinit();

    var features_map = std.StringHashMap(std.StringHashMap(void)).init(gpa);
    var inner = std.StringHashMap(void).init(gpa);
    try inner.put("zeta", {});
    try inner.put("alpha", {});
    try features_map.put("a", inner);
    var u = features_mod.Unified{ .gpa = gpa, .features = features_map, .enabled_deps = std.StringHashMap(std.StringHashMap(void)).init(gpa) };
    defer u.deinit();

    const tc = toolchain_mod.Toolchain{
        .rustc_path = "rustc",
        .version = "1.99.0-nightly",
        .host_target = "aarch64-apple-darwin",
        .commit_hash = "x",
        .sysroot = "/nonexistent",
        .digest = @import("store").hashBytes("stub"),
    };
    var ug = try buildUnitGraph(gpa, &ws, &rg, &u, profile_mod.releaseProfile(), "x86_64-unknown-linux-gnu", &tc);
    defer ug.deinit();
    // Members sort by dir: a first.
    try std.testing.expectEqualStrings("a", ug.units[0].pkg_name);
    try std.testing.expectEqual(@as(usize, 2), ug.units[0].features_sorted.len);
    try std.testing.expectEqualStrings("alpha", ug.units[0].features_sorted[0]);
    try std.testing.expectEqualStrings("zeta", ug.units[0].features_sorted[1]);
    try std.testing.expectEqual(@as(usize, 0), ug.units[1].features_sorted.len);
    try std.testing.expectEqualStrings("x86_64-unknown-linux-gnu", ug.units[0].target_triple);
    try std.testing.expectEqualStrings("3", ug.units[0].profile.opt_level);
}

test "unit graph rejects non lib-bin targets loudly" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var ws = try workspace_mod.discover(gpa, io, "testdata/cargo/workspace", null);
    defer ws.deinit();
    // Inject a test-only target (the manifest surface never produces one:
    // [test]/[bench]/[example] sections parse-and-ignore in M1, so this
    // pins the driver's loud rejection for when the surface grows).
    var weird = [_]manifest_mod.TargetDesc{.{ .name = "weird", .path = null, .kind = .@"test" }};
    ws.members[0].manifest.targets = &weird;

    const v = try @import("semver.zig").Version.parse("0.1.0");
    const path: @import("sources.zig").SourceId = .{ .path = "" };
    const nodes = [_]resolve_mod.ResolvedNode{
        .{ .name = "a", .version = v, .source = path, .deps = &.{} },
        .{ .name = "b", .version = v, .source = path, .deps = &.{} },
    };
    var rg = resolve_mod.ResolveGraph{ .arena = std.heap.ArenaAllocator.init(gpa), .nodes = &nodes };
    defer rg.deinit();
    var u = features_mod.Unified{ .gpa = gpa, .features = std.StringHashMap(std.StringHashMap(void)).init(gpa), .enabled_deps = std.StringHashMap(std.StringHashMap(void)).init(gpa) };
    defer u.deinit();
    const tc = toolchain_mod.Toolchain{
        .rustc_path = "rustc",
        .version = "1.99.0-nightly",
        .host_target = "aarch64-apple-darwin",
        .commit_hash = "x",
        .sysroot = "/nonexistent",
        .digest = @import("store").hashBytes("stub"),
    };
    try std.testing.expectError(DriverError.UnknownTarget, buildUnitGraph(gpa, &ws, &rg, &u, profile_mod.devProfile(), null, &tc));
}
