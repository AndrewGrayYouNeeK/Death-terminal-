const std = @import("std");
const builtin = @import("builtin");

/// Runtime configuration for DeathTerminal.
pub const Config = struct {
    allocator: std.mem.Allocator,
    rows: u16,
    cols: u16,
    ai_enabled: bool,
    ai_endpoint: []const u8,
    scrollback_lines: usize,
    headless: bool,
    scale: f32,
    backend: Backend,
    /// Font family looked up with fontconfig; empty = bundled JetBrains Mono.
    font_family: []u8,
    /// Font size in points (at 96 DPI, before HiDPI scaling).
    font_size: f32 = 11,
    /// Cell height multiplier.
    line_height: f32 = 1.0,
    /// `font = retro` selects the built-in 8x8 bitmap font.
    font_retro: bool = false,
    /// HarfBuzz ligatures (calt/liga/dlig).
    font_ligatures: bool = true,

    pub const Backend = enum { auto, x11, wayland, win32 };

    pub fn init(allocator: std.mem.Allocator) Config {
        return Config{
            .allocator = allocator,
            .rows = 24,
            .cols = 80,
            .ai_enabled = true,
            .ai_endpoint = allocator.dupe(u8, "localhost:50051") catch @panic("config: out of memory"),
            .scrollback_lines = 10_000,
            .headless = true,
            .scale = 0,
            .backend = .auto,
            .font_family = allocator.alloc(u8, 0) catch @panic("config: out of memory"),
        };
    }

    pub fn deinit(self: *Config) void {
        self.allocator.free(self.ai_endpoint);
        self.allocator.free(self.font_family);
    }

    fn setFontFamily(self: *Config, name: []const u8) !void {
        const owned = try self.allocator.dupe(u8, name);
        self.allocator.free(self.font_family);
        self.font_family = owned;
    }

    fn setFontMode(self: *Config, value: []const u8) !void {
        if (std.ascii.eqlIgnoreCase(value, "retro")) {
            self.font_retro = true;
        } else if (std.ascii.eqlIgnoreCase(value, "default") or std.ascii.eqlIgnoreCase(value, "freetype")) {
            self.font_retro = false;
        } else {
            // `font = <family>` is accepted as a shorthand for font_family.
            self.font_retro = false;
            try self.setFontFamily(value);
        }
    }

    /// Handle `key = value` font settings; returns false for other keys.
    fn applyFontKey(self: *Config, key: []const u8, value: []const u8) !bool {
        if (std.mem.eql(u8, key, "font")) {
            try self.setFontMode(value);
        } else if (std.mem.eql(u8, key, "font_family")) {
            try self.setFontFamily(value);
        } else if (std.mem.eql(u8, key, "font_size")) {
            self.font_size = std.math.clamp(try std.fmt.parseFloat(f32, value), 4, 96);
        } else if (std.mem.eql(u8, key, "line_height")) {
            self.line_height = std.math.clamp(try std.fmt.parseFloat(f32, value), 0.5, 3);
        } else if (std.mem.eql(u8, key, "font_ligatures")) {
            self.font_ligatures = std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1");
        } else return false;
        return true;
    }

    pub fn loadFromArgs(self: *Config, args: []const []const u8) !void {
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--no-ai")) {
                self.ai_enabled = false;
            } else if (std.mem.eql(u8, arg, "--headless")) {
                self.headless = true;
            } else if (std.mem.eql(u8, arg, "--gui")) {
                self.headless = false;
            } else if (std.mem.eql(u8, arg, "--scale")) {
                if (i + 1 >= args.len) return error.MissingScale;
                i += 1;
                self.scale = try std.fmt.parseFloat(f32, args[i]);
            } else if (std.mem.startsWith(u8, arg, "--scale=")) {
                self.scale = try std.fmt.parseFloat(f32, arg["--scale=".len..]);
            } else if (std.mem.eql(u8, arg, "--backend")) {
                if (i + 1 >= args.len) return error.MissingBackend;
                i += 1;
                self.backend = try parseBackend(args[i]);
            } else if (std.mem.startsWith(u8, arg, "--backend=")) {
                self.backend = try parseBackend(arg["--backend=".len..]);
            } else if (fontFlag(arg)) |flag| {
                const value = if (std.mem.indexOfScalar(u8, arg, '=')) |eq| arg[eq + 1 ..] else blk: {
                    if (i + 1 >= args.len) return error.MissingFontValue;
                    i += 1;
                    break :blk args[i];
                };
                _ = try self.applyFontKey(flag, value);
            } else if (std.mem.eql(u8, arg, "--config")) {
                if (i + 1 >= args.len) return error.MissingConfigPath;
                i += 1;
                try self.loadFromFile(args[i]);
            }
        }
    }

    pub fn loadFromFile(self: *Config, path: []const u8) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const contents = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(contents);

        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;
            if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq| {
                const key = std.mem.trim(u8, trimmed[0..eq], " \t");
                const value = try parseString(trimmed[eq + 1 ..]);
                if (self.applyFontKey(key, value) catch false) continue;
            }

            if (std.mem.startsWith(u8, trimmed, "rows =")) {
                self.rows = try parseU16(trimmed["rows =".len..]);
            } else if (std.mem.startsWith(u8, trimmed, "cols =")) {
                self.cols = try parseU16(trimmed["cols =".len..]);
            } else if (std.mem.startsWith(u8, trimmed, "ai_enabled =")) {
                self.ai_enabled = std.mem.indexOf(u8, trimmed, "true") != null;
            } else if (std.mem.startsWith(u8, trimmed, "ai_endpoint =")) {
                const value = try parseString(trimmed["ai_endpoint =".len..]);
                self.allocator.free(self.ai_endpoint);
                self.ai_endpoint = try self.allocator.dupe(u8, value);
            } else if (std.mem.startsWith(u8, trimmed, "scrollback_lines =")) {
                self.scrollback_lines = try parseUsize(trimmed["scrollback_lines =".len..]);
            }
        }
    }

    pub fn defaultConfigPath(self: *Config, buffer: []u8) ![]const u8 {
        _ = self;
        const home = std.posix.getenv("HOME") orelse return error.HomeNotSet;
        return try std.fmt.bufPrint(buffer, "{s}/.config/death-terminal/config.txt", .{home});
    }

    pub fn tryLoadDefault(self: *Config) void {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = self.defaultConfigPath(&path_buf) catch return;
        self.loadFromFile(path) catch {};
    }

    fn fontFlag(arg: []const u8) ?[]const u8 {
        const flags = [_][2][]const u8{
            .{ "--font", "font" },
            .{ "--font-family", "font_family" },
            .{ "--font-size", "font_size" },
            .{ "--line-height", "line_height" },
        };
        for (flags) |f| {
            if (std.mem.eql(u8, arg, f[0])) return f[1];
            if (std.mem.startsWith(u8, arg, f[0]) and arg.len > f[0].len and arg[f[0].len] == '=') return f[1];
        }
        return null;
    }

    fn parseBackend(name: []const u8) !Backend {
        if (std.mem.eql(u8, name, "auto")) return .auto;
        if (std.mem.eql(u8, name, "x11")) return .x11;
        if (std.mem.eql(u8, name, "wayland")) return .wayland;
        if (std.mem.eql(u8, name, "win32")) return .win32;
        return error.UnknownBackend;
    }

    fn parseU16(value: []const u8) !u16 {
        const trimmed = std.mem.trim(u8, value, " \t\"");
        return try std.fmt.parseInt(u16, trimmed, 10);
    }

    fn parseUsize(value: []const u8) !usize {
        const trimmed = std.mem.trim(u8, value, " \t\"");
        return try std.fmt.parseInt(usize, trimmed, 10);
    }

    fn parseString(value: []const u8) ![]const u8 {
        const trimmed = std.mem.trim(u8, value, " \t\"");
        return trimmed;
    }
};

test "Config defaults" {
    const testing = std.testing;
    var config = Config.init(testing.allocator);
    defer config.deinit();
    try testing.expect(config.ai_enabled);
    try testing.expectEqual(@as(u16, 24), config.rows);
}

test "Config arg parsing" {
    const testing = std.testing;
    var config = Config.init(testing.allocator);
    defer config.deinit();

    const args = [_][]const u8{ "deathterminal", "--no-ai", "--gui" };
    try config.loadFromArgs(&args);
    try testing.expect(!config.ai_enabled);
    try testing.expect(!config.headless);
}

test "Config scale and backend args" {
    const testing = std.testing;
    var config = Config.init(testing.allocator);
    defer config.deinit();
    const args = [_][]const u8{ "deathterminal", "--gui", "--scale", "2", "--backend", "x11" };
    try config.loadFromArgs(&args);
    try testing.expectEqual(@as(f32, 2.0), config.scale);
    try testing.expectEqual(Config.Backend.x11, config.backend);
}

test "Config font keys from file and args" {
    const testing = std.testing;
    var config = Config.init(testing.allocator);
    defer config.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "c.txt", .data = "font_family = \"Fira Code\"\nfont_size = 13.5\nline_height=1.2\nfont_ligatures = false\n" });
    const path = try tmp.dir.realpathAlloc(testing.allocator, "c.txt");
    defer testing.allocator.free(path);
    try config.loadFromFile(path);
    try testing.expectEqualStrings("Fira Code", config.font_family);
    try testing.expectEqual(@as(f32, 13.5), config.font_size);
    try testing.expectEqual(@as(f32, 1.2), config.line_height);
    try testing.expect(!config.font_ligatures);
    const args = [_][]const u8{ "deathterminal", "--font", "retro", "--font-size=9" };
    try config.loadFromArgs(&args);
    try testing.expect(config.font_retro);
    try testing.expectEqual(@as(f32, 9), config.font_size);
}
