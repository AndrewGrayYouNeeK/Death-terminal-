//! Front-end interaction state that sits between the window and the
//! terminal: scrollback viewport, mouse selection, clipboard, paste
//! safety prompt, search overlay, link opening and OSC 52 policy.
//!
//! It never talks to the window directly. Side effects (PTY writes,
//! clipboard reads/writes, opening URLs) are queued as `Effect`s that
//! the event loop executes, which keeps this file unit-testable.

const std = @import("std");
const terminal = @import("../terminal/terminal.zig");
const selection = @import("../terminal/selection.zig");
const search = @import("../terminal/search.zig");
const ask_ui = @import("ask_ui.zig");
pub const palette_mod = @import("palette.zig");
const urls = @import("../terminal/urls.zig");
const input = @import("../terminal/input.zig");
const events = @import("../platform/events.zig");
const frame = @import("../renderer/frame.zig");
const color = @import("../terminal/color.zig");

const Terminal = terminal.Terminal;
const Cell = terminal.Cell;
const Point = selection.Point;
const Selection = selection.Selection;
const Mark = frame.Mark;

pub const Osc52 = enum {
    off,
    write,
    read_write,

    pub fn parse(s: []const u8) ?Osc52 {
        if (std.mem.eql(u8, s, "off") or std.mem.eql(u8, s, "false")) return .off;
        if (std.mem.eql(u8, s, "write") or std.mem.eql(u8, s, "true")) return .write;
        if (std.mem.eql(u8, s, "read-write") or std.mem.eql(u8, s, "read_write") or std.mem.eql(u8, s, "rw")) return .read_write;
        return null;
    }
};

pub const Options = struct {
    /// Also put mouse selections on CLIPBOARD (PRIMARY is always set).
    copy_on_select: bool = false,
    /// Ask before sending a multi-line paste to an app without bracketed paste.
    paste_confirm: bool = true,
    osc52: Osc52 = .write,
    scrollbar: bool = true,
    scroll_lines: u16 = 3,
    word_chars: []const u8 = selection.default_word_chars,
    multi_click_ms: i64 = 400,
};

pub const Effect = union(enum) {
    /// Bytes for the PTY (owned).
    write: []u8,
    set_clipboard: struct { target: events.ClipTarget, text: []u8 },
    request_paste: struct { target: events.ClipTarget, purpose: events.PastePurpose },
    /// Allowlisted URL to hand to the opener (owned).
    open_url: []u8,
    /// Something picked in the SSH (Ctrl+Shift+S) or command palette
    /// (Ctrl+Shift+P).
    palette: palette_mod.Pick,
};

pub const Composed = struct {
    /// Rows in `cells` (the grid, plus the status bar when shown).
    rows: u16 = 0,
    cursor_row: u16,
    cursor_col: u16,
    cursor_visible: bool,
    scrollbar: ?struct { top: f32, height: f32 } = null,
};

const SearchState = struct {
    query: std.ArrayList(u8),
    case_sensitive: bool = false,
    regex: bool = false,
    bad_regex: bool = false,
    matches: std.ArrayList(search.Match),
    current: ?usize = null,
    /// Screen top when the matches were computed: lines above it were
    /// history then and cannot have changed since.
    searched_to: i64 = 0,
};

/// Message bar at the top of the window (config errors, reload results).
pub const Notice = struct {
    /// `ai` = an "explain last error" answer (taller, blue).
    pub const Kind = enum { err, warning, info, ai };
    kind: Kind,
    /// Owned lines; the first is the headline.
    lines: std.ArrayList([]u8),
    /// Auto-dismiss time (ms timestamp), null = until Esc.
    expires_ms: ?i64 = null,

    pub const max_rows = 6;
    pub const max_ai_rows = 14;
};

/// A short message in the top-right corner (plugin notifications).
pub const Toast = struct {
    text: []u8,
    level: Level,
    expires_ms: i64,

    pub const max = 4;
    pub const Level = enum {
        info,
        warn,
        err,
        fn colors(self: Level) [2]u32 {
            return switch (self) {
                .info => .{ 0x5FAFFF, 0x26303A },
                .warn => .{ 0xFFD75F, 0x3A3420 },
                .err => .{ 0xFF5F5F, 0x3E2222 },
            };
        }
    };
};

pub const StatusPiece = struct { text: []u8, fg: ?u32 = null };

/// AI suggestion shown as dim "ghost" text after the cursor. Only drawn
/// while the cursor is still where it was when the suggestion arrived;
/// nothing reaches the shell unless the user accepts it.
pub const Ghost = struct {
    anchor: terminal.shell_integration.Mark,
    /// Suffixes to append to the typed input (owned).
    alternatives: std.ArrayList([]u8),
    index: usize = 0,
};

const Prompt = struct {
    /// Encoded bytes ready for the PTY.
    data: []u8,
    lines: usize,
};

pub const Ui = struct {
    allocator: std.mem.Allocator,
    opts: Options,
    /// Lines scrolled back from the live screen (0 = following output).
    scroll: usize = 0,
    sel: ?Selection = null,
    dragging: bool = false,
    click_count: u8 = 0,
    last_click_ms: i64 = 0,
    last_click: Point = .{ .line = std.math.minInt(i64), .col = 0 },
    search: ?SearchState = null,
    /// Ask the Output prompt (Ctrl+Shift+Q). See `ask_ui.zig`.
    ask: ask_ui.Bar = .{},
    prompt: ?Prompt = null,
    effects: std.ArrayList(Effect),
    last_total: u64 = 0,
    last_alt: bool = false,
    last_layout: u32 = 0,
    /// Hash of the selected text (lines >= sel_hash_from) when the user
    /// last changed the selection; output that changes it clears it.
    sel_hash: u64 = 0,
    sel_hash_from: i64 = 0,
    notice: ?Notice = null,
    ghost: ?Ghost = null,
    /// Short AI status tag for the top-right corner ("AI offline"), owned.
    ai_status: ?[]u8 = null,
    /// The SSH or command palette, while open (filled by the event loop).
    palette: ?palette_mod.Palette = null,
    /// Small messages stacked in the top-right corner (plugins).
    toasts: std.ArrayList(Toast) = undefined,
    /// The status bar: one row under the grid while shown. The event loop
    /// reserves the row (`statusRows`) and sets the text.
    status_visible: bool = false,
    status_left: std.ArrayListUnmanaged(StatusPiece) = .{},
    status_right: std.ArrayListUnmanaged(StatusPiece) = .{},

    pub fn init(allocator: std.mem.Allocator, opts: Options) Ui {
        return .{ .allocator = allocator, .opts = opts, .effects = std.ArrayList(Effect).init(allocator), .toasts = std.ArrayList(Toast).init(allocator) };
    }

    pub fn deinit(self: *Ui) void {
        self.closePalette();
        for (self.toasts.items) |t| self.allocator.free(t.text);
        self.toasts.deinit();
        self.clearStatus();
        self.status_left.deinit(self.allocator);
        self.status_right.deinit(self.allocator);
        self.closeSearch();
        self.ask.close();
        self.clearNotice();
        self.clearGhost();
        self.setAiStatus(null);
        if (self.prompt) |p| self.allocator.free(p.data);
        self.freeEffects(self.effects.items);
        self.effects.deinit();
    }

    /// Hand queued effects to the caller; release them with `freeEffects`.
    pub fn takeEffects(self: *Ui) ![]Effect {
        return self.effects.toOwnedSlice();
    }

    pub fn freeEffects(self: *Ui, list: []Effect) void {
        for (list) |e| switch (e) {
            .write => |b| self.allocator.free(b),
            .set_clipboard => |c| self.allocator.free(c.text),
            .open_url => |u| self.allocator.free(u),
            .request_paste => {},
            .palette => |pk| switch (pk) {
                .open => |o| self.allocator.free(o.name),
                else => {},
            },
        };
        if (list.ptr != self.effects.items.ptr) self.allocator.free(list);
    }

    fn pushWrite(self: *Ui, bytes: []const u8) !void {
        try self.effects.append(.{ .write = try self.allocator.dupe(u8, bytes) });
    }

    // ------------------------------------------------------------ viewport

    pub fn viewTop(self: *const Ui, term: *const Terminal) i64 {
        return term.screenTop() - @as(i64, @intCast(self.scroll)) + self.viewShift(term);
    }

    /// While the search/paste bar would cover a used last row of the live
    /// primary screen (typically the prompt), the view moves up one line so
    /// that row stays visible above the bar.
    ///
    /// Likewise, while the notice covers the top rows and there is room
    /// below the cursor, the view moves down so the prompt isn't hidden.
    fn viewShift(self: *const Ui, term: *const Terminal) i64 {
        if (self.scroll != 0 or term.alt_active or term.rows < 2) return 0;
        var shift: i64 = 0;
        if (self.overlayActive()) {
            const last = term.rows - 1;
            if (term.cursor_row == last) {
                shift = 1;
            } else for (term.screenRow(last)) |c| {
                if (c.char != 0 and c.char != ' ') {
                    shift = 1;
                    break;
                }
            }
        }
        const top = self.noticeRows(term.rows, term.cols);
        if (top > 0) {
            const bottom_bar: usize = @intFromBool(self.overlayActive());
            if (@as(usize, term.cursor_row) + top + bottom_bar < term.rows) shift -= @intCast(top);
        }
        return shift;
    }

    fn maxScroll(term: *const Terminal) usize {
        return if (term.alt_active) 0 else term.scrollback.len();
    }

    pub fn scrollBy(self: *Ui, term: *const Terminal, lines: i64) void {
        const cur: i64 = @intCast(self.scroll);
        const next = std.math.clamp(cur + lines, 0, @as(i64, @intCast(maxScroll(term))));
        self.scroll = @intCast(next);
    }

    /// Keep the view anchored to the same lines while output scrolls, and
    /// drop state that no longer applies. Call after feeding output.
    pub fn sync(self: *Ui, term: *const Terminal) void {
        if (term.layout_gen != self.last_layout) {
            // Resize reflowed the lines: absolute positions moved.
            self.last_layout = term.layout_gen;
            self.sel = null;
            self.dragging = false;
            self.scroll = 0;
            self.last_total = term.scrollback.total;
            self.last_alt = term.alt_active;
            self.refreshSearch(term, true) catch {};
            return;
        }
        const total = term.scrollback.total;
        if (self.scroll > 0 and total > self.last_total) {
            self.scroll += @intCast(total - self.last_total);
        }
        self.last_total = total;
        self.scroll = @min(self.scroll, maxScroll(term));
        if (term.alt_active != self.last_alt) {
            self.last_alt = term.alt_active;
            self.sel = null;
            self.dragging = false;
            if (self.search != null) self.recomputeSearch(term) catch {};
        } else if (self.search != null) {
            self.refreshSearch(term, false) catch {};
        }
        if (self.sel) |s| {
            if (s.ordered().start.line < term.historyTop() and s.ordered().end.line < term.historyTop()) {
                self.sel = null;
            } else if (!self.dragging and self.selHash(term, self.sel_hash_from) != self.sel_hash) {
                // The selected text was overwritten.
                self.sel = null;
            }
        }
    }

    fn selHash(self: *const Ui, term: *const Terminal, from: i64) u64 {
        const s = self.sel orelse return 0;
        if (!s.active) return 0;
        const range = s.resolve(term, self.opts.word_chars);
        var h = std.hash.Wyhash.init(0);
        var line = @max(range.start.line, from);
        while (line <= range.end.line) : (line += 1) {
            const cells = term.lineAt(line) orelse {
                h.update("\xff");
                continue;
            };
            var c: u16 = 0;
            while (c < term.cols) : (c += 1) {
                if (!s.containsResolved(range, line, c)) continue;
                const cell = if (c < cells.len) cells[c] else Cell.init();
                const ch: u32 = if (cell.char == 0) ' ' else cell.char;
                h.update(std.mem.asBytes(&ch));
                h.update(&[_]u8{cell.width});
            }
        }
        return h.final();
    }

    /// Remember the selected text after the user changed the selection.
    fn noteSelection(self: *Ui, term: *const Terminal) void {
        if (self.sel == null) return;
        self.sel_hash_from = term.screenTop();
        self.sel_hash = self.selHash(term, self.sel_hash_from);
    }

    /// The user typed something for the shell: return to the live screen.
    /// Returns whether the view moved.
    pub fn userTyped(self: *Ui) bool {
        const moved = self.scroll != 0;
        self.scroll = 0;
        return moved;
    }

    fn ensureVisible(self: *Ui, term: *const Terminal, line: i64) void {
        const top = self.viewTop(term);
        // The overlay bar covers the last row.
        const rows: i64 = @max(1, @as(i64, term.rows) - @intFromBool(self.overlayActive()));
        if (line >= top and line < top + rows) return;
        const want_top = line - @divTrunc(rows, 2);
        const s = std.math.clamp(term.screenTop() - want_top, 0, @as(i64, @intCast(maxScroll(term))));
        self.scroll = @intCast(s);
    }

    pub fn pointAt(self: *const Ui, term: *const Terminal, x: i32, y: i32, cell_w: u32, cell_h: u32) Point {
        const col = std.math.clamp(@divFloor(x, @as(i32, @intCast(cell_w))), 0, @as(i32, term.cols) - 1);
        const row = std.math.clamp(@divFloor(y, @as(i32, @intCast(cell_h))), 0, @as(i32, term.rows) - 1);
        return .{ .line = self.viewTop(term) + row, .col = @intCast(col) };
    }

    // ------------------------------------------------------------ mouse

    /// Returns false when the event belongs to the application (mouse
    /// reporting on and Shift not held) or to the caller's alternate-screen
    /// wheel handling.
    pub fn handleMouse(self: *Ui, term: *const Terminal, m: events.MouseInput, cell_w: u32, cell_h: u32, now_ms: i64) !bool {
        const used = try self.handleMouseInner(term, m, cell_w, cell_h, now_ms);
        if (used) self.noteSelection(term);
        return used;
    }

    fn handleMouseInner(self: *Ui, term: *const Terminal, m: events.MouseInput, cell_w: u32, cell_h: u32, now_ms: i64) !bool {
        const reporting = term.modes.mouse != .off;
        if (reporting and !m.mods.shift) return false;
        switch (m.button) {
            .wheel_up, .wheel_down => {
                if (m.action != .press) return true;
                if (term.alt_active) return false;
                const n: i64 = self.opts.scroll_lines;
                self.scrollBy(term, if (m.button == .wheel_up) n else -n);
                return true;
            },
            .wheel_left, .wheel_right => return true,
            else => {},
        }
        switch (m.action) {
            .press => switch (m.button) {
                .left => {
                    const p = self.pointAt(term, m.x, m.y, cell_w, cell_h);
                    // Ctrl+click opens links; Ctrl+Alt (or Alt, which many
                    // window managers grab for moving) selects a block.
                    if (m.mods.ctrl and !m.mods.alt) {
                        try self.openLinkAt(term, p);
                        return true;
                    }
                    if (m.mods.shift and !reporting) {
                        if (self.sel) |*s| {
                            s.extend(p);
                            self.dragging = true;
                            return true;
                        }
                    }
                    if (p.eql(self.last_click) and now_ms - self.last_click_ms <= self.opts.multi_click_ms) {
                        self.click_count = self.click_count % 3 + 1;
                    } else self.click_count = 1;
                    self.last_click = p;
                    self.last_click_ms = now_ms;
                    const mode: selection.Mode = switch (self.click_count) {
                        2 => .word,
                        3 => .line,
                        else => if (m.mods.alt) .block else .normal,
                    };
                    self.sel = Selection.begin(p, mode);
                    self.dragging = true;
                },
                .middle => try self.effects.append(.{ .request_paste = .{ .target = .primary, .purpose = .paste } }),
                else => {},
            },
            .motion => if (self.dragging) {
                // Drag past the top/bottom edge scrolls the viewport.
                const h: i32 = @intCast(cell_h * term.rows);
                if (m.y < 0) self.scrollBy(term, 1) else if (m.y >= h) self.scrollBy(term, -1);
                const p = self.pointAt(term, m.x, m.y, cell_w, cell_h);
                if (self.sel) |*s| s.update(p);
            },
            .release => if (m.button == .left and self.dragging) {
                self.dragging = false;
                if (self.sel) |s| {
                    if (s.active) try self.copySelection(term) else self.sel = null;
                }
            },
        }
        return true;
    }

    pub fn selectionText(self: *Ui, term: *const Terminal) !?[]u8 {
        const s = self.sel orelse return null;
        if (!s.active) return null;
        const t = try s.text(self.allocator, term, self.opts.word_chars);
        if (t.len == 0) {
            self.allocator.free(t);
            return null;
        }
        return t;
    }

    /// Finished mouse selection: PRIMARY always, CLIPBOARD too with
    /// copy-on-select.
    fn copySelection(self: *Ui, term: *const Terminal) !void {
        const t = (try self.selectionText(term)) orelse return;
        if (self.opts.copy_on_select) {
            try self.effects.append(.{ .set_clipboard = .{ .target = .clipboard, .text = try self.allocator.dupe(u8, t) } });
        }
        try self.effects.append(.{ .set_clipboard = .{ .target = .primary, .text = t } });
    }

    fn openLinkAt(self: *Ui, term: *const Terminal, p: Point) !void {
        const cells = term.lineAt(p.line) orelse return;
        if (p.col < cells.len) {
            var c = cells[p.col];
            if (c.isSpacer() and p.col > 0) c = cells[p.col - 1];
            if (term.linkTarget(c.link)) |target| {
                if (urls.allowedTarget(target)) try self.effects.append(.{ .open_url = try self.allocator.dupe(u8, target) });
                return;
            }
        }
        const found = (try urls.urlAt(self.allocator, term, p)) orelse return;
        if (urls.allowedTarget(found.url)) {
            try self.effects.append(.{ .open_url = found.url });
        } else self.allocator.free(found.url);
    }

    // ------------------------------------------------------------ actions

    /// Returns false when the action doesn't apply (the caller then
    /// forwards the key to the application).
    pub fn handleAction(self: *Ui, term: *const Terminal, a: events.Action) !bool {
        const rows: i64 = term.rows;
        switch (a) {
            .copy => {
                if (try self.selectionText(term)) |t| {
                    try self.effects.append(.{ .set_clipboard = .{ .target = .clipboard, .text = t } });
                }
            },
            .paste => try self.effects.append(.{ .request_paste = .{ .target = .clipboard, .purpose = .paste } }),
            .paste_selection => try self.effects.append(.{ .request_paste = .{ .target = .primary, .purpose = .paste } }),
            .search => try self.openSearch(term),
            .scroll_page_up, .scroll_page_down, .scroll_line_up, .scroll_line_down, .scroll_top, .scroll_bottom => {
                if (term.alt_active) return false;
                switch (a) {
                    .scroll_page_up => self.scrollBy(term, rows - 1),
                    .scroll_page_down => self.scrollBy(term, -(rows - 1)),
                    .scroll_line_up => self.scrollBy(term, 1),
                    .scroll_line_down => self.scrollBy(term, -1),
                    .scroll_top => self.scroll = maxScroll(term),
                    .scroll_bottom => self.scroll = 0,
                    else => unreachable,
                }
            },
            .select_all => {
                var s = Selection.begin(.{ .line = if (term.alt_active) term.screenTop() else term.historyTop(), .col = 0 }, .normal);
                s.update(.{ .line = term.screenTop() + rows - 1, .col = term.cols - 1 });
                self.sel = s;
                self.noteSelection(term);
                try self.copySelection(term);
            },
            .clear_selection => self.sel = null,
            .ai_accept => {
                if (!self.ghostVisible(term)) return false;
                try self.pushWrite(self.ghostText().?);
                self.clearGhost();
            },
            .ai_dismiss => {
                if (!self.ghostVisible(term)) return false;
                self.clearGhost();
            },
            .ai_next, .ai_prev => {
                if (!self.ghostVisible(term)) return false;
                const g = &self.ghost.?;
                const n = g.alternatives.items.len;
                g.index = if (a == .ai_next) (g.index + 1) % n else (g.index + n - 1) % n;
            },
            else => return false,
        }
        return true;
    }

    // ------------------------------------------------------------ paste

    /// Clipboard contents arrived (see `Effect.request_paste`).
    pub fn onPaste(self: *Ui, term: *const Terminal, data: []const u8, target: events.ClipTarget, purpose: events.PastePurpose) !void {
        switch (purpose) {
            // Handled by the event loop before it gets here.
            .plugin => return,
            .osc52 => {
                if (self.opts.osc52 != .read_write) return;
                var out = std.ArrayList(u8).init(self.allocator);
                defer out.deinit();
                try out.appendSlice(if (target == .primary) "\x1b]52;p;" else "\x1b]52;c;");
                const enc = std.base64.standard.Encoder;
                const start = out.items.len;
                try out.resize(start + enc.calcSize(data.len));
                _ = enc.encode(out.items[start..], data);
                try out.appendSlice("\x1b\\");
                try self.pushWrite(out.items);
            },
            .paste => {
                if (data.len == 0) return;
                var out = std.ArrayList(u8).init(self.allocator);
                errdefer out.deinit();
                try input.encodePaste(data, term.modes, &out);
                const lines = std.mem.count(u8, out.items, "\r");
                if (self.opts.paste_confirm and !term.modes.bracketed_paste and lines > 0) {
                    if (self.prompt) |old| self.allocator.free(old.data);
                    self.prompt = .{ .data = try out.toOwnedSlice(), .lines = lines };
                    return;
                }
                try self.effects.append(.{ .write = try out.toOwnedSlice() });
                self.scroll = 0;
            },
        }
    }

    fn answerPrompt(self: *Ui, accept: bool) !void {
        const p = self.prompt orelse return;
        self.prompt = null;
        if (accept) {
            try self.effects.append(.{ .write = p.data });
            self.scroll = 0;
        } else self.allocator.free(p.data);
    }

    // ------------------------------------------------------------ OSC 52

    pub fn onClipboardOps(self: *Ui, ops: []const terminal.ClipboardOp) !void {
        for (ops) |op| switch (op) {
            .set => |s| {
                if (self.opts.osc52 == .off) continue;
                if (s.targets.clipboard) try self.effects.append(.{ .set_clipboard = .{ .target = .clipboard, .text = try self.allocator.dupe(u8, s.data) } });
                if (s.targets.primary) try self.effects.append(.{ .set_clipboard = .{ .target = .primary, .text = try self.allocator.dupe(u8, s.data) } });
            },
            .query => |t| {
                if (self.opts.osc52 != .read_write) continue;
                try self.effects.append(.{ .request_paste = .{ .target = if (t.clipboard) .clipboard else .primary, .purpose = .osc52 } });
            },
        };
    }

    // ------------------------------------------------------------ keyboard

    /// Text typed while an overlay (paste prompt / search) is open. Returns
    /// false when no overlay wants it (send it to the PTY).
    pub fn handleText(self: *Ui, term: *const Terminal, bytes: []const u8) !bool {
        if (self.palette) |*p| {
            try self.paletteResult(try p.handleText(bytes));
            return true;
        }
        if (self.prompt != null) {
            if (bytes.len == 1) switch (bytes[0]) {
                'y', 'Y', '\r' => try self.answerPrompt(true),
                'n', 'N', 0x03, 0x1b => try self.answerPrompt(false),
                else => {},
            };
            return true;
        }
        if (self.ask.live) {
            switch (self.ask.handleText(bytes)) {
                .jump => |line| self.ensureVisible(term, line),
                else => {},
            }
            return true;
        }
        if (self.search) |*st| {
            if (bytes.len == 2 and bytes[0] == 0x1b) {
                switch (bytes[1]) {
                    'c', 'C' => st.case_sensitive = !st.case_sensitive,
                    'r', 'R' => st.regex = search.regex_supported and !st.regex,
                    else => return true,
                }
                try self.recomputeSearch(term);
                return true;
            }
            if (bytes.len == 1 and bytes[0] < 0x20) {
                switch (bytes[0]) {
                    0x03, 0x07 => self.closeSearch(), // Ctrl+C / Ctrl+G
                    0x15 => { // Ctrl+U
                        st.query.clearRetainingCapacity();
                        try self.recomputeSearch(term);
                    },
                    0x08 => {
                        deleteLastCodepoint(&st.query);
                        try self.recomputeSearch(term);
                    },
                    0x0e => self.stepSearch(term, false), // Ctrl+N newer
                    0x10 => self.stepSearch(term, true), // Ctrl+P older
                    else => {},
                }
                return true;
            }
            if (bytes.len == 1 and bytes[0] == 0x7f) {
                deleteLastCodepoint(&st.query);
            } else {
                for (bytes) |b| if (b < 0x20) return true;
                if (st.query.items.len + bytes.len > 512) return true;
                try st.query.appendSlice(bytes);
            }
            try self.recomputeSearch(term);
            return true;
        }
        return false;
    }

    /// Special keys while an overlay is open; false = not consumed.
    pub fn handleKey(self: *Ui, term: *const Terminal, key: input.Key, mods: input.Mods) !bool {
        if (self.palette) |*p| {
            try self.paletteResult(try p.handleKey(key, mods));
            return true;
        }
        if (self.prompt != null) {
            switch (key) {
                .enter, .kp_enter => try self.answerPrompt(true),
                .escape => try self.answerPrompt(false),
                else => {},
            }
            return true;
        }
        if (self.ask.live) {
            switch (self.ask.handleKey(key, mods)) {
                .jump => |line| self.ensureVisible(term, line),
                else => {},
            }
            return true;
        }
        if (self.search) |*st| {
            switch (key) {
                .escape => self.closeSearch(),
                .enter, .kp_enter => self.stepSearch(term, !mods.shift),
                .up => self.stepSearch(term, true),
                .down => self.stepSearch(term, false),
                .page_up => self.scrollBy(term, @as(i64, term.rows) - 1),
                .page_down => self.scrollBy(term, -(@as(i64, term.rows) - 1)),
                .backspace => {
                    deleteLastCodepoint(&st.query);
                    try self.recomputeSearch(term);
                },
                else => {},
            }
            return true;
        }
        if (self.notice != null and key == .escape) {
            self.clearNotice();
            return true;
        }
        return false;
    }

    // ------------------------------------------------------------- ghost

    /// Show `alternatives` (suffixes, ownership taken) as ghost text at the
    /// current cursor position. An empty list clears it.
    pub fn setSuggestions(self: *Ui, term: *const Terminal, alternatives: [][]u8) !void {
        self.clearGhost();
        if (alternatives.len == 0) {
            self.allocator.free(alternatives);
            return;
        }
        self.ghost = .{
            .anchor = term.cursorMark(),
            .alternatives = std.ArrayList([]u8).fromOwnedSlice(self.allocator, alternatives),
        };
    }

    pub fn clearGhost(self: *Ui) void {
        if (self.ghost) |*g| {
            for (g.alternatives.items) |a| self.allocator.free(a);
            g.alternatives.deinit();
        }
        self.ghost = null;
    }

    pub fn ghostText(self: *const Ui) ?[]const u8 {
        const g = self.ghost orelse return null;
        return g.alternatives.items[g.index];
    }

    /// Whether the ghost text is on screen (live view, cursor unmoved, no
    /// overlay in the way).
    pub fn ghostVisible(self: *const Ui, term: *const Terminal) bool {
        const g = self.ghost orelse return false;
        if (self.scroll != 0 or term.alt_active or self.overlayActive()) return false;
        return std.meta.eql(g.anchor, term.cursorMark());
    }

    /// The user typed `bytes` for the shell. If they match the start of the
    /// ghost text, keep the rest (it reappears once the shell echoes);
    /// otherwise drop it. Returns whether a suggestion is still pending.
    pub fn ghostTyped(self: *Ui, term: *const Terminal, bytes: []const u8) bool {
        const g = &(self.ghost orelse return false);
        const text = g.alternatives.items[g.index];
        const printable = for (bytes) |b| {
            if (b < 0x20 or b == 0x7f) break false;
        } else true;
        const cols_used = std.unicode.utf8CountCodepoints(bytes) catch bytes.len;
        if (!printable or bytes.len >= text.len or !std.mem.startsWith(u8, text, bytes) or
            @as(usize, g.anchor.col) + cols_used >= term.cols)
        {
            self.clearGhost();
            return false;
        }
        // Keep only alternatives that agree with what was typed.
        var i: usize = 0;
        while (i < g.alternatives.items.len) {
            const alt = g.alternatives.items[i];
            if (alt.len > bytes.len and std.mem.startsWith(u8, alt, bytes)) {
                const rest = self.allocator.dupe(u8, alt[bytes.len..]) catch {
                    self.clearGhost();
                    return false;
                };
                self.allocator.free(alt);
                g.alternatives.items[i] = rest;
                i += 1;
            } else {
                self.allocator.free(alt);
                _ = g.alternatives.orderedRemove(i);
                if (g.index > i or g.index >= g.alternatives.items.len) g.index -|= 1;
            }
        }
        g.index = @min(g.index, g.alternatives.items.len -| 1);
        g.anchor.col += @intCast(cols_used);
        return true;
    }

    /// Set (or with null, clear) the corner status tag.
    pub fn setAiStatus(self: *Ui, text: ?[]const u8) void {
        if (self.ai_status) |old| self.allocator.free(old);
        self.ai_status = if (text) |t| self.allocator.dupe(u8, t) catch null else null;
    }

    fn drawGhost(self: *const Ui, term: *const Terminal, row_cells: []Cell, col: u16) void {
        const text = self.ghostText() orelse return;
        const g = self.ghost.?;
        const unicode = @import("../terminal/unicode.zig");
        var c: usize = col;
        var counter_buf: [32]u8 = undefined;
        const counter: []const u8 = if (g.alternatives.items.len > 1)
            std.fmt.bufPrint(&counter_buf, "  ({d}/{d})", .{ g.index + 1, g.alternatives.items.len }) catch ""
        else
            "";
        _ = term;
        for ([_][]const u8{ text, counter }) |part| {
            var it = (std.unicode.Utf8View.init(part) catch return).iterator();
            while (it.nextCodepoint()) |cp| {
                const w = unicode.width(cp);
                if (w == 0) continue;
                if (c + w > row_cells.len) return;
                // Never paint over real text (e.g. a right prompt).
                for (row_cells[c..][0..w]) |cell| if (cell.char != ' ' and cell.char != 0) return;
                var cell = row_cells[c];
                cell.char = cp;
                cell.width = @intCast(w);
                cell.fg_color = color.indexed(8);
                cell.bold = false;
                cell.italic = part.ptr == counter.ptr;
                cell.underline = false;
                cell.inverse = false;
                cell.link = 0;
                row_cells[c] = cell;
                if (w == 2) {
                    row_cells[c + 1] = cell;
                    row_cells[c + 1].char = ' ';
                    row_cells[c + 1].width = 0;
                }
                c += w;
            }
        }
    }

    /// Replace the notice with an AI answer: `title` then `body` split
    /// into lines (no "see stderr" truncation; the tail is kept visible).
    pub fn setAiNotice(self: *Ui, title: []const u8, body: []const u8, now_ms: i64) !void {
        var lines = std.ArrayList([]const u8).init(self.allocator);
        defer lines.deinit();
        var it = std.mem.splitScalar(u8, std.mem.trim(u8, body, "\n"), '\n');
        while (it.next()) |l| {
            const line = std.mem.trimRight(u8, l, " \r");
            if (std.mem.startsWith(u8, std.mem.trim(u8, line, " "), "```")) continue;
            try lines.append(line);
        }
        self.clearNotice();
        var n = Notice{ .kind = .ai, .lines = std.ArrayList([]u8).init(self.allocator) };
        errdefer {
            for (n.lines.items) |l| self.allocator.free(l);
            n.lines.deinit();
        }
        _ = now_ms;
        try n.lines.append(try self.allocator.dupe(u8, title));
        for (lines.items) |l| try n.lines.append(try std.fmt.allocPrint(self.allocator, "  {s}", .{l}));
        self.notice = n;
    }

    // ------------------------------------------------------------ notice

    /// Show `headline` plus `details` at the top of the window, replacing
    /// any current notice. Shown until Esc, or `ttl_ms` if given.
    pub fn setNotice(self: *Ui, kind: Notice.Kind, headline: []const u8, details: []const []const u8, ttl_ms: ?i64, now_ms: i64) !void {
        self.clearNotice();
        var n = Notice{ .kind = kind, .lines = std.ArrayList([]u8).init(self.allocator), .expires_ms = if (ttl_ms) |t| now_ms + t else null };
        errdefer {
            for (n.lines.items) |l| self.allocator.free(l);
            n.lines.deinit();
        }
        try n.lines.append(try self.allocator.dupe(u8, headline));
        const room = Notice.max_rows - 1;
        for (details, 0..) |d, i| {
            if (i + 1 == room and details.len > room) {
                try n.lines.append(try std.fmt.allocPrint(self.allocator, "  \u{2026} and {d} more (see stderr)", .{details.len - i}));
                break;
            }
            try n.lines.append(try std.fmt.allocPrint(self.allocator, "  {s}", .{d}));
        }
        self.notice = n;
    }

    pub fn clearNotice(self: *Ui) void {
        if (self.notice) |*n| {
            for (n.lines.items) |l| self.allocator.free(l);
            n.lines.deinit();
        }
        self.notice = null;
    }

    /// Drop an expired notice; returns true if the screen changed.
    pub fn tickNotice(self: *Ui, now_ms: i64) bool {
        const n = self.notice orelse return false;
        const t = n.expires_ms orelse return false;
        if (now_ms < t) return false;
        self.clearNotice();
        return true;
    }

    /// Milliseconds until the notice expires (for the poll timeout).
    pub fn noticeTimeout(self: *const Ui, now_ms: i64) ?i64 {
        const n = self.notice orelse return null;
        const t = n.expires_ms orelse return null;
        return @max(0, t - now_ms);
    }

    /// Rows the notice occupies at the top of a rows×cols view.
    fn noticeRows(self: *const Ui, rows: u16, cols: u16) usize {
        if (self.notice == null) return 0;
        return self.layoutNotice(rows, cols, null, null);
    }

    /// Lay out (and, given buffers, draw) the notice. Long lines wrap
    /// with indented continuations; at most max_rows + 2 rows and never
    /// the whole screen.
    fn layoutNotice(self: *const Ui, rows: u16, cols: u16, cells: ?[]Cell, marks: ?[]Mark) usize {
        const note = self.notice orelse return 0;
        const want: usize = if (note.kind == .ai) Notice.max_ai_rows else Notice.max_rows + 2;
        const limit: usize = @min(want, @as(usize, rows) -| 1);
        const colors: [2]u32 = switch (note.kind) {
            .err => .{ 0xFFFFFF, 0x8B0000 },
            .warning => .{ 0x000000, 0xD7AF00 },
            .info => .{ 0x000000, 0x5FAF5F },
            .ai => .{ 0xFFFFFF, 0x1F3A5F },
        };
        var row: usize = 0;
        for (note.lines.items, 0..) |line, i| {
            var rest = line;
            var first = true;
            while (first or rest.len > 0) {
                if (row >= limit) return row;
                const indent: []const u8 = if (first) "" else "      ";
                const hint: []const u8 = if (i == 0 and first) "  [Esc] dismiss" else "";
                const reserve = indent.len + (if (i == 0) "  [Esc] dismiss".len else 0);
                const cut = fitWidth(rest, @max(@as(usize, cols) -| reserve, 8));
                if (cells) |cs| {
                    const off = row * cols;
                    @memset(marks.?[off..][0..cols], .none);
                    var buf: [1024]u8 = undefined;
                    const text = std.fmt.bufPrint(&buf, "{s}{s}", .{ indent, rest[0..cut] }) catch rest[0..cut];
                    drawText(cs[off..][0..cols], text, hint, colors[0], colors[1]);
                }
                rest = rest[cut..];
                first = false;
                row += 1;
            }
        }
        return row;
    }

    pub fn overlayActive(self: *const Ui) bool {
        return self.prompt != null or self.search != null or self.ask.live;
    }

    pub fn askIsOpen(self: *const Ui) bool {
        return self.ask.live;
    }

    pub fn openAsk(self: *Ui, source_label: []const u8) !void {
        self.closeSearch();
        try self.ask.open(self.allocator, source_label);
    }

    pub fn closeAsk(self: *Ui) void {
        self.ask.close();
    }

    pub fn askQuery(self: *const Ui) []const u8 {
        return self.ask.queryText();
    }

    pub fn takeAskSubmit(self: *Ui) bool {
        if (!self.ask.pending_submit) return false;
        self.ask.pending_submit = false;
        return true;
    }

    pub fn takeAskCancel(self: *Ui) bool {
        if (!self.ask.pending_cancel) return false;
        self.ask.pending_cancel = false;
        return true;
    }

    pub fn askMarkWaiting(self: *Ui) void {
        self.ask.markWaiting();
    }

    pub fn askMarkEdit(self: *Ui) void {
        self.ask.markEdit();
    }

    pub fn askMarkOffline(self: *Ui) void {
        self.ask.markOffline();
    }

    /// Copies `matches` into the ask bar and scrolls the first one into view.
    pub fn setAskMatches(self: *Ui, term: *const Terminal, matches: []const search.Match) void {
        if (self.ask.setMatches(matches)) |line| self.ensureVisible(term, line);
    }

    // ------------------------------------------------------------ palette

    /// Opens a palette in `mode` (replacing one in another mode); the
    /// caller fills it.
    pub fn openPalette(self: *Ui, mode: palette_mod.Mode, title: []const u8) !*palette_mod.Palette {
        if (self.palette) |p| if (p.mode != mode) self.closePalette();
        if (self.palette == null) {
            self.closeSearch();
            self.palette = try palette_mod.Palette.init(self.allocator, mode, title);
        }
        return &self.palette.?;
    }

    pub fn paletteOpen(self: *const Ui, mode: palette_mod.Mode) bool {
        return if (self.palette) |p| p.mode == mode else false;
    }

    pub fn closePalette(self: *Ui) void {
        if (self.palette) |*p| p.deinit();
        self.palette = null;
    }

    fn paletteResult(self: *Ui, r: palette_mod.Result) !void {
        switch (r) {
            .none => {},
            .close => self.closePalette(),
            .pick => |pk| {
                errdefer if (pk == .open) self.allocator.free(pk.open.name);
                // Close first: the pick may open another overlay.
                if (pk != .toggle) self.closePalette();
                try self.effects.append(.{ .palette = pk });
            },
        }
    }

    // ------------------------------------------------------------- toasts

    /// Add a toast (top-right, newest at the bottom); the oldest goes when
    /// there are more than `Toast.max`.
    pub fn addToast(self: *Ui, text: []const u8, level: Toast.Level, ttl_ms: i64, now_ms: i64) !void {
        var clean = std.ArrayList(u8).init(self.allocator);
        defer clean.deinit();
        // One line, no control characters, at most 200 bytes.
        var it = (std.unicode.Utf8View.init(text) catch std.unicode.Utf8View.initUnchecked("(invalid UTF-8)")).iterator();
        while (it.nextCodepointSlice()) |cs| {
            if (clean.items.len + cs.len > 200) break;
            if (cs.len == 1 and (cs[0] < 0x20 or cs[0] == 0x7f)) {
                try clean.append(' ');
            } else try clean.appendSlice(cs);
        }
        const owned = try clean.toOwnedSlice();
        errdefer self.allocator.free(owned);
        if (self.toasts.items.len >= Toast.max) {
            self.allocator.free(self.toasts.items[0].text);
            _ = self.toasts.orderedRemove(0);
        }
        try self.toasts.append(.{ .text = owned, .level = level, .expires_ms = now_ms + @max(ttl_ms, 500) });
    }

    /// Drop expired toasts; true if any went.
    pub fn tickToasts(self: *Ui, now_ms: i64) bool {
        var changed = false;
        var i: usize = 0;
        while (i < self.toasts.items.len) {
            if (self.toasts.items[i].expires_ms <= now_ms) {
                self.allocator.free(self.toasts.items[i].text);
                _ = self.toasts.orderedRemove(i);
                changed = true;
            } else i += 1;
        }
        return changed;
    }

    pub fn toastTimeout(self: *const Ui, now_ms: i64) ?i64 {
        var best: ?i64 = null;
        for (self.toasts.items) |t| {
            const left = @max(t.expires_ms - now_ms, 0);
            best = if (best) |b| @min(b, left) else left;
        }
        return best;
    }

    fn drawToasts(self: *const Ui, cells: []Cell, rows: u16, cols: u16, first_row: usize) void {
        if (cols < 12) return;
        var row = first_row;
        for (self.toasts.items) |t| {
            if (row >= rows) break;
            const max_w: usize = @max(@as(usize, cols) / 2, @min(@as(usize, cols) - 2, 30));
            const tw = textCols(t.text);
            const w = @min(tw + 4, max_w);
            const start: usize = cols - w;
            const line = cells[row * cols ..][start..cols];
            const colors = t.level.colors();
            drawText(line, " ● ", "", colors[0], colors[1]);
            const used: usize = @min(3, line.len);
            var text_cells = line[used..];
            var c = Cell.init();
            c.bg_color = colors[1];
            c.fg_color = 0xF0F0F0;
            @memset(text_cells, c);
            if (tw + 1 > text_cells.len and text_cells.len > 1) {
                // Cut with an ellipsis.
                drawText(text_cells[0 .. text_cells.len - 1], t.text, "", 0xF0F0F0, colors[1]);
                text_cells[text_cells.len - 2].char = '…';
                text_cells[text_cells.len - 2].width = 1;
            } else drawText(text_cells, t.text, "", 0xF0F0F0, colors[1]);
            row += 1;
        }
    }

    // --------------------------------------------------------- status bar

    /// Rows the status bar takes under the grid (0 or 1).
    pub fn statusRows(self: *const Ui) u16 {
        return @intFromBool(self.status_visible);
    }

    pub fn clearStatus(self: *Ui) void {
        for (self.status_left.items) |p| self.allocator.free(p.text);
        for (self.status_right.items) |p| self.allocator.free(p.text);
        self.status_left.clearRetainingCapacity();
        self.status_right.clearRetainingCapacity();
    }

    /// Append a segment (copied) to the left or right group.
    pub fn addStatus(self: *Ui, right: bool, text: []const u8, fg: ?u32) !void {
        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        for (owned) |*b| if (b.* < 0x20 or b.* == 0x7f) {
            b.* = ' ';
        };
        const list = if (right) &self.status_right else &self.status_left;
        try list.append(self.allocator, .{ .text = owned, .fg = fg });
    }

    pub fn drawStatus(self: *const Ui, row: []Cell) void {
        const bg: u32 = 0x202020;
        var base = Cell.init();
        base.bg_color = bg;
        base.fg_color = 0xB0B0B0;
        @memset(row, base);
        // Right group first (measured), then the left group fills what's left.
        var right_w: usize = 0;
        for (self.status_right.items) |p| right_w += textCols(p.text) + 3;
        var right_start: usize = if (right_w < row.len) row.len - right_w else row.len;
        var col: usize = 0;
        for (self.status_left.items, 0..) |p, i| {
            if (col >= right_start) break;
            if (i > 0 and col + 1 < right_start) {
                row[col + 1].char = '│';
                row[col + 1].fg_color = 0x505050;
                col += 2;
            }
            col += 1;
            if (col >= right_start) break;
            drawPlain(row[col..right_start], p.text, p.fg orelse 0xD0D0D0);
            col += @min(textCols(p.text), right_start - col);
        }
        for (self.status_right.items) |p| {
            if (right_start + 1 >= row.len) break;
            row[right_start + 1].char = '│';
            row[right_start + 1].fg_color = 0x505050;
            right_start += 2;
            if (right_start >= row.len) break;
            drawPlain(row[right_start..], p.text, p.fg orelse 0xD0D0D0);
            right_start += @min(textCols(p.text) + 1, row.len - right_start);
        }
    }

    // ------------------------------------------------------------ search

    fn openSearch(self: *Ui, term: *const Terminal) !void {
        if (self.ask.live) _ = self.ask.requestClose();
        if (self.search != null) return;
        self.search = .{
            .query = std.ArrayList(u8).init(self.allocator),
            .matches = std.ArrayList(search.Match).init(self.allocator),
        };
        // Seed with the selection when it is a short single line.
        if (try self.selectionText(term)) |t| {
            defer self.allocator.free(t);
            if (t.len <= 128 and std.mem.indexOfScalar(u8, t, '\n') == null) {
                try self.search.?.query.appendSlice(t);
                try self.recomputeSearch(term);
            }
        }
    }

    pub fn closeSearch(self: *Ui) void {
        if (self.search) |*st| {
            st.query.deinit();
            st.matches.deinit();
        }
        self.search = null;
    }

    /// Bring the matches up to date after output: matches in lines that
    /// were history at the last search are kept (history is immutable),
    /// evicted ones dropped, and everything from the logical line at the
    /// old screen top down is searched again. The current match is kept
    /// when it still exists; the view does not move. `full` re-searches
    /// everything (after a reflow).
    fn refreshSearch(self: *Ui, term: *const Terminal, full: bool) !void {
        const st = &(self.search orelse return);
        if (st.query.items.len == 0 or st.bad_regex) {
            st.searched_to = term.screenTop();
            return;
        }
        var s = search.Searcher.init(self.allocator, st.query.items, .{ .case_sensitive = st.case_sensitive, .regex = st.regex }) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            st.bad_regex = true;
            return;
        };
        defer s.deinit();
        const avail = if (term.alt_active) term.screenTop() else term.historyTop();
        const from = if (full) avail else search.logicalStart(term, std.math.clamp(st.searched_to, avail, term.screenTop()), avail);
        const cur: ?search.Match = if (st.current) |c| st.matches.items[c] else null;

        var lo: usize = 0;
        while (lo < st.matches.items.len and st.matches.items[lo].line < avail) lo += 1;
        var hi: usize = lo;
        while (hi < st.matches.items.len and st.matches.items[hi].line < from) hi += 1;
        if (lo > 0) std.mem.copyForwards(search.Match, st.matches.items[0 .. hi - lo], st.matches.items[lo..hi]);
        st.matches.shrinkRetainingCapacity(hi - lo);
        try search.searchAll(&s, term, from, term.screenTop() + term.rows - 1, &st.matches);
        st.searched_to = term.screenTop();

        st.current = null;
        if (st.matches.items.len == 0) return;
        var idx: usize = st.matches.items.len - 1;
        if (cur) |c| {
            while (idx > 0 and st.matches.items[idx].line > c.line) idx -= 1;
            for (st.matches.items, 0..) |m, i| if (std.meta.eql(m, c)) {
                idx = i;
                break;
            };
        }
        st.current = idx;
    }

    fn recomputeSearch(self: *Ui, term: *const Terminal) !void {
        const st = &(self.search orelse return);
        st.searched_to = term.screenTop();
        // Refine around the current match while typing; otherwise start
        // from the bottom of the view.
        const anchor: i64 = if (st.current) |c| st.matches.items[c].line else self.viewTop(term) + term.rows - 1;
        st.matches.clearRetainingCapacity();
        st.current = null;
        st.bad_regex = false;
        if (st.query.items.len == 0) return;
        var s = search.Searcher.init(self.allocator, st.query.items, .{ .case_sensitive = st.case_sensitive, .regex = st.regex }) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            st.bad_regex = true; // bad pattern or no regex support
            return;
        };
        defer s.deinit();
        const first = if (term.alt_active) term.screenTop() else term.historyTop();
        try search.searchAll(&s, term, first, term.screenTop() + term.rows - 1, &st.matches);
        if (st.matches.items.len == 0) return;
        var idx: usize = st.matches.items.len - 1;
        while (idx > 0 and st.matches.items[idx].line > anchor) idx -= 1;
        st.current = idx;
        self.ensureVisible(term, st.matches.items[idx].line);
    }

    /// `older` = towards the top of the scrollback.
    fn stepSearch(self: *Ui, term: *const Terminal, older: bool) void {
        const st = &(self.search orelse return);
        st.current = search.step(st.matches.items, st.current, !older) orelse return;
        self.ensureVisible(term, st.matches.items[st.current.?].line);
    }

    pub fn matchCount(self: *const Ui) usize {
        return if (self.search) |st| st.matches.items.len else 0;
    }

    // ------------------------------------------------------------ compose

    /// Build the visible grid (scrollback + screen + overlay bar) and its
    /// highlight marks for the renderer.
    pub fn compose(self: *Ui, term: *const Terminal, cells: *std.ArrayList(Cell), marks: *std.ArrayList(Mark)) !Composed {
        const rows = term.rows;
        const cols = term.cols;
        const n = @as(usize, rows) * cols;
        try cells.resize(n);
        try marks.resize(n);
        @memset(marks.items, .none);
        const top = self.viewTop(term);
        const blank = Cell.init();

        var r: u16 = 0;
        while (r < rows) : (r += 1) {
            const dst = cells.items[@as(usize, r) * cols ..][0..cols];
            if (term.lineAt(top + r)) |src| {
                const k = @min(src.len, cols);
                @memcpy(dst[0..k], src[0..k]);
                if (k < cols) @memset(dst[k..], blank);
                // A wide char cut by a narrower history row.
                if (k > 0 and dst[k - 1].width == 2 and k == cols and src.len > cols) dst[k - 1] = blank;
            } else @memset(dst, blank);
        }

        if (self.sel) |s| if (s.active) {
            const range = s.resolve(term, self.opts.word_chars);
            r = 0;
            while (r < rows) : (r += 1) {
                const line = top + r;
                if (line < range.start.line or line > range.end.line) continue;
                var c: u16 = 0;
                while (c < cols) : (c += 1) {
                    if (s.containsResolved(range, line, c)) marks.items[@as(usize, r) * cols + c] = .selected;
                }
            }
        };

        if (self.search) |st| {
            for (st.matches.items, 0..) |m, i| {
                if (m.end_line < top or m.line >= top + rows) continue;
                const mk: Mark = if (st.current != null and st.current.? == i) .current_match else .match;
                var line = @max(m.line, top);
                while (line <= @min(m.end_line, top + rows - 1)) : (line += 1) {
                    const row: usize = @intCast(line - top);
                    var c: u16 = if (line == m.line) m.start else 0;
                    const last: u16 = if (line == m.end_line) m.end else cols - 1;
                    while (c <= last and c < cols) : (c += 1) marks.items[row * cols + c] = mk;
                }
            }
        }

        self.ask.paint(top, rows, cols, marks.items);

        const cur_row: i64 = @as(i64, term.cursor_row) + @as(i64, @intCast(@min(self.scroll, rows))) - self.viewShift(term);
        var out = Composed{
            .cursor_row = @intCast(std.math.clamp(cur_row, 0, @as(i64, rows))),
            .cursor_col = term.cursor_col,
            .cursor_visible = term.cursor_visible and cur_row >= 0 and cur_row < rows,
        };
        if (self.opts.scrollbar and self.scroll > 0) {
            const hist: f32 = @floatFromInt(term.scrollback.len());
            const total = hist + @as(f32, @floatFromInt(rows));
            out.scrollbar = .{
                .top = (hist - @as(f32, @floatFromInt(self.scroll))) / total,
                .height = @as(f32, @floatFromInt(rows)) / total,
            };
        }

        if (self.ghostVisible(term) and out.cursor_visible and out.cursor_row < rows) {
            const g = self.ghost.?;
            if (g.anchor.col < cols) {
                const row_cells = cells.items[@as(usize, out.cursor_row) * cols ..][0..cols];
                self.drawGhost(term, row_cells, g.anchor.col);
            }
        }

        if (self.ai_status) |st| if (self.notice == null and self.toasts.items.len == 0 and !term.alt_active and self.scroll == 0 and rows > 1) {
            // A small badge in the bottom-right corner, or the top-right
            // one when the bottom row is in use.
            const w = (std.unicode.utf8CountCodepoints(st) catch st.len) + 2;
            if (w + 2 < cols) {
                const start = cols - w;
                const bottom = cells.items[@as(usize, rows - 1) * cols ..][0..cols];
                const bottom_free = out.cursor_row != rows - 1 and for (bottom[start..]) |c| {
                    if (c.char != ' ' and c.char != 0) break false;
                } else true;
                const row_cells = if (bottom_free) bottom else cells.items[0..cols];
                var c: usize = start;
                var badge = Cell.init();
                badge.fg_color = 0xC0C0C0;
                badge.bg_color = 0x3A3A3A;
                for (row_cells[start..]) |*cell| cell.* = badge;
                c += 1;
                var it = (std.unicode.Utf8View.init(st) catch unreachable).iterator();
                while (it.nextCodepoint()) |cp| : (c += 1) row_cells[c].char = cp;
                if (!bottom_free and out.cursor_row == 0 and out.cursor_col >= start) out.cursor_visible = false;
            }
        };

        if (self.notice != null) {
            const shown = self.layoutNotice(rows, cols, cells.items, marks.items);
            if (out.cursor_row < shown) out.cursor_visible = false;
        }

        if (self.toasts.items.len > 0) {
            const top_rows = if (self.notice != null) self.noticeRows(rows, cols) else 0;
            self.drawToasts(cells.items, rows, cols, top_rows);
            const last = top_rows + self.toasts.items.len;
            if (out.cursor_row >= top_rows and out.cursor_row < last and out.cursor_col + 30 >= cols) out.cursor_visible = false;
        }

        if (self.palette) |*p| {
            p.draw(cells.items, rows, cols);
            @memset(marks.items, .none);
            out.cursor_visible = false;
        }

        if (self.overlayActive() and rows > 0) {
            const bar = cells.items[@as(usize, rows - 1) * cols ..][0..cols];
            const bar_marks = marks.items[@as(usize, rows - 1) * cols ..][0..cols];
            @memset(bar_marks, .none);
            try self.drawBar(bar);
            if (out.cursor_row == rows - 1) out.cursor_visible = false;
        }
        if (self.status_visible) {
            // The extra row below the grid (the caller draws rows + 1).
            try cells.resize(n + cols);
            try marks.resize(n + cols);
            @memset(marks.items[n..], .none);
            self.drawStatus(cells.items[n..][0..cols]);
            out.rows = rows + 1;
        } else out.rows = rows;
        return out;
    }

    /// Window-level overlays (toasts from `first_row` down, the palette)
    /// over a whole rows×cols window grid. Returns true when they cover
    /// the cursor (the palette is open).
    pub fn drawOverlays(self: *Ui, cells: []Cell, marks: []Mark, rows: u16, cols: u16, first_row: usize) bool {
        if (self.toasts.items.len > 0) {
            self.drawToasts(cells, rows, cols, first_row);
            for (first_row..@min(first_row + self.toasts.items.len, rows)) |r| @memset(marks[r * cols ..][cols -| @max(@as(usize, cols) / 2, 30)..cols], .none);
        }
        if (self.palette) |*p| {
            p.draw(cells, rows, cols);
            @memset(marks, .none);
            return true;
        }
        return false;
    }

    /// Anything drawn by `drawOverlays`.
    pub fn hasOverlays(self: *const Ui) bool {
        return self.palette != null or self.toasts.items.len > 0;
    }

    fn drawBar(self: *Ui, bar: []Cell) !void {
        var text = std.ArrayList(u8).init(self.allocator);
        defer text.deinit();
        var fg: u32 = 0x000000;
        var bg: u32 = 0xD0D0D0;
        if (self.prompt) |p| {
            fg = 0xFFFFFF;
            bg = 0xAF1F1F;
            try text.writer().print(" Paste {d} line{s} into a program without bracketed paste?  [Enter/y] paste  [Esc/n] cancel", .{ p.lines + 1, if (p.lines == 0) "" else "s" });
        } else if (self.ask.live) {
            fg = 0xFFFFFF;
            bg = 0x1F3A5F;
            var bar_buf: [240]u8 = undefined;
            try text.appendSlice(self.ask.barText(&bar_buf));
        } else if (self.search) |st| {
            try text.writer().print(" Find: {s}\u{2588}  ", .{st.query.items});
            if (st.bad_regex) {
                try text.appendSlice("[bad regex]");
            } else if (st.query.items.len > 0) {
                if (st.matches.items.len == 0) {
                    try text.appendSlice("no matches");
                } else try text.writer().print("{d}/{d}", .{ st.matches.items.len - st.current.?, st.matches.items.len });
            }
            try text.writer().print("  [{s}] case  [{s}] regex  Enter/\u{2191} older  Shift+Enter/\u{2193} newer  Alt+C  Alt+R  Esc", .{
                if (st.case_sensitive) "x" else " ",
                if (st.regex) "x" else " ",
            });
        }
        drawText(bar, text.items, "", fg, bg);
    }
};

/// Bytes of `text` that fit in `width` columns (whole codepoints).
fn fitWidth(text: []const u8, width: usize) usize {
    const unicode = @import("../terminal/unicode.zig");
    var col: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        if (i + n > text.len) return text.len;
        const cp = std.unicode.utf8Decode(text[i..][0..n]) catch 0xFFFD;
        const w = unicode.width(cp);
        if (col + w > width) return i;
        col += w;
        i += n;
    }
    return text.len;
}

fn textCols(text: []const u8) usize {
    const unicode = @import("../terminal/unicode.zig");
    var n: usize = 0;
    var it = (std.unicode.Utf8View.init(text) catch return text.len).iterator();
    while (it.nextCodepoint()) |cp| n += unicode.width(cp);
    return n;
}

/// Write `text` into `cells` (clipped), keeping their background.
fn drawPlain(cells: []Cell, text: []const u8, fg: u32) void {
    const unicode = @import("../terminal/unicode.zig");
    var col: usize = 0;
    var it = (std.unicode.Utf8View.init(text) catch return).iterator();
    while (it.nextCodepoint()) |cp| {
        const w = unicode.width(cp);
        if (w == 0) continue;
        if (col + w > cells.len) return;
        cells[col].char = cp;
        cells[col].width = @intCast(w);
        cells[col].fg_color = fg;
        if (w == 2) cells[col + 1].width = 0;
        col += w;
    }
}

/// Fill `bar` with `text` (then `suffix`, right after) in fg/bg.
fn drawText(bar: []Cell, text: []const u8, suffix: []const u8, fg: u32, bg: u32) void {
    var cell = Cell.init();
    cell.fg_color = fg;
    cell.bg_color = bg;
    @memset(bar, cell);
    const unicode = @import("../terminal/unicode.zig");
    var col: usize = 0;
    for ([_][]const u8{ text, suffix }) |part| {
        var it = (std.unicode.Utf8View.init(part) catch continue).iterator();
        while (it.nextCodepoint()) |cp| {
            const w = unicode.width(cp);
            if (w == 0) continue;
            if (col + w > bar.len) return;
            bar[col].char = cp;
            bar[col].width = @intCast(w);
            if (w == 2) bar[col + 1].width = 0;
            col += w;
        }
    }
}

fn deleteLastCodepoint(buf: *std.ArrayList(u8)) void {
    var n = buf.items.len;
    if (n == 0) return;
    n -= 1;
    while (n > 0 and buf.items[n] & 0xC0 == 0x80) n -= 1;
    buf.items.len = n;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;
const CW: u32 = 10;
const CH: u32 = 20;

fn mouse(action: input.MouseAction, button: input.MouseButton, col: i32, row: i32, mods: input.Mods) events.MouseInput {
    return .{ .action = action, .button = button, .x = col * @as(i32, CW) + 2, .y = row * @as(i32, CH) + 2, .mods = mods };
}

fn expectClipboard(ui: *Ui, target: events.ClipTarget, text: []const u8) !void {
    const fx = try ui.takeEffects();
    defer ui.freeEffects(fx);
    for (fx) |e| switch (e) {
        .set_clipboard => |c| if (c.target == target) {
            try testing.expectEqualStrings(text, c.text);
            return;
        },
        else => {},
    };
    return error.NoClipboardEffect;
}

fn drag(ui: *Ui, term: *const Terminal, c0: i32, r0: i32, c1: i32, r1: i32, mods: input.Mods, t: i64) !void {
    _ = try ui.handleMouse(term, mouse(.press, .left, c0, r0, mods), CW, CH, t);
    _ = try ui.handleMouse(term, mouse(.motion, .left, c1, r1, mods), CW, CH, t);
    _ = try ui.handleMouse(term, mouse(.release, .left, c1, r1, mods), CW, CH, t);
}

test "drag selects and copies to PRIMARY; copy action uses CLIPBOARD" {
    var term = try Terminal.initBuffer(testing.allocator, 3, 20, 10);
    defer term.deinit();
    try term.processOutput("hello world\r\nsecond");
    var ui = Ui.init(testing.allocator, .{});
    defer ui.deinit();
    try drag(&ui, &term, 6, 0, 2, 1, .{}, 0);
    try expectClipboard(&ui, .primary, "world\nsec");
    try testing.expect(try ui.handleAction(&term, .copy));
    try expectClipboard(&ui, .clipboard, "world\nsec");
}

test "copy-on-select also sets CLIPBOARD; plain click clears" {
    var term = try Terminal.initBuffer(testing.allocator, 2, 20, 10);
    defer term.deinit();
    try term.processOutput("abc def");
    var ui = Ui.init(testing.allocator, .{ .copy_on_select = true });
    defer ui.deinit();
    try drag(&ui, &term, 0, 0, 2, 0, .{}, 0);
    try expectClipboard(&ui, .clipboard, "abc");
    try drag(&ui, &term, 5, 0, 5, 0, .{}, 5000);
    try testing.expect(ui.sel == null);
}

test "double-click word, triple-click line, shift-click extends, alt-drag block" {
    var term = try Terminal.initBuffer(testing.allocator, 3, 20, 10);
    defer term.deinit();
    try term.processOutput("ls /usr/bin -la\r\nxy 12345\r\nabcdefgh");
    var ui = Ui.init(testing.allocator, .{});
    defer ui.deinit();
    // Double click on "usr".
    try drag(&ui, &term, 5, 0, 5, 0, .{}, 1000);
    try drag(&ui, &term, 5, 0, 5, 0, .{}, 1100);
    try expectClipboard(&ui, .primary, "/usr/bin");
    // Third click: whole line.
    try drag(&ui, &term, 5, 0, 5, 0, .{}, 1200);
    try expectClipboard(&ui, .primary, "ls /usr/bin -la");
    // Shift-click on row 1 extends the line selection.
    try drag(&ui, &term, 4, 1, 4, 1, .{ .shift = true }, 5000);
    try expectClipboard(&ui, .primary, "ls /usr/bin -la\nxy 12345");
    // Alt-drag: rectangle.
    try drag(&ui, &term, 1, 1, 3, 2, .{ .alt = true }, 9000);
    try expectClipboard(&ui, .primary, "y 1\nbcd");
}

test "mouse reporting gets clicks unless Shift is held" {
    var term = try Terminal.initBuffer(testing.allocator, 2, 20, 10);
    defer term.deinit();
    try term.processOutput("\x1b[?1000hhello");
    var ui = Ui.init(testing.allocator, .{});
    defer ui.deinit();
    try testing.expect(!try ui.handleMouse(&term, mouse(.press, .left, 0, 0, .{}), CW, CH, 0));
    try drag(&ui, &term, 0, 0, 4, 0, .{ .shift = true }, 0);
    try expectClipboard(&ui, .primary, "hello");
}

test "wheel scrolls history and a selection survives new output" {
    var term = try Terminal.initBuffer(testing.allocator, 3, 10, 100);
    defer term.deinit();
    var ui = Ui.init(testing.allocator, .{});
    defer ui.deinit();
    for (0..10) |i| {
        var buf: [16]u8 = undefined;
        try term.processOutput(try std.fmt.bufPrint(&buf, "line{d}\r\n", .{i}));
    }
    ui.sync(&term);
    try testing.expect(try ui.handleMouse(&term, mouse(.press, .wheel_up, 0, 0, .{}), CW, CH, 0));
    try testing.expectEqual(@as(usize, 3), ui.scroll);
    // Select "line5" in the scrolled view (top row = line 5).
    try testing.expectEqual(@as(i64, 5), ui.viewTop(&term));
    try drag(&ui, &term, 0, 0, 4, 0, .{}, 0);
    try expectClipboard(&ui, .primary, "line5");
    // More output: the view stays on the same lines, selection too.
    try term.processOutput("more\r\nmore\r\n");
    ui.sync(&term);
    try testing.expectEqual(@as(usize, 5), ui.scroll);
    try testing.expectEqual(@as(i64, 5), ui.viewTop(&term));
    try testing.expect(try ui.handleAction(&term, .copy));
    try expectClipboard(&ui, .clipboard, "line5");
    // Shift+End / typing returns to the live screen.
    try testing.expect(try ui.handleAction(&term, .scroll_bottom));
    try testing.expectEqual(@as(usize, 0), ui.scroll);
    try testing.expect(try ui.handleAction(&term, .scroll_top));
    try testing.expectEqual(term.scrollback.len(), ui.scroll);
    _ = ui.userTyped();
    try testing.expectEqual(@as(usize, 0), ui.scroll);
}

test "scroll actions are forwarded in the alternate screen" {
    var term = try Terminal.initBuffer(testing.allocator, 2, 10, 10);
    defer term.deinit();
    try term.processOutput("\x1b[?1049h");
    var ui = Ui.init(testing.allocator, .{});
    defer ui.deinit();
    try testing.expect(!try ui.handleAction(&term, .scroll_page_up));
    try testing.expect(!try ui.handleMouse(&term, mouse(.press, .wheel_up, 0, 0, .{}), CW, CH, 0));
}

test "paste: bracketed when enabled, prompt for multi-line otherwise" {
    var term = try Terminal.initBuffer(testing.allocator, 2, 40, 10);
    defer term.deinit();
    var ui = Ui.init(testing.allocator, .{});
    defer ui.deinit();
    // Single line goes straight through.
    try ui.onPaste(&term, "echo hi", .clipboard, .paste);
    var fx = try ui.takeEffects();
    try testing.expectEqualStrings("echo hi", fx[0].write);
    ui.freeEffects(fx);
    // Multi-line without bracketed paste: held for confirmation.
    try ui.onPaste(&term, "rm -rf x\nls\n", .clipboard, .paste);
    try testing.expect(ui.prompt != null);
    try testing.expectEqual(@as(usize, 0), ui.effects.items.len);
    try testing.expect(try ui.handleText(&term, "n"));
    try testing.expect(ui.prompt == null);
    try ui.onPaste(&term, "a\nb", .clipboard, .paste);
    try testing.expect(try ui.handleKey(&term, .enter, .{}));
    fx = try ui.takeEffects();
    try testing.expectEqualStrings("a\rb", fx[0].write);
    ui.freeEffects(fx);
    // Bracketed paste: no prompt, wrapped, end marker stripped.
    try term.processOutput("\x1b[?2004h");
    try ui.onPaste(&term, "x\n\x1b[201~y", .primary, .paste);
    fx = try ui.takeEffects();
    try testing.expectEqualStrings("\x1b[200~x\ry\x1b[201~", fx[0].write);
    ui.freeEffects(fx);
    // Middle click requests PRIMARY.
    _ = try ui.handleMouse(&term, mouse(.press, .middle, 0, 0, .{}), CW, CH, 0);
    fx = try ui.takeEffects();
    try testing.expectEqual(events.ClipTarget.primary, fx[0].request_paste.target);
    ui.freeEffects(fx);
}

test "OSC 52 policy" {
    var term = try Terminal.initBuffer(testing.allocator, 2, 10, 10);
    defer term.deinit();
    try term.processOutput("\x1b]52;c;aGk=\x07\x1b]52;c;?\x07");
    const ops = try term.takeClipboardOps();
    defer term.freeClipboardOps(ops);

    var w = Ui.init(testing.allocator, .{ .osc52 = .write });
    defer w.deinit();
    try w.onClipboardOps(ops);
    try testing.expectEqual(@as(usize, 1), w.effects.items.len); // query ignored
    try testing.expectEqualStrings("hi", w.effects.items[0].set_clipboard.text);

    var off = Ui.init(testing.allocator, .{ .osc52 = .off });
    defer off.deinit();
    try off.onClipboardOps(ops);
    try testing.expectEqual(@as(usize, 0), off.effects.items.len);

    var rw = Ui.init(testing.allocator, .{ .osc52 = .read_write });
    defer rw.deinit();
    try rw.onClipboardOps(ops);
    try testing.expectEqual(events.PastePurpose.osc52, rw.effects.items[1].request_paste.purpose);
    try rw.onPaste(&term, "yo", .clipboard, .osc52);
    try testing.expectEqualStrings("\x1b]52;c;eW8=\x1b\\", rw.effects.items[2].write);
}

test "search overlay: incremental, next/prev, case toggle, highlights" {
    var term = try Terminal.initBuffer(testing.allocator, 3, 20, 100);
    defer term.deinit();
    try term.processOutput("Alpha one\r\nbeta\r\nalpha two\r\ngamma\r\nALPHA three\r\nend");
    var ui = Ui.init(testing.allocator, .{});
    defer ui.deinit();
    ui.sync(&term);
    try testing.expect(try ui.handleAction(&term, .search));
    try testing.expect(try ui.handleText(&term, "alp"));
    try testing.expect(try ui.handleText(&term, "ha"));
    try testing.expectEqual(@as(usize, 3), ui.matchCount());
    // Current = newest match visible (line 4, "ALPHA three").
    try testing.expectEqual(@as(?usize, 2), ui.search.?.current);
    _ = try ui.handleKey(&term, .enter, .{}); // older
    try testing.expectEqual(@as(?usize, 1), ui.search.?.current);
    _ = try ui.handleKey(&term, .enter, .{}); // older -> line 0, scrolls back
    try testing.expectEqual(@as(?usize, 0), ui.search.?.current);
    try testing.expect(ui.viewTop(&term) <= 0);
    _ = try ui.handleKey(&term, .enter, .{ .shift = true }); // newer
    try testing.expectEqual(@as(?usize, 1), ui.search.?.current);
    // Case-sensitive: only "alpha two".
    try testing.expect(try ui.handleText(&term, "\x1bc"));
    try testing.expectEqual(@as(usize, 1), ui.matchCount());
    // Compose marks the match and draws the bar on the last row.
    var cells = std.ArrayList(Cell).init(testing.allocator);
    defer cells.deinit();
    var marks = std.ArrayList(Mark).init(testing.allocator);
    defer marks.deinit();
    const v = try ui.compose(&term, &cells, &marks);
    _ = v;
    var found = false;
    for (marks.items) |m| found = found or m == .current_match;
    try testing.expect(found);
    try testing.expectEqual(@as(u21, 'F'), cells.items[2 * 20 + 1].char);
    // Backspace and escape.
    _ = try ui.handleKey(&term, .backspace, .{});
    try testing.expectEqualStrings("alph", ui.search.?.query.items);
    _ = try ui.handleKey(&term, .escape, .{});
    try testing.expect(!ui.overlayActive());
}

test "compose shows history rows when scrolled and offsets the cursor" {
    var term = try Terminal.initBuffer(testing.allocator, 2, 6, 10);
    defer term.deinit();
    try term.processOutput("one\r\ntwo\r\nthree");
    var ui = Ui.init(testing.allocator, .{});
    defer ui.deinit();
    ui.sync(&term);
    ui.scrollBy(&term, 1);
    var cells = std.ArrayList(Cell).init(testing.allocator);
    defer cells.deinit();
    var marks = std.ArrayList(Mark).init(testing.allocator);
    defer marks.deinit();
    const v = try ui.compose(&term, &cells, &marks);
    try testing.expectEqual(@as(u21, 'o'), cells.items[0].char);
    try testing.expectEqual(@as(u21, 't'), cells.items[6].char);
    try testing.expect(!v.cursor_visible); // cursor row 1 + 1 scrolled = off screen
    try testing.expect(v.scrollbar != null);
}

test "ctrl+click opens allowlisted URLs and OSC 8 targets only" {
    var term = try Terminal.initBuffer(testing.allocator, 2, 40, 10);
    defer term.deinit();
    try term.processOutput("go https://ziglang.org/x now\r\n\x1b]8;;https://example.com\x07link\x1b]8;;\x07 \x1b]8;;javascript:x\x07bad\x1b]8;;\x07");
    var ui = Ui.init(testing.allocator, .{});
    defer ui.deinit();
    _ = try ui.handleMouse(&term, mouse(.press, .left, 8, 0, .{ .ctrl = true }), CW, CH, 0);
    _ = try ui.handleMouse(&term, mouse(.press, .left, 1, 1, .{ .ctrl = true }), CW, CH, 0);
    _ = try ui.handleMouse(&term, mouse(.press, .left, 6, 1, .{ .ctrl = true }), CW, CH, 0);
    const fx = try ui.takeEffects();
    defer ui.freeEffects(fx);
    try testing.expectEqual(@as(usize, 2), fx.len);
    try testing.expectEqualStrings("https://ziglang.org/x", fx[0].open_url);
    try testing.expectEqualStrings("https://example.com", fx[1].open_url);
}

test "selection clears when output overwrites the selected text" {
    var term = try Terminal.initBuffer(testing.allocator, 3, 20, 10);
    defer term.deinit();
    try term.processOutput("keep this\r\nother");
    var ui = Ui.init(testing.allocator, .{});
    defer ui.deinit();
    ui.sync(&term);
    try drag(&ui, &term, 0, 0, 3, 0, .{}, 0);
    try expectClipboard(&ui, .primary, "keep");
    // Output elsewhere leaves it alone.
    try term.processOutput(" more");
    ui.sync(&term);
    try testing.expect(ui.sel != null);
    // Rewriting the selected cells clears it.
    try term.processOutput("\x1b[1;1HKEEP");
    ui.sync(&term);
    try testing.expect(ui.sel == null);
}

test "selection survives scrolling but not a reflowing resize" {
    var term = try Terminal.initBuffer(testing.allocator, 3, 20, 10);
    defer term.deinit();
    try term.processOutput("word one\r\n");
    var ui = Ui.init(testing.allocator, .{});
    defer ui.deinit();
    ui.sync(&term);
    try drag(&ui, &term, 0, 0, 3, 0, .{}, 0);
    try term.processOutput("a\r\nb\r\nc\r\n");
    ui.sync(&term);
    try testing.expect(ui.sel != null); // scrolled into history, same text
    try term.resize(3, 10);
    ui.sync(&term);
    try testing.expect(ui.sel == null);
}

test "search refreshes on new output and matches across wraps" {
    var term = try Terminal.initBuffer(testing.allocator, 4, 10, 100);
    defer term.deinit();
    try term.processOutput("needle\r\n");
    var ui = Ui.init(testing.allocator, .{});
    defer ui.deinit();
    ui.sync(&term);
    _ = try ui.handleAction(&term, .search);
    _ = try ui.handleText(&term, "needle");
    try testing.expectEqual(@as(usize, 1), ui.matchCount());
    // New output: a wrapped match ("xxxxxneedle" wraps at 10 cols).
    try term.processOutput("xxxxxneedle\r\n");
    ui.sync(&term);
    try testing.expectEqual(@as(usize, 2), ui.matchCount());
    const m = ui.search.?.matches.items[1];
    try testing.expect(m.end_line == m.line + 1);
    // Lots more output scrolls the first match into history; it stays.
    for (0..6) |_| try term.processOutput("filler\r\n");
    ui.sync(&term);
    try testing.expectEqual(@as(usize, 2), ui.matchCount());
    // A new match on the screen is picked up.
    try term.processOutput("needle\r\n");
    ui.sync(&term);
    try testing.expectEqual(@as(usize, 3), ui.matchCount());
    // Both halves of the wrapped match are highlighted when visible.
    ui.scroll = 0;
    ui.ensureVisible(&term, m.line);
    var cells = std.ArrayList(Cell).init(testing.allocator);
    defer cells.deinit();
    var marks = std.ArrayList(Mark).init(testing.allocator);
    defer marks.deinit();
    _ = try ui.compose(&term, &cells, &marks);
    const top = ui.viewTop(&term);
    if (m.line >= top and m.end_line < top + term.rows - 1) {
        const r0: usize = @intCast(m.line - top);
        try testing.expect(marks.items[r0 * 10 + 9] != .none);
        try testing.expect(marks.items[(r0 + 1) * 10 + 0] != .none);
    }
}

test "search bar does not hide the prompt on the last row" {
    var term = try Terminal.initBuffer(testing.allocator, 3, 20, 10);
    defer term.deinit();
    try term.processOutput("a\r\nb\r\n$ prompt");
    var ui = Ui.init(testing.allocator, .{});
    defer ui.deinit();
    ui.sync(&term);
    _ = try ui.handleAction(&term, .search);
    var cells = std.ArrayList(Cell).init(testing.allocator);
    defer cells.deinit();
    var marks = std.ArrayList(Mark).init(testing.allocator);
    defer marks.deinit();
    const v = try ui.compose(&term, &cells, &marks);
    // Row 1 now shows the prompt; the bar is on row 2.
    try testing.expectEqual(@as(u21, '$'), cells.items[20].char);
    try testing.expectEqual(@as(u21, 'F'), cells.items[40 + 1].char);
    try testing.expectEqual(@as(u16, 1), v.cursor_row);
    try testing.expect(v.cursor_visible);
    _ = try ui.handleKey(&term, .escape, .{});
    const w = try ui.compose(&term, &cells, &marks);
    try testing.expectEqual(@as(u16, 2), w.cursor_row);
    // With free rows below the prompt nothing moves.
    try term.processOutput("\x1b[2J\x1b[H$ top");
    _ = try ui.handleAction(&term, .search);
    const x = try ui.compose(&term, &cells, &marks);
    try testing.expectEqual(@as(u21, '$'), cells.items[0].char);
    try testing.expectEqual(@as(u16, 0), x.cursor_row);
}

test "notice bar: top rows, overflow line, Esc dismisses, expiry" {
    var term = try Terminal.initBuffer(testing.allocator, 8, 60, 10);
    defer term.deinit();
    var ui = Ui.init(testing.allocator, .{});
    defer ui.deinit();
    const details = [_][]const u8{ "a.lua:1: one", "a.lua:2: two", "a.lua:3: three", "a.lua:4: four", "a.lua:5: five", "a.lua:6: six" };
    try ui.setNotice(.err, "config: 6 errors", &details, null, 0);
    var cells = std.ArrayList(Cell).init(testing.allocator);
    defer cells.deinit();
    var marks = std.ArrayList(Mark).init(testing.allocator);
    defer marks.deinit();
    const out = try ui.compose(&term, &cells, &marks);
    // Room below: the (empty) screen moves down under the notice.
    try testing.expect(out.cursor_visible);
    try testing.expectEqual(@as(u16, 6), out.cursor_row);
    try testing.expectEqual(@as(u21, 'c'), cells.items[0].char);
    try testing.expectEqual(@as(u32, 0x8B0000), cells.items[0].bg_color);
    // Headline + 4 details + "... and 2 more".
    try testing.expectEqual(@as(u21, 'a'), cells.items[60 * 1 + 2].char);
    try testing.expectEqual(@as(u21, 0x2026), cells.items[60 * 5 + 2].char);
    try testing.expect(cells.items[60 * 6].bg_color != 0x8B0000);
    // A long line wraps onto an indented continuation row.
    const long = [_][]const u8{"x" ** 100};
    try ui.setNotice(.warning, "w", &long, null, 0);
    _ = try ui.compose(&term, &cells, &marks);
    try testing.expectEqual(@as(u21, 'x'), cells.items[60 * 1 + 59].char);
    try testing.expectEqual(@as(u21, ' '), cells.items[60 * 2 + 0].char);
    try testing.expectEqual(@as(u21, 'x'), cells.items[60 * 2 + 6].char);
    try testing.expect(cells.items[60 * 4].bg_color != 0xD7AF00);
    try testing.expect(try ui.handleKey(&term, .escape, .{}));
    try testing.expect(ui.notice == null);
    try testing.expect(!try ui.handleKey(&term, .escape, .{}));

    // On a fresh screen the view moves down so the prompt stays visible.
    try term.processOutput("$ ");
    try ui.setNotice(.err, "config: 1 error", &details[0..1].*, null, 0);
    const shifted = try ui.compose(&term, &cells, &marks);
    try testing.expect(shifted.cursor_visible);
    try testing.expectEqual(@as(u16, 2), shifted.cursor_row);
    try testing.expectEqual(@as(u21, '$'), cells.items[60 * 2].char);
    ui.clearNotice();

    try ui.setNotice(.info, "config reloaded", &.{}, 1000, 0);
    try testing.expectEqual(@as(i64, 400), ui.noticeTimeout(600).?);
    try testing.expect(!ui.tickNotice(999));
    try testing.expect(ui.tickNotice(1000));
    try testing.expect(ui.notice == null);
}
