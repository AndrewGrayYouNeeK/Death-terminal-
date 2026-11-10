//! Bundled colour themes. `theme = "<name>"` in config.lua selects one;
//! `colors.*` keys override individual entries on top of it.
//! When `config.theme` is unset, `default_name` ("death") is used.
//! The theme named "default" is the classic ANSI palette and stays selectable.

const std = @import("std");
const color = @import("../terminal/color.zig");

pub const Theme = struct {
    name: []const u8,
    fg: u32,
    bg: u32,
    cursor: u32 = color.none,
    cursor_text: u32 = color.none,
    selection_bg: u32 = 0x3B5BA5,
    selection_fg: u32 = color.none,
    ansi: [16]u32,

    pub fn palette(self: *const Theme) color.Palette {
        var p = color.Palette{
            .fg = self.fg,
            .bg = self.bg,
            .cursor = self.cursor,
            .cursor_text = self.cursor_text,
            .selection_bg = self.selection_bg,
            .selection_fg = self.selection_fg,
        };
        @memcpy(p.colors[0..16], &self.ansi);
        return p;
    }
};

pub const all = [_]Theme{
    .{
        .name = "default",
        .fg = 0xFFFFFF,
        .bg = 0x000000,
        .ansi = color.ansi16,
    },
    .{
        .name = "death",
        .fg = 0xE0E0E0,
        .bg = 0x000000,
        .cursor = 0xFF0033,
        .cursor_text = 0x000000,
        .selection_bg = 0xFF0033,
        .selection_fg = 0x000000,
        .ansi = .{
            0x000000, 0xFF0033, 0x7A9A7A, 0xC8A050, 0x5A6E8C, 0x9A5A8C, 0x5A8C8C, 0xC0C0C0,
            0x6E6E6E, 0xFF3355, 0x9ABA9A, 0xE8C070, 0x7A8EAC, 0xBA7AAC, 0x7AACAC, 0xFFFFFF,
        },
    },
    .{
        .name = "dracula",
        .fg = 0xF8F8F2,
        .bg = 0x282A36,
        .cursor = 0xF8F8F2,
        .cursor_text = 0x282A36,
        .selection_bg = 0x44475A,
        .ansi = .{
            0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
            0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF,
        },
    },
    .{
        .name = "gruvbox-dark",
        .fg = 0xEBDBB2,
        .bg = 0x282828,
        .cursor = 0xEBDBB2,
        .cursor_text = 0x282828,
        .selection_bg = 0x504945,
        .ansi = .{
            0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984,
            0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2,
        },
    },
    .{
        .name = "nord",
        .fg = 0xD8DEE9,
        .bg = 0x2E3440,
        .cursor = 0xD8DEE9,
        .cursor_text = 0x2E3440,
        .selection_bg = 0x434C5E,
        .ansi = .{
            0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
            0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4,
        },
    },
    .{
        .name = "solarized-dark",
        .fg = 0x839496,
        .bg = 0x002B36,
        .cursor = 0x93A1A1,
        .cursor_text = 0x002B36,
        .selection_bg = 0x073642,
        .selection_fg = 0x93A1A1,
        .ansi = .{
            0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
            0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3,
        },
    },
    .{
        .name = "solarized-light",
        .fg = 0x657B83,
        .bg = 0xFDF6E3,
        .cursor = 0x586E75,
        .cursor_text = 0xFDF6E3,
        .selection_bg = 0xEEE8D5,
        .selection_fg = 0x586E75,
        .ansi = .{
            0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
            0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3,
        },
    },
};

/// Applied when `config.theme` is unset.
pub const default_name = "death";

pub fn find(name: []const u8) ?*const Theme {
    for (&all) |*t| {
        if (std.ascii.eqlIgnoreCase(t.name, name)) return t;
    }
    return null;
}

/// Theme used when `config.theme` is unset.
pub fn defaultTheme() *const Theme {
    return find(default_name) orelse unreachable;
}

comptime {
    if (find(default_name) == null) @compileError("bundled default theme \"" ++ default_name ++ "\" is missing");
}

test "themes: lookup and palette" {
    const t = find("Dracula").?;
    const p = t.palette();
    try std.testing.expectEqual(@as(u32, 0x282A36), p.bg);
    try std.testing.expectEqual(@as(u32, 0xFF5555), p.resolve(color.indexed(1)));
    // The 256-colour cube is untouched by themes.
    try std.testing.expectEqual(color.palette256(196), p.resolve(color.indexed(196)));
    try std.testing.expect(find("nope") == null);
    // Unset config.theme uses the death palette.
    const death = defaultTheme();
    try std.testing.expectEqualStrings("death", death.name);
    const dp = death.palette();
    try std.testing.expectEqual(@as(u32, 0xE0E0E0), dp.fg);
    try std.testing.expectEqual(@as(u32, 0x000000), dp.bg);
    try std.testing.expectEqual(@as(u32, 0xFF0033), dp.cursor);
    try std.testing.expectEqual(@as(u32, 0xFF0033), dp.resolve(color.indexed(1)));
    // The theme named "default" is still selectable and matches the built-in palette.
    const classic = find("default").?;
    try std.testing.expectEqualStrings("default", classic.name);
    try std.testing.expectEqual(color.default_palette.hash(), classic.palette().hash());
}

fn blend(a: u32, b: u32, t: f32) u32 {
    var out: u32 = 0;
    inline for (.{ 16, 8, 0 }) |sh| {
        const x: f32 = @floatFromInt((a >> sh) & 0xFF);
        const y: f32 = @floatFromInt((b >> sh) & 0xFF);
        const v: u32 = @intFromFloat(std.math.clamp(x + (y - x) * t, 0, 255));
        out |= v << sh;
    }
    return out;
}

// Body text, faint text, selection, the status bar and the tab bar must
// be at least 4.5:1. Ghost text (ANSI bright black, palette index 8) may
// sit under 4.5:1 and must stay at least 3:1, and dimmer than faint text.
test "death theme contrast" {
    const death = defaultTheme();
    const fg = death.fg;
    const bg = death.bg;
    const faint = color.dim(fg);
    const ghost = death.ansi[8];
    const t = std.testing;
    try t.expect(color.contrastRatio(fg, bg) >= 4.5);
    try t.expect(color.contrastRatio(faint, bg) >= 4.5);
    try t.expect(color.contrastRatio(ghost, bg) >= 3.0);
    try t.expect(color.contrastRatio(ghost, bg) < color.contrastRatio(faint, bg));
    try t.expect(color.contrastRatio(death.selection_fg, death.selection_bg) >= 4.5);
    // Status bar (ui.zig drawStatus): text 0xD0D0D0 and base 0xB0B0B0 on 0x202020.
    try t.expect(color.contrastRatio(0xD0D0D0, 0x202020) >= 4.5);
    try t.expect(color.contrastRatio(0xB0B0B0, 0x202020) >= 4.5);
    // Tab bar (session.zig drawBar): inactive label is blend(bg, fg, 0.60)
    // on blend(bg, fg, 0.10). The active tab is fg on bg.
    const bar_bg = blend(bg, fg, 0.10);
    const dim_fg = blend(bg, fg, 0.60);
    try t.expect(color.contrastRatio(fg, bg) >= 4.5);
    try t.expect(color.contrastRatio(dim_fg, bar_bg) >= 4.5);
    // Corner badge background, and the four AI label colours on both that
    // badge and the status bar.
    const badge_bg: u32 = 0x3A3A3A;
    const status_bg: u32 = 0x202020;
    const labels = [_]u32{ 0x7CFF6B, 0xD0D0D0, 0xFFB4B4, 0xC8C8C8 };
    for (labels) |c| {
        try t.expect(color.contrastRatio(c, badge_bg) >= 4.5);
        try t.expect(color.contrastRatio(c, status_bg) >= 4.5);
    }
}
