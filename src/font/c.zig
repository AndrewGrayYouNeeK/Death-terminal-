//! C bindings for FreeType and HarfBuzz (system libraries on Linux, built
//! from source on Windows and macOS) and fontconfig (Linux only; elsewhere
//! discovery.zig scans the font directories).

const builtin = @import("builtin");

pub const available = switch (builtin.os.tag) {
    .linux, .windows, .macos => true,
    else => false,
};
pub const have_fontconfig = builtin.os.tag == .linux;

pub const c = if (available) @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
    @cInclude("freetype/ftsynth.h");
    @cInclude("freetype/ftoutln.h");
    @cInclude("freetype/tttables.h");
    @cInclude("hb.h");
    @cInclude("hb-ft.h");
    if (have_fontconfig) @cInclude("fontconfig/fontconfig.h");
}) else struct {};
