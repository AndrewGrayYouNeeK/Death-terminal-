//! Stand-in for client.zig on targets where build.zig doesn't build
//! libssh2 (everything but Linux for now).
const std = @import("std");

pub fn main(a: std.mem.Allocator, args: []const []const u8) u8 {
    _ = a;
    _ = args;
    std.debug.print("deathterminal: the built-in SSH client is only available on Linux builds for now\n", .{});
    return 255;
}

pub fn libssh2Version() []const u8 {
    return "unavailable on this platform";
}
