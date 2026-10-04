/// Cargo-compatible frontend (Plan C). Each submodule is imported by path
/// from its siblings (e.g. `@import("toml.zig")`); this root only re-exports
/// them under one module for the exe (`@import("cargo").cli, …`).
pub const toml = @import("toml.zig");
pub const manifest = @import("manifest.zig");
pub const lock = @import("lock.zig");
pub const workspace = @import("workspace.zig");
pub const view = @import("view.zig");
pub const cli = @import("cli.zig");

// Same pattern as src/store/root.zig: referencing each submodule from a
// test block pulls its inline `test "…"` blocks into `zig build test`.
test {
    _ = @import("toml.zig");
    _ = @import("manifest.zig");
    _ = @import("lock.zig");
    _ = @import("workspace.zig");
    _ = @import("view.zig");
    _ = @import("cli.zig");
}
