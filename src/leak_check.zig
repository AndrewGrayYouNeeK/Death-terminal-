//! Explicit GeneralPurposeAllocator leak check. `std.testing.allocator` is
//! also a leak-checking GPA; this test owns its own so the result is a
//! number we can print.

const std = @import("std");
const t = std.testing;
const Terminal = @import("terminal/terminal.zig").Terminal;
const frame_mod = @import("renderer/frame.zig");
const fonts_mod = @import("font/fonts.zig");
const cmod = @import("font/c.zig");
const config = @import("config/config.zig");
const lua_config = @import("config/lua_config.zig");

test "leak check: terminal, frame, and lua config" {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
    const a = gpa.allocator();
    {
        var term = try Terminal.initBuffer(a, 8, 40, 64);
        defer term.deinit();
        try term.processOutput("\x1b[31mhello\x1b[0m\r\n\x1b[2J\x1b[H");
        if (cmod.available) {
            var fonts = fonts_mod.Fonts.init(a, .{}) catch null;
            if (fonts) |*f| {
                defer f.deinit();
                const n = @as(usize, term.rows) * term.cols;
                const grid = try a.alloc(@import("terminal/terminal.zig").Cell, n);
                defer a.free(grid);
                for (0..term.rows) |r| @memcpy(grid[r * term.cols ..][0..term.cols], term.screenRow(@intCast(r)));
                var frame = frame_mod.Frame.init(a);
                defer frame.deinit();
                try frame.build(f, grid, term.rows, term.cols, term.cursor_row, term.cursor_col, frame_mod.View.fromTerminal(&term));
            }
        }
        var cfg = config.Config.init(a);
        defer cfg.deinit();
        var diags = config.Diagnostics.init(a);
        defer diags.deinit();
        lua_config.loadString(&cfg, "config.font.size = 12\n", "leak.lua", .{}, &diags);
    }
    const status = gpa.deinit();
    const leaked = status == .leak;
    std.debug.print("leak check (GPA): {s}\n", .{if (leaked) "LEAK" else "clean"});
    try t.expect(!leaked);
}
