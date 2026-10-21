//! Prompt for the optional plain-English Ghost Run explanation.
//!
//! The command has not run. The text is redacted with the same pass as
//! other AI requests before it is handed to the worker.

const std = @import("std");
const openai = @import("../ai/openai.zig");
const redact = @import("../ai/redact.zig");

const system =
    \\You explain a risky shell command before it runs. It has NOT been executed.
    \\In at most 4 short lines of plain English, say what it would change and what could be lost.
    \\Use the local impact notes when they are present. Do not suggest a command to run.
    \\No markdown, no headings, no code fences.
;

pub fn messages(arena: std.mem.Allocator, command: []const u8, impact: []const u8, cwd: []const u8) ![]openai.Message {
    var user = std.ArrayList(u8).init(arena);
    const w = user.writer();
    try w.writeAll("This command has not been executed. Explain the risk.\n");
    if (cwd.len > 0) try w.print("Working directory: {s}\n", .{try redact.redact(arena, cwd)});
    try w.print("Command: {s}\n", .{try redact.redact(arena, command)});
    if (impact.len > 0) try w.print("Local read-only estimate:\n{s}\n", .{try redact.redact(arena, impact)});
    const msgs = try arena.alloc(openai.Message, 2);
    msgs[0] = .{ .role = "system", .content = system };
    msgs[1] = .{ .role = "user", .content = user.items };
    return msgs;
}
