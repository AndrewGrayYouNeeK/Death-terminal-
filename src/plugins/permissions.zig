//! Capabilities a plugin can ask for (manifest `permissions`) and the user
//! can grant (`config.plugins.<name>.allow`). A plugin gets the
//! intersection; everything not listed here needs no permission.

const std = @import("std");

pub const Permission = enum {
    /// Read the screen and scrollback text; `output_line` events; the
    /// command line in `command_start` / `command_finish`.
    screen,
    /// See (and consume) key presses: the `key` event.
    input,
    /// Write to the terminal's input (as if typed).
    pty,
    /// Read and set the clipboard.
    clipboard,
    /// HTTP(S) requests to the hosts in `plugins.<name>.hosts`.
    network,
    /// Run the programs listed in `plugins.<name>.exec`.
    exec,
    /// Files under the plugin's own data directory.
    fs,
    /// See and rewrite AI suggestions: the `ai_suggestion` event.
    ai,

    pub fn parse(name: []const u8) ?Permission {
        return std.meta.stringToEnum(Permission, name);
    }

    pub fn describe(self: Permission) []const u8 {
        return switch (self) {
            .screen => "read screen text, output lines and command lines",
            .input => "see and consume key presses",
            .pty => "type into the terminal",
            .clipboard => "read and set the clipboard",
            .network => "HTTP requests to allowlisted hosts",
            .exec => "run allowlisted programs",
            .fs => "files in its own data directory",
            .ai => "see and rewrite AI suggestions",
        };
    }
};

pub const Set = std.EnumSet(Permission);

pub const all_names = blk: {
    const fields = @typeInfo(Permission).Enum.fields;
    var names: [fields.len][]const u8 = undefined;
    for (fields, 0..) |f, i| names[i] = f.name;
    break :blk names;
};

/// "screen, exec" (or "none").
pub fn format(set: Set, buf: []u8) []const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    var it = set.iterator();
    var first = true;
    while (it.next()) |p| {
        if (!first) w.writeAll(", ") catch break;
        w.writeAll(@tagName(p)) catch break;
        first = false;
    }
    if (first) return "none";
    return fbs.getWritten();
}

/// One-line list of every permission name, for error messages.
pub fn namesList(buf: []u8) []const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    for (all_names, 0..) |n, i| {
        if (i > 0) fbs.writer().writeAll(", ") catch break;
        fbs.writer().writeAll(n) catch break;
    }
    return fbs.getWritten();
}

test "parse and format" {
    var s = Set.initEmpty();
    s.insert(Permission.parse("exec").?);
    s.insert(.screen);
    var b: [128]u8 = undefined;
    try std.testing.expectEqualStrings("screen, exec", format(s, &b));
    try std.testing.expectEqualStrings("none", format(Set.initEmpty(), &b));
    try std.testing.expect(Permission.parse("root") == null);
    try std.testing.expect(std.mem.indexOf(u8, namesList(&b), "clipboard") != null);
}
