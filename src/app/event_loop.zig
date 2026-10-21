const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const terminal = @import("../terminal/terminal.zig");
const renderer = @import("../renderer/vulkan_renderer.zig");
const software = @import("../renderer/software.zig");
const ai_controller = @import("ai_controller.zig");
const ssh_target = @import("../ssh/target.zig");
const ssh_control = if (builtin.os.tag == .linux) @import("../ssh/control.zig") else @import("../ssh/control_unsupported.zig");
const palette_mod = ui_mod.palette_mod;
const plugin_bridge = @import("plugin_bridge.zig");
const spawn = @import("spawn.zig");
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
const gui_mod = @import("gui.zig");
const ghost_hold = @import("../ghost/hold.zig");
const time_travel = @import("../ghost/time_travel.zig");
const io = @import("../platform/io.zig");
const share_ctrl = @import("share_ctrl.zig");
const win_misc = if (builtin.os.tag == .windows) @import("../platform/win_misc.zig") else struct {};

/// Wait this long after the last change event before reloading, so an
/// editor's write+rename save triggers one reload.
pub const RELOAD_DEBOUNCE_MS: i64 = 100;
/// How long the "config reloaded" notice stays up.
pub const RELOADED_NOTICE_MS: i64 = 3000;

/// Headless mode polls with this timeout so Ctrl+C / SIGTERM are noticed.
const HEADLESS_POLL_MS: i32 = 250;
const READ_BUFFER_SIZE: usize = 64 * 1024;
/// Longest the GUI parses PTY output before servicing input and drawing.
const READ_TIME_BUDGET_NS: u64 = 8 * std.time.ns_per_ms;

pub var shutdown_requested = std.atomic.Value(bool).init(false);

/// Write end of a pipe the GUI loop polls, so SIGTERM/SIGINT wake it even
/// when the signal lands on another thread (e.g. a Vulkan driver worker) and
/// the main thread sleeps in poll() without a timeout. -1 = none.
pub var signal_wake_fd = std.atomic.Value(i32).init(-1);

fn handleSignal(sig: i32) callconv(.C) void {
    _ = sig;
    shutdown_requested.store(true, .seq_cst);
    const fd = signal_wake_fd.load(.seq_cst);
    if (fd >= 0) _ = std.c.write(fd, "x", 1);
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
    /// How to start more panes like the first one.
    spawn_ctx: spawn.Context = .{},
    /// Open config.layout's tabs (the first pane is already `term`).
    startup_layout: bool = false,
    /// `deathterminal --join <code>`: show that host's pane instead of a shell.
    join_code: ?[]const u8 = null,

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

        if (self.join_code != null and self.cfg.headless) {
            try self.runGuestHeadless(vulkan_renderer, term);
            return;
        }
        if (self.cfg.headless) {
            try self.runHeadless(vulkan_renderer, term);
        } else {
            gui_mod.run(self, vulkan_renderer, term) catch |err| {
                std.debug.print("GUI failed ({s}); falling back to headless.\n", .{@errorName(err)});
                try self.runHeadless(vulkan_renderer, term);
            };
        }
    }

    fn runHeadless(
        self: *EventLoop,
        vulkan_renderer: *renderer.VulkanRenderer,
        term: *terminal.Terminal,
    ) !void {
        const pty_fd = term.getPtyFd() orelse return error.NoPty;
        try setNonBlocking(pty_fd);

        var stdin_raw = false;
        if (builtin.os.tag != .windows) {
            stdin_raw = try enableRawMode();
        } else {
            stdin_raw = win_misc.enableRawConsole();
        }
        defer if (stdin_raw) {
            if (builtin.os.tag == .windows) win_misc.restoreConsole() else disableRawMode() catch {};
        };
        const stdin_fd: io.Fd = if (builtin.os.tag == .windows) win_misc.stdinSocket() catch io.none else posix.STDIN_FILENO;

        try installSignalHandlers();

        const read_buf = try std.heap.page_allocator.alloc(u8, READ_BUFFER_SIZE);
        defer std.heap.page_allocator.free(read_buf);
        var input_buf: [4096]u8 = undefined;
        var ghost = ghost_hold.Hold.init(self.allocator);
        defer ghost.deinit();
        // Redraw only after output, at most every 16 ms while it streams.
        var dirty = true;
        var last_draw: u64 = 0;

        std.debug.print("Headless terminal active. Ctrl+C goes to the shell; exit the shell (exit / Ctrl+D) to quit.\n", .{});

        while (!shutdown_requested.load(.seq_cst)) {
            var poll_fds = [_]io.PollFd{
                io.pollFd(pty_fd, io.POLL.IN),
                io.pollFd(stdin_fd, io.POLL.IN),
            };

            const ready = io.poll(&poll_fds, if (dirty) 16 else HEADLESS_POLL_MS);

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
                const n = io.read(pty_fd, read_buf) catch |err| switch (err) {
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
                const n = io.read(stdin_fd, &input_buf) catch |err| switch (err) {
                    error.WouldBlock => 0,
                    else => return err,
                };

                if (n == 0) break;

                try self.headlessInput(term, &ghost, input_buf[0..n]);
            }
        }

        try renderHeadless(term, vulkan_renderer);
        std.debug.print("\n", .{});
    }

    /// Headless guest: the local shell is drained and the grid is the host's.
    fn runGuestHeadless(
        self: *EventLoop,
        vulkan_renderer: *renderer.VulkanRenderer,
        term: *terminal.Terminal,
    ) !void {
        var share = share_ctrl.Controller.init(self.allocator);
        defer share.deinit();
        share.configure(self.cfg);
        share.joinCode(0, self.join_code orelse return);

        const pty_fd = term.getPtyFd() orelse return error.NoPty;
        try setNonBlocking(pty_fd);
        var stdin_raw = false;
        if (builtin.os.tag != .windows) {
            stdin_raw = try enableRawMode();
        } else {
            stdin_raw = win_misc.enableRawConsole();
        }
        defer if (stdin_raw) {
            if (builtin.os.tag == .windows) win_misc.restoreConsole() else disableRawMode() catch {};
        };
        const stdin_fd: io.Fd = if (builtin.os.tag == .windows) win_misc.stdinSocket() catch io.none else posix.STDIN_FILENO;
        try installSignalHandlers();

        const deadline = std.time.milliTimestamp() + 8000;
        while (std.time.milliTimestamp() < deadline) {
            share.tick();
            const g = share.guest orelse break;
            if (g.phase != .waiting) break;
            std.time.sleep(10 * std.time.ns_per_ms);
        }
        if (share.guest == null or share.guest.?.phase != .open) {
            const why = share.takeError() orelse if (share.guest) |g| g.failure() orelse "timed out" else "timed out";
            std.debug.print("join failed: {s}\n", .{why});
            return;
        }
        std.debug.print("Watching (read-only until the host grants control). Ctrl+C leaves.\n", .{});

        var input_buf: [1024]u8 = undefined;
        var dirty = true;
        while (!shutdown_requested.load(.seq_cst)) {
            var extra = [_]io.Fd{ io.none, io.none };
            const nfd = share.fillPoll(&extra);
            var poll_fds = [_]io.PollFd{
                io.pollFd(pty_fd, io.POLL.IN),
                io.pollFd(stdin_fd, io.POLL.IN),
                io.pollFd(if (nfd > 0) extra[0] else io.none, io.POLL.IN),
            };
            _ = io.poll(&poll_fds, 50);
            if (poll_fds[0].revents & io.POLL.IN != 0) {
                var junk: [4096]u8 = undefined;
                while (true) {
                    const n = io.read(pty_fd, &junk) catch break;
                    if (n == 0) break;
                }
            }
            if (poll_fds[1].revents & io.POLL.IN != 0) {
                const n = io.read(stdin_fd, &input_buf) catch 0;
                if (n == 0) break;
                if (std.mem.indexOfScalar(u8, input_buf[0..n], 0x03) != null) break;
                share.onGuestBytes(input_buf[0..n]);
            }
            share.tick();
            if (share.applyGrid(term)) dirty = true;
            if (share.guest) |g| if (g.kicked or g.phase == .closed) {
                std.debug.print("\nThe host ended the share.\n", .{});
                break;
            };
            if (dirty) {
                try renderHeadless(term, vulkan_renderer);
                dirty = false;
            }
        }
    }

    /// Lone Enter on a risky command opens a text prompt. The command is
    /// not run until `y`. A paste that already contains the newline is
    /// not inspected (the line is not on screen yet).
    fn headlessInput(self: *EventLoop, term: *terminal.Terminal, ghost: *ghost_hold.Hold, bytes: []const u8) !void {
        if (ghost.open) {
            if (bytes.len != 1) return;
            switch (ghost.answerText(bytes)) {
                .ignore => {},
                .cancel => ghost.close(),
                .run => {
                    _ = try term.write(ghost.enter);
                    ghost.close();
                },
                .snapshot => switch (time_travel.snapshot(.{
                    .cwd = ghost.cwd,
                    .command = ghost.command,
                    .pane = ghost.pane,
                })) {
                    .ok => {
                        _ = try term.write(ghost.enter);
                        ghost.close();
                    },
                    .unavailable => std.debug.print("\nGhost Run: Time Travel is not available. The command was not run.\n", .{}),
                    .failed => |why| std.debug.print("\nGhost Run: snapshot failed ({s}). The command was not run.\n", .{why}),
                },
            }
            return;
        }
        if (self.cfg.ghost_run_enabled and ghost_hold.loneEnter(bytes)) {
            const armed = ghost.consider(.{
                .term = term,
                .enter = bytes,
                .patterns = ghost_hold.patternList(self.cfg.ghost_patterns_set, self.cfg.ghost_patterns.items),
                .remote = self.ssh_remote.len > 0,
                .pane = 0,
                .want_ai = false,
            }) catch false;
            if (armed) {
                ghost.logPreview();
                return;
            }
        }
        _ = try term.write(bytes);
    }
};

pub fn setNonBlocking(fd: io.Fd) !void {
    try io.setNonBlocking(fd);
}

pub fn installSignalHandlers() !void {
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

pub fn attachPresent(vulkan_renderer: *renderer.VulkanRenderer, window: *window_mod.Window) void {
    switch (window.backend) {
        .x11 => _ = vulkan_renderer.attachX11(window.x11DisplayPtr(), window.x11WindowId(), window.width, window.height),
        .wayland => _ = vulkan_renderer.attachWayland(window.waylandDisplayPtr(), window.waylandSurfacePtr(), window.width, window.height),
        .win32 => _ = vulkan_renderer.attachWin32(window.win32InstancePtr(), window.win32HwndPtr(), window.width, window.height),
        .cocoa => _ = vulkan_renderer.attachMetal(window.metalLayerPtr(), window.width, window.height),
        .none => {},
    }
}

/// " L 8080:localhost:80 → on " from a control reply "ok on <state>".
pub fn toggleStatus(buf: []u8, spec: []const u8, reply: []const u8) []const u8 {
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

pub const ForwardLine = struct { n: usize, on: bool, spec: []const u8, state: []const u8 };

/// "<n> <on|off> <spec> | <state>" from the control socket's `list`.
pub fn parseForwardLine(line: []const u8) ?ForwardLine {
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
pub fn openSshWindow(loop: *const EventLoop, name: []const u8) void {
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

pub const host_effect = plugin_bridge.host_mod.Effect;

pub fn freeHostEffect(a: std.mem.Allocator, e: *host_effect) void {
    switch (e.*) {
        .write, .set_clipboard => |x| a.free(x),
        .notify => |n| {
            a.free(n.source);
            a.free(n.text);
        },
        .theme => |t| a.free(t.name),
        .layout => |l| switch (l) {
            .tab_new => |cwd| if (cwd) |d| a.free(d),
            .tab_rename => |r| a.free(r.name),
            else => {},
        },
        else => {},
    }
}

pub fn chordTaken(c: events.Chord) bool {
    return events.bindings.has(c);
}

/// `notify-send` (if installed) for a plugin notice while unfocused.
pub fn desktopNotify(source: []const u8, text: []const u8) void {
    if (builtin.os.tag != .linux) return;
    var tb: [96]u8 = undefined;
    const title = std.fmt.bufPrint(&tb, "YouNeeK Death Terminal: {s}", .{source}) catch "YouNeeK Death Terminal";
    spawnDetached(&.{ "notify-send", "--app-name=YouNeeK Death Terminal", "--", title, text[0..@min(text.len, 500)] }, true);
}

pub fn nowNs() u64 {
    return @intCast(std.time.nanoTimestamp());
}

/// Frame pacing and throughput counters for the GUI loop.
pub const Pacer = struct {
    /// Minimum time between presents (0 = uncapped).
    frame_ns: u64,
    read_budget: usize,
    last_present: u64 = 0,
    frames: u64 = 0,
    skipped: u64 = 0,
    wakeups: u64 = 0,
    bytes: u64 = 0,
    batches: u64 = 0,

    pub fn due(self: *const Pacer, now: u64) bool {
        return now -% self.last_present >= self.frame_ns;
    }

    pub fn msUntilNext(self: *const Pacer, now: u64) i32 {
        const elapsed = now -% self.last_present;
        if (elapsed >= self.frame_ns) return 0;
        const left = self.frame_ns - elapsed;
        return @intCast((left + std.time.ns_per_ms - 1) / std.time.ns_per_ms);
    }

    pub fn presented(self: *Pacer, now: u64) void {
        self.last_present = now;
    }

    pub fn report(self: *const Pacer) void {
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

pub fn frameNs(max_fps: u16) u64 {
    return if (max_fps == 0) 0 else std.time.ns_per_s / @as(u64, max_fps);
}

/// Combine a poll timeout (-1 = infinite) with another wait in ms.
pub fn minTimeout(timeout: i32, ms: i64) i32 {
    const m: i32 = @intCast(std.math.clamp(ms, 0, std.math.maxInt(i32)));
    return if (timeout < 0) m else @min(timeout, m);
}

pub fn fontOptions(cfg: *const config.Config, scale: f32) fonts_mod.Options {
    return .{
        .family = cfg.font_family,
        .size_pt = cfg.font_size,
        .line_height = cfg.line_height,
        .scale = scale,
        .retro = cfg.font_retro,
        .ligatures = cfg.font_ligatures,
    };
}

pub fn fontsChanged(a: *const config.Config, b: *const config.Config) bool {
    return !std.mem.eql(u8, a.font_family, b.font_family) or a.font_size != b.font_size or
        a.line_height != b.line_height or a.font_retro != b.font_retro or a.font_ligatures != b.font_ligatures;
}

pub fn uiOptions(cfg: *const config.Config) ui_mod.Options {
    return .{
        .copy_on_select = cfg.copy_on_select,
        .paste_confirm = cfg.paste_confirm,
        .osc52 = ui_mod.Osc52.parse(cfg.osc52) orelse .write,
        .scrollbar = cfg.scrollbar,
        .scroll_lines = cfg.scroll_lines,
        .word_chars = cfg.word_chars,
    };
}

/// DECCOLM policy: `allow` from config (?40 can still turn it off);
/// `resizes` = the grid may change width (headless only).
pub fn applyColumnSwitch(term: *terminal.Terminal, allow: bool, resizes: bool) void {
    term.allow_column_switch = allow;
    term.modes.allow_deccolm = allow;
    term.deccolm_resizes = resizes;
}

/// New default cursor shape; also applied now unless an app chose one.
pub fn applyCursorShape(term: *terminal.Terminal, shape: config.CursorShape) void {
    const s: terminal.CursorShape = switch (shape) {
        .block => .block,
        .underline => .underline,
        .bar => .bar,
    };
    if (term.cursor_shape == term.default_cursor_shape) term.cursor_shape = s;
    term.default_cursor_shape = s;
}

/// Names of changed options that only apply to new terminals.
pub fn restartOnlyChanges(a: *const config.Config, b: *const config.Config, out: *std.ArrayList(u8)) !void {
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
pub fn showDiagnostics(ui: *ui_mod.Ui, diags: *const config.Diagnostics, path: []const u8, consequence: ?[]const u8) !void {
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

pub fn installBindings(cfg: *const config.Config) void {
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
pub fn openUrl(command: []const u8, url: []const u8) void {
    if (builtin.os.tag == .windows) {
        std.debug.print("  → open {s}\n", .{url});
        return win_misc.openUrl(command, url);
    }
    std.debug.print("  → open {s}\n", .{url});
    spawnDetached(&.{ command, url }, true);
}

/// Runs argv[0] (looked up in $PATH) detached from this process: double
/// fork so it is reparented and never becomes our zombie.
pub fn spawnDetached(args: []const []const u8, quiet: bool) void {
    if (builtin.os.tag == .windows) return win_misc.spawnDetached(args);
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
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var t = std.mem.zeroes(posix.termios);
    t.lflag.ISIG = true;
    t.lflag.ICANON = true;
    t.iflag.IXON = true;
    const r = rawTermios(t);
    try std.testing.expect(!r.lflag.ISIG);
    try std.testing.expect(!r.lflag.ICANON);
    try std.testing.expect(!r.iflag.IXON);
}
