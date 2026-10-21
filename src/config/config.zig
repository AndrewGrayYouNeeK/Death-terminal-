//! Runtime configuration.
//!
//! The primary format is Lua (`config.lua`, see `lua_config.zig` and
//! docs/CONFIG.md); the old `key = value` config.txt is still read, with a
//! deprecation note. All strings live in a per-Config arena, so replacing a
//! value never needs a matching free and `deinit` releases everything.

const std = @import("std");
const env_mod = @import("../platform/env.zig");
const builtin = @import("builtin");
const color = @import("../terminal/color.zig");
pub const themes = @import("themes.zig");
pub const lua_config = @import("lua_config.zig");
pub const SshProfile = @import("../ssh/target.zig").Profile;
pub const PluginConfig = @import("../plugins/plugin_config.zig").PluginConfig;

/// A pane, or a split of several (`config.layout`). Strings live in the
/// config arena.
pub const LayoutNode = struct {
    /// null = a pane; otherwise `children` side by side ("right") or
    /// stacked ("down").
    split: ?enum { right, down } = null,
    /// Share of the first child (two children only; more are made even).
    ratio: f32 = 0.5,
    children: []const LayoutNode = &.{},
    cwd: []const u8 = "",
    /// Typed into the pane's shell once it starts (like tmux send-keys).
    command: []const u8 = "",
    /// Run the built-in SSH client for this profile / target instead.
    ssh: []const u8 = "",
    /// This pane gets the focus.
    focus: bool = false,
};

pub const LayoutTab = struct {
    title: []const u8 = "",
    root: LayoutNode,
};

pub const CursorShape = enum { block, underline, bar };

/// Per-entry colour overrides applied on top of the selected theme
/// (null = take the theme's value).
pub const ColorOverrides = struct {
    fg: ?u32 = null,
    bg: ?u32 = null,
    cursor: ?u32 = null,
    cursor_text: ?u32 = null,
    selection_bg: ?u32 = null,
    selection_fg: ?u32 = null,
    palette: [256]?u32 = [_]?u32{null} ** 256,
};

/// Messages produced while loading a config; shown in the terminal's
/// notice bar and on stderr.
pub const Diagnostics = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Item),

    pub const Severity = enum { err, warning };
    pub const Item = struct { severity: Severity, text: []u8 };

    pub fn init(allocator: std.mem.Allocator) Diagnostics {
        return .{ .allocator = allocator, .items = std.ArrayList(Item).init(allocator) };
    }

    pub fn deinit(self: *Diagnostics) void {
        self.clear();
        self.items.deinit();
    }

    pub fn clear(self: *Diagnostics) void {
        for (self.items.items) |it| self.allocator.free(it.text);
        self.items.clearRetainingCapacity();
    }

    pub fn add(self: *Diagnostics, severity: Severity, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        self.items.append(.{ .severity = severity, .text = text }) catch self.allocator.free(text);
    }

    pub fn errorCount(self: *const Diagnostics) usize {
        var n: usize = 0;
        for (self.items.items) |it| n += @intFromBool(it.severity == .err);
        return n;
    }

    pub fn hasErrors(self: *const Diagnostics) bool {
        return self.errorCount() != 0;
    }

    pub fn print(self: *const Diagnostics) void {
        for (self.items.items) |it| {
            std.debug.print("config {s}: {s}\n", .{ if (it.severity == .err) "error" else "warning", it.text });
        }
    }

    pub fn contains(self: *const Diagnostics, needle: []const u8) bool {
        for (self.items.items) |it| if (std.mem.indexOf(u8, it.text, needle) != null) return true;
        return false;
    }
};

/// Where a config file was found and how to parse it.
pub const Source = struct {
    path: []const u8,
    kind: Kind,
    pub const Kind = enum { lua, legacy };

    pub fn fromPath(path: []const u8) Source {
        return .{ .path = path, .kind = if (std.mem.endsWith(u8, path, ".lua")) .lua else .legacy };
    }
};

pub const LoadOptions = struct {
    /// Expose the full Lua standard library (io, os.execute, require...).
    lua_unsafe: bool = false,
};

/// Runtime configuration for DeathTerminal.
pub const Config = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    rows: u16 = 24,
    cols: u16 = 80,
    /// AI command suggestions (docs/AI.md).
    ai_enabled: bool = true,
    /// API root. `api.x.ai` and `us.api.x.ai` use `/responses` (Grok 4.7);
    /// every other host uses `/chat/completions`.
    ai_endpoint: []const u8 = "http://localhost:11434/v1",
    ai_model: []const u8 = "qwen2.5-coder:0.5b",
    /// "" = low on xAI, omitted elsewhere. Or low, medium, high, xhigh.
    ai_reasoning: []const u8 = "",
    /// Name of the environment variable holding the API key ("" = none).
    /// The key itself is never stored in the config.
    ai_api_key_env: []const u8 = "",
    ai_timeout_ms: u32 = 5000,
    /// Typing pause before a suggestion is requested.
    ai_debounce_ms: u32 = 300,
    ai_max_tokens: u16 = 64,
    /// Tokens for "explain/fix last error" answers.
    ai_explain_max_tokens: u16 = 400,
    /// Context: how many previous commands and output lines to send.
    ai_history: u16 = 5,
    ai_output_lines: u16 = 20,
    /// Chord that accepts the ghost-text suggestion.
    ai_accept_key: []const u8 = "tab",
    /// Load the OSC 133 shell integration into bash/zsh/fish.
    shell_integration: bool = true,
    /// Built-in SSH client (docs/SSH.md).
    ssh_enabled: bool = true,
    /// OpenSSH client config read for Host aliases ("" = none).
    ssh_config_file: []const u8 = "~/.ssh/config",
    /// Keepalive interval for sessions (0 = off); profiles may override.
    ssh_keepalive_s: u16 = 30,
    /// Where host keys are checked and accepted ones are appended.
    ssh_known_hosts: []const u8 = "~/.ssh/known_hosts",
    /// `config.ssh.profiles`, in definition order.
    ssh_profiles: std.ArrayList(SshProfile),
    /// Plugin system on/off (docs/PLUGINS.md).
    plugins_enabled: bool = true,
    /// Where plugins live ("" = $XDG_CONFIG_HOME/death-terminal/plugins).
    plugins_dir: []const u8 = "",
    /// `config.plugins.<name>` grants and settings.
    plugins: std.ArrayList(PluginConfig),
    /// One-row status bar at the bottom (plugin segments). On so the bundled
    /// YouNeeK Time clock is visible without a config file.
    status_bar: bool = true,
    /// Shared Haunting (docs/SHARING.md). Hosting can be turned off; joining
    /// with --join does not consult this flag.
    share_enabled: bool = true,
    /// Local address to listen on. "0.0.0.0" accepts LAN connections.
    share_bind: []const u8 = "0.0.0.0",
    /// TCP port. 0 picks an ephemeral port and puts it in the invite.
    share_port: u16 = 0,
    /// Host name or IP written into the invite. Empty = the LAN address.
    share_advertise: []const u8 = "",
    /// Optional relay, "host:port" or "tcp://host:port". Empty = direct TCP.
    share_relay: []const u8 = "",
    /// Tab bar: "auto" (only with 2+ tabs), "top", "bottom", "hidden".
    tab_bar: []const u8 = "auto",
    /// Ask before closing a pane / tab / window whose shell runs a program.
    confirm_close: bool = true,
    /// Fade inactive panes' text towards the background (0 = off, 0.9 max).
    dim_inactive: f32 = 0,
    /// New tabs and panes start in the focused pane's directory (OSC 7).
    inherit_cwd: bool = true,
    /// `config.layout`: tabs (and their splits) to open at startup.
    startup_layout: std.ArrayList(LayoutTab),
    scrollback_lines: usize = 10_000,
    headless: bool = true,
    scale: f32 = 0,
    backend: Backend = .auto,
    /// Font family looked up with fontconfig; empty = bundled JetBrains Mono.
    font_family: []const u8 = "",
    /// Font size in points (at 96 DPI, before HiDPI scaling).
    font_size: f32 = 11,
    /// Cell height multiplier.
    line_height: f32 = 1.0,
    /// Use the built-in 8x8 bitmap font.
    font_retro: bool = false,
    /// HarfBuzz ligatures (calt/liga/dlig).
    font_ligatures: bool = true,
    /// Bundled theme name (see themes.zig). Unset uses the death theme.
    theme: []const u8 = themes.default_name,
    colors: ColorOverrides = .{},
    cursor_shape: CursorShape = .block,
    /// Mouse selections also go to CLIPBOARD (PRIMARY is always set).
    copy_on_select: bool = false,
    /// Honour DECCOLM (80/132 column switching, CSI ?3 h/l).
    allow_column_switch: bool = true,
    /// Confirm multi-line pastes when the app hasn't enabled bracketed paste.
    paste_confirm: bool = true,
    /// OSC 52 clipboard access for programs: off | write | read-write.
    osc52: []const u8 = "write",
    /// Show a scrollbar thumb while scrolled back.
    scrollbar: bool = true,
    /// Lines per mouse-wheel notch in the scrollback.
    scroll_lines: u16 = 3,
    /// Extra characters treated as part of a word on double-click.
    word_chars: []const u8 = "-_./~:@%+#?&=",
    /// Program that opens Ctrl+clicked links (receives the URL as its only argument).
    url_open_command: []const u8 = switch (builtin.os.tag) {
        .macos => "open",
        // "" = the default handler (ShellExecute).
        .windows => "",
        else => "xdg-open",
    },
    /// Swapchain present mode: fifo (vsync) | mailbox | immediate |
    /// fifo_relaxed. Falls back to what the surface supports.
    present_mode: []const u8 = "fifo",
    /// Upper bound on redraws per second while output streams in
    /// (0 = only limited by the present mode).
    max_fps: u16 = 120,
    /// PTY bytes parsed per batch before the loop services input and
    /// draws (also capped at ~8 ms of parsing).
    read_budget_kb: u32 = 1024,
    /// Start from the built-in bindings (false = only `keybinds`).
    default_keybindings: bool = true,
    /// `chord=action` entries, applied in order over the defaults.
    keybinds: std.ArrayList([]const u8),
    /// Shell to run ("" = $SHELL, then /bin/sh).
    shell_program: []const u8 = "",
    shell_args: std.ArrayList([]const u8),
    /// Extra environment for the shell, as NAME=value.
    shell_env: std.ArrayList([]const u8),
    /// Starting directory ("" = inherit; "~" is expanded).
    shell_cwd: []const u8 = "",

    pub const Backend = enum { auto, x11, wayland, win32, cocoa };

    pub fn init(allocator: std.mem.Allocator) Config {
        const arena = allocator.create(std.heap.ArenaAllocator) catch @panic("config: out of memory");
        arena.* = std.heap.ArenaAllocator.init(allocator);
        return Config{
            .allocator = allocator,
            .arena = arena,
            .keybinds = std.ArrayList([]const u8).init(allocator),
            .shell_args = std.ArrayList([]const u8).init(allocator),
            .shell_env = std.ArrayList([]const u8).init(allocator),
            .ssh_profiles = std.ArrayList(SshProfile).init(allocator),
            .startup_layout = std.ArrayList(LayoutTab).init(allocator),
            .plugins = std.ArrayList(PluginConfig).init(allocator),
        };
    }

    pub fn deinit(self: *Config) void {
        self.keybinds.deinit();
        self.shell_args.deinit();
        self.shell_env.deinit();
        self.ssh_profiles.deinit();
        self.startup_layout.deinit();
        self.plugins.deinit();
        self.arena.deinit();
        self.allocator.destroy(self.arena);
    }

    /// Copy `value` into the config's arena.
    pub fn dupe(self: *Config, value: []const u8) ![]const u8 {
        return self.arena.allocator().dupe(u8, value);
    }

    fn replaceString(self: *Config, slot: *[]const u8, value: []const u8) !void {
        slot.* = try self.dupe(value);
    }

    /// The effective colours: the theme with `colors` overrides on top.
    pub fn palette(self: *const Config) color.Palette {
        const t = themes.find(self.theme) orelse themes.defaultTheme();
        var p = t.palette();
        const o = &self.colors;
        if (o.fg) |v| p.fg = v;
        if (o.bg) |v| p.bg = v;
        if (o.cursor) |v| p.cursor = v;
        if (o.cursor_text) |v| p.cursor_text = v;
        if (o.selection_bg) |v| p.selection_bg = v;
        if (o.selection_fg) |v| p.selection_fg = v;
        for (o.palette, 0..) |v, i| if (v) |c| {
            p.colors[i] = c;
        };
        return p;
    }

    /// Set or replace the binding for `chord` (`action` "none" unbinds).
    pub fn bind(self: *Config, chord: []const u8, action: []const u8) !void {
        const entry = try std.fmt.allocPrint(self.arena.allocator(), "{s}={s}", .{ chord, action });
        try self.keybinds.append(entry);
    }

    fn parseBool(value: []const u8) bool {
        return std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "yes") or std.mem.eql(u8, value, "on");
    }

    pub fn parseColor(value: []const u8) !u32 {
        if (std.mem.eql(u8, value, "none") or std.mem.eql(u8, value, "default")) return 0xFFFFFFFF;
        const hex = if (value.len > 0 and value[0] == '#') value[1..] else value;
        if (hex.len != 6) return error.BadColor;
        return try std.fmt.parseInt(u32, hex, 16);
    }

    /// Selection / clipboard / scrollback / keybinding keys.
    fn applyUiKey(self: *Config, key: []const u8, value: []const u8) !bool {
        if (std.mem.eql(u8, key, "allow_column_switch")) {
            self.allow_column_switch = parseBool(value);
        } else if (std.mem.eql(u8, key, "copy_on_select")) {
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
            self.colors.selection_bg = try parseColor(value);
        } else if (std.mem.eql(u8, key, "selection_foreground")) {
            self.colors.selection_fg = try parseColor(value);
        } else if (std.mem.eql(u8, key, "keybind")) {
            try self.keybinds.append(try self.dupe(value));
        } else return false;
        return true;
    }

    fn setFontFamily(self: *Config, name: []const u8) !void {
        self.font_family = try self.dupe(name);
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
            } else if (std.mem.eql(u8, arg, "--no-plugins")) {
                self.plugins_enabled = false;
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
                // Loaded before the CLI flags by `load` (see main.zig).
                if (i + 1 >= args.len) return error.MissingConfigPath;
                i += 1;
            } else if (std.mem.eql(u8, arg, "--ssh")) {
                // A window for an SSH session (main.zig runs the client).
                if (i + 1 >= args.len) return error.MissingSshTarget;
                i += 1;
                const explicit_headless = for (args[1..]) |x| {
                    if (std.mem.eql(u8, x, "--headless")) break true;
                } else false;
                if (!explicit_headless) self.headless = false;
                // The profile's theme override (re-applied on every reload).
                for (self.ssh_profiles.items) |p| {
                    if (std.mem.eql(u8, p.name, args[i]) and p.theme.len > 0) self.theme = p.theme;
                }
            }
        }
    }

    /// Legacy `key = value` config.txt.
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
                self.ai_endpoint = try self.dupe(value);
            } else if (std.mem.startsWith(u8, trimmed, "scrollback_lines =")) {
                self.scrollback_lines = try parseUsize(trimmed["scrollback_lines =".len..]);
            }
        }
    }

    /// Load `src` (Lua or legacy) into this config. Problems are reported
    /// through `diags`; the caller decides whether to keep the result.
    pub fn loadSource(self: *Config, src: Source, opts: LoadOptions, diags: *Diagnostics) void {
        switch (src.kind) {
            .lua => lua_config.loadFile(self, src.path, opts, diags),
            .legacy => {
                self.loadFromFile(src.path) catch |err| {
                    diags.add(.err, "{s}: {s}", .{ src.path, @errorName(err) });
                    return;
                };
                if (!std.mem.endsWith(u8, src.path, ".txt")) return;
                diags.add(.warning, "{s} uses the deprecated key = value format; " ++
                    "run `deathterminal --print-default-config > {s}.lua` and move your settings there", .{ src.path, src.path[0 .. src.path.len - 4] });
            },
        }
    }

    pub fn tryLoadDefault(self: *Config) void {
        var diags = Diagnostics.init(self.allocator);
        defer diags.deinit();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const src = locate(&buf, null) orelse return;
        self.loadSource(src, .{}, &diags);
        diags.print();
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
        if (std.mem.eql(u8, name, "cocoa")) return .cocoa;
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

/// Find the config file: `explicit` (from --config) if given, else
/// $XDG_CONFIG_HOME/death-terminal/config.lua (default ~/.config), then each
/// $XDG_CONFIG_DIRS entry (default /etc/xdg), then the legacy
/// ~/.config/death-terminal/config.txt. The path is written into `buf`.
pub fn locate(buf: []u8, explicit: ?[]const u8) ?Source {
    if (explicit) |p| {
        if (p.len > buf.len) return null;
        @memcpy(buf[0..p.len], p);
        return Source.fromPath(buf[0..p.len]);
    }
    const env = env_mod.get;
    const rel = "death-terminal/config.lua";
    if (builtin.os.tag == .windows) if (env("APPDATA")) |x| {
        if (exists(buf, "{s}\\death-terminal\\config.lua", .{x})) |p| return .{ .path = p, .kind = .lua };
    };
    if (env("XDG_CONFIG_HOME")) |x| if (x.len > 0) {
        if (exists(buf, "{s}/{s}", .{ x, rel })) |p| return .{ .path = p, .kind = .lua };
    };
    const home = env("HOME") orelse "";
    if (home.len > 0) {
        if (exists(buf, "{s}/.config/{s}", .{ home, rel })) |p| return .{ .path = p, .kind = .lua };
    }
    var dirs = std.mem.tokenizeScalar(u8, env("XDG_CONFIG_DIRS") orelse "/etc/xdg", ':');
    while (dirs.next()) |d| {
        if (exists(buf, "{s}/{s}", .{ d, rel })) |p| return .{ .path = p, .kind = .lua };
    }
    if (home.len > 0) {
        if (exists(buf, "{s}/.config/death-terminal/config.txt", .{home})) |p| return .{ .path = p, .kind = .legacy };
    }
    return null;
}

/// Where a new config.lua would go (for messages and the file watcher).
pub fn userConfigPath(buf: []u8) ?[]const u8 {
    const env = env_mod.get;
    if (builtin.os.tag == .windows) if (env("APPDATA")) |x| {
        return std.fmt.bufPrint(buf, "{s}\\death-terminal\\config.lua", .{x}) catch null;
    };
    if (env("XDG_CONFIG_HOME")) |x| if (x.len > 0) {
        return std.fmt.bufPrint(buf, "{s}/death-terminal/config.lua", .{x}) catch null;
    };
    const home = env("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/death-terminal/config.lua", .{home}) catch null;
}

fn exists(buf: []u8, comptime fmt: []const u8, args: anytype) ?[]const u8 {
    const p = std.fmt.bufPrint(buf, fmt, args) catch return null;
    std.fs.cwd().access(p, .{}) catch return null;
    return p;
}

/// Build a complete config: defaults, then the file, then CLI flags. If the
/// file has errors the returned config holds the defaults (plus flags) and
/// `diags` explains why.
pub fn load(allocator: std.mem.Allocator, src: ?Source, args: []const []const u8, opts: LoadOptions, diags: *Diagnostics) !Config {
    var cfg = Config.init(allocator);
    errdefer cfg.deinit();
    if (src) |s| {
        cfg.loadSource(s, opts, diags);
        if (diags.hasErrors()) {
            cfg.deinit();
            cfg = Config.init(allocator);
        }
    }
    try cfg.loadFromArgs(args);
    return cfg;
}

/// The value after `--config` in `args`, if any.
pub fn configArg(args: []const []const u8) ?[]const u8 {
    for (args, 0..) |a, i| {
        if (std.mem.eql(u8, a, "--config") and i + 1 < args.len) return args[i + 1];
        if (std.mem.startsWith(u8, a, "--config=")) return a["--config=".len..];
    }
    return null;
}

test "Config defaults" {
    const testing = std.testing;
    var config = Config.init(testing.allocator);
    defer config.deinit();
    try testing.expect(config.ai_enabled);
    try testing.expectEqual(@as(u16, 24), config.rows);
    try testing.expectEqualStrings(themes.default_name, config.theme);
    try testing.expectEqual(themes.defaultTheme().palette().hash(), config.palette().hash());
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
    const path = try @import("../testutil.zig").tmpPath(testing.allocator, &tmp, "c.txt");
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
    const path = try @import("../testutil.zig").tmpPath(testing.allocator, &tmp, "c.txt");
    defer testing.allocator.free(path);
    try config.loadFromFile(path);
    try testing.expect(config.copy_on_select);
    try testing.expect(!config.paste_confirm);
    try testing.expectEqualStrings("read-write", config.osc52);
    try testing.expect(!config.scrollbar);
    try testing.expectEqual(@as(u16, 5), config.scroll_lines);
    try testing.expectEqualStrings("-_", config.word_chars);
    try testing.expectEqualStrings("firefox", config.url_open_command);
    try testing.expectEqual(@as(u32, 0x112233), config.colors.selection_bg.?);
    try testing.expectEqual(@as(u32, 0x112233), config.palette().selection_bg);
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
    const path = try @import("../testutil.zig").tmpPath(testing.allocator, &tmp, "p.txt");
    defer testing.allocator.free(path);
    try config.loadFromFile(path);
    try testing.expectEqualStrings("mailbox", config.present_mode);
    try testing.expectEqual(@as(u16, 75), config.max_fps);
    try testing.expectEqual(@as(u32, 16), config.read_budget_kb);
    try tmp.dir.writeFile(.{ .sub_path = "v.txt", .data = "vsync = false\n" });
    const vpath = try @import("../testutil.zig").tmpPath(testing.allocator, &tmp, "v.txt");
    defer testing.allocator.free(vpath);
    try config.loadFromFile(vpath);
    try testing.expectEqualStrings("mailbox", config.present_mode);
}

test "Config legacy file through loadSource warns about deprecation" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "config.txt", .data = "font_size = 14\nmax_fps = 60\n" });
    const path = try @import("../testutil.zig").tmpPath(testing.allocator, &tmp, "config.txt");
    defer testing.allocator.free(path);
    var diags = Diagnostics.init(testing.allocator);
    defer diags.deinit();
    const args = [_][]const u8{ "dt", "--config", path, "--font-size", "9" };
    var cfg = try load(testing.allocator, Source.fromPath(path), &args, .{}, &diags);
    defer cfg.deinit();
    try testing.expectEqual(@as(u16, 60), cfg.max_fps);
    // CLI flags win over the file.
    try testing.expectEqual(@as(f32, 9), cfg.font_size);
    try testing.expect(!diags.hasErrors());
    try testing.expect(diags.contains("deprecated"));
    try testing.expectEqualStrings(path, configArg(&args).?);
}

test "Config locate prefers XDG config.lua" {
    const testing = std.testing;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const s = locate(&buf, "/tmp/x.lua").?;
    try testing.expectEqual(Source.Kind.lua, s.kind);
    try testing.expectEqual(Source.Kind.legacy, Source.fromPath("/tmp/x.txt").kind);
}
