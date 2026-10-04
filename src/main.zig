const std = @import("std");
const store = @import("store");

pub fn main(init: std.process.Init) !u8 {
    _ = init;
    const d = store.hashBytes("rime");
    std.debug.print("rime storage core {s}\n", .{&d.toHex()});
    return 0;
}
