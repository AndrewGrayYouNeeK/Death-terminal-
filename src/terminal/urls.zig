//! URL detection for Ctrl+click, plus the scheme allowlist used before
//! anything (detected URL or OSC 8 target) is handed to the opener.

const std = @import("std");
const terminal = @import("terminal.zig");
const Cell = terminal.Cell;
const selection = @import("selection.zig");
const Point = selection.Point;

pub const schemes = [_][]const u8{ "https://", "http://", "ftp://", "file://", "mailto:" };

/// Only these schemes are ever opened.
pub fn allowedTarget(uri: []const u8) bool {
    if (uri.len == 0 or uri.len > 4096) return false;
    for (uri) |b| if (b < 0x21 or b == 0x7F) return false;
    for (schemes) |s| {
        if (uri.len > s.len and std.ascii.startsWithIgnoreCase(uri, s)) return true;
    }
    return false;
}

fn urlByte(b: u8) bool {
    if (std.ascii.isAlphanumeric(b)) return true;
    return std.mem.indexOfScalar(u8, "-._~:/?#[]@!$&'()*+,;=%", b) != null;
}

pub const Found = struct {
    url: []u8,
    start: Point,
    end: Point,
};

/// Find a URL covering (line, col). Follows soft wraps. Caller frees `url`.
pub fn urlAt(allocator: std.mem.Allocator, lines: anytype, at: Point) !?Found {
    // Logical line bounds.
    var first = at.line;
    while (wraps(lines, first - 1)) first -= 1;
    var last = at.line;
    while (wraps(lines, last) and lines.lineAt(last + 1) != null) last += 1;

    var text = std.ArrayList(u8).init(allocator);
    defer text.deinit();
    var map = std.ArrayList(Point).init(allocator);
    defer map.deinit();
    var line = first;
    while (line <= last) : (line += 1) {
        const cells = lines.lineAt(line) orelse break;
        for (cells, 0..) |cell, col| {
            if (cell.isSpacer()) continue;
            const before = text.items.len;
            if (cell.char < 0x80) {
                try text.append(if (cell.char == 0) ' ' else @intCast(cell.char));
            } else {
                // Non-ASCII ends a URL; keep one byte per cell for mapping.
                try text.append(' ');
            }
            for (text.items[before..]) |_| try map.append(.{ .line = line, .col = @intCast(col) });
        }
    }
    // Byte index of the clicked cell.
    var click: ?usize = null;
    for (map.items, 0..) |p, i| {
        if (p.line == at.line and (p.col == at.col or (p.col + 1 == at.col and isWideAt(lines, p)))) {
            click = i;
            break;
        }
    }
    const ci = click orelse return null;

    var search_from: usize = 0;
    while (search_from < text.items.len) {
        var best: ?usize = null;
        for (schemes) |s| {
            if (indexOfIgnoreCase(text.items, search_from, s)) |i| {
                if (best == null or i < best.?) best = i;
            }
        }
        const s0 = best orelse return null;
        var e = s0;
        while (e < text.items.len and urlByte(text.items[e])) e += 1;
        e = trimEnd(text.items[s0..e]) + s0;
        if (ci >= s0 and ci < e) {
            const url = try allocator.dupe(u8, text.items[s0..e]);
            return .{ .url = url, .start = map.items[s0], .end = map.items[e - 1] };
        }
        search_from = @max(e, s0 + 1);
    }
    return null;
}

fn isWideAt(lines: anytype, p: Point) bool {
    const cells = lines.lineAt(p.line) orelse return false;
    return p.col < cells.len and cells[p.col].width == 2;
}

fn wraps(lines: anytype, line: i64) bool {
    const cells = lines.lineAt(line) orelse return false;
    return cells.len > 0 and cells[cells.len - 1].soft_wrap;
}

fn indexOfIgnoreCase(hay: []const u8, from: usize, needle: []const u8) ?usize {
    if (needle.len > hay.len) return null;
    var i = from;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return i;
    }
    return null;
}

/// Length after dropping trailing punctuation and unbalanced closers.
fn trimEnd(url: []const u8) usize {
    var n = url.len;
    while (n > 0) {
        const b = url[n - 1];
        if (std.mem.indexOfScalar(u8, ".,;:!?'\"", b) != null) {
            n -= 1;
            continue;
        }
        if (b == ')' or b == ']') {
            const open: u8 = if (b == ')') '(' else '[';
            const opens = std.mem.count(u8, url[0..n], &.{open});
            const closes = std.mem.count(u8, url[0..n], &.{b});
            if (closes > opens) {
                n -= 1;
                continue;
            }
        }
        break;
    }
    return n;
}

const testing = std.testing;

test "url detection trims punctuation and balances parens" {
    const rows = try selection.testRows(testing.allocator, &.{"see (https://en.wikipedia.org/wiki/Zig_(language)), ok"}, 64);
    defer selection.freeTestRows(testing.allocator, rows);
    const lines = selection.TestLines{ .rows = rows };
    const f = (try urlAt(testing.allocator, lines, .{ .line = 0, .col = 20 })).?;
    defer testing.allocator.free(f.url);
    try testing.expectEqualStrings("https://en.wikipedia.org/wiki/Zig_(language)", f.url);
    try testing.expectEqual(@as(u16, 5), f.start.col);
    try testing.expect((try urlAt(testing.allocator, lines, .{ .line = 0, .col = 1 })) == null);
}

test "url detection across a soft wrap" {
    const rows = try selection.testRows(testing.allocator, &.{ "go http://exa\\", "mple.com/a." }, 13);
    defer selection.freeTestRows(testing.allocator, rows);
    const f = (try urlAt(testing.allocator, selection.TestLines{ .rows = rows }, .{ .line = 1, .col = 3 })).?;
    defer testing.allocator.free(f.url);
    try testing.expectEqualStrings("http://example.com/a", f.url);
    try testing.expectEqual(@as(i64, 0), f.start.line);
    try testing.expectEqual(@as(i64, 1), f.end.line);
}

test "only allowlisted schemes open" {
    try testing.expect(allowedTarget("https://ziglang.org"));
    try testing.expect(allowedTarget("mailto:a@b.c"));
    try testing.expect(allowedTarget("file:///tmp/x"));
    try testing.expect(!allowedTarget("javascript:alert(1)"));
    try testing.expect(!allowedTarget("-n https://x"));
    try testing.expect(!allowedTarget("https://a b"));
    try testing.expect(!allowedTarget("https://"));
}
