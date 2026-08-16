const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const terminal = @import("../terminal/terminal.zig");
const renderer = @import("../renderer/vulkan_renderer.zig");
const ai = @import("../ai/autocomplete.zig");
const ssh = @import("../ssh/tunnel.zig");
const lua_engine = @import("../scripting/lua_engine.zig");
const config = @import("../config/config.zig");

const POLL_TIMEOUT_MS: i32 = 16;
const READ_BUFFER_SIZE: usize = 4096;

var shutdown_requested = std.atomic.Value(bool).init(false);

fn handleSignal(sig: i32) callconv(.C) void {
    _ = sig;
    shutdown_requested.store(true, .seq_cst);
}

/// Main application event loop: PTY I/O, rendering, and subsystem ticks.
pub const EventLoop = struct {
    allocator: std.mem.Allocator,
    cfg: *const config.Config,

    pub fn run(
        self: *EventLoop,
        vulkan_renderer: *renderer.VulkanRenderer,
        term: *terminal.Terminal,
        lua: *lua_engine.LuaEngine,
        autocomplete: *ai.Autocomplete,
        ssh_manager: *ssh.TunnelManager,
    ) !void {
        _ = lua;
        _ = ssh_manager;

        if (!self.cfg.ai_enabled) {
            autocomplete.disable();
        } else {
            autocomplete.setEndpoint(self.cfg.ai_endpoint);
        }

        if (self.cfg.headless) {
            try self.runHeadless(vulkan_renderer, term, autocomplete);
        } else {
            try self.runHeadless(vulkan_renderer, term, autocomplete);
            std.debug.print("GUI mode is not implemented yet; running headless.\n", .{});
        }
    }

    fn runHeadless(
        self: *EventLoop,
        vulkan_renderer: *renderer.VulkanRenderer,
        term: *terminal.Terminal,
        autocomplete: *ai.Autocomplete,
    ) !void {
        _ = self;

        const pty_fd = term.getPtyFd() orelse return error.NoPty;
        try setNonBlocking(pty_fd);

        var stdin_raw = false;
        if (builtin.os.tag != .windows) {
            try enableRawMode();
            stdin_raw = true;
        }
        defer if (stdin_raw) disableRawMode() catch {};

        try installSignalHandlers();

        var read_buf: [READ_BUFFER_SIZE]u8 = undefined;
        var input_buf: [READ_BUFFER_SIZE]u8 = undefined;

        std.debug.print("Headless terminal active. Press Ctrl+C to exit.\n", .{});

        while (!shutdown_requested.load(.seq_cst)) {
            var poll_fds = [_]posix.pollfd{
                .{ .fd = pty_fd, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 },
            };

            const ready = posix.poll(&poll_fds, POLL_TIMEOUT_MS) catch 0;

            if (ready == 0) {
                try renderHeadless(term, vulkan_renderer);
                continue;
            }

            if (poll_fds[0].revents & posix.POLL.IN != 0) {
                const n = posix.read(pty_fd, &read_buf) catch |err| switch (err) {
                    error.WouldBlock => 0,
                    else => return err,
                };

                if (n == 0) {
                    std.debug.print("\nShell exited.\n", .{});
                    break;
                }

                try term.processOutput(read_buf[0..n]);
                try renderHeadless(term, vulkan_renderer);
            }

            if (poll_fds[1].revents & posix.POLL.IN != 0) {
                const n = posix.read(posix.STDIN_FILENO, &input_buf) catch |err| switch (err) {
                    error.WouldBlock => 0,
                    else => return err,
                };

                if (n == 0) break;

                if (input_buf[0] == 0x03 and n == 1) {
                    shutdown_requested.store(true, .seq_cst);
                    break;
                }

                _ = try term.write(input_buf[0..n]);

                if (autocomplete.enabled and n > 0) {
                    _ = autocomplete.getSuggestions("", input_buf[0..n]) catch {};
                }
            }
        }

        try renderHeadless(term, vulkan_renderer);
        std.debug.print("\n", .{});
    }
};

fn setNonBlocking(fd: posix.fd_t) !void {
    var fl_flags = try posix.fcntl(fd, posix.F.GETFL, 0);
    fl_flags |= 1 << @bitOffsetOf(posix.O, "NONBLOCK");
    _ = try posix.fcntl(fd, posix.F.SETFL, fl_flags);
}

fn installSignalHandlers() !void {
    if (builtin.os.tag == .windows) return;

    const action = posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = posix.empty_sigset,
        .flags = 0,
    };

    try posix.sigaction(posix.SIG.INT, &action, null);
    try posix.sigaction(posix.SIG.TERM, &action, null);
}

fn enableRawMode() !void {
    var termios = try posix.tcgetattr(posix.STDIN_FILENO);
    termios.lflag.ICANON = false;
    termios.lflag.ECHO = false;
    termios.cc[@intFromEnum(posix.V.MIN)] = 0;
    termios.cc[@intFromEnum(posix.V.TIME)] = 1;
    try posix.tcsetattr(posix.STDIN_FILENO, posix.TCSA.NOW, termios);
}

fn disableRawMode() !void {
    var termios = try posix.tcgetattr(posix.STDIN_FILENO);
    termios.lflag.ICANON = true;
    termios.lflag.ECHO = true;
    try posix.tcsetattr(posix.STDIN_FILENO, posix.TCSA.NOW, termios);
}

fn renderHeadless(term: *terminal.Terminal, vulkan_renderer: *renderer.VulkanRenderer) !void {
    _ = vulkan_renderer;

    var out: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&out);
    const writer = fbs.writer();

    try writer.writeAll("\x1b[H\x1b[2J");

    var row: u16 = 0;
    while (row < term.rows) : (row += 1) {
        var col: u16 = 0;
        while (col < term.cols) : (col += 1) {
            const cell = term.getCell(row, col) orelse continue;
            if (cell.char == ' ') continue;
            try writer.print("{u}", .{cell.char});
        }
        if (row + 1 < term.rows) try writer.writeAll("\n");
    }

    try writer.print("\x1b[{d};{d}H", .{ term.cursor_row + 1, term.cursor_col + 1 });
    _ = try posix.write(posix.STDOUT_FILENO, fbs.getWritten());
}

test "EventLoop exists" {
    const testing = std.testing;
    var cfg = config.Config.init(testing.allocator);
    defer cfg.deinit();
    const loop = EventLoop{ .allocator = testing.allocator, .cfg = &cfg };
    _ = loop;
    try testing.expect(true);
}
