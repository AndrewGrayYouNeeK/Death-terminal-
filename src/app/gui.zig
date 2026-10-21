//! The GUI event loop: one window, many sessions (tabs of split panes,
//! session.zig). Everything is driven from one poll() over the window
//! connection, the config watcher, the plugin host and every pane's PTY
//! and AI worker; with nothing to do it sleeps without a timeout.

const std = @import("std");
const env_mod = @import("../platform/env.zig");
const io = @import("../platform/io.zig");
const builtin = @import("builtin");
const posix = std.posix;

const el = @import("event_loop.zig");
const terminal = @import("../terminal/terminal.zig");
const renderer = @import("../renderer/vulkan_renderer.zig");
const software = @import("../renderer/software.zig");
const ai_controller = @import("ai_controller.zig");
const ssh_target = @import("../ssh/target.zig");
const ssh_control = if (builtin.os.tag == .linux) @import("../ssh/control.zig") else @import("../ssh/control_unsupported.zig");
const ui_mod = @import("ui.zig");
const palette_mod = ui_mod.palette_mod;
const plugin_bridge = @import("plugin_bridge.zig");
const host_mod = plugin_bridge.host_mod;
const spawn = @import("spawn.zig");
const session = @import("session.zig");
const layout = session.layout;
const config = @import("../config/config.zig");
const window_mod = @import("../platform/window.zig");
const dpi = @import("../platform/dpi.zig");
const input = @import("../terminal/input.zig");
const fonts_mod = @import("../font/fonts.zig");
const frame_mod = @import("../renderer/frame.zig");
const events = @import("../platform/events.zig");
const color = @import("../terminal/color.zig");
const config_watch = @import("config_watch.zig");
const travel_hub = @import("time_travel.zig");
const share_ctrl = @import("share_ctrl.zig");
const ghost_hold = @import("../ghost/hold.zig");
const time_travel = @import("../ghost/time_travel.zig");
const muscle_mod = @import("../muscle/session.zig");

const Pane = session.Pane;
const PaneId = session.PaneId;
const Workspace = session.Workspace;

const READ_BUFFER_SIZE: usize = 64 * 1024;
/// Longest the loop parses one pane's output before servicing the rest.
const READ_TIME_BUDGET_NS: u64 = 8 * std.time.ns_per_ms;
const NOTICE_MS: i64 = 3000;
/// Cells per keyboard resize step.
const RESIZE_STEP: u16 = 2;

pub fn run(loop: *el.EventLoop, vk: *renderer.VulkanRenderer, first_term: *terminal.Terminal) !void {
    const a = loop.allocator;
    const cfg = loop.cfg;
    var scale: f32 = if (cfg.scale >= 1.0) dpi.normalize(cfg.scale) else dpi.detectEnvScale();

    var fonts = try fonts_mod.Fonts.init(a, el.fontOptions(cfg, scale));
    defer fonts.deinit();
    var frame = frame_mod.Frame.init(a);
    defer frame.deinit();
    std.debug.print("  → Font: {s} {d:.1}pt, cell {d}x{d}px\n", .{ fonts.familyName(), fonts.size_pt, fonts.metrics.cell_w, fonts.metrics.cell_h });

    var soft = try software.SoftwareRenderer.init(a, first_term.cols, first_term.rows, .{ .w = fonts.metrics.cell_w, .h = fonts.metrics.cell_h });
    defer soft.deinit();

    var window = try window_mod.Window.open(a, .{
        .title = "YouNeeK Death Terminal",
        .width = soft.width,
        .height = soft.height,
        .scale = cfg.scale,
        .backend = cfg.backend,
    });
    defer window.deinit();
    if (!window.isLive()) return error.NoWindowBackend;
    if (window.scale != scale) {
        scale = window.scale;
        _ = try fonts.setScale(scale);
    }
    defer vk.detachPresent();
    vk.setPresentMode(renderer.PresentMode.parse(cfg.present_mode) orelse .fifo);
    el.attachPresent(vk, &window);
    try el.installSignalHandlers();

    const read_buf = try a.alloc(u8, READ_BUFFER_SIZE);
    defer a.free(read_buf);
    var pace = el.Pacer{
        .frame_ns = el.frameNs(cfg.max_fps),
        .read_budget = @as(usize, cfg.read_budget_kb) * 1024,
    };

    el.installBindings(cfg);
    var chrome = ui_mod.Ui.init(a, el.uiOptions(cfg));
    defer chrome.deinit();
    chrome.status_visible = cfg.status_bar;
    var palette = cfg.palette();
    var watcher: ?config_watch.Watcher = if (loop.watch_path) |p| config_watch.Watcher.init(p) else null;
    defer if (watcher) |*w| w.deinit();

    var ws = Workspace.init(a);
    defer ws.deinit();
    ws.opts = .{ .bar = session.BarMode.parse(cfg.tab_bar), .dim = cfg.dim_inactive, .palette = &palette };

    const first = try Pane.create(a, ws.tabs.newPaneId(), first_term, false, loop.ssh_remote, el.uiOptions(cfg), paneAiSettings(cfg, loop.ssh_remote));
    try ws.addPane(first);
    _ = try ws.newTab(first);
    try el.setNonBlocking(first_term.getPtyFd() orelse return error.NoPty);

    var plugins = plugin_bridge.Bridge.init(a, &first.track);
    defer plugins.deinit();

    var share = share_ctrl.Controller.init(a);
    defer share.deinit();
    share.configure(cfg);

    var muscle = try muscle_mod.Session.open(a);
    defer muscle.deinit();
    muscle.setSettings(.{
        .enabled = cfg.muscle_enabled,
        .min_repeats = cfg.muscle_min_repeats,
        .max_len = cfg.muscle_max_len,
    });
    if (muscle.shortcutCount() > 0) std.debug.print("  → Muscle memory: {d} shortcut(s)\n", .{muscle.shortcutCount()});

    var gui = Gui{
        .loop = loop,
        .a = a,
        .vk = vk,
        .soft = &soft,
        .window = &window,
        .fonts = &fonts,
        .frame = &frame,
        .chrome = &chrome,
        .ws = &ws,
        .cfg = cfg,
        .palette = &palette,
        .pace = &pace,
        .plugins = &plugins,
        .muscle = &muscle,
        .read_buf = read_buf,
        .share = &share,
        .ghost = ghost_hold.Hold.init(a),
        .last_focus = first.id,
        .last_tab = ws.currentTab().id,
        .travel = travel_hub.Hub.open(a, cfg),
    };
    gui.travel.activate();
    defer gui.travel.deinit();
    defer gui.ghost.deinit();
    time_travel.register(.{
        .ctx = &gui,
        .available = ghostSnapshotAvailable,
        .snapshot = ghostSnapshotProvider,
    });
    defer time_travel.unregister();
    gui.setupPane(first);
    gui.fitWindow(window.width, window.height);
    if (loop.startup_layout) gui.buildStartupLayout();
    if (loop.startup_diags) |d| if (d.items.items.len > 0) {
        try el.showDiagnostics(&gui.focusedPane().ui, d, loop.watch_path orelse "config", if (d.hasErrors()) "using the defaults" else null);
    };
    gui.startPlugins();
    if (loop.join_code) |code| gui.share.joinCode(gui.focusedPane().id, code);
    if (gui.focusedPane().ai.engine != null) std.debug.print("  → AI: {s} via {s}\n", .{ cfg.ai_model, cfg.ai_endpoint });
    std.debug.print("GUI terminal active ({s}, scale={d:.2}). Close the window or exit the shell to quit.\n", .{ @tagName(window.backend), window.scale });

    _ = try gui.present(true);
    pace.presented(el.nowNs());

    // Self-pipe for signals (see el.signal_wake_fd).
    const sig_pipe: ?[2]io.Fd = if (builtin.os.tag == .windows) null else posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true }) catch null;
    if (sig_pipe) |sp| el.signal_wake_fd.store(sp[1], .seq_cst);
    defer if (sig_pipe) |sp| {
        el.signal_wake_fd.store(-1, .seq_cst);
        io.close(sp[0]);
        io.close(sp[1]);
    };

    var fds = std.ArrayList(io.PollFd).init(a);
    defer fds.deinit();
    // Pane id for each PTY / AI slot in `fds` after the fixed three.
    var fd_panes = std.ArrayList(PaneId).init(a);
    defer fd_panes.deinit();

    while (!el.shutdown_requested.load(.seq_cst) and !gui.closing) {
        fds.clearRetainingCapacity();
        fd_panes.clearRetainingCapacity();
        try fds.append(io.pollFd(window.connectionFd() orelse io.none, io.POLL.IN));
        try fds.append(io.pollFd(if (watcher) |w| w.fd else io.none, io.POLL.IN));
        try fds.append(io.pollFd(plugins.wakeFd(), io.POLL.IN));
        var backlog = false;
        for (ws.panes.items) |p| {
            try fds.append(io.pollFd(p.ptyFd(), io.POLL.IN));
            try fds.append(io.pollFd(p.ai.wakeFd(), io.POLL.IN));
            try fd_panes.append(p.id);
            backlog = backlog or p.backlog;
        }
        try fds.append(io.pollFd(if (sig_pipe) |sp| sp[0] else io.none, io.POLL.IN));
        var share_fds = [_]io.Fd{ io.none, io.none };
        const nshare = gui.share.fillPoll(&share_fds);
        for (share_fds[0..nshare]) |fd| try fds.append(io.pollFd(fd, io.POLL.IN));

        // Sleep until input, output or the next frame slot; with nothing to
        // do the timeout is infinite (no wakeups when idle).
        var timeout: i32 = if (window.hasPending() or backlog)
            0
        else if (gui.need_present or gui.force_present)
            pace.msUntilNext(el.nowNs())
        else
            -1;
        const now_ms = std.time.milliTimestamp();
        if (gui.reload_at) |t| timeout = el.minTimeout(timeout, t - now_ms);
        if (chrome.toastTimeout(now_ms)) |t| timeout = el.minTimeout(timeout, t);
        if (plugins.timeout(now_ms)) |t| timeout = el.minTimeout(timeout, t);
        for (ws.panes.items) |p| {
            if (p.ui.noticeTimeout(now_ms)) |t| timeout = el.minTimeout(timeout, t);
            if (p.ai.timeout(now_ms)) |t| timeout = el.minTimeout(timeout, t);
        }
        if (gui.share.host != null or gui.share.guest != null) timeout = el.minTimeout(timeout, 50);
        _ = window.wait(fds.items, timeout);
        pace.wakeups += 1;

        // AI workers.
        for (fd_panes.items, 0..) |id, i| {
            const p = ws.pane(id) orelse continue;
            if (fds.items[3 + 2 * i + 1].revents & io.POLL.IN != 0) {
                if (try p.ai.onWake(&p.ui, p.term, std.time.milliTimestamp())) gui.touch(p);
                if (gui.travel.takeDirty()) gui.touchAll();
            }
            if (gui.ghost.open and gui.ghost.pane == id) {
                const st = p.ai.ghostExplainState();
                if (gui.ghost.pullAi(st.text, st.done, st.failed)) gui.touchAll();
            }
            p.ai.tick(p.term, std.time.milliTimestamp());
            if (p.ui.tickNotice(std.time.milliTimestamp())) gui.touch(p);
        }
        plugins.tick(std.time.milliTimestamp());
        try gui.pluginEffects();
        if (chrome.tickToasts(std.time.milliTimestamp())) gui.touchAll();

        if (fds.items[1].revents & io.POLL.IN != 0) {
            if (watcher) |*w| {
                if (w.drain()) gui.reload_at = std.time.milliTimestamp() + el.RELOAD_DEBOUNCE_MS;
            }
        }
        if (gui.reload_at) |t| if (std.time.milliTimestamp() >= t) {
            gui.reload_at = null;
            try gui.reloadConfig();
            gui.touchAll();
            gui.force_present = true;
        };

        while (!gui.closing) {
            const ev = window.poll();
            if (ev == .none) break;
            try gui.handleEvent(ev);
            try gui.runEffects();
            try gui.pluginEffects();
        }

        // PTY output, pane by pane.
        for (fd_panes.items, 0..) |id, i| {
            const p = ws.pane(id) orelse continue;
            const rev = fds.items[3 + 2 * i].revents;
            const exited = try gui.readPane(p, rev);
            if (exited) try gui.closePane(id);
            if (gui.closing) break;
        }

        if (gui.closing) break;
        if (gui.share.host != null or gui.share.guest != null) {
            gui.share.tick();
            try gui.serviceShare();
        }
        // Titles.
        for (ws.panes.items) |p| if (p.term.title_changed) {
            p.term.title_changed = false;
            ws.full = true;
            gui.need_present = true;
            if (p == gui.focusedPane()) window.setTitle(p.term.title);
        };
        ws.reap();

        if (!gui.closing and (gui.need_present or gui.force_present) and pace.due(el.nowNs())) {
            const drawn = try gui.present(gui.force_present);
            pace.presented(el.nowNs());
            if (drawn) pace.frames += 1 else pace.skipped += 1;
            gui.need_present = false;
            gui.force_present = false;
        }
    }
    if (gui.closing) std.debug.print("\nShell exited.\n", .{});
    if (env_mod.get("DT_PERF_STATS") != null) pace.report();
}

fn ghostSnapshotAvailable(ctx: *anyopaque) bool {
    const gui: *Gui = @ptrCast(@alignCast(ctx));
    return gui.travel.snapshotReady();
}

fn ghostSnapshotProvider(ctx: *anyopaque, req: time_travel.SnapshotRequest) time_travel.SnapshotResult {
    const gui: *Gui = @ptrCast(@alignCast(ctx));
    return switch (gui.travel.snapshotFor(req.cwd, req.command, req.pane)) {
        .ok => |id| .{ .ok = .{ .id = id } },
        .unavailable => .unavailable,
        .failed => |why| .{ .failed = why },
    };
}

fn commandStarted(ctx: *anyopaque) void {
    const p: *Pane = @ptrCast(@alignCast(ctx));
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = terminal.shell_integration.cwdFromUri(p.term.cwd_uri, &buf) orelse "";
    travel_hub.notifyStart(.{
        .pane = p.id,
        .started = p.term.shell.started,
        .cwd = cwd,
        .remote = p.ssh_display.len > 0,
        .command = p.term.shell.pending orelse "",
        .ai = &p.ai,
    });
}

fn noteCommand(self: *Gui, p: *Pane) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = terminal.shell_integration.cwdFromUri(p.term.cwd_uri, &buf) orelse p.track.cwd.items;
    const command = p.term.shell.pending orelse if (p.term.shell.lastCommand()) |c| c.text else "";
    const exit_code = if (p.term.shell.lastCommand()) |c| c.exit_code else null;
    self.travel.observe(.{
        .pane = p.id,
        .started = p.term.shell.started,
        .cwd = cwd,
        .remote = p.ssh_display.len > 0,
        .command = command,
        .ai = &p.ai,
    }, p.term.shell.finished, exit_code);
}

fn paneAiSettings(cfg: *const config.Config, remote: []const u8) ai_controller.Settings {
    var s = ai_controller.Settings.fromConfig(cfg);
    s.remote = remote;
    return s;
}

const Gui = struct {
    loop: *el.EventLoop,
    a: std.mem.Allocator,
    vk: *renderer.VulkanRenderer,
    soft: *software.SoftwareRenderer,
    window: *window_mod.Window,
    fonts: *fonts_mod.Fonts,
    frame: *frame_mod.Frame,
    /// Window-level overlays: palette, toasts, status bar.
    chrome: *ui_mod.Ui,
    ws: *Workspace,
    cfg: *config.Config,
    palette: *color.Palette,
    pace: *el.Pacer,
    plugins: *plugin_bridge.Bridge,
    muscle: *muscle_mod.Session,
    /// Scratch for a pane directory when the plugin track has no cwd yet.
    muscle_dir: [std.fs.max_path_bytes]u8 = undefined,
    read_buf: []u8,
    travel: travel_hub.Hub,
    share: *share_ctrl.Controller,
    /// Risky-command preview. Enter is held until Run, Cancel, or a snapshot.
    ghost: ghost_hold.Hold,
    window_focused: bool = true,
    need_present: bool = false,
    /// Expose/resize: redraw even if the frame is unchanged.
    force_present: bool = false,
    reload_at: ?i64 = null,
    /// The last pane closed (or the window close was confirmed).
    closing: bool = false,
    last_focus: PaneId,
    last_tab: u32,

    fn focusedPane(self: *Gui) *Pane {
        return self.ws.focused();
    }

    fn touch(self: *Gui, p: *Pane) void {
        p.dirty = true;
        self.need_present = true;
    }

    fn touchAll(self: *Gui) void {
        self.ws.full = true;
        self.need_present = true;
    }

    fn cellW(self: *Gui) u32 {
        return self.fonts.metrics.cell_w;
    }

    fn cellH(self: *Gui) u32 {
        return self.fonts.metrics.cell_h;
    }

    // ------------------------------------------------------------ drawing

    fn present(self: *Gui, force: bool) !bool {
        try self.vk.render();
        if (self.travel.isOpen()) {
            self.ws.full = true;
            for (self.ws.panes.items) |p| p.dirty = true;
        }
        const comp = try self.ws.compose(self.chrome);
        if (self.travel.isOpen()) self.travel.draw(self.focusedPane().id, self.ws.cells.items, comp.rows, comp.cols);
        const paint_id: ?PaneId = if (self.share.promptOpen())
            self.focusedPane().id
        else if (self.share.bound)
            self.share.pane
        else
            null;
        if (paint_id) |id| if (self.ws.pane(id)) |sp| {
            self.share.paint(self.ws.cells.items, self.ws.marks.items, self.ws.cols, sp.rect.x, sp.rect.y, sp.rect.w, sp.rect.h);
        };
        if (self.ghost.open) {
            const area = self.ws.area;
            self.ghost.draw(self.ws.cells.items, self.ws.marks.items, self.ws.cols, area.y, area.y + area.h);
        }
        const fp = self.focusedPane();
        var v = frame_mod.View.fromTerminal(fp.term);
        // Reverse video (DECSCNM) is whole-window: only with one pane shown.
        if (self.ws.visibleCount() > 1) v.reverse_video = false;
        v.focused = self.window_focused;
        v.cursor_visible = comp.cursor_visible and !self.travel.isOpen() and !self.ghost.open;
        v.marks = self.ws.marks.items;
        v.palette = self.palette;
        v.selection_bg = self.palette.selection_bg;
        v.selection_fg = self.palette.selection_fg;
        if (comp.scrollbar) |sb| v.scrollbar = .{ .top = sb.top, .height = sb.height };
        try self.frame.build(self.fonts, self.ws.cells.items, comp.rows, comp.cols, comp.cursor_row, comp.cursor_col, v);
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

    /// Fit the window grid to `width`×`height` px.
    fn fitWindow(self: *Gui, width: u32, height: u32) void {
        const cell = self.fonts.cellSize();
        const cols: u16 = @intCast(std.math.clamp(width / cell.w, 1, 1000));
        const rows: u16 = @intCast(std.math.clamp(height / cell.h, 1, 500));
        self.soft.resizePixels(width, height) catch {};
        self.applyLayout(self.ws.setGrid(cols, rows, self.chrome.statusRows()));
    }

    /// After the layout changed: plugins, focus, redraw.
    fn applyLayout(self: *Gui, focus_resized: bool) void {
        if (focus_resized) self.plugins.resized();
        self.syncFocus();
        self.publishTabs();
        self.touchAll();
    }

    fn relayout(self: *Gui) void {
        self.applyLayout(self.ws.relayout());
    }

    // ------------------------------------------------------------- panes

    /// Settings every pane gets (theme, cursor, plugin filter).
    fn setupPane(self: *Gui, p: *Pane) void {
        p.term.palette = self.palette.*;
        el.applyCursorShape(p.term, self.cfg.cursor_shape);
        el.applyColumnSwitch(p.term, self.cfg.allow_column_switch, false);
        p.ai.filter = self.plugins.aiFilter();
        p.term.command_start = commandStarted;
        p.term.command_start_ctx = p;
    }

    /// A new pane running the shell (or an SSH session) of `req`.
    fn newPane(self: *Gui, req: spawn.Request, rows: u16, cols: u16) ?*Pane {
        return self.newPaneOrErr(req, rows, cols) catch |err| {
            var mb: [300]u8 = undefined;
            const msg = std.fmt.bufPrint(&mb, "cannot open a new pane: {s}", .{spawn.describe(err)}) catch "cannot open a new pane";
            self.chrome.addToast(msg, .err, 6000, std.time.milliTimestamp()) catch {};
            self.touchAll();
            return null;
        };
    }

    fn newPaneOrErr(self: *Gui, req: spawn.Request, rows: u16, cols: u16) !*Pane {
        const r = try spawn.terminalFor(self.a, self.cfg, self.loop.spawn_ctx, req, rows, cols);
        defer self.a.free(r.display);
        errdefer {
            r.term.deinit();
            self.a.destroy(r.term);
        }
        if (r.term.getPtyFd()) |fd| try el.setNonBlocking(fd);
        const p = try Pane.create(self.a, self.ws.tabs.newPaneId(), r.term, true, r.display, el.uiOptions(self.cfg), paneAiSettings(self.cfg, r.display));
        errdefer _ = p.destroy(self.a);
        try self.ws.addPane(p);
        self.setupPane(p);
        self.plugins.addTrack(&p.track);
        return p;
    }

    /// Directory for a new pane: the focused one's (OSC 7), if enabled.
    fn inheritedCwd(self: *Gui, buf: []u8) []const u8 {
        if (!self.cfg.inherit_cwd) return "";
        return spawn.inheritedCwd(self.focusedPane().term, buf);
    }

    fn openTab(self: *Gui, req_in: spawn.Request) void {
        var cb: [4096]u8 = undefined;
        var req = req_in;
        if (req.cwd.len == 0 and req.ssh == null) req.cwd = self.inheritedCwd(&cb);
        const area = self.ws.area;
        const p = self.newPane(req, area.h, area.w) orelse return;
        const tab = self.ws.newTab(p) catch {
            self.dropPane(p);
            return;
        };
        if (self.plugins.host) |h| h.emitLayout(.tab_new, tab.id, null);
        if (self.plugins.host) |h| h.emitLayout(.pane_new, tab.id, p.id);
        self.relayout();
    }

    fn splitPane(self: *Gui, dir: layout.Dir, req_in: spawn.Request) void {
        var cb: [4096]u8 = undefined;
        var req = req_in;
        if (req.cwd.len == 0 and req.ssh == null) req.cwd = self.inheritedCwd(&cb);
        const fr = self.focusedPane().rect;
        const rows = if (dir == .down) fr.h / 2 else fr.h;
        const cols = if (dir == .right) fr.w / 2 else fr.w;
        const p = self.newPane(req, @max(rows, 1), @max(cols, 1)) orelse return;
        self.ws.splitFocused(dir, p, 0.5) catch {
            self.dropPane(p);
            return;
        };
        if (self.plugins.host) |h| h.emitLayout(.pane_new, self.ws.currentTab().id, p.id);
        self.relayout();
    }

    /// Undo `newPane` for a pane that never made it into a layout.
    fn dropPane(self: *Gui, p: *Pane) void {
        self.plugins.removeTrack(&p.track);
        _ = self.ws.detachPane(p.id);
        self.ws.destroyPane(p);
    }

    /// Ask first when something is running there (tabs.confirm_close).
    fn requestClosePane(self: *Gui, id: PaneId) !void {
        const p = self.ws.pane(id) orelse return;
        if (self.cfg.confirm_close) {
            var nb: [64]u8 = undefined;
            if (p.runningProgram(&nb)) |name| return self.askConfirm(.{ .pane = id }, name);
        }
        try self.closePane(id);
    }

    fn requestCloseTab(self: *Gui, index: usize) !void {
        if (index >= self.ws.tabs.tabs.items.len) return;
        const tab = self.ws.tabs.tabs.items[index];
        if (self.cfg.confirm_close) {
            var nb: [64]u8 = undefined;
            for (self.ws.panes.items) |p| if (tab.layout.contains(p.id)) {
                if (p.runningProgram(&nb)) |name| return self.askConfirm(.{ .tab = tab.id }, name);
            };
        }
        try self.closeTab(tab.id);
    }

    fn requestCloseWindow(self: *Gui) void {
        if (self.cfg.confirm_close) {
            var nb: [64]u8 = undefined;
            for (self.ws.panes.items) |p| if (p.runningProgram(&nb)) |name| {
                // Show the pane that is busy.
                _ = self.ws.focusPane(p.id);
                self.relayout();
                return self.askConfirm(.window, name);
            };
        }
        self.closing = true;
    }

    fn askConfirm(self: *Gui, what: session.Confirm.What, program: []const u8) void {
        var cf = session.Confirm{ .what = what };
        const n = @min(program.len, cf.program.len);
        @memcpy(cf.program[0..n], program[0..n]);
        cf.program_len = n;
        self.ws.confirm = cf;
        self.touchAll();
    }

    fn answerConfirm(self: *Gui, yes: bool) !void {
        const cf = self.ws.confirm orelse return;
        self.ws.confirm = null;
        self.touchAll();
        if (!yes) return;
        switch (cf.what) {
            .pane => |id| try self.closePane(id),
            .tab => |id| try self.closeTab(id),
            .window => self.closing = true,
        }
    }

    fn closeTab(self: *Gui, tab_id: u32) !void {
        const idx = self.ws.tabs.indexOf(tab_id) orelse return;
        var ids = std.ArrayList(PaneId).init(self.a);
        defer ids.deinit();
        try self.ws.tabs.tabs.items[idx].layout.panes(&ids);
        for (ids.items) |id| try self.closePane(id);
    }

    /// Close pane `id` (its shell exited, or the user closed it). The last
    /// pane closes the window.
    fn closePane(self: *Gui, id: PaneId) !void {
        self.share.onPaneClosed(id);
        const p = self.ws.pane(id) orelse return;
        const tab_id = p.track.tab;
        if (self.ws.confirm) |cf| switch (cf.what) {
            .pane => |cid| if (cid == id) {
                self.ws.confirm = null;
            },
            else => {},
        };
        if (self.ghost.open and self.ghost.pane == id) {
            p.ai.cancelGhostExplain();
            self.ghost.close();
        }
        if (self.ws.drag == .pane and self.ws.drag.pane == id) self.ws.drag = .none;
        p.term.command_start = null;
        p.term.command_start_ctx = null;
        self.travel.drop(id);
        const removed_tab = self.ws.detachPane(id);
        self.plugins.removeTrack(&p.track);
        if (self.plugins.host) |h| {
            h.emitLayout(.pane_close, tab_id, id);
            if (removed_tab != null) h.emitLayout(.tab_close, tab_id, null);
        }
        if (self.ws.panes.items.len == 0) {
            // Keep the bridge pointing at something alive until the end.
            self.plugins.cur = &p.track;
            self.closing = true;
            // The pane (and main's terminal if it is the first) is freed by
            // ws.deinit / main.
            self.ws.panes.append(self.a, p) catch self.ws.destroyPane(p);
            return;
        }
        self.plugins.setFocus(&self.ws.focused().track);
        self.ws.destroyPane(p);
        self.relayout();
    }

    /// Tell the old / new focused pane and the plugins about a focus move.
    fn syncFocus(self: *Gui) void {
        const fp = self.focusedPane();
        const tab = self.ws.currentTab();
        if (fp.id == self.last_focus and tab.id == self.last_tab) return;
        if (self.ws.pane(self.last_focus)) |old| {
            if (self.window_focused) if (input.encodeFocus(false, old.term.modes)) |seq| old.term.write(seq) catch {};
            old.dirty = true;
        }
        if (self.window_focused) if (input.encodeFocus(true, fp.term.modes)) |seq| fp.term.write(seq) catch {};
        fp.activity = false;
        fp.bell = false;
        self.plugins.setFocus(&fp.track);
        if (self.plugins.host) |h| {
            if (tab.id != self.last_tab) h.emitLayout(.tab_focus, tab.id, fp.id);
            h.emitLayout(.pane_focus, tab.id, fp.id);
        }
        self.last_focus = fp.id;
        self.last_tab = tab.id;
        self.window.setTitle(fp.term.title);
        self.touchAll();
    }

    /// The tab list plugins see.
    fn publishTabs(self: *Gui) void {
        const h = self.plugins.host orelse return;
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        const infos = self.ws.tabInfos(arena.allocator()) catch return;
        h.setTabs(infos, self.ws.currentTab().id, self.focusedPane().id);
    }

    // ------------------------------------------------------------ startup

    fn buildStartupLayout(self: *Gui) void {
        const specs = self.cfg.startup_layout.items;
        for (specs, 0..) |spec, i| {
            const tab = if (i == 0) self.ws.currentTab() else blk: {
                const leaf = firstLeaf(&spec.root);
                const p = self.newPane(.{ .cwd = leaf.cwd, .ssh = if (leaf.ssh.len > 0) leaf.ssh else null }, self.ws.area.h, self.ws.area.w) orelse continue;
                break :blk self.ws.newTab(p) catch {
                    self.dropPane(p);
                    continue;
                };
            };
            if (spec.title.len > 0) tab.setName(self.a, spec.title) catch {};
            const root_pane = tab.focused;
            var focus: ?PaneId = null;
            self.buildNode(tab, root_pane, &spec.root, &focus);
            if (focus) |f| tab.focused = f;
            self.ws.full = true;
        }
        if (specs.len > 0) self.ws.tabs.select(0);
        self.relayout();
    }

    /// Lay `node` out in the space of `pane` (which runs node's first leaf).
    fn buildNode(self: *Gui, tab: *session.tabs_mod.Tab, pane_id: PaneId, node: *const config.LayoutNode, focus: *?PaneId) void {
        const dir_opt = node.split;
        if (dir_opt == null) {
            if (node.focus) focus.* = pane_id;
            if (node.command.len > 0) if (self.ws.pane(pane_id)) |p| {
                // Typed ahead: the shell reads it once it is ready.
                p.term.write(node.command) catch {};
                p.term.write("\r") catch {};
            };
            return;
        }
        const dir: layout.Dir = if (dir_opt.? == .right) .right else .down;
        const n = node.children.len;
        var cur = pane_id;
        var panes_buf: [config_max_children]PaneId = undefined;
        panes_buf[0] = pane_id;
        var i: usize = 1;
        while (i < n and i < config_max_children) : (i += 1) {
            // Split what is left: this child gets 1/(left) of it.
            const left: f32 = @floatFromInt(n - i + 1);
            const ratio: f32 = if (n == 2) node.ratio else 1.0 / left;
            tab.layout.compute(self.ws.area);
            const r = tab.layout.rectOf(cur) orelse self.ws.area;
            const leaf = firstLeaf(&node.children[i]);
            const p = self.newPane(.{ .cwd = leaf.cwd, .ssh = if (leaf.ssh.len > 0) leaf.ssh else null }, r.h, r.w) orelse break;
            tab.layout.split(cur, dir, p.id, ratio) catch {
                self.dropPane(p);
                break;
            };
            p.track.tab = tab.id;
            panes_buf[i] = p.id;
            cur = p.id;
        }
        for (node.children[0..i], 0..) |*child, k| self.buildNode(tab, panes_buf[k], child, focus);
    }

    const config_max_children = 16;

    fn firstLeaf(node: *const config.LayoutNode) *const config.LayoutNode {
        var n = node;
        while (n.split != null and n.children.len > 0) n = &n.children[0];
        return n;
    }

    // ---------------------------------------------------------------- I/O

    /// Parse what pane `p`'s PTY has (up to the budget). True = it exited.
    fn readPane(self: *Gui, p: *Pane, revents: i16) !bool {
        // A joined pane shows the host's grid. Drain the local shell so it
        // cannot paint over that grid or fill the PTY buffer.
        if (self.share.isGuest() and self.share.claims(p.id)) {
            if (p.backlog or revents & io.POLL.IN != 0) {
                const fd = p.ptyFd();
                if (!io.isNone(fd)) while (true) {
                    const n = io.read(fd, self.read_buf) catch break;
                    if (n == 0) break;
                };
            }
            return false;
        }
        if (!p.backlog and revents & io.POLL.IN == 0) {
            return revents & (io.POLL.HUP | io.POLL.ERR) != 0;
        }
        const fd = p.ptyFd();
        if (io.isNone(fd)) return true;
        const s0 = el.nowNs();
        var total: usize = 0;
        p.backlog = false;
        var exited = false;
        while (true) {
            const n = io.read(fd, self.read_buf) catch |err| switch (err) {
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
            try p.term.processOutput(self.read_buf[0..n]);
            total += n;
            if (total >= self.pace.read_budget or el.nowNs() - s0 >= READ_TIME_BUDGET_NS) {
                p.backlog = true;
                break;
            }
        }
        if (total > 0) {
            self.pace.bytes += total;
            self.pace.batches += 1;
            if (p.term.clipboard_ops.items.len > 0) {
                const ops = try p.term.takeClipboardOps();
                defer p.term.freeClipboardOps(ops);
                try p.ui.onClipboardOps(ops);
                try self.runPaneEffects(p);
            }
            p.ui.sync(p.term);
            self.plugins.afterOutput(&p.track, std.time.milliTimestamp());
            noteCommand(self, p);
            try self.pluginEffects();
            if (self.travel.isOpen()) self.touchAll();
            try self.muscleAfterOutput(p);
            const is_focus = p == self.focusedPane();
            if (!p.visible and !p.activity) {
                p.activity = true;
                self.ws.full = true;
            }
            if (p.term.bell_count != p.seen_bells) {
                p.seen_bells = p.term.bell_count;
                if (!is_focus or !self.window_focused) {
                    p.bell = true;
                    self.ws.full = true;
                }
            }
            // The bar shows the focused pane's exit status / running state.
            const st = p.term.shell.started *% 31 +% p.term.shell.finished;
            if (st != p.bar_seen) {
                p.bar_seen = st;
                if (self.ws.bar_row != null) self.ws.full = true;
            }
            self.touch(p);
        }
        return exited;
    }

    // ------------------------------------------------------------- events

    fn handleEvent(self: *Gui, ev: window_mod.Event) !void {
        switch (ev) {
            .none => {},
            .close => self.requestCloseWindow(),
            .resize => |sz| {
                // HiDPI: the compositor may change the scale with the size.
                if (self.window.scale != self.fonts.scale) _ = try self.fonts.setScale(self.window.scale);
                self.fitWindow(sz.width, sz.height);
                try self.vk.resize(sz.width, sz.height);
                self.force_present = true;
            },
            .action => |a| try self.handleAction(a),
            .paste => |pv| {
                if (self.travel.isOpen()) return;
                if (self.share.promptOpen()) {
                    self.share.promptPaste(pv.data);
                    self.touchAll();
                    return;
                }
                if (pv.purpose == .plugin) {
                    if (self.plugins.host) |h| h.clipboardResult(pv.data);
                    return;
                }
                if (self.muscle.capturing()) {
                    self.muscleResult(try self.muscle.onText(pv.data));
                    return;
                }
                const fp = self.focusedPane();
                try fp.ui.onPaste(fp.term, pv.data, pv.target, pv.purpose);
                fp.ai.onKeystroke(&fp.ui, std.time.milliTimestamp());
                self.touch(fp);
            },
            .redraw => {
                self.touchAll();
                self.force_present = true;
            },
            .input => |bytes| try self.handleInput(bytes),
            .key => |k| try self.handleKey(k.key, k.mods),
            .mouse => |m| try self.handleMouse(m),
            .focus => |f| {
                self.window_focused = f;
                self.plugins.focus(f);
                const fp = self.focusedPane();
                if (f) {
                    fp.bell = false;
                    self.ws.full = true;
                }
                if (input.encodeFocus(f, fp.term.modes)) |seq| try fp.term.write(seq);
                self.touch(fp);
            },
        }
    }

    fn handleInput(self: *Gui, bytes: []const u8) !void {
        if (self.travel.isOpen()) {
            const result = self.travel.onText(self.focusedPane().id, bytes);
            if (result == .close) self.travel.close();
            self.touchAll();
            return;
        }
        if (self.ghost.open) {
            try self.answerGhost(self.ghost.answerText(bytes));
            return;
        }
        if (self.ws.confirm != null) {
            if (bytes.len == 1) switch (bytes[0]) {
                'y', 'Y', '\r' => try self.answerConfirm(true),
                'n', 'N', 0x1b, 0x03 => try self.answerConfirm(false),
                else => {},
            };
            return;
        }
        if (try self.ws.renameText(bytes)) {
            self.touchAll();
            return;
        }
        if (self.share.promptOpen()) {
            if (self.share.feedPrompt(bytes) == .join) self.share.join(self.focusedPane().id);
            self.touchAll();
            try self.showShare();
            return;
        }
        const fp = self.focusedPane();
        if (self.share.isGuest() and self.share.claims(fp.id)) {
            if (self.share.access() == .control) self.share.sendGuestInput(bytes);
            self.touch(fp);
            return;
        }
        if (self.chrome.palette != null) {
            _ = try self.chrome.handleText(fp.term, bytes);
            self.touchAll();
            return;
        }
        if (self.muscle.capturing()) {
            self.muscleResult(try self.muscle.onText(bytes));
            return;
        }
        if (bytes.len == 1 and (bytes[0] == '\r' or bytes[0] == '\n')) {
            if (try self.tryMuscleEnter()) return;
        }
        if (try fp.ui.handleText(fp.term, bytes)) {
            try self.pumpAsk(fp);
            self.touch(fp);
        } else if (self.plugins.text(bytes)) {
            self.touch(fp);
        } else {
            // Ctrl+C arrives as 0x03 and goes to the shell like any key.
            _ = fp.ui.userTyped();
            if (ghost_hold.loneEnter(bytes) and try self.maybeGhost(fp, bytes)) return;
            try fp.term.write(bytes);
            fp.ai.onTyped(&fp.ui, fp.term, bytes, std.time.milliTimestamp());
            self.touch(fp);
        }
    }

    fn handleKey(self: *Gui, key: input.Key, mods: input.Mods) !void {
        if (self.travel.isOpen()) {
            const result = self.travel.onKey(self.focusedPane().id, key);
            if (result == .close) self.travel.close();
            self.touchAll();
            return;
        }
        if (self.ghost.open) {
            try self.answerGhost(self.ghost.answerKey(key));
            return;
        }
        if (self.ws.confirm != null) {
            switch (key) {
                .enter, .kp_enter => try self.answerConfirm(true),
                .escape => try self.answerConfirm(false),
                else => {},
            }
            return;
        }
        if (try self.ws.renameKey(key)) {
            self.touchAll();
            return;
        }
        if (self.share.promptOpen()) {
            const fp = self.focusedPane();
            switch (key) {
                .enter, .kp_enter => if (self.share.feedPrompt("\n") == .join) self.share.join(fp.id),
                .escape => _ = self.share.feedPrompt("\x1b"),
                .backspace => _ = self.share.feedPrompt(&[_]u8{0x7f}),
                else => {},
            }
            self.touchAll();
            try self.showShare();
            return;
        }
        const fp = self.focusedPane();
        if (self.share.isGuest() and self.share.claims(fp.id)) {
            switch (self.share.onKey(key, mods)) {
                .ignore => {},
                .consumed => {
                    self.touchAll();
                    return;
                },
                .send => {
                    const seq = input.encodeKey(key, mods, fp.term.modes);
                    self.share.sendGuestInput(seq.constSlice());
                    self.touch(fp);
                    return;
                },
            }
        }
        if (self.chrome.palette != null) {
            _ = try self.chrome.handleKey(fp.term, key, mods);
            self.touchAll();
            return;
        }
        if (self.muscle.capturing()) {
            const mk: ?muscle_mod.Key = switch (key) {
                .enter, .kp_enter => if (mods.any()) null else .enter,
                .escape => .escape,
                .backspace => .backspace,
                else => null,
            };
            if (mk) |k| self.muscleResult(try self.muscle.onKey(k));
            return;
        }
        if (!mods.any() and (key == .enter or key == .kp_enter)) {
            if (try self.tryMuscleEnter()) return;
        }
        if (try fp.ui.handleKey(fp.term, key, mods)) {
            try self.pumpAsk(fp);
            self.touch(fp);
        } else if (self.plugins.key(key, mods)) {
            self.touch(fp);
        } else {
            _ = fp.ui.userTyped();
            const seq = input.encodeKey(key, mods, fp.term.modes);
            if (submitsLine(key, mods, fp.term.modes) and try self.maybeGhost(fp, seq.constSlice())) return;
            try fp.term.write(seq.constSlice());
            fp.ai.onKeystroke(&fp.ui, std.time.milliTimestamp());
            self.touch(fp);
        }
    }

    /// Unmodified Enter submits the shell line. Keypad Enter does too,
    /// unless application keypad mode turned it into SS3 M.
    fn submitsLine(key: input.Key, mods: input.Mods, modes: terminal.Modes) bool {
        if (mods.any()) return false;
        return switch (key) {
            .enter => true,
            .kp_enter => !modes.app_keypad,
            else => false,
        };
    }

    fn maybeGhost(self: *Gui, fp: *Pane, enter: []const u8) !bool {
        if (!self.cfg.ghost_run_enabled) return false;
        const want_ai = self.cfg.ghost_run_ai and fp.ai.engine != null;
        const armed = self.ghost.consider(.{
            .term = fp.term,
            .enter = enter,
            .patterns = ghost_hold.patternList(self.cfg.ghost_patterns_set, self.cfg.ghost_patterns.items),
            .remote = fp.ssh_display.len > 0,
            .pane = fp.id,
            .want_ai = want_ai,
        }) catch return false;
        if (!armed) return false;
        if (want_ai) {
            const impact = self.ghost.impactText(self.a) catch "";
            defer if (impact.len > 0) self.a.free(impact);
            fp.ai.requestGhostExplain(self.ghost.command, impact, self.ghost.cwd) catch {
                self.ghost.ai_pending = false;
            };
        }
        self.touchAll();
        self.force_present = true;
        return true;
    }

    fn answerGhost(self: *Gui, ans: ghost_hold.Answer) !void {
        if (!self.ghost.open) return;
        switch (ans) {
            .ignore => {},
            .cancel => try self.finishGhost(false),
            .run => try self.finishGhost(true),
            .snapshot => try self.snapshotGhost(),
        }
    }

    fn snapshotGhost(self: *Gui) !void {
        const result = time_travel.snapshot(.{
            .cwd = self.ghost.cwd,
            .command = self.ghost.command,
            .pane = self.ghost.pane,
        });
        switch (result) {
            .ok => try self.finishGhost(true),
            .unavailable => {
                self.ghost.setNotice("Time Travel is not available.");
                self.touchAll();
            },
            .failed => |why| {
                self.ghost.setNotice(why);
                self.touchAll();
            },
        }
    }

    /// `send` writes the held Enter. Cancel drops it. The preview
    /// never ran the command itself.
    fn finishGhost(self: *Gui, send: bool) !void {
        const pane = self.ghost.pane;
        const enter = if (send) self.a.dupe(u8, self.ghost.enter) catch return else &.{};
        defer if (enter.len > 0) self.a.free(enter);
        if (self.ws.pane(pane)) |p| p.ai.cancelGhostExplain();
        self.ghost.close();
        self.touchAll();
        if (enter.len == 0) return;
        if (self.ws.pane(pane)) |p| {
            try p.term.write(enter);
            self.touch(p);
        }
    }

    /// A bound key whose action doesn't apply goes on as if unbound.
    fn keyFallback(self: *Gui, a: events.ActionEvent) !void {
        if (events.keysymToKey(a.sym)) |key| {
            try self.handleKey(key, a.mods);
        } else if (a.sym >= 0x20 and a.sym < 0x7f) {
            // A printable key (e.g. Alt+]): Alt sends ESC first.
            var b: [2]u8 = .{ 0x1b, @intCast(a.sym) };
            try self.handleInput(if (a.mods.alt) b[0..2] else b[1..2]);
        }
    }

    fn handleAction(self: *Gui, a: events.ActionEvent) !void {
        const act = a.action;
        if (self.travel.isOpen()) {
            if (act == .time_travel) {
                self.travel.toggle(self.focusedPane().id);
            } else if (act == .ai_dismiss) {
                _ = self.travel.cancel(self.focusedPane().id);
            }
            self.touchAll();
            return;
        }
        // Overlays own the keyboard until they close. Ghost Run's `t` is a
        // snapshot, and Ctrl+Alt+T does not open Time Travel on top of it.
        if ((self.ws.confirm != null or self.ws.rename != null or self.ghost.open) and act != .command_palette) return self.keyFallback(a);
        if (self.muscle.capturing() and act != .command_palette) return self.keyFallback(a);
        if (self.chrome.palette != null and act != .command_palette and act != .ssh_palette) return self.keyFallback(a);
        if (act == .time_travel) {
            self.travel.toggle(self.focusedPane().id);
            self.touchAll();
            return;
        }
        const fp = self.focusedPane();
        const now = std.time.milliTimestamp();
        const ws = self.ws;
        self.need_present = true;
        if (act.gotoIndex()) |idx| {
            if (ws.tabs.tabs.items.len < 2 or idx >= ws.tabs.tabs.items.len) return self.keyFallback(a);
            if (ws.selectTab(idx)) self.relayout();
            return;
        }
        switch (act) {
            .reload_config => {
                self.reload_at = null;
                try self.reloadConfig();
                self.touchAll();
                self.force_present = true;
            },
            .ai_explain => try fp.ai.explain(&fp.ui, fp.term, now),
            .ai_ask => {
                try fp.ai.openAsk(&fp.ui, fp.term, now);
                self.touch(fp);
            },
            .ssh_palette => if (self.chrome.paletteOpen(.ssh)) self.chrome.closePalette() else try self.openSshPalette(),
            .command_palette => if (self.chrome.paletteOpen(.commands)) self.chrome.closePalette() else try self.openCommandPalette(),
            .toggle_status_bar => try self.setStatusBar(!self.chrome.status_visible),
            .plugin_binding => if (self.plugins.host) |h| h.runBinding(a.arg),
            .zoom_in, .zoom_out, .zoom_reset => {
                const z: i8 = switch (act) {
                    .zoom_in => 1,
                    .zoom_out => -1,
                    else => 0,
                };
                if (try self.fonts.zoom(z)) {
                    self.fitWindow(self.window.width, self.window.height);
                    std.debug.print("  → zoom: {d:.1}pt, cell {d}x{d}, grid {d}x{d}\n", .{ self.fonts.size_pt, self.cellW(), self.cellH(), ws.cols, ws.rows });
                }
            },
            .new_tab => self.openTab(.{}),
            .close_tab => try self.requestCloseTab(ws.tabs.active),
            .next_tab, .prev_tab => {
                const n = ws.tabs.tabs.items.len;
                if (n < 2) return self.keyFallback(a);
                const next = if (act == .next_tab) (ws.tabs.active + 1) % n else (ws.tabs.active + n - 1) % n;
                if (ws.selectTab(next)) self.relayout();
            },
            .move_tab_left, .move_tab_right => {
                const n = ws.tabs.tabs.items.len;
                if (n < 2) return self.keyFallback(a);
                const cur = ws.tabs.active;
                const to = if (act == .move_tab_left) (if (cur == 0) n - 1 else cur - 1) else (cur + 1) % n;
                ws.tabs.move(cur, to);
                self.relayout();
            },
            .rename_tab => {
                if (!ws.barVisible()) {
                    ws.bar_toggled = true;
                    self.relayout();
                }
                try ws.startRename(ws.currentTab().id);
                self.touchAll();
            },
            .toggle_tab_bar => {
                ws.bar_toggled = !ws.barVisible();
                self.relayout();
            },
            .split_right => self.splitPane(.right, .{}),
            .split_down => self.splitPane(.down, .{}),
            .close_pane => try self.requestClosePane(fp.id),
            .focus_left, .focus_right, .focus_up, .focus_down => {
                const side: layout.Side = switch (act) {
                    .focus_left => .left,
                    .focus_right => .right,
                    .focus_up => .up,
                    else => .down,
                };
                if (ws.focusDirection(side)) self.relayout() else return self.keyFallback(a);
            },
            .next_pane, .prev_pane => {
                if (ws.cyclePane(if (act == .next_pane) 1 else -1)) self.relayout() else return self.keyFallback(a);
            },
            .resize_left, .resize_right, .resize_up, .resize_down => {
                const side: layout.Side = switch (act) {
                    .resize_left => .left,
                    .resize_right => .right,
                    .resize_up => .up,
                    else => .down,
                };
                if (ws.resizeFocused(side, RESIZE_STEP)) self.relayout() else return self.keyFallback(a);
            },
            .zoom_pane => if (ws.toggleZoom()) self.relayout(),
            .equalize_panes => if (ws.equalize()) self.relayout(),
            .share_pane => {
                self.share.startHost(fp.id);
                try self.showShare();
                self.touchAll();
            },
            .share_grant => {
                self.share.toggleControl();
                try self.showShare();
                self.touchAll();
            },
            .share_kick => {
                if (!self.share.active()) return self.keyFallback(a);
                self.share.kickOrStop();
                self.touchAll();
            },
            .share_stop => {
                self.share.stop();
                self.touchAll();
            },
            .share_join => {
                self.share.openPrompt();
                self.touchAll();
            },
            else => {
                if (try fp.ui.handleAction(fp.term, act)) {
                    if (act == .ai_accept) fp.ai.onAccepted();
                    try self.pumpAsk(fp);
                    self.touch(fp);
                } else return self.keyFallback(a);
            },
        }
    }

    fn pumpAsk(self: *Gui, fp: *Pane) !void {
        _ = self;
        if (fp.ui.takeAskCancel()) fp.ai.cancelAsk(&fp.ui);
        if (fp.ui.takeAskSubmit()) try fp.ai.submitAsk(&fp.ui, fp.term, std.time.milliTimestamp());
    }

    // -------------------------------------------------------------- mouse

    fn handleMouse(self: *Gui, m: events.MouseInput) !void {
        const ws = self.ws;
        if (self.travel.isOpen()) {
            if (m.action == .press and m.button == .left) {
                const ch: i32 = @intCast(self.cellH());
                const row: u16 = @intCast(std.math.clamp(@divFloor(m.y, ch), 0, @as(i32, ws.rows) - 1));
                self.travel.click(self.focusedPane().id, row, ws.rows);
                self.touchAll();
            }
            return;
        }
        if (self.chrome.palette != null or ws.confirm != null or self.ghost.open) return;
        const cw: i32 = @intCast(self.cellW());
        const ch: i32 = @intCast(self.cellH());
        const col: u16 = @intCast(std.math.clamp(@divFloor(m.x, cw), 0, @as(i32, ws.cols) - 1));
        const row: u16 = @intCast(std.math.clamp(@divFloor(m.y, ch), 0, @as(i32, ws.rows) - 1));
        if (self.share.isGuest()) if (self.ws.pane(self.share.pane)) |gp| {
            const inside = gp.rect.contains(col, row);
            if (inside or (self.share.dragging and m.action != .press)) {
                const lr: u16 = if (row <= gp.rect.y) 0 else @intCast(@min(row - gp.rect.y, gp.rect.h -| 1));
                const lc: u16 = if (col <= gp.rect.x) 0 else @intCast(@min(col - gp.rect.x, gp.rect.w -| 1));
                self.share.onMouse(lr, lc, m.action, m.button);
                self.touchAll();
                return;
            }
        };
        const now = std.time.milliTimestamp();

        // Drags in progress.
        switch (ws.drag) {
            .none => {},
            .divider => |node| {
                if (m.action == .release) {
                    ws.drag = .none;
                } else if (m.action == .motion) {
                    const pos_any = ws.currentTab().layout.nodes.items[node].kind.split;
                    ws.currentTab().layout.dragDivider(node, if (pos_any.dir == .right) col else row);
                    self.relayout();
                }
                return;
            },
            .tab => |from| {
                if (m.action == .release) {
                    ws.drag = .none;
                } else if (m.action == .motion) {
                    if (ws.barSlotAt(col)) |to| if (to != from and to < ws.tabs.tabs.items.len) {
                        ws.tabs.move(from, to);
                        ws.drag = .{ .tab = to };
                        self.relayout();
                    };
                }
                return;
            },
            .pane => |id| {
                if (ws.pane(id)) |p| try self.paneMouse(p, m);
                if (m.action == .release) ws.drag = .none;
                return;
            },
        }

        switch (ws.hitTest(col, row)) {
            .none, .status => {},
            .bar => |h| {
                if (m.action != .press) return;
                switch (m.button) {
                    .wheel_up, .wheel_down => {
                        const n = ws.tabs.tabs.items.len;
                        if (n > 1) {
                            const next = if (m.button == .wheel_down) (ws.tabs.active + 1) % n else (ws.tabs.active + n - 1) % n;
                            if (ws.selectTab(next)) self.relayout();
                        }
                    },
                    .left => switch (h) {
                        .tab => |i| {
                            const id = ws.tabs.tabs.items[i].id;
                            if (ws.rename) |r| if (r.tab != id) ws.endRename();
                            if (ws.selectTab(i)) self.relayout();
                            if (ws.barClick(id, now, 400)) {
                                try ws.startRename(id);
                                self.touchAll();
                            } else ws.drag = .{ .tab = i };
                        },
                        .close => |i| try self.requestCloseTab(i),
                        .new_tab => self.openTab(.{}),
                        .none => {},
                    },
                    .middle => switch (h) {
                        .tab, .close => |i| try self.requestCloseTab(i),
                        else => {},
                    },
                    else => {},
                }
            },
            .divider => |d| {
                if (m.action == .press and m.button == .left) ws.drag = .{ .divider = d.node };
            },
            .pane => |p| {
                if (m.action == .press and p.id != self.focusedPane().id) {
                    if (ws.focusPane(p.id)) self.relayout();
                }
                // Motion over panes other than the focused one is not reported.
                if (m.action == .motion and p.id != self.focusedPane().id) return;
                try self.paneMouse(p, m);
                const wheel = switch (m.button) {
                    .wheel_up, .wheel_down, .wheel_left, .wheel_right => true,
                    else => false,
                };
                if (m.action == .press and !wheel) ws.drag = .{ .pane = p.id };
            },
        }
    }

    fn paneMouse(self: *Gui, p: *Pane, m: events.MouseInput) !void {
        const local = Workspace.localMouse(p, m, self.cellW(), self.cellH());
        if (try p.ui.handleMouse(p.term, local, self.cellW(), self.cellH(), std.time.milliTimestamp())) {
            self.touch(p);
        } else {
            try termMouse(p.term, &p.mouse, local, .{ .w = self.cellW(), .h = self.cellH() });
        }
        try self.runPaneEffects(p);
    }

    // ------------------------------------------------------------ effects

    fn runEffects(self: *Gui) !void {
        // Window overlays (palette picks).
        if (self.chrome.effects.items.len > 0) {
            const fx = try self.chrome.takeEffects();
            defer self.chrome.freeEffects(fx);
            for (fx) |e| switch (e) {
                .write => |bytes| try self.focusedPane().term.write(bytes),
                .set_clipboard => |c| self.window.setClipboard(c.target, c.text),
                .request_paste => |r| self.window.requestClipboard(r.target, r.purpose),
                .open_url => |url| el.openUrl(self.cfg.url_open_command, url),
                .palette => |pick| try self.palettePick(pick),
            };
            self.touchAll();
        }
        for (self.ws.panes.items) |p| try self.runPaneEffects(p);
    }

    fn runPaneEffects(self: *Gui, p: *Pane) !void {
        if (p.ui.effects.items.len == 0) return;
        const fx = try p.ui.takeEffects();
        defer p.ui.freeEffects(fx);
        for (fx) |e| switch (e) {
            .write => |bytes| try p.term.write(bytes),
            .set_clipboard => |c| self.window.setClipboard(c.target, c.text),
            .request_paste => |r| self.window.requestClipboard(r.target, r.purpose),
            .open_url => |url| el.openUrl(self.cfg.url_open_command, url),
            .palette => {},
        };
        self.touch(p);
    }

    fn palettePick(self: *Gui, pick: palette_mod.Pick) !void {
        switch (pick) {
            .action => |n| self.window.queue.pushAction(.{ .action = @enumFromInt(n), .sym = 0, .mods = .{} }),
            .command => |n| if (self.plugins.host) |h| h.runCommand(n),
            .tab => |id| if (self.ws.tabs.indexOf(@intCast(id))) |i| {
                if (self.ws.selectTab(i)) self.relayout();
            },
            .muscle => |v| try self.musclePick(v),
            else => try self.sshPick(pick),
        }
    }

    // ------------------------------------------------------------ plugins

    fn startPlugins(self: *Gui) void {
        // Plugin chords are checked against the terminal's own bindings.
        el.installBindings(self.cfg);
        self.plugins.start(self.cfg, el.chordTaken);
        self.installAllBindings();
        self.refreshStatus();
        self.publishTabs();
        self.pluginEffects() catch {};
    }

    /// Config bindings, then the plugins' (never replacing one).
    fn installAllBindings(self: *Gui) void {
        el.installBindings(self.cfg);
        const h = self.plugins.host orelse return;
        for (h.binds.items) |b| {
            if (!events.bindings.addPlugin(b.chord, b.id)) h.log(b.plugin, "warn", "keybinding {s} is taken; ignored", .{b.spec});
        }
    }

    fn refreshStatus(self: *Gui) void {
        self.chrome.clearStatus();
        const h = self.plugins.host orelse return;
        for (h.segments.items) |seg| {
            if (seg.text.len == 0 or !seg.plugin.running()) continue;
            self.chrome.addStatus(seg.right, seg.text, seg.fg) catch {};
        }
    }

    fn setStatusBar(self: *Gui, on: bool) !void {
        if (self.chrome.status_visible == on) return;
        self.chrome.status_visible = on;
        self.applyLayout(self.ws.setGrid(self.ws.cols, self.ws.rows, self.chrome.statusRows()));
        self.frame.invalidate();
    }

    /// Apply what plugins asked for.
    fn pluginEffects(self: *Gui) !void {
        const h = self.plugins.host orelse return;
        if (h.effects.items.len == 0) return;
        // Handlers below can queue more (e.g. a theme hook): take a copy.
        const fx = try self.a.dupe(host_mod.Effect, h.effects.items);
        h.effects.clearRetainingCapacity();
        defer {
            for (fx) |*e| el.freeHostEffect(self.a, e);
            self.a.free(fx);
        }
        const now = std.time.milliTimestamp();
        for (fx) |e| switch (e) {
            .write => |bytes| try self.focusedPane().term.write(bytes),
            .set_clipboard => |text| self.window.setClipboard(.clipboard, text),
            .request_clipboard => self.window.requestClipboard(.clipboard, .plugin),
            .notify => |n| {
                var tb: [320]u8 = undefined;
                const line = std.fmt.bufPrint(&tb, "{s}: {s}", .{ n.source, n.text[0..@min(n.text.len, 280)] }) catch n.text;
                try self.chrome.addToast(line, switch (n.level) {
                    .info, .success => .info,
                    .warn => .warn,
                    .@"error" => .err,
                }, n.timeout_ms, now);
                if (n.desktop and !self.window_focused) el.desktopNotify(n.source, n.text);
                self.touchAll();
            },
            .theme => |t| {
                self.palette.* = t.palette;
                for (self.ws.panes.items) |p| p.term.palette = t.palette;
                h.setInfo(.theme, t.name);
                self.frame.invalidate();
                self.touchAll();
            },
            .action => |act| self.window.queue.pushAction(.{ .action = act, .sym = 0, .mods = .{} }),
            .redraw => {
                self.refreshStatus();
                self.touchAll();
            },
            .bindings_changed => self.installAllBindings(),
            .layout => |op| try self.layoutOp(op),
        };
    }

    fn layoutOp(self: *Gui, op: host_mod.LayoutOp) !void {
        const ws = self.ws;
        switch (op) {
            .tab_new => |cwd| self.openTab(.{ .cwd = cwd orelse "" }),
            .tab_focus => |id| if (ws.tabs.indexOf(id)) |i| {
                if (ws.selectTab(i)) self.relayout();
            },
            .tab_close => |id| if (ws.tabs.indexOf(id)) |i| try self.requestCloseTab(i),
            .tab_rename => |r| if (ws.tabs.indexOf(r.id)) |i| {
                try ws.tabs.tabs.items[i].setName(self.a, r.name);
                self.publishTabs();
                self.touchAll();
            },
            .pane_split => |d| self.splitPane(if (d == .right) .right else .down, .{}),
            .pane_focus => |id| if (ws.focusPane(id)) self.relayout(),
            .pane_close => |id| try self.requestClosePane(id),
        }
    }

    fn openCommandPalette(self: *Gui) !void {
        const pal = try self.chrome.openPalette(.commands, "");
        var cb: [48]u8 = undefined;
        // Tabs first ("Go to tab N: title").
        if (self.ws.tabs.tabs.items.len > 1) {
            for (self.ws.tabs.tabs.items, 0..) |tab, i| {
                var tb: [160]u8 = undefined;
                const label = std.fmt.bufPrint(&tb, "Go to tab {d}: {s}", .{ i + 1, self.ws.tabLabel(tab) }) catch "Go to tab";
                const chord: []const u8 = if (i < 9) events.chordFor(&events.bindings, @enumFromInt(@intFromEnum(events.Action.goto_tab_1) + i), &cb) orelse "" else "";
                try pal.addItem(.tab, label, chord, tab.id, false);
            }
        }
        for (try self.muscle.paletteItems()) |it| {
            try pal.addItem(.muscle, it.title, it.detail, it.arg, false);
        }
        if (self.plugins.host) |h| {
            for (h.commands.items, 0..) |cmd, i| {
                if (!cmd.plugin.running()) continue;
                try pal.addItem(.command, cmd.title, cmd.plugin.name, i, false);
            }
        }
        inline for (@typeInfo(events.Action).Enum.fields) |f| {
            const act: events.Action = @enumFromInt(f.value);
            if (act.title()) |ttl| {
                try pal.addItem(.action, ttl, events.chordFor(&events.bindings, act, &cb) orelse "", f.value, false);
            }
        }
        self.touchAll();
    }

    // ------------------------------------------------------------- config

    fn reloadConfig(self: *Gui) !void {
        const loop = self.loop;
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
        const fp = self.focusedPane();
        if (diags.hasErrors()) {
            std.debug.print("config: reload failed, keeping the previous settings\n", .{});
            try el.showDiagnostics(&fp.ui, &diags, shown_path, "kept the previous settings");
            return;
        }
        next.loadFromArgs(loop.args) catch {};

        var restart = std.ArrayList(u8).init(allocator);
        defer restart.deinit();
        try el.restartOnlyChanges(self.cfg, &next, &restart);
        try self.applyConfig(&next);
        self.cfg.deinit();
        self.cfg.* = next;
        adopted = true;
        // Slices into the old config's arena were re-pointed by applyConfig.
        const opts = el.uiOptions(self.cfg);
        self.chrome.opts = opts;
        self.fonts.opts.family = self.cfg.font_family;
        self.ws.opts.bar = session.BarMode.parse(self.cfg.tab_bar);
        self.ws.opts.dim = self.cfg.dim_inactive;
        for (self.ws.panes.items) |p| {
            p.ui.opts = opts;
            p.ai.applySettings(&p.ui, paneAiSettings(self.cfg, p.ssh_display));
        }
        self.muscle.setSettings(.{
            .enabled = self.cfg.muscle_enabled,
            .min_repeats = self.cfg.muscle_min_repeats,
            .max_len = self.cfg.muscle_max_len,
        });
        self.muscle.refreshShortcuts();
        if (self.plugins.reload(self.cfg, el.chordTaken)) {
            self.installAllBindings();
            self.refreshStatus();
            self.publishTabs();
        } else self.installAllBindings();
        self.relayout();

        std.debug.print("config: reloaded {s}\n", .{shown_path});
        var lines = std.ArrayList([]const u8).init(allocator);
        defer lines.deinit();
        for (diags.items.items) |it| try lines.append(it.text);
        var restart_line: []u8 = &.{};
        defer allocator.free(restart_line);
        if (restart.items.len > 0) {
            restart_line = try std.fmt.allocPrint(allocator, "restart YouNeeK Death Terminal to apply: {s}", .{restart.items});
            try lines.append(restart_line);
        }
        var head_buf: [512]u8 = undefined;
        const head = std.fmt.bufPrint(&head_buf, "config reloaded: {s}", .{shown_path}) catch "config reloaded";
        const now = std.time.milliTimestamp();
        const target = &self.focusedPane().ui;
        if (lines.items.len > 0) {
            try target.setNotice(.warning, head, lines.items, 10 * NOTICE_MS, now);
        } else try target.setNotice(.info, head, &.{}, NOTICE_MS, now);
    }

    fn applyConfig(self: *Gui, next: *const config.Config) !void {
        const old = self.cfg;
        self.palette.* = next.palette();
        for (self.ws.panes.items) |p| {
            p.term.palette = self.palette.*;
            el.applyCursorShape(p.term, next.cursor_shape);
            el.applyColumnSwitch(p.term, next.allow_column_switch, false);
        }
        _ = self.fontsChangedAndLoad(old, next);
        self.vk.setPresentMode(renderer.PresentMode.parse(next.present_mode) orelse .fifo);
        self.pace.frame_ns = el.frameNs(next.max_fps);
        self.pace.read_budget = @as(usize, next.read_budget_kb) * 1024;
        el.installBindings(next);
        self.travel.apply(next);
        if (old.status_bar != next.status_bar) try self.setStatusBar(next.status_bar);
        self.frame.invalidate();
        self.share.configure(next);
    }

    fn serviceShare(self: *Gui) !void {
        var buf: [1024]u8 = undefined;
        const n = self.share.takeInput(&buf);
        if (n > 0) if (self.ws.pane(self.share.pane)) |p| {
            try p.term.write(buf[0..n]);
            self.touch(p);
        };
        if (self.share.host != null) if (self.ws.pane(self.share.pane)) |p| self.share.flushGrid(p.term);
        if (self.share.isGuest()) if (self.ws.pane(self.share.pane)) |p| {
            if (self.share.applyGrid(p.term)) {
                p.ui.scroll = 0;
                self.touch(p);
            }
        };
        try self.showShare();
    }

    fn showShare(self: *Gui) !void {
        var dirty = false;
        if (self.share.takeAnnounce()) |code| {
            try self.focusedPane().ui.setNotice(.info, "Shared Haunting — deathterminal --join", &.{code}, null, std.time.milliTimestamp());
            dirty = true;
        }
        if (self.share.takeError()) |text| {
            try self.focusedPane().ui.setNotice(.err, "Share", &.{text}, 6000, std.time.milliTimestamp());
            dirty = true;
        }
        if (dirty) self.touchAll();
    }

    fn fontsChangedAndLoad(self: *Gui, old: *const config.Config, next: *const config.Config) bool {
        if (!el.fontsChanged(old, next)) return false;
        if (fonts_mod.Fonts.init(self.cfg.allocator, el.fontOptions(next, self.fonts.scale))) |f_new| {
            var f = f_new;
            // New atlas contents: make sure no cache or GPU copy matches.
            f.atlas.generation = self.fonts.atlas.generation +% 1;
            f.atlas.epoch = self.fonts.atlas.epoch +% 1;
            self.fonts.deinit();
            self.fonts.* = f;
            self.frame.invalidate();
            self.fitWindow(self.window.width, self.window.height);
            std.debug.print("  → Font: {s} {d:.1}pt, cell {d}x{d}px\n", .{ self.fonts.familyName(), self.fonts.size_pt, self.cellW(), self.cellH() });
            return true;
        } else |err| {
            std.debug.print("config: cannot load the new font ({s}); keeping the current one\n", .{@errorName(err)});
            return false;
        }
    }

    // ---------------------------------------------------------------- ssh

    /// pid of the SSH client when the focused pane is an SSH session.
    fn sshPid(self: *Gui) ?posix.pid_t {
        const fp = self.focusedPane();
        if (fp.ssh_display.len == 0) return null;
        const p = fp.term.pty orelse return null;
        return p.child_pid;
    }

    fn openSshPalette(self: *Gui) !void {
        const fp = self.focusedPane();
        const pal = try self.chrome.openPalette(.ssh, if (fp.ssh_display.len > 0) fp.ssh_display else "profiles  (Enter: new tab · Shift+Enter: split · Alt+Enter: window)");
        try self.fillSshPalette(pal);
        self.touchAll();
    }

    /// The focused session's forwards + reconnect (from the client's
    /// control socket), then profiles and ~/.ssh/config aliases.
    fn fillSshPalette(self: *Gui, pal: *palette_mod.Palette) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.a);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var items = std.ArrayList(palette_mod.Item).init(a);
        if (self.sshPid()) |pid| {
            var out: [8192]u8 = undefined;
            if (ssh_control.request(pid, "list", &out)) |reply| {
                var lines = std.mem.splitScalar(u8, reply, '\n');
                while (lines.next()) |ln| {
                    const f = el.parseForwardLine(ln) orelse continue;
                    try items.append(.{ .kind = .forward, .name = try a.dupe(u8, f.spec), .detail = try a.dupe(u8, f.state), .arg = f.n, .on = f.on });
                }
            } else |_| try pal.setStatus(" session not reachable (still connecting?) ");
            try items.append(.{ .kind = .reconnect, .name = try a.dupe(u8, "Reconnect"), .detail = try a.dupe(u8, self.focusedPane().ssh_display) });
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
        std.mem.sort(palette_mod.Item, items.items[first_profile..], {}, struct {
            fn lt(_: void, x: palette_mod.Item, y: palette_mod.Item) bool {
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

    fn sshPick(self: *Gui, pick: palette_mod.Pick) !void {
        const now = std.time.milliTimestamp();
        switch (pick) {
            .open => |o| {
                var hb: [300]u8 = undefined;
                switch (o.where) {
                    .window => {
                        el.openSshWindow(self.loop, o.name);
                        try self.chrome.addToast(std.fmt.bufPrint(&hb, "ssh: opening {s} in a new window", .{o.name}) catch "ssh: opening a new window", .info, NOTICE_MS, now);
                    },
                    .tab => self.openTab(.{ .ssh = o.name }),
                    .split => self.splitPane(.right, .{ .ssh = o.name }),
                }
            },
            .toggle => |n| {
                const pid = self.sshPid() orelse return;
                var cmd: [32]u8 = undefined;
                var out: [512]u8 = undefined;
                const reply = ssh_control.request(pid, std.fmt.bufPrint(&cmd, "toggle {d}", .{n}) catch "list", &out) catch "error session not reachable";
                if (self.chrome.palette) |*pal| {
                    var spec: []const u8 = "forward";
                    for (pal.items.items) |it| if (it.kind == .forward and it.arg == n) {
                        spec = it.name;
                    };
                    var sb: [200]u8 = undefined;
                    try pal.setStatus(el.toggleStatus(&sb, spec, std.mem.trim(u8, reply, " \n")));
                    try self.fillSshPalette(pal);
                }
            },
            .reconnect => {
                const pid = self.sshPid() orelse return;
                var out: [64]u8 = undefined;
                _ = ssh_control.request(pid, "reconnect", &out) catch {};
            },
            .action, .command, .tab, .muscle => {},
        }
    }

    // ------------------------------------------------------- muscle memory

    fn paneDir(self: *Gui, p: *Pane) []const u8 {
        if (p.track.cwd.items.len > 0) return p.track.cwd.items;
        return terminal.shell_integration.cwdFromUri(p.term.cwd_uri, &self.muscle_dir) orelse "";
    }

    fn muscleAfterOutput(self: *Gui, p: *Pane) !void {
        const now_finished = p.term.shell.finished;
        const prev = p.muscle_finished;
        if (now_finished == prev) return;
        p.muscle_finished = now_finished;
        var delta = now_finished -% prev;
        if (delta > terminal.shell_integration.max_history) delta = terminal.shell_integration.max_history;
        const hist = p.term.shell.history.items;
        if (hist.len == 0 or delta == 0) return;
        const start = hist.len - @min(delta, hist.len);
        const cwd = self.paneDir(p);
        var offer = false;
        for (hist[start..]) |cmd| {
            offer = (self.muscle.observe(cwd, cmd.text, cmd.exit_code) catch false) or offer;
            const step = self.muscle.runExit(p.id, cmd.text, cmd.exit_code) catch continue;
            try self.applyRunStep(p, step);
        }
        if (offer) self.refreshMuscleUi(true);
    }

    fn applyRunStep(self: *Gui, p: *Pane, step: muscle_mod.RunStep) !void {
        switch (step) {
            .ignore, .finished => {},
            .send => |bytes| {
                defer self.a.free(bytes);
                try p.term.write(bytes);
                self.touch(p);
            },
            .stopped => |msg| {
                defer self.a.free(msg);
                try self.chrome.addToast(msg, .warn, 6 * NOTICE_MS, std.time.milliTimestamp());
                self.touchAll();
            },
        }
    }

    fn tryMuscleEnter(self: *Gui) !bool {
        const fp = self.focusedPane();
        const raw = (fp.term.currentInput(self.a) catch return false) orelse return false;
        defer self.a.free(raw);
        const name = std.mem.trim(u8, raw, " \t");
        if (name.len == 0) return false;
        const cwd = self.paneDir(fp);
        if (self.muscle.running()) {
            return self.muscle.lookup(cwd, name) != null;
        }
        const idx = self.muscle.lookup(cwd, name) orelse return false;
        if (fp.commandRunning()) {
            try self.chrome.addToast("finish the current command first", .warn, NOTICE_MS, std.time.milliTimestamp());
            self.touchAll();
            return true;
        }
        if (try self.muscle.begin(idx, fp.id, fp.term.shell.seen, true)) |bytes| {
            defer self.a.free(bytes);
            try fp.term.write(bytes);
            self.touch(fp);
        }
        return true;
    }

    fn musclePick(self: *Gui, v: usize) !void {
        const decoded = muscle_mod.unpack(v) orelse return;
        const now = std.time.milliTimestamp();
        const fp = self.focusedPane();
        switch (decoded.op) {
            .run => {
                if (fp.commandRunning()) {
                    try self.chrome.addToast("finish the current command first", .warn, NOTICE_MS, now);
                    return;
                }
                if (try self.muscle.begin(decoded.index, fp.id, fp.term.shell.seen, true)) |bytes| {
                    defer self.a.free(bytes);
                    try fp.term.write(bytes);
                    self.touch(fp);
                }
            },
            .rename => {
                try self.muscle.beginRename(decoded.index);
                self.refreshMuscleUi(false);
            },
            .delete => if (try self.muscle.deleteAt(decoded.index)) {
                try self.chrome.addToast(self.muscle.status(), .info, NOTICE_MS, now);
            },
            .save => {
                self.muscle.acceptOffer(false);
                self.refreshMuscleUi(false);
            },
            .save_global => {
                self.muscle.acceptOffer(true);
                self.refreshMuscleUi(false);
            },
        }
    }

    fn muscleResult(self: *Gui, r: muscle_mod.InputResult) void {
        const fp = self.focusedPane();
        const now = std.time.milliTimestamp();
        switch (r) {
            .idle => {},
            .stay, .invalid => self.refreshMuscleUi(false),
            .saved => {
                fp.ui.clearNotice();
                self.chrome.addToast(self.muscle.status(), .info, NOTICE_MS, now) catch {};
            },
            .dismissed => fp.ui.clearNotice(),
        }
        self.touchAll();
    }

    fn refreshMuscleUi(self: *Gui, toast_offer: bool) void {
        const fp = self.focusedPane();
        const now = std.time.milliTimestamp();
        switch (self.muscle.mode) {
            .idle => {},
            .offer => {
                if (toast_offer) self.chrome.addToast(muscle_mod.offer_text, .info, 20 * NOTICE_MS, now) catch {};
                var lines: [5][]const u8 = undefined;
                var n: usize = 0;
                const cmds = self.muscle.offerCommands();
                const show = @min(cmds.len, 3);
                for (cmds[0..show]) |c| {
                    lines[n] = c;
                    n += 1;
                }
                if (cmds.len > show) {
                    lines[n] = "…";
                    n += 1;
                }
                lines[n] = "y save · n dismiss · Esc dismiss · *name saves it globally";
                n += 1;
                fp.ui.setNotice(.info, muscle_mod.offer_text, lines[0..n], null, now) catch {};
            },
            .name => {
                const typed = self.muscle.nameText();
                const shown: []const u8 = if (typed.len == 0) "(type a name)" else typed;
                const hint: []const u8 = if (self.muscle.status().len > 0) self.muscle.status() else "Enter saves · Esc cancels · prefix * for every project";
                const lines = [_][]const u8{ shown, hint };
                fp.ui.setNotice(.info, "Name this shortcut", &lines, null, now) catch {};
            },
        }
        self.touchAll();
    }
};

/// Number of arrow-key presses sent per wheel notch in the alternate screen
/// when the application did not enable mouse reporting (xterm's
/// "alternateScroll" behaviour, so `less`/`man` scroll with the wheel).
const ALT_SCROLL_LINES: usize = 3;

/// Mouse event (in the pane's own pixels) for the application.
fn termMouse(term: *terminal.Terminal, st: *session.MouseState, m: events.MouseInput, cell: software.CellPx) !void {
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
                for (0..ALT_SCROLL_LINES) |_| try term.write(seq.constSlice());
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
    if (input.encodeMouse(ev, term.modes, st.held != .none)) |seq| try term.write(seq.constSlice());
}
