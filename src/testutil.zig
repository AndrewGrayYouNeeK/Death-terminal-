//! Helpers shared by unit tests.

const std = @import("std");
const builtin = @import("builtin");

/// Absolute path of `sub` inside a testing TmpDir.
///
/// POSIX: `realpath`. Windows: joins the process cwd with the TmpDir's known
/// location (`.zig-cache/tmp/<sub_path>`). Zig's Windows realpath goes through
/// the mount manager (IOCTL_MOUNTMGR_QUERY_POINTS), and Wine doesn't implement
/// that, so it returns error.Unexpected there. The cwd join gives the same
/// answer on real Windows without the dependency.
pub fn tmpPath(a: std.mem.Allocator, tmp: *const std.testing.TmpDir, sub: []const u8) ![]u8 {
    if (builtin.os.tag != .windows) return tmp.dir.realpathAlloc(a, sub);
    return cwdPath(a, &.{ ".zig-cache", "tmp", &tmp.sub_path, sub });
}

/// Absolute path of `parts` relative to the process cwd (see `tmpPath`).
pub fn cwdPath(a: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    if (builtin.os.tag != .windows) {
        const rel = try std.fs.path.join(a, parts);
        defer a.free(rel);
        return std.fs.cwd().realpathAlloc(a, rel);
    }
    const cwd = try std.process.getCwdAlloc(a);
    defer a.free(cwd);
    var all = std.ArrayList([]const u8).init(a);
    defer all.deinit();
    try all.append(cwd);
    try all.appendSlice(parts);
    const p = try std.fs.path.resolve(a, all.items);
    errdefer a.free(p);
    std.fs.cwd().access(p, .{}) catch |e| return e;
    return p;
}

test "tmpPath points into the TmpDir" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "f.txt", .data = "hi" });
    const p = try tmpPath(std.testing.allocator, &tmp, "f.txt");
    defer std.testing.allocator.free(p);
    try std.testing.expect(std.fs.path.isAbsolute(p));
    const f = try std.fs.openFileAbsolute(p, .{});
    defer f.close();
    var buf: [4]u8 = undefined;
    try std.testing.expectEqualStrings("hi", buf[0..try f.readAll(&buf)]);
}
