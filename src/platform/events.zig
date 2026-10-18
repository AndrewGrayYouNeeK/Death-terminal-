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
    /// A bound shortcut (see `Bindings`).
    action: ActionEvent,
    /// Clipboard contents requested with `Window.requestClipboard`.
    /// `data` is valid until the next poll.
    paste: Paste,
};

pub const ClipTarget = enum { clipboard, primary };
/// Why the clipboard was read: a user paste, or an OSC 52 query reply.
pub const PastePurpose = enum { paste, osc52 };

pub const Paste = struct {
    data: []const u8,
    target: ClipTarget,
    purpose: PastePurpose,
};

pub const Action = enum {
    none,
    copy,
    paste,
    paste_selection,
    search,
    scroll_page_up,
    scroll_page_down,
    scroll_line_up,
    scroll_line_down,
    scroll_top,
    scroll_bottom,
    zoom_in,
    zoom_out,
    zoom_reset,
    select_all,
    clear_selection,
    /// Re-read config.lua now (it also reloads on save).
    reload_config,
    /// AI ghost text: accept / dismiss / next / previous alternative.
    /// When no suggestion is showing the key goes to the shell as usual.
    ai_accept,
    ai_dismiss,
    ai_next,
    ai_prev,
    /// Ask the AI to explain (and fix) the last failed command.
    ai_explain,

    pub fn parse(name: []const u8) ?Action {
        inline for (@typeInfo(Action).Enum.fields) |f| {
            if (std.mem.eql(u8, name, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }
};

/// A shortcut that fired, with the key that triggered it (so actions that
/// don't apply, e.g. scrolling in the alternate screen, can forward it).
pub const ActionEvent = struct {
    action: Action,
    sym: u32 = 0,
    mods: input.Mods = .{},
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
        action: ActionEvent,
        paste: struct { target: ClipTarget, purpose: PastePurpose },
    };

    items: [cap]Item = undefined,
    head: usize = 0,
    len: usize = 0,
    scratch: [32]u8 = undefined,
    /// Backend-owned buffer behind the newest `paste` item.
    paste_data: []const u8 = &.{},

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

    pub fn pushAction(self: *EventQueue, ev: ActionEvent) void {
        self.push(.{ .action = ev });
    }

    /// Queue clipboard contents. `data` must stay valid until popped (the
    /// backend keeps it in its paste buffer).
    pub fn pushPaste(self: *EventQueue, data: []const u8, target: ClipTarget, purpose: PastePurpose) void {
        self.paste_data = data;
        self.push(.{ .paste = .{ .target = target, .purpose = purpose } });
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
            .action => |a| .{ .action = a },
            .paste => |p| .{ .paste = .{ .data = self.paste_data, .target = p.target, .purpose = p.purpose } },
        };
    }
};

// ------------------------------------------------------------ bindings

pub const Binding = struct {
    sym: u32,
    mods: input.Mods,
    action: Action,
};

/// Keyboard shortcuts, matched by the backends before a key becomes
/// terminal input. Keys are X11/XKB keysyms (Win32 maps its virtual keys
/// onto the same numbers). Letters are matched case-insensitively.
pub const Bindings = struct {
    pub const max = 64;
    items: [max]Binding = undefined,
    len: usize = 0,

    pub const default_specs = [_][]const u8{
        "ctrl+shift+c=copy",
        "ctrl+shift+v=paste",
        "shift+insert=paste_selection",
        "ctrl+shift+f=search",
        "shift+page_up=scroll_page_up",
        "shift+page_down=scroll_page_down",
        "shift+home=scroll_top",
        "shift+end=scroll_bottom",
        "ctrl+shift+up=scroll_line_up",
        "ctrl+shift+down=scroll_line_down",
        "ctrl+shift+alt+a=select_all",
        "ctrl+equal=zoom_in",
        "ctrl+plus=zoom_in",
        "ctrl+shift+plus=zoom_in",
        "ctrl+shift+equal=zoom_in",
        "ctrl+kp_add=zoom_in",
        "ctrl+minus=zoom_out",
        "ctrl+shift+underscore=zoom_out",
        "ctrl+shift+minus=zoom_out",
        "ctrl+kp_subtract=zoom_out",
        "ctrl+0=zoom_reset",
        "ctrl+kp_0=zoom_reset",
        "ctrl+shift+r=reload_config",
        "tab=ai_accept",
        "escape=ai_dismiss",
        "alt+bracketright=ai_next",
        "alt+bracketleft=ai_prev",
        "ctrl+shift+a=ai_explain",
    };

    pub fn defaults() Bindings {
        @setEvalBranchQuota(200_000);
        var b = Bindings{};
        for (default_specs) |spec| b.apply(spec) catch unreachable;
        return b;
    }

    /// Add or replace one "chord=action" binding; "chord=none" unbinds.
    pub fn apply(self: *Bindings, spec: []const u8) !void {
        const eq = std.mem.lastIndexOfScalar(u8, spec, '=') orelse return error.BadBinding;
        // The last '=' separates the action, so "ctrl+==zoom_in" binds '='.
        const chord_s = std.mem.trim(u8, spec[0..eq], " \t");
        const action_s = std.mem.trim(u8, spec[eq + 1 ..], " \t");
        const chord = try parseChord(chord_s);
        const action = Action.parse(action_s) orelse return error.UnknownAction;
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            const it = self.items[i];
            if (it.sym == chord.sym and @as(u3, @bitCast(it.mods)) == @as(u3, @bitCast(chord.mods))) {
                if (action == .none) {
                    self.items[i] = self.items[self.len - 1];
                    self.len -= 1;
                } else self.items[i].action = action;
                return;
            }
        }
        if (action == .none) return;
        if (self.len == max) return error.TooManyBindings;
        self.items[self.len] = .{ .sym = chord.sym, .mods = chord.mods, .action = action };
        self.len += 1;
    }

    pub fn match(self: *const Bindings, sym_in: u32, mods: input.Mods) ?Action {
        const sym = normalizeSym(sym_in);
        const want: u3 = @bitCast(mods);
        for (self.items[0..self.len]) |it| {
            if (it.sym == sym and @as(u3, @bitCast(it.mods)) == want) return it.action;
        }
        return null;
    }
};

/// Process-wide shortcut table; the event loop installs the configured one.
pub var bindings: Bindings = Bindings.defaults();

/// Shortcut lookup used by every backend.
pub fn matchBinding(sym: u32, mods: input.Mods) ?ActionEvent {
    const action = bindings.match(sym, mods) orelse return null;
    return .{ .action = action, .sym = sym, .mods = mods };
}

fn normalizeSym(sym: u32) u32 {
    if (sym >= 'A' and sym <= 'Z') return sym + 32;
    return sym;
}

pub const Chord = struct { sym: u32, mods: input.Mods };

/// Parse "ctrl+shift+c", "shift+page_up", "ctrl+=" ...
pub fn parseChord(text: []const u8) !Chord {
    var mods = input.Mods{};
    var rest = text;
    // A trailing "+" names the plus key itself ("ctrl++").
    var key_name: []const u8 = undefined;
    if (std.mem.endsWith(u8, rest, "++")) {
        key_name = "+";
        rest = rest[0 .. rest.len - 2];
    } else if (std.mem.lastIndexOfScalar(u8, rest, '+')) |i| {
        key_name = rest[i + 1 ..];
        rest = rest[0..i];
    } else {
        key_name = rest;
        rest = "";
    }
    var it = std.mem.tokenizeScalar(u8, rest, '+');
    while (it.next()) |m| {
        if (std.ascii.eqlIgnoreCase(m, "ctrl") or std.ascii.eqlIgnoreCase(m, "control")) {
            mods.ctrl = true;
        } else if (std.ascii.eqlIgnoreCase(m, "shift")) {
            mods.shift = true;
        } else if (std.ascii.eqlIgnoreCase(m, "alt") or std.ascii.eqlIgnoreCase(m, "meta")) {
            mods.alt = true;
        } else return error.UnknownModifier;
    }
    const sym = keyNameToSym(key_name) orelse return error.UnknownKey;
    return .{ .sym = normalizeSym(sym), .mods = mods };
}

const named_keys = [_]struct { []const u8, u32 }{
    .{ "page_up", 0xff55 },   .{ "pageup", 0xff55 },    .{ "prior", 0xff55 },
    .{ "page_down", 0xff56 }, .{ "pagedown", 0xff56 },  .{ "next", 0xff56 },
    .{ "home", 0xff50 },      .{ "end", 0xff57 },       .{ "insert", 0xff63 },
    .{ "delete", 0xffff },    .{ "up", 0xff52 },        .{ "down", 0xff54 },
    .{ "left", 0xff51 },      .{ "right", 0xff53 },     .{ "enter", 0xff0d },
    .{ "return", 0xff0d },    .{ "tab", 0xff09 },       .{ "escape", 0xff1b },
    .{ "esc", 0xff1b },       .{ "backspace", 0xff08 }, .{ "space", 0x20 },
    .{ "equal", '=' },        .{ "plus", '+' },         .{ "minus", '-' },
    .{ "underscore", '_' },   .{ "comma", ',' },        .{ "period", '.' },
    .{ "slash", '/' },        .{ "backslash", '\\' },   .{ "semicolon", ';' },
    .{ "apostrophe", '\'' },  .{ "grave", '`' },        .{ "bracketleft", '[' },
    .{ "bracketright", ']' }, .{ "kp_add", 0xffab },    .{ "kp_subtract", 0xffad },
    .{ "kp_0", 0xffb0 },      .{ "kp_enter", 0xff8d },
};

pub fn keyNameToSym(name: []const u8) ?u32 {
    if (name.len == 1) return name[0];
    for (named_keys) |nk| if (std.ascii.eqlIgnoreCase(name, nk[0])) return nk[1];
    if ((name[0] == 'f' or name[0] == 'F') and name.len <= 3) {
        const n = std.fmt.parseInt(u32, name[1..], 10) catch return null;
        if (n >= 1 and n <= 12) return 0xffbe + n - 1;
    }
    return null;
}

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

test "default bindings and overrides" {
    var b = Bindings.defaults();
    try std.testing.expectEqual(Action.copy, b.match('C', .{ .ctrl = true, .shift = true }).?);
    try std.testing.expectEqual(Action.copy, b.match('c', .{ .ctrl = true, .shift = true }).?);
    try std.testing.expect(b.match('c', .{ .ctrl = true }) == null); // plain Ctrl+C goes to the shell
    try std.testing.expectEqual(Action.zoom_in, b.match('=', .{ .ctrl = true }).?);
    try std.testing.expectEqual(Action.scroll_page_up, b.match(0xff55, .{ .shift = true }).?);
    try std.testing.expectEqual(Action.paste_selection, b.match(0xff63, .{ .shift = true }).?);
    try b.apply("ctrl+shift+c=none");
    try std.testing.expect(b.match('c', .{ .ctrl = true, .shift = true }) == null);
    try b.apply("alt+c=copy");
    try std.testing.expectEqual(Action.copy, b.match('c', .{ .alt = true }).?);
    try b.apply("ctrl++=zoom_in");
    try std.testing.expectEqual(Action.zoom_in, b.match('+', .{ .ctrl = true }).?);
    try b.apply("shift+f5=search");
    try std.testing.expectEqual(Action.search, b.match(0xffc2, .{ .shift = true }).?);
    try std.testing.expectError(error.UnknownAction, b.apply("ctrl+x=launch_missiles"));
    try std.testing.expectError(error.UnknownKey, b.apply("ctrl+nokey=copy"));
}

test "paste events carry the backend buffer" {
    var q = EventQueue{};
    q.pushPaste("clip", .primary, .osc52);
    const p = q.pop().paste;
    try std.testing.expectEqualStrings("clip", p.data);
    try std.testing.expectEqual(ClipTarget.primary, p.target);
    try std.testing.expectEqual(PastePurpose.osc52, p.purpose);
}
