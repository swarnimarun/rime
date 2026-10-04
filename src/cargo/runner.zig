//! Process-forwarding seam for run/test/bench (M6 Task 4).
//!
//! `Runner` is a function-pointer seam (the `fetch.zig` `GitRunner`
//! precedent) so dispatch is unit-testable without spawning. `LiveRunner`
//! spawns with explicit inherit stdio (passthrough, never captured);
//! `FakeRunner` asserts argv elementwise and returns a canned outcome.

const std = @import("std");

pub const TermTag = enum { exited, signaled, spawn_failed };
pub const RunOutcome = struct { term: TermTag, code: u8 };

pub const Runner = struct {
    ptr: *anyopaque,
    runFn: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) RunOutcome,

    pub fn run(self: Runner, gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) RunOutcome {
        return self.runFn(self.ptr, gpa, io, argv);
    }
};

pub const LiveRunner = struct {
    pub fn runner(self: *LiveRunner) Runner {
        return .{ .ptr = self, .runFn = liveRun };
    }

    fn liveRun(ptr: *anyopaque, gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) RunOutcome {
        _ = ptr;
        _ = gpa;
        if (argv.len == 0) return .{ .term = .spawn_failed, .code = 101 };
        var child = std.process.spawn(io, .{
            .argv = argv,
            .stdin = .inherit,
            .stdout = .inherit,
            .stderr = .inherit,
        }) catch return .{ .term = .spawn_failed, .code = 101 };
        defer child.kill(io);
        const term = child.wait(io) catch return .{ .term = .signaled, .code = 101 };
        return switch (term) {
            .exited => |c| .{ .term = .exited, .code = c },
            .signal, .stopped, .unknown => .{ .term = .signaled, .code = 101 },
        };
    }
};

pub const FakeRunner = struct {
    expected_argv: []const []const u8,
    outcome: RunOutcome,
    calls: u32,

    pub fn runner(self: *FakeRunner) Runner {
        return .{ .ptr = self, .runFn = fakeRun };
    }

    fn fakeRun(ptr: *anyopaque, gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) RunOutcome {
        _ = gpa;
        _ = io;
        const self: *FakeRunner = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        if (argv.len != self.expected_argv.len) return .{ .term = .spawn_failed, .code = 101 };
        for (argv, self.expected_argv) |got, want| {
            if (!std.mem.eql(u8, got, want)) return .{ .term = .spawn_failed, .code = 101 };
        }
        return self.outcome;
    }
};

/// Resolves the harness path from a unit's `filenames`: borrows the entry
/// whose basename starts with `"<target_name>-"`. Null on no match. M6
/// never re-synthesizes the filename from profile_dir+name — the metadata
/// hash is only known to the plan.
pub fn selectTestBinary(filenames: []const []const u8, target_name: []const u8) ?[]const u8 {
    for (filenames) |f| {
        const base = std.fs.path.basename(f);
        if (base.len <= target_name.len) continue;
        if (!std.mem.startsWith(u8, base, target_name)) continue;
        if (base[target_name.len] != '-') continue;
        return f;
    }
    // Exact-name fallback (unhashed dev binaries such as `target/debug/foo`).
    for (filenames) |f| {
        if (std.mem.eql(u8, std.fs.path.basename(f), target_name)) return f;
    }
    return null;
}

test "fake runner records argv and returns outcome" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var fake = FakeRunner{ .expected_argv = &.{ "/bin/echo", "hi" }, .outcome = .{ .term = .exited, .code = 0 }, .calls = 0 };
    const r = fake.runner();
    const got = r.run(std.testing.allocator, io, &.{ "/bin/echo", "hi" });
    try std.testing.expectEqual(@as(u8, 0), got.code);
    try std.testing.expectEqual(@as(u32, 1), fake.calls);
}

test "fake runner mismatched argv reads as spawn failure" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var fake = FakeRunner{ .expected_argv = &.{"/bin/echo"}, .outcome = .{ .term = .exited, .code = 0 }, .calls = 0 };
    const got = fake.runner().run(std.testing.allocator, io, &.{"/bin/other"});
    try std.testing.expect(got.term == .spawn_failed);
}

test "selectTestBinary matches hashed names and exact fallback" {
    const files = [_][]const u8{ "/w/target/debug/deps/foo-9a8b7c", "/w/target/debug/deps/libbar-1234.rlib" };
    try std.testing.expectEqualStrings("/w/target/debug/deps/foo-9a8b7c", selectTestBinary(&files, "foo").?);
    try std.testing.expect(selectTestBinary(&files, "nope") == null);
    const exact = [_][]const u8{"/w/target/debug/tool"};
    try std.testing.expectEqualStrings("/w/target/debug/tool", selectTestBinary(&exact, "tool").?);
}
