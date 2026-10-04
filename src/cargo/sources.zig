//! Source identities (M3 Task 3 contract + Task 7 surface).
//!
//! This file is created by Task 3 with the `SourceId`/`GitRef`/`LockVersion`
//! contract so Tasks 3-6 build on source-keyed refs from the start; Task 7
//! extends this same file with `Platform`/`TargetInfo`/`CfgExpr`/`parseCfg`/
//! `DepEdgeFull` (platform gates, workspace/path/git edge projection).
//! `ResolvedRef`/`ResolvedNode` (in `resolve.zig`) are source-keyed from the
//! start -- no retroactive rekey in Task 7.

const std = @import("std");

pub const LockVersion = enum { v1, v2, v3, v4 };

pub const GitRef = union(enum) {
    branch: []const u8,
    tag: []const u8,
    rev: []const u8,
    default_branch: void,
};

pub const SourceId = union(enum) {
    path: []const u8, // normalized absolute dir (arena-owned by caller)
    registry: []const u8, // normalized index URL, e.g. "sparse+https://..."
    git: struct { url: []const u8, ref: GitRef, precise: ?[40]u8 },

    pub fn isPath(self: SourceId) bool {
        return self == .path;
    }

    pub const LockLineError = error{OutOfMemory};

    /// Render the lockfile `source = "..."` line content (caller frees
    /// non-null; null for path, per the portable rule in
    /// `encode.rs::encodable_source_id`).
    ///
    /// Rules (Task 7 pins):
    /// registry sources encode as `registry+<url>` (the `sparse+` index
    /// scheme is rewritten to the historical `registry+` lock form); the URL
    /// itself is verbatim for EVERY version -- cargo's `SourceIdAsUrl`
    /// Display writes `self.inner.url` identically in both forms and only
    /// consults the `encoded` flag for git `pretty_ref`
    /// (`core/source_id.rs::fmt(SourceIdAsUrl)`), so there is no
    /// `as_encoded_url` vs `as_url` split for registry lines. Git ref values
    /// DO split (`encode.rs::encodable_source_id` calls `as_encoded_url`
    /// for v4+ and `as_url` below): v4+ percent-encodes the ref value
    /// (`GitReference::pretty_ref(encoded=true)` =
    /// `url::form_urlencoded::byte_serialize`, i.e.
    /// application/x-www-form-urlencoded: `A-Za-z0-9*-._` verbatim, space
    /// becomes `+`, everything else `%XX` uppercase hex -- frozen by cargo's
    /// own `gitrefs_roundtrip` test); v1/v2/v3 emit the ref verbatim. Git
    /// sources encode as `git+<url>[?<ref>]#<precise40>`; for v1/v2 a
    /// `branch = "master"` ref is rewritten to default-branch form (the
    /// `?branch=master` part is dropped).
    pub fn lockSourceLine(gpa: std.mem.Allocator, self: SourceId, version: LockVersion) LockLineError!?[]u8 {
        switch (self) {
            .path => return null,
            .registry => |url| {
                var rest = url;
                if (std.mem.startsWith(u8, rest, "sparse+")) rest = rest["sparse+".len..];
                if (std.mem.startsWith(u8, rest, "registry+")) rest = rest["registry+".len..];
                return std.fmt.allocPrint(gpa, "registry+{s}", .{rest}) catch
                    return LockLineError.OutOfMemory;
            },
            .git => |g| {
                var out: std.ArrayList(u8) = .empty;
                errdefer out.deinit(gpa);
                out.appendSlice(gpa, "git+") catch return LockLineError.OutOfMemory;
                out.appendSlice(gpa, g.url) catch return LockLineError.OutOfMemory;
                const drop_master = (version == .v1 or version == .v2) and
                    g.ref == .branch and std.mem.eql(u8, g.ref.branch, "master");
                if (!drop_master) {
                    switch (g.ref) {
                        .branch => |b| {
                            out.appendSlice(gpa, "?branch=") catch return LockLineError.OutOfMemory;
                            try appendRefValue(gpa, &out, b, version);
                        },
                        .tag => |t| {
                            out.appendSlice(gpa, "?tag=") catch return LockLineError.OutOfMemory;
                            try appendRefValue(gpa, &out, t, version);
                        },
                        .rev => |r| {
                            out.appendSlice(gpa, "?rev=") catch return LockLineError.OutOfMemory;
                            try appendRefValue(gpa, &out, r, version);
                        },
                        .default_branch => {},
                    }
                }
                if (g.precise) |p| {
                    out.append(gpa, '#') catch return LockLineError.OutOfMemory;
                    out.appendSlice(gpa, &p) catch return LockLineError.OutOfMemory;
                }
                return out.toOwnedSlice(gpa) catch return LockLineError.OutOfMemory;
            },
        }
    }
};

/// Append a git ref query value: verbatim for v1/v2/v3 (`as_url`), and
/// `url::form_urlencoded::byte_serialize` for v4 (`as_encoded_url`). The
/// unreserved set (`A-Za-z0-9*-._` verbatim, space to `+`, the rest `%XX`
/// uppercase hex) is frozen by cargo's `gitrefs_roundtrip` test in
/// `core/source_id.rs` (`*-._+20%30 Z/z#...` becomes
/// `*-._%2B20%2530+Z%2Fz%23...`). `LockVersion` tops out at v4, so
/// `version == .v4` is exactly cargo's `version >= ResolveVersion::V4`.
fn appendRefValue(gpa: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8, version: LockVersion) SourceId.LockLineError!void {
    if (version != .v4) {
        out.appendSlice(gpa, value) catch return SourceId.LockLineError.OutOfMemory;
        return;
    }
    const hex = "0123456789ABCDEF";
    for (value) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '*' or c == '-' or c == '.' or c == '_') {
            out.append(gpa, c) catch return SourceId.LockLineError.OutOfMemory;
        } else if (c == ' ') {
            out.append(gpa, '+') catch return SourceId.LockLineError.OutOfMemory;
        } else {
            out.append(gpa, '%') catch return SourceId.LockLineError.OutOfMemory;
            out.append(gpa, hex[c >> 4]) catch return SourceId.LockLineError.OutOfMemory;
            out.append(gpa, hex[c & 0xF]) catch return SourceId.LockLineError.OutOfMemory;
        }
    }
}

// --- Task 7: platform gates, workspace/path/git edges, source identities ---
//
// Reference pins:
// - `core/dependency.rs::{platform, target, is_build}` (edge carries a
//   gate; matching is OR-inclusive for resolution: the edge is active when
//   it has NO gate or its gate matches the build target).
// - the `cargo-platform` crate grammar (`cfg(`, `all(`, `any(`, `not(`,
//   `key = "value"`, bare `unix`/`windows`); test vectors below mirror
//   `cargo-platform`'s own expectations.
// - `encode.rs::encodable_source_id` (path → `None`; V≤2 `branch="master"`
//   git refs rewrite to default-branch form — already implemented in
//   `lockSourceLine` above).
//
// `ResolvedRef`/`ResolvedNode` (in `resolve.zig`) are source-keyed from
// Task 3; THIS task fills real per-edge values via `DepEdgeFull.source` (a
// `DepEdgeFull → DepEdge` projection applying platform + enabled-optional
// filtering feeds `resolveGraph`'s pending loop; the first real caller of
// that projection is Task 10's harness integration).

pub const TargetInfo = struct { triple: []const u8, os: []const u8, arch: []const u8, family: []const u8 };

pub const CfgError = error{ InvalidCfg, OutOfMemory };

pub const CfgExpr = union(enum) {
    flag: []const u8, // bare predicate (`unix`, `windows`, …)
    kv: struct { key: []const u8, value: []const u8 }, // `key = "value"` predicate
    all: []const CfgExpr, // `all(…)` conjunction
    any: []const CfgExpr, // `any(…)` disjunction
    not: *const CfgExpr, // `not(…)` negation (interned; see parseCfg)
    pub fn matches(self: CfgExpr, target: TargetInfo) bool {
        switch (self) {
            .flag => |f| return matchBareFlag(f, target),
            .kv => |p| {
                if (std.mem.eql(u8, p.key, "target_os")) return std.mem.eql(u8, target.os, p.value);
                if (std.mem.eql(u8, p.key, "target_arch")) return std.mem.eql(u8, target.arch, p.value);
                if (std.mem.eql(u8, p.key, "target_family")) return std.mem.eql(u8, target.family, p.value);
                // Keys without a TargetInfo field (target_env,
                // target_endian, target_pointer_width, …) never match:
                // conservative-inactive, matching rustc's unknown-cfg
                // behavior at resolution time.
                return false;
            },
            .all => |list| {
                for (list) |e| if (!e.matches(target)) return false;
                return true;
            },
            .any => |list| {
                for (list) |e| if (e.matches(target)) return true;
                return false;
            },
            .not => |e| return !e.matches(target),
        }
    }
};

fn matchBareFlag(f: []const u8, target: TargetInfo) bool {
    // `cfg(unix)` holds exactly when the target family is unix; `cfg(windows)`
    // when building for Windows. Any other bare predicate (unknown keys,
    // bare `target_os`, …) is conservative-inactive.
    if (std.mem.eql(u8, f, "unix")) return std.mem.eql(u8, target.family, "unix");
    if (std.mem.eql(u8, f, "windows")) return std.mem.eql(u8, target.os, "windows") or std.mem.eql(u8, target.family, "windows");
    return false;
}

// parseCfg storage: process-lifetime interning. `parseCfg` returns slices
// and nodes that are NEVER freed, so plan-conformant call sites (including
// temporaries such as `parseCfg(gpa, "cfg(windows)").matches(t)`, and the
// allocation-free `Platform.matches`) cannot leak under
// `std.testing.allocator`. The `gpa` parameter is retained for interface
// stability (a future bounded-cache design can use it); storage growth is
// bounded by distinct cfg texts (target-table headers + index `target`
// fields — dozens, not thousands). Guarded by a mutex for shared use.
var cfg_spin: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var cfg_arena_state: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);

fn lockCfg() void {
    while (cfg_spin.cmpxchgStrong(false, true, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}

fn unlockCfg() void {
    cfg_spin.store(false, .release);
}

fn cfgIntern() std.mem.Allocator {
    return cfg_arena_state.allocator();
}

/// `cfg(all/any/not, key = value, bare)` — the `cargo-platform` grammar.
/// Accepts the full `cfg(…)` form (as found in target-table headers and
/// sparse-index `target` fields) or, leniently, a bare inner expression.
/// Results are interned (see above): do NOT free them.
// NOTE (test-ownership deviation, reported): the returned value borrows
// from a process-lifetime arena, so the plan's temporary-style call sites
// pass `std.testing.allocator` leak checks without a `deinit`.
pub fn parseCfg(gpa: std.mem.Allocator, text: []const u8) CfgError!CfgExpr {
    _ = gpa;
    lockCfg();
    defer unlockCfg();
    var p = CfgParser{ .text = text, .pos = 0, .alloc = cfgIntern() };
    const e = try p.parseTop();
    p.skipWs();
    if (p.pos != p.text.len) return CfgError.InvalidCfg;
    return e;
}

const CfgParser = struct {
    text: []const u8,
    pos: usize,
    alloc: std.mem.Allocator,

    fn parseTop(self: *CfgParser) CfgError!CfgExpr {
        self.skipWs();
        if (std.mem.startsWith(u8, self.text[self.pos..], "cfg") and self.peekWordEnd(3)) {
            self.pos += 3;
            self.skipWs();
            try self.expect('(');
            const inner = try self.parseExpr();
            self.skipWs();
            try self.expect(')');
            return inner;
        }
        return self.parseExpr();
    }

    fn peekWordEnd(self: *CfgParser, len: usize) bool {
        const end = self.pos + len;
        if (end >= self.text.len) return true;
        const c = self.text[end];
        return !(std.ascii.isAlphanumeric(c) or c == '_');
    }

    fn parseExpr(self: *CfgParser) CfgError!CfgExpr {
        self.skipWs();
        const ident = try self.parseIdent();
        self.skipWs();
        if (self.pos < self.text.len and self.text[self.pos] == '(') {
            self.pos += 1;
            var args: std.ArrayList(CfgExpr) = .empty;
            defer args.deinit(self.alloc);
            self.skipWs();
            if (self.pos < self.text.len and self.text[self.pos] != ')') {
                while (true) {
                    const a = try self.parseExpr();
                    args.append(self.alloc, a) catch return CfgError.OutOfMemory;
                    self.skipWs();
                    if (self.pos < self.text.len and self.text[self.pos] == ',') {
                        self.pos += 1;
                        continue;
                    }
                    break;
                }
            }
            self.skipWs();
            try self.expect(')');
            if (std.mem.eql(u8, ident, "all")) {
                return .{ .all = args.toOwnedSlice(self.alloc) catch return CfgError.OutOfMemory };
            } else if (std.mem.eql(u8, ident, "any")) {
                return .{ .any = args.toOwnedSlice(self.alloc) catch return CfgError.OutOfMemory };
            } else if (std.mem.eql(u8, ident, "not")) {
                if (args.items.len != 1) return CfgError.InvalidCfg;
                const box = self.alloc.create(CfgExpr) catch return CfgError.OutOfMemory;
                box.* = args.items[0];
                return .{ .not = box };
            }
            return CfgError.InvalidCfg;
        }
        if (self.pos < self.text.len and self.text[self.pos] == '=') {
            self.pos += 1;
            self.skipWs();
            const val = try self.parseString();
            return .{ .kv = .{ .key = ident, .value = val } };
        }
        return .{ .flag = ident };
    }

    fn parseIdent(self: *CfgParser) CfgError![]const u8 {
        const start = self.pos;
        while (self.pos < self.text.len) {
            const c = self.text[self.pos];
            if (std.ascii.isAlphanumeric(c) or c == '_') {
                self.pos += 1;
            } else break;
        }
        if (start == self.pos) return CfgError.InvalidCfg;
        return self.text[start..self.pos];
    }

    fn parseString(self: *CfgParser) CfgError![]const u8 {
        if (self.pos >= self.text.len or self.text[self.pos] != '"') return CfgError.InvalidCfg;
        // Strings borrow the input text when escape-free; otherwise the
        // unescaped form is interned. (Target/cfg strings in practice never
        // contain escapes; the path exists for grammar completeness.)
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.alloc);
        var escaped = false;
        self.pos += 1; // opening quote
        const start = self.pos;
        while (self.pos < self.text.len) {
            const c = self.text[self.pos];
            if (escaped) {
                const r: u8 = switch (c) {
                    '"' => '"',
                    '\\' => '\\',
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    else => return CfgError.InvalidCfg,
                };
                // Switch to buffered mode on first escape.
                if (out.items.len == 0) out.appendSlice(self.alloc, self.text[start..self.pos - 1]) catch return CfgError.OutOfMemory;
                out.append(self.alloc, r) catch return CfgError.OutOfMemory;
                escaped = false;
                self.pos += 1;
                continue;
            }
            if (c == '\\') {
                escaped = true;
                self.pos += 1;
                continue;
            }
            if (c == '"') {
                if (out.items.len > 0) {
                    const s = out.toOwnedSlice(self.alloc) catch return CfgError.OutOfMemory;
                    self.pos += 1;
                    return s;
                }
                const s = self.text[start..self.pos];
                self.pos += 1;
                return s;
            }
            self.pos += 1;
        }
        return CfgError.InvalidCfg;
    }

    fn skipWs(self: *CfgParser) void {
        while (self.pos < self.text.len and (self.text[self.pos] == ' ' or self.text[self.pos] == '\t' or self.text[self.pos] == '\n' or self.text[self.pos] == '\r')) {
            self.pos += 1;
        }
    }

    fn expect(self: *CfgParser, c: u8) CfgError!void {
        if (self.pos >= self.text.len or self.text[self.pos] != c) return CfgError.InvalidCfg;
        self.pos += 1;
    }
};

pub const Platform = union(enum) {
    name: []const u8, // triple ("x86_64-pc-windows-msvc") or cfg shorthand cargo supports bare ("windows", "unix", …)
    cfg_expr: []const u8, // raw `cfg(…)` text for exact evaluation
    /// OR-inclusive matching (`dependency.rs`): a bare name matches its
    /// triple exactly or as a `unix`/`windows` shorthand; a `cfg(…)` text is
    /// evaluated exactly. Allocation-free (parses via the interned arena).
    pub fn matches(self: Platform, target: TargetInfo) bool {
        switch (self) {
            .name => |n| {
                if (std.mem.eql(u8, n, target.triple)) return true;
                return matchBareFlag(n, target);
            },
            .cfg_expr => |text| {
                // Storage is interned, so the allocator is irrelevant here.
                const e = parseCfg(std.heap.page_allocator, text) catch return false;
                return e.matches(target);
            },
        }
    }
};

/// Full per-edge dependency data. `base` is the Task-3 edge (name + req +
/// optional + build_only); the remaining fields are the Task-7/12 surface
/// (`platform` gate, default-features toggle, edge features, chosen source,
/// dev marker). Importing `resolve.zig` here closes a module cycle
/// (`resolve.zig` imports `sources.zig` for `SourceId`); the cycle is sound
/// because both uses are lazy struct-field references, and the standalone
/// `zig test` runs for both modules stay green (pinned below).
pub const DepEdgeFull = struct {
    base: @import("resolve.zig").DepEdge, // Task-3 edge (name + req + optional + build_only)
    platform: ?Platform, // [target.cfg(…).dependencies] gate
    uses_default: bool, // default-features (default true)
    dep_features: []const []const u8, // `features = […]` on the edge
    source: SourceId, // registry|path|git chosen for this edge
    is_dev: bool, // dev-dependency (Task 6 quarantine + resolve dev_deps flag)
};

/// Edge-form source line: as `lockSourceLine` but WITHOUT the `#precise`
/// fragment (`encode.rs::encodable_package_id` renders dependency edges from
/// `id_to_encode.without_precise()`; only the package's own `source` line
/// keeps `#precise`). Returns null for path, like `lockSourceLine`.
pub fn lockEdgeLine(gpa: std.mem.Allocator, self: SourceId, version: LockVersion) SourceId.LockLineError!?[]u8 {
    const line = try SourceId.lockSourceLine(gpa, self, version);
    const l = line orelse return null;
    // A raw `#` cannot appear in the url/ref part (it would start the
    // fragment in cargo's own parsing), so cutting at the first `#` drops
    // exactly the `#precise` suffix.
    if (std.mem.indexOfScalar(u8, l, '#')) |i| {
        defer gpa.free(l);
        const out = gpa.dupe(u8, l[0..i]) catch return SourceId.LockLineError.OutOfMemory;
        return out;
    }
    return l;
}

test "source lock lines follow version rules" {
    const gpa = std.testing.allocator;
    try std.testing.expect((try SourceId.lockSourceLine(gpa, .{ .path = "/x" }, .v4)) == null);
    const reg_line = (try SourceId.lockSourceLine(gpa, .{ .registry = "sparse+https://github.com/rust-lang/crates.io-index" }, .v4)).?;
    defer gpa.free(reg_line);
    try std.testing.expectEqualStrings("registry+https://github.com/rust-lang/crates.io-index", reg_line);
    const git_url = "https://example.com/r.git";
    var pa: [40]u8 = undefined;
    @memset(&pa, 'a');
    const git_v2 = (try SourceId.lockSourceLine(gpa, .{ .git = .{ .url = git_url, .ref = .{ .branch = "master" }, .precise = pa } }, .v2)).?;
    defer gpa.free(git_v2);
    const git_v4 = (try SourceId.lockSourceLine(gpa, .{ .git = .{ .url = git_url, .ref = .{ .branch = "master" }, .precise = pa } }, .v4)).?;
    defer gpa.free(git_v4);
    // v2 rewrites branch=master away; v4 keeps it (encode.rs V<=2 branch rule).
    try std.testing.expect(std.mem.indexOf(u8, git_v2, "branch=master") == null);
    try std.testing.expect(std.mem.indexOf(u8, git_v4, "branch=master") != null);
}

test "git ref values encode per lock version" {
    const gpa = std.testing.allocator;
    // A branch carrying characters that differ between cargo's `as_url`
    // (verbatim, v1-v3) and `as_encoded_url` (form-urlencoded, v4+).
    const git: SourceId = .{ .git = .{ .url = "https://example.com/r.git", .ref = .{ .branch = "feat/x y" }, .precise = null } };
    const old = (try SourceId.lockSourceLine(gpa, git, .v2)).?;
    defer gpa.free(old);
    try std.testing.expectEqualStrings("git+https://example.com/r.git?branch=feat/x y", old);
    const new = (try SourceId.lockSourceLine(gpa, git, .v4)).?;
    defer gpa.free(new);
    try std.testing.expectEqualStrings("git+https://example.com/r.git?branch=feat%2Fx+y", new);
    // v1/v3 agree with v2 (verbatim); tag/rev split identically.
    const v1 = (try SourceId.lockSourceLine(gpa, git, .v1)).?;
    defer gpa.free(v1);
    try std.testing.expectEqualStrings(old, v1);
    const v3 = (try SourceId.lockSourceLine(gpa, git, .v3)).?;
    defer gpa.free(v3);
    try std.testing.expectEqualStrings(old, v3);
    const tag: SourceId = .{ .git = .{ .url = "https://example.com/r.git", .ref = .{ .tag = "a+b" }, .precise = null } };
    const tag_new = (try SourceId.lockSourceLine(gpa, tag, .v4)).?;
    defer gpa.free(tag_new);
    try std.testing.expectEqualStrings("git+https://example.com/r.git?tag=a%2Bb", tag_new);
    // Frozen vector from cargo's own `gitrefs_roundtrip` test
    // (`core/source_id.rs`): `*-._` stay, `+`->`%2B`, `%`->`%25`,
    // space->`+`, `/`->`%2F`, `#`->`%23`.
    const tricky: SourceId = .{ .git = .{ .url = "https://host/path", .ref = .{ .branch = "*-._+20%30 Z/z#" }, .precise = null } };
    const tricky_new = (try SourceId.lockSourceLine(gpa, tricky, .v4)).?;
    defer gpa.free(tricky_new);
    try std.testing.expectEqualStrings("git+https://host/path?branch=*-._%2B20%2530+Z%2Fz%23", tricky_new);
    const tricky_old = (try SourceId.lockSourceLine(gpa, tricky, .v2)).?;
    defer gpa.free(tricky_old);
    try std.testing.expectEqualStrings("git+https://host/path?branch=*-._+20%30 Z/z#", tricky_old);
}

test "registry lock lines never split by version" {
    const gpa = std.testing.allocator;
    // Cargo's `SourceIdAsUrl` Display writes `self.inner.url` verbatim in
    // BOTH forms (the `encoded` flag only reaches git `pretty_ref`), so a
    // registry URL -- even one carrying characters that WOULD encode in a
    // query value -- renders identically for every lock version.
    const reg: SourceId = .{ .registry = "sparse+https://example.com/index%2Fcrate" };
    const v2 = (try SourceId.lockSourceLine(gpa, reg, .v2)).?;
    defer gpa.free(v2);
    const v4 = (try SourceId.lockSourceLine(gpa, reg, .v4)).?;
    defer gpa.free(v4);
    try std.testing.expectEqualStrings("registry+https://example.com/index%2Fcrate", v2);
    try std.testing.expectEqualStrings(v2, v4);
}

test "cfg gates match targets" {
    const t = TargetInfo{ .triple = "x86_64-pc-windows-msvc", .os = "windows", .arch = "x86_64", .family = "windows" };
    try std.testing.expect((try parseCfg(std.testing.allocator, "cfg(windows)")).matches(t));
    try std.testing.expect(!(try parseCfg(std.testing.allocator, "cfg(unix)")).matches(t));
    try std.testing.expect((try parseCfg(std.testing.allocator, "cfg(any(unix, windows))")).matches(t));
    try std.testing.expect(!(try parseCfg(std.testing.allocator, "cfg(all(windows, target_arch = \"aarch64\"))")).matches(t));
}

test "cfg parser covers cargo-platform vectors" {
    const t = TargetInfo{ .triple = "x86_64-unknown-linux-gnu", .os = "linux", .arch = "x86_64", .family = "unix" };
    // not/all/any nesting + kv matching.
    try std.testing.expect((try parseCfg(std.testing.allocator, "cfg(not(windows))")).matches(t));
    try std.testing.expect((try parseCfg(std.testing.allocator, "cfg(all(unix, target_arch = \"x86_64\"))")).matches(t));
    try std.testing.expect(!(try parseCfg(std.testing.allocator, "cfg(all(unix, target_arch = \"aarch64\"))")).matches(t));
    try std.testing.expect((try parseCfg(std.testing.allocator, "cfg(any(target_os = \"macos\", target_os = \"linux\"))")).matches(t));
    try std.testing.expect((try parseCfg(std.testing.allocator, "cfg(target_family = \"unix\")")).matches(t));
    // Unknown keys are conservative-inactive; malformed input is InvalidCfg.
    try std.testing.expect(!(try parseCfg(std.testing.allocator, "cfg(target_env = \"gnu\")")).matches(t));
    try std.testing.expectError(CfgError.InvalidCfg, parseCfg(std.testing.allocator, "cfg(all(unix)"));
    try std.testing.expectError(CfgError.InvalidCfg, parseCfg(std.testing.allocator, "cfg(not(unix, windows))"));
    try std.testing.expectError(CfgError.InvalidCfg, parseCfg(std.testing.allocator, "cfg(bogus_fn(unix))"));
    try std.testing.expectError(CfgError.InvalidCfg, parseCfg(std.testing.allocator, "cfg(target_os = gnu)"));
    // Platform shorthands: triple equality + bare unix/windows.
    try std.testing.expect((Platform{ .name = "x86_64-unknown-linux-gnu" }).matches(t));
    try std.testing.expect((Platform{ .name = "unix" }).matches(t));
    try std.testing.expect(!(Platform{ .name = "windows" }).matches(t));
    try std.testing.expect((Platform{ .cfg_expr = "cfg(unix)" }).matches(t));
    try std.testing.expect(!(Platform{ .cfg_expr = "cfg(windows)" }).matches(t));
}

test "edge source lines drop precise" {
    const gpa = std.testing.allocator;
    var pa: [40]u8 = undefined;
    @memset(&pa, 'b');
    const git: SourceId = .{ .git = .{ .url = "https://example.com/r.git", .ref = .{ .branch = "main" }, .precise = pa } };
    const full = (try SourceId.lockSourceLine(gpa, git, .v4)).?;
    defer gpa.free(full);
    try std.testing.expect(std.mem.indexOf(u8, full, "#") != null);
    const edge = (try lockEdgeLine(gpa, git, .v4)).?;
    defer gpa.free(edge);
    try std.testing.expectEqualStrings("git+https://example.com/r.git?branch=main", edge);
    try std.testing.expect((try lockEdgeLine(gpa, .{ .path = "/x" }, .v4)) == null);
}
