//! Run a shortcut one command at a time. A non-zero exit stops the rest.
//! Without OSC 133 the caller sends `chain` instead (`cmd1 && cmd2`), which
//! the shell stops the same way.

const std = @import("std");

pub const Result = union(enum) {
    send: usize,
    stop: struct { index: usize, exit_code: i32 },
    done,
    ignore,
};

pub const Runner = struct {
    len: usize,
    index: usize = 0,
    waiting: bool = false,

    pub fn begin(self: *Runner) Result {
        if (self.len == 0) return .done;
        self.index = 0;
        self.waiting = true;
        return .{ .send = 0 };
    }

    /// `code` null means the shell finished the command without a status.
    /// That is not a failure. A non-zero status is.
    pub fn onExit(self: *Runner, code: ?i32) Result {
        if (!self.waiting) return .ignore;
        self.waiting = false;
        if (code) |c| if (c != 0) return .{ .stop = .{ .index = self.index, .exit_code = c } };
        const next = self.index + 1;
        if (next >= self.len) return .done;
        self.index = next;
        self.waiting = true;
        return .{ .send = next };
    }
};

pub fn chain(a: std.mem.Allocator, commands: []const []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    errdefer out.deinit();
    for (commands, 0..) |c, i| {
        if (i != 0) try out.appendSlice(" && ");
        try out.appendSlice(c);
    }
    return out.toOwnedSlice();
}

/// Bytes for the PTY. `clear` sends Ctrl+U first so a typed shortcut name
/// is erased before the real command (readline / fish).
pub fn launchLine(a: std.mem.Allocator, clear: bool, command: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    errdefer out.deinit();
    if (clear) try out.append(0x15);
    try out.appendSlice(command);
    try out.append('\r');
    return out.toOwnedSlice();
}

test "runner sends each command and stops on the first failure" {
    var r = Runner{ .len = 3 };
    try std.testing.expectEqual(@as(usize, 0), r.begin().send);
    try std.testing.expectEqual(@as(usize, 1), r.onExit(0).send);
    const stopped = r.onExit(7);
    try std.testing.expectEqual(@as(usize, 1), stopped.stop.index);
    try std.testing.expectEqual(@as(i32, 7), stopped.stop.exit_code);
    try std.testing.expect(r.onExit(0) == .ignore);
    try std.testing.expectEqual(@as(usize, 1), r.index);
}

test "runner finishes when every command exits 0" {
    var r = Runner{ .len = 3 };
    try std.testing.expectEqual(@as(usize, 0), r.begin().send);
    try std.testing.expectEqual(@as(usize, 1), r.onExit(null).send);
    try std.testing.expectEqual(@as(usize, 2), r.onExit(0).send);
    try std.testing.expect(r.onExit(0) == .done);
    try std.testing.expect(!r.waiting);
}

test "runner of zero commands is done" {
    var r = Runner{ .len = 0 };
    try std.testing.expect(r.begin() == .done);
}

test "chain joins with && and launchLine clears the prompt" {
    const a = std.testing.allocator;
    const joined = try chain(a, &.{ "git add -A", "git commit -m wip", "git push" });
    defer a.free(joined);
    try std.testing.expectEqualStrings("git add -A && git commit -m wip && git push", joined);
    const one = try chain(a, &.{"ls"});
    defer a.free(one);
    try std.testing.expectEqualStrings("ls", one);
    const line = try launchLine(a, true, "git status");
    defer a.free(line);
    try std.testing.expectEqual(@as(u8, 0x15), line[0]);
    try std.testing.expect(std.mem.endsWith(u8, line, "git status\r"));
    const next = try launchLine(a, false, "git diff");
    defer a.free(next);
    try std.testing.expectEqualStrings("git diff\r", next);
}
