//! Last interactive UI choices: font size (from zoom) and theme name.
//! Stored at `$XDG_STATE_HOME/death-terminal/ui.txt`
//! (default `~/.local/state/death-terminal/ui.txt`). These win over
//! config.lua on the next start. `--font-size` still wins over the file.

const std = @import("std");
const builtin = @import("builtin");
const env_mod = @import("../platform/env.zig");
const config = @import("../config/config.zig");

pub const Prefs = struct {
    font_size: ?f32 = null,
    theme: ?[]u8 = null,

    pub fn deinit(self: *Prefs, a: std.mem.Allocator) void {
        if (self.theme) |t| a.free(t);
        self.* = .{};
    }
};

pub fn statePath(a: std.mem.Allocator) ![]u8 {
    const win = builtin.os.tag == .windows;
    const home = (if (win) env_mod.get("USERPROFILE") orelse env_mod.get("HOME") else env_mod.get("HOME")) orelse return error.NoHome;
    const local = if (win) env_mod.get("LOCALAPPDATA") else null;
    const state_home = if (local) |x| try a.dupe(u8, x) else blk: {
        if (env_mod.get("XDG_STATE_HOME")) |v| if (v.len > 0 and std.fs.path.isAbsolute(v)) break :blk try a.dupe(u8, v);
        break :blk try std.fs.path.join(a, &.{ home, ".local/state" });
    };
    defer a.free(state_home);
    return std.fs.path.join(a, &.{ state_home, "death-terminal", "ui.txt" });
}

pub fn parse(a: std.mem.Allocator, text: []const u8) !Prefs {
    var out = Prefs{};
    errdefer out.deinit(a);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "font_size")) {
            out.font_size = std.fmt.parseFloat(f32, value) catch continue;
        } else if (std.mem.eql(u8, key, "theme")) {
            if (out.theme) |old| a.free(old);
            out.theme = try a.dupe(u8, value);
        }
    }
    return out;
}

pub fn format(buf: []u8, font_size: f32, theme: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "font_size={d}\ntheme={s}\n", .{ font_size, theme }) catch buf[0..0];
}

pub fn load(a: std.mem.Allocator, path: []const u8) !?Prefs {
    const text = std.fs.cwd().readFileAlloc(a, path, 4096) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer a.free(text);
    return try parse(a, text);
}

pub fn save(path: []const u8, font_size: f32, theme: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try std.fs.cwd().makePath(d);
    var body: [256]u8 = undefined;
    const text = format(&body, font_size, theme);
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path}) catch return error.NameTooLong;
    {
        var f = try std.fs.cwd().createFile(tmp, .{ .truncate = true, .mode = if (builtin.os.tag == .windows) 0 else 0o600 });
        defer f.close();
        try f.writeAll(text);
    }
    std.fs.cwd().rename(tmp, path) catch {
        std.fs.cwd().deleteFile(path) catch {};
        try std.fs.cwd().rename(tmp, path);
    };
}

/// Apply a saved choice over config. `font_from_cli` keeps `--font-size`.
/// The theme name is copied into the config arena.
pub fn apply(cfg: *config.Config, prefs: Prefs, font_from_cli: bool) !void {
    if (!font_from_cli) if (prefs.font_size) |sz| {
        cfg.font_size = std.math.clamp(sz, 4, 96);
    };
    if (prefs.theme) |name| if (name.len > 0 and config.themes.find(name) != null) {
        cfg.theme = try cfg.dupe(name);
    };
}

test "prefs parse and format round trip" {
    const a = std.testing.allocator;
    var p = try parse(a, "font_size=13.5\ntheme=dracula\n");
    defer p.deinit(a);
    try std.testing.expectEqual(@as(f32, 13.5), p.font_size.?);
    try std.testing.expectEqualStrings("dracula", p.theme.?);
    var buf: [64]u8 = undefined;
    const text = format(&buf, 13.5, "dracula");
    var again = try parse(a, text);
    defer again.deinit(a);
    try std.testing.expectEqual(@as(f32, 13.5), again.font_size.?);
    try std.testing.expectEqualStrings("dracula", again.theme.?);
}

test "prefs apply keeps a CLI font size and a known theme" {
    var cfg = config.Config.init(std.testing.allocator);
    defer cfg.deinit();
    cfg.font_size = 11;
    const theme = try std.testing.allocator.dupe(u8, "nord");
    var prefs = Prefs{ .font_size = 18, .theme = theme };
    defer prefs.deinit(std.testing.allocator);
    try apply(&cfg, prefs, true);
    try std.testing.expectEqual(@as(f32, 11), cfg.font_size);
    try std.testing.expectEqualStrings("nord", cfg.theme);
    prefs.font_size = 16;
    try apply(&cfg, prefs, false);
    try std.testing.expectEqual(@as(f32, 16), cfg.font_size);
}
