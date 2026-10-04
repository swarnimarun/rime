const std = @import("std");
const manifest_mod = @import("manifest.zig"); // wired via the cargo module; see build.zig note in Plan C Task 5
const lock_mod = @import("lock.zig");

pub const Manifest = manifest_mod.Manifest;
pub const Lockfile = lock_mod.Lockfile;

pub const DiscoverError = error{ NoWorkspace, Cycle, InvalidManifest, UnsupportedKey, ParseError, UnsupportedType, InvalidLock, OutOfMemory };
pub const Member = struct {
    name: []const u8,
    version: []const u8,
    dir: []const u8, // absolute dir path (owned by workspace arena)
    manifest: Manifest, // Task-2 model; each member keeps its own arena (see discover)
    is_root: bool,
};

/// One expanded member directory: absolute path plus root membership flag.
/// (Root-relative spellings live only transiently inside expansion.)
const MemberDir = struct { abs: []const u8, is_root: bool };
pub const Workspace = struct {
    arena: std.heap.ArenaAllocator,
    root_dir: []const u8,
    members: []Member,
    lock: ?Lockfile, // parsed if Cargo.lock present next to root (null = resolve in M3)
    pub fn deinit(self: *Workspace) void {
        for (self.members) |*m| m.manifest.deinit();
        if (self.lock) |*l| l.deinit();
        self.arena.deinit();
    }
    pub fn findMember(self: *const Workspace, name: []const u8) ?*const Member {
        for (self.members) |*m| {
            if (std.mem.eql(u8, m.name, name)) return m;
        }
        return null;
    }
};

/// Cap for a single manifest read. Larger files are rejected as
/// InvalidManifest (cargo manifests are small; a huge file is a misconfig or
/// an attack on the resolver's memory budget).
const max_manifest_bytes: usize = 1 << 20;

pub fn discover(gpa: std.mem.Allocator, io: std.Io, start_dir: []const u8, manifest_path: ?[]const u8) DiscoverError!Workspace {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    const cwd = std.Io.Dir.cwd();

    // Resolve the root manifest location. With an explicit manifest path the
    // containing dir IS the root (no walk-up, mirroring cargo
    // --manifest-path). Otherwise walk up to the nearest Cargo.toml, then
    // apply cargo's member-of-parent-workspace rule (see findRoot below).
    const located: [2][]const u8 = blk: {
        if (manifest_path) |mp| {
            break :blk .{ mp, std.fs.path.dirname(mp) orelse "." };
        }
        break :blk try findRoot(gpa, io, alloc, start_dir);
    };
    const root_manifest_rel = located[0];
    const root_dir_rel = located[1];

    const root_dir = cwd.realPathFileAlloc(io, root_dir_rel, alloc) catch |e| {
        if (e == error.OutOfMemory) return DiscoverError.OutOfMemory;
        return DiscoverError.InvalidManifest;
    };

    var members: std.ArrayList(Member) = .empty;
    var root_manifest = try parseManifestFile(gpa, io, root_manifest_rel);
    // Ownership: the root shape parse below is released right after member
    // expansion (root_consumed flips then); every error path before that
    // point must free exactly once via this errdefer.
    var root_consumed = false;
    errdefer {
        for (members.items) |*m| m.manifest.deinit();
        if (!root_consumed) root_manifest.deinit();
    }

    // Expand the member set: the root package itself (when non-virtual)
    // first, then [workspace] members globs sorted for determinism (FS
    // listing order is not stable across platforms).
    var dirs: std.ArrayList(MemberDir) = .empty;
    if (root_manifest.pkg != null) {
        try dirs.append(alloc, .{ .abs = root_dir, .is_root = true });
    }
    if (root_manifest.workspace_members) |patterns| {
        var expanded: std.ArrayList(MemberDir) = .empty;
        for (patterns) |pat| {
            try expandPattern(alloc, io, cwd, root_dir_rel, root_dir, pat, root_manifest.workspace_exclude, &expanded);
        }
        std.mem.sort(MemberDir, expanded.items, {}, struct {
            fn lt(_: void, a: MemberDir, b: MemberDir) bool {
                return std.mem.order(u8, a.abs, b.abs) == .lt;
            }
        }.lt);
        try dirs.appendSlice(alloc, expanded.items);
    }
    // Workspace inheritance: clone the root's [workspace.package] values
    // and [workspace.dependencies] entries into the workspace arena. The
    // root shape parse is released right below, while member manifests
    // (parsed fresh afterwards) borrow these clones during the inherit
    // pass. Only the map header is transient; member-borrowed strings live
    // in the arena.
    const root_ws_version: ?[]const u8 = if (root_manifest.ws_version) |v| try alloc.dupe(u8, v) else null;
    const root_ws_edition: ?[]const u8 = if (root_manifest.ws_edition) |v| try alloc.dupe(u8, v) else null;
    var root_ws_deps = std.StringHashMap(manifest_mod.DependencyKind).init(alloc);
    defer root_ws_deps.deinit();
    {
        var wit = root_manifest.ws_deps.iterator();
        while (wit.next()) |kv| {
            try root_ws_deps.put(try alloc.dupe(u8, kv.key_ptr.*), try dupeDep(alloc, kv.value_ptr.*));
        }
    }
    // The root shape parse has served its purpose (pkg presence + member
    // patterns, both consumed into `dirs` above). Release it now: every
    // member — including the root package itself — is parsed fresh below so
    // that each Member owns exactly one manifest arena. This keeps the
    // ownership rule trivially auditable: one arena per manifest, freed by
    // exactly one deinit.
    root_manifest.deinit();
    root_consumed = true;

    for (dirs.items) |md| {
        // Per-iteration scope: the parsed manifest is freed here on every
        // error path; on success it moves into `members` and `man` is nulled.
        var man: ?Manifest = try parseManifestFile(gpa, io, try std.fs.path.join(alloc, &.{ md.abs, "Cargo.toml" }));
        defer if (man) |*m| m.deinit();
        const pkg = man.?.pkg orelse return DiscoverError.InvalidManifest;
        for (members.items) |*m| {
            if (std.mem.eql(u8, m.name, pkg.name)) return DiscoverError.InvalidManifest; // duplicate member name: loud, never merged
        }
        try members.append(alloc, .{
            .name = pkg.name,
            .version = pkg.version,
            .dir = md.abs,
            .manifest = man.?,
            .is_root = md.is_root,
        });
        man = null;
    }

    // Inheritance pass: fill `{ workspace = true }` package fields from the
    // root clone above, and replace member-level workspace-inherited deps
    // with the root's [workspace.dependencies] entries. Must precede edge
    // resolution (inherited path deps shape the member graph).
    for (members.items) |*m| {
        if (m.manifest.version_inherited) {
            const v = root_ws_version orelse return DiscoverError.InvalidManifest;
            // Member.version is a separate field from pkg.version (both
            // printed from the former); update both.
            m.manifest.pkg.?.version = v;
            m.version = v;
            m.manifest.version_inherited = false;
        }
        if (m.manifest.edition_inherited) {
            m.manifest.pkg.?.edition = root_ws_edition orelse return DiscoverError.InvalidManifest;
            m.manifest.edition_inherited = false;
        }
        var dit = m.manifest.deps.iterator();
        while (dit.next()) |kv| {
            if (kv.value_ptr.* != .workspace_inherit) continue;
            const rv = root_ws_deps.get(kv.key_ptr.*) orelse return DiscoverError.InvalidManifest;
            // Inherited path deps are relative to the workspace ROOT (cargo
            // rule), not the declaring member: absolutize now so the
            // member-relative edge resolution below stays correct.
            kv.value_ptr.* = if (rv == .path)
                .{ .path = try joinAbs(alloc, root_dir, rv.path) }
            else
                rv;
        }
    }

    // Depends-on cycles between members are a hard error (cargo refuses them
    // too); edges themselves are recomputed on demand by memberEdges.
    const edges = try resolveEdges(alloc, members.items);
    const color = try alloc.alloc(u8, members.items.len);
    @memset(color, 0);
    for (0..members.items.len) |i| try visitCycle(edges, color, i);

    var lock: ?Lockfile = null;
    errdefer if (lock) |*l| l.deinit();
    const lock_probe = try std.fs.path.join(alloc, &.{ root_dir, "Cargo.lock" });
    if (try existsFile(io, lock_probe)) {
        const text = cwd.readFileAlloc(io, lock_probe, gpa, .limited(max_manifest_bytes)) catch |e| {
            if (e == error.OutOfMemory) return DiscoverError.OutOfMemory;
            return DiscoverError.InvalidLock;
        };
        defer gpa.free(text);
        lock = lock_mod.parseLock(gpa, text) catch |e| return @errorCast(e);
    }

    return .{
        .arena = arena,
        .root_dir = root_dir,
        .members = try members.toOwnedSlice(alloc),
        .lock = lock,
    };
}

/// Walk-up + cargo's member-of-parent-workspace rule. Returns the root
/// manifest path and root dir (both cwd-relative as given, absolutized by the
/// caller). The nearest Cargo.toml wins outright when it declares
/// `[workspace]` members; a bare package manifest defers to the nearest
/// ancestor workspace whose expanded member set claims it (so building from
/// inside `crates/a` discovers the whole workspace); otherwise the bare
/// package is its own root.
fn findRoot(gpa: std.mem.Allocator, io: std.Io, alloc: std.mem.Allocator, start_dir: []const u8) DiscoverError![2][]const u8 {
    // Scratch arena for the transient shape parses below (candidate + ancestor
    // manifests). Everything borrowed from them dies with this function; the
    // returned paths live in the workspace arena (`alloc`).
    var tmp = std.heap.ArenaAllocator.init(gpa);
    defer tmp.deinit();
    const talloc = tmp.allocator();
    const cwd = std.Io.Dir.cwd();
    var cur: []const u8 = start_dir;
    while (true) {
        const probe = try std.fs.path.join(alloc, &.{ cur, "Cargo.toml" });
        if (try existsFile(io, probe)) {
            var cand = try parseManifestFile(talloc, io, probe);
            defer cand.deinit();
            if (cand.workspace_members != null) return .{ probe, cur };
            // Bare package: look for a claiming ancestor workspace.
            const cur_abs = cwd.realPathFileAlloc(io, cur, talloc) catch |e| {
                if (e == error.OutOfMemory) return DiscoverError.OutOfMemory;
                return DiscoverError.InvalidManifest;
            };
            var p = std.fs.path.dirname(cur);
            while (p) |parent| : (p = std.fs.path.dirname(parent)) {
                const pprobe = try std.fs.path.join(alloc, &.{ parent, "Cargo.toml" });
                if (!(try existsFile(io, pprobe))) continue;
                var anc = try parseManifestFile(talloc, io, pprobe);
                defer anc.deinit();
                if (anc.workspace_members) |patterns| {
                    var claimed = try expandPatternsForClaim(talloc, io, cwd, parent, patterns, anc.workspace_exclude);
                    defer claimed.deinit(talloc);
                    for (claimed.items) |abs| {
                        if (std.mem.eql(u8, abs, cur_abs)) return .{ pprobe, parent };
                    }
                }
            }
            return .{ probe, cur };
        }
        cur = std.fs.path.dirname(cur) orelse return DiscoverError.NoWorkspace;
    }
}

/// Claim-check expansion. All strings live in `alloc` (findRoot passes its
/// scratch arena, so no per-entry freeing is needed); the returned list
/// header is freed by the caller with the same allocator.
fn expandPatternsForClaim(alloc: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, root_rel: []const u8, patterns: []const []const u8, exclude: []const []const u8) DiscoverError!std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    for (patterns) |pat| {
        // Reuse the shared expansion core, then absolutize each hit. The
        // core reports root-relative hits; absolutize via the FS so claim
        // comparison is canonical.
        var hits: std.ArrayList(MemberHit) = .empty;
        defer hits.deinit(alloc);
        try expandOne(alloc, io, cwd, root_rel, pat, exclude, &hits);
        for (hits.items) |h| {
            const rel = try std.fs.path.join(alloc, &.{ root_rel, h.root_rel });
            const abs = cwd.realPathFileAlloc(io, rel, alloc) catch |e| {
                if (e == error.OutOfMemory) return DiscoverError.OutOfMemory;
                return DiscoverError.InvalidManifest;
            };
            try out.append(alloc, abs);
        }
    }
    return out;
}

const MemberHit = struct { root_rel: []const u8 };

/// Expand one members/claim pattern into root-relative member hits.
/// Exact paths resolve directly; otherwise the pattern must be `head/tail`
/// with `*` confined to the single trailing segment (e.g. `crates/*`).
/// `**` anywhere is rejected (no recursive globs in M1). Exclude patterns
/// filter hits (exact match or same single-`*` segment semantics).
fn expandOne(alloc: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, root_rel: []const u8, pattern: []const u8, exclude: []const []const u8, out: *std.ArrayList(MemberHit)) DiscoverError!void {
    if (std.mem.indexOf(u8, pattern, "**") != null) return DiscoverError.InvalidManifest;
    if (std.mem.indexOfScalar(u8, pattern, '*') == null) {
        // Exact member path.
        const root_rel_hit = try alloc.dupe(u8, pattern);
        if (isExcluded(root_rel_hit, exclude)) {
            alloc.free(root_rel_hit);
            return;
        }
        const manifest_rel = try std.fs.path.join(alloc, &.{ root_rel, root_rel_hit, "Cargo.toml" });
        if (!(try existsFile(io, manifest_rel))) return DiscoverError.InvalidManifest; // explicit member without a manifest: loud
        try out.append(alloc, .{ .root_rel = root_rel_hit });
        return;
    }
    const slash = std.mem.lastIndexOfScalar(u8, pattern, '/');
    const head: []const u8 = if (slash) |i| pattern[0..i] else "";
    const tail: []const u8 = if (slash) |i| pattern[i + 1 ..] else pattern;
    if (std.mem.indexOfScalar(u8, head, '*') != null) return DiscoverError.InvalidManifest; // `*` outside the trailing segment: unsupported in M1
    const base_rel = if (head.len == 0) root_rel else try std.fs.path.join(alloc, &.{ root_rel, head });
    var dir = cwd.openDir(io, base_rel, .{ .iterate = true }) catch |e| {
        if (e == error.OutOfMemory) return DiscoverError.OutOfMemory;
        return DiscoverError.InvalidManifest; // glob base missing/unreadable: loud
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (true) {
        const entry = it.next(io) catch |e| {
            if (e == error.OutOfMemory) return DiscoverError.OutOfMemory;
            return DiscoverError.InvalidManifest;
        };
        const ent = entry orelse break;
        if (ent.kind != .directory) continue;
        if (!segmentMatch(tail, ent.name)) continue;
        // Copy the name before the next iterator step invalidates it.
        const name = try alloc.dupe(u8, ent.name);
        const root_rel_hit = if (head.len == 0)
            name
        else blk: {
            defer alloc.free(name);
            break :blk try std.fmt.allocPrint(alloc, "{s}/{s}", .{ head, name });
        };
        errdefer alloc.free(root_rel_hit);
        if (isExcluded(root_rel_hit, exclude)) {
            alloc.free(root_rel_hit);
            continue;
        }
        const manifest_rel = try std.fs.path.join(alloc, &.{ root_rel, root_rel_hit, "Cargo.toml" });
        if (!(try existsFile(io, manifest_rel))) return DiscoverError.InvalidManifest; // glob hit without a manifest: loud, like cargo
        try out.append(alloc, .{ .root_rel = root_rel_hit });
    }
}

/// Shared by discover's member expansion (arena-owned hits) and the
/// findRoot claim check.
fn expandPattern(alloc: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, root_rel: []const u8, root_abs: []const u8, pattern: []const u8, exclude: []const []const u8, out: *std.ArrayList(MemberDir)) DiscoverError!void {
    var hits: std.ArrayList(MemberHit) = .empty;
    defer hits.deinit(alloc);
    try expandOne(alloc, io, cwd, root_rel, pattern, exclude, &hits);
    for (hits.items) |h| {
        const rel = try std.fs.path.join(alloc, &.{ root_rel, h.root_rel });
        const abs = cwd.realPathFileAlloc(io, rel, alloc) catch |e| {
            if (e == error.OutOfMemory) return DiscoverError.OutOfMemory;
            return DiscoverError.InvalidManifest;
        };
        // Dedupe overlapping patterns (e.g. ["a", "a"] or ["a", "*"]).
        var dup = std.mem.eql(u8, abs, root_abs);
        if (!dup) {
            for (out.items) |existing| {
                if (std.mem.eql(u8, existing.abs, abs)) {
                    dup = true;
                    break;
                }
            }
        }
        if (dup) continue;
        try out.append(alloc, .{ .abs = abs, .is_root = false });
    }
}

fn isExcluded(root_rel_hit: []const u8, exclude: []const []const u8) bool {
    for (exclude) |pat| {
        if (std.mem.indexOf(u8, pat, "**") != null) continue; // `**` unsupported: cannot match, never exclude (expandOne rejects it where it matters)
        if (std.mem.indexOfScalar(u8, pat, '*') == null) {
            if (std.mem.eql(u8, pat, root_rel_hit)) return true;
        } else if (globMatch(pat, root_rel_hit)) {
            return true;
        }
    }
    return false;
}

/// `*` matches any (possibly empty) run of non-`/` chars; every other byte
/// (including `?`, `[`, `]`) matches literally. `**` is rejected by callers.
fn segmentMatch(pattern: []const u8, name: []const u8) bool {
    var px: usize = 0;
    var nx: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;
    while (nx < name.len) {
        if (px < pattern.len and (pattern[px] == name[nx])) {
            px += 1;
            nx += 1;
        } else if (px < pattern.len and pattern[px] == '*') {
            star = px;
            mark = nx;
            px += 1;
        } else if (star) |s| {
            px = s + 1;
            mark += 1;
            nx = mark;
        } else {
            return false;
        }
    }
    while (px < pattern.len and pattern[px] == '*') px += 1;
    return px == pattern.len;
}

/// Full-path glob: both sides split on `/`; segment counts must agree and
/// every segment pair must segmentMatch (`*` never crosses a separator).
fn globMatch(pattern: []const u8, path: []const u8) bool {
    var pit = std.mem.splitScalar(u8, pattern, '/');
    var hit = std.mem.splitScalar(u8, path, '/');
    while (true) {
        const p = pit.next();
        const h = hit.next();
        if (p == null and h == null) return true;
        if (p == null or h == null) return false;
        if (!segmentMatch(p.?, h.?)) return false;
    }
}

/// Deep-dupe a dependency value (keys are duped by the caller). A nested
/// `{ workspace = true }` inside [workspace.dependencies] is invalid
/// cargo — loud, never silently kept.
fn dupeDep(alloc: std.mem.Allocator, dep: manifest_mod.DependencyKind) DiscoverError!manifest_mod.DependencyKind {
    return switch (dep) {
        .version_req => |s| .{ .version_req = try alloc.dupe(u8, s) },
        .path => |s| .{ .path = try alloc.dupe(u8, s) },
        .git => |g| .{ .git = .{
            .url = try alloc.dupe(u8, g.url),
            .ref = if (g.ref) |r| try alloc.dupe(u8, r) else null,
        } },
        .workspace_inherit => DiscoverError.InvalidManifest,
    };
}

/// Absolute join for inherited path deps (already-absolute stays as-is).
fn joinAbs(alloc: std.mem.Allocator, root_abs: []const u8, rel: []const u8) DiscoverError![]const u8 {
    if (std.fs.path.isAbsolute(rel)) return alloc.dupe(u8, rel) catch return DiscoverError.OutOfMemory;
    return std.fs.path.join(alloc, &.{ root_abs, rel }) catch return DiscoverError.OutOfMemory;
}

/// Read + parse one manifest file. The returned Manifest owns its arena
/// (allocated from `gpa`, NOT the workspace arena — see below); the raw
/// text buffer is always freed here since the TOML parser dupes every string
/// it keeps.
fn parseManifestFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) DiscoverError!Manifest {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_manifest_bytes)) catch |e| {
        if (e == error.OutOfMemory) return DiscoverError.OutOfMemory;
        return DiscoverError.InvalidManifest;
    };
    defer gpa.free(text);
    return manifest_mod.parseManifest(gpa, text) catch |e| return @errorCast(e);
}

fn existsFile(io: std.Io, path: []const u8) DiscoverError!bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch |e| {
        if (e == error.FileNotFound) return false;
        if (e == error.OutOfMemory) return DiscoverError.OutOfMemory;
        return DiscoverError.InvalidManifest;
    };
    return true;
}

/// Resolve a `path = …` dependency to an absolute, lexically-normalized path
/// (no symlink resolution: member identity is by canonical spelling, and all
/// member dirs go through the same realpath canonicalization at discovery).
fn resolvePath(alloc: std.mem.Allocator, base_abs: []const u8, rel: []const u8) DiscoverError![]const u8 {
    const joined = if (std.fs.path.isAbsolute(rel))
        try alloc.dupe(u8, rel)
    else
        try std.fs.path.join(alloc, &.{ base_abs, rel });
    defer alloc.free(joined);
    var stack: std.ArrayList([]const u8) = .empty;
    defer stack.deinit(alloc);
    var it = std.mem.splitScalar(u8, joined, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (stack.items.len > 0) _ = stack.pop();
            continue; // clamped at the filesystem root, like the OS
        }
        try stack.append(alloc, seg);
    }
    if (stack.items.len == 0) return try alloc.dupe(u8, "/");
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(alloc);
    try parts.append(alloc, "");
    try parts.appendSlice(alloc, stack.items);
    return try std.mem.join(alloc, "/", parts.items);
}

fn resolveEdges(alloc: std.mem.Allocator, members: []const Member) DiscoverError![][]usize {
    const outer = try alloc.alloc([]usize, members.len);
    var filled: usize = 0;
    errdefer {
        for (outer[0..filled]) |s| alloc.free(s);
        alloc.free(outer);
    }
    for (members, 0..) |*m, i| {
        var list: std.ArrayList(usize) = .empty;
        defer list.deinit(alloc);
        var it = m.manifest.deps.iterator();
        while (it.next()) |kv| {
            const dep = kv.value_ptr.*;
            if (dep != .path) continue; // registry/git/workspace deps resolve in M2/M3; only path edges shape the member graph
            const target = try resolvePath(alloc, m.dir, dep.path);
            defer alloc.free(target);
            for (members, 0..) |*o, j| {
                if (!std.mem.eql(u8, o.dir, target)) continue;
                var seen = false;
                for (list.items) |k| {
                    if (k == j) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) try list.append(alloc, j);
                break;
            }
            // A path dep outside the member set is an external stub (plan
            // Behavior): kept, not an error — registry deps resolve in M3.
        }
        outer[i] = try list.toOwnedSlice(alloc);
        filled += 1;
    }
    return outer;
}

fn visitCycle(edges: []const []usize, color: []u8, i: usize) DiscoverError!void {
    if (color[i] == 2) return;
    if (color[i] == 1) return DiscoverError.Cycle;
    color[i] = 1;
    for (edges[i]) |j| try visitCycle(edges, color, j);
    color[i] = 2;
}

/// Adjacency: member i -> path-dep member indices (for Task 7 plan).
/// Caller-owned: free each inner slice, then the outer slice, with gpa
/// (planUnits does this right after its Kahn pass).
pub fn memberEdges(gpa: std.mem.Allocator, ws: *const Workspace) DiscoverError![]const []const usize {
    return try resolveEdges(gpa, ws.members);
}

fn testIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

test "workspace discovers glob members minus excludes" {
    var ws = try discover(std.testing.allocator, testIo(), "testdata/cargo/workspace/crates/a", null);
    defer ws.deinit();
    try std.testing.expectEqual(@as(usize, 2), ws.members.len);
    try std.testing.expect(ws.findMember("a") != null);
    try std.testing.expect(ws.findMember("b") != null);
    try std.testing.expect(ws.findMember("c") == null);
}

test "workspace honors explicit manifest path" {
    var ws = try discover(std.testing.allocator, testIo(), ".", "testdata/cargo/workspace/Cargo.toml");
    defer ws.deinit();
    try std.testing.expectEqual(@as(usize, 2), ws.members.len);
    try std.testing.expect(ws.findMember("a") != null);
    try std.testing.expect(ws.findMember("b") != null);
}

test "workspace rejects member cycles" {
    try std.testing.expectError(DiscoverError.Cycle, discover(std.testing.allocator, testIo(), "testdata/cargo/cycle", null));
}

test "workspace missing manifest walks to root and fails" {
    try std.testing.expectError(DiscoverError.NoWorkspace, discover(std.testing.allocator, testIo(), "/tmp", null));
}

test "workspace discovers single-package root with lock" {
    var ws = try discover(std.testing.allocator, testIo(), "testdata/cargo/minimal", null);
    defer ws.deinit();
    try std.testing.expectEqual(@as(usize, 1), ws.members.len);
    const m = ws.findMember("rime-minimal").?;
    try std.testing.expectEqualStrings("0.1.0", m.version);
    try std.testing.expect(m.is_root);
    try std.testing.expect(std.fs.path.isAbsolute(m.dir));
    // Task-3 integration: the sibling Cargo.lock is parsed into the workspace.
    const lf = ws.lock.?;
    try std.testing.expectEqual(@as(u32, 4), lf.version);
    try std.testing.expectEqual(@as(usize, 2), lf.packages.len);
    try std.testing.expectEqualStrings("1.0", m.manifest.deps.get("serde").?.version_req);
}

test "workspace member edges follow path deps" {
    var ws = try discover(std.testing.allocator, testIo(), "testdata/cargo/workspace", null);
    defer ws.deinit();
    try std.testing.expectEqual(@as(usize, 2), ws.members.len);
    // Deterministic order: expanded members sort by dir, so a (index 0)
    // points at b (index 1).
    try std.testing.expectEqualStrings("a", ws.members[0].name);
    try std.testing.expectEqualStrings("b", ws.members[1].name);
    try std.testing.expect(!ws.members[0].is_root); // virtual root is not a member
    const edges = try memberEdges(std.testing.allocator, &ws);
    defer {
        for (edges) |e| std.testing.allocator.free(e);
        std.testing.allocator.free(edges);
    }
    try std.testing.expectEqual(@as(usize, 2), edges.len);
    try std.testing.expectEqual(@as(usize, 1), edges[0].len);
    try std.testing.expectEqual(@as(usize, 1), edges[0][0]);
    try std.testing.expectEqual(@as(usize, 0), edges[1].len);
}

test "workspace treats excluded dir as standalone package" {
    // crates/c is excluded from the parent workspace, so starting inside it
    // discovers a single-package workspace rooted at c itself.
    var ws = try discover(std.testing.allocator, testIo(), "testdata/cargo/workspace/crates/c", null);
    defer ws.deinit();
    try std.testing.expectEqual(@as(usize, 1), ws.members.len);
    try std.testing.expect(ws.findMember("c") != null);
    try std.testing.expect(ws.members[0].is_root);
}

test "workspace resolves inheritance from the root" {
    // validation/basic-workspace members inherit version/edition and use
    // `{ workspace = true }` deps; inherited path deps are root-relative.
    var ws = try discover(std.testing.allocator, testIo(), "validation/basic-workspace", null);
    defer ws.deinit();
    try std.testing.expectEqual(@as(usize, 3), ws.members.len);
    const cli = ws.findMember("cli-bin").?;
    try std.testing.expectEqualStrings("0.1.0", cli.version);
    try std.testing.expect(cli.manifest.version_inherited == false);
    // Members sort by dir: cli-bin(0), core-lib(1), util(2).
    try std.testing.expectEqualStrings("cli-bin", ws.members[0].name);
    const edges = try memberEdges(std.testing.allocator, &ws);
    defer {
        for (edges) |e| std.testing.allocator.free(e);
        std.testing.allocator.free(edges);
    }
    // cli-bin -> {core-lib (inherited path)}; registry deps
    // (serde/anyhow) are not member edges; util is transitive via core-lib.
    try std.testing.expectEqual(@as(usize, 1), edges[0].len);
    try std.testing.expectEqual(@as(usize, 1), edges[0][0]);
    try std.testing.expectEqual(@as(usize, 1), edges[1].len);
    try std.testing.expectEqual(@as(usize, 0), edges[2].len);
}

test "segment matching is single-segment only" {
    try std.testing.expect(segmentMatch("crates/*", "foo") == false); // pattern has a slash; helper is per-segment
    try std.testing.expect(segmentMatch("*", "anything-goes"));
    try std.testing.expect(segmentMatch("a*b", "aXYZb"));
    try std.testing.expect(!segmentMatch("a*b", "aXYZc"));
    try std.testing.expect(globMatch("crates/*", "crates/c"));
    try std.testing.expect(!globMatch("crates/*", "crates/a/b"));
    try std.testing.expect(!globMatch("*", "a/b"));
}
