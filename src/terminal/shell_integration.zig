//! OSC 133 shell-integration tracking.
//!
//! Shells that run YouNeeK Death Terminal's integration snippets (see
//! shell-integration/) mark their prompts with OSC 133:
//!
//!   ESC ] 133 ; A BEL   prompt starts
//!   ESC ] 133 ; B BEL   prompt ends, user input starts
//!   ESC ] 133 ; C BEL   the typed command starts running (output follows)
//!   ESC ] 133 ; D ; n   the command finished with exit code n
//!
//! From those marks the terminal knows the command line being typed, the
//! commands that ran, their exit codes and their output, which is the
//! context AI suggestions need. Without the marks `heuristicInput` guesses
//! the input from the cursor row (text after the last "$ " style prompt).
//!
//! Positions are absolute line numbers (`Terminal.lineAt`) plus a column,
//! tagged with the terminal's `layout_gen`: a reflow renumbers lines, so
//! marks from an older layout are dropped.

const std = @import("std");

pub const Phase = enum { none, prompt, input, running };

pub const Mark = struct {
    line: i64,
    col: u16,
    gen: u32,
};

/// Absolute line range of a command's output (OSC 133 C through D).
/// Valid while `Terminal.layout_gen` still equals `gen`.
pub const OutputSpan = struct {
    start: i64,
    end: i64,
    /// Column where the output begins on `start`.
    col: u16 = 0,
    gen: u32,
};

pub const Command = struct {
    text: []u8,
    /// null = the shell never reported it (D without a code).
    exit_code: ?i32,
    /// Tail of the command's output (at most `max_output` bytes).
    output: []u8,
    /// Screen lines of the output, when the marks were still in the grid.
    span: ?OutputSpan = null,

    fn deinit(self: Command, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.output);
    }
};

pub const max_history = 32;
pub const max_output = 4096;
pub const max_command = 4096;

pub const State = struct {
    allocator: std.mem.Allocator,
    /// Set once any OSC 133 mark arrives; until then input is guessed.
    seen: bool = false,
    phase: Phase = .none,
    input_start: ?Mark = null,
    output_start: ?Mark = null,
    /// Command line captured at C, waiting for its D.
    pending: ?[]u8 = null,
    /// Finished commands, oldest first.
    history: std.ArrayListUnmanaged(Command) = .{},
    /// Bumped whenever a command finishes.
    finished: u64 = 0,
    /// Bumped whenever a command starts (OSC 133 C).
    started: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) State {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *State) void {
        if (self.pending) |p| self.allocator.free(p);
        for (self.history.items) |c| c.deinit(self.allocator);
        self.history.deinit(self.allocator);
        self.* = undefined;
    }

    /// Forget everything (RIS).
    pub fn reset(self: *State) void {
        const a = self.allocator;
        self.deinit();
        self.* = init(a);
    }

    /// Record a finished command (takes ownership of `text` and `output`).
    pub fn pushCommand(self: *State, text: []u8, exit_code: ?i32, output: []u8, span: ?OutputSpan) void {
        if (self.history.items.len >= max_history) {
            self.history.items[0].deinit(self.allocator);
            _ = self.history.orderedRemove(0);
        }
        self.history.append(self.allocator, .{ .text = text, .exit_code = exit_code, .output = output, .span = span }) catch {
            self.allocator.free(text);
            self.allocator.free(output);
            return;
        };
        self.finished +%= 1;
    }

    pub fn lastCommand(self: *const State) ?*const Command {
        if (self.history.items.len == 0) return null;
        return &self.history.items[self.history.items.len - 1];
    }
};

/// Parse the argument of a D mark ("D", "D;0", "D;127;extra").
pub fn parseExit(arg: []const u8) ?i32 {
    if (arg.len < 2 or arg[1] != ';') return null;
    var rest = arg[2..];
    if (std.mem.indexOfScalar(u8, rest, ';')) |i| rest = rest[0..i];
    return std.fmt.parseInt(i32, std.mem.trim(u8, rest, " "), 10) catch null;
}

/// Prompt endings recognised by the heuristic, most specific first.
const prompt_markers = [_][]const u8{ "❯ ", "➜ ", "$ ", "# ", "% ", "> " };

/// Guess the typed input from the text of the cursor row before the
/// cursor: whatever follows the first prompt marker (the input itself may
/// contain "> " or "$ "). null if there is none.
pub fn heuristicInput(row_before_cursor: []const u8) ?[]const u8 {
    var best: ?usize = null;
    var best_at: usize = std.math.maxInt(usize);
    for (prompt_markers) |m| {
        if (std.mem.indexOf(u8, row_before_cursor, m)) |i| {
            if (i < best_at) {
                best_at = i;
                best = i + m.len;
            }
        }
    }
    const start = best orelse {
        // A bare prompt with the cursor right after "$" (no space yet).
        for (prompt_markers) |m| {
            const t = std.mem.trimRight(u8, m, " ");
            if (std.mem.endsWith(u8, row_before_cursor, t)) return "";
        }
        return null;
    };
    return row_before_cursor[start..];
}

/// Path of an OSC 7 `file://host/path` URI, percent-decoded into `buf`.
pub fn cwdFromUri(uri: []const u8, buf: []u8) ?[]const u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return null;
    const rest = uri[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const path = rest[slash..];
    var n: usize = 0;
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (n >= buf.len) return null;
        if (path[i] == '%' and i + 2 < path.len) {
            if (std.fmt.parseInt(u8, path[i + 1 .. i + 3], 16)) |b| {
                buf[n] = b;
                n += 1;
                i += 2;
                continue;
            } else |_| {}
        }
        buf[n] = path[i];
        n += 1;
    }
    return buf[0..n];
}

test "parseExit" {
    try std.testing.expectEqual(@as(?i32, 0), parseExit("D;0"));
    try std.testing.expectEqual(@as(?i32, 127), parseExit("D;127;aid=3"));
    try std.testing.expectEqual(@as(?i32, null), parseExit("D"));
    try std.testing.expectEqual(@as(?i32, null), parseExit("D;x"));
}

test "heuristicInput" {
    try std.testing.expectEqualStrings("git st", heuristicInput("user@host:~/src$ git st").?);
    try std.testing.expectEqualStrings("", heuristicInput("root@box:/# ").?);
    try std.testing.expectEqualStrings("ls -l", heuristicInput("~/x ❯ ls -l").?);
    try std.testing.expectEqualStrings("echo a > b", heuristicInput("$ echo a > b").?);
    try std.testing.expectEqualStrings("", heuristicInput("bash-5.2$").?);
    try std.testing.expect(heuristicInput("just output text") == null);
}

test "cwdFromUri" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("/home/a b", cwdFromUri("file://host/home/a%20b", &buf).?);
    try std.testing.expectEqualStrings("/", cwdFromUri("file:///", &buf).?);
    try std.testing.expect(cwdFromUri("http://x/y", &buf) == null);
}

test "history ring keeps the newest commands" {
    var s = State.init(std.testing.allocator);
    defer s.deinit();
    for (0..max_history + 5) |i| {
        const t = try std.fmt.allocPrint(std.testing.allocator, "cmd{d}", .{i});
        s.pushCommand(t, @intCast(i), try std.testing.allocator.dupe(u8, ""), null);
    }
    try std.testing.expectEqual(@as(usize, max_history), s.history.items.len);
    try std.testing.expectEqualStrings("cmd5", s.history.items[0].text);
    try std.testing.expectEqual(@as(?i32, max_history + 4), s.lastCommand().?.exit_code);
}
