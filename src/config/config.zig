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
    /// Mouse selections also go to CLIPBOARD (PRIMARY is always set).
    copy_on_select: bool = false,
    /// Confirm multi-line pastes when the app hasn't enabled bracketed paste.
    paste_confirm: bool = true,
    /// OSC 52 clipboard access for programs: off | write | read-write.
    osc52: []const u8 = "write",
    /// Show a scrollbar thumb while scrolled back.
    scrollbar: bool = true,
    /// Lines per mouse-wheel notch in the scrollback.
    scroll_lines: u16 = 3,
    /// Extra characters treated as part of a word on double-click.
    word_chars: []u8,
    /// Program that opens Ctrl+clicked links (receives the URL as its only argument).
    url_open_command: []u8,
    selection_background: u32 = 0x3B5BA5,
    /// 0xFFFFFFFF keeps the text colour.
    selection_foreground: u32 = 0xFFFFFFFF,
    /// Swapchain present mode: fifo (vsync) | mailbox | immediate |
    /// fifo_relaxed. Falls back to what the surface supports.
    present_mode: []const u8 = "fifo",
    /// Upper bound on redraws per second while output streams in
    /// (0 = only limited by the present mode).
    max_fps: u16 = 120,
    /// PTY bytes parsed per batch before the loop services input and
    /// draws (also capped at ~8 ms of parsing).
    read_budget_kb: u32 = 1024,
    /// `keybind = chord=action` lines, applied in order over the defaults.
    keybinds: std.ArrayList([]u8),

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
            .word_chars = allocator.dupe(u8, "-_./~:@%+#?&=") catch @panic("config: out of memory"),
            .url_open_command = allocator.dupe(u8, if (builtin.os.tag == .macos) "open" else "xdg-open") catch @panic("config: out of memory"),
            .keybinds = std.ArrayList([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *Config) void {
        self.allocator.free(self.ai_endpoint);
        self.allocator.free(self.font_family);
        self.allocator.free(self.word_chars);
        self.allocator.free(self.url_open_command);
        for (self.keybinds.items) |k| self.allocator.free(k);
        self.keybinds.deinit();
    }

    fn replaceString(self: *Config, slot: *[]u8, value: []const u8) !void {
        const owned = try self.allocator.dupe(u8, value);
        self.allocator.free(slot.*);
        slot.* = owned;
    }

    fn parseBool(value: []const u8) bool {
        return std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "yes") or std.mem.eql(u8, value, "on");
    }

    fn parseColor(value: []const u8) !u32 {
        if (std.mem.eql(u8, value, "none") or std.mem.eql(u8, value, "default")) return 0xFFFFFFFF;
        const hex = if (value.len > 0 and value[0] == '#') value[1..] else value;
        if (hex.len != 6) return error.BadColor;
        return try std.fmt.parseInt(u32, hex, 16);
    }

    /// Selection / clipboard / scrollback / keybinding keys.
    fn applyUiKey(self: *Config, key: []const u8, value: []const u8) !bool {
        if (std.mem.eql(u8, key, "copy_on_select")) {
            self.copy_on_select = parseBool(value);
        } else if (std.mem.eql(u8, key, "paste_confirm")) {
            self.paste_confirm = parseBool(value);
        } else if (std.mem.eql(u8, key, "osc52")) {
            if (std.mem.eql(u8, value, "off")) {
                self.osc52 = "off";
            } else if (std.mem.eql(u8, value, "write")) {
                self.osc52 = "write";
            } else if (std.mem.eql(u8, value, "read-write") or std.mem.eql(u8, value, "read_write")) {
                self.osc52 = "read-write";
            } else return error.BadOsc52Policy;
        } else if (std.mem.eql(u8, key, "present_mode")) {
            const modes = [_][]const u8{ "fifo", "fifo_relaxed", "mailbox", "immediate" };
            if (std.ascii.eqlIgnoreCase(value, "vsync")) {
                self.present_mode = "fifo";
            } else for (modes) |m| {
                if (std.ascii.eqlIgnoreCase(value, m)) {
                    self.present_mode = m;
                    break;
                }
            } else return error.BadPresentMode;
        } else if (std.mem.eql(u8, key, "vsync")) {
            self.present_mode = if (parseBool(value)) "fifo" else "mailbox";
        } else if (std.mem.eql(u8, key, "max_fps")) {
            self.max_fps = std.math.clamp(try std.fmt.parseInt(u16, value, 10), 0, 1000);
        } else if (std.mem.eql(u8, key, "read_budget_kb")) {
            self.read_budget_kb = std.math.clamp(try std.fmt.parseInt(u32, value, 10), 16, 65536);
        } else if (std.mem.eql(u8, key, "scrollbar")) {
            self.scrollbar = parseBool(value);
        } else if (std.mem.eql(u8, key, "scroll_lines")) {
            self.scroll_lines = std.math.clamp(try std.fmt.parseInt(u16, value, 10), 1, 100);
        } else if (std.mem.eql(u8, key, "word_chars")) {
            try self.replaceString(&self.word_chars, value);
        } else if (std.mem.eql(u8, key, "url_open_command")) {
            try self.replaceString(&self.url_open_command, value);
        } else if (std.mem.eql(u8, key, "selection_background")) {
            self.selection_background = try parseColor(value);
        } else if (std.mem.eql(u8, key, "selection_foreground")) {
            self.selection_foreground = try parseColor(value);
        } else if (std.mem.eql(u8, key, "keybind")) {
            try self.keybinds.append(try self.allocator.dupe(u8, value));
        } else return false;
        return true;
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
                if (self.applyUiKey(key, value) catch |err| {
                    std.debug.print("config: {s}: {s}\n", .{ key, @errorName(err) });
                    continue;
                }) continue;
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

test "Config selection, clipboard and keybind keys" {
    const testing = std.testing;
    var config = Config.init(testing.allocator);
    defer config.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "c.txt", .data = 
    \\copy_on_select = true
    \\paste_confirm = false
    \\osc52 = read-write
    \\scrollbar = false
    \\scroll_lines = 5
    \\word_chars = "-_"
    \\url_open_command = firefox
    \\selection_background = #112233
    \\keybind = ctrl+shift+c=none
    \\keybind = alt+c=copy
    \\
    });
    const path = try tmp.dir.realpathAlloc(testing.allocator, "c.txt");
    defer testing.allocator.free(path);
    try config.loadFromFile(path);
    try testing.expect(config.copy_on_select);
    try testing.expect(!config.paste_confirm);
    try testing.expectEqualStrings("read-write", config.osc52);
    try testing.expect(!config.scrollbar);
    try testing.expectEqual(@as(u16, 5), config.scroll_lines);
    try testing.expectEqualStrings("-_", config.word_chars);
    try testing.expectEqualStrings("firefox", config.url_open_command);
    try testing.expectEqual(@as(u32, 0x112233), config.selection_background);
    try testing.expectEqual(@as(usize, 2), config.keybinds.items.len);
    try testing.expectEqualStrings("alt+c=copy", config.keybinds.items[1]);
}

test "Config performance keys" {
    const testing = std.testing;
    var config = Config.init(testing.allocator);
    defer config.deinit();
    try testing.expectEqualStrings("fifo", config.present_mode);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "p.txt", .data = 
    \\present_mode = Mailbox
    \\max_fps = 75
    \\read_budget_kb = 4
    \\
    });
    const path = try tmp.dir.realpathAlloc(testing.allocator, "p.txt");
    defer testing.allocator.free(path);
    try config.loadFromFile(path);
    try testing.expectEqualStrings("mailbox", config.present_mode);
    try testing.expectEqual(@as(u16, 75), config.max_fps);
    try testing.expectEqual(@as(u32, 16), config.read_budget_kb);
    try tmp.dir.writeFile(.{ .sub_path = "v.txt", .data = "vsync = false\n" });
    const vpath = try tmp.dir.realpathAlloc(testing.allocator, "v.txt");
    defer testing.allocator.free(vpath);
    try config.loadFromFile(vpath);
    try testing.expectEqualStrings("mailbox", config.present_mode);
}
