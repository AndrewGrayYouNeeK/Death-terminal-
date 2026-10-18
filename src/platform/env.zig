//! Environment variables as UTF-8 on every platform. On Windows the
//! environment is UTF-16, so it is converted once (on first use) and the
//! snapshot is kept for the life of the process, like `posix.getenv`'s
//! pointers into `environ`.

const std = @import("std");
const builtin = @import("builtin");

var map: ?std.process.EnvMap = null;
var lock: std.Thread.Mutex = .{};

pub fn get(name: []const u8) ?[]const u8 {
    if (builtin.os.tag != .windows) return std.posix.getenv(name);
    lock.lock();
    defer lock.unlock();
    if (map == null) map = std.process.getEnvMap(std.heap.page_allocator) catch return null;
    return map.?.get(name);
}

/// $HOME, or %USERPROFILE% on Windows.
pub fn home() ?[]const u8 {
    if (builtin.os.tag == .windows) return get("USERPROFILE") orelse get("HOME");
    return get("HOME");
}

test "env get" {
    try std.testing.expect(get("PATH") != null);
    try std.testing.expect(get("DT_SURELY_NOT_SET_ANYWHERE") == null);
}
