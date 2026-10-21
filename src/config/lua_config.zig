//! Loads config.lua into a `Config`.
//!
//! The user's file runs in a sandboxed environment (no io / os.execute /
//! require unless --lua-unsafe) built by the embedded prelude.lua. Each
//! `config.<section>.<key> = value` is validated here against `schema`;
//! mistakes become diagnostics with file:line instead of aborting.

const std = @import("std");
const env_mod = @import("../platform/env.zig");
const builtin = @import("builtin");
const lua = @import("../scripting/lua.zig");
const c = lua.c;
const State = lua.State;
const cfg_mod = @import("config.zig");
const Config = cfg_mod.Config;
const Diagnostics = cfg_mod.Diagnostics;
const themes = @import("themes.zig");
const events = @import("../platform/events.zig");
const ssh_forward = @import("../ssh/forward.zig");
const SshProfile = cfg_mod.SshProfile;
const PluginConfig = cfg_mod.PluginConfig;
const plugin_permissions = @import("../plugins/permissions.zig");
const plugin_manifest = @import("../plugins/manifest.zig");
const plugin_value = @import("../plugins/value.zig");

const prelude_src = @embedFile("prelude.lua");
pub const version = "0.1.0";

pub const Kind = enum { section, boolean, integer, number, string, color, choice, theme, keys, string_map, string_list, palette, ssh_profiles, plugins, layout, ghost_patterns };

const Ref = union(enum) {
    boolean: *bool,
    u16: *u16,
    u32: *u32,
    usize: *usize,
    f32: *f32,
    string: *[]const u8,
    color: *?u32,
    backend: *Config.Backend,
    cursor: *cfg_mod.CursorShape,
};

const RefFn = *const fn (*Config) Ref;

pub const Field = struct {
    path: []const u8,
    kind: Kind,
    min: f64 = 0,
    max: f64 = 0,
    choices: []const []const u8 = &.{},
    /// Colours: accept "none" (derive from the cell / keep text colour).
    allow_none: bool = false,
    ref: ?RefFn = null,
    /// Changing it only takes effect for new windows / after a restart.
    restart: bool = false,
    /// Extra check for strings: returns an error message, or null if ok.
    check: ?*const fn ([]const u8) ?[]const u8 = null,
};

fn checkEndpoint(s: []const u8) ?[]const u8 {
    const uri = std.Uri.parse(s) catch return "expected an http:// or https:// URL like \"http://localhost:11434/v1\"";
    if (!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https"))
        return "expected an http:// or https:// URL like \"http://localhost:11434/v1\"";
    if (uri.host == null) return "the URL needs a host";
    return null;
}

fn checkEnvName(s: []const u8) ?[]const u8 {
    if (s.len == 0) return null;
    const ai_redact = @import("../ai/redact.zig");
    if (ai_redact.looksLikeKey(s)) return "this looks like an API key; set it to the NAME of an environment variable (e.g. \"OPENAI_API_KEY\") and export the key there";
    for (s) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_'))
        return "expected an environment variable name like \"OPENAI_API_KEY\"";
    if (std.ascii.isDigit(s[0])) return "expected an environment variable name like \"OPENAI_API_KEY\"";
    return null;
}

fn checkReasoning(s: []const u8) ?[]const u8 {
    if (s.len == 0) return null;
    const ok = [_][]const u8{ "low", "medium", "high", "xhigh" };
    for (ok) |v| if (std.ascii.eqlIgnoreCase(s, v)) return null;
    return "expected \"\", \"low\", \"medium\", \"high\" or \"xhigh\" (grok-4.7 cannot turn reasoning off)";
}

fn ghostPatternError(s: []const u8) ?[]const u8 {
    if (s.len == 0 or s.len > 200) return "expected 1 to 200 characters";
    if (std.mem.indexOfAny(u8, s, "\r\n") != null) return "cannot contain a newline";
    return null;
}

fn checkChord(s: []const u8) ?[]const u8 {
    _ = events.parseChord(s) catch return "cannot parse the key chord (use e.g. \"tab\", \"ctrl+space\", \"right\")";
    return null;
}

fn ref(comptime tag: std.meta.Tag(Ref), comptime name: []const u8) RefFn {
    return struct {
        fn f(cfg: *Config) Ref {
            return @unionInit(Ref, @tagName(tag), &@field(cfg, name));
        }
    }.f;
}

fn colorRef(comptime name: []const u8) RefFn {
    return struct {
        fn f(cfg: *Config) Ref {
            return .{ .color = &@field(cfg.colors, name) };
        }
    }.f;
}

const present_modes = [_][]const u8{ "fifo", "fifo_relaxed", "mailbox", "immediate" };
const osc52_modes = [_][]const u8{ "off", "write", "read-write" };
const backends = [_][]const u8{ "auto", "x11", "wayland", "win32", "cocoa" };
const cursor_shapes = [_][]const u8{ "block", "underline", "bar" };
const tab_bar_modes = [_][]const u8{ "auto", "top", "bottom", "hidden" };

/// Every option config.lua can set. Keep docs/CONFIG.md and
/// config.example.lua in sync (a test checks the example).
pub const schema = [_]Field{
    .{ .path = "window", .kind = .section },
    .{ .path = "window.rows", .kind = .integer, .min = 2, .max = 500, .ref = ref(.u16, "rows"), .restart = true },
    .{ .path = "window.cols", .kind = .integer, .min = 2, .max = 1000, .ref = ref(.u16, "cols"), .restart = true },
    .{ .path = "window.scale", .kind = .number, .min = 0, .max = 4, .ref = ref(.f32, "scale"), .restart = true },
    .{ .path = "window.backend", .kind = .choice, .choices = &backends, .ref = ref(.backend, "backend"), .restart = true },
    .{ .path = "window.headless", .kind = .boolean, .ref = ref(.boolean, "headless"), .restart = true },
    .{ .path = "window.allow_column_switch", .kind = .boolean, .ref = ref(.boolean, "allow_column_switch") },

    .{ .path = "font", .kind = .section },
    .{ .path = "font.family", .kind = .string, .ref = ref(.string, "font_family") },
    .{ .path = "font.size", .kind = .number, .min = 4, .max = 96, .ref = ref(.f32, "font_size") },
    .{ .path = "font.line_height", .kind = .number, .min = 0.5, .max = 3, .ref = ref(.f32, "line_height") },
    .{ .path = "font.ligatures", .kind = .boolean, .ref = ref(.boolean, "font_ligatures") },
    .{ .path = "font.retro", .kind = .boolean, .ref = ref(.boolean, "font_retro") },

    .{ .path = "theme", .kind = .theme, .ref = ref(.string, "theme") },
    .{ .path = "colors", .kind = .section },
    .{ .path = "colors.foreground", .kind = .color, .ref = colorRef("fg") },
    .{ .path = "colors.background", .kind = .color, .ref = colorRef("bg") },
    .{ .path = "colors.cursor", .kind = .color, .allow_none = true, .ref = colorRef("cursor") },
    .{ .path = "colors.cursor_text", .kind = .color, .allow_none = true, .ref = colorRef("cursor_text") },
    .{ .path = "colors.selection_background", .kind = .color, .ref = colorRef("selection_bg") },
    .{ .path = "colors.selection_foreground", .kind = .color, .allow_none = true, .ref = colorRef("selection_fg") },
    .{ .path = "colors.palette", .kind = .palette },

    .{ .path = "cursor", .kind = .section },
    .{ .path = "cursor.shape", .kind = .choice, .choices = &cursor_shapes, .ref = ref(.cursor, "cursor_shape") },

    .{ .path = "render", .kind = .section },
    .{ .path = "render.present_mode", .kind = .choice, .choices = &present_modes, .ref = ref(.string, "present_mode") },
    .{ .path = "render.max_fps", .kind = .integer, .min = 0, .max = 1000, .ref = ref(.u16, "max_fps") },
    .{ .path = "render.read_budget_kb", .kind = .integer, .min = 16, .max = 65536, .ref = ref(.u32, "read_budget_kb") },

    .{ .path = "scrollback", .kind = .section },
    .{ .path = "scrollback.lines", .kind = .integer, .min = 0, .max = 1_000_000, .ref = ref(.usize, "scrollback_lines"), .restart = true },
    .{ .path = "scrollback.scrollbar", .kind = .boolean, .ref = ref(.boolean, "scrollbar") },
    .{ .path = "scrollback.wheel_lines", .kind = .integer, .min = 1, .max = 100, .ref = ref(.u16, "scroll_lines") },

    .{ .path = "selection", .kind = .section },
    .{ .path = "selection.copy_on_select", .kind = .boolean, .ref = ref(.boolean, "copy_on_select") },
    .{ .path = "selection.word_chars", .kind = .string, .ref = ref(.string, "word_chars") },

    .{ .path = "clipboard", .kind = .section },
    .{ .path = "clipboard.paste_confirm", .kind = .boolean, .ref = ref(.boolean, "paste_confirm") },
    .{ .path = "clipboard.osc52", .kind = .choice, .choices = &osc52_modes, .ref = ref(.string, "osc52") },

    .{ .path = "links", .kind = .section },
    .{ .path = "links.open_command", .kind = .string, .ref = ref(.string, "url_open_command") },

    .{ .path = "keys", .kind = .keys },
    .{ .path = "default_keybindings", .kind = .boolean, .ref = ref(.boolean, "default_keybindings") },

    .{ .path = "shell", .kind = .section },
    .{ .path = "shell.program", .kind = .string, .ref = ref(.string, "shell_program"), .restart = true },
    .{ .path = "shell.args", .kind = .string_list, .restart = true },
    .{ .path = "shell.env", .kind = .string_map, .restart = true },
    .{ .path = "shell.cwd", .kind = .string, .ref = ref(.string, "shell_cwd"), .restart = true },
    .{ .path = "shell.integration", .kind = .boolean, .ref = ref(.boolean, "shell_integration"), .restart = true },

    .{ .path = "ghost_run", .kind = .section },
    .{ .path = "ghost_run.enabled", .kind = .boolean, .ref = ref(.boolean, "ghost_run_enabled") },
    .{ .path = "ghost_run.ai_explain", .kind = .boolean, .ref = ref(.boolean, "ghost_run_ai") },
    .{ .path = "ghost_run.patterns", .kind = .ghost_patterns },

    .{ .path = "ai", .kind = .section },
    .{ .path = "ai.enabled", .kind = .boolean, .ref = ref(.boolean, "ai_enabled") },
    .{ .path = "ai.endpoint", .kind = .string, .ref = ref(.string, "ai_endpoint"), .check = checkEndpoint },
    .{ .path = "ai.model", .kind = .string, .ref = ref(.string, "ai_model") },
    .{ .path = "ai.reasoning", .kind = .string, .ref = ref(.string, "ai_reasoning"), .check = checkReasoning },
    .{ .path = "ai.api_key_env", .kind = .string, .ref = ref(.string, "ai_api_key_env"), .check = checkEnvName },
    .{ .path = "ai.timeout_ms", .kind = .integer, .min = 200, .max = 600_000, .ref = ref(.u32, "ai_timeout_ms") },
    .{ .path = "ai.debounce_ms", .kind = .integer, .min = 0, .max = 10_000, .ref = ref(.u32, "ai_debounce_ms") },
    .{ .path = "ai.max_tokens", .kind = .integer, .min = 8, .max = 4096, .ref = ref(.u16, "ai_max_tokens") },
    .{ .path = "ai.explain_max_tokens", .kind = .integer, .min = 16, .max = 8192, .ref = ref(.u16, "ai_explain_max_tokens") },
    .{ .path = "ai.history", .kind = .integer, .min = 0, .max = 32, .ref = ref(.u16, "ai_history") },
    .{ .path = "ai.output_lines", .kind = .integer, .min = 0, .max = 200, .ref = ref(.u16, "ai_output_lines") },
    .{ .path = "ai.accept_key", .kind = .string, .ref = ref(.string, "ai_accept_key"), .check = checkChord },

    .{ .path = "ssh", .kind = .section },
    .{ .path = "ssh.enabled", .kind = .boolean, .ref = ref(.boolean, "ssh_enabled") },
    .{ .path = "ssh.config_file", .kind = .string, .ref = ref(.string, "ssh_config_file") },
    .{ .path = "ssh.keepalive_s", .kind = .integer, .min = 0, .max = 3600, .ref = ref(.u16, "ssh_keepalive_s") },
    .{ .path = "ssh.known_hosts", .kind = .string, .ref = ref(.string, "ssh_known_hosts") },
    .{ .path = "ssh.profiles", .kind = .ssh_profiles },

    .{ .path = "status_bar", .kind = .section },
    .{ .path = "status_bar.enabled", .kind = .boolean, .ref = ref(.boolean, "status_bar") },

    .{ .path = "tabs", .kind = .section },
    .{ .path = "tabs.bar", .kind = .choice, .choices = &tab_bar_modes, .ref = ref(.string, "tab_bar") },
    .{ .path = "tabs.confirm_close", .kind = .boolean, .ref = ref(.boolean, "confirm_close") },
    .{ .path = "tabs.dim_inactive", .kind = .number, .min = 0, .max = 0.9, .ref = ref(.f32, "dim_inactive") },
    .{ .path = "tabs.inherit_cwd", .kind = .boolean, .ref = ref(.boolean, "inherit_cwd") },
    .{ .path = "layout", .kind = .layout },

    .{ .path = "plugins_enabled", .kind = .boolean, .ref = ref(.boolean, "plugins_enabled") },
    .{ .path = "plugins_dir", .kind = .string, .ref = ref(.string, "plugins_dir") },
    .{ .path = "plugins", .kind = .plugins },
};

pub fn field(path: []const u8) ?*const Field {
    for (&schema) |*f| if (std.mem.eql(u8, f.path, path)) return f;
    return null;
}

// ------------------------------------------------------------------ loading

pub fn loadFile(cfg: *Config, path: []const u8, opts: cfg_mod.LoadOptions, diags: *Diagnostics) void {
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    const display = displayName(&name_buf, path);
    const src = std.fs.cwd().readFileAlloc(cfg.allocator, path, 4 * 1024 * 1024) catch |err| {
        diags.add(.err, "{s}: cannot read: {s}", .{ display, @errorName(err) });
        return;
    };
    defer cfg.allocator.free(src);
    loadString(cfg, src, display, opts, diags);
}

/// Path with $HOME shown as "~" (what error messages print).
pub fn displayName(buf: []u8, path: []const u8) []const u8 {
    if (env_mod.home()) |home| {
        if (home.len > 1 and std.mem.startsWith(u8, path, home) and path.len > home.len and std.fs.path.isSep(path[home.len])) {
            return std.fmt.bufPrint(buf, "~{s}", .{path[home.len..]}) catch path;
        }
    }
    return path;
}

const Ctx = struct {
    cfg: *Config,
    buf: [1024]u8 = undefined,
    msg_len: usize = 0,
    desc: [160]u8 = undefined,
    keys_reset: bool = false,
};

pub fn loadString(cfg: *Config, source: []const u8, display: []const u8, opts: cfg_mod.LoadOptions, diags: *Diagnostics) void {
    var vm = lua.Vm.init(.{}) catch {
        diags.add(.err, "{s}: cannot start Lua (out of memory)", .{display});
        return;
    };
    defer vm.deinit();
    const L = vm.L;
    var ctx = Ctx{ .cfg = cfg };

    lua.loadText(L, prelude_src, "=prelude") catch {
        diags.add(.err, "internal error in prelude: {s}", .{lua.toString(L, -1) orelse "?"});
        return;
    };
    c.lua_pushlightuserdata(L, &ctx);
    c.lua_pushcclosure(L, luaSet, 1);
    c.lua_pushlightuserdata(L, &ctx);
    c.lua_pushcclosure(L, luaGet, 1);
    lua.newTable(L);
    for (schema) |f| {
        lua.pushString(L, @tagName(f.kind));
        _ = c.lua_setfield(L, -2, dupeZ(&ctx.buf, f.path));
    }
    lua.pushString(L, display);
    lua.pushString(L, source);
    c.lua_pushboolean(L, @intFromBool(opts.lua_unsafe));
    lua.newTable(L);
    for (themes.all, 1..) |t, i| {
        lua.pushString(L, t.name);
        c.lua_rawseti(L, -2, @intCast(i));
    }
    lua.pushCFn(L, luaTheme);
    lua.pushCFn(L, luaPrint);
    lua.pushString(L, version);
    lua.pushString(L, @tagName(builtin.os.tag));

    lua.pcall(L, 11, 1) catch {
        const msg = lua.toString(L, -1) orelse "unknown error";
        if (std.mem.startsWith(u8, msg, display)) {
            diags.add(.err, "{s}", .{msg});
        } else diags.add(.err, "{s}: {s}", .{ display, msg });
        return;
    };
    if (c.lua_type(L, -1) != c.LUA_TTABLE) return;
    const n = c.luaL_len(L, -1);
    var i: c.lua_Integer = 1;
    while (i <= n) : (i += 1) {
        _ = c.lua_rawgeti(L, -1, i);
        diags.add(.err, "{s}", .{lua.toString(L, -1) orelse "?"});
        lua.pop(L, 1);
    }
}

fn dupeZ(buf: []u8, s: []const u8) [*:0]const u8 {
    const n = @min(s.len, buf.len - 1);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    return @ptrCast(buf.ptr);
}

fn ctxOf(L: *State) *Ctx {
    return @ptrCast(@alignCast(c.lua_touserdata(L, lua.upvalueIndex(1))));
}

fn fail(ctx: *Ctx, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(&ctx.buf, fmt, args) catch "invalid value (message too long)";
}

/// `string "abc"`, `number 3`, `table` ... for error messages.
fn describe(ctx: *Ctx, L: *State, idx: c_int) []const u8 {
    return switch (c.lua_type(L, idx)) {
        c.LUA_TSTRING => std.fmt.bufPrint(&ctx.desc, "\"{s}\"", .{truncate(lua.toString(L, idx).?, 60)}) catch "a string",
        c.LUA_TNUMBER => if (c.lua_isinteger(L, idx) != 0)
            std.fmt.bufPrint(&ctx.desc, "{d}", .{c.lua_tointegerx(L, idx, null)}) catch "a number"
        else
            std.fmt.bufPrint(&ctx.desc, "{d}", .{c.lua_tonumberx(L, idx, null)}) catch "a number",
        c.LUA_TBOOLEAN => if (c.lua_toboolean(L, idx) != 0) "true" else "false",
        c.LUA_TNIL, c.LUA_TNONE => "nil",
        else => std.fmt.bufPrint(&ctx.desc, "a {s}", .{lua.typeName(L, idx)}) catch "a value",
    };
}

fn truncate(s: []const u8, n: usize) []const u8 {
    return if (s.len > n) s[0..n] else s;
}

// ------------------------------------------------------------ Lua → Zig

/// set(path, value) / set(path, value, key): nil on success, else message.
fn luaSet(Lopt: ?*State) callconv(.C) c_int {
    const L = Lopt.?;
    const ctx = ctxOf(L);
    const path = lua.toString(L, 1) orelse return 0;
    const msg = if (c.lua_gettop(L) >= 3) setItem(ctx, L, path, 3, 2) else setValue(ctx, L, path, 2);
    if (msg) |m| {
        lua.pushString(L, m);
        return 1;
    }
    return 0;
}

fn setValue(ctx: *Ctx, L: *State, path: []const u8, idx: c_int) ?[]const u8 {
    const f = field(path) orelse return fail(ctx, "unknown option '{s}'", .{path});
    const cfg = ctx.cfg;
    if (lua.isNil(L, idx)) return fail(ctx, "{s}: cannot be nil (delete the line to keep the default)", .{path});
    switch (f.kind) {
        .section => return fail(ctx, "{s}: expected a table of options", .{path}),
        .boolean => {
            if (c.lua_type(L, idx) != c.LUA_TBOOLEAN) return fail(ctx, "{s}: expected true or false, got {s}", .{ path, describe(ctx, L, idx) });
            f.ref.?(cfg).boolean.* = c.lua_toboolean(L, idx) != 0;
        },
        .integer => {
            const ok_num = c.lua_type(L, idx) == c.LUA_TNUMBER;
            const v = c.lua_tonumberx(L, idx, null);
            if (!ok_num or v != @floor(v) or v < f.min or v > f.max) {
                return fail(ctx, "{s}: expected a whole number from {d} to {d}, got {s}", .{ path, f.min, f.max, describe(ctx, L, idx) });
            }
            switch (f.ref.?(cfg)) {
                .u16 => |p| p.* = @intFromFloat(v),
                .u32 => |p| p.* = @intFromFloat(v),
                .usize => |p| p.* = @intFromFloat(v),
                else => unreachable,
            }
        },
        .number => {
            const v = c.lua_tonumberx(L, idx, null);
            if (c.lua_type(L, idx) != c.LUA_TNUMBER or v < f.min or v > f.max) {
                return fail(ctx, "{s}: expected a number from {d} to {d}, got {s}", .{ path, f.min, f.max, describe(ctx, L, idx) });
            }
            f.ref.?(cfg).f32.* = @floatCast(v);
        },
        .string => {
            const s = lua.toString(L, idx) orelse return fail(ctx, "{s}: expected a string, got {s}", .{ path, describe(ctx, L, idx) });
            if (f.check) |check| if (check(s)) |msg| return fail(ctx, "{s}: {s}", .{ path, msg });
            f.ref.?(cfg).string.* = cfg.dupe(s) catch return "out of memory";
        },
        .color => {
            const v = parseColor(L, idx, f.allow_none) orelse return colorError(ctx, L, path, idx, f.allow_none);
            f.ref.?(cfg).color.* = v;
        },
        .choice => {
            const s = lua.toString(L, idx) orelse "";
            const pick: ?[]const u8 = for (f.choices) |ch| {
                if (std.ascii.eqlIgnoreCase(ch, s) or (std.mem.eql(u8, ch, "fifo") and std.ascii.eqlIgnoreCase(s, "vsync"))) break ch;
            } else null;
            const ch = pick orelse return choiceError(ctx, L, path, idx, f.choices);
            switch (f.ref.?(cfg)) {
                .string => |p| p.* = ch,
                .backend => |p| p.* = std.meta.stringToEnum(Config.Backend, ch).?,
                .cursor => |p| p.* = std.meta.stringToEnum(cfg_mod.CursorShape, ch).?,
                else => unreachable,
            }
        },
        .theme => {
            const s = lua.toString(L, idx) orelse "";
            const t = themes.find(s) orelse {
                var names: [256]u8 = undefined;
                return fail(ctx, "{s}: unknown theme {s} (bundled: {s})", .{ path, describe(ctx, L, idx), themeNames(&names) });
            };
            f.ref.?(cfg).string.* = t.name;
        },
        .keys, .string_map, .palette, .string_list, .ssh_profiles, .plugins, .layout, .ghost_patterns => {
            if (c.lua_type(L, idx) != c.LUA_TTABLE) {
                const what = switch (f.kind) {
                    .layout => "a list of tabs like { { split = \"right\", panes = { {}, { command = \"htop\" } } } }",
                    .plugins => "a table like { git_branch = { allow = { \"exec\" }, exec = { \"git\" } } }",
                    .keys => "a table like { [\"ctrl+shift+t\"] = \"search\" }",
                    .ssh_profiles => "a table like { work = { host = \"build.example.com\", user = \"me\" } }",
                    .string_map => "a table like { NAME = \"value\" }",
                    .palette => "a table like { [0] = \"#000000\", [1] = \"#cc0000\" }",
                    .ghost_patterns => "a list of patterns like { \"rm -r\", \"dd\" }",
                    else => "a list of strings like { \"-l\" }",
                };
                return fail(ctx, "{s}: expected {s}, got {s}", .{ path, what, describe(ctx, L, idx) });
            }
            return setCollection(ctx, L, f, idx);
        },
    }
    return null;
}

fn setCollection(ctx: *Ctx, L: *State, f: *const Field, idx: c_int) ?[]const u8 {
    const cfg = ctx.cfg;
    const t = c.lua_absindex(L, idx);
    switch (f.kind) {
        .keys => cfg.keybinds.clearRetainingCapacity(),
        .string_map => cfg.shell_env.clearRetainingCapacity(),
        .string_list => cfg.shell_args.clearRetainingCapacity(),
        .palette => cfg.colors.palette = [_]?u32{null} ** 256,
        .ssh_profiles => cfg.ssh_profiles.clearRetainingCapacity(),
        .plugins => cfg.plugins.clearRetainingCapacity(),
        .layout => cfg.startup_layout.clearRetainingCapacity(),
        .ghost_patterns => {
            cfg.ghost_patterns.clearRetainingCapacity();
            cfg.ghost_patterns_set = true;
        },
        else => unreachable,
    }
    if (f.kind == .layout) {
        // In order: tabs open left to right.
        const n = c.lua_rawlen(L, t);
        var count: usize = 0;
        c.lua_pushnil(L);
        while (c.lua_next(L, t) != 0) {
            count += 1;
            const ok = c.lua_isinteger(L, -2) != 0;
            lua.pop(L, 1);
            if (!ok) {
                lua.pop(L, 1);
                return fail(ctx, "layout: expected a list of tabs (no named keys)", .{});
            }
        }
        if (count != n) return fail(ctx, "layout: expected a list of tabs (no gaps)", .{});
        var i: c.lua_Integer = 1;
        while (i <= n) : (i += 1) {
            _ = c.lua_rawgeti(L, t, i);
            defer lua.pop(L, 1);
            if (setLayoutTab(ctx, L, i, -1)) |m| return m;
        }
        return null;
    }
    if (f.kind == .string_list) {
        const n = c.luaL_len(L, t);
        var i: c.lua_Integer = 1;
        while (i <= n) : (i += 1) {
            _ = c.lua_rawgeti(L, t, i);
            defer lua.pop(L, 1);
            const s = lua.toString(L, -1) orelse return fail(ctx, "{s}[{d}]: expected a string, got {s}", .{ f.path, i, describe(ctx, L, -1) });
            cfg.shell_args.append(cfg.dupe(s) catch return "out of memory") catch return "out of memory";
        }
        return null;
    }
    if (f.kind == .ghost_patterns) {
        const n = c.luaL_len(L, t);
        if (n > 64) return fail(ctx, "{s}: at most 64 patterns", .{f.path});
        var i: c.lua_Integer = 1;
        while (i <= n) : (i += 1) {
            _ = c.lua_rawgeti(L, t, i);
            defer lua.pop(L, 1);
            const s = lua.toString(L, -1) orelse return fail(ctx, "{s}[{d}]: expected a string, got {s}", .{ f.path, i, describe(ctx, L, -1) });
            if (ghostPatternError(s)) |msg| return fail(ctx, "{s}[{d}]: {s}", .{ f.path, i, msg });
            cfg.ghost_patterns.append(cfg.dupe(s) catch return "out of memory") catch return "out of memory";
        }
        return null;
    }
    // A 1-based palette list maps to colours 0..n-1.
    var shift: c.lua_Integer = 0;
    if (f.kind == .palette) {
        _ = c.lua_rawgeti(L, t, 0);
        const has_zero = !lua.isNil(L, -1);
        lua.pop(L, 1);
        if (!has_zero and c.luaL_len(L, t) > 0) shift = 1;
    }
    c.lua_pushnil(L);
    while (c.lua_next(L, t) != 0) {
        // key at -2, value at -1
        if (f.kind == .palette and shift == 1 and c.lua_isinteger(L, -2) != 0) {
            const k = c.lua_tointegerx(L, -2, null) - 1;
            c.lua_pushinteger(L, k);
            if (setItem(ctx, L, f.path, -1, -2)) |m| {
                lua.pop(L, 3);
                return m;
            }
            lua.pop(L, 2);
            continue;
        }
        if (setItem(ctx, L, f.path, -2, -1)) |m| {
            lua.pop(L, 2);
            return m;
        }
        lua.pop(L, 1);
    }
    return null;
}

/// path[key] = value for a collection option.
fn setItem(ctx: *Ctx, L: *State, path: []const u8, key_idx: c_int, val_idx: c_int) ?[]const u8 {
    const f = field(path) orelse return fail(ctx, "unknown option '{s}'", .{path});
    const cfg = ctx.cfg;
    switch (f.kind) {
        .keys => {
            const chord = lua.toString(L, key_idx) orelse return fail(ctx, "keys: the key must be a chord string like \"ctrl+shift+t\", got {s}", .{describe(ctx, L, key_idx)});
            _ = events.parseChord(chord) catch return fail(ctx, "keys[\"{s}\"]: cannot parse the key chord (use e.g. \"ctrl+shift+t\", \"alt+page_up\")", .{chord});
            const action: []const u8 = switch (c.lua_type(L, val_idx)) {
                c.LUA_TBOOLEAN => if (c.lua_toboolean(L, val_idx) == 0) "none" else return actionError(ctx, L, chord, val_idx),
                c.LUA_TSTRING => lua.toString(L, val_idx).?,
                else => return actionError(ctx, L, chord, val_idx),
            };
            if (events.Action.parse(action) == null) return actionError(ctx, L, chord, val_idx);
            cfg.bind(chord, action) catch return "out of memory";
        },
        .string_map => {
            const name = lua.toString(L, key_idx) orelse return fail(ctx, "{s}: variable names must be strings, got {s}", .{ path, describe(ctx, L, key_idx) });
            if (name.len == 0 or std.mem.indexOfAny(u8, name, "=\x00") != null) return fail(ctx, "{s}: invalid variable name \"{s}\"", .{ path, name });
            const value = lua.toString(L, val_idx) orelse return fail(ctx, "{s}.{s}: expected a string, got {s}", .{ path, name, describe(ctx, L, val_idx) });
            const entry = std.fmt.allocPrint(cfg.arena.allocator(), "{s}={s}", .{ name, value }) catch return "out of memory";
            // Replace an earlier value for the same name.
            for (cfg.shell_env.items) |*e| {
                if (std.mem.startsWith(u8, e.*, name) and e.*.len > name.len and e.*[name.len] == '=') {
                    e.* = entry;
                    return null;
                }
            }
            cfg.shell_env.append(entry) catch return "out of memory";
        },
        .string_list => {
            if (c.lua_isinteger(L, key_idx) == 0) return fail(ctx, "{s}: index must be a number", .{path});
            const i = c.lua_tointegerx(L, key_idx, null);
            const n: c.lua_Integer = @intCast(cfg.shell_args.items.len);
            if (i < 1 or i > n + 1) return fail(ctx, "{s}[{d}]: index out of range (1..{d})", .{ path, i, n + 1 });
            const s = lua.toString(L, val_idx) orelse return fail(ctx, "{s}[{d}]: expected a string, got {s}", .{ path, i, describe(ctx, L, val_idx) });
            const owned = cfg.dupe(s) catch return "out of memory";
            if (i == n + 1) {
                cfg.shell_args.append(owned) catch return "out of memory";
            } else cfg.shell_args.items[@intCast(i - 1)] = owned;
        },
        .ghost_patterns => {
            if (c.lua_isinteger(L, key_idx) == 0) return fail(ctx, "{s}: index must be a number", .{path});
            const i = c.lua_tointegerx(L, key_idx, null);
            const n: c.lua_Integer = @intCast(cfg.ghost_patterns.items.len);
            if (i == n + 1 and n >= 64) return fail(ctx, "{s}: at most 64 patterns", .{path});
            if (i < 1 or i > n + 1) return fail(ctx, "{s}[{d}]: index out of range (1..{d})", .{ path, i, n + 1 });
            const s = lua.toString(L, val_idx) orelse return fail(ctx, "{s}[{d}]: expected a string, got {s}", .{ path, i, describe(ctx, L, val_idx) });
            if (ghostPatternError(s)) |msg| return fail(ctx, "{s}[{d}]: {s}", .{ path, i, msg });
            const owned = cfg.dupe(s) catch return "out of memory";
            cfg.ghost_patterns_set = true;
            if (i == n + 1) {
                cfg.ghost_patterns.append(owned) catch return "out of memory";
            } else cfg.ghost_patterns.items[@intCast(i - 1)] = owned;
        },
        .palette => {
            const ok_idx = c.lua_isinteger(L, key_idx) != 0;
            const i = c.lua_tointegerx(L, key_idx, null);
            if (!ok_idx or i < 0 or i > 255) return fail(ctx, "colors.palette: index must be 0..255, got {s}", .{describe(ctx, L, key_idx)});
            const v = parseColor(L, val_idx, false) orelse {
                var p: [32]u8 = undefined;
                return colorError(ctx, L, std.fmt.bufPrint(&p, "colors.palette[{d}]", .{i}) catch "colors.palette", val_idx, false);
            };
            cfg.colors.palette[@intCast(i)] = v;
        },
        .ssh_profiles => {
            const name = lua.toString(L, key_idx) orelse return fail(ctx, "ssh.profiles: profile names must be strings, got {s}", .{describe(ctx, L, key_idx)});
            if (name.len == 0 or std.mem.indexOfAny(u8, name, " \t\r\n") != null) return fail(ctx, "ssh.profiles: invalid profile name \"{s}\"", .{name});
            if (c.lua_type(L, val_idx) != c.LUA_TTABLE) return fail(ctx, "ssh.profiles.{s}: expected a table like {{ host = \"example.com\", user = \"me\" }}, got {s}", .{ name, describe(ctx, L, val_idx) });
            const p = parseProfile(ctx, L, name, val_idx) catch |err| return switch (err) {
                error.Invalid => ctx.buf[0..ctx.msg_len],
                error.OutOfMemory => "out of memory",
            };
            for (cfg.ssh_profiles.items) |*e| if (std.mem.eql(u8, e.name, p.name)) {
                e.* = p;
                return null;
            };
            cfg.ssh_profiles.append(p) catch return "out of memory";
        },
        .layout => {
            if (c.lua_isinteger(L, key_idx) == 0) return fail(ctx, "layout: index must be a number", .{});
            return setLayoutTab(ctx, L, c.lua_tointegerx(L, key_idx, null), val_idx);
        },
        .plugins => {
            const name = lua.toString(L, key_idx) orelse return fail(ctx, "plugins: plugin names must be strings, got {s}", .{describe(ctx, L, key_idx)});
            if (!plugin_manifest.validName(name)) return fail(ctx, "plugins: invalid plugin name \"{s}\" (lowercase letters, digits, _ and -)", .{truncate(name, 64)});
            if (c.lua_type(L, val_idx) != c.LUA_TTABLE) return fail(ctx, "plugins.{s}: expected a table like {{ enabled = true, allow = {{ \"screen\" }} }}, got {s}", .{ name, describe(ctx, L, val_idx) });
            const pc = parsePlugin(ctx, L, name, val_idx) catch |err| return switch (err) {
                error.Invalid => ctx.buf[0..ctx.msg_len],
                error.OutOfMemory => "out of memory",
            };
            for (cfg.plugins.items) |*e| if (std.mem.eql(u8, e.name, pc.name)) {
                e.* = pc;
                return null;
            };
            cfg.plugins.append(pc) catch return "out of memory";
        },
        else => return fail(ctx, "{s} is not a table option", .{path}),
    }
    return null;
}

fn pluginInt(ctx: *Ctx, L: *State, name: []const u8, key: []const u8, idx: c_int, min: f64, max: f64) !u16 {
    const v = c.lua_tonumberx(L, idx, null);
    if (c.lua_type(L, idx) != c.LUA_TNUMBER or v != @floor(v) or v < min or v > max)
        return invalid(ctx, "plugins.{s}.{s}: expected a whole number from {d} to {d}, got {s}", .{ name, key, min, max, describe(ctx, L, idx) });
    return @intFromFloat(v);
}

/// A list of strings at `idx` (each checked by `check`, which returns an
/// error message or null).
fn pluginStrings(ctx: *Ctx, L: *State, name: []const u8, key: []const u8, idx_in: c_int, example: []const u8, check: *const fn ([]const u8) ?[]const u8) ![]const []const u8 {
    const idx = c.lua_absindex(L, idx_in);
    if (c.lua_type(L, idx) != c.LUA_TTABLE) return invalid(ctx, "plugins.{s}.{s}: expected a list like {s}, got {s}", .{ name, key, example, describe(ctx, L, idx) });
    var list = std.ArrayList([]const u8).init(ctx.cfg.arena.allocator());
    const n = c.lua_rawlen(L, idx);
    var i: c.lua_Integer = 1;
    while (i <= n) : (i += 1) {
        _ = c.lua_rawgeti(L, idx, i);
        defer lua.pop(L, 1);
        const v = lua.toString(L, -1) orelse return invalid(ctx, "plugins.{s}.{s}[{d}]: expected a string, got {s}", .{ name, key, i, describe(ctx, L, -1) });
        if (check(v)) |msg| return invalid(ctx, "plugins.{s}.{s}[{d}]: \"{s}\": {s}", .{ name, key, i, truncate(v, 80), msg });
        try list.append(try ctx.cfg.dupe(v));
    }
    return list.items;
}

fn checkPermissionName(s: []const u8) ?[]const u8 {
    if (plugin_permissions.Permission.parse(s) == null) return "unknown permission (known: screen, input, pty, clipboard, network, exec, fs, ai)";
    return null;
}

fn checkProgram(s: []const u8) ?[]const u8 {
    if (s.len == 0 or std.mem.indexOfAny(u8, s, " \t\x00") != null) return "expected a program name like \"git\" or an absolute path";
    if (std.mem.indexOfScalar(u8, s, '/') != null and s[0] != '/') return "use a bare name (looked up in $PATH) or an absolute path";
    return null;
}

fn checkHost(s: []const u8) ?[]const u8 {
    if (s.len == 0 or s.len > 253 or std.mem.indexOfAny(u8, s, "/ @?#") != null) return "expected a host like \"api.example.com\", \"*.example.com\" or \"localhost:8080\"";
    return null;
}

/// One `plugins.<name> = { ... }` table at `idx`.
fn parsePlugin(ctx: *Ctx, L: *State, name_in: []const u8, idx_in: c_int) error{ Invalid, OutOfMemory }!PluginConfig {
    const cfg = ctx.cfg;
    const idx = c.lua_absindex(L, idx_in);
    var p = PluginConfig{ .name = try cfg.dupe(name_in) };
    const name = p.name;
    c.lua_pushnil(L);
    while (c.lua_next(L, idx) != 0) {
        defer lua.pop(L, 1);
        const key = lua.toString(L, -2) orelse return invalid(ctx, "plugins.{s}: option names must be strings", .{name});
        if (std.mem.eql(u8, key, "enabled")) {
            if (c.lua_type(L, -1) != c.LUA_TBOOLEAN) return invalid(ctx, "plugins.{s}.enabled: expected true or false, got {s}", .{ name, describe(ctx, L, -1) });
            p.enabled = c.lua_toboolean(L, -1) != 0;
        } else if (std.mem.eql(u8, key, "allow")) {
            const names = try pluginStrings(ctx, L, name, key, -1, "{ \"screen\", \"exec\" }", checkPermissionName);
            for (names) |n| p.allow.insert(plugin_permissions.Permission.parse(n).?);
        } else if (std.mem.eql(u8, key, "exec")) {
            p.exec = try pluginStrings(ctx, L, name, key, -1, "{ \"git\" }", checkProgram);
        } else if (std.mem.eql(u8, key, "hosts")) {
            p.hosts = try pluginStrings(ctx, L, name, key, -1, "{ \"api.example.com\" }", checkHost);
        } else if (std.mem.eql(u8, key, "memory_mb")) {
            p.memory_mb = try pluginInt(ctx, L, name, key, -1, 1, 1024);
        } else if (std.mem.eql(u8, key, "cpu_ms")) {
            p.cpu_ms = try pluginInt(ctx, L, name, key, -1, 5, 10_000);
        } else if (std.mem.eql(u8, key, "settings")) {
            if (c.lua_type(L, -1) != c.LUA_TTABLE) return invalid(ctx, "plugins.{s}.settings: expected a table, got {s}", .{ name, describe(ctx, L, -1) });
            p.settings = plugin_value.fromLua(cfg.arena.allocator(), L, -1) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return invalid(ctx, "plugins.{s}.settings: {s}", .{ name, plugin_value.errorText(err) }),
            };
        } else {
            return invalid(ctx, "plugins.{s}: unknown option '{s}' (plugins have: {s})", .{ name, key, PluginConfig.fields });
        }
    }
    return p;
}

pub const max_layout_tabs = 16;
pub const max_layout_panes = 16;

/// layout[i] = { ... } (append when i is one past the end).
fn setLayoutTab(ctx: *Ctx, L: *State, i: c.lua_Integer, val_idx: c_int) ?[]const u8 {
    const cfg = ctx.cfg;
    const n: c.lua_Integer = @intCast(cfg.startup_layout.items.len);
    if (i < 1 or i > n + 1) return fail(ctx, "layout[{d}]: index out of range (1..{d})", .{ i, n + 1 });
    if (i == n + 1 and n >= max_layout_tabs) return fail(ctx, "layout: at most {d} tabs", .{max_layout_tabs});
    var path_buf: [32]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "layout[{d}]", .{i}) catch "layout";
    var panes: usize = 0;
    var title: []const u8 = "";
    const root = parseLayoutNode(ctx, L, val_idx, path, 0, "", &panes, &title) catch |err| return switch (err) {
        error.Invalid => ctx.buf[0..ctx.msg_len],
        error.OutOfMemory => "out of memory",
    };
    const tab = cfg_mod.LayoutTab{ .title = title, .root = root };
    if (i == n + 1) {
        cfg.startup_layout.append(tab) catch return "out of memory";
    } else cfg.startup_layout.items[@intCast(i - 1)] = tab;
    return null;
}

const layout_fields = "title, split, ratio, panes, cwd, command, ssh, focus";

fn parseLayoutNode(ctx: *Ctx, L: *State, idx_in: c_int, path: []const u8, depth: u8, inherit_cwd: []const u8, panes: *usize, title: *[]const u8) error{ Invalid, OutOfMemory }!cfg_mod.LayoutNode {
    const cfg = ctx.cfg;
    const idx = c.lua_absindex(L, idx_in);
    if (c.lua_type(L, idx) != c.LUA_TTABLE) return invalid(ctx, "{s}: expected a table like {{ cwd = \"~/src\", command = \"vim\" }}, got {s}", .{ path, describe(ctx, L, idx) });
    if (depth > 6) return invalid(ctx, "{s}: splits nested too deeply", .{path});
    var node = cfg_mod.LayoutNode{};
    var has_panes = false;
    c.lua_pushnil(L);
    while (c.lua_next(L, idx) != 0) {
        defer lua.pop(L, 1);
        const key = lua.toString(L, -2) orelse return invalid(ctx, "{s}: option names must be strings (put panes in `panes = {{ ... }}`)", .{path});
        if (std.mem.eql(u8, key, "split")) {
            const v = lua.toString(L, -1) orelse "";
            if (std.mem.eql(u8, v, "right") or std.mem.eql(u8, v, "horizontal")) {
                node.split = .right;
            } else if (std.mem.eql(u8, v, "down") or std.mem.eql(u8, v, "vertical")) {
                node.split = .down;
            } else return invalid(ctx, "{s}.split: expected \"right\" (side by side) or \"down\" (stacked), got {s}", .{ path, describe(ctx, L, -1) });
        } else if (std.mem.eql(u8, key, "ratio")) {
            const v = c.lua_tonumberx(L, -1, null);
            if (c.lua_type(L, -1) != c.LUA_TNUMBER or v < 0.05 or v > 0.95) return invalid(ctx, "{s}.ratio: expected a number from 0.05 to 0.95, got {s}", .{ path, describe(ctx, L, -1) });
            node.ratio = @floatCast(v);
        } else if (std.mem.eql(u8, key, "panes")) {
            has_panes = true;
        } else if (std.mem.eql(u8, key, "focus")) {
            if (c.lua_type(L, -1) != c.LUA_TBOOLEAN) return invalid(ctx, "{s}.focus: expected true or false, got {s}", .{ path, describe(ctx, L, -1) });
            node.focus = c.lua_toboolean(L, -1) != 0;
        } else if (std.mem.eql(u8, key, "title") or std.mem.eql(u8, key, "cwd") or std.mem.eql(u8, key, "command") or std.mem.eql(u8, key, "ssh")) {
            const v = lua.toString(L, -1) orelse return invalid(ctx, "{s}.{s}: expected a string, got {s}", .{ path, key, describe(ctx, L, -1) });
            if (v.len > 4096) return invalid(ctx, "{s}.{s}: too long", .{ path, key });
            const d = try cfg.dupe(v);
            switch (key[1]) {
                'i' => {
                    if (depth != 0) return invalid(ctx, "{s}.title: only a tab (top level) has a title", .{path});
                    title.* = d;
                },
                'w' => node.cwd = d,
                'o' => {
                    if (std.mem.indexOfAny(u8, v, "\r\n") != null) return invalid(ctx, "{s}.command: one line only", .{path});
                    node.command = d;
                },
                else => node.ssh = d,
            }
        } else return invalid(ctx, "{s}: unknown option '{s}' (layouts have: {s})", .{ path, key, layout_fields });
    }
    // A split's cwd is the default for its panes.
    if (node.cwd.len == 0) node.cwd = inherit_cwd;
    if (node.split == null) {
        if (has_panes) return invalid(ctx, "{s}: `panes` needs `split = \"right\"` or `\"down\"`", .{path});
        panes.* += 1;
        if (panes.* > max_layout_panes) return invalid(ctx, "{s}: at most {d} panes per tab", .{ path, max_layout_panes });
        if (node.ssh.len > 0 and node.command.len > 0) return invalid(ctx, "{s}: a pane has either `ssh` or `command`", .{path});
        return node;
    }
    if (!has_panes) return invalid(ctx, "{s}: a split needs `panes = {{ {{...}}, {{...}} }}`", .{path});
    _ = c.lua_getfield(L, idx, "panes");
    defer lua.pop(L, 1);
    const pidx = c.lua_absindex(L, -1);
    if (c.lua_type(L, pidx) != c.LUA_TTABLE) return invalid(ctx, "{s}.panes: expected a list of panes, got {s}", .{ path, describe(ctx, L, pidx) });
    const n = c.lua_rawlen(L, pidx);
    if (n < 2) return invalid(ctx, "{s}.panes: a split needs at least 2 panes", .{path});
    const kids = try cfg.arena.allocator().alloc(cfg_mod.LayoutNode, @intCast(n));
    var i: c.lua_Integer = 1;
    while (i <= n) : (i += 1) {
        _ = c.lua_rawgeti(L, pidx, i);
        defer lua.pop(L, 1);
        var cb: [128]u8 = undefined;
        const cp = std.fmt.bufPrint(&cb, "{s}.panes[{d}]", .{ path, i }) catch path;
        kids[@intCast(i - 1)] = try parseLayoutNode(ctx, L, -1, cp, depth + 1, node.cwd, panes, title);
    }
    node.children = kids;
    return node;
}

const profile_fields = "host, port, user, identity_file, jump, env, command, theme, forwards, keepalive_s, reconnect";

fn invalid(ctx: *Ctx, comptime fmt: []const u8, args: anytype) error{Invalid} {
    ctx.msg_len = (std.fmt.bufPrint(&ctx.buf, fmt, args) catch blk: {
        const m = "invalid value (message too long)";
        @memcpy(ctx.buf[0..m.len], m);
        break :blk ctx.buf[0..m.len];
    }).len;
    return error.Invalid;
}

fn profileString(ctx: *Ctx, L: *State, name: []const u8, key: []const u8, idx: c_int) ![]const u8 {
    const s = lua.toString(L, idx) orelse return invalid(ctx, "ssh.profiles.{s}.{s}: expected a string, got {s}", .{ name, key, describe(ctx, L, idx) });
    return ctx.cfg.dupe(s);
}

fn profileInt(ctx: *Ctx, L: *State, name: []const u8, key: []const u8, idx: c_int, min: f64, max: f64) !u16 {
    const v = c.lua_tonumberx(L, idx, null);
    if (c.lua_type(L, idx) != c.LUA_TNUMBER or v != @floor(v) or v < min or v > max)
        return invalid(ctx, "ssh.profiles.{s}.{s}: expected a whole number from {d} to {d}, got {s}", .{ name, key, min, max, describe(ctx, L, idx) });
    return @intFromFloat(v);
}

/// One `ssh.profiles.<name> = { ... }` table at `idx`.
fn parseProfile(ctx: *Ctx, L: *State, name_in: []const u8, idx_in: c_int) error{ Invalid, OutOfMemory }!SshProfile {
    const cfg = ctx.cfg;
    const a = cfg.arena.allocator();
    const idx = c.lua_absindex(L, idx_in);
    var p = SshProfile{ .name = try cfg.dupe(name_in) };
    const name = p.name;
    c.lua_pushnil(L);
    while (c.lua_next(L, idx) != 0) {
        defer lua.pop(L, 1);
        const key = lua.toString(L, -2) orelse return invalid(ctx, "ssh.profiles.{s}: option names must be strings", .{name});
        if (std.mem.eql(u8, key, "host")) {
            p.host = try profileString(ctx, L, name, key, -1);
            _ = @import("../ssh/target.zig").parseSpec(p.host) catch return invalid(ctx, "ssh.profiles.{s}.host: expected \"host\", \"user@host\" or \"host:port\", got \"{s}\"", .{ name, p.host });
        } else if (std.mem.eql(u8, key, "port")) {
            p.port = try profileInt(ctx, L, name, key, -1, 1, 65535);
        } else if (std.mem.eql(u8, key, "user")) {
            p.user = try profileString(ctx, L, name, key, -1);
        } else if (std.mem.eql(u8, key, "identity_file")) {
            p.identity_file = try profileString(ctx, L, name, key, -1);
        } else if (std.mem.eql(u8, key, "jump")) {
            p.jump = try profileString(ctx, L, name, key, -1);
            if (!std.ascii.eqlIgnoreCase(p.jump, "none")) {
                var it = std.mem.tokenizeAny(u8, p.jump, ", ");
                while (it.next()) |hop| _ = @import("../ssh/target.zig").parseSpec(hop) catch
                    return invalid(ctx, "ssh.profiles.{s}.jump: expected \"[user@]host[:port]\" (comma-separated for several hops), got \"{s}\"", .{ name, hop });
            }
        } else if (std.mem.eql(u8, key, "command")) {
            p.command = try profileString(ctx, L, name, key, -1);
        } else if (std.mem.eql(u8, key, "theme")) {
            const s = lua.toString(L, -1) orelse "";
            const th = themes.find(s) orelse {
                var names: [256]u8 = undefined;
                return invalid(ctx, "ssh.profiles.{s}.theme: unknown theme {s} (bundled: {s})", .{ name, describe(ctx, L, -1), themeNames(&names) });
            };
            p.theme = th.name;
        } else if (std.mem.eql(u8, key, "keepalive_s")) {
            p.keepalive_s = try profileInt(ctx, L, name, key, -1, 0, 3600);
        } else if (std.mem.eql(u8, key, "reconnect")) {
            if (c.lua_type(L, -1) != c.LUA_TBOOLEAN) return invalid(ctx, "ssh.profiles.{s}.reconnect: expected true or false, got {s}", .{ name, describe(ctx, L, -1) });
            p.reconnect = c.lua_toboolean(L, -1) != 0;
        } else if (std.mem.eql(u8, key, "env")) {
            if (c.lua_type(L, -1) != c.LUA_TTABLE) return invalid(ctx, "ssh.profiles.{s}.env: expected a table like {{ LANG = \"en_US.UTF-8\" }}, got {s}", .{ name, describe(ctx, L, -1) });
            var env = std.ArrayList([]const u8).init(a);
            const t = c.lua_absindex(L, -1);
            c.lua_pushnil(L);
            while (c.lua_next(L, t) != 0) {
                defer lua.pop(L, 1);
                const k = lua.toString(L, -2) orelse "";
                const v = lua.toString(L, -1);
                if (k.len == 0 or std.mem.indexOfAny(u8, k, "=\x00 ") != null or v == null) {
                    return invalid(ctx, "ssh.profiles.{s}.env: expected NAME = \"value\" string pairs", .{name});
                }
                try env.append(try std.fmt.allocPrint(a, "{s}={s}", .{ k, v.? }));
            }
            p.env = env.items;
        } else if (std.mem.eql(u8, key, "forwards")) {
            if (c.lua_type(L, -1) != c.LUA_TTABLE) return invalid(ctx, "ssh.profiles.{s}.forwards: expected a list like {{ \"L 8080:localhost:80\", \"D 1080\" }}, got {s}", .{ name, describe(ctx, L, -1) });
            var list = std.ArrayList(ssh_forward.Forward).init(a);
            const t = c.lua_absindex(L, -1);
            const n = c.luaL_len(L, t);
            var i: c.lua_Integer = 1;
            while (i <= n) : (i += 1) {
                _ = c.lua_rawgeti(L, t, i);
                defer lua.pop(L, 1);
                var enabled = true;
                var spec: ?[]const u8 = lua.toString(L, -1);
                if (spec == null and c.lua_type(L, -1) == c.LUA_TTABLE) {
                    _ = c.lua_rawgeti(L, -1, 1);
                    spec = lua.toString(L, -1);
                    lua.pop(L, 1);
                    _ = c.lua_getfield(L, -1, "enabled");
                    if (c.lua_type(L, -1) == c.LUA_TBOOLEAN) enabled = c.lua_toboolean(L, -1) != 0;
                    lua.pop(L, 1);
                }
                const sp = spec orelse {
                    return invalid(ctx, "ssh.profiles.{s}.forwards[{d}]: expected a string like \"L 8080:localhost:80\" or {{ \"D 1080\", enabled = false }}", .{ name, i });
                };
                var fw = ssh_forward.parse(sp) catch |err| {
                    return invalid(ctx, "ssh.profiles.{s}.forwards[{d}]: \"{s}\": {s}", .{ name, i, sp, ssh_forward.errorText(err) });
                };
                fw.enabled = enabled;
                try list.append(try fw.dupe(a));
            }
            p.forwards = list.items;
        } else {
            return invalid(ctx, "ssh.profiles.{s}: unknown option '{s}' (profiles have: {s})", .{ name, key, profile_fields });
        }
    }
    return p;
}

fn actionError(ctx: *Ctx, L: *State, chord: []const u8, idx: c_int) []const u8 {
    var names: [512]u8 = undefined;
    var w = std.io.fixedBufferStream(&names);
    inline for (@typeInfo(events.Action).Enum.fields, 0..) |af, i| {
        if (i > 1) w.writer().writeAll(", ") catch {};
        if (i > 0) w.writer().writeAll(af.name) catch {};
    }
    return fail(ctx, "keys[\"{s}\"]: unknown action {s} (use false to unbind; actions: {s})", .{ chord, describe(ctx, L, idx), w.getWritten() });
}

fn colorError(ctx: *Ctx, L: *State, path: []const u8, idx: c_int, allow_none: bool) []const u8 {
    return fail(ctx, "{s}: expected a colour like \"#1e1e2e\"{s}, got {s}", .{ path, if (allow_none) " or \"none\"" else "", describe(ctx, L, idx) });
}

fn choiceError(ctx: *Ctx, L: *State, path: []const u8, idx: c_int, choices: []const []const u8) []const u8 {
    var list: [256]u8 = undefined;
    var w = std.io.fixedBufferStream(&list);
    for (choices, 0..) |ch, i| {
        if (i > 0) w.writer().writeAll(", ") catch {};
        w.writer().print("\"{s}\"", .{ch}) catch {};
    }
    return fail(ctx, "{s}: expected one of {s}, got {s}", .{ path, w.getWritten(), describe(ctx, L, idx) });
}

fn themeNames(buf: []u8) []const u8 {
    var w = std.io.fixedBufferStream(buf);
    for (themes.all, 0..) |t, i| {
        if (i > 0) w.writer().writeAll(", ") catch {};
        w.writer().writeAll(t.name) catch {};
    }
    return w.getWritten();
}

/// "#rrggbb", "#rgb", 0xRRGGBB, or "none" (when allowed).
fn parseColor(L: *State, idx: c_int, allow_none: bool) ?u32 {
    if (c.lua_isinteger(L, idx) != 0) {
        const v = c.lua_tointegerx(L, idx, null);
        if (v < 0 or v > 0xFFFFFF) return null;
        return @intCast(v);
    }
    const s = lua.toString(L, idx) orelse return null;
    if (std.ascii.eqlIgnoreCase(s, "none")) return if (allow_none) @import("../terminal/color.zig").none else null;
    if (s.len < 1 or s[0] != '#') return null;
    const hex = s[1..];
    if (hex.len == 6) return std.fmt.parseInt(u32, hex, 16) catch null;
    if (hex.len == 3) {
        const v = std.fmt.parseInt(u32, hex, 16) catch return null;
        const r = (v >> 8) & 0xF;
        const g = (v >> 4) & 0xF;
        const b = v & 0xF;
        return (r * 17) << 16 | (g * 17) << 8 | b * 17;
    }
    return null;
}

// ------------------------------------------------------------ Zig → Lua

fn pushColor(L: *State, v: u32) void {
    if (v == @import("../terminal/color.zig").none) {
        lua.pushString(L, "none");
        return;
    }
    var b: [8]u8 = undefined;
    lua.pushString(L, std.fmt.bufPrint(&b, "#{x:0>6}", .{v}) catch "#000000");
}

/// get(path) / get(path, key): the current value (colours are effective,
/// i.e. theme plus overrides).
fn luaGet(Lopt: ?*State) callconv(.C) c_int {
    const L = Lopt.?;
    const ctx = ctxOf(L);
    const cfg = ctx.cfg;
    const path = lua.toString(L, 1) orelse return 0;
    const f = field(path) orelse return 0;
    const has_key = c.lua_gettop(L) >= 2;
    switch (f.kind) {
        .palette => {
            if (!has_key or c.lua_isinteger(L, 2) == 0) return 0;
            const i = c.lua_tointegerx(L, 2, null);
            if (i < 0 or i > 255) return 0;
            pushColor(L, cfg.palette().colors[@intCast(i)]);
        },
        .string_map => {
            const name = if (has_key) lua.toString(L, 2) orelse return 0 else return 0;
            var it = std.mem.reverseIterator(cfg.shell_env.items);
            while (it.next()) |e| {
                if (std.mem.startsWith(u8, e, name) and e.len > name.len and e[name.len] == '=') {
                    lua.pushString(L, e[name.len + 1 ..]);
                    return 1;
                }
            }
            return 0;
        },
        .string_list => {
            if (!has_key or c.lua_isinteger(L, 2) == 0) return 0;
            const i = c.lua_tointegerx(L, 2, null);
            if (i < 1 or i > cfg.shell_args.items.len) return 0;
            lua.pushString(L, cfg.shell_args.items[@intCast(i - 1)]);
        },
        .ghost_patterns => {
            if (!cfg.ghost_patterns_set) return 0;
            if (!has_key or c.lua_isinteger(L, 2) == 0) return 0;
            const i = c.lua_tointegerx(L, 2, null);
            if (i < 1 or i > cfg.ghost_patterns.items.len) return 0;
            lua.pushString(L, cfg.ghost_patterns.items[@intCast(i - 1)]);
        },
        .keys => {
            const chord = if (has_key) lua.toString(L, 2) orelse return 0 else return 0;
            var it = std.mem.reverseIterator(cfg.keybinds.items);
            while (it.next()) |e| {
                const eq = std.mem.lastIndexOfScalar(u8, e, '=') orelse continue;
                if (std.mem.eql(u8, e[0..eq], chord)) {
                    lua.pushString(L, e[eq + 1 ..]);
                    return 1;
                }
            }
            return 0;
        },
        .color => {
            const p = cfg.palette();
            const v: u32 = if (std.mem.endsWith(u8, path, ".foreground")) p.fg else if (std.mem.endsWith(u8, path, ".background")) p.bg else if (std.mem.endsWith(u8, path, ".cursor")) p.cursor else if (std.mem.endsWith(u8, path, ".cursor_text")) p.cursor_text else if (std.mem.endsWith(u8, path, ".selection_background")) p.selection_bg else p.selection_fg;
            pushColor(L, v);
        },
        .section => return 0,
        else => switch (f.ref.?(cfg)) {
            .boolean => |p| c.lua_pushboolean(L, @intFromBool(p.*)),
            .u16 => |p| c.lua_pushinteger(L, p.*),
            .u32 => |p| c.lua_pushinteger(L, p.*),
            .usize => |p| c.lua_pushinteger(L, @intCast(p.*)),
            .f32 => |p| c.lua_pushnumber(L, p.*),
            .string => |p| lua.pushString(L, p.*),
            .backend => |p| lua.pushString(L, @tagName(p.*)),
            .cursor => |p| lua.pushString(L, @tagName(p.*)),
            .color => unreachable,
        },
    }
    return 1;
}

/// theme(name) -> table of colours, or nil, message.
fn luaTheme(Lopt: ?*State) callconv(.C) c_int {
    const L = Lopt.?;
    const name = lua.toString(L, 1) orelse "";
    const t = themes.find(name) orelse {
        c.lua_pushnil(L);
        var names: [256]u8 = undefined;
        var msg: [400]u8 = undefined;
        lua.pushString(L, std.fmt.bufPrint(&msg, "unknown theme \"{s}\" (bundled: {s})", .{ truncate(name, 60), themeNames(&names) }) catch "unknown theme");
        return 2;
    };
    c.lua_createtable(L, 0, 7);
    const pairs = [_]struct { [:0]const u8, u32 }{
        .{ "foreground", t.fg },                     .{ "background", t.bg },
        .{ "cursor", t.cursor },                     .{ "cursor_text", t.cursor_text },
        .{ "selection_background", t.selection_bg }, .{ "selection_foreground", t.selection_fg },
    };
    for (pairs) |p| {
        pushColor(L, p[1]);
        c.lua_setfield(L, -2, p[0]);
    }
    c.lua_createtable(L, 16, 1);
    for (t.ansi, 0..) |v, i| {
        pushColor(L, v);
        c.lua_rawseti(L, -2, @intCast(i));
    }
    c.lua_setfield(L, -2, "palette");
    return 1;
}

/// print() from config.lua goes to stderr.
fn luaPrint(Lopt: ?*State) callconv(.C) c_int {
    const L = Lopt.?;
    const n = c.lua_gettop(L);
    var i: c_int = 1;
    std.debug.print("config.lua:", .{});
    while (i <= n) : (i += 1) {
        var len: usize = 0;
        const s = c.luaL_tolstring(L, i, &len);
        std.debug.print(" {s}", .{s[0..len]});
        lua.pop(L, 1);
    }
    std.debug.print("\n", .{});
    return 0;
}
