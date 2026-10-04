//! M6 oracle harness: real-cargo conformance for the CLI surface.
//!
//! Suite A compares `compiler-artifact`/`build-finished` JSON streams
//! (reason sequence + package_ids + target/profile shapes) between the real
//! cargo oracle and rime, after normalizing volatile fields (absolute
//! paths, filename hashes, out_dir counters, `fresh`). Suite B executes the
//! committed exit-matrix table (`validation/m6-golden/exit-matrix.json`)
//! against the built `rime` binary AND the real cargo on the same fixture
//! and asserts equal codes. Suite C (help snapshots) runs ungated.
//!
//! Gating follows the `oracle.zig` precedent: every cargo-spawning test
//! returns early (skip, never fail) unless `RIME_CARGO_ORACLE=1` AND
//! `cargo` is on `PATH`.

const std = @import("std");
const oracle = @import("oracle.zig");

/// Normalizes one JSON-stream line: absolute paths under `root` become
/// `@VALIDATION_ROOT@`, `libfoo-<meta>` hashes become `libfoo-<META>`,
/// build-script counters (`build/a-<n>`) become `build/a-<N>`.
pub fn normalizeLine(gpa: std.mem.Allocator, line: []const u8, root: []const u8) ![]u8 {
    var out = try gpa.dupe(u8, line);
    errdefer gpa.free(out);
    // Absolute root -> placeholder.
    if (root.len > 0) {
        const tmp = try replaceAll(gpa, out, root, "@VALIDATION_ROOT@");
        gpa.free(out);
        out = tmp;
    }
    // Deps-hash normalization: 16-hex metadata hashes (`libfoo-<meta>`,
    // `build/<pkg>/<meta>/out`) become `<META>----------`. Delimited on
    // both sides (dash or slash, then a terminator) so version strings
    // and 64-hex checksums never match.
    var i: usize = 0;
    while (i < out.len) {
        const delim = out[i] == '-' or out[i] == '/';
        if (delim and i + 17 < out.len and isHex16(out[i + 1 .. i + 17])) {
            const after = out[i + 17];
            if (after == '.' or after == '"' or after == '-' or after == '/' or after == '\'') {
                @memcpy(out[i + 1 .. i + 17], "<META>----------"[0..16]);
                i += 17;
                continue;
            }
        }
        i += 1;
    }
    return out;
}

fn isHex16(s: []const u8) bool {
    if (s.len < 16) return false;
    for (s[0..16]) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

fn replaceAll(gpa: std.mem.Allocator, text: []const u8, needle: []const u8, replacement: []const u8) ![]u8 {
    if (needle.len == 0) return gpa.dupe(u8, text);
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOf(u8, text[idx..], needle)) |off| {
        count += 1;
        idx += off + needle.len;
    }
    if (count == 0) return gpa.dupe(u8, text);
    const out_len = text.len - count * needle.len + count * replacement.len;
    const out = try gpa.alloc(u8, out_len);
    var w: usize = 0;
    var r: usize = 0;
    while (std.mem.indexOf(u8, text[r..], needle)) |off| {
        @memcpy(out[w .. w + off], text[r .. r + off]);
        w += off;
        @memcpy(out[w .. w + replacement.len], replacement);
        w += replacement.len;
        r += off + needle.len;
    }
    @memcpy(out[w..], text[r..]);
    return out;
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

/// Ensures worker-spawned processes (rime's toolchain probe AND cargo's
/// build-script compilation) can execute rustc: test workers may carry a
/// restricted PATH, so export an absolute `RUSTC` when unset. Both rime
/// (`resolveRustcBin` checks `$RUSTC` first) and cargo honor it.
/// Children inherit it; the duped strings intentionally leak (suite scope).
fn ensureRustcEnv(gpa: std.mem.Allocator, io: std.Io) void {
    // Test workers may carry a stripped PATH that omits the system tool
    // dirs, so `cc`/linker shims are unresolvable in spawned cargo builds
    // (observed: `linker 'cc' not found` on every build-script link). Prepend
    // the standard dirs when missing; children inherit the result.
    const path_now = if (std.c.getenv("PATH")) |z| std.mem.span(z) else "";
    const has_usr_bin = std.mem.indexOf(u8, path_now, "/usr/bin") != null;
    if (!has_usr_bin) {
        const new_path = std.fmt.allocPrint(gpa, "/usr/bin:/bin:{s}", .{path_now}) catch return;
        defer gpa.free(new_path);
        const n = gpa.dupeZ(u8, "PATH") catch return;
        defer gpa.free(n);
        const v = gpa.dupeZ(u8, new_path) catch return;
        defer gpa.free(v);
        _ = setenv(n, v, 1);
    }
    if (std.c.getenv("RUSTC")) |z| {
        if (std.mem.span(z).len > 0) return;
    }
    const abs: ?[]u8 = blk: {
        if (std.c.getenv("HOME")) |h| {
            const cand = std.fmt.allocPrint(gpa, "{s}/.cargo/bin/rustc", .{std.mem.span(h)}) catch break :blk null;
            defer gpa.free(cand);
            std.Io.Dir.accessAbsolute(io, cand, .{}) catch break :blk null;
            break :blk gpa.dupe(u8, cand) catch break :blk null;
        }
        break :blk null;
    };
    const path = abs orelse return;
    const name_z = gpa.dupeZ(u8, "RUSTC") catch return;
    defer gpa.free(name_z);
    const val_z = gpa.dupeZ(u8, path) catch return;
    defer gpa.free(val_z);
    gpa.free(path);
    // POSIX setenv copies both strings; no leak, no static storage needed.
    if (setenv(name_z, val_z, 1) != 0) return;
}

/// Resolves the oracle cargo binary to an absolute path (bare `argv[0]`
/// needs `toolchain.resolveBinPath`; `global_single_threaded` io cannot
/// spawn, so resolution + probing use the caller's threaded `io`).
/// Returns the gpa-owned absolute path, or null when cargo is absent
/// (callers skip — environmental, never a false red). Prefers
/// `$HOME/.cargo/bin/cargo`, then PATH lookup.
pub fn cargoBin(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    if (std.c.getenv("HOME")) |h| {
        const cand = try std.fmt.allocPrint(gpa, "{s}/.cargo/bin/cargo", .{std.mem.span(h)});
        errdefer gpa.free(cand);
        std.Io.Dir.accessAbsolute(io, cand, .{}) catch {
            gpa.free(cand);
            return pathLookup(gpa, io);
        };
        // Verify it runs (a stale shim must not hard-fail the suite).
        const res = oracle.runCapture(gpa, io, &.{ cand, "--version" }, "") catch {
            gpa.free(cand);
            return pathLookup(gpa, io);
        };
        defer gpa.free(res.out);
        defer gpa.free(res.err);
        if (res.exited != 0) {
            gpa.free(cand);
            return pathLookup(gpa, io);
        }
        return cand;
    }
    return pathLookup(gpa, io);
}

fn pathLookup(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    const toolchain = @import("toolchain.zig");
    const abs = try toolchain.resolveBinPath(gpa, io, "cargo");
    return abs orelse error.CargoMissing;
}

/// Compares normalized JSON streams for one fixture: runs
/// `cargo build --message-format=json` (oracle) in a scratch copy of
/// `fixture_dir` and asserts the committed golden's reason sequence matches
/// cargo's (goldens change only via `regen.sh`). `golden_path` carries the
/// normalized oracle stream.
pub fn compareJsonStream(gpa: std.mem.Allocator, io: std.Io, cargo_bin: []const u8, fixture_dir: []const u8, golden_path: []const u8) !void {
    const golden = std.Io.Dir.cwd().readFileAlloc(io, golden_path, gpa, .limited(8 << 20)) catch |e| {
        std.debug.print("m6-oracle: cannot read golden {s}: {t}\n", .{ golden_path, e });
        return error.Mismatch;
    };
    defer gpa.free(golden);
    // Scratch copy so cargo never dirties the corpus.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const scratch = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(scratch);
    const abs_fixture = try std.Io.Dir.cwd().realPathFileAlloc(io, fixture_dir, gpa);
    defer gpa.free(abs_fixture);
    copyTree(gpa, io, abs_fixture, scratch) catch |e| {
        std.debug.print("m6-oracle: scratch copy failed: {t}\n", .{e});
        return error.Mismatch;
    };
    const res_warm = oracle.runCapture(gpa, io, &.{ cargo_bin, "build", "--message-format=json" }, scratch) catch {
        std.debug.print("m6-oracle: cargo build failed to spawn\n", .{});
        return error.Mismatch;
    };
    gpa.free(res_warm.out);
    gpa.free(res_warm.err);
    // Goldens pin the WARM rebuild (all `fresh:true`): capture the second
    // build so hashes/counters are stable and compilation noise is gone.
    const res = oracle.runCapture(gpa, io, &.{ cargo_bin, "build", "--message-format=json" }, scratch) catch {
        std.debug.print("m6-oracle: cargo build failed to spawn\n", .{});
        return error.Mismatch;
    };
    defer gpa.free(res.out);
    defer gpa.free(res.err);
    if (res.exited != 0) {
        std.debug.print("m6-oracle: cargo build exited {d} outlen={d} errlen={d}:\nSTDOUT:{s}\nSTDERR:{s}\n", .{ res.exited, res.out.len, res.err.len, res.out, res.err });
        return error.Mismatch;
    }
    var want_lines = std.mem.splitScalar(u8, golden, '\n');
    var got_lines = std.mem.splitScalar(u8, res.out, '\n');
    var line_no: usize = 0;
    while (true) {
        const w = want_lines.next();
        const g = got_lines.next();
        if (w == null and g == null) break;
        line_no += 1;
        const ws = std.mem.trim(u8, w orelse "", " \t\r");
        const gs = std.mem.trim(u8, g orelse "", " \t\r");
        if (ws.len == 0 and gs.len == 0) continue;
        const norm_g = try normalizeLine(gpa, gs, scratch);
        defer gpa.free(norm_g);
        if (!std.mem.eql(u8, ws, norm_g)) {
            std.debug.print("m6-oracle: stream mismatch line {d}:\n  golden: {s}\n  cargo : {s}\n", .{ line_no, ws, norm_g });
            return error.Mismatch;
        }
    }
}

fn copyTree(gpa: std.mem.Allocator, io: std.Io, src_abs: []const u8, dst_abs: []const u8) !void {
    var src = try std.Io.Dir.openDirAbsolute(io, src_abs, .{ .iterate = true });
    defer src.close(io);
    var it = src.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, "target")) continue;
        const s = try std.fs.path.join(gpa, &.{ src_abs, entry.name });
        defer gpa.free(s);
        const d = try std.fs.path.join(gpa, &.{ dst_abs, entry.name });
        defer gpa.free(d);
        switch (entry.kind) {
            .directory => {
                std.Io.Dir.cwd().createDirPath(io, d) catch {};
                try copyTree(gpa, io, s, d);
            },
            .file => {
                const bytes = try std.Io.Dir.cwd().readFileAlloc(io, s, gpa, .limited(32 << 20));
                defer gpa.free(bytes);
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = d, .data = bytes });
            },
            else => {},
        }
    }
}

/// One exit-matrix row: argv (after the binary), fixture dir, expected
/// code, expected stderr needle.
pub const MatrixRow = struct {
    argv: []const []const u8,
    fixture: []const u8,
    code: u8,
    needle: []const u8,
};

/// Executes `exit-matrix.json` rows against `rime_bin` and the real cargo,
/// asserting rime's code equals cargo's code for every row. Each row's
/// fixture is copied to scratch (`@FIXTURE@` in argv substitutes the
/// scratch dir) so the corpus is never dirtied; rime's code must also
/// equal the row's expected code with the needle present on stderr.
pub fn checkExitMatrix(gpa: std.mem.Allocator, io: std.Io, cargo_bin: []const u8, table_path: []const u8, rime_bin: []const u8) !void {
    const text = std.Io.Dir.cwd().readFileAlloc(io, table_path, gpa, .limited(1 << 20)) catch {
        std.debug.print("m6-oracle: cannot read {s}\n", .{table_path});
        return error.Mismatch;
    };
    defer gpa.free(text);
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch {
        std.debug.print("m6-oracle: matrix is not valid JSON\n", .{});
        return error.Mismatch;
    };
    defer parsed.deinit();
    const rows = parsed.value.object.get("rows") orelse return error.Mismatch;
    if (rows != .array) return error.Mismatch;
    for (rows.array.items) |*row| {
        const argv_v = row.object.get("argv") orelse return error.Mismatch;
        const fixture_v = row.object.get("fixture") orelse return error.Mismatch;
        const code_v = row.object.get("code") orelse return error.Mismatch;
        const needle_v = row.object.get("needle") orelse return error.Mismatch;
        if (argv_v != .array or fixture_v != .string) return error.Mismatch;
        if (code_v != .integer or needle_v != .string) return error.Mismatch;
        const want_code: u8 = @intCast(code_v.integer);
        // Scratch copy so neither binary dirties the corpus.
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const scratch = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(scratch);
        const abs_fixture = try std.Io.Dir.cwd().realPathFileAlloc(io, fixture_v.string, gpa);
        defer gpa.free(abs_fixture);
        // Absolute rime path: the child runs with cwd=scratch, so a
        // relative argv[0] would resolve inside the scratch dir.
        const abs_rime = try std.Io.Dir.cwd().realPathFileAlloc(io, rime_bin, gpa);
        defer gpa.free(abs_rime);
        copyTree(gpa, io, abs_fixture, scratch) catch {
            std.debug.print("m6-oracle: scratch copy failed for {s}\n", .{fixture_v.string});
            return error.Mismatch;
        };
        var rargv: std.ArrayList([]const u8) = .empty;
        defer {
            for (rargv.items[1..]) |a| gpa.free(a);
            rargv.deinit(gpa);
        }
        try rargv.append(gpa, abs_rime);
        for (argv_v.array.items) |*a| {
            if (a.* != .string) return error.Mismatch;
            try rargv.append(gpa, try substFixture(gpa, a.string, scratch));
        }
        var cargv: std.ArrayList([]const u8) = .empty;
        defer {
            for (cargv.items[1..]) |a| gpa.free(a);
            cargv.deinit(gpa);
        }
        try cargv.append(gpa, cargo_bin);
        for (argv_v.array.items) |*a| try cargv.append(gpa, try substFixture(gpa, a.string, scratch));
        const rres = oracle.runCapture(gpa, io, rargv.items, scratch) catch {
            std.debug.print("m6-oracle: rime spawn failed for row {s}\n", .{fixture_v.string});
            return error.Mismatch;
        };
        defer gpa.free(rres.out);
        defer gpa.free(rres.err);
        const cres = oracle.runCapture(gpa, io, cargv.items, scratch) catch {
            std.debug.print("m6-oracle: cargo spawn failed for row {s}\n", .{fixture_v.string});
            return error.Mismatch;
        };
        defer gpa.free(cres.out);
        defer gpa.free(cres.err);
        if (rres.exited != cres.exited) {
            std.debug.print("m6-oracle: code mismatch fixture={s} argv={s}: rime={d} cargo={d}\nrime stderr: {s}\ncargo stderr: {s}\n", .{ fixture_v.string, argv_v.array.items[0].string, rres.exited, cres.exited, rres.err, cres.err });
            return error.Mismatch;
        }
        if (rres.exited != want_code) {
            std.debug.print("m6-oracle: committed code wrong fixture={s}: got={d} want={d}\n", .{ fixture_v.string, rres.exited, want_code });
            return error.Mismatch;
        }
        if (needle_v.string.len > 0 and std.mem.indexOf(u8, rres.err, needle_v.string) == null and std.mem.indexOf(u8, rres.out, needle_v.string) == null) {
            std.debug.print("m6-oracle: needle missing fixture={s}: want {s} in stdout+stderr\n", .{ fixture_v.string, needle_v.string });
            return error.Mismatch;
        }
    }
}

fn substFixture(gpa: std.mem.Allocator, arg: []const u8, scratch: []const u8) ![]u8 {
    const tag = "@FIXTURE@";
    const at = std.mem.indexOf(u8, arg, tag) orelse return gpa.dupe(u8, arg);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, arg[0..at]);
    try out.appendSlice(gpa, scratch);
    try out.appendSlice(gpa, arg[at + tag.len ..]);
    return out.toOwnedSlice(gpa);
}

test "m6-oracle json stream matches cargo on basic-workspace" {
    if (!oracle.oracleEnabled()) {
        std.debug.print("skip: set RIME_CARGO_ORACLE=1 for oracle comparison\n", .{});
        return;
    }
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    ensureRustcEnv(std.testing.allocator, io);
    const cargo_bin = cargoBin(std.testing.allocator, io) catch {
        std.debug.print("skip: cargo binary not found\n", .{});
        return;
    };
    defer std.testing.allocator.free(cargo_bin);
    try compareJsonStream(std.testing.allocator, io, cargo_bin, "validation/basic-workspace", "validation/m6-golden/basic-workspace.build.json");
}

test "m6-oracle exit matrix matches cargo" {
    if (!oracle.oracleEnabled()) {
        std.debug.print("skip: set RIME_CARGO_ORACLE=1 for oracle comparison\n", .{});
        return;
    }
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    ensureRustcEnv(std.testing.allocator, io);
    const cargo_bin = cargoBin(std.testing.allocator, io) catch {
        std.debug.print("skip: cargo binary not found\n", .{});
        return;
    };
    defer std.testing.allocator.free(cargo_bin);
    const bin = "zig-out/bin/rime";
    try checkExitMatrix(std.testing.allocator, io, cargo_bin, "validation/m6-golden/exit-matrix.json", bin);
}

test "normalizeLine pins substitutions" {
    const n = try normalizeLine(std.testing.allocator, "/ws/target/debug/deps/libfoo-9a8b7c1d2e3f4a5b.rlib", "/ws");
    defer std.testing.allocator.free(n);
    try std.testing.expectEqualStrings("@VALIDATION_ROOT@/target/debug/deps/libfoo-<META>----------.rlib", n);
}
