const std = @import("std");
const Cell = @import("../terminal/terminal.zig").Cell;
const software = @import("software.zig");

pub const MAX_INSTANCES: u32 = 32768;

/// Per-cell instance consumed by the GPU text vertex shader.
pub const Instance = extern struct {
    origin: [2]f32,
    size: [2]f32,
    uv_origin: [2]f32,
    uv_size: [2]f32,
    fg: [4]f32,
    bg: [4]f32,
};

pub const Vertex = extern struct {
    corner: [2]f32,
};

pub const QUAD_VERTS = [_]Vertex{
    .{ .corner = .{ 0, 0 } },
    .{ .corner = .{ 1, 0 } },
    .{ .corner = .{ 1, 1 } },
    .{ .corner = .{ 0, 1 } },
};

pub const QUAD_INDICES = [_]u16{ 0, 1, 2, 2, 3, 0 };

pub fn colorToVec(rgb: u32) [4]f32 {
    const r = @as(f32, @floatFromInt((rgb >> 16) & 0xFF)) / 255.0;
    const g = @as(f32, @floatFromInt((rgb >> 8) & 0xFF)) / 255.0;
    const b = @as(f32, @floatFromInt(rgb & 0xFF)) / 255.0;
    return .{ r, g, b, 1.0 };
}

pub fn glyphUv(cp: u21) struct { origin: [2]f32, size: [2]f32 } {
    const i = software.atlasIndex(cp);
    const gx = i % software.ATLAS_COLS;
    const gy = i / software.ATLAS_COLS;
    const aw: f32 = @floatFromInt(software.ATLAS_COLS * software.GLYPH_PX);
    const ah: f32 = @floatFromInt(software.ATLAS_ROWS * software.GLYPH_PX);
    const gw: f32 = @floatFromInt(software.GLYPH_PX);
    return .{
        .origin = .{ @as(f32, @floatFromInt(gx)) * gw / aw, @as(f32, @floatFromInt(gy)) * gw / ah },
        .size = .{ gw / aw, gw / ah },
    };
}

/// Generate one instance per cell plus overlay quads (underline,
/// strikethrough, bar/underline cursor). Overlays use fg == bg so they draw
/// solid regardless of the glyph sampled. Returns the count written.
pub fn packInstances(
    out: []Instance,
    cells: []const Cell,
    rows: u16,
    cols: u16,
    cursor_row: u16,
    cursor_col: u16,
    view: software.View,
    fb_w: f32,
    fb_h: f32,
    cell_w: f32,
    cell_h: f32,
) u32 {
    if (fb_w <= 0 or fb_h <= 0 or rows == 0 or cols == 0) return 0;
    const size = [2]f32{ 2.0 * cell_w / fb_w, 2.0 * cell_h / fb_h };
    const blank_uv = glyphUv(' ');

    var count: u32 = 0;
    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        var col: u16 = 0;
        while (col < cols) : (col += 1) {
            if (count >= out.len) return count;
            const idx = @as(usize, row) * @as(usize, cols) + col;
            const cell = if (idx < cells.len) cells[idx] else Cell.init();
            const at_cursor = view.cursor_visible and row == cursor_row and col == cursor_col;
            const colors = software.cellColors(cell, view, at_cursor and view.cursor_shape == .block);
            const fg = colorToVec(colors.fg);
            const uv = glyphUv(if (cell.hidden) ' ' else cell.char);
            const origin = [2]f32{
                -1.0 + 2.0 * (@as(f32, @floatFromInt(col)) * cell_w) / fb_w,
                -1.0 + 2.0 * (@as(f32, @floatFromInt(row)) * cell_h) / fb_h,
            };
            out[count] = .{
                .origin = origin,
                .size = size,
                .uv_origin = uv.origin,
                .uv_size = uv.size,
                .fg = fg,
                .bg = colorToVec(colors.bg),
            };
            count += 1;

            const visible = !cell.hidden;
            if (visible and cell.underline) count = overlay(out, count, origin, size, software.underline_rect, fg, blank_uv);
            if (visible and cell.strikethrough) count = overlay(out, count, origin, size, software.strike_rect, fg, blank_uv);
            if (at_cursor) {
                const cfg = colorToVec(software.cellColors(cell, view, false).fg);
                switch (view.cursor_shape) {
                    .block => {},
                    .bar => count = overlay(out, count, origin, size, software.cursor_bar_rect, cfg, blank_uv),
                    .underline => count = overlay(out, count, origin, size, software.cursor_underline_rect, cfg, blank_uv),
                }
            }
        }
    }
    return count;
}

fn overlay(out: []Instance, count: u32, origin: [2]f32, size: [2]f32, r: software.Overlay, c: [4]f32, uv: anytype) u32 {
    if (count >= out.len) return count;
    out[count] = .{
        .origin = .{ origin[0] + r.x * size[0], origin[1] + r.y * size[1] },
        .size = .{ r.w * size[0], r.h * size[1] },
        .uv_origin = uv.origin,
        .uv_size = uv.size,
        .fg = c,
        .bg = c,
    };
    return count + 1;
}

test "packInstances writes one instance per cell" {
    var cells = [_]Cell{ Cell.init(), Cell.init() };
    cells[0].char = 'A';
    cells[0].fg_color = 0xFFFFFF;
    var out: [4]Instance = undefined;
    const n = packInstances(&out, &cells, 1, 2, 0, 1, .{}, 16, 16, 8, 16);
    try std.testing.expectEqual(@as(u32, 2), n);
    try std.testing.expect(out[0].fg[0] > 0.9);
    try std.testing.expect(out[1].bg[0] > 0.9); // cursor inverts cell 1
}

test "Instance stride is 64 bytes" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(Instance));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Vertex));
}

test "packInstances adds overlays for underline and bar cursor" {
    var cells = [_]Cell{ Cell.init(), Cell.init() };
    cells[0].underline = true;
    var out: [8]Instance = undefined;
    const n = packInstances(&out, &cells, 1, 2, 0, 1, .{ .cursor_shape = .bar }, 16, 16, 8, 16);
    try std.testing.expectEqual(@as(u32, 4), n); // 2 cells + underline + bar
    try std.testing.expectEqual(out[1].fg[0], out[1].bg[0]); // overlay is solid
    try std.testing.expect(out[3].size[0] < out[2].size[0]); // bar is narrow
}
