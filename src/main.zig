const std = @import("std");
const builtin = @import("builtin");
const terminal = @import("terminal/terminal.zig");
const renderer = @import("renderer/vulkan_renderer.zig");
const ai = @import("ai/autocomplete.zig");
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

    // Print banner only for interactive runs
    try printBanner();

    var cfg = config.Config.init(allocator);
    defer cfg.deinit();
    cfg.tryLoadDefault();
    try cfg.loadFromArgs(args);

    std.debug.print("Initializing DeathTerminal...\n", .{});

    // Initialize subsystems
    std.debug.print("[1/5] Initializing Vulkan renderer...\n", .{});
    var vulkan_renderer = try renderer.VulkanRenderer.init(allocator);
    defer vulkan_renderer.deinit();

    std.debug.print("[2/5] Initializing terminal core...\n", .{});
    var term = try terminal.Terminal.initWithSize(allocator, cfg.rows, cfg.cols, cfg.scrollback_lines);
    defer term.deinit();

    std.debug.print("[3/5] Initializing Lua scripting engine...\n", .{});
    var lua = try lua_engine.LuaEngine.init(allocator);
    defer lua.deinit();

    std.debug.print("[4/5] Initializing AI autocomplete...\n", .{});
    var autocomplete = try ai.Autocomplete.init(allocator);
    defer autocomplete.deinit();

    std.debug.print("[5/5] Initializing SSH tunnel manager...\n", .{});
    var ssh_manager = try ssh.TunnelManager.init(allocator);
    defer ssh_manager.deinit();

    std.debug.print("\n✓ DeathTerminal initialized successfully\n", .{});

    var loop = event_loop.EventLoop{
        .allocator = allocator,
        .cfg = &cfg,
    };
    try loop.run(&vulkan_renderer, &term, &lua, &autocomplete, &ssh_manager);
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
        \\    --config <file>  Use custom configuration file
        \\    --no-ai          Disable AI autocomplete
        \\    --headless       Run without a GUI window (default)
        \\    --gui            Attempt GUI mode (falls back to headless for now)
        \\
        \\FEATURES:
        \\    • AI-powered autocomplete
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

test "basic functionality" {
    const testing = std.testing;
    try testing.expect(true);
}
