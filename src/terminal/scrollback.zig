const std = @import("std");
const Cell = @import("terminal.zig").Cell;

/// Scrollback stores lines that have scrolled off the top of the viewport.
pub const Scrollback = struct {
    allocator: std.mem.Allocator,
    lines: std.ArrayList([]Cell),
    max_lines: usize,

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
        const copy = try self.allocator.alloc(Cell, line.len);
        @memcpy(copy, line);
        try self.lines.append(copy);

        while (self.lines.items.len > self.max_lines) {
            const oldest = self.lines.orderedRemove(0);
            self.allocator.free(oldest);
        }
    }

    pub fn len(self: *const Scrollback) usize {
        return self.lines.items.len;
    }

    /// Get a line by index, where 0 is the oldest line.
    pub fn getLine(self: *const Scrollback, index: usize) ?[]const Cell {
        if (index >= self.lines.items.len) return null;
        return self.lines.items[index];
    }

    pub fn clear(self: *Scrollback) void {
        for (self.lines.items) |line| {
            self.allocator.free(line);
        }
        self.lines.clearRetainingCapacity();
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
}
