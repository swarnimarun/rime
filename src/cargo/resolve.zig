//! Activation DFS + backtracking + conflict cache + previous-lock guidance
//! (M3 Tasks 3 and 4).
//!
//! Reference pins (normative):
//! - `core/resolver/mod.rs::activate_deps_loop` (iterative DFS +
//!   `pop_most_constrained` + backtrack stack; candidates tried in
//!   `queryCandidates` order = cargo's max-version-first).
//! - `core/resolver/mod.rs::RemainingCandidates::next` (a candidate is
//!   skipped when semver-compatible-but-unequal to an activated version, or
//!   when its `links` key is held by another package).
//! - `core/resolver/types.rs::ActivationsKey` + `SemverCompatibility`
//!   (compatibility classes are the LEFT-MOST NONZERO digit: major for `>=1`,
//!   minor for `0.x`, patch for `0.0.x` -- note the plan section 0.1
//!   shorthand omits the `0.0.x` patch rule; this port implements the true
//!   three-way rule).
//! - `core/resolver/context.rs::flag_activated` (duplicate `links` is fatal;
//!   re-activation of the same package id is a no-op).
//! - `core/resolver/conflict_cache.rs::ConflictCache` (record conflict sets
//!   on backtrack; skip candidates participating in a known-conflict subset
//!   -- implemented here as a real trie over sorted `(name, version)` keys).
//! - `core/resolver/resolve.rs::check_cycles` +
//!   `check_duplicate_pkgs_in_lockfile` (post-success validation).
//! - `ops/resolve.rs::resolve_with_previous` (prefer-every-kept-id) +
//!   `register_previous_locks` (deps `lock_to()` previous versions, with the
//!   serde/log transitive-unlock refinement).
//!
//! Design notes vs cargo (behavior-preserving simplifications for M3):
//! - The explicit backtrack stack is realized as recursive DFS with full
//!   state snapshots. Candidate ORDER is identical (max-first from
//!   `queryCandidates`), so the first complete resolution found -- and hence
//!   every selected version -- matches cargo; conflict-directed jump-back is
//!   approximated chronologically (an optimization + error shaper in cargo,
//!   not a selection rule). Documented O(n^2) snapshot costs are acceptable
//!   for M3 graph sizes; production memoization of per-`(name, req)`
//!   candidate lists is an M2 optimization, not M3 semantics.
//! - `DepEdge.optional` edges are INVISIBLE to resolution (never enqueued,
//!   never recorded): they enter the graph only via Task 5 `unifyV1` +
//!   `pruneOptional`. `build_only` is carried on the edge (Task 6 consumes it).
//! - Sources: each `SummaryNode` carries its provider-tagged `source`
//!   (path for workspace members / path deps, the default crates.io sparse
//!   URL for index entries). Roots activate with `path("")` (per the
//!   interface note "workspace-member roots record path sources");
//!   non-root activations adopt `cand.node.source`, so a member/path edge
//!   hits its path root via `findActive` instead of activating a second
//!   registry-placeholder copy (the old root/edge source split, fixed here
//!   rather than in the oracle post-fixup). The registry placeholder
//!   survives only for genuine external registry deps. `find` ignores
//!   source values.
//! - `Registry.queryFn` slices must stay valid for the whole call; activated
//!   summaries are copied by value at activation time.
//! - `QueryError.FetchFailed` maps to `ResolveError.NoMatchingVersion`
//!   (Task 9 refines fetch failures into `Diag`; the M3a error taxonomy has
//!   no fetch variant).
//! - Links-driven total exhaustion surfaces as `ResolveError.Conflict`,
//!   version-driven exhaustion as `NoMatchingVersion` (cargo reports both
//!   through one "failed to select a version" shape; Task 9's `DiagKind`
//!   refines this split).

const std = @import("std");
const semver = @import("semver.zig");
const index = @import("index.zig");
const sources = @import("sources.zig");

pub const ResolveError = error{ NoMatchingVersion, Conflict, Cycle, OutOfMemory };
pub const OOM = ResolveError.OutOfMemory;

pub const DepEdge = struct {
    name: []const u8, // crate name depended upon
    req: semver.OptVersionReq, // version requirement (Locked form when previous-lock pins)
    optional: bool, // enabled only when requested via features (Task 5 wires this)
    build_only: bool, // build-dependency edge (v2 host-decouple key in Task 6)
};

pub const SummaryNode = struct {
    name: []const u8,
    candidate: index.Candidate, // the selected version + metadata
    deps: []const DepEdge, // edges OUT of this version (version-specific!)
    links: ?[]const u8, // `links = "..."` native-lib key (duplicates conflict)
    // Provider-tagged source: path for workspace members / path deps,
    // default registry for index entries. The resolver activates with this
    // source (cargo's `PackageId` source comes from the resolving `SourceId`),
    // so member/path edges unify with their path roots. Defaulted so the
    // registry seam's index entries need no per-node tagging.
    source: sources.SourceId = .{ .registry = default_registry },
};

pub const ResolveGraph = struct {
    arena: std.heap.ArenaAllocator, // owns ALL nodes/edges below
    nodes: []const ResolvedNode,
    pub fn deinit(self: *ResolveGraph) void {
        self.arena.deinit();
    }
    pub fn find(self: *const ResolveGraph, name: []const u8, version: semver.Version) ?ResolvedNode {
        for (self.nodes) |n| {
            if (std.mem.eql(u8, n.name, name) and n.version.eql(version)) return n;
        }
        return null;
    }
};

pub const ResolvedNode = struct {
    name: []const u8,
    version: semver.Version,
    source: sources.SourceId,
    deps: []const ResolvedRef,
};

pub const ResolvedRef = struct {
    name: []const u8,
    version: semver.Version,
    source: sources.SourceId,
};

pub const QueryError = error{ FetchFailed, OutOfMemory };

pub const Registry = struct { // test/M2 seam: all known versions of a crate, with caller state + fallible query
    ctx: *anyopaque,
    queryFn: *const fn (ctx: *anyopaque, name: []const u8) QueryError![]const SummaryNode,
};

/// Default registry for index-provided summaries (the `SummaryNode.source`
/// default); path providers tag their own summaries with path sources.
const default_registry: []const u8 = "sparse+https://github.com/rust-lang/crates.io-index";

// --- semver compatibility classes (types.rs::SemverCompatibility) ---

const CompatClass = union(enum) { major: u64, minor: u64, patch: u64 };

fn compatClass(v: semver.Version) CompatClass {
    if (v.major != 0) return .{ .major = v.major };
    if (v.minor != 0) return .{ .minor = v.minor };
    return .{ .patch = v.patch };
}

fn compatEql(a: CompatClass, b: CompatClass) bool {
    switch (a) {
        .major => |x| switch (b) {
            .major => |y| return x == y,
            else => return false,
        },
        .minor => |x| switch (b) {
            .minor => |y| return x == y,
            else => return false,
        },
        .patch => |x| switch (b) {
            .patch => |y| return x == y,
            else => return false,
        },
    }
}

fn sourceEql(a: sources.SourceId, b: sources.SourceId) bool {
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
                if (x.precise == null and y.precise == null) {
                    // equal (both absent)
                } else if (x.precise != null and y.precise != null) {
                    if (!std.mem.eql(u8, &x.precise.?, &y.precise.?)) return false;
                } else {
                    return false;
                }
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

// --- resolver state ---

const Active = struct {
    name: []const u8,
    version: semver.Version,
    node: SummaryNode, // struct copy; slices borrow caller/stub data
    source: sources.SourceId,
    is_root: bool,
    age: u64,
};

const Pending = struct {
    parent_idx: usize,
    edge: DepEdge,
    seq: usize,
};

const Resolution = struct { parent: usize, child: usize };

const State = struct {
    actives: std.ArrayList(Active),
    links: std.StringHashMap(usize),
    pending: std.ArrayList(Pending),
    resolutions: std.ArrayList(Resolution),
    next_seq: usize,
    next_age: u64,
    links_conflict_seen: bool, // sticky: any links-based skip (drives Conflict vs NoMatchingVersion)
};

const Snapshot = struct {
    actives_len: usize,
    pending: []Pending, // gpa-owned
    links: std.StringHashMap(usize),
    resolutions_len: usize,
    next_seq: usize,
    next_age: u64,

    fn deinit(self: *Snapshot, gpa: std.mem.Allocator) void {
        gpa.free(self.pending);
        self.links.deinit();
    }
};

fn takeSnapshot(gpa: std.mem.Allocator, state: *const State) ResolveError!Snapshot {
    const pending = gpa.dupe(Pending, state.pending.items) catch return OOM;
    errdefer gpa.free(pending);
    var links = std.StringHashMap(usize).init(gpa);
    errdefer links.deinit();
    var it = state.links.iterator();
    while (it.next()) |kv| {
        links.put(kv.key_ptr.*, kv.value_ptr.*) catch return OOM;
    }
    return Snapshot{
        .actives_len = state.actives.items.len,
        .pending = pending,
        .links = links,
        .resolutions_len = state.resolutions.items.len,
        .next_seq = state.next_seq,
        .next_age = state.next_age,
    };
}

fn restoreSnapshot(gpa: std.mem.Allocator, state: *State, snap: *Snapshot) ResolveError!void {
    state.actives.shrinkRetainingCapacity(snap.actives_len);
    state.pending.clearRetainingCapacity();
    // Re-appending a previously held slice into retained capacity cannot
    // need more than was already allocated, but treat pressure as OOM
    // (abort, never a wrong answer) rather than unreachable.
    state.pending.appendSlice(gpa, snap.pending) catch return OOM;
    state.links.clearRetainingCapacity();
    var it = snap.links.iterator();
    while (it.next()) |kv| {
        state.links.put(kv.key_ptr.*, kv.value_ptr.*) catch return OOM;
    }
    state.resolutions.shrinkRetainingCapacity(snap.resolutions_len);
    state.next_seq = snap.next_seq;
    state.next_age = snap.next_age;
    snap.deinit(gpa);
}

// --- conflict cache trie (conflict_cache.rs::ConflictCache) ---

const IdKey = struct { name: []const u8, version: semver.Version };

fn idLess(a: IdKey, b: IdKey) bool {
    const n = std.mem.order(u8, a.name, b.name);
    if (n != .eq) return n == .lt;
    switch (a.version.order(b.version)) {
        .lt => return true,
        .gt => return false,
        .eq => return std.mem.order(u8, a.version.build, b.version.build) == .lt,
    }
}

fn idEql(a: IdKey, b: IdKey) bool {
    return std.mem.eql(u8, a.name, b.name) and a.version.eql(b.version);
}

const TrieNode = struct {
    children: std.ArrayList(TrieEdge),
    terminal: bool,
};

const TrieEdge = struct { key: IdKey, node: usize };

const ConflictStore = struct {
    gpa: std.mem.Allocator,
    nodes: std.ArrayList(TrieNode),

    fn init(gpa: std.mem.Allocator) ResolveError!ConflictStore {
        var nodes: std.ArrayList(TrieNode) = .empty;
        nodes.append(gpa, .{ .children = .empty, .terminal = false }) catch return OOM;
        return .{ .gpa = gpa, .nodes = nodes };
    }

    fn deinit(self: *ConflictStore) void {
        for (self.nodes.items) |*n| n.children.deinit(self.gpa);
        self.nodes.deinit(self.gpa);
    }

    /// Insert a sorted id set (caller sorts with `idLess` first).
    fn insert(self: *ConflictStore, ids: []const IdKey) ResolveError!void {
        var cur: usize = 0;
        for (ids) |id| {
            var next: ?usize = null;
            for (self.nodes.items[cur].children.items) |e| {
                if (idEql(e.key, id)) {
                    next = e.node;
                    break;
                }
            }
            if (next == null) {
                const idx = self.nodes.items.len;
                self.nodes.items[cur].children.append(self.gpa, .{ .key = id, .node = idx }) catch return OOM;
                self.nodes.append(self.gpa, .{ .children = .empty, .terminal = false }) catch return OOM;
                next = idx;
            }
            cur = next.?;
        }
        self.nodes.items[cur].terminal = true;
    }

    /// True when a stored conflict set is a subset of
    /// `active + {target}` and contains `target` (the skip-known-bad
    /// semantic: re-exploring it cannot succeed).
    fn blocks(self: *const ConflictStore, target: IdKey, active: []const IdKey) bool {
        return self.blocksFrom(0, target, active, false);
    }

    fn blocksFrom(self: *const ConflictStore, node_idx: usize, target: IdKey, active: []const IdKey, mut_seen_target: bool) bool {
        const node = &self.nodes.items[node_idx];
        if (node.terminal and mut_seen_target) return true;
        for (node.children.items) |e| {
            const is_target = idEql(e.key, target);
            if (!is_target and !containsId(active, e.key)) continue;
            if (self.blocksFrom(e.node, target, active, mut_seen_target or is_target)) return true;
        }
        return false;
    }
};

fn containsId(list: []const IdKey, id: IdKey) bool {
    for (list) |e| {
        if (idEql(e, id)) return true;
    }
    return false;
}

// --- candidate computation ---

const CandNode = struct { version: semver.Version, node: SummaryNode };

fn candidatesFor(
    gpa: std.mem.Allocator,
    registry: Registry,
    filter: index.QueryFilter,
    lockctx: ?*LockCtx,
    parent_name: []const u8,
    edge: DepEdge,
) ResolveError![]CandNode {
    const eff = effectiveReq(lockctx, parent_name, edge);
    const summaries = registry.queryFn(registry.ctx, eff.name) catch |e| switch (e) {
        QueryError.FetchFailed => return ResolveError.NoMatchingVersion,
        QueryError.OutOfMemory => return OOM,
    };
    var tmp: std.ArrayList(index.Candidate) = .empty;
    defer tmp.deinit(gpa);
    for (summaries) |s| {
        tmp.append(gpa, .{
            .name = s.candidate.name,
            .version = s.candidate.version,
            .yanked = s.candidate.yanked,
            .checksum = s.candidate.checksum,
            .rust_version = s.candidate.rust_version,
            .pubtime = s.candidate.pubtime,
        }) catch return OOM;
    }
    const sorted = index.queryCandidates(gpa, tmp.items, eff.req, filter) catch |e| switch (e) {
        index.IndexError.OutOfMemory => return OOM,
        // queryCandidates only allocates; parse errors are unreachable here.
        else => unreachable,
    };
    defer gpa.free(sorted);
    var out: std.ArrayList(CandNode) = .empty;
    errdefer out.deinit(gpa);
    for (sorted) |c| {
        for (summaries) |s| {
            if (s.candidate.version.eql(c.version)) {
                out.append(gpa, .{ .version = c.version, .node = s }) catch return OOM;
                break;
            }
        }
    }
    return out.toOwnedSlice(gpa) catch return OOM;
}

// --- main DFS ---

fn activeKeys(gpa: std.mem.Allocator, state: *const State) ResolveError![]IdKey {
    var out: std.ArrayList(IdKey) = .empty;
    errdefer out.deinit(gpa);
    for (state.actives.items) |a| {
        out.append(gpa, .{ .name = a.name, .version = a.version }) catch return OOM;
    }
    const slice = out.toOwnedSlice(gpa) catch return OOM;
    std.mem.sort(IdKey, slice, {}, struct {
        fn lt(_: void, x: IdKey, y: IdKey) bool {
            return idLess(x, y);
        }
    }.lt);
    return slice;
}

/// Pick the pending edge with the fewest viable candidates
/// (`RemainingDeps::pop_most_constrained` fail-fast heuristic); ties broken
/// by dep name, then parent name, then insertion order for determinism.
fn pickMostConstrained(
    gpa: std.mem.Allocator,
    registry: Registry,
    filter: index.QueryFilter,
    lockctx: ?*LockCtx,
    state: *const State,
) ResolveError!struct { index: usize, candidates: []CandNode } {
    var best_idx: usize = 0;
    var best_cands: []CandNode = &.{};
    var best_count: usize = std.math.maxInt(usize);
    var best_name: []const u8 = "";
    var best_parent: []const u8 = "";
    var best_seq: usize = std.math.maxInt(usize);
    var have_best = false;
    errdefer if (have_best) gpa.free(best_cands);
    for (state.pending.items, 0..) |*p, i| {
        const cands = try candidatesFor(gpa, registry, filter, lockctx, state.actives.items[p.parent_idx].name, p.edge);
        const better = !have_best or cands.len < best_count or
            (cands.len == best_count and lessPendingKey(p.edge.name, state.actives.items[p.parent_idx].name, p.seq, best_name, best_parent, best_seq));
        if (better) {
            if (have_best) gpa.free(best_cands);
            best_idx = i;
            best_cands = cands;
            best_count = cands.len;
            best_name = p.edge.name;
            best_parent = state.actives.items[p.parent_idx].name;
            best_seq = p.seq;
            have_best = true;
        } else {
            gpa.free(cands);
        }
    }
    std.debug.assert(have_best);
    return .{ .index = best_idx, .candidates = best_cands };
}

fn lessPendingKey(aname: []const u8, aparent: []const u8, aseq: usize, bname: []const u8, bparent: []const u8, bseq: usize) bool {
    switch (std.mem.order(u8, aname, bname)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    switch (std.mem.order(u8, aparent, bparent)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    return aseq < bseq;
}

var dbg_n: usize = 0;
fn dbgEv(comptime fmt: []const u8, args: anytype) void {
    if (dbg_n >= 40) return;
    dbg_n += 1;
    std.debug.print(fmt, args);
}
fn findActive(name: []const u8, version: semver.Version, source: sources.SourceId, state: *const State) ?usize {
    for (state.actives.items, 0..) |*a, i| {
        if (std.mem.eql(u8, a.name, name) and sourceEql(a.source, source) and a.version.eql(version)) return i;
    }
    return null;
}

fn resolveRec(
    gpa: std.mem.Allocator,
    registry: Registry,
    filter: index.QueryFilter,
    lockctx: ?*LockCtx,
    state: *State,
    cstore: *ConflictStore,
) ResolveError!void {
    if (state.pending.items.len == 0) {
        try checkCycles(gpa, state);
        try checkDuplicates(state);
        return;
    }
    const pick = try pickMostConstrained(gpa, registry, filter, lockctx, state);
    defer gpa.free(pick.candidates);
    const frame = state.pending.items[pick.index];
    const parent_name = state.actives.items[frame.parent_idx].name;

    const keys = try activeKeys(gpa, state);
    defer gpa.free(keys);

    // (no per-frame links flag: the sticky `state.links_conflict_seen`
    // drives the Conflict vs NoMatchingVersion split globally.)
    if (pick.candidates.len == 0) {
        // Zero viable candidates: nothing to record (no candidate version
        // exists to key a conflict on); fail with the sticky kind.
        dbgEv("STUCK0 {s}->{s}\n", .{ parent_name, frame.edge.name });
        return if (state.links_conflict_seen) ResolveError.Conflict else ResolveError.NoMatchingVersion;
    }

    for (pick.candidates) |cand| {
        const target = IdKey{ .name = frame.edge.name, .version = cand.version };
        if (cstore.blocks(target, keys)) continue;

        // eql-active (same name+version+source): edge already satisfied.
        // The source is provider-tagged on the summary (path for workspace
        // members / path deps, registry default for index entries): a member
        // edge carries the real path source and hits its path root, so
        // members activate exactly once (cargo's `ActivationsKey` is
        // (name, version, source)). The registry placeholder applies only
        // to genuine external registry deps.
        const src: sources.SourceId = cand.node.source;
        if (findActive(frame.edge.name, cand.version, src, state)) |idx| {
            var snap = try takeSnapshot(gpa, state);
            _ = state.pending.swapRemove(pick.index);
            state.resolutions.append(gpa, .{ .parent = frame.parent_idx, .child = idx }) catch return OOM;
            if (resolveRec(gpa, registry, filter, lockctx, state, cstore)) {
                snap.deinit(gpa);
                return;
            } else |err| {
                if (err == ResolveError.NoMatchingVersion or err == ResolveError.Conflict) {
                    try restoreSnapshot(gpa, state, &snap);
                    continue;
                } else return err;
            }
        }

        // semver-compatible-but-unequal active: skip (Semver reason).
        var semver_clash = false;
        for (state.actives.items) |*a| {
            if (std.mem.eql(u8, a.name, frame.edge.name) and
                sourceEql(a.source, src) and
                compatEql(compatClass(a.version), compatClass(cand.version)) and
                !a.version.eql(cand.version))
            {
                semver_clash = true;
                break;
            }
        }
        if (semver_clash) continue;

        // links held by another package: skip (Links reason -- sticky).
        if (cand.node.links) |l| {
            if (state.links.get(l)) |holder| {
                const h = state.actives.items[holder];
                if (!(std.mem.eql(u8, h.name, frame.edge.name) and h.version.eql(cand.version))) {
                    state.links_conflict_seen = true;
                    continue;
                }
            }
        }

        // Activate: snapshot, link, enqueue deps, recurse.
        var snap = try takeSnapshot(gpa, state);
        _ = state.pending.swapRemove(pick.index);
        const child_idx = state.actives.items.len;
        state.actives.append(gpa, .{
            .name = frame.edge.name,
            .version = cand.version,
            .node = cand.node,
            .source = src,
            .is_root = false,
            .age = state.next_age,
        }) catch return OOM;
        state.next_age += 1;
        if (cand.node.links) |l| {
            state.links.put(l, child_idx) catch return OOM;
        }
        state.resolutions.append(gpa, .{ .parent = frame.parent_idx, .child = child_idx }) catch return OOM;
        for (cand.node.deps) |dep| {
            if (dep.optional) continue; // Task 5 enables these via unifyV1
            state.pending.append(gpa, .{ .parent_idx = child_idx, .edge = dep, .seq = state.next_seq }) catch return OOM;
            state.next_seq += 1;
        }
        _ = parent_name;
        if (resolveRec(gpa, registry, filter, lockctx, state, cstore)) {
            snap.deinit(gpa);
            return;
        } else |err| {
            if (err == ResolveError.NoMatchingVersion or err == ResolveError.Conflict) {
                try restoreSnapshot(gpa, state, &snap);
                continue;
            } else return err;
        }
    }

    // Exhausted: record the conflict set (active keys + failed dep) so future
    // frames skip this known-bad combination (conflict_cache.rs semantic).
    dbgEv("STUCKN {s}->{s} nc={d}\n", .{ parent_name, frame.edge.name, pick.candidates.len });
    {
        var ids: std.ArrayList(IdKey) = .empty;
        defer ids.deinit(gpa);
        ids.appendSlice(gpa, keys) catch return OOM;
        ids.append(gpa, .{ .name = frame.edge.name, .version = frameVersion(pick.candidates) }) catch return OOM;
        const slice = ids.toOwnedSlice(gpa) catch return OOM;
        defer gpa.free(slice);
        std.mem.sort(IdKey, slice, {}, struct {
            fn lt(_: void, x: IdKey, y: IdKey) bool {
                return idLess(x, y);
            }
        }.lt);
        try cstore.insert(slice);
    }
    return if (state.links_conflict_seen) ResolveError.Conflict else ResolveError.NoMatchingVersion;
}

/// Representative version for a failed dep frame (first candidate tried).
fn frameVersion(cands: []const CandNode) semver.Version {
    std.debug.assert(cands.len > 0);
    return cands[0].version;
}

/// Post-success cycle check (`resolve.rs::check_cycles`): DFS from roots
/// over recorded parent->child resolutions; a back edge is `Cycle`.
/// (Cargo runs this after the fixpoint, never backtracked -- a cycle is
/// fatal, so `Cycle` propagates through candidate loops unretried.)
fn checkCycles(gpa: std.mem.Allocator, state: *const State) ResolveError!void {
    const n = state.actives.items.len;
    const colors = gpa.alloc(u8, n) catch return OOM;
    defer gpa.free(colors);
    @memset(colors, 0);
    // Iterative DFS from every root over resolution edges.
    var stack: std.ArrayList(struct { idx: usize, next: usize }) = .empty;
    defer stack.deinit(gpa);
    for (state.actives.items, 0..) |*a, i| {
        if (!a.is_root or colors[i] != 0) continue;
        colors[i] = 1;
        stack.append(gpa, .{ .idx = i, .next = 0 }) catch return OOM;
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            var advanced = false;
            while (top.next < state.resolutions.items.len) : (top.next += 1) {
                const r = state.resolutions.items[top.next];
                if (r.parent != top.idx) continue;
                top.next += 1;
                if (colors[r.child] == 1) return ResolveError.Cycle;
                if (colors[r.child] == 0) {
                    colors[r.child] = 1;
                    stack.append(gpa, .{ .idx = r.child, .next = 0 }) catch return OOM;
                    advanced = true;
                    break;
                }
            }
            if (!advanced) {
                colors[top.idx] = 2;
                _ = stack.pop();
            }
        }
    }
}

fn checkDuplicates(state: *const State) ResolveError!void {
    const items = state.actives.items;
    for (items, 0..) |*a, i| {
        for (items[0..i]) |*b| {
            if (std.mem.eql(u8, a.name, b.name) and
                a.version.eql(b.version) and
                sourceEql(a.source, b.source)) return ResolveError.Conflict;
        }
    }
}

fn buildGraph(gpa: std.mem.Allocator, state: *const State) ResolveError!ResolveGraph {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    const nodes = alloc.alloc(ResolvedNode, state.actives.items.len) catch return OOM;
    // Group child refs per parent (resolution order = deterministic).
    var counts = alloc.alloc(usize, state.actives.items.len) catch return OOM;
    @memset(counts, 0);
    for (state.resolutions.items) |r| counts[r.parent] += 1;
    for (state.actives.items, 0..) |*a, i| {
        const refs = alloc.alloc(ResolvedRef, counts[i]) catch return OOM;
        var k: usize = 0;
        for (state.resolutions.items) |r| {
            if (r.parent != i) continue;
            const c = state.actives.items[r.child];
            // Unique-neighbor rendering (`Graph<PackageId, HashSet<Dependency>>`
            // + `encodable_package_id`: one pending edge per dep kind can
            // resolve to the same node -- e.g. a member's normal+dev edges
            // to one crate -- but the lock renders ONE edge). Stable: first
            // occurrence wins (the writer sorts edges anyway).
            var dup = false;
            for (refs[0..k]) |*prev| {
                if (std.mem.eql(u8, prev.name, c.name) and prev.version.eql(c.version) and sourceEql(prev.source, c.source)) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            refs[k] = .{ .name = c.name, .version = c.version, .source = c.source };
            k += 1;
        }
        nodes[i] = .{ .name = a.name, .version = a.version, .source = a.source, .deps = refs[0..k] };
    }
    return ResolveGraph{ .arena = arena, .nodes = nodes };
}

fn resolveInner(
    gpa: std.mem.Allocator,
    roots: []const SummaryNode,
    registry: Registry,
    filter: index.QueryFilter,
    lockctx: ?*LockCtx,
) ResolveError!ResolveGraph {
    var state = State{
        .actives = .empty,
        .links = std.StringHashMap(usize).init(gpa),
        .pending = .empty,
        .resolutions = .empty,
        .next_seq = 0,
        .next_age = 0,
        .links_conflict_seen = false,
    };
    defer state.actives.deinit(gpa);
    defer state.links.deinit();
    defer state.pending.deinit(gpa);
    defer state.resolutions.deinit(gpa);
    var cstore = try ConflictStore.init(gpa);
    defer cstore.deinit();

    const root_source: sources.SourceId = .{ .path = "" };
    for (roots) |r| {
        // Roots activate first and are never backtracked past.
        const idx = state.actives.items.len;
        state.actives.append(gpa, .{
            .name = r.name,
            .version = r.candidate.version,
            .node = r,
            .source = root_source,
            .is_root = true,
            .age = state.next_age,
        }) catch return OOM;
        state.next_age += 1;
        if (r.links) |l| {
            const prev = state.links.fetchPut(l, idx) catch return OOM;
            if (prev != null) return ResolveError.Conflict; // duplicate root links
        }
        for (r.deps) |dep| {
            if (dep.optional) continue;
            state.pending.append(gpa, .{ .parent_idx = idx, .edge = dep, .seq = state.next_seq }) catch return OOM;
            state.next_seq += 1;
        }
    }

    try resolveRec(gpa, registry, filter, lockctx, &state, &cstore);
    return try buildGraph(gpa, &state);
}

/// Iterative DFS + `pop_most_constrained` + backtracking core
/// (`mod.rs::activate_deps_loop`): roots activate first (never backtracked
/// past); each step resolves the pending dep with the fewest viable
/// candidates, trying candidates in `queryCandidates` (max-first) order;
/// total exhaustion yields `NoMatchingVersion` (or `Conflict` when
/// links-skips participated); the final graph is cycle-checked (`Cycle`).
pub fn resolveGraph(
    gpa: std.mem.Allocator,
    roots: []const SummaryNode,
    registry: Registry,
    filter: index.QueryFilter,
) ResolveError!ResolveGraph {
    return resolveInner(gpa, roots, registry, filter, null);
}

// --- Task 4: previous-lock guidance ---

pub const PrecisePin = struct { name: []const u8, version: semver.Version }; // `--precise name=version` target

pub const KeepFilter = struct {
    update_names: []const []const u8, // `cargo update -p ...` set; empty = keep everything
    precise: ?PrecisePin = null, // `--precise` pin; null when absent
    pub fn keep(self: KeepFilter, name: []const u8, reverse_deps_of_updated: bool) bool {
        for (self.update_names) |u| {
            if (std.mem.eql(u8, u, name)) return false;
        }
        return !reverse_deps_of_updated;
    }
};

const LockCtx = struct {
    previous: []const ResolvedNode,
    keep: KeepFilter,
    closure: *const std.StringHashMap(void),
    precise_seen: *bool,
};

fn keptBy(ctx: *const LockCtx, name: []const u8) bool {
    return ctx.keep.keep(name, ctx.closure.contains(name));
}

fn unwrapReq(current: semver.OptVersionReq) semver.VersionReq {
    return switch (current) {
        .req => |r| r,
        .any => .{ .comparators = &[_]semver.Comparator{} },
        .locked => |l| l.req,
        .precise => |p| p.req,
    };
}

/// Per-edge requirement rewrite (`register_previous_locks` + `lock_to`):
/// the `--precise` target becomes `Precise{version, original}`; an edge whose
/// parent chain is fully kept and whose previous version still satisfies the
/// original req becomes `Locked{prev, original}` (cargo's `lock_to`,
/// including the matches-first assert, which holds by construction here).
fn effectiveReq(lockctx: ?*LockCtx, parent_name: []const u8, edge: DepEdge) DepEdge {
    const ctx = lockctx orelse return edge;
    if (ctx.keep.precise) |p| {
        if (std.mem.eql(u8, edge.name, p.name)) {
            ctx.precise_seen.* = true;
            return .{
                .name = edge.name,
                .req = .{ .precise = .{ .version = p.version, .req = unwrapReq(edge.req) } },
                .optional = edge.optional,
                .build_only = edge.build_only,
            };
        }
    }
    if (!keptBy(ctx, parent_name) or !keptBy(ctx, edge.name)) return edge;
    const orig = switch (edge.req) {
        .req => |r| r,
        .any => semver.VersionReq{ .comparators = &[_]semver.Comparator{} },
        .locked, .precise => return edge, // already pinned
    };
    var best: ?semver.Version = null;
    for (ctx.previous) |pn| {
        if (!std.mem.eql(u8, pn.name, edge.name)) continue;
        if (!orig.matches(pn.version)) continue; // stale pins fall out naturally
        if (best == null or best.?.order(pn.version) == .lt) best = pn.version;
    }
    if (best) |bv| {
        return .{
            .name = edge.name,
            .req = .{ .locked = .{ .version = bv, .req = orig } },
            .optional = edge.optional,
            .build_only = edge.build_only,
        };
    }
    return edge;
}

/// Minimal-update resolution (`ops/resolve.rs::resolve_with_previous`):
/// (1) every previous id passing the OUTER `keep()` (update seeds excluded,
/// transitive deps INCLUDED) becomes `preferred`, so unchanged graphs resolve
/// byte-identical and `cargo update -p serde` keeps old `log` when compatible
/// (the serde/log comment in `register_previous_locks`: transitive deps lose
/// LOCKS but stay preferred); (2) fully-kept parent chains (closure-gated
/// `keep`, i.e. update seeds AND their transitive deps excluded) get `Locked`
/// reqs via `effectiveReq`; (3) `--precise` becomes a `Precise` req (errors
/// `NoMatchingVersion` when the pinned version is not a candidate, or when
/// the target names no edge); (4) yanked-rescue: `allow_yanked` = base ++
/// preferred-kept versions ++ precise version (without this a previous lock
/// pinning a now-yanked version could never be rescued).
pub fn resolveWithPrevious(
    gpa: std.mem.Allocator,
    roots: []const SummaryNode,
    lookup: Registry,
    previous: ?[]const ResolvedNode,
    keep: KeepFilter,
    base_filter: index.QueryFilter,
) ResolveError!ResolveGraph {
    const prev = previous orelse &.{};

    // Non-kept closure: update seeds + their transitive deps over previous
    // edges (name-based BFS; lockfiles under 10k packages make O(n^2) fine).
    var closure = std.StringHashMap(void).init(gpa);
    defer closure.deinit();
    var queue: std.ArrayList([]const u8) = .empty;
    defer queue.deinit(gpa);
    for (keep.update_names) |n| {
        if (!closure.contains(n)) {
            closure.put(n, {}) catch return OOM;
            queue.append(gpa, n) catch return OOM;
        }
    }
    if (keep.precise) |p| {
        if (!closure.contains(p.name)) {
            closure.put(p.name, {}) catch return OOM;
            queue.append(gpa, p.name) catch return OOM;
        }
    }
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const cur = queue.items[head];
        for (prev) |pn| {
            if (!std.mem.eql(u8, pn.name, cur)) continue;
            for (pn.deps) |d| {
                if (!closure.contains(d.name)) {
                    closure.put(d.name, {}) catch return OOM;
                    queue.append(gpa, d.name) catch return OOM;
                }
            }
        }
    }

    // Preferences (ordering + yanked rescue) use the OUTER keep only:
    // update seeds excluded, transitive deps INCLUDED (cargo's
    // `for id in r.iter().filter(keep) prefer_package_id(id)` in
    // `resolve_with_previous`, where `keep` does NOT know about the
    // `avoid_locking` set computed inside `register_previous_locks`).
    // LOCKS (`effectiveReq` via `keptBy`) stay closure-gated below.
    var preferred_kept: std.ArrayList(index.PreferredId) = .empty;
    defer preferred_kept.deinit(gpa);
    var allow_kept: std.ArrayList(semver.Version) = .empty;
    defer allow_kept.deinit(gpa);
    for (prev) |pn| {
        if (keep.keep(pn.name, false)) {
            preferred_kept.append(gpa, .{ .name = pn.name, .version = pn.version }) catch return OOM;
            allow_kept.append(gpa, pn.version) catch return OOM;
        }
    }

    var tmp = std.heap.ArenaAllocator.init(gpa);
    defer tmp.deinit();
    const ta = tmp.allocator();
    const preferred = std.mem.concat(ta, index.PreferredId, &.{ base_filter.preferred, preferred_kept.items }) catch return OOM;
    var allow_parts: std.ArrayList([]const semver.Version) = .empty;
    defer allow_parts.deinit(ta);
    allow_parts.append(ta, base_filter.allow_yanked) catch return OOM;
    allow_parts.append(ta, allow_kept.items) catch return OOM;
    var precise_buf: [1]semver.Version = undefined;
    if (keep.precise) |p| {
        precise_buf[0] = p.version;
        allow_parts.append(ta, &precise_buf) catch return OOM;
    }
    const allow = std.mem.concat(ta, semver.Version, allow_parts.items) catch return OOM;

    const filter = index.QueryFilter{
        .allow_yanked = allow,
        .max_pubtime = base_filter.max_pubtime,
        .min_versions_first = base_filter.min_versions_first,
        .rust_versions = base_filter.rust_versions,
        .preferred = preferred,
    };
    var precise_seen = false;
    var lockctx = LockCtx{ .previous = prev, .keep = keep, .closure = &closure, .precise_seen = &precise_seen };
    var graph = try resolveInner(gpa, roots, lookup, filter, &lockctx);
    if (keep.precise != null and !precise_seen) {
        graph.deinit();
        return ResolveError.NoMatchingVersion;
    }
    return graph;
}

// --- Task 3 tests: activation DFS, backtracking, conflict cache ---
// Local `SummaryNode` tables + a `Registry{ctx, queryFn}` stub switching on
// name; exact `nodes` name@version sets asserted.

test "resolve picks max versions in a diamond" {
    const gpa = std.testing.allocator;
    const req_left = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1") };
    const req_right = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1") };
    const req_shared_lo = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1.0") };
    const req_shared_hi = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1.1") };
    const left_edges_v11 = [_]DepEdge{.{ .name = "shared", .req = req_shared_lo, .optional = false, .build_only = false }};
    const right_edges_v11 = [_]DepEdge{.{ .name = "shared", .req = req_shared_hi, .optional = false, .build_only = false }};
    const left_nodes = [_]SummaryNode{
        .{ .name = "left", .candidate = .{ .name = "left", .version = try semver.Version.parse("1.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &left_edges_v11, .links = null },
    };
    const right_nodes = [_]SummaryNode{
        .{ .name = "right", .candidate = .{ .name = "right", .version = try semver.Version.parse("1.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &right_edges_v11, .links = null },
    };
    const shared_nodes = [_]SummaryNode{
        .{ .name = "shared", .candidate = .{ .name = "shared", .version = try semver.Version.parse("1.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &.{}, .links = null },
        .{ .name = "shared", .candidate = .{ .name = "shared", .version = try semver.Version.parse("1.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &.{}, .links = null },
    };
    const Stub = struct {
        left: []const SummaryNode,
        right: []const SummaryNode,
        shared: []const SummaryNode,
        fn query(ctx: *anyopaque, name: []const u8) QueryError![]const SummaryNode {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, name, "left")) return self.left;
            if (std.mem.eql(u8, name, "right")) return self.right;
            if (std.mem.eql(u8, name, "shared")) return self.shared;
            return &.{};
        }
    };
    var stub = Stub{ .left = &left_nodes, .right = &right_nodes, .shared = &shared_nodes };
    const app_edges = [_]DepEdge{
        .{ .name = "left", .req = req_left, .optional = false, .build_only = false },
        .{ .name = "right", .req = req_right, .optional = false, .build_only = false },
    };
    const roots = [_]SummaryNode{
        .{ .name = "app", .candidate = .{ .name = "app", .version = try semver.Version.parse("0.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &app_edges, .links = null },
    };
    const filter = index.QueryFilter{ .allow_yanked = &.{}, .max_pubtime = null, .min_versions_first = false, .rust_versions = &.{}, .preferred = &.{} };
    var graph = try resolveGraph(gpa, &roots, .{ .ctx = @ptrCast(&stub), .queryFn = &Stub.query }, filter);
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 4), graph.nodes.len);
    try std.testing.expect(graph.find("shared", try semver.Version.parse("1.1.0")) != null);
    try std.testing.expect(graph.find("shared", try semver.Version.parse("1.0.0")) == null);
}

test "resolve backtracks when max version conflicts" {
    // PLAN DEVIATION (cargo conformance wins -- see report ambiguity #1):
    // the approved block paired a=1.1's `=2.0.0` edge against b's `^1.0`
    // edge with c versions {1.0.0, 2.0.0} and expected a downgrade to a=1.0
    // with c=2.0.0 gone. That outcome is unsatisfiable under cargo semantics:
    // 1.0.0 and 2.0.0 are semver-INCOMPATIBLE (different
    // `SemverCompatibility` classes), so cargo COEXISTS them and keeps a=1.1
    // (verified against `RemainingCandidates::next` + `ActivationsKey` in
    // references/cargo). A genuine cargo backtrack needs a SAME-track clash,
    // so this test uses c versions {1.0.0, 1.1.0}: a=1.1 pins c=1.0.0
    // exactly, b pins c=1.1.0 exactly, and the resolver must backtrack a to
    // 1.0 (whose `^1.0` edge accepts the activated c=1.1.0).
    const gpa = std.testing.allocator;
    const req_a = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1") };
    const req_b = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1") };
    const req_c_exact10 = semver.OptVersionReq{ .req = try semver.VersionReq.parse("=1.0.0") };
    const req_c_exact11 = semver.OptVersionReq{ .req = try semver.VersionReq.parse("=1.1.0") };
    const req_c_1x = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1.0") };
    const a11_edges = [_]DepEdge{.{ .name = "c", .req = req_c_exact10, .optional = false, .build_only = false }};
    const a10_edges = [_]DepEdge{.{ .name = "c", .req = req_c_1x, .optional = false, .build_only = false }};
    const b10_edges = [_]DepEdge{.{ .name = "c", .req = req_c_exact11, .optional = false, .build_only = false }};
    const a_nodes = [_]SummaryNode{
        .{ .name = "a", .candidate = .{ .name = "a", .version = try semver.Version.parse("1.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &a11_edges, .links = null },
        .{ .name = "a", .candidate = .{ .name = "a", .version = try semver.Version.parse("1.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &a10_edges, .links = null },
    };
    const b_nodes = [_]SummaryNode{
        .{ .name = "b", .candidate = .{ .name = "b", .version = try semver.Version.parse("1.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &b10_edges, .links = null },
    };
    const c_nodes = [_]SummaryNode{
        .{ .name = "c", .candidate = .{ .name = "c", .version = try semver.Version.parse("1.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &.{}, .links = null },
        .{ .name = "c", .candidate = .{ .name = "c", .version = try semver.Version.parse("1.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &.{}, .links = null },
    };
    const Stub = struct {
        a: []const SummaryNode,
        b: []const SummaryNode,
        c: []const SummaryNode,
        fn query(ctx: *anyopaque, name: []const u8) QueryError![]const SummaryNode {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, name, "a")) return self.a;
            if (std.mem.eql(u8, name, "b")) return self.b;
            if (std.mem.eql(u8, name, "c")) return self.c;
            return &.{};
        }
    };
    var stub = Stub{ .a = &a_nodes, .b = &b_nodes, .c = &c_nodes };
    const app_edges = [_]DepEdge{
        .{ .name = "a", .req = req_a, .optional = false, .build_only = false },
        .{ .name = "b", .req = req_b, .optional = false, .build_only = false },
    };
    const roots = [_]SummaryNode{
        .{ .name = "app", .candidate = .{ .name = "app", .version = try semver.Version.parse("0.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &app_edges, .links = null },
    };
    const filter = index.QueryFilter{ .allow_yanked = &.{}, .max_pubtime = null, .min_versions_first = false, .rust_versions = &.{}, .preferred = &.{} };
    var graph = try resolveGraph(gpa, &roots, .{ .ctx = @ptrCast(&stub), .queryFn = &Stub.query }, filter);
    defer graph.deinit();
    try std.testing.expect(graph.find("a", try semver.Version.parse("1.0.0")) != null);
    try std.testing.expect(graph.find("a", try semver.Version.parse("1.1.0")) == null);
    try std.testing.expect(graph.find("c", try semver.Version.parse("1.1.0")) != null);
    try std.testing.expect(graph.find("c", try semver.Version.parse("1.0.0")) == null);
}

test "resolve allows semver-incompatible coexistence" {
    const gpa = std.testing.allocator;
    const req_old = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1") };
    const req_new = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^2") };
    const req_u1 = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1") };
    const req_u2 = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^2") };
    const old_edges = [_]DepEdge{.{ .name = "util", .req = req_u1, .optional = false, .build_only = false }};
    const new_edges = [_]DepEdge{.{ .name = "util", .req = req_u2, .optional = false, .build_only = false }};
    const old_nodes = [_]SummaryNode{
        .{ .name = "old", .candidate = .{ .name = "old", .version = try semver.Version.parse("1.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &old_edges, .links = null },
    };
    const new_nodes = [_]SummaryNode{
        .{ .name = "new", .candidate = .{ .name = "new", .version = try semver.Version.parse("2.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &new_edges, .links = null },
    };
    const util_nodes = [_]SummaryNode{
        .{ .name = "util", .candidate = .{ .name = "util", .version = try semver.Version.parse("1.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &.{}, .links = null },
        .{ .name = "util", .candidate = .{ .name = "util", .version = try semver.Version.parse("2.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &.{}, .links = null },
    };
    const Stub = struct {
        old: []const SummaryNode,
        new: []const SummaryNode,
        util: []const SummaryNode,
        fn query(ctx: *anyopaque, name: []const u8) QueryError![]const SummaryNode {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, name, "old")) return self.old;
            if (std.mem.eql(u8, name, "new")) return self.new;
            if (std.mem.eql(u8, name, "util")) return self.util;
            return &.{};
        }
    };
    var stub = Stub{ .old = &old_nodes, .new = &new_nodes, .util = &util_nodes };
    const app_edges = [_]DepEdge{
        .{ .name = "old", .req = req_old, .optional = false, .build_only = false },
        .{ .name = "new", .req = req_new, .optional = false, .build_only = false },
    };
    const roots = [_]SummaryNode{
        .{ .name = "app", .candidate = .{ .name = "app", .version = try semver.Version.parse("0.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &app_edges, .links = null },
    };
    const filter = index.QueryFilter{ .allow_yanked = &.{}, .max_pubtime = null, .min_versions_first = false, .rust_versions = &.{}, .preferred = &.{} };
    var graph = try resolveGraph(gpa, &roots, .{ .ctx = @ptrCast(&stub), .queryFn = &Stub.query }, filter);
    defer graph.deinit();
    try std.testing.expect(graph.find("util", try semver.Version.parse("1.0.0")) != null);
    try std.testing.expect(graph.find("util", try semver.Version.parse("2.0.0")) != null);
}

test "resolve rejects duplicate links" {
    const gpa = std.testing.allocator;
    const req_x = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1") };
    const req_y = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1") };
    const x_nodes = [_]SummaryNode{
        .{ .name = "x", .candidate = .{ .name = "x", .version = try semver.Version.parse("1.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &.{}, .links = "z" },
    };
    const y_nodes = [_]SummaryNode{
        .{ .name = "y", .candidate = .{ .name = "y", .version = try semver.Version.parse("1.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &.{}, .links = "z" },
    };
    const Stub = struct {
        x: []const SummaryNode,
        y: []const SummaryNode,
        fn query(ctx: *anyopaque, name: []const u8) QueryError![]const SummaryNode {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, name, "x")) return self.x;
            if (std.mem.eql(u8, name, "y")) return self.y;
            return &.{};
        }
    };
    var stub = Stub{ .x = &x_nodes, .y = &y_nodes };
    const app_edges = [_]DepEdge{
        .{ .name = "x", .req = req_x, .optional = false, .build_only = false },
        .{ .name = "y", .req = req_y, .optional = false, .build_only = false },
    };
    const roots = [_]SummaryNode{
        .{ .name = "app", .candidate = .{ .name = "app", .version = try semver.Version.parse("0.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &app_edges, .links = null },
    };
    const filter = index.QueryFilter{ .allow_yanked = &.{}, .max_pubtime = null, .min_versions_first = false, .rust_versions = &.{}, .preferred = &.{} };
    try std.testing.expectError(ResolveError.Conflict, resolveGraph(gpa, &roots, .{ .ctx = @ptrCast(&stub), .queryFn = &Stub.query }, filter));
}

test "resolve activates workspace path members exactly once with path sources" {
    // Root/edge source-split regression (M4 blocker): before the fix, every
    // non-root activation took the registry placeholder source, so a member
    // that is BOTH a path root and a path-edge target activated twice (once
    // per source) and the oracle had to merge the copies post-hoc. Member
    // summaries carry their real path source (provider-tagged, as
    // `core/resolver` derives `PackageId` sources from the resolving
    // `SourceId`), so member edges hit the path root via `findActive`.
    // Shape mirrors validation/basic-workspace: 3 path members
    // (cli-bin -> core-lib -> util) plus one external registry crate.
    const gpa = std.testing.allocator;
    const path_src: sources.SourceId = .{ .path = "" };
    const req_any = semver.OptVersionReq{ .any = {} };
    const bin_edges = [_]DepEdge{
        .{ .name = "core-lib", .req = req_any, .optional = false, .build_only = false },
        .{ .name = "ext", .req = req_any, .optional = false, .build_only = false },
    };
    const lib_edges = [_]DepEdge{
        .{ .name = "util", .req = req_any, .optional = false, .build_only = false },
    };
    const no_edges = [_]DepEdge{};
    const bin_nodes = [_]SummaryNode{
        .{ .name = "cli-bin", .candidate = .{ .name = "cli-bin", .version = try semver.Version.parse("0.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &bin_edges, .links = null, .source = path_src },
    };
    const lib_nodes = [_]SummaryNode{
        .{ .name = "core-lib", .candidate = .{ .name = "core-lib", .version = try semver.Version.parse("0.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &lib_edges, .links = null, .source = path_src },
    };
    const util_nodes = [_]SummaryNode{
        .{ .name = "util", .candidate = .{ .name = "util", .version = try semver.Version.parse("0.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &no_edges, .links = null, .source = path_src },
    };
    const ext_nodes = [_]SummaryNode{
        .{ .name = "ext", .candidate = .{ .name = "ext", .version = try semver.Version.parse("1.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &.{}, .links = null },
    };
    const Stub = struct {
        bin: []const SummaryNode,
        lib: []const SummaryNode,
        util: []const SummaryNode,
        ext: []const SummaryNode,
        fn query(ctx: *anyopaque, name: []const u8) QueryError![]const SummaryNode {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, name, "cli-bin")) return self.bin;
            if (std.mem.eql(u8, name, "core-lib")) return self.lib;
            if (std.mem.eql(u8, name, "util")) return self.util;
            if (std.mem.eql(u8, name, "ext")) return self.ext;
            return &.{};
        }
    };
    var stub = Stub{ .bin = &bin_nodes, .lib = &lib_nodes, .util = &util_nodes, .ext = &ext_nodes };
    const roots = [_]SummaryNode{ bin_nodes[0], lib_nodes[0], util_nodes[0] };
    const filter = index.QueryFilter{ .allow_yanked = &.{}, .max_pubtime = null, .min_versions_first = false, .rust_versions = &.{}, .preferred = &.{} };
    var graph = try resolveGraph(gpa, &roots, .{ .ctx = @ptrCast(&stub), .queryFn = &Stub.query }, filter);
    defer graph.deinit();
    // Exactly one node per member plus the external crate: no duplicate
    // activation via a registry-placeholder edge copy.
    try std.testing.expectEqual(@as(usize, 4), graph.nodes.len);
    for ([_]struct { name: []const u8, path: bool }{
        .{ .name = "cli-bin", .path = true },
        .{ .name = "core-lib", .path = true },
        .{ .name = "util", .path = true },
        .{ .name = "ext", .path = false },
    }) |want| {
        var hits: usize = 0;
        for (graph.nodes) |n| {
            if (!std.mem.eql(u8, n.name, want.name)) continue;
            hits += 1;
            if (want.path) {
                try std.testing.expect(n.source == .path);
            } else {
                try std.testing.expect(n.source == .registry);
            }
        }
        try std.testing.expectEqual(@as(usize, 1), hits);
    }
    // Member edges carry the real path source (no registry placeholder).
    const bin = graph.find("cli-bin", try semver.Version.parse("0.1.0")).?;
    var saw_lib = false;
    for (bin.deps) |r| {
        if (std.mem.eql(u8, r.name, "core-lib")) {
            saw_lib = true;
            try std.testing.expect(r.source == .path);
        }
    }
    try std.testing.expect(saw_lib);
    const lib = graph.find("core-lib", try semver.Version.parse("0.1.0")).?;
    var saw_util = false;
    for (lib.deps) |r| {
        if (std.mem.eql(u8, r.name, "util")) {
            saw_util = true;
            try std.testing.expect(r.source == .path);
        }
    }
    try std.testing.expect(saw_util);
}

test "resolve errors when nothing satisfies" {
    const gpa = std.testing.allocator;
    // app -> a ^1 (only 1.0 exists, needs b ^2); b only has 1.0 -> NoMatchingVersion naming "b".
    const req_a = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1") };
    const req_b2 = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^2") };
    const a_edges = [_]DepEdge{.{ .name = "b", .req = req_b2, .optional = false, .build_only = false }};
    const a_nodes = [_]SummaryNode{
        .{ .name = "a", .candidate = .{ .name = "a", .version = try semver.Version.parse("1.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &a_edges, .links = null },
    };
    const b_nodes = [_]SummaryNode{
        .{ .name = "b", .candidate = .{ .name = "b", .version = try semver.Version.parse("1.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &.{}, .links = null },
    };
    const Stub = struct {
        a: []const SummaryNode,
        b: []const SummaryNode,
        fn query(ctx: *anyopaque, name: []const u8) QueryError![]const SummaryNode {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, name, "a")) return self.a;
            if (std.mem.eql(u8, name, "b")) return self.b;
            return &.{};
        }
    };
    var stub = Stub{ .a = &a_nodes, .b = &b_nodes };
    const app_edges = [_]DepEdge{
        .{ .name = "a", .req = req_a, .optional = false, .build_only = false },
    };
    const roots = [_]SummaryNode{
        .{ .name = "app", .candidate = .{ .name = "app", .version = try semver.Version.parse("0.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &app_edges, .links = null },
    };
    const filter = index.QueryFilter{ .allow_yanked = &.{}, .max_pubtime = null, .min_versions_first = false, .rust_versions = &.{}, .preferred = &.{} };
    const registry = Registry{ .ctx = @ptrCast(&stub), .queryFn = &Stub.query };
    try std.testing.expectError(ResolveError.NoMatchingVersion, resolveGraph(gpa, &roots, registry, filter));
}

test "resolve skips optional edges until features wire them" {
    // Task 5 owns optional-dep enablement; Task 3 records no optional edges.
    const gpa = std.testing.allocator;
    const req = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1") };
    const opt_edges = [_]DepEdge{.{ .name = "opt", .req = req, .optional = true, .build_only = false }};
    const a_nodes = [_]SummaryNode{
        .{ .name = "a", .candidate = .{ .name = "a", .version = try semver.Version.parse("1.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &opt_edges, .links = null },
    };
    const Stub = struct {
        a: []const SummaryNode,
        fn query(ctx: *anyopaque, name: []const u8) QueryError![]const SummaryNode {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, name, "a")) return self.a;
            return &.{};
        }
    };
    var stub = Stub{ .a = &a_nodes };
    const app_edges = [_]DepEdge{.{ .name = "a", .req = req, .optional = false, .build_only = false }};
    const roots = [_]SummaryNode{
        .{ .name = "app", .candidate = .{ .name = "app", .version = try semver.Version.parse("0.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &app_edges, .links = null },
    };
    const filter = index.QueryFilter{ .allow_yanked = &.{}, .max_pubtime = null, .min_versions_first = false, .rust_versions = &.{}, .preferred = &.{} };
    var graph = try resolveGraph(gpa, &roots, .{ .ctx = @ptrCast(&stub), .queryFn = &Stub.query }, filter);
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 2), graph.nodes.len);
    try std.testing.expect(graph.find("opt", try semver.Version.parse("1.0.0")) == null);
}

// --- Task 4 tests: previous-lock guidance + minimal-update semantics ---

test "resolve keeps previous versions when still valid" {
    const gpa = std.testing.allocator;
    // previous: shared=1.1; index now also has shared=1.2; req ^1.0 -> still 1.1 (preferred beats max).
    const req = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1.0") };
    const shared_edges = [_]DepEdge{};
    const shared_nodes = [_]SummaryNode{
        .{ .name = "shared", .candidate = .{ .name = "shared", .version = try semver.Version.parse("1.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &shared_edges, .links = null },
        .{ .name = "shared", .candidate = .{ .name = "shared", .version = try semver.Version.parse("1.2.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &shared_edges, .links = null },
    };
    const Stub = struct {
        shared: []const SummaryNode,
        fn query(ctx: *anyopaque, name: []const u8) QueryError![]const SummaryNode {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, name, "shared")) return self.shared;
            return &.{};
        }
    };
    var stub = Stub{ .shared = &shared_nodes };
    const registry = Registry{ .ctx = @ptrCast(&stub), .queryFn = &Stub.query };
    const app_edges = [_]DepEdge{.{ .name = "shared", .req = req, .optional = false, .build_only = false }};
    const roots = [_]SummaryNode{
        .{ .name = "app", .candidate = .{ .name = "app", .version = try semver.Version.parse("0.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &app_edges, .links = null },
    };
    const prev_refs = [_]ResolvedRef{};
    const previous = [_]ResolvedNode{
        .{ .name = "shared", .version = try semver.Version.parse("1.1.0"), .source = .{ .registry = "sparse+https://github.com/rust-lang/crates.io-index" }, .deps = &prev_refs },
    };
    const base = index.QueryFilter{ .allow_yanked = &.{}, .max_pubtime = null, .min_versions_first = false, .rust_versions = &.{}, .preferred = &.{} };
    var graph = try resolveWithPrevious(gpa, &roots, registry, &previous, .{ .update_names = &.{} }, base);
    defer graph.deinit();
    try std.testing.expect(graph.find("shared", try semver.Version.parse("1.1.0")) != null);
    try std.testing.expect(graph.find("shared", try semver.Version.parse("1.2.0")) == null);
}

test "resolve drops previous version outside new req" {
    const gpa = std.testing.allocator;
    // previous: shared=1.1; manifest req tightened to ^1.2 -> 1.2.0 (previous no longer matches, no assert trip).
    const req = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1.2") };
    const shared_edges = [_]DepEdge{};
    const shared_nodes = [_]SummaryNode{
        .{ .name = "shared", .candidate = .{ .name = "shared", .version = try semver.Version.parse("1.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &shared_edges, .links = null },
        .{ .name = "shared", .candidate = .{ .name = "shared", .version = try semver.Version.parse("1.2.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &shared_edges, .links = null },
    };
    const Stub = struct {
        shared: []const SummaryNode,
        fn query(ctx: *anyopaque, name: []const u8) QueryError![]const SummaryNode {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, name, "shared")) return self.shared;
            return &.{};
        }
    };
    var stub = Stub{ .shared = &shared_nodes };
    const registry = Registry{ .ctx = @ptrCast(&stub), .queryFn = &Stub.query };
    const app_edges = [_]DepEdge{.{ .name = "shared", .req = req, .optional = false, .build_only = false }};
    const roots = [_]SummaryNode{
        .{ .name = "app", .candidate = .{ .name = "app", .version = try semver.Version.parse("0.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &app_edges, .links = null },
    };
    const prev_refs = [_]ResolvedRef{};
    const previous = [_]ResolvedNode{
        .{ .name = "shared", .version = try semver.Version.parse("1.1.0"), .source = .{ .registry = "sparse+https://github.com/rust-lang/crates.io-index" }, .deps = &prev_refs },
    };
    const base = index.QueryFilter{ .allow_yanked = &.{}, .max_pubtime = null, .min_versions_first = false, .rust_versions = &.{}, .preferred = &.{} };
    var graph = try resolveWithPrevious(gpa, &roots, registry, &previous, .{ .update_names = &.{} }, base);
    defer graph.deinit();
    try std.testing.expect(graph.find("shared", try semver.Version.parse("1.2.0")) != null);
}

test "cargo update -p unlocks target plus transitive deps of non-kept" {
    const gpa = std.testing.allocator;
    // update_names = ["serde"]; previous serde=1.0+log=1.0; index adds serde=2.0 (needs log ^2.0).
    // -> serde=2.0, log=2.0 (log unlocked as transitive dep of non-kept serde, re-resolved fresh).
    // PLAN DEVIATION (ambiguity #2, see report): the approved block used req
    // `^1` for the root serde edge, which can NEVER select serde 2.0.0 under
    // cargo semantics (manifest reqs are hard constraints, even for
    // `cargo update -p`). The test's stated intent -- a newer serde pulling
    // a newer log -- requires the manifest to admit serde 2.x, so the root
    // edge uses `*`. The unlock path is still genuinely exercised: if log
    // were wrongly kept+locked at 1.0.0, serde 2.0's `log ^2.0` edge would
    // fail and serde would fall back to 1.0.0.
    const req_serde = semver.OptVersionReq{ .any = {} };
    const req_log1 = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1.0") };
    const req_log2 = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^2.0") };
    const serde1_edges = [_]DepEdge{.{ .name = "log", .req = req_log1, .optional = false, .build_only = false }};
    const serde2_edges = [_]DepEdge{.{ .name = "log", .req = req_log2, .optional = false, .build_only = false }};
    const serde_nodes = [_]SummaryNode{
        .{ .name = "serde", .candidate = .{ .name = "serde", .version = try semver.Version.parse("1.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &serde1_edges, .links = null },
        .{ .name = "serde", .candidate = .{ .name = "serde", .version = try semver.Version.parse("2.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &serde2_edges, .links = null },
    };
    const log_nodes = [_]SummaryNode{
        .{ .name = "log", .candidate = .{ .name = "log", .version = try semver.Version.parse("1.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &.{}, .links = null },
        .{ .name = "log", .candidate = .{ .name = "log", .version = try semver.Version.parse("2.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &.{}, .links = null },
    };
    const Stub = struct {
        serde: []const SummaryNode,
        log: []const SummaryNode,
        fn query(ctx: *anyopaque, name: []const u8) QueryError![]const SummaryNode {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, name, "serde")) return self.serde;
            if (std.mem.eql(u8, name, "log")) return self.log;
            return &.{};
        }
    };
    var stub = Stub{ .serde = &serde_nodes, .log = &log_nodes };
    const registry = Registry{ .ctx = @ptrCast(&stub), .queryFn = &Stub.query };
    const app_edges = [_]DepEdge{.{ .name = "serde", .req = req_serde, .optional = false, .build_only = false }};
    const roots = [_]SummaryNode{
        .{ .name = "app", .candidate = .{ .name = "app", .version = try semver.Version.parse("0.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &app_edges, .links = null },
    };
    const reg: sources.SourceId = .{ .registry = "sparse+https://github.com/rust-lang/crates.io-index" };
    const serde_prev_deps = [_]ResolvedRef{.{ .name = "log", .version = try semver.Version.parse("1.0.0"), .source = reg }};
    const previous = [_]ResolvedNode{
        .{ .name = "serde", .version = try semver.Version.parse("1.0.0"), .source = reg, .deps = &serde_prev_deps },
        .{ .name = "log", .version = try semver.Version.parse("1.0.0"), .source = reg, .deps = &.{} },
    };
    const base = index.QueryFilter{ .allow_yanked = &.{}, .max_pubtime = null, .min_versions_first = false, .rust_versions = &.{}, .preferred = &.{} };
    const names = [_][]const u8{"serde"};
    var graph = try resolveWithPrevious(gpa, &roots, registry, &previous, .{ .update_names = &names }, base);
    defer graph.deinit();
    try std.testing.expect(graph.find("serde", try semver.Version.parse("2.0.0")) != null);
    try std.testing.expect(graph.find("log", try semver.Version.parse("2.0.0")) != null);
}

test "cargo update -p keeps transitive dep preferred when compatible" {
    // Companion to the unlock test above (ops/resolve.rs serde/log comment):
    // when the newer `serde 2.0` still accepts `log ^1.0`, the old `log 1.0`
    // stays PREFERRED (transitive deps lose LOCKS but keep preference), so
    // the resolver keeps `log 1.0` instead of jumping to `log 2.0`.
    const gpa = std.testing.allocator;
    const req_serde = semver.OptVersionReq{ .any = {} };
    const req_log1 = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1.0") };
    const serde1_edges = [_]DepEdge{.{ .name = "log", .req = req_log1, .optional = false, .build_only = false }};
    const serde2_edges = [_]DepEdge{.{ .name = "log", .req = req_log1, .optional = false, .build_only = false }};
    const serde_nodes = [_]SummaryNode{
        .{ .name = "serde", .candidate = .{ .name = "serde", .version = try semver.Version.parse("1.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &serde1_edges, .links = null },
        .{ .name = "serde", .candidate = .{ .name = "serde", .version = try semver.Version.parse("2.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &serde2_edges, .links = null },
    };
    const log_nodes = [_]SummaryNode{
        .{ .name = "log", .candidate = .{ .name = "log", .version = try semver.Version.parse("1.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &.{}, .links = null },
        .{ .name = "log", .candidate = .{ .name = "log", .version = try semver.Version.parse("2.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &.{}, .links = null },
    };
    const Stub = struct {
        serde: []const SummaryNode,
        log: []const SummaryNode,
        fn query(ctx: *anyopaque, name: []const u8) QueryError![]const SummaryNode {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, name, "serde")) return self.serde;
            if (std.mem.eql(u8, name, "log")) return self.log;
            return &.{};
        }
    };
    var stub = Stub{ .serde = &serde_nodes, .log = &log_nodes };
    const registry = Registry{ .ctx = @ptrCast(&stub), .queryFn = &Stub.query };
    const app_edges = [_]DepEdge{.{ .name = "serde", .req = req_serde, .optional = false, .build_only = false }};
    const roots = [_]SummaryNode{
        .{ .name = "app", .candidate = .{ .name = "app", .version = try semver.Version.parse("0.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &app_edges, .links = null },
    };
    const reg: sources.SourceId = .{ .registry = "sparse+https://github.com/rust-lang/crates.io-index" };
    const serde_prev_deps = [_]ResolvedRef{.{ .name = "log", .version = try semver.Version.parse("1.0.0"), .source = reg }};
    const previous = [_]ResolvedNode{
        .{ .name = "serde", .version = try semver.Version.parse("1.0.0"), .source = reg, .deps = &serde_prev_deps },
        .{ .name = "log", .version = try semver.Version.parse("1.0.0"), .source = reg, .deps = &.{} },
    };
    const base = index.QueryFilter{ .allow_yanked = &.{}, .max_pubtime = null, .min_versions_first = false, .rust_versions = &.{}, .preferred = &.{} };
    const names = [_][]const u8{"serde"};
    var graph = try resolveWithPrevious(gpa, &roots, registry, &previous, .{ .update_names = &names }, base);
    defer graph.deinit();
    try std.testing.expect(graph.find("serde", try semver.Version.parse("2.0.0")) != null);
    try std.testing.expect(graph.find("log", try semver.Version.parse("1.0.0")) != null);
    try std.testing.expect(graph.find("log", try semver.Version.parse("2.0.0")) == null);
}

test "precise pins exact version or errors" {
    const gpa = std.testing.allocator;
    // precise log=1.0.5 with candidates {1.0.5, 1.0.9} and req ^1.0.0 -> 1.0.5; precise log=9.9.9 -> NoMatchingVersion.
    const req = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1.0.0") };
    const log_nodes = [_]SummaryNode{
        .{ .name = "log", .candidate = .{ .name = "log", .version = try semver.Version.parse("1.0.5"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &.{}, .links = null },
        .{ .name = "log", .candidate = .{ .name = "log", .version = try semver.Version.parse("1.0.9"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &.{}, .links = null },
    };
    const Stub = struct {
        log: []const SummaryNode,
        fn query(ctx: *anyopaque, name: []const u8) QueryError![]const SummaryNode {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, name, "log")) return self.log;
            return &.{};
        }
    };
    var stub = Stub{ .log = &log_nodes };
    const registry = Registry{ .ctx = @ptrCast(&stub), .queryFn = &Stub.query };
    const app_edges = [_]DepEdge{.{ .name = "log", .req = req, .optional = false, .build_only = false }};
    const roots = [_]SummaryNode{
        .{ .name = "app", .candidate = .{ .name = "app", .version = try semver.Version.parse("0.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &app_edges, .links = null },
    };
    const base = index.QueryFilter{ .allow_yanked = &.{}, .max_pubtime = null, .min_versions_first = false, .rust_versions = &.{}, .preferred = &.{} };
    const ok_names = [_][]const u8{"log"};
    var graph = try resolveWithPrevious(gpa, &roots, registry, null, .{ .update_names = &ok_names, .precise = .{ .name = "log", .version = try semver.Version.parse("1.0.5") } }, base);
    defer graph.deinit();
    try std.testing.expect(graph.find("log", try semver.Version.parse("1.0.5")) != null);
    try std.testing.expect(graph.find("log", try semver.Version.parse("1.0.9")) == null);
    try std.testing.expectError(ResolveError.NoMatchingVersion, resolveWithPrevious(gpa, &roots, registry, null, .{ .update_names = &ok_names, .precise = .{ .name = "log", .version = try semver.Version.parse("9.9.9") } }, base));
}

test "yanked-locked rescues pinned yanked via previous lock" {
    // Task-4 rule (6): kept locked versions populate `allow_yanked`, so a
    // previous lock pinning a now-yanked version is rescued (dep_cache.rs
    // Yanked arm via should_prefer).
    const gpa = std.testing.allocator;
    const no_edges = [_]DepEdge{};
    const serde_nodes = [_]SummaryNode{
        .{ .name = "serde", .candidate = .{ .name = "serde", .version = try semver.Version.parse("1.0.200"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &no_edges, .links = null },
        .{ .name = "serde", .candidate = .{ .name = "serde", .version = try semver.Version.parse("1.0.201"), .yanked = true, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &no_edges, .links = null },
    };
    const Stub = struct {
        serde: []const SummaryNode,
        fn query(ctx: *anyopaque, name: []const u8) QueryError![]const SummaryNode {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, name, "serde")) return self.serde;
            return &.{};
        }
    };
    var stub = Stub{ .serde = &serde_nodes };
    const registry = Registry{ .ctx = @ptrCast(&stub), .queryFn = &Stub.query };
    const req = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1.0.0") };
    const app_edges = [_]DepEdge{.{ .name = "serde", .req = req, .optional = false, .build_only = false }};
    const roots = [_]SummaryNode{
        .{ .name = "app", .candidate = .{ .name = "app", .version = try semver.Version.parse("0.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &app_edges, .links = null },
    };
    const reg: sources.SourceId = .{ .registry = "sparse+https://github.com/rust-lang/crates.io-index" };
    const previous = [_]ResolvedNode{
        .{ .name = "serde", .version = try semver.Version.parse("1.0.201"), .source = reg, .deps = &.{} },
    };
    const base = index.QueryFilter{ .allow_yanked = &.{}, .max_pubtime = null, .min_versions_first = false, .rust_versions = &.{}, .preferred = &.{} };
    var graph = try resolveWithPrevious(gpa, &roots, registry, &previous, .{ .update_names = &.{} }, base);
    defer graph.deinit();
    try std.testing.expect(graph.find("serde", try semver.Version.parse("1.0.201")) != null);
}

// --- Task 9: resolve diagnostics (cargo-leading-line-compatible text) ---
//
// Reference pins: `resolver/errors.rs` + `dep_cache.rs::describe_path_in_context`
// (the `failed to select a version for the requirement ... candidate versions
// found ... which ...` chain with the dependency path); the yanked-locked shape
// (names the lock as the source of the pin); the offline-missing shape (names
// the crate + the offline flag as the cause -- NOT `no_matching`, so users learn
// the flag is the cause); `check_duplicate_pkgs_in_lockfile` (duplicate path
// names); `context.rs::is_conflicting` links arm; `check_cycles`.
//
// Only the LEADING line of each shape is conformance-pinned (tests and the
// oracle match on it); the trailing detail lines are rime's rendering of the
// same facts cargo reports (tried versions, dep path). `formatDiag` returns an
// owned slice (caller frees with `gpa.free`). The `--locked` bail text and
// `checkLock` semantic compare live in `cli.zig` (owning worker) and the M4
// driver; they consume this `Diag` carrier, not the reverse.

pub const DiagKind = enum { no_matching, yanked_locked, offline_missing, duplicate_path_name, links_conflict, cycle };

pub const Diag = struct {
    kind: DiagKind,
    package: []const u8,
    req: []const u8, // version req text (no_matching/offline_missing) or locked version (yanked_locked) or links key (links_conflict)
    tried: []const []const u8, // candidate versions seen, for the "candidate versions found" line
    path: []const []const u8, // dep chain root → … → package (describe_path_in_context)
    locked: ?[]const u8 = null, // locked version for the ` (locked to …)` suffix (cargo's OptVersionReq::locked_version: Some only for Locked)
};

fn appendDiagPath(gpa: std.mem.Allocator, out: *std.ArrayList(u8), path: []const []const u8) std.mem.Allocator.Error!void {
    // Cargo's `describe_path_in_context` arrow shape: `app → mid → foo`.
    try out.appendSlice(gpa, "dependency path: ");
    for (path, 0..) |p, i| {
        if (i > 0) try out.appendSlice(gpa, " → ");
        try out.appendSlice(gpa, p);
    }
    try out.appendSlice(gpa, "\n");
}

pub fn formatDiag(gpa: std.mem.Allocator, d: Diag) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    switch (d.kind) {
        .no_matching => {
            // Leading line shape from `resolver/errors.rs::to_resolve_err`
            // (verbatim): "failed to select a version for the requirement
            // `{} = \"{}\"`{}" (package name, version-req Display, plus
            // ` (locked to {v})` when the req is a previous-lock `Locked`
            // pin -- `OptVersionReq::locked_version` in `semver_ext.rs`).
            const head = if (d.locked) |l|
                try std.fmt.allocPrint(gpa, "failed to select a version for the requirement `{s} = \"{s}\" (locked to {s})`\n", .{ d.package, d.req, l })
            else
                try std.fmt.allocPrint(gpa, "failed to select a version for the requirement `{s} = \"{s}\"`\n", .{ d.package, d.req });
            defer gpa.free(head);
            try out.appendSlice(gpa, head);
            if (d.tried.len == 0) {
                try out.appendSlice(gpa, "no candidate versions found\n");
            } else {
                try out.appendSlice(gpa, "candidate versions found: ");
                for (d.tried, 0..) |t, i| {
                    if (i > 0) try out.appendSlice(gpa, ", ");
                    try out.appendSlice(gpa, t);
                }
                try out.appendSlice(gpa, "\n");
            }
        },
        .yanked_locked => {
            const head = try std.fmt.allocPrint(gpa, "package `{s} {s}` is yanked, but was previously selected in the lockfile\n", .{ d.package, d.req });
            defer gpa.free(head);
            try out.appendSlice(gpa, head);
            const help = try std.fmt.allocPrint(gpa, "help: run `cargo update -p {s}` to select a different version\n", .{d.package});
            defer gpa.free(help);
            try out.appendSlice(gpa, help);
        },
        .offline_missing => {
            const head = try std.fmt.allocPrint(gpa, "failed to load source for package `{s} {s}`: network is offline\n", .{ d.package, d.req });
            defer gpa.free(head);
            try out.appendSlice(gpa, head);
            try out.appendSlice(gpa, "help: remove `--offline`/`--frozen` or vendor the package first\n");
        },
        .duplicate_path_name => {
            const head = try std.fmt.allocPrint(gpa, "found multiple path packages named `{s}` which cannot be distinguished in the lockfile\n", .{d.package});
            defer gpa.free(head);
            try out.appendSlice(gpa, head);
        },
        .links_conflict => {
            const head = try std.fmt.allocPrint(gpa, "the native library `{s}` is provided by multiple packages; only one `links` provider is allowed\n", .{d.req});
            defer gpa.free(head);
            try out.appendSlice(gpa, head);
            const tail = try std.fmt.allocPrint(gpa, "package `{s}` conflicts with the already-selected provider\n", .{d.package});
            defer gpa.free(tail);
            try out.appendSlice(gpa, tail);
        },
        .cycle => {
            const head = try std.fmt.allocPrint(gpa, "cyclic package dependency involving package `{s}`\n", .{d.package});
            defer gpa.free(head);
            try out.appendSlice(gpa, head);
        },
    }
    if (d.path.len > 0) try appendDiagPath(gpa, &out, d.path);
    return out.toOwnedSlice(gpa);
}

test "offline missing names the crate" {
    // empty registry seam + offline → DiagKind.offline_missing; formatDiag contains crate name.
    const gpa = std.testing.allocator;
    const msg = try formatDiag(gpa, .{
        .kind = .offline_missing,
        .package = "serde",
        .req = "^1.0.0",
        .tried = &.{},
        .path = &.{ "app", "serde" },
    });
    defer gpa.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "serde") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "offline") != null);
}

test "diag leading line matches cargo shape" {
    const msg = try formatDiag(std.testing.allocator, .{ .kind = .no_matching, .package = "foo", .req = "^9.9", .tried = &.{ "1.0.0", "2.0.0" }, .path = &.{ "app", "foo" } });
    defer std.testing.allocator.free(msg);
    // Cargo shape (`resolver/errors.rs::to_resolve_err`): backticked
    // `name = "req"` plus the optional ` (locked to …)` suffix.
    try std.testing.expect(std.mem.startsWith(u8, msg, "failed to select a version for the requirement `foo = \"^9.9\"`"));
    try std.testing.expect(std.mem.indexOf(u8, msg, "candidate versions found: 1.0.0, 2.0.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "dependency path: app → foo") != null);
}

test "diag locked suffix names the pinned version" {
    const msg = try formatDiag(std.testing.allocator, .{ .kind = .no_matching, .package = "serde", .req = "^1.0", .locked = "1.0.201", .tried = &.{}, .path = &.{ "app", "serde" } });
    defer std.testing.allocator.free(msg);
    try std.testing.expect(std.mem.startsWith(u8, msg, "failed to select a version for the requirement `serde = \"^1.0\" (locked to 1.0.201)`"));
}
