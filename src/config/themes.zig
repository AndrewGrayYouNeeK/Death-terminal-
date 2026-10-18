//! Bundled colour themes. `theme = "<name>"` in config.lua selects one;
//! `colors.*` keys override individual entries on top of it.

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
            0x4A4A4A, 0xFF3355, 0x9ABA9A, 0xE8C070, 0x7A8EAC, 0xBA7AAC, 0x7AACAC, 0xFFFFFF,
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

pub fn find(name: []const u8) ?*const Theme {
    for (&all) |*t| {
        if (std.ascii.eqlIgnoreCase(t.name, name)) return t;
    }
    return null;
}

test "themes: lookup and palette" {
    const t = find("Dracula").?;
    const p = t.palette();
    try std.testing.expectEqual(@as(u32, 0x282A36), p.bg);
    try std.testing.expectEqual(@as(u32, 0xFF5555), p.resolve(color.indexed(1)));
    // The 256-colour cube is untouched by themes.
    try std.testing.expectEqual(color.palette256(196), p.resolve(color.indexed(196)));
    try std.testing.expect(find("nope") == null);
    // Default theme matches the built-in palette.
    try std.testing.expectEqual(color.default_palette.hash(), find("default").?.palette().hash());
}
