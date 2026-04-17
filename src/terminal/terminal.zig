const std = @import("std");

/// Terminal represents the core terminal emulator functionality
/// Handles PTY (pseudo-terminal) creation, process spawning, and I/O
pub const Terminal = struct {
    allocator: std.mem.Allocator,
    rows: u16,
    cols: u16,
    buffer: []u8,
    initialized: bool,

    pub fn init(allocator: std.mem.Allocator) !Terminal {
        // TODO: Initialize PTY, spawn shell process
        std.debug.print("  → Terminal core stub initialized (80x24)\n", .{});

        const default_rows = 24;
        const default_cols = 80;
        const buffer = try allocator.alloc(u8, default_rows * default_cols);

        return Terminal{
            .allocator = allocator,
            .rows = default_rows,
            .cols = default_cols,
            .buffer = buffer,
            .initialized = true,
        };
    }

    pub fn deinit(self: *Terminal) void {
        self.allocator.free(self.buffer);
        self.initialized = false;
    }

    pub fn resize(self: *Terminal, rows: u16, cols: u16) !void {
        // TODO: Resize PTY and update buffer
        self.rows = rows;
        self.cols = cols;
    }

    pub fn write(self: *Terminal, data: []const u8) !void {
        _ = self;
        _ = data;
        // TODO: Write data to PTY
    }

    pub fn read(self: *Terminal, buffer: []u8) !usize {
        _ = self;
        _ = buffer;
        // TODO: Read data from PTY
        return 0;
    }
};

test "Terminal init" {
    const testing = std.testing;
    var term = try Terminal.init(testing.allocator);
    defer term.deinit();
    try testing.expect(term.initialized);
    try testing.expectEqual(@as(u16, 24), term.rows);
    try testing.expectEqual(@as(u16, 80), term.cols);
}
