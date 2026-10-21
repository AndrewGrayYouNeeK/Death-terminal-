//! Plugins shipped inside the binary. `plan` writes them next to the plugin
//! data directory and loads any the user has not installed themselves.
//! YouNeeK Time is one of them, so a fresh config shows its clock.

const std = @import("std");
const embedded = @import("youneek_plugin");

pub const youneek_name = "youneek-time";

const manifest_lua = embedded.manifest;
const init_lua = embedded.init;
const clock_lua = embedded.clock;
const moon_lua = embedded.moon;

const sep = std.fs.path.sep_str;

const File = struct {
    rel: []const u8,
    data: []const u8,
};

const youneek_files = [_]File{
    .{ .rel = "manifest.lua", .data = manifest_lua },
    .{ .rel = "init.lua", .data = init_lua },
    .{ .rel = "lib" ++ sep ++ "clock.lua", .data = clock_lua },
    .{ .rel = "lib" ++ sep ++ "moon.lua", .data = moon_lua },
};

/// Parent directory that holds `<name>/`. Sibling of the plugin data root
/// (`…/death-terminal/bundled-plugins`).
pub fn rootFromData(a: std.mem.Allocator, data_root: []const u8) ![]u8 {
    const parent = std.fs.path.dirname(data_root) orelse ".";
    return std.fs.path.join(a, &.{ parent, "bundled-plugins" });
}

/// Write the embedded YouNeeK Time plugin under `root` if the bytes differ.
pub fn materialize(root: []const u8) !void {
    var dir = try std.fs.cwd().makeOpenPath(root, .{});
    defer dir.close();
    var sub = try dir.makeOpenPath(youneek_name, .{});
    defer sub.close();
    try sub.makePath("lib");
    for (youneek_files) |f| try writeIfChanged(&sub, f.rel, f.data);
}

fn writeIfChanged(dir: *std.fs.Dir, rel: []const u8, data: []const u8) !void {
    const existing = dir.readFileAlloc(std.heap.page_allocator, rel, data.len + 64) catch null;
    if (existing) |buf| {
        defer std.heap.page_allocator.free(buf);
        if (std.mem.eql(u8, buf, data)) return;
    }
    try dir.writeFile(.{ .sub_path = rel, .data = data });
}
