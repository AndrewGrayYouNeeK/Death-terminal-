//! Project key for a working directory: the nearest parent that contains
//! `.git` (directory or file), otherwise the directory itself. No network.

const std = @import("std");

pub fn into(cwd: []const u8, buf: []u8) ?[]const u8 {
    const trimmed = trimSep(std.mem.trim(u8, cwd, " \t"));
    if (trimmed.len == 0 or trimmed.len >= buf.len) return null;
    @memcpy(buf[0..trimmed.len], trimmed);
    if (!exists(buf[0..trimmed.len])) return buf[0..trimmed.len];
    var len = trimmed.len;
    var hops: u8 = 0;
    while (hops < 48) : (hops += 1) {
        if (hasGit(buf[0..len])) return buf[0..len];
        const parent = std.fs.path.dirname(buf[0..len]) orelse return buf[0..trimmed.len];
        if (parent.len == 0 or parent.len == len) return buf[0..trimmed.len];
        len = parent.len;
    }
    return buf[0..trimmed.len];
}

pub fn alloc(a: std.mem.Allocator, cwd: []const u8) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const key = into(cwd, &buf) orelse return a.dupe(u8, "");
    return a.dupe(u8, key);
}

fn trimSep(s: []const u8) []const u8 {
    if (s.len <= 1) return s;
    var n = s.len;
    while (n > 1 and (s[n - 1] == '/' or s[n - 1] == '\\')) n -= 1;
    return s[0..n];
}

fn exists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn hasGit(dir: []const u8) bool {
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const git = std.fmt.bufPrint(&path, "{s}{c}.git", .{ dir, std.fs.path.sep }) catch return false;
    return exists(git);
}

test "missing directory is its own project" {
    var buf: [64]u8 = undefined;
    const key = into("/no/such/muscle-project-zz", &buf).?;
    try std.testing.expectEqualStrings("/no/such/muscle-project-zz", key);
    try std.testing.expect(into("", &buf) == null);
    try std.testing.expect(into("   ", &buf) == null);
}

test "nearest .git directory or file is the project" {
    const util = @import("../testutil.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("repo/sub/deep");
    try tmp.dir.makeDir("repo/.git");
    try tmp.dir.makePath("wt/sub");
    try tmp.dir.writeFile(.{ .sub_path = "wt/.git", .data = "gitdir: /elsewhere\n" });
    const repo_sub = try util.tmpPath(std.testing.allocator, &tmp, "repo/sub/deep");
    defer std.testing.allocator.free(repo_sub);
    const repo = try util.tmpPath(std.testing.allocator, &tmp, "repo");
    defer std.testing.allocator.free(repo);
    const wt_sub = try util.tmpPath(std.testing.allocator, &tmp, "wt/sub");
    defer std.testing.allocator.free(wt_sub);
    const wt = try util.tmpPath(std.testing.allocator, &tmp, "wt");
    defer std.testing.allocator.free(wt);

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(repo, into(repo_sub, &buf).?);
    try std.testing.expectEqualStrings(wt, into(wt_sub, &buf).?);
}
