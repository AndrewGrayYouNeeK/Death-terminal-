//! `zig build bench`: parser/terminal throughput and frame-building cost.
//! Prints a Markdown table so results can be pasted into docs/PERFORMANCE.md.

const std = @import("std");
const terminal = @import("terminal/terminal.zig");
const frame_mod = @import("renderer/frame.zig");
const software = @import("renderer/software.zig");
const text = @import("renderer/text_renderer.zig");
const fonts_mod = @import("font/fonts.zig");

const Timer = std.time.Timer;

fn makeAscii(alloc: std.mem.Allocator, bytes: usize) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(alloc, bytes + 128);
    const line = "The quick brown fox jumps over the lazy dog 0123456789 ~!@#$%^&*() lorem ipsum dolor sit amet\r\n";
    var i: usize = 0;
    while (out.items.len < bytes) : (i += 1) {
        try out.writer().print("{d:>8} ", .{i});
        try out.appendSlice(line);
    }
    return out.toOwnedSlice();
}

fn makeYes(alloc: std.mem.Allocator, bytes: usize) ![]u8 {
    const out = try alloc.alloc(u8, bytes - bytes % 3);
    var i: usize = 0;
    while (i < out.len) : (i += 3) {
        out[i] = 'y';
        out[i + 1] = '\r';
        out[i + 2] = '\n';
    }
    return out;
}

fn makeSgr(alloc: std.mem.Allocator, bytes: usize) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(alloc, bytes + 128);
    var i: usize = 0;
    while (out.items.len < bytes) : (i += 1) {
        try out.writer().print("\x1b[38;5;{d}m{s}\x1b[1;48;2;{d};{d};40m{d}\x1b[0m ", .{ i % 256, "word", i % 200, (i * 7) % 256, i });
        if (i % 12 == 11) try out.appendSlice("\r\n");
    }
    return out.toOwnedSlice();
}

fn makeUtf8(alloc: std.mem.Allocator, bytes: usize) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(alloc, bytes + 128);
    const line = "日本語のテキスト ünïcödé — ελληνικά кириллица 中文 😀 🎉 e\u{301}\r\n";
    while (out.items.len < bytes) try out.appendSlice(line);
    return out.toOwnedSlice();
}

fn makeCursor(alloc: std.mem.Allocator, bytes: usize) ![]u8 {
    // Full-screen app style: absolute moves + short writes (vim/htop redraw).
    var out = try std.ArrayList(u8).initCapacity(alloc, bytes + 128);
    var i: usize = 0;
    while (out.items.len < bytes) : (i += 1) {
        try out.writer().print("\x1b[{d};{d}H\x1b[K{d}%", .{ i % 50 + 1, (i * 13) % 100 + 1, i % 100 });
    }
    return out.toOwnedSlice();
}

const Result = struct { name: []const u8, mb: f64, secs: f64 };

fn parseBench(alloc: std.mem.Allocator, name: []const u8, data: []const u8, chunk: usize) !Result {
    var term = try terminal.Terminal.initBuffer(alloc, 50, 120, 10_000);
    defer term.deinit();
    var timer = try Timer.start();
    var off: usize = 0;
    while (off < data.len) {
        const end = @min(off + chunk, data.len);
        try term.processOutput(data[off..end]);
        term.replies.clearRetainingCapacity();
        off = end;
    }
    const ns = timer.read();
    return .{ .name = name, .mb = @as(f64, @floatFromInt(data.len)) / (1024 * 1024), .secs = @as(f64, @floatFromInt(ns)) / 1e9 };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const out = std.io.getStdOut().writer();

    // `zig build bench -- frames` skips the (slow) parser section.
    var frames_only = false;
    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "frames")) frames_only = true;
    }
    const size: usize = if (frames_only) 0 else 32 * 1024 * 1024;
    try out.print("Cell = {d} bytes\n\n", .{@sizeOf(terminal.Cell)});
    try out.print("## Parser / emulator throughput (120x50, 10k scrollback, 64 KiB chunks)\n\n| workload | MiB | seconds | MiB/s |\n|---|---:|---:|---:|\n", .{});
    const gens = .{
        .{ "ascii text", makeAscii },
        .{ "yes (y\\r\\n)", makeYes },
        .{ "SGR colours", makeSgr },
        .{ "UTF-8 / CJK / emoji", makeUtf8 },
        .{ "cursor moves (TUI)", makeCursor },
    };
    inline for (gens) |g| if (!frames_only) {
        const data = try g[1](alloc, size);
        defer alloc.free(data);
        const r = try parseBench(alloc, g[0], data, 64 * 1024);
        try out.print("| {s} | {d:.0} | {d:.3} | {d:.1} |\n", .{ r.name, r.mb, r.secs, r.mb / r.secs });
    };

    // ---- frames
    try out.print("\n## Frame building (120x50, JetBrains Mono 11pt)\n\n| step | per frame | frames/s |\n|---|---:|---:|\n", .{});
    var fonts = try fonts_mod.Fonts.init(alloc, .{});
    defer fonts.deinit();
    var term = try terminal.Terminal.initBuffer(alloc, 50, 120, 1000);
    defer term.deinit();
    {
        const data = try makeSgr(alloc, 64 * 1024);
        defer alloc.free(data);
        try term.processOutput(data);
    }
    var fr = frame_mod.Frame.init(alloc);
    defer fr.deinit();
    const view = frame_mod.View.fromTerminal(&term);
    // The renderer takes the visible grid in row order (the UI composes it
    // from the terminal's row map); build it once here.
    const grid = try alloc.alloc(terminal.Cell, @as(usize, term.rows) * term.cols);
    defer alloc.free(grid);
    for (0..term.rows) |r| @memcpy(grid[r * term.cols ..][0..term.cols], term.screenRow(@intCast(r)));
    // Warm the glyph cache.
    try fr.build(&fonts, grid, term.rows, term.cols, term.cursor_row, term.cursor_col, view);

    const iters: usize = 200;
    {
        var timer = try Timer.start();
        for (0..iters) |_| {
            fr.invalidate();
            try fr.build(&fonts, grid, term.rows, term.cols, term.cursor_row, term.cursor_col, view);
        }
        try report(out, "full rebuild (shape + quads)", timer.read(), iters);
    }
    {
        var timer = try Timer.start();
        for (0..iters) |i| {
            for (0..term.rows) |r| grid[r * term.cols + term.cols - 1].char = @intCast('a' + i % 26);
            try fr.build(&fonts, grid, term.rows, term.cols, term.cursor_row, term.cursor_col, view);
        }
        try report(out, "damage: every row dirty", timer.read(), iters);
    }
    {
        var timer = try Timer.start();
        for (0..iters) |i| {
            grid[(i % term.rows) * term.cols].char = @intCast('a' + i % 26);
            try fr.build(&fonts, grid, term.rows, term.cols, term.cursor_row, term.cursor_col, view);
        }
        try report(out, "damage: 1 dirty row", timer.read(), iters);
        var uploaded: usize = 0;
        for (fr.damage.items) |r| uploaded += r.end - r.start;
        try out.print("| ↳ instances to upload: {d} of {d} ({d} B of {d} B) | | |\n", .{ uploaded, fr.quads.items.len, uploaded * @sizeOf(text.Instance), fr.quads.items.len * @sizeOf(text.Instance) });
    }
    {
        var timer = try Timer.start();
        for (0..iters) |_| try fr.build(&fonts, grid, term.rows, term.cols, term.cursor_row, term.cursor_col, view);
        try report(out, "damage: nothing changed", timer.read(), iters);
    }
    {
        const inst = try alloc.alloc(text.Instance, text.MAX_INSTANCES);
        defer alloc.free(inst);
        var timer = try Timer.start();
        for (0..iters) |_| std.mem.doNotOptimizeAway(text.packQuads(inst, fr.quads.items));
        try report(out, "pack all instances", timer.read(), iters);
    }
    {
        const cell = fonts.cellSize();
        var soft = try software.SoftwareRenderer.init(alloc, term.cols, term.rows, .{ .w = cell.w, .h = cell.h });
        defer soft.deinit();
        var timer = try Timer.start();
        for (0..iters / 4) |_| soft.render(&fr, &fonts.atlas);
        try report(out, "software raster, full", timer.read(), iters / 4);
        timer.reset();
        for (0..iters) |i| {
            grid[(i % term.rows) * term.cols].char = @intCast('a' + i % 26);
            try fr.build(&fonts, grid, term.rows, term.cols, term.cursor_row, term.cursor_col, view);
            soft.renderDamage(&fr, &fonts.atlas);
        }
        try report(out, "software raster, 1 dirty row (incl. build)", timer.read(), iters);
    }

    // ---- streaming: parse a chunk, then build the frame (what the GUI
    // loop does per batch while `yes` runs)
    try out.print("\n## Streaming (`yes`, parse 1 MiB batch + damage frame)\n\n| step | per batch | MiB/s |\n|---|---:|---:|\n", .{});
    {
        const data = try makeYes(alloc, 1024 * 1024);
        defer alloc.free(data);
        const batches: usize = 32;
        var timer = try Timer.start();
        for (0..batches) |_| {
            try term.processOutput(data);
            for (0..term.rows) |r| @memcpy(grid[r * term.cols ..][0..term.cols], term.screenRow(@intCast(r)));
            try fr.build(&fonts, grid, term.rows, term.cols, term.cursor_row, term.cursor_col, view);
        }
        const ns = timer.read();
        const per = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(batches));
        try out.print("| 1 MiB of y\\r\\n + frame | {d:.2} ms | {d:.1} |\n", .{ per / 1e6, 1.0 / (per / 1e9) });
    }

    // ---- reflow
    try out.print("\n## Reflow on resize (10k lines of scrollback)\n\n| step | time |\n|---|---:|\n", .{});
    {
        var t2 = try terminal.Terminal.initBuffer(alloc, 50, 120, 10_000);
        defer t2.deinit();
        const data = try makeAscii(alloc, 2 * 1024 * 1024);
        defer alloc.free(data);
        try t2.processOutput(data);
        var timer = try Timer.start();
        try t2.resize(50, 80);
        const a = timer.lap();
        try t2.resize(50, 120);
        const b = timer.read();
        try out.print("| 120 → 80 cols | {d:.1} ms |\n| 80 → 120 cols | {d:.1} ms |\n", .{ ms(a), ms(b) });
    }
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

fn report(out: anytype, name: []const u8, ns: u64, iters: usize) !void {
    const per = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(iters));
    try out.print("| {s} | {d:.3} ms | {d:.0} |\n", .{ name, per / 1e6, 1e9 / per });
}
