//! Ghost Run overlay state.
//!
//! Opening it parses and estimates. It does not write to the PTY. The
//! caller sends the held Enter bytes only after Run or a successful
//! Time Travel snapshot.

const std = @import("std");
const builtin = @import("builtin");
const terminal = @import("../terminal/terminal.zig");
const input = @import("../terminal/input.zig");
const frame = @import("../renderer/frame.zig");
const match = @import("match.zig");
const impact = @import("impact.zig");
const time_travel = @import("time_travel.zig");

const Cell = terminal.Cell;

pub const Answer = enum { ignore, cancel, run, snapshot };

pub const Hold = struct {
    allocator: std.mem.Allocator,
    open: bool = false,
    pane: u32 = 0,
    command: []u8 = &.{},
    enter: []u8 = &.{},
    summary: []u8 = &.{},
    lines: std.ArrayList([]u8),
    ai: []u8 = &.{},
    notice: []u8 = &.{},
    pattern: []u8 = &.{},
    cwd: []u8 = &.{},
    partial: bool = false,
    ai_pending: bool = false,

    pub fn init(allocator: std.mem.Allocator) Hold {
        return .{ .allocator = allocator, .lines = std.ArrayList([]u8).init(allocator) };
    }

    pub fn deinit(self: *Hold) void {
        self.close();
        self.lines.deinit();
    }

    pub fn close(self: *Hold) void {
        const a = self.allocator;
        a.free(self.command);
        a.free(self.enter);
        a.free(self.summary);
        a.free(self.ai);
        a.free(self.notice);
        a.free(self.pattern);
        a.free(self.cwd);
        for (self.lines.items) |line| a.free(line);
        self.lines.clearRetainingCapacity();
        self.* = .{ .allocator = a, .lines = self.lines };
    }

    /// Intercept `command` when it matches. False leaves the hold closed.
    pub fn arm(self: *Hold, req: struct {
        command: []const u8,
        enter: []const u8,
        patterns: []const []const u8,
        cwd: []const u8,
        remote: bool,
        pane: u32,
        want_ai: bool,
    }) !bool {
        self.close();
        var hit = try match.intercept(self.allocator, req.command, req.patterns, req.cwd, req.remote) orelse return false;
        defer hit.deinit(self.allocator);
        var report = impact.estimate(self.allocator, &hit, req.cwd, req.remote) catch {
            return self.armFallback(req, "impact preview failed. The command was not run.");
        };
        var stolen = false;
        defer if (!stolen) report.deinit(self.allocator);
        const command = try self.allocator.dupe(u8, std.mem.trim(u8, req.command, " \t"));
        errdefer self.allocator.free(command);
        const enter = try self.allocator.dupe(u8, req.enter);
        errdefer self.allocator.free(enter);
        const pattern = try self.allocator.dupe(u8, hit.pattern);
        errdefer self.allocator.free(pattern);
        const cwd_copy = try self.allocator.dupe(u8, req.cwd);
        errdefer self.allocator.free(cwd_copy);
        self.lines.deinit();
        self.lines = std.ArrayList([]u8).fromOwnedSlice(self.allocator, report.lines);
        self.command = command;
        self.enter = enter;
        self.summary = report.summary;
        self.pattern = pattern;
        self.cwd = cwd_copy;
        report.summary = &.{};
        report.lines = &.{};
        stolen = true;
        self.partial = report.partial;
        self.pane = req.pane;
        self.ai_pending = req.want_ai;
        self.open = true;
        return true;
    }

    fn armFallback(self: *Hold, req: anytype, summary: []const u8) !bool {
        self.command = try self.allocator.dupe(u8, std.mem.trim(u8, req.command, " \t"));
        errdefer self.close();
        self.enter = try self.allocator.dupe(u8, req.enter);
        self.summary = try self.allocator.dupe(u8, summary);
        self.pane = req.pane;
        self.cwd = try self.allocator.dupe(u8, req.cwd);
        self.ai_pending = req.want_ai;
        self.partial = true;
        self.open = true;
        return true;
    }

    pub fn answerKey(self: *const Hold, key: input.Key) Answer {
        if (!self.open) return .ignore;
        return switch (key) {
            .escape => .cancel,
            else => .ignore,
        };
    }

    pub fn answerText(self: *const Hold, bytes: []const u8) Answer {
        if (!self.open or bytes.len != 1) return .ignore;
        return switch (bytes[0]) {
            'y', 'Y' => .run,
            'n', 'N', 0x1b, 0x03 => .cancel,
            't', 'T' => .snapshot,
            else => .ignore,
        };
    }

    pub fn setNotice(self: *Hold, text: []const u8) void {
        const d = self.allocator.dupe(u8, text) catch return;
        self.allocator.free(self.notice);
        self.notice = d;
    }

    /// Copy a streamed explanation. Returns whether the text changed.
    /// Parse `term`'s current command and arm when it matches.
    /// The command is not written to the PTY.
    pub fn consider(self: *Hold, req: struct {
        term: *const terminal.Terminal,
        enter: []const u8,
        patterns: []const []const u8,
        remote: bool,
        pane: u32,
        want_ai: bool,
    }) !bool {
        const cmd = (try req.term.currentInput(self.allocator)) orelse return false;
        defer self.allocator.free(cmd);
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = if (req.remote) "" else localCwd(req.term.cwd_uri, &buf);
        return self.arm(.{
            .command = cmd,
            .enter = req.enter,
            .patterns = req.patterns,
            .cwd = cwd,
            .remote = req.remote,
            .pane = req.pane,
            .want_ai = req.want_ai,
        });
    }

    pub fn impactText(self: *const Hold, allocator: std.mem.Allocator) ![]u8 {
        var out = std.ArrayList(u8).init(allocator);
        errdefer out.deinit();
        try out.appendSlice(self.summary);
        for (self.lines.items) |line| {
            try out.append('\n');
            try out.appendSlice(line);
        }
        return try out.toOwnedSlice();
    }

    /// Headless prompt. The command has not been run.
    pub fn logPreview(self: *const Hold) void {
        std.debug.print("\nGhost Run — not executed\n  {s}\n  {s}\n", .{ self.command, self.summary });
        for (self.lines.items) |line| std.debug.print("  {s}\n", .{line});
        if (self.partial) std.debug.print("  (preview stopped early)\n", .{});
        if (time_travel.isAvailable()) {
            std.debug.print("[y] Run   [n/Esc] Cancel   [t] Run with Time Travel snapshot\n", .{});
        } else {
            std.debug.print("[y] Run   [n/Esc] Cancel\n", .{});
        }
    }

    pub fn pullAi(self: *Hold, text: []const u8, done: bool, failed: bool) bool {
        if (!self.open or !self.ai_pending) return false;
        if (failed) {
            self.setNotice("AI explanation is unavailable.");
            self.ai_pending = false;
            return true;
        }
        if (std.mem.eql(u8, self.ai, text) and (!done or !self.ai_pending)) return false;
        const d = self.allocator.dupe(u8, text) catch return false;
        self.allocator.free(self.ai);
        self.ai = d;
        if (done) self.ai_pending = false;
        return true;
    }

    pub fn draw(self: *const Hold, cells: []Cell, marks: []frame.Mark, cols: u16, top: u16, bottom: u16) void {
        if (!self.open or bottom <= top or cols == 0) return;
        const room: usize = bottom - top;
        var title: [240]u8 = undefined;
        const title_s = std.fmt.bufPrint(&title, " GHOST RUN  {s}", .{self.command}) catch " GHOST RUN";
        var keys: [160]u8 = undefined;
        const keys_s = if (time_travel.isAvailable())
            std.fmt.bufPrint(&keys, " [y] Run   [n/Esc] Cancel   [t] Run with Time Travel snapshot", .{}) catch " [y] Run  [n] Cancel"
        else
            std.fmt.bufPrint(&keys, " [y] Run   [n/Esc] Cancel", .{}) catch " [y] Run  [n] Cancel";

        var rows: [20][]const u8 = undefined;
        var fgs: [20]u32 = undefined;
        var n: usize = 0;
        const push = struct {
            fn call(dst: [][]const u8, fg: []u32, len: *usize, text: []const u8, color: u32) void {
                if (len.* >= dst.len or text.len == 0) return;
                dst[len.*] = text;
                fg[len.*] = color;
                len.* += 1;
            }
        }.call;
        push(&rows, &fgs, &n, title_s, 0xFF5F5F);
        push(&rows, &fgs, &n, self.summary, 0xF5E6E6);
        for (self.lines.items) |line| push(&rows, &fgs, &n, line, 0xE8C8C8);
        if (self.notice.len > 0) push(&rows, &fgs, &n, self.notice, 0xFFD75F);
        if (self.ai_pending and self.ai.len == 0) push(&rows, &fgs, &n, "AI: thinking...", 0x9BD4FF);
        if (self.ai.len > 0) {
            var it = std.mem.splitScalar(u8, self.ai, '\n');
            var shown: usize = 0;
            while (it.next()) |line| {
                if (shown == 4) break;
                const t = std.mem.trim(u8, line, " \t\r");
                if (t.len == 0) continue;
                push(&rows, &fgs, &n, t, 0x9BD4FF);
                shown += 1;
            }
        }
        push(&rows, &fgs, &n, keys_s, 0xFFD75F);
        const shown_n = @min(n, room);
        const start = n - shown_n;
        const row0: usize = bottom - shown_n;
        var i: usize = 0;
        while (i < shown_n) : (i += 1) {
            const r = row0 + i;
            const row = cells[r * cols ..][0..cols];
            const mk = marks[r * cols ..][0..cols];
            @memset(mk, .none);
            paint(row, rows[start + i], fgs[start + i], 0x2A1014);
        }
    }
};

fn paint(cells: []Cell, text: []const u8, fg: u32, bg: u32) void {
    var c = Cell.init();
    c.fg_color = fg;
    c.bg_color = bg;
    c.bold = true;
    @memset(cells, c);
    var it = (std.unicode.Utf8View.init(text) catch return).iterator();
    var i: usize = 0;
    while (it.nextCodepoint()) |cp| : (i += 1) {
        if (i >= cells.len) break;
        if (i + 1 == cells.len and it.i < text.len) {
            cells[i].char = '…';
            break;
        }
        cells[i].char = if (cp < 0x20) ' ' else cp;
    }
}

pub fn patternList(custom_set: bool, custom: []const []const u8) []const []const u8 {
    if (custom_set) return custom;
    return &match.defaults;
}

pub fn loneEnter(bytes: []const u8) bool {
    return std.mem.eql(u8, bytes, "\r") or std.mem.eql(u8, bytes, "\n") or std.mem.eql(u8, bytes, "\r\n");
}

/// Shell cwd from an OSC 7 file URI when the host is this machine.
pub fn localCwd(uri: []const u8, buf: []u8) []const u8 {
    const path = terminal.shell_integration.cwdFromUri(uri, buf) orelse return "";
    if (!std.mem.startsWith(u8, uri, "file://")) return "";
    const rest = uri["file://".len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return "";
    const host = rest[0..slash];
    if (host.len == 0 or std.mem.eql(u8, host, "localhost")) return path;
    if (builtin.os.tag == .windows) return "";
    var name: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const me = std.posix.gethostname(&name) catch return "";
    if (!std.mem.eql(u8, host, me)) return "";
    return path;
}

test "overlay arms on rm, y would run, preview does not delete" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "gone.txt", .data = "still here" });
    const cwd = try @import("../testutil.zig").tmpPath(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(cwd);

    var hold = Hold.init(std.testing.allocator);
    defer hold.deinit();
    const armed = try hold.arm(.{
        .command = "rm -rf gone.txt",
        .enter = "\r",
        .patterns = &match.defaults,
        .cwd = cwd,
        .remote = false,
        .pane = 3,
        .want_ai = false,
    });
    try std.testing.expect(armed);
    try std.testing.expect(hold.open);
    try std.testing.expect(hold.answerText("\r") == .ignore);
    try std.testing.expect(hold.answerKey(.enter) == .ignore);
    try std.testing.expect(hold.answerText("t") == .snapshot);
    try std.testing.expect(hold.answerText("y") == .run);
    try std.testing.expectEqualStrings("\r", hold.enter);

    var body: [16]u8 = undefined;
    const f = try tmp.dir.openFile("gone.txt", .{});
    defer f.close();
    try std.testing.expectEqualStrings("still here", body[0..try f.readAll(&body)]);

    const cells = try std.testing.allocator.alloc(Cell, 8 * 60);
    defer std.testing.allocator.free(cells);
    const marks = try std.testing.allocator.alloc(frame.Mark, cells.len);
    defer std.testing.allocator.free(marks);
    @memset(cells, Cell.init());
    @memset(marks, .none);
    hold.draw(cells, marks, 60, 0, 8);
    var saw_title = false;
    for (cells, 0..) |c, i| {
        if (i % 60 == 1 and c.char == 'G') saw_title = true;
    }
    try std.testing.expect(saw_title);

    try std.testing.expect(hold.answerText("n") == .cancel);
    hold.close();
    try std.testing.expect(!hold.open);
}

test "time travel snapshot is not taken during preview" {
    const Probe = struct {
        var calls: usize = 0;
        fn available(_: *anyopaque) bool {
            return true;
        }
        fn snapshot(_: *anyopaque, req: time_travel.SnapshotRequest) time_travel.SnapshotResult {
            calls += 1;
            if (!std.mem.eql(u8, req.command, "rm -rf gone.txt")) return .{ .failed = "unexpected" };
            return .{ .ok = .{ .id = "snap" } };
        }
    };
    Probe.calls = 0;
    time_travel.register(.{ .ctx = undefined, .available = Probe.available, .snapshot = Probe.snapshot });
    defer time_travel.unregister();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "gone.txt", .data = "x" });
    const cwd = try @import("../testutil.zig").tmpPath(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(cwd);
    var hold = Hold.init(std.testing.allocator);
    defer hold.deinit();
    try std.testing.expect(try hold.arm(.{
        .command = "rm -rf gone.txt",
        .enter = "\r",
        .patterns = &match.defaults,
        .cwd = cwd,
        .remote = false,
        .pane = 1,
        .want_ai = false,
    }));
    try std.testing.expectEqual(@as(usize, 0), Probe.calls);
    const result = time_travel.snapshot(.{ .cwd = cwd, .command = hold.command, .pane = hold.pane });
    try std.testing.expectEqual(@as(usize, 1), Probe.calls);
    try std.testing.expect(result == .ok);
}
