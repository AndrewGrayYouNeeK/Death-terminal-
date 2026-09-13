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

/// Generate one instance per visible cell. Returns the count written.
pub fn packInstances(
    out: []Instance,
    cells: []const Cell,
    rows: u16,
    cols: u16,
    cursor_row: u16,
    cursor_col: u16,
    cursor_visible: bool,
    fb_w: f32,
    fb_h: f32,
) u32 {
    if (fb_w <= 0 or fb_h <= 0 or rows == 0 or cols == 0) return 0;
    const cell_w = @as(f32, @floatFromInt(software.CELL_W));
    const cell_h = @as(f32, @floatFromInt(software.CELL_H));
    const size = [2]f32{ 2.0 * cell_w / fb_w, 2.0 * cell_h / fb_h };

    var count: u32 = 0;
    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        var col: u16 = 0;
        while (col < cols) : (col += 1) {
            if (count >= out.len) return count;
            const idx = @as(usize, row) * @as(usize, cols) + col;
            const cell = if (idx < cells.len) cells[idx] else Cell.init();
            const invert = cursor_visible and row == cursor_row and col == cursor_col;
            var fg = colorToVec(cell.fg_color);
            var bg = colorToVec(cell.bg_color);
            if (invert) {
                const tmp = fg;
                fg = bg;
                bg = tmp;
            }
            const uv = glyphUv(cell.char);
            out[count] = .{
                .origin = .{
                    -1.0 + 2.0 * (@as(f32, @floatFromInt(col)) * cell_w) / fb_w,
                    -1.0 + 2.0 * (@as(f32, @floatFromInt(row)) * cell_h) / fb_h,
                },
                .size = size,
                .uv_origin = uv.origin,
                .uv_size = uv.size,
                .fg = fg,
                .bg = bg,
            };
            count += 1;
        }
    }
    return count;
}

test "packInstances writes one instance per cell" {
    var cells = [_]Cell{ Cell.init(), Cell.init() };
    cells[0].char = 'A';
    cells[0].fg_color = 0xFFFFFF;
    var out: [4]Instance = undefined;
    const n = packInstances(&out, &cells, 1, 2, 0, 1, true, 16, 16);
    try std.testing.expectEqual(@as(u32, 2), n);
    try std.testing.expect(out[0].fg[0] > 0.9);
    try std.testing.expect(out[1].bg[0] > 0.9); // cursor inverts cell 1
}

test "Instance stride is 64 bytes" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(Instance));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Vertex));
}
