//! A window's sessions: panes (each with its own terminal, UI state and AI
//! context) arranged in tabs of split layouts, and the composite grid the
//! renderer draws from them (tab bar, dividers, dimming, status row).

const std = @import("std");
const posix = std.posix;
const terminal = @import("../terminal/terminal.zig");
const input = @import("../terminal/input.zig");
const color = @import("../terminal/color.zig");
const frame_mod = @import("../renderer/frame.zig");
const events = @import("../platform/events.zig");
const ui_mod = @import("ui.zig");
const ai_controller = @import("ai_controller.zig");
const plugin_bridge = @import("plugin_bridge.zig");
pub const layout = @import("layout.zig");
pub const tabs_mod = @import("tabs.zig");

const Terminal = terminal.Terminal;
const Cell = terminal.Cell;
const Mark = frame_mod.Mark;
pub const PaneId = layout.PaneId;
pub const Rect = layout.Rect;

pub const MouseState = struct {
    held: input.MouseButton = .none,
    last_col: u16 = std.math.maxInt(u16),
    last_row: u16 = std.math.maxInt(u16),
};

pub const Pane = struct {
    id: PaneId,
    term: *Terminal,
    /// false for the first pane, whose terminal belongs to main().
    owned: bool,
    ui: ui_mod.Ui,
    ai: ai_controller.Controller,
    mouse: MouseState = .{},
    /// This pane's composed view (term.rows × term.cols).
    cells: std.ArrayList(Cell),
    marks: std.ArrayList(Mark),
    composed: ui_mod.Composed = .{ .cursor_row = 0, .cursor_col = 0, .cursor_visible = false },
    /// Needs composing again before the next frame.
    dirty: bool = true,
    track: plugin_bridge.Track,
    /// "user@host:port" when the pane runs the SSH client (owned).
    ssh_display: []u8 = &.{},
    /// The last read stopped at the budget: more output is waiting.
    backlog: bool = false,
    /// Output / bell since the pane was last looked at.
    activity: bool = false,
    bell: bool = false,
    seen_bells: u32 = 0,
    /// Command counters last drawn in the tab bar.
    bar_seen: u64 = 0,
    /// Where the pane is drawn (empty when its tab is hidden or another
    /// pane is zoomed).
    rect: Rect = .{},
    visible: bool = false,

    pub fn create(a: std.mem.Allocator, id: PaneId, term: *Terminal, owned: bool, ssh_display: []const u8, ui_opts: ui_mod.Options, ai_settings_in: ai_controller.Settings) !*Pane {
        const p = try a.create(Pane);
        errdefer a.destroy(p);
        const display = try a.dupe(u8, ssh_display);
        var ai_settings = ai_settings_in;
        // Slices the controller keeps must outlive it: the pane owns this one.
        ai_settings.remote = display;
        p.* = .{
            .ssh_display = display,
            .id = id,
            .term = term,
            .owned = owned,
            .ui = ui_mod.Ui.init(a, ui_opts),
            .ai = ai_controller.Controller.init(a, ai_settings),
            .cells = std.ArrayList(Cell).init(a),
            .marks = std.ArrayList(Mark).init(a),
            .track = .{ .term = term, .pane = id },
            .seen_bells = term.bell_count,
        };
        return p;
    }

    /// Frees the pane; returns the child's pid when it may still need
    /// reaping.
    pub fn destroy(self: *Pane, a: std.mem.Allocator) ?posix.pid_t {
        self.ui.deinit();
        self.ai.deinit();
        self.cells.deinit();
        self.marks.deinit();
        self.track.deinit(a);
        a.free(self.ssh_display);
        var pid: ?posix.pid_t = null;
        if (self.owned) {
            if (self.term.pty) |p| pid = p.child_pid;
            self.term.deinit();
            a.destroy(self.term);
        }
        a.destroy(self);
        return pid;
    }

    pub fn ptyFd(self: *const Pane) posix.fd_t {
        return self.term.getPtyFd() orelse -1;
    }

    /// Name of the program in the foreground of the pane's terminal when
    /// it isn't the shell itself (for "close anyway?"), else null.
    pub fn runningProgram(self: *const Pane, buf: []u8) ?[]const u8 {
        const p = self.term.pty orelse return null;
        const child = p.child_pid orelse return null;
        const fd = self.term.getPtyFd() orelse return null;
        const pgrp = tcgetpgrp(fd) orelse return null;
        if (pgrp == child or pgrp <= 0) return null;
        var pb: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&pb, "/proc/{d}/comm", .{pgrp}) catch return "a program";
        const f = std.fs.openFileAbsolute(path, .{}) catch return "a program";
        defer f.close();
        const n = f.read(buf) catch return "a program";
        const name = std.mem.trimRight(u8, buf[0..n], "\n");
        return if (name.len == 0) "a program" else name;
    }

    /// Exit code of the last finished command (OSC 133 D), if any.
    pub fn lastExit(self: *const Pane) ?i32 {
        const c = self.term.shell.lastCommand() orelse return null;
        return c.exit_code;
    }

    /// Whether a command is running (OSC 133 C seen, no D yet).
    pub fn commandRunning(self: *const Pane) bool {
        return self.term.shell.started > self.term.shell.finished;
    }
};

fn tcgetpgrp(fd: posix.fd_t) ?posix.pid_t {
    var pgrp: posix.pid_t = 0;
    const rc = std.os.linux.ioctl(fd, std.os.linux.T.IOCGPGRP, @intFromPtr(&pgrp));
    if (std.os.linux.E.init(rc) != .SUCCESS) return null;
    return pgrp;
}

pub const BarMode = enum {
    auto,
    top,
    bottom,
    hidden,

    pub fn parse(s: []const u8) BarMode {
        return std.meta.stringToEnum(BarMode, s) orelse .auto;
    }
};

pub const Confirm = struct {
    pub const What = union(enum) { pane: PaneId, tab: tabs_mod.TabId, window };
    what: What,
    /// What is still running (for the prompt).
    program: [64]u8 = undefined,
    program_len: usize = 0,

    pub fn programName(self: *const Confirm) []const u8 {
        return self.program[0..self.program_len];
    }
};

pub const Rename = struct {
    tab: tabs_mod.TabId,
    text: std.ArrayListUnmanaged(u8) = .{},
};

pub const Drag = union(enum) {
    none,
    divider: layout.NodeId,
    tab: usize,
    /// Mouse events go to this pane until the button is released.
    pane: PaneId,
};

/// Where a mouse position falls in the window grid.
pub const Hit = union(enum) {
    none,
    bar: tabs_mod.Bar.Hit,
    divider: layout.Divider,
    pane: *Pane,
    status,
};

pub const Composite = struct {
    rows: u16,
    cols: u16,
    cursor_row: u16 = 0,
    cursor_col: u16 = 0,
    cursor_visible: bool = false,
    scrollbar: ?struct { top: f32, height: f32 } = null,
};

pub const Options = struct {
    bar: BarMode = .auto,
    /// 0 = off; 0..0.9 fades inactive panes' text towards the background.
    dim: f32 = 0,
    /// Window-wide palette (dimming resolves colours with it).
    palette: *const color.Palette = &color.default_palette,
};

pub const Workspace = struct {
    a: std.mem.Allocator,
    tabs: tabs_mod.TabSet,
    panes: std.ArrayListUnmanaged(*Pane) = .{},
    opts: Options = .{},
    /// toggle_tab_bar flips this over `opts.bar`.
    bar_toggled: ?bool = null,
    /// Whole window grid.
    cols: u16 = 80,
    rows: u16 = 24,
    status_rows: u16 = 0,
    /// Tab bar row (null = hidden) and the area panes share.
    bar_row: ?u16 = null,
    area: Rect = .{},
    bar: tabs_mod.Bar = .{},
    cells: std.ArrayList(Cell),
    marks: std.ArrayList(Mark),
    rename: ?Rename = null,
    confirm: ?Confirm = null,
    drag: Drag = .none,
    last_bar_click_ms: i64 = 0,
    last_bar_click_tab: ?tabs_mod.TabId = null,
    /// Everything must be composed again (layout, tab or theme change).
    full: bool = true,
    /// Children of closed panes not reaped yet.
    zombies: std.ArrayListUnmanaged(posix.pid_t) = .{},
    scratch_rects: std.ArrayList(layout.PaneRect),
    scratch_divs: std.ArrayList(layout.Divider),

    pub fn init(a: std.mem.Allocator) Workspace {
        return .{
            .a = a,
            .tabs = tabs_mod.TabSet.init(a),
            .cells = std.ArrayList(Cell).init(a),
            .marks = std.ArrayList(Mark).init(a),
            .scratch_rects = std.ArrayList(layout.PaneRect).init(a),
            .scratch_divs = std.ArrayList(layout.Divider).init(a),
        };
    }

    pub fn deinit(self: *Workspace) void {
        for (self.panes.items) |p| if (p.destroy(self.a)) |pid| self.zombies.append(self.a, pid) catch {};
        self.panes.deinit(self.a);
        self.tabs.deinit();
        self.cells.deinit();
        self.marks.deinit();
        self.scratch_rects.deinit();
        self.scratch_divs.deinit();
        self.endRename();
        self.reap();
        self.zombies.deinit(self.a);
    }

    // ------------------------------------------------------------ lookup

    pub fn pane(self: *const Workspace, id: PaneId) ?*Pane {
        for (self.panes.items) |p| if (p.id == id) return p;
        return null;
    }

    pub fn currentTab(self: *const Workspace) *tabs_mod.Tab {
        return self.tabs.current().?;
    }

    pub fn focused(self: *const Workspace) *Pane {
        return self.pane(self.currentTab().focused).?;
    }

    /// Visible panes (the active tab's, or only the zoomed one).
    pub fn visiblePanes(self: *const Workspace, out: *std.ArrayList(*Pane)) !void {
        for (self.panes.items) |p| if (p.visible) try out.append(p);
    }

    pub fn visibleCount(self: *const Workspace) usize {
        var n: usize = 0;
        for (self.panes.items) |p| n += @intFromBool(p.visible);
        return n;
    }

    // ----------------------------------------------------------- building

    /// Register a pane created by the caller.
    pub fn addPane(self: *Workspace, p: *Pane) !void {
        try self.panes.append(self.a, p);
    }

    /// A new tab around pane `p` (already added), after the active one.
    pub fn newTab(self: *Workspace, p: *Pane) !*tabs_mod.Tab {
        const tab = try self.tabs.add(p.id, true);
        p.track.tab = tab.id;
        self.full = true;
        return tab;
    }

    /// Split the focused pane of the current tab; `p` (added) takes the
    /// new half and the focus.
    pub fn splitFocused(self: *Workspace, dir: layout.Dir, p: *Pane, ratio: f32) !void {
        const tab = self.currentTab();
        tab.zoomed = false;
        try tab.layout.split(tab.focused, dir, p.id, ratio);
        tab.focused = p.id;
        p.track.tab = tab.id;
        self.full = true;
    }

    /// Take pane `id` out of its tab (and the tab out of the window when it
    /// was the last one). The caller destroys the pane. Returns the tab
    /// index that was removed, if any.
    pub fn detachPane(self: *Workspace, id: PaneId) ?usize {
        var removed_tab: ?usize = null;
        if (self.tabs.tabOf(id)) |tab| {
            const next = tab.layout.remove(id);
            if (next) |n| {
                if (tab.focused == id) tab.focused = n;
                if (tab.layout.count() <= 1) tab.zoomed = false;
            } else {
                const idx = self.tabs.indexOf(tab.id).?;
                if (self.rename) |r| if (r.tab == tab.id) self.endRename();
                self.tabs.remove(idx);
                removed_tab = idx;
            }
        }
        for (self.panes.items, 0..) |p, i| if (p.id == id) {
            _ = self.panes.orderedRemove(i);
            break;
        };
        self.full = true;
        return removed_tab;
    }

    /// Destroy a pane already detached; its child is reaped later.
    pub fn destroyPane(self: *Workspace, p: *Pane) void {
        if (p.destroy(self.a)) |pid| self.zombies.append(self.a, pid) catch {};
        self.reap();
    }

    /// Collect exited children of closed panes.
    pub fn reap(self: *Workspace) void {
        var i: usize = 0;
        while (i < self.zombies.items.len) {
            const r = posix.waitpid(self.zombies.items[i], posix.W.NOHANG);
            if (r.pid != 0) {
                _ = self.zombies.swapRemove(i);
            } else i += 1;
        }
    }

    // ------------------------------------------------------------- layout

    pub fn barVisible(self: *const Workspace) bool {
        const auto_on = switch (self.opts.bar) {
            .hidden => false,
            .auto => self.tabs.tabs.items.len > 1,
            .top, .bottom => true,
        };
        return self.bar_toggled orelse auto_on;
    }

    /// The window grid changed size (or the status row / tab bar came or
    /// went).
    pub fn setGrid(self: *Workspace, cols: u16, rows: u16, status_rows: u16) bool {
        self.cols = @max(cols, 1);
        self.rows = @max(rows, 1);
        self.status_rows = status_rows;
        return self.relayout();
    }

    /// Place every tab's panes and resize terminals that changed size.
    /// Returns true if the focused pane's size changed.
    pub fn relayout(self: *Workspace) bool {
        const show_bar = self.barVisible() and self.rows > self.status_rows + 2;
        const bottom = self.opts.bar == .bottom;
        const avail = self.rows -| self.status_rows;
        self.bar_row = if (show_bar) (if (bottom) avail - 1 else 0) else null;
        const top: u16 = if (show_bar and !bottom) 1 else 0;
        const h = @max(avail -| @as(u16, @intFromBool(show_bar)), 1);
        self.area = .{ .x = 0, .y = top, .w = self.cols, .h = h };
        const focus_id = if (self.tabs.current()) |t| t.focused else 0;
        var focus_resized = false;
        for (self.tabs.tabs.items, 0..) |tab, ti| {
            tab.layout.compute(self.area);
            const active = ti == self.tabs.active;
            self.scratch_rects.clearRetainingCapacity();
            tab.layout.paneRects(&self.scratch_rects) catch {};
            for (self.scratch_rects.items) |pr| {
                const p = self.pane(pr.pane) orelse continue;
                var r = pr.rect;
                if (tab.zoomed and pr.pane == tab.focused) r = self.area;
                p.visible = active and (!tab.zoomed or pr.pane == tab.focused);
                p.rect = r;
                p.track.tab = tab.id;
                const rows = @max(r.h, 1);
                const cols = @max(r.w, 1);
                if (rows != p.term.rows or cols != p.term.cols) {
                    p.term.resize(rows, cols) catch {};
                    p.ui.sync(p.term);
                    if (p.id == focus_id) focus_resized = true;
                }
                p.dirty = true;
                if (p.visible and p.id == focus_id) p.activity = false;
            }
        }
        self.full = true;
        return focus_resized;
    }

    // --------------------------------------------------------- tabs/focus

    /// Make pane `id` the focused one (switching tabs if needed). Returns
    /// whether anything changed.
    pub fn focusPane(self: *Workspace, id: PaneId) bool {
        const tab = self.tabs.tabOf(id) orelse return false;
        const idx = self.tabs.indexOf(tab.id).?;
        if (idx == self.tabs.active and tab.focused == id) return false;
        const zoom_change = tab.zoomed and tab.focused != id;
        tab.focused = id;
        if (zoom_change) tab.zoomed = false;
        if (idx != self.tabs.active or zoom_change) {
            self.tabs.select(idx);
            _ = self.relayout();
        }
        if (self.pane(id)) |p| {
            p.activity = false;
            p.bell = false;
        }
        self.full = true;
        return true;
    }

    pub fn selectTab(self: *Workspace, index: usize) bool {
        if (index >= self.tabs.tabs.items.len or index == self.tabs.active) return false;
        self.tabs.select(index);
        _ = self.relayout();
        if (self.pane(self.currentTab().focused)) |p| {
            p.activity = false;
            p.bell = false;
        }
        return true;
    }

    /// Directional focus within the current tab.
    pub fn focusDirection(self: *Workspace, side: layout.Side) bool {
        const tab = self.currentTab();
        if (tab.zoomed) return false;
        const n = tab.layout.neighbor(tab.focused, side) orelse return false;
        return self.focusPane(n);
    }

    /// next/prev pane in layout order (cycles).
    pub fn cyclePane(self: *Workspace, delta: i32) bool {
        const tab = self.currentTab();
        var list = std.ArrayList(PaneId).init(self.a);
        defer list.deinit();
        tab.layout.panes(&list) catch return false;
        if (list.items.len < 2) return false;
        const cur = std.mem.indexOfScalar(PaneId, list.items, tab.focused) orelse 0;
        const n: i32 = @intCast(list.items.len);
        const next: usize = @intCast(@mod(@as(i32, @intCast(cur)) + delta, n));
        return self.focusPane(list.items[next]);
    }

    pub fn toggleZoom(self: *Workspace) bool {
        const tab = self.currentTab();
        if (tab.layout.count() < 2 and !tab.zoomed) return false;
        tab.zoomed = !tab.zoomed;
        _ = self.relayout();
        return true;
    }

    pub fn resizeFocused(self: *Workspace, side: layout.Side, cells: u16) bool {
        const tab = self.currentTab();
        if (tab.zoomed) return false;
        if (!tab.layout.resize(tab.focused, side, cells)) return false;
        _ = self.relayout();
        return true;
    }

    pub fn equalize(self: *Workspace) bool {
        const tab = self.currentTab();
        if (tab.layout.count() < 2) return false;
        tab.layout.equalize();
        _ = self.relayout();
        return true;
    }

    // -------------------------------------------------------------- rename

    pub fn startRename(self: *Workspace, tab_id: tabs_mod.TabId) !void {
        self.endRename();
        const idx = self.tabs.indexOf(tab_id) orelse return;
        var r = Rename{ .tab = tab_id };
        // Start from the name given before; titles are replaced by typing.
        if (self.tabs.tabs.items[idx].name) |n| try r.text.appendSlice(self.a, n);
        self.rename = r;
        self.full = true;
    }

    pub fn endRename(self: *Workspace) void {
        if (self.rename) |*r| r.text.deinit(self.a);
        self.rename = null;
        self.full = true;
    }

    /// Keys while renaming: Enter keeps, Escape cancels. True = consumed.
    pub fn renameKey(self: *Workspace, key: input.Key) !bool {
        const r = &(self.rename orelse return false);
        switch (key) {
            .enter, .kp_enter => {
                if (self.tabs.indexOf(r.tab)) |i| try self.tabs.tabs.items[i].setName(self.a, std.mem.trim(u8, r.text.items, " "));
                self.endRename();
            },
            .escape => self.endRename(),
            .backspace => deleteLast(&r.text),
            else => {},
        }
        self.full = true;
        return true;
    }

    /// Typed text while renaming. True = consumed.
    pub fn renameText(self: *Workspace, bytes: []const u8) !bool {
        const r = &(self.rename orelse return false);
        if (bytes.len == 1) switch (bytes[0]) {
            '\r', '\n' => return self.renameKey(.enter),
            0x1b, 0x03, 0x07 => return self.renameKey(.escape),
            0x7f, 0x08 => return self.renameKey(.backspace),
            0x15 => {
                r.text.clearRetainingCapacity();
                self.full = true;
                return true;
            },
            else => {},
        };
        for (bytes) |b| if (b < 0x20 or b == 0x7f) return true;
        if (r.text.items.len + bytes.len <= 64) try r.text.appendSlice(self.a, bytes);
        self.full = true;
        return true;
    }

    // ------------------------------------------------------------- labels

    /// Tab name, else its focused pane's title, else its directory.
    pub fn tabLabel(self: *const Workspace, tab: *const tabs_mod.Tab) []const u8 {
        if (tab.name) |n| return n;
        const p = self.pane(tab.focused) orelse return "shell";
        if (p.term.title.len > 0) return p.term.title;
        if (p.track.cwd.items.len > 0) return std.fs.path.basename(p.track.cwd.items);
        if (p.ssh_display.len > 0) return p.ssh_display;
        return "shell";
    }

    /// The directory shown next to the title (basename), "" when the title
    /// already mentions it.
    fn tabDir(self: *const Workspace, tab: *const tabs_mod.Tab, label: []const u8) []const u8 {
        const p = self.pane(tab.focused) orelse return "";
        const cwd = p.track.cwd.items;
        if (cwd.len == 0) return "";
        const base = if (std.mem.eql(u8, cwd, "/")) "/" else std.fs.path.basename(cwd);
        if (std.mem.indexOf(u8, label, base) != null) return "";
        return base;
    }

    const TabState = struct { activity: bool, bell: bool, failed: bool, running: bool };

    fn tabState(self: *const Workspace, tab: *const tabs_mod.Tab) TabState {
        var st = TabState{ .activity = false, .bell = false, .failed = false, .running = false };
        for (self.panes.items) |p| {
            if (!tab.layout.contains(p.id)) continue;
            st.activity = st.activity or p.activity;
            st.bell = st.bell or p.bell;
            if (p.id == tab.focused) {
                st.running = p.commandRunning();
                if (p.lastExit()) |c| st.failed = c != 0 and !st.running;
            }
        }
        return st;
    }

    // ----------------------------------------------------------- drawing

    /// Build the window grid in `self.cells` / `self.marks`. `chrome` draws
    /// window overlays (toasts, palette, status row) when given.
    pub fn compose(self: *Workspace, chrome: ?*ui_mod.Ui) !Composite {
        const cols = self.cols;
        const rows = self.rows;
        const n = @as(usize, rows) * cols;
        const pal = self.opts.palette;
        if (self.cells.items.len != n) {
            try self.cells.resize(n);
            try self.marks.resize(n);
            self.full = true;
        }
        const blank = Cell.init();
        if (self.full) {
            @memset(self.cells.items, blank);
            @memset(self.marks.items, .none);
        }
        var out = Composite{ .rows = rows, .cols = cols };
        const tab = self.currentTab();
        const visible = self.visibleCount();
        const dim = if (visible > 1) self.opts.dim else 0;

        for (self.panes.items) |p| {
            if (!p.visible) continue;
            if (!p.dirty and !self.full) continue;
            p.composed = try p.ui.compose(p.term, &p.cells, &p.marks);
            p.dirty = false;
            const r = p.rect;
            const pr = @min(r.h, p.term.rows);
            const pc = @min(r.w, p.term.cols);
            const fade = if (p.id != tab.focused) dim else 0;
            var y: u16 = 0;
            while (y < pr) : (y += 1) {
                if (r.y + y >= rows) break;
                const src = p.cells.items[@as(usize, y) * p.term.cols ..][0..pc];
                const srcm = p.marks.items[@as(usize, y) * p.term.cols ..][0..pc];
                const off = @as(usize, r.y + y) * cols + r.x;
                const dst = self.cells.items[off..][0..pc];
                @memcpy(dst, src);
                @memcpy(self.marks.items[off..][0..pc], srcm);
                if (fade > 0) for (dst) |*c| dimCell(c, pal, fade);
            }
            // Rows the terminal doesn't cover (shouldn't happen) stay blank.
        }

        // Dividers.
        if (!tab.zoomed and self.full) {
            self.scratch_divs.clearRetainingCapacity();
            try tab.layout.dividers(&self.scratch_divs);
            const fr = if (self.pane(tab.focused)) |p| p.rect else Rect{};
            const line_fg = blend(pal.bg, pal.fg, 0.30);
            const accent = accentColor(pal);
            for (self.scratch_divs.items) |d| {
                const near = touches(d, fr);
                var c = blank;
                c.fg_color = if (near) accent else line_fg;
                c.char = if (d.dir == .right) '│' else '─';
                var y = d.rect.y;
                while (y < d.rect.y + d.rect.h and y < rows) : (y += 1) {
                    var x = d.rect.x;
                    while (x < d.rect.x + d.rect.w and x < cols) : (x += 1) {
                        const i = @as(usize, y) * cols + x;
                        self.cells.items[i] = c;
                        self.marks.items[i] = .none;
                    }
                }
            }
        }

        if (self.full) {
            if (self.bar_row) |br| self.drawBar(br);
        }

        // Cursor: the focused pane's, moved to its place.
        const fp = self.focused();
        if (fp.visible) {
            const cmp = fp.composed;
            out.cursor_visible = cmp.cursor_visible and cmp.cursor_row < fp.rect.h and cmp.cursor_col < fp.rect.w;
            out.cursor_row = fp.rect.y + @min(cmp.cursor_row, fp.rect.h -| 1);
            out.cursor_col = fp.rect.x + @min(cmp.cursor_col, fp.rect.w -| 1);
            // The scrollbar is drawn at the window's right edge.
            if (cmp.scrollbar) |sb| if (fp.rect.x + fp.rect.w == cols) {
                const total: f32 = @floatFromInt(rows);
                const ph: f32 = @floatFromInt(fp.rect.h);
                const py: f32 = @floatFromInt(fp.rect.y);
                out.scrollbar = .{ .top = (py + sb.top * ph) / total, .height = sb.height * ph / total };
            };
        }
        if (self.confirm) |cf| {
            self.drawConfirm(&cf);
            if (out.cursor_row == self.area.y + self.area.h - 1) out.cursor_visible = false;
        }
        if (self.rename != null) out.cursor_visible = false;

        if (chrome) |ch| {
            const first: usize = if (self.bar_row) |br| (if (br == 0) 1 else 0) else 0;
            if (ch.hasOverlays()) {
                // Overlays change cells under them: recompose next time.
                if (ch.drawOverlays(self.cells.items, self.marks.items, rows, cols, first)) out.cursor_visible = false;
                if (out.cursor_row < first + ch.toasts.items.len and out.cursor_col + 30 >= cols) out.cursor_visible = false;
                self.full = true;
                for (self.panes.items) |p| p.dirty = true;
            }
            if (self.status_rows > 0 and rows > self.status_rows) {
                const sr = rows - 1;
                ch.drawStatus(self.cells.items[@as(usize, sr) * cols ..][0..cols]);
                @memset(self.marks.items[@as(usize, sr) * cols ..][0..cols], .none);
            }
        }
        if (self.confirm == null and (chrome == null or !chrome.?.hasOverlays())) self.full = false;
        return out;
    }

    fn drawConfirm(self: *Workspace, cf: *const Confirm) void {
        const row = self.area.y + self.area.h -| 1;
        const cells = self.cells.items[@as(usize, row) * self.cols ..][0..self.cols];
        @memset(self.marks.items[@as(usize, row) * self.cols ..][0..self.cols], .none);
        var buf: [256]u8 = undefined;
        const what = switch (cf.what) {
            .pane => "this pane",
            .tab => "this tab",
            .window => "the window",
        };
        const text = std.fmt.bufPrint(&buf, " Close {s}? {s} is still running.  [y/Enter] close  [n/Esc] cancel", .{ what, cf.programName() }) catch " Close? [y/n]";
        fillText(cells, text, 0xFFFFFF, 0xAF1F1F, false);
        self.full = true;
    }

    fn drawBar(self: *Workspace, row: u16) void {
        const cols = self.cols;
        const pal = self.opts.palette;
        const cells = self.cells.items[@as(usize, row) * cols ..][0..cols];
        @memset(self.marks.items[@as(usize, row) * cols ..][0..cols], .none);
        const bar_bg = blend(pal.bg, pal.fg, 0.10);
        const dim_fg = blend(pal.bg, pal.fg, 0.60);
        const accent = accentColor(pal);
        var base = Cell.init();
        base.bg_color = bar_bg;
        base.fg_color = dim_fg;
        @memset(cells, base);

        const n = self.tabs.tabs.items.len;
        var want: [tabs_mod.Bar.max_slots]u16 = undefined;
        var lb: [tabs_mod.Bar.max_slots][160]u8 = undefined;
        var labels: [tabs_mod.Bar.max_slots][]const u8 = undefined;
        for (self.tabs.tabs.items[0..@min(n, tabs_mod.Bar.max_slots)], 0..) |tab, i| {
            const editing = if (self.rename) |r| r.tab == tab.id else false;
            const label = if (editing) self.rename.?.text.items else self.tabLabel(tab);
            const dir = if (editing) "" else self.tabDir(tab, label);
            labels[i] = std.fmt.bufPrint(&lb[i], "{d} {s}{s}{s}", .{ i + 1, label, if (dir.len > 0) " · " else "", dir }) catch label;
            // number + label + markers + close.
            want[i] = @intCast(@min(textCols(labels[i]) + 4, 200));
        }
        self.bar = tabs_mod.layoutBar(want[0..@min(n, tabs_mod.Bar.max_slots)], self.tabs.active, cols);
        for (self.bar.slots[0..self.bar.n], 0..) |slot, si| {
            const ti = self.bar.first + si;
            const tab = self.tabs.tabs.items[ti];
            const active = ti == self.tabs.active;
            const editing = if (self.rename) |r| r.tab == tab.id else false;
            const st = self.tabState(tab);
            const seg = cells[slot.x..][0..slot.w];
            const fg = if (active) pal.fg else dim_fg;
            const bg = if (editing) blend(pal.bg, accent, 0.35) else if (active) pal.bg else bar_bg;
            var c = base;
            c.bg_color = bg;
            c.fg_color = fg;
            @memset(seg, c);
            if (active) {
                // Accent edge on the active tab.
                seg[0].char = '▎';
                seg[0].fg_color = accent;
            }
            // Status marker before the close button.
            const marker_x: usize = slot.w -| 4;
            const text_w = marker_x -| 1;
            if (text_w > 0) {
                fillText(seg[1..][0..text_w], labels[si], fg, bg, active);
                if (editing and textCols(labels[si]) + 1 < text_w) seg[1 + textCols(labels[si])].char = '▏';
            }
            if (marker_x < slot.w) {
                const m = &seg[marker_x];
                if (st.bell) {
                    m.char = '!';
                    m.fg_color = 0xFFD75F;
                    m.bold = true;
                } else if (st.failed) {
                    m.char = '✗';
                    m.fg_color = 0xFF5F5F;
                } else if (st.running and !active) {
                    m.char = '…';
                    m.fg_color = dim_fg;
                } else if (st.activity and !active) {
                    m.char = '●';
                    m.fg_color = accent;
                }
            }
            const cx = slot.close_x - slot.x;
            if (cx < slot.w) {
                seg[cx].char = '×';
                seg[cx].fg_color = dim_fg;
            }
            // Separator.
            if (!active and slot.w > 0) {
                seg[slot.w - 1].char = '│';
                seg[slot.w - 1].fg_color = blend(pal.bg, pal.fg, 0.25);
            }
        }
        if (self.bar.plus_x) |px| {
            if (px + 1 < cols) {
                cells[px + 1].char = '+';
                cells[px + 1].fg_color = dim_fg;
            }
        }
    }

    // --------------------------------------------------------------- mouse

    pub fn hitTest(self: *Workspace, col: u16, row: u16) Hit {
        if (self.status_rows > 0 and row >= self.rows - self.status_rows) return .status;
        if (self.bar_row) |br| if (row == br) return .{ .bar = self.bar.hit(col) };
        const tab = self.currentTab();
        if (!tab.zoomed) if (tab.layout.dividerAt(col, row)) |d| return .{ .divider = d };
        for (self.panes.items) |p| if (p.visible and p.rect.contains(col, row)) return .{ .pane = p };
        return .none;
    }

    /// Double-click detection on the tab bar.
    pub fn barClick(self: *Workspace, tab_id: tabs_mod.TabId, now_ms: i64, multi_ms: i64) bool {
        const double = self.last_bar_click_tab != null and self.last_bar_click_tab.? == tab_id and now_ms - self.last_bar_click_ms <= multi_ms;
        self.last_bar_click_tab = if (double) null else tab_id;
        self.last_bar_click_ms = now_ms;
        return double;
    }

    /// Tab under column `col` of the bar while dragging (for reordering).
    pub fn barSlotAt(self: *const Workspace, col: u16) ?usize {
        if (self.bar.n == 0) return null;
        for (self.bar.slots[0..self.bar.n], 0..) |s, i| if (col >= s.x and col < s.x + s.w) return self.bar.first + i;
        const last = self.bar.slots[self.bar.n - 1];
        if (col >= last.x + last.w) return self.bar.first + self.bar.n - 1;
        return self.bar.first;
    }

    /// Mouse event `m` translated into `p`'s own coordinates.
    pub fn localMouse(p: *const Pane, m: events.MouseInput, cell_w: u32, cell_h: u32) events.MouseInput {
        var l = m;
        l.x -= @as(i32, p.rect.x) * @as(i32, @intCast(cell_w));
        l.y -= @as(i32, p.rect.y) * @as(i32, @intCast(cell_h));
        return l;
    }

    // -------------------------------------------------------------- plugins

    /// Snapshot of the tabs for dt.tabs.list().
    pub fn tabInfos(self: *const Workspace, a: std.mem.Allocator) ![]plugin_bridge.host_mod.TabInfo {
        const out = try a.alloc(plugin_bridge.host_mod.TabInfo, self.tabs.tabs.items.len);
        for (self.tabs.tabs.items, 0..) |tab, i| {
            var ids = std.ArrayList(PaneId).init(a);
            try tab.layout.panes(&ids);
            out[i] = .{
                .id = tab.id,
                .title = self.tabLabel(tab),
                .active = i == self.tabs.active,
                .panes = ids.items,
                .focused_pane = tab.focused,
            };
        }
        return out;
    }
};

// ------------------------------------------------------------------ helpers

fn deleteLast(buf: *std.ArrayListUnmanaged(u8)) void {
    if (buf.items.len == 0) return;
    var i = buf.items.len - 1;
    while (i > 0 and buf.items[i] & 0xC0 == 0x80) i -= 1;
    buf.shrinkRetainingCapacity(i);
}

fn textCols(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

/// Write `text` into `cells` (cut to fit, rest padded with `bg`).
fn fillText(cells: []Cell, text: []const u8, fg: u32, bg: u32, bold: bool) void {
    var c = Cell.init();
    c.fg_color = fg;
    c.bg_color = bg;
    c.bold = bold;
    @memset(cells, c);
    var it = (std.unicode.Utf8View.init(text) catch std.unicode.Utf8View.initUnchecked("?")).iterator();
    var i: usize = 0;
    while (it.nextCodepoint()) |cp| : (i += 1) {
        if (i >= cells.len) break;
        if (i == cells.len - 1 and it.i < text.len) {
            cells[i].char = '…';
            break;
        }
        cells[i].char = if (cp < 0x20) ' ' else cp;
    }
}

pub fn blend(a: u32, b: u32, t: f32) u32 {
    var out: u32 = 0;
    inline for (.{ 16, 8, 0 }) |sh| {
        const x: f32 = @floatFromInt((a >> sh) & 0xFF);
        const y: f32 = @floatFromInt((b >> sh) & 0xFF);
        const v: u32 = @intFromFloat(std.math.clamp(x + (y - x) * t, 0, 255));
        out |= v << sh;
    }
    return out;
}

fn accentColor(pal: *const color.Palette) u32 {
    if (pal.cursor != color.none and pal.cursor & color.tag_mask == 0) return pal.cursor;
    return pal.colors[4] & 0xFFFFFF;
}

/// Fade a cell's text towards its background by `t`.
pub fn dimCell(c: *Cell, pal: *const color.Palette, t: f32) void {
    var fg = pal.resolve(c.fg_color);
    var bg = pal.resolve(c.bg_color);
    if (fg == color.none) fg = pal.fg;
    if (bg == color.none) bg = pal.bg;
    if (c.inverse) {
        c.bg_color = blend(fg, bg, t);
    } else c.fg_color = blend(fg, bg, t);
}

/// Whether divider `d` borders rect `r`.
fn touches(d: layout.Divider, r: Rect) bool {
    if (r.empty()) return false;
    if (d.dir == .right) {
        const adj = d.rect.x == r.x + r.w or d.rect.x + 1 == r.x;
        return adj and d.rect.y < r.y + r.h and r.y < d.rect.y + d.rect.h;
    }
    const adj = d.rect.y == r.y + r.h or d.rect.y + 1 == r.y;
    return adj and d.rect.x < r.x + r.w and r.x < d.rect.x + d.rect.w;
}

// -------------------------------------------------------------------- tests

const tt = std.testing;

fn testPane(ws: *Workspace) !*Pane {
    const term = try tt.allocator.create(Terminal);
    term.* = try Terminal.initBuffer(tt.allocator, 24, 80, 100);
    const p = try Pane.create(tt.allocator, ws.tabs.newPaneId(), term, true, "", .{}, .{ .enabled = false });
    try ws.addPane(p);
    return p;
}

test "workspace: tabs and splits size their terminals" {
    var ws = Workspace.init(tt.allocator);
    defer ws.deinit();
    const p1 = try testPane(&ws);
    _ = try ws.newTab(p1);
    _ = ws.setGrid(80, 24, 0);
    // One tab, auto bar: no bar, the pane gets the whole grid.
    try tt.expect(ws.bar_row == null);
    try tt.expectEqual(@as(u16, 24), p1.term.rows);
    const p2 = try testPane(&ws);
    try ws.splitFocused(.right, p2, 0.5);
    _ = ws.relayout();
    try tt.expectEqual(@as(u16, 24), p2.term.rows);
    try tt.expectEqual(@as(u16, 79), p1.term.cols + p2.term.cols);
    try tt.expectEqual(p2.id, ws.focused().id);
    // A second tab brings the bar (top row) and shrinks every pane.
    const p3 = try testPane(&ws);
    _ = try ws.newTab(p3);
    _ = ws.relayout();
    try tt.expectEqual(@as(?u16, 0), ws.bar_row);
    try tt.expectEqual(@as(u16, 23), p3.term.rows);
    try tt.expectEqual(@as(u16, 23), p1.term.rows);
    try tt.expect(p3.visible and !p1.visible and !p2.visible);
    // Focusing a pane in the other tab switches tabs.
    try tt.expect(ws.focusPane(p1.id));
    try tt.expectEqual(@as(usize, 0), ws.tabs.active);
    try tt.expect(p1.visible and p2.visible and !p3.visible);
    try tt.expect(ws.focusDirection(.right));
    try tt.expectEqual(p2.id, ws.focused().id);
    // Zoom gives the focused pane the whole area.
    try tt.expect(ws.toggleZoom());
    try tt.expectEqual(@as(u16, 80), p2.term.cols);
    try tt.expect(!p1.visible);
    try tt.expect(ws.toggleZoom());
    try tt.expect(p1.visible);
    // Keyboard resize moves the divider.
    const before = p2.term.cols;
    try tt.expect(ws.resizeFocused(.left, 5));
    try tt.expectEqual(before + 5, p2.term.cols);
    try tt.expect(ws.equalize());
    try tt.expect(@as(i32, p1.term.cols) - @as(i32, p2.term.cols) <= 1);
    // Closing p2 gives p1 the tab back.
    try tt.expectEqual(@as(?usize, null), ws.detachPane(p2.id));
    ws.destroyPane(p2);
    _ = ws.relayout();
    try tt.expectEqual(@as(u16, 80), p1.term.cols);
    // Closing the only pane of tab 2 removes the tab (and the auto bar).
    try tt.expectEqual(@as(?usize, 1), ws.detachPane(p3.id));
    ws.destroyPane(p3);
    _ = ws.relayout();
    try tt.expect(ws.bar_row == null);
    try tt.expectEqual(@as(u16, 24), p1.term.rows);
}

test "workspace: compose blits panes, dividers, tab bar and dims" {
    var ws = Workspace.init(tt.allocator);
    defer ws.deinit();
    ws.opts.bar = .top;
    ws.opts.dim = 0.5;
    const p1 = try testPane(&ws);
    _ = try ws.newTab(p1);
    _ = ws.setGrid(21, 6, 0);
    const p2 = try testPane(&ws);
    try ws.splitFocused(.right, p2, 0.5);
    _ = ws.relayout();
    try p1.term.processOutput("left");
    try p2.term.processOutput("right");
    try p2.term.processOutput("\x1b]2;my title\x07");
    const out = try ws.compose(null);
    const row1 = ws.cells.items[21..42];
    try tt.expectEqual(@as(u21, 'l'), row1[0].char);
    try tt.expectEqual(@as(u21, '│'), row1[p1.rect.w].char);
    try tt.expectEqual(@as(u21, 'r'), row1[p2.rect.x].char);
    // p1 is not focused: its text is faded to an RGB colour.
    try tt.expect(row1[0].fg_color & color.tag_mask == 0);
    try tt.expect(row1[p2.rect.x].fg_color & color.tag_mask != 0);
    // Cursor sits after "right" in p2.
    try tt.expectEqual(@as(u16, 1), out.cursor_row);
    try tt.expectEqual(p2.rect.x + 5, out.cursor_col);
    // The bar shows the focused pane's title.
    var bar_text: [64]u8 = undefined;
    var n: usize = 0;
    for (ws.cells.items[0..21]) |c| {
        n += std.unicode.utf8Encode(if (c.char == 0) ' ' else c.char, bar_text[n..]) catch 0;
    }
    try tt.expect(std.mem.indexOf(u8, bar_text[0..n], "1 my title") != null);
    // Hit tests.
    try tt.expect(ws.hitTest(p1.rect.w, 2) == .divider);
    try tt.expect(ws.hitTest(0, 2).pane == p1);
    try tt.expect(ws.hitTest(3, 0) == .bar);
}

test "workspace: rename edits the label" {
    var ws = Workspace.init(tt.allocator);
    defer ws.deinit();
    const p1 = try testPane(&ws);
    const tab = try ws.newTab(p1);
    _ = ws.setGrid(40, 5, 0);
    try ws.startRename(tab.id);
    _ = try ws.renameText("\x15");
    _ = try ws.renameText("build");
    _ = try ws.renameKey(.backspace);
    _ = try ws.renameText("s");
    _ = try ws.renameText("\r");
    try tt.expectEqualStrings("buils", tab.name.?);
    try tt.expect(ws.rename == null);
    try ws.startRename(tab.id);
    _ = try ws.renameText("zzz");
    _ = try ws.renameKey(.escape);
    try tt.expectEqualStrings("buils", ws.tabLabel(tab));
}

test "dimCell blends towards the background" {
    var c = Cell.init();
    c.fg_color = 0xFFFFFF;
    c.bg_color = 0x000000;
    dimCell(&c, &color.default_palette, 0.5);
    try tt.expectEqual(@as(u32, 0x7F7F7F), c.fg_color);
}

test "dim: indexed colours in an unfocused right pane" {
    var ws = Workspace.init(tt.allocator);
    defer ws.deinit();
    ws.opts.dim = 0.5;
    const p1 = try testPane(&ws);
    _ = try ws.newTab(p1);
    _ = ws.setGrid(21, 6, 0);
    const p2 = try testPane(&ws);
    try ws.splitFocused(.right, p2, 0.5);
    _ = ws.relayout();
    _ = ws.focusPane(p1.id);
    try p2.term.processOutput("\x1b[31mred");
    _ = try ws.compose(null);
    const c = ws.cells.items[p2.rect.x];
    try tt.expectEqual(@as(u21, 'r'), c.char);
    try tt.expect(c.fg_color & color.tag_mask == 0);
    p2.dirty = true;
    try p2.term.processOutput("x");
    _ = try ws.compose(null);
    try tt.expect(ws.cells.items[p2.rect.x].fg_color & color.tag_mask == 0);
}
