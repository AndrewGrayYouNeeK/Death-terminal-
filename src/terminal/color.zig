//! xterm color palette and the colour encoding stored in cells.
//!
//! A cell colour is either a direct 0xRRGGBB value (true colour, top byte
//! 0), a palette index (`indexed(n)`, top byte 1) or the theme's default
//! foreground/background (top byte 2). Indexed and default colours are
//! resolved through a `Palette` at render time, so changing the theme
//! recolours text that is already on screen.

const std = @import("std");

pub const tag_mask: u32 = 0xFF000000;
pub const indexed_tag: u32 = 0x01000000;
pub const special_tag: u32 = 0x02000000;
/// Theme foreground / background.
pub const default_fg: u32 = special_tag | 0;
pub const default_bg: u32 = special_tag | 1;
/// Sentinel for "no explicit colour" (e.g. underline uses the foreground).
pub const none: u32 = 0xFFFFFFFF;

pub fn indexed(i: u32) u32 {
    return indexed_tag | @min(i, 255);
}

/// Colours a theme provides; `none` for cursor/selection colours means
/// "derive from the cell".
pub const Palette = struct {
    fg: u32 = 0xFFFFFF,
    bg: u32 = 0x000000,
    cursor: u32 = none,
    cursor_text: u32 = none,
    selection_bg: u32 = 0x3B5BA5,
    selection_fg: u32 = none,
    colors: [256]u32 = default256,

    /// 0xRRGGBB for a cell colour (`none` passes through).
    pub fn resolve(self: *const Palette, c: u32) u32 {
        return switch (c & tag_mask) {
            0 => c,
            indexed_tag => self.colors[c & 0xFF],
            special_tag => if (c & 1 == 0) self.fg else self.bg,
            else => c,
        };
    }

    pub fn hash(self: *const Palette) u64 {
        return std.hash.Wyhash.hash(0, std.mem.asBytes(self));
    }
};

pub const default_palette = Palette{};

pub const default256: [256]u32 = blk: {
    var p: [256]u32 = undefined;
    for (&p, 0..) |*c, i| c.* = palette256(@intCast(i));
    break :blk p;
};

pub const ansi16 = [16]u32{
    0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x0000EE, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
    0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00, 0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF,
};

const cube_levels = [6]u32{ 0, 95, 135, 175, 215, 255 };

/// RGB for an xterm 256-color index (0..15 ANSI, 16..231 6x6x6 cube,
/// 232..255 grayscale ramp). Out-of-range indices clamp to 255.
pub fn palette256(index: u32) u32 {
    const i: u32 = @min(index, 255);
    if (i < 16) return ansi16[i];
    if (i < 232) {
        const c = i - 16;
        const r = cube_levels[c / 36];
        const g = cube_levels[(c / 6) % 6];
        const b = cube_levels[c % 6];
        return (r << 16) | (g << 8) | b;
    }
    const v = 8 + (i - 232) * 10;
    return (v << 16) | (v << 8) | v;
}

pub fn rgb(r: u32, g: u32, b: u32) u32 {
    const rr: u32 = @min(r, 255);
    const gg: u32 = @min(g, 255);
    const bb: u32 = @min(b, 255);
    return (rr << 16) | (gg << 8) | bb;
}

/// Halve each channel (SGR 2 "faint").
pub fn dim(c: u32) u32 {
    return (c >> 1) & 0x7F7F7F;
}

test "palette256" {
    const t = @import("std").testing;
    try t.expectEqual(@as(u32, 0xCD0000), palette256(1));
    try t.expectEqual(@as(u32, 0x000000), palette256(16));
    try t.expectEqual(@as(u32, 0xFF0000), palette256(196));
    try t.expectEqual(@as(u32, 0x5F87AF), palette256(67));
    try t.expectEqual(@as(u32, 0x080808), palette256(232));
    try t.expectEqual(@as(u32, 0xEEEEEE), palette256(255));
}
