//! Oracle harness: the real `cargo` binary as conformance oracle (M3 Task 10).
//!
//! Each fixture dir is a COMPLETE standalone workspace. Oracle tests copy
//! the fixture to a `std.testing.tmpDir` (cargo MUST NOT write into the
//! repo), run the real `cargo generate-lockfile [--offline]` there, resolve
//! the same manifests with rime, and byte-compare. Path-only graphs compare
//! byte-identically (no checksums involved); registry graphs resolve through
//! live sparse-index data (same wire shape cargo consumes) with the golden
//! lock as previous (keep-everything minimal-update, exactly the M4 flow).
//!
//! Gating: every cargo-spawning test returns `error.SkipZigTest` unless
//! `RIME_CARGO_ORACLE=1` AND `cargo` is on `PATH`. The default
//! `zig build test` stays hermetic (only the cargo-free
//! `discoverValidationProjects` shape test runs unconditionally).
//!
//! Env scrub + timeouts: cargo runs inherit the ambient `CARGO_HOME` (the
//! warm cache the validation corpus relies on -- isolating it would force
//! network for `--offline` runs) but always in a tmp cwd, so the repo is
//! never dirtied. Every spawn has a 60s watchdog (kill + `CargoFailed` on
//! timeout).
//!
//! Reference pins: `tests/testsuite/generate_lockfile.rs` (CLI shapes) +
//! `tests/testsuite/lockfile_compat.rs` (version upgrade/downgrade
//! expectations re-checked on rime's writer by these byte-compares).

const std = @import("std");
const semver = @import("semver.zig");
const index = @import("index.zig");
const resolve = @import("resolve.zig");
const sources = @import("sources.zig");
const lock = @import("lock.zig");
const features = @import("features.zig");
const manifest = @import("manifest.zig");
const workspace = @import("workspace.zig");

pub const OracleError = error{ CargoMissing, CargoFailed, Mismatch, OutOfMemory, Io };

/// Oracle gate (fetch.zig Task-9 precedent): `RIME_CARGO_ORACLE=1` enables
/// the real-cargo comparisons; default runs skip. Env via `std.c.getenv`
/// (cli.zig precedent; `std.process.getEnvVarOwned` is absent in 0.16).
pub fn oracleEnabled() bool {
    const v = std.c.getenv("RIME_CARGO_ORACLE") orelse return false;
    return std.mem.eql(u8, std.mem.span(v), "1");
}

/// `cargo --version` spawns cleanly (no env gate -- a read-only probe; the
/// gate lives in the tests so hermetic runs never spawn at all).
pub fn cargoAvailable() bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    var child = std.process.spawn(io, .{
        .argv = &.{ "cargo", "--version" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    defer child.kill(io);
    const term = child.wait(io) catch return false;
    return term == .exited and term.exited == 0;
}

const spawn_timeout_ns: u64 = 60 * std.time.ns_per_s;

const Watchdog = struct {
    child: *std.process.Child,
    io: std.Io,
    done: std.atomic.Value(bool),
    fired: std.atomic.Value(bool),
};

fn watchdogMain(w: *Watchdog) void {
    const step = std.Io.Duration.fromMilliseconds(100);
    var waited: u64 = 0;
    while (waited < spawn_timeout_ns) {
        std.Io.sleep(w.io, step, .awake) catch return;
        waited += 100 * std.time.ns_per_ms;
        if (w.done.load(.acquire)) return;
    }
    w.fired.store(true, .release);
    w.child.kill(w.io);
}

const RunError = error{ SpawnFailed, TimedOut, OutOfMemory };

/// Spawn `argv` with `cwd`, drain stdout+stderr, enforce the 60s watchdog.
/// Returns the exit code plus a gpa-owned stdout copy. Stderr is discarded
/// (callers that need it read files, e.g. Cargo.lock, instead).
fn runCapture(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: []const u8) RunError!struct { exited: u8, out: []u8 } {
    const cwd_opt: std.process.Child.Cwd = if (cwd.len == 0) .inherit else .{ .path = cwd };
    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = cwd_opt,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch return RunError.SpawnFailed;
    errdefer child.kill(io);
    var w = Watchdog{ .child = &child, .io = io, .done = std.atomic.Value(bool).init(false), .fired = std.atomic.Value(bool).init(false) };
    const watcher = std.Thread.spawn(.{}, watchdogMain, .{&w}) catch return RunError.SpawnFailed;
    var mr_buf: std.Io.File.MultiReader.Buffer(2) = undefined;
    var mr: std.Io.File.MultiReader = undefined;
    mr.init(gpa, io, mr_buf.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer mr.deinit();
    const out_r = mr.reader(0);
    while (mr.fill(4096, .none)) |_| {} else |e| if (e != error.EndOfStream) {
        w.done.store(true, .release);
        watcher.join();
        return RunError.SpawnFailed;
    }
    const term = child.wait(io) catch {
        w.done.store(true, .release);
        watcher.join();
        return RunError.SpawnFailed;
    };
    w.done.store(true, .release);
    watcher.join();
    if (w.fired.load(.acquire)) return RunError.TimedOut;
    if (term != .exited) return RunError.SpawnFailed;
    const out = gpa.dupe(u8, out_r.buffered()) catch return RunError.OutOfMemory;
    return .{ .exited = term.exited, .out = out };
}

/// Runs `cargo generate-lockfile [--offline]` in `dir`, returns the
/// `Cargo.lock` bytes cargo wrote (gpa-owned). `CargoMissing` when the
/// binary is absent; `CargoFailed` on timeout/nonzero exit/unreadable lock.
pub fn generateLockfile(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, offline: bool) OracleError![]u8 {
    if (!cargoAvailable()) return OracleError.CargoMissing;
    const argv: []const []const u8 = if (offline)
        &.{ "cargo", "generate-lockfile", "--offline" }
    else
        &.{ "cargo", "generate-lockfile" };
    const res = runCapture(gpa, io, argv, dir) catch |e| switch (e) {
        RunError.OutOfMemory => return OracleError.OutOfMemory,
        RunError.SpawnFailed, RunError.TimedOut => return OracleError.CargoFailed,
    };
    defer gpa.free(res.out);
    if (res.exited != 0) return OracleError.CargoFailed;
    const lock_path = std.fmt.allocPrint(gpa, "{s}/Cargo.lock", .{dir}) catch return OracleError.OutOfMemory;
    defer gpa.free(lock_path);
    return std.Io.Dir.cwd().readFileAlloc(io, lock_path, gpa, .limited(8 << 20)) catch |e| switch (e) {
        error.OutOfMemory => return OracleError.OutOfMemory,
        else => return OracleError.Io,
    };
}

/// `cargo metadata --format-version 1 --offline` in `dir`, projected to a
/// sorted `[]const u8` list of `"name version"` strings (gpa-owned; caller
/// frees each string plus the slice). Absolute paths in metadata are never
/// read -- only name+version, so no `@VALIDATION_ROOT@` sanitizing is
/// needed for this projection.
pub fn metadataPkgs(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) OracleError![][]const u8 {
    if (!cargoAvailable()) return OracleError.CargoMissing;
    const res = runCapture(gpa, io, &.{ "cargo", "metadata", "--format-version", "1", "--offline" }, dir) catch |e| switch (e) {
        RunError.OutOfMemory => return OracleError.OutOfMemory,
        RunError.SpawnFailed, RunError.TimedOut => return OracleError.CargoFailed,
    };
    defer gpa.free(res.out);
    if (res.exited != 0) return OracleError.CargoFailed;
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, res.out, .{}) catch return OracleError.CargoFailed;
    defer parsed.deinit();
    const pkgs = parsed.value.object.get("packages") orelse return OracleError.CargoFailed;
    if (pkgs != .array) return OracleError.CargoFailed;
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |s| gpa.free(s);
        list.deinit(gpa);
    }
    for (pkgs.array.items) |*p| {
        if (p.* != .object) return OracleError.CargoFailed;
        const name = p.object.get("name") orelse return OracleError.CargoFailed;
        const ver = p.object.get("version") orelse return OracleError.CargoFailed;
        if (name != .string or ver != .string) return OracleError.CargoFailed;
        const s = std.fmt.allocPrint(gpa, "{s} {s}", .{ name.string, ver.string }) catch return OracleError.OutOfMemory;
        errdefer gpa.free(s);
        try list.append(gpa, s);
    }
    const slice = try list.toOwnedSlice(gpa);
    std.mem.sort([]const u8, slice, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return slice;
}

fn renderVersion(gpa: std.mem.Allocator, v: semver.Version) std.mem.Allocator.Error![]u8 {
    if (v.pre.len == 0 and v.build.len == 0)
        return std.fmt.allocPrint(gpa, "{d}.{d}.{d}", .{ v.major, v.minor, v.patch });
    if (v.pre.len == 0)
        return std.fmt.allocPrint(gpa, "{d}.{d}.{d}+{s}", .{ v.major, v.minor, v.patch, v.build });
    if (v.build.len == 0)
        return std.fmt.allocPrint(gpa, "{d}.{d}.{d}-{s}", .{ v.major, v.minor, v.patch, v.pre });
    return std.fmt.allocPrint(gpa, "{d}.{d}.{d}-{s}+{s}", .{ v.major, v.minor, v.patch, v.pre, v.build });
}

/// Graph node set (`name version` strings, sorted, gpa-owned) for set
/// compares. Rendering is canonical, so string equality is exact.
fn graphNameVersions(gpa: std.mem.Allocator, graph: *const resolve.ResolveGraph) OracleError![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |s| gpa.free(s);
        list.deinit(gpa);
    }
    for (graph.nodes) |n| {
        const ver = try renderVersion(gpa, n.version);
        errdefer gpa.free(ver);
        const s = std.fmt.allocPrint(gpa, "{s} {s}", .{ n.name, ver }) catch return OracleError.OutOfMemory;
        gpa.free(ver);
        errdefer gpa.free(s);
        try list.append(gpa, s);
    }
    const slice = try list.toOwnedSlice(gpa);
    std.mem.sort([]const u8, slice, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return slice;
}

/// Decodes cargo's lock via `lock.parseLock` and compares the node
/// name@version SETS against rime's graph. On mismatch prints both sorted
/// sets to stderr, then `Mismatch` (fail loudly, never a bare code).
pub fn expectSameGraph(rime: *const resolve.ResolveGraph, cargo_lock_text: []const u8) OracleError!void {
    const gpa = std.heap.page_allocator;
    var lf = lock.parseLock(gpa, cargo_lock_text) catch {
        std.debug.print("oracle: cargo lock failed to parse\n", .{});
        return OracleError.Mismatch;
    };
    defer lf.deinit();
    var want: std.ArrayList([]const u8) = .empty;
    defer {
        for (want.items) |s| gpa.free(s);
        want.deinit(gpa);
    }
    for (lf.packages) |p| {
        const s = std.fmt.allocPrint(gpa, "{s} {s}", .{ p.name, p.version }) catch return OracleError.OutOfMemory;
        want.append(gpa, s) catch return OracleError.OutOfMemory;
    }
    std.mem.sort([]const u8, want.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    const got = try graphNameVersions(gpa, rime);
    defer {
        for (got) |s| gpa.free(s);
        gpa.free(got);
    }
    if (want.items.len != got.len or !setsEqual(want.items, got)) {
        std.debug.print("oracle: graph mismatch\n  cargo lock ({d}):\n", .{want.items.len});
        for (want.items) |s| std.debug.print("    {s}\n", .{s});
        std.debug.print("  rime graph ({d}):\n", .{got.len});
        for (got) |s| std.debug.print("    {s}\n", .{s});
        return OracleError.Mismatch;
    }
}

fn setsEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

/// Byte-compares rime's `writeLock` output against the file cargo wrote.
/// On mismatch prints a line-anchored diff to stderr, then `Mismatch`.
pub fn expectSameLockfile(rime_lock: []const u8, cargo_lock_path: []const u8, io: std.Io) OracleError!void {
    const gpa = std.heap.page_allocator;
    const cargo_lock = std.Io.Dir.cwd().readFileAlloc(io, cargo_lock_path, gpa, .limited(8 << 20)) catch |e| switch (e) {
        error.OutOfMemory => return OracleError.OutOfMemory,
        else => return OracleError.Io,
    };
    defer gpa.free(cargo_lock);
    if (std.mem.eql(u8, rime_lock, cargo_lock)) return;
    printLockDiff(rime_lock, cargo_lock);
    return OracleError.Mismatch;
}

fn printLockDiff(rime_lock: []const u8, cargo_lock: []const u8) void {
    std.debug.print("oracle: lockfile byte mismatch (rime {d} bytes, cargo {d} bytes)\n", .{ rime_lock.len, cargo_lock.len });
    var rl = std.mem.splitScalar(u8, rime_lock, '\n');
    var cl = std.mem.splitScalar(u8, cargo_lock, '\n');
    var line: usize = 1;
    var shown: usize = 0;
    while (true) {
        const r = rl.next();
        const c = cl.next();
        if (r == null and c == null) break;
        const rs = r orelse "<eof>";
        const cs = c orelse "<eof>";
        if (!std.mem.eql(u8, rs, cs)) {
            std.debug.print("  line {d}:\n    rime : {s}\n    cargo: {s}\n", .{ line, rs, cs });
            shown += 1;
            if (shown >= 12) {
                std.debug.print("  ... (truncated after 12 differing lines)\n", .{});
                break;
            }
        }
        line += 1;
    }
}

/// Lists `validation/*/` dirs, sorted (names match the landed projects).
/// Empty is NOT an error from the helper -- but the conformance test FAILS
/// on empty since the corpus has landed.
pub fn discoverValidationProjects(gpa: std.mem.Allocator, io: std.Io) OracleError![][]const u8 {
    var dir = std.Io.Dir.cwd().openDir(io, "validation", .{ .iterate = true }) catch {
        return OracleError.Io;
    };
    defer dir.close(io);
    var it = dir.iterate();
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |s| gpa.free(s);
        list.deinit(gpa);
    }
    while (true) {
        const entry = it.next(io) catch {
            return OracleError.Io;
        };
        const ent = entry orelse break;
        if (ent.kind != .directory) continue;
        const name = gpa.dupe(u8, ent.name) catch return OracleError.OutOfMemory;
        errdefer gpa.free(name);
        try list.append(gpa, name);
    }
    const slice = try list.toOwnedSlice(gpa);
    std.mem.sort([]const u8, slice, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return slice;
}

/// `golden.metadata.json` package set (`name version` strings, sorted).
/// Only name+version are read, so embedded absolute paths need no
/// `@VALIDATION_ROOT@` sanitizing for this projection.
pub fn metadataFilePkgs(gpa: std.mem.Allocator, io: std.Io, path: []const u8) OracleError![][]const u8 {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(8 << 20)) catch |e| switch (e) {
        error.OutOfMemory => return OracleError.OutOfMemory,
        else => return OracleError.Io,
    };
    defer gpa.free(text);
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch return OracleError.Mismatch;
    defer parsed.deinit();
    const pkgs = parsed.value.object.get("packages") orelse return OracleError.Mismatch;
    if (pkgs != .array) return OracleError.Mismatch;
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |s| gpa.free(s);
        list.deinit(gpa);
    }
    for (pkgs.array.items) |*p| {
        if (p.* != .object) return OracleError.Mismatch;
        const name = p.object.get("name") orelse return OracleError.Mismatch;
        const ver = p.object.get("version") orelse return OracleError.Mismatch;
        if (name != .string or ver != .string) return OracleError.Mismatch;
        const s = std.fmt.allocPrint(gpa, "{s} {s}", .{ name.string, ver.string }) catch return OracleError.OutOfMemory;
        errdefer gpa.free(s);
        try list.append(gpa, s);
    }
    const slice = try list.toOwnedSlice(gpa);
    std.mem.sort([]const u8, slice, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return slice;
}

/// `golden.tree*.txt` package set: lines shaped `name vX[.Y][...]` (leading
/// tree glyphs tolerated); `name feature "…"` lines carry no version and
/// are skipped. Set-level only (rime has no tree renderer; structure is
/// cargo's to keep, the set is the conformance signal).
pub fn treeFilePkgs(gpa: std.mem.Allocator, text: []const u8) OracleError![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |s| gpa.free(s);
        list.deinit(gpa);
    }
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trimStart(u8, std.mem.trim(u8, line, " \t\r"), "│├└─ ");
        var toks = std.mem.tokenizeAny(u8, t, " \t");
        const name = toks.next() orelse continue;
        const ver = toks.next() orelse continue;
        if (std.mem.eql(u8, name, "[dev-dependencies]")) continue;
        if (!std.mem.startsWith(u8, ver, "v")) continue;
        const v = ver[1..];
        if (v.len == 0 or !std.ascii.isDigit(v[0])) continue;
        // Strip the `(*)` dup marker and ` (@root/…)` suffix cargo appends.
        const vend = std.mem.indexOfScalar(u8, v, ' ') orelse v.len;
        const s = std.fmt.allocPrint(gpa, "{s} {s}", .{ name, v[0..vend] }) catch return OracleError.OutOfMemory;
        errdefer gpa.free(s);
        // De-duplicate (tree repeats shared nodes; -features variants
        // repeat every line per feature edge).
        var dup = false;
        for (list.items) |e| {
            if (std.mem.eql(u8, e, s)) {
                dup = true;
                break;
            }
        }
        if (dup) {
            gpa.free(s);
            continue;
        }
        try list.append(gpa, s);
    }
    const slice = try list.toOwnedSlice(gpa);
    std.mem.sort([]const u8, slice, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return slice;
}

// =====================================================================
// Workspace resolution projection (the Task-7/12 seams' first real
// caller): manifests -> SummaryNodes -> resolveWithPrevious -> graph.
//
// Lock-resolution semantics (pinned by real cargo behavior, verified
// against the committed goldens):
// - `ops/resolve.rs::resolve_with_registry` resolves the LOCK with
//   `CliFeatures::new_all(true)`: EVERY optional edge is enabled, so the
//   projection emits all optional deps as required edges (the core never
//   enqueues `optional` edges; unify/prune only NARROW for build plans).
// - Dev-deps resolve for workspace MEMBERS only (transitive dev edges of
//   registry/path non-members are excluded, exactly as cargo's
//   `resolve_ws_with_opts` scopes `dev_deps` to members).
// - Target-gated edges resolve for ALL targets (lockfiles are
//   platform-independent: `windows-sys` ships in macOS-generated locks).
// - `[patch]` replaces the registry candidate set for patched names
//   (`registry.lock_patches`); shadowed previous-lock versions lose `keep`
//   via `patchPreferences` (`avoid_patch_ids`) while patch versions become
//   `preferred`.
// - Previous-lock guidance is keep-everything (empty `update_names`) plus
//   the patch-avoid names above -- exactly the M4 driver flow.

const WsError = error{ Mismatch, OutOfMemory, SkipZigTest, Io };

fn wsFail(comptime fmt: []const u8, args: anytype) WsError {
    std.debug.print("oracle resolve: " ++ fmt ++ "\n", args);
    return WsError.Mismatch;
}

const index_url = "sparse+https://github.com/rust-lang/crates.io-index";

/// `*` names the `Any` requirement; anything else parses now (manifest reqs
/// were validated at parse, but index reqs fail per-entry: a bad `req`
/// makes that entry `Invalid` -- dropped, never fatal, per section 0.6).
fn optReqFromText(text: []const u8) semver.OptVersionReq {
    const t = std.mem.trim(u8, text, " \t");
    if (t.len == 0 or std.mem.eql(u8, t, "*")) return .any;
    const req = semver.VersionReq.parse(t) catch return .any;
    // NOTE: unreachable for manifest reqs (validated); for index reqs the
    // ENTRY-level skip happens in `projectIndexEntry`, which checks
    // parseability BEFORE calling this. A parse failure here would silently
    // widen to Any, so that pre-check is load-bearing -- see below.
    return .{ .req = req };
}

fn indexReqOk(text: []const u8) bool {
    const t = std.mem.trim(u8, text, " \t");
    if (t.len == 0 or std.mem.eql(u8, t, "*")) return true;
    _ = semver.VersionReq.parse(t) catch return false;
    return true;
}

/// Manifest `DepRef` -> resolve edge under the lock projection (all
/// optional deps enabled). `version_req` for path/git tables comes from the
/// retained `version` text (`DepRef.version`), `Any` when absent.
fn manifestEdge(d: manifest.DepRef) WsError!resolve.DepEdge {
    // Alternate registries have no stub-index source in the oracle: resolving
    // against crates.io would pick the wrong source silently (§0.7), so fail
    // loudly like the git/workspace-inherit arms below and the index-side
    // non-default-registry check in `projectCrate`.
    if (d.registry_url != null) return wsFail("alternate-registry dependency `{s}` unsupported in the oracle (crates.io only)", .{d.key});
    const req_text: []const u8 = switch (d.kind) {
        .version_req => |r| r,
        .path => d.version orelse "*",
        .git => return wsFail("git dependency `{s}` unsupported in the oracle (path+registry only)", .{d.key}),
        .workspace_inherit => return wsFail("unexpanded workspace-inherit dep `{s}` reached resolution", .{d.key}),
    };
    return .{
        .name = d.realName(),
        .req = optReqFromText(req_text),
        .optional = false,
        .build_only = d.dep_kind == .build,
    };
}

/// Index dep -> resolve edge; null means SKIP (dev edges of non-members,
/// non-default registries -- the latter loud-skipped: no corpus case hits
/// it, and a silent wrong-source resolution would be a conformance bug).
fn indexEdge(d: index.IndexDep) ?resolve.DepEdge {
    if (d.kind == .dev) return null;
    if (d.registry != null) return null;
    if (!indexReqOk(d.req)) return null;
    return .{
        .name = d.realName(),
        .req = optReqFromText(d.req),
        .optional = false,
        .build_only = d.kind == .build,
    };
}

/// Sparse-index URL layout (`index/mod.rs` cache path): 1/2/3-char names
/// get short prefixes, longer names `ab/cd/rest`.
fn indexRelPath(name: []const u8, buf: *[96]u8) []const u8 {
    if (name.len == 1) return std.fmt.bufPrint(buf, "1/{s}", .{name}) catch unreachable;
    if (name.len == 2) return std.fmt.bufPrint(buf, "2/{s}", .{name}) catch unreachable;
    if (name.len == 3) return std.fmt.bufPrint(buf, "3/{s}/{s}", .{ name[0..1], name }) catch unreachable;
    return std.fmt.bufPrint(buf, "{s}/{s}/{s}", .{ name[0..2], name[2..4], name }) catch unreachable;
}

/// Prebuilt-artifact mode (no-spawn environments): RIME_ORACLE_PREBUILT
/// points at a dir of shell-produced real-cargo outputs
/// (case-name/Cargo.lock), and RIME_INDEX_DIR at shell-fetched sparse-index
/// files (crate-relpath layout). The compared bytes are still genuine
/// cargo/index outputs (see the shell procedure in the conformance report);
/// only the invoker differs. Where test-process spawning works, the live
/// paths below are used instead.
fn prebuiltDir() ?[]const u8 {
    const v = std.c.getenv("RIME_ORACLE_PREBUILT") orelse return null;
    return std.mem.span(v);
}

fn indexFileDir() ?[]const u8 {
    const v = std.c.getenv("RIME_INDEX_DIR") orelse return null;
    return std.mem.span(v);
}

/// Fetch one crate's sparse-index lines over HTTP (same wire bytes cargo
/// consumes). Curl failure (no curl, offline, HTTP error, timeout, or an
/// environment where test-process spawning is unavailable) falls back to
/// RIME_INDEX_DIR files when set; anything else is `FetchFailed` -- the
/// caller records it and the test SKIPS (environmental, never a false red).
fn fetchIndexLines(gpa: std.mem.Allocator, io: std.Io, name: []const u8) error{ FetchFailed, OutOfMemory }![]u8 {
    var rel_buf: [96]u8 = undefined;
    const rel = indexRelPath(name, &rel_buf);
    const url = std.fmt.allocPrint(gpa, "https://index.crates.io/{s}", .{rel}) catch return error.OutOfMemory;
    defer gpa.free(url);
    const res = runCapture(gpa, io, &.{ "curl", "-fsSL", "--max-time", "50", url }, "") catch |e| switch (e) {
        RunError.OutOfMemory => return error.OutOfMemory,
        RunError.SpawnFailed, RunError.TimedOut => {
            if (indexFileDir()) |idir| {
                const fpath = std.fmt.allocPrint(gpa, "{s}/{s}", .{ idir, rel }) catch return error.OutOfMemory;
                defer gpa.free(fpath);
                return std.Io.Dir.cwd().readFileAlloc(io, fpath, gpa, .limited(32 << 20)) catch |read_err| {
                    std.debug.print("oracle: index file missing for `{s}` ({s}): {t}\n", .{ name, fpath, read_err });
                    return error.FetchFailed;
                };
            }
            std.debug.print("oracle: index fetch failed for `{s}` (no file fallback)\n", .{name});
            return error.FetchFailed;
        },
    };
    errdefer gpa.free(res.out);
    if (res.exited != 0) {
        gpa.free(res.out);
        return error.FetchFailed;
    }
    return res.out;
}

const PathNode = struct {
    is_patch_target: bool, // true for [patch] vendored dirs: invisible to the path query branch (patch branch serves them)
    name: []const u8, // registry arena
    version: semver.Version, // borrows ext manifest text
    dir: []const u8, // absolute dir (registry arena)
    is_member: bool,
    summary: resolve.SummaryNode, // precomputed (dep req texts + links borrow ext)
    ext: manifest.ManifestExt, // KEPT ALIVE: summaries borrow its arenas; deinited with the registry
};

const PatchNode = struct {
    name: []const u8, // REAL name
    version: semver.Version,
    summary: resolve.SummaryNode,
    used: bool,
};

const CrateSummaries = struct {
    nodes: []resolve.SummaryNode,
};

const WsRegistry = struct {
    arena: std.heap.ArenaAllocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    path_nodes: std.ArrayList(PathNode),
    patch_nodes: std.ArrayList(PatchNode),
    entries: std.ArrayList(index.IndexEntry), // ALL parsed entries, kept alive (candidates borrow them)
    crates: std.StringHashMap(CrateSummaries),
    previous: []resolve.ResolvedNode, // minimal-update guidance (arena + gpa mix; freed below)
    wanted: std.StringHashMap([]const []const u8), // registry name -> rendered previous versions
    fetch_failed: bool, // environmental (curl/offline/HTTP): skip, never a false red
    hard_failed: bool, // genuine semantic failure inside query: Mismatch, never skip
    replaces: []manifest.ReplaceEntry,

    pub fn deinit(self: *WsRegistry) void {
        for (self.entries.items) |*e| e.deinit(self.gpa);
        self.entries.deinit(self.gpa);
        var cit = self.crates.iterator();
        while (cit.next()) |kv| {
            self.gpa.free(kv.key_ptr.*);
            for (kv.value_ptr.nodes) |n| self.gpa.free(n.deps);
            self.gpa.free(kv.value_ptr.nodes);
        }
        self.crates.deinit();
        var wit = self.wanted.iterator();
        while (wit.next()) |kv| {
            self.gpa.free(kv.key_ptr.*);
            for (kv.value_ptr.*) |s| self.gpa.free(s);
            self.gpa.free(kv.value_ptr.*);
        }
        self.wanted.deinit();
        for (self.path_nodes.items) |*pn| {
            self.gpa.free(pn.summary.deps);
            pn.ext.deinit();
        }
        for (self.previous) |*pn| self.gpa.free(pn.deps);
        self.gpa.free(self.previous);
        self.path_nodes.deinit(self.gpa);
        self.patch_nodes.deinit(self.gpa);
        self.arena.deinit();
    }

    pub fn registry(self: *WsRegistry) resolve.Registry {
        return .{ .ctx = @ptrCast(self), .queryFn = queryFn };
    }

    fn queryFn(ctx: *anyopaque, name: []const u8) resolve.QueryError![]const resolve.SummaryNode {
        const self: *WsRegistry = @ptrCast(@alignCast(ctx));
        return self.query(name) catch |e| switch (e) {
            // WsError.Io/SkipZigTest are unreachable inside query (no IO,
            // no gating there); both collapse to FetchFailed like genuine
            // Mismatch (flagged via hard_failed/fetch_failed below).
            error.OutOfMemory => resolve.QueryError.OutOfMemory,
            error.Mismatch, error.Io, error.SkipZigTest => resolve.QueryError.FetchFailed,
        };
    }

    fn query(self: *WsRegistry, name: []const u8) WsError![]const resolve.SummaryNode {
        const alloc = self.arena.allocator();
        // 1. Path packages (members + transitive path deps). Patch targets
        // are EXCLUDED here even though they live in path_nodes (fixup
        // needs them): the patch branch below serves them and tracks use.
        var path_hits: usize = 0;
        for (self.path_nodes.items) |*pn| {
            if (!pn.is_patch_target and std.mem.eql(u8, pn.name, name)) path_hits += 1;
        }
        if (path_hits > 0) {
            const out = alloc.alloc(resolve.SummaryNode, path_hits) catch return WsError.OutOfMemory;
            var i: usize = 0;
            for (self.path_nodes.items) |*pn| {
                if (pn.is_patch_target or !std.mem.eql(u8, pn.name, name)) continue;
                out[i] = pn.summary;
                i += 1;
            }
            return out;
        }
        // 2. Patch overrides (registry candidates are REPLACED, never merged).
        var patch_hits: usize = 0;
        for (self.patch_nodes.items) |*pn| {
            if (std.mem.eql(u8, pn.name, name)) patch_hits += 1;
        }
        if (patch_hits > 0) {
            const out = alloc.alloc(resolve.SummaryNode, patch_hits) catch return WsError.OutOfMemory;
            var i: usize = 0;
            for (self.patch_nodes.items) |*pn| {
                if (!std.mem.eql(u8, pn.name, name)) continue;
                pn.used = true;
                out[i] = pn.summary;
                i += 1;
            }
            return out;
        }
        // 3. [replace] only targets registry summaries here; a spec naming
        // a path package is a loud misuse (no corpus case hits it).
        for (self.replaces) |r| {
            if (manifest.matchReplaceSpec(r.spec, name, null)) {
                self.hard_failed = true;
                return wsFail("[replace] spec `{s}` names path-resolved `{s}` (oracle supports registry targets only)", .{ r.spec, name });
            }
        }
        // 4. Sparse index (cached per crate).
        if (self.crates.get(name)) |hit| return hit.nodes;
        const text = fetchIndexLines(self.gpa, self.io, name) catch |e| switch (e) {
            error.OutOfMemory => return WsError.OutOfMemory,
            error.FetchFailed => {
                self.fetch_failed = true;
                return WsError.Mismatch;
            },
        };
        defer self.gpa.free(text);
        const nodes = try self.projectCrate(name, text);
        const owned_name = self.gpa.dupe(u8, name) catch return WsError.OutOfMemory;
        errdefer self.gpa.free(owned_name);
        try self.crates.put(owned_name, .{ .nodes = nodes });
        return nodes;
    }

    /// Parse one crate's index lines into summaries. Lines failing even
    /// minimal parse are SKIPPED (slow-path `continue`, never fatal);
    /// schema-v3+ lines parse but stay unselected (`unsupported`); entries
    /// with unparseable reqs are DROPPED (`Invalid`, never selected). The
    /// `wanted` prefilter keeps only previous-lock versions when the crate
    /// has any (keep-everything Locked resolution can only select those);
    /// crates with no previous versions parse everything (fresh selection).
    fn projectCrate(self: *WsRegistry, name: []const u8, text: []const u8) WsError![]resolve.SummaryNode {
        const wanted = self.wanted.get(name);
        var nodes: std.ArrayList(resolve.SummaryNode) = .empty;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const t = std.mem.trim(u8, line, " \t\r");
            if (t.len == 0) continue;
            if (wanted) |ws| {
                if (!versWanted(t, ws)) continue;
            }
            var entry = index.parseIndexLine(self.gpa, t) catch continue;
            if (entry.unsupported) {
                entry.deinit(self.gpa);
                continue;
            }
            // A non-default `registry` on any dep is LOUD (propagates past
            // the skip handler below -- wrong-source resolution would be
            // silent divergence; no corpus case hits it).
            for (entry.deps) |d| {
                if (d.registry != null) {
                    entry.deinit(self.gpa);
                    self.hard_failed = true;
                    return wsFail("crate `{s}` index entry has a non-default registry dep (oracle supports crates.io only)", .{entry.candidate.name});
                }
            }
            const node = try self.projectEntry(&entry);
            try self.entries.append(self.gpa, entry);
            if (node) |n| try nodes.append(self.gpa, n);
        }
        return nodes.toOwnedSlice(self.gpa) catch return WsError.OutOfMemory;
    }

    /// Entry -> SummaryNode; null when the entry is Invalid (an unparseable
    /// dep req anywhere drops the whole entry, exactly as
    /// `registry_dependency_into_dep` failing drops the summary). A
    /// non-default `registry` on any dep is a LOUD skip (wrong-source
    /// resolution would be silent divergence; no corpus case hits it).
    fn projectEntry(self: *WsRegistry, entry: *index.IndexEntry) WsError!?resolve.SummaryNode {
        for (entry.deps) |d| {
            if (d.kind != .dev and !indexReqOk(d.req)) return null;
        }
        var edges: std.ArrayList(resolve.DepEdge) = .empty;
        for (entry.deps) |d| {
            if (indexEdge(d)) |e| try edges.append(self.gpa, e);
        }
        const deps = edges.toOwnedSlice(self.gpa) catch return WsError.OutOfMemory;
        // `name`/`candidate`/`links` borrow the entry (kept alive in
        // `entries` for the whole resolve); only the edge slice is owned.
        return .{
            .name = entry.candidate.name,
            .candidate = entry.candidate,
            .deps = deps,
            .links = entry.links,
        };
    }
};

/// `"vers":"<v>"` substring test against the wanted rendered versions.
fn versWanted(line: []const u8, wanted: []const []const u8) bool {
    const key = "\"vers\":\"";
    const i = std.mem.indexOf(u8, line, key) orelse return false;
    const rest = line[i + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return false;
    const vers = rest[0..end];
    for (wanted) |w| {
        if (std.mem.eql(u8, vers, w)) return true;
    }
    return false;
}

/// A fully-loaded workspace: registry (owns ALL manifest/index memory),
/// root ext (owns replaces/patch tables borrowed below), precomputed roots,
/// previous-lock nodes, and update guidance. Deinit in reverse: caller frees
/// `prefer`/`update_names`, then `load.deinit()`.
const WsLoad = struct {
    reg: WsRegistry,
    root_ext: manifest.ManifestExt,
    root_dir: []const u8, // absolute, in reg.arena
    roots: []resolve.SummaryNode, // gpa-owned (copies of member summaries)
    previous: []resolve.ResolvedNode, // reg.arena-owned
    prefer: []index.PreferredId, // gpa-owned
    update_names: [][]const u8, // gpa-owned (names with patch-shadowed locks)
    patch_versions: []manifest.PatchVersion, // gpa-owned (versions borrow patch exts)

    pub fn deinit(self: *WsLoad) void {
        const gpa = self.reg.gpa;
        gpa.free(self.roots);
        gpa.free(self.prefer);
        for (self.update_names) |n| gpa.free(n);
        gpa.free(self.update_names);
        gpa.free(self.patch_versions);
        self.root_ext.deinit();
        self.reg.deinit();
    }
};

fn readManifestFile(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) WsError!struct { text: []u8, path: []u8 } {
    const path = std.fmt.allocPrint(gpa, "{s}/Cargo.toml", .{dir}) catch return WsError.OutOfMemory;
    errdefer gpa.free(path);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |e| switch (e) {
        error.OutOfMemory => return WsError.OutOfMemory,
        else => return wsFail("cannot read manifest `{s}`", .{path}),
    };
    return .{ .text = text, .path = path };
}

/// Load + project a workspace dir for lock resolution. `previous_lock` is
/// the lock guiding minimal-update (golden bytes or cargo-fresh bytes);
/// null means fresh resolution.
fn loadWorkspace(gpa: std.mem.Allocator, io: std.Io, ws_dir: []const u8, previous_lock: ?[]const u8) WsError!WsLoad {
    var ws = workspace.discover(gpa, io, ws_dir, null) catch {
        return wsFail("workspace discovery failed for `{s}`", .{ws_dir});
    };
    defer ws.deinit();
    var reg = WsRegistry{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .gpa = gpa,
        .io = io,
        .path_nodes = .empty,
        .patch_nodes = .empty,
        .entries = .empty,
        .crates = std.StringHashMap(CrateSummaries).init(gpa),
        .wanted = std.StringHashMap([]const []const u8).init(gpa),
        .fetch_failed = false,
        .hard_failed = false,
        .previous = &.{},
        .replaces = &.{},
    };
    errdefer reg.deinit();
    const alloc = reg.arena.allocator();
    const root_dir = alloc.dupe(u8, ws.root_dir) catch return WsError.OutOfMemory;

    // Root manifest first (inheritance source + patches + replaces).
    const root_file = try readManifestFile(gpa, io, root_dir);
    defer gpa.free(root_file.text);
    defer gpa.free(root_file.path);
    var root_ext = manifest.parseManifestExt(gpa, root_file.text, root_file.path) catch |e| {
        return wsFail("root manifest `{s}` failed to parse: {t}", .{ root_file.path, e });
    };
    errdefer root_ext.deinit();
    reg.replaces = root_ext.replaces;

    // Members: parse + inherit, then seed the path walk.
    var visit: std.ArrayList(struct { dir: []const u8, is_member: bool }) = .empty;
    defer visit.deinit(gpa);
    var seen: std.StringHashMap(void) = std.StringHashMap(void).init(gpa);
    defer seen.deinit();
    for (ws.members) |*m| {
        const dir = alloc.dupe(u8, m.dir) catch return WsError.OutOfMemory;
        const f = try readManifestFile(gpa, io, dir);
        defer gpa.free(f.text);
        defer gpa.free(f.path);
        const ext = manifest.parseManifestExt(gpa, f.text, f.path) catch |e| {
            return wsFail("member manifest `{s}` failed to parse: {t}", .{ f.path, e });
        };
        const resolved = manifest.resolveInheritance(gpa, ext, root_ext) catch |e| {
            return wsFail("member manifest `{s}` failed inheritance: {t}", .{ f.path, e });
        };
        // Ownership transfer with a pending slot: addPathNode stores the
        // ext in path_nodes (reg.deinit frees it); if anything below fails
        // first, the slot frees it. A bare errdefer would double-free after
        // a successful transfer.
        var pending: ?manifest.ManifestExt = resolved;
        errdefer if (pending) |*px| px.deinit();
        try addPathNode(gpa, &reg, dir, true, false, pending.?);
        pending = null;
        try visit.append(gpa, .{ .dir = dir, .is_member = true });
        try seen.put(dir, {});
    }

    // Transitive path walk (member deps, patch targets, replacement
    // targets): breadth-first over manifest-declared path deps.
    var head: usize = 0;
    while (head < visit.items.len) {
        const cur = visit.items[head];
        head += 1;
        const node = findPathNode(&reg, cur.dir) orelse continue;
        // NOTE: `node.ext` borrows below; the lists are arena-stable.
        const ext_lists = [_][]manifest.DepRef{ node.ext.renamed, node.ext.target_deps };
        for (ext_lists) |list| {
            for (list) |d| {
                if (d.kind != .path) continue;
                const target = joinPath(alloc, cur.dir, d.kind.path) catch return WsError.OutOfMemory;
                if (seen.contains(target)) continue;
                try seen.put(target, {});
                const f = try readManifestFile(gpa, io, target);
                defer gpa.free(f.text);
                defer gpa.free(f.path);
                const ext = manifest.parseManifestExt(gpa, f.text, f.path) catch |e| {
                    return wsFail("path manifest `{s}` failed to parse: {t}", .{ f.path, e });
                };
                const resolved = manifest.resolveInheritance(gpa, ext, root_ext) catch |e| {
                    return wsFail("path manifest `{s}` failed inheritance: {t}", .{ f.path, e });
                };
                var pending: ?manifest.ManifestExt = resolved;
                errdefer if (pending) |*px| px.deinit();
                // Path req check (cargo validates the target version
                // against the declaring req, it never silently mismatches).
                const target_pkg = resolved.base.pkg orelse {
                    return wsFail("path manifest `{s}` has no [package]", .{f.path});
                };
                if (d.version) |rv| {
                    const tv = semver.Version.parse(target_pkg.version) catch {
                        return wsFail("path package `{s}` has an unparseable version", .{f.path});
                    };
                    const req = semver.VersionReq.parse(rv) catch {
                        return wsFail("invalid path req `{s}`", .{rv});
                    };
                    if (!req.matches(tv)) {
                        return wsFail("path dependency `{s}` version {s} does not satisfy req `{s}`", .{ d.key, target_pkg.version, rv });
                    }
                }
                try addPathNode(gpa, &reg, target, false, false, pending.?);
                pending = null;
                try visit.append(gpa, .{ .dir = target, .is_member = false });
            }
        }
    }

    // Patch targets (path form): read manifests, build patch nodes.
    var patch_versions: std.ArrayList(manifest.PatchVersion) = .empty;
    errdefer patch_versions.deinit(gpa);
    for (root_ext.patches) |p| {
        for (p.deps) |d| {
            if (d.kind == .path) {
                const target = joinPath(alloc, root_dir, d.kind.path) catch return WsError.OutOfMemory;
                if (findPathNode(&reg, target)) |existing| {
                    if (!existing.is_patch_target) {
                        return wsFail("patch target `{s}` is also a workspace member (member-patch corner unsupported)", .{target});
                    }
                } else {
                    try seen.put(target, {});
                    const f = try readManifestFile(gpa, io, target);
                    defer gpa.free(f.text);
                    defer gpa.free(f.path);
                    const ext = manifest.parseManifestExt(gpa, f.text, f.path) catch |e| {
                        return wsFail("patch manifest `{s}` failed to parse: {t}", .{ f.path, e });
                    };
                    const resolved = manifest.resolveInheritance(gpa, ext, root_ext) catch |e| {
                        return wsFail("patch manifest `{s}` failed inheritance: {t}", .{ f.path, e });
                    };
                    var pending: ?manifest.ManifestExt = resolved;
                    errdefer if (pending) |*px| px.deinit();
                    try addPathNode(gpa, &reg, target, false, true, pending.?);
                    pending = null;
                }
                const pn = findPathNode(&reg, target) orelse return wsFail("patch target vanished", .{});
                // The patch manifest MUST name the patched crate (cargo
                // identifies the patch by it -- a rename here is an error).
                const patch_pkg = pn.ext.base.pkg orelse return wsFail("patch manifest `{s}` has no [package]", .{target});
                if (!std.mem.eql(u8, patch_pkg.name, d.realName())) {
                    return wsFail("patch entry `{s}` names manifest `{s}` (must match)", .{ d.realName(), patch_pkg.name });
                }
                try reg.patch_nodes.append(gpa, .{ .name = d.realName(), .version = pn.version, .summary = pn.summary, .used = false });
                try patch_versions.append(gpa, .{ .name = d.realName(), .version = pn.version });
            } else if (d.kind == .version_req) {
                return wsFail("[patch] version-form entry `{s}` needs a registry patch source (oracle supports path patches only)", .{d.key});
            } else if (d.kind == .git) {
                return wsFail("[patch] git entry `{s}` unsupported in the oracle (path patches only)", .{d.key});
            } else {
                return wsFail("[patch] entry `{s}` has no usable source", .{d.key});
            }
        }
    }

    // Previous-lock nodes (minimal-update guidance, owned by reg).
    if (previous_lock) |text| {
        reg.previous = try previousFromLock(&reg, text);
    }
    const previous = reg.previous;

    // Patch preferences: prefer pins feed the query filter; shadowed
    // previous versions become update targets (lose keep, re-resolve).
    var prefer: []index.PreferredId = &.{};
    var update_names: std.ArrayList([]const u8) = .empty;
    errdefer {
        gpa.free(prefer);
        for (update_names.items) |n| gpa.free(n);
        update_names.deinit(gpa);
    }
    const pvs = try patch_versions.toOwnedSlice(gpa);
    errdefer gpa.free(pvs);
    if (pvs.len > 0) {
        const prefs = root_ext.patchPreferences(gpa, previous, pvs) catch return WsError.OutOfMemory;
        defer gpa.free(prefs.prefer);
        defer gpa.free(prefs.avoid_locked);
        prefer = gpa.dupe(index.PreferredId, prefs.prefer) catch return WsError.OutOfMemory;
        var unwant: std.ArrayList([]const u8) = .empty;
        defer unwant.deinit(gpa);
        for (previous) |pn| {
            if (!root_ext.isPatched(pn.name)) continue;
            var shadowed = true;
            for (pvs) |pv| {
                if (std.mem.eql(u8, pv.name, pn.name) and pv.version.eql(pn.version)) {
                    shadowed = false;
                    break;
                }
            }
            if (shadowed) try unwant.append(gpa, pn.name);
        }
        // De-duplicate names.
        std.mem.sort([]const u8, unwant.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lt);
        var last: ?[]const u8 = null;
        for (unwant.items) |n| {
            if (last) |l| {
                if (std.mem.eql(u8, l, n)) continue;
            }
            last = n;
            try update_names.append(gpa, try gpa.dupe(u8, n));
        }
    }

    // Wanted versions per registry crate (vers prefilter).
    for (previous) |*pn| {
        if (pn.source != .registry) continue;
        const ver = try renderVersion(gpa, pn.version);
        errdefer gpa.free(ver);
        const key = gpa.dupe(u8, pn.name) catch {
            gpa.free(ver);
            return WsError.OutOfMemory;
        };
        errdefer gpa.free(key);
        if (reg.wanted.getPtr(key)) |slot| {
            gpa.free(key);
            const old = slot.*;
            const grown = gpa.alloc([]const u8, old.len + 1) catch {
                gpa.free(ver);
                return WsError.OutOfMemory;
            };
            @memcpy(grown[0..old.len], old);
            grown[old.len] = ver;
            gpa.free(old);
            slot.* = grown;
        } else {
            const arr = gpa.alloc([]const u8, 1) catch {
                gpa.free(key);
                gpa.free(ver);
                return WsError.OutOfMemory;
            };
            arr[0] = ver;
            reg.wanted.put(key, arr) catch {
                gpa.free(key);
                gpa.free(ver);
                gpa.free(arr);
                return WsError.OutOfMemory;
            };
        }
    }

    // Roots = member summaries (precomputed in path_nodes).
    var roots: std.ArrayList(resolve.SummaryNode) = .empty;
    errdefer roots.deinit(gpa);
    for (reg.path_nodes.items) |*pn| {
        if (!pn.is_member) continue;
        try roots.append(gpa, pn.summary);
    }

    return .{
        .reg = reg,
        .root_ext = root_ext,
        .root_dir = root_dir,
        .roots = try roots.toOwnedSlice(gpa),
        .previous = previous,
        .prefer = prefer,
        .update_names = try update_names.toOwnedSlice(gpa),
        .patch_versions = pvs,
    };
}

fn findPathNode(reg: *WsRegistry, dir: []const u8) ?*PathNode {
    for (reg.path_nodes.items) |*pn| {
        if (std.mem.eql(u8, pn.dir, dir)) return pn;
    }
    return null;
}

fn joinPath(alloc: std.mem.Allocator, dir: []const u8, rel: []const u8) WsError![]u8 {
    if (std.fs.path.isAbsolute(rel)) return alloc.dupe(u8, rel) catch return WsError.OutOfMemory;
    return std.fs.path.join(alloc, &.{ dir, rel }) catch return WsError.OutOfMemory;
}

/// Store a parsed path package (members keep dev edges; non-members drop
/// them). Takes ownership of `ext`. Git edges are LOUD (no corpus case).
/// NOTE: `reg.path_nodes` may reallocate -- callers must re-fetch pointers
/// after this returns (only arena-stable slices are held across calls).
fn addPathNode(gpa: std.mem.Allocator, reg: *WsRegistry, dir: []const u8, is_member: bool, is_patch_target: bool, ext: manifest.ManifestExt) WsError!void {
    _ = gpa;
    const alloc = reg.arena.allocator();
    const pkg = ext.base.pkg orelse return wsFail("manifest `{s}` has no [package]", .{ext.filename});
    const version = semver.Version.parse(pkg.version) catch {
        return wsFail("package `{s}` has an unparseable version `{s}`", .{ pkg.name, pkg.version });
    };
    const name = alloc.dupe(u8, pkg.name) catch return WsError.OutOfMemory;
    var edges: std.ArrayList(resolve.DepEdge) = .empty;
    const lists = [_][]manifest.DepRef{ ext.renamed, ext.target_deps };
    for (lists) |list| {
        for (list) |d| {
            if (!is_member and d.dep_kind == .dev) continue;
            try edges.append(reg.gpa, try manifestEdge(d));
        }
    }
    const deps = edges.toOwnedSlice(reg.gpa) catch return WsError.OutOfMemory;
    errdefer reg.gpa.free(deps);
    // The stored node borrows `ext` (version pre/build slices, links, dep
    // req texts) -- the ext moves into the node slot and dies with the
    // registry. name/dir are arena-owned; deps is gpa-owned (freed in
    // deinit alongside the ext).
    try reg.path_nodes.append(reg.gpa, .{
        .is_patch_target = is_patch_target,
        .name = name,
        .version = version,
        .dir = dir,
        .is_member = is_member,
        .summary = .{
            .name = name,
            .candidate = .{
                .name = name,
                .version = version,
                .yanked = false,
                .checksum = null,
                .rust_version = null,
                .pubtime = null,
            },
            .deps = deps,
            .links = ext.links,
        },
        .ext = ext,
    });
}

/// Previous-lock decode for minimal-update guidance: versions parse now
/// (unparseable = loud Mismatch, never a silent skip); sources map
/// null->path, `registry+` canonical crates.io->registry, anything else
/// (git, alternate registries) is a loud Mismatch. Edges resolve with
/// `into_resolve` tolerance (ambiguous/dangling edge strings are DROPPED).
fn previousFromLock(reg: *WsRegistry, text: []const u8) WsError![]resolve.ResolvedNode {
    const alloc = reg.arena.allocator();
    var lf = lock.parseLock(reg.gpa, text) catch {
        return wsFail("previous lockfile failed to parse", .{});
    };
    defer lf.deinit();
    var nodes: std.ArrayList(resolve.ResolvedNode) = .empty;
    for (lf.packages) |*p| {
        const version = semver.Version.parse(p.version) catch {
            return wsFail("previous lock package `{s}` has an unparseable version `{s}`", .{ p.name, p.version });
        };
        const source: sources.SourceId = if (p.source) |s| blk: {
            if (std.mem.eql(u8, s, "registry+https://github.com/rust-lang/crates.io-index")) {
                break :blk .{ .registry = index_url };
            }
            return wsFail("previous lock package `{s}` has a non-crates.io source `{s}`", .{ p.name, s });
        } else .{ .path = "" };
        const name = alloc.dupe(u8, p.name) catch return WsError.OutOfMemory;
        var refs: std.ArrayList(resolve.ResolvedRef) = .empty;
        for (p.dependencies) |e| {
            const r = resolvePrevEdge(lf.packages, e) orelse continue;
            const pv = semver.Version.parse(r.version) catch continue;
            const rname = alloc.dupe(u8, r.name) catch return WsError.OutOfMemory;
            // Ref sources are name-based placeholders here (only names and
            // versions feed the keep-closure walk); the resolved graph gets
            // real sources from the fixup below.
            try refs.append(reg.gpa, .{ .name = rname, .version = pv, .source = .{ .path = "" } });
        }
        const dep_slice = refs.toOwnedSlice(reg.gpa) catch return WsError.OutOfMemory;
        try nodes.append(reg.gpa, .{ .name = name, .version = version, .source = source, .deps = dep_slice });
    }
    return nodes.toOwnedSlice(reg.gpa) catch return WsError.OutOfMemory;
}

const PrevEdge = struct { name: []const u8, version: []const u8 };

/// `into_resolve`-tolerant edge resolution for the previous-lock walk
/// (mirrors `cli.resolveLockEdgeForSig`: bare names need a unique version,
/// qualified edges need the package to exist, else dropped).
fn resolvePrevEdge(packages: []lock.LockPackage, edge: []const u8) ?PrevEdge {
    const sp = std.mem.indexOfScalar(u8, edge, ' ') orelse {
        var first: ?[]const u8 = null;
        for (packages) |*p| {
            if (!std.mem.eql(u8, p.name, edge)) continue;
            if (first) |f| {
                if (!std.mem.eql(u8, f, p.version)) return null;
            } else first = p.version;
        }
        const v = first orelse return null;
        return .{ .name = edge, .version = v };
    };
    const name = edge[0..sp];
    const rest = edge[sp + 1 ..];
    const ver = if (std.mem.indexOfScalar(u8, rest, ' ')) |sp2| rest[0..sp2] else rest;
    for (packages) |*p| {
        if (std.mem.eql(u8, p.name, name) and std.mem.eql(u8, p.version, ver)) return .{ .name = name, .version = ver };
    }
    return null;
}

/// Run the keep-everything (+patch-avoid) resolution, then narrow
/// optionals through the feature pass (buildMaps -> unifyV1 ->
/// pruneOptional) and return a self-contained graph (deep-copied into its
/// own arena, so the caller can drop everything else). Maps environmental
/// trouble (fetch) to SKIP and genuine failures to MISMATCH.
fn runResolve(gpa: std.mem.Allocator, load: *WsLoad) WsError!resolve.ResolveGraph {
    const filter = index.QueryFilter{
        .allow_yanked = &.{},
        .max_pubtime = null,
        .min_versions_first = false,
        .rust_versions = &.{},
        .preferred = load.prefer,
    };
    const keep = resolve.KeepFilter{ .update_names = load.update_names };
    const prev: ?[]const resolve.ResolvedNode = if (load.previous.len == 0 and load.update_names.len == 0) null else load.previous;
    var pass1 = resolve.resolveWithPrevious(gpa, load.roots, load.reg.registry(), prev, keep, filter) catch |e| {
        // Environmental trouble (index fetch) skips even when resolution
        // itself errors; genuine query failures fail loudly.
        if (load.reg.hard_failed) return WsError.Mismatch;
        if (load.reg.fetch_failed) {
            std.debug.print("oracle resolve: skipping (index fetch failed)\n", .{});
            return WsError.SkipZigTest;
        }
        return switch (e) {
            resolve.ResolveError.NoMatchingVersion => wsFail("resolution found no matching version", .{}),
            resolve.ResolveError.Conflict => wsFail("resolution conflicted", .{}),
            resolve.ResolveError.Cycle => wsFail("resolution found a dependency cycle", .{}),
            resolve.ResolveError.OutOfMemory => WsError.OutOfMemory,
        };
    };
    defer pass1.deinit();
    if (load.reg.hard_failed) return WsError.Mismatch;
    if (load.reg.fetch_failed) return WsError.SkipZigTest;
    try fixupSources(load, &pass1);
    // Feature pass: maps + per-package requests from the resolved data,
    // unify (v1 namespace -- lock resolution is not target- or host-split
    // at the VERSION level), prune disabled optionals.
    const maps = try buildMaps(load, &pass1);
    const reqs = try buildRootReqs(gpa, load, &pass1);
    defer gpa.free(reqs);
    var unified = features.unifyV1(gpa, &pass1, &maps, reqs) catch |e| switch (e) {
        features.UnifiedError.UnknownFeature => return wsFail("feature unification hit an unknown feature", .{}),
        features.UnifiedError.InvalidBehavior => return wsFail("feature unification behavior error", .{}),
        features.UnifiedError.OutOfMemory => return WsError.OutOfMemory,
    };
    defer unified.deinit();
    const kept = try pruneEnabled(gpa, &pass1, &unified);
    defer gpa.free(kept);
    // Deep-copy the survivors into a fresh arena (headers only; strings
    // stay borrowed from loader-owned memory, alive past this call).
    var out_arena = std.heap.ArenaAllocator.init(gpa);
    errdefer out_arena.deinit();
    const na = out_arena.allocator();
    const nodes = na.alloc(resolve.ResolvedNode, kept.len) catch return WsError.OutOfMemory;
    for (kept, nodes) |*src, *dst| {
        dst.* = src.*;
        dst.deps = na.dupe(resolve.ResolvedRef, src.deps) catch return WsError.OutOfMemory;
    }
    return .{ .arena = out_arena, .nodes = nodes };
}

/// Source fixup (the core's placeholder-registry documented in
/// `resolve.zig`: every non-root node emerges `.registry`, including path
/// packages). Re-key by (name, version) against the walked path set; patch
/// and registry nodes keep the canonical registry source. Both nodes AND
/// refs are rewritten consistently (the writer renders refs through the
/// same shortening/sorting).
fn fixupSources(load: *WsLoad, graph: *resolve.ResolveGraph) WsError!void {
    // In-place normalization of arena-owned (genuinely mutable) memory:
    // the `[]const` on node/ref slices is a read-default, not an
    // immutability guarantee.
    const nodes: []resolve.ResolvedNode = @constCast(graph.nodes);
    for (nodes) |*n| {
        if (isPathNode(load, n.name, n.version)) n.source = .{ .path = "" };
        const deps: []resolve.ResolvedRef = @constCast(n.deps);
        for (deps) |*r| {
            if (isPathNode(load, r.name, r.version)) r.source = .{ .path = "" };
        }
        // Edge dedup (cargo's `Graph<PackageId, HashSet<Dependency>>` +
        // unique-neighbor rendering: a member's normal+dev edges to the
        // same crate resolve to ONE node and render ONE lock edge, while
        // the core records one ref per pending edge). Stable: first
        // occurrence wins (the writer sorts edges anyway).
        var w: usize = 0;
        for (deps, 0..) |*r, i| {
            var dup = false;
            for (deps[0..w]) |*k| {
                if (std.mem.eql(u8, k.name, r.name) and k.version.eql(r.version) and sourceEql(k.source, r.source)) {
                    dup = true;
                    break;
                }
            }
            if (!dup) {
                deps[w] = deps[i];
                w += 1;
            }
        }
        n.deps = deps[0..w];
    }
    // Node merge: the core activates workspace members once as roots
    // (path source) and again via edges (registry placeholder), yielding
    // two nodes for one package. Post-fixup both carry the true source, so
    // same-(name, version, source) nodes merge with unioned dep sets
    // (cargo has one node per PackageId). Distinct versions and distinct
    // real sources never share a key and are untouched. Union arrays grow
    // in the graph arena.
    const galloc = graph.arena.allocator();
    var w: usize = 0;
    for (nodes, 0..) |*n, i| {
        var target: ?*resolve.ResolvedNode = null;
        for (nodes[0..w]) |*k| {
            if (std.mem.eql(u8, k.name, n.name) and k.version.eql(n.version) and sourceEql(k.source, n.source)) {
                target = k;
                break;
            }
        }
        if (target) |t| {
            t.deps = unionDeps(galloc, t.deps, n.deps) catch return WsError.OutOfMemory;
        } else {
            nodes[w] = nodes[i];
            w += 1;
        }
    }
    graph.nodes = nodes[0..w];
}

fn unionDeps(alloc: std.mem.Allocator, a: []const resolve.ResolvedRef, b: []const resolve.ResolvedRef) WsError![]resolve.ResolvedRef {
    var out: std.ArrayList(resolve.ResolvedRef) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, a);
    for (b) |*r| {
        var found = false;
        for (out.items) |*k| {
            if (std.mem.eql(u8, k.name, r.name) and k.version.eql(r.version) and sourceEql(k.source, r.source)) {
                found = true;
                break;
            }
        }
        if (!found) try out.append(alloc, r.*);
    }
    return out.toOwnedSlice(alloc) catch return WsError.OutOfMemory;
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
            .git => |y| return std.mem.eql(u8, x.url, y.url),
            else => return false,
        },
    }
}

fn isPathNode(load: *WsLoad, name: []const u8, version: semver.Version) bool {
    for (load.reg.path_nodes.items) |*pn| {
        if (std.mem.eql(u8, pn.name, name) and pn.version.eql(version)) return true;
    }
    return false;
}

/// Checksum map for `writeLock` (`checksumKey` convention): registry nodes
/// look up their index entry's `cksum`; path nodes and cksum-less entries
/// are absent (cargo omits the line). gpa-owned map (caller deinits keys;
/// values borrow index entries alive in the registry).
fn buildChecksums(gpa: std.mem.Allocator, load: *WsLoad, graph: *const resolve.ResolveGraph) WsError!std.StringHashMap(?[]const u8) {
    var map = std.StringHashMap(?[]const u8).init(gpa);
    errdefer {
        var it = map.iterator();
        while (it.next()) |kv| gpa.free(kv.key_ptr.*);
        map.deinit();
    }
    const srcline = sources.SourceId.lockSourceLine(gpa, .{ .registry = index_url }, .v4) catch return WsError.OutOfMemory;
    defer gpa.free(srcline.?);
    for (graph.nodes) |*n| {
        if (n.source != .registry) continue;
        const ver = try renderVersion(gpa, n.version);
        defer gpa.free(ver);
        const key = lock.checksumKey(gpa, n.name, ver, srcline.?) catch return WsError.OutOfMemory;
        errdefer gpa.free(key);
        var cksum: ?[]const u8 = null;
        for (load.reg.entries.items) |*e| {
            if (std.mem.eql(u8, e.candidate.name, n.name) and e.candidate.version.eql(n.version)) {
                cksum = e.candidate.checksum;
                break;
            }
        }
        // Absent entry (should not happen: the version was selected FROM
        // an entry) or cksum-less entry (pre-2014 metadata) both omit.
        if (cksum == null) {
            gpa.free(key);
            continue;
        }
        try map.put(key, cksum);
    }
    return map;
}

/// Unused `[patch]` entries for `writeLockFull` (`[[patch.unused]]`,
/// cargo order = declaration order here = sorted manifest order, which is
/// deterministic; single-source fixtures make this exact). Only path
/// patches can be unused in the oracle (registry-form patches are
/// rejected at load).
fn unusedPatches(gpa: std.mem.Allocator, load: *WsLoad) WsError![]lock.PatchUnusedEntry {
    var out: std.ArrayList(lock.PatchUnusedEntry) = .empty;
    for (load.reg.patch_nodes.items) |*pn| {
        if (pn.used) continue;
        try out.append(gpa, .{ .name = pn.name, .version = pn.version, .source = .{ .path = "" } });
    }
    return out.toOwnedSlice(gpa) catch return WsError.OutOfMemory;
}

/// Recursive fixture copy (repo -> tmp): directories always traversed
/// EXCEPT `target/` (build artifacts, huge) and dot-dirs; files copied
/// iff whitelisted (`Cargo.toml` + sources + struck JSON goldens). Lock
/// files are NEVER copied (the test materializes `Cargo.lock` from the
/// golden explicitly, so cargo always re-resolves rather than
/// minimal-updating a stale copy). Dotfiles are skipped (no `.oracle.*`
/// droppings or `.git` ever leak in).
fn copyFixture(gpa: std.mem.Allocator, io: std.Io, src_rel: []const u8, dst_abs: []const u8) WsError!void {
    const cwd = std.Io.Dir.cwd();
    var src = cwd.openDir(io, src_rel, .{ .iterate = true }) catch {
        return wsFail("cannot open fixture `{s}`", .{src_rel});
    };
    defer src.close(io);
    var dst = cwd.createDirPathOpen(io, dst_abs, .{}) catch return WsError.Io;
    defer dst.close(io);
    var it = src.iterate();
    while (true) {
        const entry = it.next(io) catch return WsError.Io;
        const ent = entry orelse break;
        if (ent.name.len > 0 and ent.name[0] == '.') continue;
        if (ent.kind == .directory) {
            if (std.mem.eql(u8, ent.name, "target")) continue;
            const sub_src = std.fmt.allocPrint(gpa, "{s}/{s}", .{ src_rel, ent.name }) catch return WsError.OutOfMemory;
            defer gpa.free(sub_src);
            const sub_dst = std.fmt.allocPrint(gpa, "{s}/{s}", .{ dst_abs, ent.name }) catch return WsError.OutOfMemory;
            defer gpa.free(sub_dst);
            try copyFixture(gpa, io, sub_src, sub_dst);
        } else {
            if (!copyableExt(ent.name)) continue;
            const src_file = std.fmt.allocPrint(gpa, "{s}/{s}", .{ src_rel, ent.name }) catch return WsError.OutOfMemory;
            defer gpa.free(src_file);
            const bytes = cwd.readFileAlloc(io, src_file, gpa, .limited(4 << 20)) catch return WsError.Io;
            defer gpa.free(bytes);
            var f = dst.createFile(io, ent.name, .{}) catch return WsError.Io;
            defer f.close(io);
            f.writeStreamingAll(io, bytes) catch return WsError.Io;
        }
    }
}

fn copyableExt(name: []const u8) bool {
    const exts = [_][]const u8{ ".toml", ".rs", ".json" };
    for (exts) |e| {
        if (std.mem.endsWith(u8, name, e)) return true;
    }
    return false;
}

/// Materialize `Cargo.lock` in `dir` from `src_path` bytes (repo golden or
/// cargo-fresh path -- always an explicit copy, never a repo write).
fn writeTmpLock(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, src_path: []const u8) WsError!void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, src_path, gpa, .limited(8 << 20)) catch return WsError.Io;
    defer gpa.free(bytes);
    const dst_path = std.fmt.allocPrint(gpa, "{s}/Cargo.lock", .{dir}) catch return WsError.OutOfMemory;
    defer gpa.free(dst_path);
    var f = std.Io.Dir.cwd().createFile(io, dst_path, .{}) catch return WsError.Io;
    defer f.close(io);
    f.writeStreamingAll(io, bytes) catch return WsError.Io;
}

// =====================================================================
// Tests. Cargo-spawning tests skip unless RIME_CARGO_ORACLE=1 with cargo
// on PATH; everything else runs hermetically in every `zig build test`.

fn requireOracle() error{SkipZigTest}!void {
    if (!oracleEnabled()) return error.SkipZigTest;
    // Live mode needs a spawning cargo; prebuilt mode trusts the
    // shell-produced artifacts (RIME_ORACLE_PREBUILT) instead.
    if (prebuiltDir() == null and !cargoAvailable()) return error.SkipZigTest;
}

/// Cargo.lock bytes for a case: live cargo-generate-lockfile (spawn) or,
/// under RIME_ORACLE_PREBUILT, the shell-produced real-cargo output at
/// prebuilt/case-name/Cargo.lock (copied into dir so downstream paths
/// stay identical).
fn cargoLockFor(gpa: std.mem.Allocator, io: std.Io, case_rel: []const u8, dir: []const u8, offline: bool) OracleError![]u8 {
    if (prebuiltDir()) |pb| {
        const src_path = std.fmt.allocPrint(gpa, "{s}/{s}/Cargo.lock", .{ pb, case_rel }) catch return OracleError.OutOfMemory;
        defer gpa.free(src_path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, src_path, gpa, .limited(8 << 20)) catch |e| switch (e) {
            error.OutOfMemory => return OracleError.OutOfMemory,
            else => return OracleError.Io,
        };
        errdefer gpa.free(bytes);
        const dst_path = std.fmt.allocPrint(gpa, "{s}/Cargo.lock", .{dir}) catch return OracleError.OutOfMemory;
        defer gpa.free(dst_path);
        var f = std.Io.Dir.cwd().createFile(io, dst_path, .{}) catch return OracleError.Io;
        defer f.close(io);
        f.writeStreamingAll(io, bytes) catch return OracleError.Io;
        return bytes;
    }
    return generateLockfile(gpa, io, dir, offline);
}

fn freeStrList(gpa: std.mem.Allocator, list: [][]const u8) void {
    for (list) |s| gpa.free(s);
    gpa.free(list);
}

/// Path-only fixture flow: copy -> cargo generate-lockfile --offline ->
/// rime resolve (previous = cargo's lock) -> graph compare + lock
/// byte-compare. No network, no index data: versions are path-fixed.
fn checkPathFixture(fixture_rel: []const u8) !void {
    try requireOracle();
    const gpa = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);
    try copyFixture(gpa, io, fixture_rel, dir);
    const cargo_lock = try cargoLockFor(gpa, io, fixture_rel, dir, true);
    defer gpa.free(cargo_lock);
    var load = try loadWorkspace(gpa, io, dir, cargo_lock);
    defer load.deinit();
    var graph = try runResolve(gpa, &load);
    defer graph.deinit();
    try expectSameGraph(&graph, cargo_lock);
    var cks = try buildChecksums(gpa, &load, &graph);
    defer {
        var it = cks.iterator();
        while (it.next()) |kv| gpa.free(kv.key_ptr.*);
        cks.deinit();
    }
    const rime_lock = try lock.writeLock(gpa, &graph, &cks, .v4);
    defer gpa.free(rime_lock);
    const cargo_path = try std.fmt.allocPrint(gpa, "{s}/Cargo.lock", .{dir});
    defer gpa.free(cargo_path);
    try expectSameLockfile(rime_lock, cargo_path, io);
}

test "oracle diamond matches cargo" {
    try checkPathFixture("testdata/cargo/resolve/diamond");
}

test "oracle offline-ok matches cargo" {
    try checkPathFixture("testdata/cargo/resolve/offline-ok");
}

test "oracle renamed-deps matches cargo" {
    // Case 15 end-to-end vs real cargo: the `old = { package = "real" }`
    // edge resolves, locks, and renders under the REAL name `real`.
    try checkPathFixture("testdata/cargo/resolve/renamed-deps");
}

test "oracle workspace-inherit matches cargo" {
    // Case 16 end-to-end: `version.workspace`/`edition.workspace` members
    // plus `mylib.workspace = true` dep inheritance.
    try checkPathFixture("testdata/cargo/resolve/workspace-inherit");
}

test "oracle patch-table matches cargo" {
    // Case 17 end-to-end: `[patch.crates-io]` path patch for `log` wins
    // over the registry, the unused patch lands in `[[patch.unused]]`
    // (cargo order), and the unused-patch warning condition holds. Fresh
    // resolve (no previous lock): the patch is the only `log` candidate,
    // so no index data is needed and --offline suffices.
    try requireOracle();
    const gpa = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);
    try copyFixture(gpa, io, "testdata/cargo/resolve/patch-table", dir);
    const cargo_lock = try cargoLockFor(gpa, io, "testdata/cargo/resolve/patch-table", dir, true);
    defer gpa.free(cargo_lock);
    var load = try loadWorkspace(gpa, io, dir, null);
    defer load.deinit();
    var graph = try runResolve(gpa, &load);
    defer graph.deinit();
    try expectSameGraph(&graph, cargo_lock);
    var cks = try buildChecksums(gpa, &load, &graph);
    defer {
        var it = cks.iterator();
        while (it.next()) |kv| gpa.free(kv.key_ptr.*);
        cks.deinit();
    }
    const unused = try unusedPatches(gpa, &load);
    defer gpa.free(unused);
    // The warning condition: exactly the unused patch is unused.
    try std.testing.expectEqual(@as(usize, 1), unused.len);
    try std.testing.expectEqualStrings("unused-crate", unused[0].name);
    try std.testing.expect(unused[0].version.eql(try semver.Version.parse("9.9.9")));
    const rime_lock = try lock.writeLockFull(gpa, &graph, &cks, .v4, unused, &.{});
    defer gpa.free(rime_lock);
    const cargo_path = try std.fmt.allocPrint(gpa, "{s}/Cargo.lock", .{dir});
    defer gpa.free(cargo_path);
    try expectSameLockfile(rime_lock, cargo_path, io);
}

const ValidationProject = struct {
    name: []const u8,
    lock_golden: []const u8, // golden filename inside the project dir
};

const validation_projects = [_]ValidationProject{
    .{ .name = "basic-workspace", .lock_golden = "golden.Cargo.lock" },
    .{ .name = "feature-matrix", .lock_golden = "golden.Cargo.lock" },
    .{ .name = "full-manifest", .lock_golden = "golden.Cargo.lock" },
    .{ .name = "lockfile-golden", .lock_golden = "Cargo.lock" },
};

test "oracle validation projects match committed cargo goldens" {
    // Per project: (a) copy to tmp (NEVER resolve inside the repo);
    // (b) materialize Cargo.lock from the committed golden;
    // (c) real `cargo generate-lockfile --offline` must reproduce the
    // golden byte-for-byte (offline first; one online retry for a cold
    // cache, then bytes must still equal the golden or Mismatch);
    // (d) rime resolves the SAME copied manifests (previous = golden,
    // keep-everything) and must match the golden graph (expectSameGraph),
    // the metadata package set, and every golden.tree*.txt package set;
    // (e) rime's writeLock(.v4) must byte-equal the golden file.
    // On ANY mismatch: project name + both sets/diff, then Mismatch (fail
    // loudly, fail per-project). Goldens are cargo-committed (never
    // rime-generated); this harness only READS them.
    try requireOracle();
    const gpa = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    for (validation_projects) |proj| {
        std.debug.print("oracle: checking validation/{s}\n", .{proj.name});
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(dir);
        const src_rel = try std.fmt.allocPrint(gpa, "validation/{s}", .{proj.name});
        defer gpa.free(src_rel);
        try copyFixture(gpa, io, src_rel, dir);
        const golden_rel = try std.fmt.allocPrint(gpa, "validation/{s}/{s}", .{ proj.name, proj.lock_golden });
        defer gpa.free(golden_rel);
        try writeTmpLock(gpa, io, dir, golden_rel);
        const golden = std.Io.Dir.cwd().readFileAlloc(io, golden_rel, gpa, .limited(8 << 20)) catch return OracleError.Io;
        defer gpa.free(golden);
        // Live mode: offline first, one online retry for a cold cache
        // (bytes must STILL equal the golden -- conservative update keeps
        // every version -- or this is real drift). Prebuilt mode: the
        // shell-produced real-cargo bytes (verified against the golden by
        // the same comparison below).
        const cargo_lock = if (prebuiltDir() != null)
            try cargoLockFor(gpa, io, src_rel, dir, true)
        else blk: {
            break :blk generateLockfile(gpa, io, dir, true) catch |e| {
                if (e != OracleError.CargoFailed) return e;
                std.debug.print("oracle: {s}: offline run failed, retrying online\n", .{proj.name});
                break :blk try generateLockfile(gpa, io, dir, false);
            };
        };
        defer gpa.free(cargo_lock);
        if (!std.mem.eql(u8, cargo_lock, golden)) {
            std.debug.print("oracle: {s}: cargo no longer reproduces its committed golden\n", .{proj.name});
            printLockDiff(golden, cargo_lock);
            return OracleError.Mismatch;
        }
        var load = try loadWorkspace(gpa, io, dir, golden);
        defer load.deinit();
        var graph = try runResolve(gpa, &load);
        defer graph.deinit();
        // (d) graph vs golden lock.
        expectSameGraph(&graph, golden) catch |e| {
            std.debug.print("oracle: {s}: graph differs from golden\n", .{proj.name});
            return e;
        };
        // (d) metadata package set vs graph set.
        const meta_rel = try std.fmt.allocPrint(gpa, "validation/{s}/golden.metadata.json", .{proj.name});
        defer gpa.free(meta_rel);
        const meta_pkgs = try metadataFilePkgs(gpa, io, meta_rel);
        defer freeStrList(gpa, meta_pkgs);
        const graph_pkgs = try graphNameVersions(gpa, &graph);
        defer freeStrList(gpa, graph_pkgs);
        if (!setsEqual(meta_pkgs, graph_pkgs)) {
            std.debug.print("oracle: {s}: metadata set differs from graph\n", .{proj.name});
            return OracleError.Mismatch;
        }
        // (d) every golden.tree*.txt package set vs graph set.
        const tree_names = [_][]const u8{ "golden.tree.txt", "golden.tree-features.txt", "golden.tree-all-features.txt" };
        for (tree_names, 0..) |tname, ti| {
            const tree_rel = try std.fmt.allocPrint(gpa, "validation/{s}/{s}", .{ proj.name, tname });
            defer gpa.free(tree_rel);
            const text = std.Io.Dir.cwd().readFileAlloc(io, tree_rel, gpa, .limited(8 << 20)) catch |e| switch (e) {
                error.OutOfMemory => return OracleError.OutOfMemory,
                else => {
                    // Only golden.tree.txt is required everywhere; the
                    // -features variants exist only for feature-matrix.
                    if (ti == 0) return OracleError.Io;
                    continue;
                },
            };
            defer gpa.free(text);
            const tree_pkgs = try treeFilePkgs(gpa, text);
            defer freeStrList(gpa, tree_pkgs);
            if (!setsEqual(tree_pkgs, graph_pkgs)) {
                std.debug.print("oracle: {s}: {s} set differs from graph\n", .{ proj.name, tname });
                return OracleError.Mismatch;
            }
        }
        // (e) byte-stable lock write vs the same golden file.
        var cks = try buildChecksums(gpa, &load, &graph);
        defer {
            var it = cks.iterator();
            while (it.next()) |kv| gpa.free(kv.key_ptr.*);
            cks.deinit();
        }
        const unused = try unusedPatches(gpa, &load);
        defer gpa.free(unused);
        const rime_lock = try lock.writeLockFull(gpa, &graph, &cks, .v4, unused, &.{});
        defer gpa.free(rime_lock);
        const cargo_path = try std.fmt.allocPrint(gpa, "{s}/Cargo.lock", .{dir});
        defer gpa.free(cargo_path);
        expectSameLockfile(rime_lock, cargo_path, io) catch |e| {
            std.debug.print("oracle: {s}: lock bytes differ from golden\n", .{proj.name});
            return e;
        };
    }
}

test "discoverValidationProjects lists the landed corpus" {
    // Rime-only (no cargo): asserts the sorted landed project names. Update
    // in the same commit whenever a project is added or renamed.
    const io = std.Io.Threaded.global_single_threaded.io();
    const projects = try discoverValidationProjects(std.testing.allocator, io);
    defer freeStrList(std.testing.allocator, projects);
    const want = [_][]const u8{ "basic-workspace", "feature-matrix", "full-manifest", "lockfile-golden" };
    try std.testing.expectEqual(want.len, projects.len);
    for (want, projects) |w, p| try std.testing.expectEqualStrings(w, p);
}

test "expectSameGraph accepts equal sets and rejects drift" {
    const gpa = std.testing.allocator;
    const path: sources.SourceId = .{ .path = "" };
    const v010 = try semver.Version.parse("0.1.0");
    const nodes = [_]resolve.ResolvedNode{
        .{ .name = "app", .version = v010, .source = path, .deps = &.{} },
    };
    var graph = resolve.ResolveGraph{ .arena = std.heap.ArenaAllocator.init(gpa), .nodes = &nodes };
    defer graph.deinit();
    const same = "version = 4\n[[package]]\nname = \"app\"\nversion = \"0.1.0\"\n";
    try expectSameGraph(&graph, same);
    const drifted = "version = 4\n[[package]]\nname = \"app\"\nversion = \"0.2.0\"\n";
    try std.testing.expectError(OracleError.Mismatch, expectSameGraph(&graph, drifted));
    try std.testing.expectError(OracleError.Mismatch, expectSameGraph(&graph, "not toml [[[["));
}

test "expectSameLockfile compares bytes with a diff" {
    const gpa = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);
    const want = "version = 4\n[[package]]\nname = \"a\"\nversion = \"0.1.0\"\n";
    const dst_path = try std.fmt.allocPrint(gpa, "{s}/Cargo.lock", .{dir});
    defer gpa.free(dst_path);
    var f = try std.Io.Dir.cwd().createFile(io, dst_path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, want);
    try expectSameLockfile(want, dst_path, io);
    try std.testing.expectError(OracleError.Mismatch, expectSameLockfile("version = 4\n", dst_path, io));
    try std.testing.expectError(OracleError.Io, expectSameLockfile(want, "/nonexistent-dir-xyz/Cargo.lock", io));
}

test "treeFilePkgs extracts the package set tolerantly" {
    const gpa = std.testing.allocator;
    const text =
        "feature-matrix v0.1.0 (@VALIDATION_ROOT@/feature-matrix)\n" ++
        "├── anyhow v1.0.104\n" ++
        "anyhow feature \"default\"\n" ++
        "│   └── libc v0.2.190\n" ++
        "[dev-dependencies]\n" ++
        "└── serde_json v1.0.151 (*)\n";
    const pkgs = try treeFilePkgs(gpa, text);
    defer freeStrList(gpa, pkgs);
    try std.testing.expectEqual(@as(usize, 4), pkgs.len);
    try std.testing.expectEqualStrings("anyhow 1.0.104", pkgs[0]);
    try std.testing.expectEqualStrings("feature-matrix 0.1.0", pkgs[1]);
    try std.testing.expectEqualStrings("libc 0.2.190", pkgs[2]);
    try std.testing.expectEqualStrings("serde_json 1.0.151", pkgs[3]);
}

test "indexRelPath follows the sparse layout" {
    var buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings("1/a", indexRelPath("a", &buf));
    try std.testing.expectEqualStrings("2/ab", indexRelPath("ab", &buf));
    try std.testing.expectEqualStrings("3/x/xyz", indexRelPath("xyz", &buf));
    try std.testing.expectEqualStrings("se/rd/serde", indexRelPath("serde", &buf));
}

test "versWanted matches exact rendered versions" {
    const line = "{\"name\":\"serde\",\"vers\":\"1.0.229\",\"deps\":[]}";
    const wanted = [_][]const u8{ "1.0.200", "1.0.229" };
    try std.testing.expect(versWanted(line, &wanted));
    const other = [_][]const u8{"1.0.200"};
    try std.testing.expect(!versWanted(line, &other));
    try std.testing.expect(!versWanted("garbage", &wanted));
}

test "manifestEdge rejects alternate-registry deps loudly" {
    // `registry = "…"` must never resolve silently as default crates.io:
    // the oracle only serves crates.io + path sources, so the edge fails
    // with a loud Mismatch (same policy as the index-side non-default
    // registry check in `projectCrate`).
    const d = manifest.DepRef{
        .key = "alt-dep",
        .package = null,
        .kind = .{ .version_req = "^1" },
        .version = "^1",
        .registry_url = "https://example.com/index",
        .optional = false,
        .default_features = true,
        .features = &.{},
        .target = null,
        .dep_kind = .normal,
    };
    try std.testing.expectError(WsError.Mismatch, manifestEdge(d));
}

test "unused patch warning matches cargo verbatim" {
    // First line asserted against real cargo stderr (patch-table probe):
    // `warning: patch ... was not used` + `help: Check that the patched…`.
    try std.testing.expect(std.mem.startsWith(u8, manifest.unused_patch_warning, "Check that the patched package version and available features are compatible\n"));
    try std.testing.expect(std.mem.indexOf(u8, manifest.unused_patch_warning, "run `cargo update` to use the new\nversion.") != null);
    try std.testing.expect(std.mem.endsWith(u8, manifest.unused_patch_warning, "optional dependency that is not enabled."));
}


// =====================================================================
// Feature-driven optional narrowing (the Task-5 two-pass loop's second
// half): pass 1 resolves with every optional edge enabled (superset);
// unifyV1 computes the enabled feature/dep sets from real feature maps
// (member manifests + selected index entries); pruneOptional drops
// disabled-optional subtrees. Versions never change by narrowing (fewer
// constraints), exactly as `features.rs` documents ("second pass can only
// narrow").

// Parse one feature-table value with manifest/index key -> real-name
// mapping for dep heads (members: `old/feat` means the REAL crate;
// index: rename split). Unknown heads pass through (harmless: enabling a
// nonexistent dep is a no-op in prune, and validated requests fail loudly
// in unify).
fn parseFeatureValue(
    key_to_real: *const std.StringHashMap([]const u8),
    text: []const u8,
) features.FeatureValue {
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

// Per-package feature source: raw [features] defs + optional dep
// real-names + key->real map, from either a member/path manifest ext or a
// selected index entry. The map struct lives in the registry arena (freed
// whole with it); all strings borrow loader-owned memory.
const FeatSrc = struct {
    defs: []const index.FeatureDef,
    optional_reals: []const []const u8,
    key_to_real: *const std.StringHashMap([]const u8),
};

// Unioned per-name accumulator (selected versions may differ; union is the
// safe merge -- rule application is idempotent by fixpoint).
const MapAcc = struct {
    default_vals: std.ArrayList([]const u8),
    rules: std.ArrayList(features.FeatureRule),
    optional_set: std.ArrayList([]const u8),
    suppress: std.ArrayList([]const u8), // dep:-targets + explicit rule names
};

fn containsStr(list: []const []const u8, s: []const u8) bool {
    for (list) |e| {
        if (std.mem.eql(u8, e, s)) return true;
    }
    return false;
}

// Build v1 feature maps for every package in the pass-1 graph. Everything
// lives in the registry arena or borrows loader-owned memory (no per-map
// deinit; freed whole with the registry).
fn buildMaps(load: *WsLoad, graph: *const resolve.ResolveGraph) WsError!std.StringHashMap(features.FeatureMap) {
    const alloc = load.reg.arena.allocator();
    var accs = std.StringHashMap(MapAcc).init(alloc);
    for (graph.nodes) |*n| {
        const src = try featSrcFor(load, n.name, n.version);
        const gop = accs.getOrPut(n.name) catch return WsError.OutOfMemory;
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .default_vals = .empty,
                .rules = .empty,
                .optional_set = .empty,
                .suppress = .empty,
            };
        }
        var acc = gop.value_ptr;
        for (src.defs) |fd| {
            if (std.mem.eql(u8, fd.name, "default")) {
                for (fd.values) |v| {
                    if (v.len == 0) continue;
                    if (!containsStr(acc.default_vals.items, v)) try acc.default_vals.append(alloc, v);
                }
                continue;
            }
            // Explicit rule names suppress same-named implicit features.
            if (!containsStr(acc.suppress.items, fd.name)) try acc.suppress.append(alloc, fd.name);
            var vals: std.ArrayList(features.FeatureValue) = .empty;
            for (fd.values) |v| {
                if (v.len == 0) continue;
                try vals.append(alloc, parseFeatureValue(src.key_to_real, v));
                if (vals.items[vals.items.len - 1] == .dep_named) {
                    const dn = vals.items[vals.items.len - 1].dep_named;
                    if (!containsStr(acc.suppress.items, dn)) try acc.suppress.append(alloc, dn);
                }
            }
            try acc.rules.append(alloc, .{ .feature = fd.name, .values = try vals.toOwnedSlice(alloc) });
        }
        for (src.optional_reals) |o| {
            if (!containsStr(acc.optional_set.items, o)) try acc.optional_set.append(alloc, o);
        }
    }
    var maps = std.StringHashMap(features.FeatureMap).init(alloc);
    var ait = accs.iterator();
    while (ait.next()) |kv| {
        var opt: std.ArrayList([]const u8) = .empty;
        for (kv.value_ptr.optional_set.items) |o| {
            if (containsStr(kv.value_ptr.suppress.items, o)) continue;
            try opt.append(alloc, o);
        }
        try maps.put(kv.key_ptr.*, .{
            .default = try kv.value_ptr.default_vals.toOwnedSlice(alloc),
            .optional_deps = try opt.toOwnedSlice(alloc),
            .rules = try kv.value_ptr.rules.toOwnedSlice(alloc),
        });
    }
    return maps;
}

// Locate the feature source for one resolved (name, version): path nodes
// (member or not) read their manifest ext; registry nodes read the
// selected index entry. Missing backing data is a loud oracle bug (every
// resolved node comes from known data).
fn featSrcFor(load: *WsLoad, name: []const u8, version: semver.Version) WsError!FeatSrc {
    const alloc = load.reg.arena.allocator();
    for (load.reg.path_nodes.items) |*pn| {
        if (!std.mem.eql(u8, pn.name, name) or !pn.version.eql(version)) continue;
        const mapp = alloc.create(std.StringHashMap([]const u8)) catch return WsError.OutOfMemory;
        mapp.* = std.StringHashMap([]const u8).init(alloc);
        const lists = [_][]manifest.DepRef{ pn.ext.renamed, pn.ext.target_deps };
        for (lists) |list| {
            for (list) |d| try mapp.put(d.key, d.realName());
        }
        var optionals: std.ArrayList([]const u8) = .empty;
        for (lists) |list| {
            for (list) |d| {
                if (!d.optional) continue;
                if (!containsStr(optionals.items, d.realName())) try optionals.append(alloc, d.realName());
            }
        }
        return .{
            .defs = pn.ext.features,
            .optional_reals = try optionals.toOwnedSlice(alloc),
            .key_to_real = mapp,
        };
    }
    for (load.reg.entries.items) |*e| {
        if (!std.mem.eql(u8, e.candidate.name, name) or !e.candidate.version.eql(version)) continue;
        const mapp = alloc.create(std.StringHashMap([]const u8)) catch return WsError.OutOfMemory;
        mapp.* = std.StringHashMap([]const u8).init(alloc);
        for (e.deps) |d| try mapp.put(d.name, d.realName());
        var optionals: std.ArrayList([]const u8) = .empty;
        for (e.deps) |d| {
            if (!d.optional) continue;
            if (!containsStr(optionals.items, d.realName())) try optionals.append(alloc, d.realName());
        }
        var defs: std.ArrayList(index.FeatureDef) = .empty;
        for (e.features) |fd| try defs.append(alloc, fd);
        return .{
            .defs = try defs.toOwnedSlice(alloc),
            .optional_reals = try optionals.toOwnedSlice(alloc),
            .key_to_real = mapp,
        };
    }
    return wsFail("no feature source for resolved `{s}` (oracle bug)", .{name});
}

// Per-package requested features from the pass-1 edges: union of incoming
// edge `features` + OR of incoming `uses_default`. Members resolve with
// all features (CliFeatures::new_all(true)); everyone else with exactly
// this. Non-member dev edges are excluded (they do not exist in pass 1,
// mirroring the projection).
const EdgeWants = struct {
    feats: std.ArrayList([]const u8),
    uses_default: bool,
};

fn buildRootReqs(
    gpa: std.mem.Allocator,
    load: *WsLoad,
    graph: *const resolve.ResolveGraph,
) WsError![]features.RootReq {
    const alloc = load.reg.arena.allocator();
    var wants = std.StringHashMap(EdgeWants).init(alloc);
    for (graph.nodes) |*pn| {
        const is_member = isMemberNode(load, pn.name, pn.version);
        const data = try parentDepData(load, pn.name, pn.version);
        for (data) |d| {
            if (!is_member and (d.dep_kind == .dev or (d.is_index and d.index_kind == .dev))) continue;
            const gop = wants.getOrPut(d.real) catch return WsError.OutOfMemory;
            if (!gop.found_existing) gop.value_ptr.* = .{ .feats = .empty, .uses_default = false };
            for (d.feats) |f| {
                if (f.len == 0) continue;
                try gop.value_ptr.feats.append(alloc, f);
            }
            gop.value_ptr.uses_default = gop.value_ptr.uses_default or d.uses_default;
        }
    }
    // Distinct package names in graph order.
    var names: std.ArrayList([]const u8) = .empty;
    for (graph.nodes) |*n| {
        if (!containsStr(names.items, n.name)) try names.append(alloc, n.name);
    }
    var reqs: std.ArrayList(features.RootReq) = .empty;
    errdefer reqs.deinit(gpa);
    for (names.items) |nm| {
        if (isMemberName(load, nm)) {
            try reqs.append(gpa, .{ .package = nm, .features = &.{}, .all_features = true, .no_default = false });
            continue;
        }
        const w = wants.get(nm);
        try reqs.append(gpa, .{
            .package = nm,
            .features = if (w) |ww| ww.feats.items else &.{},
            .all_features = false,
            .no_default = if (w) |ww| !ww.uses_default else true,
        });
    }
    return reqs.toOwnedSlice(gpa) catch return WsError.OutOfMemory;
}

// Uniform dep view for edge-want collection: manifest refs and index deps.
const DepDatum = struct {
    real: []const u8,
    feats: []const []const u8,
    uses_default: bool,
    dep_kind: manifest.DepTableKind, // normal for index deps (kind carried separately)
    is_index: bool,
    index_kind: index.DepKind,
};

// All outgoing dep data of one resolved parent (manifest ext or selected
// index entry), in declaration order.
fn parentDepData(load: *WsLoad, name: []const u8, version: semver.Version) WsError![]DepDatum {
    const alloc = load.reg.arena.allocator();
    var out: std.ArrayList(DepDatum) = .empty;
    for (load.reg.path_nodes.items) |*pn| {
        if (!std.mem.eql(u8, pn.name, name) or !pn.version.eql(version)) continue;
        const lists = [_][]manifest.DepRef{ pn.ext.renamed, pn.ext.target_deps };
        for (lists) |list| {
            for (list) |d| {
                try out.append(alloc, .{
                    .real = d.realName(),
                    .feats = d.features,
                    .uses_default = d.default_features,
                    .dep_kind = d.dep_kind,
                    .is_index = false,
                    .index_kind = .normal,
                });
            }
        }
        return out.toOwnedSlice(alloc) catch return WsError.OutOfMemory;
    }
    for (load.reg.entries.items) |*e| {
        if (!std.mem.eql(u8, e.candidate.name, name) or !e.candidate.version.eql(version)) continue;
        for (e.deps) |d| {
            try out.append(alloc, .{
                .real = d.realName(),
                .feats = d.features,
                .uses_default = d.default_features,
                .dep_kind = .normal,
                .is_index = true,
                .index_kind = d.kind,
            });
        }
        return out.toOwnedSlice(alloc) catch return WsError.OutOfMemory;
    }
    return wsFail("no dep data for resolved `{s}` (oracle bug)", .{name});
}

fn isMemberNode(load: *WsLoad, name: []const u8, version: semver.Version) bool {
    for (load.reg.path_nodes.items) |*pn| {
        if (std.mem.eql(u8, pn.name, name) and pn.version.eql(version)) return pn.is_member;
    }
    return false;
}

fn isMemberName(load: *WsLoad, name: []const u8) bool {
    for (load.reg.path_nodes.items) |*pn| {
        if (pn.is_member and std.mem.eql(u8, pn.name, name)) return true;
    }
    return false;
}


// Drop disabled-optional nodes + orphaned subtrees (same contract as
// features.pruneOptional, corrected traversal): an edge P->D survives iff
// D is in unified.enabled_deps[P] (normal edges were pre-recorded there by
// unifyV1). Nodes surviving = reachable from indegree-0 nodes via surviving
// edges, in original graph order. Returned slice is gpa-owned (headers only;
// strings borrow the pass-1 graph); the caller deep-copies. Caller frees.
fn pruneEnabled(
    gpa: std.mem.Allocator,
    graph: *const resolve.ResolveGraph,
    unified: *const features.Unified,
) WsError![]const resolve.ResolvedNode {
    const n = graph.nodes.len;
    var keep = gpa.alloc(bool, n) catch return WsError.OutOfMemory;
    defer gpa.free(keep);
    @memset(keep, false);
    var indeg = gpa.alloc(usize, n) catch return WsError.OutOfMemory;
    defer gpa.free(indeg);
    @memset(indeg, 0);
    for (graph.nodes) |pn| {
        for (pn.deps) |d| {
            if (findNode(graph, d.name, d.version, d.source)) |ci| indeg[ci] += 1;
        }
    }
    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(gpa);
    for (graph.nodes, 0..) |_, i| {
        if (indeg[i] == 0) {
            keep[i] = true;
            stack.append(gpa, i) catch return WsError.OutOfMemory;
        }
    }
    while (stack.items.len > 0) {
        const pi = stack.pop().?;
        const pn = graph.nodes[pi];
        const allowed = unified.enabled_deps.get(pn.name);
        for (pn.deps) |d| {
            if (allowed == null or !allowed.?.contains(d.name)) continue;
            if (findNode(graph, d.name, d.version, d.source)) |ci| {
                if (!keep[ci]) {
                    keep[ci] = true;
                    stack.append(gpa, ci) catch return WsError.OutOfMemory;
                }
            }
        }
    }
    var out: std.ArrayList(resolve.ResolvedNode) = .empty;
    errdefer out.deinit(gpa);
    for (graph.nodes, 0..) |node, i| {
        if (keep[i]) try out.append(gpa, node);
    }
    return out.toOwnedSlice(gpa) catch return WsError.OutOfMemory;
}

fn findNode(graph: *const resolve.ResolveGraph, name: []const u8, version: semver.Version, source: sources.SourceId) ?usize {
    for (graph.nodes, 0..) |cn, ci| {
        if (std.mem.eql(u8, cn.name, name) and cn.version.eql(version) and sourceEql(cn.source, source)) return ci;
    }
    return null;
}
