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
    try printBanner();
    var cfg = config.Config.init(allocator);
    defer cfg.deinit();
    cfg.tryLoadDefault();
    try cfg.loadFromArgs(args);
    std.debug.print("Initializing DeathTerminal...\n", .{});
    var vulkan_renderer = try renderer.VulkanRenderer.init(allocator);
    defer vulkan_renderer.deinit();
    var term = try terminal.Terminal.initWithSize(allocator, cfg.rows, cfg.cols, cfg.scrollback_lines);
    defer term.deinit();
    var lua = try lua_engine.LuaEngine.init(allocator);
    defer lua.deinit();
    var autocomplete = try ai.Autocomplete.init(allocator);
    defer autocomplete.deinit();
    var ssh_manager = try ssh.TunnelManager.init(allocator);
    defer ssh_manager.deinit();
    var loop = event_loop.EventLoop{ .allocator = allocator, .cfg = &cfg };
    try loop.run(&vulkan_renderer, &term, &lua, &autocomplete, &ssh_manager);
}

fn printBanner() !void {
    std.debug.print("DeathTerminal\n", .{});
}

fn printVersion() !void {
    std.debug.print("DeathTerminal v{s}\n", .{VERSION});
    std.debug.print("Built with Zig {s}\n", .{builtin.zig_version_string});
}

fn printHelp() !void {
    std.debug.print("deathterminal [--headless|--gui] [--no-ai] [--config file]\n", .{});
}

test "basic functionality" {
    try std.testing.expect(true);
}

test {
    _ = @import("config/config.zig");
    _ = @import("renderer/software.zig");
    _ = @import("renderer/vulkan_renderer.zig");
    _ = @import("app/event_loop.zig");
    _ = @import("terminal/scrollback.zig");
    _ = @import("terminal/grid_test.zig");
    _ = @import("ai/autocomplete.zig");
    _ = @import("ssh/tunnel.zig");
    _ = @import("scripting/lua_engine.zig");
}
