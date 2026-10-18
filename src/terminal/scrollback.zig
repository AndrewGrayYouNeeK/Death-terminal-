const std = @import("std");
const terminal = @import("terminal.zig");
const Cell = terminal.Cell;

/// Scrollback stores lines that have scrolled off the top of the viewport.
/// Once full it is a ring: the oldest line is recycled in O(1).
pub const Scrollback = struct {
    allocator: std.mem.Allocator,
    lines: std.ArrayList([]Cell),
    max_lines: usize,
    /// Ring start (index of the oldest line) once `lines` is full.
    head: usize = 0,
    /// Lines ever pushed. Absolute line numbers (selection, search) are
    /// based on this, so they stay valid while history scrolls.
    total: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, max_lines: usize) Scrollback {
        return Scrollback{
            .allocator = allocator,
            .lines = std.ArrayList([]Cell).init(allocator),
            .max_lines = max_lines,
        };
    }

    pub fn deinit(self: *Scrollback) void {
        for (self.lines.items) |line| {
            self.allocator.free(line);
        }
        self.lines.deinit();
    }

    /// Push a full row of cells into scrollback history.
    pub fn pushLine(self: *Scrollback, line: []const Cell) !void {
        if (self.max_lines == 0) {
            self.total += 1;
            return;
        }
        if (self.lines.items.len < self.max_lines) {
            const copy = try self.allocator.alloc(Cell, line.len);
            @memcpy(copy, line);
            try self.lines.append(copy);
        } else {
            // Recycle the oldest slot.
            const slot = &self.lines.items[self.head];
            if (slot.len != line.len) {
                const copy = try self.allocator.alloc(Cell, line.len);
                self.allocator.free(slot.*);
                slot.* = copy;
            }
            @memcpy(slot.*, line);
            self.head = (self.head + 1) % self.lines.items.len;
        }
        self.total += 1;
    }

    pub fn len(self: *const Scrollback) usize {
        return self.lines.items.len;
    }

    /// Get a line by index, where 0 is the oldest line.
    pub fn getLine(self: *const Scrollback, index: usize) ?[]const Cell {
        const n = self.lines.items.len;
        if (index >= n) return null;
        return self.lines.items[(self.head + index) % n];
    }

    pub fn clear(self: *Scrollback) void {
        for (self.lines.items) |line| {
            self.allocator.free(line);
        }
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
    try testing.expectEqualStrings("C  ", text.items);

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
