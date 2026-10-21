//! One-line command summaries for the Time Travel timeline.
//!
//! The text is a prompt for the existing AI engine (`Kind.summarize`).
//! Nothing here opens a socket. Commands and paths go through the same
//! redaction pass as other AI requests.

const std = @import("std");
const openai = @import("../ai/openai.zig");
const redact = @import("../ai/redact.zig");

pub const built = struct {
    messages: [2]openai.Message,
    pub fn deinit(self: *const built, a: std.mem.Allocator) void {
        a.free(self.messages[0].content);
        a.free(self.messages[1].content);
    }
};

pub fn build(
    a: std.mem.Allocator,
    command: []const u8,
    added: []const []const u8,
    removed: []const []const u8,
    modified: []const []const u8,
) !built {
    const sys = "Reply with one short line describing what this shell command changed in its working tree. No preamble, no quotes, no list.";
    var user = std.ArrayList(u8).init(a);
    errdefer user.deinit();
    try user.appendSlice("command: ");
    try appendFlat(&user, command);
    try user.appendSlice("\nadded: ");
    try appendNames(&user, added);
    try user.appendSlice("\nremoved: ");
    try appendNames(&user, removed);
    try user.appendSlice("\nmodified: ");
    try appendNames(&user, modified);
    const red = try redact.redact(a, user.items);
    user.deinit();
    errdefer a.free(red);
    const sys_owned = try a.dupe(u8, sys);
    return .{ .messages = .{
        .{ .role = "system", .content = sys_owned },
        .{ .role = "user", .content = red },
    } };
}

fn appendFlat(out: *std.ArrayList(u8), text: []const u8) !void {
    const n = @min(text.len, 240);
    for (text[0..n]) |c| {
        try out.append(if (c < 0x20 or c == 0x7f) ' ' else c);
    }
    if (text.len > n) try out.appendSlice("...");
}

fn appendNames(out: *std.ArrayList(u8), names: []const []const u8) !void {
    if (names.len == 0) {
        try out.appendSlice("(none)");
        return;
    }
    const n = @min(names.len, 12);
    for (names[0..n], 0..) |name, i| {
        if (i > 0) try out.appendSlice(", ");
        const cut = @min(name.len, 80);
        try out.appendSlice(name[0..cut]);
    }
    if (names.len > n) try out.writer().print(" (+{d} more)", .{names.len - n});
}

/// First line, trimmed, at most 160 bytes, on a UTF-8 boundary.
pub fn oneLine(text: []const u8) []const u8 {
    var s = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.indexOfAny(u8, s, "\r\n")) |i| s = std.mem.trim(u8, s[0..i], " \t");
    if (s.len <= 160) return s;
    var n: usize = 160;
    while (n > 0 and s[n] & 0xC0 == 0x80) n -= 1;
    return s[0..n];
}

test "oneLine keeps the first line only" {
    try std.testing.expectEqualStrings("built the parser", oneLine("  built the parser\nextra"));
    try std.testing.expectEqual(@as(usize, 160), oneLine("x" ** 200).len);
}

test "summary prompt names the command and the paths" {
    var b = try build(std.testing.allocator, "rm -rf build", &.{}, &.{"build/a.o"}, &.{});
    defer b.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, b.messages[1].content, "rm -rf build") != null);
    try std.testing.expect(std.mem.indexOf(u8, b.messages[1].content, "build/a.o") != null);
    try std.testing.expectEqualStrings("system", b.messages[0].role);
}
