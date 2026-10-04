//! Rustc toolchain identity (M4 Task 1).
//!
//! `probeToolchain` resolves the rustc binary (`rustc_path` param, else
//! `$RUSTC`, else `PATH` lookup of `"rustc"`), runs `<rustc> -vV` and
//! `<rustc> --print sysroot`, and binds all three content sources into one
//! digest: the `-vV` bytes, the rustc binary bytes, and the sorted
//! `<sysroot>/lib` tree bytes (storage-v2 §5.3 action-key contents rule).
//! The digest is computed incrementally with BLAKE3 over the concatenation,
//! so it equals `hashBytes(vV ++ binary ++ sysroot_libs)` without ever
//! holding the whole input in memory.
//!
//! Ownership: every string on `Toolchain` except `rustc_path` is gpa-owned
//! (`deinit` frees them); `rustc_path` borrows the caller/`$RUSTC`/static
//! and must NOT be freed. `parseRustcVv` returns borrow slices of its input.

const std = @import("std");
const store_mod = @import("store");

const Digest = store_mod.Digest;

pub const ToolchainError = error{ SpawnFailed, BadVersionOutput, RustcNotFound, OutOfMemory } || std.mem.Allocator.Error;

pub const Toolchain = struct {
    rustc_path: []const u8, // resolved $RUSTC or "rustc" spelling (borrowed; do not free; NOT directly spawnable — resolve with resolveBinPath first)
    version: []const u8, // "1.99.0-nightly" (gpa-owned)
    host_target: []const u8, // "aarch64-apple-darwin" (gpa-owned)
    commit_hash: []const u8, // 40-hex (gpa-owned)
    sysroot: []const u8, // absolute sysroot path (gpa-owned)
    digest: Digest, // BLAKE3(vV ++ rustc binary ++ sorted sysroot-lib bytes); value type

    pub fn deinit(self: *Toolchain, gpa: std.mem.Allocator) void {
        gpa.free(self.version);
        gpa.free(self.host_target);
        gpa.free(self.commit_hash);
        gpa.free(self.sysroot);
    }

    /// Storage-v2 §11.3 `toolchain` tag value: `rustc <version> <digest8>`.
    /// The digest binds sysroot lib bytes per §5.3, so the 8-hex suffix is
    /// honestly a sysroot-digest prefix, not just a version string.
    pub fn tag(self: *const Toolchain, gpa: std.mem.Allocator) ToolchainError![]u8 {
        const hex = self.digest.toHex();
        return std.fmt.allocPrint(gpa, "rustc {s} {s}", .{ self.version, hex[0..8] }) catch return ToolchainError.OutOfMemory;
    }
};

/// Parses the three pinned lines of `rustc -vV` output
/// (`rustc <version> (<hash> <date>)`, `host: <triple>`,
/// `commit-hash: <40-hex>`). Returned slices borrow `text`.
pub fn parseRustcVv(text: []const u8) ToolchainError!struct { version: []const u8, host: []const u8, commit: []const u8 } {
    var version: ?[]const u8 = null;
    var host: ?[]const u8 = null;
    var commit: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "rustc ")) {
            const rest = line["rustc ".len..];
            const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
            version = rest[0..end];
        } else if (std.mem.startsWith(u8, line, "host: ")) {
            host = std.mem.trim(u8, line["host: ".len..], " \r");
        } else if (std.mem.startsWith(u8, line, "commit-hash: ")) {
            commit = std.mem.trim(u8, line["commit-hash: ".len..], " \r");
        }
    }
    if (version == null or host == null or commit == null) return ToolchainError.BadVersionOutput;
    return .{ .version = version.?, .host = host.?, .commit = commit.? };
}

const spawn_timeout_ns: u64 = 60 * std.time.ns_per_s;

const Watchdog = struct {
    child: *std.process.Child,
    io: std.Io,
    done: std.atomic.Value(bool),
    fired: std.atomic.Value(bool),
};

// Copied from oracle.zig::watchdogMain (do not redesign): 60 s watchdog
// that kills the child when the timeout fires.
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

/// Spawn `argv`, drain stdout+stderr with the oracle `runCapture` loop
/// shape, enforce the 60 s watchdog. Returns exit code + gpa-owned stdout.
/// Missing binary → `RustcNotFound`; timeout/signal → `SpawnFailed`.
fn captureStdout(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) ToolchainError!struct { exited: u8, out: []u8 } {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch return ToolchainError.RustcNotFound;
    errdefer child.kill(io);
    var w = Watchdog{ .child = &child, .io = io, .done = std.atomic.Value(bool).init(false), .fired = std.atomic.Value(bool).init(false) };
    const watcher = std.Thread.spawn(.{}, watchdogMain, .{&w}) catch return ToolchainError.SpawnFailed;
    var mr_buf: std.Io.File.MultiReader.Buffer(2) = undefined;
    var mr: std.Io.File.MultiReader = undefined;
    mr.init(gpa, io, mr_buf.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer mr.deinit();
    const out_r = mr.reader(0);
    while (mr.fill(4096, .none)) |_| {} else |e| if (e != error.EndOfStream) {
        w.done.store(true, .release);
        watcher.join();
        return ToolchainError.SpawnFailed;
    }
    const term = child.wait(io) catch {
        w.done.store(true, .release);
        watcher.join();
        return ToolchainError.SpawnFailed;
    };
    w.done.store(true, .release);
    watcher.join();
    if (w.fired.load(.acquire)) return ToolchainError.SpawnFailed;
    if (term != .exited) return ToolchainError.SpawnFailed;
    const out = gpa.dupe(u8, out_r.buffered()) catch return ToolchainError.OutOfMemory;
    return .{ .exited = term.exited, .out = out };
}

/// Resolves the rustc spelling: explicit param, else `$RUSTC` (via
/// `std.c.getenv`, the oracle precedent), else bare `"rustc"` (PATH).
/// Returned slice is borrowed (param / environ / static); do not free.
/// NOTE: this is the display spelling kept on `Toolchain.rustc_path` — it
/// is NOT directly spawnable (see `resolveBinPath`).
fn resolveRustcBin(rustc_path: ?[]const u8) []const u8 {
    if (rustc_path) |p| return p;
    if (std.c.getenv("RUSTC")) |z| {
        const s = std.mem.span(z);
        if (s.len > 0) return s;
    }
    return "rustc";
}

/// Resolves a rustc spelling to an absolute path for spawning. Spellings
/// containing '/' are duped verbatim; bare names search the AMBIENT PATH
/// (libc getenv). The ambient search is load-bearing: the spawner resolves
/// bare names against the io environ's PATH (empty under
/// `Threaded.init(gpa, .{})` in tests) or its fixed default_PATH
/// (`/usr/local/bin:/bin:/usr/bin`), so a bare `rustc` living in
/// `~/.cargo/bin` FileNotFounds without this. Returns null when no
/// executable candidate exists. gpa-owned; caller frees.
/// (Added seam for Task 7's spawnRustc: call this on `tc.rustc_path` — the
/// field keeps the borrowed original spelling per the Interfaces.)
pub fn resolveBinPath(gpa: std.mem.Allocator, io: std.Io, name: []const u8) std.mem.Allocator.Error!?[]u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) return try gpa.dupe(u8, name);
    const path_z = std.c.getenv("PATH") orelse return null;
    const path = std.mem.span(path_z);
    var it = std.mem.splitScalar(u8, path, ':');
    const cwd = std.Io.Dir.cwd();
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, name });
        errdefer gpa.free(full);
        const st = cwd.statFile(io, full, .{}) catch {
            gpa.free(full);
            continue;
        };
        if (st.permissions.toMode() & 0o111 == 0) {
            gpa.free(full);
            continue;
        }
        return full;
    }
    return null;
}

/// Opens the rustc binary for hashing: direct open when the path names a
/// file (contains `/`), else a `PATH` search like the spawner performs.
/// Failure → `RustcNotFound` (the binary cannot be located as a file).
fn openRustcBin(io: std.Io, bin: []const u8) ToolchainError!std.Io.File {
    if (std.mem.indexOfScalar(u8, bin, '/') != null) {
        return std.Io.Dir.cwd().openFile(io, bin, .{}) catch return ToolchainError.RustcNotFound;
    }
    const path_z = std.c.getenv("PATH") orelse return ToolchainError.RustcNotFound;
    const path = std.mem.span(path_z);
    var it = std.mem.splitScalar(u8, path, ':');
    var buf: [4096]u8 = undefined;
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, bin }) catch continue;
        if (std.Io.Dir.cwd().openFile(io, full, .{})) |f| return f else |_| continue;
    }
    return ToolchainError.RustcNotFound;
}

/// Streams one file's bytes into an in-flight BLAKE3 hasher (positional
/// reads, no rewind, 64 KiB chunks — the `digest.hashFile` shape).
fn streamFileInto(h: *std.crypto.hash.Blake3, file: std.Io.File, io: std.Io) ToolchainError!void {
    var buf: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = file.readPositionalAll(io, &buf, offset) catch return ToolchainError.SpawnFailed;
        if (n == 0) break;
        h.update(buf[0..n]);
        offset += n;
    }
}

const max_sysroot_files: usize = 20_000;
// PLAN-FIX (reported): the prose cap of 512 MiB rejects the pinned oracle
// toolchain itself (nightly-2026-08-04 `<sysroot>/lib` is ~748 MB / 3877
// files), failing the Task-1 oracle probe with BadVersionOutput. Raised to
// 2 GiB: still bounded and loud, comfortably above real sysroots.
const max_sysroot_bytes: u64 = 2 << 30;

/// Recursive collector for `hashSysrootLibs`: every regular file (symlinks
/// followed at hash time) under `dir`, as gpa-owned `/`-joined paths
/// relative to the walk root. Directories recurse; anything else is
/// skipped. Mid-walk IO failures are loud (`SpawnFailed`), never skipped —
/// a partial tree would silently weaken the toolchain identity.
fn collectLibFiles(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, prefix: []const u8, out: *std.ArrayList([]const u8)) ToolchainError!void {
    var it = dir.iterate();
    while (it.next(io) catch return ToolchainError.SpawnFailed) |entry| {
        if (out.items.len >= max_sysroot_files) return ToolchainError.BadVersionOutput;
        const rel = if (prefix.len == 0)
            try gpa.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(gpa, "{s}/{s}", .{ prefix, entry.name });
        errdefer gpa.free(rel);
        switch (entry.kind) {
            .directory => {
                var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch return ToolchainError.SpawnFailed;
                defer sub.close(io);
                try collectLibFiles(gpa, io, sub, rel, out);
                gpa.free(rel);
            },
            .file, .sym_link => {
                try out.append(gpa, rel);
            },
            else => gpa.free(rel),
        }
    }
}

fn sortStrings(items: [][]const u8) void {
    std.mem.sort([]const u8, items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
}

/// Hashes the walk root's file list into an in-flight hasher: sorted
/// relpaths, each as `relpath \x00 filebytes`. Enforces the file-count and
/// total-bytes caps (`BadVersionOutput` when exceeded — bounded, loud).
fn hashLibWalkInto(h: *std.crypto.hash.Blake3, gpa: std.mem.Allocator, io: std.Io, lib_dir: std.Io.Dir) ToolchainError!void {
    var files: std.ArrayList([]const u8) = .empty;
    defer {
        for (files.items) |f| gpa.free(f);
        files.deinit(gpa);
    }
    try collectLibFiles(gpa, io, lib_dir, "", &files);
    sortStrings(files.items);
    var total: u64 = 0;
    for (files.items) |rel| {
        const st = lib_dir.statFile(io, rel, .{}) catch return ToolchainError.SpawnFailed;
        total += st.size;
        if (total > max_sysroot_bytes) return ToolchainError.BadVersionOutput;
        h.update(rel);
        h.update(&[_]u8{0});
        var f = lib_dir.openFile(io, rel, .{}) catch return ToolchainError.SpawnFailed;
        defer f.close(io);
        try streamFileInto(h, f, io);
    }
}

/// BLAKE3 over the sorted `<sysroot>/lib` tree (`relpath \x00 filebytes`
/// joins). A missing `<sysroot>/lib` dir hashes as the empty string —
/// documented fallback for lib-less layouts, still content-bound
/// everywhere else. Caps: 20k files / 2 GiB total, else `BadVersionOutput`.
pub fn hashSysrootLibs(gpa: std.mem.Allocator, io: std.Io, sysroot: []const u8) ToolchainError!Digest {
    var h = std.crypto.hash.Blake3.init(.{});
    const lib_path = std.fs.path.join(gpa, &.{ sysroot, "lib" }) catch return ToolchainError.OutOfMemory;
    defer gpa.free(lib_path);
    var lib_dir = std.Io.Dir.cwd().openDir(io, lib_path, .{ .iterate = true }) catch |e| {
        // Missing dir (or a file where the dir belongs) hashes as the
        // empty string — documented fallback for lib-less layouts.
        if (e == error.FileNotFound or e == error.NotDir) return store_mod.hashBytes("");
        if (e == error.OutOfMemory) return ToolchainError.OutOfMemory;
        return ToolchainError.SpawnFailed;
    };
    defer lib_dir.close(io);
    try hashLibWalkInto(&h, gpa, io, lib_dir);
    var out: [32]u8 = undefined;
    h.final(&out);
    return .{ .bytes = out };
}

pub fn probeToolchain(gpa: std.mem.Allocator, io: std.Io, rustc_path: ?[]const u8) ToolchainError!Toolchain {
    const bin = resolveRustcBin(rustc_path);
    // Spawnable absolute path (ambient-PATH search for bare spellings).
    const bin_abs = try resolveBinPath(gpa, io, bin) orelse return ToolchainError.RustcNotFound;
    defer gpa.free(bin_abs);

    const vv_argv = [_][]const u8{ bin_abs, "-vV" };
    const vv = try captureStdout(gpa, io, &vv_argv);
    defer gpa.free(vv.out);
    const parsed = try parseRustcVv(vv.out);

    const sr_argv = [_][]const u8{ bin_abs, "--print", "sysroot" };
    const sr = try captureStdout(gpa, io, &sr_argv);
    defer gpa.free(sr.out);
    const sysroot_trimmed = std.mem.trim(u8, sr.out, " \t\r\n");
    if (sysroot_trimmed.len == 0) return ToolchainError.BadVersionOutput;

    // Digest = BLAKE3(vV bytes ++ rustc binary bytes ++ sorted
    // sysroot-lib bytes), streamed incrementally (never materialized).
    var h = std.crypto.hash.Blake3.init(.{});
    h.update(vv.out);
    {
        var f = try openRustcBin(io, bin_abs);
        defer f.close(io);
        try streamFileInto(&h, f, io);
    }
    {
        const lib_path = try std.fs.path.join(gpa, &.{ sysroot_trimmed, "lib" });
        defer gpa.free(lib_path);
        const lib_dir_opt = std.Io.Dir.cwd().openDir(io, lib_path, .{ .iterate = true }) catch |e| blk: {
            if (e == error.FileNotFound or e == error.NotDir) break :blk null;
            if (e == error.OutOfMemory) return ToolchainError.OutOfMemory;
            return ToolchainError.SpawnFailed;
        };
        if (lib_dir_opt) |*ld| {
            defer ld.close(io);
            try hashLibWalkInto(&h, gpa, io, ld.*);
        } else {
            h.update("");
        }
    }
    var digest_bytes: [32]u8 = undefined;
    h.final(&digest_bytes);

    return .{
        .rustc_path = bin,
        .version = try gpa.dupe(u8, parsed.version),
        .host_target = try gpa.dupe(u8, parsed.host),
        .commit_hash = try gpa.dupe(u8, parsed.commit),
        .sysroot = try gpa.dupe(u8, sysroot_trimmed),
        .digest = .{ .bytes = digest_bytes },
    };
}

test "toolchain parses rustc -vV output" {
    const text =
        "rustc 1.99.0-nightly (1ed2df61a 2026-08-04)\n" ++
        "binary: rustc\n" ++
        "commit-hash: 1ed2df61a19042f231709eb05d032ae9e2cb2084\n" ++
        "commit-date: 2026-08-04\n" ++
        "host: aarch64-apple-darwin\n" ++
        "release: 1.99.0-nightly\n" ++
        "LLVM version: 22.1.8\n";
    const p = try parseRustcVv(text);
    try std.testing.expectEqualStrings("1.99.0-nightly", p.version);
    try std.testing.expectEqualStrings("aarch64-apple-darwin", p.host);
    try std.testing.expectEqualStrings("1ed2df61a19042f231709eb05d032ae9e2cb2084", p.commit);
}

test "toolchain rejects truncated version output" {
    try std.testing.expectError(ToolchainError.BadVersionOutput, parseRustcVv("rustc\n"));
}

test "toolchain tag spells rustc version plus digest8" {
    // deinit frees the owned strings, so the stub dups them exactly like
    // probeToolchain does (statics must never reach deinit).
    const gpa = std.testing.allocator;
    var tc = Toolchain{
        .rustc_path = "rustc",
        .version = try gpa.dupe(u8, "1.99.0-nightly"),
        .host_target = try gpa.dupe(u8, "aarch64-apple-darwin"),
        .commit_hash = try gpa.dupe(u8, "1ed2df61a19042f231709eb05d032ae9e2cb2084"),
        .sysroot = try gpa.dupe(u8, "/nonexistent"),
        .digest = store_mod.hashBytes("stub-toolchain"),
    };
    defer tc.deinit(gpa);
    const t = try tc.tag(std.testing.allocator);
    defer std.testing.allocator.free(t);
    try std.testing.expect(std.mem.startsWith(u8, t, "rustc 1.99.0-nightly "));
    try std.testing.expectEqual(@as(usize, "rustc 1.99.0-nightly ".len + 8), t.len);
}

test "sysroot lib walk is deterministic and content-bound" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "lib/nested");
    try tmp.dir.writeFile(io, .{ .sub_path = "lib/a.rlib", .data = "rlib-bytes" });
    try tmp.dir.writeFile(io, .{ .sub_path = "lib/nested/b.so", .data = "so-bytes" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const d1 = try hashSysrootLibs(gpa, io, root);
    const d2 = try hashSysrootLibs(gpa, io, root);
    try std.testing.expectEqual(d1.bytes, d2.bytes);
    // Content change (same names, different bytes) changes the digest.
    try tmp.dir.writeFile(io, .{ .sub_path = "lib/a.rlib", .data = "rlib-bytes-changed" });
    const d3 = try hashSysrootLibs(gpa, io, root);
    try std.testing.expect(!std.mem.eql(u8, &d1.bytes, &d3.bytes));
    // Missing lib dir hashes as the empty string (documented fallback).
    const d4 = try hashSysrootLibs(gpa, io, "/nonexistent-rime-toolchain-sysroot");
    try std.testing.expectEqual(store_mod.hashBytes("").bytes, d4.bytes);
}

test "toolchain resolves bare names against the ambient PATH" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    // Absolute spellings pass through verbatim.
    const abs = try resolveBinPath(gpa, io, "/bin/sh");
    defer {
        if (abs) |a| gpa.free(a);
    }
    try std.testing.expect(abs != null);
    // A missing binary resolves to null (never a fabricated path).
    const missing = try resolveBinPath(gpa, io, "rime-no-such-binary-xyz");
    try std.testing.expect(missing == null);
}

test "toolchain probes the real rustc when oracle enabled" {
    if (!@import("oracle.zig").oracleEnabled()) return error.SkipZigTest;
    // PLAN-FIX (reported): the plan's sketch uses global_single_threaded
    // io here, but that instance sets .allocator = .failing, so
    // processSpawn (argv/env block alloc) always returns OutOfMemory.
    // Spawn-capable tests need a real pool (fetch.zig CliGit precedent).
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tc = try probeToolchain(gpa, io, null);
    defer tc.deinit(gpa);
    try std.testing.expect(tc.version.len > 0);
    try std.testing.expect(std.mem.indexOfScalar(u8, tc.host_target, '-') != null);
    const t = try tc.tag(gpa);
    defer gpa.free(t);
    try std.testing.expect(std.mem.startsWith(u8, t, "rustc "));
}
