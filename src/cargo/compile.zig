//! rustc driver execution (M4 Tasks 7–9): spawn rustc with JSON
//! diagnostics, ingest spool outputs into the global store, and round-trip
//! incremental sessions as bounded `kind=incremental` objects.
//!
//! Planning (units, fingerprints, action keys, argv) lives in
//! `driver`/`fingerprint`/`actionkey`/`invoke`; this module only executes:
//! spawn → envelopes → ingest → session save. The pipeline (Task 10) calls,
//! per unit in topo order: `tryIngestCacheHit` (skip spawn on hit) →
//! `materializeSession` (when `profile.incremental`) → `spawnRustc` →
//! `emitEnvelopes` → `ingestUnitOutputs` + `ingestSession`.
//!
//! Ownership: `CompileOutput` owns its byte copies via an arena
//! (`deinit` frees all). Every other input borrows the caller (units,
//! tags, argv, spool dirs) and stays valid exactly as long as the caller.
//! `ingestUnitOutputs`/`ingestSession` allocate only transiently (freed
//! before return); the store owns everything persisted.

const std = @import("std");
const store_mod = @import("store");
const driver_mod = @import("driver.zig");
const invoke_mod = @import("invoke.zig");
const oracle_mod = @import("oracle.zig");
const cli_mod = @import("cli.zig");
const fingerprint_mod = @import("fingerprint.zig");
const toolchain_mod = @import("toolchain.zig");

const Store = store_mod.Store;
const Digest = store_mod.Digest;
const Tag = store_mod.Tag;
const Kind = store_mod.Kind;
const Unit = driver_mod.Unit;
const RustcInvocation = invoke_mod.RustcInvocation;
const Fingerprint = fingerprint_mod.Fingerprint;

// libc process-env mutation (clone.zig precedent: `extern "c"` fns).
// `std.c` exposes `getenv` but no `setenv`/`unsetenv` in 0.16, so they are
// declared here. Used ONLY to apply `RustcInvocation.env_extra` around the
// spawn: `std.process.spawn`'s `environ_map` REPLACES the whole child
// environment, so it cannot carry just the extras without re-snapshotting
// the parent env. setenv-around-spawn preserves the parent env verbatim.
// Single-threaded CLI/test use only (no concurrent spawns with env_extra).
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

// =====================================================================
// Task 7: spawn + JSON message plumbing
// =====================================================================

pub const CompileError = error{ SpawnFailed, TimedOut, RustcFailed, BadMessage, OutOfMemory, Io } || std.mem.Allocator.Error;

/// One parsed rustc JSON diagnostic (`$message_type == "diagnostic"`).
/// `level`/`message` borrow the parsed JSON line (valid for the immediate
/// rendering only); `package`/`target` borrow the caller unit.
pub const Diagnostic = struct {
    level: []const u8, // "error" | "warning" | "note" | "help" (rustc spelling)
    message: []const u8, // rendered message (rustc `message` field)
    package: []const u8, // borrowed from caller unit
    target: []const u8, // borrowed from caller unit
};

pub const CompileOutput = struct {
    arena: std.heap.ArenaAllocator, // owns stdout/stderr copies + parsed lines
    exited: u8,
    stdout: []const u8,
    stderr: []const u8,
    pub fn deinit(self: *CompileOutput) void {
        self.arena.deinit();
    }
};

/// Restores one `env_extra` entry to its pre-spawn state (called via
/// `defer` for every applied entry, so restores run even on spawn error).
const EnvRestore = struct {
    name: [:0]u8, // gpa-owned sentinel key (also freed here)
    old: ?[]u8, // gpa-owned previous value, null = was absent
};

fn restoreEnv(gpa: std.mem.Allocator, restores: *std.ArrayList(EnvRestore)) void {
    for (restores.items) |r| {
        if (r.old) |v| {
            const zv = gpa.dupeZ(u8, v) catch continue;
            defer gpa.free(zv);
            _ = setenv(r.name, zv, 1);
            gpa.free(v);
        } else {
            _ = unsetenv(r.name);
        }
        gpa.free(r.name);
    }
    restores.deinit(gpa);
}

/// Spawns rustc via the shared `oracle.runCapture` drain loop (deviation
/// D-R1: one combined stdout+stderr drain with the 60 s watchdog inherited,
/// no redesigned plumbing). `inv.env_extra` (`RUSTC_BOOTSTRAP=1` for
/// panic=abort units) is applied with setenv around the spawn and restored
/// before return. `argv[0]` is resolved to an absolute path with the
/// `toolchain.resolveBinPath` seam first (Task-1-provided): bare spellings
/// (`"rustc"`, no `/`) fail inside `std.process.spawn`'s own PATH lookup
/// in this environment (surfaces as `SpawnFailed`), while absolute paths
/// spawn cleanly — the probe lane hit this first and left the seam with a
/// pointer to this caller. Returns the output for ANY exit code — nonzero exits are
/// reported by `emitEnvelopes` as `RustcFailed` after the diagnostics are
/// emitted, never here (the caller maps that to exit 101).
pub fn spawnRustc(gpa: std.mem.Allocator, io: std.Io, inv: *const RustcInvocation) CompileError!CompileOutput {
    // Apply env extras first (deferred restore covers every exit below).
    var restores: std.ArrayList(EnvRestore) = .empty;
    defer restoreEnv(gpa, &restores);
    for (inv.env_extra) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse return CompileError.SpawnFailed;
        const zname = gpa.dupeZ(u8, kv[0..eq]) catch return CompileError.OutOfMemory;
        errdefer gpa.free(zname);
        const old: ?[]u8 = if (std.c.getenv(zname)) |z|
            gpa.dupe(u8, std.mem.span(z)) catch return CompileError.OutOfMemory
        else
            null;
        errdefer if (old) |v| gpa.free(v);
        const zvalue = gpa.dupeZ(u8, kv[eq + 1 ..]) catch {
            if (old) |v| gpa.free(v);
            return CompileError.OutOfMemory;
        };
        defer gpa.free(zvalue);
        if (setenv(zname, zvalue, 1) != 0) {
            if (old) |v| gpa.free(v);
            gpa.free(zname);
            return CompileError.SpawnFailed;
        }
        restores.append(gpa, .{ .name = zname, .old = old }) catch {
            // Append failed after a successful setenv: restore this entry
            // now (the deferred sweep covers earlier ones).
            if (old) |v| {
                const zv = gpa.dupeZ(u8, v) catch {
                    gpa.free(v);
                    gpa.free(zname);
                    return CompileError.OutOfMemory;
                };
                defer gpa.free(zv);
                _ = setenv(zname, zv, 1);
                gpa.free(v);
            } else {
                _ = unsetenv(zname);
            }
            gpa.free(zname);
            return CompileError.OutOfMemory;
        };
    }

    if (inv.argv.len == 0) return CompileError.SpawnFailed;
    const resolved0 = try toolchain_mod.resolveBinPath(gpa, io, inv.argv[0]) orelse return CompileError.SpawnFailed;
    defer gpa.free(resolved0);
    const argv = try gpa.alloc([]const u8, inv.argv.len);
    defer gpa.free(argv);
    @memcpy(argv, inv.argv);
    argv[0] = resolved0;

    const res = oracle_mod.runCapture(gpa, io, argv, "") catch |e| switch (e) {
        oracle_mod.RunError.SpawnFailed => return CompileError.SpawnFailed,
        oracle_mod.RunError.TimedOut => return CompileError.TimedOut,
        oracle_mod.RunError.OutOfMemory => return CompileError.OutOfMemory,
    };
    defer gpa.free(res.out);
    defer gpa.free(res.err);

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const aalloc = arena.allocator();
    const stdout = aalloc.dupe(u8, res.out) catch return CompileError.OutOfMemory;
    errdefer aalloc.free(stdout);
    const stderr = aalloc.dupe(u8, res.err) catch return CompileError.OutOfMemory;
    return .{ .arena = arena, .exited = res.exited, .stdout = stdout, .stderr = stderr };
}

/// The rustc JSON diagnostic subset rime reads (`mod.rs:2394` role).
/// Unknown fields are ignored (`.ignore_unknown_fields` — the exact options
/// literal the plan pins; verified against `std.json.ParseOptions`).
const DiagJson = struct {
    @"$message_type": []const u8,
    message: []const u8,
    level: []const u8,
};

/// Filenames payload paired with each `compiler-artifact` envelope (the
/// `artifacts` Interfaces param, verbatim — absolute spool paths at emit
/// time; Task 12 normalizes them in golden compares).
const ArtifactPayload = struct {
    filenames: []const []const u8,
};

fn writeErr(e: anyerror) CompileError {
    return if (e == error.OutOfMemory) CompileError.OutOfMemory else CompileError.Io;
}

fn emitLine(w: *std.Io.Writer, line: []const u8) CompileError!void {
    w.writeAll(line) catch |e| return writeErr(e);
    w.writeAll("\n") catch |e| return writeErr(e);
}

/// Re-emits rustc output as cargo-compatible envelopes (`mod.rs:2394` +
/// `mod.rs:2430` roles: the three envelope reasons). Per `\n`-separated
/// line of stderr (then stdout — rustc diagnostics go to stderr):
/// - JSON with `$message_type == "diagnostic"` → one `compiler-message`
///   envelope (human: `level: message` to `w`; json: the envelope line,
///   then the ORIGINAL rustc JSON line verbatim after it so consumers can
///   pair them — byte-contains, not byte-equal, conformance), and an
///   `error`-level diagnostic flips the success bit.
/// - Non-JSON lines pass through verbatim (human) or are dropped (json),
///   except lines smelling like errors (`error:`) which become a
///   `compiler-message` envelope with `success = false` (rustc prints some
///   pre-JSON failures as plain text; dropping them would hide failures).
/// `w` is stdout in json mode, stderr in human mode (single-writer
/// contract — the caller passes the right stream). After a zero exit with
/// no error diagnostics: emits the `compiler-artifact` envelope (envelope
/// line + filenames payload) and returns true. Nonzero exit: emits the
/// diagnostics first, then returns `RustcFailed` (the caller maps it to
/// exit 101). Zero exit WITH error-level diagnostics (defensive — rustc
/// promises nonzero there): returns false.
/// `BadMessage` is reserved: malformed lines pass through, never error.
pub fn emitEnvelopes(
    gpa: std.mem.Allocator,
    io: std.Io,
    w: *std.Io.Writer,
    unit: *const Unit,
    profile_name: []const u8,
    out: *const CompileOutput,
    artifacts: []const []const u8,
    message_format_json: bool,
) CompileError!bool {
    _ = io;
    var saw_error = false;
    const streams = [_][]const u8{ out.stderr, out.stdout };
    for (streams) |bytes| {
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len == 0) continue;
            const parsed = std.json.parseFromSlice(DiagJson, gpa, line, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
                // Not a JSON diagnostic: pass through (human) or drop
                // (json), except error-smelling lines which must surface.
                if (!message_format_json) {
                    try emitLine(w, line);
                } else if (std.mem.startsWith(u8, line, "error") or std.mem.indexOf(u8, line, "error:") != null) {
                    saw_error = true;
                    const env = cli_mod.JsonEnvelope{
                        .reason = "compiler-message",
                        .package = unit.pkg_name,
                        .target = unit.target_name,
                        .profile = profile_name,
                        .success = false,
                    };
                    env.writeLine(w) catch |e| return writeErr(e);
                    try emitLine(w, line);
                }
                continue;
            };
            defer parsed.deinit();
            if (!std.mem.eql(u8, parsed.value.@"$message_type", "diagnostic")) {
                if (!message_format_json) try emitLine(w, line);
                continue;
            }
            const diag = Diagnostic{
                .level = parsed.value.level,
                .message = parsed.value.message,
                .package = unit.pkg_name,
                .target = unit.target_name,
            };
            if (std.mem.eql(u8, diag.level, "error")) saw_error = true;
            if (!message_format_json) {
                w.print("{s}: {s}\n", .{ diag.level, diag.message }) catch |e| return writeErr(e);
            } else {
                const env = cli_mod.JsonEnvelope{
                    .reason = "compiler-message",
                    .package = diag.package,
                    .target = diag.target,
                    .profile = profile_name,
                    .success = !std.mem.eql(u8, diag.level, "error"),
                };
                env.writeLine(w) catch |e| return writeErr(e);
                try emitLine(w, line);
            }
        }
    }
    if (out.exited != 0) return CompileError.RustcFailed;
    if (saw_error) return false;
    const env = cli_mod.JsonEnvelope{
        .reason = "compiler-artifact",
        .package = unit.pkg_name,
        .target = unit.target_name,
        .profile = profile_name,
        .success = true,
    };
    env.writeLine(w) catch |e| return writeErr(e);
    std.json.Stringify.value(ArtifactPayload{ .filenames = artifacts }, .{}, w) catch |e| return writeErr(e);
    w.writeAll("\n") catch |e| return writeErr(e);
    return true;
}

// =====================================================================
// Task 8: output ingestion (spool → store)
// =====================================================================

/// (Spelling note vs the plan's Interfaces block: the plan writes
/// `TagError` inside the error set; that reads as the store `TagError` set
/// (`UnknownTagKey`/`TagMismatch`/`TagLimit`/`StoreFull` + index `DbError`),
/// unioned here — a bare `error.TagError` name would NOT cover the
/// `tagObject` failures this function propagates.)
pub const IngestError = error{ StoreRead, StoreFull, OutOfMemory, Io } || store_mod.TagError || std.mem.Allocator.Error;

pub const IngestedUnit = struct {
    manifest_digest: ?Digest, // putManifest over the unit's outputs; null = StoreFull, spool-only (no manifest exists)
    action_key: Digest, // the key just recorded
    cache_hit: bool, // true when lookupAction hit and outputs re-materialized
};

/// One file rustc was asked to produce: the Task-10 layout step lists
/// `lib<name>-<meta>.rlib` (+ `.rmeta` when lib-build emits it), bin
/// `<name>-<meta16>`, and dep-info `<target>.d`. Kinds ride along so
/// ingestion tags bytes correctly (dep-info `.d` files as `dep_info`).
pub const ExpectedOutput = struct {
    filename: []const u8,
    kind: Kind,
    mode: u32,
};

/// Manifest kind for a unit's outputs: check-mode units (Task 11) record
/// `.rmeta` (nothing is linked), lib builds `.rlib`, bins `.bin`.
fn manifestKind(unit: *const Unit) Kind {
    if (unit.mode == .check) return .rmeta;
    return switch (unit.kind) {
        .lib => .rlib,
        .bin => .bin,
        else => .other,
    };
}

/// Renders the §10.4 one-line StoreFull diagnostic through the
/// `log: ?*std.Io.Writer` Interfaces param (same field shape as the
/// storage-v2 §10.4 CLI line and `main.zig::renderStoreFull`). Null log =
/// silent (tests). Write failures are swallowed: the rendering must never
/// fail a build that already succeeded.
fn renderStoreFull(store: *Store, log: ?*std.Io.Writer) void {
    const sink = log orelse return;
    const bd = store.lastFull();
    sink.print("rime: store full admitting {d} to {s} (budget {d}, {s} {d}/{d}, reserved {d}, reclaimable {d}): {s}\n", .{
        bd.requested_bytes,
        @tagName(bd.class),
        bd.budget,
        @tagName(bd.class),
        bd.used_class,
        bd.cap_class,
        bd.reserved_class,
        bd.reclaimable_class,
        @tagName(bd.hint),
    }) catch {};
}

/// Ingests one compiled unit's spool outputs into the global store:
/// per-file `putFile` + `tagObject` with the `unitTags()` set, then
/// `putManifest` + `putAction(action_key, manifest)`.
/// Build-driver rule (storage-v2 §10.4): a `StoreFull` on ANY cache write
/// is swallowed — the artifact stays in spool for the caller to use and
/// this returns `.manifest_digest = null` (spool-only; no manifest exists,
/// so a Digest-typed sentinel would lie). The pipeline materializes the
/// view from SPOOL when null, from store otherwise. The breakdown is
/// rendered through `log` (null in tests).
/// A missing non-`.rmeta` file is `Io` (rustc did not produce what it was
/// asked for); a missing `.rmeta` is skipped (pipelining variance across
/// rustc versions emits it inconsistently).
pub fn ingestUnitOutputs(
    gpa: std.mem.Allocator,
    io: std.Io,
    store: *Store,
    unit: *const Unit,
    out_dir: []const u8, // spool unit dir holding rustc outputs
    expected: []const ExpectedOutput, // filenames + kinds rustc was asked to produce
    tags: []const Tag, // unitTags() value (crate/version/toolchain/target/profile/features/project/action)
    action_key: Digest,
    log: ?*std.Io.Writer, // StoreFull one-line rendering sink (null in tests)
) IngestError!IngestedUnit {
    const spoolOnly = IngestedUnit{ .manifest_digest = null, .action_key = action_key, .cache_hit = false };
    var outputs: std.ArrayList(Store.ManifestOutput) = .empty;
    defer outputs.deinit(gpa);
    for (expected) |exp| {
        const full = std.fs.path.join(gpa, &.{ out_dir, exp.filename }) catch return IngestError.OutOfMemory;
        defer gpa.free(full);
        var file = std.Io.Dir.openFileAbsolute(io, full, .{}) catch |e| {
            // Missing .rmeta is pipelining variance (skip); anything else
            // missing means rustc did not produce its contracted outputs.
            if (e == error.FileNotFound and exp.kind == .rmeta) continue;
            if (e == error.OutOfMemory) return IngestError.OutOfMemory;
            return IngestError.Io;
        };
        defer file.close(io);
        const size = file.stat(io) catch |e| {
            if (e == error.OutOfMemory) return IngestError.OutOfMemory;
            return IngestError.Io;
        };
        const digest = store.putFile(io, file, exp.kind) catch |e| {
            if (e == error.StoreFull) {
                renderStoreFull(store, log);
                return spoolOnly;
            }
            if (e == error.OutOfMemory) return IngestError.OutOfMemory;
            return IngestError.StoreRead;
        };
        store.tagObject(io, digest, tags) catch |e| {
            if (e == error.StoreFull) {
                renderStoreFull(store, log);
                return spoolOnly;
            }
            return e;
        };
        outputs.append(gpa, .{ .path = exp.filename, .digest = digest, .size = size.size, .mode = exp.mode }) catch return IngestError.OutOfMemory;
    }
    const manifest_digest = store.putManifest(io, .{ .kind = manifestKind(unit), .outputs = outputs.items }) catch |e| {
        if (e == error.StoreFull) {
            renderStoreFull(store, log);
            return spoolOnly;
        }
        if (e == error.OutOfMemory) return IngestError.OutOfMemory;
        return IngestError.StoreRead;
    };
    // putAction cannot StoreFull (index-backed action write, no admission
    // class); residual failures are store trouble, not caller trouble.
    store.putAction(io, action_key, manifest_digest) catch |e| {
        if (e == error.OutOfMemory) return IngestError.OutOfMemory;
        return IngestError.StoreRead;
    };
    return .{ .manifest_digest = manifest_digest, .action_key = action_key, .cache_hit = false };
}

/// `lookupAction` fast path (called BEFORE spawning): returns the recorded
/// manifest digest on a hit, null on a miss. Every referenced object is
/// verified to still `exist` (storage-v2 §12.1 "verify the winner by
/// digest"); a missing/unreadable manifest or any missing object is a
/// stale miss (null), never an error — the caller just recompiles. Only
/// genuine store trouble surfaces (`StoreRead`).
pub fn tryIngestCacheHit(
    gpa: std.mem.Allocator,
    io: std.Io,
    store: *Store,
    action_key: Digest,
) IngestError!?Digest {
    const entry = store.lookupAction(io, gpa, action_key) catch |e| {
        if (e == error.OutOfMemory) return IngestError.OutOfMemory;
        return IngestError.StoreRead;
    };
    const manifest_digest = (entry orelse return null).manifest;
    var man = store.getManifest(io, gpa, manifest_digest) catch {
        return null;
    };
    defer man.deinit(gpa);
    for (man.outputs) |o| {
        if (!store.exists(io, o.digest)) return null;
    }
    return manifest_digest;
}

// =====================================================================
// Task 9: incremental sessions as global objects
// =====================================================================

pub const SessionError = error{ StoreRead, StoreFull, OutOfMemory, Io } || store_mod.TagError || std.mem.Allocator.Error;

/// Session key: `hash("rime-session-v1" ++ fp.toDigest ++ input_digest)`.
/// The `-C incremental=` dir path itself is EXCLUDED from the action key
/// (it varies per build); the session CONTENT enters the key via
/// `input_digest` instead (the Task-5 normalization rule).
pub fn sessionKey(fp: *const Fingerprint, input_digest: Digest) Digest {
    const fpd = fp.toDigest();
    var buf: [15 + 32 + 32]u8 = undefined;
    @memcpy(buf[0..15], "rime-session-v1");
    @memcpy(buf[15..47], &fpd.bytes);
    @memcpy(buf[47..79], &input_digest.bytes);
    return store_mod.hashBytes(&buf);
}

/// Extra session tags beyond the unit tag set (the `user.*` extension
/// point — bare `session` is NOT in the §11.3 vocabulary and `tagObject`
/// rejects it with `UnknownTagKey`). Every session blob carries
/// `user.session=<keyhex>` (provenance + budget attribution); the session
/// manifest additionally carries `user.session_manifest=<keyhex>` so
/// restore lands EXACTLY on manifests (content blobs never parse as
/// manifests, but the explicit tag removes the sniffing entirely).
fn sessionHex(key: Digest, buf: *[64]u8) []const u8 {
    buf.* = key.toHex();
    return buf[0..64];
}

const max_session_files: usize = 50_000;
const max_session_bytes: u64 = 1 << 30; // 1 GiB

const SessionFileJson = struct {
    path: []const u8,
    digest: []const u8, // raw 64-hex (the store Manifest convention, no b3- prefix)
    size: u64,
    mode: u32,
};

const SessionManifestJson = struct {
    format: u32,
    files: []const SessionFileJson,
};

/// Recursive session-file collector: regular files only (dirs recursed,
/// symlinks/others skipped — sessions are rustc-internal trees). Relpaths
/// are gpa-owned `prefix/name` strings freed by the caller alongside the
/// list backing. Over-cap collection is `OverCap` (the caller maps it to a
/// silent skip — sessions are hints).
const WalkCap = error{ OverCap, OutOfMemory, Io };

/// One collected session file: sess_dir-relative path plus the stat
/// snapshot (named so the collector and its caller share ONE type —
/// anonymous structs written twice are distinct types in Zig).
const SessionEntry = struct {
    rel: []const u8,
    size: u64,
    mode: u32,
};

fn collectSessionFiles(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    prefix: []const u8,
    out: *std.ArrayList(SessionEntry),
    total: *u64,
) WalkCap!void {
    var it = dir.iterate();
    while (it.next(io) catch return WalkCap.Io) |entry| {
        if (out.items.len >= max_session_files) return WalkCap.OverCap;
        const rel = std.fmt.allocPrint(gpa, "{s}/{s}", .{ prefix, entry.name }) catch return WalkCap.OutOfMemory;
        switch (entry.kind) {
            .directory => {
                defer gpa.free(rel);
                var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch return WalkCap.Io;
                defer sub.close(io);
                try collectSessionFiles(gpa, io, sub, rel, out, total);
            },
            .file => {
                const st = dir.statFile(io, entry.name, .{}) catch {
                    gpa.free(rel);
                    return WalkCap.Io;
                };
                total.* += st.size;
                if (total.* > max_session_bytes) {
                    gpa.free(rel);
                    return WalkCap.OverCap;
                }
                out.append(gpa, .{ .rel = rel, .size = st.size, .mode = st.permissions.toMode() }) catch {
                    gpa.free(rel);
                    return WalkCap.OutOfMemory;
                };
            },
            else => gpa.free(rel),
        }
    }
}

/// Saves the post-compile incremental session: each file under `sess_dir`
/// becomes its own `kind=incremental` object (unit tags + `user.session`
/// tag), plus one session-manifest object (JSON `relpath → digest`, itself
/// tagged with the manifest tag) so restore is exact. Storage-v2 §13.2:
/// global objects under the `kind:incremental` soft tag budget, never
/// pushed remote, standard `max_age` retention.
/// Sessions are HINTS: `StoreFull` at any point drops the session silently
/// (the build output is already cached by Task 8); an over-cap session or
/// a missing dir is likewise skipped quietly. A `TagLimit` on either tag
/// write also drops the session silently: identical session bytes across
/// builds (e.g. a flag change that leaves incremental state byte-identical)
/// address the same object under different unit-tag values, and the
/// single-value-per-key rule would otherwise fail a correct build for a
/// mere hint. Other store/file failures are loud.
pub fn ingestSession(
    gpa: std.mem.Allocator,
    io: std.Io,
    store: *Store,
    key: Digest,
    sess_dir: []const u8,
    tags: []const Tag,
) SessionError!void {
    var dir = std.Io.Dir.openDirAbsolute(io, sess_dir, .{ .iterate = true }) catch |e| {
        if (e == error.FileNotFound) return; // nothing ran here: nothing to save
        if (e == error.OutOfMemory) return SessionError.OutOfMemory;
        return SessionError.Io;
    };
    defer dir.close(io);

    var files: std.ArrayList(SessionEntry) = .empty;
    defer {
        for (files.items) |f| gpa.free(f.rel);
        files.deinit(gpa);
    }
    var total: u64 = 0;
    collectSessionFiles(gpa, io, dir, ".", &files, &total) catch |e| switch (e) {
        WalkCap.OverCap => return, // unbounded session: skip quietly (hints only)
        WalkCap.OutOfMemory => return SessionError.OutOfMemory,
        WalkCap.Io => return SessionError.Io,
    };

    var hex_buf: [64]u8 = undefined;
    const hex = sessionHex(key, &hex_buf);
    const blob_tags = gpa.alloc(Tag, tags.len + 1) catch return SessionError.OutOfMemory;
    defer gpa.free(blob_tags);
    @memcpy(blob_tags[0..tags.len], tags);
    blob_tags[tags.len] = .{ .key = "user.session", .value = hex };

    const owned = files.items;
    const dtos = gpa.alloc(SessionFileJson, owned.len) catch return SessionError.OutOfMemory;
    defer gpa.free(dtos);
    // Assigned prefix of `dtos` (hint-drop returns below abandon the whole
    // session, so only the assigned prefix owns digests — freeing all of
    // `dtos` would free unassigned garbage).
    var dto_count: usize = 0;
    defer {
        for (dtos[0..dto_count]) |dto| gpa.free(dto.digest);
    }
    for (owned, dtos) |f, *dto| {
        // Strip the "./" walk prefix: manifest paths are sess_dir-relative.
        const rel = if (std.mem.startsWith(u8, f.rel, "./")) f.rel[2..] else f.rel;
        const full = std.fs.path.join(gpa, &.{ sess_dir, rel }) catch return SessionError.OutOfMemory;
        defer gpa.free(full);
        var src = std.Io.Dir.openFileAbsolute(io, full, .{}) catch |e| {
            if (e == error.OutOfMemory) return SessionError.OutOfMemory;
            return SessionError.Io;
        };
        defer src.close(io);
        const digest = store.putFile(io, src, .incremental) catch |e| {
            if (e == error.StoreFull) return; // drop the session silently
            if (e == error.OutOfMemory) return SessionError.OutOfMemory;
            return SessionError.StoreRead;
        };
        store.tagObject(io, digest, blob_tags) catch |e| {
            // Drop the session silently on StoreFull (no budget) or
            // TagLimit (same bytes already tagged under another build's
            // unit-tag values — hints only, never fail the build).
            if (e == error.StoreFull or e == error.TagLimit) return;
            return e;
        };
        const dhex = digest.toHex();
        const dhex_dup = gpa.dupe(u8, dhex[0..]) catch return SessionError.OutOfMemory;
        dto.* = .{ .path = rel, .digest = dhex_dup, .size = f.size, .mode = f.mode };
        dto_count += 1;
    }

    const body = std.json.Stringify.valueAlloc(gpa, SessionManifestJson{ .format = 1, .files = dtos[0..dto_count] }, .{}) catch return SessionError.OutOfMemory;
    defer gpa.free(body);
    const manifest_digest = store.putBytes(io, body, .incremental) catch |e| {
        if (e == error.StoreFull) return; // drop the session silently
        if (e == error.OutOfMemory) return SessionError.OutOfMemory;
        return SessionError.StoreRead;
    };
    const man_tags = gpa.alloc(Tag, tags.len + 2) catch return SessionError.OutOfMemory;
    defer gpa.free(man_tags);
    @memcpy(man_tags[0..tags.len], tags);
    man_tags[tags.len] = .{ .key = "user.session", .value = hex };
    man_tags[tags.len + 1] = .{ .key = "user.session_manifest", .value = hex };
    store.tagObject(io, manifest_digest, man_tags) catch |e| {
        // Same hint-drop rule as the blob tags above (identical session
        // manifests across builds share one object under different keys).
        if (e == error.StoreFull or e == error.TagLimit) return;
        return e;
    };
}

/// Restores the prior incremental session for `key` into `sess_dir`
/// (created empty on a miss). Queries the manifest tag
/// (`user.session_manifest=<keyhex>`) newest-first; the first candidate
/// that parses as a format-1 session manifest wins (a miss returns
/// false). Blobs are read by digest and
/// written with `0o644` (writable COPIES — store objects stay `0o444`;
/// rustc must update session files in place). An over-cap manifest, an
/// unreadable blob, or a corrupt entry is a miss (false), never a partial
/// restore: half a session is worse than none.
pub fn materializeSession(
    gpa: std.mem.Allocator,
    io: std.Io,
    store: *Store,
    key: Digest,
    sess_dir: []const u8,
) SessionError!bool {
    std.Io.Dir.cwd().createDirPath(io, sess_dir) catch |e| {
        if (e == error.OutOfMemory) return SessionError.OutOfMemory;
        return SessionError.Io;
    };
    var hex_buf: [64]u8 = undefined;
    const hex = sessionHex(key, &hex_buf);
    // The conjunctive restore predicate is the manifest tag alone. A fixed
    // signature carries no unit-tags param, and none is needed: `key`
    // already binds (toolchain digest, target triple, profile, features)
    // through the fingerprint (see `sessionKey`), so the manifest tag
    // value is unique per unit configuration by construction.
    const candidates = try store.lookupObjects(io, gpa, .{ .tags = &.{.{ .key = "user.session_manifest", .value = hex }}, .limit = 4 });
    defer gpa.free(candidates);
    for (candidates) |man_digest| {
        const body = store.readObject(io, man_digest, gpa) catch |e| {
            if (e == error.ObjectNotFound) continue;
            if (e == error.OutOfMemory) return SessionError.OutOfMemory;
            return SessionError.StoreRead;
        };
        defer gpa.free(body);
        const parsed = std.json.parseFromSlice(SessionManifestJson, gpa, body, .{ .allocate = .alloc_always }) catch continue;
        defer parsed.deinit();
        if (parsed.value.format != 1) continue;
        if (parsed.value.files.len > max_session_files) return false;
        var total: u64 = 0;
        for (parsed.value.files) |f| {
            total += f.size;
            if (total > max_session_bytes) return false;
        }
        for (parsed.value.files) |f| {
            const digest = Digest.fromHex(f.digest) catch return false;
            const blob = store.readObject(io, digest, gpa) catch |e| {
                if (e == error.ObjectNotFound) return false;
                if (e == error.OutOfMemory) return SessionError.OutOfMemory;
                return SessionError.StoreRead;
            };
            defer gpa.free(blob);
            const full = std.fs.path.join(gpa, &.{ sess_dir, f.path }) catch return SessionError.OutOfMemory;
            defer gpa.free(full);
            const parent = std.fs.path.dirname(full) orelse sess_dir;
            std.Io.Dir.cwd().createDirPath(io, parent) catch |e| {
                if (e == error.OutOfMemory) return SessionError.OutOfMemory;
                return SessionError.Io;
            };
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = full, .data = blob }) catch |e| {
                if (e == error.OutOfMemory) return SessionError.OutOfMemory;
                return SessionError.Io;
            };
            var out = std.Io.Dir.openFileAbsolute(io, full, .{ .mode = .write_only }) catch |e| {
                if (e == error.OutOfMemory) return SessionError.OutOfMemory;
                return SessionError.Io;
            };
            defer out.close(io);
            out.setPermissions(io, .fromMode(0o644)) catch |e| {
                if (e == error.OutOfMemory) return SessionError.OutOfMemory;
                return SessionError.Io;
            };
        }
        return true;
    }
    return false;
}

// =====================================================================
// Tests (Tasks 7–9; oracle-gated where real rustc/store pressure applies)
// =====================================================================

fn testUnit() Unit {
    return .{
        .pkg_name = "foo",
        .version = "0.1.0",
        .target_name = "foo",
        .kind = .lib,
        .edition = "2021",
        .crate_types = &.{"rlib"},
        .profile = @import("profile.zig").profileFor("dev"),
        .features_sorted = &.{},
        .target_triple = "aarch64-apple-darwin",
        .compile_kind = .target,
        .mode = .build,
        .src_path = "/ws/foo",
        .deps = &.{},
    };
}

fn testFingerprint() Fingerprint {
    return .{
        .rustc_digest = store_mod.hashBytes("r"),
        .features_sorted = &.{},
        .target_desc_hash = store_mod.hashBytes("t"),
        .profile_hash = store_mod.hashBytes("p"),
        .path_hash = store_mod.hashBytes("h"),
        .dep_fps = &.{},
        .rustflags_hash = store_mod.hashBytes(""),
        .config_hash = store_mod.hashBytes("c"),
    };
}

test "envelopes re-emit rustc json diagnostics" {
    const gpa = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    // Fake CompileOutput with one diagnostic line; assert a
    // compiler-message envelope line appears (the plan's Step-1 test).
    const line = "{\"$message_type\":\"diagnostic\",\"message\":\"unused var\",\"level\":\"warning\",\"spans\":[]}\nnot-json-noise\n";
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aalloc = arena.allocator();
    const unit = testUnit();
    const out = CompileOutput{
        .arena = arena,
        .exited = 0,
        .stdout = "",
        .stderr = try aalloc.dupe(u8, line),
    };
    var buf: std.Io.Writer.Allocating = try .initCapacity(gpa, 512);
    defer buf.deinit();
    const ok = try emitEnvelopes(gpa, io, &buf.writer, &unit, "dev", &out, &.{}, true);
    try std.testing.expect(ok);
    const got = try buf.toOwnedSlice();
    defer gpa.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "compiler-message") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "unused var") != null);
    // The verbatim rustc line follows its envelope (two-line pairing).
    try std.testing.expect(std.mem.indexOf(u8, got, "$message_type") != null);
    // Non-JSON noise is dropped in json mode.
    try std.testing.expect(std.mem.indexOf(u8, got, "not-json-noise") == null);
}

test "envelopes fail loud on nonzero exit and pass noise through for humans" {
    const gpa = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aalloc = arena.allocator();
    const unit = testUnit();
    const line = "{\"$message_type\":\"diagnostic\",\"message\":\"boom\",\"level\":\"error\",\"spans\":[]}\nplain-noise\n";
    var out = CompileOutput{
        .arena = arena,
        .exited = 1,
        .stdout = "",
        .stderr = try aalloc.dupe(u8, line),
    };
    var buf: std.Io.Writer.Allocating = try .initCapacity(gpa, 512);
    defer buf.deinit();
    // Diagnostics are emitted BEFORE the RustcFailed return (caller maps
    // it to exit 101 with the envelopes already on the wire).
    try std.testing.expectError(CompileError.RustcFailed, emitEnvelopes(gpa, io, &buf.writer, &unit, "dev", &out, &.{}, false));
    const got = try buf.toOwnedSlice();
    defer gpa.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "error: boom") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "plain-noise") != null);
}

test "spawn runs real rustc --version when oracle enabled" {
    if (!oracle_mod.oracleEnabled()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    // Spawn-capable io needs a real pool: global_single_threaded sets
    // .allocator = .failing, so processSpawn's argv/env alloc always
    // returns OutOfMemory (the toolchain probe test's PLAN-FIX precedent).
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // One-arg invocation built by hand (rustc --version), all strings
    // gpa-owned so `deinit` frees them (never static slices — `free` on
    // a `&.{}` literal would corrupt the testing allocator).
    const argv = try gpa.alloc([]const u8, 2);
    argv[0] = try gpa.dupe(u8, "rustc");
    argv[1] = try gpa.dupe(u8, "--version");
    var inv = RustcInvocation{
        .argv = argv,
        .env_extra = try gpa.alloc([]const u8, 0),
        .out_dir = "",
        .dep_info_path = try gpa.dupe(u8, "/tmp/rime-spawn-probe.d"),
    };
    defer inv.deinit(gpa);
    var out = try spawnRustc(gpa, io, &inv);
    defer out.deinit();
    try std.testing.expectEqual(@as(u8, 0), out.exited);
    try std.testing.expect(std.mem.indexOf(u8, out.stdout, "rustc") != null);
}

test "ingest stores spool outputs and records the action" {
    const gpa = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    // Scratch store directly (the view.zig test shape: Store.open over a
    // tmpDir — test_support stays behind the store module wall).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tstore = try Store.open(io, tmp.dir, .{});
    defer tstore.close(io);

    // Spool dir with two files (fake rlib bytes + dep-info text).
    var spool = std.testing.tmpDir(.{});
    defer spool.cleanup();
    try spool.dir.writeFile(io, .{ .sub_path = "libfoo-abc.rlib", .data = "fake-rlib-bytes" });
    try spool.dir.writeFile(io, .{ .sub_path = "foo.d", .data = "libfoo.rlib: src/lib.rs\n" });
    const spool_abs = try spool.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(spool_abs);

    const actionkey_mod = @import("actionkey.zig");
    const feats = try actionkey_mod.featuresTag(gpa, &.{});
    defer gpa.free(feats);
    const tags = try actionkey_mod.unitTags(gpa, "rustc 1.99.0 a1b2c3d4", "aarch64-apple-darwin", "dev", feats, "pb3-test", "foo", "0.1.0", "rustc");
    defer gpa.free(tags);
    const fp = testFingerprint();
    const norm_argv = [_][]const u8{ "rustc", "--crate-name", "foo" };
    const key = try actionkey_mod.actionKey(gpa, &fp, &norm_argv, store_mod.hashBytes("in"), &.{});
    const unit = testUnit();
    const expected = [_]ExpectedOutput{
        .{ .filename = "libfoo-abc.rlib", .kind = .rlib, .mode = 0o444 },
        .{ .filename = "foo.d", .kind = .dep_info, .mode = 0o444 },
    };
    const ing = try ingestUnitOutputs(gpa, io, &tstore, &unit, spool_abs, &expected, tags, key, null);
    try std.testing.expect(ing.manifest_digest != null);
    try std.testing.expect(!ing.cache_hit);
    try std.testing.expectEqual(key.bytes, ing.action_key.bytes);
    // putAction round-trips via lookupAction…
    const hit = try tryIngestCacheHit(gpa, io, &tstore, key);
    try std.testing.expect(hit != null);
    try std.testing.expectEqual(ing.manifest_digest.?.bytes, hit.?.bytes);
    // …and the crate tag is on a stored object.
    var man = try tstore.getManifest(io, gpa, ing.manifest_digest.?);
    defer man.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), man.outputs.len);
    const obj_tags = try tstore.tagsFor(io, gpa, man.outputs[0].digest);
    defer {
        for (obj_tags) |t| {
            gpa.free(t.key);
            gpa.free(t.value);
        }
        gpa.free(obj_tags);
    }
    var saw_crate = false;
    for (obj_tags) |t| {
        if (std.mem.eql(u8, t.key, "crate") and std.mem.eql(u8, t.value, "foo")) saw_crate = true;
    }
    try std.testing.expect(saw_crate);
    // A missing non-.rmeta file is Io (rustc broke its contract)…
    const bad_expected = [_]ExpectedOutput{.{ .filename = "absent.rlib", .kind = .rlib, .mode = 0o444 }};
    try std.testing.expectError(IngestError.Io, ingestUnitOutputs(gpa, io, &tstore, &unit, spool_abs, &bad_expected, tags, key, null));
    // …while a missing .rmeta is pipelining variance (skipped, still recorded).
    const rmeta_expected = [_]ExpectedOutput{.{ .filename = "absent.rmeta", .kind = .rmeta, .mode = 0o444 }};
    const ing2 = try ingestUnitOutputs(gpa, io, &tstore, &unit, spool_abs, &rmeta_expected, tags, key, null);
    try std.testing.expect(ing2.manifest_digest != null);
}

test "ingest degrades to spool-only when the store is full" {
    const gpa = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    // The root.zig pin-test precedent: a 1 B index_state cap refuses every
    // tag/manifest write with StoreFull while tiny hot puts still fit — so
    // ingestion must swallow and return manifest_digest == null, no error.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tstore = try Store.open(io, tmp.dir, .{
        .budget = .{ .fixed = 10_000_000 },
        .index_state_cap = .{ .fixed = 1 },
    });
    defer tstore.close(io);

    var spool = std.testing.tmpDir(.{});
    defer spool.cleanup();
    try spool.dir.writeFile(io, .{ .sub_path = "libfoo-abc.rlib", .data = "fake-rlib-bytes" });
    const spool_abs = try spool.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(spool_abs);

    const actionkey_mod = @import("actionkey.zig");
    const feats = try actionkey_mod.featuresTag(gpa, &.{});
    defer gpa.free(feats);
    const tags = try actionkey_mod.unitTags(gpa, "rustc 1.99.0 a1b2c3d4", "aarch64-apple-darwin", "dev", feats, "pb3-test", "foo", "0.1.0", "rustc");
    defer gpa.free(tags);
    const fp = testFingerprint();
    const norm_argv = [_][]const u8{ "rustc", "--crate-name", "foo" };
    const key = try actionkey_mod.actionKey(gpa, &fp, &norm_argv, store_mod.hashBytes("in"), &.{});
    const unit = testUnit();
    const expected = [_]ExpectedOutput{
        .{ .filename = "libfoo-abc.rlib", .kind = .rlib, .mode = 0o444 },
    };
    // The one-line §10.4 rendering goes through the log sink (null in the
    // test above); here assert the sink receives the `rime: store full` line.
    var log: std.Io.Writer.Allocating = try .initCapacity(gpa, 256);
    defer log.deinit();
    const ing = try ingestUnitOutputs(gpa, io, &tstore, &unit, spool_abs, &expected, tags, key, &log.writer);
    try std.testing.expect(ing.manifest_digest == null);
    try std.testing.expect(!ing.cache_hit);
    const logged = try log.toOwnedSlice();
    defer gpa.free(logged);
    try std.testing.expect(std.mem.indexOf(u8, logged, "rime: store full") != null);
}

test "session round-trips through the store" {
    const gpa = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tstore = try Store.open(io, tmp.dir, .{});
    defer tstore.close(io);

    var sess = std.testing.tmpDir(.{});
    defer sess.cleanup();
    try sess.dir.writeFile(io, .{ .sub_path = "a.bin", .data = "session-bytes-a" });
    try sess.dir.createDirPath(io, "sub");
    try sess.dir.writeFile(io, .{ .sub_path = "sub/b.bin", .data = "session-bytes-b" });
    const sess_abs = try sess.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(sess_abs);

    const actionkey_mod = @import("actionkey.zig");
    const feats = try actionkey_mod.featuresTag(gpa, &.{});
    defer gpa.free(feats);
    const tags = try actionkey_mod.unitTags(gpa, "rustc 1.99.0 a1b2c3d4", "aarch64-apple-darwin", "dev", feats, "pb3-test", "foo", "0.1.0", "rustc");
    defer gpa.free(tags);
    const fp = testFingerprint();
    const key = sessionKey(&fp, store_mod.hashBytes("inputs"));
    try ingestSession(gpa, io, &tstore, key, sess_abs, tags);

    // Wipe the dir; restore must recreate it byte-identical.
    try sess.dir.deleteTree(io, "sub");
    try sess.dir.deleteFile(io, "a.bin");
    try std.testing.expect(try materializeSession(gpa, io, &tstore, key, sess_abs));
    const ra = try sess.dir.readFileAlloc(io, "a.bin", gpa, .limited(1 << 20));
    defer gpa.free(ra);
    try std.testing.expectEqualStrings("session-bytes-a", ra);
    const rb = try sess.dir.readFileAlloc(io, "sub/b.bin", gpa, .limited(1 << 20));
    defer gpa.free(rb);
    try std.testing.expectEqualStrings("session-bytes-b", rb);
    // Restored copies are writable (0o644) even though store objects are 0o444.
    const st = try sess.dir.statFile(io, "a.bin", .{});
    try std.testing.expect(st.permissions.toMode() & 0o777 == 0o644);
}

test "session miss returns false" {
    const gpa = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tstore = try Store.open(io, tmp.dir, .{});
    defer tstore.close(io);

    var sess = std.testing.tmpDir(.{});
    defer sess.cleanup();
    const sess_abs = try sess.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(sess_abs);
    const fp = testFingerprint();
    const key = sessionKey(&fp, store_mod.hashBytes("never-ingested"));
    // Miss under a nested (not-yet-existing) dir: created empty, false returned.
    const nested = try std.fmt.allocPrint(gpa, "{s}/fresh", .{sess_abs});
    defer gpa.free(nested);
    try std.testing.expect(!try materializeSession(gpa, io, &tstore, key, nested));
    var dd = try std.Io.Dir.openDirAbsolute(io, nested, .{ .iterate = true });
    defer dd.close(io);
    var it = dd.iterate();
    try std.testing.expect((try it.next(io)) == null);
}

// =====================================================================
// Task 12: diagnostic normalization for golden compares
// =====================================================================

/// Normalizes one `--message-format=json` envelope line for golden
/// compares: `ws_root` → `@VALIDATION_ROOT@`, spool build dirs
/// (`<...>/rime-build-<id>/...` tokens) → `@SPOOL@`. Durations, rustc
/// versions, and fingerprint hashes pass through — the Task-12 compare is
/// byte-contains per diagnostic message (order rules documented there),
/// never raw-line equality. gpa-owned; the input line is borrowed.
pub fn normalizeDiagLine(gpa: std.mem.Allocator, line: []const u8, ws_root: []const u8) CompileError![]u8 {
    const pass1 = replaceAll(gpa, line, ws_root, "@VALIDATION_ROOT@") catch return CompileError.OutOfMemory;
    defer gpa.free(pass1);
    return replaceSpoolToken(gpa, pass1) catch return CompileError.OutOfMemory;
}

fn replaceAll(gpa: std.mem.Allocator, text: []const u8, needle: []const u8, replacement: []const u8) std.mem.Allocator.Error![]u8 {
    if (needle.len == 0) return gpa.dupe(u8, text);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var rest = text;
    while (std.mem.indexOf(u8, rest, needle)) |i| {
        try out.appendSlice(gpa, rest[0..i]);
        try out.appendSlice(gpa, replacement);
        rest = rest[i + needle.len ..];
    }
    try out.appendSlice(gpa, rest);
    return out.toOwnedSlice(gpa);
}

fn isSpoolChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.' or c == '/';
}

/// Replaces every path token containing `rime-build-` with `@SPOOL@`
/// (token boundaries: the maximal `isSpoolChar` run around the marker).
fn replaceSpoolToken(gpa: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]u8 {
    const marker = "rime-build-";
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var rest = text;
    while (std.mem.indexOf(u8, rest, marker)) |i| {
        var start = i;
        while (start > 0 and isSpoolChar(rest[start - 1])) start -= 1;
        var end = i + marker.len;
        while (end < rest.len and isSpoolChar(rest[end])) end += 1;
        try out.appendSlice(gpa, rest[0..start]);
        try out.appendSlice(gpa, "@SPOOL@");
        rest = rest[end..];
    }
    try out.appendSlice(gpa, rest);
    return out.toOwnedSlice(gpa);
}

test "normalizeDiagLine replaces roots and spool tokens" {
    const gpa = std.testing.allocator;
    const line = "{\"reason\":\"compiler-artifact\",\"filenames\":[\"/ws/proj/target/debug/deps/liba-abc.rlib\",\"/c/spool/rime-build-99/units/a/liba-abc.rlib\"]}";
    const n = try normalizeDiagLine(gpa, line, "/ws/proj");
    defer gpa.free(n);
    try std.testing.expect(std.mem.indexOf(u8, n, "@VALIDATION_ROOT@/target") != null);
    try std.testing.expect(std.mem.indexOf(u8, n, "@SPOOL@") != null);
    try std.testing.expect(std.mem.indexOf(u8, n, "rime-build-") == null);
    try std.testing.expect(std.mem.indexOf(u8, n, "/ws/proj") == null);
}
