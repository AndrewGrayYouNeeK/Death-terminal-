//! xterm color palette.

pub const default_fg: u32 = 0xFFFFFF;
/// Sentinel for "no explicit colour" (e.g. underline uses the foreground).
pub const none: u32 = 0xFFFFFFFF;
pub const default_bg: u32 = 0x000000;

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
