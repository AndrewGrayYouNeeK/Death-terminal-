//! Encode keyboard, mouse, focus and paste input into the byte sequences an
//! xterm-compatible application expects, honoring the terminal's modes.

const std = @import("std");
const Modes = @import("terminal.zig").Modes;

pub const Key = enum {
    up,
    down,
    right,
    left,
    home,
    end,
    insert,
    delete,
    page_up,
    page_down,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    enter,
    tab,
    backspace,
    escape,
    kp_0,
    kp_1,
    kp_2,
    kp_3,
    kp_4,
    kp_5,
    kp_6,
    kp_7,
    kp_8,
    kp_9,
    kp_decimal,
    kp_divide,
    kp_multiply,
    kp_subtract,
    kp_add,
    kp_enter,
    kp_equal,
};

pub const Mods = packed struct {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,

    pub fn any(self: Mods) bool {
        return self.shift or self.alt or self.ctrl;
    }

    /// xterm modifier parameter: 1 + shift + 2*alt + 4*ctrl.
    pub fn param(self: Mods) u8 {
        return 1 + @as(u8, @intFromBool(self.shift)) + 2 * @as(u8, @intFromBool(self.alt)) + 4 * @as(u8, @intFromBool(self.ctrl));
    }
};

pub const Buf = std.BoundedArray(u8, 32);

fn csiFinal(out: *Buf, mods: Mods, app: bool, final: u8) void {
    if (mods.any()) {
        out.writer().print("\x1b[1;{d}{c}", .{ mods.param(), final }) catch {};
    } else if (app) {
        out.writer().print("\x1bO{c}", .{final}) catch {};
    } else {
        out.writer().print("\x1b[{c}", .{final}) catch {};
    }
}

fn tilde(out: *Buf, mods: Mods, n: u8) void {
    if (mods.any()) {
        out.writer().print("\x1b[{d};{d}~", .{ n, mods.param() }) catch {};
    } else {
        out.writer().print("\x1b[{d}~", .{n}) catch {};
    }
}

/// Encode a non-text key. Returns the bytes to write to the PTY.
pub fn encodeKey(key: Key, mods: Mods, modes: Modes) Buf {
    var out = Buf{};
    const w = out.writer();
    switch (key) {
        .up => csiFinal(&out, mods, modes.app_cursor, 'A'),
        .down => csiFinal(&out, mods, modes.app_cursor, 'B'),
        .right => csiFinal(&out, mods, modes.app_cursor, 'C'),
        .left => csiFinal(&out, mods, modes.app_cursor, 'D'),
        .home => csiFinal(&out, mods, modes.app_cursor, 'H'),
        .end => csiFinal(&out, mods, modes.app_cursor, 'F'),
        .insert => tilde(&out, mods, 2),
        .delete => tilde(&out, mods, 3),
        .page_up => tilde(&out, mods, 5),
        .page_down => tilde(&out, mods, 6),
        // F1-F4 use SS3 unmodified, CSI 1;m P..S modified.
        .f1 => csiFinal(&out, mods, true, 'P'),
        .f2 => csiFinal(&out, mods, true, 'Q'),
        .f3 => csiFinal(&out, mods, true, 'R'),
        .f4 => csiFinal(&out, mods, true, 'S'),
        .f5 => tilde(&out, mods, 15),
        .f6 => tilde(&out, mods, 17),
        .f7 => tilde(&out, mods, 18),
        .f8 => tilde(&out, mods, 19),
        .f9 => tilde(&out, mods, 20),
        .f10 => tilde(&out, mods, 21),
        .f11 => tilde(&out, mods, 23),
        .f12 => tilde(&out, mods, 24),
        .enter => {
            if (mods.alt) w.writeByte(0x1b) catch {};
            w.writeAll(if (modes.newline) "\r\n" else "\r") catch {};
        },
        .tab => w.writeAll(if (mods.shift) "\x1b[Z" else "\t") catch {},
        .backspace => {
            if (mods.alt) w.writeByte(0x1b) catch {};
            w.writeByte(if (mods.ctrl) 0x08 else 0x7f) catch {};
        },
        .escape => w.writeByte(0x1b) catch {},
        else => encodeKeypad(&out, key, mods, modes),
    }
    return out;
}

fn encodeKeypad(out: *Buf, key: Key, mods: Mods, modes: Modes) void {
    const app_final: u8, const text: u8 = switch (key) {
        .kp_0 => .{ 'p', '0' },
        .kp_1 => .{ 'q', '1' },
        .kp_2 => .{ 'r', '2' },
        .kp_3 => .{ 's', '3' },
        .kp_4 => .{ 't', '4' },
        .kp_5 => .{ 'u', '5' },
        .kp_6 => .{ 'v', '6' },
        .kp_7 => .{ 'w', '7' },
        .kp_8 => .{ 'x', '8' },
        .kp_9 => .{ 'y', '9' },
        .kp_decimal => .{ 'n', '.' },
        .kp_divide => .{ 'o', '/' },
        .kp_multiply => .{ 'j', '*' },
        .kp_subtract => .{ 'm', '-' },
        .kp_add => .{ 'k', '+' },
        .kp_enter => .{ 'M', '\r' },
        .kp_equal => .{ 'X', '=' },
        else => return,
    };
    if (modes.app_keypad and !mods.any()) {
        out.writer().print("\x1bO{c}", .{app_final}) catch {};
    } else {
        out.writer().writeByte(text) catch {};
    }
}

/// Text typed on the keyboard (already translated by the platform, so
/// Ctrl+letter arrives as a control byte). Alt prefixes ESC.
pub fn encodeText(text: []const u8, mods: Mods, out: *std.ArrayList(u8)) !void {
    if (mods.alt) try out.append(0x1b);
    try out.appendSlice(text);
}

pub const MouseButton = enum { left, middle, right, none, wheel_up, wheel_down, wheel_left, wheel_right };
pub const MouseAction = enum { press, release, motion };

pub const MouseEvent = struct {
    action: MouseAction,
    button: MouseButton,
    /// 0-based cell coordinates.
    col: u16,
    row: u16,
    mods: Mods = .{},
};

fn isWheel(b: MouseButton) bool {
    return switch (b) {
        .wheel_up, .wheel_down, .wheel_left, .wheel_right => true,
        else => false,
    };
}

/// Encode a mouse event for the active tracking mode, or null if the
/// application didn't ask for it. `button_held` is true while any button is
/// down (needed for ?1002 motion).
pub fn encodeMouse(ev: MouseEvent, modes: Modes, button_held: bool) ?Buf {
    switch (modes.mouse) {
        .off => return null,
        .x10 => if (ev.action != .press or isWheel(ev.button) or ev.button == .none) return null,
        .normal => if (ev.action == .motion) return null,
        .button => if (ev.action == .motion and !button_held) return null,
        .any => {},
    }
    if (ev.action == .release and isWheel(ev.button)) return null;

    var code: u32 = switch (ev.button) {
        .left => 0,
        .middle => 1,
        .right => 2,
        .none => 3,
        .wheel_up => 64,
        .wheel_down => 65,
        .wheel_left => 66,
        .wheel_right => 67,
    };
    if (modes.mouse != .x10) {
        if (ev.mods.shift) code += 4;
        if (ev.mods.alt) code += 8;
        if (ev.mods.ctrl) code += 16;
    }
    if (ev.action == .motion) code += 32;

    var out = Buf{};
    const x = @as(u32, ev.col) + 1;
    const y = @as(u32, ev.row) + 1;
    if (modes.mouse_sgr) {
        const final: u8 = if (ev.action == .release) 'm' else 'M';
        out.writer().print("\x1b[<{d};{d};{d}{c}", .{ code, x, y, final }) catch {};
    } else {
        // Legacy X10 encoding: release has no button identity.
        if (ev.action == .release) code = (code & ~@as(u32, 3)) | 3;
        out.writer().writeAll("\x1b[M") catch {};
        out.writer().writeByte(@intCast(@min(code + 32, 255))) catch {};
        out.writer().writeByte(@intCast(@min(x + 32, 255))) catch {};
        out.writer().writeByte(@intCast(@min(y + 32, 255))) catch {};
    }
    return out;
}

/// ?1004 focus reports.
pub fn encodeFocus(focused: bool, modes: Modes) ?[]const u8 {
    if (!modes.focus_events) return null;
    return if (focused) "\x1b[I" else "\x1b[O";
}

/// Paste text. Newlines become CR (like xterm). With ?2004 the text is
/// wrapped in ESC[200~ ... ESC[201~ and any embedded end marker is removed
/// so pasted data can't break out of the bracket.
pub fn encodePaste(text: []const u8, modes: Modes, out: *std.ArrayList(u8)) !void {
    if (modes.bracketed_paste) try out.appendSlice("\x1b[200~");
    var i: usize = 0;
    while (i < text.len) {
        if (modes.bracketed_paste and std.mem.startsWith(u8, text[i..], "\x1b[201~")) {
            i += 6;
            continue;
        }
        const b = text[i];
        if (b == '\r' and i + 1 < text.len and text[i + 1] == '\n') {
            try out.append('\r');
            i += 2;
            continue;
        }
        try out.append(if (b == '\n') '\r' else b);
        i += 1;
    }
    if (modes.bracketed_paste) try out.appendSlice("\x1b[201~");
}

// ---------------------------------------------------------------- tests

const t = std.testing;

test "cursor keys honor DECCKM and modifiers" {
    var m = Modes{};
    try t.expectEqualStrings("\x1b[A", encodeKey(.up, .{}, m).slice());
    m.app_cursor = true;
    try t.expectEqualStrings("\x1bOA", encodeKey(.up, .{}, m).slice());
    try t.expectEqualStrings("\x1bOH", encodeKey(.home, .{}, m).slice());
    try t.expectEqualStrings("\x1b[1;5C", encodeKey(.right, .{ .ctrl = true }, m).slice());
    try t.expectEqualStrings("\x1b[1;2D", encodeKey(.left, .{ .shift = true }, m).slice());
}

test "tilde and function keys" {
    const m = Modes{};
    try t.expectEqualStrings("\x1b[3~", encodeKey(.delete, .{}, m).slice());
    try t.expectEqualStrings("\x1b[5;5~", encodeKey(.page_up, .{ .ctrl = true }, m).slice());
    try t.expectEqualStrings("\x1bOP", encodeKey(.f1, .{}, m).slice());
    try t.expectEqualStrings("\x1b[1;2Q", encodeKey(.f2, .{ .shift = true }, m).slice());
    try t.expectEqualStrings("\x1b[24~", encodeKey(.f12, .{}, m).slice());
    try t.expectEqualStrings("\x1b[Z", encodeKey(.tab, .{ .shift = true }, m).slice());
    try t.expectEqualStrings("\x7f", encodeKey(.backspace, .{}, m).slice());
    try t.expectEqualStrings("\x1b\x7f", encodeKey(.backspace, .{ .alt = true }, m).slice());
}

test "keypad application mode" {
    var m = Modes{};
    try t.expectEqualStrings("5", encodeKey(.kp_5, .{}, m).slice());
    m.app_keypad = true;
    try t.expectEqualStrings("\x1bOu", encodeKey(.kp_5, .{}, m).slice());
    try t.expectEqualStrings("\x1bOM", encodeKey(.kp_enter, .{}, m).slice());
}

test "enter honors LNM" {
    var m = Modes{};
    try t.expectEqualStrings("\r", encodeKey(.enter, .{}, m).slice());
    m.newline = true;
    try t.expectEqualStrings("\r\n", encodeKey(.enter, .{}, m).slice());
}

test "alt text prefixes ESC" {
    var out = std.ArrayList(u8).init(t.allocator);
    defer out.deinit();
    try encodeText("x", .{ .alt = true }, &out);
    try t.expectEqualStrings("\x1bx", out.items);
}

test "mouse off and x10" {
    var m = Modes{};
    const press = MouseEvent{ .action = .press, .button = .left, .col = 0, .row = 0 };
    try t.expect(encodeMouse(press, m, false) == null);
    m.mouse = .x10;
    try t.expectEqualStrings("\x1b[M !!", encodeMouse(press, m, false).?.slice());
    try t.expect(encodeMouse(.{ .action = .release, .button = .left, .col = 0, .row = 0 }, m, false) == null);
}

test "mouse normal legacy encoding with release and wheel" {
    var m = Modes{};
    m.mouse = .normal;
    try t.expectEqualStrings("\x1b[M\x22\x2a\x25", encodeMouse(.{ .action = .press, .button = .right, .col = 9, .row = 4 }, m, false).?.slice());
    try t.expectEqualStrings("\x1b[M\x23\x2a\x25", encodeMouse(.{ .action = .release, .button = .right, .col = 9, .row = 4 }, m, false).?.slice());
    try t.expectEqualStrings("\x1b[M`!!", encodeMouse(.{ .action = .press, .button = .wheel_up, .col = 0, .row = 0 }, m, false).?.slice());
    try t.expect(encodeMouse(.{ .action = .motion, .button = .left, .col = 1, .row = 1 }, m, true) == null);
}

test "mouse SGR encoding, modifiers, motion modes" {
    var m = Modes{};
    m.mouse = .button;
    m.mouse_sgr = true;
    try t.expectEqualStrings("\x1b[<0;300;2M", encodeMouse(.{ .action = .press, .button = .left, .col = 299, .row = 1 }, m, false).?.slice());
    try t.expectEqualStrings("\x1b[<0;300;2m", encodeMouse(.{ .action = .release, .button = .left, .col = 299, .row = 1 }, m, false).?.slice());
    try t.expectEqualStrings("\x1b[<20;1;1M", encodeMouse(.{ .action = .press, .button = .left, .col = 0, .row = 0, .mods = .{ .shift = true, .ctrl = true } }, m, false).?.slice());
    try t.expect(encodeMouse(.{ .action = .motion, .button = .none, .col = 2, .row = 2 }, m, false) == null);
    try t.expectEqualStrings("\x1b[<32;3;3M", encodeMouse(.{ .action = .motion, .button = .left, .col = 2, .row = 2 }, m, true).?.slice());
    m.mouse = .any;
    try t.expectEqualStrings("\x1b[<35;3;3M", encodeMouse(.{ .action = .motion, .button = .none, .col = 2, .row = 2 }, m, false).?.slice());
}

test "focus events" {
    var m = Modes{};
    try t.expect(encodeFocus(true, m) == null);
    m.focus_events = true;
    try t.expectEqualStrings("\x1b[I", encodeFocus(true, m).?);
    try t.expectEqualStrings("\x1b[O", encodeFocus(false, m).?);
}

test "bracketed paste wraps and strips end markers" {
    var m = Modes{};
    var out = std.ArrayList(u8).init(t.allocator);
    defer out.deinit();
    try encodePaste("a\nb\r\nc", m, &out);
    try t.expectEqualStrings("a\rb\rc", out.items);
    out.clearRetainingCapacity();
    m.bracketed_paste = true;
    try encodePaste("ls\x1b[201~rm -rf /\n", m, &out);
    try t.expectEqualStrings("\x1b[200~lsrm -rf /\r\x1b[201~", out.items);
}
