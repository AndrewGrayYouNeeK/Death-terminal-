//! Mouse text selection over the scrollback + screen.
//!
//! Points use absolute line numbers (see `Terminal.lineAt`): line N stays
//! line N while output scrolls, so a selection survives scrolling and
//! viewport movement. Lines are read through any `lines` value with a
//! `lineAt(i64) ?[]const Cell` method.

const std = @import("std");
const terminal = @import("terminal.zig");
const Cell = terminal.Cell;

pub const Point = struct {
    line: i64,
    col: u16,

    pub fn before(a: Point, b: Point) bool {
        return a.line < b.line or (a.line == b.line and a.col < b.col);
    }

    pub fn eql(a: Point, b: Point) bool {
        return a.line == b.line and a.col == b.col;
    }
};

pub const Mode = enum { normal, word, line, block };

/// Default extra "word" characters for double-click (besides letters,
/// digits and non-ASCII), chosen so paths and URLs select in one go.
pub const default_word_chars = "-_./~:@%+#?&=";

pub const Selection = struct {
    anchor: Point,
    head: Point,
    mode: Mode = .normal,
    /// False until the pointer moves (or a word/line click); a plain click
    /// without a drag selects nothing.
    active: bool = false,

    pub fn begin(p: Point, mode: Mode) Selection {
        return .{ .anchor = p, .head = p, .mode = mode, .active = mode == .word or mode == .line };
    }

    pub fn update(self: *Selection, p: Point) void {
        if (!p.eql(self.head)) self.active = true;
        self.head = p;
    }

    /// Shift-click: extend from whichever end is farther from `p`.
    pub fn extend(self: *Selection, p: Point) void {
        const r = self.ordered();
        if (p.before(r.start)) {
            self.anchor = r.end;
        } else if (r.end.before(p)) {
            self.anchor = r.start;
        } else {
            // Inside: keep the start, move the end.
            self.anchor = r.start;
        }
        self.head = p;
        self.active = true;
    }

    pub const Range = struct { start: Point, end: Point };

    /// Anchor/head in reading order (raw, before word/line expansion).
    pub fn ordered(self: Selection) Range {
        return if (self.head.before(self.anchor))
            .{ .start = self.head, .end = self.anchor }
        else
            .{ .start = self.anchor, .end = self.head };
    }

    /// Selected range after word/line expansion and wide-char snapping.
    /// For block mode `start.col`/`end.col` are the rectangle's columns.
    pub fn resolve(self: Selection, lines: anytype, word_chars: []const u8) Range {
        var r = self.ordered();
        switch (self.mode) {
            .normal => {
                r.start = snapLead(lines, r.start);
                r.end = snapTrail(lines, r.end);
            },
            .word => {
                r.start = wordStart(lines, r.start, word_chars);
                r.end = wordEnd(lines, r.end, word_chars);
            },
            .line => {
                r.start = .{ .line = logicalLineStart(lines, r.start.line), .col = 0 };
                r.end = .{ .line = logicalLineEnd(lines, r.end.line), .col = std.math.maxInt(u16) };
            },
            .block => {
                const c0 = @min(self.anchor.col, self.head.col);
                const c1 = @max(self.anchor.col, self.head.col);
                r.start.col = c0;
                r.end.col = c1;
            },
        }
        return r;
    }

    /// True when cell (line, col) is inside the resolved range `r`.
    pub fn containsResolved(self: Selection, r: Range, line: i64, col: u16) bool {
        if (!self.active) return false;
        if (line < r.start.line or line > r.end.line) return false;
        if (self.mode == .block) return col >= r.start.col and col <= r.end.col;
        if (line == r.start.line and col < r.start.col) return false;
        if (line == r.end.line and col > r.end.col) return false;
        return true;
    }

    /// Selected text as UTF-8. Trailing blanks on each line are dropped;
    /// soft-wrapped lines are joined without a newline (except in block
    /// mode). Wide-char spacers are skipped.
    pub fn text(self: Selection, allocator: std.mem.Allocator, lines: anytype, word_chars: []const u8) ![]u8 {
        var out = std.ArrayList(u8).init(allocator);
        errdefer out.deinit();
        if (!self.active) return out.toOwnedSlice();
        const r = self.resolve(lines, word_chars);
        var line = r.start.line;
        while (line <= r.end.line) : (line += 1) {
            const cells = lines.lineAt(line) orelse continue;
            if (cells.len == 0) continue;
            const last: usize = cells.len - 1;
            var c0: usize = 0;
            var c1: usize = last;
            if (self.mode == .block) {
                c0 = r.start.col;
                c1 = @min(@as(usize, r.end.col), last);
            } else {
                if (line == r.start.line) c0 = r.start.col;
                if (line == r.end.line) c1 = @min(@as(usize, r.end.col), last);
            }
            const mark = out.items.len;
            if (c0 <= c1 and c0 <= last) {
                var col = c0;
                while (col <= c1) : (col += 1) {
                    const cell = cells[col];
                    if (cell.isSpacer()) continue;
                    try cell.writeUtf8(out.writer());
                }
            }
            const wrapped = cells[last].soft_wrap and self.mode != .block and c1 == last;
            if (!wrapped) {
                // Trim trailing blanks written for this line.
                while (out.items.len > mark and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
                if (line != r.end.line) try out.append('\n');
            }
        }
        return out.toOwnedSlice();
    }
};

fn cellAt(lines: anytype, p: Point) ?Cell {
    const cells = lines.lineAt(p.line) orelse return null;
    if (p.col >= cells.len) return null;
    return cells[p.col];
}

/// Move a start point off a wide-char spacer onto its leading half.
fn snapLead(lines: anytype, p: Point) Point {
    const c = cellAt(lines, p) orelse return p;
    if (c.isSpacer() and p.col > 0) return .{ .line = p.line, .col = p.col - 1 };
    return p;
}

/// Move an end point on a wide char's leading half onto its spacer.
fn snapTrail(lines: anytype, p: Point) Point {
    const c = cellAt(lines, p) orelse return p;
    if (c.width == 2) return .{ .line = p.line, .col = p.col + 1 };
    return p;
}

pub const Class = enum { space, word, punct };

pub fn classify(cp: u21, word_chars: []const u8) Class {
    if (cp == ' ' or cp == '\t' or cp == 0 or cp == 0xA0 or cp == 0x3000) return .space;
    if (cp < 0x80) {
        const b: u8 = @intCast(cp);
        if (std.ascii.isAlphanumeric(b)) return .word;
        if (std.mem.indexOfScalar(u8, word_chars, b) != null) return .word;
        return .punct;
    }
    // Box drawing / blocks behave like punctuation; other non-ASCII
    // (letters, CJK, emoji) like word characters.
    if (cp >= 0x2500 and cp <= 0x259F) return .punct;
    return .word;
}

fn classAt(lines: anytype, p: Point, word_chars: []const u8) ?Class {
    var q = p;
    const cells = lines.lineAt(q.line) orelse return null;
    if (q.col >= cells.len) return null;
    if (cells[q.col].isSpacer() and q.col > 0) q.col -= 1;
    return classify(cells[q.col].char, word_chars);
}

fn lineWraps(lines: anytype, line: i64) bool {
    const cells = lines.lineAt(line) orelse return false;
    return cells.len > 0 and cells[cells.len - 1].soft_wrap;
}

fn lineLen(lines: anytype, line: i64) u16 {
    const cells = lines.lineAt(line) orelse return 0;
    return @intCast(cells.len);
}

/// Previous cell in reading order, following soft wraps only.
fn prevCell(lines: anytype, p: Point) ?Point {
    if (p.col > 0) return .{ .line = p.line, .col = p.col - 1 };
    if (!lineWraps(lines, p.line - 1)) return null;
    const n = lineLen(lines, p.line - 1);
    if (n == 0) return null;
    return .{ .line = p.line - 1, .col = n - 1 };
}

fn nextCell(lines: anytype, p: Point) ?Point {
    const n = lineLen(lines, p.line);
    if (p.col + 1 < n) return .{ .line = p.line, .col = p.col + 1 };
    if (!lineWraps(lines, p.line)) return null;
    if (lines.lineAt(p.line + 1) == null) return null;
    return .{ .line = p.line + 1, .col = 0 };
}

pub fn wordStart(lines: anytype, p_in: Point, word_chars: []const u8) Point {
    const p = snapLead(lines, p_in);
    const cls = classAt(lines, p, word_chars) orelse return p;
    var cur = p;
    while (prevCell(lines, cur)) |q| {
        if (classAt(lines, q, word_chars) != cls) break;
        cur = q;
    }
    return snapLead(lines, cur);
}

pub fn wordEnd(lines: anytype, p_in: Point, word_chars: []const u8) Point {
    const p = snapLead(lines, p_in);
    const cls = classAt(lines, p, word_chars) orelse return p;
    var cur = p;
    while (nextCell(lines, cur)) |q| {
        if (classAt(lines, q, word_chars) != cls) break;
        cur = q;
    }
    return snapTrail(lines, cur);
}

fn logicalLineStart(lines: anytype, line: i64) i64 {
    var l = line;
    while (lineWraps(lines, l - 1)) l -= 1;
    return l;
}

fn logicalLineEnd(lines: anytype, line: i64) i64 {
    var l = line;
    while (lineWraps(lines, l) and lines.lineAt(l + 1) != null) l += 1;
    return l;
}

// ------------------------------------------------------------------ tests

pub const TestLines = struct {
    rows: []const []Cell,
    pub fn lineAt(self: TestLines, line: i64) ?[]const Cell {
        if (line < 0 or line >= self.rows.len) return null;
        return self.rows[@intCast(line)];
    }
};

/// Build test rows from strings; a trailing '\\' marks a soft wrap and
/// wide chars occupy two cells.
pub fn testRows(allocator: std.mem.Allocator, comptime strs: []const []const u8, cols: u16) ![][]Cell {
    const unicode = @import("unicode.zig");
    const rows = try allocator.alloc([]Cell, strs.len);
    for (strs, 0..) |s, i| {
        rows[i] = try allocator.alloc(Cell, cols);
        @memset(rows[i], Cell.init());
        var src = s;
        var wrap = false;
        if (src.len > 0 and src[src.len - 1] == '\\') {
            wrap = true;
            src = src[0 .. src.len - 1];
        }
        var col: usize = 0;
        var it = (try std.unicode.Utf8View.init(src)).iterator();
        while (it.nextCodepoint()) |cp| {
            if (col >= cols) break;
            const w = unicode.width(cp);
            rows[i][col].char = cp;
            if (w == 2 and col + 1 < cols) {
                rows[i][col].width = 2;
                rows[i][col + 1].width = 0;
                col += 2;
            } else col += 1;
        }
        if (wrap) rows[i][cols - 1].soft_wrap = true;
    }
    return rows;
}

pub fn freeTestRows(allocator: std.mem.Allocator, rows: [][]Cell) void {
    for (rows) |r| allocator.free(r);
    allocator.free(rows);
}

const testing = std.testing;

fn selText(sel: Selection, lines: TestLines) ![]u8 {
    return sel.text(testing.allocator, lines, default_word_chars);
}

test "normal selection across lines trims trailing blanks" {
    const rows = try testRows(testing.allocator, &.{ "hello world", "second line", "third" }, 16);
    defer freeTestRows(testing.allocator, rows);
    const lines = TestLines{ .rows = rows };
    var sel = Selection.begin(.{ .line = 0, .col = 6 }, .normal);
    sel.update(.{ .line = 2, .col = 2 });
    const t = try selText(sel, lines);
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("world\nsecond line\nthi", t);
    // Reverse drag gives the same text.
    var rev = Selection.begin(.{ .line = 2, .col = 2 }, .normal);
    rev.update(.{ .line = 0, .col = 6 });
    const t2 = try selText(rev, lines);
    defer testing.allocator.free(t2);
    try testing.expectEqualStrings(t, t2);
}

test "click without drag selects nothing" {
    const rows = try testRows(testing.allocator, &.{"abc"}, 8);
    defer freeTestRows(testing.allocator, rows);
    const sel = Selection.begin(.{ .line = 0, .col = 1 }, .normal);
    const t = try selText(sel, .{ .rows = rows });
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("", t);
}

test "word boundaries: paths, punctuation, CJK" {
    const rows = try testRows(testing.allocator, &.{"cd /usr/local-bin; 日本語 (x)"}, 40);
    defer freeTestRows(testing.allocator, rows);
    const lines = TestLines{ .rows = rows };
    const wc = default_word_chars;
    // Double-click inside the path selects the whole path, not the ';'.
    var sel = Selection.begin(.{ .line = 0, .col = 8 }, .word);
    var t = try selText(sel, lines);
    try testing.expectEqualStrings("/usr/local-bin", t);
    testing.allocator.free(t);
    // CJK run: click on a spacer cell of 本.
    sel = Selection.begin(.{ .line = 0, .col = 22 }, .word);
    t = try selText(sel, lines);
    try testing.expectEqualStrings("日本語", t);
    testing.allocator.free(t);
    // Punctuation is its own class.
    try testing.expectEqual(Class.punct, classify('(', wc));
    try testing.expectEqual(Class.space, classify(' ', wc));
    try testing.expectEqual(Class.word, classify('_', wc));
    try testing.expectEqual(Class.punct, classify(0x2500, wc));
    // Custom word chars: without '/', the path splits.
    const r = Selection.begin(.{ .line = 0, .col = 8 }, .word).resolve(lines, "-");
    try testing.expectEqual(@as(u16, 8), r.start.col);
}

test "word selection follows soft wraps" {
    const rows = try testRows(testing.allocator, &.{ "see https://exa\\", "mple.com/x ok" }, 15);
    defer freeTestRows(testing.allocator, rows);
    const sel = Selection.begin(.{ .line = 1, .col = 2 }, .word);
    const t = try selText(sel, .{ .rows = rows });
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("https://example.com/x", t);
}

test "line selection takes the whole logical line" {
    const rows = try testRows(testing.allocator, &.{ "first", "wrapped part one\\", "and two", "last" }, 16);
    defer freeTestRows(testing.allocator, rows);
    const sel = Selection.begin(.{ .line = 2, .col = 3 }, .line);
    const t = try selText(sel, .{ .rows = rows });
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("wrapped part oneand two", t);
}

test "block selection is rectangular" {
    const rows = try testRows(testing.allocator, &.{ "abcdef", "ghijkl", "mnopqr" }, 8);
    defer freeTestRows(testing.allocator, rows);
    var sel = Selection.begin(.{ .line = 0, .col = 4 }, .block);
    sel.update(.{ .line = 2, .col = 1 });
    const t = try selText(sel, .{ .rows = rows });
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("bcde\nhijk\nnopq", t);
    const r = sel.resolve(TestLines{ .rows = rows }, default_word_chars);
    try testing.expect(sel.containsResolved(r, 1, 2));
    try testing.expect(!sel.containsResolved(r, 1, 5));
}

test "wide chars are never split" {
    const rows = try testRows(testing.allocator, &.{"a日本b"}, 8);
    defer freeTestRows(testing.allocator, rows);
    // Start on the spacer of 日 (col 2) and end on the lead of 本 (col 3).
    var sel = Selection.begin(.{ .line = 0, .col = 2 }, .normal);
    sel.update(.{ .line = 0, .col = 3 });
    const t = try selText(sel, .{ .rows = rows });
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("日本", t);
    const r = sel.resolve(TestLines{ .rows = rows }, default_word_chars);
    try testing.expectEqual(@as(u16, 1), r.start.col);
    try testing.expectEqual(@as(u16, 4), r.end.col);
}

test "shift-click extends from the far end" {
    var sel = Selection.begin(.{ .line = 5, .col = 3 }, .normal);
    sel.update(.{ .line = 5, .col = 10 });
    sel.extend(.{ .line = 2, .col = 0 });
    const r = sel.ordered();
    try testing.expectEqual(@as(i64, 2), r.start.line);
    try testing.expectEqual(@as(u16, 10), r.end.col);
    sel.extend(.{ .line = 9, .col = 1 });
    try testing.expectEqual(@as(i64, 2), sel.ordered().start.line);
    try testing.expectEqual(@as(i64, 9), sel.ordered().end.line);
}
