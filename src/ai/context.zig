//! What the AI is told, and how its replies become suggestions.
//!
//! Everything taken from the terminal (typed input, directory, previous
//! commands, output) goes through `redact.redact` before it is put in a
//! prompt, so tokens, keys and passwords never leave the machine.

const std = @import("std");
const builtin = @import("builtin");
const openai = @import("openai.zig");
const redact = @import("redact.zig");

pub const HistoryItem = struct {
    command: []const u8,
    exit_code: ?i32 = null,
};

pub const Context = struct {
    /// The command line typed so far.
    input: []const u8,
    cwd: []const u8 = "",
    shell: []const u8 = "",
    os: []const u8 = @tagName(builtin.os.tag),
    /// Previous commands, oldest first.
    history: []const HistoryItem = &.{},
    /// Recent terminal output (tail).
    output: []const u8 = "",
};

pub const max_alternatives = 3;

const suggest_system =
    \\You are a shell autocompletion engine. The user is typing a command line.
    \\Reply with up to 3 likely complete command lines, one per line, best first.
    \\Every line must start with exactly the text typed so far and continue it.
    \\Reply with commands only: no explanations, no numbering, no markdown, no backticks.
;

const explain_system =
    \\You are a concise shell expert. A command failed. In at most 4 short lines,
    \\say why it failed, then give the corrected command on its own line prefixed with "$ ".
    \\No markdown headings.
;

fn writeCommon(w: anytype, arena: std.mem.Allocator, ctx: Context) !void {
    try w.print("OS: {s}\n", .{ctx.os});
    if (ctx.shell.len > 0) try w.print("Shell: {s}\n", .{std.fs.path.basename(ctx.shell)});
    if (ctx.cwd.len > 0) try w.print("Working directory: {s}\n", .{try redact.redact(arena, ctx.cwd)});
    if (ctx.history.len > 0) {
        try w.writeAll("Recent commands:\n");
        for (ctx.history) |h| {
            const cmd = try redact.redact(arena, h.command);
            if (h.exit_code) |code|
                try w.print("$ {s}   (exit {d})\n", .{ cmd, code })
            else
                try w.print("$ {s}\n", .{cmd});
        }
    }
    const out = std.mem.trim(u8, ctx.output, " \n");
    if (out.len > 0) try w.print("Recent output:\n{s}\n", .{try redact.redact(arena, out)});
}

/// Messages asking for completions of `ctx.input`. Allocated in `arena`.
pub fn suggestMessages(arena: std.mem.Allocator, ctx: Context) ![]openai.Message {
    var user = std.ArrayList(u8).init(arena);
    const w = user.writer();
    try writeCommon(w, arena, ctx);
    try w.print("Typed so far: {s}\nCompletions:", .{try redact.redact(arena, ctx.input)});
    const msgs = try arena.alloc(openai.Message, 2);
    msgs[0] = .{ .role = "system", .content = suggest_system };
    msgs[1] = .{ .role = "user", .content = user.items };
    return msgs;
}

/// Messages asking why `failed` went wrong and how to fix it.
pub fn explainMessages(arena: std.mem.Allocator, ctx: Context, failed: HistoryItem, failed_output: []const u8) ![]openai.Message {
    var user = std.ArrayList(u8).init(arena);
    const w = user.writer();
    var c = ctx;
    c.output = "";
    try writeCommon(w, arena, c);
    try w.print("Failed command: {s}\n", .{try redact.redact(arena, failed.command)});
    if (failed.exit_code) |code| try w.print("Exit code: {d}\n", .{code});
    const out = std.mem.trim(u8, failed_output, " \n");
    try w.print("Its output:\n{s}\n", .{if (out.len > 0) try redact.redact(arena, out) else "(none)"});
    const msgs = try arena.alloc(openai.Message, 2);
    msgs[0] = .{ .role = "system", .content = explain_system };
    msgs[1] = .{ .role = "user", .content = user.items };
    return msgs;
}

/// Clean one reply line: drop markdown fences, bullets, numbering, a
/// leading "$ " prompt and surrounding backticks.
fn cleanLine(line_in: []const u8) []const u8 {
    var line = std.mem.trim(u8, line_in, " \t\r");
    if (std.mem.startsWith(u8, line, "```")) return "";
    for ([_][]const u8{ "- ", "* ", "• " }) |b| {
        if (std.mem.startsWith(u8, line, b)) line = line[b.len..];
    }
    // "1. cmd" / "2) cmd"
    var i: usize = 0;
    while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
    if (i > 0 and i + 1 < line.len and (line[i] == '.' or line[i] == ')') and line[i + 1] == ' ') line = line[i + 2 ..];
    if (std.mem.startsWith(u8, line, "$ ")) line = line[2..];
    if (line.len >= 2 and line[0] == '`' and line[line.len - 1] == '`') line = line[1 .. line.len - 1];
    return std.mem.trim(u8, line, " \t");
}

/// Turn a reply into ghost-text suffixes: candidate lines that extend the
/// typed `input`, minus the typed part, deduplicated, at most `max`.
/// `complete` = the reply is finished (otherwise its last line may still
/// be growing and is only used if it already extends the input).
pub fn parseSuggestions(allocator: std.mem.Allocator, input: []const u8, reply: []const u8, max: usize) ![][]u8 {
    var out = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit();
    }
    const typed_trimmed = std.mem.trimLeft(u8, input, " ");
    var it = std.mem.splitScalar(u8, reply, '\n');
    while (it.next()) |raw| {
        if (out.items.len >= max) break;
        const line = cleanLine(raw);
        if (line.len == 0) continue;
        const suffix = suffixFor(typed_trimmed, line) orelse continue;
        if (suffix.len == 0) continue;
        // One line only, and no control characters may reach the PTY.
        var ok = true;
        for (suffix) |ch| if (ch < 0x20 or ch == 0x7f) {
            ok = false;
        };
        if (!ok) continue;
        const dup = for (out.items) |s| {
            if (std.mem.eql(u8, s, suffix)) break true;
        } else false;
        if (dup) continue;
        try out.append(try allocator.dupe(u8, suffix));
    }
    return out.toOwnedSlice();
}

fn suffixFor(typed: []const u8, line: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, line, typed)) return std.mem.trimRight(u8, line[typed.len..], " ");
    // The model may drop a trailing space the user typed ("git " -> "git push").
    const bare = std.mem.trimRight(u8, typed, " ");
    if (bare.len < typed.len and std.mem.startsWith(u8, line, bare) and line.len > bare.len and line[bare.len] == ' ')
        return std.mem.trimLeft(u8, line[bare.len..], " ");
    return null;
}

pub fn freeSuggestions(allocator: std.mem.Allocator, list: [][]u8) void {
    for (list) |s| allocator.free(s);
    allocator.free(list);
}

// ------------------------------------------------------------------ tests

const t = std.testing;

test "suggest prompt carries redacted context" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const msgs = try suggestMessages(arena, .{
        .input = "git pu",
        .cwd = "/home/u/proj",
        .shell = "/bin/bash",
        .os = "linux",
        .history = &.{
            .{ .command = "export GITHUB_TOKEN=gh" ++ "p_0123456789abcdefghijklmnopqrstuvwxyzAB", .exit_code = 0 },
            .{ .command = "git comit -m wip", .exit_code = 1 },
        },
        .output = "git: 'comit' is not a git command.\nAuthorization: Bearer abc.def.ghi123456\n",
    });
    try t.expectEqual(@as(usize, 2), msgs.len);
    const u = msgs[1].content;
    try t.expect(std.mem.indexOf(u8, u, "Shell: bash") != null);
    try t.expect(std.mem.indexOf(u8, u, "Working directory: /home/u/proj") != null);
    try t.expect(std.mem.indexOf(u8, u, "$ git comit -m wip   (exit 1)") != null);
    try t.expect(std.mem.indexOf(u8, u, "Typed so far: git pu") != null);
    try t.expect(std.mem.indexOf(u8, u, "gh" ++ "p_") == null);
    try t.expect(std.mem.indexOf(u8, u, "abc.def.ghi123456") == null);
    try t.expect(std.mem.indexOf(u8, u, "[REDACTED]") != null);
}

test "explain prompt names the failed command and its output" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const msgs = try explainMessages(arena_state.allocator(), .{ .input = "", .os = "linux" }, .{ .command = "mysql -uroot -phunter2 db", .exit_code = 1 }, "ERROR 1045 (28000): Access denied");
    const u = msgs[1].content;
    try t.expect(std.mem.indexOf(u8, u, "Exit code: 1") != null);
    try t.expect(std.mem.indexOf(u8, u, "Access denied") != null);
    try t.expect(std.mem.indexOf(u8, u, "hunter2") == null);
}

test "parseSuggestions keeps lines that extend the input" {
    const reply =
        \\```bash
        \\1. git push origin main
        \\2. `git pull --rebase`
        \\- git push origin main
        \\git status
        \\$ git push --force-with-lease
        \\```
    ;
    const s = try parseSuggestions(t.allocator, "git pu", reply, max_alternatives);
    defer freeSuggestions(t.allocator, s);
    try t.expectEqual(@as(usize, 3), s.len);
    try t.expectEqualStrings("sh origin main", s[0]);
    try t.expectEqualStrings("ll --rebase", s[1]);
    try t.expectEqualStrings("sh --force-with-lease", s[2]);
}

test "parseSuggestions: trailing space, nothing new, control characters" {
    const a = try parseSuggestions(t.allocator, "ls ", "ls -la\nls \nls\x1b[31m -l", 3);
    defer freeSuggestions(t.allocator, a);
    try t.expectEqual(@as(usize, 1), a.len);
    try t.expectEqualStrings("-la", a[0]);
    const b = try parseSuggestions(t.allocator, "docker", "Sure! Here are some options:\nkubectl get pods", 3);
    defer freeSuggestions(t.allocator, b);
    try t.expectEqual(@as(usize, 0), b.len);
}
