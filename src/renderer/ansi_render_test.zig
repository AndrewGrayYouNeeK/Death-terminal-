//! Feed ANSI through the terminal, then assert the frame's colours, cursor
//! and that the glyph atlas actually received ink.

const std = @import("std");
const builtin = @import("builtin");
const t = std.testing;
const Terminal = @import("../terminal/terminal.zig").Terminal;
const frame_mod = @import("frame.zig");
const fonts_mod = @import("../font/fonts.zig");
const cmod = @import("../font/c.zig");
const color = @import("../terminal/color.zig");

test "render: ANSI sets cell colour, cursor, and atlas glyphs" {
    if (!cmod.available) return error.SkipZigTest;
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var term = try Terminal.initBuffer(t.allocator, 4, 16, 8);
    defer term.deinit();
    try term.processOutput("\x1b[1;31mZ\x1b[0m\x1b[2;4H");
    try t.expectEqual(@as(u16, 1), term.cursor_row);
    try t.expectEqual(@as(u16, 3), term.cursor_col);
    const cell = term.screenRow(0)[0];
    try t.expectEqual(@as(u21, 'Z'), cell.char);
    try t.expect(cell.bold);
    try t.expect(cell.fg_color != color.default_fg);

    var fonts = try fonts_mod.Fonts.init(t.allocator, .{});
    defer fonts.deinit();
    if (fonts.isRetro()) return error.SkipZigTest;

    const rows = term.rows;
    const cols = term.cols;
    const grid = try t.allocator.alloc(@import("../terminal/terminal.zig").Cell, @as(usize, rows) * cols);
    defer t.allocator.free(grid);
    for (0..rows) |r| @memcpy(grid[r * cols ..][0..cols], term.screenRow(@intCast(r)));

    var frame = frame_mod.Frame.init(t.allocator);
    defer frame.deinit();
    var view = frame_mod.View.fromTerminal(&term);
    view.cursor_visible = true;
    view.focused = true;
    try frame.build(&fonts, grid, rows, cols, term.cursor_row, term.cursor_col, view);

    var glyphs: usize = 0;
    var ink = false;
    for (frame.quads.items) |q| {
        if (q.kind == .mono or q.kind == .colored) {
            glyphs += 1;
            if (q.uw > 0 and q.vh > 0) ink = true;
        }
    }
    try t.expect(glyphs > 0);
    try t.expect(ink);
    var painted: usize = 0;
    for (fonts.atlas.pixels) |b| painted += if (b != 0) 1 else 0;
    try t.expect(painted > 0);
    std.debug.print("render test: {d} glyph quads, {d} atlas bytes with ink, cursor {d},{d}\n", .{
        glyphs, painted, term.cursor_row, term.cursor_col,
    });
}
