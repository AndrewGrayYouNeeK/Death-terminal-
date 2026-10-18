//! Platform-neutral window events and a small FIFO the backends fill.

const std = @import("std");
const input = @import("../terminal/input.zig");

pub const KeyPress = struct { key: input.Key, mods: input.Mods };

pub const MouseInput = struct {
    action: input.MouseAction,
    button: input.MouseButton,
    /// Pixel position inside the window (physical pixels).
    x: i32,
    y: i32,
    mods: input.Mods = .{},
};

pub const Event = union(enum) {
    none,
    close,
    redraw,
    resize: struct { width: u32, height: u32 },
    /// Text bytes ready for the PTY (UTF-8 / control bytes, Alt already
    /// encoded as an ESC prefix). Valid until the next poll.
    input: []const u8,
    /// A non-text key; encoded by the event loop according to terminal modes.
    key: KeyPress,
    mouse: MouseInput,
    focus: bool,
};

pub const EventQueue = struct {
    const cap = 256;
    const Item = union(enum) {
        close,
        redraw,
        resize: struct { width: u32, height: u32 },
        text: struct { buf: [32]u8, len: u8 },
        key: KeyPress,
        mouse: MouseInput,
        focus: bool,
    };

    items: [cap]Item = undefined,
    head: usize = 0,
    len: usize = 0,
    scratch: [32]u8 = undefined,

    pub fn push(self: *EventQueue, item: Item) void {
        if (self.len == cap) return; // drop when flooded
        self.items[(self.head + self.len) % cap] = item;
        self.len += 1;
    }

    pub fn pushClose(self: *EventQueue) void {
        self.push(.close);
    }

    pub fn pushRedraw(self: *EventQueue) void {
        self.push(.redraw);
    }

    pub fn pushResize(self: *EventQueue, width: u32, height: u32) void {
        self.push(.{ .resize = .{ .width = width, .height = height } });
    }

    pub fn pushKey(self: *EventQueue, key: input.Key, mods: input.Mods) void {
        self.push(.{ .key = .{ .key = key, .mods = mods } });
    }

    pub fn pushMouse(self: *EventQueue, m: MouseInput) void {
        // Coalesce consecutive motion events.
        if (m.action == .motion and self.len > 0) {
            const last = &self.items[(self.head + self.len - 1) % cap];
            if (last.* == .mouse and last.mouse.action == .motion) {
                last.mouse = m;
                return;
            }
        }
        self.push(.{ .mouse = m });
    }

    pub fn pushFocus(self: *EventQueue, focused: bool) void {
        self.push(.{ .focus = focused });
    }

    /// Queue typed text; `alt` prefixes ESC (meta sends escape).
    pub fn pushText(self: *EventQueue, bytes: []const u8, alt: bool) void {
        if (bytes.len == 0) return;
        var item: Item = .{ .text = .{ .buf = undefined, .len = 0 } };
        var n: usize = 0;
        if (alt) {
            item.text.buf[0] = 0x1b;
            n = 1;
        }
        const take = @min(bytes.len, item.text.buf.len - n);
        @memcpy(item.text.buf[n .. n + take], bytes[0..take]);
        item.text.len = @intCast(n + take);
        self.push(item);
    }

    pub fn pop(self: *EventQueue) Event {
        if (self.len == 0) return .none;
        const item = self.items[self.head];
        self.head = (self.head + 1) % cap;
        self.len -= 1;
        return switch (item) {
            .close => .close,
            .redraw => .redraw,
            .resize => |r| .{ .resize = .{ .width = r.width, .height = r.height } },
            .text => |tx| blk: {
                @memcpy(self.scratch[0..tx.len], tx.buf[0..tx.len]);
                break :blk .{ .input = self.scratch[0..tx.len] };
            },
            .key => |k| .{ .key = k },
            .mouse => |m| .{ .mouse = m },
            .focus => |f| .{ .focus = f },
        };
    }
};

/// Map an X11 / XKB keysym (same numbering) to a terminal key.
pub fn keysymToKey(sym: u32) ?input.Key {
    return switch (sym) {
        0xff52, 0xff97 => .up,
        0xff54, 0xff99 => .down,
        0xff53, 0xff98 => .right,
        0xff51, 0xff96 => .left,
        0xff50, 0xff95 => .home,
        0xff57, 0xff9c => .end,
        0xff55, 0xff9a => .page_up,
        0xff56, 0xff9b => .page_down,
        0xff63, 0xff9e => .insert,
        0xffff, 0xff9f => .delete,
        0xffbe => .f1,
        0xffbf => .f2,
        0xffc0 => .f3,
        0xffc1 => .f4,
        0xffc2 => .f5,
        0xffc3 => .f6,
        0xffc4 => .f7,
        0xffc5 => .f8,
        0xffc6 => .f9,
        0xffc7 => .f10,
        0xffc8 => .f11,
        0xffc9 => .f12,
        0xff0d => .enter,
        0xff09 => .tab,
        0xfe20 => .tab, // ISO_Left_Tab (Shift+Tab)
        0xff08 => .backspace,
        0xff1b => .escape,
        0xff8d => .kp_enter,
        0xffbd => .kp_equal,
        0xffaa => .kp_multiply,
        0xffab => .kp_add,
        0xffad => .kp_subtract,
        0xffae, 0xffac => .kp_decimal,
        0xffaf => .kp_divide,
        0xffb0 => .kp_0,
        0xffb1 => .kp_1,
        0xffb2 => .kp_2,
        0xffb3 => .kp_3,
        0xffb4 => .kp_4,
        0xffb5 => .kp_5,
        0xffb6 => .kp_6,
        0xffb7 => .kp_7,
        0xffb8 => .kp_8,
        0xffb9 => .kp_9,
        else => null,
    };
}

test "event queue preserves order and coalesces motion" {
    var q = EventQueue{};
    q.pushText("ab", true);
    q.pushMouse(.{ .action = .motion, .button = .none, .x = 1, .y = 1 });
    q.pushMouse(.{ .action = .motion, .button = .none, .x = 5, .y = 6 });
    q.pushFocus(false);
    try std.testing.expectEqualStrings("\x1bab", q.pop().input);
    const m = q.pop().mouse;
    try std.testing.expectEqual(@as(i32, 5), m.x);
    try std.testing.expect(!q.pop().focus);
    try std.testing.expect(q.pop() == .none);
}

test "keysym mapping" {
    try std.testing.expectEqual(input.Key.up, keysymToKey(0xff52).?);
    try std.testing.expectEqual(input.Key.kp_5, keysymToKey(0xffb5).?);
    try std.testing.expect(keysymToKey('a') == null);
}
