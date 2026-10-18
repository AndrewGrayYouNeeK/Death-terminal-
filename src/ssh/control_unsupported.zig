//! Stand-in for control.zig where the built-in SSH client isn't built
//! (Windows, macOS for now): every request fails.

const std = @import("std");

pub fn request(pid: anytype, cmd: []const u8, out: []u8) ![]const u8 {
    _ = pid;
    _ = cmd;
    _ = out;
    return error.SshUnsupported;
}
