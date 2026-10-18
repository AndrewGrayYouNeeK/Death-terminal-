const std = @import("std");
const builtin = @import("builtin");
const terminal = @import("terminal/terminal.zig");
const renderer = @import("renderer/vulkan_renderer.zig");
const shell_inject = @import("app/shell_inject.zig");
const ssh = @import("ssh/tunnel.zig");
const lua_engine = @import("scripting/lua_engine.zig");
const config = @import("config/config.zig");
const event_loop = @import("app/event_loop.zig");

const VERSION = "0.1.0";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len > 1) {
        if (std.mem.eql(u8, args[1], "--version") or std.mem.eql(u8, args[1], "-v")) {
            try printVersion();
            return;
        }
        if (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")) {
            try printHelp();
            return;
        }
    }
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--print-default-config")) {
            try std.io.getStdOut().writeAll(@import("default_config").text);
            return;
        }
    }
    for (args[1..], 1..) |a, i| {
        if (std.mem.eql(u8, a, "--print-shell-integration")) {
            const name = if (i + 1 < args.len) args[i + 1] else "";
            const sh = std.meta.stringToEnum(shell_inject.Shell, name) orelse {
                std.debug.print("usage: deathterminal --print-shell-integration bash|zsh|fish\n", .{});
                std.process.exit(2);
            };
            try std.io.getStdOut().writeAll(shell_inject.script(sh));
            return;
        }
    }

    // Print banner only for interactive runs
    try printBanner();

    // Config: defaults, then config.lua (or legacy config.txt), then flags.
    const config_arg = config.configArg(args);
    const load_opts = config.LoadOptions{ .lua_unsafe = hasFlag(args, "--lua-unsafe") };
    var diags = config.Diagnostics.init(allocator);
    defer diags.deinit();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const src = config.locate(&path_buf, config_arg);
    var cfg = try config.load(allocator, src, args, load_opts, &diags);
    defer cfg.deinit();
    if (src) |s| std.debug.print("Config: {s}{s}\n", .{ s.path, if (load_opts.lua_unsafe) " (unsafe Lua)" else "" });
    diags.print();
    if (diags.hasErrors()) std.debug.print("config: {d} error(s); using the defaults\n", .{diags.errorCount()});
    var watch_buf: [std.fs.max_path_bytes]u8 = undefined;
    const watch_path: ?[]const u8 = if (src) |s| s.path else config.userConfigPath(&watch_buf);

    std.debug.print("Initializing DeathTerminal...\n", .{});

    // Initialize subsystems
    std.debug.print("[1/5] Initializing Vulkan renderer...\n", .{});
    var vulkan_renderer = try renderer.VulkanRenderer.init(allocator);
    defer vulkan_renderer.deinit();

    std.debug.print("[2/5] Initializing terminal core...\n", .{});
    var shell_arena = std.heap.ArenaAllocator.init(allocator);
    defer shell_arena.deinit();
    const shell_opts = shell_inject.apply(shell_arena.allocator(), .{
        .program = cfg.shell_program,
        .args = cfg.shell_args.items,
        .env = cfg.shell_env.items,
        .cwd = cfg.shell_cwd,
    }, cfg.shell_integration);
    var term = try terminal.Terminal.initWithShell(allocator, cfg.rows, cfg.cols, cfg.scrollback_lines, shell_opts);
    defer term.deinit();

    std.debug.print("[3/5] Initializing Lua scripting engine...\n", .{});
    var lua = try lua_engine.LuaEngine.init(allocator);
    defer lua.deinit();

    if (cfg.ai_enabled) {
        std.debug.print("[4/5] AI suggestions: {s} at {s}\n", .{ cfg.ai_model, cfg.ai_endpoint });
    } else {
        std.debug.print("[4/5] AI suggestions disabled\n", .{});
    }

    std.debug.print("[5/5] Initializing SSH tunnel manager...\n", .{});
    var ssh_manager = try ssh.TunnelManager.init(allocator);
    defer ssh_manager.deinit();

    std.debug.print("\n✓ DeathTerminal initialized successfully\n", .{});

    var loop = event_loop.EventLoop{
        .allocator = allocator,
        .cfg = &cfg,
        .args = args,
        .config_arg = config_arg,
        .load_opts = load_opts,
        .watch_path = watch_path,
        .startup_diags = &diags,
    };
    try loop.run(&vulkan_renderer, &term, &lua, &ssh_manager);
}

fn hasFlag(args: []const []const u8, flag: []const u8) bool {
    for (args[1..]) |a| if (std.mem.eql(u8, a, flag)) return true;
    return false;
}

fn printBanner() !void {
    const banner =
        \\
        \\ ██████╗ ███████╗ █████╗ ████████╗██╗  ██╗
        \\ ██╔══██╗██╔════╝██╔══██╗╚══██╔══╝██║  ██║
        \\ ██║  ██║█████╗  ███████║   ██║   ███████║
        \\ ██║  ██║██╔══╝  ██╔══██║   ██║   ██╔══██║
        \\ ██████╔╝███████╗██║  ██║   ██║   ██║  ██║
        \\ ╚═════╝ ╚══════╝╚═╝  ╚═╝   ╚═╝   ╚═╝  ╚═╝
        \\     ████████╗███████╗██████╗ ███╗   ███╗██╗███╗   ██╗ █████╗ ██╗
        \\     ╚══██╔══╝██╔════╝██╔══██╗████╗ ████║██║████╗  ██║██╔══██╗██║
        \\        ██║   █████╗  ██████╔╝██╔████╔██║██║██╔██╗ ██║███████║██║
        \\        ██║   ██╔══╝  ██╔══██╗██║╚██╔╝██║██║██║╚██╗██║██╔══██║██║
        \\        ██║   ███████╗██║  ██║██║ ╚═╝ ██║██║██║ ╚████║██║  ██║███████╗
        \\        ╚═╝   ╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝╚══════╝
        \\
        \\        Brutalist Terminal Emulator with AI-Powered Autocomplete
        \\
    ;
    std.debug.print("{s}\n", .{banner});
}

fn printVersion() !void {
    std.debug.print("DeathTerminal v{s}\n", .{VERSION});
    std.debug.print("Built with Zig {s}\n", .{builtin.zig_version_string});
    std.debug.print("Target: {s}-{s}\n", .{ @tagName(builtin.cpu.arch), @tagName(builtin.os.tag) });
}

fn printHelp() !void {
    const help_text =
        \\DeathTerminal - Brutalist Terminal Emulator
        \\
        \\USAGE:
        \\    deathterminal [OPTIONS]
        \\
        \\OPTIONS:
        \\    -h, --help       Print this help message
        \\    -v, --version    Print version information
        \\    --config <file>  Config file (.lua, or legacy key = value .txt). Default:
        \\                     $XDG_CONFIG_HOME/death-terminal/config.lua (~/.config/...)
        \\    --print-default-config  Print a documented config.lua with every default
        \\    --lua-unsafe     Give config.lua the full Lua library (io, os.execute, require)
        \\    --print-shell-integration <bash|zsh|fish>  Print the OSC 133 shell snippet
        \\    --no-ai          Disable AI command suggestions
        \\    --headless       Run without a GUI window (default)
        \\    --gui            Open a native window (Wayland/X11/Win32; falls back to headless)
        \\    --scale <n>      UI scale 1–4 (default: auto from DPI / compositor / env)
        \\    --backend <name>  Window backend: auto | x11 | wayland | win32
        \\    --font <retro|default>  Font renderer (retro = built-in 8x8 bitmap)
        \\    --font-family <name>    Font family via fontconfig (default: bundled JetBrains Mono)
        \\    --font-size <pt>        Font size in points (default: 11; Ctrl+= / Ctrl+- / Ctrl+0 zoom)
        \\    --line-height <n>       Cell height multiplier (default: 1.0)
        \\
        \\    Command-line flags override config.lua. Saving config.lua (or Ctrl+Shift+R)
        \\    reloads it live; see docs/CONFIG.md.
        \\
        \\FEATURES:
        \\    • AI command suggestions (OpenAI-compatible, local Ollama by default)
        \\    • Cross-platform SSH tunneling
        \\    • Vulkan-accelerated rendering
        \\    • Lua scripting support
        \\    • Brutalist, high-performance design
        \\
        \\For more information, visit: https://github.com/AndrewGrayYouNeeK/Death-terminal-
        \\
    ;
    std.debug.print("{s}\n", .{help_text});
}

test {
    _ = @import("terminal/terminal.zig");
    _ = @import("terminal/ansi_parser.zig");
    _ = @import("terminal/scrollback.zig");
    _ = @import("terminal/grid_test.zig");
    _ = @import("terminal/unicode.zig");
    _ = @import("terminal/color.zig");
    _ = @import("terminal/pty.zig");
    _ = @import("terminal/input.zig");
    _ = @import("renderer/vulkan_renderer.zig");
    _ = @import("renderer/loader.zig");
    _ = @import("renderer/vulkan_c.zig");
    _ = @import("renderer/pipeline.zig");
    _ = @import("renderer/text_renderer.zig");
    _ = @import("renderer/gpu_present.zig");
    _ = @import("renderer/text_pipeline.zig");
    _ = @import("renderer/software.zig");
    _ = @import("platform/window.zig");
    _ = @import("platform/dpi.zig");
    _ = @import("platform/events.zig");
    _ = @import("font/atlas.zig");
    _ = @import("font/box.zig");
    _ = @import("font/discovery.zig");
    _ = @import("font/face_set.zig");
    _ = @import("font/retro.zig");
    _ = @import("font/fonts.zig");
    _ = @import("renderer/frame.zig");
    _ = @import("terminal/selection.zig");
    _ = @import("terminal/search.zig");
    _ = @import("terminal/urls.zig");
    _ = @import("app/ui.zig");
    _ = @import("platform/wayland_backend.zig");
    _ = @import("platform/win32_backend.zig");
    _ = @import("app/event_loop.zig");
    _ = @import("app/config_watch.zig");
    _ = @import("config/config.zig");
    _ = @import("config/themes.zig");
    _ = @import("config/lua_config.zig");
    _ = @import("config/lua_config_test.zig");
    _ = @import("scripting/lua.zig");
    _ = @import("ai/redact.zig");
    _ = @import("ai/openai.zig");
    _ = @import("ai/context.zig");
    _ = @import("ai/engine.zig");
    _ = @import("app/ai_controller.zig");
    _ = @import("app/shell_inject.zig");
    _ = @import("ssh/tunnel.zig");
    _ = @import("scripting/lua_engine.zig");
}

test "basic functionality" {
    const testing = std.testing;
    try testing.expect(true);
}
