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
};

pub const Composed = struct {
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
    prompt: ?Prompt = null,
    effects: std.ArrayList(Effect),
    last_total: u64 = 0,
    last_alt: bool = false,

    pub fn init(allocator: std.mem.Allocator, opts: Options) Ui {
        return .{ .allocator = allocator, .opts = opts, .effects = std.ArrayList(Effect).init(allocator) };
    }

    pub fn deinit(self: *Ui) void {
        self.closeSearch();
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
        };
        if (list.ptr != self.effects.items.ptr) self.allocator.free(list);
    }

    fn pushWrite(self: *Ui, bytes: []const u8) !void {
        try self.effects.append(.{ .write = try self.allocator.dupe(u8, bytes) });
    }

    // ------------------------------------------------------------ viewport

    pub fn viewTop(self: *const Ui, term: *const Terminal) i64 {
        return term.screenTop() - @as(i64, @intCast(self.scroll));
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
        }
        if (self.sel) |s| {
            if (s.ordered().start.line < term.historyTop() and s.ordered().end.line < term.historyTop()) self.sel = null;
        }
    }

    /// The user typed something for the shell: return to the live screen.
    pub fn userTyped(self: *Ui) void {
        self.scroll = 0;
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
                try self.copySelection(term);
            },
            .clear_selection => self.sel = null,
            .none, .zoom_in, .zoom_out, .zoom_reset => return false,
        }
        return true;
    }

    // ------------------------------------------------------------ paste

    /// Clipboard contents arrived (see `Effect.request_paste`).
    pub fn onPaste(self: *Ui, term: *const Terminal, data: []const u8, target: events.ClipTarget, purpose: events.PastePurpose) !void {
        switch (purpose) {
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
        if (self.prompt != null) {
            if (bytes.len == 1) switch (bytes[0]) {
                'y', 'Y', '\r' => try self.answerPrompt(true),
                'n', 'N', 0x03, 0x1b => try self.answerPrompt(false),
                else => {},
            };
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
        if (self.prompt != null) {
            switch (key) {
                .enter, .kp_enter => try self.answerPrompt(true),
                .escape => try self.answerPrompt(false),
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
        return false;
    }

    pub fn overlayActive(self: *const Ui) bool {
        return self.prompt != null or self.search != null;
    }

    // ------------------------------------------------------------ search

    fn openSearch(self: *Ui, term: *const Terminal) !void {
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

    fn recomputeSearch(self: *Ui, term: *const Terminal) !void {
        const st = &(self.search orelse return);
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
                if (m.line < top or m.line >= top + rows) continue;
                const row: usize = @intCast(m.line - top);
                const mk: Mark = if (st.current != null and st.current.? == i) .current_match else .match;
                var c = m.start;
                while (c <= m.end and c < cols) : (c += 1) marks.items[row * cols + c] = mk;
            }
        }

        var out = Composed{
            .cursor_row = term.cursor_row + @as(u16, @intCast(@min(self.scroll, rows))),
            .cursor_col = term.cursor_col,
            .cursor_visible = term.cursor_visible and self.scroll < rows and @as(usize, term.cursor_row) + self.scroll < rows,
        };
        if (self.opts.scrollbar and self.scroll > 0) {
            const hist: f32 = @floatFromInt(term.scrollback.len());
            const total = hist + @as(f32, @floatFromInt(rows));
            out.scrollbar = .{
                .top = (hist - @as(f32, @floatFromInt(self.scroll))) / total,
                .height = @as(f32, @floatFromInt(rows)) / total,
            };
        }

        if (self.overlayActive() and rows > 0) {
            const bar = cells.items[@as(usize, rows - 1) * cols ..][0..cols];
            const bar_marks = marks.items[@as(usize, rows - 1) * cols ..][0..cols];
            @memset(bar_marks, .none);
            try self.drawBar(bar);
            if (out.cursor_row == rows - 1) out.cursor_visible = false;
        }
        return out;
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
        var cell = Cell.init();
        cell.fg_color = fg;
        cell.bg_color = bg;
        @memset(bar, cell);
        const unicode = @import("../terminal/unicode.zig");
        var col: usize = 0;
        var it = (std.unicode.Utf8View.init(text.items) catch return).iterator();
        while (it.nextCodepoint()) |cp| {
            const w = unicode.width(cp);
            if (w == 0) continue;
            if (col + w > bar.len) break;
            bar[col].char = cp;
            bar[col].width = @intCast(w);
            if (w == 2) bar[col + 1].width = 0;
            col += w;
        }
    }
};

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
    ui.userTyped();
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
