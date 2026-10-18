const std = @import("std");
const terminal = @import("terminal.zig");
const Cell = terminal.Cell;

/// Scrollback stores lines that have scrolled off the top of the viewport.
/// Once full it is a ring: the oldest line is recycled in O(1).
pub const Line = struct {
    /// Allocation (capacity); recycled ring slots keep their buffer.
    buf: []Cell,
    len: usize,

    pub fn cells(self: Line) []Cell {
        return self.buf[0..self.len];
    }
};

pub const Scrollback = struct {
    allocator: std.mem.Allocator,
    lines: std.ArrayList(Line),
    max_lines: usize,
    /// Ring start (index of the oldest line) once `lines` is full.
    head: usize = 0,
    /// Lines ever pushed. Absolute line numbers (selection, search) are
    /// based on this, so they stay valid while history scrolls.
    total: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, max_lines: usize) Scrollback {
        return Scrollback{
            .allocator = allocator,
            .lines = std.ArrayList(Line).init(allocator),
            .max_lines = max_lines,
        };
    }

    pub fn deinit(self: *Scrollback) void {
        for (self.lines.items) |line| self.allocator.free(line.buf);
        self.lines.deinit();
    }

    /// Push a row of cells into scrollback history. Trailing default blanks
    /// are not stored (a `yes` line costs one cell, not a full row).
    pub fn pushLine(self: *Scrollback, line_in: []const Cell) !void {
        if (self.max_lines == 0) {
            self.total += 1;
            return;
        }
        const line = trimmed(line_in);
        if (self.lines.items.len < self.max_lines) {
            const copy = try self.allocator.alloc(Cell, line.len);
            @memcpy(copy, line);
            try self.lines.append(.{ .buf = copy, .len = line.len });
        } else {
            // Recycle the oldest slot, reusing its buffer when it is big enough.
            const slot = &self.lines.items[self.head];
            if (slot.buf.len < line.len) {
                const copy = try self.allocator.alloc(Cell, line.len);
                self.allocator.free(slot.buf);
                slot.buf = copy;
            }
            @memcpy(slot.buf[0..line.len], line);
            slot.len = line.len;
            self.head = (self.head + 1) % self.lines.items.len;
        }
        self.total += 1;
    }

    /// Take ownership of a heap row (used by reflow).
    pub fn appendOwned(self: *Scrollback, row: []Cell) !void {
        try self.lines.append(.{ .buf = row, .len = trimmed(row).len });
    }

    pub fn len(self: *const Scrollback) usize {
        return self.lines.items.len;
    }

    /// Get a line by index, where 0 is the oldest line.
    pub fn getLine(self: *const Scrollback, index: usize) ?[]const Cell {
        const n = self.lines.items.len;
        if (index >= n) return null;
        return self.lines.items[(self.head + index) % n].cells();
    }

    pub fn clear(self: *Scrollback) void {
        for (self.lines.items) |line| self.allocator.free(line.buf);
        self.lines.clearRetainingCapacity();
        self.head = 0;
    }

    /// Write a scrollback line as UTF-8 (wide-char spacers skipped).
    pub fn lineText(self: *const Scrollback, index: usize, writer: anytype) !void {
        const line = self.getLine(index) orelse return;
        try terminal.appendRowText(line, writer);
    }

    /// Return oldest-first indices of lines containing `query`.
    pub fn search(self: *const Scrollback, query: []const u8, allocator: std.mem.Allocator) ![]usize {
        var hits = std.ArrayList(usize).init(allocator);
        errdefer hits.deinit();
        if (query.len == 0) return hits.toOwnedSlice();

        var buf = std.ArrayList(u8).init(allocator);
        defer buf.deinit();
        for (0..self.lines.items.len) |i| {
            buf.clearRetainingCapacity();
            try self.lineText(i, buf.writer());
            if (std.mem.indexOf(u8, buf.items, query) != null) {
                try hits.append(i);
            }
        }
        return hits.toOwnedSlice();
    }
};

fn isDefaultBlank(c: Cell) bool {
    const d = Cell.init();
    return (c.char == ' ' or c.char == 0) and c.width == 1 and c.combining[0] == 0 and
        c.bg_color == d.bg_color and !c.underline and !c.inverse and !c.strikethrough and c.link == 0 and !c.soft_wrap;
}

fn trimmed(line: []const Cell) []const Cell {
    var n = line.len;
    while (n > 0 and isDefaultBlank(line[n - 1])) n -= 1;
    return line[0..n];
}

test "Scrollback push and trim" {
    const testing = std.testing;
    var scrollback = Scrollback.init(testing.allocator, 2);
    defer scrollback.deinit();

    var line1 = [_]Cell{Cell.init()} ** 3;
    line1[0].char = 'A';
    try scrollback.pushLine(&line1);

    var line2 = [_]Cell{Cell.init()} ** 3;
    line2[0].char = 'B';
    try scrollback.pushLine(&line2);

    var line3 = [_]Cell{Cell.init()} ** 3;
    line3[0].char = 'C';
    try scrollback.pushLine(&line3);

    try testing.expectEqual(@as(usize, 2), scrollback.len());
    try testing.expectEqual(@as(u21, 'B'), scrollback.getLine(0).?[0].char);
    try testing.expectEqual(@as(u21, 'C'), scrollback.getLine(1).?[0].char);

    var text = std.ArrayList(u8).init(testing.allocator);
    defer text.deinit();
    try scrollback.lineText(1, text.writer());
    try testing.expectEqualStrings("C", text.items); // trailing blanks are not stored

    const hits = try scrollback.search("C", testing.allocator);
    defer testing.allocator.free(hits);
    try testing.expectEqual(@as(usize, 1), hits.len);
}

test "Scrollback search matches UTF-8" {
    const testing = std.testing;
    var scrollback = Scrollback.init(testing.allocator, 4);
    defer scrollback.deinit();

    var line = [_]Cell{Cell.init()} ** 4;
    line[0].char = 0x65E5; // 日 (wide)
    line[0].width = 2;
    line[1].width = 0;
    line[2].char = 0xE9; // é
    try scrollback.pushLine(&line);

    const hits = try scrollback.search("\u{65e5}\u{e9}", testing.allocator);
    defer testing.allocator.free(hits);
    try testing.expectEqual(@as(usize, 1), hits.len);
}
