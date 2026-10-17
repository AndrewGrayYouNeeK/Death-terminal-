//! Font lookups: family + style → file, and codepoint → fallback file.
//! fontconfig on Linux; on Windows and macOS the system font directories
//! are scanned once (on first use) with FreeType.

const std = @import("std");
const builtin = @import("builtin");
const cmod = @import("c.zig");
const c = cmod.c;
const env = @import("../platform/env.zig");

pub const Match = struct {
    /// Owned, NUL-terminated path.
    path: [:0]u8,
    index: u32,
    /// Whether fontconfig marks the face as a colour font.
    color: bool = false,
    /// Family name fontconfig matched (owned).
    family: []u8,

    pub fn deinit(self: *Match, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.family);
    }
};

pub const Style = struct { bold: bool = false, italic: bool = false };

var fc_ready: bool = false;

fn ensureInit() bool {
    if (!cmod.have_fontconfig) return false;
    if (!fc_ready) fc_ready = c.FcInit() == c.FcTrue;
    return fc_ready;
}

fn matchFromPattern(allocator: std.mem.Allocator, pat: *c.FcPattern) !?Match {
    var file: [*c]c.FcChar8 = null;
    if (c.FcPatternGetString(pat, c.FC_FILE, 0, &file) != c.FcResultMatch or file == null) return null;
    var index: c_int = 0;
    _ = c.FcPatternGetInteger(pat, c.FC_INDEX, 0, &index);
    var color: c.FcBool = c.FcFalse;
    _ = c.FcPatternGetBool(pat, c.FC_COLOR, 0, &color);
    var fam: [*c]c.FcChar8 = null;
    _ = c.FcPatternGetString(pat, c.FC_FAMILY, 0, &fam);
    const path = try allocator.dupeZ(u8, std.mem.span(@as([*:0]const u8, @ptrCast(file))));
    errdefer allocator.free(path);
    const family = try allocator.dupe(u8, if (fam != null) std.mem.span(@as([*:0]const u8, @ptrCast(fam))) else "");
    return Match{ .path = path, .index = @intCast(@max(0, index)), .color = color == c.FcTrue, .family = family };
}

/// Find `family` in the requested style. Returns null when fontconfig
/// would only substitute a different family.
pub fn findFamily(allocator: std.mem.Allocator, family: []const u8, style: Style) !?Match {
    if (!cmod.have_fontconfig) return scan.findFamily(allocator, family, style);
    if (!ensureInit()) return null;
    const fam_z = try allocator.dupeZ(u8, family);
    defer allocator.free(fam_z);
    const pat = c.FcPatternCreate() orelse return null;
    defer c.FcPatternDestroy(pat);
    _ = c.FcPatternAddString(pat, c.FC_FAMILY, @ptrCast(fam_z.ptr));
    _ = c.FcPatternAddInteger(pat, c.FC_WEIGHT, if (style.bold) c.FC_WEIGHT_BOLD else c.FC_WEIGHT_REGULAR);
    _ = c.FcPatternAddInteger(pat, c.FC_SLANT, if (style.italic) c.FC_SLANT_ITALIC else c.FC_SLANT_ROMAN);
    _ = c.FcConfigSubstitute(null, pat, c.FcMatchPattern);
    c.FcDefaultSubstitute(pat);
    var result: c.FcResult = undefined;
    const found = c.FcFontMatch(null, pat, &result) orelse return null;
    defer c.FcPatternDestroy(found);
    var m = (try matchFromPattern(allocator, found)) orelse return null;
    if (!familyMatches(m.family, family)) {
        m.deinit(allocator);
        return null;
    }
    return m;
}

fn familyMatches(got: []const u8, want: []const u8) bool {
    // Generic aliases resolve to whatever the system prefers.
    const generic = [_][]const u8{ "monospace", "mono", "sans-serif", "sans", "serif" };
    for (generic) |g| if (std.ascii.eqlIgnoreCase(want, g)) return true;
    return std.ascii.eqlIgnoreCase(got, want);
}

/// Best installed font that covers `cp`. `want_color` prefers colour
/// (emoji) fonts and only returns one when it covers `cp`.
pub fn findForCodepoint(allocator: std.mem.Allocator, cp: u21, want_color: bool) !?Match {
    if (!cmod.have_fontconfig) return scan.findForCodepoint(allocator, cp, want_color);
    if (!ensureInit()) return null;
    const pat = c.FcPatternCreate() orelse return null;
    defer c.FcPatternDestroy(pat);
    const cs = c.FcCharSetCreate() orelse return null;
    defer c.FcCharSetDestroy(cs);
    _ = c.FcCharSetAddChar(cs, cp);
    _ = c.FcPatternAddCharSet(pat, c.FC_CHARSET, cs);
    if (want_color) {
        _ = c.FcPatternAddBool(pat, c.FC_COLOR, c.FcTrue);
        _ = c.FcPatternAddString(pat, c.FC_FAMILY, "emoji");
    } else {
        _ = c.FcPatternAddString(pat, c.FC_FAMILY, "monospace");
    }
    _ = c.FcConfigSubstitute(null, pat, c.FcMatchPattern);
    c.FcDefaultSubstitute(pat);
    var result: c.FcResult = undefined;
    const set = c.FcFontSort(null, pat, c.FcFalse, null, &result) orelse return null;
    defer c.FcFontSetDestroy(set);
    var i: usize = 0;
    while (i < @as(usize, @intCast(set.*.nfont))) : (i += 1) {
        const font = set.*.fonts[i];
        var fcs: ?*c.FcCharSet = null;
        if (c.FcPatternGetCharSet(font, c.FC_CHARSET, 0, &fcs) != c.FcResultMatch) continue;
        if (c.FcCharSetHasChar(fcs, cp) != c.FcTrue) continue;
        var color: c.FcBool = c.FcFalse;
        _ = c.FcPatternGetBool(font, c.FC_COLOR, 0, &color);
        if (want_color and color != c.FcTrue) continue;
        // Skip bitmap-only non-colour fonts; they rarely match our size.
        var scalable: c.FcBool = c.FcTrue;
        _ = c.FcPatternGetBool(font, c.FC_SCALABLE, 0, &scalable);
        if (scalable != c.FcTrue and color != c.FcTrue) continue;
        return try matchFromPattern(allocator, font orelse continue);
    }
    return null;
}

/// Directory scan for platforms without fontconfig.
const scan = struct {
    const Entry = struct {
        path: [:0]u8,
        index: u32,
        family: []u8,
        bold: bool,
        italic: bool,
        color: bool,
    };

    var entries: std.ArrayListUnmanaged(Entry) = .{};
    var scanned = false;
    var lock: std.Thread.Mutex = .{};
    const pa = std.heap.page_allocator;

    /// Generic names → families tried in order.
    const monospace = switch (builtin.os.tag) {
        .windows => [_][]const u8{ "Cascadia Mono", "Consolas", "Lucida Console", "Courier New" },
        else => [_][]const u8{ "SF Mono", "Menlo", "Monaco", "Courier New" },
    };
    /// Families tried first for fallback glyphs (symbols, CJK, scripts).
    const preferred = switch (builtin.os.tag) {
        .windows => [_][]const u8{ "Segoe UI Symbol", "Cascadia Mono", "Consolas", "MS Gothic", "Yu Gothic", "Microsoft YaHei", "SimSun", "Malgun Gothic", "Nirmala UI", "Segoe UI", "Segoe UI Historic", "Arial Unicode MS" },
        else => [_][]const u8{ "Menlo", "Apple Symbols", "PingFang SC", "Hiragino Sans", "Apple SD Gothic Neo", "STIXGeneral", "Arial Unicode MS", "Geneva" },
    };
    const emoji = switch (builtin.os.tag) {
        .windows => [_][]const u8{"Segoe UI Emoji"},
        else => [_][]const u8{"Apple Color Emoji"},
    };

    fn dirs(buf: *[6][std.fs.max_path_bytes]u8) [][]const u8 {
        var out: [6][]const u8 = undefined;
        var n: usize = 0;
        const S = struct {
            fn add(o: *[6][]const u8, k: *usize, b: *[std.fs.max_path_bytes]u8, comptime fmt: []const u8, args: anytype) void {
                o[k.*] = std.fmt.bufPrint(b, fmt, args) catch return;
                k.* += 1;
            }
        };
        if (builtin.os.tag == .windows) {
            S.add(&out, &n, &buf[0], "{s}\\Fonts", .{env.get("WINDIR") orelse env.get("SystemRoot") orelse "C:\\Windows"});
            if (env.get("LOCALAPPDATA")) |l| S.add(&out, &n, &buf[1], "{s}\\Microsoft\\Windows\\Fonts", .{l});
        } else {
            S.add(&out, &n, &buf[0], "/System/Library/Fonts", .{});
            S.add(&out, &n, &buf[1], "/System/Library/Fonts/Supplemental", .{});
            S.add(&out, &n, &buf[2], "/Library/Fonts", .{});
            if (env.home()) |h| S.add(&out, &n, &buf[3], "{s}/Library/Fonts", .{h});
        }
        const S2 = struct {
            var keep: [6][]const u8 = undefined;
        };
        S2.keep = out;
        return S2.keep[0..n];
    }

    fn isFontFile(name: []const u8) bool {
        const exts = [_][]const u8{ ".ttf", ".otf", ".ttc", ".otc" };
        for (exts) |e| if (name.len > e.len and std.ascii.eqlIgnoreCase(name[name.len - e.len ..], e)) return true;
        return false;
    }

    fn ensureScanned() void {
        if (scanned) return;
        scanned = true;
        var lib: c.FT_Library = null;
        if (c.FT_Init_FreeType(&lib) != 0) return;
        defer _ = c.FT_Done_FreeType(lib);
        var bufs: [6][std.fs.max_path_bytes]u8 = undefined;
        for (dirs(&bufs)) |dir_path| {
            var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch continue;
            defer dir.close();
            var it = dir.iterate();
            while (it.next() catch null) |e| {
                if (e.kind == .directory or !isFontFile(e.name)) continue;
                const path = std.fs.path.joinZ(pa, &.{ dir_path, e.name }) catch continue;
                addFile(lib, path);
                pa.free(path);
            }
        }
    }

    fn addFile(lib: c.FT_Library, path: [:0]const u8) void {
        var count: c_long = 1;
        var i: c_long = 0;
        while (i < count and i < 64) : (i += 1) {
            var face: c.FT_Face = null;
            if (c.FT_New_Face(lib, path.ptr, i, &face) != 0) return;
            defer _ = c.FT_Done_Face(face);
            count = face.*.num_faces;
            if (face.*.family_name == null) continue;
            const fam = pa.dupe(u8, std.mem.span(face.*.family_name)) catch return;
            const p = pa.dupeZ(u8, path) catch return;
            entries.append(pa, .{
                .path = p,
                .index = @intCast(i),
                .family = fam,
                .bold = face.*.style_flags & c.FT_STYLE_FLAG_BOLD != 0,
                .italic = face.*.style_flags & c.FT_STYLE_FLAG_ITALIC != 0,
                .color = face.*.face_flags & c.FT_FACE_FLAG_COLOR != 0,
            }) catch return;
        }
    }

    fn toMatch(allocator: std.mem.Allocator, e: Entry) !Match {
        const path = try allocator.dupeZ(u8, e.path);
        errdefer allocator.free(path);
        return .{ .path = path, .index = e.index, .color = e.color, .family = try allocator.dupe(u8, e.family) };
    }

    /// Best style match within one family (exact, then regular, then any).
    fn bestOf(family: []const u8, style: Style) ?Entry {
        var fallback: ?Entry = null;
        var any: ?Entry = null;
        for (entries.items) |e| {
            if (!std.ascii.eqlIgnoreCase(e.family, family)) continue;
            if (e.bold == style.bold and e.italic == style.italic) return e;
            if (!e.bold and !e.italic) fallback = e;
            if (any == null) any = e;
        }
        return fallback orelse any;
    }

    fn findFamily(allocator: std.mem.Allocator, family: []const u8, style: Style) !?Match {
        if (!cmod.available) return null;
        lock.lock();
        defer lock.unlock();
        ensureScanned();
        const generic = [_][]const u8{ "monospace", "mono" };
        for (generic) |g| if (std.ascii.eqlIgnoreCase(family, g)) {
            for (monospace) |m| if (bestOf(m, style)) |e| return try toMatch(allocator, e);
            return null;
        };
        const e = bestOf(family, style) orelse return null;
        return try toMatch(allocator, e);
    }

    fn covers(lib: c.FT_Library, e: Entry, cp: u21) bool {
        var face: c.FT_Face = null;
        if (c.FT_New_Face(lib, e.path.ptr, @intCast(e.index), &face) != 0) return false;
        defer _ = c.FT_Done_Face(face);
        return c.FT_Get_Char_Index(face, cp) != 0;
    }

    fn findForCodepoint(allocator: std.mem.Allocator, cp: u21, want_color: bool) !?Match {
        if (!cmod.available) return null;
        lock.lock();
        defer lock.unlock();
        ensureScanned();
        var lib: c.FT_Library = null;
        if (c.FT_Init_FreeType(&lib) != 0) return null;
        defer _ = c.FT_Done_FreeType(lib);
        const first: []const []const u8 = if (want_color) &emoji else &preferred;
        for (first) |fam| {
            for (entries.items) |e| {
                if (!std.ascii.eqlIgnoreCase(e.family, fam) or e.bold or e.italic) continue;
                if (want_color and !e.color) continue;
                if (covers(lib, e, cp)) return try toMatch(allocator, e);
            }
        }
        for (entries.items) |e| {
            if (e.bold or e.italic) continue;
            if (want_color != e.color) continue;
            if (covers(lib, e, cp)) return try toMatch(allocator, e);
        }
        return null;
    }
};

test "family aliases match anything" {
    try std.testing.expect(familyMatches("DejaVu Sans Mono", "monospace"));
    try std.testing.expect(familyMatches("JetBrains Mono", "jetbrains mono"));
    try std.testing.expect(!familyMatches("DejaVu Sans", "Fira Code"));
}
