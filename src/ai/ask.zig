//! "Ask the Output": pick a region (selection, last OSC 133 command, or
//! the visible screen), redact it, and turn an answer's line references
//! into search highlights.
//!
//! Long regions are split into chunks of `max_lines`. The request sends
//! the tail (the last chunk, filled backward so a short final chunk still
//! carries up to `max_lines` lines) and says which lines were omitted.

const std = @import("std");
const terminal = @import("../terminal/terminal.zig");
const selection = @import("../terminal/selection.zig");
const search = @import("../terminal/search.zig");
const unicode = @import("../terminal/unicode.zig");
const openai = @import("openai.zig");
const redact = @import("redact.zig");

const Cell = terminal.Cell;
const Terminal = terminal.Terminal;

/// Hard cap on the output block inside one request, on top of `max_lines`.
pub const max_prompt_bytes: usize = 24 * 1024;

pub const Source = enum {
    selection,
    last_command,
    screen,

    pub fn label(self: Source) []const u8 {
        return switch (self) {
            .selection => "selection",
            .last_command => "last output",
            .screen => "screen",
        };
    }
};

/// One row of a region. `number` is 1-based in the full region (before the
/// tail window). `abs` < 0 means the row is text only (the grid line is gone).
pub const LineRec = struct {
    abs: i64,
    number: u32,
    col0: u16,
    text: []u8,
};

pub const Region = struct {
    source: Source,
    command: []u8,
    lines: []LineRec,
    /// Collected rows dropped from the front to keep the tail.
    omitted_before: usize = 0,
    /// Rows in the original span that had already left the scrollback.
    scrolled_out: usize = 0,
    /// A kept line is longer than `max_bytes` and was clipped in the prompt.
    clipped: bool = false,
    max_lines: usize = 200,
    max_bytes: usize = max_prompt_bytes,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Region) void {
        for (self.lines) |l| self.allocator.free(l.text);
        self.allocator.free(self.lines);
        self.allocator.free(self.command);
    }
};

pub const Ref = struct {
    /// 1-based line number in the region (`LineRec.number`).
    line: u32,
    /// Empty = the whole line. Owned by `Parsed` (or a static "").
    substring: []const u8,
};

pub const Parsed = struct {
    answer: []u8,
    refs: []Ref,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Parsed) void {
        self.allocator.free(self.answer);
        for (self.refs) |r| if (r.substring.len > 0) self.allocator.free(r.substring);
        self.allocator.free(self.refs);
    }
};

pub const ChunkBound = struct { start: usize, end: usize };

pub const ExtractOpts = struct {
    selection: ?selection.Selection = null,
    word_chars: []const u8 = selection.default_word_chars,
    view_top: i64 = 0,
    view_rows: u16 = 0,
    max_lines: usize = 200,
    max_bytes: usize = max_prompt_bytes,
};

const ask_system =
    \\You answer a question about terminal output. Reply in at most 4 short lines, no markdown headings.
    \\Then a line exactly "REFS:" and one reference per following line, using the line numbers from the output:
    \\L<number>
    \\L<number>:<exact substring copied from that line>
    \\Cite only lines that were shown. If the output does not contain the answer, say so and leave no references under REFS:.
;

/// How many chunks of `size` cover `total` lines. The last chunk is shorter
/// when `total` is not a multiple of `size`.
pub fn chunkCount(total: usize, size: usize) usize {
    if (total == 0 or size == 0) return 0;
    return (total + size - 1) / size;
}

/// Non-overlapping chunks of at most `size` lines. `out` limits how many
/// are written; the return value is the slice that was filled.
pub fn chunkBounds(total: usize, size: usize, out: []ChunkBound) []ChunkBound {
    if (size == 0 or total == 0 or out.len == 0) return out[0..0];
    var i: usize = 0;
    var n: usize = 0;
    while (i < total and n < out.len) {
        const end = @min(total, i + size);
        out[n] = .{ .start = i, .end = end };
        n += 1;
        i = end;
    }
    return out[0..n];
}

/// Selection, else the last command's output (OSC 133), else the visible screen.
pub fn classify(term: *const Terminal, sel: ?selection.Selection) Source {
    if (sel) |s| {
        if (s.active) return .selection;
    }
    if (term.shell.phase == .running and term.validMark(term.shell.output_start) != null) return .last_command;
    if (term.shell.lastCommand() != null) return .last_command;
    return .screen;
}

pub fn extract(allocator: std.mem.Allocator, term: *const Terminal, opts: ExtractOpts) !Region {
    if (opts.selection) |sel| {
        if (sel.active) {
            return finish(allocator, term, opts, .selection, "", try collectSelection(allocator, term, sel, opts.word_chars), 0);
        }
    }
    if (try collectLast(allocator, term)) |got| {
        return finish(allocator, term, opts, .last_command, got.command, got.lines, got.scrolled_out);
    }
    const rows: u16 = if (opts.view_rows == 0) term.rows else opts.view_rows;
    return finish(allocator, term, opts, .screen, "", try collectScreen(allocator, term, opts.view_top, rows), 0);
}

const Collected = struct {
    command: []const u8,
    lines: std.ArrayList(LineRec),
    scrolled_out: usize = 0,
};

fn finish(
    allocator: std.mem.Allocator,
    term: *const Terminal,
    opts: ExtractOpts,
    source: Source,
    command: []const u8,
    lines_in: std.ArrayList(LineRec),
    scrolled_out: usize,
) !Region {
    _ = term;
    var lines = lines_in;
    errdefer {
        for (lines.items) |l| allocator.free(l.text);
        lines.deinit();
    }
    const window = trimTail(allocator, &lines, opts.max_lines, opts.max_bytes);
    const owned_cmd = try allocator.dupe(u8, command);
    errdefer allocator.free(owned_cmd);
    const kept = try lines.toOwnedSlice();
    return .{
        .source = source,
        .command = owned_cmd,
        .lines = kept,
        .omitted_before = window.omitted,
        .scrolled_out = scrolled_out,
        .clipped = window.clipped,
        .max_lines = opts.max_lines,
        .max_bytes = opts.max_bytes,
        .allocator = allocator,
    };
}

const Window = struct { omitted: usize, clipped: bool };

/// Keep the tail: the last `max_lines` rows, then drop whole rows from the
/// front until the block fits in `max_bytes`. One over-long row stays and
/// is marked clipped.
fn trimTail(allocator: std.mem.Allocator, lines: *std.ArrayList(LineRec), max_lines: usize, max_bytes: usize) Window {
    var start: usize = 0;
    if (max_lines == 0) start = lines.items.len else if (lines.items.len > max_lines) start = lines.items.len - max_lines;
    while (start < lines.items.len and bytesOf(lines.items[start..]) > max_bytes and start + 1 < lines.items.len) start += 1;
    const clipped = start < lines.items.len and bytesOf(lines.items[start..]) > max_bytes;
    for (lines.items[0..start]) |l| allocator.free(l.text);
    if (start > 0) {
        std.mem.copyForwards(LineRec, lines.items[0 .. lines.items.len - start], lines.items[start..]);
        lines.shrinkRetainingCapacity(lines.items.len - start);
    }
    return .{ .omitted = start, .clipped = clipped };
}

fn bytesOf(lines: []const LineRec) usize {
    var n: usize = 0;
    for (lines) |l| n += l.text.len + 8;
    return n;
}

fn collectSelection(allocator: std.mem.Allocator, term: *const Terminal, sel: selection.Selection, word_chars: []const u8) !std.ArrayList(LineRec) {
    var list = std.ArrayList(LineRec).init(allocator);
    errdefer freeList(&list);
    const range = sel.resolve(term, word_chars);
    var number: u32 = 1;
    var line = range.start.line;
    while (line <= range.end.line) : (line += 1) {
        const num = number;
        number += 1;
        const cells = term.lineAt(line) orelse continue;
        const b = lineBounds(sel, range, line, cells.len);
        try list.append(try rowFromCells(allocator, line, num, cells, b.c0, b.c1));
    }
    trimEmptyEnds(allocator, &list, true);
    return list;
}

fn collectScreen(allocator: std.mem.Allocator, term: *const Terminal, view_top: i64, rows: u16) !std.ArrayList(LineRec) {
    var list = std.ArrayList(LineRec).init(allocator);
    errdefer freeList(&list);
    var r: u16 = 0;
    while (r < rows) : (r += 1) {
        const abs = view_top + r;
        const cells = term.lineAt(abs) orelse continue;
        const end: usize = if (cells.len == 0) 0 else cells.len - 1;
        try list.append(try rowFromCells(allocator, abs, r + 1, cells, 0, end));
    }
    trimEmptyEnds(allocator, &list, true);
    return list;
}

fn collectLast(allocator: std.mem.Allocator, term: *const Terminal) !?Collected {
    if (term.shell.phase == .running) {
        if (term.validMark(term.shell.output_start)) |start| {
            if (term.outputSpan(start)) |span| {
                var list = try collectSpan(allocator, term, span);
                errdefer freeList(&list.lines);
                dropTrailingEmpty(allocator, &list.lines);
                const cmd = term.shell.pending orelse "";
                return .{ .command = cmd, .lines = list.lines, .scrolled_out = list.scrolled_out };
            }
        }
    }
    const last = term.shell.lastCommand() orelse return null;
    if (last.span) |span| {
        if (span.gen == term.layout_gen) {
            var list = try collectSpan(allocator, term, span);
            errdefer freeList(&list.lines);
            dropTrailingEmpty(allocator, &list.lines);
            if (list.lines.items.len > 0) return .{ .command = last.text, .lines = list.lines, .scrolled_out = list.scrolled_out };
            freeList(&list.lines);
        }
    }
    if (last.output.len > 0) {
        const list = try linesFromStored(allocator, last.output);
        return .{ .command = last.text, .lines = list, .scrolled_out = 0 };
    }
    const empty = std.ArrayList(LineRec).init(allocator);
    return .{ .command = last.text, .lines = empty, .scrolled_out = 0 };
}

const SpanLines = struct { lines: std.ArrayList(LineRec), scrolled_out: usize };

fn collectSpan(allocator: std.mem.Allocator, term: *const Terminal, span: terminal.shell_integration.OutputSpan) !SpanLines {
    var list = std.ArrayList(LineRec).init(allocator);
    errdefer freeList(&list);
    var missing: usize = 0;
    var number: u32 = 1;
    var line = span.start;
    while (line <= span.end) : (line += 1) {
        const num = number;
        number += 1;
        const cells = term.lineAt(line) orelse {
            missing += 1;
            continue;
        };
        const c0: usize = if (line == span.start) span.col else 0;
        const end: usize = if (cells.len == 0) 0 else cells.len - 1;
        try list.append(try rowFromCells(allocator, line, num, cells, c0, end));
    }
    return .{ .lines = list, .scrolled_out = missing };
}

fn linesFromStored(allocator: std.mem.Allocator, text: []const u8) !std.ArrayList(LineRec) {
    var list = std.ArrayList(LineRec).init(allocator);
    errdefer freeList(&list);
    var it = std.mem.splitScalar(u8, text, '\n');
    var number: u32 = 1;
    while (it.next()) |raw| {
        const trimmed = std.mem.trimRight(u8, raw, " \t\r");
        const owned = try allocator.dupe(u8, trimmed);
        try list.append(.{ .abs = -1, .number = number, .col0 = 0, .text = owned });
        number += 1;
    }
    dropTrailingEmpty(allocator, &list);
    return list;
}

fn dropTrailingEmpty(allocator: std.mem.Allocator, list: *std.ArrayList(LineRec)) void {
    while (list.items.len > 0 and list.items[list.items.len - 1].text.len == 0) {
        allocator.free(list.items[list.items.len - 1].text);
        _ = list.pop();
    }
}

fn trimEmptyEnds(allocator: std.mem.Allocator, list: *std.ArrayList(LineRec), renumber: bool) void {
    while (list.items.len > 0 and list.items[0].text.len == 0) {
        allocator.free(list.items[0].text);
        _ = list.orderedRemove(0);
    }
    dropTrailingEmpty(allocator, list);
    if (renumber) {
        for (list.items, 0..) |*l, i| l.number = @intCast(i + 1);
    }
}

fn freeList(list: *std.ArrayList(LineRec)) void {
    for (list.items) |l| list.allocator.free(l.text);
    list.deinit();
}

const Bounds = struct { c0: usize, c1: usize };

fn lineBounds(sel: selection.Selection, range: selection.Selection.Range, line: i64, cells_len: usize) Bounds {
    if (cells_len == 0) return .{ .c0 = 0, .c1 = 0 };
    const last = cells_len - 1;
    if (sel.mode == .block) {
        const c0 = @min(@as(usize, range.start.col), last);
        const c1 = @min(@as(usize, range.end.col), last);
        return .{ .c0 = @min(c0, c1), .c1 = @max(c0, c1) };
    }
    var c0: usize = 0;
    var c1: usize = last;
    if (line == range.start.line) c0 = @min(@as(usize, range.start.col), last);
    if (line == range.end.line) c1 = @min(@as(usize, range.end.col), last);
    if (c1 < c0) c1 = c0;
    return .{ .c0 = c0, .c1 = c1 };
}

fn rowFromCells(allocator: std.mem.Allocator, abs: i64, number: u32, cells: []const Cell, c0: usize, c1: usize) !LineRec {
    var text = std.ArrayList(u8).init(allocator);
    errdefer text.deinit();
    var col0: u16 = @intCast(@min(c0, std.math.maxInt(u16)));
    var seen = false;
    if (cells.len > 0 and c0 <= c1) {
        const end = @min(c1, cells.len - 1);
        var col: usize = @min(c0, cells.len);
        while (col <= end and col < cells.len) {
            const cell = cells[col];
            if (cell.isSpacer()) {
                col += 1;
                continue;
            }
            if (!seen) {
                col0 = @intCast(@min(col, std.math.maxInt(u16)));
                seen = true;
            }
            try cell.writeUtf8(text.writer());
            col += 1;
        }
    }
    while (text.items.len > 0 and text.items[text.items.len - 1] == ' ') text.items.len -= 1;
    return .{ .abs = abs, .number = number, .col0 = col0, .text = try text.toOwnedSlice() };
}

/// Empty when the whole region fits. Otherwise describes the tail that was sent.
pub fn formatNote(buf: []u8, region: *const Region) []const u8 {
    if (region.lines.len == 0) return "No output in this region.";
    const total = region.scrolled_out + region.omitted_before + region.lines.len;
    const earlier = total - region.lines.len;
    if (earlier == 0 and !region.clipped) return "";
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    const first = region.lines[0].number;
    const last = region.lines[region.lines.len - 1].number;
    if (earlier > 0) {
        const chunks = chunkCount(total, if (region.max_lines == 0) total else region.max_lines);
        w.print("Showing lines {d}-{d} of {d} (output chunked into {d} chunks of up to {d} lines; {d} earlier lines omitted).", .{
            first, last, total, chunks, region.max_lines, earlier,
        }) catch return buf[0..fbs.getWritten().len];
    }
    if (region.clipped) {
        w.writeAll(if (earlier > 0) " A long line was truncated." else "A long line was truncated.") catch {};
    }
    return fbs.getWritten();
}

pub fn messages(arena: std.mem.Allocator, question: []const u8, region: *const Region) ![]openai.Message {
    var note_buf: [320]u8 = undefined;
    const note = formatNote(&note_buf, region);
    var user = std.ArrayList(u8).init(arena);
    const w = user.writer();
    try w.print("Source: {s}\n", .{region.source.label()});
    if (region.command.len > 0) {
        const cmd = try redact.redact(arena, region.command);
        const shown = cmd[0..@min(cmd.len, 200)];
        try w.print("Command: {s}\n", .{shown});
    }
    if (note.len > 0) try w.print("Note: {s}\n", .{note});
    try w.writeAll("Output:\n");
    if (region.lines.len == 0) {
        try w.writeAll("(none)\n");
    } else {
        for (region.lines) |l| {
            const red = try redact.redact(arena, l.text);
            try w.print("L{d}|", .{l.number});
            try writeCapped(w, red, region.max_bytes);
            try w.writeByte('\n');
        }
    }
    const q = try redact.redact(arena, std.mem.trim(u8, question, " \t\r\n"));
    try w.print("Question: {s}\n", .{q});
    const msgs = try arena.alloc(openai.Message, 2);
    msgs[0] = .{ .role = "system", .content = ask_system };
    msgs[1] = .{ .role = "user", .content = user.items };
    return msgs;
}

fn writeCapped(w: anytype, text: []const u8, cap: usize) !void {
    if (cap == 0 or text.len <= cap) {
        try w.writeAll(text);
        return;
    }
    var n: usize = cap;
    while (n > 0 and (text[n] & 0xC0) == 0x80) n -= 1;
    try w.writeAll(text[0..n]);
    try w.writeAll(" ...[truncated]");
}

pub fn parseReply(allocator: std.mem.Allocator, reply: []const u8) !Parsed {
    var answer = std.ArrayList(u8).init(allocator);
    errdefer answer.deinit();
    var refs = std.ArrayList(Ref).init(allocator);
    errdefer {
        for (refs.items) |r| if (r.substring.len > 0) allocator.free(r.substring);
        refs.deinit();
    }
    var seen = false;
    var it = std.mem.splitScalar(u8, reply, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!seen and isRefsHeader(line)) {
            seen = true;
            continue;
        }
        if (!seen) {
            if (answer.items.len > 0) try answer.append('\n');
            try answer.appendSlice(std.mem.trimRight(u8, raw, " \t\r"));
            continue;
        }
        try parseRefLine(allocator, line, &refs);
    }
    if (!seen) try scanInline(allocator, answer.items, &refs);
    while (answer.items.len > 0 and answer.items[answer.items.len - 1] == '\n') _ = answer.pop();
    return .{
        .answer = try answer.toOwnedSlice(),
        .refs = try refs.toOwnedSlice(),
        .allocator = allocator,
    };
}

fn isRefsHeader(line: []const u8) bool {
    var s = std.mem.trim(u8, line, " \t");
    if (s.len >= 2 and s[0] == '`' and s[s.len - 1] == '`') s = s[1 .. s.len - 1];
    return std.ascii.eqlIgnoreCase(s, "REFS:") or std.ascii.eqlIgnoreCase(s, "REFS");
}

fn parseRefLine(allocator: std.mem.Allocator, line_in: []const u8, refs: *std.ArrayList(Ref)) !void {
    var s = std.mem.trim(u8, line_in, " \t");
    if (s.len == 0) return;
    if (std.mem.startsWith(u8, s, "- ") or std.mem.startsWith(u8, s, "* ")) s = s[2..];
    if (std.mem.startsWith(u8, s, "• ")) s = s["• ".len..];
    s = std.mem.trim(u8, s, " \t");
    if (s.len >= 2 and s[0] == '`' and s[s.len - 1] == '`') s = std.mem.trim(u8, s[1 .. s.len - 1], " \t");
    if (std.ascii.startsWithIgnoreCase(s, "lines ")) s = s["lines ".len..] else if (std.ascii.startsWithIgnoreCase(s, "line ")) s = s["line ".len..];
    s = std.mem.trim(u8, s, " \t");
    if (s.len > 0 and (s[0] == 'L' or s[0] == 'l')) s = s[1..];
    const n1 = leadingInt(s) orelse return;
    s = s[n1.len..];
    if (s.len > 0 and s[0] == '-') {
        s = s[1..];
        if (s.len > 0 and (s[0] == 'L' or s[0] == 'l')) s = s[1..];
        const n2 = leadingInt(s) orelse return;
        try addRange(allocator, refs, n1.value, n2.value);
        return;
    }
    var sub: []const u8 = "";
    if (s.len > 0 and (s[0] == ':' or s[0] == '|')) {
        sub = std.mem.trim(u8, s[1..], " \t");
        if (sub.len >= 2) {
            const q = sub[0];
            if ((q == '"' or q == '\'' or q == '`') and sub[sub.len - 1] == q) sub = sub[1 .. sub.len - 1];
        }
        sub = trimPunct(sub);
        if (sub.len > 200) sub = sub[0..200];
    }
    try pushRef(allocator, refs, n1.value, sub);
}

const Lead = struct { len: usize, value: u32 };

fn leadingInt(s: []const u8) ?Lead {
    var i: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    if (i == 0) return null;
    const v = std.fmt.parseInt(u32, s[0..i], 10) catch return null;
    if (v == 0) return null;
    return .{ .len = i, .value = v };
}

fn addRange(allocator: std.mem.Allocator, refs: *std.ArrayList(Ref), from: u32, to: u32) !void {
    var a = from;
    var b = to;
    if (b < a) std.mem.swap(u32, &a, &b);
    if (b - a > 40) b = a + 40;
    var n = a;
    while (n <= b) : (n += 1) try pushRef(allocator, refs, n, "");
}

fn pushRef(allocator: std.mem.Allocator, refs: *std.ArrayList(Ref), line: u32, sub: []const u8) !void {
    if (line == 0) return;
    for (refs.items) |r| if (r.line == line and std.mem.eql(u8, r.substring, sub)) return;
    const owned = if (sub.len == 0) "" else try allocator.dupe(u8, sub);
    errdefer if (owned.len > 0) allocator.free(owned);
    try refs.append(.{ .line = line, .substring = owned });
}

fn scanInline(allocator: std.mem.Allocator, text: []const u8, refs: *std.ArrayList(Ref)) !void {
    var i: usize = 0;
    while (i < text.len) {
        if ((text[i] == 'L' or text[i] == 'l') and (i == 0 or !std.ascii.isAlphanumeric(text[i - 1]))) {
            const lead = leadingInt(text[i + 1 ..]);
            if (lead) |n| {
                var next = i + 1 + n.len;
                var sub: []const u8 = "";
                if (next < text.len and text[next] == ':') {
                    var k = next + 1;
                    while (k < text.len and text[k] != ' ' and text[k] != '\n' and text[k] != '\t') k += 1;
                    sub = trimPunct(text[next + 1 .. k]);
                    if (sub.len > 200) sub = sub[0..200];
                    next = k;
                }
                try pushRef(allocator, refs, n.value, sub);
                i = next;
                continue;
            }
        }
        i += 1;
    }
}

fn trimPunct(s: []const u8) []const u8 {
    var e = s.len;
    while (e > 0) {
        const c = s[e - 1];
        if (c == '.' or c == ',' or c == ';' or c == ')' or c == ']' or c == ':') {
            e -= 1;
            continue;
        }
        break;
    }
    return if (e == 0) s else s[0..e];
}

pub fn mapHighlights(allocator: std.mem.Allocator, lines: []const LineRec, refs: []const Ref) ![]search.Match {
    var out = std.ArrayList(search.Match).init(allocator);
    errdefer out.deinit();
    for (refs) |r| {
        const line = findLine(lines, r.line) orelse continue;
        if (line.abs < 0) continue;
        const m = matchFor(line, r.substring);
        var dup = false;
        for (out.items) |e| if (std.meta.eql(e, m)) {
            dup = true;
            break;
        };
        if (!dup) try out.append(m);
    }
    return out.toOwnedSlice();
}

fn findLine(lines: []const LineRec, number: u32) ?LineRec {
    for (lines) |l| if (l.number == number) return l;
    return null;
}

fn matchFor(line: LineRec, substring: []const u8) search.Match {
    const whole = wholeMatch(line);
    if (substring.len == 0) return whole;
    const at = std.mem.indexOf(u8, line.text, substring) orelse return whole;
    const start = satAdd(line.col0, columnsUntil(line.text, at));
    const end_w = columnsUntil(line.text, at + substring.len);
    const end = if (end_w == 0) start else satAdd(line.col0, end_w - 1);
    return search.Match.single(line.abs, start, end);
}

fn wholeMatch(line: LineRec) search.Match {
    const w = columnsUntil(line.text, line.text.len);
    const end = if (w == 0) line.col0 else satAdd(line.col0, w - 1);
    return search.Match.single(line.abs, line.col0, end);
}

fn satAdd(a: u16, b: u16) u16 {
    const sum = @as(u32, a) + b;
    return if (sum > std.math.maxInt(u16)) std.math.maxInt(u16) else @intCast(sum);
}

fn columnsUntil(text: []const u8, byte_end: usize) u16 {
    var col: u16 = 0;
    var i: usize = 0;
    const end = @min(byte_end, text.len);
    while (i < end) {
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        if (i + n > text.len) {
            col = satAdd(col, 1);
            break;
        }
        const cp = std.unicode.utf8Decode(text[i..][0..n]) catch {
            col = satAdd(col, 1);
            i += 1;
            continue;
        };
        col = satAdd(col, unicode.width(cp));
        i += n;
    }
    return col;
}

// ------------------------------------------------------------------ tests

const t = std.testing;

test "chunkBounds splits a region into max_lines chunks" {
    var buf: [8]ChunkBound = undefined;
    const c = chunkBounds(5, 2, &buf);
    try t.expectEqual(@as(usize, 3), c.len);
    try t.expectEqual(ChunkBound{ .start = 0, .end = 2 }, c[0]);
    try t.expectEqual(ChunkBound{ .start = 2, .end = 4 }, c[1]);
    try t.expectEqual(ChunkBound{ .start = 4, .end = 5 }, c[2]);
    try t.expectEqual(@as(usize, 3), chunkCount(5, 2));
    try t.expectEqual(@as(usize, 1), chunkCount(2, 10));
    try t.expectEqual(@as(usize, 0), chunkBounds(0, 2, &buf).len);
    try t.expectEqual(@as(usize, 0), chunkCount(4, 0));
}

test "extract: last command output, selection, then the screen" {
    var term = try Terminal.initBuffer(t.allocator, 12, 40, 32);
    defer term.deinit();
    try term.processOutput("\x1b]133;A\x07$ \x1b]133;B\x07ls\r\n\x1b]133;C\x07a.txt\r\nreadme\r\n\x1b]133;D;0\x07\x1b]133;A\x07$ \x1b]133;B\x07");

    var region = try extract(t.allocator, &term, .{ .view_top = term.screenTop(), .view_rows = term.rows });
    defer region.deinit();
    try t.expectEqual(Source.last_command, region.source);
    try t.expectEqualStrings("ls", region.command);
    try t.expectEqual(@as(usize, 2), region.lines.len);
    try t.expectEqualStrings("a.txt", region.lines[0].text);
    try t.expectEqualStrings("readme", region.lines[1].text);
    try t.expectEqual(@as(u32, 1), region.lines[0].number);
    try t.expect(region.lines[0].abs >= 0);
    var note_buf: [8]u8 = undefined;
    try t.expectEqual(@as(usize, 0), formatNote(&note_buf, &region).len);

    var sel = selection.Selection.begin(.{ .line = region.lines[1].abs, .col = 0 }, .normal);
    sel.update(.{ .line = region.lines[1].abs, .col = 3 });
    var picked = try extract(t.allocator, &term, .{ .selection = sel, .view_top = term.screenTop(), .view_rows = term.rows });
    defer picked.deinit();
    try t.expectEqual(Source.selection, picked.source);
    try t.expectEqual(@as(usize, 1), picked.lines.len);
    try t.expectEqualStrings("read", picked.lines[0].text);

    var bare = try Terminal.initBuffer(t.allocator, 6, 40, 8);
    defer bare.deinit();
    try bare.processOutput("hello screen\r\n");
    var screen = try extract(t.allocator, &bare, .{ .view_top = bare.screenTop(), .view_rows = bare.rows });
    defer screen.deinit();
    try t.expectEqual(Source.screen, screen.source);
    try t.expectEqualStrings("hello screen", screen.lines[0].text);
}

test "extract: a running command's output is the region" {
    var term = try Terminal.initBuffer(t.allocator, 8, 30, 8);
    defer term.deinit();
    try term.processOutput("\x1b]133;A\x07$ \x1b]133;B\x07make\r\n\x1b]133;C\x07cc main.c\r\n");
    var region = try extract(t.allocator, &term, .{});
    defer region.deinit();
    try t.expectEqual(Source.last_command, region.source);
    try t.expectEqualStrings("make", region.command);
    try t.expectEqualStrings("cc main.c", region.lines[0].text);
}

test "extract: long output is chunked to the tail with a note" {
    var term = try Terminal.initBuffer(t.allocator, 16, 20, 16);
    defer term.deinit();
    try term.processOutput("\x1b]133;A\x07$ \x1b]133;B\x07cmd\r\n\x1b]133;C\x07l1\r\nl2\r\nl3\r\nl4\r\nl5\r\n\x1b]133;D;0\x07");
    var region = try extract(t.allocator, &term, .{ .max_lines = 2 });
    defer region.deinit();
    try t.expectEqual(@as(usize, 2), region.lines.len);
    try t.expectEqualStrings("l4", region.lines[0].text);
    try t.expectEqualStrings("l5", region.lines[1].text);
    try t.expectEqual(@as(u32, 4), region.lines[0].number);
    try t.expectEqual(@as(u32, 5), region.lines[1].number);
    try t.expect(region.omitted_before >= 3);
    var buf: [256]u8 = undefined;
    const note = formatNote(&buf, &region);
    try t.expect(std.mem.indexOf(u8, note, "chunked") != null);
    try t.expect(std.mem.indexOf(u8, note, "omitted") != null);
    try t.expect(std.mem.indexOf(u8, note, "4-5") != null);
}

test "messages redact secrets and include the chunk note" {
    var term = try Terminal.initBuffer(t.allocator, 8, 60, 8);
    defer term.deinit();
    try term.processOutput("\x1b]133;A\x07$ \x1b]133;B\x07tool\r\n\x1b]133;C\x07client_secret=xyz\r\nok\r\n\x1b]133;D;0\x07");
    var region = try extract(t.allocator, &term, .{ .max_lines = 1 });
    defer region.deinit();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const msgs = try messages(arena_state.allocator(), "where is client_secret=xyz?", &region);
    try t.expect(std.mem.indexOf(u8, msgs[1].content, "xyz") == null);
    try t.expect(std.mem.indexOf(u8, msgs[1].content, "[REDACTED]") != null);
    try t.expect(std.mem.indexOf(u8, msgs[1].content, "chunked") != null);
    try t.expect(std.mem.indexOf(u8, msgs[1].content, "Question:") != null);
    try t.expect(std.mem.indexOf(u8, msgs[0].content, "REFS:") != null);
}

test "messages clip one over-long line" {
    var term = try Terminal.initBuffer(t.allocator, 6, 120, 4);
    defer term.deinit();
    try term.processOutput("\x1b]133;A\x07$ \x1b]133;B\x07x\r\n\x1b]133;C\x07");
    try term.processOutput("a" ** 90);
    try term.processOutput("\r\n\x1b]133;D;0\x07");
    var region = try extract(t.allocator, &term, .{ .max_lines = 4, .max_bytes = 20 });
    defer region.deinit();
    try t.expect(region.clipped);
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const msgs = try messages(arena_state.allocator(), "what", &region);
    try t.expect(std.mem.indexOf(u8, msgs[1].content, "[truncated]") != null);
    var buf: [128]u8 = undefined;
    try t.expect(std.mem.indexOf(u8, formatNote(&buf, &region), "truncated") != null);
}

test "parseReply reads REFS lines, ranges, and inline fallback" {
    const reply =
        \\The empty file is a.txt
        \\REFS:
        \\L2
        \\L3:foo
        \\- L4: bar
        \\L5-L6
        \\lines 8-9
        \\nope
        \\`L10:zz`
    ;
    var parsed = try parseReply(t.allocator, reply);
    defer parsed.deinit();
    try t.expectEqualStrings("The empty file is a.txt", parsed.answer);
    const expect = [_]struct { u32, []const u8 }{
        .{ 2, "" }, .{ 3, "foo" }, .{ 4, "bar" }, .{ 5, "" }, .{ 6, "" },
        .{ 8, "" }, .{ 9, "" },    .{ 10, "zz" },
    };
    try t.expectEqual(expect.len, parsed.refs.len);
    for (expect, parsed.refs) |e, r| {
        try t.expectEqual(e[0], r.line);
        try t.expectEqualStrings(e[1], r.substring);
    }

    var inline_p = try parseReply(t.allocator, "See L3 and L4:error for the cause.");
    defer inline_p.deinit();
    try t.expectEqual(@as(usize, 2), inline_p.refs.len);
    try t.expectEqual(@as(u32, 3), inline_p.refs[0].line);
    try t.expectEqualStrings("", inline_p.refs[0].substring);
    try t.expectEqual(@as(u32, 4), inline_p.refs[1].line);
    try t.expectEqualStrings("error", inline_p.refs[1].substring);
}

test "mapHighlights maps line and substring refs onto search matches" {
    const lines = [_]LineRec{
        .{ .abs = 3, .number = 1, .col0 = 0, .text = @constCast("日x") },
        .{ .abs = 4, .number = 2, .col0 = 2, .text = @constCast("abcd") },
        .{ .abs = -1, .number = 3, .col0 = 0, .text = @constCast("gone") },
    };
    const refs = [_]Ref{
        .{ .line = 1, .substring = "x" },
        .{ .line = 2, .substring = "" },
        .{ .line = 2, .substring = "missing" },
        .{ .line = 3, .substring = "gone" },
        .{ .line = 9, .substring = "nope" },
    };
    const matches = try mapHighlights(t.allocator, &lines, &refs);
    defer t.allocator.free(matches);
    // "x" after a wide char; unknown line and abs < 0 are dropped.
    // Missing substring falls back to the whole line, which duplicates the empty-substring ref.
    try t.expectEqual(@as(usize, 2), matches.len);
    try t.expectEqual(search.Match.single(3, 2, 2), matches[0]);
    try t.expectEqual(search.Match.single(4, 2, 5), matches[1]);
}
