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

/// Half-open range of quad indices.
pub const Range = struct { start: u32, end: u32 };

/// Everything outside the cells that changes how a row looks; a change
/// here invalidates every row.
const FrameKey = struct {
    rows: u16 = 0,
    cols: u16 = 0,
    cell_w: u32 = 0,
    cell_h: u32 = 0,
    epoch: u32 = 0,
    reverse_video: bool = false,
    selection_bg: u32 = 0,
    selection_fg: u32 = 0,
};

/// Cursor state that recolours cells (block cursor) or adds quads.
const CursorKey = struct {
    on: bool = false,
    block: bool = false,
    row: u16 = 0,
    col: u16 = 0,
    shape: terminal.CursorShape = .block,
    focused: bool = true,
};

const RowCache = struct {
    bg: std.ArrayListUnmanaged(Quad) = .{},
    fg: std.ArrayListUnmanaged(Quad) = .{},

    fn deinit(self: *RowCache, a: std.mem.Allocator) void {
        self.bg.deinit(a);
        self.fg.deinit(a);
    }
};

/// Retained frame: quads are cached per row and only rows whose cells,
/// highlight marks or cursor state changed are re-shaped and rebuilt.
/// After `build`, `quads` holds the whole frame in draw order
/// (all backgrounds, then all glyphs/decorations, then the overlay) and
/// `damage` lists the quad ranges that differ from the previous build.
pub const Frame = struct {
    allocator: std.mem.Allocator,
    quads: std.ArrayList(Quad),
    glyphs: std.ArrayList(fonts_mod.Positioned),
    clear: u32 = 0,

    /// Rows rebuilt by the last `build` (len = rows).
    dirty_rows: std.ArrayListUnmanaged(bool) = .{},
    /// Quad ranges changed by the last build (sorted, merged). Empty with
    /// `changed == false` means the frame is identical to the previous one.
    damage: std.ArrayListUnmanaged(Range) = .{},
    /// The whole frame changed (layout, size, fonts...).
    full_damage: bool = true,
    changed: bool = true,
    /// Pixel rects of the overlay (cursor, scrollbar) before and after the
    /// last build, for partial CPU rasterisation.
    overlay_px: [2]?PxRect = .{ null, null },
    /// Counts for the CPU rasteriser.
    rows_rebuilt: usize = 0,

    cache: std.ArrayListUnmanaged(RowCache) = .{},
    prev_cells: std.ArrayListUnmanaged(Cell) = .{},
    prev_marks: std.ArrayListUnmanaged(Mark) = .{},
    overlay: std.ArrayListUnmanaged(Quad) = .{},
    prev_overlay: std.ArrayListUnmanaged(Quad) = .{},
    /// Start of each row's bg / fg quads in `quads` (len rows + 1).
    bg_off: std.ArrayListUnmanaged(u32) = .{},
    fg_off: std.ArrayListUnmanaged(u32) = .{},
    key: FrameKey = .{},
    cursor: CursorKey = .{},
    valid: bool = false,

    pub const PxRect = struct { x: f32, y: f32, w: f32, h: f32 };

    pub fn init(allocator: std.mem.Allocator) Frame {
        return .{ .allocator = allocator, .quads = std.ArrayList(Quad).init(allocator), .glyphs = std.ArrayList(fonts_mod.Positioned).init(allocator) };
    }

    pub fn deinit(self: *Frame) void {
        const a = self.allocator;
        self.quads.deinit();
        self.glyphs.deinit();
        for (self.cache.items) |*c| c.deinit(a);
        self.cache.deinit(a);
        self.prev_cells.deinit(a);
        self.prev_marks.deinit(a);
        self.overlay.deinit(a);
        self.prev_overlay.deinit(a);
        self.bg_off.deinit(a);
        self.fg_off.deinit(a);
        self.dirty_rows.deinit(a);
        self.damage.deinit(a);
    }

    /// Forget the cache: the next build rebuilds every row.
    pub fn invalidate(self: *Frame) void {
        self.valid = false;
    }

    /// Build the frame. Retries once with an emptied atlas if it fills up.
    pub fn build(self: *Frame, fonts: *Fonts, cells: []const Cell, rows: u16, cols: u16, cursor_row: u16, cursor_col: u16, view: View) !void {
        self.buildOnce(fonts, cells, rows, cols, cursor_row, cursor_col, view) catch |err| switch (err) {
            error.AtlasFull => {
                fonts.resetCache();
                self.invalidate();
                try self.buildOnce(fonts, cells, rows, cols, cursor_row, cursor_col, view);
            },
            else => return err,
        };
    }

    fn buildOnce(self: *Frame, fonts: *Fonts, cells: []const Cell, rows: u16, cols: u16, cursor_row: u16, cursor_col: u16, view: View) !void {
        const a = self.allocator;
        const m = fonts.metrics;
        const cursor_on = view.cursor_visible and cursor_row < rows and cursor_col < cols;
        const cur = CursorKey{
            .on = cursor_on,
            .block = cursor_on and view.cursor_shape == .block and view.focused,
            .row = cursor_row,
            .col = cursor_col,
            .shape = view.cursor_shape,
            .focused = view.focused,
        };
        const key = FrameKey{
            .rows = rows,
            .cols = cols,
            .cell_w = m.cell_w,
            .cell_h = m.cell_h,
            .epoch = fonts.atlas.epoch,
            .reverse_video = view.reverse_video,
            .selection_bg = view.selection_bg,
            .selection_fg = view.selection_fg,
        };
        const n = @as(usize, rows) * cols;
        const full = !self.valid or !std.meta.eql(key, self.key) or self.prev_cells.items.len != n;
        if (full) {
            // Keep the row buffers' capacity: a full rebuild (resize, zoom,
            // atlas reset) should not pay for re-allocating every row.
            if (self.cache.items.len > rows) {
                for (self.cache.items[rows..]) |*c| c.deinit(a);
                self.cache.shrinkRetainingCapacity(rows);
            }
            for (self.cache.items) |*c| {
                c.bg.clearRetainingCapacity();
                c.fg.clearRetainingCapacity();
            }
            if (self.cache.items.len < rows) try self.cache.appendNTimes(a, .{}, rows - self.cache.items.len);
            try self.prev_cells.resize(a, n);
            try self.prev_marks.resize(a, n);
        }
        try self.dirty_rows.resize(a, rows);
        self.clear = clearColor(view);

        // Which rows need rebuilding?
        var any_row = false;
        self.rows_rebuilt = 0;
        var row: u16 = 0;
        while (row < rows) : (row += 1) {
            const line = rowSlice(cells, row, cols) orelse {
                self.dirty_rows.items[row] = false;
                continue;
            };
            const start = @as(usize, row) * cols;
            var dirty = full;
            if (!dirty) dirty = !cellsEql(self.prev_cells.items[start..][0..cols], line);
            if (!dirty) dirty = !std.mem.eql(Mark, self.prev_marks.items[start..][0..cols], marksRow(view, cols, row));
            if (!dirty and !std.meta.eql(cur, self.cursor)) {
                // The block cursor recolours its cells; other shapes are overlay.
                dirty = (self.cursor.block and self.cursor.row == row) or (cur.block and cur.row == row);
            }
            self.dirty_rows.items[row] = dirty;
            if (!dirty) continue;
            any_row = true;
            self.rows_rebuilt += 1;
            @memcpy(self.prev_cells.items[start..][0..cols], line);
            @memcpy(self.prev_marks.items[start..][0..cols], marksRow(view, cols, row));
            try self.buildRow(fonts, line, row, cols, cur, view);
        }

        // Overlay: non-block cursor + scrollbar (always rebuilt; tiny).
        std.mem.swap(std.ArrayListUnmanaged(Quad), &self.overlay, &self.prev_overlay);
        self.overlay.clearRetainingCapacity();
        try self.buildOverlay(cells, rows, cols, cur, view, m);
        const overlay_changed = full or !std.mem.eql(u8, std.mem.sliceAsBytes(self.overlay.items), std.mem.sliceAsBytes(self.prev_overlay.items));
        self.overlay_px = .{ boundsOf(self.prev_overlay.items), boundsOf(self.overlay.items) };

        self.key = key;
        self.cursor = cur;
        self.valid = true;
        self.damage.clearRetainingCapacity();
        self.full_damage = full;
        self.changed = full or any_row or overlay_changed;
        if (!self.changed) return;
        try self.assemble(rows, full);
    }

    /// Concatenate the row caches into `quads` and record damage.
    fn assemble(self: *Frame, rows: u16, full: bool) !void {
        const a = self.allocator;
        const old_bg = try a.dupe(u32, self.bg_off.items);
        defer a.free(old_bg);
        const old_fg = try a.dupe(u32, self.fg_off.items);
        defer a.free(old_fg);
        const old_len: u32 = @intCast(self.quads.items.len);

        try self.bg_off.resize(a, @as(usize, rows) + 1);
        try self.fg_off.resize(a, @as(usize, rows) + 1);
        self.quads.clearRetainingCapacity();
        var r: usize = 0;
        while (r < rows) : (r += 1) {
            self.bg_off.items[r] = @intCast(self.quads.items.len);
            try self.quads.appendSlice(self.cache.items[r].bg.items);
        }
        self.bg_off.items[rows] = @intCast(self.quads.items.len);
        r = 0;
        while (r < rows) : (r += 1) {
            self.fg_off.items[r] = @intCast(self.quads.items.len);
            try self.quads.appendSlice(self.cache.items[r].fg.items);
        }
        self.fg_off.items[rows] = @intCast(self.quads.items.len);
        const overlay_start: u32 = @intCast(self.quads.items.len);
        try self.quads.appendSlice(self.overlay.items);
        const new_len: u32 = @intCast(self.quads.items.len);

        if (full or old_bg.len != self.bg_off.items.len) {
            self.full_damage = true;
            try self.damage.append(a, .{ .start = 0, .end = new_len });
            return;
        }
        // A row whose quad count changed shifts everything after it in its
        // segment; otherwise only the row itself changed.
        inline for (.{ .{ old_bg, &self.bg_off }, .{ old_fg, &self.fg_off } }) |seg| {
            const old = seg[0];
            const off = seg[1].items;
            r = 0;
            while (r < rows) : (r += 1) {
                if (off[r] != old[r]) {
                    try self.addDamage(off[r], off[rows]);
                    break;
                }
                if (self.dirty_rows.items[r]) try self.addDamage(off[r], off[r + 1]);
            }
        }
        if (new_len != old_len or overlay_start != old_fg[rows] or self.overlay.items.len > 0 or self.prev_overlay.items.len > 0)
            try self.addDamage(overlay_start, new_len);
    }

    fn addDamage(self: *Frame, start: u32, end: u32) !void {
        if (end <= start) return;
        if (self.damage.items.len > 0) {
            const last = &self.damage.items[self.damage.items.len - 1];
            if (start <= last.end) {
                last.end = @max(last.end, end);
                return;
            }
        }
        try self.damage.append(self.allocator, .{ .start = start, .end = end });
    }

    fn buildRow(self: *Frame, fonts: *Fonts, line: []const Cell, row: u16, cols: u16, cur: CursorKey, view: View) !void {
        const a = self.allocator;
        const rc = &self.cache.items[row];
        rc.bg.clearRetainingCapacity();
        rc.fg.clearRetainingCapacity();
        const m = fonts.metrics;
        const cw: f32 = @floatFromInt(m.cell_w);
        const ch: f32 = @floatFromInt(m.cell_h);
        const y = @as(f32, @floatFromInt(row)) * ch;
        const block_here = cur.block and cur.row == row;
        const clear = clearColor(view);

        // Background runs.
        var col: u16 = 0;
        while (col < cols) {
            const at = block_here and cursorCovers(line, cur.col, col);
            const bg = markedColors(line[col], view, at, markAt(view, cols, row, col)).bg;
            var end = col + 1;
            while (end < cols) : (end += 1) {
                const at2 = block_here and cursorCovers(line, cur.col, end);
                if (markedColors(line[end], view, at2, markAt(view, cols, row, end)).bg != bg) break;
            }
            if (bg != clear) try rc.bg.append(a, .{
                .x = @as(f32, @floatFromInt(col)) * cw,
                .y = y,
                .w = @as(f32, @floatFromInt(end - col)) * cw,
                .h = ch,
                .rgb = bg,
                .kind = .solid,
            });
            col = end;
        }

        // Glyphs.
        self.glyphs.clearRetainingCapacity();
        try fonts.layoutRow(line, &self.glyphs);
        for (self.glyphs.items) |p| {
            const cell = line[p.col];
            const at = block_here and cursorCovers(line, cur.col, p.col);
            const fg = markedColors(cell, view, at, markAt(view, cols, row, p.col)).fg;
            const g = p.glyph;
            if (g.rect.w == 0 or g.rect.h == 0) continue;
            try rc.fg.append(a, .{
                .x = @as(f32, @floatFromInt(p.col)) * cw + @as(f32, @floatFromInt(g.left + p.dx)),
                .y = y + @as(f32, @floatFromInt(g.top - p.dy)),
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

        // Decorations.
        const t: f32 = @floatFromInt(m.underline_thickness);
        const uy: f32 = @as(f32, @floatFromInt(m.underline_y)) - @floor(t / 2);
        col = 0;
        while (col < cols) : (col += 1) {
            const cell = line[col];
            if (cell.isSpacer() or cell.hidden) continue;
            if (!cell.underline and !cell.strikethrough) continue;
            const at = block_here and cursorCovers(line, cur.col, col);
            const fg = markedColors(cell, view, at, markAt(view, cols, row, col)).fg;
            const span: u8 = if (cell.width == 2) 2 else 1;
            const x = @as(f32, @floatFromInt(col)) * cw;
            const w = cw * @as(f32, @floatFromInt(span));
            if (cell.underline) {
                const uc = if (cell.underline_color != color.none) cell.underline_color else fg;
                switch (cell.underline_style) {
                    .single => try solidTo(a, &rc.fg, x, y + uy, w, t, uc),
                    .double => {
                        const y2 = @min(y + uy + 2 * t, y + ch - t);
                        try solidTo(a, &rc.fg, x, y2 - 2 * t, w, t, uc);
                        try solidTo(a, &rc.fg, x, y2, w, t, uc);
                    },
                    .curly, .dotted, .dashed => {
                        const sp: u21 = switch (cell.underline_style) {
                            .curly => box.sprite_curly,
                            .dotted => box.sprite_dotted,
                            else => box.sprite_dashed,
                        };
                        const g = try fonts.sprite(sp, span);
                        try rc.fg.append(a, .{ .x = x, .y = y, .w = @floatFromInt(g.rect.w), .h = @floatFromInt(g.rect.h), .u = @floatFromInt(g.rect.x), .v = @floatFromInt(g.rect.y), .uw = @floatFromInt(g.rect.w), .vh = @floatFromInt(g.rect.h), .rgb = uc, .kind = .mono });
                    },
                }
            }
            if (cell.strikethrough) try solidTo(a, &rc.fg, x, y + @as(f32, @floatFromInt(m.strike_y)) - @floor(t / 2), w, t, fg);
        }
    }

    fn buildOverlay(self: *Frame, cells: []const Cell, rows: u16, cols: u16, cur: CursorKey, view: View, m: fonts_mod.Metrics) !void {
        const a = self.allocator;
        const cw: f32 = @floatFromInt(m.cell_w);
        const ch: f32 = @floatFromInt(m.cell_h);
        const t: f32 = @floatFromInt(m.underline_thickness);
        if (cur.on and !cur.block) {
            if (rowSlice(cells, cur.row, cols)) |line| {
                const cell = line[cur.col];
                const span: f32 = if (cell.width == 2) 2 else 1;
                const cc = cellColors(cell, view, false).fg;
                const x = @as(f32, @floatFromInt(cur.col)) * cw;
                const y = @as(f32, @floatFromInt(cur.row)) * ch;
                const bar = @max(1, @round(cw / 8));
                switch (view.cursor_shape) {
                    .bar => try solidTo(a, &self.overlay, x, y, bar, ch, cc),
                    .underline => try solidTo(a, &self.overlay, x, y + ch - 2 * t, cw * span, 2 * t, cc),
                    .block => {
                        // Unfocused: hollow box.
                        try solidTo(a, &self.overlay, x, y, cw * span, 1, cc);
                        try solidTo(a, &self.overlay, x, y + ch - 1, cw * span, 1, cc);
                        try solidTo(a, &self.overlay, x, y, 1, ch, cc);
                        try solidTo(a, &self.overlay, x + cw * span - 1, y, 1, ch, cc);
                    },
                }
            }
        }
        if (view.scrollbar) |sb| {
            const total_h = ch * @as(f32, @floatFromInt(rows));
            const bw = @max(4, @round(cw / 2));
            const x = cw * @as(f32, @floatFromInt(cols)) - bw;
            const h = @max(ch / 2, sb.height * total_h);
            const y = @min(sb.top * total_h, total_h - h);
            try solidTo(a, &self.overlay, x, y, bw, h, scrollbar_rgb);
        }
    }

    /// Quads of row `r`: backgrounds and foreground (glyphs/decorations).
    pub fn rowQuads(self: *const Frame, r: usize) struct { bg: []const Quad, fg: []const Quad } {
        return .{ .bg = self.cache.items[r].bg.items, .fg = self.cache.items[r].fg.items };
    }

    pub fn overlayQuads(self: *const Frame) []const Quad {
        return self.overlay.items;
    }
};

fn solidTo(a: std.mem.Allocator, list: *std.ArrayListUnmanaged(Quad), x: f32, y: f32, w: f32, h: f32, rgb: u32) !void {
    try list.append(a, .{ .x = x, .y = y, .w = w, .h = h, .rgb = rgb, .kind = .solid });
}

fn boundsOf(quads: []const Quad) ?Frame.PxRect {
    if (quads.len == 0) return null;
    var x0: f32 = std.math.floatMax(f32);
    var y0: f32 = x0;
    var x1: f32 = -x0;
    var y1: f32 = -x0;
    for (quads) |q| {
        x0 = @min(x0, q.x);
        y0 = @min(y0, q.y);
        x1 = @max(x1, q.x + q.w);
        y1 = @max(y1, q.y + q.h);
    }
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

fn marksRow(view: View, cols: u16, row: u16) []const Mark {
    const start = @as(usize, row) * cols;
    if (view.marks) |marks| {
        if (start + cols <= marks.len) return marks[start..][0..cols];
    }
    return none_marks_buf[0..@min(cols, none_marks_buf.len)];
}

const none_marks_buf = [_]Mark{.none} ** 1024;

/// Field-wise equality (cells may contain undefined padding bytes).
fn cellsEql(a: []const Cell, b: []const Cell) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.char != y.char or x.fg_color != y.fg_color or x.bg_color != y.bg_color or x.width != y.width or
            x.bold != y.bold or x.italic != y.italic or x.underline != y.underline or x.faint != y.faint or
            x.blink != y.blink or x.inverse != y.inverse or x.hidden != y.hidden or x.strikethrough != y.strikethrough or
            x.link != y.link or x.underline_style != y.underline_style or x.underline_color != y.underline_color or
            !std.mem.eql(u21, &x.combining, &y.combining)) return false;
    }
    return true;
}

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

test "frame: damage tracking rebuilds only changed rows" {
    var f = try Fonts.init(std.testing.allocator, .{ .retro = true });
    defer f.deinit();
    var cells: [3 * 4]Cell = undefined;
    testCells("ab  cd  ef  ", &cells);
    var fr = Frame.init(std.testing.allocator);
    defer fr.deinit();
    const v = View{ .cursor_visible = false };
    try fr.build(&f, &cells, 3, 4, 0, 0, v);
    try std.testing.expect(fr.full_damage and fr.changed);
    const total = fr.quads.items.len;

    // Identical input: nothing to do.
    try fr.build(&f, &cells, 3, 4, 0, 0, v);
    try std.testing.expect(!fr.changed);
    try std.testing.expectEqual(@as(usize, 0), fr.rows_rebuilt);

    // Same quad count on row 1: damage is exactly that row's glyph range.
    cells[4].char = 'x';
    try fr.build(&f, &cells, 3, 4, 0, 0, v);
    try std.testing.expect(fr.changed and !fr.full_damage);
    try std.testing.expectEqual(@as(usize, 1), fr.rows_rebuilt);
    try std.testing.expect(fr.dirty_rows.items[1] and !fr.dirty_rows.items[0] and !fr.dirty_rows.items[2]);
    try std.testing.expectEqual(@as(usize, 1), fr.damage.items.len);
    try std.testing.expectEqual(fr.fg_off.items[1], fr.damage.items[0].start);
    try std.testing.expectEqual(fr.fg_off.items[2], fr.damage.items[0].end);
    try std.testing.expectEqual(total, fr.quads.items.len);

    // A selection mark on row 2 adds a background quad: the bg segment
    // shifts from that row on.
    var marks = [_]Mark{.none} ** 12;
    marks[8] = .selected;
    try fr.build(&f, &cells, 3, 4, 0, 0, .{ .cursor_visible = false, .marks = &marks });
    try std.testing.expectEqual(@as(usize, 1), fr.rows_rebuilt);
    try std.testing.expectEqual(total + 1, fr.quads.items.len);
    try std.testing.expectEqual(fr.bg_off.items[2], fr.damage.items[0].start);

    // Moving the block cursor dirties the old and new rows only.
    try fr.build(&f, &cells, 3, 4, 0, 0, .{ .marks = &marks });
    try fr.build(&f, &cells, 3, 4, 2, 0, .{ .marks = &marks });
    try std.testing.expectEqual(@as(usize, 2), fr.rows_rebuilt);
    try std.testing.expect(fr.dirty_rows.items[0] and fr.dirty_rows.items[2]);

    // Font/atlas reset invalidates everything.
    f.resetCache();
    try fr.build(&f, &cells, 3, 4, 2, 0, .{ .marks = &marks });
    try std.testing.expect(fr.full_damage);
    try std.testing.expectEqual(@as(usize, 3), fr.rows_rebuilt);
}
