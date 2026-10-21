//! Platform-neutral window events and a small FIFO the backends fill.

const std = @import("std");
const builtin = @import("builtin");
const input = @import("../terminal/input.zig");

pub const KeyPress = struct { key: input.Key, mods: input.Mods };

pub const MouseInput = struct {
    action: input.MouseAction,
    button: input.MouseButton,
    /// Pixel position inside the window (physical pixels).
    x: i32,
    y: i32,
    mods: input.Mods = .{},
    /// 0: the UI counts clicks with its timer (Win32, X11, Wayland).
    /// 1, 2, 3+: the backend's click count (Cocoa `clickCount`).
    clicks: u8 = 0,
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
/// `plugin`: a plugin asked with dt.clipboard.get (needs the clipboard grant).
pub const PastePurpose = enum { paste, osc52, plugin };

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
    /// Ask a question about the last command's output, the selection, or the screen.
    ai_ask,
    /// SSH palette: profiles (open in a new window), and this session's
    /// forwards (toggle) and reconnect.
    ssh_palette,
    /// Command palette: built-in actions and plugin commands.
    command_palette,
    /// Show / hide the status bar (config.status_bar.enabled sets the default).
    toggle_status_bar,
    /// Tabs (docs/TABS.md).
    new_tab,
    close_tab,
    next_tab,
    prev_tab,
    move_tab_left,
    move_tab_right,
    rename_tab,
    toggle_tab_bar,
    goto_tab_1,
    goto_tab_2,
    goto_tab_3,
    goto_tab_4,
    goto_tab_5,
    goto_tab_6,
    goto_tab_7,
    goto_tab_8,
    goto_tab_9,
    /// Split panes.
    split_right,
    split_down,
    close_pane,
    focus_left,
    focus_right,
    focus_up,
    focus_down,
    next_pane,
    prev_pane,
    resize_left,
    resize_right,
    resize_up,
    resize_down,
    zoom_pane,
    equalize_panes,
    /// Rewind the working tree to just before a command in this session.
    time_travel,
    /// A plugin keybinding (ActionEvent.arg = the binding's id). Not
    /// bindable from config.
    plugin_binding,
    /// Shared Haunting (docs/SHARING.md).
    share_pane,
    share_grant,
    share_kick,
    share_stop,
    share_join,
    /// Copy the current invite (address, port, and code) to the clipboard.
    /// Palette only; the invite is already copied when sharing starts.
    share_copy,

    /// goto_tab_N -> N-1.
    pub fn gotoIndex(self: Action) ?usize {
        const lo = @intFromEnum(Action.goto_tab_1);
        const v = @intFromEnum(self);
        if (v < lo or v > @intFromEnum(Action.goto_tab_9)) return null;
        return v - lo;
    }

    /// Label in the command palette (null = not listed there).
    pub fn title(self: Action) ?[]const u8 {
        return switch (self) {
            .copy => "Copy selection",
            .paste => "Paste",
            .paste_selection => "Paste primary selection",
            .search => "Find in scrollback",
            .scroll_page_up => "Scroll up a page",
            .scroll_page_down => "Scroll down a page",
            .scroll_line_up => "Scroll up a line",
            .scroll_line_down => "Scroll down a line",
            .scroll_top => "Scroll to the top",
            .scroll_bottom => "Scroll to the bottom",
            .zoom_in => "Zoom in",
            .zoom_out => "Zoom out",
            .zoom_reset => "Reset zoom",
            .select_all => "Select all",
            .clear_selection => "Clear selection",
            .reload_config => "Reload config",
            .ai_explain => "AI: explain the last failed command",
            .ai_ask => "AI: ask about the output",
            .ssh_palette => "SSH: profiles and forwards",
            .toggle_status_bar => "Toggle status bar",
            .new_tab => "Tabs: new tab",
            .close_tab => "Tabs: close tab",
            .next_tab => "Tabs: next tab",
            .prev_tab => "Tabs: previous tab",
            .move_tab_left => "Tabs: move tab left",
            .move_tab_right => "Tabs: move tab right",
            .rename_tab => "Tabs: rename tab",
            .toggle_tab_bar => "Tabs: show / hide the tab bar",
            .split_right => "Panes: split right",
            .split_down => "Panes: split down",
            .close_pane => "Panes: close pane",
            .focus_left => "Panes: focus left",
            .focus_right => "Panes: focus right",
            .focus_up => "Panes: focus up",
            .focus_down => "Panes: focus down",
            .next_pane => "Panes: next pane",
            .prev_pane => "Panes: previous pane",
            .resize_left => "Panes: grow / shrink left",
            .resize_right => "Panes: grow / shrink right",
            .resize_up => "Panes: grow / shrink up",
            .resize_down => "Panes: grow / shrink down",
            .zoom_pane => "Panes: zoom (toggle)",
            .equalize_panes => "Panes: equalize sizes",
            .time_travel => "Time Travel: rewind the working tree",
            .share_pane => "Share: share this pane",
            .share_grant => "Share: grant or revoke guest control",
            .share_kick => "Share: kick the guest",
            .share_stop => "Share: stop sharing",
            .share_join => "Share: join a haunting",
            .share_copy => "Share: copy invite",
            // Listed as "Go to tab N: <title>" entries instead.
            .goto_tab_1, .goto_tab_2, .goto_tab_3, .goto_tab_4, .goto_tab_5, .goto_tab_6, .goto_tab_7, .goto_tab_8, .goto_tab_9 => null,
            .none, .ai_accept, .ai_dismiss, .ai_next, .ai_prev, .command_palette, .plugin_binding => null,
        };
    }

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
    /// Extra data (plugin binding id).
    arg: u16 = 0,
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
    arg: u16 = 0,
};

/// Keyboard shortcuts, matched by the backends before a key becomes
/// terminal input. Keys are X11/XKB keysyms (Win32 maps its virtual keys
/// onto the same numbers). Letters are matched case-insensitively.
pub const Bindings = struct {
    pub const max = 128;
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
        "ctrl+shift+q=ai_ask",
        "ctrl+shift+s=ssh_palette",
        "ctrl+shift+p=command_palette",
        "ctrl+shift+b=toggle_status_bar",
        "ctrl+shift+t=new_tab",
        // Ctrl+Shift+T is New Tab. On macOS, Command without Option is tried as
        // Ctrl+Shift first, so Cmd+T and Cmd+Shift+T are both New Tab. Time
        // Travel is Ctrl+Alt+T (Cmd+Option+T) so it does not take that chord.
        // Share stays Ctrl+Shift+H here; the Mac press is Cmd+Shift+H, because
        // bare Cmd+H is Hide and is not translated (see cocoa_backend.zig).
        "ctrl+alt+t=time_travel",
        "ctrl+shift+alt+w=close_tab",
        "ctrl+page_down=next_tab",
        "ctrl+tab=next_tab",
        "ctrl+page_up=prev_tab",
        "ctrl+shift+tab=prev_tab",
        "ctrl+shift+page_up=move_tab_left",
        "ctrl+shift+page_down=move_tab_right",
        "ctrl+shift+alt+r=rename_tab",
        "alt+1=goto_tab_1",
        "alt+2=goto_tab_2",
        "alt+3=goto_tab_3",
        "alt+4=goto_tab_4",
        "alt+5=goto_tab_5",
        "alt+6=goto_tab_6",
        "alt+7=goto_tab_7",
        "alt+8=goto_tab_8",
        "alt+9=goto_tab_9",
        "ctrl+shift+e=split_right",
        "ctrl+shift+o=split_down",
        "ctrl+shift+w=close_pane",
        "alt+left=focus_left",
        "alt+right=focus_right",
        "alt+up=focus_up",
        "alt+down=focus_down",
        "alt+shift+left=resize_left",
        "alt+shift+right=resize_right",
        "alt+shift+up=resize_up",
        "alt+shift+down=resize_down",
        "ctrl+shift+z=zoom_pane",
        "ctrl+shift+alt+e=equalize_panes",
        "ctrl+shift+h=share_pane",
        "ctrl+shift+g=share_grant",
        "f12=share_kick",
        "ctrl+shift+alt+h=share_stop",
        "ctrl+shift+j=share_join",
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
        if (action == .plugin_binding) return error.UnknownAction;
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
        const b = self.find(sym_in, mods) orelse return null;
        return b.action;
    }

    pub fn find(self: *const Bindings, sym_in: u32, mods: input.Mods) ?Binding {
        const sym = normalizeSym(sym_in);
        const want: u3 = @bitCast(mods);
        for (self.items[0..self.len]) |it| {
            if (it.sym == sym and @as(u3, @bitCast(it.mods)) == want) return it;
        }
        return null;
    }

    /// Whether `chord` is bound (to anything).
    pub fn has(self: *const Bindings, chord: Chord) bool {
        return self.find(chord.sym, chord.mods) != null;
    }

    /// Add a plugin binding (never replaces an existing one).
    pub fn addPlugin(self: *Bindings, chord: Chord, id: u16) bool {
        if (self.has(chord) or self.len == max) return false;
        self.items[self.len] = .{ .sym = chord.sym, .mods = chord.mods, .action = .plugin_binding, .arg = id };
        self.len += 1;
        return true;
    }
};

/// Process-wide shortcut table; the event loop installs the configured one.
pub var bindings: Bindings = Bindings.defaults();

/// Shortcut lookup used by every backend.
pub fn matchBinding(sym: u32, mods: input.Mods) ?ActionEvent {
    const b = bindings.find(sym, mods) orelse return null;
    return .{ .action = b.action, .arg = b.arg, .sym = sym, .mods = mods };
}

fn normalizeSym(sym: u32) u32 {
    if (sym >= 'A' and sym <= 'Z') return sym + 32;
    if (sym == 0xfe20) return 0xff09; // ISO_Left_Tab = Shift+Tab
    return sym;
}

pub const Chord = struct { sym: u32, mods: input.Mods };

fn writeChordKey(w: anytype, sym: u32) void {
    const pretty = [_]struct { u32, []const u8 }{
        .{ 0xff55, "PgUp" },   .{ 0xff56, "PgDn" },      .{ 0xff50, "Home" },  .{ 0xff57, "End" },
        .{ 0xff63, "Insert" }, .{ 0xffff, "Delete" },    .{ 0xff52, "Up" },    .{ 0xff54, "Down" },
        .{ 0xff51, "Left" },   .{ 0xff53, "Right" },     .{ 0xff0d, "Enter" }, .{ 0xff09, "Tab" },
        .{ 0xff1b, "Esc" },    .{ 0xff08, "Backspace" }, .{ 0x20, "Space" },   .{ 0xffab, "Num+" },
        .{ 0xffad, "Num-" },   .{ 0xffb0, "Num0" },
    };
    for (pretty) |pk| if (pk[0] == sym) {
        w.writeAll(pk[1]) catch {};
        return;
    };
    if (sym >= 0xffbe and sym <= 0xffc9) {
        w.print("F{d}", .{sym - 0xffbe + 1}) catch {};
    } else if (sym > 0x20 and sym < 0x7f) {
        w.writeByte(std.ascii.toUpper(@intCast(sym))) catch {};
    } else w.print("0x{x}", .{sym}) catch {};
}

/// "Ctrl+Shift+P", "Shift+PgUp", "F5".
pub fn formatChord(buf: []u8, sym: u32, mods: input.Mods) []const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    if (mods.ctrl) w.writeAll("Ctrl+") catch {};
    if (mods.alt) w.writeAll("Alt+") catch {};
    if (mods.shift) w.writeAll("Shift+") catch {};
    writeChordKey(w, sym);
    return fbs.getWritten();
}

/// Letters whose Ctrl+Shift binding is Command+Shift on macOS, not bare Command.
/// Cmd+H hides the app, Cmd+Option+H hides the others, and Cmd+Q quits.
/// G and J use the same shape so Share does not sit on Cmd+G (Find Next).
pub fn macCommandNeedsShift(sym: u32) bool {
    const s = if (sym >= 'A' and sym <= 'Z') sym + 32 else sym;
    return s == 'h' or s == 'g' or s == 'j' or s == 'q';
}

/// How `mods` is pressed on macOS. Command stands in for Ctrl. Shift is kept
/// when `macCommandNeedsShift` says bare Command is reserved or a different
/// action (Cmd+Shift+H share, Cmd+Shift+Q ask). Other Ctrl+Shift chords show
/// as Command alone (Cmd+C, Cmd+T), which is the press that reaches them.
pub fn formatMacChord(buf: []u8, sym: u32, mods: input.Mods) []const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    var shift = mods.shift;
    if (mods.ctrl and mods.shift and !mods.alt and !macCommandNeedsShift(sym)) shift = false;
    if (mods.ctrl) w.writeAll("Cmd+") catch {};
    if (shift) w.writeAll("Shift+") catch {};
    if (mods.alt) w.writeAll("Option+") catch {};
    writeChordKey(w, sym);
    return fbs.getWritten();
}

/// The first chord bound to `action` in `b`, formatted.
pub fn chordFor(b: *const Bindings, action: Action, buf: []u8) ?[]const u8 {
    for (b.items[0..b.len]) |it| if (it.action == action) return formatChord(buf, it.sym, it.mods);
    return null;
}

/// Chord shown in the palette and other on-screen hints. macOS builds use
/// the keys that reach the app (`formatMacChord`).
pub fn chordLabel(b: *const Bindings, action: Action, buf: []u8) ?[]const u8 {
    for (b.items[0..b.len]) |it| if (it.action == action) {
        if (comptime builtin.os.tag == .macos) return formatMacChord(buf, it.sym, it.mods);
        return formatChord(buf, it.sym, it.mods);
    };
    return null;
}

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
    try std.testing.expectEqual(Action.new_tab, b.match('t', .{ .ctrl = true, .shift = true }).?);
    try std.testing.expectEqual(Action.time_travel, b.match('t', .{ .ctrl = true, .alt = true }).?);
    try std.testing.expectEqual(Action.ai_ask, b.match('q', .{ .ctrl = true, .shift = true }).?);
    try std.testing.expectEqual(Action.share_pane, b.match('h', .{ .ctrl = true, .shift = true }).?);
    try std.testing.expectEqual(Action.share_grant, b.match('g', .{ .ctrl = true, .shift = true }).?);
    try std.testing.expectEqual(Action.share_join, b.match('j', .{ .ctrl = true, .shift = true }).?);
    try std.testing.expectEqual(Action.share_stop, b.match('h', .{ .ctrl = true, .shift = true, .alt = true }).?);
    try std.testing.expectEqualStrings("Share: share this pane", Action.share_pane.title().?);
    try std.testing.expectEqualStrings("Share: copy invite", Action.share_copy.title().?);
    try std.testing.expectEqual(Action.ai_ask, b.match('Q', .{ .ctrl = true, .shift = true }).?);
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

test "chord formatting and action titles" {
    var b: [32]u8 = undefined;
    try std.testing.expectEqualStrings("Ctrl+Shift+P", formatChord(&b, 'p', .{ .ctrl = true, .shift = true }));
    try std.testing.expectEqualStrings("Shift+PgUp", formatChord(&b, 0xff55, .{ .shift = true }));
    try std.testing.expectEqualStrings("F5", formatChord(&b, 0xffc2, .{}));
    try std.testing.expectEqualStrings("Cmd+Shift+H", formatMacChord(&b, 'h', .{ .ctrl = true, .shift = true }));
    try std.testing.expectEqualStrings("Cmd+Shift+G", formatMacChord(&b, 'g', .{ .ctrl = true, .shift = true }));
    try std.testing.expectEqualStrings("Cmd+Shift+J", formatMacChord(&b, 'j', .{ .ctrl = true, .shift = true }));
    try std.testing.expectEqualStrings("Cmd+Shift+Q", formatMacChord(&b, 'q', .{ .ctrl = true, .shift = true }));
    try std.testing.expectEqualStrings("Cmd+Shift+Option+H", formatMacChord(&b, 'h', .{ .ctrl = true, .shift = true, .alt = true }));
    try std.testing.expectEqualStrings("Cmd+Option+T", formatMacChord(&b, 't', .{ .ctrl = true, .alt = true }));
    try std.testing.expectEqualStrings("Cmd+C", formatMacChord(&b, 'c', .{ .ctrl = true, .shift = true }));
    try std.testing.expectEqualStrings("Cmd+T", formatMacChord(&b, 't', .{ .ctrl = true, .shift = true }));
    try std.testing.expectEqualStrings("F12", formatMacChord(&b, 0xffc9, .{}));
    const d = Bindings.defaults();
    try std.testing.expectEqualStrings("Ctrl+Shift+P", chordFor(&d, .command_palette, &b).?);
    try std.testing.expectEqualStrings("Ctrl+Shift+H", chordLabel(&d, .share_pane, &b).?);
    try std.testing.expectEqualStrings("Share: share this pane", Action.share_pane.title().?);
    try std.testing.expect(Action.copy.title() != null);
    try std.testing.expect(Action.plugin_binding.title() == null);
    var x = Bindings{};
    try std.testing.expectError(error.UnknownAction, x.apply("ctrl+x=plugin_binding"));
    try std.testing.expect(x.addPlugin(.{ .sym = 'x', .mods = .{ .ctrl = true } }, 7));
    try std.testing.expect(!x.addPlugin(.{ .sym = 'x', .mods = .{ .ctrl = true } }, 8));
    try std.testing.expectEqual(@as(u16, 7), x.find('x', .{ .ctrl = true }).?.arg);
}

test "paste events carry the backend buffer" {
    var q = EventQueue{};
    q.pushPaste("clip", .primary, .osc52);
    const p = q.pop().paste;
    try std.testing.expectEqualStrings("clip", p.data);
    try std.testing.expectEqual(ClipTarget.primary, p.target);
    try std.testing.expectEqual(PastePurpose.osc52, p.purpose);
}
