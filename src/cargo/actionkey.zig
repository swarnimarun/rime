//! Action keys (M4 Task 5): content-bound cache keys over the unit
//! fingerprint, normalized rustc argv, input bytes, and tracked env
//! (storage-v2 §5.3 contents rule + §11.3 tags; sccache Rust-key model).
//!
//! Normalization (normative): paths that vary per machine/run (`--out-dir`,
//! incremental session dirs, absolute dep rlib paths) are canonicalized to
//! `store:<hex>` / `spool:<basename>` form or dropped; everything else is
//! hashed verbatim in argv order.
//!
//! Ownership: every returned slice is gpa-owned (`featuresTag`,
//! `normalizeArgs` elements + outer slice, `actionKey` is a value type,
//! `collectTrackedEnv` elements + outer slice, `unitTags` outer slice).
//! `unitTags` keys are statics and values borrow the inputs — the slice is
//! valid only while the inputs live.

const std = @import("std");
const store_mod = @import("store");
const fingerprint_mod = @import("fingerprint.zig");

const Digest = store_mod.Digest;
const Tag = store_mod.Tag;
const Fingerprint = fingerprint_mod.Fingerprint;

pub const ActionError = error{ OutOfMemory } || std.mem.Allocator.Error;

/// Env vars that enter the action key (`"K=V"` pairs via collectTrackedEnv).
/// Anything else (notably absolute-Path-carrying `OUT_DIR`-style vars and
/// per-run TMPDIRs) is inherited by the child but never keyed.
pub const tracked_env_vars = [_][]const u8{ "RUSTFLAGS", "RUSTDOCFLAGS", "CARGO_ENCODED_RUSTFLAGS", "RUSTC_BOOTSTRAP" };

/// `fh-<16 hex>` over the `+`-joined SORTED feature set (storage-v2 §11.3
/// `features` shape — validates under the index `TagMismatch` gate; the
/// empty set hashes `""`, still `fh-` + 16 hex, never bare).
pub fn featuresTag(gpa: std.mem.Allocator, feats: []const []const u8) ActionError![]u8 {
    const cp = try gpa.dupe([]const u8, feats);
    defer gpa.free(cp);
    std.mem.sort([]const u8, cp, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    var h = std.crypto.hash.Blake3.init(.{});
    for (cp, 0..) |f, i| {
        if (i > 0) h.update("+");
        h.update(f);
    }
    var out: [32]u8 = undefined;
    h.final(&out);
    const hex = std.fmt.bytesToHex(out, .lower);
    return std.fmt.allocPrint(gpa, "fh-{s}", .{hex[0..16]});
}

/// Normalizes argv per the key table: drops `--out-dir` (pair and `=` form)
/// and `-C incremental=…` (pair and `-Cincremental=` form); rewrites
/// `--extern` / `-L` path halves to `store:<hex>` / `spool:<basename>`;
/// everything else verbatim, order preserved. Every element gpa-owned.
pub fn normalizeArgs(gpa: std.mem.Allocator, argv: []const []const u8) ActionError![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |s| gpa.free(s);
        out.deinit(gpa);
    }
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--out-dir")) {
            i += 1; // drop the spool path pair (loop's own increment skips it)
            continue;
        }
        if (std.mem.startsWith(u8, a, "--out-dir=")) continue;
        if (std.mem.eql(u8, a, "-C") and i + 1 < argv.len and std.mem.startsWith(u8, argv[i + 1], "incremental=")) {
            i += 1; // drop the session-dir pair (the session digest enters via input_digest)
            continue;
        }
        if (std.mem.startsWith(u8, a, "-Cincremental=")) continue;
        if (std.mem.eql(u8, a, "--extern")) {
            // Pair form canonicalizes to the same two elements (flag kept).
            try out.append(gpa, try gpa.dupe(u8, a));
            if (i + 1 < argv.len) {
                try out.append(gpa, try rewriteExternValue(gpa, argv[i + 1]));
                i += 1;
            }
            continue;
        }
        if (std.mem.startsWith(u8, a, "--extern=")) {
            // `=` form canonicalizes to the pair form above.
            try out.append(gpa, try gpa.dupe(u8, "--extern"));
            try out.append(gpa, try rewriteExternValue(gpa, a["--extern=".len..]));
            continue;
        }
        if (std.mem.eql(u8, a, "-L")) {
            try out.append(gpa, try gpa.dupe(u8, a));
            if (i + 1 < argv.len) {
                try out.append(gpa, try rewriteLValue(gpa, argv[i + 1]));
                i += 1;
            }
            continue;
        }
        if (a.len > 2 and std.mem.startsWith(u8, a, "-L")) {
            try out.append(gpa, try gpa.dupe(u8, "-L"));
            try out.append(gpa, try rewriteLValue(gpa, a["-L".len..]));
            continue;
        }
        try out.append(gpa, try gpa.dupe(u8, a));
    }
    return out.toOwnedSlice(gpa);
}

/// Rewrites an absolute path to its shareable form: store object paths
/// (`…/objects/ab/cdef…`) become `store:<64hex>` (hex from the trailing two
/// path segments); everything else becomes `spool:<basename>`.
fn rewritePath(gpa: std.mem.Allocator, path: []const u8) ActionError![]u8 {
    if (std.mem.indexOf(u8, path, "/objects/")) |idx| {
        const rest = path[idx + "/objects/".len..];
        if (std.mem.lastIndexOfScalar(u8, rest, '/')) |s| {
            return std.fmt.allocPrint(gpa, "store:{s}{s}", .{ rest[0..s], rest[s + 1 ..] });
        }
        return std.fmt.allocPrint(gpa, "store:{s}", .{rest});
    }
    return std.fmt.allocPrint(gpa, "spool:{s}", .{std.fs.path.basename(path)});
}

/// `--extern` pair value `name=path` → `name=<rewritten>`; a bare crate
/// name (no `=`) passes through verbatim (rustc resolves it via `-L`).
fn rewriteExternValue(gpa: std.mem.Allocator, v: []const u8) ActionError![]u8 {
    const eq = std.mem.indexOfScalar(u8, v, '=') orelse return gpa.dupe(u8, v);
    const rewritten = try rewritePath(gpa, v[eq + 1 ..]);
    defer gpa.free(rewritten);
    return std.fmt.allocPrint(gpa, "{s}={s}", .{ v[0..eq], rewritten });
}

/// `-L` value `kind=path` → `kind=<rewritten>`; a bare path (no `=`)
/// rewrites as a path.
fn rewriteLValue(gpa: std.mem.Allocator, v: []const u8) ActionError![]u8 {
    const eq = std.mem.indexOfScalar(u8, v, '=') orelse return rewritePath(gpa, v);
    const rewritten = try rewritePath(gpa, v[eq + 1 ..]);
    defer gpa.free(rewritten);
    return std.fmt.allocPrint(gpa, "{s}={s}", .{ v[0..eq], rewritten });
}

/// Canonical action-key join (prefix `rime-action-v1\x00`):
/// `fp.toDigest().raw \x00 argc \x00 argv… \x00 input_digest.raw \x00 env…`,
/// `\x00` after every field. `env_pairs` must already be the sorted
/// `"K=V"` tracked-var snapshot (collectTrackedEnv shape).
pub fn actionKey(
    gpa: std.mem.Allocator,
    fp: *const Fingerprint,
    normalized_argv: []const []const u8,
    input_digest: Digest,
    env_pairs: []const []const u8,
) ActionError!Digest {
    var h = std.crypto.hash.Blake3.init(.{});
    h.update("rime-action-v1\x00");
    const fpd = fp.toDigest();
    h.update(&fpd.bytes);
    h.update(&[_]u8{0});
    const argc = try std.fmt.allocPrint(gpa, "{d}", .{normalized_argv.len});
    defer gpa.free(argc);
    h.update(argc);
    h.update(&[_]u8{0});
    for (normalized_argv) |a| {
        h.update(a);
        h.update(&[_]u8{0});
    }
    h.update(&input_digest.bytes);
    h.update(&[_]u8{0});
    for (env_pairs) |e| {
        h.update(e);
        h.update(&[_]u8{0});
    }
    var out: [32]u8 = undefined;
    h.final(&out);
    return .{ .bytes = out };
}

/// `"K=V"` snapshot of the tracked vars (absent vars omitted), sorted by
/// key. `std.c.getenv` needs sentinel keys, so each name is duped with a
/// terminator first (the toolchain `$RUSTC` precedent).
pub fn collectTrackedEnv(gpa: std.mem.Allocator) ActionError![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |s| gpa.free(s);
        out.deinit(gpa);
    }
    for (tracked_env_vars) |k| {
        const zname = try gpa.dupeZ(u8, k);
        defer gpa.free(zname);
        if (std.c.getenv(zname)) |z| {
            try out.append(gpa, try std.fmt.allocPrint(gpa, "{s}={s}", .{ k, std.mem.span(z) }));
        }
    }
    std.mem.sort([]u8, out.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, keyOf(a), keyOf(b)) == .lt;
        }
        fn keyOf(s: []const u8) []const u8 {
            return s[0 .. std.mem.indexOfScalar(u8, s, '=') orelse s.len];
        }
    }.lt);
    return out.toOwnedSlice(gpa);
}

/// The exact §11.3 key set in vocabulary order (`crate`, `crate_version`,
/// `toolchain`, `target`, `profile`, `features`, `project`, `action`) with
/// `action` ALWAYS `"rustc"` — `"check"` is not in the action vocabulary
/// and `tagObject` rejects it; `CompileMode` already feeds the
/// fingerprint's profile hash so check and build keys never collide.
/// Gpa-owned 8-slice; keys are statics, values borrow the inputs.
pub fn unitTags(
    gpa: std.mem.Allocator,
    tc_tag: []const u8,
    triple: []const u8,
    profile_name: []const u8,
    features_tag: []const u8,
    project_id: []const u8,
    pkg_name: []const u8,
    version: []const u8,
    action: []const u8,
) ActionError![]Tag {
    const out = try gpa.alloc(Tag, 8);
    out[0] = .{ .key = "crate", .value = pkg_name };
    out[1] = .{ .key = "crate_version", .value = version };
    out[2] = .{ .key = "toolchain", .value = tc_tag };
    out[3] = .{ .key = "target", .value = triple };
    out[4] = .{ .key = "profile", .value = profile_name };
    out[5] = .{ .key = "features", .value = features_tag };
    out[6] = .{ .key = "project", .value = project_id };
    out[7] = .{ .key = "action", .value = action };
    return out;
}

test "action key ignores out-dir and incremental paths" {
    const a = [_][]const u8{ "rustc", "--crate-name", "foo", "--out-dir", "/tmp/spool-1", "-C", "incremental=/tmp/sess" };
    const b = [_][]const u8{ "rustc", "--crate-name", "foo", "--out-dir", "/tmp/spool-2", "-C", "incremental=/tmp/sess2" };
    const na = try normalizeArgs(std.testing.allocator, &a);
    defer {
        for (na) |s| std.testing.allocator.free(s);
        std.testing.allocator.free(na);
    }
    const nb = try normalizeArgs(std.testing.allocator, &b);
    defer {
        for (nb) |s| std.testing.allocator.free(s);
        std.testing.allocator.free(nb);
    }
    try std.testing.expectEqualStrings("rustc", na[0]);
    try std.testing.expectEqual(@as(usize, 3), na.len);
    // keys over identical fingerprints + normalized argv are identical
    const fp = Fingerprint{ .rustc_digest = store_mod.hashBytes("r"), .features_sorted = &.{}, .target_desc_hash = store_mod.hashBytes("t"), .profile_hash = store_mod.hashBytes("p"), .path_hash = store_mod.hashBytes("h"), .dep_fps = &.{}, .rustflags_hash = store_mod.hashBytes(""), .config_hash = store_mod.hashBytes("c") };
    const ka = try actionKey(std.testing.allocator, &fp, na, store_mod.hashBytes("in"), &.{});
    const kb = try actionKey(std.testing.allocator, &fp, nb, store_mod.hashBytes("in"), &.{});
    try std.testing.expectEqual(ka.bytes, kb.bytes);
}

test "features tag matches the index vocabulary" {
    const t = try featuresTag(std.testing.allocator, &.{ "tls", "json" });
    defer std.testing.allocator.free(t);
    try std.testing.expect(std.mem.startsWith(u8, t, "fh-"));
    try std.testing.expectEqual(@as(usize, 19), t.len);
    for (t[3..]) |ch| try std.testing.expect((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f'));
    // Order-insensitive: same set, different order, same tag.
    const u = try featuresTag(std.testing.allocator, &.{ "json", "tls" });
    defer std.testing.allocator.free(u);
    try std.testing.expectEqualStrings(t, u);
    // Empty set is still fh- + 16 hex (never bare).
    const e = try featuresTag(std.testing.allocator, &.{});
    defer std.testing.allocator.free(e);
    try std.testing.expectEqual(@as(usize, 19), e.len);
    try std.testing.expect(std.mem.startsWith(u8, e, "fh-"));
}

test "extern store paths canonicalize across checkouts" {
    const gpa = std.testing.allocator;
    const a = [_][]const u8{ "--extern", "serde=/cache/objects/ab/cdef1234" };
    const na = try normalizeArgs(gpa, &a);
    defer {
        for (na) |s| gpa.free(s);
        gpa.free(na);
    }
    // name= preserved, path rewritten to the store form.
    try std.testing.expectEqualStrings("serde=store:abcdef1234", na[1]);
    // A different checkout prefix over the same object normalizes identically.
    const b = [_][]const u8{ "--extern", "serde=/other/checkout/objects/ab/cdef1234" };
    const nb = try normalizeArgs(gpa, &b);
    defer {
        for (nb) |s| gpa.free(s);
        gpa.free(nb);
    }
    try std.testing.expectEqualStrings(na[1], nb[1]);
    // Non-store paths collapse to spool:<basename>; flags are kept so the
    // normalized argv stays flag-shaped (na[0] is always the flag).
    const c = [_][]const u8{ "--extern", "foo=/tmp/spool-1/libfoo.rlib", "-L", "dependency=/tmp/spool-1" };
    const nc = try normalizeArgs(gpa, &c);
    defer {
        for (nc) |s| gpa.free(s);
        gpa.free(nc);
    }
    try std.testing.expectEqual(@as(usize, 4), nc.len);
    try std.testing.expectEqualStrings("--extern", nc[0]);
    try std.testing.expectEqualStrings("foo=spool:libfoo.rlib", nc[1]);
    try std.testing.expectEqualStrings("-L", nc[2]);
    try std.testing.expectEqualStrings("dependency=spool:spool-1", nc[3]);
    // `=` spellings canonicalize to the same pair form.
    const d = [_][]const u8{ "--extern=foo=/tmp/spool-1/libfoo.rlib", "-Ldependency=/tmp/spool-1" };
    const nd = try normalizeArgs(gpa, &d);
    defer {
        for (nd) |s| gpa.free(s);
        gpa.free(nd);
    }
    try std.testing.expectEqual(@as(usize, 4), nd.len);
    for (nc, nd) |x, y| try std.testing.expectEqualStrings(x, y);
}

test "unit tags carry the section 11.3 key set in order" {
    const tags = try unitTags(
        std.testing.allocator,
        "rustc 1.99.0 a1b2c3d4",
        "aarch64-apple-darwin",
        "dev",
        "fh-9c41aa02d1e57f03",
        "pb3-abc",
        "serde",
        "1.0.0",
        "rustc",
    );
    defer std.testing.allocator.free(tags);
    try std.testing.expectEqual(@as(usize, 8), tags.len);
    const keys = [_][]const u8{ "crate", "crate_version", "toolchain", "target", "profile", "features", "project", "action" };
    for (keys, tags) |k, t| try std.testing.expectEqualStrings(k, t.key);
    try std.testing.expectEqualStrings("serde", tags[0].value);
    try std.testing.expectEqualStrings("rustc", tags[7].value);
}
