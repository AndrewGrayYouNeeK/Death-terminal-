//! Saved window layout. One text file, rewritten when the tabs or splits
//! change, and read on the next start when config.lua has no `layout`.
//!
//! ```
//! tab
//! split right 0.50
//! leaf ssh=box cwd=/tmp
//! leaf ssh= cwd=
//! tab
//! leaf ssh= cwd=/home/me
//! ```
//!
//! A `split` is followed by its two children. `ssh` and `cwd` may be empty.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config/config.zig");
const env_mod = @import("../platform/env.zig");

pub fn sessionPath(a: std.mem.Allocator) ![]u8 {
    const win = builtin.os.tag == .windows;
    const home = (if (win) env_mod.get("USERPROFILE") orelse env_mod.get("HOME") else env_mod.get("HOME")) orelse return error.NoHome;
    const local = if (win) env_mod.get("LOCALAPPDATA") else null;
    const state_home = if (local) |x| try a.dupe(u8, x) else blk: {
        if (env_mod.get("XDG_STATE_HOME")) |v| if (v.len > 0 and std.fs.path.isAbsolute(v)) break :blk try a.dupe(u8, v);
        break :blk try std.fs.path.join(a, &.{ home, ".local/state" });
    };
    defer a.free(state_home);
    return std.fs.path.join(a, &.{ state_home, "death-terminal", "layout.txt" });
}

pub fn parse(cfg: *config.Config, text: []const u8) !void {
    var lines_buf: [256][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (n == lines_buf.len) return error.TooManyLines;
        lines_buf[n] = line;
        n += 1;
    }
    var lines = lines_buf[0..n];
    while (lines.len > 0) {
        if (!std.mem.eql(u8, lines[0], "tab")) return error.BadLayout;
        lines = lines[1..];
        const root = try parseNode(cfg, &lines);
        try cfg.startup_layout.append(.{ .root = root });
    }
}

fn parseNode(cfg: *config.Config, lines: *[]const []const u8) !config.LayoutNode {
    if (lines.len == 0) return error.BadLayout;
    const line = lines.*[0];
    lines.* = lines.*[1..];
    if (std.mem.startsWith(u8, line, "leaf")) {
        return .{
            .ssh = try cfg.dupe(field(line, "ssh=")),
            .cwd = try cfg.dupe(restField(line, "cwd=")),
        };
    }
    if (std.mem.startsWith(u8, line, "split ")) {
        var parts = std.mem.tokenizeScalar(u8, line, ' ');
        _ = parts.next();
        const dir_s = parts.next() orelse return error.BadLayout;
        const ratio_s = parts.next() orelse return error.BadLayout;
        const ratio = std.fmt.parseFloat(f32, ratio_s) catch 0.5;
        const a = try parseNode(cfg, lines);
        const b = try parseNode(cfg, lines);
        const kids = try cfg.arena.allocator().alloc(config.LayoutNode, 2);
        kids[0] = a;
        kids[1] = b;
        var node = config.LayoutNode{ .ratio = ratio, .children = kids };
        node.split = if (std.mem.eql(u8, dir_s, "down")) .down else .right;
        return node;
    }
    return error.BadLayout;
}

fn restField(line: []const u8, key: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, line, key) orelse return "";
    return line[at + key.len ..];
}

fn field(line: []const u8, key: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, line, key) orelse return "";
    const rest = line[at + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    return rest[0..end];
}

pub fn formatLeaf(buf: []u8, ssh: []const u8, cwd: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "leaf ssh={s} cwd={s}\n", .{ ssh, cwd }) catch "leaf ssh= cwd=\n";
}

test "layout file round trip" {
    var cfg = config.Config.init(std.testing.allocator);
    defer cfg.deinit();
    const text =
        \\tab
        \\split right 0.50
        \\leaf ssh=box cwd=/tmp
        \\leaf ssh= cwd=
        \\tab
        \\leaf ssh= cwd=/home/me
        \\
    ;
    try parse(&cfg, text);
    try std.testing.expectEqual(@as(usize, 2), cfg.startup_layout.items.len);
    const root = cfg.startup_layout.items[0].root;
    try std.testing.expect(root.split.? == .right);
    try std.testing.expectEqualStrings("box", root.children[0].ssh);
    try std.testing.expectEqualStrings("/tmp", root.children[0].cwd);
    try std.testing.expectEqualStrings("", root.children[1].ssh);
    try std.testing.expectEqualStrings("/home/me", cfg.startup_layout.items[1].root.cwd);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("leaf ssh=box cwd=/tmp\n", formatLeaf(&buf, "box", "/tmp"));
}
