//! Scrollback/screen text search (plain or POSIX extended regex).
//!
//! Matches are reported in cell coordinates: an absolute line (see
//! `Terminal.lineAt`) and an inclusive column range that covers both
//! halves of wide characters. Soft-wrapped rows are searched as one
//! logical line, so a match may start on one row and end on a later one.

const std = @import("std");
const builtin = @import("builtin");
const terminal = @import("terminal.zig");
const Cell = terminal.Cell;

const have_regex = builtin.os.tag == .linux or builtin.os.tag == .macos;
const re = if (have_regex) @cImport(@cInclude("regex.h")) else struct {};

pub const Options = struct {
    case_sensitive: bool = false,
    regex: bool = false,
};

pub const Match = struct {
    line: i64,
    start: u16,
    /// Line of the last cell (> line when the match crosses a wrap).
    end_line: i64,
    end: u16,

    pub fn single(line: i64, start: u16, end: u16) Match {
        return .{ .line = line, .start = start, .end_line = line, .end = end };
    }
};

/// Byte position → (row within the logical line, column).
const Pos = struct { row: u32, col: u16 };

pub const regex_supported = have_regex;
const regex_block = 256;

pub const Searcher = struct {
    allocator: std.mem.Allocator,
    opts: Options,
    needle: []u8,
    compiled: if (have_regex) ?*re.regex_t else void = if (have_regex) null else {},
    text: std.ArrayList(u8),
    pos: std.ArrayList(Pos),
    rows_buf: std.ArrayList([]const Cell),

    /// error.BadRegex for an invalid pattern; error.RegexUnsupported when
    /// the platform lacks <regex.h>.
    pub fn init(allocator: std.mem.Allocator, query: []const u8, opts: Options) !Searcher {
        var s = Searcher{
            .allocator = allocator,
            .opts = opts,
            .needle = try allocator.dupe(u8, query),
            .text = std.ArrayList(u8).init(allocator),
            .pos = std.ArrayList(Pos).init(allocator),
            .rows_buf = std.ArrayList([]const Cell).init(allocator),
        };
        errdefer s.deinit();
        if (opts.regex) {
            if (!have_regex) return error.RegexUnsupported;
            const pat = try allocator.dupeZ(u8, query);
            defer allocator.free(pat);
            // regex_t has bitfields translate-c can't size; reserve a
            // generous block (glibc: 64 bytes, macOS: 32).
            const block = try allocator.alignedAlloc(u8, 16, regex_block);
            const r: *re.regex_t = @ptrCast(block.ptr);
            var flags: c_int = re.REG_EXTENDED;
            if (!opts.case_sensitive) flags |= re.REG_ICASE;
            if (re.regcomp(r, pat.ptr, flags) != 0) {
                allocator.free(block);
                return error.BadRegex;
            }
            s.compiled = r;
        } else if (!opts.case_sensitive) {
            for (s.needle) |*b| b.* = std.ascii.toLower(b.*);
        }
        return s;
    }

    pub fn deinit(self: *Searcher) void {
        if (have_regex) {
            if (self.compiled) |r| {
                re.regfree(r);
                const block: [*]align(16) u8 = @ptrCast(@alignCast(r));
                self.allocator.free(block[0..regex_block]);
            }
        }
        self.allocator.free(self.needle);
        self.text.deinit();
        self.pos.deinit();
        self.rows_buf.deinit();
    }

    /// Append the matches in one (unwrapped) line, left to right.
    pub fn searchLine(self: *Searcher, line: i64, cells: []const Cell, out: *std.ArrayList(Match)) !void {
        const one = [_][]const Cell{cells};
        try self.searchLogical(line, &one, out);
    }

    /// Append the matches in a logical line made of soft-wrapped `rows`
    /// starting at absolute line `first`.
    pub fn searchLogical(self: *Searcher, first: i64, rows: []const []const Cell, out: *std.ArrayList(Match)) !void {
        if (self.needle.len == 0) return;
        try self.buildText(rows);
        const hay = self.text.items[0 .. self.text.items.len - 1]; // drop NUL
        if (self.opts.regex) {
            if (!have_regex) return;
            const r = self.compiled orelse return;
            var off: usize = 0;
            while (off <= hay.len) {
                var m: [1]re.regmatch_t = undefined;
                const flags: c_int = if (off > 0) re.REG_NOTBOL else 0;
                if (re.regexec(r, self.text.items[off..].ptr, 1, &m, flags) != 0) break;
                const b0 = off + @as(usize, @intCast(m[0].rm_so));
                const b1 = off + @as(usize, @intCast(m[0].rm_eo));
                if (b1 > b0) try self.emit(first, rows, b0, b1, out);
                off = if (b1 > b0) b1 else b0 + 1;
            }
        } else {
            var off: usize = 0;
            while (std.mem.indexOfPos(u8, hay, off, self.needle)) |b0| {
                try self.emit(first, rows, b0, b0 + self.needle.len, out);
                off = b0 + self.needle.len;
            }
        }
    }

    fn buildText(self: *Searcher, rows: []const []const Cell) !void {
        self.text.clearRetainingCapacity();
        self.pos.clearRetainingCapacity();
        for (rows, 0..) |cells, ri| {
            for (cells, 0..) |cell, col| {
                if (cell.isSpacer()) continue;
                // The blank pad left when a wide char wrapped early.
                if (ri + 1 < rows.len and col + 1 == cells.len and cell.char == 0 and rows[ri + 1].len > 0 and rows[ri + 1][0].width == 2) continue;
                const start = self.text.items.len;
                var c = cell;
                if (c.char == 0) c.char = ' ';
                try c.writeUtf8(self.text.writer());
                if (!self.opts.case_sensitive and !self.opts.regex) {
                    for (self.text.items[start..]) |*b| b.* = std.ascii.toLower(b.*);
                }
                for (self.text.items[start..]) |_| try self.pos.append(.{ .row = @intCast(ri), .col = @intCast(col) });
            }
        }
        try self.text.append(0);
        try self.pos.append(.{ .row = @intCast(rows.len), .col = 0 });
    }

    fn emit(self: *Searcher, first: i64, rows: []const []const Cell, b0: usize, b1: usize, out: *std.ArrayList(Match)) !void {
        const p0 = self.pos.items[b0];
        const p1 = self.pos.items[b1 - 1];
        var c1 = p1.col;
        const last = rows[p1.row];
        if (c1 < last.len and last[c1].width == 2) c1 += 1;
        try out.append(.{ .line = first + p0.row, .start = p0.col, .end_line = first + p1.row, .end = c1 });
    }
};

fn wraps(cells: []const Cell) bool {
    return cells.len > 0 and cells[cells.len - 1].soft_wrap;
}

/// First line of the logical line containing `line` (walks back over
/// soft wraps, not past `floor`).
pub fn logicalStart(lines: anytype, line: i64, floor: i64) i64 {
    var l = line;
    while (l > floor) {
        const prev = lines.lineAt(l - 1) orelse break;
        if (!wraps(prev)) break;
        l -= 1;
    }
    return l;
}

/// Search lines `first..=last` of `lines` (anything with
/// `lineAt(i64) ?[]const Cell`) and append every match, oldest first.
/// Soft-wrapped rows are joined into logical lines; `first` should be the
/// start of one (see `logicalStart`).
pub fn searchAll(searcher: *Searcher, lines: anytype, first: i64, last: i64, out: *std.ArrayList(Match)) !void {
    var line = first;
    while (line <= last) {
        const cells = lines.lineAt(line) orelse {
            line += 1;
            continue;
        };
        searcher.rows_buf.clearRetainingCapacity();
        try searcher.rows_buf.append(cells);
        var next = line + 1;
        var cur = cells;
        while (wraps(cur) and next <= last) {
            cur = lines.lineAt(next) orelse break;
            try searcher.rows_buf.append(cur);
            next += 1;
        }
        try searcher.searchLogical(line, searcher.rows_buf.items, out);
        line = next;
    }
}

/// Index of the match to jump to from `from` going backwards (older,
/// `forward == false`) or forwards; wraps around.
pub fn step(matches: []const Match, current: ?usize, forward: bool) ?usize {
    if (matches.len == 0) return null;
    const cur = current orelse return if (forward) 0 else matches.len - 1;
    if (forward) return (cur + 1) % matches.len;
    return if (cur == 0) matches.len - 1 else cur - 1;
}

const sel = @import("selection.zig");
const testing = std.testing;

test "plain search is case-insensitive by default and maps wide columns" {
    const rows = try sel.testRows(testing.allocator, &.{ "Error: 日本 error", "no hit", "ERROR again" }, 24);
    defer sel.freeTestRows(testing.allocator, rows);
    const lines = sel.TestLines{ .rows = rows };
    var s = try Searcher.init(testing.allocator, "error", .{});
    defer s.deinit();
    var out = std.ArrayList(Match).init(testing.allocator);
    defer out.deinit();
    try searchAll(&s, lines, 0, 2, &out);
    try testing.expectEqual(@as(usize, 3), out.items.len);
    try testing.expectEqual(Match.single(0, 0, 4), out.items[0]);
    // "error" after two wide chars starts at col 12.
    try testing.expectEqual(Match.single(0, 12, 16), out.items[1]);
    try testing.expectEqual(@as(i64, 2), out.items[2].line);

    var cs = try Searcher.init(testing.allocator, "error", .{ .case_sensitive = true });
    defer cs.deinit();
    out.clearRetainingCapacity();
    try searchAll(&cs, lines, 0, 2, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);

    var wide = try Searcher.init(testing.allocator, "本", .{});
    defer wide.deinit();
    out.clearRetainingCapacity();
    try searchAll(&wide, lines, 0, 0, &out);
    try testing.expectEqual(Match.single(0, 9, 10), out.items[0]);
}

test "regex search" {
    if (!regex_supported) return;
    const rows = try sel.testRows(testing.allocator, &.{"id=42 id=7 x=1"}, 20);
    defer sel.freeTestRows(testing.allocator, rows);
    var s = try Searcher.init(testing.allocator, "id=[0-9]+", .{ .regex = true });
    defer s.deinit();
    var out = std.ArrayList(Match).init(testing.allocator);
    defer out.deinit();
    try searchAll(&s, sel.TestLines{ .rows = rows }, 0, 0, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqual(Match.single(0, 6, 9), out.items[1]);
    try testing.expectError(error.BadRegex, Searcher.init(testing.allocator, "(", .{ .regex = true }));
    // Zero-length matches don't loop forever.
    var z = try Searcher.init(testing.allocator, "x*", .{ .regex = true });
    defer z.deinit();
    out.clearRetainingCapacity();
    try searchAll(&z, sel.TestLines{ .rows = rows }, 0, 0, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
}

test "step wraps in both directions" {
    const m = [_]Match{ Match.single(0, 0, 0), Match.single(1, 0, 0) };
    try testing.expectEqual(@as(?usize, 1), step(&m, null, false));
    try testing.expectEqual(@as(?usize, 0), step(&m, 1, true));
    try testing.expectEqual(@as(?usize, 1), step(&m, 0, false));
    try testing.expectEqual(@as(?usize, null), step(&[_]Match{}, null, true));
}

test "matches span soft-wrapped rows" {
    var term = try terminal.Terminal.initBuffer(testing.allocator, 4, 8, 10);
    defer term.deinit();
    // "hello world" wraps after "hello wo".
    try term.processOutput("hello world\r\nxx");
    var s = try Searcher.init(testing.allocator, "world", .{});
    defer s.deinit();
    var out = std.ArrayList(Match).init(testing.allocator);
    defer out.deinit();
    try searchAll(&s, &term, term.screenTop(), term.screenTop() + 3, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(Match{ .line = 0, .start = 6, .end_line = 1, .end = 2 }, out.items[0]);
    try testing.expectEqual(@as(i64, 0), logicalStart(&term, 1, 0));
}
