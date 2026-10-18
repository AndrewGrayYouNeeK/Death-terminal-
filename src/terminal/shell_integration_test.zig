//! OSC 133 tracking against a real Terminal grid.

const std = @import("std");
const t = std.testing;
const Terminal = @import("terminal.zig").Terminal;

fn mk(rows: u16, cols: u16) !Terminal {
    return Terminal.initBuffer(t.allocator, rows, cols, 64);
}

fn expectInput(term: *Terminal, expected: ?[]const u8) !void {
    const got = try term.currentInput(t.allocator);
    defer if (got) |g| t.allocator.free(g);
    if (expected) |e| {
        try t.expect(got != null);
        try t.expectEqualStrings(e, got.?);
    } else try t.expect(got == null);
}

const A = "\x1b]133;A\x07";
const B = "\x1b]133;B\x07";
const C = "\x1b]133;C\x07";

test "marks: input, command, exit code and output" {
    var term = try mk(10, 40);
    defer term.deinit();
    try term.processOutput(A ++ "user@h:~$ " ++ B);
    try expectInput(&term, "");
    try term.processOutput("git sta");
    try expectInput(&term, "git sta");
    try term.processOutput("tus ");
    try expectInput(&term, "git status ");
    // Enter: the shell echoes a newline, marks C, the command prints.
    try term.processOutput("\r\n" ++ C ++ "fatal: not a git repository\r\n");
    try expectInput(&term, null); // a command is running
    try term.processOutput("\x1b]133;D;128\x07" ++ A ++ "user@h:~$ " ++ B);
    const last = term.shell.lastCommand().?;
    try t.expectEqualStrings("git status", last.text);
    try t.expectEqual(@as(?i32, 128), last.exit_code);
    try t.expectEqualStrings("fatal: not a git repository", last.output);
    try expectInput(&term, "");
}

test "marks: the cursor in the middle of the input gives no input" {
    var term = try mk(5, 40);
    defer term.deinit();
    try term.processOutput(A ++ "$ " ++ B ++ "echo hello\x1b[5D");
    try expectInput(&term, null);
    try term.processOutput("\x1b[5C");
    try expectInput(&term, "echo hello");
}

test "marks: long input that soft-wraps is joined" {
    var term = try mk(5, 10);
    defer term.deinit();
    try term.processOutput(A ++ "$ " ++ B ++ "echo abcdefghijkl");
    try expectInput(&term, "echo abcdefghijkl");
}

test "marks: a new prompt without D still records the command" {
    var term = try mk(6, 30);
    defer term.deinit();
    try term.processOutput(A ++ "$ " ++ B ++ "make\r\n" ++ C ++ "ok\r\n" ++ A ++ "$ " ++ B);
    const last = term.shell.lastCommand().?;
    try t.expectEqualStrings("make", last.text);
    try t.expectEqual(@as(?i32, null), last.exit_code);
    try t.expectEqualStrings("ok", last.output);
}

test "marks: ignored on the alternate screen; RIS forgets them" {
    var term = try mk(5, 30);
    defer term.deinit();
    try term.processOutput("\x1b[?1049h" ++ A);
    try t.expect(!term.shell.seen);
    try expectInput(&term, null);
    try term.processOutput("\x1b[?1049l" ++ A ++ "$ " ++ B ++ "ls");
    try expectInput(&term, "ls");
    try term.processOutput("\x1bc");
    try t.expect(!term.shell.seen);
}

test "no marks: heuristic from the cursor row" {
    var term = try mk(5, 40);
    defer term.deinit();
    try term.processOutput("some output\r\nuser@host:~/src$ docker ps -");
    try expectInput(&term, "docker ps -");
    try term.processOutput("\r\nplain output, no prompt");
    try expectInput(&term, null);
}

test "recentText trims and joins rows" {
    var term = try mk(5, 20);
    defer term.deinit();
    try term.processOutput("one\r\ntwo\r\nthree\r\n$ ");
    const s = try term.recentText(t.allocator, 3);
    defer t.allocator.free(s);
    try t.expectEqualStrings("two\nthree\n$", s);
}
