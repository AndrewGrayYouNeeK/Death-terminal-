//! Converts frame quads into GPU instances for the text pipeline.
//!
//! Instances are in framebuffer pixels and atlas texels; the vertex shader
//! normalises with push constants, so cached instances stay valid when the
//! window is resized or the atlas grows.

const std = @import("std");
const frame_mod = @import("frame.zig");

pub const MAX_INSTANCES: u32 = 1 << 18;

/// Per-quad instance consumed by the text vertex shader (32 bytes).
pub const Instance = extern struct {
    /// Top-left and size in framebuffer pixels.
    origin: [2]f32,
    size: [2]f32,
    /// Atlas texel rect.
    uv_origin: [2]u16,
    uv_size: [2]u16,
    /// sRGB 0xAABBGGRR (R8G8B8A8_UNORM in memory); linearised in the shader.
    color: u32,
    /// 0 solid, 1 mono glyph (coverage in alpha), 2 colour glyph.
    kind: u32,
};

/// Push constants shared by every instance of a draw.
pub const PushConstants = extern struct {
    inv_viewport: [2]f32,
    inv_atlas: [2]f32,
    srgb: u32,
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

fn srgbToLinear(v: f32) f32 {
    return if (v <= 0.04045) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
}

/// 0xRRGGBB → RGBA floats; linearised when the target is an sRGB image
/// (used for the clear colour).
pub fn colorToVec(rgb: u32, srgb_target: bool) [4]f32 {
    var out = [4]f32{
        @as(f32, @floatFromInt((rgb >> 16) & 0xFF)) / 255.0,
        @as(f32, @floatFromInt((rgb >> 8) & 0xFF)) / 255.0,
        @as(f32, @floatFromInt(rgb & 0xFF)) / 255.0,
        1.0,
    };
    if (srgb_target) {
        for (out[0..3]) |*c| c.* = srgbToLinear(c.*);
    }
    return out;
}

fn texel(v: f32) u16 {
    return @intFromFloat(std.math.clamp(v, 0, 65535));
}

pub fn instanceOf(q: frame_mod.Quad) Instance {
    const r = (q.rgb >> 16) & 0xFF;
    const g = (q.rgb >> 8) & 0xFF;
    const b = q.rgb & 0xFF;
    return .{
        .origin = .{ q.x, q.y },
        .size = .{ q.w, q.h },
        .uv_origin = .{ texel(q.u), texel(q.v) },
        .uv_size = .{ texel(q.uw), texel(q.vh) },
        .color = r | (g << 8) | (b << 16) | (0xFF << 24),
        .kind = @intFromEnum(q.kind),
    };
}

/// Write instances for `quads`; returns the count written.
pub fn packQuads(out: []Instance, quads: []const frame_mod.Quad) u32 {
    const n = @min(out.len, quads.len);
    for (out[0..n], quads[0..n]) |*o, q| o.* = instanceOf(q);
    return @intCast(n);
}

pub fn pushConstants(fb_w: u32, fb_h: u32, atlas_size: u32, srgb_target: bool) PushConstants {
    return .{
        .inv_viewport = .{ 1.0 / @as(f32, @floatFromInt(@max(fb_w, 1))), 1.0 / @as(f32, @floatFromInt(@max(fb_h, 1))) },
        .inv_atlas = .{ 1.0 / @as(f32, @floatFromInt(@max(atlas_size, 1))), 1.0 / @as(f32, @floatFromInt(@max(atlas_size, 1))) },
        .srgb = @intFromBool(srgb_target),
    };
}

/// A small set of dirty instance ranges for one GPU buffer; merges when it
/// would grow past `max` entries.
pub const RangeSet = struct {
    items: [max]frame_mod.Range = undefined,
    len: usize = 0,
    all: bool = true,

    pub const max = 16;

    pub fn setAll(self: *RangeSet) void {
        self.all = true;
        self.len = 0;
    }

    pub fn clear(self: *RangeSet) void {
        self.all = false;
        self.len = 0;
    }

    pub fn add(self: *RangeSet, r: frame_mod.Range) void {
        if (self.all or r.end <= r.start) return;
        // Insert sorted, then merge overlapping/adjacent neighbours.
        var i: usize = 0;
        while (i < self.len and self.items[i].start < r.start) i += 1;
        if (self.len == max) {
            // Out of slots: fold into the nearest neighbour.
            const j = if (i == self.len) i - 1 else i;
            self.items[j].start = @min(self.items[j].start, r.start);
            self.items[j].end = @max(self.items[j].end, r.end);
        } else {
            std.mem.copyBackwards(frame_mod.Range, self.items[i + 1 .. self.len + 1], self.items[i..self.len]);
            self.items[i] = r;
            self.len += 1;
        }
        var w: usize = 0;
        for (self.items[1..self.len]) |it| {
            if (it.start <= self.items[w].end) {
                self.items[w].end = @max(self.items[w].end, it.end);
            } else {
                w += 1;
                self.items[w] = it;
            }
        }
        self.len = w + 1;
    }

    pub fn slice(self: *const RangeSet) []const frame_mod.Range {
        return self.items[0..self.len];
    }
};

test "Instance stride is 32 bytes" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(Instance));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Vertex));
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(PushConstants));
}

test "packQuads keeps pixels and texels, packs colour as RGBA8" {
    const quads = [_]frame_mod.Quad{.{ .x = 8, .y = 0, .w = 8, .h = 16, .u = 32, .v = 64, .uw = 8, .vh = 16, .rgb = 0xFF8000, .kind = .mono }};
    var out: [2]Instance = undefined;
    const n = packQuads(&out, &quads);
    try std.testing.expectEqual(@as(u32, 1), n);
    try std.testing.expectEqual(@as(f32, 8), out[0].origin[0]);
    try std.testing.expectEqual(@as(u16, 64), out[0].uv_origin[1]);
    try std.testing.expectEqual(@as(u32, 1), out[0].kind);
    try std.testing.expectEqual(@as(u32, 0xFF0080FF), out[0].color);
    const pc = pushConstants(16, 32, 128, true);
    try std.testing.expectEqual(@as(f32, 1.0 / 32.0), pc.inv_viewport[1]);
}

test "sRGB targets get linear clear colours" {
    const v = colorToVec(0x808080, true);
    try std.testing.expect(v[0] > 0.2 and v[0] < 0.23);
}

test "RangeSet merges and caps" {
    var rs = RangeSet{};
    rs.clear();
    rs.add(.{ .start = 10, .end = 20 });
    rs.add(.{ .start = 0, .end = 5 });
    rs.add(.{ .start = 18, .end = 30 });
    try std.testing.expectEqual(@as(usize, 2), rs.len);
    try std.testing.expectEqual(@as(u32, 30), rs.items[1].end);
    var i: u32 = 0;
    while (i < 40) : (i += 1) rs.add(.{ .start = 100 + i * 10, .end = 101 + i * 10 });
    try std.testing.expect(rs.len <= RangeSet.max);
    rs.setAll();
    try std.testing.expect(rs.all);
}
