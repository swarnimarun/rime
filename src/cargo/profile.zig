//! Build profile model (M4 Task 2): dev/release defaults plus the
//! allow-listed `[profile.*]` overrides, pinned to cargo's
//! `core/profiles.rs` default rows.
//!
//! Ownership: `devProfile`/`releaseProfile`/`profileFor` return Profiles
//! whose `name`/`opt_level` borrow statics (or the caller's `name` slice
//! for custom profiles) — do NOT free them. `applyProfileToml`, on SUCCESS
//! (including a missing-section no-op), replaces `p.opt_level` with a
//! gpa-owned dup, transferring ownership to the caller: free `p.opt_level`
//! exactly once after a successful call, and only then. On ERROR `p` is left
//! untouched (no ownership change, nothing to free).
//!
//! `[profile.*.package."*"]` per-package overrides parse and are IGNORED
//! (limitation L1: per-dependency profile resolution needs the full
//! `profiles.rs::get_profile`; validation projects use top-level profiles).

const std = @import("std");
const toml = @import("toml.zig");

pub const ProfileError = error{ UnknownProfileKey, InvalidManifest, ParseError, UnsupportedType, OutOfMemory };
pub const PanicStrategy = enum { unwind, abort };
pub const Profile = struct {
    name: []const u8, // "dev" | "release" | custom (borrowed; do not free)
    opt_level: []const u8, // "0" | "1" | "2" | "3" | "s" | "z" (static until applyProfileToml dups it)
    debug_info: u8, // 0, 1, 2 (cargo `debug = true` means 2; `"line-tables-only"` means 1)
    debug_assertions: bool,
    overflow_checks: bool,
    incremental: bool,
    panic_strategy: PanicStrategy,
    lto_off: bool, // true emits `-C lto=off -C embed-bitcode=no` (cargo lto_args::Lto::Off)
};

/// Cargo dev defaults (`profiles.rs`): opt 0, debug 2, assertions on,
/// overflow on, incremental on, unwind.
pub fn devProfile() Profile {
    return .{ .name = "dev", .opt_level = "0", .debug_info = 2, .debug_assertions = true, .overflow_checks = true, .incremental = true, .panic_strategy = .unwind, .lto_off = false };
}

/// Cargo release defaults (`profiles.rs`): opt 3, debug 0, assertions off,
/// overflow off, incremental off, unwind.
pub fn releaseProfile() Profile {
    return .{ .name = "release", .opt_level = "3", .debug_info = 0, .debug_assertions = false, .overflow_checks = false, .incremental = false, .panic_strategy = .unwind, .lto_off = false };
}

/// `"dev"`/`"test"` map to dev; anything else is release-shaped with the
/// requested name kept (borrowed from the caller).
pub fn profileFor(name: []const u8) Profile {
    if (std.mem.eql(u8, name, "dev") or std.mem.eql(u8, name, "test")) return devProfile();
    var p = releaseProfile();
    p.name = name;
    return p;
}

/// Applies the `[profile.<section>]` table from `text` onto `p`. Missing
/// section (or missing `[profile]`) is a no-op success. Allow-listed keys:
/// `opt-level` (int 0–3 or `"s"`/`"z"`), `debug` (bool, 0/1/2,
/// `"line-tables-only"`/`"full"`), `debug-assertions`, `overflow-checks`,
/// `incremental` (bools), `panic` (`"unwind"`/`"abort"`), `lto` (`false`
/// flips `lto_off`; `true`/strings parse and change nothing). The
/// `package` key (per-package overrides) parses and is ignored (L1).
/// Unknown keys → `UnknownProfileKey`; mistyped/misvalued keys →
/// `InvalidManifest`; TOML failures map verbatim.
pub fn applyProfileToml(p: *Profile, gpa: std.mem.Allocator, text: []const u8, section: []const u8) ProfileError!void {
    var doc = toml.parseDocument(gpa, text) catch |e| return switch (e) {
        toml.TomlError.ParseError => ProfileError.ParseError,
        toml.TomlError.UnsupportedType => ProfileError.UnsupportedType,
        toml.TomlError.OutOfMemory => ProfileError.OutOfMemory,
    };
    defer doc.deinit();
    // Success path owns the final opt_level (dup of old or new); error
    // paths free the pending dup and leave `p` untouched.
    var new_opt: ?[]u8 = null;
    errdefer if (new_opt) |o| gpa.free(o);

    const finish = struct {
        fn apply(profile: *Profile, alloc: std.mem.Allocator, pending: ?[]u8) std.mem.Allocator.Error!void {
            profile.opt_level = pending orelse try alloc.dupe(u8, profile.opt_level);
        }
    }.apply;

    const pv = doc.root.get("profile") orelse return finish(p, gpa, new_opt);
    if (pv.* != .table) return ProfileError.InvalidManifest;
    const sv = pv.table.get(section) orelse return finish(p, gpa, new_opt);
    if (sv.* != .table) return ProfileError.InvalidManifest;

    // Borrowed-then-duped: integers format into owned text immediately;
    // string spellings borrow the doc arena and are duped below.
    var opt_text: ?[]const u8 = null;
    var opt_owned: ?[]u8 = null;
    errdefer if (opt_owned) |o| gpa.free(o);

    // Staged locals: error paths return early, so `p` is only committed
    // on success (doc: errors leave `p` untouched).
    var new_debug: u8 = p.debug_info;
    var new_debug_assertions: bool = p.debug_assertions;
    var new_overflow_checks: bool = p.overflow_checks;
    var new_incremental: bool = p.incremental;
    var new_panic: PanicStrategy = p.panic_strategy;
    var new_lto_off: bool = p.lto_off;

    var it = sv.table.entries.iterator();
    while (it.next()) |kv| {
        const key = kv.key_ptr.*;
        const val = &kv.value_ptr.value;
        if (std.mem.eql(u8, key, "package")) continue; // L1: per-package overrides parsed-and-ignored
        if (std.mem.eql(u8, key, "opt-level")) {
            if (val.* == .integer) {
                const v = val.integer;
                if (v < 0 or v > 3) return ProfileError.InvalidManifest;
                const digits = [_][]const u8{ "0", "1", "2", "3" };
                opt_text = digits[@intCast(v)];
            } else if (val.* == .string) {
                if (!(std.mem.eql(u8, val.string, "s") or std.mem.eql(u8, val.string, "z"))) return ProfileError.InvalidManifest;
                opt_text = val.string;
            } else {
                return ProfileError.InvalidManifest;
            }
        } else if (std.mem.eql(u8, key, "debug")) {
            if (val.* == .boolean) {
                new_debug = if (val.boolean) 2 else 0;
            } else if (val.* == .integer) {
                if (val.integer < 0 or val.integer > 2) return ProfileError.InvalidManifest;
                new_debug = @intCast(val.integer);
            } else if (val.* == .string) {
                if (std.mem.eql(u8, val.string, "line-tables-only")) {
                    new_debug = 1;
                } else if (std.mem.eql(u8, val.string, "full")) {
                    new_debug = 2;
                } else {
                    return ProfileError.InvalidManifest;
                }
            } else {
                return ProfileError.InvalidManifest;
            }
        } else if (std.mem.eql(u8, key, "debug-assertions")) {
            if (val.* != .boolean) return ProfileError.InvalidManifest;
            new_debug_assertions = val.boolean;
        } else if (std.mem.eql(u8, key, "overflow-checks")) {
            if (val.* != .boolean) return ProfileError.InvalidManifest;
            new_overflow_checks = val.boolean;
        } else if (std.mem.eql(u8, key, "incremental")) {
            if (val.* != .boolean) return ProfileError.InvalidManifest;
            new_incremental = val.boolean;
        } else if (std.mem.eql(u8, key, "panic")) {
            if (val.* != .string) return ProfileError.InvalidManifest;
            if (std.mem.eql(u8, val.string, "unwind")) {
                new_panic = .unwind;
            } else if (std.mem.eql(u8, val.string, "abort")) {
                new_panic = .abort;
            } else {
                return ProfileError.InvalidManifest;
            }
        } else if (std.mem.eql(u8, key, "lto")) {
            // Only `false` changes codegen flags; `true`/strings parse and
            // are ignored (thin/fat LTO selection is out of M4 scope).
            if (val.* == .boolean) {
                if (!val.boolean) new_lto_off = true;
            } else if (val.* != .string) {
                return ProfileError.InvalidManifest;
            }
        } else {
            return ProfileError.UnknownProfileKey;
        }
    }

    if (opt_text) |t| {
        opt_owned = try gpa.dupe(u8, t);
        new_opt = opt_owned;
        opt_owned = null;
    }
    // Ownership transfer: from here the pending opt_level (or the dup
    // inside `finish`) belongs to the caller via `p.opt_level`. Disarm both
    // errdefers; a dup failure below frees the pending slice first.
    // Scalars commit only after the fallible opt_level dup succeeds, so a
    // dup failure still leaves `p` fully untouched.
    const owned = new_opt;
    new_opt = null;
    opt_owned = null;
    finish(p, gpa, owned) catch |e| {
        if (owned) |o| gpa.free(o);
        return e;
    };
    p.debug_info = new_debug;
    p.debug_assertions = new_debug_assertions;
    p.overflow_checks = new_overflow_checks;
    p.incremental = new_incremental;
    p.panic_strategy = new_panic;
    p.lto_off = new_lto_off;
}

test "profile dev and release defaults match cargo" {
    const dev = devProfile();
    try std.testing.expectEqualStrings("0", dev.opt_level);
    try std.testing.expectEqual(@as(u8, 2), dev.debug_info);
    try std.testing.expect(dev.incremental);
    try std.testing.expect(dev.debug_assertions);
    try std.testing.expect(dev.overflow_checks); // default_dev: both on (profiles.rs:715-724)
    const rel = releaseProfile();
    try std.testing.expectEqualStrings("3", rel.opt_level);
    try std.testing.expectEqual(@as(u8, 0), rel.debug_info);
    try std.testing.expect(!rel.incremental);
    try std.testing.expect(!rel.debug_assertions);
    try std.testing.expect(!rel.overflow_checks); // default_release: both off (profiles.rs:728-736)
}

test "profile toml overrides known keys and rejects unknown" {
    var p = devProfile();
    try applyProfileToml(&p, std.testing.allocator, "[profile.dev]\nopt-level = 2\nincremental = false\n", "dev");
    defer std.testing.allocator.free(p.opt_level);
    try std.testing.expectEqualStrings("2", p.opt_level);
    try std.testing.expect(!p.incremental);
    var q = devProfile();
    try std.testing.expectError(ProfileError.UnknownProfileKey, applyProfileToml(&q, std.testing.allocator, "[profile.dev]\nflux = true\n", "dev"));
}

test "profile debug spellings and panic parse" {
    var p = devProfile();
    try applyProfileToml(&p, std.testing.allocator, "[profile.release]\ndebug = \"line-tables-only\"\npanic = \"abort\"\nlto = false\n", "release");
    defer std.testing.allocator.free(p.opt_level); // only valid because applyProfileToml succeeded; devProfile default is static
    try std.testing.expectEqual(@as(u8, 1), p.debug_info);
    try std.testing.expect(p.panic_strategy == .abort);
    try std.testing.expect(p.lto_off);
}

test "profile missing section is a gpa-owned no-op" {
    var p = devProfile();
    try applyProfileToml(&p, std.testing.allocator, "[profile.release]\nopt-level = 1\n", "dev");
    defer std.testing.allocator.free(p.opt_level);
    try std.testing.expectEqualStrings("0", p.opt_level);
    try std.testing.expect(p.incremental);
}

test "profile rejects mistyped and misvalued keys" {
    var p = devProfile();
    // opt-level out of range / bad string / wrong type.
    try std.testing.expectError(ProfileError.InvalidManifest, applyProfileToml(&p, std.testing.allocator, "[profile.dev]\nopt-level = 9\n", "dev"));
    try std.testing.expectError(ProfileError.InvalidManifest, applyProfileToml(&p, std.testing.allocator, "[profile.dev]\nopt-level = \"turbo\"\n", "dev"));
    try std.testing.expectError(ProfileError.InvalidManifest, applyProfileToml(&p, std.testing.allocator, "[profile.dev]\ndebug = 7\n", "dev"));
    try std.testing.expectError(ProfileError.InvalidManifest, applyProfileToml(&p, std.testing.allocator, "[profile.dev]\npanic = \"unwind-ish\"\n", "dev"));
    try std.testing.expectError(ProfileError.InvalidManifest, applyProfileToml(&p, std.testing.allocator, "[profile.dev]\nincremental = \"yes\"\n", "dev"));
    // Errors leave p untouched (statics still borrowed, nothing to free).
    try std.testing.expectEqualStrings("0", p.opt_level);
    // L1: per-package overrides parse and are ignored.
    try applyProfileToml(&p, std.testing.allocator, "[profile.dev.package.\"*\"]\nopt-level = 3\n", "dev");
    defer std.testing.allocator.free(p.opt_level);
    try std.testing.expectEqualStrings("0", p.opt_level);
}
