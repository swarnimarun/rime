//! Sparse-index candidate seam + query filter + version preferences
//! (M3 Task 2).
//!
//! Resolution input is crates.io sparse-index metadata EXACTLY as cargo
//! consumes it: one JSON object per line per crate version (`IndexPackage` in
//! `cargo-util-schemas/src/index.rs`). `IndexEntry`/`IndexDep` mirror
//! `IndexPackage`/`RegistryDependency` field-for-field; `Candidate` is the
//! resolver-facing projection.
//!
//! Reference pins (commented at each function):
//! - `dep_cache.rs::RegistryQueryer::query` (yanked/too-new filter: yanked
//!   kept iff in `allow_yanked`, compared build-sensitively; pubtime-newer
//!   than max dropped).
//! - `version_prefs.rs::sort_summaries` (preferred first, then
//!   `msrv_compat_count` descending, then version descending -- or ascending
//!   for `-Zminimal-versions`) and `version_prefs.rs::should_prefer`.
//! - `sources/registry/index/mod.rs::index_package_to_summary` +
//!   `registry_dependency_into_dep` (features2 merge, empty-feature filter,
//!   kind mapping, rename split, `default_true`) and
//!   `cargo-util-schemas/src/index.rs` (wire fields).
//!
//! Ownership: `parseIndexLine` copies every string/slice into an arena owned
//! by the returned entry (`IndexEntry.arena`; freed by `deinit`). `Candidate`
//! values therefore BORROW from their entry -- keep the entry alive while
//! using them. `queryCandidates` returns an owned `[]Candidate` slice whose
//! ELEMENTS still borrow from the input `all` slice (only the slice header is
//! allocated); the caller frees the slice with `gpa.free`.

const std = @import("std");
const semver = @import("semver.zig");

pub const SourceKind = enum { path, registry, git };

pub const Candidate = struct {
    name: []const u8,
    version: semver.Version,
    yanked: bool,
    checksum: ?[]const u8, // null for path/git
    rust_version: ?semver.Version, // index `rust_version` (partial ok)
    pubtime: ?i64, // unix seconds; null when unknown (never filtered)
};

pub const DepKind = enum { normal, build, dev };

pub const IndexDep = struct {
    name: []const u8, // TOML/index key (the RENAME when package != null)
    package: ?[]const u8, // real crate name when renamed; null otherwise
    req: []const u8, // raw req text (parsed to OptVersionReq at query time)
    features: []const []const u8, // empty-string entries already filtered at parse
    optional: bool,
    default_features: bool,
    target: ?[]const u8, // raw target cfg string (parsed by sources.parseCfg)
    kind: DepKind,
    registry: ?[]const u8, // non-default index URL; null = default registry
    public: bool, // RFC 1977 passthrough (default false; no M3 semantics, never errors)
    artifact: ?[]const u8, // carried verbatim (bindeps-deferred, never a parse error)
    bindep_target: ?[]const u8, // raw target for artifact dep; null when absent
    lib: bool, // artifact lib flag (default false)

    /// The name used in resolution/lock/feature keys: the real crate name.
    pub fn realName(self: IndexDep) []const u8 {
        return self.package orelse self.name;
    }
};

pub const FeatureDef = struct { name: []const u8, values: []const []const u8 };

pub const IndexEntry = struct {
    candidate: Candidate,
    links: ?[]const u8,
    schema_v: u32, // `v`, default 1 when absent
    unsupported: bool, // true when schema_v > v_max (v_max = 2 in M3): never selected
    features: []const FeatureDef, // merged features + features2
    deps: []const IndexDep,
    arena: std.heap.ArenaAllocator, // owns ALL strings/slices above

    pub fn deinit(self: *IndexEntry, gpa: std.mem.Allocator) void {
        _ = gpa;
        self.arena.deinit();
    }
};

pub const INDEX_V_MAX: u32 = 2;

/// A preferred previous-lock pin, keyed by (name, version) like cargo's
/// `PackageId` (`version_prefs.rs::should_prefer`: `try_to_use` is a
/// `HashSet<PackageId>`). A bare `Version` is NOT sufficient: unrelated
/// crates often share versions (e.g. `serde 1.1.0` vs `log 1.1.0`), and a
/// bare-version match would wrongly prefer `log 1.1.0` just because `serde
/// 1.1.0` was locked. Comparison is build-sensitive (`eql`), matching the
/// yanked-rescue rule.
pub const PreferredId = struct {
    name: []const u8,
    version: semver.Version,
};

pub const QueryFilter = struct {
    allow_yanked: []const semver.Version, // exact pinned versions usable despite yanked
    max_pubtime: ?i64, // publish_time pre-filter; null = no filter
    min_versions_first: bool, // -Zminimal-versions ordering
    rust_versions: []const semver.Version, // workspace rust versions for msrv-compat count
    // NOTE (plan-Interfaces deviation, cargo-conformant): the M3 plan text
    // pins this field as `[]const semver.Version`, but cargo's
    // `VersionPreferences::try_to_use` is a `HashSet<PackageId>` (name +
    // version + source), and `should_prefer` matches per package id. Bare
    // versions would wrongly prefer UNRELATED crates sharing a version
    // number (e.g. a `serde 1.1.0` lock pin would prefer `log 1.1.0` too) --
    // pinned by the "index preference is scoped to crate name" test below.
    // The plan's Interfaces table needs the same update (`PreferredId`);
    // that doc edit belongs to the plan owner (outside this task's file
    // ownership), recorded here so the code never regresses to match stale
    // text.
    preferred: []const PreferredId, // previous-lock pins tried first (per-PackageId)
};

pub const IndexError = error{ OutOfMemory, UnsupportedIndexField, InvalidIndexLine };
// NOTE: index-side artifact/public data NEVER yields UnsupportedIndexField
// (carried verbatim per the plan section 0.6); the variant is retained for
// genuinely unsupported index surface only.

/// Count of `rust_versions` entries `>= candidate_rv`. A candidate with no
/// `rust_version` counts as fully compatible (`rust_versions.len`), per
/// `version_prefs.rs::msrv_compat_count`.
pub fn msrvCompatCount(candidate_rv: ?semver.Version, rust_versions: []const semver.Version) usize {
    const rv = candidate_rv orelse return rust_versions.len;
    var n: usize = 0;
    for (rust_versions) |w| {
        if (rv.order(w) != .gt) n += 1;
    }
    return n;
}

fn containsVersion(list: []const semver.Version, v: semver.Version) bool {
    for (list) |e| {
        if (e.eql(v)) return true;
    }
    return false;
}

/// Per-`PackageId` preference membership (`should_prefer`): both name AND
/// version (build-sensitive) must match.
fn isPreferred(list: []const PreferredId, name: []const u8, v: semver.Version) bool {
    for (list) |e| {
        if (std.mem.eql(u8, e.name, name) and e.version.eql(v)) return true;
    }
    return false;
}

/// `dep_cache.rs::RegistryQueryer::query` (filter half) +
/// `version_prefs.rs::sort_summaries` (order half):
/// (1) retain candidates where `req.matches(version)`;
/// (2) drop `yanked` unless `allow_yanked` contains an equal version
/// (build-sensitive `eql`);
/// (3) drop `pubtime > max_pubtime` when both present;
/// (4) stable sort: preferred first, then higher `msrvCompatCount` first,
/// then version descending (ascending when `min_versions_first`);
/// (5) return an owned slice (caller frees with `gpa.free`; elements borrow
/// from `all`).
pub fn queryCandidates(
    gpa: std.mem.Allocator,
    all: []const Candidate,
    req: semver.OptVersionReq,
    filter: QueryFilter,
) IndexError![]Candidate {
    const Decorated = struct { c: Candidate, idx: usize };
    var tmp: std.ArrayList(Decorated) = .empty;
    defer tmp.deinit(gpa);
    for (all, 0..) |c, i| {
        if (!req.matches(c.version)) continue;
        if (c.yanked and !containsVersion(filter.allow_yanked, c.version)) continue;
        if (filter.max_pubtime) |max| {
            if (c.pubtime) |pt| {
                if (pt > max) continue;
            }
        }
        tmp.append(gpa, .{ .c = c, .idx = i }) catch return IndexError.OutOfMemory;
    }
    const Ctx = struct { filter: QueryFilter };
    std.mem.sort(Decorated, tmp.items, Ctx{ .filter = filter }, struct {
        fn lt(ctx: Ctx, a: Decorated, b: Decorated) bool {
            const pa = isPreferred(ctx.filter.preferred, a.c.name, a.c.version);
            const pb = isPreferred(ctx.filter.preferred, b.c.name, b.c.version);
            if (pa != pb) return pa;
            const ca = msrvCompatCount(a.c.rust_version, ctx.filter.rust_versions);
            const cb = msrvCompatCount(b.c.rust_version, ctx.filter.rust_versions);
            if (ca != cb) return ca > cb;
            switch (a.c.version.order(b.c.version)) {
                .lt => return ctx.filter.min_versions_first,
                .gt => return !ctx.filter.min_versions_first,
                .eq => {},
            }
            // Deterministic tie-break below full-version equality (versions
            // are unique per source in practice; build-only duplicates keep
            // input order via the index tie-break rather than asserting).
            const bord = std.mem.order(u8, a.c.version.build, b.c.version.build);
            if (bord != .eq) return bord == .lt;
            return a.idx < b.idx;
        }
    }.lt);
    const out = gpa.alloc(Candidate, tmp.items.len) catch return IndexError.OutOfMemory;
    for (tmp.items, 0..) |d, i| out[i] = d.c;
    return out;
}

// --- sparse-index line parsing ---

const OOM = IndexError.OutOfMemory;

fn dupe(arena: *std.heap.ArenaAllocator, s: []const u8) IndexError![]const u8 {
    return arena.allocator().dupe(u8, s) catch return OOM;
}

fn optString(obj: *const std.json.ObjectMap, arena: *std.heap.ArenaAllocator, key: []const u8) IndexError!?[]const u8 {
    const v = obj.get(key) orelse return null;
    if (v == .null) return null;
    if (v != .string) return IndexError.InvalidIndexLine;
    return try dupe(arena, v.string);
}

fn reqString(obj: *const std.json.ObjectMap, arena: *std.heap.ArenaAllocator, key: []const u8) IndexError![]const u8 {
    const v = obj.get(key) orelse return IndexError.InvalidIndexLine;
    if (v != .string) return IndexError.InvalidIndexLine;
    return try dupe(arena, v.string);
}

fn optBool(obj: *const std.json.ObjectMap, key: []const u8, default: bool) IndexError!bool {
    const v = obj.get(key) orelse return default;
    if (v == .null) return default;
    if (v != .bool) return IndexError.InvalidIndexLine;
    return v.bool;
}

/// Parse one JSON object per line in exactly the sparse-index wire shape
/// (`cargo-util-schemas/src/index.rs::IndexPackage`). Unknown fields are
/// ignored (forward-compat). Conversion rules mirror
/// `index/mod.rs::index_package_to_summary` + `registry_dependency_into_dep`:
/// features + features2 MERGED, dep `features` filtered of `""`,
/// `default_features` defaults true, `kind` `"dev"|"build"|""` mapped
/// (absent/unknown -> normal), `package` split from `name` for renames,
/// `public` passed through, `artifact`/`bindep_target`/`lib` carried verbatim
/// (NEVER a parse-time error on index lines), `v > v_max` (2 in M3) kept as
/// `unsupported` (never selected, not an error).
pub fn parseIndexLine(gpa: std.mem.Allocator, line: []const u8) IndexError!IndexEntry {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{}) catch
        return IndexError.InvalidIndexLine;
    defer parsed.deinit();
    if (parsed.value != .object) return IndexError.InvalidIndexLine;
    const obj = &parsed.value.object;

    const name = try reqString(obj, &arena, "name");
    const vers_raw = try reqString(obj, &arena, "vers");
    const version = semver.Version.parse(vers_raw) catch return IndexError.InvalidIndexLine;

    const yanked = try optBool(obj, "yanked", false);
    const checksum = try optString(obj, &arena, "cksum");
    const links = try optString(obj, &arena, "links");

    var rust_version: ?semver.Version = null;
    if (obj.get("rust_version")) |rv| {
        if (rv != .null) {
            if (rv != .string) return IndexError.InvalidIndexLine;
            const raw = try dupe(&arena, rv.string);
            rust_version = parseRustVersion(raw) catch return IndexError.InvalidIndexLine;
        }
    }

    var pubtime: ?i64 = null;
    if (obj.get("pubtime")) |pv| {
        if (pv != .null) {
            if (pv != .string) return IndexError.InvalidIndexLine;
            pubtime = parsePubtime(pv.string) catch return IndexError.InvalidIndexLine;
        }
    }

    var schema_v: u32 = 1;
    if (obj.get("v")) |vv| {
        if (vv != .integer) return IndexError.InvalidIndexLine;
        if (vv.integer < 0 or vv.integer > std.math.maxInt(u32))
            return IndexError.InvalidIndexLine;
        schema_v = @intCast(vv.integer);
    }

    const features = try parseFeatureTables(obj, &arena);
    const deps = try parseDeps(obj, &arena);
    _ = alloc;

    return IndexEntry{
        .candidate = .{
            .name = name,
            .version = version,
            .yanked = yanked,
            .checksum = checksum,
            .rust_version = rust_version,
            .pubtime = pubtime,
        },
        .links = links,
        .schema_v = schema_v,
        .unsupported = schema_v > INDEX_V_MAX,
        .features = features,
        .deps = deps,
        .arena = arena,
    };
}

/// Index `rust_version` is partial (`"1.60"` -> `1.60.0`); full `x.y.z`
/// accepted. Borrows from `raw` (already arena-owned).
fn parseRustVersion(raw: []const u8) semver.ParseError!semver.Version {
    if (semver.Version.parse(raw)) |v| return v else |_| {}
    // Partial fallback: 1-3 strict numeric components, no pre/build.
    var parts: [3]u64 = .{ 0, 0, 0 };
    var it = std.mem.splitScalar(u8, raw, '.');
    var n: usize = 0;
    while (it.next()) |part| : (n += 1) {
        if (n >= 3) return semver.ParseError.InvalidVersion;
        if (part.len == 0) return semver.ParseError.InvalidVersion;
        for (part) |c| {
            if (!std.ascii.isDigit(c)) return semver.ParseError.InvalidVersion;
        }
        if (part.len > 1 and part[0] == '0') return semver.ParseError.InvalidVersion;
        parts[n] = std.fmt.parseInt(u64, part, 10) catch return semver.ParseError.InvalidVersion;
    }
    if (n == 0) return semver.ParseError.InvalidVersion;
    return semver.Version{
        .major = parts[0],
        .minor = parts[1],
        .patch = parts[2],
        .pre = "",
        .build = "",
    };
}

/// Strict `%Y-%m-%dT%H:%M:%SZ` (UTC `Z` only, no fractional seconds/offsets)
/// to unix seconds. Range-checked incl. leap days; a leap second (`:60`)
/// clamps to `:59`.
fn parsePubtime(s: []const u8) semver.ParseError!i64 {
    if (s.len != 20) return semver.ParseError.InvalidVersion;
    if (s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or s[16] != ':' or s[19] != 'Z')
        return semver.ParseError.InvalidVersion;
    const y = parseDigits(s[0..4]) orelse return semver.ParseError.InvalidVersion;
    const mo = parseDigits(s[5..7]) orelse return semver.ParseError.InvalidVersion;
    const d = parseDigits(s[8..10]) orelse return semver.ParseError.InvalidVersion;
    const hh = parseDigits(s[11..13]) orelse return semver.ParseError.InvalidVersion;
    const mm = parseDigits(s[14..16]) orelse return semver.ParseError.InvalidVersion;
    var ss = parseDigits(s[17..19]) orelse return semver.ParseError.InvalidVersion;
    if (mo < 1 or mo > 12) return semver.ParseError.InvalidVersion;
    const leap = (y % 4 == 0 and y % 100 != 0) or y % 400 == 0;
    const dim: u32 = switch (mo) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (leap) 29 else 28,
        else => unreachable,
    };
    if (d < 1 or d > dim) return semver.ParseError.InvalidVersion;
    if (hh > 23 or mm > 59 or ss > 60) return semver.ParseError.InvalidVersion;
    if (ss == 60) ss = 59;
    const days = daysFromCivil(@intCast(y), mo, d);
    return days * 86400 + @as(i64, hh) * 3600 + @as(i64, mm) * 60 + @as(i64, ss);
}

fn parseDigits(s: []const u8) ?u32 {
    var v: u32 = 0;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return null;
        v = v * 10 + (c - '0');
    }
    return v;
}

/// Howard Hinnant's days-from-civil; days since 1970-01-01 (may be negative).
fn daysFromCivil(y_in: i64, m_in: u32, d: u32) i64 {
    var y = y_in;
    const m: i64 = @intCast(m_in);
    y -= @intFromBool(m <= 2);
    const era: i64 = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe: i64 = y - era * 400;
    const mp: i64 = @mod(m - 3, 12);
    const doy: i64 = @divFloor(153 * mp + 2, 5) + @as(i64, d) - 1;
    const doe: i64 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn parseFeatureTables(obj: *const std.json.ObjectMap, arena: *std.heap.ArenaAllocator) IndexError![]FeatureDef {
    const alloc = arena.allocator();
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(alloc);
    var values: std.ArrayList([]const []const u8) = .empty;
    defer values.deinit(alloc);

    const feats_v = obj.get("features") orelse null;
    if (feats_v) |fv| {
        if (fv != .null) {
            if (fv != .object) return IndexError.InvalidIndexLine;
            var it = fv.object.iterator();
            while (it.next()) |kv| {
                const vals = try parseStringArray(kv.value_ptr.*, arena);
                try names.append(alloc, try dupe(arena, kv.key_ptr.*));
                try values.append(alloc, vals);
            }
        }
    }
    const feats2_v = obj.get("features2") orelse null;
    if (feats2_v) |fv| {
        if (fv != .null) {
            if (fv != .object) return IndexError.InvalidIndexLine;
            var it = fv.object.iterator();
            while (it.next()) |kv| {
                const extra = try parseStringArray(kv.value_ptr.*, arena);
                var found = false;
                for (names.items, 0..) |n, i| {
                    if (std.mem.eql(u8, n, kv.key_ptr.*)) {
                        // features2 EXTENDS the same-name key.
                        const old = values.items[i];
                        const merged = alloc.alloc([]const u8, old.len + extra.len) catch return OOM;
                        @memcpy(merged[0..old.len], old);
                        @memcpy(merged[old.len..], extra);
                        values.items[i] = merged;
                        alloc.free(extra);
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    try names.append(alloc, try dupe(arena, kv.key_ptr.*));
                    try values.append(alloc, extra);
                } else {
                    // `extra` consumed into merged (or freed).
                }
            }
        }
    }
    const out = alloc.alloc(FeatureDef, names.items.len) catch return OOM;
    for (names.items, values.items, 0..) |n, v, i| out[i] = .{ .name = n, .values = v };
    return out;
}

fn parseStringArray(v: std.json.Value, arena: *std.heap.ArenaAllocator) IndexError![]const []const u8 {
    if (v != .array) return IndexError.InvalidIndexLine;
    const alloc = arena.allocator();
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(alloc);
    for (v.array.items) |item| {
        if (item != .string) return IndexError.InvalidIndexLine;
        try out.append(alloc, try dupe(arena, item.string));
    }
    return out.toOwnedSlice(alloc) catch return OOM;
}

fn parseDeps(obj: *const std.json.ObjectMap, arena: *std.heap.ArenaAllocator) IndexError![]IndexDep {
    const deps_v = obj.get("deps") orelse return &.{};
    if (deps_v == .null) return &.{};
    if (deps_v != .array) return IndexError.InvalidIndexLine;
    const alloc = arena.allocator();
    var out: std.ArrayList(IndexDep) = .empty;
    defer out.deinit(alloc);
    for (deps_v.array.items) |item| {
        if (item != .object) return IndexError.InvalidIndexLine;
        try out.append(alloc, try parseDep(&item.object, arena));
    }
    return out.toOwnedSlice(alloc) catch return OOM;
}

fn parseDep(obj: *const std.json.ObjectMap, arena: *std.heap.ArenaAllocator) IndexError!IndexDep {
    const name = try reqString(obj, arena, "name");
    const req = try reqString(obj, arena, "req");
    const package = try optString(obj, arena, "package");
    const target = try optString(obj, arena, "target");
    const registry = try optString(obj, arena, "registry");
    const bindep_target = try optString(obj, arena, "bindep_target");

    var feats: std.ArrayList([]const u8) = .empty;
    defer feats.deinit(arena.allocator());
    if (obj.get("features")) |fv| {
        if (fv != .null) {
            if (fv != .array) return IndexError.InvalidIndexLine;
            for (fv.array.items) |item| {
                if (item != .string) return IndexError.InvalidIndexLine;
                // Published junk: empty-string entries are FILTERED OUT
                // (`registry_dependency_into_dep` retains non-empty only).
                if (item.string.len == 0) continue;
                try feats.append(arena.allocator(), try dupe(arena, item.string));
            }
        }
    }

    const optional = try optBool(obj, "optional", false);
    const default_features = try optBool(obj, "default_features", true);

    var kind: DepKind = .normal;
    if (obj.get("kind")) |kv| {
        if (kv == .null) {
            kind = .normal;
        } else if (kv != .string) {
            return IndexError.InvalidIndexLine;
        } else if (std.mem.eql(u8, kv.string, "dev")) {
            kind = .dev;
        } else if (std.mem.eql(u8, kv.string, "build")) {
            kind = .build;
        } else {
            kind = .normal; // absent/unknown -> Normal
        }
    }

    const public = try optBool(obj, "public", false);
    const lib = try optBool(obj, "lib", false);

    // Artifact data is parsed and carried verbatim (deferred `-Zbindeps`
    // semantics); its PRESENCE is never a parse-time error on index lines.
    // Stored as a normalized comma-joined string (null when absent).
    var artifact: ?[]const u8 = null;
    if (obj.get("artifact")) |av| {
        if (av != .null) {
            if (av != .array) return IndexError.InvalidIndexLine;
            var joined: std.ArrayList(u8) = .empty;
            defer joined.deinit(arena.allocator());
            for (av.array.items, 0..) |item, i| {
                if (item != .string) return IndexError.InvalidIndexLine;
                if (i > 0) try joined.append(arena.allocator(), ',');
                try joined.appendSlice(arena.allocator(), item.string);
            }
            artifact = try joined.toOwnedSlice(arena.allocator());
        }
    }

    return IndexDep{
        .name = name,
        .package = package,
        .req = req,
        .features = try feats.toOwnedSlice(arena.allocator()),
        .optional = optional,
        .default_features = default_features,
        .target = target,
        .kind = kind,
        .registry = registry,
        .public = public,
        .artifact = artifact,
        .bindep_target = bindep_target,
        .lib = lib,
    };
}

test "index filters yanked and prefers locked versions" {
    const all = [_]Candidate{
        .{ .name = "serde", .version = try semver.Version.parse("1.0.200"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null },
        .{ .name = "serde", .version = try semver.Version.parse("1.0.201"), .yanked = true, .checksum = null, .rust_version = null, .pubtime = null },
        .{ .name = "serde", .version = try semver.Version.parse("1.0.150"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null },
    };
    const req = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1.0.0") };
    // Yanked 1.0.201 hidden by default; newest non-yanked first.
    const got = try queryCandidates(std.testing.allocator, &all, req, .{ .allow_yanked = &.{}, .max_pubtime = null, .min_versions_first = false, .rust_versions = &.{}, .preferred = &.{} });
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expect(got[0].version.eql(try semver.Version.parse("1.0.200")));
    // Pinned yanked version is rescued (lock_to path in dep_cache.rs query).
    // Preference is per-PackageId (name, version): only the matching crate
    // is preferred, never an unrelated crate sharing the version number.
    const pinned = [_]semver.Version{try semver.Version.parse("1.0.201")};
    const preferred = [_]PreferredId{.{ .name = "serde", .version = try semver.Version.parse("1.0.201") }};
    const got2 = try queryCandidates(std.testing.allocator, &all, req, .{ .allow_yanked = &pinned, .max_pubtime = null, .min_versions_first = false, .rust_versions = &.{}, .preferred = &preferred });
    defer std.testing.allocator.free(got2);
    try std.testing.expectEqual(@as(usize, 3), got2.len);
    try std.testing.expect(got2[0].version.eql(try semver.Version.parse("1.0.201")));
}

test "index preference is scoped to crate name" {
    // A preferred pin for `other 1.0.150` must NOT prefer `serde 1.0.150`:
    // cargo's `should_prefer` is per-PackageId (name, version, source).
    const all = [_]Candidate{
        .{ .name = "serde", .version = try semver.Version.parse("1.0.200"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null },
        .{ .name = "serde", .version = try semver.Version.parse("1.0.150"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null },
    };
    const req = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1.0.0") };
    const foreign = [_]PreferredId{.{ .name = "other", .version = try semver.Version.parse("1.0.150") }};
    const got = try queryCandidates(std.testing.allocator, &all, req, .{ .allow_yanked = &.{}, .max_pubtime = null, .min_versions_first = false, .rust_versions = &.{}, .preferred = &foreign });
    defer std.testing.allocator.free(got);
    // Without a same-name preference, max-first order wins (1.0.200 first).
    try std.testing.expect(got[0].version.eql(try semver.Version.parse("1.0.200")));
    const same = [_]PreferredId{.{ .name = "serde", .version = try semver.Version.parse("1.0.150") }};
    const got2 = try queryCandidates(std.testing.allocator, &all, req, .{ .allow_yanked = &.{}, .max_pubtime = null, .min_versions_first = false, .rust_versions = &.{}, .preferred = &same });
    defer std.testing.allocator.free(got2);
    try std.testing.expect(got2[0].version.eql(try semver.Version.parse("1.0.150")));
}

test "index orders by msrv compatibility then version" {
    // candidate A v2.0.0 needs rust 1.80, candidate B v1.9.0 needs rust 1.60; workspace rust is 1.70 -> B first.
    const all = [_]Candidate{
        .{ .name = "x", .version = try semver.Version.parse("2.0.0"), .yanked = false, .checksum = null, .rust_version = try semver.Version.parse("1.80.0"), .pubtime = null },
        .{ .name = "x", .version = try semver.Version.parse("1.9.0"), .yanked = false, .checksum = null, .rust_version = try semver.Version.parse("1.60.0"), .pubtime = null },
    };
    const rv = [_]semver.Version{try semver.Version.parse("1.70.0")};
    const got = try queryCandidates(std.testing.allocator, &all, .{ .any = {} }, .{ .allow_yanked = &.{}, .max_pubtime = null, .min_versions_first = false, .rust_versions = &rv, .preferred = &.{} });
    defer std.testing.allocator.free(got);
    try std.testing.expect(got[0].version.eql(try semver.Version.parse("1.9.0")));
}

test "index minimal-versions sorts ascending and pubtime filters" {
    // NOTE (plan ambiguity resolved): the approved block paired version
    // 1.2.0 with pubtime 100 (survives `max_pubtime = 500`) yet asserted the
    // survivor is NOT 1.2.0 -- unsatisfiable with only 1.2.0 surviving.
    // The pubtimes are swapped here so the assertions hold verbatim: 1.2.0
    // is the too-new entry that gets filtered, 1.1.0 survives.
    const all = [_]Candidate{
        .{ .name = "x", .version = try semver.Version.parse("1.2.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = 9999 },
        .{ .name = "x", .version = try semver.Version.parse("1.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = 100 },
    };
    const got = try queryCandidates(std.testing.allocator, &all, .{ .any = {} }, .{ .allow_yanked = &.{}, .max_pubtime = 500, .min_versions_first = true, .rust_versions = &.{}, .preferred = &.{} });
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expect(got[0].version.eql(try semver.Version.parse("1.2.0")) == false);
}

test "index minimal-versions ordering is ascending" {
    const all = [_]Candidate{
        .{ .name = "x", .version = try semver.Version.parse("1.2.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null },
        .{ .name = "x", .version = try semver.Version.parse("1.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null },
    };
    const base = QueryFilter{ .allow_yanked = &.{}, .max_pubtime = null, .min_versions_first = false, .rust_versions = &.{}, .preferred = &.{} };
    const desc = try queryCandidates(std.testing.allocator, &all, .{ .any = {} }, base);
    defer std.testing.allocator.free(desc);
    try std.testing.expect(desc[0].version.eql(try semver.Version.parse("1.2.0")));
    var asc_filter = base;
    asc_filter.min_versions_first = true;
    const asc = try queryCandidates(std.testing.allocator, &all, .{ .any = {} }, asc_filter);
    defer std.testing.allocator.free(asc);
    try std.testing.expect(asc[0].version.eql(try semver.Version.parse("1.1.0")));
}

test "index parses a real sparse-index line faithfully" {
    const line =
        "{\"name\":\"serde\",\"vers\":\"1.0.200\",\"deps\":[{\"name\":\"serde_derive\",\"req\":\"^1.0.200\",\"features\":[],\"optional\":true,\"default_features\":true,\"target\":null,\"kind\":\"normal\",\"registry\":null,\"package\":null}],\"features\":{\"default\":[\"std\"],\"alloc\":[]},\"features2\":{\"default\":[\"dep:serde_derive\"]},\"cksum\":\"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\",\"yanked\":false,\"links\":null,\"rust_version\":\"1.56\",\"v\":2}";
    var entry = try parseIndexLine(std.testing.allocator, line);
    defer entry.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("serde", entry.candidate.name);
    try std.testing.expect(entry.candidate.version.eql(try semver.Version.parse("1.0.200")));
    try std.testing.expect(entry.candidate.rust_version.?.eql(try semver.Version.parse("1.56.0")));
    try std.testing.expect(!entry.unsupported);
    // features + features2 merged under one key.
    try std.testing.expectEqual(@as(usize, 2), entry.features.len); // default, alloc
    // Optional dep edge preserved with kind + rename split.
    try std.testing.expect(entry.deps[0].optional);
    try std.testing.expectEqualStrings("serde_derive", entry.deps[0].realName());
}

test "index carries public and defers artifact (bindeps gate)" {
    // `public` is a passthrough bool (registry_dependency_into_dep): parsed, carried, never an error.
    const with_public = "{\"name\":\"x\",\"vers\":\"1.0.0\",\"deps\":[{\"name\":\"y\",\"req\":\"^1\",\"features\":[],\"optional\":false,\"default_features\":true,\"target\":null,\"kind\":\"normal\",\"public\":true}],\"cksum\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"yanked\":false}";
    var e = try parseIndexLine(std.testing.allocator, with_public);
    defer e.deinit(std.testing.allocator);
    try std.testing.expect(e.deps[0].public);
    // Artifact data on a v<=2 line is parsed and carried verbatim (registry_dependency_into_dep
    // returns Ok) -- NEVER a parse error; M3 defers artifact semantics. Selection of v3
    // lines is still gated by Unsupported (v_max = 2 without -Zbindeps).
    const with_artifact = "{\"name\":\"x\",\"vers\":\"1.0.0\",\"deps\":[{\"name\":\"y\",\"req\":\"^1\",\"features\":[],\"optional\":false,\"default_features\":true,\"target\":null,\"kind\":\"normal\",\"artifact\":[\"bin\"]}],\"cksum\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"yanked\":false,\"v\":2}";
    var ea = try parseIndexLine(std.testing.allocator, with_artifact);
    defer ea.deinit(std.testing.allocator);
    try std.testing.expect(!ea.unsupported);
    try std.testing.expect(ea.deps[0].artifact != null);
    try std.testing.expect(!ea.deps[0].lib);
    // Manifest-side artifact keys stay a loud UnsupportedManifestForm (Task 12 table);
    // index lines are never rejected for artifact data.
    // Schema v3 line is kept but never selected (IndexSummary::Unsupported rule).
    const v3 = "{\"name\":\"x\",\"vers\":\"2.0.0\",\"deps\":[],\"cksum\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"v\":3}";
    var e3 = try parseIndexLine(std.testing.allocator, v3);
    defer e3.deinit(std.testing.allocator);
    try std.testing.expect(e3.unsupported);
}

test "index rejects malformed lines loudly" {
    const bad_vers = "{\"name\":\"x\",\"vers\":\"not.a.version\",\"deps\":[],\"cksum\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"yanked\":false}";
    try std.testing.expectError(IndexError.InvalidIndexLine, parseIndexLine(std.testing.allocator, bad_vers));
    const bad_req = "{\"name\":\"x\",\"vers\":\"1.0.0\",\"deps\":[{\"name\":\"y\",\"req\":42,\"features\":[],\"optional\":false,\"default_features\":true}],\"cksum\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"yanked\":false}";
    try std.testing.expectError(IndexError.InvalidIndexLine, parseIndexLine(std.testing.allocator, bad_req));
    try std.testing.expectError(IndexError.InvalidIndexLine, parseIndexLine(std.testing.allocator, "not json"));
    try std.testing.expectError(IndexError.InvalidIndexLine, parseIndexLine(std.testing.allocator, "{\"name\":\"x\"}"));
}

test "index pubtime parses strict UTC timestamps" {
    const line = "{\"name\":\"x\",\"vers\":\"1.0.0\",\"deps\":[],\"cksum\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"yanked\":false,\"pubtime\":\"2024-02-29T12:00:00Z\"}";
    var e = try parseIndexLine(std.testing.allocator, line);
    defer e.deinit(std.testing.allocator);
    // 2024-02-29 is a leap day; 2023-02-29 is not.
    try std.testing.expect(e.candidate.pubtime != null);
    const bad_day = "{\"name\":\"x\",\"vers\":\"1.0.0\",\"deps\":[],\"cksum\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"yanked\":false,\"pubtime\":\"2023-02-29T12:00:00Z\"}";
    try std.testing.expectError(IndexError.InvalidIndexLine, parseIndexLine(std.testing.allocator, bad_day));
    const bad_off = "{\"name\":\"x\",\"vers\":\"1.0.0\",\"deps\":[],\"cksum\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"yanked\":false,\"pubtime\":\"2024-01-01T00:00:00+00:00\"}";
    try std.testing.expectError(IndexError.InvalidIndexLine, parseIndexLine(std.testing.allocator, bad_off));
}

test "ported yanked-avoid stub hides yanked newest" {
    // Task 11 case 2 over the REAL stub file (sparse-index wire shape, one
    // JSON object per line): newest serde is yanked → hidden by default;
    // pinned via allow_yanked (+ preference) → rescued first. This is the
    // `loadStubIndex` shape Task 11 prescribes (split lines → parseIndexLine
    // → Candidates + queryCandidates), hosted here because `oracle.zig`
    // belongs to the sibling worker.
    const gpa = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const text = try std.Io.Dir.cwd().readFileAlloc(io, "testdata/cargo/resolve/yanked-avoid/index.json", gpa, .limited(1 << 20));
    defer gpa.free(text);
    var entries: std.ArrayList(IndexEntry) = .empty;
    defer {
        for (entries.items) |*e| e.deinit(gpa);
        entries.deinit(gpa);
    }
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |ln| {
        const line = std.mem.trim(u8, ln, " \t\r");
        if (line.len == 0) continue;
        try entries.append(gpa, try parseIndexLine(gpa, line));
    }
    try std.testing.expectEqual(@as(usize, 2), entries.items.len);
    var cands: std.ArrayList(Candidate) = .empty;
    defer cands.deinit(gpa);
    for (entries.items) |*e| try cands.append(gpa, e.candidate);
    const req = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1.0.0") };
    const hidden = try queryCandidates(gpa, cands.items, req, .{ .allow_yanked = &.{}, .max_pubtime = null, .min_versions_first = false, .rust_versions = &.{}, .preferred = &.{} });
    defer gpa.free(hidden);
    try std.testing.expectEqual(@as(usize, 1), hidden.len);
    try std.testing.expect(hidden[0].version.eql(try semver.Version.parse("1.0.200")));
    // Pinned yanked version is rescued (lock_to path in dep_cache.rs query).
    const pinned = [_]semver.Version{try semver.Version.parse("1.0.201")};
    const prefer = [_]PreferredId{.{ .name = "serde", .version = try semver.Version.parse("1.0.201") }};
    const rescued = try queryCandidates(gpa, cands.items, req, .{ .allow_yanked = &pinned, .max_pubtime = null, .min_versions_first = false, .rust_versions = &.{}, .preferred = &prefer });
    defer gpa.free(rescued);
    try std.testing.expectEqual(@as(usize, 2), rescued.len);
    try std.testing.expect(rescued[0].version.eql(try semver.Version.parse("1.0.201")));
}
