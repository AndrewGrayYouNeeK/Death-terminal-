//! CPU fallback renderer: rasterizes a `frame.Frame` (quads + glyph atlas)
//! into a packed 0xAARRGGBB framebuffer for SHM / XPutImage / GDI present.

const std = @import("std");
const frame_mod = @import("frame.zig");
const Atlas = @import("../font/atlas.zig").Atlas;

pub const View = frame_mod.View;
pub const cellColors = frame_mod.cellColors;

pub const CellPx = struct { w: u32, h: u32 };

pub const SoftwareRenderer = struct {
    allocator: std.mem.Allocator,
    pixels: []u32,
    width: u32,
    height: u32,
    dirty: bool,

    pub fn init(allocator: std.mem.Allocator, cols: u16, rows: u16, cell: CellPx) !SoftwareRenderer {
        const width = @max(1, @as(u32, cols) * cell.w);
        const height = @max(1, @as(u32, rows) * cell.h);
        const pixels = try allocator.alloc(u32, width * height);
        @memset(pixels, 0xFF000000);
        return .{ .allocator = allocator, .pixels = pixels, .width = width, .height = height, .dirty = true };
    }

    pub fn deinit(self: *SoftwareRenderer) void {
        self.allocator.free(self.pixels);
        self.pixels = &.{};
    }

    /// Resize to an exact pixel size (the window size).
    pub fn resizePixels(self: *SoftwareRenderer, width: u32, height: u32) !void {
        const w = @max(1, width);
        const h = @max(1, height);
        if (w == self.width and h == self.height) return;
        const pixels = try self.allocator.alloc(u32, w * h);
        self.allocator.free(self.pixels);
        self.pixels = pixels;
        self.width = w;
        self.height = h;
        self.dirty = true;
        @memset(self.pixels, 0xFF000000);
    }

    pub fn render(self: *SoftwareRenderer, fr: *const frame_mod.Frame, atlas: *const Atlas) void {
        @memset(self.pixels, 0xFF000000 | (fr.clear & 0xFFFFFF));
        for (fr.quads.items) |q| self.drawQuad(q, atlas);
        self.dirty = true;
    }

    fn drawQuad(self: *SoftwareRenderer, q: frame_mod.Quad, atlas: *const Atlas) void {
        const x0: i64 = @intFromFloat(@round(q.x));
        const y0: i64 = @intFromFloat(@round(q.y));
        const w: i64 = @intFromFloat(@round(q.w));
        const h: i64 = @intFromFloat(@round(q.h));
        const tu0: i64 = @intFromFloat(q.u);
        const tv0: i64 = @intFromFloat(q.v);
        var dy: i64 = 0;
        while (dy < h) : (dy += 1) {
            const py = y0 + dy;
            if (py < 0 or py >= self.height) continue;
            var dx: i64 = 0;
            while (dx < w) : (dx += 1) {
                const px = x0 + dx;
                if (px < 0 or px >= self.width) continue;
                const idx: usize = @intCast(py * @as(i64, self.width) + px);
                switch (q.kind) {
                    .solid => self.pixels[idx] = 0xFF000000 | (q.rgb & 0xFFFFFF),
                    .mono, .colored => {
                        const tx = tu0 + dx;
                        const ty = tv0 + dy;
                        if (tx < 0 or ty < 0 or tx >= atlas.size or ty >= atlas.size) continue;
                        const t = atlas.texel(@intCast(tx), @intCast(ty));
                        if (t[3] == 0) continue;
                        const src: [4]u32 = if (q.kind == .mono) .{
                            ((q.rgb >> 16) & 0xFF) * t[3] / 255,
                            ((q.rgb >> 8) & 0xFF) * t[3] / 255,
                            (q.rgb & 0xFF) * t[3] / 255,
                            t[3],
                        } else .{ t[0], t[1], t[2], t[3] };
                        self.pixels[idx] = blendOver(self.pixels[idx], src);
                    },
                }
            }
        }
    }
};

/// Premultiplied `src` (r,g,b,a 0-255) over opaque 0xAARRGGBB `dst`.
fn blendOver(dst: u32, src: [4]u32) u32 {
    const inv = 255 - src[3];
    const r = src[0] + ((dst >> 16) & 0xFF) * inv / 255;
    const g = src[1] + ((dst >> 8) & 0xFF) * inv / 255;
    const b = src[2] + (dst & 0xFF) * inv / 255;
    const rr: u32 = @min(r, 255);
    const gg: u32 = @min(g, 255);
    const bb: u32 = @min(b, 255);
    return 0xFF000000 | (rr << 16) | (gg << 8) | bb;
}

const Fonts = @import("../font/fonts.zig").Fonts;
const Cell = @import("../terminal/terminal.zig").Cell;

test "software renderer allocates framebuffer" {
    var r = try SoftwareRenderer.init(std.testing.allocator, 10, 2, .{ .w = 8, .h = 16 });
    defer r.deinit();
    try std.testing.expectEqual(@as(u32, 80), r.width);
    try std.testing.expectEqual(@as(u32, 32), r.height);
    try r.resizePixels(100, 50);
    try std.testing.expectEqual(@as(usize, 5000), r.pixels.len);
}

test "software renderer draws glyph pixels in the fg colour over bg" {
    var f = try Fonts.init(std.testing.allocator, .{ .retro = true });
    defer f.deinit();
    var cells = [_]Cell{ Cell.init(), Cell.init() };
    cells[0].char = 0x2588; // full block
    cells[0].fg_color = 0x00FF00;
    cells[1].bg_color = 0x0000FF;
    var fr = frame_mod.Frame.init(std.testing.allocator);
    defer fr.deinit();
    try fr.build(&f, &cells, 1, 2, 0, 0, .{ .cursor_visible = false });
    var r = try SoftwareRenderer.init(std.testing.allocator, 2, 1, .{ .w = 8, .h = 16 });
    defer r.deinit();
    r.render(&fr, &f.atlas);
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), r.pixels[8 * 16 / 2 * 0 + 3]);
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), r.pixels[5 * 16 + 12]);
}

test "blendOver mixes premultiplied coverage" {
    try std.testing.expectEqual(@as(u32, 0xFF808080), blendOver(0xFF000000, .{ 128, 128, 128, 128 }));
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), blendOver(0xFF123456, .{ 255, 255, 255, 255 }));
}
