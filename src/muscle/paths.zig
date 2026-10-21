//! Local files for muscle memory. Nothing here touches the network.
//!
//!   shortcuts   $XDG_CONFIG_HOME/death-terminal/shortcuts.lua
//!               (default ~/.config/death-terminal/shortcuts.lua;
//!               %APPDATA%\death-terminal\shortcuts.lua on Windows)
//!   history     $XDG_STATE_HOME/death-terminal/muscle-history
//!   dismissed   $XDG_STATE_HOME/death-terminal/muscle-dismissed

const std = @import("std");
const builtin = @import("builtin");
const env_mod = @import("../platform/env.zig");

pub const Resolved = struct {
    shortcuts: []u8,
    history: []u8,
    dismissed: []u8,

    pub fn deinit(self: *Resolved, a: std.mem.Allocator) void {
        a.free(self.shortcuts);
        a.free(self.history);
        a.free(self.dismissed);
    }
};

pub fn resolve(a: std.mem.Allocator) !Resolved {
    const win = builtin.os.tag == .windows;
    const home = (if (win) env_mod.get("USERPROFILE") orelse env_mod.get("HOME") else env_mod.get("HOME")) orelse return error.NoHome;
    const config_home = if (win)
        if (env_mod.get("APPDATA")) |x| try a.dupe(u8, x) else try xdg(a, "XDG_CONFIG_HOME", home, ".config")
    else
        try xdg(a, "XDG_CONFIG_HOME", home, ".config");
    defer a.free(config_home);
    const local = if (win) env_mod.get("LOCALAPPDATA") else null;
    const state_home = if (local) |x| try a.dupe(u8, x) else try xdg(a, "XDG_STATE_HOME", home, ".local/state");
    defer a.free(state_home);
    const config_dir = try std.fs.path.join(a, &.{ config_home, "death-terminal" });
    defer a.free(config_dir);
    const state_dir = try std.fs.path.join(a, &.{ state_home, "death-terminal" });
    defer a.free(state_dir);
    return .{
        .shortcuts = try std.fs.path.join(a, &.{ config_dir, "shortcuts.lua" }),
        .history = try std.fs.path.join(a, &.{ state_dir, "muscle-history" }),
        .dismissed = try std.fs.path.join(a, &.{ state_dir, "muscle-dismissed" }),
    };
}

fn xdg(a: std.mem.Allocator, name: []const u8, home: []const u8, fallback: []const u8) ![]u8 {
    if (env_mod.get(name)) |v| if (v.len > 0 and std.fs.path.isAbsolute(v)) return a.dupe(u8, v);
    return std.fs.path.join(a, &.{ home, fallback });
}

/// Replace `path`, creating parent directories. The file is mode 0600 on POSIX.
pub fn replaceFile(path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try std.fs.cwd().makePath(d);
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path}) catch return error.NameTooLong;
    {
        var f = try std.fs.cwd().createFile(tmp, .{
            .truncate = true,
            .mode = if (builtin.os.tag == .windows) 0 else 0o600,
        });
        defer f.close();
        try f.writeAll(data);
    }
    std.fs.cwd().rename(tmp, path) catch {
        std.fs.cwd().deleteFile(path) catch {};
        try std.fs.cwd().rename(tmp, path);
    };
}

pub fn readFile(a: std.mem.Allocator, path: []const u8, max: usize) !?[]u8 {
    const data = std.fs.cwd().readFileAlloc(a, path, max) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return data;
}
