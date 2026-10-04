//! Unit fingerprints (M4 Task 4): content-bound identity per compile unit
//! plus dep-info freshness (cargo `fingerprint/mod.rs` + `dep_info.rs`
//! roles; deviation F1: store `Digest`s instead of u64s).
//!
//! `Fingerprint.toDigest` is the content hash (feeds the Task-5 action
//! key); `checkFresh` is the dep-info mtime comparison (feeds skip
//! decisions, cargo `FsStatus` role). `hashInputs` hashes crate source
//! bytes (deviation F4: content hashes, not mtimes, in the key).
//!
//! Ownership: `Fingerprint.features_sorted` borrows the `Unit` (do not
//! free). `fingerprintUnit` dupes + byte-sorts `dep_fps` into a gpa-owned
//! slice (free with `gpa.free`). `DepInfo` strings are gpa-owned (`deinit`
//! frees them). `checkFresh` takes no allocator by contract, so its
//! transient parse uses the page allocator (freed before return — the
//! `tags.zig::tagObject` precedent, not an arena).

const std = @import("std");
const store_mod = @import("store");
const driver_mod = @import("driver.zig");

const Digest = store_mod.Digest;
const Unit = driver_mod.Unit;

pub const FpError = error{ Io, BadDepInfo, OutOfMemory } || std.mem.Allocator.Error;

pub const Fingerprint = struct {
    rustc_digest: Digest, // zeroed by fingerprintUnit; the pipeline MUST overwrite with toolchain.digest before toDigest
    features_sorted: []const []const u8, // borrowed from Unit
    target_desc_hash: Digest, // hash(pkg \x00 target \x00 kind \x00 edition)
    profile_hash: Digest, // hash(opt \x00 debug \x00 assertions \x00 overflow \x00 incremental \x00 panic \x00 lto_off \x00 mode)
    path_hash: Digest, // hash(src_path verbatim — no workspace root is available to relativize against)
    dep_fps: []const Digest, // gpa-owned (duped + byte-sorted by fingerprintUnit)
    rustflags_hash: Digest, // hash(RUSTFLAGS bytes or "")
    config_hash: Digest, // hash(target_triple \x00 compile_kind)

    /// Canonical join (field order fixed — this IS the key format, versioned
    /// with a `rime-fp-v1\x00` prefix): every `Digest` as raw 32 bytes,
    /// feature strings joined with `+`, `\x00` separators throughout.
    pub fn toDigest(self: *const Fingerprint) Digest {
        var h = std.crypto.hash.Blake3.init(.{});
        h.update("rime-fp-v1\x00");
        h.update(&self.rustc_digest.bytes);
        h.update(&[_]u8{0});
        for (self.features_sorted, 0..) |f, i| {
            if (i > 0) h.update("+");
            h.update(f);
        }
        h.update(&[_]u8{0});
        h.update(&self.target_desc_hash.bytes);
        h.update(&[_]u8{0});
        h.update(&self.profile_hash.bytes);
        h.update(&[_]u8{0});
        h.update(&self.path_hash.bytes);
        h.update(&[_]u8{0});
        for (self.dep_fps) |d| h.update(&d.bytes);
        h.update(&[_]u8{0});
        h.update(&self.rustflags_hash.bytes);
        h.update(&[_]u8{0});
        h.update(&self.config_hash.bytes);
        var out: [32]u8 = undefined;
        h.final(&out);
        return .{ .bytes = out };
    }

    /// Filename meta: first 16 hex chars of the fingerprint digest
    /// (deviation F2 — cargo's SipHash meta role, content-bound).
    pub fn toHex16(self: *const Fingerprint) [16]u8 {
        const hex = self.toDigest().toHex();
        return hex[0..16].*;
    }
};

/// Joins `parts` with `\x00` separators (trailing separator included) into
/// one BLAKE3 digest. No allocation; the canonical field-hash helper.
fn hashJoin(parts: []const []const u8) Digest {
    var h = std.crypto.hash.Blake3.init(.{});
    for (parts) |p| {
        h.update(p);
        h.update(&[_]u8{0});
    }
    var out: [32]u8 = undefined;
    h.final(&out);
    return .{ .bytes = out };
}

/// Builds the unit fingerprint (`fingerprint/mod.rs::Fingerprint` roles).
/// `declared_features` is deliberately NOT hashed (deviation F5 — enabled
/// set only). `rustc_digest` is ZEROED here: this function never sees the
/// `Toolchain` handle (fixed Interfaces), so the pipeline MUST assign
/// `fp.rustc_digest = tc.digest` before `toDigest` (the field stays `pub`
/// for exactly this). `dep_fps` is duped + byte-sorted into a gpa-owned
/// slice (free with `gpa.free`); pass dep digests in any order.
pub fn fingerprintUnit(gpa: std.mem.Allocator, unit: *const Unit, dep_fps: []const Digest, rustflags: []const u8) FpError!Fingerprint {
    const profile = unit.profile;
    // debug_info is 0/1/2 by construction; the 4-byte buffer provably holds
    // any u8 rendering, so formatting cannot fail.
    var dbg_buf: [4]u8 = undefined;
    const dbg = std.fmt.bufPrint(&dbg_buf, "{d}", .{profile.debug_info}) catch unreachable;
    const owned_deps = try gpa.dupe(Digest, dep_fps);
    std.mem.sort(Digest, owned_deps, {}, struct {
        fn lt(_: void, a: Digest, b: Digest) bool {
            return std.mem.order(u8, &a.bytes, &b.bytes) == .lt;
        }
    }.lt);
    return .{
        .rustc_digest = .{ .bytes = [_]u8{0} ** 32 },
        .features_sorted = unit.features_sorted,
        .target_desc_hash = hashJoin(&.{ unit.pkg_name, unit.target_name, @tagName(unit.kind), unit.edition }),
        .profile_hash = hashJoin(&.{
            profile.opt_level,
            dbg,
            if (profile.debug_assertions) "1" else "0",
            if (profile.overflow_checks) "1" else "0",
            if (profile.incremental) "1" else "0",
            @tagName(profile.panic_strategy),
            if (profile.lto_off) "1" else "0",
            @tagName(unit.mode),
        }),
        .path_hash = store_mod.hashBytes(unit.src_path),
        .dep_fps = owned_deps,
        .rustflags_hash = store_mod.hashBytes(rustflags),
        .config_hash = hashJoin(&.{ unit.target_triple, @tagName(unit.compile_kind) }),
    };
}

const max_input_files: usize = 10_000;
const max_input_bytes: u64 = 256 << 20;

/// Content hash over the crate's inputs (deviation F4): `Cargo.toml` +
/// `build.rs` when present plus every `*.rs` file under `src/`, as sorted
/// `relpath \x00 filebytes` joins. Caps: 10k files / 256 MiB total, else
/// `Io` (bounded, loud).
pub fn hashInputs(gpa: std.mem.Allocator, io: std.Io, crate_root: []const u8) FpError!Digest {
    var root = std.Io.Dir.cwd().openDir(io, crate_root, .{ .iterate = true }) catch return FpError.Io;
    defer root.close(io);
    var rels: std.ArrayList([]const u8) = .empty;
    defer {
        for (rels.items) |r| gpa.free(r);
        rels.deinit(gpa);
    }
    for ([_][]const u8{ "Cargo.toml", "build.rs" }) |name| {
        if (root.statFile(io, name, .{})) |_| {
            try appendDup(&rels, gpa, name);
        } else |_| {}
    }
    if (root.openDir(io, "src", .{ .iterate = true })) |src_dir| {
        var src = src_dir;
        defer src.close(io);
        try collectRs(gpa, io, src, "src", &rels);
    } else |_| {}
    std.mem.sort([]const u8, rels.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    var h = std.crypto.hash.Blake3.init(.{});
    var total: u64 = 0;
    for (rels.items) |rel| {
        const st = root.statFile(io, rel, .{}) catch return FpError.Io;
        total += st.size;
        if (total > max_input_bytes) return FpError.Io;
        h.update(rel);
        h.update(&[_]u8{0});
        {
            var f = root.openFile(io, rel, .{}) catch return FpError.Io;
            defer f.close(io);
            var buf: [64 * 1024]u8 = undefined;
            var offset: u64 = 0;
            while (true) {
                const n = f.readPositionalAll(io, &buf, offset) catch return FpError.Io;
                if (n == 0) break;
                h.update(buf[0..n]);
                offset += n;
            }
        }
    }
    var out: [32]u8 = undefined;
    h.final(&out);
    return .{ .bytes = out };
}

fn appendDup(list: *std.ArrayList([]const u8), gpa: std.mem.Allocator, s: []const u8) FpError!void {
    const dup = try gpa.dupe(u8, s);
    list.append(gpa, dup) catch {
        gpa.free(dup);
        return FpError.OutOfMemory;
    };
}

/// Recursive `*.rs` collector under `dir`; relpaths are `prefix/name`
/// gpa-owned strings appended to `out`. Symlinks ending in `.rs` are
/// followed at hash time (opens follow them); anything else is skipped.
/// Mid-walk IO failures are loud (`Io`), never skipped.
fn collectRs(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, prefix: []const u8, out: *std.ArrayList([]const u8)) FpError!void {
    var it = dir.iterate();
    while (it.next(io) catch return FpError.Io) |entry| {
        if (out.items.len >= max_input_files) return FpError.Io;
        const rel = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ prefix, entry.name });
        switch (entry.kind) {
            .directory => {
                defer gpa.free(rel);
                var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch return FpError.Io;
                defer sub.close(io);
                try collectRs(gpa, io, sub, rel, out);
            },
            .file, .sym_link => {
                if (!std.mem.endsWith(u8, entry.name, ".rs")) {
                    gpa.free(rel);
                    continue;
                }
                out.append(gpa, rel) catch {
                    gpa.free(rel);
                    return FpError.OutOfMemory;
                };
            },
            else => gpa.free(rel),
        }
    }
}

pub const DepInfo = struct {
    target: []const u8, // gpa-owned
    deps: []const []const u8, // gpa-owned entries

    pub fn deinit(self: *DepInfo, gpa: std.mem.Allocator) void {
        gpa.free(self.target);
        for (self.deps) |d| gpa.free(d);
        gpa.free(self.deps);
    }
};

fn unescape(gpa: std.mem.Allocator, s: []const u8) FpError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var k: usize = 0;
    while (k < s.len) {
        if (s[k] == '\\' and k + 1 < s.len) {
            try out.append(gpa, s[k + 1]);
            k += 2;
        } else {
            try out.append(gpa, s[k]);
            k += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

/// `dep_info.rs` grammar subset rustc actually emits: `target: dep…` with
/// backslash-newline continuations and `\ `-escaped spaces (a backslash
/// escapes any following char literally, in target and deps alike). Splits
/// at the FIRST `:`; missing colon → `BadDepInfo`.
pub fn parseDepInfo(gpa: std.mem.Allocator, text: []const u8) FpError!DepInfo {
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(gpa);
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\\' and i + 1 < text.len and (text[i + 1] == '\n' or (text[i + 1] == '\r' and i + 2 < text.len and text[i + 2] == '\n'))) {
            i += if (text[i + 1] == '\n') 2 else 3;
            continue;
        }
        try joined.append(gpa, text[i]);
        i += 1;
    }
    const flat = joined.items;
    const colon = std.mem.indexOfScalar(u8, flat, ':') orelse return FpError.BadDepInfo;
    const target_raw = std.mem.trim(u8, flat[0..colon], " \t");
    var deps: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (deps.items) |d| gpa.free(d);
        deps.deinit(gpa);
    }
    var cur: std.ArrayList(u8) = .empty;
    defer cur.deinit(gpa);
    const rest = flat[colon + 1 ..];
    var j: usize = 0;
    while (j <= rest.len) {
        const c: u8 = if (j < rest.len) rest[j] else ' ';
        if (c == '\\' and j + 1 < rest.len) {
            try cur.append(gpa, rest[j + 1]);
            j += 2;
            continue;
        }
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            if (cur.items.len > 0) {
                const dup = try gpa.dupe(u8, cur.items);
                deps.append(gpa, dup) catch {
                    gpa.free(dup);
                    return FpError.OutOfMemory;
                };
                cur.clearRetainingCapacity();
            }
        } else {
            try cur.append(gpa, c);
        }
        j += 1;
    }
    const target = try unescape(gpa, target_raw);
    errdefer gpa.free(target);
    return .{ .target = target, .deps = try deps.toOwnedSlice(gpa) };
}

/// Cargo `FsStatus` mtime role: parses the dep-info file and stats every
/// dep; returns false when any dep mtime exceeds `max_mtime_ns` (the
/// recorded output mtime), any dep is missing, or the dep-info file itself
/// is missing. Other IO failures are loud (`Io`).
pub fn checkFresh(io: std.Io, dep_info_path: []const u8, max_mtime_ns: i128) FpError!bool {
    // Fixed Interfaces carry no allocator; the transient parse uses the
    // page allocator and frees before return (store tagObject precedent).
    const gpa = std.heap.page_allocator;
    const text = std.Io.Dir.cwd().readFileAlloc(io, dep_info_path, gpa, .limited(16 << 20)) catch |e| {
        if (e == error.FileNotFound) return false;
        if (e == error.OutOfMemory) return FpError.OutOfMemory;
        return FpError.Io;
    };
    defer gpa.free(text);
    var info = try parseDepInfo(gpa, text);
    defer info.deinit(gpa);
    const cwd = std.Io.Dir.cwd();
    for (info.deps) |dep| {
        const st = cwd.statFile(io, dep, .{}) catch return false;
        const dep_ns: i128 = @as(i128, st.mtime.toMilliseconds()) * 1_000_000;
        if (dep_ns > max_mtime_ns) return false;
    }
    return true;
}

test "fingerprint is deterministic and change-sensitive" {
    const fp1 = Fingerprint{
        .rustc_digest = store_mod.hashBytes("rustc-a"),
        .features_sorted = &.{"json"},
        .target_desc_hash = store_mod.hashBytes("pkg\x00lib\x00lib\x002021"),
        .profile_hash = store_mod.hashBytes("0\x002\x00"),
        .path_hash = store_mod.hashBytes("/ws/a"),
        .dep_fps = &.{store_mod.hashBytes("dep")},
        .rustflags_hash = store_mod.hashBytes(""),
        .config_hash = store_mod.hashBytes("aarch64-apple-darwin\x00target"),
    };
    const fp2 = fp1;
    try std.testing.expectEqual(fp1.toDigest().bytes, fp2.toDigest().bytes);
    var fp3 = fp1;
    fp3.rustc_digest = store_mod.hashBytes("rustc-b");
    try std.testing.expect(!std.mem.eql(u8, &fp1.toDigest().bytes, &fp3.toDigest().bytes));
}

test "dep-info parses continuations and escaped spaces" {
    var d = try parseDepInfo(std.testing.allocator, "libfoo.rlib: src/lib.rs src/my\\ file.rs \\\n  src/other.rs\n");
    defer d.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), d.deps.len);
    try std.testing.expectEqualStrings("src/my file.rs", d.deps[1]);
}

test "hashInputs covers sources and Cargo.toml" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const d1 = try hashInputs(std.testing.allocator, io, "testdata/cargo/workspace/crates/a");
    const d2 = try hashInputs(std.testing.allocator, io, "testdata/cargo/workspace/crates/a");
    try std.testing.expectEqual(d1.bytes, d2.bytes);
    const d3 = try hashInputs(std.testing.allocator, io, "testdata/cargo/workspace/crates/b");
    try std.testing.expect(!std.mem.eql(u8, &d1.bytes, &d3.bytes));
}

test "dep-info rejects colon-less input" {
    try std.testing.expectError(FpError.BadDepInfo, parseDepInfo(std.testing.allocator, "no colon here\n"));
}

test "fingerprintUnit binds profile mode and dep order" {
    const gpa = std.testing.allocator;
    const unit_build = driver_mod.Unit{
        .pkg_name = "a",
        .version = "0.1.0",
        .target_name = "a",
        .kind = .lib,
        .edition = "2021",
        .crate_types = &.{"rlib"},
        .profile = @import("profile.zig").devProfile(),
        .features_sorted = &.{},
        .target_triple = "aarch64-apple-darwin",
        .compile_kind = .target,
        .mode = .build,
        .src_path = "/ws/a",
        .deps = &.{},
    };
    var unit_check = unit_build;
    unit_check.mode = .check;
    const d_a = store_mod.hashBytes("dep-a");
    const d_b = store_mod.hashBytes("dep-b");
    var fp_build = try fingerprintUnit(gpa, &unit_build, &.{ d_a, d_b }, "");
    defer gpa.free(fp_build.dep_fps);
    var fp_check = try fingerprintUnit(gpa, &unit_check, &.{d_b, d_a}, "");
    defer gpa.free(fp_check.dep_fps);
    // Mode flips the digest (check and build keys never collide); dep input
    // order does not (constructor byte-sorts).
    try std.testing.expect(!std.mem.eql(u8, &fp_build.toDigest().bytes, &fp_check.toDigest().bytes));
    try std.testing.expectEqual(fp_build.dep_fps[0].bytes, fp_check.dep_fps[0].bytes);
    try std.testing.expectEqual(fp_build.dep_fps[1].bytes, fp_check.dep_fps[1].bytes);
    // Filename meta is 16 lowercase hex chars.
    const meta = fp_build.toHex16();
    try std.testing.expectEqual(@as(usize, 16), meta.len);
    for (meta) |ch| try std.testing.expect((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f'));
}

test "checkFresh compares dep mtimes against the recorded output" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "lib.rs", .data = "pub fn x() {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.rs", .data = "fn main() {}\n" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const dep_info = try std.fmt.allocPrint(gpa, "out.rlib: {s}/lib.rs {s}/main.rs\n", .{ root, root });
    defer gpa.free(dep_info);
    try tmp.dir.writeFile(io, .{ .sub_path = "out.d", .data = dep_info });
    const dep_info_path = try std.fmt.allocPrint(gpa, "{s}/out.d", .{root});
    defer gpa.free(dep_info_path);
    // Recorded output mtime = the NEWEST dep mtime (both files were just
    // written; per-file mtimes can differ at ns granularity).
    var recorded_ns: i128 = 0;
    for ([_][]const u8{ "lib.rs", "main.rs" }) |name| {
        const p = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, name });
        defer gpa.free(p);
        const st = try std.Io.Dir.cwd().statFile(io, p, .{});
        recorded_ns = @max(recorded_ns, @as(i128, st.mtime.toMilliseconds()) * 1_000_000);
    }
    // Dep mtimes equal the recorded output mtime: fresh (strictly-greater
    // comparison, cargo FsStatus role).
    try std.testing.expect(try checkFresh(io, dep_info_path, recorded_ns));
    // Recorded output older than a dep: stale.
    try std.testing.expect(!try checkFresh(io, dep_info_path, recorded_ns - 1));
    // Missing dep-info file: stale, not an error.
    const missing = try std.fmt.allocPrint(gpa, "{s}/nope.d", .{root});
    defer gpa.free(missing);
    try std.testing.expect(!try checkFresh(io, missing, recorded_ns));
    // Missing dep entry: stale, not an error.
    const bad_info = try std.fmt.allocPrint(gpa, "out.rlib: {s}/gone.rs\n", .{root});
    defer gpa.free(bad_info);
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.d", .data = bad_info });
    const bad_path = try std.fmt.allocPrint(gpa, "{s}/bad.d", .{root});
    defer gpa.free(bad_path);
    try std.testing.expect(!try checkFresh(io, bad_path, recorded_ns));
}
