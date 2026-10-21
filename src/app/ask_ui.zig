//! Bottom bar for Ask the Output: the question, then jump-between-matches
//! once the answer is in. Highlights use the same marks as search.

const std = @import("std");
const input = @import("../terminal/input.zig");
const search = @import("../terminal/search.zig");
const frame = @import("../renderer/frame.zig");

pub const Phase = enum { edit, wait, answer };

pub const Effect = union(enum) {
    ignored,
    consumed,
    submit,
    close,
    jump: i64,
};

pub const Bar = struct {
    live: bool = false,
    allocator: std.mem.Allocator = undefined,
    query: ?std.ArrayList(u8) = null,
    source: []u8 = &.{},
    phase: Phase = .edit,
    matches: ?std.ArrayList(search.Match) = null,
    current: ?usize = null,
    pending_submit: bool = false,
    pending_cancel: bool = false,
    offline: bool = false,

    pub fn isOpen(self: *const Bar) bool {
        return self.live;
    }

    pub fn open(self: *Bar, allocator: std.mem.Allocator, source_label: []const u8) !void {
        self.close();
        self.pending_cancel = false;
        var query = std.ArrayList(u8).init(allocator);
        errdefer query.deinit();
        var matches = std.ArrayList(search.Match).init(allocator);
        errdefer matches.deinit();
        const source = try allocator.dupe(u8, source_label);
        self.allocator = allocator;
        self.query = query;
        self.matches = matches;
        self.source = source;
        self.live = true;
        self.phase = .edit;
        self.current = null;
        self.pending_submit = false;
        self.offline = false;
    }

    pub fn close(self: *Bar) void {
        if (!self.live) return;
        if (self.query) |*q| q.deinit();
        if (self.matches) |*m| m.deinit();
        self.query = null;
        self.matches = null;
        if (self.source.len > 0) self.allocator.free(self.source);
        self.source = &.{};
        self.live = false;
        self.phase = .edit;
        self.current = null;
        self.pending_submit = false;
        self.offline = false;
    }

    pub fn requestClose(self: *Bar) Effect {
        if (!self.live) return .ignored;
        self.pending_cancel = true;
        self.close();
        return .close;
    }

    pub fn queryText(self: *const Bar) []const u8 {
        const q = self.query orelse return "";
        return q.items;
    }

    pub fn markWaiting(self: *Bar) void {
        if (!self.live) return;
        self.phase = .wait;
        self.offline = false;
        if (self.matches) |*m| m.clearRetainingCapacity();
        self.current = null;
    }

    pub fn markEdit(self: *Bar) void {
        if (!self.live) return;
        self.phase = .edit;
    }

    pub fn markOffline(self: *Bar) void {
        if (!self.live) return;
        self.phase = .answer;
        self.offline = true;
        if (self.matches) |*m| m.clearRetainingCapacity();
        self.current = null;
    }

    /// Copies `matches`. Returns the absolute line of the first one.
    pub fn setMatches(self: *Bar, matches: []const search.Match) ?i64 {
        if (!self.live) return null;
        const ms = &(self.matches orelse return null);
        ms.clearRetainingCapacity();
        ms.appendSlice(matches) catch return null;
        self.phase = .answer;
        self.offline = false;
        if (ms.items.len == 0) {
            self.current = null;
            return null;
        }
        self.current = 0;
        return ms.items[0].line;
    }

    pub fn handleText(self: *Bar, bytes: []const u8) Effect {
        if (!self.live) return .ignored;
        if (self.phase != .edit) {
            if (bytes.len == 1 and (bytes[0] == 0x03 or bytes[0] == 0x1b or bytes[0] == 0x07)) return self.requestClose();
            if (self.phase == .answer and bytes.len == 1) switch (bytes[0]) {
                0x0e => return self.jump(false),
                0x10 => return self.jump(true),
                else => {},
            };
            return .consumed;
        }
        if (bytes.len == 1) switch (bytes[0]) {
            0x03, 0x07, 0x1b => return self.requestClose(),
            0x15 => {
                if (self.query) |*q| q.clearRetainingCapacity();
                return .consumed;
            },
            0x08, 0x7f => {
                if (self.query) |*q| deleteLast(q);
                return .consumed;
            },
            '\r', '\n' => return self.submit(),
            else => {},
        };
        if (bytes.len == 1 and bytes[0] < 0x20) return .consumed;
        for (bytes) |b| if (b < 0x20) return .consumed;
        const q = &(self.query orelse return .consumed);
        if (q.items.len + bytes.len > 400) return .consumed;
        q.appendSlice(bytes) catch return .consumed;
        return .consumed;
    }

    pub fn handleKey(self: *Bar, key: input.Key, mods: input.Mods) Effect {
        if (!self.live) return .ignored;
        return switch (self.phase) {
            .edit => switch (key) {
                .enter, .kp_enter => self.submit(),
                .escape => self.requestClose(),
                .backspace => blk: {
                    if (self.query) |*q| deleteLast(q);
                    break :blk .consumed;
                },
                else => .consumed,
            },
            .wait => switch (key) {
                .escape => self.requestClose(),
                else => .consumed,
            },
            .answer => switch (key) {
                .escape => self.requestClose(),
                .enter, .kp_enter => self.jump(mods.shift),
                .up => self.jump(true),
                .down => self.jump(false),
                else => .consumed,
            },
        };
    }

    pub fn barText(self: *const Bar, buf: []u8) []const u8 {
        if (!self.live) return "";
        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();
        const src = if (self.source.len > 0) self.source else "output";
        switch (self.phase) {
            .edit => w.print(" Ask ({s}): {s}\u{2588}   Enter ask   Esc cancel", .{ src, self.queryText() }) catch {},
            .wait => w.print(" Ask ({s}): thinking\u{2026}   Esc cancel", .{src}) catch {},
            .answer => {
                if (self.offline) {
                    w.writeAll(" Ask: AI offline   Esc close") catch {};
                } else {
                    const n = if (self.matches) |m| m.items.len else 0;
                    if (n == 0) {
                        w.writeAll(" Ask: no cited lines   Esc close") catch {};
                    } else {
                        const cur = (self.current orelse 0) + 1;
                        w.print(" Ask: {d}/{d}   Enter/\u{2193} next   Shift+Enter/\u{2191} previous   Esc close", .{ cur, n }) catch {};
                    }
                }
            },
        }
        return fbs.getWritten();
    }

    pub fn paint(self: *const Bar, top: i64, rows: u16, cols: u16, marks: []frame.Mark) void {
        if (!self.live or self.phase != .answer or cols == 0) return;
        const ms = self.matches orelse return;
        for (ms.items, 0..) |m, i| {
            if (m.end_line < top or m.line >= top + rows) continue;
            const mk: frame.Mark = if (self.current != null and self.current.? == i) .current_match else .match;
            var line = @max(m.line, top);
            const last_vis = top + @as(i64, rows) - 1;
            while (line <= @min(m.end_line, last_vis)) : (line += 1) {
                const row: usize = @intCast(line - top);
                var c: u16 = if (line == m.line) m.start else 0;
                const last: u16 = if (line == m.end_line) m.end else cols - 1;
                while (c <= last and c < cols) : (c += 1) marks[row * @as(usize, cols) + c] = mk;
            }
        }
    }

    fn submit(self: *Bar) Effect {
        const q = &(self.query orelse return .consumed);
        if (std.mem.trim(u8, q.items, " \t").len == 0) return .consumed;
        self.pending_submit = true;
        self.phase = .wait;
        self.offline = false;
        if (self.matches) |*m| m.clearRetainingCapacity();
        self.current = null;
        return .submit;
    }

    fn jump(self: *Bar, older: bool) Effect {
        const ms = &(self.matches orelse return .consumed);
        self.current = search.step(ms.items, self.current, !older) orelse return .consumed;
        return .{ .jump = ms.items[self.current.?].line };
    }
};

fn deleteLast(buf: *std.ArrayList(u8)) void {
    var n = buf.items.len;
    if (n == 0) return;
    n -= 1;
    while (n > 0 and buf.items[n] & 0xC0 == 0x80) n -= 1;
    buf.items.len = n;
}

test "ask bar submits a question and jumps between matches" {
    var bar = Bar{};
    try bar.open(std.testing.allocator, "last output");
    defer bar.close();
    try std.testing.expect(bar.handleText("why") == .consumed);
    try std.testing.expect(bar.handleKey(.enter, .{}) == .submit);
    try std.testing.expect(bar.pending_submit);
    try std.testing.expectEqual(Phase.wait, bar.phase);
    bar.pending_submit = false;
    const ms = [_]search.Match{
        search.Match.single(2, 0, 3),
        search.Match.single(4, 1, 2),
    };
    try std.testing.expectEqual(@as(?i64, 2), bar.setMatches(&ms));
    const fx = bar.handleKey(.down, .{});
    switch (fx) {
        .jump => |line| try std.testing.expectEqual(@as(i64, 4), line),
        else => return error.Unexpected,
    }
    try std.testing.expectEqual(@as(?usize, 1), bar.current);
    var buf: [160]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, bar.barText(&buf), "2/2") != null);
    try std.testing.expectEqual(Effect.close, bar.handleKey(.escape, .{}));
    try std.testing.expect(bar.pending_cancel);
    try std.testing.expect(!bar.live);
}
