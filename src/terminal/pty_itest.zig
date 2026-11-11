//! Spawn a real shell and check that bytes and VT sequences survive the PTY.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const pty_mod = @import("pty.zig");
const Terminal = @import("terminal.zig").Terminal;

const t = std.testing;

test "pty integration: shell output and VT sequences round-trip" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try posixRoundTrip();
}

fn posixRoundTrip() !void {
    if (comptime builtin.os.tag == .windows) return;
    var pty = try pty_mod.PTY.open();
    defer pty.close();
    try pty.setWindowSize(6, 20);
    // sh -c so the script is the whole session: a letter, a clear, a home,
    // another letter, and an OSC title. No interactive prompt mixed in.
    const script = "printf 'A\\033[2J\\033[HY\\033]0;Hi\\007'";
    try pty.spawnShell(t.allocator, .{ .program = "/bin/sh", .args = &.{ "-c", script } });
    defer reap(&pty);

    var got = std.ArrayList(u8).init(t.allocator);
    defer got.deinit();
    try readUntilIdle(&pty, &got, 2000);
    try t.expect(got.items.len > 0);
    try t.expect(std.mem.indexOf(u8, got.items, "Y") != null);
    try t.expect(std.mem.indexOf(u8, got.items, "\x1b[2J") != null or std.mem.indexOf(u8, got.items, "\x1b[H") != null);

    var term = try Terminal.initBuffer(t.allocator, 6, 20, 32);
    defer term.deinit();
    try term.processOutput(got.items);
    try t.expectEqualStrings("Hi", term.title);
    try t.expectEqual(@as(u21, 'Y'), term.screenRow(0)[0].char);
    try t.expectEqual(@as(u16, 0), term.cursor_row);
    try t.expectEqual(@as(u16, 1), term.cursor_col);
    std.debug.print("pty integration: {d} bytes, title \"{s}\", cursor {d},{d}\n", .{
        got.items.len, term.title, term.cursor_row, term.cursor_col,
    });
}

fn readUntilIdle(pty: *pty_mod.PTY, out: *std.ArrayList(u8), timeout_ms: i64) !void {
    if (comptime builtin.os.tag == .windows) return;
    const fd = pty.fd();
    var buf: [512]u8 = undefined;
    const deadline = std.time.milliTimestamp() + timeout_ms;
    var idle: i64 = 0;
    while (std.time.milliTimestamp() < deadline) {
        var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
        const n = posix.poll(&fds, 50) catch break;
        if (n == 0) {
            idle += 50;
            if (out.items.len > 0 and idle >= 200) break;
            continue;
        }
        idle = 0;
        const r = posix.read(fd, &buf) catch |err| switch (err) {
            error.InputOutput, error.ConnectionResetByPeer => break,
            else => return err,
        };
        if (r == 0) break;
        try out.appendSlice(buf[0..r]);
    }
}

fn reap(pty: *pty_mod.PTY) void {
    if (comptime builtin.os.tag == .windows) return;
    if (pty.child_pid) |pid| {
        _ = posix.waitpid(pid, 0);
        pty.child_pid = null;
    }
}
