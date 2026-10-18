const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const terminal = @import("../terminal/terminal.zig");
const renderer = @import("../renderer/vulkan_renderer.zig");
const software = @import("../renderer/software.zig");
const ai = @import("../ai/autocomplete.zig");
const ssh = @import("../ssh/tunnel.zig");
const lua_engine = @import("../scripting/lua_engine.zig");
const config = @import("../config/config.zig");
const window_mod = @import("../platform/window.zig");
const dpi = @import("../platform/dpi.zig");
const input = @import("../terminal/input.zig");
const fonts_mod = @import("../font/fonts.zig");
const frame_mod = @import("../renderer/frame.zig");

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
            self.runGui(vulkan_renderer, term, autocomplete) catch |err| {
                std.debug.print("GUI failed ({s}); falling back to headless.\n", .{@errorName(err)});
                try self.runHeadless(vulkan_renderer, term, autocomplete);
            };
        }
    }

    fn runGui(
        self: *EventLoop,
        vulkan_renderer: *renderer.VulkanRenderer,
        term: *terminal.Terminal,
        autocomplete: *ai.Autocomplete,
    ) !void {
        var scale: f32 = if (self.cfg.scale >= 1.0)
            dpi.normalize(self.cfg.scale)
        else
            dpi.detectEnvScale();

        var fonts = try fonts_mod.Fonts.init(self.allocator, .{
            .family = self.cfg.font_family,
            .size_pt = self.cfg.font_size,
            .line_height = self.cfg.line_height,
            .scale = scale,
            .retro = self.cfg.font_retro,
            .ligatures = self.cfg.font_ligatures,
        });
        defer fonts.deinit();
        var frame = frame_mod.Frame.init(self.allocator);
        defer frame.deinit();
        std.debug.print("  → Font: {s} {d:.1}pt, cell {d}x{d}px\n", .{ fonts.familyName(), fonts.size_pt, fonts.metrics.cell_w, fonts.metrics.cell_h });

        var soft = try software.SoftwareRenderer.init(self.allocator, term.cols, term.rows, .{ .w = fonts.metrics.cell_w, .h = fonts.metrics.cell_h });
        defer soft.deinit();

        var window = try window_mod.Window.open(self.allocator, .{
            .title = "DeathTerminal",
            .width = soft.width,
            .height = soft.height,
            .scale = self.cfg.scale,
            .backend = self.cfg.backend,
        });
        defer window.deinit();
        if (!window.isLive()) return error.NoWindowBackend;
        if (window.scale != scale) {
            scale = window.scale;
            _ = try fonts.setScale(scale);
            try regrid(term, &fonts, &soft, window.width, window.height);
        }
        defer vulkan_renderer.detachPresent();
        attachPresent(vulkan_renderer, &window);

        const pty_fd = term.getPtyFd() orelse return error.NoPty;
        try setNonBlocking(pty_fd);
        try installSignalHandlers();

        var read_buf: [READ_BUFFER_SIZE]u8 = undefined;
        var mouse = MouseState{};
        std.debug.print("GUI terminal active ({s}, scale={d:.2}). Close the window or exit the shell to quit.\n", .{
            @tagName(window.backend),
            window.scale,
        });
        var focused = true;
        try presentGui(term, vulkan_renderer, &soft, &window, &fonts, &frame, focused);

        while (!shutdown_requested.load(.seq_cst)) {
            var poll_fds = [_]posix.pollfd{
                .{ .fd = pty_fd, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = window.connectionFd() orelse -1, .events = posix.POLL.IN, .revents = 0 },
            };
            const nfd: usize = if (window.connectionFd() != null) 2 else 1;
            _ = posix.poll(poll_fds[0..nfd], POLL_TIMEOUT_MS) catch 0;

            var need_present = false;
            while (true) {
                switch (window.poll()) {
                    .none => break,
                    .close => {
                        shutdown_requested.store(true, .seq_cst);
                        break;
                    },
                    .resize => |sz| {
                        // HiDPI: the compositor may change the scale with the size.
                        if (window.scale != fonts.scale) _ = try fonts.setScale(window.scale);
                        try regrid(term, &fonts, &soft, sz.width, sz.height);
                        try vulkan_renderer.resize(sz.width, sz.height);
                        need_present = true;
                    },
                    .zoom => |step| {
                        if (try fonts.zoom(step)) {
                            try regrid(term, &fonts, &soft, window.width, window.height);
                            std.debug.print("  → zoom: {d:.1}pt, cell {d}x{d}, grid {d}x{d}\n", .{ fonts.size_pt, fonts.metrics.cell_w, fonts.metrics.cell_h, term.cols, term.rows });
                        }
                        need_present = true;
                    },
                    .redraw => need_present = true,
                    .input => |bytes| {
                        // Ctrl+C arrives as 0x03 and goes to the shell like any key.
                        _ = try term.write(bytes);
                        if (autocomplete.enabled) {
                            _ = autocomplete.getSuggestions("", bytes) catch {};
                        }
                    },
                    .key => |k| {
                        const seq = input.encodeKey(k.key, k.mods, term.modes);
                        _ = try term.write(seq.constSlice());
                    },
                    .mouse => |m| try handleMouse(term, &mouse, m, .{ .w = fonts.metrics.cell_w, .h = fonts.metrics.cell_h }),
                    .focus => |f| {
                        focused = f;
                        need_present = true;
                        if (input.encodeFocus(f, term.modes)) |seq| _ = try term.write(seq);
                    },
                }
            }

            if (poll_fds[0].revents & posix.POLL.IN == 0 and
                poll_fds[0].revents & (posix.POLL.HUP | posix.POLL.ERR) != 0)
            {
                std.debug.print("\nShell exited.\n", .{});
                break;
            }

            if (poll_fds[0].revents & posix.POLL.IN != 0) {
                const n = posix.read(pty_fd, &read_buf) catch |err| switch (err) {
                    error.WouldBlock => 0,
                    // Linux reports EIO on the master once the shell exits.
                    error.InputOutput => {
                        std.debug.print("\nShell exited.\n", .{});
                        break;
                    },
                    else => return err,
                };
                if (n == 0) {
                    std.debug.print("\nShell exited.\n", .{});
                    break;
                }
                try term.processOutput(read_buf[0..n]);
                need_present = true;
            }

            if (term.title_changed) {
                term.title_changed = false;
                window.setTitle(term.title);
            }

            if (need_present) {
                try presentGui(term, vulkan_renderer, &soft, &window, &fonts, &frame, focused);
            }
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
            stdin_raw = try enableRawMode();
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

            if (poll_fds[0].revents & posix.POLL.IN == 0 and
                poll_fds[0].revents & (posix.POLL.HUP | posix.POLL.ERR) != 0)
            {
                std.debug.print("\nShell exited.\n", .{});
                break;
            }

            if (poll_fds[0].revents & posix.POLL.IN != 0) {
                const n = posix.read(pty_fd, &read_buf) catch |err| switch (err) {
                    error.WouldBlock => 0,
                    // Linux reports EIO on the master once the shell exits.
                    error.InputOutput => {
                        std.debug.print("\nShell exited.\n", .{});
                        break;
                    },
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

fn enableRawMode() !bool {
    var termios = posix.tcgetattr(posix.STDIN_FILENO) catch |err| switch (err) {
        error.NotATerminal => return false,
        else => return err,
    };
    termios.lflag.ICANON = false;
    termios.lflag.ECHO = false;
    termios.cc[@intFromEnum(posix.V.MIN)] = 0;
    termios.cc[@intFromEnum(posix.V.TIME)] = 1;
    try posix.tcsetattr(posix.STDIN_FILENO, posix.TCSA.NOW, termios);
    return true;
}

fn disableRawMode() !void {
    var termios = posix.tcgetattr(posix.STDIN_FILENO) catch |err| switch (err) {
        error.NotATerminal => return,
        else => return err,
    };
    termios.lflag.ICANON = true;
    termios.lflag.ECHO = true;
    try posix.tcsetattr(posix.STDIN_FILENO, posix.TCSA.NOW, termios);
}

fn attachPresent(vulkan_renderer: *renderer.VulkanRenderer, window: *window_mod.Window) void {
    switch (window.backend) {
        .x11 => _ = vulkan_renderer.attachX11(window.x11DisplayPtr(), window.x11WindowId(), window.width, window.height),
        .wayland => _ = vulkan_renderer.attachWayland(window.waylandDisplayPtr(), window.waylandSurfacePtr(), window.width, window.height),
        .win32 => _ = vulkan_renderer.attachWin32(window.win32InstancePtr(), window.win32HwndPtr(), window.width, window.height),
        .none => {},
    }
}

const MouseState = struct {
    held: input.MouseButton = .none,
    last_col: u16 = std.math.maxInt(u16),
    last_row: u16 = std.math.maxInt(u16),
};

/// Number of arrow-key presses sent per wheel notch in the alternate screen
/// when the application did not enable mouse reporting (xterm's
/// "alternateScroll" behaviour, so `less`/`man` scroll with the wheel).
const ALT_SCROLL_LINES: usize = 3;

fn handleMouse(term: *terminal.Terminal, st: *MouseState, m: window_mod.MouseInput, cell: software.CellPx) !void {
    const col: u16 = @intCast(std.math.clamp(@divFloor(m.x, @as(i32, @intCast(cell.w))), 0, @as(i32, term.cols) - 1));
    const row: u16 = @intCast(std.math.clamp(@divFloor(m.y, @as(i32, @intCast(cell.h))), 0, @as(i32, term.rows) - 1));
    const wheel = switch (m.button) {
        .wheel_up, .wheel_down, .wheel_left, .wheel_right => true,
        else => false,
    };

    switch (m.action) {
        .press => if (!wheel) {
            st.held = m.button;
        },
        .release => st.held = .none,
        .motion => {
            if (col == st.last_col and row == st.last_row) return;
        },
    }
    st.last_col = col;
    st.last_row = row;

    if (term.modes.mouse == .off) {
        if (wheel and term.alt_active and m.action == .press) {
            const key: ?input.Key = switch (m.button) {
                .wheel_up => .up,
                .wheel_down => .down,
                else => null,
            };
            if (key) |k| {
                const seq = input.encodeKey(k, .{}, term.modes);
                for (0..ALT_SCROLL_LINES) |_| _ = try term.write(seq.constSlice());
            }
        }
        return;
    }

    const ev = input.MouseEvent{
        .action = m.action,
        .button = if (m.action == .motion) st.held else m.button,
        .col = col,
        .row = row,
        .mods = m.mods,
    };
    if (input.encodeMouse(ev, term.modes, st.held != .none)) |seq| {
        _ = try term.write(seq.constSlice());
    }
}

/// Fit the grid to a window of `width`×`height` px with the current cell
/// size; resizes the terminal (and so the PTY) when it changes.
fn regrid(term: *terminal.Terminal, fonts: *fonts_mod.Fonts, soft: *software.SoftwareRenderer, width: u32, height: u32) !void {
    const cell = fonts.cellSize();
    const cols: u16 = @intCast(std.math.clamp(width / cell.w, 1, 1000));
    const rows: u16 = @intCast(std.math.clamp(height / cell.h, 1, 500));
    if (cols != term.cols or rows != term.rows) try term.resize(rows, cols);
    try soft.resizePixels(width, height);
}

fn presentGui(
    term: *terminal.Terminal,
    vulkan_renderer: *renderer.VulkanRenderer,
    soft: *software.SoftwareRenderer,
    window: *window_mod.Window,
    fonts: *fonts_mod.Fonts,
    frame: *frame_mod.Frame,
    focused: bool,
) !void {
    try vulkan_renderer.render();
    var view = frame_mod.View.fromTerminal(term);
    view.focused = focused;
    try frame.build(fonts, term.buffer, term.rows, term.cols, term.cursor_row, term.cursor_col, view);
    if (vulkan_renderer.presentFrame(frame, &fonts.atlas)) {
        soft.dirty = false;
        return;
    }
    soft.render(frame, &fonts.atlas);
    if (!vulkan_renderer.presentPixels(soft.pixels, soft.width, soft.height)) {
        window.presentRgba(soft.pixels, soft.width, soft.height);
    }
    soft.dirty = false;
}

fn renderHeadless(term: *terminal.Terminal, vulkan_renderer: *renderer.VulkanRenderer) !void {
    try vulkan_renderer.render();
    try writeHeadlessFrame(term, std.io.getStdOut().writer());
}

/// Write the whole grid to `out` as UTF-8: home the cursor, emit every cell
/// (blanks included, so columns line up; wide-char spacers skipped because
/// the host terminal advances two columns for the wide glyph), then place
/// the cursor.
fn writeHeadlessFrame(term: *terminal.Terminal, out: anytype) !void {
    var buffered = std.io.bufferedWriter(out);
    const writer = buffered.writer();

    try writer.writeAll("\x1b[H");

    var row: u16 = 0;
    while (row < term.rows) : (row += 1) {
        const start = @as(usize, row) * @as(usize, term.cols);
        try terminal.appendRowText(term.buffer[start..][0..term.cols], writer);
        if (row + 1 < term.rows) try writer.writeAll("\r\n");
    }

    try writer.print("\x1b[{d};{d}H", .{ term.cursor_row + 1, term.cursor_col + 1 });
    try buffered.flush();
}

test "headless frame keeps blank columns" {
    var term = try terminal.Terminal.initBuffer(std.testing.allocator, 2, 12, 4);
    defer term.deinit();
    try term.processOutput("echo HELLO_DT");

    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    try writeHeadlessFrame(&term, out.writer());

    try std.testing.expect(std.mem.indexOf(u8, out.items, "echo HELLO_D") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "echoHELLO") == null);
}

test "EventLoop exists" {
    const testing = std.testing;
    var cfg = config.Config.init(testing.allocator);
    defer cfg.deinit();
    const loop = EventLoop{ .allocator = testing.allocator, .cfg = &cfg };
    _ = loop;
    try testing.expect(true);
}

test "headless frame emits UTF-8 and wide chars" {
    var term = try terminal.Terminal.initBuffer(std.testing.allocator, 1, 14, 4);
    defer term.deinit();
    try term.processOutput("h\xc3\xa9llo \xe6\x97\xa5\xe6\x9c\xac \xf0\x9f\x99\x82");

    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    try writeHeadlessFrame(&term, out.writer());

    try std.testing.expect(std.mem.indexOf(u8, out.items, "h\u{e9}llo \u{65e5}\u{672c} \u{1f642} ") != null);
}
