//! Local command log: cwd, command, exit code. Commands that the AI
//! redactor would change are not stored (they contain a secret).

const std = @import("std");
const redact = @import("../ai/redact.zig");
const paths = @import("paths.zig");

pub const max_entries = 2000;
const max_command = 2048;
const max_file = 2 * 1024 * 1024;

pub const Entry = struct {
    cwd: []u8,
    command: []u8,
    exit_code: ?i32,

    pub fn deinit(self: Entry, a: std.mem.Allocator) void {
        a.free(self.cwd);
        a.free(self.command);
    }
};

pub fn containsSecret(a: std.mem.Allocator, text: []const u8) bool {
    const red = redact.redact(a, text) catch return true;
    defer a.free(red);
    return !std.mem.eql(u8, red, text);
}

pub const Log = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry),
    path: ?[]u8,

    pub fn init(a: std.mem.Allocator, path: ?[]const u8) !Log {
        var self = Log{
            .allocator = a,
            .entries = std.ArrayList(Entry).init(a),
            .path = if (path) |p| try a.dupe(u8, p) else null,
        };
        errdefer self.deinit();
        if (self.path) |p| self.load(p) catch |err| {
            std.debug.print("muscle: cannot read history: {s}\n", .{@errorName(err)});
        };
        return self;
    }

    pub fn deinit(self: *Log) void {
        for (self.entries.items) |e| e.deinit(self.allocator);
        self.entries.deinit();
        if (self.path) |p| self.allocator.free(p);
    }

    /// false = skipped (empty, multi-line, or contains a secret).
    pub fn record(self: *Log, cwd: []const u8, command: []const u8, exit_code: ?i32) !bool {
        const dir = std.mem.trim(u8, cwd, " \t");
        const cmd = std.mem.trim(u8, command, " \t");
        if (dir.len == 0 or cmd.len == 0 or cmd.len > max_command) return false;
        if (std.mem.indexOfScalar(u8, cmd, '\n') != null or std.mem.indexOfScalar(u8, cmd, 0) != null) return false;
        if (containsSecret(self.allocator, cmd)) return false;
        try self.entries.append(.{
            .cwd = try self.allocator.dupe(u8, dir),
            .command = try self.allocator.dupe(u8, cmd),
            .exit_code = exit_code,
        });
        if (self.entries.items.len > max_entries) {
            const drop = self.entries.items.len - max_entries;
            for (self.entries.items[0..drop]) |e| e.deinit(self.allocator);
            try self.entries.replaceRange(0, drop, &.{});
        }
        if (self.path) |p| self.save(p) catch |err| {
            std.debug.print("muscle: cannot write history: {s}\n", .{@errorName(err)});
        };
        return true;
    }

    fn load(self: *Log, path: []const u8) !void {
        const data = try paths.readFile(self.allocator, path, max_file) orelse return;
        defer self.allocator.free(data);
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            const parts = split3(line) orelse continue;
            const cmd = try unescape(self.allocator, parts[2]);
            errdefer self.allocator.free(cmd);
            const dir = try unescape(self.allocator, parts[1]);
            errdefer self.allocator.free(dir);
            if (cmd.len == 0 or dir.len == 0 or containsSecret(self.allocator, cmd)) {
                self.allocator.free(cmd);
                self.allocator.free(dir);
                continue;
            }
            const code: ?i32 = if (std.mem.eql(u8, parts[0], "-"))
                null
            else
                std.fmt.parseInt(i32, parts[0], 10) catch {
                    self.allocator.free(cmd);
                    self.allocator.free(dir);
                    continue;
                };
            try self.entries.append(.{ .cwd = dir, .command = cmd, .exit_code = code });
        }
        if (self.entries.items.len > max_entries) {
            const drop = self.entries.items.len - max_entries;
            for (self.entries.items[0..drop]) |e| e.deinit(self.allocator);
            try self.entries.replaceRange(0, drop, &.{});
        }
    }

    fn save(self: *Log, path: []const u8) !void {
        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        try buf.appendSlice("# YouNeeK Death Terminal muscle-memory history. Local only.\n");
        for (self.entries.items) |e| {
            if (e.exit_code) |c| try buf.writer().print("{d}\t", .{c}) else try buf.appendSlice("-\t");
            try escape(&buf, e.cwd);
            try buf.append('\t');
            try escape(&buf, e.command);
            try buf.append('\n');
        }
        try paths.replaceFile(path, buf.items);
    }
};

fn split3(line: []const u8) ?[3][]const u8 {
    const a = std.mem.indexOfScalar(u8, line, '\t') orelse return null;
    const b = std.mem.indexOfScalarPos(u8, line, a + 1, '\t') orelse return null;
    return .{ line[0..a], line[a + 1 .. b], line[b + 1 ..] };
}

fn escape(buf: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| switch (c) {
        '\\' => try buf.appendSlice("\\\\"),
        '\t' => try buf.appendSlice("\\t"),
        '\n' => try buf.appendSlice("\\n"),
        '\r' => try buf.appendSlice("\\r"),
        else => try buf.append(c),
    };
}

fn unescape(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    errdefer out.deinit();
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            try out.append(switch (s[i]) {
                't' => '\t',
                'n' => '\n',
                'r' => '\r',
                '\\' => '\\',
                else => s[i],
            });
        } else try out.append(s[i]);
    }
    return out.toOwnedSlice();
}

test "secrets are not stored and ordinary commands round-trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try @import("../testutil.zig").tmpPath(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(dir);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, "hist" });
    defer std.testing.allocator.free(path);

    var log = try Log.init(std.testing.allocator, path);
    defer log.deinit();
    try std.testing.expect(try log.record("/work/app", "git status", 0));
    try std.testing.expect(try log.record("/work/app", "echo a\tb", 1));
    try std.testing.expect(!try log.record("/work/app", "tool --password hunter2", 0));
    try std.testing.expect(!try log.record("/work/app", "   ", 0));
    try std.testing.expectEqual(@as(usize, 2), log.entries.items.len);

    var again = try Log.init(std.testing.allocator, path);
    defer again.deinit();
    try std.testing.expectEqual(@as(usize, 2), again.entries.items.len);
    try std.testing.expectEqualStrings("git status", again.entries.items[0].command);
    try std.testing.expectEqual(@as(?i32, 0), again.entries.items[0].exit_code);
    try std.testing.expectEqualStrings("/work/app", again.entries.items[0].cwd);
    try std.testing.expectEqualStrings("echo a\tb", again.entries.items[1].command);
    try std.testing.expectEqual(@as(?i32, 1), again.entries.items[1].exit_code);
}
