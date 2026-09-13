const std = @import("std");
const Cell = @import("../terminal/terminal.zig").Cell;

pub const CELL_W: u32 = 8;
pub const CELL_H: u32 = 16;

pub const SoftwareRenderer = struct {
    allocator: std.mem.Allocator,
    pixels: []u32,
    width: u32,
    height: u32,
    dirty: bool,

    pub fn init(allocator: std.mem.Allocator, cols: u16, rows: u16) !SoftwareRenderer {
        const width = @as(u32, cols) * CELL_W;
        const height = @as(u32, rows) * CELL_H;
        const pixels = try allocator.alloc(u32, width * height);
        @memset(pixels, 0xFF000000);
        return .{
            .allocator = allocator,
            .pixels = pixels,
            .width = width,
            .height = height,
            .dirty = true,
        };
    }

    pub fn deinit(self: *SoftwareRenderer) void {
        self.allocator.free(self.pixels);
        self.pixels = &.{};
    }

    pub fn resize(self: *SoftwareRenderer, cols: u16, rows: u16) !void {
        const width = @as(u32, cols) * CELL_W;
        const height = @as(u32, rows) * CELL_H;
        const pixels = try self.allocator.alloc(u32, width * height);
        @memset(pixels, 0xFF000000);
        self.allocator.free(self.pixels);
        self.pixels = pixels;
        self.width = width;
        self.height = height;
        self.dirty = true;
    }

    pub fn renderGrid(self: *SoftwareRenderer, cells: []const Cell, rows: u16, cols: u16, cursor_row: u16, cursor_col: u16, cursor_visible: bool) void {
        @memset(self.pixels, 0xFF000000);
        var row: u16 = 0;
        while (row < rows) : (row += 1) {
            var col: u16 = 0;
            while (col < cols) : (col += 1) {
                const idx = @as(usize, row) * cols + col;
                if (idx >= cells.len) break;
                blit(self, col, row, cells[idx], cursor_visible and row == cursor_row and col == cursor_col);
            }
        }
        self.dirty = true;
    }
};

fn blit(self: *SoftwareRenderer, col: u16, row: u16, cell: Cell, invert: bool) void {
    const ox = @as(u32, col) * CELL_W;
    const oy = @as(u32, row) * CELL_H;
    var fg = cell.fg_color | 0xFF000000;
    var bg = cell.bg_color | 0xFF000000;
    if (invert) {
        const tmp = fg;
        fg = bg;
        bg = tmp;
    }
    const bits = glyph(cell.char);
    var gy: u32 = 0;
    while (gy < CELL_H) : (gy += 1) {
        const row_bits = bits[gy / 2];
        var gx: u32 = 0;
        while (gx < CELL_W) : (gx += 1) {
            const on = (row_bits & (@as(u8, 0x80) >> @intCast(gx))) != 0;
            const px = ox + gx;
            const py = oy + gy;
            if (px >= self.width or py >= self.height) continue;
            self.pixels[py * self.width + px] = if (on) fg else bg;
        }
    }
}

fn glyph(cp: u21) [8]u8 {
    return switch (cp) {
        ' ' => .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        '0' => .{ 0x3C, 0x66, 0x6E, 0x76, 0x66, 0x3C, 0, 0 },
        '1' => .{ 0x18, 0x38, 0x18, 0x18, 0x18, 0x7E, 0, 0 },
        'A', 'a' => .{ 0x18, 0x3C, 0x66, 0x7E, 0x66, 0x66, 0, 0 },
        else => .{ 0x7E, 0x42, 0x42, 0x42, 0x42, 0x7E, 0, 0 },
    };
}

test "software renderer allocates framebuffer" {
    var r = try SoftwareRenderer.init(std.testing.allocator, 4, 2);
    defer r.deinit();
    try std.testing.expectEqual(@as(u32, 32), r.width);
}
