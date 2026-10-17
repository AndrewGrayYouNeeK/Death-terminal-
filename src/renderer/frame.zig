//! Turns the cell grid into a flat list of quads (backgrounds, glyphs,
//! decorations, cursor) shared by the GPU and CPU renderers.

const std = @import("std");
const terminal = @import("../terminal/terminal.zig");
const color = @import("../terminal/color.zig");
const fonts_mod = @import("../font/fonts.zig");
const box = @import("../font/box.zig");
const Cell = terminal.Cell;
const Fonts = fonts_mod.Fonts;

pub const Kind = enum(u8) { solid, mono, colored };

/// Pixel-space quad. `u`,`v`,`uw`,`vh` are atlas pixels (unused for solid).
pub const Quad = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    u: f32 = 0,
    v: f32 = 0,
    uw: f32 = 0,
    vh: f32 = 0,
    rgb: u32,
    kind: Kind,
};

/// Per-frame cursor and screen state.
pub const View = struct {
    cursor_visible: bool = true,
    cursor_shape: terminal.CursorShape = .block,
    /// DECSCNM: swap foreground and background for the whole screen.
    reverse_video: bool = false,
    /// Window focus; an unfocused block cursor draws hollow.
    focused: bool = true,
    /// Optional per-cell highlight (rows*cols, see `Mark`).
    marks: ?[]const Mark = null,
    selection_bg: u32 = 0x3B5BA5,
    /// `color.none` keeps each cell's own foreground.
    selection_fg: u32 = color.none,
    /// Scrollbar thumb as fractions of the window height.
    scrollbar: ?struct { top: f32, height: f32 } = null,

    pub fn fromTerminal(term: *const terminal.Terminal) View {
        return .{
            .cursor_visible = term.cursor_visible,
            .cursor_shape = term.cursor_shape,
            .reverse_video = term.modes.reverse_video,
        };
    }
};

pub const Mark = enum(u8) { none, selected, match, current_match };

pub const match_bg: u32 = 0xD7AF00;
pub const current_match_bg: u32 = 0xFF6F00;
pub const scrollbar_rgb: u32 = 0x8A8A8A;

/// Colours for a cell including selection / search highlights.
pub fn markedColors(cell: Cell, view: View, block_cursor: bool, mark: Mark) struct { fg: u32, bg: u32 } {
    const c = cellColors(cell, view, block_cursor);
    if (block_cursor) return .{ .fg = c.fg, .bg = c.bg };
    return switch (mark) {
        .none => .{ .fg = c.fg, .bg = c.bg },
        .selected => .{ .fg = if (view.selection_fg != color.none) view.selection_fg else c.fg, .bg = view.selection_bg },
        .match => .{ .fg = 0x000000, .bg = match_bg },
        .current_match => .{ .fg = 0x000000, .bg = current_match_bg },
    };
}

fn markAt(view: View, cols: u16, row: u16, col: u16) Mark {
    const marks = view.marks orelse return .none;
    const i = @as(usize, row) * cols + col;
    return if (i < marks.len) marks[i] else .none;
}

/// Colors for a cell after attributes, reverse video, and a block cursor.
pub fn cellColors(cell: Cell, view: View, block_cursor: bool) struct { fg: u32, bg: u32 } {
    const c = cell.resolvedColors();
    var fg = c.fg;
    var bg = c.bg;
    if (view.reverse_video != block_cursor) {
        const tmp = fg;
        fg = bg;
        bg = tmp;
    }
    return .{ .fg = fg, .bg = bg };
}

pub fn clearColor(view: View) u32 {
    return if (view.reverse_video) color.default_fg else color.default_bg;
}

pub const Frame = struct {
    quads: std.ArrayList(Quad),
    glyphs: std.ArrayList(fonts_mod.Positioned),
    clear: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) Frame {
        return .{ .quads = std.ArrayList(Quad).init(allocator), .glyphs = std.ArrayList(fonts_mod.Positioned).init(allocator) };
    }

    pub fn deinit(self: *Frame) void {
        self.quads.deinit();
        self.glyphs.deinit();
    }

    /// Build the frame. Retries once with an emptied atlas if it fills up.
    pub fn build(self: *Frame, fonts: *Fonts, cells: []const Cell, rows: u16, cols: u16, cursor_row: u16, cursor_col: u16, view: View) !void {
        self.buildOnce(fonts, cells, rows, cols, cursor_row, cursor_col, view) catch |err| switch (err) {
            error.AtlasFull => {
                fonts.resetCache();
                try self.buildOnce(fonts, cells, rows, cols, cursor_row, cursor_col, view);
            },
            else => return err,
        };
    }

    fn buildOnce(self: *Frame, fonts: *Fonts, cells: []const Cell, rows: u16, cols: u16, cursor_row: u16, cursor_col: u16, view: View) !void {
        self.quads.clearRetainingCapacity();
        self.clear = clearColor(view);
        const m = fonts.metrics;
        const cw: f32 = @floatFromInt(m.cell_w);
        const ch: f32 = @floatFromInt(m.cell_h);
        const cursor_on = view.cursor_visible and cursor_row < rows and cursor_col < cols;
        const block = cursor_on and view.cursor_shape == .block and view.focused;

        // Pass 1: background runs.
        var row: u16 = 0;
        while (row < rows) : (row += 1) {
            const line = rowSlice(cells, row, cols) orelse break;
            var col: u16 = 0;
            while (col < cols) {
                const at = block and row == cursor_row and cursorCovers(line, cursor_col, col);
                const bg = markedColors(line[col], view, at, markAt(view, cols, row, col)).bg;
                var end = col + 1;
                while (end < cols) : (end += 1) {
                    const at2 = block and row == cursor_row and cursorCovers(line, cursor_col, end);
                    if (markedColors(line[end], view, at2, markAt(view, cols, row, end)).bg != bg) break;
                }
                if (bg != self.clear) try self.quads.append(.{
                    .x = @as(f32, @floatFromInt(col)) * cw,
                    .y = @as(f32, @floatFromInt(row)) * ch,
                    .w = @as(f32, @floatFromInt(end - col)) * cw,
                    .h = ch,
                    .rgb = bg,
                    .kind = .solid,
                });
                col = end;
            }
        }

        // Pass 2: glyphs.
        row = 0;
        while (row < rows) : (row += 1) {
            const line = rowSlice(cells, row, cols) orelse break;
            self.glyphs.clearRetainingCapacity();
            try fonts.layoutRow(line, &self.glyphs);
            for (self.glyphs.items) |p| {
                const cell = line[p.col];
                const at = block and row == cursor_row and cursorCovers(line, cursor_col, p.col);
                const fg = markedColors(cell, view, at, markAt(view, cols, row, p.col)).fg;
                const g = p.glyph;
                if (g.rect.w == 0 or g.rect.h == 0) continue;
                try self.quads.append(.{
                    .x = @as(f32, @floatFromInt(p.col)) * cw + @as(f32, @floatFromInt(g.left + p.dx)),
                    .y = @as(f32, @floatFromInt(row)) * ch + @as(f32, @floatFromInt(g.top - p.dy)),
                    .w = @floatFromInt(g.rect.w),
                    .h = @floatFromInt(g.rect.h),
                    .u = @floatFromInt(g.rect.x),
                    .v = @floatFromInt(g.rect.y),
                    .uw = @floatFromInt(g.rect.w),
                    .vh = @floatFromInt(g.rect.h),
                    .rgb = fg,
                    .kind = if (g.colored) .colored else .mono,
                });
            }
        }

        // Pass 3: decorations and non-block cursors.
        const t: f32 = @floatFromInt(m.underline_thickness);
        const uy: f32 = @as(f32, @floatFromInt(m.underline_y)) - @floor(t / 2);
        row = 0;
        while (row < rows) : (row += 1) {
            const line = rowSlice(cells, row, cols) orelse break;
            var col: u16 = 0;
            while (col < cols) : (col += 1) {
                const cell = line[col];
                if (cell.isSpacer() or cell.hidden) continue;
                const at = block and row == cursor_row and cursorCovers(line, cursor_col, col);
                const fg = markedColors(cell, view, at, markAt(view, cols, row, col)).fg;
                const span: u8 = if (cell.width == 2) 2 else 1;
                const x = @as(f32, @floatFromInt(col)) * cw;
                const y = @as(f32, @floatFromInt(row)) * ch;
                const w = cw * @as(f32, @floatFromInt(span));
                if (cell.underline) {
                    const uc = if (cell.underline_color != color.none) cell.underline_color else fg;
                    switch (cell.underline_style) {
                        .single => try self.solid(x, y + uy, w, t, uc),
                        .double => {
                            const y2 = @min(y + uy + 2 * t, y + ch - t);
                            try self.solid(x, y2 - 2 * t, w, t, uc);
                            try self.solid(x, y2, w, t, uc);
                        },
                        .curly, .dotted, .dashed => {
                            const sp: u21 = switch (cell.underline_style) {
                                .curly => box.sprite_curly,
                                .dotted => box.sprite_dotted,
                                else => box.sprite_dashed,
                            };
                            const g = try fonts.sprite(sp, span);
                            try self.quads.append(.{ .x = x, .y = y, .w = @floatFromInt(g.rect.w), .h = @floatFromInt(g.rect.h), .u = @floatFromInt(g.rect.x), .v = @floatFromInt(g.rect.y), .uw = @floatFromInt(g.rect.w), .vh = @floatFromInt(g.rect.h), .rgb = uc, .kind = .mono });
                        },
                    }
                }
                if (cell.strikethrough) try self.solid(x, y + @as(f32, @floatFromInt(m.strike_y)) - @floor(t / 2), w, t, fg);
            }
        }

        if (cursor_on and !block) {
            const line = rowSlice(cells, cursor_row, cols).?;
            const cell = line[cursor_col];
            const span: f32 = if (cell.width == 2) 2 else 1;
            const cc = cellColors(cell, view, false).fg;
            const x = @as(f32, @floatFromInt(cursor_col)) * cw;
            const y = @as(f32, @floatFromInt(cursor_row)) * ch;
            const bar = @max(1, @round(cw / 8));
            switch (view.cursor_shape) {
                .bar => try self.solid(x, y, bar, ch, cc),
                .underline => try self.solid(x, y + ch - 2 * t, cw * span, 2 * t, cc),
                .block => {
                    // Unfocused: hollow box.
                    try self.solid(x, y, cw * span, 1, cc);
                    try self.solid(x, y + ch - 1, cw * span, 1, cc);
                    try self.solid(x, y, 1, ch, cc);
                    try self.solid(x + cw * span - 1, y, 1, ch, cc);
                },
            }
        }

        if (view.scrollbar) |sb| {
            const total_h = ch * @as(f32, @floatFromInt(rows));
            const bw = @max(4, @round(cw / 2));
            const x = cw * @as(f32, @floatFromInt(cols)) - bw;
            const h = @max(ch / 2, sb.height * total_h);
            const y = @min(sb.top * total_h, total_h - h);
            try self.solid(x, y, bw, h, scrollbar_rgb);
        }
    }

    fn solid(self: *Frame, x: f32, y: f32, w: f32, h: f32, rgb: u32) !void {
        try self.quads.append(.{ .x = x, .y = y, .w = w, .h = h, .rgb = rgb, .kind = .solid });
    }
};

fn rowSlice(cells: []const Cell, row: u16, cols: u16) ?[]const Cell {
    const start = @as(usize, row) * cols;
    if (start + cols > cells.len) return null;
    return cells[start..][0..cols];
}

/// A block cursor on a wide char covers both halves.
fn cursorCovers(line: []const Cell, cursor_col: u16, col: u16) bool {
    if (col == cursor_col) return true;
    if (col == cursor_col + 1 and cursor_col < line.len and line[cursor_col].width == 2) return true;
    if (col + 1 == cursor_col and line[col].width == 2) return true;
    return false;
}

fn testCells(text: []const u8, cells: []Cell) void {
    for (cells, 0..) |*c, i| {
        c.* = Cell.init();
        if (i < text.len) c.char = text[i];
    }
}

test "frame: glyphs per non-blank cell, cursor block inverts" {
    var f = try Fonts.init(std.testing.allocator, .{ .retro = true });
    defer f.deinit();
    var cells: [4]Cell = undefined;
    testCells("ab ", &cells);
    var fr = Frame.init(std.testing.allocator);
    defer fr.deinit();
    try fr.build(&f, &cells, 1, 4, 0, 0, .{});
    // bg quad for cursor cell + 2 glyphs
    var solids: usize = 0;
    var glyphs: usize = 0;
    for (fr.quads.items) |q| switch (q.kind) {
        .solid => solids += 1,
        else => glyphs += 1,
    };
    try std.testing.expectEqual(@as(usize, 1), solids);
    try std.testing.expectEqual(@as(usize, 2), glyphs);
    // Glyph under the cursor uses the background colour.
    try std.testing.expectEqual(color.default_bg, fr.quads.items[1].rgb);
}

test "frame: background runs merge, underline uses SGR 58 colour" {
    var f = try Fonts.init(std.testing.allocator, .{ .retro = true });
    defer f.deinit();
    var cells: [4]Cell = undefined;
    testCells("    ", &cells);
    for (cells[0..3]) |*c| c.bg_color = 0x112233;
    cells[3].underline = true;
    cells[3].underline_color = 0xFF0000;
    var fr = Frame.init(std.testing.allocator);
    defer fr.deinit();
    try fr.build(&f, &cells, 1, 4, 0, 0, .{ .cursor_visible = false });
    try std.testing.expectEqual(@as(f32, 3 * 8), fr.quads.items[0].w);
    const last = fr.quads.items[fr.quads.items.len - 1];
    try std.testing.expectEqual(@as(u32, 0xFF0000), last.rgb);
    try std.testing.expectEqual(@as(f32, 24), last.x);
}

test "frame: curly underline is a sprite, bar cursor is narrow" {
    var f = try Fonts.init(std.testing.allocator, .{ .retro = true });
    defer f.deinit();
    var cells: [2]Cell = undefined;
    testCells("x ", &cells);
    cells[0].underline = true;
    cells[0].underline_style = .curly;
    var fr = Frame.init(std.testing.allocator);
    defer fr.deinit();
    try fr.build(&f, &cells, 1, 2, 0, 1, .{ .cursor_shape = .bar });
    var mono: usize = 0;
    for (fr.quads.items) |q| mono += @intFromBool(q.kind == .mono);
    try std.testing.expectEqual(@as(usize, 2), mono); // 'x' + curly sprite
    const cur = fr.quads.items[fr.quads.items.len - 1];
    try std.testing.expect(cur.w < 8 and cur.x == 8);
}

test "frame: wide cell cursor covers both halves" {
    var cells: [2]Cell = undefined;
    testCells("  ", &cells);
    cells[0].width = 2;
    cells[1].width = 0;
    try std.testing.expect(cursorCovers(&cells, 0, 1));
    try std.testing.expect(cursorCovers(&cells, 1, 0));
}

test "frame: selection and search marks recolour cells, scrollbar drawn" {
    var f = try Fonts.init(std.testing.allocator, .{ .retro = true });
    defer f.deinit();
    var cells: [4]Cell = undefined;
    testCells("abcd", &cells);
    const marks = [_]Mark{ .selected, .selected, .match, .current_match };
    var fr = Frame.init(std.testing.allocator);
    defer fr.deinit();
    try fr.build(&f, &cells, 1, 4, 0, 0, .{ .cursor_visible = false, .marks = &marks, .scrollbar = .{ .top = 0.5, .height = 0.25 } });
    try std.testing.expectEqual(@as(u32, 0x3B5BA5), fr.quads.items[0].rgb);
    try std.testing.expectEqual(@as(f32, 16), fr.quads.items[0].w);
    try std.testing.expectEqual(match_bg, fr.quads.items[1].rgb);
    try std.testing.expectEqual(current_match_bg, fr.quads.items[2].rgb);
    const sb = fr.quads.items[fr.quads.items.len - 1];
    try std.testing.expectEqual(scrollbar_rgb, sb.rgb);
    try std.testing.expect(sb.x > 24);
}
