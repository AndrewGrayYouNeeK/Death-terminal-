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
const events = @import("../platform/events.zig");
const ui_mod = @import("ui.zig");

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

        installBindings(self.cfg);
        var ui = ui_mod.Ui.init(self.allocator, .{
            .copy_on_select = self.cfg.copy_on_select,
            .paste_confirm = self.cfg.paste_confirm,
            .osc52 = ui_mod.Osc52.parse(self.cfg.osc52) orelse .write,
            .scrollbar = self.cfg.scrollbar,
            .scroll_lines = self.cfg.scroll_lines,
            .word_chars = self.cfg.word_chars,
        });
        defer ui.deinit();
        var view = ViewBuffers.init(self.allocator);
        defer view.deinit();
        const gui = Gui{
            .term = term,
            .vk = vulkan_renderer,
            .soft = &soft,
            .window = &window,
            .fonts = &fonts,
            .frame = &frame,
            .ui = &ui,
            .view = &view,
            .cfg = self.cfg,
        };
        std.debug.print("GUI terminal active ({s}, scale={d:.2}). Close the window or exit the shell to quit.\n", .{
            @tagName(window.backend),
            window.scale,
        });
        var focused = true;
        try gui.present(focused);

        while (!shutdown_requested.load(.seq_cst)) {
            var poll_fds = [_]posix.pollfd{
                .{ .fd = pty_fd, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = window.connectionFd() orelse -1, .events = posix.POLL.IN, .revents = 0 },
            };
            const nfd: usize = if (window.connectionFd() != null) 2 else 1;
            const timeout: i32 = if (window.hasPending()) 0 else POLL_TIMEOUT_MS;
            _ = posix.poll(poll_fds[0..nfd], timeout) catch 0;

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
                    .action => |a| {
                        const step: ?i8 = switch (a.action) {
                            .zoom_in => 1,
                            .zoom_out => -1,
                            .zoom_reset => 0,
                            else => null,
                        };
                        if (step) |z| {
                            if (try fonts.zoom(z)) {
                                try regrid(term, &fonts, &soft, window.width, window.height);
                                std.debug.print("  → zoom: {d:.1}pt, cell {d}x{d}, grid {d}x{d}\n", .{ fonts.size_pt, fonts.metrics.cell_w, fonts.metrics.cell_h, term.cols, term.rows });
                            }
                        } else if (!try ui.handleAction(term, a.action)) {
                            // Not applicable here (e.g. Shift+PgUp in the
                            // alternate screen): the app gets the key.
                            if (events.keysymToKey(a.sym)) |key| {
                                const seq = input.encodeKey(key, a.mods, term.modes);
                                _ = try term.write(seq.constSlice());
                            }
                        }
                        need_present = true;
                    },
                    .paste => |p| {
                        try ui.onPaste(term, p.data, p.target, p.purpose);
                        need_present = true;
                    },
                    .redraw => need_present = true,
                    .input => |bytes| {
                        if (try ui.handleText(term, bytes)) {
                            need_present = true;
                        } else {
                            // Ctrl+C arrives as 0x03 and goes to the shell like any key.
                            ui.userTyped();
                            _ = try term.write(bytes);
                            if (autocomplete.enabled) {
                                _ = autocomplete.getSuggestions("", bytes) catch {};
                            }
                        }
                    },
                    .key => |k| {
                        if (try ui.handleKey(term, k.key, k.mods)) {
                            need_present = true;
                        } else {
                            ui.userTyped();
                            const seq = input.encodeKey(k.key, k.mods, term.modes);
                            _ = try term.write(seq.constSlice());
                        }
                    },
                    .mouse => |m| {
                        if (try ui.handleMouse(term, m, fonts.metrics.cell_w, fonts.metrics.cell_h, std.time.milliTimestamp())) {
                            need_present = true;
                        } else {
                            try handleMouse(term, &mouse, m, .{ .w = fonts.metrics.cell_w, .h = fonts.metrics.cell_h });
                        }
                    },
                    .focus => |f| {
                        focused = f;
                        need_present = true;
                        if (input.encodeFocus(f, term.modes)) |seq| _ = try term.write(seq);
                    },
                }
                try gui.runEffects();
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
                if (term.clipboard_ops.items.len > 0) {
                    const ops = try term.takeClipboardOps();
                    defer term.freeClipboardOps(ops);
                    try ui.onClipboardOps(ops);
                    try gui.runEffects();
                }
                ui.sync(term);
                need_present = true;
            }

            if (term.title_changed) {
                term.title_changed = false;
                window.setTitle(term.title);
            }

            if (need_present) {
                try gui.present(focused);
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

        std.debug.print("Headless terminal active. Ctrl+C goes to the shell; exit the shell (exit / Ctrl+D) to quit.\n", .{});

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

var saved_termios: ?posix.termios = null;

/// Put the host terminal in raw mode so every key (Ctrl+C, Ctrl+Z, Ctrl+S,
/// Ctrl+V ...) reaches the inner shell as a byte instead of being turned
/// into a signal or flow control for DeathTerminal itself.
fn enableRawMode() !bool {
    const orig = posix.tcgetattr(posix.STDIN_FILENO) catch |err| switch (err) {
        error.NotATerminal => return false,
        else => return err,
    };
    saved_termios = orig;
    try posix.tcsetattr(posix.STDIN_FILENO, posix.TCSA.NOW, rawTermios(orig));
    return true;
}

fn rawTermios(orig: posix.termios) posix.termios {
    var t = orig;
    t.lflag.ICANON = false;
    t.lflag.ECHO = false;
    t.lflag.ISIG = false; // Ctrl+C / Ctrl+Z / Ctrl+\ are bytes for the shell
    t.lflag.IEXTEN = false; // Ctrl+V literal-next
    t.iflag.IXON = false; // Ctrl+S / Ctrl+Q
    t.iflag.ICRNL = false; // Enter stays CR
    t.cc[@intFromEnum(posix.V.MIN)] = 0;
    t.cc[@intFromEnum(posix.V.TIME)] = 1;
    return t;
}

fn disableRawMode() !void {
    const orig = saved_termios orelse return;
    try posix.tcsetattr(posix.STDIN_FILENO, posix.TCSA.NOW, orig);
    saved_termios = null;
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

const ViewBuffers = struct {
    cells: std.ArrayList(terminal.Cell),
    marks: std.ArrayList(frame_mod.Mark),

    fn init(allocator: std.mem.Allocator) ViewBuffers {
        return .{ .cells = std.ArrayList(terminal.Cell).init(allocator), .marks = std.ArrayList(frame_mod.Mark).init(allocator) };
    }

    fn deinit(self: *ViewBuffers) void {
        self.cells.deinit();
        self.marks.deinit();
    }
};

/// Everything the GUI loop draws with and acts on.
const Gui = struct {
    term: *terminal.Terminal,
    vk: *renderer.VulkanRenderer,
    soft: *software.SoftwareRenderer,
    window: *window_mod.Window,
    fonts: *fonts_mod.Fonts,
    frame: *frame_mod.Frame,
    ui: *ui_mod.Ui,
    view: *ViewBuffers,
    cfg: *const config.Config,

    fn present(self: Gui, focused: bool) !void {
        try self.vk.render();
        const composed = try self.ui.compose(self.term, &self.view.cells, &self.view.marks);
        var v = frame_mod.View.fromTerminal(self.term);
        v.focused = focused;
        v.cursor_visible = composed.cursor_visible;
        v.marks = self.view.marks.items;
        v.selection_bg = self.cfg.selection_background;
        v.selection_fg = self.cfg.selection_foreground;
        if (composed.scrollbar) |sb| v.scrollbar = .{ .top = sb.top, .height = sb.height };
        try self.frame.build(self.fonts, self.view.cells.items, self.term.rows, self.term.cols, composed.cursor_row, composed.cursor_col, v);
        if (self.vk.presentFrame(self.frame, &self.fonts.atlas)) {
            self.soft.dirty = false;
            return;
        }
        self.soft.render(self.frame, &self.fonts.atlas);
        if (!self.vk.presentPixels(self.soft.pixels, self.soft.width, self.soft.height)) {
            self.window.presentRgba(self.soft.pixels, self.soft.width, self.soft.height);
        }
        self.soft.dirty = false;
    }

    /// Execute what the UI queued: PTY writes, clipboard, link opening.
    fn runEffects(self: Gui) !void {
        if (self.ui.effects.items.len == 0) return;
        const fx = try self.ui.takeEffects();
        defer self.ui.freeEffects(fx);
        for (fx) |e| switch (e) {
            .write => |bytes| _ = try self.term.write(bytes),
            .set_clipboard => |c| self.window.setClipboard(c.target, c.text),
            .request_paste => |r| self.window.requestClipboard(r.target, r.purpose),
            .open_url => |url| openUrl(self.cfg.url_open_command, url),
        };
    }
};

fn installBindings(cfg: *const config.Config) void {
    events.bindings = events.Bindings.defaults();
    for (cfg.keybinds.items) |spec| {
        events.bindings.apply(spec) catch |err| std.debug.print("config: keybind {s}: {s}\n", .{ spec, @errorName(err) });
    }
}

/// Launch `command url` detached (double fork, no shell). The URL has
/// already passed `urls.allowedTarget`.
fn openUrl(command: []const u8, url: []const u8) void {
    if (builtin.os.tag == .windows) return; // TODO: ShellExecuteW
    std.debug.print("  → open {s}\n", .{url});
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cmd_z = arena.dupeZ(u8, command) catch return;
    const url_z = arena.dupeZ(u8, url) catch return;
    const argv = [_:null]?[*:0]const u8{ cmd_z.ptr, url_z.ptr, null };
    const pid = posix.fork() catch return;
    if (pid == 0) {
        // Intermediate child: fork the opener and exit so it is reparented.
        if (builtin.os.tag == .linux) _ = std.os.linux.setsid();
        const pid2 = posix.fork() catch posix.exit(1);
        if (pid2 == 0) {
            const devnull = posix.openZ("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch posix.exit(1);
            posix.dup2(devnull, 0) catch {};
            posix.dup2(devnull, 1) catch {};
            posix.dup2(devnull, 2) catch {};
            const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
            _ = posix.execvpeZ(cmd_z.ptr, &argv, envp) catch {};
            posix.exit(127);
        }
        posix.exit(0);
    }
    _ = posix.waitpid(pid, 0);
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

test "raw mode keeps Ctrl+C away from signals" {
    var t = std.mem.zeroes(posix.termios);
    t.lflag.ISIG = true;
    t.lflag.ICANON = true;
    t.iflag.IXON = true;
    const r = rawTermios(t);
    try std.testing.expect(!r.lflag.ISIG);
    try std.testing.expect(!r.lflag.ICANON);
    try std.testing.expect(!r.iflag.IXON);
}
