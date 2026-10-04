//! Workspace build pipeline (M4 Tasks 10–13): fetch → resolve → feature
//! unification → unit fingerprints → action keys → rustc in topo order →
//! view materialization, plus `rime check` (rmeta-only), validation plan
//! dumps, and the incremental-reuse / cross-project proofs.
//!
//! Architecture: `buildPlan` is pure planning (hermetic — no spawn, no
//! store writes, never touches the network) returning a `PlannedBuild`;
//! `buildWorkspace` executes it (leases, cache lookup, spawn, ingest,
//! sessions, view). `cli.run` (non-`--dry-run`) drives `buildWorkspace`;
//! `--dry-run` keeps the M1 plan-print path untouched.
//!
//! Ownership: `PlannedBuild` owns a plan arena (filenames, crate roots,
//! dep-fingerprint slices, tags, profile overrides) plus the `UnitGraph`
//! (own arena). Everything else borrows the caller's `Workspace`,
//! `Toolchain`, and `PipelineOptions` — all three must outlive the plan,
//! which `buildWorkspace` guarantees by owning the plan for the whole call.
//! Resolve/unify/prune temporaries use the caller gpa with explicit frees
//! (never nested arenas — a nested `ArenaAllocator.init(alloc)` would
//! double-free on teardown).
//!
//! Deviations and amendments vs the plan's Interfaces (all reported):
//! - `PipelineOptions` gains `frozen`, `locked` (the cli `--locked`/
//!   `--frozen` wiring the seam mandates), and `cache_dir` (spool root +
//!   fetch cache root — both need a home outside the project and the plan
//!   names no other carrier). `PipelineError` gains `LockedViolation`.
//! - `path_hash` is workspace-relative when under the workspace root
//!   (the plan's Task-4 Interfaces text); the Task-4 implementation hashes
//!   verbatim absolute, so the pipeline overwrites `fp.path_hash` here.
//! - rustc output filenames: Task 6 passes no `-C metadata` /
//!   `-C extra-filename`, so rustc would choose its own unsuffixed names
//!   and break the Task-10 layout contract. The pipeline appends
//!   `-C metadata=<meta16> -C extra-filename=-<meta16>` post-hoc (cargo
//!   passes both; verified against real rustc: suffixed rlib/rmeta/d,
//!   check-mode bins emit `lib<crate>-<meta>.rmeta`). Both flags survive
//!   normalization verbatim, so they stay bound in the key.
//! - Binaries are renamed `<crate>-<meta>` → `<target>` in spool before
//!   ingest (cargo's final-copy role — the view holds cargo-final names).
//! - Behaviour `v2`/`v3` unifies via `unifyV1`: M4 feeds no host/dev edge
//!   kinds, so every edge is normal-namespace and the results coincide;
//!   `unify`'s `UnifiedNamespaces` has no `Unified` consumer (its dep-name
//!   sets are private), so the plan's "or unify" arm is unimplementable
//!   without features-lane support (M5 host units own that wiring).
//! - Offline lock-guided planning: with a `Cargo.lock` present, registry
//!   summaries are derived FROM THE LOCK (exact pins, `resolveWithPrevious`
//!   with an empty update set), so planning never touches the network
//!   (the plan's "registry deps need no download for PLANNING"). Any
//!   registry/git entry in the built closure is a loud `NeedFetch` at
//!   build time — M4 compiles workspace members only and no M2 production
//!   registry client exists in-tree to fetch from.
//! - `-p` never rewrites `Cargo.lock` (partial resolve must not corrupt the
//!   full-workspace lock).
//! - Lease/`retainProject` failures are swallowed (best-effort GC
//!   protection/bookkeeping — a failed lease must never fail a correct
//!   build, same spirit as §10.4). StoreFull inside ingest/sessions is
//!   already swallowed there.
//! - The JSON `unit-cached` envelope is rendered by a local `Envelope`
//!   struct with `cli.JsonEnvelope`'s exact field order (importing `cli`
//!   would cycle: `cli` drives this pipeline). A test pins the wire bytes.

const std = @import("std");
const store_mod = @import("store");
const workspace_mod = @import("workspace.zig");
const manifest_mod = @import("manifest.zig");
const resolve_mod = @import("resolve.zig");
const features_mod = @import("features.zig");
const lock_mod = @import("lock.zig");
const index_mod = @import("index.zig");
const sources_mod = @import("sources.zig");
const semver_mod = @import("semver.zig");
const fetch_mod = @import("fetch.zig");
const profile_mod = @import("profile.zig");
const toolchain_mod = @import("toolchain.zig");
const driver_mod = @import("driver.zig");
const fingerprint_mod = @import("fingerprint.zig");
const actionkey_mod = @import("actionkey.zig");
const invoke_mod = @import("invoke.zig");
const compile_mod = @import("compile.zig");
const view_mod = @import("view.zig");
const oracle_mod = @import("oracle.zig");

const Store = store_mod.Store;
const Digest = store_mod.Digest;
const Workspace = workspace_mod.Workspace;
const Toolchain = toolchain_mod.Toolchain;
const Profile = profile_mod.Profile;
const Unit = driver_mod.Unit;
const CompileMode = driver_mod.CompileMode;
const Fingerprint = fingerprint_mod.Fingerprint;

// (Spelling note vs the plan: the plan writes `TagError` inside the error
// set; that reads as the store `TagError` set unioned here — a bare
// `error.TagError` name would NOT cover the `tagObject` failures.)
pub const PipelineError = error{
    NoWorkspace,
    NeedFetch,
    RustcFailed,
    LockedViolation,
    Usage,
    Io,
    StoreRead,
    StoreFull,
    OutOfMemory,
} || store_mod.TagError || std.mem.Allocator.Error;

/// Last pipeline failure detail (the `cli.parseDiagnostic` precedent:
/// error unions carry no payload, so actionable diagnostics — the crate
/// name for `NeedFetch`, the target kind for `Usage` — ride here).
/// Fixed buffer, truncated on overflow; read via `planDiagnostic()`.
var diag_buf: [512]u8 = undefined;
var diag_len: usize = 0;

pub fn planDiagnostic() ?[]const u8 {
    if (diag_len == 0) return null;
    return diag_buf[0..diag_len];
}

fn planFail(err: PipelineError, comptime fmt: []const u8, args: anytype) PipelineError {
    const msg = std.fmt.bufPrint(&diag_buf, fmt, args) catch &diag_buf;
    diag_len = msg.len;
    return err;
}

pub const PipelineOptions = struct {
    manifest_path: ?[]const u8,
    profile_name: []const u8, // "dev" default
    target_triple: ?[]const u8,
    features_cli: []const []const u8,
    all_features: bool,
    no_default: bool,
    mode: CompileMode, // .build or .check (Task 11)
    message_format_json: bool,
    offline: bool,
    frozen: bool, // AMENDMENT: --frozen (lock must match, no network)
    locked: bool, // AMENDMENT: --locked (lock must match)
    only_package: ?[]const u8, // -p
    cache_dir: []const u8, // AMENDMENT: spool root + fetch cache root
};

/// One planned unit: everything execute needs, parallel to
/// `PlannedBuild.graph.units` by index. Strings arena-owned; digests values.
pub const PlannedUnit = struct {
    fp: Fingerprint, // rustc_digest + ws-relative path_hash assigned
    input_digest: Digest, // hashInputs over the crate root
    action_key: Digest,
    crate_root: []const u8, // absolute crate-root source file
    out_dir_name: []const u8, // "<pkg>-<target>" spool subdir leaf
    rlib_file: ?[]const u8, // "lib<e>-<m>.rlib" (lib units)
    rmeta_file: ?[]const u8, // "lib<e>-<m>.rmeta" (lib units, all check units)
    bin_file: ?[]const u8, // spool bin name "<e>-<m>" (bin build units)
    view_bin: ?[]const u8, // cargo-final view name "<target>" (bin build units)
    depinfo_file: []const u8, // "<extern>-<m>.d"
    features_tag: []const u8, // fh- tag value
};

pub const PlannedBuild = struct {
    arena: std.heap.ArenaAllocator, // owns all PlannedUnit strings + dep_fps + order
    graph: driver_mod.UnitGraph, // own arena (independent — never nested)
    units: []PlannedUnit, // arena-owned, parallel to graph.units
    order: []usize, // arena-owned topo order (deps first; -p filtered)
    profile: Profile, // opt_level/name arena-owned when overridden
    profile_name: []const u8, // borrowed from PipelineOptions (outlives use)
    tc_tag: []const u8, // arena-owned toolchain.tag() value
    project_id: []const u8, // arena-owned pb3- id (view.projectId spelling)
    mode: CompileMode,
    lock_changed: bool, // resolve-vs-lockfile drift (writeback decision)
    lock_bytes: ?[]const u8, // arena-owned fresh lock text (null when up-to-date)
    lock_version: lock_mod.ResolveVersion,
    has_registry: bool, // built closure needs registry/git sources (NeedFetch)
    registry_name: []const u8, // first such crate (arena-owned; valid if has_registry)

    pub fn deinit(self: *PlannedBuild) void {
        self.graph.deinit();
        self.arena.deinit();
    }
};

// =====================================================================
// Planning: manifests → resolve → features → units → fingerprints → keys
// =====================================================================

/// One member's resolved manifest surface (member + transitive path deps
/// share this shape; registry entries never appear here).
const MemberData = struct {
    name: []const u8, // borrowed from Workspace (stable package name)
    version: []const u8, // borrowed from Workspace member
    dir: []const u8, // borrowed from Workspace member (absolute)
    ext: *const manifest_mod.ManifestExt, // resolved ext (caller-owned)
    is_member: bool,
};

const max_manifest_bytes: usize = 1 << 20;

fn readManifestText(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) PipelineError![]u8 {
    const path = std.fs.path.join(gpa, &.{ dir, "Cargo.toml" }) catch return PipelineError.OutOfMemory;
    defer gpa.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_manifest_bytes)) catch |e| {
        if (e == error.OutOfMemory) return PipelineError.OutOfMemory;
        return planFail(PipelineError.Usage, "cannot read manifest `{s}`", .{path});
    };
}

/// Parses + inherits one member manifest. `root_ext` is borrowed (never
/// consumed); the returned ext is caller-owned (deinit frees it).
fn parseMemberExt(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, root_ext: *const manifest_mod.ManifestExt) PipelineError!manifest_mod.ManifestExt {
    const text = try readManifestText(gpa, io, dir);
    defer gpa.free(text);
    const path = std.fs.path.join(gpa, &.{ dir, "Cargo.toml" }) catch return PipelineError.OutOfMemory;
    defer gpa.free(path);
    const ext = manifest_mod.parseManifestExt(gpa, text, path) catch |e| {
        if (e == error.OutOfMemory) return PipelineError.OutOfMemory;
        return planFail(PipelineError.Usage, "invalid manifest `{s}`: {t}", .{ path, e });
    };
    return manifest_mod.resolveInheritance(gpa, ext, root_ext.*) catch |e| {
        if (e == error.OutOfMemory) return PipelineError.OutOfMemory;
        return planFail(PipelineError.Usage, "cannot inherit workspace values in `{s}`: {t}", .{ path, e });
    };
}

/// `dep:` / `/` / `?/` grammar (copy of the `oracle.parseFeatureValue`
/// semantics: `dep:` maps through key→real, weak splits on trailing `?`,
/// everything else is `own` — bare dep names enable via `optional_deps`,
/// never via values).
fn parseFeatureValue(key_to_real: *const std.StringHashMap([]const u8), text: []const u8) features_mod.FeatureValue {
    if (std.mem.startsWith(u8, text, "dep:")) {
        const key = text["dep:".len..];
        return .{ .dep_named = key_to_real.get(key) orelse key };
    }
    if (std.mem.indexOfScalar(u8, text, '/')) |slash| {
        const head = text[0..slash];
        const feat = text[slash + 1 ..];
        if (head.len > 0 and head[head.len - 1] == '?') {
            const key = head[0 .. head.len - 1];
            return .{ .weak_feature = .{ .dep = key_to_real.get(key) orelse key, .feat = feat } };
        }
        return .{ .dep_feature = .{ .dep = key_to_real.get(head) orelse head, .feat = feat } };
    }
    return .{ .own = text };
}

/// Builds one package's `FeatureMap` from its manifest surface (the
/// `oracle.buildMaps` per-package projection, restricted to local
/// manifests — registry crates have no maps, so their edges stay normal).
/// All slices borrow `ext` (valid through unification); the map shell is
/// caller-allocated.
fn featureMapFor(alloc: std.mem.Allocator, ext: *const manifest_mod.ManifestExt) std.mem.Allocator.Error!features_mod.FeatureMap {
    var key_to_real = std.StringHashMap([]const u8).init(alloc);
    const lists = [_][]manifest_mod.DepRef{ ext.renamed, ext.target_deps };
    for (lists) |list| {
        for (list) |d| try key_to_real.put(d.key, d.realName());
    }
    var default_vals: std.ArrayList([]const u8) = .empty;
    var rules: std.ArrayList(features_mod.FeatureRule) = .empty;
    var optional_set: std.ArrayList([]const u8) = .empty;
    var suppress: std.ArrayList([]const u8) = .empty;
    for (ext.features) |fd| {
        if (std.mem.eql(u8, fd.name, "default")) {
            for (fd.values) |v| {
                if (v.len == 0) continue;
                if (!containsStr(default_vals.items, v)) try default_vals.append(alloc, v);
            }
            continue;
        }
        if (!containsStr(suppress.items, fd.name)) try suppress.append(alloc, fd.name);
        var vals: std.ArrayList(features_mod.FeatureValue) = .empty;
        for (fd.values) |v| {
            if (v.len == 0) continue;
            try vals.append(alloc, parseFeatureValue(&key_to_real, v));
            if (vals.items[vals.items.len - 1] == .dep_named) {
                const dn = vals.items[vals.items.len - 1].dep_named;
                if (!containsStr(suppress.items, dn)) try suppress.append(alloc, dn);
            }
        }
        try rules.append(alloc, .{ .feature = fd.name, .values = try vals.toOwnedSlice(alloc) });
    }
    for (lists) |list| {
        for (list) |d| {
            if (!d.optional) continue;
            if (!containsStr(optional_set.items, d.realName())) try optional_set.append(alloc, d.realName());
        }
    }
    var opt: std.ArrayList([]const u8) = .empty;
    for (optional_set.items) |o| {
        if (containsStr(suppress.items, o)) continue;
        try opt.append(alloc, o);
    }
    return .{
        .default = try default_vals.toOwnedSlice(alloc),
        .optional_deps = try opt.toOwnedSlice(alloc),
        .rules = try rules.toOwnedSlice(alloc),
    };
}

fn containsStr(items: []const []const u8, s: []const u8) bool {
    for (items) |it| {
        if (std.mem.eql(u8, it, s)) return true;
    }
    return false;
}

/// Manifest `DepRef` → resolve edge. Dev-deps map to normal edges (M4 has
/// no dev-unit planning; lock-pinned resolution is unaffected and the
/// pruned member plan never shows them). Target-selector deps are included
/// unconditionally (all-platform closure, matching `Cargo.lock` which pins
/// every platform's deps).
fn depEdge(alloc: std.mem.Allocator, d: *const manifest_mod.DepRef) PipelineError!resolve_mod.DepEdge {
    const name = alloc.dupe(u8, d.realName()) catch return PipelineError.OutOfMemory;
    errdefer alloc.free(name);
    const req = try reqFromDep(d);
    return .{
        .name = name,
        .req = req,
        .optional = d.optional,
        .build_only = d.dep_kind == .build,
    };
}

fn reqFromDep(d: *const manifest_mod.DepRef) PipelineError!semver_mod.OptVersionReq {
    const text: ?[]const u8 = d.version orelse switch (d.kind) {
        .version_req => |t| t,
        else => null,
    };
    const t = std.mem.trim(u8, text orelse return .any, " \t");
    if (t.len == 0 or std.mem.eql(u8, t, "*")) return .any;
    const req = semver_mod.VersionReq.parse(t) catch {
        return planFail(PipelineError.Usage, "invalid version requirement `{s}` for `{s}`", .{ t, d.realName() });
    };
    return .{ .req = req };
}

/// One member root (manifest edges; version + links from the ext surface).
fn rootFor(alloc: std.mem.Allocator, m: *const MemberData) PipelineError!resolve_mod.SummaryNode {
    const version = semver_mod.Version.parse(m.version) catch {
        return planFail(PipelineError.Usage, "invalid version `{s}` for `{s}`", .{ m.version, m.name });
    };
    var deps: std.ArrayList(resolve_mod.DepEdge) = .empty;
    errdefer deps.deinit(alloc);
    const lists = [_][]manifest_mod.DepRef{ m.ext.renamed, m.ext.target_deps };
    for (lists) |list| {
        for (list) |*d| try deps.append(alloc, try depEdge(alloc, d));
    }
    return .{
        .name = m.name,
        .candidate = .{
            .name = m.name,
            .version = version,
            .yanked = false,
            .checksum = null,
            .rust_version = null,
            .pubtime = null,
        },
        .deps = try deps.toOwnedSlice(alloc),
        .links = m.ext.links,
        .source = .{ .path = "" },
    };
}

// --- Registry seam (offline: members/path walk, or lock-derived pins) ---

const RegCtx = struct {
    paths: []resolve_mod.SummaryNode, // fresh-path manifest summaries (empty when locked)
    locked: []resolve_mod.SummaryNode, // lock-derived pins (empty when fresh)
    arena: std.mem.Allocator, // plan arena for per-query result slices
};

fn regQuery(ctx: *anyopaque, name: []const u8) resolve_mod.QueryError![]const resolve_mod.SummaryNode {
    const c: *RegCtx = @ptrCast(@alignCast(ctx));
    var n: usize = 0;
    for (c.paths) |s| {
        if (std.mem.eql(u8, s.name, name)) n += 1;
    }
    for (c.locked) |s| {
        if (std.mem.eql(u8, s.name, name)) n += 1;
    }
    const out = c.arena.alloc(resolve_mod.SummaryNode, n) catch return resolve_mod.QueryError.OutOfMemory;
    var i: usize = 0;
    for (c.paths) |s| {
        if (!std.mem.eql(u8, s.name, name)) continue;
        out[i] = s;
        i += 1;
    }
    for (c.locked) |s| {
        if (!std.mem.eql(u8, s.name, name)) continue;
        out[i] = s;
        i += 1;
    }
    return out;
}

/// Lock `source` → resolve `SourceId` (offline planning maps every shape;
/// only EXECUTION rejects registry/git with `NeedFetch`). Registry inverts
/// the `lockSourceLine` spelling (`registry+URL` ↔ `sparse+URL`). Git maps
/// `git+<url>[?<query>]#<oid>` to `{url, default_branch, precise}` — the
/// ref kind is a planning-only approximation (consistent within the run;
/// git never compiles in M4). Malformed rows keep null/empty parts rather
/// than failing (same input → same output, always consistent).
fn lockSourceToId(alloc: std.mem.Allocator, source: ?[]const u8) PipelineError!sources_mod.SourceId {
    const s = source orelse return .{ .path = "" };
    if (std.mem.startsWith(u8, s, "registry+")) {
        const url = std.fmt.allocPrint(alloc, "sparse+{s}", .{s["registry+".len..]}) catch return PipelineError.OutOfMemory;
        return .{ .registry = url };
    }
    if (std.mem.startsWith(u8, s, "git+")) {
        const rest = s["git+".len..];
        const hash = std.mem.lastIndexOfScalar(u8, rest, '#');
        const url = if (hash) |h| rest[0..h] else rest;
        var precise: ?[40]u8 = null;
        if (hash) |h| {
            const oid = rest[h + 1 ..];
            if (oid.len == 40) {
                var arr: [40]u8 = undefined;
                var valid = true;
                for (oid, 0..) |c, i| {
                    if (!std.ascii.isHex(c)) valid = false;
                    arr[i] = c;
                }
                if (valid) precise = arr;
            }
        }
        return .{ .git = .{ .url = url, .ref = .default_branch, .precise = precise } };
    }
    return .{ .path = "" };
}

/// First non-path dependency name in the built (`kept`) closure — the
/// actionable `NeedFetch` subject for the EXECUTE gate. Null when the
/// built closure is path-only.
fn firstMissingDep(members: []const MemberData, kept: []const bool) ?[]const u8 {
    for (members, 0..) |*m, i| {
        if (!kept[i]) continue;
        const lists = [_][]manifest_mod.DepRef{ m.ext.renamed, m.ext.target_deps };
        for (lists) |list| {
            for (list) |*d| {
                if (d.kind == .path) continue;
                return d.realName();
            }
        }
    }
    return null;
}

/// First lock-edge token (the package name; `"name version (source)"` or
/// bare `"name"` short form).
fn lockEdgeName(edge: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, edge, ' ')) |i| return edge[0..i];
    return edge;
}

/// Lock edge → resolved version: explicit second token, else the unique
/// lock package with that name (`into_resolve` bad-merge tolerance —
/// ambiguous or dangling edges resolve to null and are skipped).
fn lockEdgeVersion(packages: []lock_mod.LockPackage, edge: []const u8) ?semver_mod.Version {
    const sp = std.mem.indexOfScalar(u8, edge, ' ') orelse {
        var found: ?semver_mod.Version = null;
        for (packages) |*p| {
            if (!std.mem.eql(u8, p.name, edge)) continue;
            const v = semver_mod.Version.parse(p.version) catch continue;
            if (found != null) {
                if (!found.?.eql(v)) return null;
                continue;
            }
            found = v;
        }
        return found;
    };
    const rest = edge[sp + 1 ..];
    const ver = if (std.mem.indexOfScalar(u8, rest, ' ')) |i| rest[0..i] else rest;
    return semver_mod.Version.parse(ver) catch null;
}

/// Lock-derived query summaries: every lock package becomes one candidate
/// (exact locked version, deps as `.any` edges — `resolveWithPrevious`
/// with an empty update set rewrites them all to `Locked` pins, so the
/// resolution reproduces the lock deterministically with no network).
fn lockSummaries(alloc: std.mem.Allocator, lock: *const lock_mod.Lockfile) PipelineError![]resolve_mod.SummaryNode {
    var out: std.ArrayList(resolve_mod.SummaryNode) = .empty;
    errdefer out.deinit(alloc);
    for (lock.packages) |*p| {
        const version = semver_mod.Version.parse(p.version) catch {
            return planFail(PipelineError.Usage, "invalid locked version `{s}` for `{s}`", .{ p.version, p.name });
        };
        const source = try lockSourceToId(alloc, p.source);
        var deps: std.ArrayList(resolve_mod.DepEdge) = .empty;
        errdefer deps.deinit(alloc);
        for (p.dependencies) |e| {
            const name = try alloc.dupe(u8, lockEdgeName(e));
            errdefer alloc.free(name);
            try deps.append(alloc, .{ .name = name, .req = .any, .optional = false, .build_only = false });
        }
        try out.append(alloc, .{
            .name = p.name,
            .candidate = .{
                .name = p.name,
                .version = version,
                .yanked = false,
                .checksum = p.checksum,
                .rust_version = null,
                .pubtime = null,
            },
            .deps = try deps.toOwnedSlice(alloc),
            .links = null, // lockfiles carry no links (documented caveat)
            .source = source,
        });
    }
    return out.toOwnedSlice(alloc);
}

/// Lock → previous-lock nodes for `resolveWithPrevious` (minimal-update
/// guidance; with an empty update set every edge keeps its pin).
fn lockPrevious(alloc: std.mem.Allocator, lock: *const lock_mod.Lockfile) PipelineError![]resolve_mod.ResolvedNode {
    var out: std.ArrayList(resolve_mod.ResolvedNode) = .empty;
    errdefer out.deinit(alloc);
    for (lock.packages) |*p| {
        const version = semver_mod.Version.parse(p.version) catch {
            return planFail(PipelineError.Usage, "invalid locked version `{s}` for `{s}`", .{ p.version, p.name });
        };
        const source = try lockSourceToId(alloc, p.source);
        var deps: std.ArrayList(resolve_mod.ResolvedRef) = .empty;
        errdefer deps.deinit(alloc);
        for (p.dependencies) |e| {
            const name = lockEdgeName(e);
            const v = lockEdgeVersion(lock.packages, e) orelse continue;
            // Source follows the matched package (`v` always came from the
            // list, so exactly one match exists — duplicate lock rows are
            // rejected by `parseLock`).
            var src: sources_mod.SourceId = .{ .path = "" };
            for (lock.packages) |*q| {
                if (!std.mem.eql(u8, q.name, name)) continue;
                const qv = semver_mod.Version.parse(q.version) catch continue;
                if (!qv.eql(v)) continue;
                src = try lockSourceToId(alloc, q.source);
                break;
            }
            try deps.append(alloc, .{ .name = name, .version = v, .source = src });
        }
        try out.append(alloc, .{ .name = p.name, .version = version, .source = source, .deps = try deps.toOwnedSlice(alloc) });
    }
    return out.toOwnedSlice(alloc);
}

/// Transitive path-dep walk for fresh (lockless) resolve: members plus every
/// reachable non-member path dir, each parsed for version/edges/links.
/// Join targets are canonicalized with `realPath` so diamond path deps
/// (`a/../b` vs `b`) hit the `seen` set and cycles terminate. Non-member
/// dirs parse WITHOUT workspace inheritance (their workspace root is
/// unknown): a `version.workspace = true` placeholder there is a loud
/// `Usage`. Missing dep dirs are a loud `Usage` naming the target.
fn walkPathSummaries(
    alloc: std.mem.Allocator,
    io: std.Io,
    members: []const MemberData,
    owned_exts: *std.ArrayList(manifest_mod.ManifestExt),
) PipelineError![]resolve_mod.SummaryNode {
    // `owned_exts` (caller scope, deinited by the caller after the unit
    // graph is built) owns every non-member ext. Interior pointers into
    // it are NEVER retained across appends: the current ext is re-taken by
    // index on each iteration, and summaries borrow only ext-owned STRINGS
    // (stable under struct memcpy) plus arena/caller memory.
    var out: std.ArrayList(resolve_mod.SummaryNode) = .empty;
    errdefer out.deinit(alloc);
    var dirs: std.ArrayList([]const u8) = .empty; // aligned with `out`
    defer dirs.deinit(alloc);
    var seen: std.StringHashMap(void) = std.StringHashMap(void).init(alloc);
    defer seen.deinit();
    for (members) |*m| {
        try out.append(alloc, try rootFor(alloc, m));
        try dirs.append(alloc, m.dir);
        seen.put(m.dir, {}) catch return PipelineError.OutOfMemory;
    }
    var head: usize = 0;
    while (head < out.items.len) : (head += 1) {
        // Re-taken by index every iteration (never retained across appends).
        const base_idx = head -| members.len;
        const cur_ext: *const manifest_mod.ManifestExt = if (head < members.len)
            members[head].ext
        else
            &owned_exts.items[base_idx];
        const cur_dir = dirs.items[head];
        const cur_name = out.items[head].name;
        const lists = [_][]manifest_mod.DepRef{ cur_ext.renamed, cur_ext.target_deps };
        for (lists) |list| {
            for (list) |*d| {
                if (d.kind != .path) continue;
                // Inherited workspace path deps arrive already root-joined
                // (absolute) from `resolveInheritance`; only truly relative
                // spellings resolve against the declaring member's dir.
                // (`std.fs.path.join` concatenates blindly — joining an
                // absolute second component would double-root the path.)
                const joined = if (std.fs.path.isAbsolute(d.kind.path))
                    alloc.dupe(u8, d.kind.path) catch return PipelineError.OutOfMemory
                else
                    std.fs.path.join(alloc, &.{ cur_dir, d.kind.path }) catch return PipelineError.OutOfMemory;
                const canon = std.Io.Dir.cwd().realPathFileAlloc(io, joined, alloc) catch |e| {
                    if (e == error.OutOfMemory) return PipelineError.OutOfMemory;
                    return planFail(PipelineError.Usage, "unknown path dependency `{s}` of `{s}`", .{ joined, cur_name });
                };
                if (seen.contains(canon)) continue;
                seen.put(canon, {}) catch return PipelineError.OutOfMemory;
                const text = try readManifestText(alloc, io, canon);
                defer alloc.free(text);
                const mpath = std.fs.path.join(alloc, &.{ canon, "Cargo.toml" }) catch return PipelineError.OutOfMemory;
                defer alloc.free(mpath);
                const raw = manifest_mod.parseManifestExt(alloc, text, mpath) catch |e| {
                    if (e == error.OutOfMemory) return PipelineError.OutOfMemory;
                    return planFail(PipelineError.Usage, "invalid manifest `{s}`: {t}", .{ mpath, e });
                };
                // Failure diagnostics below must not borrow `raw` (it is
                // deinited on those paths): `canon` is arena-stable, and
                // the package name is duped into the arena first.
                const pkg = raw.base.pkg orelse {
                    var owned = raw;
                    owned.deinit();
                    return planFail(PipelineError.Usage, "path dependency at `{s}` has no [package]", .{canon});
                };
                const pkg_name = alloc.dupe(u8, pkg.name) catch return PipelineError.OutOfMemory;
                if (pkg.version.len == 0 or raw.base.version_inherited) {
                    var owned = raw;
                    owned.deinit();
                    return planFail(PipelineError.Usage, "path dependency `{s}` needs a concrete version (workspace inheritance unsupported outside members)", .{pkg_name});
                }
                owned_exts.append(alloc, raw) catch return PipelineError.OutOfMemory;
                const md = MemberData{
                    .name = pkg.name,
                    .version = pkg.version,
                    .dir = canon,
                    .ext = &owned_exts.items[owned_exts.items.len - 1],
                    .is_member = false,
                };
                try out.append(alloc, try rootFor(alloc, &md));
                try dirs.append(alloc, canon);
            }
        }
    }
    return out.toOwnedSlice(alloc);
}

// --- Resolve driver (lock-guided offline, or fresh) ---

/// Resolve failures: unresolvable registry names (fresh path, no lock pins
/// to serve them) read as the actionable `NeedFetch`; everything else is a
/// genuine resolution failure.
fn mapResolveError(e: resolve_mod.ResolveError, members: []const MemberData, kept: []const bool) PipelineError {
    switch (e) {
        error.OutOfMemory => return PipelineError.OutOfMemory,
        error.NoMatchingVersion => {
            if (firstMissingDep(members, kept)) |name| {
                return planFail(PipelineError.NeedFetch, "{s} requires M2 fetch (registry sources are not compilable in M4)", .{name});
            }
            return planFail(PipelineError.Usage, "cannot resolve workspace dependencies", .{});
        },
        error.Conflict => return planFail(PipelineError.Usage, "conflicting dependency requirements", .{}),
        error.Cycle => return planFail(PipelineError.Usage, "cyclic package dependency", .{}),
    }
}

/// Lowest workspace `rust-version` (partial `major[.minor[.patch]]`) for
/// `versionForRustVersion`. Unparseable/absent → null (lock v4).
fn lowestRustVersion(members: []const MemberData) ?semver_mod.Version {
    var best: ?semver_mod.Version = null;
    for (members) |*m| {
        const text = m.ext.base.rust_version orelse continue;
        const v = parsePartialVersion(text) orelse continue;
        if (best == null or v.order(best.?) == .lt) best = v;
    }
    return best;
}

fn parsePartialVersion(text: []const u8) ?semver_mod.Version {
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, text, " \t"), '.');
    const major = it.next() orelse return null;
    const minor = it.next() orelse "0";
    const patch = it.next() orelse "0";
    if (it.next() != null) return null;
    const ma = std.fmt.parseInt(u64, major, 10) catch return null;
    const mi = std.fmt.parseInt(u64, minor, 10) catch return null;
    const pa = std.fmt.parseInt(u64, patch, 10) catch return null;
    return .{ .major = ma, .minor = mi, .patch = pa, .pre = "", .build = "" };
}

/// `-p` member closure over `memberEdges` (the `view.planUnits` kept-set
/// logic, copied per the plan — 15 lines). Unknown names are `Usage`.
fn keptMembers(gpa: std.mem.Allocator, ws: *const Workspace, only_package: ?[]const u8) PipelineError![]bool {
    const kept = gpa.alloc(bool, ws.members.len) catch return PipelineError.OutOfMemory;
    errdefer gpa.free(kept);
    @memset(kept, true);
    const name = only_package orelse return kept;
    const edges = workspace_mod.memberEdges(gpa, ws) catch |e| {
        if (e == error.OutOfMemory) return PipelineError.OutOfMemory;
        return planFail(PipelineError.Usage, "cannot compute member closure", .{});
    };
    defer {
        for (edges) |e| gpa.free(e);
        gpa.free(edges);
    }
    var root_idx: ?usize = null;
    for (ws.members, 0..) |*m, i| {
        if (std.mem.eql(u8, m.name, name)) root_idx = i;
    }
    const root = root_idx orelse {
        gpa.free(kept);
        return planFail(PipelineError.Usage, "package not found: {s}", .{name});
    };
    @memset(kept, false);
    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(gpa);
    stack.append(gpa, root) catch return PipelineError.OutOfMemory;
    while (stack.pop()) |i| {
        if (kept[i]) continue;
        kept[i] = true;
        for (edges[i]) |j| stack.append(gpa, j) catch return PipelineError.OutOfMemory;
    }
    return kept;
}

/// Pure planning (hermetic): resolve → unify → prune → unit graph → per-unit
/// fingerprints + action keys + crate roots + output filenames. No spawn, no
/// store writes, no network. `store` is reserved for the execute phase
/// (fixed Interfaces carry it; planning is offline by construction).
pub fn buildPlan(
    gpa: std.mem.Allocator,
    io: std.Io,
    store: *Store,
    ws: *const Workspace,
    tc: *const Toolchain,
    opts: PipelineOptions,
) PipelineError!PlannedBuild {
    _ = store;
    diag_len = 0;
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    if (ws.members.len == 0) return planFail(PipelineError.NoWorkspace, "no workspace members", .{});

    // 1. Manifest surfaces: root ext (inheritance source + resolver) plus
    //    one resolved ext per member. Non-member path exts accumulate in
    //    `owned_exts` (deinited after the unit graph is built).
    const root_text = try readManifestText(gpa, io, ws.root_dir);
    defer gpa.free(root_text);
    const root_path = std.fs.path.join(gpa, &.{ ws.root_dir, "Cargo.toml" }) catch return PipelineError.OutOfMemory;
    defer gpa.free(root_path);
    var root_ext = manifest_mod.parseManifestExt(gpa, root_text, root_path) catch |e| {
        if (e == error.OutOfMemory) return PipelineError.OutOfMemory;
        return planFail(PipelineError.Usage, "invalid manifest `{s}`: {t}", .{ root_path, e });
    };
    defer root_ext.deinit();
    var member_exts: std.ArrayList(manifest_mod.ManifestExt) = .empty;
    defer {
        for (member_exts.items) |*e| e.deinit();
        member_exts.deinit(gpa);
    }
    var owned_exts: std.ArrayList(manifest_mod.ManifestExt) = .empty;
    defer {
        for (owned_exts.items) |*e| e.deinit();
        owned_exts.deinit(gpa);
    }
    var members: std.ArrayList(MemberData) = .empty;
    defer members.deinit(gpa);
    // Reserve member capacity up front: `members` retains `&member_exts`
    // interior pointers across loop iterations, which is only sound when no
    // reallocation happens (same hazard class as the walk's index rule).
    member_exts.ensureTotalCapacity(gpa, ws.members.len) catch return PipelineError.OutOfMemory;
    members.ensureTotalCapacity(gpa, ws.members.len) catch return PipelineError.OutOfMemory;
    for (ws.members) |*m| {
        const ext = try parseMemberExt(gpa, io, m.dir, &root_ext);
        member_exts.appendAssumeCapacity(ext);
        members.appendAssumeCapacity(.{
            .name = m.name,
            .version = m.version,
            .dir = m.dir,
            .ext = &member_exts.items[member_exts.items.len - 1],
            .is_member = true,
        });
    }

    // 2. `-p` closure (also bounds the NeedFetch scan: siblings outside the
    //    closure never block a filtered build at PLAN time; resolve itself
    //    still covers the workspace — see step 3).
    const kept = try keptMembers(gpa, ws, opts.only_package);
    defer gpa.free(kept);

    // 3. Resolve: lock-guided (`resolveWithPrevious`, empty update set) when
    //    `Cargo.lock` exists, else fresh over the path-walk registry.
    //    Registry/git rows resolve from lock pins with NO network (offline
    //    planning); unit construction drops non-member refs, so the PLAN
    //    always succeeds — only EXECUTION gates on registry (step 9).
    const filter: index_mod.QueryFilter = .{
        .allow_yanked = &.{},
        .max_pubtime = null,
        .min_versions_first = false,
        .rust_versions = &.{},
        .preferred = &.{},
    };
    // Roots borrow the plan arena (edge names included): resolve borrows
    // them through the call, so gpa-frees here would risk use-after-free
    // if the graph retains any root strings. Arena ownership is free-safe.
    var roots: std.ArrayList(resolve_mod.SummaryNode) = .empty;
    defer roots.deinit(gpa);
    for (members.items) |*m| try roots.append(gpa, try rootFor(alloc, m));
    var reg_box = RegCtx{ .paths = &.{}, .locked = &.{}, .arena = alloc };
    const registry: resolve_mod.Registry = .{ .ctx = @ptrCast(&reg_box), .queryFn = regQuery };
    var graph = if (ws.lock) |*lock| blk: {
        const summaries = try lockSummaries(alloc, lock);
        const prev = try lockPrevious(alloc, lock);
        reg_box.locked = summaries;
        // Manifest-walk path summaries ride along (fresh links + deps;
        // lock pins stay authoritative through the `Locked` req rewrite).
        // A missing transitive manifest fails here — correctly, since its
        // sources would be needed to compile anyway.
        reg_box.paths = try walkPathSummaries(alloc, io, members.items, &owned_exts);
        break :blk resolve_mod.resolveWithPrevious(gpa, roots.items, registry, prev, .{ .update_names = &.{}, .precise = null }, filter) catch |e| {
            return mapResolveError(e, members.items, kept);
        };
    } else blk: {
        const summaries = try walkPathSummaries(alloc, io, members.items, &owned_exts);
        reg_box.paths = summaries;
        break :blk resolve_mod.resolveGraph(gpa, roots.items, registry, filter) catch |e| {
            return mapResolveError(e, members.items, kept);
        };
    };
    defer graph.deinit();

    // 4. Features: maps per local package, CLI seeds per kept member, v1
    //    unification (see module doc for the v2/v3 coincidence), then prune.
    var maps = std.StringHashMap(features_mod.FeatureMap).init(alloc);
    for (members.items) |*m| {
        const fm = try featureMapFor(alloc, m.ext);
        maps.put(m.name, fm) catch return PipelineError.OutOfMemory;
    }
    // Non-member path deps contribute maps too (their edges pre-record
    // correctly instead of defaulting to normal).
    for (owned_exts.items) |*e| {
        const pkg = e.base.pkg orelse continue;
        const fm = try featureMapFor(alloc, e);
        maps.put(pkg.name, fm) catch return PipelineError.OutOfMemory;
    }
    const behavior: features_mod.Behavior = if (root_ext.resolver) |r|
        features_mod.Behavior.fromManifest(r) catch {
            return planFail(PipelineError.Usage, "invalid resolver `{s}`", .{r});
        }
    else
        .v1;
    _ = behavior; // validated; unification is v1 in M4 (see module doc)
    var rreqs: std.ArrayList(features_mod.RootReq) = .empty;
    defer rreqs.deinit(gpa);
    for (members.items, 0..) |*m, i| {
        if (!kept[i]) continue;
        try rreqs.append(gpa, .{
            .package = m.name,
            .features = opts.features_cli,
            .all_features = opts.all_features,
            .no_default = opts.no_default,
        });
    }
    var unified = features_mod.unifyV1(gpa, &graph, &maps, rreqs.items) catch |e| {
        if (e == error.OutOfMemory) return PipelineError.OutOfMemory;
        return planFail(PipelineError.Usage, "unknown feature requested: {t}", .{e});
    };
    defer unified.deinit();
    const pruned = features_mod.pruneOptional(gpa, &graph, &unified) catch |e| {
        if (e == error.OutOfMemory) return PipelineError.OutOfMemory;
        return PipelineError.Io;
    };
    defer gpa.free(pruned);
    var pgraph = resolve_mod.ResolveGraph{ .arena = std.heap.ArenaAllocator.init(gpa), .nodes = pruned };
    defer pgraph.deinit();

    // 5. Profile overlay + unit graph (modes flipped to the requested mode
    //    BEFORE fingerprinting — mode feeds the profile hash).
    var prof = profile_mod.profileFor(opts.profile_name);
    profile_mod.applyProfileToml(&prof, alloc, root_text, opts.profile_name) catch |e| {
        if (e == error.OutOfMemory) return PipelineError.OutOfMemory;
        return planFail(PipelineError.Usage, "invalid [profile.{s}]: {t}", .{ opts.profile_name, e });
    };
    // Uniform arena ownership for the profile name (defaults borrow statics;
    // the plan outlives any caller scratch but never the arena).
    prof.name = alloc.dupe(u8, opts.profile_name) catch return PipelineError.OutOfMemory;
    // Target-kind gate (limitation L2): example/test/bench targets fail
    // LOUD here, naming the member + target + kind, instead of surfacing
    // as a bare `UnknownTarget` from the driver.
    for (ws.members) |*m| {
        for (m.manifest.targets) |t| {
            switch (t.kind) {
                .lib, .bin => {},
                else => return planFail(PipelineError.Usage, "target kind `{s}` for `{s}` `{s}` is not compilable in M4 (example/test/bench deferred)", .{ @tagName(t.kind), m.name, t.name }),
            }
        }
    }
    var ugraph = driver_mod.buildUnitGraph(gpa, ws, &pgraph, &unified, prof, opts.target_triple, tc) catch |e| {
        if (e == error.OutOfMemory) return PipelineError.OutOfMemory;
        return planFail(PipelineError.Usage, "cannot plan units: {t}", .{e});
    };
    errdefer ugraph.deinit();
    for (ugraph.units) |*u| u.mode = opts.mode;

    // 6. Two passes over topo order: fingerprints bottom-up (dep digests
    //    flow parent-ward), then argv → keys (dep output filenames are
    //    deterministic from dep fingerprints, so keys need no compilation).
    const order = ugraph.topoOrder(alloc) catch |e| {
        if (e == error.OutOfMemory) return PipelineError.OutOfMemory;
        return planFail(PipelineError.Usage, "unit dependency cycle", .{});
    };
    var planned = alloc.alloc(PlannedUnit, ugraph.units.len) catch return PipelineError.OutOfMemory;
    const rustflags = try currentRustflags(gpa);
    defer gpa.free(rustflags);
    for (order) |idx| {
        const u = &ugraph.units[idx];
        var dep_digests: std.ArrayList(Digest) = .empty;
        defer dep_digests.deinit(gpa);
        for (u.deps) |d| {
            const dd = planned[d.unit].fp.toDigest();
            dep_digests.append(gpa, dd) catch return PipelineError.OutOfMemory;
        }
        var fp = fingerprint_mod.fingerprintUnit(alloc, u, dep_digests.items, rustflags) catch |e| {
            if (e == error.OutOfMemory) return PipelineError.OutOfMemory;
            return PipelineError.Io;
        };
        fp.rustc_digest = tc.digest;
        fp.path_hash = planPathHash(u.src_path, ws.root_dir);
        const input_digest = fingerprint_mod.hashInputs(gpa, io, memberDirFor(ws, u.pkg_name)) catch |e| {
            if (e == error.OutOfMemory) return PipelineError.OutOfMemory;
            return planFail(PipelineError.Io, "cannot hash sources of `{s}`", .{u.pkg_name});
        };
        planned[idx] = .{
            .fp = fp,
            .input_digest = input_digest,
            .action_key = undefined,
            .crate_root = undefined,
            .out_dir_name = undefined,
            .rlib_file = null,
            .rmeta_file = null,
            .bin_file = null,
            .view_bin = null,
            .depinfo_file = undefined,
            .features_tag = undefined,
        };
    }
    const tc_tag = tc.tag(alloc) catch return PipelineError.OutOfMemory;
    const project_id = view_mod.projectId(alloc, ws.root_dir) catch return PipelineError.OutOfMemory;
    for (order) |idx| {
        const u = &ugraph.units[idx];
        const p = &planned[idx];
        const meta16 = p.fp.toHex16();
        // externName only fails on OOM in practice (dup + byte map).
        const extern_name = driver_mod.externName(alloc, u.target_name) catch return PipelineError.OutOfMemory;
        const out_dir_name = std.fmt.allocPrint(alloc, "{s}-{s}", .{ u.pkg_name, u.target_name }) catch return PipelineError.OutOfMemory;
        p.out_dir_name = out_dir_name;
        p.crate_root = try crateRootFor(alloc, io, ws, u);
        const meta_str = meta16[0..];
        if (u.kind == .lib) {
            // Check mode links nothing: no rlib filename is planned (ingest
            // and the view only ever see rmeta + dep-info).
            if (u.mode == .build) {
                p.rlib_file = view_mod.depFileName(alloc, extern_name, meta_str, ".rlib") catch return PipelineError.OutOfMemory;
            }
            p.rmeta_file = view_mod.depFileName(alloc, extern_name, meta_str, ".rmeta") catch return PipelineError.OutOfMemory;
        } else {
            p.view_bin = try alloc.dupe(u8, u.target_name);
            if (u.mode == .check) {
                p.rmeta_file = view_mod.depFileName(alloc, extern_name, meta_str, ".rmeta") catch return PipelineError.OutOfMemory;
            } else {
                p.bin_file = view_mod.depFileName(alloc, extern_name, meta_str, "") catch return PipelineError.OutOfMemory;
            }
        }
        // Dep-info carries the crate (extern) name + extra-filename suffix
        // (verified against real rustc: `<crate>-<meta>.d`).
        p.depinfo_file = std.fmt.allocPrint(alloc, "{s}-{s}.d", .{ extern_name, meta_str }) catch return PipelineError.OutOfMemory;
        p.features_tag = try actionkey_mod.featuresTag(alloc, u.features_sorted);
        // Action key over the normalized argv (dep rlib paths are
        // deterministic spool paths from dep fingerprints — known now).
        var dep_libs: std.ArrayList(invoke_mod.DepLib) = .empty;
        defer dep_libs.deinit(gpa);
        for (u.deps) |d| {
            const dp = &planned[d.unit];
            // Dep output selection (Task 11): check mode links rmeta,
            // build mode links rlib. A dep with NEITHER (bin-only member
            // depended upon) cannot satisfy `--extern` — loud, not silent.
            const dep_file = if (u.mode == .check)
                dp.rmeta_file orelse return planFail(PipelineError.Usage, "cannot extern check output of `{s}`", .{ugraph.units[d.unit].pkg_name})
            else
                dp.rlib_file orelse dp.rmeta_file orelse return planFail(PipelineError.Usage, "cannot extern bin-only dependency `{s}`", .{ugraph.units[d.unit].pkg_name});
            // Spool placeholder (never a real path at plan time): the
            // normalizer rewrites non-store paths to `spool:<basename>`,
            // and basenames are deterministic from fingerprints — so the
            // planned key EQUALS the execution key.
            const rlib_path = std.fs.path.join(gpa, &.{ "<spool-deps>", dep_file }) catch return PipelineError.OutOfMemory;
            defer gpa.free(rlib_path);
            try dep_libs.append(gpa, .{ .extern_name = d.extern_name, .rlib_path = rlib_path, .is_rmeta = u.mode == .check });
        }
        var inv = invoke_mod.buildRustcArgs(gpa, tc, u, prof, dep_libs.items, "<spool-out>", p.crate_root, null) catch return PipelineError.OutOfMemory;
        defer inv.deinit(gpa);
        const norm = actionkey_mod.normalizeArgs(gpa, inv.argv) catch return PipelineError.OutOfMemory;
        defer {
            for (norm) |s| gpa.free(s);
            gpa.free(norm);
        }
        const env_pairs = actionkey_mod.collectTrackedEnv(gpa) catch return PipelineError.OutOfMemory;
        defer {
            for (env_pairs) |s| gpa.free(s);
            gpa.free(env_pairs);
        }
        p.action_key = try actionkey_mod.actionKey(gpa, &p.fp, norm, p.input_digest, env_pairs);
    }

    // 7. Filtered topo order (kept members' units only).
    var forder: std.ArrayList(usize) = .empty;
    errdefer forder.deinit(alloc);
    for (order) |idx| {
        const u = &ugraph.units[idx];
        if (memberKept(ws, kept, u.pkg_name)) try forder.append(alloc, idx);
    }

    // 8. Lock writeback decision (bytes only; the write itself happens in
    //    buildWorkspace — planning never touches the project dir).
    const lock_version = lock_mod.versionForRustVersion(lowestRustVersion(members.items));
    var lock_changed = false;
    var lock_bytes: ?[]const u8 = null;
    {
        var cksums = std.StringHashMap(?[]const u8).init(gpa);
        defer cksums.deinit();
        if (ws.lock) |*lock| {
            for (lock.packages) |*lp| {
                if (lp.checksum == null) continue;
                const key = lock_mod.checksumKey(gpa, lp.name, lp.version, lp.source) catch return PipelineError.OutOfMemory;
                cksums.put(key, lp.checksum) catch return PipelineError.OutOfMemory;
            }
            var cit = cksums.iterator();
            defer {
                while (cit.next()) |kv| gpa.free(kv.key_ptr.*);
            }
            const prev_text = try readLockText(gpa, io, ws.root_dir);
            defer {
                if (prev_text) |t| gpa.free(t);
            }
            const fresh = lock_mod.writeLockWithOrig(gpa, &graph, &cksums, lock_version, prev_text) catch |e| {
                if (e == error.OutOfMemory) return PipelineError.OutOfMemory;
                return PipelineError.Io;
            };
            defer gpa.free(fresh);
            if (prev_text) |pt| {
                if (!std.mem.eql(u8, pt, fresh)) {
                    lock_changed = true;
                    lock_bytes = alloc.dupe(u8, fresh) catch return PipelineError.OutOfMemory;
                }
            } else {
                lock_changed = true;
                lock_bytes = alloc.dupe(u8, fresh) catch return PipelineError.OutOfMemory;
            }
        } else {
            const fresh = lock_mod.writeLock(gpa, &graph, &cksums, lock_version) catch |e| {
                if (e == error.OutOfMemory) return PipelineError.OutOfMemory;
                return PipelineError.Io;
            };
            defer gpa.free(fresh);
            lock_changed = true;
            lock_bytes = alloc.dupe(u8, fresh) catch return PipelineError.OutOfMemory;
        }
    }

    // Execute gate inputs: the built closure's first registry/git need
    // (null = path-only, compilable). buildWorkspace raises NeedFetch.
    const missing = firstMissingDep(members.items, kept);
    return .{
        .arena = arena,
        .graph = ugraph,
        .units = planned,
        .order = try forder.toOwnedSlice(alloc),
        .profile = prof,
        .profile_name = opts.profile_name,
        .tc_tag = tc_tag,
        .project_id = project_id,
        .mode = opts.mode,
        .lock_changed = lock_changed,
        .lock_bytes = lock_bytes,
        .lock_version = lock_version,
        .has_registry = missing != null,
        .registry_name = if (missing) |n| try alloc.dupe(u8, n) else "",
    };
}

// --- Small planning helpers ---

fn memberKept(ws: *const Workspace, kept: []const bool, pkg_name: []const u8) bool {
    for (ws.members, 0..) |*m, i| {
        if (std.mem.eql(u8, m.name, pkg_name)) return kept[i];
    }
    return false;
}

fn memberDirFor(ws: *const Workspace, pkg_name: []const u8) []const u8 {
    for (ws.members) |*m| {
        if (std.mem.eql(u8, m.name, pkg_name)) return m.dir;
    }
    return ws.root_dir;
}

/// Absolute crate-root source file for one unit: explicit manifest target
/// `path` wins, else `src/lib.rs` / `src/main.rs`. A missing file is `Usage`
/// naming it (manifest/layout error, exit 1 — never a compile attempt).
fn crateRootFor(alloc: std.mem.Allocator, io: std.Io, ws: *const Workspace, u: *const Unit) PipelineError![]const u8 {
    const m = ws.findMember(u.pkg_name) orelse {
        return planFail(PipelineError.Usage, "unknown member `{s}`", .{u.pkg_name});
    };
    for (m.manifest.targets) |t| {
        if (t.kind == u.kind and std.mem.eql(u8, t.name, u.target_name)) {
            if (t.path) |p| {
                const full = std.fs.path.join(alloc, &.{ m.dir, p }) catch return PipelineError.OutOfMemory;
                _ = std.Io.Dir.cwd().statFile(io, full, .{}) catch {
                    return planFail(PipelineError.Usage, "cannot find crate root `{s}` for `{s}`", .{ full, u.pkg_name });
                };
                return full;
            }
        }
    }
    const rel = if (u.kind == .lib) "src/lib.rs" else "src/main.rs";
    const full = std.fs.path.join(alloc, &.{ m.dir, rel }) catch return PipelineError.OutOfMemory;
    _ = std.Io.Dir.cwd().statFile(io, full, .{}) catch {
        return planFail(PipelineError.Usage, "cannot find crate root `{s}` for `{s}`", .{ full, u.pkg_name });
    };
    return full;
}

/// `path_hash` input (plan Interfaces: workspace-relative when under the
/// workspace root, absolute otherwise). Enables identical keys for
/// same-content checkouts once argv paths are canonicalized.
fn planPathHash(src_path: []const u8, ws_root: []const u8) Digest {
    if (src_path.len > ws_root.len and std.mem.startsWith(u8, src_path, ws_root) and src_path[ws_root.len] == '/') {
        return store_mod.hashBytes(src_path[ws_root.len + 1 ..]);
    }
    return store_mod.hashBytes(src_path);
}

fn currentRustflags(gpa: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
    const zname = try gpa.dupeZ(u8, "RUSTFLAGS");
    defer gpa.free(zname);
    if (std.c.getenv(zname)) |z| return gpa.dupe(u8, std.mem.span(z));
    return gpa.alloc(u8, 0);
}

fn readLockText(gpa: std.mem.Allocator, io: std.Io, ws_root: []const u8) PipelineError!?[]u8 {
    const path = std.fs.path.join(gpa, &.{ ws_root, "Cargo.lock" }) catch return PipelineError.OutOfMemory;
    defer gpa.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_manifest_bytes)) catch |e| {
        if (e == error.OutOfMemory) return PipelineError.OutOfMemory;
        if (e == error.FileNotFound) return null;
        return PipelineError.Io;
    };
}

// =====================================================================
// Execute: buildWorkspace (fetch → compile loop → materialize)
// =====================================================================

/// Cargo-shaped JSON envelope (local copy of `cli.JsonEnvelope`'s wire
/// shape — field order pinned; importing `cli` would cycle).
const Envelope = struct {
    reason: []const u8,
    package: []const u8,
    target: []const u8,
    profile: []const u8,
    success: bool,
    pub fn writeLine(self: *const Envelope, w: *std.Io.Writer) !void {
        try std.json.Stringify.value(self.*, .{}, w);
        try w.writeAll("\n");
    }
};

fn emitCached(w: *std.Io.Writer, unit: *const Unit, profile_name: []const u8, human: *std.Io.Writer) void {
    const env = Envelope{
        .reason = "unit-cached",
        .package = unit.pkg_name,
        .target = unit.target_name,
        .profile = profile_name,
        .success = true,
    };
    env.writeLine(w) catch {};
    human.print("Fresh {s} v{s} ({s})\n", .{ unit.pkg_name, unit.version, unit.target_name }) catch {};
}

fn copyFile(gpa: std.mem.Allocator, io: std.Io, src_abs: []const u8, dst_abs: []const u8) PipelineError!void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, src_abs, gpa, .limited(1 << 30)) catch |e| {
        if (e == error.OutOfMemory) return PipelineError.OutOfMemory;
        return PipelineError.Io;
    };
    defer gpa.free(bytes);
    if (std.fs.path.dirname(dst_abs)) |parent| {
        std.Io.Dir.cwd().createDirPath(io, parent) catch |e| {
            if (e == error.OutOfMemory) return PipelineError.OutOfMemory;
            return PipelineError.Io;
        };
    }
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dst_abs, .data = bytes }) catch |e| {
        if (e == error.OutOfMemory) return PipelineError.OutOfMemory;
        return PipelineError.Io;
    };
}

fn chmodAbs(io: std.Io, path: []const u8, mode: u32) PipelineError!void {
    var f = std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .write_only }) catch |e| {
        if (e == error.OutOfMemory) return PipelineError.OutOfMemory;
        return PipelineError.Io;
    };
    defer f.close(io);
    f.setPermissions(io, .fromMode(@intCast(mode))) catch |e| {
        if (e == error.OutOfMemory) return PipelineError.OutOfMemory;
        return PipelineError.Io;
    };
}

/// Wall-clock milliseconds (the `admission.now_ms` precedent) for build-id
/// and spool-dir uniqueness.
fn nowMs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

fn statMtimeNs(io: std.Io, path: []const u8) i128 {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return 0;
    return @as(i128, st.mtime.toMilliseconds()) * 1_000_000;
}

/// Appends cargo's `-C metadata` + `-C extra-filename` (deterministic
/// Task-10 layout) and, when `incremental`, `-C incremental=<sess_dir>`
/// (the `add_codegen_incremental` role) to a built invocation. Returns a
/// replacement invocation owning the extended argv (deinit frees
/// everything, exactly once — the original argv slice is NOT freed here).
fn extendInvocation(
    gpa: std.mem.Allocator,
    inv: *const invoke_mod.RustcInvocation,
    meta16: []const u8,
    sess_dir: ?[]const u8,
) std.mem.Allocator.Error!invoke_mod.RustcInvocation {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(gpa);
    try argv.appendSlice(gpa, inv.argv);
    try argv.append(gpa, try gpa.dupe(u8, "-C"));
    try argv.append(gpa, try std.fmt.allocPrint(gpa, "metadata={s}", .{meta16}));
    try argv.append(gpa, try gpa.dupe(u8, "-C"));
    try argv.append(gpa, try std.fmt.allocPrint(gpa, "extra-filename=-{s}", .{meta16}));
    if (sess_dir) |s| {
        try argv.append(gpa, try gpa.dupe(u8, "-C"));
        try argv.append(gpa, try std.fmt.allocPrint(gpa, "incremental={s}", .{s}));
    }
    return .{
        .argv = try argv.toOwnedSlice(gpa),
        .env_extra = inv.env_extra,
        .out_dir = inv.out_dir,
        .dep_info_path = inv.dep_info_path,
    };
}

/// Frees an `extendInvocation` result WITHOUT touching the borrowed
/// `env_extra`/`out_dir`/`dep_info_path` (owned by the base invocation).
/// Only the extended argv slice + the appended elements are freed here;
/// the base elements stay owned by the base invocation's deinit.
fn freeExtended(gpa: std.mem.Allocator, base_len: usize, ext: *invoke_mod.RustcInvocation) void {
    for (ext.argv[base_len..]) |s| gpa.free(s);
    gpa.free(ext.argv);
}

// --- Execute: one build ------------------------------------------------

/// Executes a plan: lock writeback → fetch → per-unit compile loop →
/// view materialization. Returns the cargo exit code (0 ok, 101 rustc
/// failure — diagnostics already emitted). Layout: spool under
/// `<cache_dir>/spool/rime-build-<id>/` (`units/<pkg>-<target>/`,
/// shared `deps/`, `sessions/<pkg>-<target>/`), deleted at the end on ALL
/// paths (after view materialization, so the view never depends on spool).
pub fn buildWorkspace(
    gpa: std.mem.Allocator,
    io: std.Io,
    store: *Store,
    ws_root: []const u8,
    ws: *const Workspace,
    tc: *const Toolchain,
    opts: PipelineOptions,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) PipelineError!u8 {
    diag_len = 0;
    var plan = try buildPlan(gpa, io, store, ws, tc, opts);
    defer plan.deinit();
    const json = opts.message_format_json;
    const out_w = if (json) stdout else stderr;

    // Execute gate (Task 10): the plan always succeeds offline, but M4
    // compiles workspace members only — a built unit needing registry/git
    // sources is the actionable `need fetch` diagnostic (exit 1).
    if (plan.has_registry) {
        return planFail(PipelineError.NeedFetch, "{s} requires M2 fetch (registry sources are not compilable in M4)", .{plan.registry_name});
    }

    // Lock writeback (never under -p: partial resolve must not corrupt the
    // full-workspace lock; never without changes).
    if (plan.lock_changed) {
        if (opts.only_package != null) {
            // Skip silently (documented M4 limitation).
        } else if (opts.locked or opts.frozen) {
            const flag = if (opts.frozen) "--frozen" else "--locked";
            const prev_text = try readLockText(gpa, io, ws_root);
            defer {
                if (prev_text) |t| gpa.free(t);
            }
            const verb: []const u8 = if (prev_text != null) "update" else "create";
            return planFail(PipelineError.LockedViolation, "cannot {s} the lock file {s}/Cargo.lock because {s} was passed to prevent this", .{ verb, ws_root, flag });
        } else if (plan.lock_bytes) |bytes| {
            const dest = std.fs.path.join(gpa, &.{ ws_root, "Cargo.lock" }) catch return PipelineError.OutOfMemory;
            defer gpa.free(dest);
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dest, .data = bytes }) catch |e| {
                if (e == error.OutOfMemory) return PipelineError.OutOfMemory;
                return PipelineError.Io;
            };
        }
    }

    // Fetch (path-only verified no-op): the plan gate already rejected
    // registry/git declarations, so `ensureSources` over the lockfile only
    // ever sees path rows (skipped). Fresh lockless plans skip it (nothing
    // but path sources exist — anything else failed the plan gate).
    if (ws.lock) |*lock| {
        var git = fetch_mod.CliGit{};
        var git_decls = fetch_mod.GitDecls.init(gpa);
        defer git_decls.deinit();
        // Stub registry client: unreachable for path-only locks (plan gate
        // rejected every registry/git declaration). Stack-borrowed, never
        // dereferenced — its methods only run for registry/git packages.
        var stub_reg = fetch_mod.FileRegistry{ .root = "<path-only-stub-never-queried>" };
        const fetched = fetch_mod.ensureSources(gpa, io, store, stub_reg.client(), git.runner(), .{
            .offline = opts.offline,
            .frozen = opts.frozen,
            .locked = opts.locked,
            .cache_dir = opts.cache_dir,
        }, lock, &git_decls) catch |e| {
            return mapFetchError(e);
        };
        defer {
            for (fetched) |*s| s.deinit();
            gpa.free(fetched);
        }
    }

    // Leases (best-effort GC protection; never fail the build).
    const build_id = std.fmt.allocPrint(gpa, "rime-build-{d}", .{nowMs(io)}) catch return PipelineError.OutOfMemory;
    defer gpa.free(build_id);
    var lease_ok = true;
    {
        var digests: std.ArrayList(Digest) = .empty;
        defer digests.deinit(gpa);
        for (plan.order) |idx| digests.append(gpa, plan.units[idx].input_digest) catch {
            lease_ok = false;
            break;
        };
        if (lease_ok) store.leasePut(io, build_id, digests.items) catch {
            lease_ok = false;
        };
    }
    defer {
        if (lease_ok) store.leaseDrop(io, build_id) catch {};
    }

    // Spool layout.
    const spool_root = std.fmt.allocPrint(gpa, "{s}/spool/rime-build-{d}", .{ opts.cache_dir, nowMs(io) }) catch return PipelineError.OutOfMemory;
    defer gpa.free(spool_root);
    const spool_deps = std.fmt.allocPrint(gpa, "{s}/deps", .{spool_root}) catch return PipelineError.OutOfMemory;
    defer gpa.free(spool_deps);
    std.Io.Dir.cwd().createDirPath(io, spool_deps) catch |e| {
        if (e == error.OutOfMemory) return PipelineError.OutOfMemory;
        return PipelineError.Io;
    };
    defer {
        std.Io.Dir.cwd().deleteTree(io, spool_root) catch {};
    }

    // History for the checkFresh fast path (Task 13).
    var history = view_mod.readLastBuildUnits(gpa, io, ws_root, opts.profile_name) catch return PipelineError.OutOfMemory;
    defer {
        if (history) |*h| h.deinit();
    }

    const profile_dir = view_mod.profileDirName(opts.profile_name);
    var spool_map = view_mod.SpoolMap.init(gpa);
    defer {
        var kit = spool_map.iterator();
        while (kit.next()) |kv| {
            gpa.free(kv.key_ptr.*);
            gpa.free(kv.value_ptr.*);
        }
        spool_map.deinit();
    }
    // Per-unit results for the view step.
    var manifests = gpa.alloc(?Digest, plan.graph.units.len) catch return PipelineError.OutOfMemory;
    defer gpa.free(manifests);
    @memset(manifests, null);
    var compiled = gpa.alloc(bool, plan.graph.units.len) catch return PipelineError.OutOfMemory;
    defer gpa.free(compiled);
    @memset(compiled, false);

    for (plan.order) |idx| {
        const u = &plan.graph.units[idx];
        const p = &plan.units[idx];
        const unit_out = std.fs.path.join(gpa, &.{ spool_root, "units", p.out_dir_name }) catch return PipelineError.OutOfMemory;
        defer gpa.free(unit_out);
        std.Io.Dir.cwd().createDirPath(io, unit_out) catch |e| {
            if (e == error.OutOfMemory) return PipelineError.OutOfMemory;
            return PipelineError.Io;
        };

        // (a) mtime fast path: dep-info in the view + recorded output mtime
        // say nothing changed → Fresh without hashing or spawning. View
        // outputs are current by the freshness proof; copy linkables to the
        // shared deps dir for downstream units.
        if (history) |*h| {
            if (h.mtimeFor(u.pkg_name, u.target_name)) |recorded| {
                const view_d = std.fs.path.join(gpa, &.{ ws_root, "target", profile_dir, "deps", p.depinfo_file }) catch return PipelineError.OutOfMemory;
                defer gpa.free(view_d);
                const fresh = fingerprint_mod.checkFresh(io, view_d, recorded) catch false;
                if (fresh and try tryCopyViewOutputs(gpa, io, ws_root, profile_dir, u, p, opts.mode, spool_deps)) {
                    emitCached(out_w, u, opts.profile_name, stderr);
                    if (lease_ok) store.leaseRenew(io, build_id) catch {};
                    continue;
                }
            }
        }

        // (b) Action-key lookup: hit → materialize dep outputs to the shared
        // deps dir from verified store bytes, no spawn.
        if (compile_mod.tryIngestCacheHit(gpa, io, store, p.action_key) catch |e| {
            if (e == error.OutOfMemory) return PipelineError.OutOfMemory;
            return PipelineError.StoreRead;
        }) |man_digest| {
            manifests[idx] = man_digest;
            var man = store.getManifest(io, gpa, man_digest) catch |e| {
                if (e == error.OutOfMemory) return PipelineError.OutOfMemory;
                return PipelineError.StoreRead;
            };
            defer man.deinit(gpa);
            for (man.outputs) |o| {
                const dest = std.fs.path.join(gpa, &.{ spool_deps, o.path }) catch return PipelineError.OutOfMemory;
                defer gpa.free(dest);
                _ = store.materialize(io, o.digest, dest, o.mode) catch |e| {
                    if (e == error.OutOfMemory) return PipelineError.OutOfMemory;
                    return PipelineError.StoreRead;
                };
            }
            emitCached(out_w, u, opts.profile_name, stderr);
            if (lease_ok) store.leaseRenew(io, build_id) catch {};
            continue;
        }

        // (c) Miss: restore session, spawn, emit, ingest, save session.
        stderr.print("Compiling {s} v{s} ({s})\n", .{ u.pkg_name, u.version, u.target_name }) catch {};
        // Dep --extern wiring: shared deps dir first (placed by earlier
        // units), else dep out_dirs from THIS run (freshly compiled),
        // copied in. Store-manifest deps were materialized at their own
        // (b) turn, so (i) covers them.
        var dep_libs: std.ArrayList(invoke_mod.DepLib) = .empty;
        defer dep_libs.deinit(gpa);
        for (u.deps) |d| {
            const dp = &plan.units[d.unit];
            // Plan-time guard (key loop) already rejected bin-only deps as
            // un-externable; these unwraps are unreachable in practice.
            const dep_file = if (opts.mode == .check) dp.rmeta_file.? else dp.rlib_file orelse dp.rmeta_file.?;
            const pooled = std.fs.path.join(gpa, &.{ spool_deps, dep_file }) catch return PipelineError.OutOfMemory;
            defer gpa.free(pooled);
            const present = std.Io.Dir.cwd().statFile(io, pooled, .{}) catch null;
            const use_path: []const u8 = if (present != null) pooled else blk: {
                const dep_out = std.fs.path.join(gpa, &.{ spool_root, "units", dp.out_dir_name, dep_file }) catch return PipelineError.OutOfMemory;
                defer gpa.free(dep_out);
                _ = std.Io.Dir.cwd().statFile(io, dep_out, .{}) catch {
                    return planFail(PipelineError.Io, "missing dependency output `{s}` for `{s}`", .{ dep_file, u.pkg_name });
                };
                try copyFile(gpa, io, dep_out, pooled);
                break :blk pooled;
            };
            try dep_libs.append(gpa, .{ .extern_name = d.extern_name, .rlib_path = use_path, .is_rmeta = opts.mode == .check });
        }
        const sess_dir = std.fs.path.join(gpa, &.{ spool_root, "sessions", p.out_dir_name }) catch return PipelineError.OutOfMemory;
        defer gpa.free(sess_dir);
        const want_session = plan.profile.incremental;
        if (want_session) {
            _ = compile_mod.materializeSession(gpa, io, store, compile_mod.sessionKey(&p.fp, p.input_digest), sess_dir) catch |e| {
                if (e == error.OutOfMemory) return PipelineError.OutOfMemory;
                return PipelineError.StoreRead;
            };
        }
        var base = invoke_mod.buildRustcArgs(gpa, tc, u, plan.profile, dep_libs.items, unit_out, p.crate_root, null) catch return PipelineError.OutOfMemory;
        defer base.deinit(gpa);
        const meta16 = p.fp.toHex16();
        var ext = extendInvocation(gpa, &base, meta16[0..], if (want_session) sess_dir else null) catch return PipelineError.OutOfMemory;
        defer freeExtended(gpa, base.argv.len, &ext);
        var out = compile_mod.spawnRustc(gpa, io, &ext) catch |e| {
            if (e == error.OutOfMemory) return PipelineError.OutOfMemory;
            return planFail(PipelineError.Io, "cannot spawn rustc for `{s}`: {t}", .{ u.pkg_name, e });
        };
        defer out.deinit();
        // Cargo-final bin copy (bins land at cargo-final `<target>` names;
        // a missing binary is loud — rustc broke its contract).
        if (out.exited == 0 and p.bin_file != null) {
            try binFinalCopy(gpa, io, unit_out, p.bin_file.?, p.view_bin.?);
        }
        const artifacts = try emittedArtifacts(gpa, io, unit_out, u, p);
        defer {
            for (artifacts) |s| gpa.free(s);
            gpa.free(artifacts);
        }
        const ok = compile_mod.emitEnvelopes(gpa, io, out_w, u, opts.profile_name, &out, artifacts, json) catch |e| {
            if (e == error.OutOfMemory) return PipelineError.OutOfMemory;
            if (e == error.RustcFailed) return PipelineError.RustcFailed;
            return PipelineError.Io;
        };
        // Zero exit WITH error-level diagnostics (defensive — rustc
        // promises nonzero there): still a failed build.
        if (!ok) return PipelineError.RustcFailed;
        // Tags + ingest (StoreFull inside degrades to spool-only, never fails).
        const tags = try actionkey_mod.unitTags(gpa, plan.tc_tag, u.target_triple, opts.profile_name, p.features_tag, plan.project_id, u.pkg_name, u.version, "rustc");
        defer gpa.free(tags);
        const expected = try expectedOutputs(gpa, u, p);
        defer gpa.free(expected);
        const ing = compile_mod.ingestUnitOutputs(gpa, io, store, u, unit_out, expected, tags, p.action_key, if (json) null else stderr) catch |e| {
            if (e == error.OutOfMemory) return PipelineError.OutOfMemory;
            return PipelineError.StoreRead;
        };
        manifests[idx] = ing.manifest_digest;
        compiled[idx] = true;
        // Spool-map values are duped: `unit_out` frees at iteration end
        // but the map lives until the view step (teardown frees both).
        // No errdefer here: on success the map owns both buffers (teardown
        // frees), so each failure path frees exactly what it owns.
        const skey = view_mod.spoolKey(gpa, u.pkg_name, u.target_name) catch return PipelineError.OutOfMemory;
        const sdir = gpa.dupe(u8, unit_out) catch |e| {
            gpa.free(skey);
            if (e == error.OutOfMemory) return PipelineError.OutOfMemory;
            return PipelineError.Io;
        };
        spool_map.put(skey, sdir) catch {
            gpa.free(skey);
            gpa.free(sdir);
            return PipelineError.OutOfMemory;
        };
        if (want_session) {
            compile_mod.ingestSession(gpa, io, store, compile_mod.sessionKey(&p.fp, p.input_digest), sess_dir, tags) catch |e| {
                if (e == error.OutOfMemory) return PipelineError.OutOfMemory;
                return PipelineError.StoreRead;
            };
        }
        // Linkables for downstream units land in the shared deps dir now
        // (their --extern/-L point there, never at per-unit out dirs).
        try copyLinkables(gpa, io, unit_out, spool_deps, u, p);
        if (lease_ok) store.leaseRenew(io, build_id) catch {};
    }

    // View: store manifests, spool fallback for StoreFull units.
    var plans = gpa.alloc(view_mod.UnitPlan, plan.order.len) catch return PipelineError.OutOfMemory;
    defer gpa.free(plans);
    for (plan.order, 0..) |idx, i| {
        const u = &plan.graph.units[idx];
        const p = &plan.units[idx];
        var outs: std.ArrayList([]const u8) = .empty;
        defer outs.deinit(gpa);
        if (p.rlib_file) |f| outs.append(gpa, f) catch return PipelineError.OutOfMemory;
        if (p.rmeta_file) |f| outs.append(gpa, f) catch return PipelineError.OutOfMemory;
        if (p.view_bin) |f| {
            // View holds the cargo-final bin name (renamed pre-ingest).
            if (compiled[idx]) outs.append(gpa, f) catch return PipelineError.OutOfMemory;
        }
        outs.append(gpa, p.depinfo_file) catch return PipelineError.OutOfMemory;
        plans[i] = .{
            .package = u.pkg_name,
            .version = u.version,
            .target = u.target_name,
            .kind = u.kind,
            .manifest_digest = manifests[idx],
            .outputs = outs.toOwnedSlice(gpa) catch return PipelineError.OutOfMemory,
        };
    }
    defer {
        for (plans) |pl| gpa.free(pl.outputs);
    }
    view_mod.materializeOutputsWithSpool(gpa, io, store, ws_root, opts.profile_name, plans, &spool_map) catch |e| {
        if (e == error.OutOfMemory) return PipelineError.OutOfMemory;
        return PipelineError.Io;
    };
    // Record view output mtimes (freshness history), merging skipped units'
    // previous rows so history survives partial rebuilds.
    var full = gpa.alloc(view_mod.ViewUnitFull, plan.order.len) catch return PipelineError.OutOfMemory;
    defer gpa.free(full);
    for (plan.order, 0..) |idx, i| {
        const u = &plan.graph.units[idx];
        const p = &plan.units[idx];
        const mtime = viewMtimeFor(gpa, io, ws_root, profile_dir, u, p);
        const prev: i128 = if (history) |*h| h.mtimeFor(u.pkg_name, u.target_name) orelse 0 else 0;
        full[i] = .{
            .package = u.pkg_name,
            .version = u.version,
            .target = u.target_name,
            .manifest_digest = manifests[idx],
            .toolchain = plan.tc_tag,
            .features = p.features_tag,
            .target_triple = u.target_triple,
            .output_mtime_ns = if (compiled[idx] or manifests[idx] != null) mtime else prev,
        };
    }
    view_mod.writeViewMetaFull(gpa, io, ws_root, opts.profile_name, full) catch |e| {
        if (e == error.OutOfMemory) return PipelineError.OutOfMemory;
        return PipelineError.Io;
    };
    // retainProject is bookkeeping (best-effort like leases).
    {
        var mlist: std.ArrayList(Digest) = .empty;
        defer mlist.deinit(gpa);
        for (manifests) |md| {
            if (md) |d| mlist.append(gpa, d) catch break;
        }
        store.retainProject(io, plan.project_id, mlist.items) catch {};
    }

    if (json) {
        const done = Envelope{ .reason = "build-finished", .package = "", .target = "", .profile = opts.profile_name, .success = true };
        done.writeLine(stdout) catch |e| {
            if (e == error.OutOfMemory) return PipelineError.OutOfMemory;
            return PipelineError.Io;
        };
    } else {
        stderr.print("Finished {s} profile\n", .{opts.profile_name}) catch {};
    }
    return 0;
}

// --- Execute helpers ---

fn mapFetchError(e: fetch_mod.FetchError) PipelineError {
    switch (e) {
        error.OutOfMemory => return PipelineError.OutOfMemory,
        error.OfflineMissing, error.FrozenViolation, error.LockedViolation => return planFail(PipelineError.NeedFetch, "fetch unavailable for registry sources in M4: {t}", .{e}),
        error.StoreFull => return PipelineError.StoreFull,
        error.StoreRead => return PipelineError.StoreRead,
        else => return planFail(PipelineError.Io, "fetch failed: {t}", .{e}),
    }
}

/// Primary view output path for one unit (bin-build → profile root final
/// name; everything else → deps/ suffixed name).
fn viewPrimaryFor(ws_root: []const u8, profile_dir: []const u8, u: *const Unit, p: *const PlannedUnit, buf: *[512]u8) []const u8 {
    if (u.kind == .bin and u.mode == .build) {
        return std.fmt.bufPrint(buf, "{s}/target/{s}/{s}", .{ ws_root, profile_dir, p.view_bin.? }) catch ws_root;
    }
    const f = if (u.mode == .check) p.rmeta_file.? else p.rlib_file orelse p.rmeta_file.?;
    return std.fmt.bufPrint(buf, "{s}/target/{s}/deps/{s}", .{ ws_root, profile_dir, f }) catch ws_root;
}

fn viewMtimeFor(gpa: std.mem.Allocator, io: std.Io, ws_root: []const u8, profile_dir: []const u8, u: *const Unit, p: *const PlannedUnit) i128 {
    _ = gpa;
    var buf: [512]u8 = undefined;
    return statMtimeNs(io, viewPrimaryFor(ws_root, profile_dir, u, p, &buf));
}

/// Copies a unit's linkables (rlib + rmeta when present) from the view into
/// the shared spool deps dir. Missing files (absent rmeta under pipelining
/// variance, absent view outputs) read as false — never an error (the full
/// path recompiles correctly).
fn tryCopyViewOutputs(
    gpa: std.mem.Allocator,
    io: std.Io,
    ws_root: []const u8,
    profile_dir: []const u8,
    u: *const Unit,
    p: *const PlannedUnit,
    mode: CompileMode,
    spool_deps: []const u8,
) PipelineError!bool {
    if (u.kind == .bin and mode == .build) {
        var buf: [512]u8 = undefined;
        const vbin = viewPrimaryFor(ws_root, profile_dir, u, p, &buf);
        _ = std.Io.Dir.cwd().statFile(io, vbin, .{}) catch return false;
        return true;
    }
    const linkable = if (mode == .check) p.rmeta_file.? else p.rlib_file orelse return false;
    const src = std.fs.path.join(gpa, &.{ ws_root, "target", profile_dir, "deps", linkable }) catch return PipelineError.OutOfMemory;
    defer gpa.free(src);
    const dst = std.fs.path.join(gpa, &.{ spool_deps, linkable }) catch return PipelineError.OutOfMemory;
    defer gpa.free(dst);
    copyFile(gpa, io, src, dst) catch return false;
    if (mode == .build) {
        if (p.rmeta_file) |rmeta| {
            const rsrc = std.fs.path.join(gpa, &.{ ws_root, "target", profile_dir, "deps", rmeta }) catch return PipelineError.OutOfMemory;
            defer gpa.free(rsrc);
            const rdst = std.fs.path.join(gpa, &.{ spool_deps, rmeta }) catch return PipelineError.OutOfMemory;
            defer gpa.free(rdst);
            copyFile(gpa, io, rsrc, rdst) catch {};
        }
    }
    return true;
}

/// Cargo-final bin copy: `<out>/<crate>-<meta>` → `<out>/<target>`.
/// A missing source means rustc did not produce the binary — loud `Io`.
fn binFinalCopy(gpa: std.mem.Allocator, io: std.Io, unit_out: []const u8, bin_file: []const u8, view_bin: []const u8) PipelineError!void {
    const src = std.fs.path.join(gpa, &.{ unit_out, bin_file }) catch return PipelineError.OutOfMemory;
    defer gpa.free(src);
    const dst = std.fs.path.join(gpa, &.{ unit_out, view_bin }) catch return PipelineError.OutOfMemory;
    defer gpa.free(dst);
    _ = std.Io.Dir.cwd().statFile(io, src, .{}) catch {
        return planFail(PipelineError.Io, "rustc produced no binary `{s}`", .{bin_file});
    };
    try copyFile(gpa, io, src, dst);
    std.Io.Dir.cwd().deleteFile(io, src) catch |e| {
        if (e == error.OutOfMemory) return PipelineError.OutOfMemory;
        return PipelineError.Io;
    };
    try chmodAbs(io, dst, 0o755);
}

/// Absolute spool paths of actually-emitted files for the
/// `compiler-artifact` envelope (post-rename names; dep-info included).
fn emittedArtifacts(gpa: std.mem.Allocator, io: std.Io, unit_out: []const u8, u: *const Unit, p: *const PlannedUnit) PipelineError![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |s| gpa.free(s);
        out.deinit(gpa);
    }
    // Binaries are listed under their cargo-final (renamed) names.
    const bin_name: ?[]const u8 = if (u.kind == .bin and u.mode == .build) p.view_bin else null;
    const names = [_]?[]const u8{ p.rlib_file, p.rmeta_file, bin_name, p.depinfo_file };
    for (names) |maybe| {
        const f = maybe orelse continue;
        const full = std.fs.path.join(gpa, &.{ unit_out, f }) catch return PipelineError.OutOfMemory;
        errdefer gpa.free(full);
        _ = std.Io.Dir.cwd().statFile(io, full, .{}) catch {
            gpa.free(full);
            continue;
        };
        try out.append(gpa, full);
    }
    return out.toOwnedSlice(gpa);
}

/// `ExpectedOutput` list for ingestion (post-rename names: the view-final
/// bin name for build-mode bins; a missing `.rmeta` is pipelining variance
/// and skipped by ingest).
fn expectedOutputs(gpa: std.mem.Allocator, u: *const Unit, p: *const PlannedUnit) PipelineError![]compile_mod.ExpectedOutput {
    var out: std.ArrayList(compile_mod.ExpectedOutput) = .empty;
    errdefer out.deinit(gpa);
    if (u.kind == .lib) {
        if (u.mode == .build) try out.append(gpa, .{ .filename = p.rlib_file.?, .kind = .rlib, .mode = 0o444 });
        try out.append(gpa, .{ .filename = p.rmeta_file.?, .kind = .rmeta, .mode = 0o444 });
    } else {
        if (u.mode == .build) {
            try out.append(gpa, .{ .filename = p.view_bin.?, .kind = .bin, .mode = 0o755 });
        } else {
            try out.append(gpa, .{ .filename = p.rmeta_file.?, .kind = .rmeta, .mode = 0o444 });
        }
    }
    try out.append(gpa, .{ .filename = p.depinfo_file, .kind = .dep_info, .mode = 0o444 });
    return out.toOwnedSlice(gpa);
}

/// Copies a fresh unit's linkables (rlib + rmeta when present) into the
/// shared spool deps dir for downstream `--extern`/`-L`.
fn copyLinkables(gpa: std.mem.Allocator, io: std.Io, unit_out: []const u8, spool_deps: []const u8, u: *const Unit, p: *const PlannedUnit) PipelineError!void {
    _ = u;
    const names = [_]?[]const u8{ p.rlib_file, p.rmeta_file };
    for (names) |maybe| {
        const f = maybe orelse continue;
        const src = std.fs.path.join(gpa, &.{ unit_out, f }) catch return PipelineError.OutOfMemory;
        defer gpa.free(src);
        _ = std.Io.Dir.cwd().statFile(io, src, .{}) catch continue;
        const dst = std.fs.path.join(gpa, &.{ spool_deps, f }) catch return PipelineError.OutOfMemory;
        defer gpa.free(dst);
        try copyFile(gpa, io, src, dst);
    }
}

// =====================================================================
// Task 12: validation plan dumps
// =====================================================================

/// Golden plan dump (Task 12): sorted `[{package, version, target, kind,
/// edition, features[], profile, triple, deps[extern names]}]`, one line.
/// Fingerprint/meta fields are EXCLUDED (they bind toolchain bytes, not
/// cargo semantics); no absolute paths appear, so no normalization is
/// needed. gpa-owned (caller frees).
pub fn dumpUnitPlan(gpa: std.mem.Allocator, planned: *const PlannedBuild) PipelineError![]u8 {
    const PlanRow = struct {
        package: []const u8,
        version: []const u8,
        target: []const u8,
        kind: []const u8,
        edition: []const u8,
        features: []const []const u8,
        profile: []const u8,
        triple: []const u8,
        deps: []const []const u8,
    };
    const idxs = gpa.alloc(usize, planned.order.len) catch return PipelineError.OutOfMemory;
    defer gpa.free(idxs);
    @memcpy(idxs, planned.order);
    std.mem.sort(usize, idxs, planned, struct {
        fn lt(pl: *const PlannedBuild, a: usize, b: usize) bool {
            const ua = &pl.graph.units[a];
            const ub = &pl.graph.units[b];
            const pc = std.mem.order(u8, ua.pkg_name, ub.pkg_name);
            if (pc != .eq) return pc == .lt;
            return std.mem.order(u8, ua.target_name, ub.target_name) == .lt;
        }
    }.lt);
    var rows: std.ArrayList(PlanRow) = .empty;
    defer rows.deinit(gpa);
    for (idxs) |idx| {
        const u = &planned.graph.units[idx];
        var deps: std.ArrayList([]const u8) = .empty;
        defer deps.deinit(gpa);
        for (u.deps) |d| try deps.append(gpa, d.extern_name);
        std.mem.sort([]const u8, deps.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lt);
        try rows.append(gpa, .{
            .package = u.pkg_name,
            .version = u.version,
            .target = u.target_name,
            .kind = @tagName(u.kind),
            .edition = u.edition,
            .features = u.features_sorted,
            .profile = planned.profile_name,
            .triple = u.target_triple,
            .deps = try deps.toOwnedSlice(gpa),
        });
    }
    defer {
        for (rows.items) |r| gpa.free(r.deps);
    }
    const body = std.json.Stringify.valueAlloc(gpa, rows.items, .{}) catch return PipelineError.OutOfMemory;
    defer gpa.free(body);
    return std.fmt.allocPrint(gpa, "{s}\n", .{body}) catch return PipelineError.OutOfMemory;
}

// =====================================================================
// Tests (Tasks 10–13)
// =====================================================================

fn stubToolchain() Toolchain {
    return .{
        .rustc_path = "rustc",
        .version = "1.99.0-nightly",
        .host_target = "aarch64-apple-darwin",
        .commit_hash = "1ed2df61a19042f231709eb05d032ae9e2cb2084",
        .sysroot = "/nonexistent",
        .digest = store_mod.hashBytes("stub"),
    };
}

fn testOptions(mode: CompileMode) PipelineOptions {
    return .{
        .manifest_path = null,
        .profile_name = "dev",
        .target_triple = null,
        .features_cli = &.{},
        .all_features = false,
        .no_default = false,
        .mode = mode,
        .message_format_json = false,
        .offline = false,
        .frozen = false,
        .locked = false,
        .only_package = null,
        .cache_dir = "/tmp/rime-test-cache",
    };
}

fn openScratchStore(io: std.Io) !struct { tmp: std.testing.TmpDir, store: Store } {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    const s = try Store.open(io, tmp.dir, .{});
    return .{ .tmp = tmp, .store = s };
}

test "pipeline plans member order without compiling" {
    const gpa = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var ws = try workspace_mod.discover(gpa, io, "testdata/cargo/workspace", null);
    defer ws.deinit();
    var holder = try openScratchStore(io);
    defer holder.tmp.cleanup();
    defer holder.store.close(io);
    var tc = stubToolchain();
    var plan = try buildPlan(gpa, io, &holder.store, &ws, &tc, testOptions(.build));
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 2), plan.order.len);
    try std.testing.expectEqualStrings("b", plan.graph.units[plan.order[0]].pkg_name);
    try std.testing.expectEqualStrings("a", plan.graph.units[plan.order[1]].pkg_name);
    try std.testing.expectEqualStrings("rlib", plan.graph.units[plan.order[0]].crate_types[0]);
    // Crate roots resolve to real source files.
    try std.testing.expect(std.mem.endsWith(u8, plan.units[plan.order[0]].crate_root, "src/lib.rs"));
    // Unit edges carry the extern/dep names.
    try std.testing.expectEqual(@as(usize, 1), plan.graph.units[plan.order[1]].deps.len);
    try std.testing.expectEqualStrings("b", plan.graph.units[plan.order[1]].deps[0].extern_name);
    // Keys are deterministic across plans (same inputs → same key).
    var plan2 = try buildPlan(gpa, io, &holder.store, &ws, &tc, testOptions(.build));
    defer plan2.deinit();
    try std.testing.expectEqual(plan.units[plan.order[0]].action_key.bytes, plan2.units[plan2.order[0]].action_key.bytes);
    try std.testing.expect(!std.mem.eql(u8, &plan.units[plan.order[0]].action_key.bytes, &plan.units[plan.order[1]].action_key.bytes));
}

test "check mode plans rmeta-only units" {
    const gpa = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var ws = try workspace_mod.discover(gpa, io, "testdata/cargo/workspace", null);
    defer ws.deinit();
    var holder = try openScratchStore(io);
    defer holder.tmp.cleanup();
    defer holder.store.close(io);
    var tc = stubToolchain();
    var plan = try buildPlan(gpa, io, &holder.store, &ws, &tc, testOptions(.check));
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 2), plan.order.len);
    for (plan.order) |idx| {
        const u = &plan.graph.units[idx];
        const p = &plan.units[idx];
        try std.testing.expect(u.mode == .check);
        try std.testing.expect(p.rlib_file == null); // nothing linked in check
        try std.testing.expect(p.rmeta_file != null);
        try std.testing.expect(std.mem.endsWith(u8, p.rmeta_file.?, ".rmeta"));
        try std.testing.expect(p.bin_file == null);
    }
}

test "action keys differ across feature sets and profiles" {
    // Always-run companion for the flag-change proof (lives here, not in
    // actionkey.zig — that file is owned by another lane).
    const gpa = std.testing.allocator;
    const base = Fingerprint{
        .rustc_digest = store_mod.hashBytes("r"),
        .features_sorted = &.{},
        .target_desc_hash = store_mod.hashBytes("t"),
        .profile_hash = store_mod.hashBytes("p-dev"),
        .path_hash = store_mod.hashBytes("h"),
        .dep_fps = &.{},
        .rustflags_hash = store_mod.hashBytes(""),
        .config_hash = store_mod.hashBytes("c"),
    };
    const argv = [_][]const u8{ "rustc", "--crate-name", "foo" };
    const k_base = try actionkey_mod.actionKey(gpa, &base, &argv, store_mod.hashBytes("in"), &.{});
    var feat = base;
    feat.features_sorted = &.{"json"};
    const k_feat = try actionkey_mod.actionKey(gpa, &feat, &argv, store_mod.hashBytes("in"), &.{});
    try std.testing.expect(!std.mem.eql(u8, &k_base.bytes, &k_feat.bytes));
    var prof = base;
    prof.profile_hash = store_mod.hashBytes("p-release");
    const k_prof = try actionkey_mod.actionKey(gpa, &prof, &argv, store_mod.hashBytes("in"), &.{});
    try std.testing.expect(!std.mem.eql(u8, &k_base.bytes, &k_prof.bytes));
}

// --- Test helpers: scratch trees, streams, goldens ---

/// Recursive tree copy for oracle tests (validation/ + testdata/ are NEVER
/// dirtied: every compiling test works on a `/tmp` copy). `target/` dirs
/// are skipped (cargo's regenerable cache — gigabytes in validation/).
fn copyTree(gpa: std.mem.Allocator, io: std.Io, src_in: []const u8, dst_abs: []const u8) !void {
    // Absolute-ize the source (tests pass repo-relative fixture paths;
    // `openDirAbsolute` needs a true absolute path). Sentinel-typed: both
    // arms allocate len+1 (`dupeZ`/`realPathFileAlloc`), so the free must
    // see the `[:0]` length (a `[]u8` coercion under-frees by one and trips
    // the DebugAllocator).
    const src_abs: [:0]u8 = if (std.fs.path.isAbsolute(src_in)) try gpa.dupeZ(u8, src_in) else try std.Io.Dir.cwd().realPathFileAlloc(io, src_in, gpa);
    defer gpa.free(src_abs);
    var src = try std.Io.Dir.openDirAbsolute(io, src_abs, .{ .iterate = true });
    defer src.close(io);
    std.Io.Dir.cwd().createDirPath(io, dst_abs) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return error.Io;
    };
    var it = src.iterate();
    while (try it.next(io)) |e| {
        if (std.mem.eql(u8, e.name, "target")) continue;
        const s = try std.fs.path.join(gpa, &.{ src_abs, e.name });
        defer gpa.free(s);
        const d = try std.fs.path.join(gpa, &.{ dst_abs, e.name });
        defer gpa.free(d);
        switch (e.kind) {
            .directory => try copyTree(gpa, io, s, d),
            .file => {
                const bytes = try std.Io.Dir.cwd().readFileAlloc(io, s, gpa, .limited(1 << 28));
                defer gpa.free(bytes);
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = d, .data = bytes });
            },
            else => {},
        }
    }
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |i| {
        n += 1;
        rest = rest[i + needle.len ..];
    }
    return n;
}

/// Collects every `"message":"<...>"` string capture (backslash-escapes
/// skipped verbatim, so both sides' rustc escaping compares identically).
fn messageSet(gpa: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    const key = "\"message\":\"";
    while (std.mem.indexOf(u8, text[i..], key)) |rel| {
        var j = i + rel + key.len;
        const start = j;
        while (j < text.len and text[j] != '"') {
            if (text[j] == '\\' and j + 1 < text.len) j += 2 else j += 1;
        }
        try out.append(gpa, text[start..j]);
        i = j;
    }
    return out.toOwnedSlice(gpa);
}

fn sortedDupe(gpa: std.mem.Allocator, items: [][]const u8) ![][]const u8 {
    const cp = try gpa.dupe([]const u8, items);
    std.mem.sort([]const u8, cp, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return cp;
}

// Oracle tests inline their own spawn-capable `Threaded` io:
// `global_single_threaded` sets `.allocator = .failing`, so process spawn
// always returns OutOfMemory there.

test "unit plans match committed goldens" {
    const gpa = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const projects = [_][]const u8{ "basic-workspace", "feature-matrix", "lockfile-golden", "full-manifest" };
    for (projects) |proj| {
        const dir = try std.fmt.allocPrint(gpa, "validation/{s}", .{proj});
        defer gpa.free(dir);
        var ws = try workspace_mod.discover(gpa, io, dir, null);
        defer ws.deinit();
        var holder = try openScratchStore(io);
        defer holder.tmp.cleanup();
        defer holder.store.close(io);
        var tc = stubToolchain();
        var plan = buildPlan(gpa, io, &holder.store, &ws, &tc, testOptions(.build)) catch |e| {
            std.debug.print("plan failed for {s}: {t} {s}\n", .{ proj, e, planDiagnostic() orelse "" });
            return e;
        };
        defer plan.deinit();
        const dump = try dumpUnitPlan(gpa, &plan);
        defer gpa.free(dump);
        const gpath = try std.fmt.allocPrint(gpa, "validation/{s}/golden.units.json", .{proj});
        defer gpa.free(gpath);
        const want = std.Io.Dir.cwd().readFileAlloc(io, gpath, gpa, .limited(1 << 20)) catch |e| {
            if (e == error.FileNotFound) {
                std.debug.print("missing {s}; approve the dump above with: cp <dump> {s}\n", .{ gpath, gpath });
            }
            return e;
        };
        defer gpa.free(want);
        std.testing.expectEqualStrings(want, dump) catch |e| {
            std.debug.print("golden mismatch for {s}\n--- golden ---\n{s}\n--- fresh ---\n{s}\n", .{ proj, want, dump });
            return e;
        };
    }
}

// NOTE on limitation L2 (plan Q5): the M1 manifest surface drops
// example/test/bench sections before the driver ever sees them, so
// full-manifest plans its lib+bin units above (the driver's own
// `UnknownTarget` rejection, pinned by driver tests, remains the backstop
// if the manifest surface ever grows). The pipeline's target-kind gate
// ahead of `buildUnitGraph` names the member/target/kind loudly in that
// event.

test "pipeline compiles the workspace when oracle enabled" {
    if (!oracle_mod.oracleEnabled()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const stamp = nowMs(io);
    const dst = try std.fmt.allocPrint(gpa, "/tmp/rime-build-{d}", .{stamp});
    defer gpa.free(dst);
    defer std.Io.Dir.cwd().deleteTree(io, dst) catch {};
    try copyTree(gpa, io, "testdata/cargo/workspace", dst);
    var ws = try workspace_mod.discover(gpa, io, dst, null);
    defer ws.deinit();
    var holder = try openScratchStore(io);
    defer holder.tmp.cleanup();
    defer holder.store.close(io);
    var tc = try toolchain_mod.probeToolchain(gpa, io, null);
    defer tc.deinit(gpa);
    const cache_dir = try std.fmt.allocPrint(gpa, "{s}-cache", .{dst});
    defer gpa.free(cache_dir);
    std.Io.Dir.cwd().createDirPath(io, cache_dir) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return error.Io;
    };
    var stdout: std.Io.Writer.Allocating = try .initCapacity(gpa, 4096);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = try .initCapacity(gpa, 4096);
    defer stderr.deinit();
    var opts = testOptions(.build);
    opts.cache_dir = cache_dir;
    const code = try buildWorkspace(gpa, io, &holder.store, dst, &ws, &tc, opts, &stdout.writer, &stderr.writer);
    try std.testing.expectEqual(@as(u8, 0), code);
    // Both rlibs materialized under target/debug/deps/.
    const deps_dir = try std.fs.path.join(gpa, &.{ dst, "target", "debug", "deps" });
    defer gpa.free(deps_dir);
    var dd = try std.Io.Dir.openDirAbsolute(io, deps_dir, .{ .iterate = true });
    defer dd.close(io);
    var saw_a = false;
    var saw_b = false;
    var dit = dd.iterate();
    while (try dit.next(io)) |e| {
        if (std.mem.startsWith(u8, e.name, "liba-")) saw_a = true;
        if (std.mem.startsWith(u8, e.name, "libb-")) saw_b = true;
    }
    try std.testing.expect(saw_a and saw_b);
    // Complete view rows carry the toolchain tag (never null in M4).
    const meta = try std.fs.path.join(gpa, &.{ dst, "target", "debug", ".rime-view.json" });
    defer gpa.free(meta);
    const mtext = try std.Io.Dir.cwd().readFileAlloc(io, meta, gpa, .limited(1 << 20));
    defer gpa.free(mtext);
    try std.testing.expect(std.mem.indexOf(u8, mtext, "\"complete\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, mtext, "\"toolchain\":\"rustc ") != null);
    // last-build.json carries per-unit mtimes for the fast path.
    const last = try std.fs.path.join(gpa, &.{ dst, "target", "debug", "last-build.json" });
    defer gpa.free(last);
    const ltext = try std.Io.Dir.cwd().readFileAlloc(io, last, gpa, .limited(1 << 20));
    defer gpa.free(ltext);
    try std.testing.expect(std.mem.indexOf(u8, ltext, "output_mtime_ns") != null);
    // Human progress lines name both units.
    const err = try stderr.toOwnedSlice();
    defer gpa.free(err);
    try std.testing.expect(countOccurrences(err, "Compiling ") == 2);
}

test "check mode compiles rmeta-only when oracle enabled" {
    if (!oracle_mod.oracleEnabled()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const stamp = nowMs(io);
    const dst = try std.fmt.allocPrint(gpa, "/tmp/rime-check-{d}", .{stamp});
    defer gpa.free(dst);
    defer std.Io.Dir.cwd().deleteTree(io, dst) catch {};
    try copyTree(gpa, io, "testdata/cargo/workspace", dst);
    var ws = try workspace_mod.discover(gpa, io, dst, null);
    defer ws.deinit();
    var holder = try openScratchStore(io);
    defer holder.tmp.cleanup();
    defer holder.store.close(io);
    var tc = try toolchain_mod.probeToolchain(gpa, io, null);
    defer tc.deinit(gpa);
    const cache_dir = try std.fmt.allocPrint(gpa, "{s}-cache", .{dst});
    defer gpa.free(cache_dir);
    std.Io.Dir.cwd().createDirPath(io, cache_dir) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return error.Io;
    };
    var stdout: std.Io.Writer.Allocating = try .initCapacity(gpa, 4096);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = try .initCapacity(gpa, 4096);
    defer stderr.deinit();
    var opts = testOptions(.check);
    opts.cache_dir = cache_dir;
    const code = try buildWorkspace(gpa, io, &holder.store, dst, &ws, &tc, opts, &stdout.writer, &stderr.writer);
    try std.testing.expectEqual(@as(u8, 0), code);
    // rmeta only: no rlib, no linked outputs.
    const deps_dir = try std.fs.path.join(gpa, &.{ dst, "target", "debug", "deps" });
    defer gpa.free(deps_dir);
    var dd = try std.Io.Dir.openDirAbsolute(io, deps_dir, .{ .iterate = true });
    defer dd.close(io);
    var saw_rmeta = false;
    var dit = dd.iterate();
    while (try dit.next(io)) |e| {
        if (std.mem.endsWith(u8, e.name, ".rlib")) return error.TestUnexpectedResult;
        if (std.mem.endsWith(u8, e.name, ".rmeta")) saw_rmeta = true;
    }
    try std.testing.expect(saw_rmeta);
}

test "rime diagnostics match cargo on the path-only fixture when oracle enabled" {
    // Task 12(b): same sources, same rustc, same /tmp root on both sides
    // (paths are trivially identical — no normalization needed). Compares
    // diagnostic MESSAGE sets (order-insensitive per the plan) plus
    // artifact counts.
    if (!oracle_mod.oracleEnabled()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const stamp = nowMs(io);
    const dst = try std.fmt.allocPrint(gpa, "/tmp/rime-diag-{d}", .{stamp});
    defer gpa.free(dst);
    defer std.Io.Dir.cwd().deleteTree(io, dst) catch {};
    try copyTree(gpa, io, "testdata/cargo/workspace", dst);
    var ws = try workspace_mod.discover(gpa, io, dst, null);
    defer ws.deinit();
    var holder = try openScratchStore(io);
    defer holder.tmp.cleanup();
    defer holder.store.close(io);
    var tc = try toolchain_mod.probeToolchain(gpa, io, null);
    defer tc.deinit(gpa);
    const cache_dir = try std.fmt.allocPrint(gpa, "{s}-cache", .{dst});
    defer gpa.free(cache_dir);
    std.Io.Dir.cwd().createDirPath(io, cache_dir) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return error.Io;
    };
    var stdout: std.Io.Writer.Allocating = try .initCapacity(gpa, 8192);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = try .initCapacity(gpa, 8192);
    defer stderr.deinit();
    var opts = testOptions(.build);
    opts.cache_dir = cache_dir;
    opts.message_format_json = true;
    const code = try buildWorkspace(gpa, io, &holder.store, dst, &ws, &tc, opts, &stdout.writer, &stderr.writer);
    try std.testing.expectEqual(@as(u8, 0), code);
    const rime_out = try stdout.toOwnedSlice();
    defer gpa.free(rime_out);
    const timeout_bin = try toolchain_mod.resolveBinPath(gpa, io, "timeout");
    defer if (timeout_bin) |b| gpa.free(b);
    const cargo_bin = try toolchain_mod.resolveBinPath(gpa, io, "cargo");
    defer if (cargo_bin) |b| gpa.free(b);
    if (timeout_bin == null or cargo_bin == null) return error.SkipZigTest;
    const res = try oracle_mod.runCapture(gpa, io, &.{ timeout_bin orelse unreachable, "300", cargo_bin orelse unreachable, "build", "--offline", "--message-format=json" }, dst);
    defer gpa.free(res.out);
    defer gpa.free(res.err);
    try std.testing.expectEqual(@as(u8, 0), res.exited);
    const rime_msgs = try messageSet(gpa, rime_out);
    defer gpa.free(rime_msgs);
    const cargo_msgs = try messageSet(gpa, res.out);
    defer gpa.free(cargo_msgs);
    const rsorted = try sortedDupe(gpa, rime_msgs);
    defer gpa.free(rsorted);
    const csorted = try sortedDupe(gpa, cargo_msgs);
    defer gpa.free(csorted);
    try std.testing.expectEqual(csorted.len, rsorted.len);
    for (rsorted, csorted) |r, c| try std.testing.expectEqualStrings(c, r);
    // One compiler-artifact per unit on both sides (filenames differ —
    // rime vs cargo metadata — so only counts compare).
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(rime_out, "\"reason\":\"compiler-artifact\""));
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(res.out, "\"reason\":\"compiler-artifact\""));
}

test "committed goldens match cargo metadata when oracle enabled" {
    // Task 12(c) oracle self-check: the committed golden.units.json rows
    // reproduce what cargo itself reports (re-pin goldens, not rime, on
    // upstream drift). Read-only over validation/ (metadata writes nothing).
    if (!oracle_mod.oracleEnabled()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const projects = [_][]const u8{ "basic-workspace", "feature-matrix", "lockfile-golden" };
    const MetaTarget = struct { name: []const u8, kind: []const []const u8 };
    const MetaPkg = struct { name: []const u8, version: []const u8, targets: []const MetaTarget };
    const MetaRoot = struct { packages: []const MetaPkg };
    const GoldenRow = struct {
        package: []const u8,
        version: []const u8,
        target: []const u8,
        kind: []const u8,
        edition: []const u8,
        features: []const []const u8,
        profile: []const u8,
        triple: []const u8,
        deps: []const []const u8,
    };
    for (projects) |proj| {
        const dir = try std.fmt.allocPrint(gpa, "validation/{s}", .{proj});
        defer gpa.free(dir);
        const manifest = try std.fmt.allocPrint(gpa, "validation/{s}/Cargo.toml", .{proj});
        defer gpa.free(manifest);
        const cargo_bin = try toolchain_mod.resolveBinPath(gpa, io, "cargo");
        defer if (cargo_bin) |b| gpa.free(b);
        const timeout_bin = try toolchain_mod.resolveBinPath(gpa, io, "timeout");
        defer if (timeout_bin) |b| gpa.free(b);
        if (cargo_bin == null or timeout_bin == null) return error.SkipZigTest;
        const res = try oracle_mod.runCapture(gpa, io, &.{ timeout_bin orelse unreachable, "300", cargo_bin orelse unreachable, "metadata", "--format-version", "1", "--no-deps", "--offline", "--manifest-path", manifest }, dir);
        defer gpa.free(res.out);
        defer gpa.free(res.err);
        if (res.exited != 0) {
            std.debug.print("cargo metadata failed for {s}: {s}\n", .{ proj, res.err });
            return error.TestUnexpectedResult;
        }
        const parsed = try std.json.parseFromSlice(MetaRoot, gpa, res.out, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
        defer parsed.deinit();
        const gpath = try std.fmt.allocPrint(gpa, "validation/{s}/golden.units.json", .{proj});
        defer gpa.free(gpath);
        const gtext = try std.Io.Dir.cwd().readFileAlloc(io, gpath, gpa, .limited(1 << 20));
        defer gpa.free(gtext);
        const grows = try std.json.parseFromSlice([]GoldenRow, gpa, gtext, .{ .allocate = .alloc_always });
        defer grows.deinit();
        for (grows.value) |row| {
            var found = false;
            for (parsed.value.packages) |pkg| {
                if (!std.mem.eql(u8, pkg.name, row.package)) continue;
                if (!std.mem.eql(u8, pkg.version, row.version)) continue;
                for (pkg.targets) |t| {
                    if (!std.mem.eql(u8, t.name, row.target)) continue;
                    for (t.kind) |k| {
                        if (std.mem.eql(u8, k, row.kind)) found = true;
                    }
                }
            }
            if (!found) {
                std.debug.print("golden row not in cargo metadata for {s}: {s} {s} {s}\n", .{ proj, row.package, row.target, row.kind });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "diagnostic streams match committed diag goldens" {
    // Registry projects cannot compile in M4: the committed
    // golden.diag-dev.json pins the (empty) diagnostic stream plus the
    // loud NeedFetch boundary. Always runs (no spawn, stub toolchain).
    const gpa = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const projects = [_][]const u8{ "basic-workspace", "feature-matrix", "lockfile-golden", "full-manifest" };
    for (projects) |proj| {
        const dir = try std.fmt.allocPrint(gpa, "validation/{s}", .{proj});
        defer gpa.free(dir);
        var ws = try workspace_mod.discover(gpa, io, dir, null);
        defer ws.deinit();
        var holder = try openScratchStore(io);
        defer holder.tmp.cleanup();
        defer holder.store.close(io);
        var tc = stubToolchain();
        var stdout: std.Io.Writer.Allocating = try .initCapacity(gpa, 1024);
        defer stdout.deinit();
        var stderr: std.Io.Writer.Allocating = try .initCapacity(gpa, 1024);
        defer stderr.deinit();
        var opts = testOptions(.build);
        opts.message_format_json = true;
        const res = buildWorkspace(gpa, io, &holder.store, dir, &ws, &tc, opts, &stdout.writer, &stderr.writer);
        // Every registry project fails at the execute gate (full-manifest
        // plans its lib+bin units fine — the M1 surface drops the deferred
        // target kinds — then blocks on its registry deps like the rest).
        // Loud NeedFetch, never silent.
        try std.testing.expectError(PipelineError.NeedFetch, res);
        try std.testing.expect(std.mem.indexOf(u8, planDiagnostic() orelse "", "fetch") != null);
        const got = try stdout.toOwnedSlice();
        defer gpa.free(got);
        // Golden compare runs the committed bytes through the same
        // normalizer (wiring exercise; boundary streams carry no paths).
        var norm: std.Io.Writer.Allocating = try .initCapacity(gpa, 1024);
        defer norm.deinit();
        var lines = std.mem.splitScalar(u8, got, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const n = try compile_mod.normalizeDiagLine(gpa, line, dir);
            defer gpa.free(n);
            try norm.writer.writeAll(n);
            try norm.writer.writeAll("\n");
        }
        const ngot = try norm.toOwnedSlice();
        defer gpa.free(ngot);
        const gpath = try std.fmt.allocPrint(gpa, "validation/{s}/golden.diag-dev.json", .{proj});
        defer gpa.free(gpath);
        const want = std.Io.Dir.cwd().readFileAlloc(io, gpath, gpa, .limited(1 << 20)) catch |e| {
            if (e == error.FileNotFound) {
                std.debug.print("missing {s}; boundary stream is currently {d} bytes\n", .{ gpath, ngot.len });
            }
            return e;
        };
        defer gpa.free(want);
        try std.testing.expectEqualStrings(want, ngot);
    }
}

test "edit one file recompiles one crate when oracle enabled" {
    // Task 13 incremental-reuse: touch ONE crate (content change) →
    // exactly that crate plus its reverse-deps recompile; a no-change
    // rebuild compiles nothing.
    if (!oracle_mod.oracleEnabled()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const stamp = nowMs(io);
    const dst = try std.fmt.allocPrint(gpa, "/tmp/rime-incr-{d}", .{stamp});
    defer gpa.free(dst);
    defer std.Io.Dir.cwd().deleteTree(io, dst) catch {};
    try copyTree(gpa, io, "testdata/cargo/workspace", dst);
    var holder = try openScratchStore(io);
    defer holder.tmp.cleanup();
    defer holder.store.close(io);
    var tc = try toolchain_mod.probeToolchain(gpa, io, null);
    defer tc.deinit(gpa);
    const cache_dir = try std.fmt.allocPrint(gpa, "{s}-cache", .{dst});
    defer gpa.free(cache_dir);
    std.Io.Dir.cwd().createDirPath(io, cache_dir) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return error.Io;
    };
    var opts = testOptions(.build);
    opts.cache_dir = cache_dir;

    var n1: usize = 0;
    {
        var ws = try workspace_mod.discover(gpa, io, dst, null);
        defer ws.deinit();
        var stdout: std.Io.Writer.Allocating = try .initCapacity(gpa, 4096);
        defer stdout.deinit();
        var stderr: std.Io.Writer.Allocating = try .initCapacity(gpa, 4096);
        defer stderr.deinit();
        try std.testing.expectEqual(@as(u8, 0), try buildWorkspace(gpa, io, &holder.store, dst, &ws, &tc, opts, &stdout.writer, &stderr.writer));
        const err = try stderr.toOwnedSlice();
        defer gpa.free(err);
        n1 = countOccurrences(err, "Compiling ");
    }
    try std.testing.expectEqual(@as(usize, 2), n1);

    // Touch ONE file in ONE crate (content change, mtime change).
    {
        const fpath = try std.fs.path.join(gpa, &.{ dst, "crates", "b", "src", "lib.rs" });
        defer gpa.free(fpath);
        const old = try std.Io.Dir.cwd().readFileAlloc(io, fpath, gpa, .limited(1 << 20));
        defer gpa.free(old);
        const new = try std.fmt.allocPrint(gpa, "{s}\n// touch-one\n", .{old});
        defer gpa.free(new);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = fpath, .data = new });
    }

    {
        var ws = try workspace_mod.discover(gpa, io, dst, null);
        defer ws.deinit();
        var stdout: std.Io.Writer.Allocating = try .initCapacity(gpa, 4096);
        defer stdout.deinit();
        var stderr: std.Io.Writer.Allocating = try .initCapacity(gpa, 4096);
        defer stderr.deinit();
        try std.testing.expectEqual(@as(u8, 0), try buildWorkspace(gpa, io, &holder.store, dst, &ws, &tc, opts, &stdout.writer, &stderr.writer));
        const err = try stderr.toOwnedSlice();
        defer gpa.free(err);
        // Exactly the touched crate plus its reverse-dep recompile, deps-first.
        try std.testing.expectEqual(@as(usize, 2), countOccurrences(err, "Compiling "));
        const ib = std.mem.indexOf(u8, err, "Compiling b ");
        const ia = std.mem.indexOf(u8, err, "Compiling a ");
        try std.testing.expect(ib != null and ia != null and ib.? < ia.?);
    }

    // No-change rebuild: full no-op hit (zero spawns either path).
    {
        var ws = try workspace_mod.discover(gpa, io, dst, null);
        defer ws.deinit();
        var stdout: std.Io.Writer.Allocating = try .initCapacity(gpa, 4096);
        defer stdout.deinit();
        var stderr: std.Io.Writer.Allocating = try .initCapacity(gpa, 4096);
        defer stderr.deinit();
        try std.testing.expectEqual(@as(u8, 0), try buildWorkspace(gpa, io, &holder.store, dst, &ws, &tc, opts, &stdout.writer, &stderr.writer));
        const err = try stderr.toOwnedSlice();
        defer gpa.free(err);
        try std.testing.expectEqual(@as(usize, 0), countOccurrences(err, "Compiling "));
        try std.testing.expectEqual(@as(usize, 2), countOccurrences(err, "Fresh "));
    }
}

test "cross-project copies do not share action keys" {
    // Task 13 cross-project, hermetic mechanism proof: two same-content
    // checkouts at different absolute paths produce DIFFERENT keys (the
    // crate-root operand stays verbatim per the Task-5 table), so the
    // global store cannot serve across them for path deps. Registry deps
    // (content-addressed by version) are the sharing vehicle — and those
    // raise the loud NeedFetch below until M2 lands.
    const gpa = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const stamp = nowMs(io);
    const dst_a = try std.fmt.allocPrint(gpa, "/tmp/rime-xa-{d}", .{stamp});
    defer gpa.free(dst_a);
    defer std.Io.Dir.cwd().deleteTree(io, dst_a) catch {};
    const dst_b = try std.fmt.allocPrint(gpa, "/tmp/rime-xb-{d}", .{stamp});
    defer gpa.free(dst_b);
    defer std.Io.Dir.cwd().deleteTree(io, dst_b) catch {};
    try copyTree(gpa, io, "testdata/cargo/workspace", dst_a);
    try copyTree(gpa, io, "testdata/cargo/workspace", dst_b);
    var ws_a = try workspace_mod.discover(gpa, io, dst_a, null);
    defer ws_a.deinit();
    var ws_b = try workspace_mod.discover(gpa, io, dst_b, null);
    defer ws_b.deinit();
    var holder = try openScratchStore(io);
    defer holder.tmp.cleanup();
    defer holder.store.close(io);
    var tc = stubToolchain();
    var plan_a = try buildPlan(gpa, io, &holder.store, &ws_a, &tc, testOptions(.build));
    defer plan_a.deinit();
    var plan_b = try buildPlan(gpa, io, &holder.store, &ws_b, &tc, testOptions(.build));
    defer plan_b.deinit();
    try std.testing.expectEqual(plan_a.order.len, plan_b.order.len);
    for (plan_a.order, plan_b.order) |ia, ib| {
        try std.testing.expectEqualStrings(plan_a.graph.units[ia].pkg_name, plan_b.graph.units[ib].pkg_name);
        try std.testing.expect(!std.mem.eql(u8, &plan_a.units[ia].action_key.bytes, &plan_b.units[ib].action_key.bytes));
    }
}

test "registry dependencies fail loud naming fetch" {
    // Task 13 cross-project boundary, always runs: a registry dep cannot
    // even plan fresh (no lock pins, no network client) — the NeedFetch
    // diagnostic names the crate and the M2 gap. Stub toolchain, no spawn.
    const gpa = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const stamp = nowMs(io);
    const dst = try std.fmt.allocPrint(gpa, "/tmp/rime-needfetch-{d}", .{stamp});
    defer gpa.free(dst);
    defer std.Io.Dir.cwd().deleteTree(io, dst) catch {};
    std.Io.Dir.cwd().createDirPath(io, dst) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return error.Io;
    };
    const manifest_path = try std.fs.path.join(gpa, &.{ dst, "Cargo.toml" });
    defer gpa.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = manifest_path,
        .data = "[package]\nname = \"needs-serde\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n[dependencies]\nserde = \"1\"\n\n[lib]\nname = \"needs_serde\"\npath = \"src/lib.rs\"\n",
    });
    const src_dir = try std.fs.path.join(gpa, &.{ dst, "src" });
    defer gpa.free(src_dir);
    std.Io.Dir.cwd().createDirPath(io, src_dir) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return error.Io;
    };
    const lib_path = try std.fs.path.join(gpa, &.{ dst, "src", "lib.rs" });
    defer gpa.free(lib_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = lib_path, .data = "pub fn f() {}\n" });
    var ws = try workspace_mod.discover(gpa, io, dst, null);
    defer ws.deinit();
    var holder = try openScratchStore(io);
    defer holder.tmp.cleanup();
    defer holder.store.close(io);
    var tc = stubToolchain();
    var stdout: std.Io.Writer.Allocating = try .initCapacity(gpa, 256);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = try .initCapacity(gpa, 256);
    defer stderr.deinit();
    const res = buildWorkspace(gpa, io, &holder.store, dst, &ws, &tc, testOptions(.build), &stdout.writer, &stderr.writer);
    try std.testing.expectError(PipelineError.NeedFetch, res);
    try std.testing.expect(std.mem.indexOf(u8, planDiagnostic() orelse "", "serde") != null);
    try std.testing.expect(std.mem.indexOf(u8, planDiagnostic() orelse "", "fetch") != null);
}

test "feature changes recompile when oracle enabled" {
    // Task 13 flag-change: same project, `--features` changed → different
    // feature sets in the key → all affected units recompile.
    if (!oracle_mod.oracleEnabled()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const stamp = nowMs(io);
    const dst = try std.fmt.allocPrint(gpa, "/tmp/rime-feat-{d}", .{stamp});
    defer gpa.free(dst);
    defer std.Io.Dir.cwd().deleteTree(io, dst) catch {};
    std.Io.Dir.cwd().createDirPath(io, dst) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return error.Io;
    };
    const manifest_path = try std.fs.path.join(gpa, &.{ dst, "Cargo.toml" });
    defer gpa.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = manifest_path,
        .data = "[package]\nname = \"feat\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n[features]\ndefault = []\njson = []\n\n[lib]\nname = \"feat\"\npath = \"src/lib.rs\"\n",
    });
    const src_dir = try std.fs.path.join(gpa, &.{ dst, "src" });
    defer gpa.free(src_dir);
    std.Io.Dir.cwd().createDirPath(io, src_dir) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return error.Io;
    };
    const lib_path = try std.fs.path.join(gpa, &.{ dst, "src", "lib.rs" });
    defer gpa.free(lib_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = lib_path, .data = "pub fn f() {}\n" });
    var holder = try openScratchStore(io);
    defer holder.tmp.cleanup();
    defer holder.store.close(io);
    var tc = try toolchain_mod.probeToolchain(gpa, io, null);
    defer tc.deinit(gpa);
    const cache_dir = try std.fmt.allocPrint(gpa, "{s}-cache", .{dst});
    defer gpa.free(cache_dir);
    std.Io.Dir.cwd().createDirPath(io, cache_dir) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return error.Io;
    };
    var opts = testOptions(.build);
    opts.cache_dir = cache_dir;
    {
        var ws = try workspace_mod.discover(gpa, io, dst, null);
        defer ws.deinit();
        var stdout: std.Io.Writer.Allocating = try .initCapacity(gpa, 1024);
        defer stdout.deinit();
        var stderr: std.Io.Writer.Allocating = try .initCapacity(gpa, 1024);
        defer stderr.deinit();
        try std.testing.expectEqual(@as(u8, 0), try buildWorkspace(gpa, io, &holder.store, dst, &ws, &tc, opts, &stdout.writer, &stderr.writer));
        const err = try stderr.toOwnedSlice();
        defer gpa.free(err);
        try std.testing.expectEqual(@as(usize, 1), countOccurrences(err, "Compiling "));
    }
    {
        var ws = try workspace_mod.discover(gpa, io, dst, null);
        defer ws.deinit();
        var stdout: std.Io.Writer.Allocating = try .initCapacity(gpa, 1024);
        defer stdout.deinit();
        var stderr: std.Io.Writer.Allocating = try .initCapacity(gpa, 1024);
        defer stderr.deinit();
        const feats = [_][]const u8{"json"};
        opts.features_cli = &feats;
        try std.testing.expectEqual(@as(u8, 0), try buildWorkspace(gpa, io, &holder.store, dst, &ws, &tc, opts, &stdout.writer, &stderr.writer));
        const err = try stderr.toOwnedSlice();
        defer gpa.free(err);
        // Different feature set → different key → miss → recompile.
        try std.testing.expectEqual(@as(usize, 1), countOccurrences(err, "Compiling "));
    }
}
