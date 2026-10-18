const std = @import("std");
const t = std.testing;
const config = @import("config.zig");
const lua_config = @import("lua_config.zig");
const color = @import("../terminal/color.zig");

fn loadStr(src: []const u8, diags: *config.Diagnostics) config.Config {
    var cfg = config.Config.init(t.allocator);
    lua_config.loadString(&cfg, src, "test.lua", .{}, diags);
    return cfg;
}

test "lua config: every section parses" {
    var d = config.Diagnostics.init(t.allocator);
    defer d.deinit();
    var cfg = loadStr(
        \\config.window.rows = 30
        \\config.window = { cols = 100, backend = "x11" }
        \\config.font.family = "Fira Code"
        \\config.font.size = 13.5
        \\config.font.line_height = 1.1
        \\config.font.ligatures = false
        \\config.font.retro = true
        \\config.theme = "nord"
        \\config.colors.background = "#101010"
        \\config.colors.palette[1] = "#f00"
        \\config.cursor.shape = "bar"
        \\config.render = { present_mode = "mailbox", max_fps = 60, read_budget_kb = 256 }
        \\config.scrollback.lines = 5000
        \\config.scrollback.scrollbar = false
        \\config.scrollback.wheel_lines = 5
        \\config.selection.copy_on_select = true
        \\config.selection.word_chars = "-_"
        \\config.clipboard.paste_confirm = false
        \\config.clipboard.osc52 = "read-write"
        \\config.links.open_command = "firefox"
        \\config.keys["ctrl+shift+t"] = "search"
        \\config.keys["ctrl+shift+c"] = false
        \\dt.bind("alt+c", "copy")
        \\config.shell = { program = "/bin/zsh", args = { "-l" }, env = { FOO = "bar" }, cwd = "~/src" }
        \\config.shell.env.BAZ = "1"
        \\config.ai = { enabled = false, endpoint = "http://x:1/v1", model = "m", api_key_env = "K" }
        \\config.ssh.keepalive_s = 10
        \\assert(config.font.size == 13.5)
        \\assert(config.colors.background == "#101010")
        \\assert(config.colors.foreground == "#d8dee9")
        \\assert(config.shell.env.FOO == "bar")
    , &d);
    defer cfg.deinit();
    d.print();
    try t.expectEqual(@as(usize, 0), d.items.items.len);
    try t.expectEqual(@as(u16, 30), cfg.rows);
    try t.expectEqual(@as(u16, 100), cfg.cols);
    try t.expectEqual(config.Config.Backend.x11, cfg.backend);
    try t.expectEqualStrings("Fira Code", cfg.font_family);
    try t.expectEqual(@as(f32, 13.5), cfg.font_size);
    try t.expect(cfg.font_retro and !cfg.font_ligatures);
    try t.expectEqualStrings("nord", cfg.theme);
    const p = cfg.palette();
    try t.expectEqual(@as(u32, 0x101010), p.bg);
    try t.expectEqual(@as(u32, 0xD8DEE9), p.fg);
    try t.expectEqual(@as(u32, 0xFF0000), p.colors[1]);
    try t.expectEqual(@as(u32, 0xA3BE8C), p.colors[2]);
    try t.expectEqual(config.CursorShape.bar, cfg.cursor_shape);
    try t.expectEqualStrings("mailbox", cfg.present_mode);
    try t.expectEqual(@as(u16, 60), cfg.max_fps);
    try t.expectEqual(@as(u32, 256), cfg.read_budget_kb);
    try t.expectEqual(@as(usize, 5000), cfg.scrollback_lines);
    try t.expect(!cfg.scrollbar);
    try t.expectEqual(@as(u16, 5), cfg.scroll_lines);
    try t.expect(cfg.copy_on_select);
    try t.expectEqualStrings("-_", cfg.word_chars);
    try t.expect(!cfg.paste_confirm);
    try t.expectEqualStrings("read-write", cfg.osc52);
    try t.expectEqualStrings("firefox", cfg.url_open_command);
    try t.expectEqual(@as(usize, 3), cfg.keybinds.items.len);
    try t.expectEqualStrings("ctrl+shift+c=none", cfg.keybinds.items[1]);
    try t.expectEqualStrings("alt+c=copy", cfg.keybinds.items[2]);
    try t.expectEqualStrings("/bin/zsh", cfg.shell_program);
    try t.expectEqualStrings("-l", cfg.shell_args.items[0]);
    try t.expectEqual(@as(usize, 2), cfg.shell_env.items.len);
    try t.expectEqualStrings("BAZ=1", cfg.shell_env.items[1]);
    try t.expectEqualStrings("~/src", cfg.shell_cwd);
    try t.expect(!cfg.ai_enabled);
    try t.expectEqualStrings("m", cfg.ai_model);
    try t.expectEqual(@as(u16, 10), cfg.ssh_keepalive_s);
}

test "lua config: returned table style and dt.theme" {
    var d = config.Diagnostics.init(t.allocator);
    defer d.deinit();
    var cfg = loadStr(
        \\local c = dt.theme("dracula")
        \\c.background = "#000000"
        \\return { colors = c, font = { size = 20 }, render = { present_mode = "vsync" } }
    , &d);
    defer cfg.deinit();
    try t.expectEqual(@as(usize, 0), d.items.items.len);
    const p = cfg.palette();
    try t.expectEqual(@as(u32, 0), p.bg);
    try t.expectEqual(@as(u32, 0xF8F8F2), p.fg);
    try t.expectEqual(@as(u32, 0xFF5555), p.colors[1]);
    try t.expectEqual(@as(f32, 20), cfg.font_size);
    try t.expectEqualStrings("fifo", cfg.present_mode);
}

test "lua config: validation errors carry file:line and keep going" {
    var d = config.Diagnostics.init(t.allocator);
    defer d.deinit();
    var cfg = loadStr(
        \\config.font.size = 200
        \\config.font.szie = 12
        \\config.clipboard.osc52 = "rw"
        \\config.theme = "draclua"
        \\config.colors.background = "blue"
        \\config.keys["ctrl+shift+q"] = "quit"
        \\config.fnt.size = 3
        \\config.render.max_fps = "fast"
        \\config.cursor.shape = "Bar"
    , &d);
    defer cfg.deinit();
    for (d.items.items) |it| std.debug.print("  {s}\n", .{it.text});
    try t.expectEqual(@as(usize, 8), d.errorCount());
    try t.expect(d.contains("test.lua:1: font.size: expected a number from 4 to 96, got 200"));
    try t.expect(d.contains("test.lua:2: unknown option 'font.szie' (did you mean 'font.size'?)"));
    try t.expect(d.contains("test.lua:3: clipboard.osc52: expected one of \"off\", \"write\", \"read-write\", got \"rw\""));
    try t.expect(d.contains("test.lua:4: theme: unknown theme \"draclua\""));
    try t.expect(d.contains("test.lua:5: colors.background: expected a colour"));
    try t.expect(d.contains("test.lua:6: keys[\"ctrl+shift+q\"]: unknown action \"quit\""));
    try t.expect(d.contains("test.lua:7: unknown option 'fnt'"));
    try t.expect(d.contains("test.lua:8: render.max_fps: expected a whole number"));
    // Valid lines still applied (case-insensitive choice).
    try t.expectEqual(config.CursorShape.bar, cfg.cursor_shape);
}

test "lua config: syntax and runtime errors" {
    var d = config.Diagnostics.init(t.allocator);
    defer d.deinit();
    var a = loadStr("config.font.size = = 3\n", &d);
    a.deinit();
    try t.expect(d.contains("test.lua:1:"));
    d.clear();
    var b = loadStr("\n\nlocal x = nil\nx.y = 1\n", &d);
    b.deinit();
    try t.expect(d.contains("test.lua:4: attempt to index"));
    d.clear();
    var e = loadStr("config.theme = dt.theme('nope')\n", &d);
    e.deinit();
    try t.expect(d.contains("test.lua:1: unknown theme \"nope\""));
}

test "lua config: sandbox hides io, os.execute and require" {
    var d = config.Diagnostics.init(t.allocator);
    defer d.deinit();
    var cfg = loadStr(
        \\assert(io == nil, "io")
        \\assert(os.execute == nil, "os.execute")
        \\assert(os.remove == nil and require == nil and dofile == nil and loadfile == nil and debug == nil)
        \\assert(os.getenv("HOME") ~= nil and type(os.time()) == "number")
        \\assert(load(string.dump(function() end)) == nil, "binary chunks")
        \\config.font.size = 12
    , &d);
    defer cfg.deinit();
    d.print();
    try t.expectEqual(@as(usize, 0), d.items.items.len);
    try t.expectEqual(@as(f32, 12), cfg.font_size);

    var u = config.Config.init(t.allocator);
    defer u.deinit();
    lua_config.loadString(&u, "assert(io and os.execute and require)", "u.lua", .{ .lua_unsafe = true }, &d);
    try t.expectEqual(@as(usize, 0), d.items.items.len);
}

test "lua config: runaway scripts are stopped" {
    var d = config.Diagnostics.init(t.allocator);
    defer d.deinit();
    var cfg = loadStr("while true do end", &d);
    cfg.deinit();
    try t.expect(d.contains("took too long"));
    d.clear();
    var m = loadStr("local t = {} while true do t[#t + 1] = ('x'):rep(4096) end", &d);
    m.deinit();
    try t.expect(d.contains("memory"));
}

test "lua config: config.example.lua is valid and matches the defaults" {
    var d = config.Diagnostics.init(t.allocator);
    defer d.deinit();
    var cfg = loadStr(@import("default_config").text, &d);
    defer cfg.deinit();
    d.print();
    try t.expectEqual(@as(usize, 0), d.items.items.len);
    var def = config.Config.init(t.allocator);
    defer def.deinit();
    inline for (.{ "rows", "cols", "scale", "backend", "headless", "font_size", "line_height", "font_retro", "font_ligatures", "cursor_shape", "max_fps", "read_budget_kb", "scrollback_lines", "scrollbar", "scroll_lines", "copy_on_select", "paste_confirm", "default_keybindings", "ai_enabled", "ssh_enabled", "ssh_keepalive_s" }) |name| {
        try t.expectEqual(@field(def, name), @field(cfg, name));
    }
    inline for (.{ "font_family", "theme", "present_mode", "osc52", "word_chars", "url_open_command", "shell_program", "shell_cwd", "ai_endpoint", "ai_model", "ai_api_key_env", "ssh_config_file" }) |name| {
        try t.expectEqualStrings(@field(def, name), @field(cfg, name));
    }
    try t.expectEqual(def.palette().hash(), cfg.palette().hash());
    try t.expectEqual(@as(usize, 0), cfg.shell_args.items.len + cfg.shell_env.items.len);
}

test "lua config: load() falls back to defaults on errors" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "config.lua", .data = "config.font.size = 14\nconfig.render.max_fps = -1\n" });
    const path = try tmp.dir.realpathAlloc(t.allocator, "config.lua");
    defer t.allocator.free(path);
    var d = config.Diagnostics.init(t.allocator);
    defer d.deinit();
    const args = [_][]const u8{"dt"};
    var cfg = try config.load(t.allocator, config.Source.fromPath(path), &args, .{}, &d);
    defer cfg.deinit();
    try t.expect(d.contains("config.lua:2: render.max_fps"));
    try t.expectEqual(@as(f32, 11), cfg.font_size);

    // Fixed file: loads cleanly.
    try tmp.dir.writeFile(.{ .sub_path = "config.lua", .data = "config.font.size = 14\n" });
    d.clear();
    var ok = try config.load(t.allocator, config.Source.fromPath(path), &args, .{}, &d);
    defer ok.deinit();
    try t.expectEqual(@as(usize, 0), d.items.items.len);
    try t.expectEqual(@as(f32, 14), ok.font_size);
}
