//! Converts frame quads into GPU instances for the text pipeline.

const std = @import("std");
const frame_mod = @import("frame.zig");

pub const MAX_INSTANCES: u32 = 65536;

/// Per-quad instance consumed by the text vertex shader.
pub const Instance = extern struct {
    origin: [2]f32,
    size: [2]f32,
    uv_origin: [2]f32,
    uv_size: [2]f32,
    color: [4]f32,
    /// x: 0 solid, 1 mono glyph (coverage in alpha), 2 colour glyph.
    params: [4]f32,
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

/// 0xRRGGBB → RGBA floats; linearised when the target is an sRGB image.
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

/// Write instances for `quads`; returns the count written.
pub fn packQuads(out: []Instance, quads: []const frame_mod.Quad, fb_w: f32, fb_h: f32, atlas_size: u32, srgb_target: bool) u32 {
    if (fb_w <= 0 or fb_h <= 0) return 0;
    const as: f32 = @floatFromInt(@max(atlas_size, 1));
    var n: u32 = 0;
    for (quads) |q| {
        if (n >= out.len) break;
        out[n] = .{
            .origin = .{ -1.0 + 2.0 * q.x / fb_w, -1.0 + 2.0 * q.y / fb_h },
            .size = .{ 2.0 * q.w / fb_w, 2.0 * q.h / fb_h },
            .uv_origin = .{ q.u / as, q.v / as },
            .uv_size = .{ q.uw / as, q.vh / as },
            .color = colorToVec(q.rgb, srgb_target),
            .params = .{ @floatFromInt(@intFromEnum(q.kind)), 0, 0, 0 },
        };
        n += 1;
    }
    return n;
}

test "Instance stride is 64 bytes" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(Instance));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Vertex));
}

test "packQuads maps pixels to NDC and atlas pixels to UV" {
    const quads = [_]frame_mod.Quad{.{ .x = 8, .y = 0, .w = 8, .h = 16, .u = 32, .v = 64, .uw = 8, .vh = 16, .rgb = 0xFF0000, .kind = .mono }};
    var out: [2]Instance = undefined;
    const n = packQuads(&out, &quads, 16, 16, 128, false);
    try std.testing.expectEqual(@as(u32, 1), n);
    try std.testing.expectEqual(@as(f32, 0), out[0].origin[0]);
    try std.testing.expectEqual(@as(f32, 2), out[0].size[1]);
    try std.testing.expectEqual(@as(f32, 0.25), out[0].uv_origin[0]);
    try std.testing.expectEqual(@as(f32, 1), out[0].params[0]);
    try std.testing.expectEqual(@as(f32, 1), out[0].color[0]);
}

test "sRGB targets get linear colours" {
    const v = colorToVec(0x808080, true);
    try std.testing.expect(v[0] > 0.2 and v[0] < 0.23);
}
