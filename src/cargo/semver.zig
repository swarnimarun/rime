//! Semver requirement parsing + matching (M3 Task 1).
//!
//! Cargo-conformant version/requirement model for the rime resolver.
//! Reference pins (normative):
//! - `references/cargo/src/cargo/util/semver_ext.rs::OptVersionReq::matches`
//!   (Any/Req/Locked/Precise four-way split; Locked uses full `==` including
//!   build metadata; Precise matches major/minor/patch/pre exactly and build
//!   metadata only when the precise request names it).
//! - `references/cargo/src/cargo/util/semver_eval_ext.rs::matches_prerelease`
//!   (RFC 3493 per-op prerelease logic with the `lower_bound_prerelease` flag;
//!   see that file's own warning that `x.y.z-pre.0` vs `x.y.z` upper-bound
//!   behavior is still unresolved upstream -- this port mirrors current cargo
//!   behavior, including the documented quirks, and does NOT "fix" them).
//! - Stock `VersionReq::matches` follows the `semver` crate's evaluation
//!   rules (`src/eval.rs` in dtolnay/semver, as copied into
//!   `semver_eval_ext.rs::matches_exact/matches_greater/matches_less`):
//!   prereleases are excluded unless the requirement itself contains a
//!   prerelease comparator on the same `major.minor.patch`.
//!
//! Caret/tilde/wildcard desugar to comparator pairs at MATCH time via
//! `matches`, not by rewriting at parse time. Reason: prerelease gating needs
//! the original op (a caret comparator carries its own `pre` for the gate,
//! while a rewritten `>=`/`<` pair would lose which half named the
//! prerelease).

const std = @import("std");

pub const ParseError = error{ InvalidVersion, InvalidReq, OutOfMemory };

pub const Version = struct {
    major: u64,
    minor: u64,
    patch: u64,
    pre: []const u8, // "" when stable; raw prerelease string, e.g. "alpha.1"
    build: []const u8, // "" when absent; compared ONLY by Precise/Locked rules

    /// Strict `x.y.z[-pre][+build]`: exactly three numeric core components,
    /// no leading zeros, no `v` prefix, no surrounding whitespace. `pre` and
    /// `build` borrow from `text`.
    pub fn parse(text: []const u8) ParseError!Version {
        // Split build metadata first (`+` cannot appear in core or pre).
        var rest = text;
        var build: []const u8 = "";
        if (std.mem.indexOfScalar(u8, rest, '+')) |i| {
            build = rest[i + 1 ..];
            rest = rest[0..i];
            try checkIdentifiers(build, false);
        }
        // Then the prerelease (`-` cannot appear in the numeric core).
        var pre: []const u8 = "";
        if (std.mem.indexOfScalar(u8, rest, '-')) |i| {
            pre = rest[i + 1 ..];
            rest = rest[0..i];
            try checkIdentifiers(pre, true);
        }
        var it = std.mem.splitScalar(u8, rest, '.');
        const major_s = it.next() orelse return ParseError.InvalidVersion;
        const minor_s = it.next() orelse return ParseError.InvalidVersion;
        const patch_s = it.next() orelse return ParseError.InvalidVersion;
        if (it.next() != null) return ParseError.InvalidVersion;
        return Version{
            .major = try parseNumeric(major_s),
            .minor = try parseNumeric(minor_s),
            .patch = try parseNumeric(patch_s),
            .pre = pre,
            .build = build,
        };
    }

    /// Precedence: numeric core, then stable > any prerelease, then
    /// prerelease identifiers per semver section 11. Build metadata is
    /// IGNORED (semver section 10); use `eql` when build matters.
    pub fn order(self: Version, other: Version) std.math.Order {
        if (self.major != other.major) return std.math.order(self.major, other.major);
        if (self.minor != other.minor) return std.math.order(self.minor, other.minor);
        if (self.patch != other.patch) return std.math.order(self.patch, other.patch);
        return comparePre(self.pre, other.pre);
    }

    /// Full equality INCLUDING build metadata (the Locked rule in
    /// `semver_ext.rs::OptVersionReq::matches`: lockfiles pin reproducibility
    /// over semver-metadata-ignorance).
    pub fn eql(self: Version, other: Version) bool {
        return self.major == other.major and
            self.minor == other.minor and
            self.patch == other.patch and
            std.mem.eql(u8, self.pre, other.pre) and
            std.mem.eql(u8, self.build, other.build);
    }
};

/// Compare two raw prerelease strings per semver section 11. The empty string
/// denotes a STABLE version and sorts above every prerelease (this matches
/// the `semver` crate, where `Prerelease::EMPTY` is greater than any
/// non-empty prerelease).
pub fn comparePre(a: []const u8, b: []const u8) std.math.Order {
    if (a.len == 0 and b.len == 0) return .eq;
    if (a.len == 0) return .gt;
    if (b.len == 0) return .lt;
    var it_a = std.mem.splitScalar(u8, a, '.');
    var it_b = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const ia = it_a.next();
        const ib = it_b.next();
        if (ia == null and ib == null) return .eq;
        if (ia == null) return .lt;
        if (ib == null) return .gt;
        const ord = comparePreIdent(ia.?, ib.?);
        if (ord != .eq) return ord;
    }
}

fn comparePreIdent(a: []const u8, b: []const u8) std.math.Order {
    const a_num = isNumericIdent(a);
    const b_num = isNumericIdent(b);
    if (a_num and b_num) {
        // Numeric identifiers compare numerically. Length-then-lexicographic
        // avoids any integer-width overflow on adversarial inputs.
        if (a.len != b.len) return std.math.order(a.len, b.len);
        return std.mem.order(u8, a, b);
    }
    if (a_num) return .lt; // numeric < alphanumeric
    if (b_num) return .gt;
    return std.mem.order(u8, a, b);
}

fn isNumericIdent(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

fn parseNumeric(s: []const u8) ParseError!u64 {
    if (s.len == 0) return ParseError.InvalidVersion;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return ParseError.InvalidVersion;
    }
    if (s.len > 1 and s[0] == '0') return ParseError.InvalidVersion;
    return std.fmt.parseInt(u64, s, 10) catch return ParseError.InvalidVersion;
}

/// Validate dot-separated `pre`/`build` identifiers. `pre` additionally
/// rejects leading zeros on numeric identifiers (semver section 9);
/// `build` allows them (semver section 10).
fn checkIdentifiers(s: []const u8, is_pre: bool) ParseError!void {
    if (s.len == 0) return ParseError.InvalidVersion;
    var it = std.mem.splitScalar(u8, s, '.');
    while (it.next()) |ident| {
        if (ident.len == 0) return ParseError.InvalidVersion;
        for (ident) |c| {
            if (!(std.ascii.isDigit(c) or std.ascii.isAlphabetic(c) or c == '-'))
                return ParseError.InvalidVersion;
        }
        if (is_pre and isNumericIdent(ident) and ident.len > 1 and ident[0] == '0')
            return ParseError.InvalidVersion;
    }
}

pub const Op = enum { caret, tilde, exact, gte, lte, gt, lt, wildcard };

pub const Comparator = struct {
    op: Op,
    major: u64,
    minor: ?u64,
    patch: ?u64,
    pre: []const u8,
};

pub const VersionReq = struct {
    comparators: []Comparator, // comma-separated AND; empty means `*`

    /// Parse a requirement string: `*`, `^`, `~`, `=`, `>=`, `<=`, `>`, `<`,
    /// bare partials (`1`, `1.2`, `1.2.3`), wildcards (`1.*`, `1.2.*`, `x`),
    /// comma-separated AND combinations. Whitespace around predicates and
    /// between an operator and its version is accepted (cargo's own tests
    /// use `">= 1.2.3-0, < 1.3.0-0"`); anything else strict.
    ///
    /// Allocation note: comparators are allocated with
    /// `std.heap.page_allocator` and intentionally never freed (process-lifetime
    /// requirement cache for M3; requirements are tiny and few). Callers that
    /// need ownership (bounded lifetimes, leak-checked tests) use `parseAlloc`
    /// instead; callers must NOT free `comparators` from THIS function.
    pub fn parse(text: []const u8) ParseError!VersionReq {
        return parseInner(std.heap.page_allocator, text);
    }

    /// Owning parse: identical grammar to `parse`, but comparators AND the
    /// requirement text live in `gpa` (returned as `OwnedVersionReq`, freed
    /// with `deinit`). Required because `Comparator.pre` borrows from the
    /// input text: the text is duped first and parsing runs on the dupe, so
    /// the returned req never borrows the caller's buffer.
    pub fn parseAlloc(gpa: std.mem.Allocator, text: []const u8) ParseError!OwnedVersionReq {
        const buf = gpa.dupe(u8, text) catch return ParseError.OutOfMemory;
        errdefer gpa.free(buf);
        const req = try parseInner(gpa, buf);
        return OwnedVersionReq{
            .req = req,
            .text = buf,
            // `parseInner` allocates via `toOwnedSlice` only when at least
            // one comparator was appended; STAR/empty yields the static
            // `&[_]Comparator{}`, which must NOT be freed.
            .comparators_owned = req.comparators.len > 0,
        };
    }

    fn parseInner(alloc: std.mem.Allocator, text: []const u8) ParseError!VersionReq {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return ParseError.InvalidReq;
        // Lone STAR spellings (`*`, `x`, `X`) are all `VersionReq::STAR`
        // (empty comparators) per the `semver` crate: a bare wildcard names
        // no version and matches any stable version.
        if (isStarText(trimmed)) return VersionReq{ .comparators = &[_]Comparator{} };
        var list: std.ArrayList(Comparator) = .empty;
        errdefer list.deinit(alloc);
        var it = std.mem.splitScalar(u8, trimmed, ',');
        while (it.next()) |part| {
            const pred = std.mem.trim(u8, part, " \t\r\n");
            if (pred.len == 0) return ParseError.InvalidReq;
            // A STAR predicate inside an AND list contributes zero
            // comparators (e.g. `"*, ^1.0"` == `"^1.0"`).
            if (isStarText(pred)) continue;
            try list.append(alloc, try parsePredicate(pred));
        }
        return VersionReq{ .comparators = try list.toOwnedSlice(alloc) };
    }

    /// STOCK `semver`-crate rules (see module docs): AND over comparators,
    /// then the prerelease gate -- a prerelease version matches only when
    /// some comparator names a prerelease on the same `major.minor.patch`.
    /// Build metadata on the candidate is stripped before comparison
    /// (ignored); an EMPTY comparator list (`*`) therefore matches stable
    /// versions only, exactly like the `semver` crate's vacuous gate.
    pub fn matches(self: VersionReq, v: Version) bool {
        for (self.comparators) |c| {
            if (!matchesComparator(c, v)) return false;
        }
        if (v.pre.len == 0) return true;
        for (self.comparators) |c| {
            if (c.pre.len > 0 and c.major == v.major and
                (c.minor orelse v.minor) == v.minor and
                (c.patch orelse v.patch) == v.patch) return true;
        }
        return false;
    }

    /// RFC 3493 rules for the `--precise <prerelease>` path ONLY (direct port
    /// of `semver_eval_ext.rs::matches_prerelease`, quirks included -- see
    /// that file's warning about unresolved upper-bound behavior).
    pub fn matchesPrerelease(self: VersionReq, v: Version) bool {
        var lower_bound_prerelease = false;
        for (self.comparators) |c| {
            if ((c.op == .gt or c.op == .gte) and c.pre.len > 0) {
                lower_bound_prerelease = true;
                break;
            }
        }
        for (self.comparators) |c| {
            if (!matchesPrereleaseImpl(c, v, lower_bound_prerelease)) return false;
        }
        return true;
    }
};

/// Owning handle for `VersionReq.parseAlloc`: the req plus the `gpa`-owned
/// requirement text its `Comparator.pre` slices borrow from. `deinit` frees
/// both (the comparator slice only when `parseAlloc` actually allocated it --
/// STAR forms share the static empty slice).
pub const OwnedVersionReq = struct {
    req: VersionReq,
    text: []u8,
    comparators_owned: bool,
    pub fn deinit(self: *OwnedVersionReq, gpa: std.mem.Allocator) void {
        if (self.comparators_owned) gpa.free(self.req.comparators);
        gpa.free(self.text);
    }
};

fn parsePredicate(pred: []const u8) ParseError!Comparator {
    var rest = pred;
    var op: ?Op = null;
    if (std.mem.startsWith(u8, rest, ">=")) {
        op = .gte;
        rest = rest[2..];
    } else if (std.mem.startsWith(u8, rest, "<=")) {
        op = .lte;
        rest = rest[2..];
    } else if (std.mem.startsWith(u8, rest, ">")) {
        op = .gt;
        rest = rest[1..];
    } else if (std.mem.startsWith(u8, rest, "<")) {
        op = .lt;
        rest = rest[1..];
    } else if (std.mem.startsWith(u8, rest, "=")) {
        op = .exact;
        rest = rest[1..];
    } else if (std.mem.startsWith(u8, rest, "~")) {
        op = .tilde;
        rest = rest[1..];
    } else if (std.mem.startsWith(u8, rest, "^")) {
        op = .caret;
        rest = rest[1..];
    }
    rest = std.mem.trim(u8, rest, " \t\r\n");
    if (rest.len == 0) return ParseError.InvalidReq;

    // Split off build (accepted and ignored) then prerelease.
    var build: []const u8 = "";
    var core_pre = rest;
    if (std.mem.indexOfScalar(u8, core_pre, '+')) |i| {
        build = core_pre[i + 1 ..];
        core_pre = core_pre[0..i];
        try checkIdentifiers(build, false);
    }
    var pre: []const u8 = "";
    var core = core_pre;
    if (std.mem.indexOfScalar(u8, core_pre, '-')) |i| {
        pre = core_pre[i + 1 ..];
        core = core_pre[0..i];
        try checkIdentifiers(pre, true);
    }

    var parts: [3]?u64 = .{ null, null, null };
    var wildcards: u32 = 0;
    var it = std.mem.splitScalar(u8, core, '.');
    var n: usize = 0;
    while (it.next()) |part| : (n += 1) {
        if (n >= 3) return ParseError.InvalidReq;
        if (isWildcard(part)) {
            wildcards += 1;
        } else {
            if (wildcards > 0) return ParseError.InvalidReq; // e.g. `1.*.3`
            parts[n] = try parseReqNumeric(part);
        }
    }
    if (n == 0) return ParseError.InvalidReq;
    // `4.*.*` is allowed (trailing wildcards). A lone STAR spelling (`*`,
    // `x`, `X`) never reaches here: `parse` intercepts it and returns empty
    // comparators (STAR), so no special case is needed.
    if (wildcards > 0 and op != null) return ParseError.InvalidReq; // e.g. `>=1.*`

    const final_op = op orelse (if (wildcards > 0) Op.wildcard else Op.caret);
    return Comparator{
        .op = final_op,
        .major = parts[0] orelse return ParseError.InvalidReq,
        .minor = parts[1],
        .patch = parts[2],
        .pre = pre,
    };
}

fn isWildcard(s: []const u8) bool {
    return std.mem.eql(u8, s, "*") or std.mem.eql(u8, s, "x") or std.mem.eql(u8, s, "X");
}

/// Lone STAR spellings: `*`, `x`, `X` (the `semver` crate treats all three
/// as `VersionReq::STAR`). Only exact matches qualify; `x` with attached
/// pre/build (e.g. `x-alpha`) is NOT star and falls through to the normal
/// predicate parser.
fn isStarText(s: []const u8) bool {
    return std.mem.eql(u8, s, "*") or std.mem.eql(u8, s, "x") or std.mem.eql(u8, s, "X");
}

fn parseReqNumeric(s: []const u8) ParseError!u64 {
    if (s.len == 0) return ParseError.InvalidReq;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return ParseError.InvalidReq;
    }
    if (s.len > 1 and s[0] == '0') return ParseError.InvalidReq;
    return std.fmt.parseInt(u64, s, 10) catch return ParseError.InvalidReq;
}

// --- stock matching primitives (dtolnay/semver eval.rs shapes) ---

fn matchesComparator(c: Comparator, v: Version) bool {
    return switch (c.op) {
        .exact => matchesExact(c, v),
        .wildcard => matchesWildcard(c, v),
        .gt => matchesGreater(c, v),
        .gte => matchesExact(c, v) or matchesGreater(c, v),
        .lt => matchesLess(c, v),
        .lte => matchesExact(c, v) or matchesLess(c, v),
        .tilde => matchesTilde(c, v),
        .caret => matchesCaret(c, v),
    };
}

fn matchesExact(c: Comparator, v: Version) bool {
    if (v.major != c.major) return false;
    if (c.minor) |m| {
        if (v.minor != m) return false;
    }
    if (c.patch) |p| {
        if (v.patch != p) return false;
    }
    return comparePre(v.pre, c.pre) == .eq;
}

fn matchesWildcard(c: Comparator, v: Version) bool {
    // Specified components must be equal; prereleases are handled by the
    // global gate in `matches` (a bare wildcard never names `pre`).
    if (v.major != c.major) return false;
    if (c.minor) |m| {
        if (v.minor != m) return false;
    }
    if (c.patch) |p| {
        if (v.patch != p) return false;
    }
    return true;
}

fn matchesGreater(c: Comparator, v: Version) bool {
    if (v.major != c.major) return v.major > c.major;
    const minor = c.minor orelse return false;
    if (v.minor != minor) return v.minor > minor;
    const patch = c.patch orelse return false;
    if (v.patch != patch) return v.patch > patch;
    return comparePre(v.pre, c.pre) == .gt;
}

fn matchesLess(c: Comparator, v: Version) bool {
    if (v.major != c.major) return v.major < c.major;
    const minor = c.minor orelse return false;
    if (v.minor != minor) return v.minor < minor;
    const patch = c.patch orelse return false;
    if (v.patch != patch) return v.patch < patch;
    return comparePre(v.pre, c.pre) == .lt;
}

fn fillPartial(c: Comparator) Comparator {
    var out = c;
    if (out.minor == null) {
        out.minor = 0;
        out.patch = 0;
    } else if (out.patch == null) {
        out.patch = 0;
    }
    return out;
}

/// Caret upper bound per the cargo table (`^1.2.3 -> <2.0.0`,
/// `^0.2.3 -> <0.3.0`, `^0.0.3 -> <0.0.4`, `^1.2 -> <2.0.0`, `^1 -> <2.0.0`,
/// `^0 -> <1.0.0`, `^0.0 -> <0.1.0`): bump the left-most non-zero component,
/// else the last specified one. On `u64` overflow the bound is unbounded
/// (unreachable for real versions; documented, not silently wrapped).
fn caretUpperFull(c: Comparator) ?Comparator {
    if (c.major > 0) {
        if (c.major == std.math.maxInt(u64)) return null;
        return Comparator{ .op = .lt, .major = c.major + 1, .minor = 0, .patch = 0, .pre = "" };
    }
    if (c.minor == null) {
        if (c.major == std.math.maxInt(u64)) return null;
        return Comparator{ .op = .lt, .major = c.major + 1, .minor = 0, .patch = 0, .pre = "" };
    }
    const minor = c.minor.?;
    if (minor > 0 or c.patch == null) {
        if (minor == std.math.maxInt(u64)) return null;
        return Comparator{ .op = .lt, .major = 0, .minor = minor + 1, .patch = 0, .pre = "" };
    }
    const patch = c.patch.?;
    if (patch == std.math.maxInt(u64)) return null;
    return Comparator{ .op = .lt, .major = 0, .minor = 0, .patch = patch + 1, .pre = "" };
}

fn matchesCaret(c: Comparator, v: Version) bool {
    if (matchesExact(c, v)) return true;
    if (!matchesGreater(fillPartial(c), v)) return false;
    const upper = caretUpperFull(c) orelse return true;
    return matchesLess(upper, v);
}

/// Tilde upper bound (`~1.2.3 -> <1.3.0`, `~1.2 -> <1.3.0`, `~1 -> <2.0.0`).
fn tildeUpper(c: Comparator) ?Comparator {
    if (c.minor) |minor| {
        if (minor == std.math.maxInt(u64)) return null;
        return Comparator{ .op = .lt, .major = c.major, .minor = minor + 1, .patch = 0, .pre = "" };
    }
    if (c.major == std.math.maxInt(u64)) return null;
    return Comparator{ .op = .lt, .major = c.major + 1, .minor = 0, .patch = 0, .pre = "" };
}

fn matchesTilde(c: Comparator, v: Version) bool {
    if (matchesExact(c, v)) return true;
    if (!matchesGreater(fillPartial(c), v)) return false;
    const upper = tildeUpper(c) orelse return true;
    return matchesLess(upper, v);
}

// --- RFC 3493 prerelease matching (semver_eval_ext.rs port) ---

fn matchesPrereleaseImpl(c: Comparator, v: Version, lower_bound_prerelease: bool) bool {
    switch (c.op) {
        .exact, .wildcard => return matchesExactPrerelease(c, v),
        .gt => return matchesGreater(c, v),
        .gte => {
            if (matchesExactPrerelease(c, v)) return true;
            return matchesGreater(c, v);
        },
        .lt => {
            if (lower_bound_prerelease) {
                return matchesLess(fillPartial(c), v);
            } else {
                return matchesLess(fillPartialIncludePre(c), v);
            }
        },
        .lte => {
            if (matchesExactPrerelease(c, v)) return true;
            return matchesLess(fillPartial(c), v);
        },
        .tilde => return matchesTildePrerelease(c, v),
        .caret => return matchesCaretPrerelease(c, v),
    }
}

fn fillPartialIncludePre(c: Comparator) Comparator {
    // Mirrors `fill_partial_req_include_pre` verbatim
    // (references/cargo/src/cargo/util/semver_eval_ext.rs:142-155): when
    // `minor` is absent, `pre` is OVERWRITTEN to "0" even if the comparator
    // already names a prerelease (e.g. `<1-alpha` -> `<1.0.0-0`); only the
    // `patch == null` arm preserves an existing `pre`.
    var out = c;
    if (out.minor == null) {
        out.minor = 0;
        out.patch = 0;
        out.pre = "0";
    } else if (out.patch == null) {
        out.patch = 0;
    }
    if (out.pre.len == 0) out.pre = "0";
    return out;
}

fn matchesExactPrerelease(c: Comparator, v: Version) bool {
    if (matchesExact(c, v)) return true;
    // A comparator WITH a prerelease tag only ever matches exactly.
    if (c.pre.len > 0) return false;
    if (!matchesGreater(fillPartial(c), v)) return false;
    var upper = c;
    upper.op = .lt;
    upper.pre = "0";
    if (upper.minor != null and upper.patch != null) {
        const p = upper.patch.?;
        if (p == std.math.maxInt(u64)) return false;
        upper.patch = p + 1;
    } else if (upper.minor != null) {
        const m = upper.minor.?;
        if (m == std.math.maxInt(u64)) return false;
        upper.minor = m + 1;
        upper.patch = 0;
    } else if (upper.patch == null) {
        if (upper.major == std.math.maxInt(u64)) return false;
        upper.major += 1;
        upper.minor = 0;
        upper.patch = 0;
    }
    return matchesLess(upper, v);
}

fn matchesTildePrerelease(c: Comparator, v: Version) bool {
    if (matchesExact(c, v)) return true;
    if (!matchesGreater(fillPartial(c), v)) return false;
    var upper = c;
    upper.op = .lt;
    upper.pre = "0";
    if (upper.minor != null) {
        const m = upper.minor.?;
        if (m == std.math.maxInt(u64)) return false;
        upper.minor = m + 1;
        upper.patch = 0;
    } else {
        if (upper.major == std.math.maxInt(u64)) return false;
        upper.major += 1;
        upper.minor = 0;
        upper.patch = 0;
    }
    return matchesLess(upper, v);
}

fn matchesCaretPrerelease(c: Comparator, v: Version) bool {
    if (matchesExact(c, v)) return true;
    if (!matchesGreater(fillPartial(c), v)) return false;
    var upper = c;
    upper.op = .lt;
    upper.pre = "0";
    const minor_some = upper.minor != null;
    const patch_some = upper.patch != null;
    if (upper.major > 0 or (!minor_some and !patch_some)) {
        if (upper.major == std.math.maxInt(u64)) return false;
        upper.major += 1;
        upper.minor = 0;
        upper.patch = 0;
    } else if (minor_some and !patch_some) {
        const m = upper.minor.?;
        if (m == std.math.maxInt(u64)) return false;
        upper.minor = m + 1;
        upper.patch = 0;
    } else if (minor_some and upper.minor.? > 0) {
        const m = upper.minor.?;
        if (m == std.math.maxInt(u64)) return false;
        upper.minor = m + 1;
        upper.patch = 0;
    } else if (minor_some and upper.minor.? == 0) {
        if (upper.patch == null) {
            upper.patch = 1;
        } else {
            const p = upper.patch.?;
            if (p == std.math.maxInt(u64)) return false;
            upper.patch = p + 1;
        }
    }
    return matchesLess(upper, v);
}

pub const OptVersionReq = union(enum) {
    any: void,
    req: VersionReq,
    locked: struct { version: Version, req: VersionReq },
    precise: struct { version: Version, req: VersionReq },

    pub fn matches(self: OptVersionReq, v: Version) bool {
        switch (self) {
            .any => return true,
            .req => |r| return r.matches(v),
            // Locked pins full `==` INCLUDING build metadata (reproducibility
            // over semver-metadata-ignorance; semver_ext.rs Locked arm).
            .locked => |l| return l.version.eql(v),
            // Precise matches major/minor/patch/pre exactly; build metadata
            // only constrains when the precise request names it.
            .precise => |p| return p.version.major == v.major and
                p.version.minor == v.minor and
                p.version.patch == v.patch and
                std.mem.eql(u8, p.version.pre, v.pre) and
                (p.version.build.len == 0 or std.mem.eql(u8, p.version.build, v.build)),
        }
    }

    /// Pin to `v`, asserting the current requirement matches first (cargo's
    /// `assert!(self.matches(version))` in `lock_to`,
    /// references/cargo/src/cargo/util/semver_ext.rs:86-94). Rust `assert!`
    /// fires in ALL profiles, so this uses an unconditional `@panic` rather
    /// than `std.debug.assert` (which is compiled out in ReleaseFast/Small).
    pub fn lockTo(self: *OptVersionReq, v: Version) void {
        if (!self.matches(v)) @panic("OptVersionReq.lockTo: version does not match requirement");
        switch (self.*) {
            .any => self.* = .{ .locked = .{ .version = v, .req = .{ .comparators = &[_]Comparator{} } } },
            .req => |r| self.* = .{ .locked = .{ .version = v, .req = r } },
            .locked => |l| self.* = .{ .locked = .{ .version = v, .req = l.req } },
            .precise => |p| self.* = .{ .locked = .{ .version = v, .req = p.req } },
        }
    }
};

test "semver parses versions strictly" {
    const v = try Version.parse("1.2.3");
    try std.testing.expectEqual(@as(u64, 1), v.major);
    try std.testing.expectError(ParseError.InvalidVersion, Version.parse("1.2"));
    try std.testing.expectError(ParseError.InvalidVersion, Version.parse("v1.2.3"));
    try std.testing.expectError(ParseError.InvalidVersion, Version.parse("01.2.3"));
    const pre = try Version.parse("1.0.0-alpha.1+build.5");
    try std.testing.expectEqualStrings("alpha.1", pre.pre);
    try std.testing.expectEqualStrings("build.5", pre.build);
}

test "semver caret ranges expand per cargo table" {
    const cases = [_]struct { req: []const u8, yes: []const u8, no: []const u8 }{
        .{ .req = "^1.2.3", .yes = "1.9.0", .no = "2.0.0" },
        .{ .req = "^0.2.3", .yes = "0.2.9", .no = "0.3.0" },
        .{ .req = "^0.0.3", .yes = "0.0.3", .no = "0.0.4" },
        .{ .req = "1.2", .yes = "1.9.0", .no = "2.0.0" },
        .{ .req = "~1.2.3", .yes = "1.2.9", .no = "1.3.0" },
        .{ .req = ">=1.2.3, <2.0.0", .yes = "1.5.0", .no = "2.0.0" },
        .{ .req = "*", .yes = "0.1.1", .no = "" },
    };
    for (cases) |c| {
        const req = try VersionReq.parse(c.req);
        try std.testing.expect(req.matches(try Version.parse(c.yes)));
        if (c.no.len > 0) try std.testing.expect(!req.matches(try Version.parse(c.no)));
    }
}

test "semver stock matching excludes prereleases" {
    const req = try VersionReq.parse("^1.2.3");
    try std.testing.expect(!req.matches(try Version.parse("1.5.0-alpha")));
    const with_pre = try VersionReq.parse(">=1.2.3-alpha, <2.0.0");
    try std.testing.expect(with_pre.matchesPrerelease(try Version.parse("1.5.0-alpha")));
    // Locked pins build metadata exactly (util/semver_ext.rs Locked arm).
    var l = OptVersionReq{ .locked = .{ .version = try Version.parse("1.0.0+bar"), .req = try VersionReq.parse("*") } };
    try std.testing.expect(!l.matches(try Version.parse("1.0.0+foo")));
    try std.testing.expect(l.matches(try Version.parse("1.0.0+bar")));
    // Precise without build in request ignores build in candidate.
    var p = OptVersionReq{ .precise = .{ .version = try Version.parse("1.0.0"), .req = try VersionReq.parse("*") } };
    try std.testing.expect(p.matches(try Version.parse("1.0.0+anything")));
}

test "semver wildcard and partial forms" {
    const w = try VersionReq.parse("1.2.*");
    try std.testing.expect(w.matches(try Version.parse("1.2.9")));
    try std.testing.expect(!w.matches(try Version.parse("1.3.0")));
    try std.testing.expect(!w.matches(try Version.parse("1.2.9-alpha")));
    const star = try VersionReq.parse("*");
    try std.testing.expect(star.matches(try Version.parse("9.9.9")));
    // Stock STAR (like the semver crate) does not admit prereleases;
    // `OptVersionReq.any` (manifest-missing req) does.
    try std.testing.expect(!star.matches(try Version.parse("9.9.9-alpha")));
    try std.testing.expect((OptVersionReq{ .any = {} }).matches(try Version.parse("9.9.9-alpha")));
    const eq = try VersionReq.parse("=1.2.3");
    try std.testing.expect(eq.matches(try Version.parse("1.2.3")));
    try std.testing.expect(!eq.matches(try Version.parse("1.2.4")));
    const one = try VersionReq.parse("1");
    try std.testing.expect(one.matches(try Version.parse("1.99.0")));
    try std.testing.expect(!one.matches(try Version.parse("2.0.0")));
    const zero = try VersionReq.parse("0");
    try std.testing.expect(zero.matches(try Version.parse("0.9.9")));
    try std.testing.expect(!zero.matches(try Version.parse("1.0.0")));
}

test "semver tilde partials and build stripping" {
    const t1 = try VersionReq.parse("~1.2");
    try std.testing.expect(t1.matches(try Version.parse("1.2.7")));
    try std.testing.expect(!t1.matches(try Version.parse("1.3.0")));
    const t0 = try VersionReq.parse("~1");
    try std.testing.expect(t0.matches(try Version.parse("1.7.0")));
    try std.testing.expect(!t0.matches(try Version.parse("2.0.0")));
    // Build metadata is ignored by requirement matching.
    const r = try VersionReq.parse("^1.2.3");
    try std.testing.expect(r.matches(try Version.parse("1.5.0+inhouse")));
    try std.testing.expect((try Version.parse("1.5.0+inhouse")).order(try Version.parse("1.5.0")) == .eq);
}

test "semver matches_prerelease tracks cargo vectors" {
    // Subset of `semver_ext.rs::matches_prerelease::prerelease` (the RFC 3493
    // tracking test, quirks included -- e.g. `>1.2.3, <1.2.4` vs `1.2.4-0`
    // is false: the "upper bound semantic" issue).
    const cases = [_]struct { req: []const u8, ver: []const u8, yes: bool }{
        .{ .req = "1.2.3", .ver = "1.2.3-0", .yes = false },
        .{ .req = "1.2.3", .ver = "1.2.4-0", .yes = true },
        .{ .req = ">=1.2.3", .ver = "1.2.4-0", .yes = true },
        .{ .req = ">1.2.3, <1.2.4", .ver = "1.2.4-0", .yes = false },
        .{ .req = ">1.2.3, <=1.2.4", .ver = "1.2.4-0", .yes = true },
        .{ .req = ">=1.2.3-0, <1.2.3", .ver = "1.2.3-0", .yes = true },
        .{ .req = ">=1.2.3-0, <1.2.3", .ver = "1.2.4-0", .yes = false },
        .{ .req = "=1.2.3-0", .ver = "1.2.3-0", .yes = true },
        .{ .req = "=1.2.3-0", .ver = "1.2.3", .yes = false },
        .{ .req = ">=1.2.3-2, <1.2.3-4", .ver = "1.2.3-3", .yes = true },
        .{ .req = ">=1.2.3-2, <1.2.3-4", .ver = "1.2.3-5", .yes = false },
        .{ .req = "^1.2.3", .ver = "1.9.9", .yes = true },
        .{ .req = "^1.2.3", .ver = "1.2.3-0", .yes = false },
        .{ .req = "^0.0.3", .ver = "0.0.3", .yes = true },
        .{ .req = "^0.0.3", .ver = "0.0.3-1", .yes = false },
        .{ .req = "~1.2.3", .ver = "1.2.4-0", .yes = true },
        .{ .req = "~1.2.3", .ver = "1.2.3-0", .yes = false },
        .{ .req = "4.2.*", .ver = "4.2.9", .yes = true },
        .{ .req = "4.2.*", .ver = "4.2.0-0", .yes = false },
    };
    for (cases) |c| {
        const req = try VersionReq.parse(c.req);
        const ver = try Version.parse(c.ver);
        try std.testing.expectEqual(c.yes, req.matchesPrerelease(ver));
    }
}

test "semver lockTo pins and asserts" {
    var r = OptVersionReq{ .req = try VersionReq.parse("^1.0.0") };
    r.lockTo(try Version.parse("1.4.2"));
    try std.testing.expect(r.matches(try Version.parse("1.4.2")));
    try std.testing.expect(!r.matches(try Version.parse("1.4.3")));
    var a = OptVersionReq{ .any = {} };
    a.lockTo(try Version.parse("2.0.0"));
    try std.testing.expect(a.matches(try Version.parse("2.0.0")));
    try std.testing.expect(!a.matches(try Version.parse("2.0.1")));
}

test "semver lone x/X parse to STAR" {
    // The `semver` crate treats `*`, `x`, and `X` identically as
    // `VersionReq::STAR` (zero comparators), matching any stable version.
    for ([_][]const u8{ "*", "x", "X" }) |s| {
        const req = try VersionReq.parse(s);
        try std.testing.expectEqual(@as(usize, 0), req.comparators.len);
        try std.testing.expect(req.matches(try Version.parse("1.2.3")));
        // STAR still excludes prereleases under stock rules.
        try std.testing.expect(!req.matches(try Version.parse("1.2.3-alpha")));
    }
    // A STAR predicate inside an AND list contributes zero comparators.
    const and_req = try VersionReq.parse("x, ^1.0.0");
    try std.testing.expectEqual(@as(usize, 1), and_req.comparators.len);
    try std.testing.expect(and_req.matches(try Version.parse("1.5.0")));
    try std.testing.expect(!and_req.matches(try Version.parse("2.0.0")));
}

test "semver fillPartialIncludePre overwrites pre when minor absent" {
    // Cargo verbatim (`fill_partial_req_include_pre`): `<1-beta` fills to
    // `<1.0.0-0`, NOT `<1.0.0-beta`, so `1.0.0-alpha` (which is < `-beta`
    // but > `-0`) does NOT match.
    const req = try VersionReq.parse("<1-beta");
    try std.testing.expect(!req.matchesPrerelease(try Version.parse("1.0.0-alpha")));
    // With minor present the existing pre IS preserved (`<1.0-beta` stays
    // `<1.0.0-beta`), so the lower prerelease matches.
    const req2 = try VersionReq.parse("<1.0-beta");
    try std.testing.expect(req2.matchesPrerelease(try Version.parse("1.0.0-alpha")));
}

test "semver parseAlloc owns its memory" {
    // Identical matching to `parse`, but fully owned by the caller
    // (leak-checked here via `std.testing.allocator`).
    const gpa = std.testing.allocator;
    var owned = try VersionReq.parseAlloc(gpa, ">=1.2.3-alpha, <2.0.0");
    defer owned.deinit(gpa);
    try std.testing.expect(owned.req.matches(try Version.parse("1.5.0")));
    try std.testing.expect(!owned.req.matches(try Version.parse("2.0.0")));
    try std.testing.expect(owned.req.matchesPrerelease(try Version.parse("1.5.0-alpha")));
    // The prerelease slice borrows the DUPED text, not the caller buffer:
    // mutating the input afterwards cannot change matching.
    const input: []u8 = try gpa.dupe(u8, ">=1.0.0-alpha");
    defer gpa.free(input);
    var owned2 = try VersionReq.parseAlloc(gpa, input);
    defer owned2.deinit(gpa);
    @memset(input, ' ');
    try std.testing.expect(owned2.req.matchesPrerelease(try Version.parse("1.0.0-alpha")));
    // STAR forms share the static empty slice; deinit frees text only.
    var star = try VersionReq.parseAlloc(gpa, "*");
    defer star.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), star.req.comparators.len);
    try std.testing.expect(star.req.matches(try Version.parse("1.2.3")));
    // All-STAR AND list (zero comparators via toOwnedSlice, not the static).
    var stars = try VersionReq.parseAlloc(gpa, "*, x");
    defer stars.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), stars.req.comparators.len);
    try std.testing.expectError(ParseError.InvalidReq, VersionReq.parseAlloc(gpa, ""));
}
