//! Terminal emulator core: screen grid, cursor, modes, and the
//! interpretation of parser actions (xterm-compatible subset).

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const ansi_parser = @import("ansi_parser.zig");
const unicode = @import("unicode.zig");
const color = @import("color.zig");
const scrollback_mod = @import("scrollback.zig");
const pty_mod = @import("pty.zig");

pub const PTY = pty_mod.PTY;
const CSIParams = ansi_parser.CSIParams;

/// Cell represents a single character cell in the terminal
pub const Cell = struct {
    char: u21, // Unicode codepoint
    fg_color: u32,
    bg_color: u32,
    bold: bool,
    italic: bool,
    underline: bool,
    faint: bool = false,
    blink: bool = false,
    inverse: bool = false,
    hidden: bool = false,
    strikethrough: bool = false,
    /// Columns this cell's glyph covers: 1 normally, 2 for the leading half
    /// of a wide character, 0 for the trailing spacer of a wide character
    /// (spacers hold ' ' so renderers that ignore `width` draw a blank).
    width: u2 = 1,
    /// Combining marks attached to `char` (0 = empty slot). Extra marks
    /// beyond the slots are dropped.
    combining: [max_combining]u21 = .{0} ** max_combining,
    /// OSC 8 hyperlink: 0 = none, otherwise index+1 into `Terminal.links`.
    link: u16 = 0,
    /// Underline style when `underline` is set (SGR 4:n / 21).
    underline_style: UnderlineStyle = .single,
    /// SGR 58 underline colour, or `color.none` to use the foreground.
    underline_color: u32 = color.none,
    /// Set on a row's last cell when the text auto-wrapped onto the next
    /// row, so selection/search/URLs can join the two rows.
    soft_wrap: bool = false,

    pub const max_combining = 2;

    pub fn init() Cell {
        return Cell{
            .char = ' ',
            .fg_color = color.default_fg,
            .bg_color = color.default_bg,
            .bold = false,
            .italic = false,
            .underline = false,
        };
    }

    pub fn isSpacer(self: Cell) bool {
        return self.width == 0;
    }

    /// Final colors after inverse / faint / hidden are applied.
    pub fn resolvedColors(self: Cell) struct { fg: u32, bg: u32 } {
        var fg = self.fg_color;
        var bg = self.bg_color;
        if (self.faint) fg = color.dim(fg);
        if (self.inverse) {
            const t = fg;
            fg = bg;
            bg = t;
        }
        if (self.hidden) fg = bg;
        return .{ .fg = fg, .bg = bg };
    }

    /// Append `char` and its combining marks to `writer` as UTF-8.
    pub fn writeUtf8(self: Cell, writer: anytype) !void {
        try writeCodepoint(writer, self.char);
        for (self.combining) |cp| {
            if (cp == 0) break;
            try writeCodepoint(writer, cp);
        }
    }
};

fn writeCodepoint(writer: anytype, cp: u21) !void {
    if (cp < 0x20 or cp == 0x7F) return writer.writeByte(' ');
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch return writer.writeAll("\u{FFFD}");
    try writer.writeAll(buf[0..n]);
}

pub const UnderlineStyle = enum(u3) { single, double, curly, dotted, dashed };

/// Current graphic rendition ("pen") applied to newly written cells.
pub const Pen = struct {
    fg: u32 = color.default_fg,
    bg: u32 = color.default_bg,
    bold: bool = false,
    faint: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    inverse: bool = false,
    hidden: bool = false,
    strikethrough: bool = false,
    link: u16 = 0,
    underline_style: UnderlineStyle = .single,
    underline_color: u32 = color.none,
};

pub const CursorShape = enum { block, underline, bar };

pub const MouseTracking = enum {
    off,
    /// ?9: press only
    x10,
    /// ?1000: press + release
    normal,
    /// ?1002: + motion while a button is held
    button,
    /// ?1003: + all motion
    any,
};

pub const Charset = enum { ascii, dec_special };

pub const Modes = struct {
    /// DECCKM: cursor keys send ESC O x
    app_cursor: bool = false,
    /// DECKPAM: keypad sends application sequences
    app_keypad: bool = false,
    /// DECOM: cursor addressing relative to the scroll region
    origin: bool = false,
    /// DECAWM
    autowrap: bool = true,
    /// IRM
    insert: bool = false,
    /// LNM: LF also returns the carriage
    newline: bool = false,
    bracketed_paste: bool = false,
    mouse: MouseTracking = .off,
    /// ?1006 SGR mouse encoding
    mouse_sgr: bool = false,
    /// ?1004
    focus_events: bool = false,
    /// DECSCNM
    reverse_video: bool = false,
    cursor_blink: bool = false,
};

pub const ClipboardTargets = packed struct {
    clipboard: bool = false,
    primary: bool = false,

    /// OSC 52 Pc: 'c' clipboard, 'p'/'s' primary/selection; empty = "s0"
    /// which xterm maps to the clipboard for most setups.
    pub fn parse(pc: []const u8) ClipboardTargets {
        var t = ClipboardTargets{};
        for (pc) |b| switch (b) {
            'c' => t.clipboard = true,
            'p', 's' => t.primary = true,
            else => {},
        };
        if (!t.clipboard and !t.primary) t.clipboard = true;
        return t;
    }
};

pub const ClipboardOp = union(enum) {
    set: struct { targets: ClipboardTargets, data: []u8 },
    query: ClipboardTargets,
};

const SavedCursor = struct {
    row: u16 = 0,
    col: u16 = 0,
    wrap_pending: bool = false,
    pen: Pen = .{},
    origin: bool = false,
    charsets: [2]Charset = .{ .ascii, .ascii },
    gl: u1 = 0,
};

const MAX_LINKS = 4096;
const MAX_LINK_LEN = 2048;
const MAX_TITLE_LEN = 1024;

/// Terminal represents the core terminal emulator functionality
pub const Terminal = struct {
    allocator: std.mem.Allocator,
    rows: u16,
    cols: u16,
    /// Active screen (points at `primary` or `alt`).
    buffer: []Cell,
    primary: []Cell,
    alt: []Cell,
    alt_active: bool = false,
    cursor_row: u16 = 0,
    cursor_col: u16 = 0,
    /// Set after writing the last column with autowrap on; the next printable
    /// character wraps first (xterm "pending wrap").
    wrap_pending: bool = false,
    pen: Pen = .{},
    saved: [2]SavedCursor = .{ .{}, .{} },
    scroll_top: u16 = 0,
    scroll_bottom: u16,
    tabs: []bool,
    modes: Modes = .{},
    charsets: [2]Charset = .{ .ascii, .ascii },
    gl: u1 = 0,
    last_char: u21 = 0,
    pty: ?PTY = null,
    parser: ansi_parser.Parser,
    scrollback: scrollback_mod.Scrollback,
    initialized: bool,
    title: []u8,
    title_changed: bool = false,
    /// Working directory reported by the shell via OSC 7 (file:// URI).
    cwd_uri: []u8,
    cursor_visible: bool = true,
    cursor_shape: CursorShape = .block,
    bell: bool = false,
    /// Bytes to send back to the application (DA, DSR, ...).
    replies: std.ArrayList(u8),
    /// OSC 8 hyperlink targets, referenced by `Cell.link`.
    links: std.ArrayList([]u8),
    /// OSC 52 requests waiting for the front end (which applies the
    /// configured policy).
    clipboard_ops: std.ArrayList(ClipboardOp),

    pub fn init(allocator: std.mem.Allocator) !Terminal {
        return initWithSize(allocator, 24, 80, 10_000);
    }

    /// Terminal without a PTY (tests, headless replays).
    pub fn initBuffer(allocator: std.mem.Allocator, rows_in: u16, cols_in: u16, scrollback_lines: usize) !Terminal {
        const rows = @max(rows_in, 1);
        const cols = @max(cols_in, 1);
        const primary = try allocator.alloc(Cell, @as(usize, rows) * cols);
        errdefer allocator.free(primary);
        const alt = try allocator.alloc(Cell, @as(usize, rows) * cols);
        errdefer allocator.free(alt);
        @memset(primary, Cell.init());
        @memset(alt, Cell.init());
        const tabs = try allocator.alloc(bool, cols);
        errdefer allocator.free(tabs);
        resetTabs(tabs);

        const title = try allocator.dupe(u8, "DeathTerminal");
        errdefer allocator.free(title);
        const cwd = try allocator.alloc(u8, 0);

        return Terminal{
            .allocator = allocator,
            .rows = rows,
            .cols = cols,
            .buffer = primary,
            .primary = primary,
            .alt = alt,
            .scroll_bottom = rows - 1,
            .tabs = tabs,
            .parser = ansi_parser.Parser.init(allocator),
            .scrollback = scrollback_mod.Scrollback.init(allocator, scrollback_lines),
            .initialized = true,
            .title = title,
            .cwd_uri = cwd,
            .replies = std.ArrayList(u8).init(allocator),
            .links = std.ArrayList([]u8).init(allocator),
            .clipboard_ops = std.ArrayList(ClipboardOp).init(allocator),
        };
    }

    pub fn initWithSize(allocator: std.mem.Allocator, rows: u16, cols: u16, scrollback_lines: usize) !Terminal {
        std.debug.print("  → Initializing terminal core...\n", .{});

        var term = try initBuffer(allocator, rows, cols, scrollback_lines);
        errdefer term.deinit();

        var pty = try PTY.open();
        errdefer pty.close();
        try pty.setWindowSize(rows, cols);
        try pty.spawnShell(allocator);
        term.pty = pty;

        std.debug.print("  → Terminal core initialized ({d}x{d}, TERM=xterm-256color)\n", .{ cols, rows });
        return term;
    }

    pub fn deinit(self: *Terminal) void {
        self.parser.deinit();
        self.scrollback.deinit();
        self.allocator.free(self.primary);
        self.allocator.free(self.alt);
        self.allocator.free(self.tabs);
        self.allocator.free(self.title);
        self.allocator.free(self.cwd_uri);
        self.replies.deinit();
        for (self.links.items) |l| self.allocator.free(l);
        self.links.deinit();
        for (self.clipboard_ops.items) |op| switch (op) {
            .set => |cs| self.allocator.free(cs.data),
            .query => {},
        };
        self.clipboard_ops.deinit();
        if (self.pty) |*pty| pty.close();
        self.initialized = false;
    }

    pub fn getPtyFd(self: *const Terminal) ?posix.fd_t {
        if (self.pty) |pty| return pty.master_fd;
        return null;
    }

    pub fn scrollbackLen(self: *const Terminal) usize {
        return self.scrollback.len();
    }

    pub fn write(self: *Terminal, data: []const u8) !void {
        if (self.pty) |pty| {
            var off: usize = 0;
            while (off < data.len) {
                const n = pty.write(data[off..]) catch |err| switch (err) {
                    error.WouldBlock => {
                        var fds = [_]posix.pollfd{.{ .fd = pty.master_fd, .events = posix.POLL.OUT, .revents = 0 }};
                        _ = posix.poll(&fds, 100) catch {};
                        continue;
                    },
                    else => return err,
                };
                off += n;
            }
        }
    }

    pub fn read(self: *Terminal, buffer: []u8) !usize {
        if (self.pty) |pty| return try pty.read(buffer);
        return 0;
    }

    // ------------------------------------------------------------ grid access

    fn cellIndex(self: *const Terminal, row: u16, col: u16) usize {
        return @as(usize, row) * @as(usize, self.cols) + col;
    }

    pub fn getCell(self: *Terminal, row: u16, col: u16) ?*Cell {
        if (row >= self.rows or col >= self.cols) return null;
        return &self.buffer[self.cellIndex(row, col)];
    }

    pub fn setCell(self: *Terminal, row: u16, col: u16, cell: Cell) void {
        if (row >= self.rows or col >= self.cols) return;
        self.buffer[self.cellIndex(row, col)] = cell;
    }

    fn rowSlice(self: *Terminal, row: u16) []Cell {
        const start = self.cellIndex(row, 0);
        return self.buffer[start .. start + self.cols];
    }

    /// Cell written by erase operations: blank with the current background
    /// (xterm "bce"), all other attributes default.
    fn eraseCell(self: *const Terminal) Cell {
        var cell = Cell.init();
        cell.bg_color = self.pen.bg;
        return cell;
    }

    fn penCell(self: *const Terminal, cp: u21) Cell {
        const p = self.pen;
        return Cell{
            .char = cp,
            .fg_color = p.fg,
            .bg_color = p.bg,
            .bold = p.bold,
            .italic = p.italic,
            .underline = p.underline,
            .faint = p.faint,
            .blink = p.blink,
            .inverse = p.inverse,
            .hidden = p.hidden,
            .strikethrough = p.strikethrough,
            .link = p.link,
            .underline_style = p.underline_style,
            .underline_color = p.underline_color,
        };
    }

    pub fn moveCursor(self: *Terminal, row: u16, col: u16) void {
        self.cursor_row = @min(row, self.rows - 1);
        self.cursor_col = @min(col, self.cols - 1);
        self.wrap_pending = false;
    }

    // ------------------------------------------------------------ output

    /// Process PTY output and update terminal state. Replies (DA, DSR, ...)
    /// are written back to the PTY when one is attached, otherwise they stay
    /// in `replies` for the caller.
    pub fn processOutput(self: *Terminal, data: []const u8) !void {
        for (data) |byte| {
            if (try self.parser.advance(byte)) |action| try self.handleAction(action);
            if (self.parser.takePending()) |action| try self.handleAction(action);
        }
        if (self.pty != null and self.replies.items.len > 0) {
            self.write(self.replies.items) catch {};
            self.replies.clearRetainingCapacity();
        }
    }

    fn reply(self: *Terminal, comptime fmt: []const u8, args: anytype) void {
        self.replies.writer().print(fmt, args) catch {};
    }

    pub fn handleAction(self: *Terminal, action: ansi_parser.Action) !void {
        switch (action) {
            .Print => |cp| try self.putChar(cp),
            .Execute => |byte| try self.execute(byte),
            .Esc => |e| try self.escDispatch(e.intermediate, e.final),
            .CSI => |c| try self.csiDispatch(c.params, c.final_byte),
            .OSC => |data| try self.oscDispatch(data),
        }
    }

    fn execute(self: *Terminal, byte: u8) !void {
        switch (byte) {
            0x07 => self.bell = true,
            0x08 => self.backspace(),
            0x09 => self.tabForward(1),
            0x0A, 0x0B, 0x0C => try self.newline(),
            0x0D => self.carriageReturn(),
            0x0E => self.gl = 1, // SO
            0x0F => self.gl = 0, // SI
            else => {},
        }
    }

    // ------------------------------------------------------------ printing

    fn translateCharset(self: *const Terminal, cp: u21) u21 {
        if (self.charsets[self.gl] != .dec_special) return cp;
        if (cp < 0x5F or cp > 0x7E) return cp;
        const table = [_]u21{
            0x00A0, 0x25C6, 0x2592, 0x2409, 0x240C, 0x240D, 0x240A, 0x00B0, // _ ` a b c d e f
            0x00B1, 0x2424, 0x240B, 0x2518, 0x2510, 0x250C, 0x2514, 0x253C, // g h i j k l m n
            0x23BA, 0x23BB, 0x2500, 0x23BC, 0x23BD, 0x251C, 0x2524, 0x2534, // o p q r s t u v
            0x252C, 0x2502, 0x2264, 0x2265, 0x03C0, 0x2260, 0x00A3, 0x00B7, // w x y z { | } ~
        };
        return table[cp - 0x5F];
    }

    pub fn putChar(self: *Terminal, ch: u21) !void {
        var cp = self.translateCharset(ch);
        var w: u16 = unicode.width(cp);
        if (w == 0) return self.attachCombining(cp);
        if (w == 2 and self.cols < 2) {
            cp = unicode.replacement_char;
            w = 1;
        }

        if (self.wrap_pending and self.modes.autowrap) {
            self.buffer[self.cellIndex(self.cursor_row, self.cols - 1)].soft_wrap = true;
            self.cursor_col = 0;
            try self.index();
        }
        self.wrap_pending = false;

        if (self.cursor_col + w > self.cols) {
            if (self.modes.autowrap) {
                // A wide char that doesn't fit in the last column: blank that
                // column and wrap, like xterm.
                self.breakWideAt(self.cursor_row, self.cursor_col);
                self.buffer[self.cellIndex(self.cursor_row, self.cursor_col)] = self.eraseCell();
                self.buffer[self.cellIndex(self.cursor_row, self.cols - 1)].soft_wrap = true;
                self.cursor_col = 0;
                try self.index();
            } else {
                self.cursor_col = self.cols - w;
            }
        }

        if (self.modes.insert) self.insertBlanks(w);

        const row = self.cursor_row;
        const col = self.cursor_col;
        self.breakWideAt(row, col);
        if (w == 2) self.breakWideAt(row, col + 1);

        var cell = self.penCell(cp);
        cell.width = @intCast(w);
        self.buffer[self.cellIndex(row, col)] = cell;
        if (w == 2) {
            var spacer = self.penCell(' ');
            spacer.width = 0;
            self.buffer[self.cellIndex(row, col + 1)] = spacer;
        }
        self.last_char = cp;

        if (col + w >= self.cols) {
            self.cursor_col = self.cols - 1;
            self.wrap_pending = self.modes.autowrap;
        } else {
            self.cursor_col = col + w;
        }
    }

    /// Before overwriting (row, col), dissolve any wide pair it belongs to
    /// so no orphaned half is left behind.
    fn breakWideAt(self: *Terminal, row: u16, col: u16) void {
        if (row >= self.rows or col >= self.cols) return;
        const cell = &self.buffer[self.cellIndex(row, col)];
        if (cell.width == 0 and col > 0) {
            const lead = &self.buffer[self.cellIndex(row, col - 1)];
            if (lead.width == 2) lead.* = blankLike(lead.*);
        } else if (cell.width == 2 and col + 1 < self.cols) {
            const spacer = &self.buffer[self.cellIndex(row, col + 1)];
            if (spacer.width == 0) spacer.* = blankLike(spacer.*);
        }
    }

    fn blankLike(cell: Cell) Cell {
        var out = cell;
        out.char = ' ';
        out.width = 1;
        out.combining = .{0} ** Cell.max_combining;
        return out;
    }

    /// Attach a zero-width codepoint to the previously written cell.
    fn attachCombining(self: *Terminal, cp: u21) void {
        var col: u16 = undefined;
        if (self.wrap_pending) {
            col = self.cursor_col;
        } else {
            if (self.cursor_col == 0) return; // nothing to combine with on this row
            col = self.cursor_col - 1;
        }
        if (self.buffer[self.cellIndex(self.cursor_row, col)].width == 0 and col > 0) col -= 1;
        const cell = &self.buffer[self.cellIndex(self.cursor_row, col)];
        for (&cell.combining) |*slot| {
            if (slot.* == 0) {
                slot.* = cp;
                return;
            }
        }
    }

    /// Repair wide pairs on one row after a bulk erase/move touched it.
    fn fixWideRow(self: *Terminal, row: u16) void {
        if (row >= self.rows) return;
        var col: u16 = 0;
        while (col < self.cols) : (col += 1) {
            const cell = &self.buffer[self.cellIndex(row, col)];
            if (cell.width == 2) {
                const ok = col + 1 < self.cols and self.buffer[self.cellIndex(row, col + 1)].width == 0;
                if (!ok) cell.* = blankLike(cell.*) else col += 1;
            } else if (cell.width == 0) {
                cell.* = blankLike(cell.*); // spacer without a lead
            }
        }
    }

    // ------------------------------------------------------------ cursor

    pub fn backspace(self: *Terminal) void {
        self.wrap_pending = false;
        if (self.cursor_col > 0) self.cursor_col -= 1;
    }

    pub fn carriageReturn(self: *Terminal) void {
        self.cursor_col = 0;
        self.wrap_pending = false;
    }

    /// LF / VT / FF.
    pub fn newline(self: *Terminal) !void {
        try self.index();
        if (self.modes.newline) self.cursor_col = 0;
    }

    /// Backwards-compatible alias for `newline`.
    pub fn lineFeed(self: *Terminal) !void {
        try self.newline();
    }

    /// IND: move down one line, scrolling the region at its bottom margin.
    pub fn index(self: *Terminal) !void {
        self.wrap_pending = false;
        if (self.cursor_row == self.scroll_bottom) {
            try self.scrollUp(1);
        } else if (self.cursor_row + 1 < self.rows) {
            self.cursor_row += 1;
        }
    }

    /// RI: move up one line, scrolling the region down at its top margin.
    pub fn reverseIndex(self: *Terminal) void {
        self.wrap_pending = false;
        if (self.cursor_row == self.scroll_top) {
            self.scrollDown(1);
        } else if (self.cursor_row > 0) {
            self.cursor_row -= 1;
        }
    }

    pub fn cursorUp(self: *Terminal, n: u32) void {
        const limit: u16 = if (self.cursor_row >= self.scroll_top) self.scroll_top else 0;
        const d: u16 = @intCast(@min(n, self.rows));
        self.cursor_row = if (self.cursor_row >= limit + d) self.cursor_row - d else limit;
        self.wrap_pending = false;
    }

    pub fn cursorDown(self: *Terminal, n: u32) void {
        const limit: u16 = if (self.cursor_row <= self.scroll_bottom) self.scroll_bottom else self.rows - 1;
        const d: u16 = @intCast(@min(n, self.rows));
        self.cursor_row = @min(self.cursor_row + d, limit);
        self.wrap_pending = false;
    }

    pub fn cursorForward(self: *Terminal, n: u32) void {
        const d: u16 = @intCast(@min(n, self.cols));
        self.cursor_col = @min(self.cursor_col + d, self.cols - 1);
        self.wrap_pending = false;
    }

    pub fn cursorBack(self: *Terminal, n: u32) void {
        const d: u16 = @intCast(@min(n, self.cols));
        self.cursor_col = if (self.cursor_col >= d) self.cursor_col - d else 0;
        self.wrap_pending = false;
    }

    /// CUP / HVP with 1-based coordinates, honoring origin mode.
    pub fn setCursorPos(self: *Terminal, row1: u32, col1: u32) void {
        var top: u32 = 0;
        var bottom: u32 = self.rows - 1;
        if (self.modes.origin) {
            top = self.scroll_top;
            bottom = self.scroll_bottom;
        }
        const r = @min(top + (@max(row1, 1) - 1), bottom);
        const c = @min(@max(col1, 1) - 1, self.cols - 1);
        self.cursor_row = @intCast(r);
        self.cursor_col = @intCast(c);
        self.wrap_pending = false;
    }

    fn setCursorRow(self: *Terminal, row1: u32) void {
        self.setCursorPos(row1, @as(u32, self.cursor_col) + 1);
    }

    fn setCursorCol(self: *Terminal, col1: u32) void {
        self.cursor_col = @intCast(@min(@max(col1, 1) - 1, self.cols - 1));
        self.wrap_pending = false;
    }

    pub fn saveCursor(self: *Terminal) void {
        self.saved[@intFromBool(self.alt_active)] = .{
            .row = self.cursor_row,
            .col = self.cursor_col,
            .wrap_pending = self.wrap_pending,
            .pen = self.pen,
            .origin = self.modes.origin,
            .charsets = self.charsets,
            .gl = self.gl,
        };
    }

    pub fn restoreCursor(self: *Terminal) void {
        const s = self.saved[@intFromBool(self.alt_active)];
        self.cursor_row = @min(s.row, self.rows - 1);
        self.cursor_col = @min(s.col, self.cols - 1);
        self.wrap_pending = s.wrap_pending;
        self.pen = s.pen;
        self.modes.origin = s.origin;
        self.charsets = s.charsets;
        self.gl = s.gl;
    }

    // ------------------------------------------------------------ tabs

    fn resetTabs(tabs: []bool) void {
        for (tabs, 0..) |*t, i| t.* = i % 8 == 0 and i != 0;
    }

    pub fn tabForward(self: *Terminal, n: u32) void {
        var left = n;
        while (left > 0 and self.cursor_col + 1 < self.cols) : (left -= 1) {
            var c = self.cursor_col + 1;
            while (c < self.cols - 1 and !self.tabs[c]) c += 1;
            self.cursor_col = c;
        }
        self.wrap_pending = false;
    }

    pub fn tabBack(self: *Terminal, n: u32) void {
        var left = n;
        while (left > 0 and self.cursor_col > 0) : (left -= 1) {
            var c = self.cursor_col - 1;
            while (c > 0 and !self.tabs[c]) c -= 1;
            self.cursor_col = c;
        }
        self.wrap_pending = false;
    }

    // ------------------------------------------------------------ scrolling

    /// Shift rows [top, bottom] up by n, blanking the bottom n rows.
    fn shiftUp(self: *Terminal, top: u16, bottom: u16, n_in: u32, to_scrollback: bool) !void {
        if (top > bottom) return;
        const height: u32 = @as(u32, bottom) - top + 1;
        const n: u16 = @intCast(@min(n_in, height));
        if (n == 0) return;
        if (to_scrollback) {
            var r: u16 = 0;
            while (r < n) : (r += 1) try self.scrollback.pushLine(self.rowSlice(top + r));
        }
        const cols: usize = self.cols;
        const dst = self.cellIndex(top, 0);
        const src = self.cellIndex(top + n, 0);
        const end = self.cellIndex(bottom, 0) + cols;
        std.mem.copyForwards(Cell, self.buffer[dst .. end - @as(usize, n) * cols], self.buffer[src..end]);
        @memset(self.buffer[end - @as(usize, n) * cols .. end], self.eraseCell());
    }

    /// Shift rows [top, bottom] down by n, blanking the top n rows.
    fn shiftDown(self: *Terminal, top: u16, bottom: u16, n_in: u32) void {
        if (top > bottom) return;
        const height: u32 = @as(u32, bottom) - top + 1;
        const n: u16 = @intCast(@min(n_in, height));
        if (n == 0) return;
        const cols: usize = self.cols;
        const start = self.cellIndex(top, 0);
        const end = self.cellIndex(bottom, 0) + cols;
        std.mem.copyBackwards(Cell, self.buffer[start + @as(usize, n) * cols .. end], self.buffer[start .. end - @as(usize, n) * cols]);
        @memset(self.buffer[start .. start + @as(usize, n) * cols], self.eraseCell());
    }

    /// SU / scroll the region up. Lines leaving a full-height primary-screen
    /// region go to scrollback.
    pub fn scrollUp(self: *Terminal, n: u32) !void {
        const keep = self.scroll_top == 0 and !self.alt_active;
        try self.shiftUp(self.scroll_top, self.scroll_bottom, n, keep);
    }

    /// SD / scroll the region down.
    pub fn scrollDown(self: *Terminal, n: u32) void {
        self.shiftDown(self.scroll_top, self.scroll_bottom, n);
    }

    fn cursorInRegion(self: *const Terminal) bool {
        return self.cursor_row >= self.scroll_top and self.cursor_row <= self.scroll_bottom;
    }

    /// IL
    pub fn insertLines(self: *Terminal, n: u32) void {
        if (!self.cursorInRegion()) return;
        self.shiftDown(self.cursor_row, self.scroll_bottom, n);
        self.cursor_col = 0;
        self.wrap_pending = false;
    }

    /// DL
    pub fn deleteLines(self: *Terminal, n: u32) !void {
        if (!self.cursorInRegion()) return;
        try self.shiftUp(self.cursor_row, self.scroll_bottom, n, false);
        self.cursor_col = 0;
        self.wrap_pending = false;
    }

    /// ICH / insert-mode helper: shift the rest of the line right by n.
    fn insertBlanks(self: *Terminal, n_in: u32) void {
        const row = self.rowSlice(self.cursor_row);
        const col = self.cursor_col;
        const n: u16 = @intCast(@min(n_in, self.cols - col));
        self.breakWideAt(self.cursor_row, col);
        if (col + n < self.cols) {
            std.mem.copyBackwards(Cell, row[col + n ..], row[col .. self.cols - n]);
        }
        @memset(row[col .. col + n], self.eraseCell());
        self.fixWideRow(self.cursor_row);
    }

    pub fn insertChars(self: *Terminal, n: u32) void {
        self.wrap_pending = false;
        self.insertBlanks(n);
    }

    /// DCH
    pub fn deleteChars(self: *Terminal, n_in: u32) void {
        self.wrap_pending = false;
        const row = self.rowSlice(self.cursor_row);
        const col = self.cursor_col;
        const n: u16 = @intCast(@min(n_in, self.cols - col));
        self.breakWideAt(self.cursor_row, col);
        if (col + n < self.cols) {
            std.mem.copyForwards(Cell, row[col .. self.cols - n], row[col + n ..]);
        }
        @memset(row[self.cols - n ..], self.eraseCell());
        self.fixWideRow(self.cursor_row);
    }

    /// ECH
    pub fn eraseChars(self: *Terminal, n_in: u32) void {
        self.wrap_pending = false;
        const row = self.rowSlice(self.cursor_row);
        const col = self.cursor_col;
        const n: u16 = @intCast(@min(n_in, self.cols - col));
        @memset(row[col .. col + n], self.eraseCell());
        self.fixWideRow(self.cursor_row);
    }

    // ------------------------------------------------------------ erase

    pub fn clear(self: *Terminal) !void {
        @memset(self.buffer, self.eraseCell());
        self.cursor_row = 0;
        self.cursor_col = 0;
        self.wrap_pending = false;
    }

    pub fn eraseDisplay(self: *Terminal, mode: u32) !void {
        const here = self.cellIndex(self.cursor_row, self.cursor_col);
        switch (mode) {
            0 => @memset(self.buffer[here..], self.eraseCell()),
            1 => @memset(self.buffer[0 .. here + 1], self.eraseCell()),
            2 => @memset(self.buffer, self.eraseCell()),
            3 => self.scrollback.clear(),
            else => return,
        }
        self.wrap_pending = false;
        self.fixWideRow(self.cursor_row);
    }

    pub fn eraseLine(self: *Terminal, mode: u32) !void {
        const row = self.rowSlice(self.cursor_row);
        const col = self.cursor_col;
        switch (mode) {
            0 => @memset(row[col..], self.eraseCell()),
            1 => @memset(row[0 .. col + 1], self.eraseCell()),
            2 => @memset(row, self.eraseCell()),
            else => return,
        }
        self.wrap_pending = false;
        self.fixWideRow(self.cursor_row);
    }

    // ------------------------------------------------------------ screens

    fn enterAlt(self: *Terminal, clear_it: bool) void {
        if (!self.alt_active) {
            self.buffer = self.alt;
            self.alt_active = true;
        }
        if (clear_it) @memset(self.alt, self.eraseCell());
    }

    fn leaveAlt(self: *Terminal, clear_it: bool) void {
        if (!self.alt_active) return;
        if (clear_it) @memset(self.alt, self.eraseCell());
        self.buffer = self.primary;
        self.alt_active = false;
    }

    /// DECSTR
    pub fn softReset(self: *Terminal) void {
        self.cursor_visible = true;
        self.modes.insert = false;
        self.modes.origin = false;
        self.modes.autowrap = true;
        self.modes.app_cursor = false;
        self.modes.app_keypad = false;
        self.scroll_top = 0;
        self.scroll_bottom = self.rows - 1;
        self.pen = .{};
        self.charsets = .{ .ascii, .ascii };
        self.gl = 0;
        self.saved = .{ .{}, .{} };
        self.wrap_pending = false;
    }

    /// RIS
    pub fn fullReset(self: *Terminal) void {
        self.leaveAlt(true);
        self.softReset();
        self.modes = .{};
        self.cursor_shape = .block;
        resetTabs(self.tabs);
        @memset(self.primary, Cell.init());
        @memset(self.alt, Cell.init());
        self.cursor_row = 0;
        self.cursor_col = 0;
        self.parser.reset();
    }

    pub fn resize(self: *Terminal, rows_in: u16, cols_in: u16) !void {
        const new_rows = @max(rows_in, 1);
        const new_cols = @max(cols_in, 1);
        if (new_rows == self.rows and new_cols == self.cols) return;

        if (self.pty) |pty| try pty.setWindowSize(new_rows, new_cols);

        const new_primary = try self.allocator.alloc(Cell, @as(usize, new_rows) * new_cols);
        errdefer self.allocator.free(new_primary);
        const new_alt = try self.allocator.alloc(Cell, @as(usize, new_rows) * new_cols);
        errdefer self.allocator.free(new_alt);
        const new_tabs = try self.allocator.alloc(bool, new_cols);
        resetTabs(new_tabs);

        // Keep the cursor on screen: when shrinking past it, drop rows off
        // the top (into scrollback for the primary screen).
        const shift: u16 = if (self.cursor_row >= new_rows) self.cursor_row - new_rows + 1 else 0;
        if (!self.alt_active) {
            var r: u16 = 0;
            while (r < shift) : (r += 1) try self.scrollback.pushLine(self.primary[@as(usize, r) * self.cols ..][0..self.cols]);
        }
        copyGrid(new_primary, new_rows, new_cols, self.primary, self.rows, self.cols, if (self.alt_active) 0 else shift);
        copyGrid(new_alt, new_rows, new_cols, self.alt, self.rows, self.cols, if (self.alt_active) shift else 0);

        self.allocator.free(self.primary);
        self.allocator.free(self.alt);
        self.allocator.free(self.tabs);
        self.primary = new_primary;
        self.alt = new_alt;
        self.tabs = new_tabs;
        self.buffer = if (self.alt_active) new_alt else new_primary;
        self.rows = new_rows;
        self.cols = new_cols;
        self.cursor_row = @min(self.cursor_row - shift, new_rows - 1);
        self.cursor_col = @min(self.cursor_col, new_cols - 1);
        self.wrap_pending = false;
        self.scroll_top = 0;
        self.scroll_bottom = new_rows - 1;
        for (&self.saved) |*s| {
            s.row = @min(s.row, new_rows - 1);
            s.col = @min(s.col, new_cols - 1);
        }
        var r: u16 = 0;
        while (r < new_rows) : (r += 1) self.fixWideRow(r);
        if (self.alt_active) {
            self.buffer = new_primary;
            r = 0;
            while (r < new_rows) : (r += 1) self.fixWideRow(r);
            self.buffer = new_alt;
        } else {
            self.buffer = new_alt;
            r = 0;
            while (r < new_rows) : (r += 1) self.fixWideRow(r);
            self.buffer = new_primary;
        }
    }

    fn copyGrid(dst: []Cell, dst_rows: u16, dst_cols: u16, src: []const Cell, src_rows: u16, src_cols: u16, src_row_offset: u16) void {
        @memset(dst, Cell.init());
        const cols = @min(dst_cols, src_cols);
        var r: u16 = 0;
        while (r < dst_rows and r + src_row_offset < src_rows) : (r += 1) {
            const s = @as(usize, r + src_row_offset) * src_cols;
            const d = @as(usize, r) * dst_cols;
            @memcpy(dst[d .. d + cols], src[s .. s + cols]);
        }
    }

    // ------------------------------------------------------------ ESC

    fn escDispatch(self: *Terminal, intermediate: u8, final: u8) !void {
        switch (intermediate) {
            0 => switch (final) {
                '7' => self.saveCursor(),
                '8' => self.restoreCursor(),
                'D' => try self.index(),
                'E' => {
                    self.carriageReturn();
                    try self.index();
                },
                'H' => self.tabs[self.cursor_col] = true,
                'M' => self.reverseIndex(),
                'c' => self.fullReset(),
                '=' => self.modes.app_keypad = true,
                '>' => self.modes.app_keypad = false,
                else => {},
            },
            '(', ')' => {
                const slot: usize = if (intermediate == '(') 0 else 1;
                self.charsets[slot] = if (final == '0') .dec_special else .ascii;
            },
            '#' => if (final == '8') self.decaln(),
            else => {},
        }
    }

    /// DECALN: fill the screen with 'E' (alignment test).
    fn decaln(self: *Terminal) void {
        var cell = Cell.init();
        cell.char = 'E';
        @memset(self.buffer, cell);
        self.scroll_top = 0;
        self.scroll_bottom = self.rows - 1;
        self.cursor_row = 0;
        self.cursor_col = 0;
        self.wrap_pending = false;
    }

    // ------------------------------------------------------------ CSI

    fn csiDispatch(self: *Terminal, p: CSIParams, final: u8) !void {
        if (p.intermediate != 0) return self.csiIntermediate(p, final);
        switch (p.private) {
            0 => {},
            '?' => return self.csiPrivate(p, final),
            '>' => {
                switch (final) {
                    'c' => self.reply("\x1b[>1;10;0c", .{}), // DA2: VT220, version 10
                    'q' => self.reply("\x1bP>|DeathTerminal 0.1.0\x1b\\", .{}), // XTVERSION
                    else => {},
                }
                return;
            },
            else => return,
        }

        const n1 = p.getNonZero(0, 1);
        switch (final) {
            '@' => self.insertChars(n1),
            'A' => self.cursorUp(n1),
            'B', 'e' => self.cursorDown(n1),
            'C', 'a' => self.cursorForward(n1),
            'D' => self.cursorBack(n1),
            'E' => {
                self.cursorDown(n1);
                self.cursor_col = 0;
            },
            'F' => {
                self.cursorUp(n1);
                self.cursor_col = 0;
            },
            'G', '`' => self.setCursorCol(n1),
            'H', 'f' => self.setCursorPos(p.getNonZero(0, 1), p.getNonZero(1, 1)),
            'I' => self.tabForward(n1),
            'J' => try self.eraseDisplay(p.getParam(0, 0)),
            'K' => try self.eraseLine(p.getParam(0, 0)),
            'L' => self.insertLines(n1),
            'M' => try self.deleteLines(n1),
            'P' => self.deleteChars(n1),
            'S' => try self.scrollUp(n1),
            'T' => if (p.param_count <= 1) self.scrollDown(n1),
            'X' => self.eraseChars(n1),
            'Z' => self.tabBack(n1),
            'b' => {
                if (self.last_char != 0) {
                    var i: u32 = 0;
                    const count = @min(n1, @as(u32, self.rows) * self.cols);
                    while (i < count) : (i += 1) try self.putChar(self.last_char);
                }
            },
            'c' => if (p.getParam(0, 0) == 0) self.reply("\x1b[?62;22c", .{}), // DA1: VT220 + ANSI color
            'd' => self.setCursorRow(n1),
            'g' => switch (p.getParam(0, 0)) {
                0 => self.tabs[self.cursor_col] = false,
                3 => @memset(self.tabs, false),
                else => {},
            },
            'h' => self.setAnsiModes(p, true),
            'l' => self.setAnsiModes(p, false),
            'm' => self.sgr(p),
            'n' => switch (p.getParam(0, 0)) {
                5 => self.reply("\x1b[0n", .{}),
                6 => self.reply("\x1b[{d};{d}R", .{ self.reportRow(), @as(u32, self.cursor_col) + 1 }),
                else => {},
            },
            'r' => self.setScrollRegion(p.getNonZero(0, 1), p.getNonZero(1, self.rows)),
            's' => self.saveCursor(),
            'u' => self.restoreCursor(),
            't' => switch (p.getParam(0, 0)) {
                18 => self.reply("\x1b[8;{d};{d}t", .{ self.rows, self.cols }),
                else => {},
            },
            else => {},
        }
    }

    fn reportRow(self: *const Terminal) u32 {
        const base: u16 = if (self.modes.origin) self.scroll_top else 0;
        return @as(u32, self.cursor_row - base) + 1;
    }

    fn csiIntermediate(self: *Terminal, p: CSIParams, final: u8) !void {
        switch (p.intermediate) {
            ' ' => if (final == 'q' and p.private == 0) {
                // DECSCUSR
                const v = p.getParam(0, 0);
                self.cursor_shape = switch (v) {
                    3, 4 => .underline,
                    5, 6 => .bar,
                    else => .block,
                };
                self.modes.cursor_blink = v == 0 or v % 2 == 1;
            },
            '!' => if (final == 'p') self.softReset(),
            '$' => if (final == 'p') {
                // DECRQM
                const mode = p.getParam(0, 0);
                const state: u8 = if (p.private == '?') self.privateModeState(mode) else self.ansiModeState(mode);
                if (p.private == '?') {
                    self.reply("\x1b[?{d};{d}$y", .{ mode, state });
                } else {
                    self.reply("\x1b[{d};{d}$y", .{ mode, state });
                }
            },
            else => {},
        }
    }

    fn setScrollRegion(self: *Terminal, top1: u32, bottom1: u32) void {
        const bottom = @min(bottom1, self.rows);
        if (top1 >= bottom) return;
        self.scroll_top = @intCast(top1 - 1);
        self.scroll_bottom = @intCast(bottom - 1);
        self.setCursorPos(1, 1);
    }

    // ------------------------------------------------------------ modes

    fn setAnsiModes(self: *Terminal, p: CSIParams, on: bool) void {
        var i: u8 = 0;
        while (i < p.param_count) : (i += 1) switch (p.params[i]) {
            4 => self.modes.insert = on,
            20 => self.modes.newline = on,
            else => {},
        };
    }

    fn ansiModeState(self: *const Terminal, mode: u32) u8 {
        return switch (mode) {
            4 => if (self.modes.insert) 1 else 2,
            20 => if (self.modes.newline) 1 else 2,
            else => 0,
        };
    }

    fn csiPrivate(self: *Terminal, p: CSIParams, final: u8) !void {
        switch (final) {
            'h', 'l' => {
                const on = final == 'h';
                var i: u8 = 0;
                while (i < p.param_count) : (i += 1) self.setPrivateMode(p.params[i], on);
            },
            'J' => try self.eraseDisplay(p.getParam(0, 0)), // DECSED (no protection)
            'K' => try self.eraseLine(p.getParam(0, 0)), // DECSEL
            'n' => switch (p.getParam(0, 0)) {
                6 => self.reply("\x1b[?{d};{d}R", .{ self.reportRow(), @as(u32, self.cursor_col) + 1 }),
                15 => self.reply("\x1b[?13n", .{}), // no printer
                26 => self.reply("\x1b[?27;1;0;0n", .{}), // US keyboard
                else => {},
            },
            else => {},
        }
    }

    fn setPrivateMode(self: *Terminal, mode: u32, on: bool) void {
        switch (mode) {
            1 => self.modes.app_cursor = on,
            // DECCOLM: the grid size follows the window, so 80/132 switching
            // is not honoured, but the side effects apps rely on are (reset
            // margins, clear the screen, home the cursor), like Alacritty.
            3 => {
                self.scroll_top = 0;
                self.scroll_bottom = self.rows - 1;
                @memset(self.buffer, self.eraseCell());
                self.setCursorPos(1, 1);
            },
            5 => self.modes.reverse_video = on,
            6 => {
                self.modes.origin = on;
                self.setCursorPos(1, 1);
            },
            7 => {
                self.modes.autowrap = on;
                if (!on) self.wrap_pending = false;
            },
            9 => self.modes.mouse = if (on) .x10 else .off,
            12 => self.modes.cursor_blink = on,
            25 => self.cursor_visible = on,
            47 => if (on) self.enterAlt(false) else self.leaveAlt(false),
            1047 => if (on) self.enterAlt(false) else self.leaveAlt(true),
            1048 => if (on) self.saveCursor() else self.restoreCursor(),
            1049 => if (on) {
                if (!self.alt_active) {
                    self.saveCursor();
                    self.enterAlt(true);
                }
            } else if (self.alt_active) {
                self.leaveAlt(false);
                self.restoreCursor();
            },
            1000 => self.modes.mouse = if (on) .normal else .off,
            1002 => self.modes.mouse = if (on) .button else .off,
            1003 => self.modes.mouse = if (on) .any else .off,
            1004 => self.modes.focus_events = on,
            1006 => self.modes.mouse_sgr = on,
            2004 => self.modes.bracketed_paste = on,
            else => {},
        }
    }

    fn privateModeState(self: *const Terminal, mode: u32) u8 {
        const m = self.modes;
        const v: ?bool = switch (mode) {
            1 => m.app_cursor,
            5 => m.reverse_video,
            6 => m.origin,
            7 => m.autowrap,
            9 => m.mouse == .x10,
            12 => m.cursor_blink,
            25 => self.cursor_visible,
            47, 1047, 1049 => self.alt_active,
            1000 => m.mouse == .normal,
            1002 => m.mouse == .button,
            1003 => m.mouse == .any,
            1004 => m.focus_events,
            1006 => m.mouse_sgr,
            2004 => m.bracketed_paste,
            else => null,
        };
        const b = v orelse return 0;
        return if (b) 1 else 2;
    }

    // ------------------------------------------------------------ SGR

    /// Parse an extended color starting at params[i] (the 38/48/58 itself).
    /// Returns the color (null = invalid) and the index of the last consumed
    /// parameter.
    fn extendedColor(p: CSIParams, i: u8) struct { color: ?u32, last: u8 } {
        if (i + 1 >= p.param_count) return .{ .color = null, .last = i };
        if (p.isSub(i + 1)) {
            // Colon form: 38:5:n or 38:2:[cs]:r:g:b
            var last = i + 1;
            while (last + 1 < p.param_count and p.isSub(last + 1)) last += 1;
            const subs = last - i; // number of sub-params incl. the mode
            switch (p.params[i + 1]) {
                5 => if (subs >= 2) return .{ .color = color.palette256(p.params[i + 2]), .last = last },
                2 => {
                    if (subs >= 5) return .{ .color = color.rgb(p.params[i + 3], p.params[i + 4], p.params[i + 5]), .last = last };
                    if (subs == 4) return .{ .color = color.rgb(p.params[i + 2], p.params[i + 3], p.params[i + 4]), .last = last };
                },
                else => {},
            }
            return .{ .color = null, .last = last };
        }
        switch (p.params[i + 1]) {
            5 => {
                if (i + 2 < p.param_count) return .{ .color = color.palette256(p.params[i + 2]), .last = i + 2 };
                return .{ .color = null, .last = p.param_count - 1 };
            },
            2 => {
                if (i + 4 < p.param_count) return .{ .color = color.rgb(p.params[i + 2], p.params[i + 3], p.params[i + 4]), .last = i + 4 };
                return .{ .color = null, .last = p.param_count - 1 };
            },
            else => return .{ .color = null, .last = i + 1 },
        }
    }

    fn sgr(self: *Terminal, p: CSIParams) void {
        if (p.param_count == 0) {
            self.resetPen();
            return;
        }
        var i: u8 = 0;
        while (i < p.param_count) : (i += 1) {
            const v = p.params[i];
            switch (v) {
                0 => self.resetPen(),
                1 => self.pen.bold = true,
                2 => self.pen.faint = true,
                3 => self.pen.italic = true,
                4 => {
                    // 4:0 = no underline, 4:1..5 = styles
                    if (i + 1 < p.param_count and p.isSub(i + 1)) {
                        const style = p.params[i + 1];
                        self.pen.underline = style != 0;
                        self.pen.underline_style = switch (style) {
                            2 => .double,
                            3 => .curly,
                            4 => .dotted,
                            5 => .dashed,
                            else => .single,
                        };
                        i += 1;
                        while (i + 1 < p.param_count and p.isSub(i + 1)) i += 1;
                    } else {
                        self.pen.underline = true;
                        self.pen.underline_style = .single;
                    }
                },
                5, 6 => self.pen.blink = true,
                7 => self.pen.inverse = true,
                8 => self.pen.hidden = true,
                9 => self.pen.strikethrough = true,
                21 => {
                    self.pen.underline = true;
                    self.pen.underline_style = .double;
                },
                22 => {
                    self.pen.bold = false;
                    self.pen.faint = false;
                },
                23 => self.pen.italic = false,
                24 => self.pen.underline = false,
                25 => self.pen.blink = false,
                27 => self.pen.inverse = false,
                28 => self.pen.hidden = false,
                29 => self.pen.strikethrough = false,
                30...37 => self.pen.fg = color.ansi16[v - 30],
                38 => {
                    const r = extendedColor(p, i);
                    if (r.color) |c| self.pen.fg = c;
                    i = r.last;
                },
                39 => self.pen.fg = color.default_fg,
                40...47 => self.pen.bg = color.ansi16[v - 40],
                48 => {
                    const r = extendedColor(p, i);
                    if (r.color) |c| self.pen.bg = c;
                    i = r.last;
                },
                49 => self.pen.bg = color.default_bg,
                58 => {
                    const r = extendedColor(p, i);
                    if (r.color) |c| self.pen.underline_color = c;
                    i = r.last;
                },
                59 => self.pen.underline_color = color.none,
                90...97 => self.pen.fg = color.ansi16[v - 90 + 8],
                100...107 => self.pen.bg = color.ansi16[v - 100 + 8],
                else => {
                    // Skip sub-params of unknown attributes.
                    while (i + 1 < p.param_count and p.isSub(i + 1)) i += 1;
                },
            }
        }
    }

    fn resetPen(self: *Terminal) void {
        const link = self.pen.link; // hyperlinks are not SGR state
        self.pen = .{};
        self.pen.link = link;
    }

    // ------------------------------------------------------------ OSC

    fn oscDispatch(self: *Terminal, data: []const u8) !void {
        const sep = std.mem.indexOfScalar(u8, data, ';') orelse return;
        const cmd = std.fmt.parseInt(u32, data[0..sep], 10) catch return;
        const arg = data[sep + 1 ..];
        switch (cmd) {
            0, 2 => try self.setTitle(arg),
            7 => {
                const v = arg[0..@min(arg.len, MAX_LINK_LEN)];
                const copy = try self.allocator.dupe(u8, v);
                self.allocator.free(self.cwd_uri);
                self.cwd_uri = copy;
            },
            8 => try self.setHyperlink(arg),
            52 => try self.clipboardOsc(arg),
            10, 11 => if (std.mem.eql(u8, arg, "?")) {
                const c = if (cmd == 10) color.default_fg else color.default_bg;
                const r = (c >> 16) & 0xFF;
                const g = (c >> 8) & 0xFF;
                const b = c & 0xFF;
                self.reply("\x1b]{d};rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}\x1b\\", .{ cmd, r, r, g, g, b, b });
            },
            else => {},
        }
    }

    /// OSC 52 ; Pc ; Pd — Pd is base64 text to store, or "?" to query.
    fn clipboardOsc(self: *Terminal, arg: []const u8) !void {
        const sep = std.mem.indexOfScalar(u8, arg, ';') orelse return;
        const targets = ClipboardTargets.parse(arg[0..sep]);
        const data = arg[sep + 1 ..];
        if (self.clipboard_ops.items.len >= 16) return; // front end not draining
        if (std.mem.eql(u8, data, "?")) {
            try self.clipboard_ops.append(.{ .query = targets });
            return;
        }
        // Accept padded and unpadded base64.
        const trimmed = std.mem.trimRight(u8, data, "=");
        const nopad = std.base64.standard_no_pad.Decoder;
        const size = nopad.calcSizeForSlice(trimmed) catch return;
        const buf = try self.allocator.alloc(u8, size);
        nopad.decode(buf, trimmed) catch {
            self.allocator.free(buf);
            return;
        };
        try self.clipboard_ops.append(.{ .set = .{ .targets = targets, .data = buf } });
    }

    /// Hand pending OSC 52 requests to the caller (who frees `set.data`
    /// with `freeClipboardOp`).
    pub fn takeClipboardOps(self: *Terminal) ![]ClipboardOp {
        return self.clipboard_ops.toOwnedSlice();
    }

    pub fn freeClipboardOps(self: *Terminal, ops: []ClipboardOp) void {
        for (ops) |op| switch (op) {
            .set => |s| self.allocator.free(s.data),
            .query => {},
        };
        self.allocator.free(ops);
    }

    // ------------------------------------------------------------ lines

    /// Absolute number of the screen's first row. Scrollback lines are
    /// numbered below it (oldest retained = `historyTop`).
    pub fn screenTop(self: *const Terminal) i64 {
        return @intCast(self.scrollback.total);
    }

    pub fn historyTop(self: *const Terminal) i64 {
        return self.screenTop() - @as(i64, @intCast(self.scrollback.len()));
    }

    /// Cells of absolute line `line` (scrollback or active screen), or
    /// null when it is out of range. Scrollback rows keep the width they
    /// had when they scrolled off.
    pub fn lineAt(self: *const Terminal, line: i64) ?[]const Cell {
        const top = self.screenTop();
        if (line >= top) {
            const r = line - top;
            if (r >= self.rows) return null;
            const start = @as(usize, @intCast(r)) * self.cols;
            return self.buffer[start..][0..self.cols];
        }
        if (self.alt_active) return null;
        const hist = self.historyTop();
        if (line < hist) return null;
        return self.scrollback.getLine(@intCast(line - hist));
    }

    /// OSC 8 ; params ; URI — an empty URI ends the link.
    fn setHyperlink(self: *Terminal, arg: []const u8) !void {
        const sep = std.mem.indexOfScalar(u8, arg, ';') orelse return;
        const uri = arg[sep + 1 ..];
        if (uri.len == 0 or uri.len > MAX_LINK_LEN) {
            self.pen.link = 0;
            return;
        }
        for (uri) |b| if (b < 0x20 or b == 0x7F) {
            self.pen.link = 0;
            return;
        };
        for (self.links.items, 0..) |existing, idx| {
            if (std.mem.eql(u8, existing, uri)) {
                self.pen.link = @intCast(idx + 1);
                return;
            }
        }
        if (self.links.items.len >= MAX_LINKS) {
            self.pen.link = 0;
            return;
        }
        try self.links.append(try self.allocator.dupe(u8, uri));
        self.pen.link = @intCast(self.links.items.len);
    }

    pub fn linkTarget(self: *const Terminal, link: u16) ?[]const u8 {
        if (link == 0 or link > self.links.items.len) return null;
        return self.links.items[link - 1];
    }

    pub fn setTitle(self: *Terminal, title: []const u8) !void {
        const t = title[0..@min(title.len, MAX_TITLE_LEN)];
        // Keep only valid UTF-8 and no control characters.
        var out = std.ArrayList(u8).init(self.allocator);
        defer out.deinit();
        var it = std.unicode.Utf8View.init(t) catch {
            for (t) |b| try out.append(if (b >= 0x20 and b < 0x7F) b else '?');
            return self.replaceTitle(try out.toOwnedSlice());
        };
        var cps = it.iterator();
        while (cps.nextCodepointSlice()) |s| {
            if (s.len == 1 and (s[0] < 0x20 or s[0] == 0x7F)) continue;
            try out.appendSlice(s);
        }
        try self.replaceTitle(try out.toOwnedSlice());
    }

    fn replaceTitle(self: *Terminal, owned: []u8) !void {
        self.allocator.free(self.title);
        self.title = owned;
        self.title_changed = true;
    }

    // ------------------------------------------------------------ text

    /// The grid as UTF-8 text, one line per row. Wide-char spacers are
    /// skipped (the wide glyph already covers two columns).
    pub fn visibleText(self: *const Terminal, allocator: std.mem.Allocator) ![]u8 {
        var list = std.ArrayList(u8).init(allocator);
        errdefer list.deinit();
        var row: u16 = 0;
        while (row < self.rows) : (row += 1) {
            try appendRowText(self.buffer[self.cellIndex(row, 0)..][0..self.cols], list.writer());
            if (row + 1 < self.rows) try list.append('\n');
        }
        return list.toOwnedSlice();
    }
};

/// Write a row of cells as UTF-8, skipping wide-char spacers.
pub fn appendRowText(cells: []const Cell, writer: anytype) !void {
    for (cells) |cell| {
        if (cell.isSpacer()) continue;
        try cell.writeUtf8(writer);
    }
}

test {
    _ = @import("vt_test.zig");
    _ = pty_mod;
}
