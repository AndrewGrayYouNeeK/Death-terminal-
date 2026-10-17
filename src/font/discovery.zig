//! fontconfig lookups: family + style → file, and codepoint → fallback file.

const std = @import("std");
const cmod = @import("c.zig");
const c = cmod.c;

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
    if (!cmod.available) return false;
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

test "family aliases match anything" {
    try std.testing.expect(familyMatches("DejaVu Sans Mono", "monospace"));
    try std.testing.expect(familyMatches("JetBrains Mono", "jetbrains mono"));
    try std.testing.expect(!familyMatches("DejaVu Sans", "Fira Code"));
}
