//! Connects the plugin host (src/plugins/host.zig) to a terminal window:
//! loads the plan from config, turns terminal changes into hook events
//! (commands, output lines, cwd, title, bell, SSH) and exposes the host's
//! timers / jobs to the event loop. The loop applies `host.effects`.

const std = @import("std");
const terminal = @import("../terminal/terminal.zig");
const si = terminal.shell_integration;
const input = @import("../terminal/input.zig");
const config = @import("../config/config.zig");
const events = @import("../platform/events.zig");
pub const host_mod = @import("../plugins/host.zig");
const registry = @import("../plugins/registry.zig");
const value = @import("../plugins/value.zig");
const ai_controller = @import("ai_controller.zig");

pub const Host = host_mod.Host;
const Entry = value.Entry;
const V = value.Value;

pub const version = "0.11.0";

/// What one pane (terminal) looked like at its last `afterOutput`.
pub const Track = struct {
    term: *terminal.Terminal,
    pane: u32 = 1,
    tab: u32 = 1,
    seen_started: u64 = 0,
    seen_finished: u64 = 0,
    seen_bells: u32 = 0,
    cmd_start_ms: i64 = 0,
    cmd_running: bool = false,
    /// Absolute line of the cursor row last time (lines above it are done).
    line_mark: i64 = 0,
    line_gen: u32 = 0,
    cwd: std.ArrayListUnmanaged(u8) = .{},
    title: std.ArrayListUnmanaged(u8) = .{},
    ssh: std.ArrayListUnmanaged(u8) = .{},

    pub fn deinit(self: *Track, a: std.mem.Allocator) void {
        self.cwd.deinit(a);
        self.title.deinit(a);
        self.ssh.deinit(a);
    }

    fn sync(self: *Track) void {
        self.seen_started = self.term.shell.started;
        self.seen_finished = self.term.shell.finished;
        self.seen_bells = self.term.bell_count;
        const m = self.term.cursorMark();
        self.line_mark = m.line;
        self.line_gen = m.gen;
        self.term.ssh_events.clearRetainingCapacity();
    }
};

pub const Bridge = struct {
    a: std.mem.Allocator,
    /// The focused pane: what dt.term / dt.screen read.
    cur: *Track,
    /// Every pane in the window.
    tracks: std.ArrayListUnmanaged(*Track) = .{},
    host: ?*Host = null,
    /// Plan hash of the running host (reload restarts it when it changes).
    hash: u64 = 0,
    scratch: std.ArrayList(u8),

    pub fn init(a: std.mem.Allocator, first: *Track) Bridge {
        var b = Bridge{ .a = a, .cur = first, .scratch = std.ArrayList(u8).init(a) };
        b.tracks.append(a, first) catch {};
        return b;
    }

    pub fn deinit(self: *Bridge) void {
        self.stop();
        self.tracks.deinit(self.a);
        self.scratch.deinit();
    }

    /// A new pane (its counters start now).
    pub fn addTrack(self: *Bridge, tr: *Track) void {
        tr.sync();
        self.tracks.append(self.a, tr) catch {};
    }

    /// A pane is going away (`cur` must be moved first).
    pub fn removeTrack(self: *Bridge, tr: *Track) void {
        for (self.tracks.items, 0..) |x, i| if (x == tr) {
            _ = self.tracks.swapRemove(i);
            break;
        };
    }

    /// The focus moved to another pane.
    pub fn setFocus(self: *Bridge, tr: *Track) void {
        self.cur = tr;
        const h = self.host orelse return;
        h.info.rows = tr.term.rows;
        h.info.cols = tr.term.cols;
        h.info.pane = tr.pane;
        h.info.tab = tr.tab;
        h.setInfo(.cwd, tr.cwd.items);
        h.setInfo(.title, tr.term.title);
        h.setInfo(.ssh, tr.ssh.items);
    }

    /// (Re)load the plugins `cfg` asks for. Returns false when none run.
    pub fn start(self: *Bridge, cfg: *const config.Config, taken: *const fn (events.Chord) bool) void {
        self.stop();
        if (!cfg.plugins_enabled) return;
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        const p = registry.plan(arena.allocator(), cfg.plugins_dir, cfg.plugins.items) catch |err| {
            std.debug.print("plugins: {s}\n", .{@errorName(err)});
            return;
        };
        self.hash = p.hash;
        if (p.specs.len == 0) return;
        const h = Host.init(self.a, .{ .ctx = self, .screenText = screenText, .cursor = cursor }, .{
            .log_path = p.paths.log_file,
            .data_root = p.paths.data_root,
            .version = version,
        }) catch |err| {
            std.debug.print("plugins: {s}\n", .{@errorName(err)});
            return;
        };
        h.taken = taken;
        h.setInfo(.theme, cfg.theme);
        self.host = h;
        self.setFocus(self.cur);
        for (self.tracks.items) |tr| tr.sync();
        h.start(p.specs) catch |err| std.debug.print("plugins: {s}\n", .{@errorName(err)});
        var running: usize = 0;
        for (h.plugins.items) |pl| running += @intFromBool(pl.running());
        std.debug.print("  → Plugins: {d}/{d} loaded ({s})\n", .{ running, p.specs.len, p.paths.plugins_dir });
    }

    pub fn stop(self: *Bridge) void {
        if (self.host) |h| h.deinit();
        self.host = null;
    }

    /// Config reloaded: restart the host if its plan changed, else tell
    /// the plugins. Returns true when it restarted.
    pub fn reload(self: *Bridge, cfg: *const config.Config, taken: *const fn (events.Chord) bool) bool {
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        const want: ?u64 = if (!cfg.plugins_enabled) null else if (registry.plan(arena.allocator(), cfg.plugins_dir, cfg.plugins.items)) |p| p.hash else |_| null;
        const running = self.host != null or self.hash != 0;
        if (want == null) {
            if (running) {
                self.stop();
                self.hash = 0;
                return true;
            }
            return false;
        }
        if (want.? != self.hash or !running) {
            self.start(cfg, taken);
            return true;
        }
        if (self.host) |h| {
            h.setInfo(.theme, cfg.theme);
            h.emit(.config_reload, null);
        }
        return false;
    }

    // ---------------------------------------------------------- app view

    fn screenText(ctx: *anyopaque, out: *std.ArrayList(u8), scrollback: u32) void {
        const self: *Bridge = @ptrCast(@alignCast(ctx));
        const t = self.cur.term;
        const first = @max(t.historyTop(), t.screenTop() - @as(i64, scrollback));
        var line = first;
        while (line < t.screenTop() + t.rows) : (line += 1) {
            const cells = t.lineAt(line) orelse continue;
            const s0 = out.items.len;
            terminal.appendRowText(cells, out.writer()) catch return;
            // Trim the blank tail.
            while (out.items.len > s0 and (out.items[out.items.len - 1] == ' ' or out.items[out.items.len - 1] == 0)) out.items.len -= 1;
            out.append('\n') catch return;
        }
    }

    fn cursor(ctx: *anyopaque) [2]u32 {
        const self: *Bridge = @ptrCast(@alignCast(ctx));
        return .{ self.cur.term.cursor_row, self.cur.term.cursor_col };
    }

    // ------------------------------------------------------------ events

    /// After `tr`'s PTY output was parsed: fire whatever changed.
    pub fn afterOutput(self: *Bridge, tr: *Track, now_ms: i64) void {
        const h = self.host orelse {
            tr.sync();
            return;
        };
        const t = tr.term;
        const focused = tr == self.cur;
        const pane: Entry = .{ .key = "pane", .value = .{ .integer = tr.pane } };
        const tab: Entry = .{ .key = "tab", .value = .{ .integer = tr.tab } };
        // Commands (OSC 133 C / D).
        if (t.shell.started != tr.seen_started) {
            tr.seen_started = t.shell.started;
            tr.cmd_start_ms = now_ms;
            tr.cmd_running = true;
            if (h.wants(.command_start)) {
                const cmd = t.shell.pending orelse "";
                h.emitWithPrivate(.command_start, &.{
                    .{ .key = "cwd", .value = .{ .string = tr.cwd.items } },
                    pane,
                    tab,
                }, &.{.{ .key = "command", .value = .{ .string = cmd } }});
            }
        }
        if (t.shell.finished != tr.seen_finished) {
            tr.seen_finished = t.shell.finished;
            const dur: i64 = if (tr.cmd_running) now_ms - tr.cmd_start_ms else 0;
            tr.cmd_running = false;
            if (h.wants(.command_finish)) {
                const last = t.shell.lastCommand();
                const code: V = if (last) |c| (if (c.exit_code) |e| V{ .integer = e } else V{ .boolean = false }) else V{ .boolean = false };
                h.emitWithPrivate(.command_finish, &.{
                    .{ .key = "exit_code", .value = code },
                    .{ .key = "duration_ms", .value = .{ .integer = dur } },
                    .{ .key = "cwd", .value = .{ .string = tr.cwd.items } },
                    // Window focused and this pane the focused one.
                    .{ .key = "focused", .value = .{ .boolean = h.info.focused and focused } },
                    pane,
                    tab,
                }, &.{.{ .key = "command", .value = .{ .string = if (last) |c| c.text else "" } }});
            }
        }
        // Working directory (OSC 7).
        var cb: [4096]u8 = undefined;
        if (si.cwdFromUri(t.cwd_uri, &cb)) |dir| if (!std.mem.eql(u8, dir, tr.cwd.items)) {
            tr.cwd.clearRetainingCapacity();
            tr.cwd.appendSlice(self.a, dir) catch {};
            if (focused) h.setInfo(.cwd, dir);
            h.emit(.cwd, .{ .map = &.{ .{ .key = "cwd", .value = .{ .string = dir } }, pane, tab } });
        };
        // Title.
        if (!std.mem.eql(u8, t.title, tr.title.items)) {
            tr.title.clearRetainingCapacity();
            tr.title.appendSlice(self.a, t.title) catch {};
            if (focused) h.setInfo(.title, t.title);
            h.emit(.title, .{ .map = &.{ .{ .key = "title", .value = .{ .string = t.title } }, pane, tab } });
        }
        // Bell.
        if (t.bell_count != tr.seen_bells) {
            tr.seen_bells = t.bell_count;
            h.emit(.bell, .{ .map = &.{ pane, tab } });
        }
        // SSH session reports (OSC 7799, verified by the terminal).
        for (t.ssh_events.items) |ev| {
            const target = ev.target();
            tr.ssh.clearRetainingCapacity();
            if (ev.kind == .connect) tr.ssh.appendSlice(self.a, target) catch {};
            if (focused) h.setInfo(.ssh, tr.ssh.items);
            h.emit(if (ev.kind == .connect) .ssh_connect else .ssh_disconnect, .{ .map = &.{ .{ .key = "target", .value = .{ .string = target } }, pane, tab } });
        }
        t.ssh_events.clearRetainingCapacity();
        self.outputLines(tr);
    }

    /// Rows that the cursor left since last time (main screen only).
    fn outputLines(self: *Bridge, tr: *Track) void {
        const h = self.host.?;
        const t = tr.term;
        const m = t.cursorMark();
        defer {
            tr.line_mark = m.line;
            tr.line_gen = m.gen;
        }
        if (t.alt_active or m.gen != tr.line_gen or m.line <= tr.line_mark) return;
        if (!h.wants(.output_line)) return;
        const first = @max(tr.line_mark, m.line - host_mod.Limits.output_lines_per_batch, t.historyTop());
        self.scratch.clearRetainingCapacity();
        var spans: [host_mod.Limits.output_lines_per_batch][2]usize = undefined;
        var n: usize = 0;
        var line = first;
        while (line < m.line and n < spans.len) : (line += 1) {
            const cells = t.lineAt(line) orelse continue;
            const s0 = self.scratch.items.len;
            terminal.appendRowText(cells, self.scratch.writer()) catch return;
            while (self.scratch.items.len > s0 and (self.scratch.items[self.scratch.items.len - 1] == ' ' or self.scratch.items[self.scratch.items.len - 1] == 0)) self.scratch.items.len -= 1;
            spans[n] = .{ s0, self.scratch.items.len };
            n += 1;
        }
        var slices: [host_mod.Limits.output_lines_per_batch][]const u8 = undefined;
        for (spans[0..n], 0..) |sp, i| slices[i] = self.scratch.items[sp[0]..sp[1]];
        h.outputLines(slices[0..n]);
    }

    pub fn focus(self: *Bridge, f: bool) void {
        const h = self.host orelse return;
        h.info.focused = f;
        h.emit(.focus, .{ .map = &.{.{ .key = "focused", .value = .{ .boolean = f } }} });
    }

    pub fn resized(self: *Bridge) void {
        const h = self.host orelse return;
        h.info.rows = self.cur.term.rows;
        h.info.cols = self.cur.term.cols;
    }

    /// A key from a `.key` event; true = a plugin consumed it.
    pub fn key(self: *Bridge, k: input.Key, mods: input.Mods) bool {
        const h = self.host orelse return false;
        if (!h.wants(.key)) return false;
        return h.key(keyPayload(@tagName(k), "", mods));
    }

    /// Typed bytes from an `.input` event; true = consumed.
    pub fn text(self: *Bridge, bytes: []const u8) bool {
        const h = self.host orelse return false;
        if (!h.wants(.key) or bytes.len == 0) return false;
        var kb: [8]u8 = undefined;
        var mods = input.Mods{};
        var name: []const u8 = bytes;
        var shown: []const u8 = bytes;
        var rest = bytes;
        if (rest.len == 2 and rest[0] == 0x1b) {
            mods.alt = true;
            rest = rest[1..];
            name = rest;
            shown = "";
        }
        if (rest.len == 1) {
            const b = rest[0];
            switch (b) {
                '\r', '\n' => name = "enter",
                '\t' => name = "tab",
                0x1b => name = "escape",
                0x7f, 0x08 => name = "backspace",
                1...7, 0x0b, 0x0c, 0x0e...0x1a => {
                    mods.ctrl = true;
                    kb[0] = b - 1 + 'a';
                    name = kb[0..1];
                },
                'A'...'Z' => {
                    mods.shift = true;
                    kb[0] = std.ascii.toLower(b);
                    name = kb[0..1];
                },
                else => {},
            }
            if (b < 0x20 or b == 0x7f) shown = "";
        } else if (rest.len > 8) return false; // a paste-like burst, not a key
        return h.key(keyPayload(name, shown, mods));
    }

    // -------------------------------------------------------- AI filter

    pub fn aiFilter(self: *Bridge) ai_controller.Controller.Filter {
        return .{ .ctx = self, .run = filterRun, .active = filterActive };
    }

    fn filterActive(ctx: *anyopaque) bool {
        const self: *Bridge = @ptrCast(@alignCast(ctx));
        const h = self.host orelse return false;
        return h.wants(.ai_suggestion);
    }

    fn filterRun(ctx: *anyopaque, txt: []const u8, typed: []const u8) ai_controller.Controller.FilterResult {
        const self: *Bridge = @ptrCast(@alignCast(ctx));
        const h = self.host orelse return .keep;
        return switch (h.filterSuggestion(txt, typed)) {
            .keep => .keep,
            .drop => .drop,
            // Both use the general-purpose allocator handed to init.
            .replace => |s| .{ .replace = s },
        };
    }

    // ------------------------------------------------------- scheduling

    pub fn wakeFd(self: *const Bridge) std.posix.fd_t {
        const h = self.host orelse return -1;
        return h.wakeFd();
    }

    pub fn timeout(self: *const Bridge, now_ms: i64) ?i64 {
        const h = self.host orelse return null;
        const d = h.nextDeadline(now_ms) orelse return null;
        return @max(d - now_ms, 0);
    }

    pub fn tick(self: *Bridge, now_ms: i64) void {
        const h = self.host orelse return;
        h.pollJobs();
        h.tick(now_ms);
    }
};

fn keyPayload(name: []const u8, typed: []const u8, mods: input.Mods) V {
    const S = struct {
        threadlocal var buf: [5]Entry = undefined;
    };
    S.buf = .{
        .{ .key = "key", .value = .{ .string = name } },
        .{ .key = "text", .value = .{ .string = typed } },
        .{ .key = "ctrl", .value = .{ .boolean = mods.ctrl } },
        .{ .key = "alt", .value = .{ .boolean = mods.alt } },
        .{ .key = "shift", .value = .{ .boolean = mods.shift } },
    };
    return .{ .map = &S.buf };
}
