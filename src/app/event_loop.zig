const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const terminal = @import("../terminal/terminal.zig");
const renderer = @import("../renderer/vulkan_renderer.zig");
const software = @import("../renderer/software.zig");
const ai_controller = @import("ai_controller.zig");
const ssh_target = @import("../ssh/target.zig");
const ssh_control = @import("../ssh/control.zig");
const ssh_palette = ui_mod.ssh_palette;
const lua_engine = @import("../scripting/lua_engine.zig");
const config = @import("../config/config.zig");
const window_mod = @import("../platform/window.zig");
const dpi = @import("../platform/dpi.zig");
const input = @import("../terminal/input.zig");
const fonts_mod = @import("../font/fonts.zig");
const frame_mod = @import("../renderer/frame.zig");
const events = @import("../platform/events.zig");
const ui_mod = @import("ui.zig");
const color = @import("../terminal/color.zig");
const config_watch = @import("config_watch.zig");

/// Wait this long after the last change event before reloading, so an
/// editor's write+rename save triggers one reload.
const RELOAD_DEBOUNCE_MS: i64 = 100;
/// How long the "config reloaded" notice stays up.
const RELOADED_NOTICE_MS: i64 = 3000;

/// Headless mode polls with this timeout so Ctrl+C / SIGTERM are noticed.
const HEADLESS_POLL_MS: i32 = 250;
const READ_BUFFER_SIZE: usize = 64 * 1024;
/// Longest the GUI parses PTY output before servicing input and drawing.
const READ_TIME_BUDGET_NS: u64 = 8 * std.time.ns_per_ms;

var shutdown_requested = std.atomic.Value(bool).init(false);

fn handleSignal(sig: i32) callconv(.C) void {
    _ = sig;
    shutdown_requested.store(true, .seq_cst);
}

/// Main application event loop: PTY I/O, rendering, and subsystem ticks.
pub const EventLoop = struct {
    allocator: std.mem.Allocator,
    /// Replaced in place when config.lua is reloaded.
    cfg: *config.Config,
    /// Command line, re-applied over the file on every reload.
    args: []const []const u8 = &.{},
    /// `--config` value, if given.
    config_arg: ?[]const u8 = null,
    load_opts: config.LoadOptions = .{},
    /// File to watch for live reload (may not exist yet).
    watch_path: ?[]const u8 = null,
    /// Problems from loading the config at startup, shown in the window.
    startup_diags: ?*const config.Diagnostics = null,
    /// `--ssh <target>`: the PTY runs the SSH client for this target.
    ssh_target: ?[]const u8 = null,
    /// "user@host[:port]" of that session (AI context, palette title).
    ssh_remote: []const u8 = "",

    fn aiSettings(self: *const EventLoop) ai_controller.Settings {
        var s = ai_controller.Settings.fromConfig(self.cfg);
        s.remote = self.ssh_remote;
        return s;
    }

    pub fn run(
        self: *EventLoop,
        vulkan_renderer: *renderer.VulkanRenderer,
        term: *terminal.Terminal,
        lua: *lua_engine.LuaEngine,
    ) !void {
        _ = lua;

        if (self.cfg.headless) {
            try self.runHeadless(vulkan_renderer, term);
        } else {
            self.runGui(vulkan_renderer, term) catch |err| {
                std.debug.print("GUI failed ({s}); falling back to headless.\n", .{@errorName(err)});
                try self.runHeadless(vulkan_renderer, term);
            };
        }
    }

    fn runGui(
        self: *EventLoop,
        vulkan_renderer: *renderer.VulkanRenderer,
        term: *terminal.Terminal,
    ) !void {
        var scale: f32 = if (self.cfg.scale >= 1.0)
            dpi.normalize(self.cfg.scale)
        else
            dpi.detectEnvScale();

        var fonts = try fonts_mod.Fonts.init(self.allocator, fontOptions(self.cfg, scale));
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
        vulkan_renderer.setPresentMode(renderer.PresentMode.parse(self.cfg.present_mode) orelse .fifo);
        attachPresent(vulkan_renderer, &window);

        const pty_fd = term.getPtyFd() orelse return error.NoPty;
        try setNonBlocking(pty_fd);
        try installSignalHandlers();

        const read_buf = try self.allocator.alloc(u8, READ_BUFFER_SIZE);
        defer self.allocator.free(read_buf);
        var mouse = MouseState{};
        var pace = Pacer{
            .frame_ns = frameNs(self.cfg.max_fps),
            .read_budget = @as(usize, self.cfg.read_budget_kb) * 1024,
        };

        installBindings(self.cfg);
        var ui = ui_mod.Ui.init(self.allocator, uiOptions(self.cfg));
        defer ui.deinit();
        var palette = self.cfg.palette();
        term.palette = palette;
        applyCursorShape(term, self.cfg.cursor_shape);
        var watcher: ?config_watch.Watcher = if (self.watch_path) |p| config_watch.Watcher.init(p) else null;
        defer if (watcher) |*w| w.deinit();
        // Pending debounced reload (ms timestamp).
        var reload_at: ?i64 = null;
        if (self.startup_diags) |d| if (d.items.items.len > 0) {
            try showDiagnostics(&ui, d, self.watch_path orelse "config", if (d.hasErrors()) "using the defaults" else null);
        };
        var view = ViewBuffers.init(self.allocator);
        defer view.deinit();
        var ai = ai_controller.Controller.init(self.allocator, self.aiSettings());
        defer ai.deinit();
        if (ai.engine != null) std.debug.print("  → AI: {s} via {s}\n", .{ self.cfg.ai_model, self.cfg.ai_endpoint });
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
            .palette = &palette,
            .pace = &pace,
            .ai = &ai,
            .loop = self,
        };
        std.debug.print("GUI terminal active ({s}, scale={d:.2}). Close the window or exit the shell to quit.\n", .{
            @tagName(window.backend),
            window.scale,
        });
        var focused = true;
        _ = try gui.present(focused, true);
        pace.presented(nowNs());
        // Set when something visible changed; drawn at the next frame slot.
        var need_present = false;
        // Expose/resize: the window contents are gone, redraw even if the
        // frame is unchanged.
        var force_present = false;
        // The last read stopped at the budget: more output is waiting.
        var pty_backlog = false;

        while (!shutdown_requested.load(.seq_cst)) {
            var poll_fds = [_]posix.pollfd{
                .{ .fd = pty_fd, .events = posix.POLL.IN, .revents = 0 },
                // A negative fd is ignored by poll.
                .{ .fd = window.connectionFd() orelse -1, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = if (watcher) |w| w.fd else -1, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = ai.wakeFd(), .events = posix.POLL.IN, .revents = 0 },
            };
            // Sleep until input, output or the next frame slot; with nothing
            // to do the timeout is infinite (no wakeups when idle).
            var timeout: i32 = if (window.hasPending() or pty_backlog)
                0
            else if (need_present or force_present)
                pace.msUntilNext(nowNs())
            else
                -1;
            const now_ms = std.time.milliTimestamp();
            if (reload_at) |t| timeout = minTimeout(timeout, t - now_ms);
            if (ui.noticeTimeout(now_ms)) |t| timeout = minTimeout(timeout, t);
            if (ai.timeout(now_ms)) |t| timeout = minTimeout(timeout, t);
            _ = posix.poll(&poll_fds, timeout) catch 0;
            pace.wakeups += 1;

            if (poll_fds[3].revents & posix.POLL.IN != 0) {
                if (try ai.onWake(&ui, term, std.time.milliTimestamp())) need_present = true;
            }
            ai.tick(term, std.time.milliTimestamp());

            if (poll_fds[2].revents & posix.POLL.IN != 0) {
                if (watcher) |*w| {
                    if (w.drain()) reload_at = std.time.milliTimestamp() + RELOAD_DEBOUNCE_MS;
                }
            }
            if (reload_at) |t| if (std.time.milliTimestamp() >= t) {
                reload_at = null;
                try gui.reloadConfig(self);
                need_present = true;
                force_present = true;
            };
            if (ui.tickNotice(std.time.milliTimestamp())) need_present = true;

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
                        ui.sync(term);
                        need_present = true;
                        force_present = true;
                    },
                    .action => |a| {
                        const step: ?i8 = switch (a.action) {
                            .zoom_in => 1,
                            .zoom_out => -1,
                            .zoom_reset => 0,
                            else => null,
                        };
                        if (a.action == .reload_config) {
                            reload_at = null;
                            try gui.reloadConfig(self);
                            force_present = true;
                        } else if (a.action == .ai_explain) {
                            try ai.explain(&ui, term, std.time.milliTimestamp());
                        } else if (a.action == .ssh_palette) {
                            if (ui.ssh_palette != null) ui.closeSshPalette() else try gui.openSshPalette();
                        } else if (step) |z| {
                            if (try fonts.zoom(z)) {
                                try regrid(term, &fonts, &soft, window.width, window.height);
                                std.debug.print("  → zoom: {d:.1}pt, cell {d}x{d}, grid {d}x{d}\n", .{ fonts.size_pt, fonts.metrics.cell_w, fonts.metrics.cell_h, term.cols, term.rows });
                            }
                        } else if (try ui.handleAction(term, a.action)) {
                            if (a.action == .ai_accept) ai.onAccepted();
                        } else {
                            // Not applicable here (e.g. Shift+PgUp in the
                            // alternate screen, Tab with no suggestion):
                            // the key goes on as if unbound.
                            if (events.keysymToKey(a.sym)) |key| {
                                if (!try ui.handleKey(term, key, a.mods)) {
                                    if (ui.userTyped()) need_present = true;
                                    const seq = input.encodeKey(key, a.mods, term.modes);
                                    _ = try term.write(seq.constSlice());
                                    ai.onKeystroke(&ui, std.time.milliTimestamp());
                                }
                            } else if (a.sym >= 0x20 and a.sym < 0x7f) {
                                // A printable key (e.g. Alt+]): Alt sends ESC first.
                                var b: [2]u8 = .{ 0x1b, @intCast(a.sym) };
                                const bytes: []const u8 = if (a.mods.alt) b[0..2] else b[1..2];
                                if (!try ui.handleText(term, bytes)) {
                                    _ = try term.write(bytes);
                                    ai.onKeystroke(&ui, std.time.milliTimestamp());
                                }
                            }
                        }
                        need_present = true;
                    },
                    .paste => |p| {
                        try ui.onPaste(term, p.data, p.target, p.purpose);
                        ai.onKeystroke(&ui, std.time.milliTimestamp());
                        need_present = true;
                    },
                    .redraw => {
                        need_present = true;
                        force_present = true;
                    },
                    .input => |bytes| {
                        if (try ui.handleText(term, bytes)) {
                            need_present = true;
                        } else {
                            // Ctrl+C arrives as 0x03 and goes to the shell like any key.
                            if (ui.userTyped()) need_present = true;
                            _ = try term.write(bytes);
                            ai.onTyped(&ui, term, bytes, std.time.milliTimestamp());
                            need_present = true;
                        }
                    },
                    .key => |k| {
                        if (try ui.handleKey(term, k.key, k.mods)) {
                            need_present = true;
                        } else {
                            if (ui.userTyped()) need_present = true;
                            const seq = input.encodeKey(k.key, k.mods, term.modes);
                            _ = try term.write(seq.constSlice());
                            ai.onKeystroke(&ui, std.time.milliTimestamp());
                            need_present = true;
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

            if (pty_backlog or poll_fds[0].revents & posix.POLL.IN != 0) {
                // Coalesce: parse everything available up to the byte/time
                // budget, then let input and drawing run before more.
                const start = nowNs();
                var total: usize = 0;
                pty_backlog = false;
                var exited = false;
                while (true) {
                    const n = posix.read(pty_fd, read_buf) catch |err| switch (err) {
                        error.WouldBlock => break,
                        // Linux reports EIO on the master once the shell exits.
                        error.InputOutput => {
                            exited = true;
                            break;
                        },
                        else => return err,
                    };
                    if (n == 0) {
                        exited = true;
                        break;
                    }
                    try term.processOutput(read_buf[0..n]);
                    total += n;
                    if (total >= pace.read_budget or nowNs() - start >= READ_TIME_BUDGET_NS) {
                        pty_backlog = true;
                        break;
                    }
                }
                if (total > 0) {
                    pace.bytes += total;
                    pace.batches += 1;
                    if (term.clipboard_ops.items.len > 0) {
                        const ops = try term.takeClipboardOps();
                        defer term.freeClipboardOps(ops);
                        try ui.onClipboardOps(ops);
                        try gui.runEffects();
                    }
                    ui.sync(term);
                    need_present = true;
                }
                if (exited) {
                    if (total > 0) _ = try gui.present(focused, true);
                    std.debug.print("\nShell exited.\n", .{});
                    break;
                }
            }

            if (term.title_changed) {
                term.title_changed = false;
                window.setTitle(term.title);
            }

            if ((need_present or force_present) and pace.due(nowNs())) {
                const drawn = try gui.present(focused, force_present);
                pace.presented(nowNs());
                if (drawn) pace.frames += 1 else pace.skipped += 1;
                need_present = false;
                force_present = false;
            }
        }
        if (std.posix.getenv("DT_PERF_STATS") != null) pace.report();
    }

    fn runHeadless(
        self: *EventLoop,
        vulkan_renderer: *renderer.VulkanRenderer,
        term: *terminal.Terminal,
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

        const read_buf = try std.heap.page_allocator.alloc(u8, READ_BUFFER_SIZE);
        defer std.heap.page_allocator.free(read_buf);
        var input_buf: [4096]u8 = undefined;
        // Redraw only after output, at most every 16 ms while it streams.
        var dirty = true;
        var last_draw: u64 = 0;

        std.debug.print("Headless terminal active. Ctrl+C goes to the shell; exit the shell (exit / Ctrl+D) to quit.\n", .{});

        while (!shutdown_requested.load(.seq_cst)) {
            var poll_fds = [_]posix.pollfd{
                .{ .fd = pty_fd, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 },
            };

            const ready = posix.poll(&poll_fds, if (dirty) 16 else HEADLESS_POLL_MS) catch 0;

            if (dirty and nowNs() - last_draw >= 16 * std.time.ns_per_ms) {
                try renderHeadless(term, vulkan_renderer);
                last_draw = nowNs();
                dirty = false;
            }
            if (ready == 0) continue;

            if (poll_fds[0].revents & posix.POLL.IN == 0 and
                poll_fds[0].revents & (posix.POLL.HUP | posix.POLL.ERR) != 0)
            {
                std.debug.print("\nShell exited.\n", .{});
                break;
            }

            if (poll_fds[0].revents & posix.POLL.IN != 0) {
                const n = posix.read(pty_fd, read_buf) catch |err| switch (err) {
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
                dirty = true;
            }

            if (poll_fds[1].revents & posix.POLL.IN != 0) {
                const n = posix.read(posix.STDIN_FILENO, &input_buf) catch |err| switch (err) {
                    error.WouldBlock => 0,
                    else => return err,
                };

                if (n == 0) break;

                _ = try term.write(input_buf[0..n]);
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
    cfg: *config.Config,
    /// Effective colours (theme + overrides) of `cfg`.
    palette: *color.Palette,
    pace: *Pacer,
    ai: *ai_controller.Controller,
    loop: *const EventLoop,

    /// Build the frame and draw it. Unchanged frames are not drawn unless
    /// `force` (expose/resize). Returns whether anything was presented.
    fn present(self: Gui, focused: bool, force: bool) !bool {
        try self.vk.render();
        const composed = try self.ui.compose(self.term, &self.view.cells, &self.view.marks);
        var v = frame_mod.View.fromTerminal(self.term);
        v.focused = focused;
        v.cursor_visible = composed.cursor_visible;
        v.marks = self.view.marks.items;
        v.palette = self.palette;
        v.selection_bg = self.palette.selection_bg;
        v.selection_fg = self.palette.selection_fg;
        if (composed.scrollbar) |sb| v.scrollbar = .{ .top = sb.top, .height = sb.height };
        try self.frame.build(self.fonts, self.view.cells.items, self.term.rows, self.term.cols, composed.cursor_row, composed.cursor_col, v);
        if (!self.frame.changed and !force) return false;
        switch (self.vk.presentFrame(self.frame, &self.fonts.atlas)) {
            .presented => {
                self.soft.dirty = false;
                return true;
            },
            .skipped => return false,
            .unavailable => {},
        }
        self.soft.renderDamage(self.frame, &self.fonts.atlas);
        if (!self.vk.presentPixels(self.soft.pixels, self.soft.width, self.soft.height)) {
            self.window.presentRgba(self.soft.pixels, self.soft.width, self.soft.height);
        }
        self.soft.dirty = false;
        return true;
    }

    /// Re-read the config file and apply what can change live. A file with
    /// errors leaves the running config untouched and shows why.
    fn reloadConfig(self: Gui, loop: *const EventLoop) !void {
        const allocator = self.cfg.allocator;
        var diags = config.Diagnostics.init(allocator);
        defer diags.deinit();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const src = config.locate(&buf, loop.config_arg);
        const shown_path = if (src) |sv| sv.path else loop.watch_path orelse "config";
        var next = config.Config.init(allocator);
        var adopted = false;
        defer if (!adopted) next.deinit();
        if (src) |sv| next.loadSource(sv, loop.load_opts, &diags);
        diags.print();
        if (diags.hasErrors()) {
            std.debug.print("config: reload failed, keeping the previous settings\n", .{});
            try showDiagnostics(self.ui, &diags, shown_path, "kept the previous settings");
            return;
        }
        next.loadFromArgs(loop.args) catch {};

        var restart = std.ArrayList(u8).init(allocator);
        defer restart.deinit();
        try restartOnlyChanges(self.cfg, &next, &restart);
        try self.applyConfig(&next);
        self.cfg.deinit();
        self.cfg.* = next;
        adopted = true;
        // Slices into the old config's arena were re-pointed by applyConfig.
        self.ui.opts = uiOptions(self.cfg);
        self.fonts.opts.family = self.cfg.font_family;
        self.ai.applySettings(self.ui, loop.aiSettings());

        std.debug.print("config: reloaded {s}\n", .{shown_path});
        var lines = std.ArrayList([]const u8).init(allocator);
        defer lines.deinit();
        for (diags.items.items) |it| try lines.append(it.text);
        var restart_line: []u8 = &.{};
        defer allocator.free(restart_line);
        if (restart.items.len > 0) {
            restart_line = try std.fmt.allocPrint(allocator, "restart DeathTerminal to apply: {s}", .{restart.items});
            try lines.append(restart_line);
        }
        var head_buf: [512]u8 = undefined;
        const head = std.fmt.bufPrint(&head_buf, "config reloaded: {s}", .{shown_path}) catch "config reloaded";
        const now = std.time.milliTimestamp();
        if (lines.items.len > 0) {
            try self.ui.setNotice(.warning, head, lines.items, 10 * RELOADED_NOTICE_MS, now);
        } else try self.ui.setNotice(.info, head, &.{}, RELOADED_NOTICE_MS, now);
    }

    /// Push `next`'s live settings into the running terminal.
    fn applyConfig(self: Gui, next: *const config.Config) !void {
        const old = self.cfg;
        self.palette.* = next.palette();
        self.term.palette = self.palette.*;
        applyCursorShape(self.term, next.cursor_shape);
        if (fontsChanged(old, next)) {
            if (fonts_mod.Fonts.init(self.cfg.allocator, fontOptions(next, self.fonts.scale))) |f_new| {
                var f = f_new;
                // New atlas contents: make sure no cache or GPU copy matches.
                f.atlas.generation = self.fonts.atlas.generation +% 1;
                f.atlas.epoch = self.fonts.atlas.epoch +% 1;
                self.fonts.deinit();
                self.fonts.* = f;
                self.frame.invalidate();
                try regrid(self.term, self.fonts, self.soft, self.window.width, self.window.height);
                self.ui.sync(self.term);
                std.debug.print("  → Font: {s} {d:.1}pt, cell {d}x{d}px\n", .{ self.fonts.familyName(), self.fonts.size_pt, self.fonts.metrics.cell_w, self.fonts.metrics.cell_h });
            } else |err| {
                std.debug.print("config: cannot load the new font ({s}); keeping the current one\n", .{@errorName(err)});
            }
        }
        self.vk.setPresentMode(renderer.PresentMode.parse(next.present_mode) orelse .fifo);
        self.pace.frame_ns = frameNs(next.max_fps);
        self.pace.read_budget = @as(usize, next.read_budget_kb) * 1024;
        installBindings(next);
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
            .ssh => |pick| try self.sshPick(pick),
        };
    }

    // ---------------------------------------------------------------- ssh

    /// pid of the SSH client when this window is an SSH session.
    fn sshPid(self: Gui) ?posix.pid_t {
        if (self.loop.ssh_target == null) return null;
        const p = self.term.pty orelse return null;
        return p.child_pid;
    }

    fn openSshPalette(self: Gui) !void {
        const pal = try self.ui.openSshPalette(if (self.loop.ssh_remote.len > 0) self.loop.ssh_remote else "profiles");
        try self.fillSshPalette(pal);
    }

    /// This session's forwards + reconnect (from the client's control
    /// socket), then profiles and ~/.ssh/config aliases.
    fn fillSshPalette(self: Gui, pal: *ssh_palette.Palette) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.cfg.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var items = std.ArrayList(ssh_palette.Item).init(a);
        if (self.sshPid()) |pid| {
            var out: [8192]u8 = undefined;
            if (ssh_control.request(pid, "list", &out)) |reply| {
                var lines = std.mem.splitScalar(u8, reply, '\n');
                while (lines.next()) |ln| {
                    const f = parseForwardLine(ln) orelse continue;
                    try items.append(.{ .kind = .forward, .name = try a.dupe(u8, f.spec), .detail = try a.dupe(u8, f.state), .forward = f.n, .on = f.on });
                }
            } else |_| try pal.setStatus(" session not reachable (still connecting?) ");
            try items.append(.{ .kind = .reconnect, .name = try a.dupe(u8, "Reconnect"), .detail = try a.dupe(u8, self.loop.ssh_remote) });
        }
        for (self.cfg.ssh_profiles.items) |p| {
            var db: [300]u8 = undefined;
            const detail = if (ssh_target.resolveForConfig(a, self.cfg.ssh_profiles.items, self.cfg.ssh_config_file, self.cfg.ssh_keepalive_s, p.name)) |t|
                try std.fmt.allocPrint(a, "{s}{s}{s}", .{ t.display(&db), if (t.jumps.len > 0) "  via jump" else "", if (t.forwards.len > 0) "  +forwards" else "" })
            else |_|
                try a.dupe(u8, "(invalid)");
            try items.append(.{ .kind = .profile, .name = try a.dupe(u8, p.name), .detail = detail });
        }
        // Lua table order is arbitrary: list profiles by name.
        const first_profile = blk: {
            for (items.items, 0..) |it, i| if (it.kind == .profile) break :blk i;
            break :blk items.items.len;
        };
        std.mem.sort(ssh_palette.Item, items.items[first_profile..], {}, struct {
            fn lt(_: void, x: ssh_palette.Item, y: ssh_palette.Item) bool {
                return std.mem.lessThan(u8, x.name, y.name);
            }
        }.lt);
        var aliases = std.ArrayList([]const u8).init(a);
        ssh_target.configAliases(a, self.cfg.ssh_config_file, &aliases);
        for (aliases.items) |name| {
            if (ssh_target.findProfile(self.cfg.ssh_profiles.items, name) != null) continue;
            try items.append(.{ .kind = .alias, .name = try a.dupe(u8, name), .detail = try a.dupe(u8, "~/.ssh/config") });
        }
        try pal.setItems(items.items);
    }

    fn sshPick(self: Gui, pick: ssh_palette.Pick) !void {
        const now = std.time.milliTimestamp();
        switch (pick) {
            .open => |name| {
                openSshWindow(self.loop, name);
                var hb: [300]u8 = undefined;
                try self.ui.setNotice(.info, std.fmt.bufPrint(&hb, "ssh: opening {s} in a new window", .{name}) catch "ssh: opening a new window", &.{}, RELOADED_NOTICE_MS, now);
            },
            .toggle => |n| {
                const pid = self.sshPid() orelse return;
                var cmd: [32]u8 = undefined;
                var out: [512]u8 = undefined;
                const reply = ssh_control.request(pid, std.fmt.bufPrint(&cmd, "toggle {d}", .{n}) catch "list", &out) catch "error session not reachable";
                if (self.ui.ssh_palette) |*pal| {
                    var spec: []const u8 = "forward";
                    for (pal.items.items) |it| if (it.kind == .forward and it.forward == n) {
                        spec = it.name;
                    };
                    var sb: [200]u8 = undefined;
                    try pal.setStatus(toggleStatus(&sb, spec, std.mem.trim(u8, reply, " \n")));
                    try self.fillSshPalette(pal);
                }
            },
            .reconnect => {
                const pid = self.sshPid() orelse return;
                var out: [64]u8 = undefined;
                _ = ssh_control.request(pid, "reconnect", &out) catch {};
            },
        }
    }
};

/// " L 8080:localhost:80 → on " from a control reply "ok on <state>".
fn toggleStatus(buf: []u8, spec: []const u8, reply: []const u8) []const u8 {
    if (std.mem.startsWith(u8, reply, "ok ")) {
        const r = reply[3..];
        const word = r[0 .. std.mem.indexOfScalar(u8, r, ' ') orelse r.len];
        return std.fmt.bufPrint(buf, " {s} \u{2192} {s} ", .{ spec, word }) catch " ok ";
    }
    const why = if (std.mem.startsWith(u8, reply, "error ")) reply[6..] else reply;
    return std.fmt.bufPrint(buf, " {s}: {s} ", .{ spec, why }) catch " error ";
}

test "toggleStatus" {
    var b: [200]u8 = undefined;
    try std.testing.expectEqualStrings(" D 1080 \u{2192} off ", toggleStatus(&b, "D 1080", "ok off off"));
    try std.testing.expectEqualStrings(" D 1080: session not reachable ", toggleStatus(&b, "D 1080", "error session not reachable"));
}

const ForwardLine = struct { n: usize, on: bool, spec: []const u8, state: []const u8 };

/// "<n> <on|off> <spec> | <state>" from the control socket's `list`.
fn parseForwardLine(line: []const u8) ?ForwardLine {
    var it = std.mem.splitScalar(u8, line, ' ');
    const n = std.fmt.parseInt(usize, it.next() orelse return null, 10) catch return null;
    const onoff = it.next() orelse return null;
    const rest = it.rest();
    const bar = std.mem.indexOf(u8, rest, " | ") orelse return null;
    return .{ .n = n, .on = std.mem.eql(u8, onoff, "on"), .spec = rest[0..bar], .state = rest[bar + 3 ..] };
}

test "parseForwardLine" {
    const f = parseForwardLine("2 off D 1080 | off").?;
    try std.testing.expectEqual(@as(usize, 2), f.n);
    try std.testing.expect(!f.on);
    try std.testing.expectEqualStrings("D 1080", f.spec);
    try std.testing.expectEqualStrings("off", f.state);
    try std.testing.expect(parseForwardLine("garbage") == null);
}

/// A new window process for `name` (same config file and safety flags).
fn openSshWindow(loop: *const EventLoop, name: []const u8) void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const exe = std.fs.selfExePathAlloc(a) catch return;
    var argv = std.ArrayList([]const u8).init(a);
    argv.appendSlice(&.{ exe, "--gui", "--ssh", name }) catch return;
    if (loop.config_arg) |c| argv.appendSlice(&.{ "--config", c }) catch return;
    if (loop.load_opts.lua_unsafe) argv.append("--lua-unsafe") catch return;
    if (!loop.cfg.ai_enabled) argv.append("--no-ai") catch return;
    spawnDetached(argv.items, false);
}

fn nowNs() u64 {
    return @intCast(std.time.nanoTimestamp());
}

/// Frame pacing and throughput counters for the GUI loop.
const Pacer = struct {
    /// Minimum time between presents (0 = uncapped).
    frame_ns: u64,
    read_budget: usize,
    last_present: u64 = 0,
    frames: u64 = 0,
    skipped: u64 = 0,
    wakeups: u64 = 0,
    bytes: u64 = 0,
    batches: u64 = 0,

    fn due(self: *const Pacer, now: u64) bool {
        return now -% self.last_present >= self.frame_ns;
    }

    fn msUntilNext(self: *const Pacer, now: u64) i32 {
        const elapsed = now -% self.last_present;
        if (elapsed >= self.frame_ns) return 0;
        const left = self.frame_ns - elapsed;
        return @intCast((left + std.time.ns_per_ms - 1) / std.time.ns_per_ms);
    }

    fn presented(self: *Pacer, now: u64) void {
        self.last_present = now;
    }

    fn report(self: *const Pacer) void {
        std.debug.print("perf: {d} frames presented, {d} unchanged skipped, {d} wakeups, {d} bytes in {d} batches\n", .{ self.frames, self.skipped, self.wakeups, self.bytes, self.batches });
    }
};

test "pacer waits for the next frame slot" {
    var p = Pacer{ .frame_ns = 10 * std.time.ns_per_ms, .read_budget = 1 };
    p.presented(100 * std.time.ns_per_ms);
    try std.testing.expect(!p.due(104 * std.time.ns_per_ms));
    try std.testing.expectEqual(@as(i32, 6), p.msUntilNext(104 * std.time.ns_per_ms));
    try std.testing.expect(p.due(110 * std.time.ns_per_ms));
    try std.testing.expectEqual(@as(i32, 0), p.msUntilNext(111 * std.time.ns_per_ms));
    var u = Pacer{ .frame_ns = 0, .read_budget = 1 };
    try std.testing.expect(u.due(0));
}

fn frameNs(max_fps: u16) u64 {
    return if (max_fps == 0) 0 else std.time.ns_per_s / @as(u64, max_fps);
}

/// Combine a poll timeout (-1 = infinite) with another wait in ms.
fn minTimeout(timeout: i32, ms: i64) i32 {
    const m: i32 = @intCast(std.math.clamp(ms, 0, std.math.maxInt(i32)));
    return if (timeout < 0) m else @min(timeout, m);
}

fn fontOptions(cfg: *const config.Config, scale: f32) fonts_mod.Options {
    return .{
        .family = cfg.font_family,
        .size_pt = cfg.font_size,
        .line_height = cfg.line_height,
        .scale = scale,
        .retro = cfg.font_retro,
        .ligatures = cfg.font_ligatures,
    };
}

fn fontsChanged(a: *const config.Config, b: *const config.Config) bool {
    return !std.mem.eql(u8, a.font_family, b.font_family) or a.font_size != b.font_size or
        a.line_height != b.line_height or a.font_retro != b.font_retro or a.font_ligatures != b.font_ligatures;
}

fn uiOptions(cfg: *const config.Config) ui_mod.Options {
    return .{
        .copy_on_select = cfg.copy_on_select,
        .paste_confirm = cfg.paste_confirm,
        .osc52 = ui_mod.Osc52.parse(cfg.osc52) orelse .write,
        .scrollbar = cfg.scrollbar,
        .scroll_lines = cfg.scroll_lines,
        .word_chars = cfg.word_chars,
    };
}

/// New default cursor shape; also applied now unless an app chose one.
fn applyCursorShape(term: *terminal.Terminal, shape: config.CursorShape) void {
    const s: terminal.CursorShape = switch (shape) {
        .block => .block,
        .underline => .underline,
        .bar => .bar,
    };
    if (term.cursor_shape == term.default_cursor_shape) term.cursor_shape = s;
    term.default_cursor_shape = s;
}

/// Names of changed options that only apply to new terminals.
fn restartOnlyChanges(a: *const config.Config, b: *const config.Config, out: *std.ArrayList(u8)) !void {
    const w = out.writer();
    var first = true;
    const names = [_]struct { []const u8, bool }{
        .{ "window.rows/cols", a.rows != b.rows or a.cols != b.cols },
        .{ "window.scale", a.scale != b.scale },
        .{ "window.backend", a.backend != b.backend },
        .{ "scrollback.lines", a.scrollback_lines != b.scrollback_lines },
        .{ "shell.program", !std.mem.eql(u8, a.shell_program, b.shell_program) },
        .{ "shell.args", !eqlList(a.shell_args.items, b.shell_args.items) },
        .{ "shell.env", !eqlList(a.shell_env.items, b.shell_env.items) },
        .{ "shell.cwd", !std.mem.eql(u8, a.shell_cwd, b.shell_cwd) },
        .{ "shell.integration", a.shell_integration != b.shell_integration },
    };
    for (names) |n| if (n[1]) {
        if (!first) try w.writeAll(", ");
        try w.writeAll(n[0]);
        first = false;
    };
}

fn eqlList(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

/// "/a/b/config.lua:3: msg" -> "config.lua:3: msg".
fn shortenPath(text: []const u8) []const u8 {
    const colon = std.mem.indexOf(u8, text, ": ") orelse return text;
    const slash = std.mem.lastIndexOfScalar(u8, text[0..colon], '/') orelse return text;
    return text[slash + 1 ..];
}

/// Put config diagnostics in the notice bar.
fn showDiagnostics(ui: *ui_mod.Ui, diags: *const config.Diagnostics, path: []const u8, consequence: ?[]const u8) !void {
    var lines = std.ArrayList([]const u8).init(ui.allocator);
    defer lines.deinit();
    // Errors first; the headline names the file, so lines start at its
    // basename ("config.lua:3: ...").
    for ([_]config.Diagnostics.Severity{ .err, .warning }) |sev| {
        for (diags.items.items) |it| if (it.severity == sev) try lines.append(shortenPath(it.text));
    }
    var head_buf: [512]u8 = undefined;
    const n = diags.errorCount();
    const head = if (n > 0)
        std.fmt.bufPrint(&head_buf, "config: {d} error{s} in {s}; {s}", .{ n, if (n == 1) "" else "s", path, consequence orelse "" }) catch "config errors"
    else
        std.fmt.bufPrint(&head_buf, "config: {s}", .{path}) catch "config warnings";
    try ui.setNotice(if (n > 0) .err else .warning, head, lines.items, null, std.time.milliTimestamp());
}

fn installBindings(cfg: *const config.Config) void {
    events.bindings = if (cfg.default_keybindings) events.Bindings.defaults() else .{};
    // config.ai.accept_key moves "accept suggestion" off Tab.
    if (cfg.default_keybindings and !std.ascii.eqlIgnoreCase(cfg.ai_accept_key, "tab")) {
        events.bindings.apply("tab=none") catch {};
        var buf: [96]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "{s}=ai_accept", .{cfg.ai_accept_key})) |spec| {
            events.bindings.apply(spec) catch |err| std.debug.print("config: ai.accept_key {s}: {s}\n", .{ cfg.ai_accept_key, @errorName(err) });
        } else |_| {}
    }
    for (cfg.keybinds.items) |spec| {
        events.bindings.apply(spec) catch |err| std.debug.print("config: keybind {s}: {s}\n", .{ spec, @errorName(err) });
    }
}

/// Launch `command url` detached (double fork, no shell). The URL has
/// already passed `urls.allowedTarget`.
fn openUrl(command: []const u8, url: []const u8) void {
    if (builtin.os.tag == .windows) return; // TODO: ShellExecuteW
    std.debug.print("  → open {s}\n", .{url});
    spawnDetached(&.{ command, url }, true);
}

/// Runs argv[0] (looked up in $PATH) detached from this process: double
/// fork so it is reparented and never becomes our zombie.
fn spawnDetached(args: []const []const u8, quiet: bool) void {
    if (builtin.os.tag == .windows) return;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const argv = arena.allocSentinel(?[*:0]const u8, args.len, null) catch return;
    for (args, 0..) |x, i| argv[i] = (arena.dupeZ(u8, x) catch return).ptr;
    const pid = posix.fork() catch return;
    if (pid == 0) {
        if (builtin.os.tag == .linux) _ = std.os.linux.setsid();
        const pid2 = posix.fork() catch posix.exit(1);
        if (pid2 == 0) {
            const devnull = posix.openZ("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch posix.exit(1);
            posix.dup2(devnull, 0) catch {};
            if (quiet) {
                posix.dup2(devnull, 1) catch {};
                posix.dup2(devnull, 2) catch {};
            }
            const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
            _ = posix.execvpeZ(argv[0].?, argv.ptr, envp) catch {};
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
        try terminal.appendRowText(term.screenRow(row), writer);
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

test "restart-only changes are listed" {
    var a = config.Config.init(std.testing.allocator);
    defer a.deinit();
    var b = config.Config.init(std.testing.allocator);
    defer b.deinit();
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    b.font_size = 20; // live
    try restartOnlyChanges(&a, &b, &out);
    try std.testing.expectEqualStrings("", out.items);
    b.scrollback_lines = 5;
    b.shell_program = "/bin/zsh";
    try restartOnlyChanges(&a, &b, &out);
    try std.testing.expectEqualStrings("scrollback.lines, shell.program", out.items);
    try std.testing.expect(fontsChanged(&a, &b));
    try std.testing.expectEqual(@as(i32, 5), minTimeout(-1, 5));
    try std.testing.expectEqual(@as(i32, 3), minTimeout(3, 5));
    try std.testing.expectEqual(@as(i32, 0), minTimeout(-1, -7));
    try std.testing.expectEqualStrings("config.lua:3: x: y", shortenPath("~/.config/dt/config.lua:3: x: y"));
    try std.testing.expectEqualStrings("plain message", shortenPath("plain message"));
}

test "cursor shape default follows config unless an app changed it" {
    var term = try terminal.Terminal.initBuffer(std.testing.allocator, 2, 10, 0);
    defer term.deinit();
    applyCursorShape(&term, .bar);
    try std.testing.expectEqual(terminal.CursorShape.bar, term.cursor_shape);
    try term.processOutput("\x1b[4 q"); // app: underline
    applyCursorShape(&term, .block);
    try std.testing.expectEqual(terminal.CursorShape.underline, term.cursor_shape);
    try term.processOutput("\x1b[0 q"); // app: back to default
    try std.testing.expectEqual(terminal.CursorShape.block, term.cursor_shape);
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
