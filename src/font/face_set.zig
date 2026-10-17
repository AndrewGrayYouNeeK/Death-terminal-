//! FreeType faces: the primary family in four styles plus a lazily grown
//! fallback chain (fontconfig charset matches, colour emoji first for emoji
//! presentation). Computes cell metrics and rasterizes glyphs into bitmaps
//! sized for one or two cells.

const std = @import("std");
const cmod = @import("c.zig");
const c = cmod.c;
const discovery = @import("discovery.zig");
const unicode = @import("../terminal/unicode.zig");

pub const Style = enum(u2) {
    regular,
    bold,
    italic,
    bold_italic,

    pub fn of(bold: bool, italic: bool) Style {
        return @enumFromInt(@as(u2, @intFromBool(bold)) | (@as(u2, @intFromBool(italic)) << 1));
    }
    pub fn isBold(s: Style) bool {
        return @intFromEnum(s) & 1 != 0;
    }
    pub fn isItalic(s: Style) bool {
        return @intFromEnum(s) & 2 != 0;
    }
};

pub const Metrics = struct {
    cell_w: u32,
    cell_h: u32,
    /// Baseline, in px from the top of the cell.
    baseline: u32,
    underline_y: u32,
    underline_thickness: u32,
    strike_y: u32,
};

/// Glyph lookup result.
pub const FaceRef = struct {
    face: u16,
    synth_bold: bool = false,
    synth_italic: bool = false,
};

pub const Bitmap = struct {
    w: u32 = 0,
    h: u32 = 0,
    /// Offset of the bitmap's top-left from the cell's top-left, px.
    left: i32 = 0,
    top: i32 = 0,
    colored: bool = false,
    /// Coverage (w*h) or premultiplied RGBA (w*h*4) when `colored`.
    data: []const u8 = &.{},
};

pub const bundled = struct {
    pub const regular = @embedFile("jbm_regular");
    pub const bold = @embedFile("jbm_bold");
    pub const italic = @embedFile("jbm_italic");
    pub const bold_italic = @embedFile("jbm_bold_italic");
    pub const family = "JetBrains Mono";
};

const Face = struct {
    ft: c.FT_Face,
    hb: ?*c.hb_font_t,
    /// Colour bitmap font (CBDT/sbix) with fixed strikes.
    colored: bool,
    fixed: bool,
    /// For deduplicating fallbacks.
    path: ?[:0]u8,
    index: u32,
};

pub const Options = struct {
    family: []const u8 = "",
    size_pt: f32 = 11,
    line_height: f32 = 1.0,
    scale: f32 = 1.0,
};

pub const no_face: u16 = 0xFFFF;
const max_fallbacks = 24;

pub const FaceSet = struct {
    allocator: std.mem.Allocator,
    lib: c.FT_Library,
    faces: std.ArrayListUnmanaged(Face) = .{},
    /// Face index per style for the primary family; `synth[i]` when the
    /// style had to be synthesised from regular.
    primary: [4]u16 = .{ 0, 0, 0, 0 },
    synth_bold: [4]bool = .{ false, false, false, false },
    synth_italic: [4]bool = .{ false, false, false, false },
    family_name: []const u8 = bundled.family,
    /// codepoint → fallback face (no_face = nothing covers it).
    fallback_map: std.AutoHashMapUnmanaged(u32, u16) = .{},
    px: f32 = 14,
    line_height: f32 = 1.0,
    metrics: Metrics = undefined,
    scratch: std.ArrayListUnmanaged(u8) = .{},
    scratch2: std.ArrayListUnmanaged(u8) = .{},
    use_fontconfig: bool = true,

    pub fn init(allocator: std.mem.Allocator, opts: Options) !*FaceSet {
        if (!cmod.available) return error.FreeTypeUnavailable;
        const self = try allocator.create(FaceSet);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .lib = null };
        if (c.FT_Init_FreeType(&self.lib) != 0) return error.FreeTypeInit;
        errdefer _ = c.FT_Done_FreeType(self.lib);
        self.line_height = std.math.clamp(opts.line_height, 0.5, 3.0);
        self.px = pointsToPx(opts.size_pt, opts.scale);

        if (opts.family.len != 0 and !std.ascii.eqlIgnoreCase(opts.family, bundled.family)) {
            self.loadSystemFamily(opts.family) catch |err| {
                std.debug.print("  → font family \"{s}\" not usable ({s}); using bundled {s}\n", .{ opts.family, @errorName(err), bundled.family });
                self.clearFaces();
            };
        }
        if (self.faces.items.len == 0) try self.loadBundled();
        try self.applySize();
        return self;
    }

    pub fn deinit(self: *FaceSet) void {
        self.clearFaces();
        self.faces.deinit(self.allocator);
        self.fallback_map.deinit(self.allocator);
        self.scratch.deinit(self.allocator);
        self.scratch2.deinit(self.allocator);
        _ = c.FT_Done_FreeType(self.lib);
        const a = self.allocator;
        a.destroy(self);
    }

    fn clearFaces(self: *FaceSet) void {
        for (self.faces.items) |f| {
            if (f.hb) |h| c.hb_font_destroy(h);
            _ = c.FT_Done_Face(f.ft);
            if (f.path) |p| self.allocator.free(p);
        }
        self.faces.clearRetainingCapacity();
        self.fallback_map.clearRetainingCapacity();
    }

    pub fn pointsToPx(pt: f32, scale: f32) f32 {
        return std.math.clamp(pt, 4, 96) * 96.0 / 72.0 * @max(scale, 0.5);
    }

    fn addFace(self: *FaceSet, ft: c.FT_Face, path: ?[:0]u8, index: u32) !u16 {
        const colored = c.FT_HAS_COLOR(ft);
        const fixed = !c.FT_IS_SCALABLE(ft);
        _ = c.FT_Select_Charmap(ft, c.FT_ENCODING_UNICODE);
        try self.faces.append(self.allocator, .{ .ft = ft, .hb = null, .colored = colored, .fixed = fixed, .path = path, .index = index });
        return @intCast(self.faces.items.len - 1);
    }

    fn openMemory(self: *FaceSet, data: []const u8) !c.FT_Face {
        var ft: c.FT_Face = null;
        if (c.FT_New_Memory_Face(self.lib, data.ptr, @intCast(data.len), 0, &ft) != 0) return error.BadFont;
        return ft;
    }

    fn openPath(self: *FaceSet, path: [:0]const u8, index: u32) !c.FT_Face {
        var ft: c.FT_Face = null;
        if (c.FT_New_Face(self.lib, path.ptr, @intCast(index), &ft) != 0) return error.BadFont;
        return ft;
    }

    fn loadBundled(self: *FaceSet) !void {
        const datas = [4][]const u8{ bundled.regular, bundled.bold, bundled.italic, bundled.bold_italic };
        for (datas, 0..) |d, i| {
            const ft = try self.openMemory(d);
            self.primary[i] = try self.addFace(ft, null, 0);
        }
        self.family_name = bundled.family;
    }

    fn loadSystemFamily(self: *FaceSet, family: []const u8) !void {
        var regular = (try discovery.findFamily(self.allocator, family, .{})) orelse return error.FamilyNotFound;
        defer regular.deinit(self.allocator);
        const reg_ft = try self.openPath(regular.path, regular.index);
        self.primary[0] = try self.addFace(reg_ft, try self.allocator.dupeZ(u8, regular.path), regular.index);
        var i: u2 = 1;
        while (true) : (i += 1) {
            const st: Style = @enumFromInt(i);
            const m = try discovery.findFamily(self.allocator, family, .{ .bold = st.isBold(), .italic = st.isItalic() });
            if (m) |found| {
                var mm = found;
                defer mm.deinit(self.allocator);
                if (std.mem.eql(u8, mm.path, regular.path) and mm.index == regular.index) {
                    self.primary[i] = self.primary[0];
                    self.synth_bold[i] = st.isBold();
                    self.synth_italic[i] = st.isItalic();
                } else {
                    const ft = try self.openPath(mm.path, mm.index);
                    self.primary[i] = try self.addFace(ft, try self.allocator.dupeZ(u8, mm.path), mm.index);
                    // fontconfig may hand back e.g. Regular for Bold if that's all there is.
                    const sf = self.faces.items[self.primary[i]].ft.*.style_flags;
                    self.synth_bold[i] = st.isBold() and (sf & c.FT_STYLE_FLAG_BOLD) == 0;
                    self.synth_italic[i] = st.isItalic() and (sf & c.FT_STYLE_FLAG_ITALIC) == 0;
                }
            } else {
                self.primary[i] = self.primary[0];
                self.synth_bold[i] = st.isBold();
                self.synth_italic[i] = st.isItalic();
            }
            if (i == 3) break;
        }
        self.family_name = family;
    }

    /// Change the pixel size (zoom / DPI change).
    pub fn setPx(self: *FaceSet, px: f32) !void {
        self.px = std.math.clamp(px, 5, 200);
        try self.applySize();
    }

    fn sizeFace(self: *FaceSet, f: *Face) void {
        if (f.fixed) {
            // Pick the strike closest to (but not below) the cell height.
            const ft = f.ft;
            var best: c_int = 0;
            var i: c_int = 0;
            while (i < ft.*.num_fixed_sizes) : (i += 1) {
                const hh = ft.*.available_sizes[@intCast(i)].height;
                const bh = ft.*.available_sizes[@intCast(best)].height;
                if ((hh >= @as(c_short, @intFromFloat(self.px)) and (hh < bh or bh < @as(c_short, @intFromFloat(self.px)))) or (bh < @as(c_short, @intFromFloat(self.px)) and hh > bh)) best = i;
            }
            _ = c.FT_Select_Size(ft, best);
        } else {
            _ = c.FT_Set_Char_Size(f.ft, 0, @intFromFloat(@round(self.px * 64)), 72, 72);
        }
        if (f.hb) |h| {
            c.hb_ft_font_changed(h);
        } else {
            f.hb = c.hb_ft_font_create_referenced(f.ft);
        }
        if (f.hb) |h| c.hb_ft_font_set_load_flags(h, @intCast(loadFlags(f.*)));
    }

    fn applySize(self: *FaceSet) !void {
        for (self.faces.items) |*f| self.sizeFace(f);
        self.metrics = computeMetrics(self.faces.items[self.primary[0]].ft, self.px, self.line_height);
    }

    fn computeMetrics(ft: c.FT_Face, px: f32, line_height: f32) Metrics {
        const units: f32 = @floatFromInt(@max(1, ft.*.units_per_EM));
        const k = px / units;
        var adv: f32 = px * 0.6;
        const gid = c.FT_Get_Char_Index(ft, 'M');
        if (gid != 0 and c.FT_Load_Glyph(ft, gid, c.FT_LOAD_NO_HINTING) == 0) {
            adv = @as(f32, @floatFromInt(ft.*.glyph.*.linearHoriAdvance)) / 65536.0;
        }
        var asc = @as(f32, @floatFromInt(ft.*.ascender)) * k;
        var desc = -@as(f32, @floatFromInt(ft.*.descender)) * k;
        // Prefer OS/2 typo/win metrics when the hhea ones are missing.
        if (asc <= 0) asc = px * 0.8;
        if (desc <= 0) desc = px * 0.2;
        const ascent: u32 = @intFromFloat(@ceil(asc - 0.01));
        const descent: u32 = @intFromFloat(@ceil(desc - 0.01));
        const natural = ascent + descent;
        const cell_h: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(natural)) * line_height))));
        const pad = (@as(i64, cell_h) - @as(i64, natural));
        const baseline: u32 = @intCast(std.math.clamp(@as(i64, ascent) + @divFloor(pad, 2), 1, @as(i64, cell_h) - 1));
        const cell_w: u32 = @max(1, @as(u32, @intFromFloat(@round(adv))));

        var thick = @as(f32, @floatFromInt(ft.*.underline_thickness)) * k;
        if (thick <= 0) thick = px / 14;
        const ut: u32 = @max(1, @as(u32, @intFromFloat(@round(thick))));
        var upos = -@as(f32, @floatFromInt(ft.*.underline_position)) * k;
        if (upos <= 0) upos = px * 0.1;
        var uy: u32 = baseline + @as(u32, @intFromFloat(@round(upos)));
        uy = @min(uy, cell_h - (ut + 1) / 2 - @intFromBool(ut % 2 == 0));
        var strike: u32 = baseline -| @as(u32, @intFromFloat(@round(px * 0.27)));
        const os2: ?*c.TT_OS2 = @ptrCast(@alignCast(c.FT_Get_Sfnt_Table(ft, c.FT_SFNT_OS2)));
        if (os2) |t| {
            if (t.yStrikeoutPosition > 0) strike = baseline -| @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(t.yStrikeoutPosition)) * k)));
        }
        return .{ .cell_w = cell_w, .cell_h = cell_h, .baseline = baseline, .underline_y = uy, .underline_thickness = ut, .strike_y = strike };
    }

    fn loadFlags(f: Face) i32 {
        if (f.colored) return c.FT_LOAD_COLOR;
        return c.FT_LOAD_TARGET_LIGHT | c.FT_LOAD_NO_BITMAP;
    }

    pub fn hasGlyph(self: *const FaceSet, face: u16, cp: u21) bool {
        return c.FT_Get_Char_Index(self.faces.items[face].ft, cp) != 0;
    }

    pub fn glyphIndex(self: *const FaceSet, face: u16, cp: u21) u32 {
        return c.FT_Get_Char_Index(self.faces.items[face].ft, cp);
    }

    pub fn hbFont(self: *const FaceSet, face: u16) ?*c.hb_font_t {
        return self.faces.items[face].hb;
    }

    pub fn isColorFace(self: *const FaceSet, face: u16) bool {
        return self.faces.items[face].colored;
    }

    /// Codepoints drawn with emoji presentation (colour font preferred).
    pub fn wantsEmoji(cp: u21, vs16: bool) bool {
        if (vs16) return true;
        return switch (cp) {
            0x1F000...0x1FAFF => unicode.width(cp) == 2,
            0x2600...0x27BF, 0x2B00...0x2BFF, 0x2300...0x23FF => unicode.width(cp) == 2,
            else => false,
        };
    }

    /// Choose a face for `cp` in `style`: primary style face, then primary
    /// regular with synthesis, then fallbacks.
    pub fn resolve(self: *FaceSet, cp: u21, style: Style, emoji: bool) FaceRef {
        const si = @intFromEnum(style);
        if (!emoji) {
            const pf = self.primary[si];
            if (self.hasGlyph(pf, cp)) return .{ .face = pf, .synth_bold = self.synth_bold[si], .synth_italic = self.synth_italic[si] };
            if (si != 0 and self.hasGlyph(self.primary[0], cp)) {
                return .{ .face = self.primary[0], .synth_bold = style.isBold(), .synth_italic = style.isItalic() };
            }
        }
        const fb = self.fallbackFor(cp, emoji);
        if (fb == no_face) {
            if (emoji and self.hasGlyph(self.primary[si], cp)) return .{ .face = self.primary[si] };
            return .{ .face = no_face };
        }
        const colored = self.faces.items[fb].colored;
        return .{ .face = fb, .synth_bold = style.isBold() and !colored, .synth_italic = style.isItalic() and !colored };
    }

    fn fallbackFor(self: *FaceSet, cp: u21, emoji: bool) u16 {
        const key: u32 = @as(u32, cp) | (@as(u32, @intFromBool(emoji)) << 24);
        if (self.fallback_map.get(key)) |f| return f;
        const f = self.findFallback(cp, emoji) catch no_face;
        self.fallback_map.put(self.allocator, key, f) catch {};
        return f;
    }

    fn findFallback(self: *FaceSet, cp: u21, emoji: bool) !u16 {
        // Already-loaded fallbacks first (cheap, keeps the chain short).
        for (self.faces.items, 0..) |f, i| {
            const idx: u16 = @intCast(i);
            if (isPrimary(self, idx)) continue;
            if (emoji and !f.colored) continue;
            if (self.hasGlyph(idx, cp)) return idx;
        }
        if (!self.use_fontconfig) return no_face;
        var m = (try discovery.findForCodepoint(self.allocator, cp, emoji)) orelse {
            if (emoji) return self.findFallback(cp, false);
            return no_face;
        };
        defer m.deinit(self.allocator);
        for (self.faces.items, 0..) |f, i| {
            if (f.path) |p| if (std.mem.eql(u8, p, m.path) and f.index == m.index) return @intCast(i);
        }
        if (self.faces.items.len >= max_fallbacks + 4) return no_face;
        const ft = try self.openPath(m.path, m.index);
        const idx = try self.addFace(ft, try self.allocator.dupeZ(u8, m.path), m.index);
        self.sizeFace(&self.faces.items[idx]);
        if (!self.hasGlyph(idx, cp)) return no_face;
        return idx;
    }

    pub fn isPrimaryFace(self: *const FaceSet, idx: u16) bool {
        return self.isPrimary(idx);
    }

    fn isPrimary(self: *const FaceSet, idx: u16) bool {
        for (self.primary) |p| if (p == idx) return true;
        return false;
    }

    /// Rasterize `glyph` from `ref.face` to fit `span` cells. The returned
    /// bitmap's data lives in internal scratch until the next call.
    pub fn rasterize(self: *FaceSet, ref: FaceRef, glyph: u32, span: u2) !Bitmap {
        const f = self.faces.items[ref.face];
        const ft = f.ft;
        const m = self.metrics;
        const span_w: f32 = @floatFromInt(m.cell_w * @max(@as(u32, span), 1));
        if (c.FT_Load_Glyph(ft, glyph, loadFlags(f)) != 0) return error.LoadGlyph;
        const slot = ft.*.glyph;
        if (slot.*.format == c.FT_GLYPH_FORMAT_OUTLINE) {
            if (ref.synth_bold) _ = c.FT_Outline_Embolden(&slot.*.outline, @intFromFloat(@max(64, self.px * 64 / 24)));
            if (ref.synth_italic) {
                var mat = c.FT_Matrix{ .xx = 0x10000, .xy = 0x0366A, .yx = 0, .yy = 0x10000 };
                c.FT_Outline_Transform(&slot.*.outline, &mat);
            }
            // Shrink glyphs whose advance overflows their cells (wide
            // symbols from proportional fallbacks, CJK in narrow fonts).
            // Ink alone may overhang: monospace ligature glyphs (e.g.
            // JetBrains Mono's `->`) keep a one-cell advance and draw
            // leftwards over the preceding cells by design.
            var cbox: c.FT_BBox = undefined;
            c.FT_Outline_Get_CBox(&slot.*.outline, &cbox);
            const gw = @as(f32, @floatFromInt(cbox.xMax - cbox.xMin)) / 64.0;
            const adv = @as(f32, @floatFromInt(slot.*.advance.x)) / 64.0;
            const limit = span_w * 1.05;
            if (adv > limit + 1 and gw > 0) {
                const k = limit / @max(gw, adv);
                const kk: c.FT_Fixed = @intFromFloat(k * 65536);
                var mat = c.FT_Matrix{ .xx = kk, .xy = 0, .yx = 0, .yy = kk };
                c.FT_Outline_Transform(&slot.*.outline, &mat);
                c.FT_Outline_Get_CBox(&slot.*.outline, &cbox);
                // Centre horizontally in the span.
                const new_w = cbox.xMax - cbox.xMin;
                const target_left: c.FT_Pos = @intFromFloat((span_w * 64 - @as(f32, @floatFromInt(new_w))) / 2);
                c.FT_Outline_Translate(&slot.*.outline, target_left - cbox.xMin, 0);
            }
            if (c.FT_Render_Glyph(slot, c.FT_RENDER_MODE_LIGHT) != 0) return error.Render;
        } else if (slot.*.format != c.FT_GLYPH_FORMAT_BITMAP) {
            if (c.FT_Render_Glyph(slot, c.FT_RENDER_MODE_NORMAL) != 0) return error.Render;
        }
        const bm = slot.*.bitmap;
        const bw: u32 = bm.width;
        const bh: u32 = bm.rows;
        if (bw == 0 or bh == 0) return Bitmap{};
        const pitch: i32 = bm.pitch;
        const row_ptr = struct {
            fn get(buffer: [*c]u8, p: i32, rows: u32, y: u32) [*]const u8 {
                const off: isize = if (p >= 0) @as(isize, p) * @as(isize, @intCast(y)) else @as(isize, -p) * @as(isize, @intCast(rows - 1 - y));
                return @ptrCast(buffer + @as(usize, @intCast(off)));
            }
        }.get;

        switch (bm.pixel_mode) {
            c.FT_PIXEL_MODE_GRAY, c.FT_PIXEL_MODE_MONO => {
                try self.scratch.resize(self.allocator, bw * bh);
                var y: u32 = 0;
                while (y < bh) : (y += 1) {
                    const src = row_ptr(bm.buffer, pitch, bh, y);
                    var x: u32 = 0;
                    while (x < bw) : (x += 1) {
                        self.scratch.items[y * bw + x] = if (bm.pixel_mode == c.FT_PIXEL_MODE_MONO)
                            (if ((src[x / 8] >> @intCast(7 - x % 8)) & 1 != 0) 255 else 0)
                        else
                            src[x];
                    }
                }
                return .{
                    .w = bw,
                    .h = bh,
                    .left = slot.*.bitmap_left,
                    .top = @as(i32, @intCast(m.baseline)) - slot.*.bitmap_top,
                    .data = self.scratch.items,
                };
            },
            c.FT_PIXEL_MODE_BGRA => {
                // Colour bitmap: scale to fit span × cell height.
                try self.scratch2.resize(self.allocator, bw * bh * 4);
                var y: u32 = 0;
                while (y < bh) : (y += 1) {
                    const src = row_ptr(bm.buffer, pitch, bh, y);
                    var x: u32 = 0;
                    while (x < bw) : (x += 1) {
                        const o = (y * bw + x) * 4;
                        self.scratch2.items[o + 0] = src[x * 4 + 2];
                        self.scratch2.items[o + 1] = src[x * 4 + 1];
                        self.scratch2.items[o + 2] = src[x * 4 + 0];
                        self.scratch2.items[o + 3] = src[x * 4 + 3];
                    }
                }
                const ch: f32 = @floatFromInt(m.cell_h);
                const k = @min(span_w / @as(f32, @floatFromInt(bw)), ch / @as(f32, @floatFromInt(bh)));
                const tw: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(bw)) * k))));
                const th: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(bh)) * k))));
                try self.scratch.resize(self.allocator, tw * th * 4);
                resampleRgba(self.scratch2.items, bw, bh, self.scratch.items, tw, th);
                return .{
                    .w = tw,
                    .h = th,
                    .left = @intFromFloat(@round((span_w - @as(f32, @floatFromInt(tw))) / 2)),
                    .top = @intFromFloat(@round((ch - @as(f32, @floatFromInt(th))) / 2)),
                    .colored = true,
                    .data = self.scratch.items,
                };
            },
            else => return error.UnsupportedPixelMode,
        }
    }
};

/// Area-averaging resample of premultiplied RGBA (downscale; also works
/// for mild upscales).
pub fn resampleRgba(src: []const u8, sw: u32, sh: u32, dst: []u8, dw: u32, dh: u32) void {
    const fx = @as(f32, @floatFromInt(sw)) / @as(f32, @floatFromInt(dw));
    const fy = @as(f32, @floatFromInt(sh)) / @as(f32, @floatFromInt(dh));
    var y: u32 = 0;
    while (y < dh) : (y += 1) {
        const y0 = @as(f32, @floatFromInt(y)) * fy;
        const y1 = y0 + fy;
        var x: u32 = 0;
        while (x < dw) : (x += 1) {
            const x0 = @as(f32, @floatFromInt(x)) * fx;
            const x1 = x0 + fx;
            var acc = [4]f32{ 0, 0, 0, 0 };
            var wsum: f32 = 0;
            var sy: u32 = @intFromFloat(@floor(y0));
            while (sy < sh and @as(f32, @floatFromInt(sy)) < y1) : (sy += 1) {
                const wy = @min(y1, @as(f32, @floatFromInt(sy + 1))) - @max(y0, @as(f32, @floatFromInt(sy)));
                var sx: u32 = @intFromFloat(@floor(x0));
                while (sx < sw and @as(f32, @floatFromInt(sx)) < x1) : (sx += 1) {
                    const wx = @min(x1, @as(f32, @floatFromInt(sx + 1))) - @max(x0, @as(f32, @floatFromInt(sx)));
                    const wgt = @max(0, wx) * @max(0, wy);
                    const o = (sy * sw + sx) * 4;
                    inline for (0..4) |ch| acc[ch] += @as(f32, @floatFromInt(src[o + ch])) * wgt;
                    wsum += wgt;
                }
            }
            const o = (y * dw + x) * 4;
            inline for (0..4) |ch| dst[o + ch] = @intFromFloat(@min(255, @round(acc[ch] / @max(wsum, 1e-6))));
        }
    }
}

test "resample halves a 2x2 block to its average" {
    const src = [_]u8{ 255, 0, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0, 255, 0, 0, 255 };
    var dst: [4]u8 = undefined;
    resampleRgba(&src, 2, 2, &dst, 1, 1);
    try std.testing.expectEqual(@as(u8, 128), dst[0]);
    try std.testing.expectEqual(@as(u8, 128), dst[3]);
}

test "Style packs bold and italic" {
    try std.testing.expectEqual(Style.bold_italic, Style.of(true, true));
    try std.testing.expect(Style.of(false, true).isItalic());
    try std.testing.expect(!Style.of(false, true).isBold());
}

test "bundled font loads with sane metrics" {
    if (!cmod.available) return error.SkipZigTest;
    const fs = try FaceSet.init(std.testing.allocator, .{ .size_pt = 11 });
    defer fs.deinit();
    const m = fs.metrics;
    // JetBrains Mono: advance 0.6 em, ascent+descent ≈ 1.32 em.
    try std.testing.expect(m.cell_w >= 8 and m.cell_w <= 10);
    try std.testing.expect(m.cell_h >= 18 and m.cell_h <= 21);
    try std.testing.expect(m.baseline > m.cell_h / 2 and m.baseline < m.cell_h);
    try std.testing.expect(m.underline_y > m.baseline and m.underline_y < m.cell_h);
    try std.testing.expect(m.strike_y < m.baseline);
    try fs.setPx(FaceSet.pointsToPx(22, 1));
    try std.testing.expect(fs.metrics.cell_w >= 2 * m.cell_w - 1);
}

test "line height scales the cell but not the advance" {
    if (!cmod.available) return error.SkipZigTest;
    const a = try FaceSet.init(std.testing.allocator, .{ .size_pt = 11 });
    defer a.deinit();
    const b = try FaceSet.init(std.testing.allocator, .{ .size_pt = 11, .line_height = 1.5 });
    defer b.deinit();
    try std.testing.expectEqual(a.metrics.cell_w, b.metrics.cell_w);
    try std.testing.expect(b.metrics.cell_h > a.metrics.cell_h + 5);
}

test "resolve: ASCII from primary, bold uses bold face, missing glyph falls back" {
    if (!cmod.available) return error.SkipZigTest;
    const fs = try FaceSet.init(std.testing.allocator, .{});
    defer fs.deinit();
    const a = fs.resolve('A', .regular, false);
    try std.testing.expectEqual(fs.primary[0], a.face);
    const b = fs.resolve('A', .bold, false);
    try std.testing.expectEqual(fs.primary[1], b.face);
    try std.testing.expect(!b.synth_bold);
    // JetBrains Mono has no CJK; the fallback (if any is installed) is another face.
    const cjk = fs.resolve(0x65E5, .regular, false);
    if (cjk.face != no_face) try std.testing.expect(!fs.isPrimaryFace(cjk.face));
    // Something nobody covers.
    fs.use_fontconfig = false;
    try std.testing.expectEqual(no_face, fs.resolve(0x10FFFD, .regular, false).face);
}

test "emoji presentation detection" {
    try std.testing.expect(FaceSet.wantsEmoji(0x1F642, false));
    try std.testing.expect(!FaceSet.wantsEmoji('A', false));
    try std.testing.expect(FaceSet.wantsEmoji(0x2764, true));
}

test "rasterize renders an ASCII glyph inside the cell" {
    if (!cmod.available) return error.SkipZigTest;
    const fs = try FaceSet.init(std.testing.allocator, .{});
    defer fs.deinit();
    const ref = fs.resolve('H', .regular, false);
    const bm = try fs.rasterize(ref, fs.glyphIndex(ref.face, 'H'), 1);
    try std.testing.expect(bm.w > 2 and bm.w <= fs.metrics.cell_w);
    try std.testing.expect(bm.top >= 0 and bm.top + @as(i32, @intCast(bm.h)) <= @as(i32, @intCast(fs.metrics.baseline)) + 1);
    var lit: usize = 0;
    for (bm.data) |p| lit += @intFromBool(p > 128);
    try std.testing.expect(lit > 10);
}
