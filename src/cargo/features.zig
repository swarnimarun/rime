//! Feature unification v1 + v2/v3 decoupled namespaces (M3 Tasks 5 and 6).
//!
//! Reference pins (normative):
//! - `core/resolver/features.rs` module docs (two-pass design: the main
//!   resolver still does v1-style feature unification during resolution to
//!   decide which optional deps exist, then the new feature resolver runs as
//!   a second pass that can only NARROW what the first pass selected).
//! - `core/resolver/features.rs::FeatureOpts::new_behavior` (the v1/v2 flag
//!   table, copied verbatim into `FeatureOpts.forBehavior`).
//! - `core/resolver/features.rs::FeaturesFor::{from_for_host, apply_opts}`
//!   (v1 collapses every namespace via `apply_opts` into `NormalOrDev`).
//! - `core/summary.rs` feature-map building (an optional dependency
//!   implicitly creates a same-named feature unless `dep:` syntax is used).
//! - `core/features.rs` validation (an unknown feature is a hard error
//!   naming the feature + package).
//! - `core/resolver/types.rs::ResolveBehavior::from_manifest` (`"1"|"2"|"3"`
//!   mapping + the invalid-`resolver` error text, reused by
//!   `Behavior.fromManifest`).
//!
//! Resolver interplay: `resolve.zig`'s `DepEdge.optional` edges are INVISIBLE
//! to resolution (never enqueued). The M3 loop is resolve (all-features
//! assumption) -> `unifyV1`/`unify` -> `pruneOptional` -> done, since version
//! selection never depends on features for correctness (`features.rs` docs:
//! "second pass can only narrow").

const std = @import("std");
const resolve = @import("resolve.zig");

pub const UnifiedError = error{ UnknownFeature, InvalidBehavior, OutOfMemory };
const OOM = UnifiedError.OutOfMemory;

pub const FeatureValue = union(enum) {
    dep: []const u8, // "dep-name" (enables optional dep's implicit feature)
    dep_named: []const u8, // "dep:dep-name" (enables dep WITHOUT its implicit feature)
    dep_feature: struct { dep: []const u8, feat: []const u8 }, // "dep-name/feat"
    weak_feature: struct { dep: []const u8, feat: []const u8 }, // "dep-name?/feat" (only if dep enabled)
    own: []const u8, // enables another feature of the same package
};

pub const FeatureRule = struct { feature: []const u8, values: []const FeatureValue };

pub const FeatureMap = struct {
    default: []const []const u8,
    optional_deps: []const []const u8, // implicit same-name features (non-`dep:` optionals)
    rules: []const FeatureRule,
};

pub const RootReq = struct { package: []const u8, features: []const []const u8, all_features: bool, no_default: bool };

// v1 test tables carry the per-edge default-features choice in this form
// (`ops/resolve.rs` edge data); the production carrier is Task-7
// `DepEdgeFull.uses_default`/`dep_features`. `unifyV1` has no edge inputs, so
// it always applies an enabled optional dep's defaults (uses_default=true).
pub const DepFeatures = struct { features: []const []const u8, uses_default: bool };

pub const Unified = struct {
    gpa: std.mem.Allocator,
    features: std.StringHashMap(std.StringHashMap(void)), // pkg name → enabled feature set
    enabled_deps: std.StringHashMap(std.StringHashMap(void)), // pkg name → enabled optional-dep names
    // NOTE: `enabled_deps[p]` additionally contains every NORMAL-dep target
    // of `p` (edges whose dep name is not in `p`'s `optional_deps`). The
    // resolver graph carries no optional flag on `ResolvedRef`, so
    // `pruneOptional` cannot tell disabled-optionals from normal edges
    // without this. Documented, not accidental.
    pub fn deinit(self: *Unified) void {
        var it = self.features.iterator();
        while (it.next()) |kv| kv.value_ptr.deinit();
        self.features.deinit();
        var it2 = self.enabled_deps.iterator();
        while (it2.next()) |kv| kv.value_ptr.deinit();
        self.enabled_deps.deinit();
    }
    pub fn isEnabled(self: *const Unified, pkg: []const u8, feat: []const u8) bool {
        const set = self.features.get(pkg) orelse return false;
        return set.contains(feat);
    }
};

fn featSet(gpa: std.mem.Allocator, m: *std.StringHashMap(std.StringHashMap(void)), pkg: []const u8) UnifiedError!*std.StringHashMap(void) {
    const gop = m.getOrPut(pkg) catch return OOM;
    if (!gop.found_existing) gop.value_ptr.* = std.StringHashMap(void).init(gpa);
    return gop.value_ptr;
}

const V1 = struct {
    gpa: std.mem.Allocator,
    maps: *const std.StringHashMap(FeatureMap),
    features: std.StringHashMap(std.StringHashMap(void)),
    enabled_deps: std.StringHashMap(std.StringHashMap(void)),

    fn request(self: *V1, pkg: []const u8, feat: []const u8, validated: bool) UnifiedError!void {
        // Validation rule (pinned by the Task 5 tests): root seeds and
        // same-package (`own`/`dep`) references must name a rule, `default`,
        // or an implicit optional-dep feature, else `UnknownFeature`.
        // Cross-package `dep-name/feat` (and `dep-name?/feat`) requests and
        // `default`-list expansion intentionally SKIP validation: the Task 5
        // fixtures enable `feat-a`/`feat-b` on a map with no such rules, and
        // cargo reports those as build-plan diagnostics (Task 9), not as
        // unification failures.
        if (validated) {
            var ok = std.mem.eql(u8, feat, "default");
            if (!ok) {
                if (self.maps.get(pkg)) |mm| {
                    for (mm.rules) |r| {
                        if (std.mem.eql(u8, r.feature, feat)) {
                            ok = true;
                            break;
                        }
                    }
                    if (!ok) for (mm.optional_deps) |o| {
                        if (std.mem.eql(u8, o, feat)) {
                            ok = true;
                            break;
                        }
                    };
                }
            }
            if (!ok) return UnifiedError.UnknownFeature;
        }
        const set = try featSet(self.gpa, &self.features, pkg);
        if (set.contains(feat)) return;
        set.put(feat, {}) catch return OOM;
        // Implicit same-name feature: enabling it enables the optional dep.
        if (self.maps.get(pkg)) |mm| {
            for (mm.optional_deps) |o| {
                if (std.mem.eql(u8, o, feat)) {
                    try self.enableDep(pkg, o);
                    break;
                }
            }
        }
    }

    fn enableDep(self: *V1, holder: []const u8, dep: []const u8) UnifiedError!void {
        const set = try featSet(self.gpa, &self.enabled_deps, holder);
        // Record even if already present: defaults were pulled on first add.
        if (!set.contains(dep)) {
            set.put(dep, {}) catch return OOM;
            // Enabling an optional dep pulls that dep's `default` features
            // (dep-level `default-features = false` arrives via Task 7's edge
            // data; without edges v1 assumes uses_default=true).
            try self.request(dep, "default", false);
        }
    }

    fn applyValue(self: *V1, pkg: []const u8, v: FeatureValue) UnifiedError!bool {
        const before = self.count();
        switch (v) {
            .own => |f| try self.request(pkg, f, true),
            .dep => |n| try self.request(pkg, n, true),
            .dep_named => |n| try self.enableDep(pkg, n),
            .dep_feature => |df| {
                try self.enableDep(pkg, df.dep);
                try self.request(df.dep, df.feat, false);
            },
            .weak_feature => |wf| {
                // Weak: request `feat` ONLY if the dep is already enabled;
                // NEVER enables the dep itself. Later-enabling is handled by
                // the outer repeat-until-stable scan.
                const set = self.enabled_deps.get(pkg);
                if (set != null and set.?.contains(wf.dep)) {
                    try self.request(wf.dep, wf.feat, false);
                }
            },
        }
        return self.count() != before;
    }

    fn count(self: *const V1) usize {
        var n: usize = 0;
        var it = self.features.iterator();
        while (it.next()) |kv| n += kv.value_ptr.count();
        var it2 = self.enabled_deps.iterator();
        while (it2.next()) |kv| n += kv.value_ptr.count();
        return n;
    }
};

/// v1 unification (`features.rs` two-pass, first pass): a single global
/// namespace per package — ALL requests for `(pkg)` merge regardless of
/// which parent, dep-kind, or target requested them. Fixpoint by
/// repeat-full-scan until stable (re-scanning makes weak `dep?/feat` values
/// apply when their dep flips on later).
pub fn unifyV1(
    gpa: std.mem.Allocator,
    graph: *const resolve.ResolveGraph,
    maps: *const std.StringHashMap(FeatureMap),
    roots: []const RootReq,
) UnifiedError!Unified {
    var st = V1{
        .gpa = gpa,
        .maps = maps,
        .features = std.StringHashMap(std.StringHashMap(void)).init(gpa),
        .enabled_deps = std.StringHashMap(std.StringHashMap(void)).init(gpa),
    };
    errdefer {
        var it = st.features.iterator();
        while (it.next()) |kv| kv.value_ptr.deinit();
        st.features.deinit();
        var it2 = st.enabled_deps.iterator();
        while (it2.next()) |kv| kv.value_ptr.deinit();
        st.enabled_deps.deinit();
    }

    // Normal (non-optional) graph edges are pre-recorded as enabled so
    // `pruneOptional` keeps them without needing the feature maps. An edge
    // P→D is normal iff D is not in P's `optional_deps`.
    for (graph.nodes) |n| {
        const mm = maps.get(n.name);
        for (n.deps) |d| {
            var is_opt = false;
            if (mm) |m| {
                for (m.optional_deps) |o| {
                    if (std.mem.eql(u8, o, d.name)) {
                        is_opt = true;
                        break;
                    }
                }
            }
            if (!is_opt) {
                const set = try featSet(gpa, &st.enabled_deps, n.name);
                set.put(d.name, {}) catch return OOM;
            }
        }
    }

    for (roots) |r| {
        if (r.all_features) {
            if (maps.get(r.package)) |m| {
                for (m.rules) |rule| try st.request(r.package, rule.feature, false);
                try st.request(r.package, "default", false);
                for (m.optional_deps) |o| try st.request(r.package, o, false);
            }
            // A package without a feature table + --all-features: nothing to
            // enable, not an error.
        } else if (!r.no_default) {
            try st.request(r.package, "default", false);
        }
        for (r.features) |f| try st.request(r.package, f, true);
    }

    var changed = true;
    while (changed) {
        changed = false;
        // Snapshot the (pkg, feat) pairs: `request` grows the maps, which
        // may rehash during iteration.
        var work: std.ArrayList(struct { pkg: []const u8, feat: []const u8 }) = .empty;
        defer work.deinit(gpa);
        var it = st.features.iterator();
        while (it.next()) |kv| {
            var jt = kv.value_ptr.iterator();
            while (jt.next()) |f| {
                work.append(gpa, .{ .pkg = kv.key_ptr.*, .feat = f.key_ptr.* }) catch return OOM;
            }
        }
        for (work.items) |w| {
            if (std.mem.eql(u8, w.feat, "default")) {
                if (maps.get(w.pkg)) |m| {
                    for (m.default) |d| {
                        const before = st.count();
                        try st.request(w.pkg, d, false);
                        if (st.count() != before) changed = true;
                    }
                }
                continue;
            }
            const mm = maps.get(w.pkg) orelse continue;
            for (mm.rules) |rule| {
                if (!std.mem.eql(u8, rule.feature, w.feat)) continue;
                for (rule.values) |v| {
                    if (try st.applyValue(w.pkg, v)) changed = true;
                }
                break;
            }
            // Implicit optional features carry no rule; the dep was enabled
            // at request time. Unknown names already errored at request.
        }
    }

    return Unified{ .gpa = gpa, .features = st.features, .enabled_deps = st.enabled_deps };
}

fn sourceEql(a: @import("sources.zig").SourceId, b: @import("sources.zig").SourceId) bool {
    switch (a) {
        .path => |x| switch (b) {
            .path => |y| return std.mem.eql(u8, x, y),
            else => return false,
        },
        .registry => |x| switch (b) {
            .registry => |y| return std.mem.eql(u8, x, y),
            else => return false,
        },
        .git => |x| switch (b) {
            .git => |y| {
                if (!std.mem.eql(u8, x.url, y.url)) return false;
                const xp = x.precise;
                const yp = y.precise;
                if (xp == null and yp == null) {} else if (xp != null and yp != null) {
                    if (!std.mem.eql(u8, &xp.?, &yp.?)) return false;
                } else return false;
                switch (x.ref) {
                    .branch => |r| switch (y.ref) {
                        .branch => |s| return std.mem.eql(u8, r, s),
                        else => return false,
                    },
                    .tag => |r| switch (y.ref) {
                        .tag => |s| return std.mem.eql(u8, r, s),
                        else => return false,
                    },
                    .rev => |r| switch (y.ref) {
                        .rev => |s| return std.mem.eql(u8, r, s),
                        else => return false,
                    },
                    .default_branch => return y.ref == .default_branch,
                }
            },
            else => return false,
        },
    }
}

/// Drop disabled-optional nodes + orphaned subtrees. An edge P→D survives iff
/// `D ∈ unified.enabled_deps[P]` (normal edges were pre-recorded there by
/// `unifyV1`). Nodes surviving = reachable from indegree-0 nodes (workspace
/// roots) via surviving edges, in original graph order. Caller frees.
pub fn pruneOptional(
    gpa: std.mem.Allocator,
    graph: *const resolve.ResolveGraph,
    unified: *const Unified,
) UnifiedError![]const resolve.ResolvedNode {
    const n = graph.nodes.len;
    // Edge survival per (parent idx, ref idx) is evaluated on demand below.
    var keep = gpa.alloc(bool, n) catch return OOM;
    defer gpa.free(keep);
    @memset(keep, false);

    // Roots = indegree-0 nodes (resolve graphs are acyclic; workspace members
    // have no incoming edges).
    var indeg = gpa.alloc(usize, n) catch return OOM;
    defer gpa.free(indeg);
    @memset(indeg, 0);
    for (graph.nodes) |pn| {
        for (pn.deps) |d| {
            for (graph.nodes, 0..) |cn, ci| {
                if (std.mem.eql(u8, cn.name, d.name) and cn.version.eql(d.version) and sourceEql(cn.source, d.source)) {
                    indeg[ci] += 1;
                    break;
                }
            }
        }
    }
    // Iterative BFS from roots over surviving edges.
    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(gpa);
    for (graph.nodes, 0..) |_, i| {
        if (indeg[i] == 0) {
            keep[i] = true;
            stack.append(gpa, i) catch return OOM;
        }
    }
    // A graph where every node has indegree > 0 cannot arise from the
    // resolver (roots are indegree-0); keep-all would silently mask it, so
    // fall back to keeping roots only (none) rather than the whole graph.
    while (stack.items.len > 0) {
        const pi = stack.pop().?;
        const pn = graph.nodes[pi];
        const allowed = unified.enabled_deps.get(pn.name);
        for (pn.deps) |d| {
            if (allowed == null or !allowed.?.contains(d.name)) continue;
            for (graph.nodes, 0..) |cn, ci| {
                if (keep[ci]) break;
                if (std.mem.eql(u8, cn.name, d.name) and cn.version.eql(d.version) and sourceEql(cn.source, d.source)) {
                    keep[ci] = true;
                    stack.append(gpa, ci) catch return OOM;
                    break;
                }
            }
        }
    }
    var out: std.ArrayList(resolve.ResolvedNode) = .empty;
    errdefer out.deinit(gpa);
    for (graph.nodes, 0..) |node, i| {
        if (keep[i]) out.append(gpa, node) catch return OOM;
    }
    return out.toOwnedSlice(gpa) catch return OOM;
}

// --- Task 6: v2/v3 decoupled namespaces ---

pub const Behavior = enum {
    v1,
    v2,
    v3, // == v2 for features (v3 only changes version preferences)

    /// `types.rs::ResolveBehavior::from_manifest`: `"1"|"2"|"3"` mapping.
    /// Any other value errors with cargo's message.
    pub fn fromManifest(text: []const u8) UnifiedError!Behavior {
        if (std.mem.eql(u8, text, "1")) return .v1;
        if (std.mem.eql(u8, text, "2")) return .v2;
        if (std.mem.eql(u8, text, "3")) return .v3;
        return UnifiedError.InvalidBehavior;
    }
};

/// `features.rs::FeatureOpts::new_behavior`, exact flag table:
/// `V1 → all false` (single namespace);
/// `V2|V3 → {decouple_host_deps: true,
///            decouple_dev_deps: has_dev_units == No,
///            ignore_inactive_targets: true}`.
/// Note `HasDevUnits::Yes` (building tests/examples) DISABLES dev-dep
/// decoupling even under v2.
pub const FeatureOpts = struct {
    decouple_host_deps: bool,
    decouple_dev_deps: bool, // false when building dev units even under v2 (HasDevUnits::Yes rule)
    ignore_inactive_targets: bool,
    pub fn forBehavior(b: Behavior, has_dev_units: bool) FeatureOpts {
        return switch (b) {
            .v1 => .{ .decouple_host_deps = false, .decouple_dev_deps = false, .ignore_inactive_targets = false },
            .v2, .v3 => .{ .decouple_host_deps = true, .decouple_dev_deps = !has_dev_units, .ignore_inactive_targets = true },
        };
    }
};

pub const FeaturesFor = enum { normal_or_dev, host_dep };

/// NOTE: unlike `Registry.queryFn` (which threads M2 fetcher state with a
/// fallible ctx query), `edgeKind` stays a pure name-pair callback (tests
/// use literals; no fetcher state or failure modes). `is_dev` marks
/// dev-dependency edges (Task 7 `DepEdgeFull.is_dev` is the production
/// carrier; tests use literals).
pub const EdgeKind = struct { for_host: bool, target_active: bool, is_dev: bool = false };

pub const NsSets = struct {
    normal_or_dev: std.StringHashMap(void), // features enabled in the normal/dev namespace
    host_dep: std.StringHashMap(void), // features enabled in the host-dep namespace (build-deps/proc-macros under v2)
    pub fn deinit(self: *NsSets) void {
        self.normal_or_dev.deinit();
        self.host_dep.deinit();
    }
};

pub const UnifiedNamespaces = struct {
    gpa: std.mem.Allocator,
    // (pkg, FeaturesFor) → feature set; v1 callers use normal_or_dev for everything.
    inner: std.StringHashMap(NsSets),
    quarantined: std.StringHashMap(std.StringHashMap(void)), // dev-dep quarantine namespace (test-only reads)
    pub fn deinit(self: *UnifiedNamespaces) void {
        var it = self.inner.iterator();
        while (it.next()) |kv| kv.value_ptr.deinit();
        self.inner.deinit();
        var it2 = self.quarantined.iterator();
        while (it2.next()) |kv| kv.value_ptr.deinit();
        self.quarantined.deinit();
    }
    pub fn isEnabled(self: *const UnifiedNamespaces, pkg: []const u8, which: FeaturesFor, feat: []const u8) bool {
        const sets = self.inner.get(pkg) orelse return false;
        return switch (which) {
            .normal_or_dev => sets.normal_or_dev.contains(feat),
            .host_dep => sets.host_dep.contains(feat),
        };
    }
    /// Tests ONLY, never build planning.
    pub fn isEnabledQuarantined(self: *const UnifiedNamespaces, pkg: []const u8, feat: []const u8) bool {
        const set = self.quarantined.get(pkg) orelse return false;
        return set.contains(feat);
    }
};

const Ns = enum { normal, host, quar };

const PkgState = struct {
    feats: std.StringHashMap(void),
    deps: std.StringHashMap(void),
};

const NS = struct {
    gpa: std.mem.Allocator,
    maps: *const std.StringHashMap(FeatureMap),
    opts: FeatureOpts,
    edgeKind: *const fn (parent: []const u8, dep: []const u8) EdgeKind,
    graph: *const resolve.ResolveGraph,
    norm: std.StringHashMap(PkgState),
    host: std.StringHashMap(PkgState),
    quar: std.StringHashMap(PkgState),

    fn stateFor(self: *NS, ns: Ns, pkg: []const u8) UnifiedError!*PkgState {
        const m = switch (ns) {
            .normal => &self.norm,
            .host => &self.host,
            .quar => &self.quar,
        };
        const gop = m.getOrPut(pkg) catch return OOM;
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .feats = std.StringHashMap(void).init(self.gpa),
                .deps = std.StringHashMap(void).init(self.gpa),
            };
        }
        return gop.value_ptr;
    }

    fn request(self: *NS, pkg: []const u8, ns: Ns, feat: []const u8, validated: bool) UnifiedError!void {
        if (validated) {
            var ok = std.mem.eql(u8, feat, "default");
            if (!ok) {
                if (self.maps.get(pkg)) |mm| {
                    for (mm.rules) |r| {
                        if (std.mem.eql(u8, r.feature, feat)) {
                            ok = true;
                            break;
                        }
                    }
                    if (!ok) for (mm.optional_deps) |o| {
                        if (std.mem.eql(u8, o, feat)) {
                            ok = true;
                            break;
                        }
                    };
                }
            }
            if (!ok) return UnifiedError.UnknownFeature;
        }
        const ps = try self.stateFor(ns, pkg);
        if (ps.feats.contains(feat)) return;
        ps.feats.put(feat, {}) catch return OOM;
        if (self.maps.get(pkg)) |mm| {
            for (mm.optional_deps) |o| {
                if (std.mem.eql(u8, o, feat)) {
                    // Implicit feature: enable the dep in this namespace,
                    // defaults landing where it builds (same ns here).
                    try self.enableDep(pkg, ns, o, ns);
                    break;
                }
            }
        }
    }

    /// Record P's dep D as enabled in `ns_rec` (the requesting namespace's
    /// view, which is what weak `dep?/feat` values observe) and pull D's
    /// defaults into `ns_feat` (where D builds). Same-namespace callers pass
    /// the same value twice, exactly matching v1.
    fn enableDep(self: *NS, holder: []const u8, ns_rec: Ns, dep: []const u8, ns_feat: Ns) UnifiedError!void {
        const ps = try self.stateFor(ns_rec, holder);
        if (ps.deps.contains(dep)) return;
        ps.deps.put(dep, {}) catch return OOM;
        try self.request(dep, ns_feat, "default", false);
    }

    /// Namespace routing for a feature request crossing edge P→D from a rule
    /// processed in `ns_p`: quarantine sticks; dev edges quarantine when
    /// decoupled; host edges go host when decoupled; otherwise a host unit's
    /// normal deps stay host (they build for host), else normal.
    fn route(self: *NS, parent: []const u8, dep: []const u8, ns_p: Ns) Ns {
        if (ns_p == .quar) return .quar;
        const k = self.edgeKind(parent, dep);
        if (k.is_dev and self.opts.decouple_dev_deps) return .quar;
        if (k.for_host and self.opts.decouple_host_deps) return .host;
        if (ns_p == .host) return .host;
        return .normal;
    }

    fn edgeActive(self: *NS, parent: []const u8, dep: []const u8) bool {
        if (!self.opts.ignore_inactive_targets) return true;
        return self.edgeKind(parent, dep).target_active;
    }

    fn applyValue(self: *NS, pkg: []const u8, ns_p: Ns, v: FeatureValue) UnifiedError!void {
        switch (v) {
            .own => |f| try self.request(pkg, ns_p, f, true),
            .dep => |n| try self.request(pkg, ns_p, n, true),
            .dep_named => |n| {
                if (!self.edgeActive(pkg, n)) return;
                try self.enableDep(pkg, ns_p, n, ns_p);
            },
            .dep_feature => |df| {
                if (!self.edgeActive(pkg, df.dep)) return;
                const ns_d = self.route(pkg, df.dep, ns_p);
                try self.enableDep(pkg, ns_p, df.dep, ns_d);
                try self.request(df.dep, ns_d, df.feat, false);
            },
            .weak_feature => |wf| {
                if (!self.edgeActive(pkg, wf.dep)) return;
                const ps = try self.stateFor(ns_p, pkg);
                if (ps.deps.contains(wf.dep)) {
                    const ns_d = self.route(pkg, wf.dep, ns_p);
                    try self.request(wf.dep, ns_d, wf.feat, false);
                }
            },
        }
    }

    /// A root's seeds land in quarantine iff dev-deps are decoupled AND the
    /// root is reachable in-graph solely through dev edges (i.e. it is
    /// itself a dev-dep, like `dtest` behind `app → dtest (dev)`). Roots
    /// with no incoming edges (workspace members being built) stay normal.
    fn rootNs(self: *NS, root: []const u8) Ns {
        if (!self.opts.decouple_dev_deps) return .normal;
        var incoming: usize = 0;
        var all_dev = true;
        for (self.graph.nodes) |pn| {
            for (pn.deps) |d| {
                if (!std.mem.eql(u8, d.name, root)) continue;
                // The (parent, dep) callback is name-keyed; any version's
                // edge answers for the name pair.
                incoming += 1;
                if (!self.edgeKind(pn.name, d.name).is_dev) all_dev = false;
            }
        }
        if (incoming > 0 and all_dev) return .quar;
        return .normal;
    }
};

/// Namespaced unification (`features.rs` second pass). EVERYTHING is keyed by
/// `(pkg, FeaturesFor)`: `for_host` edges (build-deps, proc-macros) land in
/// `host_dep` when `decouple_host_deps`, else merged; dev-edge requests route
/// to a quarantined namespace (invisible to build planning) when
/// `decouple_dev_deps`; inactive-target edges contribute nothing when
/// `ignore_inactive_targets`. With all-false opts this equals `unifyV1`
/// (pinned by test). `v3 == v2` for unification (v3 only changes version
/// preferences — already covered by the index msrv ordering).
pub fn unify(
    gpa: std.mem.Allocator,
    graph: *const resolve.ResolveGraph,
    maps: *const std.StringHashMap(FeatureMap),
    roots: []const RootReq,
    opts: FeatureOpts,
    edgeKind: *const fn (parent: []const u8, dep: []const u8) EdgeKind,
) UnifiedError!UnifiedNamespaces {
    var st = NS{
        .gpa = gpa,
        .maps = maps,
        .opts = opts,
        .edgeKind = edgeKind,
        .graph = graph,
        .norm = std.StringHashMap(PkgState).init(gpa),
        .host = std.StringHashMap(PkgState).init(gpa),
        .quar = std.StringHashMap(PkgState).init(gpa),
    };
    errdefer {
        var it = st.norm.iterator();
        while (it.next()) |kv| {
            kv.value_ptr.feats.deinit();
            kv.value_ptr.deps.deinit();
        }
        st.norm.deinit();
        var it2 = st.host.iterator();
        while (it2.next()) |kv| {
            kv.value_ptr.feats.deinit();
            kv.value_ptr.deps.deinit();
        }
        st.host.deinit();
        var it3 = st.quar.iterator();
        while (it3.next()) |kv| {
            kv.value_ptr.feats.deinit();
            kv.value_ptr.deps.deinit();
        }
        st.quar.deinit();
    }

    for (roots) |r| {
        const ns0 = st.rootNs(r.package);
        if (r.all_features) {
            if (maps.get(r.package)) |m| {
                for (m.rules) |rule| try st.request(r.package, ns0, rule.feature, false);
                try st.request(r.package, ns0, "default", false);
                for (m.optional_deps) |o| try st.request(r.package, ns0, o, false);
            }
        } else if (!r.no_default) {
            try st.request(r.package, ns0, "default", false);
        }
        for (r.features) |f| try st.request(r.package, ns0, f, true);
    }

    var changed = true;
    while (changed) {
        changed = false;
        var work: std.ArrayList(struct { pkg: []const u8, ns: Ns, feat: []const u8 }) = .empty;
        defer work.deinit(gpa);
        const tables = [_]*std.StringHashMap(PkgState){ &st.norm, &st.host, &st.quar };
        const nss = [_]Ns{ .normal, .host, .quar };
        for (tables, 0..) |t, ti| {
            var it = t.iterator();
            while (it.next()) |kv| {
                var jt = kv.value_ptr.feats.iterator();
                while (jt.next()) |f| {
                    work.append(gpa, .{ .pkg = kv.key_ptr.*, .ns = nss[ti], .feat = f.key_ptr.* }) catch return OOM;
                }
            }
        }
        for (work.items) |w| {
            // Count-gated change detection: `request`/`enableDep` dedup, so
            // only genuine growth flips `changed`; termination follows from
            // the bounded (pkg, ns, feat) space.
            const before = countAll(&st);
            if (std.mem.eql(u8, w.feat, "default")) {
                if (maps.get(w.pkg)) |m| {
                    for (m.default) |d| try st.request(w.pkg, w.ns, d, false);
                }
            } else if (maps.get(w.pkg)) |m| {
                for (m.rules) |rule| {
                    if (!std.mem.eql(u8, rule.feature, w.feat)) continue;
                    for (rule.values) |v| try st.applyValue(w.pkg, w.ns, v);
                    break;
                }
            }
            if (countAll(&st) != before) changed = true;
        }
    }

    var inner = std.StringHashMap(NsSets).init(gpa);
    errdefer {
        var it = inner.iterator();
        while (it.next()) |kv| kv.value_ptr.deinit();
        inner.deinit();
    }
    // Union of norm/host package keys; move the owned sets out of the
    // working tables (source outers are deinited below without touching the
    // moved inners).
    var keys: std.StringHashMap(void) = std.StringHashMap(void).init(gpa);
    defer keys.deinit();
    var itk = st.norm.iterator();
    while (itk.next()) |kv| keys.put(kv.key_ptr.*, {}) catch return OOM;
    var itk2 = st.host.iterator();
    while (itk2.next()) |kv| keys.put(kv.key_ptr.*, {}) catch return OOM;
    var itk3 = keys.iterator();
    while (itk3.next()) |kv| {
        const pkg = kv.key_ptr.*;
        const nstate = st.norm.getPtr(pkg);
        const hstate = st.host.getPtr(pkg);
        var sets = NsSets{
            .normal_or_dev = if (nstate) |s| s.feats else std.StringHashMap(void).init(gpa),
            .host_dep = if (hstate) |s| s.feats else std.StringHashMap(void).init(gpa),
        };
        // Detach: remove the entries so the working-table teardown below
        // does not deinit the moved sets (dep sets are dropped: internal).
        if (nstate) |s| {
            s.deps.deinit();
            _ = st.norm.remove(pkg);
        }
        if (hstate) |s| {
            s.deps.deinit();
            _ = st.host.remove(pkg);
        }
        inner.put(pkg, sets) catch {
            sets.deinit();
            return OOM;
        };
    }
    // Drop remaining working entries (pkgs only in quarantine, if any, plus
    // dep sets of moved entries are already deinited).
    {
        var it = st.norm.iterator();
        while (it.next()) |kv| {
            kv.value_ptr.feats.deinit();
            kv.value_ptr.deps.deinit();
        }
        st.norm.deinit();
        var itb = st.host.iterator();
        while (itb.next()) |kv| {
            kv.value_ptr.feats.deinit();
            kv.value_ptr.deps.deinit();
        }
        st.host.deinit();
    }
    var quarantined = std.StringHashMap(std.StringHashMap(void)).init(gpa);
    errdefer {
        var it = quarantined.iterator();
        while (it.next()) |kv| kv.value_ptr.deinit();
        quarantined.deinit();
    }
    {
        var it = st.quar.iterator();
        while (it.next()) |kv| {
            kv.value_ptr.deps.deinit();
            quarantined.put(kv.key_ptr.*, kv.value_ptr.feats) catch return OOM;
        }
        st.quar.deinit();
    }
    return UnifiedNamespaces{ .gpa = gpa, .inner = inner, .quarantined = quarantined };
}

fn countAll(st: *NS) usize {
    var n: usize = 0;
    var it = st.norm.iterator();
    while (it.next()) |kv| {
        n += kv.value_ptr.feats.count();
        n += kv.value_ptr.deps.count();
    }
    var it2 = st.host.iterator();
    while (it2.next()) |kv| {
        n += kv.value_ptr.feats.count();
        n += kv.value_ptr.deps.count();
    }
    var it3 = st.quar.iterator();
    while (it3.next()) |kv| {
        n += kv.value_ptr.feats.count();
        n += kv.value_ptr.deps.count();
    }
    return n;
}

// --- Task 5 tests ---

const semver = @import("semver.zig");
const sources = @import("sources.zig");

test "v1 unifies features across parents" {
    const gpa = std.testing.allocator;
    // app → left (feat f → shared/feat-a), app → right (feat g → shared/feat-b).
    // unified shared has BOTH feat-a and feat-b (v1 single namespace).
    const reg: sources.SourceId = .{ .registry = "sparse+https://github.com/rust-lang/crates.io-index" };
    const v100 = try semver.Version.parse("1.0.0");
    const left_refs = [_]resolve.ResolvedRef{.{ .name = "shared", .version = v100, .source = reg }};
    const right_refs = [_]resolve.ResolvedRef{.{ .name = "shared", .version = v100, .source = reg }};
    const app_refs = [_]resolve.ResolvedRef{
        .{ .name = "left", .version = v100, .source = reg },
        .{ .name = "right", .version = v100, .source = reg },
    };
    const nodes = [_]resolve.ResolvedNode{
        .{ .name = "app", .version = v100, .source = reg, .deps = &app_refs },
        .{ .name = "left", .version = v100, .source = reg, .deps = &left_refs },
        .{ .name = "right", .version = v100, .source = reg, .deps = &right_refs },
        .{ .name = "shared", .version = v100, .source = reg, .deps = &.{} },
    };
    var graph = resolve.ResolveGraph{ .arena = std.heap.ArenaAllocator.init(gpa), .nodes = &nodes };
    defer graph.deinit();
    const left_rules = [_]FeatureRule{
        .{ .feature = "f", .values = &[_]FeatureValue{.{ .dep_feature = .{ .dep = "shared", .feat = "feat-a" } }} },
    };
    const right_rules = [_]FeatureRule{
        .{ .feature = "g", .values = &[_]FeatureValue{.{ .dep_feature = .{ .dep = "shared", .feat = "feat-b" } }} },
    };
    var maps = std.StringHashMap(FeatureMap).init(gpa);
    defer maps.deinit();
    try maps.put("left", .{ .default = &.{}, .optional_deps = &.{}, .rules = &left_rules });
    try maps.put("right", .{ .default = &.{}, .optional_deps = &.{}, .rules = &right_rules });
    try maps.put("shared", .{ .default = &.{}, .optional_deps = &.{}, .rules = &.{} });
    const roots = [_]RootReq{
        .{ .package = "left", .features = &[_][]const u8{"f"}, .all_features = false, .no_default = true },
        .{ .package = "right", .features = &[_][]const u8{"g"}, .all_features = false, .no_default = true },
    };
    var u = try unifyV1(gpa, &graph, &maps, &roots);
    defer u.deinit();
    try std.testing.expect(u.isEnabled("shared", "feat-a"));
    try std.testing.expect(u.isEnabled("shared", "feat-b"));
}

test "weak dep feature does not enable the dep" {
    const gpa = std.testing.allocator;
    const reg: sources.SourceId = .{ .registry = "sparse+https://github.com/rust-lang/crates.io-index" };
    const v100 = try semver.Version.parse("1.0.0");
    const nodes = [_]resolve.ResolvedNode{
        .{ .name = "app", .version = v100, .source = reg, .deps = &.{} },
        .{ .name = "opt", .version = v100, .source = reg, .deps = &.{} },
    };
    var graph = resolve.ResolveGraph{ .arena = std.heap.ArenaAllocator.init(gpa), .nodes = &nodes };
    defer graph.deinit();
    // rule f = ["opt?/feat"]; opt NOT otherwise enabled → opt stays disabled, feat not applied.
    const app_rules = [_]FeatureRule{
        .{ .feature = "f", .values = &[_]FeatureValue{.{ .weak_feature = .{ .dep = "opt", .feat = "feat" } }} },
    };
    var maps = std.StringHashMap(FeatureMap).init(gpa);
    defer maps.deinit();
    try maps.put("app", .{ .default = &.{}, .optional_deps = &[_][]const u8{"opt"}, .rules = &app_rules });
    try maps.put("opt", .{ .default = &[_][]const u8{"feat"}, .optional_deps = &.{}, .rules = &.{} });
    const roots_off = [_]RootReq{
        .{ .package = "app", .features = &[_][]const u8{"f"}, .all_features = false, .no_default = true },
    };
    var u_off = try unifyV1(gpa, &graph, &maps, &roots_off);
    defer u_off.deinit();
    try std.testing.expect(!u_off.isEnabled("opt", "feat"));
    // Same rule with opt enabled elsewhere → feat applied, opt enabled.
    const roots_on = [_]RootReq{
        .{ .package = "app", .features = &[_][]const u8{ "f", "opt" }, .all_features = false, .no_default = true },
    };
    var u_on = try unifyV1(gpa, &graph, &maps, &roots_on);
    defer u_on.deinit();
    try std.testing.expect(u_on.isEnabled("opt", "feat"));
}

test "dep-colon syntax skips implicit feature" {
    const gpa = std.testing.allocator;
    // rule f = ["dep:opt"] → opt enabled but app's own implicit feature "opt" NOT marked.
    const reg: sources.SourceId = .{ .registry = "sparse+https://github.com/rust-lang/crates.io-index" };
    const v100 = try semver.Version.parse("1.0.0");
    const nodes = [_]resolve.ResolvedNode{
        .{ .name = "app", .version = v100, .source = reg, .deps = &.{} },
        .{ .name = "opt", .version = v100, .source = reg, .deps = &.{} },
    };
    var graph = resolve.ResolveGraph{ .arena = std.heap.ArenaAllocator.init(gpa), .nodes = &nodes };
    defer graph.deinit();
    const app_rules = [_]FeatureRule{
        .{ .feature = "f", .values = &[_]FeatureValue{.{ .dep_named = "opt" }} },
    };
    var maps = std.StringHashMap(FeatureMap).init(gpa);
    defer maps.deinit();
    try maps.put("app", .{ .default = &.{}, .optional_deps = &[_][]const u8{"opt"}, .rules = &app_rules });
    try maps.put("opt", .{ .default = &.{}, .optional_deps = &.{}, .rules = &.{} });
    const roots = [_]RootReq{
        .{ .package = "app", .features = &[_][]const u8{"f"}, .all_features = false, .no_default = true },
    };
    var u = try unifyV1(gpa, &graph, &maps, &roots);
    defer u.deinit();
    const deps_of_app = u.enabled_deps.get("app");
    try std.testing.expect(deps_of_app != null and deps_of_app.?.contains("opt"));
    try std.testing.expect(!u.isEnabled("app", "opt"));
}

test "unknown feature errors" {
    const gpa = std.testing.allocator;
    const reg: sources.SourceId = .{ .registry = "sparse+https://github.com/rust-lang/crates.io-index" };
    const v100 = try semver.Version.parse("1.0.0");
    const nodes = [_]resolve.ResolvedNode{
        .{ .name = "app", .version = v100, .source = reg, .deps = &.{} },
    };
    var graph = resolve.ResolveGraph{ .arena = std.heap.ArenaAllocator.init(gpa), .nodes = &nodes };
    defer graph.deinit();
    var maps = std.StringHashMap(FeatureMap).init(gpa);
    defer maps.deinit();
    try maps.put("app", .{ .default = &[_][]const u8{"std"}, .optional_deps = &.{}, .rules = &.{} });
    const roots = [_]RootReq{
        .{ .package = "app", .features = &[_][]const u8{"nope"}, .all_features = false, .no_default = true },
    };
    try std.testing.expectError(UnifiedError.UnknownFeature, unifyV1(gpa, &graph, &maps, &roots));
}

test "pruneOptional removes disabled optional subtree" {
    const gpa = std.testing.allocator;
    // graph has app → opt (optional, disabled) → sub; after prune, opt and sub gone, app kept.
    const reg: sources.SourceId = .{ .registry = "sparse+https://github.com/rust-lang/crates.io-index" };
    const v100 = try semver.Version.parse("1.0.0");
    const opt_refs = [_]resolve.ResolvedRef{.{ .name = "sub", .version = v100, .source = reg }};
    const app_refs = [_]resolve.ResolvedRef{.{ .name = "opt", .version = v100, .source = reg }};
    const nodes = [_]resolve.ResolvedNode{
        .{ .name = "app", .version = v100, .source = reg, .deps = &app_refs },
        .{ .name = "opt", .version = v100, .source = reg, .deps = &opt_refs },
        .{ .name = "sub", .version = v100, .source = reg, .deps = &.{} },
    };
    var graph = resolve.ResolveGraph{ .arena = std.heap.ArenaAllocator.init(gpa), .nodes = &nodes };
    defer graph.deinit();
    var maps = std.StringHashMap(FeatureMap).init(gpa);
    defer maps.deinit();
    try maps.put("app", .{ .default = &.{}, .optional_deps = &[_][]const u8{"opt"}, .rules = &.{} });
    try maps.put("opt", .{ .default = &.{}, .optional_deps = &.{}, .rules = &.{} });
    try maps.put("sub", .{ .default = &.{}, .optional_deps = &.{}, .rules = &.{} });
    const roots = [_]RootReq{
        .{ .package = "app", .features = &.{}, .all_features = false, .no_default = true },
    };
    var u = try unifyV1(gpa, &graph, &maps, &roots);
    defer u.deinit();
    const kept = try pruneOptional(gpa, &graph, &u);
    defer gpa.free(kept);
    try std.testing.expectEqual(@as(usize, 1), kept.len);
    try std.testing.expectEqualStrings("app", kept[0].name);
}

// --- Task 6 tests ---

test "v2 does not unify build-dep features into normal deps" {
    const gpa = std.testing.allocator;
    // shared built normally (feat normal-only) AND as build-dep of tool (feat host-only).
    // v1: shared has both. v2: normal namespace has normal-only; host namespace has host-only.
    const reg: sources.SourceId = .{ .registry = "sparse+https://github.com/rust-lang/crates.io-index" };
    const v100 = try semver.Version.parse("1.0.0");
    const app_refs = [_]resolve.ResolvedRef{.{ .name = "shared", .version = v100, .source = reg }};
    const tool_refs = [_]resolve.ResolvedRef{.{ .name = "shared", .version = v100, .source = reg }};
    const nodes = [_]resolve.ResolvedNode{
        .{ .name = "app", .version = v100, .source = reg, .deps = &app_refs },
        .{ .name = "tool", .version = v100, .source = reg, .deps = &tool_refs },
        .{ .name = "shared", .version = v100, .source = reg, .deps = &.{} },
    };
    var graph = resolve.ResolveGraph{ .arena = std.heap.ArenaAllocator.init(gpa), .nodes = &nodes };
    defer graph.deinit();
    const app_rules = [_]FeatureRule{
        .{ .feature = "f", .values = &[_]FeatureValue{.{ .dep_feature = .{ .dep = "shared", .feat = "normal-only" } }} },
    };
    const tool_rules = [_]FeatureRule{
        .{ .feature = "h", .values = &[_]FeatureValue{.{ .dep_feature = .{ .dep = "shared", .feat = "host-only" } }} },
    };
    var maps = std.StringHashMap(FeatureMap).init(gpa);
    defer maps.deinit();
    try maps.put("app", .{ .default = &.{}, .optional_deps = &.{}, .rules = &app_rules });
    try maps.put("tool", .{ .default = &.{}, .optional_deps = &.{}, .rules = &tool_rules });
    try maps.put("shared", .{ .default = &.{}, .optional_deps = &.{}, .rules = &.{} });
    const roots = [_]RootReq{
        .{ .package = "app", .features = &[_][]const u8{"f"}, .all_features = false, .no_default = true },
        .{ .package = "tool", .features = &[_][]const u8{"h"}, .all_features = false, .no_default = true },
    };
    const Kinds = struct {
        fn edge(parent: []const u8, dep: []const u8) EdgeKind {
            if (std.mem.eql(u8, parent, "tool") and std.mem.eql(u8, dep, "shared"))
                return .{ .for_host = true, .target_active = true };
            return .{ .for_host = false, .target_active = true };
        }
    };
    var v1 = try unifyV1(gpa, &graph, &maps, &roots);
    defer v1.deinit();
    try std.testing.expect(v1.isEnabled("shared", "normal-only"));
    try std.testing.expect(v1.isEnabled("shared", "host-only"));
    var v2 = try unify(gpa, &graph, &maps, &roots, FeatureOpts.forBehavior(.v2, false), &Kinds.edge);
    defer v2.deinit();
    try std.testing.expect(v2.isEnabled("shared", .normal_or_dev, "normal-only"));
    try std.testing.expect(!v2.isEnabled("shared", .normal_or_dev, "host-only"));
    try std.testing.expect(v2.isEnabled("shared", .host_dep, "host-only"));
    try std.testing.expect(!v2.isEnabled("shared", .host_dep, "normal-only"));
}

test "v2 dev-deps stay quarantined without dev units" {
    const gpa = std.testing.allocator;
    // app dev-dep dtest enables feat-x on shared; normal path does not.
    // has_dev_units=false → normal shared lacks feat-x; has_dev_units=true → unified (HasDevUnits::Yes rule).
    const reg: sources.SourceId = .{ .registry = "sparse+https://github.com/rust-lang/crates.io-index" };
    const v100 = try semver.Version.parse("1.0.0");
    const app_refs = [_]resolve.ResolvedRef{
        .{ .name = "shared", .version = v100, .source = reg },
        .{ .name = "dtest", .version = v100, .source = reg },
    };
    const dtest_refs = [_]resolve.ResolvedRef{.{ .name = "shared", .version = v100, .source = reg }};
    const nodes = [_]resolve.ResolvedNode{
        .{ .name = "app", .version = v100, .source = reg, .deps = &app_refs },
        .{ .name = "dtest", .version = v100, .source = reg, .deps = &dtest_refs },
        .{ .name = "shared", .version = v100, .source = reg, .deps = &.{} },
    };
    var graph = resolve.ResolveGraph{ .arena = std.heap.ArenaAllocator.init(gpa), .nodes = &nodes };
    defer graph.deinit();
    const dtest_rules = [_]FeatureRule{
        .{ .feature = "t", .values = &[_]FeatureValue{.{ .dep_feature = .{ .dep = "shared", .feat = "feat-x" } }} },
    };
    var maps = std.StringHashMap(FeatureMap).init(gpa);
    defer maps.deinit();
    try maps.put("app", .{ .default = &.{}, .optional_deps = &.{}, .rules = &.{} });
    try maps.put("dtest", .{ .default = &.{}, .optional_deps = &.{}, .rules = &dtest_rules });
    try maps.put("shared", .{ .default = &.{}, .optional_deps = &.{}, .rules = &.{} });
    const roots = [_]RootReq{
        .{ .package = "app", .features = &.{}, .all_features = false, .no_default = true },
        .{ .package = "dtest", .features = &[_][]const u8{"t"}, .all_features = false, .no_default = true },
    };
    const Kinds = struct {
        fn edge(parent: []const u8, dep: []const u8) EdgeKind {
            if (std.mem.eql(u8, parent, "app") and std.mem.eql(u8, dep, "dtest"))
                return .{ .for_host = false, .target_active = true, .is_dev = true };
            return .{ .for_host = false, .target_active = true };
        }
    };
    var cold = try unify(gpa, &graph, &maps, &roots, FeatureOpts.forBehavior(.v2, false), &Kinds.edge);
    defer cold.deinit();
    try std.testing.expect(!cold.isEnabled("shared", .normal_or_dev, "feat-x"));
    try std.testing.expect(cold.isEnabledQuarantined("shared", "feat-x"));
    var hot = try unify(gpa, &graph, &maps, &roots, FeatureOpts.forBehavior(.v2, true), &Kinds.edge);
    defer hot.deinit();
    try std.testing.expect(hot.isEnabled("shared", .normal_or_dev, "feat-x"));
}

test "v1 opts equal unifyV1" {
    const gpa = std.testing.allocator;
    // replay Task 5's cross-parent fixture through unify(all-false) and unifyV1; assert identical sets.
    const reg: sources.SourceId = .{ .registry = "sparse+https://github.com/rust-lang/crates.io-index" };
    const v100 = try semver.Version.parse("1.0.0");
    const left_refs = [_]resolve.ResolvedRef{.{ .name = "shared", .version = v100, .source = reg }};
    const right_refs = [_]resolve.ResolvedRef{.{ .name = "shared", .version = v100, .source = reg }};
    const nodes = [_]resolve.ResolvedNode{
        .{ .name = "left", .version = v100, .source = reg, .deps = &left_refs },
        .{ .name = "right", .version = v100, .source = reg, .deps = &right_refs },
        .{ .name = "shared", .version = v100, .source = reg, .deps = &.{} },
    };
    var graph = resolve.ResolveGraph{ .arena = std.heap.ArenaAllocator.init(gpa), .nodes = &nodes };
    defer graph.deinit();
    const left_rules = [_]FeatureRule{
        .{ .feature = "f", .values = &[_]FeatureValue{.{ .dep_feature = .{ .dep = "shared", .feat = "feat-a" } }} },
    };
    const right_rules = [_]FeatureRule{
        .{ .feature = "g", .values = &[_]FeatureValue{.{ .dep_feature = .{ .dep = "shared", .feat = "feat-b" } }} },
    };
    var maps = std.StringHashMap(FeatureMap).init(gpa);
    defer maps.deinit();
    try maps.put("left", .{ .default = &.{}, .optional_deps = &.{}, .rules = &left_rules });
    try maps.put("right", .{ .default = &.{}, .optional_deps = &.{}, .rules = &right_rules });
    try maps.put("shared", .{ .default = &.{}, .optional_deps = &.{}, .rules = &.{} });
    const roots = [_]RootReq{
        .{ .package = "left", .features = &[_][]const u8{"f"}, .all_features = false, .no_default = true },
        .{ .package = "right", .features = &[_][]const u8{"g"}, .all_features = false, .no_default = true },
    };
    const Kinds = struct {
        fn edge(parent: []const u8, dep: []const u8) EdgeKind {
            _ = parent;
            _ = dep;
            return .{ .for_host = false, .target_active = true };
        }
    };
    var v1 = try unifyV1(gpa, &graph, &maps, &roots);
    defer v1.deinit();
    var u = try unify(gpa, &graph, &maps, &roots, FeatureOpts.forBehavior(.v1, false), &Kinds.edge);
    defer u.deinit();
    for ([_][]const u8{ "feat-a", "feat-b" }) |feat| {
        try std.testing.expectEqual(v1.isEnabled("shared", feat), u.isEnabled("shared", .normal_or_dev, feat));
    }
}

test "v3 matches v2 for features and behavior parses" {
    // v3 == v2 for unification (v3 only changes version preferences).
    try std.testing.expectEqual(FeatureOpts.forBehavior(.v2, false), FeatureOpts.forBehavior(.v3, false));
    try std.testing.expectEqual(FeatureOpts.forBehavior(.v2, true), FeatureOpts.forBehavior(.v3, true));
    try std.testing.expect((try Behavior.fromManifest("1")) == .v1);
    try std.testing.expect((try Behavior.fromManifest("2")) == .v2);
    try std.testing.expect((try Behavior.fromManifest("3")) == .v3);
    try std.testing.expectError(UnifiedError.InvalidBehavior, Behavior.fromManifest("4"));
}

test "v2 ignores inactive-target edges" {
    const gpa = std.testing.allocator;
    // left enables shared/win-only through a windows-gated edge; target is
    // linux (inactive) → v2 drops the request, v1 leaks it.
    const reg: sources.SourceId = .{ .registry = "sparse+https://github.com/rust-lang/crates.io-index" };
    const v100 = try semver.Version.parse("1.0.0");
    const left_refs = [_]resolve.ResolvedRef{.{ .name = "shared", .version = v100, .source = reg }};
    const nodes = [_]resolve.ResolvedNode{
        .{ .name = "left", .version = v100, .source = reg, .deps = &left_refs },
        .{ .name = "shared", .version = v100, .source = reg, .deps = &.{} },
    };
    var graph = resolve.ResolveGraph{ .arena = std.heap.ArenaAllocator.init(gpa), .nodes = &nodes };
    defer graph.deinit();
    const left_rules = [_]FeatureRule{
        .{ .feature = "f", .values = &[_]FeatureValue{.{ .dep_feature = .{ .dep = "shared", .feat = "win-only" } }} },
    };
    var maps = std.StringHashMap(FeatureMap).init(gpa);
    defer maps.deinit();
    try maps.put("left", .{ .default = &.{}, .optional_deps = &.{}, .rules = &left_rules });
    try maps.put("shared", .{ .default = &.{}, .optional_deps = &.{}, .rules = &.{} });
    const roots = [_]RootReq{
        .{ .package = "left", .features = &[_][]const u8{"f"}, .all_features = false, .no_default = true },
    };
    const Kinds = struct {
        fn edge(parent: []const u8, dep: []const u8) EdgeKind {
            _ = parent;
            _ = dep;
            return .{ .for_host = false, .target_active = false };
        }
    };
    var v1 = try unifyV1(gpa, &graph, &maps, &roots);
    defer v1.deinit();
    try std.testing.expect(v1.isEnabled("shared", "win-only"));
    var v2 = try unify(gpa, &graph, &maps, &roots, FeatureOpts.forBehavior(.v2, false), &Kinds.edge);
    defer v2.deinit();
    try std.testing.expect(!v2.isEnabled("shared", .normal_or_dev, "win-only"));
}
