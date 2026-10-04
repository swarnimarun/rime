const std = @import("std");

fn addSqlite3(m: *std.Build.Module, b: *std.Build) void {
    m.addCSourceFile(.{
        .file = b.path("vendor/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_DEFAULT_JOURNAL_MODE=WAL",
            "-DSQLITE_DEFAULT_SYNCHRONOUS=1",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-O2",
        },
    });
    m.addIncludePath(b.path("vendor"));
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const store_mod = b.createModule(.{
        .root_source_file = b.path("src/store/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const tests = b.addTest(.{ .root_module = store_mod });
    addSqlite3(store_mod, b);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "store", .module = store_mod }},
    });
    const exe = b.addExecutable(.{ .name = "rime", .root_module = exe_mod });
    // NOTE: sqlite3 is wired only into store_mod (index.zig owns every
    // sqlite3_* call). exe_mod imports store_mod, so a second
    // addSqlite3(exe_mod, b) would compile sqlite3.c twice into one
    // binary and fail with duplicate symbols.
    b.installArtifact(exe);

    // CLI unit tests live inline in src/main.zig (parseCommand surface).
    const exe_tests = b.addTest(.{ .root_module = exe_mod });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    test_step.dependOn(&run_exe_tests.step);
}
