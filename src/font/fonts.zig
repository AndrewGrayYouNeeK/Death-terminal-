//! Font front-end used by the renderers: picks FreeType or the retro
//! bitmap font, owns the glyph atlas and cache, handles zoom, and lays out a
//! row of cells into positioned glyphs (HarfBuzz-shaped when available).

const std = @import("std");
const cmod = @import("c.zig");
const c = cmod.c;
const atlas_mod = @import("atlas.zig");
const box = @import("box.zig");
const retro = @import("retro.zig");
const face_set = @import("face_set.zig");
const terminal = @import("../terminal/terminal.zig");
const Cell = terminal.Cell;

pub const Atlas = atlas_mod.Atlas;
pub const Rect = atlas_mod.Rect;
pub const Style = face_set.Style;
pub const FaceSet = face_set.FaceSet;

pub const Options = struct {
    /// Empty = bundled JetBrains Mono.
    family: []const u8 = "",
    size_pt: f32 = 11,
    line_height: f32 = 1.0,
    scale: f32 = 1.0,
    retro: bool = false,
    ligatures: bool = true,
    atlas_initial: u32 = 512,
    atlas_max: u32 = 2048,
};

pub const Metrics = face_set.Metrics;

/// A rasterized glyph in the atlas. `left`/`top` place the bitmap relative
/// to the top-left of the first cell it covers.
pub const Glyph = struct {
    rect: Rect,
    left: i32,
    top: i32,
    colored: bool,
};

/// One glyph to draw for a row.
pub const Positioned = struct {
    col: u16,
    span: u8,
    glyph: Glyph,
    /// Extra offset from shaping (px).
    dx: i32 = 0,
    dy: i32 = 0,
};

const Kind = enum(u2) { glyph, sprite, retro };

fn cacheKey(kind: Kind, face: u16, id: u32, synth_bold: bool, synth_italic: bool, span: u8) u64 {
    return @as(u64, id) |
        (@as(u64, face) << 32) |
        (@as(u64, @intFromBool(synth_bold)) << 48) |
        (@as(u64, @intFromBool(synth_italic)) << 49) |
        (@as(u64, @min(span, 15)) << 50) |
        (@as(u64, @intFromEnum(kind)) << 54);
}

pub const zoom_min_pt: f32 = 5;
pub const zoom_max_pt: f32 = 72;

pub const Fonts = struct {
    allocator: std.mem.Allocator,
    opts: Options,
    faces: ?*FaceSet,
    atlas: Atlas,
    cache: std.AutoHashMapUnmanaged(u64, Glyph) = .{},
    metrics: Metrics,
    /// Current size in points (base size ± zoom).
    size_pt: f32,
    scale: f32,
    hb_buf: if (cmod.available) ?*c.hb_buffer_t else ?*anyopaque = null,
    features: [3]if (cmod.available) c.hb_feature_t else u8 = undefined,
    scratch: std.ArrayListUnmanaged(u8) = .{},

    pub fn init(allocator: std.mem.Allocator, opts: Options) !Fonts {
        var self = Fonts{
            .allocator = allocator,
            .opts = opts,
            .faces = null,
            .atlas = try Atlas.init(allocator, opts.atlas_initial, opts.atlas_max),
            .metrics = undefined,
            .size_pt = opts.size_pt,
            .scale = opts.scale,
        };
        errdefer self.atlas.deinit();
        if (!opts.retro) {
            if (FaceSet.init(allocator, .{ .family = opts.family, .size_pt = opts.size_pt, .line_height = opts.line_height, .scale = opts.scale })) |fs| {
                self.faces = fs;
            } else |err| {
                std.debug.print("  → FreeType fonts unavailable ({s}); using retro 8x8 font\n", .{@errorName(err)});
            }
        }
        if (self.faces != null and cmod.available) {
            self.hb_buf = c.hb_buffer_create();
            const names = [_][:0]const u8{ "-liga", "-calt", "-dlig" };
            for (names, 0..) |n, i| _ = c.hb_feature_from_string(n.ptr, -1, &self.features[i]);
        }
        self.computeMetrics();
        return self;
    }

    pub fn deinit(self: *Fonts) void {
        if (self.faces) |fs| fs.deinit();
        if (cmod.available) {
            if (self.hb_buf) |b| c.hb_buffer_destroy(b);
        }
        self.cache.deinit(self.allocator);
        self.scratch.deinit(self.allocator);
        self.atlas.deinit();
    }

    pub fn isRetro(self: *const Fonts) bool {
        return self.faces == null;
    }

    pub fn familyName(self: *const Fonts) []const u8 {
        if (self.faces) |fs| return fs.family_name;
        return "retro 8x8";
    }

    fn computeMetrics(self: *Fonts) void {
        if (self.faces) |fs| {
            self.metrics = fs.metrics;
            return;
        }
        // Retro: 8x16 per unit scale; zoom scales by size / base size.
        const k = @max(0.25, self.scale * self.size_pt / @max(self.opts.size_pt, 1));
        const w: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f32, retro.cell_w) * k))));
        const h: u32 = @max(2, @as(u32, @intFromFloat(@round(@as(f32, retro.cell_h) * k))));
        const t: u32 = @max(1, h / 16);
        self.metrics = .{
            .cell_w = w,
            .cell_h = h,
            .baseline = h * 13 / 16,
            .underline_y = @min(h - 1, h * 14 / 16 + t / 2),
            .underline_thickness = t,
            .strike_y = h * 7 / 16,
        };
    }

    pub fn cellSize(self: *const Fonts) struct { w: u32, h: u32 } {
        return .{ .w = self.metrics.cell_w, .h = self.metrics.cell_h };
    }

    /// Drop every cached glyph (atlas full, size change).
    pub fn resetCache(self: *Fonts) void {
        self.cache.clearRetainingCapacity();
        self.atlas.reset();
    }

    fn applySize(self: *Fonts) !void {
        if (self.faces) |fs| try fs.setPx(FaceSet.pointsToPx(self.size_pt, self.scale));
        self.computeMetrics();
        self.resetCache();
    }

    /// Change DPI scale. Returns true if metrics changed.
    pub fn setScale(self: *Fonts, scale: f32) !bool {
        if (scale == self.scale) return false;
        self.scale = scale;
        const before = self.metrics;
        try self.applySize();
        return before.cell_w != self.metrics.cell_w or before.cell_h != self.metrics.cell_h;
    }

    /// Ctrl+= (+1), Ctrl+- (-1), Ctrl+0 (0 = reset). Returns true if the
    /// cell size changed.
    pub fn zoom(self: *Fonts, step: i8) !bool {
        const before = self.metrics;
        const target = if (step == 0) self.opts.size_pt else std.math.clamp(self.size_pt + @as(f32, @floatFromInt(step)), zoom_min_pt, zoom_max_pt);
        if (target == self.size_pt) return false;
        self.size_pt = target;
        try self.applySize();
        return before.cell_w != self.metrics.cell_w or before.cell_h != self.metrics.cell_h;
    }

    fn boxMetrics(self: *const Fonts, span: u8) box.Metrics {
        return .{
            .w = self.metrics.cell_w * @max(@as(u32, span), 1),
            .h = self.metrics.cell_h,
            .underline_y = self.metrics.underline_y,
            .underline_thickness = self.metrics.underline_thickness,
        };
    }

    fn store(self: *Fonts, key: u64, w: u32, h: u32, left: i32, top: i32, colored: bool, data: []const u8) !Glyph {
        const rect = (try self.atlas.reserve(w, h)) orelse return error.AtlasFull;
        if (w > 0 and h > 0) {
            if (colored) self.atlas.write(rect, data) else self.atlas.writeAlpha(rect, data);
        }
        const g = Glyph{ .rect = rect, .left = left, .top = top, .colored = colored };
        try self.cache.put(self.allocator, key, g);
        return g;
    }

    /// Procedural sprite (box drawing, underline styles, missing box).
    pub fn sprite(self: *Fonts, cp: u21, span: u8) !Glyph {
        const key = cacheKey(.sprite, 0, cp, false, false, span);
        if (self.cache.get(key)) |g| return g;
        const m = self.boxMetrics(span);
        try self.scratch.resize(self.allocator, @as(usize, m.w) * m.h);
        _ = box.render(cp, m, self.scratch.items);
        return self.store(key, m.w, m.h, 0, 0, false, self.scratch.items);
    }

    fn retroGlyph(self: *Fonts, cp: u21) !Glyph {
        const key = cacheKey(.retro, 0, cp, false, false, 1);
        if (self.cache.get(key)) |g| return g;
        const w = self.metrics.cell_w;
        const h = self.metrics.cell_h;
        try self.scratch.resize(self.allocator, @as(usize, w) * h);
        retro.render(cp, w, h, self.scratch.items);
        return self.store(key, w, h, 0, 0, false, self.scratch.items);
    }

    fn faceGlyph(self: *Fonts, ref: face_set.FaceRef, gid: u32, span: u8) !Glyph {
        const key = cacheKey(.glyph, ref.face, gid, ref.synth_bold, ref.synth_italic, span);
        if (self.cache.get(key)) |g| return g;
        const fs = self.faces.?;
        const bm = fs.rasterize(ref, gid, @intCast(@min(span, 3))) catch Bitmap0;
        return self.store(key, bm.w, bm.h, bm.left, bm.top, bm.colored, bm.data);
    }

    const Bitmap0 = face_set.Bitmap{};

    /// Lay out one row of cells: append positioned glyphs (blank cells
    /// produce nothing). May return error.AtlasFull; the caller should
    /// `resetCache` and redo the frame.
    pub fn layoutRow(self: *Fonts, row: []const Cell, out: *std.ArrayList(Positioned)) !void {
        var col: usize = 0;
        while (col < row.len) {
            const cell = row[col];
            const span: u8 = if (cell.width == 2) 2 else 1;
            if (cell.isSpacer() or cell.hidden or (cell.char == ' ' and cell.combining[0] == 0) or cell.char == 0) {
                col += 1;
                continue;
            }
            if (box.isSprite(cell.char)) {
                try out.append(.{ .col = @intCast(col), .span = span, .glyph = try self.sprite(cell.char, span) });
                col += span;
                continue;
            }
            if (self.faces == null) {
                try out.append(.{ .col = @intCast(col), .span = span, .glyph = try self.retroGlyph(cell.char) });
                col += span;
                continue;
            }
            const fs = self.faces.?;
            const ref = resolveCell(fs, cell);
            if (ref.face == face_set.no_face) {
                try out.append(.{ .col = @intCast(col), .span = span, .glyph = try self.sprite(box.sprite_missing, span) });
                col += span;
                continue;
            }
            // Extend the run while cells resolve to the same face/style.
            var end = col + span;
            while (end < row.len) {
                const n = row[end];
                if (n.isSpacer()) {
                    end += 1;
                    continue;
                }
                if (n.hidden or n.char == 0 or box.isSprite(n.char)) break;
                if (n.char == ' ' and n.combining[0] == 0) {
                    // Keep spaces inside runs (ligature context) only if the
                    // primary face is shaping; they draw nothing.
                    if (ref.face != fs.primary[0]) break;
                } else {
                    const r2 = resolveCell(fs, n);
                    if (r2.face != ref.face or r2.synth_bold != ref.synth_bold or r2.synth_italic != ref.synth_italic) break;
                }
                end += if (n.width == 2) 2 else 1;
            }
            try self.shapeRun(row, col, @min(end, row.len), ref, out);
            col = end;
        }
    }

    fn resolveCell(fs: *FaceSet, cell: Cell) face_set.FaceRef {
        var vs16 = false;
        for (cell.combining) |m| {
            if (m == 0xFE0F) vs16 = true;
        }
        const emoji = FaceSet.wantsEmoji(cell.char, vs16) and !(cell.combining[0] == 0xFE0E);
        return fs.resolve(cell.char, Style.of(cell.bold, cell.italic), emoji);
    }

    fn shapeRun(self: *Fonts, row: []const Cell, start: usize, end: usize, ref: face_set.FaceRef, out: *std.ArrayList(Positioned)) !void {
        const fs = self.faces.?;
        const hb_font = fs.hbFont(ref.face);
        const buf = self.hb_buf;
        if (!cmod.available or hb_font == null or buf == null) return self.unshapedRun(row, start, end, ref, out);

        c.hb_buffer_reset(buf);
        var col = start;
        while (col < end) : (col += 1) {
            const cell = row[col];
            if (cell.isSpacer()) continue;
            c.hb_buffer_add(buf, cell.char, @intCast(col));
            for (cell.combining) |m| {
                if (m == 0) break;
                c.hb_buffer_add(buf, m, @intCast(col));
            }
        }
        c.hb_buffer_set_content_type(buf, c.HB_BUFFER_CONTENT_TYPE_UNICODE);
        c.hb_buffer_set_direction(buf, c.HB_DIRECTION_LTR);
        c.hb_buffer_guess_segment_properties(buf);
        if (self.opts.ligatures) {
            c.hb_shape(hb_font, buf, null, 0);
        } else {
            c.hb_shape(hb_font, buf, &self.features, self.features.len);
        }
        var n: c_uint = 0;
        const infos = c.hb_buffer_get_glyph_infos(buf, &n);
        const pos = c.hb_buffer_get_glyph_positions(buf, &n);
        const colored = fs.isColorFace(ref.face);
        var pen: i32 = 0;
        var cluster_pen: i32 = 0;
        var cur_cluster: u32 = std.math.maxInt(u32);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const cl = infos[i].cluster;
            if (cl != cur_cluster) {
                cur_cluster = cl;
                cluster_pen = pen;
            }
            const gid = infos[i].codepoint;
            const ccol: usize = cl;
            const cell = row[ccol];
            // Cells covered by this cluster (ligatures may merge clusters).
            var next: usize = end;
            var j = i + 1;
            while (j < n) : (j += 1) {
                if (infos[j].cluster != cl) {
                    next = infos[j].cluster;
                    break;
                }
            }
            const cells_in_cluster: usize = if (next > ccol) next - ccol else 1;
            const span: u8 = @intCast(@min(@max(cells_in_cluster, if (cell.width == 2) @as(usize, 2) else 1), 8));
            const is_space = cell.char == ' ' and cell.combining[0] == 0;
            if (!is_space) {
                if (gid == 0) {
                    try out.append(.{ .col = @intCast(ccol), .span = span, .glyph = try self.sprite(box.sprite_missing, span) });
                } else {
                    const g = try self.faceGlyph(ref, gid, span);
                    var dx: i32 = 0;
                    var dy: i32 = 0;
                    if (!colored) {
                        dx = @divFloor(pen - cluster_pen + pos[i].x_offset + 32, 64);
                        dy = @divFloor(pos[i].y_offset + 32, 64);
                    }
                    try out.append(.{ .col = @intCast(ccol), .span = span, .glyph = g, .dx = dx, .dy = dy });
                }
            }
            pen += pos[i].x_advance;
        }
    }

    fn unshapedRun(self: *Fonts, row: []const Cell, start: usize, end: usize, ref: face_set.FaceRef, out: *std.ArrayList(Positioned)) !void {
        const fs = self.faces.?;
        var col = start;
        while (col < end) : (col += 1) {
            const cell = row[col];
            if (cell.isSpacer() or cell.char == ' ') continue;
            const span: u8 = if (cell.width == 2) 2 else 1;
            const gid = fs.glyphIndex(ref.face, cell.char);
            const g = if (gid == 0) try self.sprite(box.sprite_missing, span) else try self.faceGlyph(ref, gid, span);
            try out.append(.{ .col = @intCast(col), .span = span, .glyph = g });
        }
    }
};

fn rowFrom(text: []const u21, cells: []Cell) []Cell {
    for (text, 0..) |cp, i| {
        cells[i] = Cell.init();
        cells[i].char = cp;
    }
    return cells[0..text.len];
}

test "retro fonts lay out one glyph per non-blank cell" {
    var f = try Fonts.init(std.testing.allocator, .{ .retro = true });
    defer f.deinit();
    try std.testing.expect(f.isRetro());
    try std.testing.expectEqual(@as(u32, 8), f.metrics.cell_w);
    try std.testing.expectEqual(@as(u32, 16), f.metrics.cell_h);
    var cells: [4]Cell = undefined;
    const row = rowFrom(&.{ 'h', ' ', 'i', 0x2500 }, &cells);
    var out = std.ArrayList(Positioned).init(std.testing.allocator);
    defer out.deinit();
    try f.layoutRow(row, &out);
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expectEqual(@as(u16, 3), out.items[2].col);
}

test "glyph cache reuses atlas slots" {
    var f = try Fonts.init(std.testing.allocator, .{ .retro = true });
    defer f.deinit();
    const a = try f.sprite(0x2500, 1);
    const b = try f.sprite(0x2500, 1);
    try std.testing.expectEqual(a.rect, b.rect);
    const wide = try f.sprite(0x2500, 2);
    try std.testing.expect(wide.rect.w == 2 * a.rect.w);
}

test "atlas full surfaces AtlasFull and reset recovers" {
    var f = try Fonts.init(std.testing.allocator, .{ .retro = true, .atlas_initial = 32, .atlas_max = 32 });
    defer f.deinit();
    var cp: u21 = 0x2500;
    var full = false;
    while (cp < 0x2580) : (cp += 1) {
        _ = f.sprite(cp, 1) catch |err| {
            try std.testing.expectEqual(error.AtlasFull, err);
            full = true;
            break;
        };
    }
    try std.testing.expect(full);
    f.resetCache();
    _ = try f.sprite(0x2500, 1);
}

test "zoom changes cell size and resets" {
    var f = try Fonts.init(std.testing.allocator, .{});
    defer f.deinit();
    const w0 = f.metrics.cell_w;
    try std.testing.expect(try f.zoom(4));
    try std.testing.expect(f.metrics.cell_w > w0);
    try std.testing.expect(try f.zoom(0));
    try std.testing.expectEqual(w0, f.metrics.cell_w);
    try std.testing.expect(!(try f.zoom(0)));
}

test "FreeType layout: ASCII, wide CJK spans two cells, unknown gets missing box" {
    if (!cmod.available) return error.SkipZigTest;
    var f = try Fonts.init(std.testing.allocator, .{});
    defer f.deinit();
    if (f.isRetro()) return error.SkipZigTest;
    var cells: [5]Cell = undefined;
    _ = rowFrom(&.{ 'a', 'b', 0x65E5, ' ', 0x10FFFD }, &cells);
    cells[2].width = 2;
    cells[3].width = 0; // spacer
    var out = std.ArrayList(Positioned).init(std.testing.allocator);
    defer out.deinit();
    f.faces.?.use_fontconfig = std.process.hasEnvVarConstant("DT_TEST_FONTCONFIG");
    try f.layoutRow(&cells, &out);
    try std.testing.expectEqual(@as(usize, 4), out.items.len);
    try std.testing.expectEqual(@as(u16, 2), out.items[2].col);
    try std.testing.expectEqual(@as(u8, 2), out.items[2].span);
    try std.testing.expectEqual(@as(u16, 4), out.items[3].col);
}

test "ligature-capable font keeps one glyph per cell for -> and ==" {
    if (!cmod.available) return error.SkipZigTest;
    var f = try Fonts.init(std.testing.allocator, .{});
    defer f.deinit();
    if (f.isRetro()) return error.SkipZigTest;
    var cells: [4]Cell = undefined;
    const row = rowFrom(&.{ '-', '>', '=', '=' }, &cells);
    var out = std.ArrayList(Positioned).init(std.testing.allocator);
    defer out.deinit();
    try f.layoutRow(row, &out);
    // JetBrains Mono ligatures substitute per-cell glyphs (calt), so the
    // grid stays aligned: every cell still gets exactly one glyph.
    try std.testing.expectEqual(@as(usize, 4), out.items.len);
    for (out.items, 0..) |p, i| try std.testing.expectEqual(@as(u16, @intCast(i)), p.col);
    // With ligatures on, '-' before '>' is a different glyph than alone.
    var lone: [1]Cell = undefined;
    var out2 = std.ArrayList(Positioned).init(std.testing.allocator);
    defer out2.deinit();
    try f.layoutRow(rowFrom(&.{'-'}, &lone), &out2);
    try std.testing.expect(!std.meta.eql(out.items[0].glyph.rect, out2.items[0].glyph.rect));
}
