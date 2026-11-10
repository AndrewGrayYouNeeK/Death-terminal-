//! Short numbers from the same work `zig build bench` measures, small enough
//! to run inside `zig build test`. The full table is still `zig build bench`.

const std = @import("std");
const t = std.testing;
const Terminal = @import("terminal/terminal.zig").Terminal;
const frame_mod = @import("renderer/frame.zig");
const fonts_mod = @import("font/fonts.zig");
const atlas_mod = @import("font/atlas.zig");
const cmod = @import("font/c.zig");

test "bench: frame time, pty-sized reads, atlas growth" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        _ = gpa.deinit();
    }
    const a = gpa.allocator();

    const bytes: usize = 256 * 1024;
    const chunk: usize = 4096;
    const data = try a.alloc(u8, bytes);
    defer a.free(data);
    var i: usize = 0;
    while (i + 3 <= data.len) : (i += 3) {
        data[i] = 'y';
        data[i + 1] = '\r';
        data[i + 2] = '\n';
    }

    var term = try Terminal.initBuffer(a, 24, 80, 1000);
    defer term.deinit();
    var timer = try std.time.Timer.start();
    var off: usize = 0;
    var reads: usize = 0;
    while (off < data.len) {
        const end = @min(off + chunk, data.len);
        try term.processOutput(data[off..end]);
        off = end;
        reads += 1;
    }
    const parse_ns = timer.read();
    const mib_s = (@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0)) / (@as(f64, @floatFromInt(parse_ns)) / 1e9);

    var frame_ms: f64 = 0;
    if (cmod.available) {
        var fonts = fonts_mod.Fonts.init(a, .{}) catch null;
        if (fonts) |*f| {
            defer f.deinit();
            const grid = try a.alloc(@import("terminal/terminal.zig").Cell, @as(usize, term.rows) * term.cols);
            defer a.free(grid);
            for (0..term.rows) |r| @memcpy(grid[r * term.cols ..][0..term.cols], term.screenRow(@intCast(r)));
            var frame = frame_mod.Frame.init(a);
            defer frame.deinit();
            const view = frame_mod.View.fromTerminal(&term);
            try frame.build(f, grid, term.rows, term.cols, 0, 0, view);
            timer.reset();
            const iters: usize = 20;
            for (0..iters) |_| {
                frame.invalidate();
                try frame.build(f, grid, term.rows, term.cols, 0, 0, view);
            }
            frame_ms = (@as(f64, @floatFromInt(timer.read())) / @as(f64, @floatFromInt(iters))) / 1e6;
        }
    }

    var atlas = try atlas_mod.Atlas.init(a, 32, 256);
    defer atlas.deinit();
    const before = atlas.size;
    var placed: usize = 0;
    while (placed < 40) : (placed += 1) {
        const rect = try atlas.reserve(20, 24);
        if (rect == null) break;
    }
    std.debug.print(
        "bench sample: parse {d} KiB in {d} reads of {d} B -> {d:.1} MiB/s; full frame {d:.3} ms; atlas {d} -> {d} after {d} glyphs\n",
        .{ bytes / 1024, reads, chunk, mib_s, frame_ms, before, atlas.size, placed },
    );
    try t.expect(reads == bytes / chunk);
    try t.expect(mib_s > 0);
    try t.expect(atlas.size > before);
}
