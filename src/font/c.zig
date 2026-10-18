//! C bindings for FreeType, HarfBuzz and fontconfig (Linux only).

const builtin = @import("builtin");

pub const available = builtin.os.tag == .linux;

pub const c = if (available) @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
    @cInclude("freetype/ftsynth.h");
    @cInclude("freetype/ftoutln.h");
    @cInclude("freetype/tttables.h");
    @cInclude("hb.h");
    @cInclude("hb-ft.h");
    @cInclude("fontconfig/fontconfig.h");
}) else struct {};
