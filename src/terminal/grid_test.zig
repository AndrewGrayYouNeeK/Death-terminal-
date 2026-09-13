const std = @import("std");
const terminal = @import("terminal.zig");

test "buffer writes and wraps" {
    var term = try terminal.Terminal.initBuffer(std.testing.allocator, 3, 8, 4);
    defer term.deinit();

    try term.processOutput("hi");
    try std.testing.expectEqual(@as(u21, 'h'), term.getCell(0, 0).?.char);
    try std.testing.expectEqual(@as(u21, 'i'), term.getCell(0, 1).?.char);
    try std.testing.expectEqual(@as(u16, 2), term.cursor_col);
}

test "ansi clear and color" {
    var term = try terminal.Terminal.initBuffer(std.testing.allocator, 2, 10, 4);
    defer term.deinit();

    try term.processOutput("abc");
    try term.processOutput("\x1b[2J");
    try std.testing.expectEqual(@as(u21, ' '), term.getCell(0, 0).?.char);
    try std.testing.expectEqual(@as(u16, 0), term.cursor_row);

    try term.processOutput("\x1b[31mX");
    try std.testing.expectEqual(@as(u21, 'X'), term.getCell(0, 0).?.char);
    try std.testing.expectEqual(@as(u32, 0xCD0000), term.getCell(0, 0).?.fg_color);
}

test "scrollback receives scrolled line" {
    var term = try terminal.Terminal.initBuffer(std.testing.allocator, 2, 4, 8);
    defer term.deinit();

    try term.processOutput("AAAA\r\nBBBB\r\n");
    try std.testing.expect(term.scrollbackLen() >= 1);
}
