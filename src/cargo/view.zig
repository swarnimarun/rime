/// target/ view layout + materialize + clean (Plan C Task 6).
///
/// The project dir holds a regenerable *view*: final outputs materialized
/// from the global store by clone-or-copy (never hardlink). `clean` removes
/// only the view, never store state.
///
/// Ownership: `Layout` paths are `gpa`-owned (`deinit` frees them).
/// `UnitPlan`'s outer slice is `gpa`-owned (free with the same allocator);
/// every inner slice (package/version/target names, outputs) borrows the
/// `Workspace` (member manifests or its arena) and stays valid exactly as
/// long as the workspace. `planUnits` allocates the small predicted-name
/// strings from the workspace arena via `@constCast` for this reason —
/// single-threaded CLI/test use only, no aliasing during the call.
const std = @import("std");
const store_mod = @import("store");
const manifest_mod = @import("manifest.zig");
const workspace_mod = @import("workspace.zig");

const Store = store_mod.Store;
const Digest = store_mod.Digest;
const TargetKind = manifest_mod.TargetKind;
const Workspace = workspace_mod.Workspace;

pub const ViewError = error{ Io, StoreRead, StoreFull, OutOfMemory };

pub const Layout = struct {
    view_root: []const u8, // "<ws>/target"
    profile_dir: []const u8, // "<ws>/target/<profile>"
    deps_dir: []const u8, // "<ws>/target/<profile>/deps"
    fingerprint_dir: []const u8, // "<ws>/target/<profile>/.fingerprint"

    pub fn deinit(self: *const Layout, gpa: std.mem.Allocator) void {
        gpa.free(self.view_root);
        gpa.free(self.profile_dir);
        gpa.free(self.deps_dir);
        gpa.free(self.fingerprint_dir);
    }
};

pub fn layoutPaths(gpa: std.mem.Allocator, ws_root: []const u8, profile: []const u8) ViewError!Layout {
    const view_root = std.fs.path.join(gpa, &.{ ws_root, "target" }) catch return ViewError.OutOfMemory;
    errdefer gpa.free(view_root);
    const profile_dir = std.fs.path.join(gpa, &.{ view_root, profileDirName(profile) }) catch return ViewError.OutOfMemory;
    errdefer gpa.free(profile_dir);
    const deps_dir = std.fs.path.join(gpa, &.{ profile_dir, "deps" }) catch return ViewError.OutOfMemory;
    errdefer gpa.free(deps_dir);
    const fingerprint_dir = std.fs.path.join(gpa, &.{ profile_dir, ".fingerprint" }) catch return ViewError.OutOfMemory;
    return .{
        .view_root = view_root,
        .profile_dir = profile_dir,
        .deps_dir = deps_dir,
        .fingerprint_dir = fingerprint_dir,
    };
}

/// Cargo's directory spelling: `dev` builds live under `target/debug/`;
/// every other profile name maps verbatim (`release` → `release`, custom
/// `--profile foo` → `foo`). Returns static strings (no allocation).
pub fn profileDirName(profile: []const u8) []const u8 {
    if (std.mem.eql(u8, profile, "dev")) return "debug";
    return profile;
}

/// Cargo's `deps/` file spelling: rlib/rmeta outputs carry the `lib` prefix
/// (`libserde-ab12.rlib`); binaries and other kinds use the bare
/// `<name>-<meta><ext>` form.
pub fn depFileName(gpa: std.mem.Allocator, crate_name: []const u8, meta: []const u8, ext: []const u8) ViewError![]u8 {
    if (std.mem.eql(u8, ext, ".rlib") or std.mem.eql(u8, ext, ".rmeta")) {
        return std.fmt.allocPrint(gpa, "lib{s}-{s}{s}", .{ crate_name, meta, ext }) catch return ViewError.OutOfMemory;
    }
    return std.fmt.allocPrint(gpa, "{s}-{s}{s}", .{ crate_name, meta, ext }) catch return ViewError.OutOfMemory;
}

pub const UnitPlan = struct {
    package: []const u8,
    version: []const u8,
    target: []const u8, // target name (lib name or bin name)
    kind: TargetKind, // re-exported from manifest.zig
    manifest_digest: ?Digest, // set from M4 on; null in M1 (plan without artifacts)
    outputs: []const []const u8, // terminal output file names for this unit (M1: predicted names)
};

/// Topological unit plan over `memberEdges` (dependencies before
/// dependents; ties broken alphabetically for determinism). `only_package`
/// (`-p`) restricts the plan to the named member plus its transitive
/// path-deps; an unknown name is `ViewError.Io` (the caller formats the
/// `package not found` message, since it owns the name).
pub fn planUnits(gpa: std.mem.Allocator, ws: *const Workspace, only_package: ?[]const u8) ViewError![]UnitPlan {
    const edges = workspace_mod.memberEdges(gpa, ws) catch |e| return switch (e) {
        error.OutOfMemory => ViewError.OutOfMemory,
        else => ViewError.Io,
    };
    defer {
        for (edges) |e| gpa.free(e);
        gpa.free(edges);
    }

    // Restrict to the -p closure (member + transitive path-deps).
    var kept: []bool = gpa.alloc(bool, ws.members.len) catch return ViewError.OutOfMemory;
    defer gpa.free(kept);
    @memset(kept, true);
    if (only_package) |name| {
        const root_idx = indexOfMember(ws, name) orelse return ViewError.Io;
        @memset(kept, false);
        var stack: std.ArrayList(usize) = .empty;
        defer stack.deinit(gpa);
        stack.append(gpa, root_idx) catch return ViewError.OutOfMemory;
        while (stack.pop()) |i| {
            if (kept[i]) continue;
            kept[i] = true;
            for (edges[i]) |j| stack.append(gpa, j) catch return ViewError.OutOfMemory;
        }
    }

    // Kahn over the reversed graph (dep -> dependent), alphabetical
    // tie-break by member name. indeg[i] counts i's kept path-deps.
    const kept_count = countKept(kept);
    var emitted: []bool = gpa.alloc(bool, ws.members.len) catch return ViewError.OutOfMemory;
    defer gpa.free(emitted);
    @memset(emitted, false);
    var order: std.ArrayList(usize) = .empty;
    defer order.deinit(gpa);
    var indeg = gpa.alloc(usize, ws.members.len) catch return ViewError.OutOfMemory;
    defer gpa.free(indeg);
    for (0..ws.members.len) |i| {
        var d: usize = 0;
        if (kept[i]) for (edges[i]) |j| {
            if (kept[j]) d += 1;
        };
        indeg[i] = d;
    }
    while (order.items.len < kept_count) {
        // Alphabetically smallest ready member.
        var best: ?usize = null;
        for (0..ws.members.len) |i| {
            if (!kept[i] or emitted[i] or indeg[i] != 0) continue;
            if (best == null or std.mem.order(u8, ws.members[i].name, ws.members[best.?].name) == .lt) best = i;
        }
        const next = best orelse return ViewError.Io; // cycle: unreachable (discover rejects them)
        emitted[next] = true;
        order.append(gpa, next) catch return ViewError.OutOfMemory;
        // Dependents of `next`: every kept i with next in edges[i].
        for (0..ws.members.len) |i| {
            if (!kept[i] or emitted[i]) continue;
            for (edges[i]) |j| {
                if (j == next) {
                    indeg[i] -= 1;
                    break;
                }
            }
        }
    }

    // Expand members to units (explicit targets, else one default lib unit).
    // Inner strings borrow the workspace (see module doc); the outer slice
    // is gpa-owned.
    var arena = @constCast(&ws.arena);
    const alloc = arena.allocator();
    var units: std.ArrayList(UnitPlan) = .empty;
    errdefer units.deinit(gpa);
    for (order.items) |mi| {
        const m = &ws.members[mi];
        if (m.manifest.targets.len == 0) {
            const tname = defaultLibName(alloc, m.name) catch return ViewError.OutOfMemory;
            const out = predictedOutputs(alloc, tname, .lib) catch return ViewError.OutOfMemory;
            units.append(gpa, .{
                .package = m.name,
                .version = m.version,
                .target = tname,
                .kind = .lib,
                .manifest_digest = null,
                .outputs = out,
            }) catch return ViewError.OutOfMemory;
        } else {
            for (m.manifest.targets) |t| {
                const out = predictedOutputs(alloc, t.name, t.kind) catch return ViewError.OutOfMemory;
                units.append(gpa, .{
                    .package = m.name,
                    .version = m.version,
                    .target = t.name,
                    .kind = t.kind,
                    .manifest_digest = null,
                    .outputs = out,
                }) catch return ViewError.OutOfMemory;
            }
        }
    }
    return units.toOwnedSlice(gpa) catch ViewError.OutOfMemory;
}

fn indexOfMember(ws: *const Workspace, name: []const u8) ?usize {
    for (ws.members, 0..) |*m, i| {
        if (std.mem.eql(u8, m.name, name)) return i;
    }
    return null;
}

fn countKept(kept: []const bool) usize {
    var n: usize = 0;
    for (kept) |k| if (k) {
        n += 1;
    };
    return n;
}

/// Cargo's default lib target name: the package name with `-` mapped to `_`.
fn defaultLibName(alloc: std.mem.Allocator, pkg_name: []const u8) std.mem.Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, pkg_name, '-') == null) return pkg_name;
    const buf = try alloc.dupe(u8, pkg_name);
    for (buf) |*c| if (c.* == '-') {
        c.* = '_';
    };
    return buf;
}

/// M1 predicted terminal names (no metadata hash exists before the M4
/// driver): libs → `lib<target>.rlib`, everything else → bare `<target>`.
fn predictedOutputs(alloc: std.mem.Allocator, target: []const u8, kind: TargetKind) std.mem.Allocator.Error![]const []const u8 {
    const out = try alloc.alloc([]const u8, 1);
    out[0] = switch (kind) {
        .lib => try std.fmt.allocPrint(alloc, "lib{s}.rlib", .{target}),
        else => try alloc.dupe(u8, target),
    };
    return out;
}

/// M4 driver project identity: `"pb3-" ++ hex(hashBytes(ws_root))`.
/// Factored out of `writeViewMeta` (same computation, single spelling) so
/// the pipeline's action-key `project` tag matches the committed view rows.
/// gpa-owned (free with the same allocator).
pub fn projectId(gpa: std.mem.Allocator, ws_root: []const u8) ViewError![]u8 {
    const proj_hex = store_mod.hashBytes(ws_root).toHex();
    return std.fmt.allocPrint(gpa, "pb3-{s}", .{proj_hex[0..]}) catch return ViewError.OutOfMemory;
}

/// Spool fallback map (M4 Task 10): `"pkg\x00target" → absolute spool
/// out_dir` for units whose outputs never reached the store (`StoreFull`:
/// the artifact stays in spool and the view fills by plain copy). Borrowed
/// dirs; the map header is caller-owned. Null (or a missing entry) keeps the
/// M1 stub behavior for plan-only units.
pub const SpoolMap = std.StringHashMap([]const u8);

/// `"pkg\x00target"` join for `SpoolMap` keys. gpa-owned.
pub fn spoolKey(gpa: std.mem.Allocator, package: []const u8, target: []const u8) ViewError![]u8 {
    return std.fmt.allocPrint(gpa, "{s}\x00{s}", .{ package, target }) catch return ViewError.OutOfMemory;
}

/// Materializes terminal outputs into the view. Units carrying a
/// `manifest_digest` resolve it via `getManifest` and clone-or-copy each
/// listed output (`0o755` for bins so the view copy runs, `0o444` for
/// everything else so store objects stay read-only in spirit); units with a
/// null digest (all of M1) get fingerprint-dir stubs only. Never hardlinks
/// (delegated to `Store.materialize`).
pub fn materializeOutputs(gpa: std.mem.Allocator, io: std.Io, store: *Store, ws_root: []const u8, profile: []const u8, units: []const UnitPlan) ViewError!void {
    return materializeOutputsWithSpool(gpa, io, store, ws_root, profile, units, null);
}

/// `materializeOutputs` plus the M4 Task-10 spool fallback: null-digest
/// units WITH a `spool_dirs` entry copy their listed outputs from the spool
/// dir instead of leaving stubs (the `StoreFull` delivery path — the whole
/// store is full, but the view still fills from spool). A missing spool file
/// is `Io` (the pipeline guarantees presence); a missing map entry falls
/// back to the stub. `spool_dirs` borrows the caller's map.
pub fn materializeOutputsWithSpool(gpa: std.mem.Allocator, io: std.Io, store: *Store, ws_root: []const u8, profile: []const u8, units: []const UnitPlan, spool_dirs: ?*const SpoolMap) ViewError!void {
    const layout = try layoutPaths(gpa, ws_root, profile);
    defer layout.deinit(gpa);
    // All view writes go through the workspace-root handle with root-
    // relative paths (never cwd-relative: --manifest-path runs with an
    // unrelated cwd). Only Store.materialize dests stay absolute.
    var root = std.Io.Dir.cwd().openDir(io, ws_root, .{}) catch return ViewError.Io;
    defer root.close(io);
    const profile_rel = try relPath(gpa, ws_root, layout.profile_dir);
    defer gpa.free(profile_rel);
    const deps_rel = try relPath(gpa, ws_root, layout.deps_dir);
    defer gpa.free(deps_rel);
    const fp_rel = try relPath(gpa, ws_root, layout.fingerprint_dir);
    defer gpa.free(fp_rel);
    root.createDirPath(io, profile_rel) catch |e| return mapDirError(e);
    root.createDirPath(io, deps_rel) catch |e| return mapDirError(e);
    root.createDirPath(io, fp_rel) catch |e| return mapDirError(e);

    for (units) |u| {
        if (u.manifest_digest) |md| {
            const dest_dir = if (u.kind == .bin) layout.profile_dir else layout.deps_dir;
            const mode: u32 = if (u.kind == .bin) 0o755 else 0o444;
            {
                const man = store.getManifest(io, gpa, md) catch |e| return switch (e) {
                    error.OutOfMemory => ViewError.OutOfMemory,
                    else => ViewError.StoreRead,
                };
                defer man.deinit(gpa);
                for (man.outputs) |o| {
                    const dest = std.fs.path.join(gpa, &.{ dest_dir, o.path }) catch return ViewError.OutOfMemory;
                    defer gpa.free(dest);
                    // Stage the parent through the root handle, then
                    // materialize to the absolute destination.
                    const parent = std.fs.path.dirname(dest) orelse dest_dir;
                    const parent_rel = try relPath(gpa, ws_root, parent);
                    defer gpa.free(parent_rel);
                    root.createDirPath(io, parent_rel) catch |e| return mapDirError(e);
                    _ = store.materialize(io, o.digest, dest, mode) catch return ViewError.StoreRead;
                }
            }
        } else {
            // Spool fallback (M4): copy real outputs when the pipeline
            // hands us the spool dir (spool-only delivery under StoreFull).
            if (spool_dirs) |sm| {
                const key = try spoolKey(gpa, u.package, u.target);
                defer gpa.free(key);
                if (sm.get(key)) |sdir| {
                    const dest_dir = if (u.kind == .bin) layout.profile_dir else layout.deps_dir;
                    const mode: u32 = if (u.kind == .bin) 0o755 else 0o444;
                    for (u.outputs) |fname| {
                        const src = std.fs.path.join(gpa, &.{ sdir, fname }) catch return ViewError.OutOfMemory;
                        defer gpa.free(src);
                        const bytes = std.Io.Dir.cwd().readFileAlloc(io, src, gpa, .limited(1 << 30)) catch |e| {
                            if (e == error.OutOfMemory) return ViewError.OutOfMemory;
                            return ViewError.Io;
                        };
                        defer gpa.free(bytes);
                        const dest = std.fs.path.join(gpa, &.{ dest_dir, fname }) catch return ViewError.OutOfMemory;
                        defer gpa.free(dest);
                        const parent = std.fs.path.dirname(dest) orelse dest_dir;
                        const parent_rel = try relPath(gpa, ws_root, parent);
                        defer gpa.free(parent_rel);
                        root.createDirPath(io, parent_rel) catch |e| return mapDirError(e);
                        const dest_rel = try relPath(gpa, ws_root, dest);
                        defer gpa.free(dest_rel);
                        root.writeFile(io, .{ .sub_path = dest_rel, .data = bytes }) catch |e| return mapDirError(e);
                        var out = std.Io.Dir.openFileAbsolute(io, dest, .{ .mode = .write_only }) catch |e| return mapDirError(e);
                        defer out.close(io);
                        out.setPermissions(io, .fromMode(@intCast(mode))) catch |e| return mapDirError(e);
                    }
                    continue;
                }
            }
            // M1 stub: no artifacts exist before the driver, so the unit
            // leaves only a fingerprint-dir marker cargo tooling can see.
            const stub = std.fs.path.join(gpa, &.{ layout.fingerprint_dir, u.target }) catch return ViewError.OutOfMemory;
            defer gpa.free(stub);
            const rel = relPath(gpa, ws_root, stub) catch return ViewError.OutOfMemory;
            defer gpa.free(rel);
            const body = std.fmt.allocPrint(gpa, "{{\"package\":\"{s}\",\"version\":\"{s}\",\"complete\":false}}\n", .{ u.package, u.version }) catch return ViewError.OutOfMemory;
            defer gpa.free(body);
            root.writeFile(io, .{ .sub_path = rel, .data = body }) catch |e| return mapDirError(e);
        }
    }
}

fn relPath(gpa: std.mem.Allocator, base: []const u8, abs: []const u8) std.mem.Allocator.Error![]u8 {
    if (std.mem.startsWith(u8, abs, base) and abs.len > base.len and abs[base.len] == '/') {
        return gpa.dupe(u8, abs[base.len + 1 ..]);
    }
    return gpa.dupe(u8, abs);
}

fn mapDirError(e: anyerror) ViewError {
    return if (e == error.OutOfMemory) ViewError.OutOfMemory else ViewError.Io;
}

/// Writes `target/<profile>/.rime-view.json` (the full storage-v2 §11.3 tag
/// key set with M1-partial values: `crate`, `crate_version`, `profile`,
/// `project`, `action` filled; `target` triple only when `--target` was
/// passed (M1 rows: always null — triple plumbing lands with the driver);
/// driver-known `toolchain`/`features` stay null until M4) plus
/// `last-build.json` (`{ "manifests": [] }` in M1, real digests from M4).
/// `"complete": false` marks every row PARTIAL — Plan B must not ingest
/// these as index tags until M4 flips the marker with complete rows.
pub fn writeViewMeta(gpa: std.mem.Allocator, io: std.Io, ws_root: []const u8, profile: []const u8, units: []const UnitPlan) ViewError!void {
    const layout = try layoutPaths(gpa, ws_root, profile);
    defer layout.deinit(gpa);
    // Root-relative writes (see materializeOutputs): never cwd-relative.
    var root = std.Io.Dir.cwd().openDir(io, ws_root, .{}) catch return ViewError.Io;
    defer root.close(io);
    const profile_rel = relPath(gpa, ws_root, layout.profile_dir) catch return ViewError.OutOfMemory;
    defer gpa.free(profile_rel);
    root.createDirPath(io, profile_rel) catch |e| return mapDirError(e);

    const proj_hex = store_mod.hashBytes(ws_root).toHex();
    const project_id = std.fmt.allocPrint(gpa, "pb3-{s}", .{proj_hex[0..]}) catch return ViewError.OutOfMemory;
    defer gpa.free(project_id);

    // Units borrow caller strings; only the entry headers are transient.
    const entries = gpa.alloc(ViewUnit, units.len) catch return ViewError.OutOfMemory;
    defer gpa.free(entries);
    for (units, entries) |u, *slot| {
        slot.* = .{
            .package = u.package,
            .version = u.version,
            .target = u.target,
            .tags = .{
                .crate = u.package,
                .crate_version = u.version,
                .toolchain = null,
                .target = null,
                .profile = profile,
                .features = null,
                .project = project_id,
                .action = "rustc",
            },
        };
    }
    const meta = ViewMeta{
        .version = 1,
        .complete = false,
        .project_id = project_id,
        .profile = profile,
        .units = entries,
    };
    const meta_path = std.fs.path.join(gpa, &.{ layout.profile_dir, ".rime-view.json" }) catch return ViewError.OutOfMemory;
    defer gpa.free(meta_path);
    const meta_rel = relPath(gpa, ws_root, meta_path) catch return ViewError.OutOfMemory;
    defer gpa.free(meta_rel);
    {
        var out: std.Io.Writer.Allocating = try .initCapacity(gpa, 1024);
        defer out.deinit();
        std.json.Stringify.value(meta, .{}, &out.writer) catch return ViewError.OutOfMemory;
        out.writer.writeAll("\n") catch return ViewError.OutOfMemory;
        const bytes = try out.toOwnedSlice();
        defer gpa.free(bytes);
        root.writeFile(io, .{ .sub_path = meta_rel, .data = bytes }) catch |e| return mapDirError(e);
    }
    const last_path = std.fs.path.join(gpa, &.{ layout.profile_dir, "last-build.json" }) catch return ViewError.OutOfMemory;
    defer gpa.free(last_path);
    const last_rel = relPath(gpa, ws_root, last_path) catch return ViewError.OutOfMemory;
    defer gpa.free(last_rel);
    {
        var out: std.Io.Writer.Allocating = try .initCapacity(gpa, 64);
        defer out.deinit();
        std.json.Stringify.value(LastBuild{ .manifests = @as([]const []const u8, &.{}) }, .{}, &out.writer) catch return ViewError.OutOfMemory;
        out.writer.writeAll("\n") catch return ViewError.OutOfMemory;
        const bytes = try out.toOwnedSlice();
        defer gpa.free(bytes);
        root.writeFile(io, .{ .sub_path = last_rel, .data = bytes }) catch |e| return mapDirError(e);
    }
}

/// One COMPLETE driver row (M4 Task 10): the plan plus the driver-known tag
/// values and the recorded output mtime that feeds the next run's `checkFresh`
/// fast path (Task 13). All strings borrow the caller (pipeline plan/tags);
/// `manifest_digest` null = spool-only unit (view filled from spool).
pub const ViewUnitFull = struct {
    package: []const u8,
    version: []const u8,
    target: []const u8,
    manifest_digest: ?Digest,
    toolchain: []const u8, // tc.tag() value (storage-v2 §11.3 `toolchain`)
    features: []const u8, // fh- tag (§11.3 `features`)
    target_triple: []const u8, // §11.3 `target`
    output_mtime_ns: i128, // view primary-output mtime, ms×1e6 (checkFresh units)
};

/// One recorded per-unit mtime row in `last-build.json` (Task-13 amendment
/// to Task 10: `{manifests: [...], units: [{package, target,
/// output_mtime_ns}]}`). History for the `checkFresh` fast path; merged
/// across runs (skipped units keep their previous rows).
pub const LastBuildUnit = struct {
    package: []const u8,
    target: []const u8,
    output_mtime_ns: i128,
};

/// Writes `target/<profile>/.rime-view.json` with COMPLETE rows (real
/// toolchain/features/target tags, `"complete": true`) plus
/// `last-build.json` (`{manifests: ["b3-<hex>"…], units: [{package,
/// target, output_mtime_ns}]}`). Same paths as `writeViewMeta` (overwrite).
/// Manifests list follows units order, skipping null digests.
pub fn writeViewMetaFull(gpa: std.mem.Allocator, io: std.Io, ws_root: []const u8, profile: []const u8, units: []const ViewUnitFull) ViewError!void {
    const layout = try layoutPaths(gpa, ws_root, profile);
    defer layout.deinit(gpa);
    var root = std.Io.Dir.cwd().openDir(io, ws_root, .{}) catch return ViewError.Io;
    defer root.close(io);
    const profile_rel = relPath(gpa, ws_root, layout.profile_dir) catch return ViewError.OutOfMemory;
    defer gpa.free(profile_rel);
    root.createDirPath(io, profile_rel) catch |e| return mapDirError(e);

    const project_id = try projectId(gpa, ws_root);
    defer gpa.free(project_id);

    const entries = gpa.alloc(ViewUnit, units.len) catch return ViewError.OutOfMemory;
    defer gpa.free(entries);
    for (units, entries) |u, *slot| {
        slot.* = .{
            .package = u.package,
            .version = u.version,
            .target = u.target,
            .tags = .{
                .crate = u.package,
                .crate_version = u.version,
                .toolchain = u.toolchain,
                .target = u.target_triple,
                .profile = profile,
                .features = u.features,
                .project = project_id,
                .action = "rustc",
            },
        };
    }
    const meta = ViewMeta{
        .version = 1,
        .complete = true,
        .project_id = project_id,
        .profile = profile,
        .units = entries,
    };
    const meta_path = std.fs.path.join(gpa, &.{ layout.profile_dir, ".rime-view.json" }) catch return ViewError.OutOfMemory;
    defer gpa.free(meta_path);
    const meta_rel = relPath(gpa, ws_root, meta_path) catch return ViewError.OutOfMemory;
    defer gpa.free(meta_rel);
    {
        var out: std.Io.Writer.Allocating = try .initCapacity(gpa, 2048);
        defer out.deinit();
        std.json.Stringify.value(meta, .{}, &out.writer) catch return ViewError.OutOfMemory;
        out.writer.writeAll("\n") catch return ViewError.OutOfMemory;
        const bytes = try out.toOwnedSlice();
        defer gpa.free(bytes);
        root.writeFile(io, .{ .sub_path = meta_rel, .data = bytes }) catch |e| return mapDirError(e);
    }
    var mans: std.ArrayList([]const u8) = .empty;
    defer mans.deinit(gpa);
    var rows: std.ArrayList(LastBuildUnit) = .empty;
    defer rows.deinit(gpa);
    for (units) |u| {
        if (u.manifest_digest) |md| {
            const hex = md.toHex();
            const s = std.fmt.allocPrint(gpa, "b3-{s}", .{hex[0..]}) catch return ViewError.OutOfMemory;
            mans.append(gpa, s) catch return ViewError.OutOfMemory;
        }
        rows.append(gpa, .{ .package = u.package, .target = u.target, .output_mtime_ns = u.output_mtime_ns }) catch return ViewError.OutOfMemory;
    }
    defer for (mans.items) |s| gpa.free(s);
    const last_path = std.fs.path.join(gpa, &.{ layout.profile_dir, "last-build.json" }) catch return ViewError.OutOfMemory;
    defer gpa.free(last_path);
    const last_rel = relPath(gpa, ws_root, last_path) catch return ViewError.OutOfMemory;
    defer gpa.free(last_rel);
    {
        var out: std.Io.Writer.Allocating = try .initCapacity(gpa, 1024);
        defer out.deinit();
        std.json.Stringify.value(LastBuildFileOut{ .manifests = mans.items, .units = rows.items }, .{}, &out.writer) catch return ViewError.OutOfMemory;
        out.writer.writeAll("\n") catch return ViewError.OutOfMemory;
        const bytes = try out.toOwnedSlice();
        defer gpa.free(bytes);
        root.writeFile(io, .{ .sub_path = last_rel, .data = bytes }) catch |e| return mapDirError(e);
    }
}

const LastBuildFileOut = struct {
    manifests: []const []const u8,
    units: []const LastBuildUnit,
};

/// History file read-back for the `checkFresh` fast path: `{arena owns all,
/// manifests: digest strings, units: per-unit rows}`. Missing or malformed
/// files read as null (no history → full planning path, always correct).
/// Only `OutOfMemory` propagates; every other failure means "no usable
/// history", never a failed build.
pub const LastBuildFile = struct {
    arena: std.heap.ArenaAllocator,
    manifests: []const []const u8,
    units: []const LastBuildUnit,
    pub fn deinit(self: *LastBuildFile) void {
        self.arena.deinit();
    }
    pub fn mtimeFor(self: *const LastBuildFile, package: []const u8, target: []const u8) ?i128 {
        for (self.units) |u| {
            if (std.mem.eql(u8, u.package, package) and std.mem.eql(u8, u.target, target)) return u.output_mtime_ns;
        }
        return null;
    }
};

pub fn readLastBuildUnits(gpa: std.mem.Allocator, io: std.Io, ws_root: []const u8, profile: []const u8) ViewError!?LastBuildFile {
    const layout = try layoutPaths(gpa, ws_root, profile);
    defer layout.deinit(gpa);
    const last_path = std.fs.path.join(gpa, &.{ layout.profile_dir, "last-build.json" }) catch return ViewError.OutOfMemory;
    defer gpa.free(last_path);
    const text = std.Io.Dir.cwd().readFileAlloc(io, last_path, gpa, .limited(1 << 20)) catch |e| {
        if (e == error.OutOfMemory) return ViewError.OutOfMemory;
        return null; // missing/unreadable history: plan from scratch
    };
    defer gpa.free(text);
    const parsed = std.json.parseFromSlice(LastBuildFileOut, gpa, text, .{ .allocate = .alloc_always }) catch {
        return null; // malformed history (e.g. M1 `{manifests: []}` shape): ignore
    };
    defer parsed.deinit();
    // M1 files (`{"manifests":[]}`, no `units` key) fail struct parsing
    // above and already returned null: no history, plan from scratch.
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    const mans = alloc.dupe([]const u8, parsed.value.manifests) catch return ViewError.OutOfMemory;
    for (mans, parsed.value.manifests) |*dst, src| {
        dst.* = alloc.dupe(u8, src) catch return ViewError.OutOfMemory;
    }
    const rows = alloc.alloc(LastBuildUnit, parsed.value.units.len) catch return ViewError.OutOfMemory;
    for (rows, parsed.value.units) |*dst, src| {
        dst.* = .{
            .package = alloc.dupe(u8, src.package) catch return ViewError.OutOfMemory,
            .target = alloc.dupe(u8, src.target) catch return ViewError.OutOfMemory,
            .output_mtime_ns = src.output_mtime_ns,
        };
    }
    return .{ .arena = arena, .manifests = mans, .units = rows };
}

const ViewTags = struct {
    crate: []const u8,
    crate_version: []const u8,
    toolchain: ?[]const u8,
    target: ?[]const u8,
    profile: []const u8,
    features: ?[]const u8,
    project: []const u8,
    action: []const u8,
};

const ViewUnit = struct {
    package: []const u8,
    version: []const u8,
    target: []const u8,
    tags: ViewTags,
};

const ViewMeta = struct {
    version: u32,
    complete: bool,
    project_id: []const u8,
    profile: []const u8,
    units: []ViewUnit,
};

const LastBuild = struct {
    manifests: []const []const u8,
};

/// Deletes the view: the whole `target/` dir with `profile == null`, else
/// only `target/<profile>/`. Never touches the store (no store handle is
/// even taken — enforced by the signature). Missing dirs are a no-op.
pub fn clean(gpa: std.mem.Allocator, io: std.Io, ws_root: []const u8, profile: ?[]const u8) ViewError!void {
    var root = std.Io.Dir.cwd().openDir(io, ws_root, .{}) catch return ViewError.Io;
    defer root.close(io);
    if (profile) |p| {
        const rel = std.fs.path.join(gpa, &.{ "target", profileDirName(p) }) catch return ViewError.OutOfMemory;
        defer gpa.free(rel);
        root.deleteTree(io, rel) catch |e| {
            if (e != error.FileNotFound) return ViewError.Io;
        };
    } else {
        root.deleteTree(io, "target") catch |e| {
            if (e != error.FileNotFound) return ViewError.Io;
        };
    }
}

test "view maps dev to debug and keeps custom profiles" {
    try std.testing.expectEqualStrings("debug", profileDirName("dev"));
    try std.testing.expectEqualStrings("release", profileDirName("release"));
    try std.testing.expectEqualStrings("fast", profileDirName("fast"));
}

test "view dep file names match cargo" {
    const n = try depFileName(std.testing.allocator, "serde", "ab12cd34", ".rlib");
    defer std.testing.allocator.free(n);
    try std.testing.expectEqualStrings("libserde-ab12cd34.rlib", n);
}

test "view layout joins under the workspace root" {
    const gpa = std.testing.allocator;
    const l = try layoutPaths(gpa, "/ws", "dev");
    defer l.deinit(gpa);
    try std.testing.expectEqualStrings("/ws/target", l.view_root);
    try std.testing.expectEqualStrings("/ws/target/debug", l.profile_dir);
    try std.testing.expectEqualStrings("/ws/target/debug/deps", l.deps_dir);
    try std.testing.expectEqualStrings("/ws/target/debug/.fingerprint", l.fingerprint_dir);
    const b = try depFileName(gpa, "tool", "ab12", "");
    defer gpa.free(b);
    try std.testing.expectEqualStrings("tool-ab12", b);
}

test "view materializes store objects and clean removes only the view" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    // test_support is private to the store module, so the test opens a
    // scratch store directly (same shape as openTestStore with defaults).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tstore = try store_mod.Store.open(io, tmp.dir, .{});
    defer tstore.close(io);

    // One .bin object in the store, referenced by a manifest entry.
    const d = try tstore.putBytes(io, "hello-bin", .bin);
    var outs = [_]store_mod.Store.ManifestOutput{
        .{ .path = "hello-bin", .digest = d, .size = "hello-bin".len, .mode = 0o755 },
    };
    const man_digest = try tstore.putManifest(io, .{ .kind = .bin, .outputs = &outs });

    // Separate workspace dir (absolute path: Store.materialize resolves
    // relative dests under the store).
    var ws_tmp = std.testing.tmpDir(.{});
    defer ws_tmp.cleanup();
    const ws_root = try ws_tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(ws_root);

    const units = [_]UnitPlan{.{
        .package = "hello",
        .version = "0.1.0",
        .target = "hello",
        .kind = .bin,
        .manifest_digest = man_digest,
        .outputs = &.{"hello-bin"},
    }};
    try materializeOutputs(gpa, io, &tstore, ws_root, "dev", &units);

    // View copy: identical bytes, executable bit per the mode-per-kind table.
    const got = try ws_tmp.dir.readFileAlloc(io, "target/debug/hello-bin", gpa, .unlimited);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("hello-bin", got);
    const vst = try ws_tmp.dir.statFile(io, "target/debug/hello-bin", .{});
    try std.testing.expectEqual(@as(u32, 0o755), vst.permissions.toMode() & 0o777);

    // Store object untouched: still read-only 0o444, still verifies.
    var hex_buf: [65]u8 = undefined;
    const obj_path = try std.fs.path.join(gpa, &.{ "objects", d.relPath(&hex_buf) });
    defer gpa.free(obj_path);
    const ost = try tstore.dir.statFile(io, obj_path, .{});
    try std.testing.expectEqual(@as(u32, 0o444), ost.permissions.toMode() & 0o777);
    try tstore.verifyObject(io, d);

    // clean(ws_root, null) removes target/ and nothing else: store objects
    // survive, and the workspace dir itself is intact.
    try clean(gpa, io, ws_root, null);
    try std.testing.expectError(error.FileNotFound, ws_tmp.dir.statFile(io, "target", .{}));
    try std.testing.expect(tstore.dirHasHot(io, d));
    try std.testing.expect(tstore.dirHasHot(io, man_digest));
    // Second clean is a no-op (missing dir tolerated).
    try clean(gpa, io, ws_root, null);
}

test "view writeViewMeta emits partial tag rows" {
    // Regression guard: this writer hid a semantic error while dead code
    // (nothing called it until cli.run landed). It now runs under test.
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var ws_tmp = std.testing.tmpDir(.{});
    defer ws_tmp.cleanup();
    const ws_root = try ws_tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(ws_root);
    const units = [_]UnitPlan{.{
        .package = "a",
        .version = "0.1.0",
        .target = "a",
        .kind = .lib,
        .manifest_digest = null,
        .outputs = &.{"liba.rlib"},
    }};
    try writeViewMeta(gpa, io, ws_root, "dev", &units);
    const meta = try ws_tmp.dir.readFileAlloc(io, "target/debug/.rime-view.json", gpa, .limited(1 << 20));
    defer gpa.free(meta);
    // Full v2 §11.3 key set, M1-partial values, never ingested as complete.
    for ([_][]const u8{ "\"complete\":false", "\"crate\":\"a\"", "\"crate_version\":\"0.1.0\"", "\"toolchain\":null", "\"target\":null", "\"features\":null", "\"action\":\"rustc\"", "\"project\":\"pb3-" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, meta, needle) != null);
    }
    const last = try ws_tmp.dir.readFileAlloc(io, "target/debug/last-build.json", gpa, .limited(1024));
    defer gpa.free(last);
    try std.testing.expectEqualStrings("{\"manifests\":[]}\n", last);
}

test "view planUnits orders dependencies first" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var ws = try workspace_mod.discover(std.testing.allocator, io, "testdata/cargo/workspace", null);
    defer ws.deinit();
    const units = try planUnits(std.testing.allocator, &ws, null);
    defer std.testing.allocator.free(units);
    try std.testing.expectEqual(@as(usize, 2), units.len);
    try std.testing.expectEqualStrings("b", units[0].package);
    try std.testing.expectEqualStrings("a", units[1].package);
    try std.testing.expect(units[0].manifest_digest == null);
    // -p restricts to the member plus its path-deps; unknown names are Io.
    const sub = try planUnits(std.testing.allocator, &ws, "a");
    defer std.testing.allocator.free(sub);
    try std.testing.expectEqual(@as(usize, 2), sub.len);
    const only_b = try planUnits(std.testing.allocator, &ws, "b");
    defer std.testing.allocator.free(only_b);
    try std.testing.expectEqual(@as(usize, 1), only_b.len);
    try std.testing.expectError(ViewError.Io, planUnits(std.testing.allocator, &ws, "nope"));
}
