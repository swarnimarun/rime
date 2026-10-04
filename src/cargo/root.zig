/// Cargo-compatible frontend (Plan C). Each submodule is imported by path
/// from its siblings (e.g. `@import("toml.zig")`); this root only re-exports
/// them under one module for the exe (`@import("cargo").cli, …`).
pub const toml = @import("toml.zig");
pub const manifest = @import("manifest.zig");
pub const lock = @import("lock.zig");
pub const workspace = @import("workspace.zig");
pub const view = @import("view.zig");
pub const cli = @import("cli.zig");
pub const fetch = @import("fetch.zig");
pub const semver = @import("semver.zig");
pub const index = @import("index.zig");
pub const resolve = @import("resolve.zig");
pub const sources = @import("sources.zig");
pub const features = @import("features.zig");
pub const oracle = @import("oracle.zig");
pub const toolchain = @import("toolchain.zig");
pub const profile = @import("profile.zig");
pub const driver = @import("driver.zig");
pub const fingerprint = @import("fingerprint.zig");
pub const actionkey = @import("actionkey.zig");
pub const invoke = @import("invoke.zig");
pub const compile = @import("compile.zig");
pub const pipeline = @import("pipeline.zig");

// Same pattern as src/store/root.zig: referencing each submodule from a
// test block pulls its inline `test "…"` blocks into `zig build test`.
test {
    _ = @import("toml.zig");
    _ = @import("manifest.zig");
    _ = @import("lock.zig");
    _ = @import("workspace.zig");
    _ = @import("view.zig");
    _ = @import("cli.zig");
    _ = @import("fetch.zig");
    _ = @import("semver.zig");
    _ = @import("index.zig");
    _ = @import("resolve.zig");
    _ = @import("sources.zig");
    _ = @import("features.zig");
    _ = @import("oracle.zig");
    _ = @import("toolchain.zig");
    _ = @import("profile.zig");
    _ = @import("driver.zig");
    _ = @import("fingerprint.zig");
    _ = @import("actionkey.zig");
    _ = @import("invoke.zig");
    _ = @import("compile.zig");
    _ = @import("pipeline.zig");
}
