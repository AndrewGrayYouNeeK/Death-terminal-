//! macOS window backend: an NSWindow whose content view hosts a
//! CAMetalLayer (Vulkan via MoltenVK, VK_EXT_metal_surface), with a
//! CoreGraphics fallback for the software renderer.
//!
//! UNTESTED AT RUNTIME: this file is cross-compiled from Linux only. The
//! design keeps the dependency surface small: the Objective-C runtime and
//! frameworks are loaded with dlopen (see objc.zig). There is no
//! NSApplicationDelegate. A runtime NSView subclass is the content view and
//! first responder so Command chords arrive through `performKeyEquivalent:`
//! (AppKit does not deliver those as `keyDown:`). Other events are read
//! straight off the AppKit queue.
//!
//! Waiting: AppKit wants its main thread blocked in
//! nextEventMatchingMask, but the event loop also waits on PTY / wake fds.
//! `wait` hands the fds to a helper thread that poll()s them and posts an
//! application-defined NSEvent when one is ready, so a single blocking
//! call covers both sources and idle CPU stays at zero.

const std = @import("std");
const builtin = @import("builtin");
const events = @import("events.zig");
const Event = events.Event;
const input = @import("../terminal/input.zig");
const io = @import("io.zig");
const objc = @import("objc.zig");
const Id = objc.Id;
const msg = objc.msg;
const posix = std.posix;

const NSEventType = struct {
    const left_down = 1;
    const left_up = 2;
    const right_down = 3;
    const right_up = 4;
    const mouse_moved = 5;
    const left_dragged = 6;
    const right_dragged = 7;
    const key_down = 10;
    const key_up = 11;
    const flags_changed = 12;
    const app_defined = 15;
    const scroll_wheel = 22;
    const other_down = 25;
    const other_up = 26;
    const other_dragged = 27;
};

const Flag = struct {
    const shift: u64 = 1 << 17;
    const control: u64 = 1 << 18;
    const option: u64 = 1 << 19;
    const command: u64 = 1 << 20;
};

/// Subtype marking our own wake-up events.
const wake_subtype: i16 = 0x4454; // "DT"

/// `NSEventMaskAny`. A bare `std.math.maxInt(u64)` is a `comptime_int`,
/// which is erased from the C ABI; the mask must occupy its own register.
const any_event_mask: u64 = @as(u64, std.math.maxInt(u64));

pub const State = struct {
    allocator: std.mem.Allocator = undefined,
    app: Id = null,
    window: Id = null,
    view: Id = null,
    layer: Id = null,
    /// Plain CALayer for software frames (sublayer of `layer`).
    sw_layer: Id = null,
    run_mode: Id = null,
    width: u32 = 0,
    height: u32 = 0,
    scale: f32 = 1.0,
    visible: bool = true,
    key_window: bool = false,
    queue: events.EventQueue = .{},
    held: input.MouseButton = .none,
    scroll_acc: f64 = 0,
    primary_text: ?[]u8 = null,
    paste_buf: std.ArrayListUnmanaged(u8) = .{},
    waiter: ?*Waiter = null,
    /// Last key event already given to the matcher. AppKit can deliver the
    /// same Command chord twice (performKeyEquivalent: and keyDown:).
    key_stamp: f64 = -1,
    key_code: u16 = 0,
    key_seen: bool = false,
    key_taken: bool = false,
    /// Main-menu key equivalents cleared so Hide/Quit cannot swallow Cmd+Shift+letter.
    menu_disarmed: bool = false,
    /// Last mouse event already given to selection. The poll loop and the
    /// view's mouseDown:/mouseDragged:/mouseUp: can both see one NSEvent.
    mouse_stamp: f64 = -1,
    mouse_type: u64 = 0,
    mouse_clicks: i64 = -1,
    mouse_seen: bool = false,
};

/// The one window. View callbacks have no ivar slot (no SDK).
var cocoa_key_state: ?*State = null;

// ------------------------------------------------------------------ waiter

/// Helper thread that poll()s the event loop's fds while the main thread
/// sleeps inside AppKit.
const Waiter = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    /// Main → helper: fds to watch (null = idle). Helper → main: busy flag.
    fds: ?[]io.PollFd = null,
    /// Helper is inside poll() with `fds` (guarded by `mutex`).
    busy: bool = false,
    quit: bool = false,
    stop: io.Wake,
    app: Id,
    thread: std.Thread = undefined,

    fn run(self: *Waiter) void {
        var local: [64]posix.pollfd = undefined;
        while (true) {
            self.mutex.lock();
            while (self.fds == null and !self.quit) self.cond.wait(&self.mutex);
            if (self.quit) {
                self.mutex.unlock();
                return;
            }
            const fds = self.fds.?;
            self.busy = true;
            self.mutex.unlock();

            const n = @min(fds.len, local.len - 1);
            for (fds[0..n], 0..) |f, i| local[i] = .{ .fd = f.fd, .events = f.events, .revents = 0 };
            local[n] = .{ .fd = self.stop.fd(), .events = posix.POLL.IN, .revents = 0 };
            _ = posix.poll(local[0 .. n + 1], -1) catch {};
            if (local[n].revents == 0) {
                postWake(self.app);
                // Don't spin on a ready fd: park until the main thread
                // takes the fds back.
                var p = [_]posix.pollfd{.{ .fd = self.stop.fd(), .events = posix.POLL.IN, .revents = 0 }};
                _ = posix.poll(&p, -1) catch {};
            }
            self.stop.drain();

            self.mutex.lock();
            self.busy = false;
            self.cond.broadcast();
            self.mutex.unlock();
        }
    }

    /// Main thread: stop watching. The stop pipe is only signalled while
    /// the helper is busy, so no stale wake-up leaks into the next round.
    fn reclaim(self: *Waiter) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.fds = null;
        if (!self.busy) return;
        self.stop.signal();
        while (self.busy) self.cond.wait(&self.mutex);
    }
};

fn postWake(app: Id) void {
    const pool = objc.rt.poolPush();
    defer objc.rt.poolPop(pool);
    const ev = msg(Id, objc.class("NSEvent"), "otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:", .{
        @as(u64, NSEventType.app_defined), objc.NSPoint{}, @as(u64, 0), @as(f64, 0), @as(isize, 0), @as(Id, null), wake_subtype, @as(isize, 0), @as(isize, 0),
    });
    msg(void, app, "postEvent:atStart:", .{ ev, objc.NO });
}

// ------------------------------------------------------------------ API

pub fn open(st: *State, allocator: std.mem.Allocator, title: []const u8, width: u32, height: u32, scale: f32) !void {
    if (builtin.os.tag != .macos) return error.UnsupportedPlatform;
    try objc.load();
    st.allocator = allocator;
    const pool = objc.rt.poolPush();
    defer objc.rt.poolPop(pool);

    st.app = msg(Id, objc.class("NSApplication"), "sharedApplication", .{});
    if (st.app == null) return error.NoNSApplication;
    _ = msg(objc.BOOL, st.app, "setActivationPolicy:", .{@as(isize, 0)}); // Regular
    st.run_mode = objc.constant("NSDefaultRunLoopMode");

    const pts_scale: f64 = @max(1.0, scale);
    const rect = objc.NSRect{ .size = .{
        .width = @as(f64, @floatFromInt(width)) / pts_scale,
        .height = @as(f64, @floatFromInt(height)) / pts_scale,
    } };
    const style: u64 = 1 | 2 | 4 | 8; // titled | closable | miniaturizable | resizable
    st.window = msg(Id, objc.alloc("NSWindow"), "initWithContentRect:styleMask:backing:defer:", .{ rect, style, @as(u64, 2), objc.NO });
    if (st.window == null) return error.NoWindow;
    msg(void, st.window, "setReleasedWhenClosed:", .{objc.NO});
    msg(void, st.window, "setAcceptsMouseMovedEvents:", .{objc.YES});
    setTitle(st, title);

    try ensureContentClass();
    const view = msg(Id, objc.alloc("DTContentView"), "initWithFrame:", .{rect});
    if (view == null) return error.NoWindow;
    msg(void, st.window, "setContentView:", .{view});
    st.view = view;
    cocoa_key_state = st;
    st.layer = msg(Id, objc.class("CAMetalLayer"), "layer", .{});
    if (st.layer == null) return error.NoMetalLayer;
    msg(void, st.view, "setLayer:", .{st.layer});
    msg(void, st.view, "setWantsLayer:", .{objc.YES});

    msg(void, st.window, "center", .{});
    msg(void, st.window, "makeKeyAndOrderFront:", .{@as(Id, null)});
    msg(void, st.app, "finishLaunching", .{});
    msg(void, st.app, "activateIgnoringOtherApps:", .{objc.YES});
    disarmMenu(st);
    _ = msg(objc.BOOL, st.window, "makeFirstResponder:", .{st.view});

    syncGeometry(st, false);

    const w = try allocator.create(Waiter);
    errdefer allocator.destroy(w);
    w.* = .{ .stop = try io.Wake.init(), .app = st.app };
    w.thread = try std.Thread.spawn(.{}, Waiter.run, .{w});
    st.waiter = w;
}

pub fn close(st: *State) void {
    if (cocoa_key_state == st) cocoa_key_state = null;
    if (st.waiter) |w| {
        w.reclaim();
        w.mutex.lock();
        w.quit = true;
        w.cond.broadcast();
        w.mutex.unlock();
        w.thread.join();
        w.stop.deinit();
        st.allocator.destroy(w);
        st.waiter = null;
    }
    if (st.window != null) {
        msg(void, st.window, "close", .{});
        objc.release(st.window);
        st.window = null;
    }
    if (st.primary_text) |t| st.allocator.free(t);
    st.primary_text = null;
    st.paste_buf.deinit(st.allocator);
}

/// Block until `fds` are ready, an AppKit event arrives or the timeout
/// passes. Returns the number of ready fds (their revents are filled in).
pub fn wait(st: *State, fds: []io.PollFd, timeout_ms: i32) usize {
    const ready_now = io.poll(fds, 0);
    if (ready_now > 0 or st.queue.len > 0) return ready_now;

    const w = st.waiter orelse return io.poll(fds, timeout_ms);
    w.mutex.lock();
    w.fds = fds;
    w.cond.broadcast();
    w.mutex.unlock();

    {
        const pool = objc.rt.poolPush();
        defer objc.rt.poolPop(pool);
        const until: Id = if (timeout_ms < 0)
            msg(Id, objc.class("NSDate"), "distantFuture", .{})
        else
            msg(Id, objc.class("NSDate"), "dateWithTimeIntervalSinceNow:", .{@as(f64, @floatFromInt(timeout_ms)) / 1000.0});
        disarmMenu(st);
        const ev = msg(Id, st.app, "nextEventMatchingMask:untilDate:inMode:dequeue:", .{ any_event_mask, until, st.run_mode, objc.YES });
        if (ev != null) handleEvent(st, ev);
    }

    w.reclaim();

    syncGeometry(st, true);
    return io.poll(fds, 0);
}

pub fn poll(st: *State) Event {
    if (st.queue.len == 0) pump(st);
    return st.queue.pop();
}

pub fn hasPending(st: *const State) bool {
    return st.queue.len > 0;
}

pub fn setTitle(st: *State, title: []const u8) void {
    if (st.window == null) return;
    const pool = objc.rt.poolPush();
    defer objc.rt.poolPop(pool);
    msg(void, st.window, "setTitle:", .{objc.nsString(title)});
}

pub fn setClipboard(st: *State, target: events.ClipTarget, text: []const u8) void {
    switch (target) {
        .primary => {
            // macOS has no PRIMARY selection; emulate it in-process.
            const copy = st.allocator.dupe(u8, text) catch return;
            if (st.primary_text) |old| st.allocator.free(old);
            st.primary_text = copy;
        },
        .clipboard => {
            const pool = objc.rt.poolPush();
            defer objc.rt.poolPop(pool);
            const pb = msg(Id, objc.class("NSPasteboard"), "generalPasteboard", .{});
            _ = msg(isize, pb, "clearContents", .{});
            _ = msg(objc.BOOL, pb, "setString:forType:", .{ objc.nsString(text), objc.constant("NSPasteboardTypeString") });
        },
    }
}

pub fn requestClipboard(st: *State, target: events.ClipTarget, purpose: events.PastePurpose) void {
    st.paste_buf.clearRetainingCapacity();
    switch (target) {
        .primary => if (st.primary_text) |t| st.paste_buf.appendSlice(st.allocator, t) catch {},
        .clipboard => {
            const pool = objc.rt.poolPush();
            defer objc.rt.poolPop(pool);
            const pb = msg(Id, objc.class("NSPasteboard"), "generalPasteboard", .{});
            const s = msg(Id, pb, "stringForType:", .{objc.constant("NSPasteboardTypeString")});
            st.paste_buf.appendSlice(st.allocator, objc.utf8(s)) catch {};
        },
    }
    st.queue.pushPaste(st.paste_buf.items, target, purpose);
}

/// CAMetalLayer for vkCreateMetalSurfaceEXT.
pub fn metalLayerPtr(st: *const State) ?*anyopaque {
    return st.layer;
}

const CGImageFns = struct {
    colorSpace: *const fn () callconv(.C) ?*anyopaque,
    dataCreate: *const fn (?*anyopaque, [*]const u8, isize) callconv(.C) ?*anyopaque,
    providerCreate: *const fn (?*anyopaque) callconv(.C) ?*anyopaque,
    imageCreate: *const fn (usize, usize, usize, usize, usize, ?*anyopaque, u32, ?*anyopaque, ?*const f64, bool, i32) callconv(.C) ?*anyopaque,
    cfRelease: *const fn (?*anyopaque) callconv(.C) void,
};
var cg_fns: ?CGImageFns = null;

fn cgFns() ?CGImageFns {
    if (cg_fns) |f| return f;
    cg_fns = .{
        .colorSpace = objc.cfn(*const fn () callconv(.C) ?*anyopaque, "CGColorSpaceCreateDeviceRGB") orelse return null,
        .dataCreate = objc.cfn(*const fn (?*anyopaque, [*]const u8, isize) callconv(.C) ?*anyopaque, "CFDataCreate") orelse return null,
        .providerCreate = objc.cfn(*const fn (?*anyopaque) callconv(.C) ?*anyopaque, "CGDataProviderCreateWithCFData") orelse return null,
        .imageCreate = objc.cfn(@TypeOf(@as(CGImageFns, undefined).imageCreate), "CGImageCreate") orelse return null,
        .cfRelease = objc.cfn(*const fn (?*anyopaque) callconv(.C) void, "CFRelease") orelse return null,
    };
    return cg_fns;
}

/// Software renderer path: wrap the frame in a CGImage and make it the
/// contents of a sublayer (pixels are 0x00RRGGBB words).
pub fn presentRgba(st: *State, pixels: []const u32, width: u32, height: u32) void {
    const f = cgFns() orelse return;
    if (st.layer == null or width == 0 or height == 0) return;
    const pool = objc.rt.poolPush();
    defer objc.rt.poolPop(pool);
    if (st.sw_layer == null) {
        st.sw_layer = msg(Id, objc.class("CALayer"), "layer", .{});
        msg(void, st.sw_layer, "setContentsGravity:", .{objc.nsString("topLeft")});
        msg(void, st.layer, "addSublayer:", .{st.sw_layer});
    }
    const bytes = std.mem.sliceAsBytes(pixels[0 .. @as(usize, width) * height]);
    const data = f.dataCreate(null, bytes.ptr, @intCast(bytes.len)) orelse return;
    defer f.cfRelease(data);
    const provider = f.providerCreate(data) orelse return;
    defer f.cfRelease(provider);
    const space = f.colorSpace() orelse return;
    defer f.cfRelease(space);
    const info: u32 = (2 << 12) | 6; // kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst
    const image = f.imageCreate(width, height, 8, 32, @as(usize, width) * 4, space, info, provider, null, false, 0) orelse return;
    defer f.cfRelease(image);

    const tx = objc.class("CATransaction");
    msg(void, tx, "begin", .{});
    msg(void, tx, "setDisableActions:", .{objc.YES});
    const bounds = msg(objc.NSRect, st.view, "bounds", .{});
    msg(void, st.sw_layer, "setFrame:", .{bounds});
    msg(void, st.sw_layer, "setContentsScale:", .{@as(f64, st.scale)});
    msg(void, st.sw_layer, "setContents:", .{@as(Id, image)});
    msg(void, tx, "commit", .{});
}

// ------------------------------------------------------------------ events

fn pump(st: *State) void {
    if (st.app == null) return;
    const pool = objc.rt.poolPush();
    defer objc.rt.poolPop(pool);
    disarmMenu(st);
    const past = msg(Id, objc.class("NSDate"), "distantPast", .{});
    var n: usize = 0;
    while (n < 256) : (n += 1) {
        const ev = msg(Id, st.app, "nextEventMatchingMask:untilDate:inMode:dequeue:", .{ any_event_mask, past, st.run_mode, objc.YES });
        if (ev == null) break;
        handleEvent(st, ev);
    }
    syncGeometry(st, true);
}

/// Pixel size / scale / visibility / focus, pushing events on change.
fn syncGeometry(st: *State, notify: bool) void {
    if (st.window == null) return;
    const scale = msg(f64, st.window, "backingScaleFactor", .{});
    const frame = msg(objc.NSRect, st.view, "frame", .{});
    const s: f32 = @floatCast(@max(1.0, scale));
    const w: u32 = @intFromFloat(@max(1.0, @round(frame.size.width * s)));
    const h: u32 = @intFromFloat(@max(1.0, @round(frame.size.height * s)));
    if (s != st.scale) {
        st.scale = s;
        msg(void, st.layer, "setContentsScale:", .{@as(f64, s)});
    }
    if (w != st.width or h != st.height) {
        st.width = w;
        st.height = h;
        if (notify) st.queue.pushResize(w, h);
    }
    const visible = objc.isTrue(msg(objc.BOOL, st.window, "isVisible", .{}));
    const miniaturized = objc.isTrue(msg(objc.BOOL, st.window, "isMiniaturized", .{}));
    if (st.visible and !visible and !miniaturized) {
        if (notify) st.queue.pushClose();
    }
    st.visible = visible or miniaturized;
    const key = objc.isTrue(msg(objc.BOOL, st.window, "isKeyWindow", .{}));
    if (key != st.key_window) {
        st.key_window = key;
        if (notify) st.queue.pushFocus(key);
    }
}

fn modsOf(flags: u64) input.Mods {
    return .{
        .shift = flags & Flag.shift != 0,
        .ctrl = flags & Flag.control != 0,
        .alt = flags & Flag.option != 0,
    };
}

fn handleEvent(st: *State, ev: Id) void {
    const ty = msg(u64, ev, "type", .{});
    switch (ty) {
        NSEventType.app_defined => {
            if (msg(i16, ev, "subtype", .{}) == wake_subtype) return;
        },
        NSEventType.key_down => {
            if (deliverKey(st, ev, .key_down)) return;
        },
        NSEventType.key_up, NSEventType.flags_changed => return,
        NSEventType.left_down, NSEventType.left_up, NSEventType.right_down, NSEventType.right_up, NSEventType.other_down, NSEventType.other_up, NSEventType.mouse_moved, NSEventType.left_dragged, NSEventType.right_dragged, NSEventType.other_dragged => {
            if (msg(Id, ev, "window", .{}) == st.window and claimMouse(st, ev)) handleMouse(st, ev, ty);
        },
        NSEventType.scroll_wheel => {
            if (msg(Id, ev, "window", .{}) == st.window) handleScroll(st, ev);
        },
        else => {},
    }
    // Everything else (title bar drags, resize, menus) goes to AppKit.
    msg(void, st.app, "sendEvent:", .{ev});
}

const KeyVia = enum { key_down, key_equivalent };

/// One key event, once. `performKeyEquivalent:` and the poll loop can both
/// see a Command chord; the second call returns the first result.
fn deliverKey(st: *State, ev: Id, via: KeyVia) bool {
    const stamp = msg(f64, ev, "timestamp", .{});
    const code = msg(u16, ev, "keyCode", .{});
    if (st.key_seen and stamp == st.key_stamp and code == st.key_code) return st.key_taken;
    // Record before handling. performKeyEquivalent: can re-enter while AppKit
    // hides the app, and the poll loop can see the same event afterwards.
    st.key_seen = true;
    st.key_stamp = stamp;
    st.key_code = code;
    st.key_taken = true;
    const taken = matchKey(st, ev, via);
    st.key_taken = taken;
    return taken;
}

/// Returns true when the key was consumed (not forwarded to AppKit, which
/// would beep for keys no responder handles).
fn matchKey(st: *State, ev: Id, via: KeyVia) bool {
    const flags = msg(u64, ev, "modifierFlags", .{});
    const code = msg(u16, ev, "keyCode", .{});
    const mac = macFlags(flags);
    // `charactersIgnoringModifiers` keeps Shift and, with Control held, is
    // often the C0 control character (Ctrl+H → 0x08). Shortcuts use the
    // virtual key code in that case; see `keysymOf`.
    const chars = objc.utf8(msg(Id, ev, "charactersIgnoringModifiers", .{}));

        if (keysymOf(code, chars)) |sym| {
        if (macStandardEdit(sym, mac)) |action| {
            logCommand(ev, via, mac, sym, @tagName(action));
            st.queue.pushAction(.{ .action = action, .sym = sym, .mods = modsOf(flags) });
            return true;
        }
        const plan = macMatchPlan(sym, chars, mac);
        if (plan.quit) {
            logCommand(ev, via, mac, sym, "quit");
            st.queue.pushClose();
            return true;
        }
        switch (plan.hide) {
            .app => {
                logCommand(ev, via, mac, sym, "hide");
                if (st.app != null) msg(void, st.app, "hide:", .{@as(Id, null)});
                return true;
            },
            .others => {
                logCommand(ev, via, mac, sym, "hide-others");
                if (st.app != null) msg(void, st.app, "hideOtherApplications:", .{@as(Id, null)});
                return true;
            },
            .none => {},
        }
        for (plan.mods) |slot| if (slot) |m| {
            if (events.matchBinding(sym, m)) |a| {
                logCommand(ev, via, mac, sym, @tagName(a.action));
                st.queue.pushAction(a);
                return true;
            }
        };
        // Unmatched Command keys: the menu equivalents were cleared, so
        // returning false lets the poll loop forward the event. Nothing
        // in the menu is waiting for it.
        if (mac.command) {
            logCommand(ev, via, mac, sym, "unbound");
            return false;
        }
    } else if (mac.command) {
        if (commandQuits(chars, flags)) {
            st.queue.pushClose();
            return true;
        }
        return false;
    }

    const mods = modsOf(flags);
    if (keyOf(code)) |key| {
        st.queue.pushKey(key, mods);
        return true;
    }
    if (mods.alt) {
        // Option as Meta: ESC + the unmodified character.
        const raw = objc.utf8(msg(Id, ev, "charactersIgnoringModifiers", .{}));
        st.queue.pushText(raw, true);
        return true;
    }
    const text = objc.utf8(msg(Id, ev, "characters", .{}));
    if (text.len == 0) return true;
    // Function-key private-use characters (U+F700..U+F8FF) have no text.
    if (std.unicode.utf8Decode(text) catch null) |cp| if (cp >= 0xF700 and cp <= 0xF8FF) return true;
    st.queue.pushText(text, false);
    return true;
}

fn logCommand(ev: Id, via: KeyVia, mac: MacFlags, sym: u32, what: []const u8) void {
    if (!mac.command) return;
    if (objc.isTrue(msg(objc.BOOL, ev, "isARepeat", .{}))) return;
    const letter: u8 = if (sym >= 'a' and sym <= 'z') @intCast(sym - 32) else '?';
    std.debug.print("cocoa: {s} {s}{s}{s}{s}{c} -> {s}\n", .{
        if (via == .key_equivalent) "performKeyEquivalent" else "keyDown",
        if (mac.command) "Cmd+" else "",
        if (mac.shift) "Shift+" else "",
        if (mac.option) "Option+" else "",
        if (mac.control) "Ctrl+" else "",
        letter,
        what,
    });
}

fn viewAcceptsFirstResponder(_: Id, _: objc.Sel) callconv(.C) objc.BOOL {
    return objc.YES;
}

/// Command chords are delivered here, not to keyDown:. Cmd+C, Cmd+V and
/// Cmd+A are matched in `macStandardEdit` before any Ctrl+Shift binding.
fn viewKeyEquivalent(_: Id, _: objc.Sel, ev: Id) callconv(.C) objc.BOOL {
    const st = cocoa_key_state orelse return objc.NO;
    if (ev == null) return objc.NO;
    if (msg(u64, ev, "type", .{}) != NSEventType.key_down) return objc.NO;
    if (msg(u64, ev, "modifierFlags", .{}) & Flag.command == 0) return objc.NO;
    return if (deliverKey(st, ev, .key_equivalent)) objc.YES else objc.NO;
}

fn viewKeyDown(_: Id, _: objc.Sel, ev: Id) callconv(.C) void {
    const st = cocoa_key_state orelse return;
    if (ev == null) return;
    _ = deliverKey(st, ev, .key_down);
}

/// AppKit's `sendEvent:` for a mouse-down runs a tracking loop and delivers
/// `mouseDragged:` / `mouseUp:` to the view. Those events never come back
/// out of `nextEventMatchingMask`. Without these methods the drag and the
/// button-up are dropped, so a press starts an inactive selection and
/// nothing highlights.
fn viewMouse(_: Id, _: objc.Sel, ev: Id) callconv(.C) void {
    const st = cocoa_key_state orelse return;
    if (ev == null) return;
    if (!claimMouse(st, ev)) return;
    handleMouse(st, ev, msg(u64, ev, "type", .{}));
}

/// Selectors installed on `DTContentView`. The test below checks this list
/// so a mouse or Command-key method cannot be dropped from the class.
const content_selectors = [_]struct { name: [:0]const u8, types: [:0]const u8 }{
    .{ .name = "acceptsFirstResponder", .types = "c@:" },
    .{ .name = "canBecomeKeyView", .types = "c@:" },
    .{ .name = "keyDown:", .types = "v@:@" },
    .{ .name = "performKeyEquivalent:", .types = "c@:@" },
    .{ .name = "mouseDown:", .types = "v@:@" },
    .{ .name = "mouseDragged:", .types = "v@:@" },
    .{ .name = "mouseUp:", .types = "v@:@" },
    .{ .name = "rightMouseDown:", .types = "v@:@" },
    .{ .name = "rightMouseDragged:", .types = "v@:@" },
    .{ .name = "rightMouseUp:", .types = "v@:@" },
    .{ .name = "otherMouseDown:", .types = "v@:@" },
    .{ .name = "otherMouseDragged:", .types = "v@:@" },
    .{ .name = "otherMouseUp:", .types = "v@:@" },
};

fn contentImp(name: [:0]const u8) *const anyopaque {
    if (std.mem.eql(u8, name, "acceptsFirstResponder") or std.mem.eql(u8, name, "canBecomeKeyView")) return @ptrCast(&viewAcceptsFirstResponder);
    if (std.mem.eql(u8, name, "keyDown:")) return @ptrCast(&viewKeyDown);
    if (std.mem.eql(u8, name, "performKeyEquivalent:")) return @ptrCast(&viewKeyEquivalent);
    return @ptrCast(&viewMouse);
}

var content_class_ready = false;

fn ensureContentClass() !void {
    if (content_class_ready or objc.class("DTContentView") != null) {
        content_class_ready = true;
        return;
    }
    const super = objc.class("NSView");
    if (super == null) return error.NoWindow;
    const cls = objc.allocateClassPair(super, "DTContentView") orelse return error.NoWindow;
    var ok = true;
    for (content_selectors) |m| {
        ok = objc.addMethod(cls, m.name, contentImp(m.name), m.types) and ok;
    }
    objc.registerClassPair(cls);
    if (!ok) return error.NoWindow;
    content_class_ready = true;
}

fn disarmMenu(st: *State) void {
    if (st.menu_disarmed or st.app == null) return;
    const menu = msg(Id, st.app, "mainMenu", .{});
    if (menu == null) return;
    clearMenuKeys(menu, 0);
    st.menu_disarmed = true;
}

fn clearMenuKeys(menu: Id, depth: u8) void {
    if (menu == null or depth > 8) return;
    const n = msg(isize, menu, "numberOfItems", .{});
    var i: isize = 0;
    while (i < n) : (i += 1) {
        const item = msg(Id, menu, "itemAtIndex:", .{i});
        if (item == null) continue;
        msg(void, item, "setKeyEquivalent:", .{objc.nsString("")});
        const sub = msg(Id, item, "submenu", .{});
        if (sub != null) clearMenuKeys(sub, depth + 1);
    }
}

/// True the first time this NSEvent is seen. `timestamp` plus type plus
/// clickCount identifies it; AppKit reuses event objects, so the pointer
/// is not an identity.
fn claimMouse(st: *State, ev: Id) bool {
    const stamp = msg(f64, ev, "timestamp", .{});
    const ty = msg(u64, ev, "type", .{});
    const clicks = msg(i64, ev, "clickCount", .{});
    if (st.mouse_seen and stamp == st.mouse_stamp and ty == st.mouse_type and clicks == st.mouse_clicks) return false;
    st.mouse_seen = true;
    st.mouse_stamp = stamp;
    st.mouse_type = ty;
    st.mouse_clicks = clicks;
    return true;
}

const ViewPixels = struct { x: i32, y: i32, inside: bool };

fn mouseLocation(st: *State, ev: Id) ViewPixels {
    var loc = msg(objc.NSPoint, ev, "locationInWindow", .{});
    if (st.view == null) return .{ .x = 0, .y = 0, .inside = false };
    // Window points include the title bar. The view's own bounds do not.
    loc = msg(objc.NSPoint, st.view, "convertPoint:fromView:", .{ loc, @as(Id, null) });
    const bounds = msg(objc.NSRect, st.view, "bounds", .{});
    return viewPixels(loc.x, loc.y, bounds.size.height, st.scale);
}

/// Flip a view-local point into physical pixels. `inside` is false in the
/// title bar (y above the content view).
fn viewPixels(x_pt: f64, y_pt: f64, height: f64, scale: f64) ViewPixels {
    const s = if (scale < 1) 1 else scale;
    return .{
        .x = @intFromFloat(@floor(x_pt * s)),
        .y = @intFromFloat(@floor((height - y_pt) * s)),
        .inside = y_pt >= 0 and y_pt <= height,
    };
}

fn handleMouse(st: *State, ev: Id, ty: u64) void {
    const loc = mouseLocation(st, ev);
    const x = loc.x;
    const y = loc.y;
    const mods = modsOf(msg(u64, ev, "modifierFlags", .{}));
    const raw_clicks = msg(i64, ev, "clickCount", .{});
    const clicks: u8 = if (raw_clicks <= 0) 1 else if (raw_clicks > 3) 3 else @intCast(raw_clicks);
    const button: input.MouseButton = switch (ty) {
        NSEventType.left_down, NSEventType.left_up, NSEventType.left_dragged => .left,
        NSEventType.right_down, NSEventType.right_up, NSEventType.right_dragged => .right,
        NSEventType.other_down, NSEventType.other_up, NSEventType.other_dragged => .middle,
        else => st.held,
    };
    switch (ty) {
        NSEventType.left_down, NSEventType.right_down, NSEventType.other_down => {
            if (!loc.inside) return; // title bar, or outside the content view
            st.held = button;
            st.queue.pushMouse(.{ .action = .press, .button = button, .x = x, .y = y, .mods = mods, .clicks = clicks });
        },
        NSEventType.left_up, NSEventType.right_up, NSEventType.other_up => {
            st.held = .none;
            st.queue.pushMouse(.{ .action = .release, .button = button, .x = x, .y = y, .mods = mods, .clicks = clicks });
        },
        else => st.queue.pushMouse(.{ .action = .motion, .button = st.held, .x = x, .y = y, .mods = mods }),
    }
}

fn handleScroll(st: *State, ev: Id) void {
    var dy = msg(f64, ev, "scrollingDeltaY", .{});
    // Trackpads report pixels; group them into wheel notches.
    if (objc.isTrue(msg(objc.BOOL, ev, "hasPreciseScrollingDeltas", .{}))) {
        st.scroll_acc += dy;
        if (@abs(st.scroll_acc) < 16) return;
        dy = st.scroll_acc;
        st.scroll_acc = 0;
    }
    if (dy == 0) return;
    const loc = msg(objc.NSPoint, ev, "locationInWindow", .{});
    const frame = msg(objc.NSRect, st.view, "frame", .{});
    const s: f64 = st.scale;
    st.queue.pushMouse(.{
        .action = .press,
        .button = if (dy > 0) .wheel_up else .wheel_down,
        .x = @intFromFloat(@floor(loc.x * s)),
        .y = @intFromFloat(@floor((frame.size.height - loc.y) * s)),
        .mods = modsOf(msg(u64, ev, "modifierFlags", .{})),
    });
}

// ------------------------------------------------------------------ keys

/// macOS virtual key codes (Carbon kVK_*) for non-text keys.
fn keyOf(code: u16) ?input.Key {
    return switch (code) {
        126 => .up,
        125 => .down,
        124 => .right,
        123 => .left,
        115 => .home,
        119 => .end,
        114 => .insert, // Help
        117 => .delete,
        116 => .page_up,
        121 => .page_down,
        122 => .f1,
        120 => .f2,
        99 => .f3,
        118 => .f4,
        96 => .f5,
        97 => .f6,
        98 => .f7,
        100 => .f8,
        101 => .f9,
        109 => .f10,
        103 => .f11,
        111 => .f12,
        36 => .enter,
        48 => .tab,
        51 => .backspace,
        53 => .escape,
        76 => .kp_enter,
        else => null,
    };
}

/// X11 keysym numbering used by the bindings table.
///
/// Printable `chars` win, so a non-US layout still matches the character the
/// user sees. When Control is down, AppKit's `charactersIgnoringModifiers`
/// is a C0 byte (or empty) instead of the letter, and the binding would miss.
/// The ANSI virtual key code is the fallback for that case.
fn keysymOf(code: u16, chars: []const u8) ?u32 {
    const named: ?u32 = switch (code) {
        114 => 0xff63,
        117 => 0xffff,
        116 => 0xff55,
        121 => 0xff56,
        115 => 0xff50,
        119 => 0xff57,
        126 => 0xff52,
        125 => 0xff54,
        123 => 0xff51,
        124 => 0xff53,
        69 => 0xffab, // keypad +
        78 => 0xffad, // keypad -
        82 => 0xffb0, // keypad 0
        122 => 0xffbe,
        120 => 0xffbf,
        99 => 0xffc0,
        118 => 0xffc1,
        96 => 0xffc2,
        97 => 0xffc3,
        98 => 0xffc4,
        100 => 0xffc5,
        101 => 0xffc6,
        109 => 0xffc7,
        103 => 0xffc8,
        111 => 0xffc9,
        else => null,
    };
    if (named) |n| return n;
    if (chars.len == 1) {
        switch (chars[0]) {
            'A'...'Z' => |c| return c + 32,
            'a'...'z', '0'...'9', '=', '-', ',', '.', '/', '+', '_' => |c| return c,
            else => {},
        }
    }
    return ansiKeysym(code);
}

/// Carbon kVK_ANSI_* → the unshifted keysym. US positions; used only when
/// the event text is not a shortcut character (Control held).
fn ansiKeysym(code: u16) ?u32 {
    return switch (code) {
        0x00 => 'a',
        0x01 => 's',
        0x02 => 'd',
        0x03 => 'f',
        0x04 => 'h',
        0x05 => 'g',
        0x06 => 'z',
        0x07 => 'x',
        0x08 => 'c',
        0x09 => 'v',
        0x0B => 'b',
        0x0C => 'q',
        0x0D => 'w',
        0x0E => 'e',
        0x0F => 'r',
        0x10 => 'y',
        0x11 => 't',
        0x12 => '1',
        0x13 => '2',
        0x14 => '3',
        0x15 => '4',
        0x16 => '6',
        0x17 => '5',
        0x18 => '=',
        0x19 => '9',
        0x1A => '7',
        0x1B => '-',
        0x1C => '8',
        0x1D => '0',
        0x1E => ']',
        0x1F => 'o',
        0x20 => 'u',
        0x21 => '[',
        0x22 => 'i',
        0x23 => 'p',
        0x25 => 'l',
        0x26 => 'j',
        0x27 => '\'',
        0x28 => 'k',
        0x29 => ';',
        0x2A => '\\',
        0x2B => ',',
        0x2C => '/',
        0x2D => 'n',
        0x2E => 'm',
        0x2F => '.',
        0x32 => '`',
        else => null,
    };
}

const MacFlags = struct {
    shift: bool = false,
    control: bool = false,
    option: bool = false,
    command: bool = false,
};

fn macFlags(bits: u64) MacFlags {
    return .{
        .shift = bits & Flag.shift != 0,
        .control = bits & Flag.control != 0,
        .option = bits & Flag.option != 0,
        .command = bits & Flag.command != 0,
    };
}

fn macFlagBits(f: MacFlags) u64 {
    var bits: u64 = 0;
    if (f.shift) bits |= Flag.shift;
    if (f.control) bits |= Flag.control;
    if (f.option) bits |= Flag.option;
    if (f.command) bits |= Flag.command;
    return bits;
}

const HideTarget = enum { none, app, others };

const MacPlan = struct {
    quit: bool = false,
    hide: HideTarget = .none,
    mods: [3]?input.Mods = .{ null, null, null },
};

/// Which binding mods a macOS keyDown should try.
///
/// Command is not itself a binding modifier. Without Option it tries
/// Ctrl+Shift, then Ctrl (Cmd+C copies, Cmd+T opens a tab, Cmd+= zooms).
/// Option is tried first as Ctrl+Alt, so Cmd+Option+T is Time Travel and
/// does not take New Tab.
///
/// Bare Cmd+H hides the app and Cmd+Option+H hides the others. Those are
/// not bindings, so Share is Cmd+Shift+H and stop is Cmd+Shift+Option+H.
/// The menu's key equivalents are cleared; hiding is done from here, because
/// a menu item for "h" would also swallow Cmd+Shift+H.
/// G, J and Q also require Shift (Cmd+Q quits; Cmd+Shift+Q asks).
/// With no Command key, the physical Control/Option/Shift set is used.
/// That path matches Ctrl+Shift+H when AppKit delivers the event, because
/// `keysymOf` recovers the letter from the virtual key code.
fn macMatchPlan(sym: u32, chars: []const u8, flags: MacFlags) MacPlan {
    if (!flags.command) {
        return .{ .mods = .{
            .{ .shift = flags.shift, .alt = flags.option, .ctrl = flags.control },
            null,
            null,
        } };
    }
    if (commandQuits(chars, macFlagBits(flags))) return .{ .quit = true };
    // Hide / Hide Others. Shift (or Control) means it is one of our chords.
    if (sym == 'h' and !flags.shift and !flags.control) {
        return .{ .hide = if (flags.option) .others else .app };
    }
    const needs_shift = events.macCommandNeedsShift(sym);
    const command_alts = [2]?input.Mods{
        .{ .ctrl = true, .shift = true },
        .{ .ctrl = true, .shift = flags.shift },
    };
    if (flags.option) {
        var plan = MacPlan{};
        plan.mods[0] = .{ .ctrl = true, .alt = true, .shift = flags.shift };
        if (!(needs_shift and !flags.shift)) {
            plan.mods[1] = command_alts[0];
            plan.mods[2] = .{ .ctrl = true };
        }
        return plan;
    }
    if (needs_shift and !flags.shift) {
        // Cmd+G / Cmd+J / Cmd+Q (quit already returned). Do not invent Shift.
        return .{ .mods = .{ .{ .ctrl = true }, null, null } };
    }
    return .{ .mods = .{
        command_alts[0],
        .{ .ctrl = true },
        command_alts[1],
    } };
}

const KeyDelivery = enum { key_down, key_equivalent, system };

/// Where AppKit delivers the event, and where we have to read it.
/// Command+letter (including Command+Shift+letter) is sent to
/// `performKeyEquivalent:` on the key view and is not delivered as `keyDown:`.
/// Reading only `keyDown:` makes every Cmd shortcut dead. Bare Cmd+H is Hide.
fn keyDelivery(flags: MacFlags, sym: ?u32) KeyDelivery {
    if (!flags.command) return .key_down;
    if (sym) |s| if (s == 'h' and !flags.shift and !flags.control) return .system;
    return .key_equivalent;
}

/// Cmd+Q quits. Shift or Option keeps the key for bindings (Cmd+Shift+Q asks).
fn commandQuits(chars: []const u8, flags: u64) bool {
    if (!std.mem.eql(u8, chars, "q")) return false;
    if (flags & (Flag.shift | Flag.option) != 0) return false;
    return true;
}

test "cocoa: content view takes mouse and Command-key events" {
    const need = [_][]const u8{
        "acceptsFirstResponder",
        "mouseDown:",
        "mouseDragged:",
        "mouseUp:",
        "performKeyEquivalent:",
    };
    for (need) |name| {
        var found = false;
        for (content_selectors) |m| {
            if (std.mem.eql(u8, m.name, name)) found = true;
        }
        try std.testing.expect(found);
    }
}

test "cocoa: view pixels flip Y and apply the backing scale" {
    const p = viewPixels(10, 20, 100, 2);
    try std.testing.expectEqual(@as(i32, 20), p.x);
    try std.testing.expectEqual(@as(i32, 160), p.y);
    try std.testing.expect(p.inside);
    const title = viewPixels(0, 120, 100, 1);
    try std.testing.expect(!title.inside);
    try std.testing.expect(title.y < 0);
}

test "cocoa: Cmd+Q quits; Cmd+Shift+Q does not" {
    try std.testing.expect(commandQuits("q", Flag.command));
    try std.testing.expect(commandQuits("q", Flag.command | Flag.control));
    try std.testing.expect(!commandQuits("q", Flag.command | Flag.shift));
    try std.testing.expect(!commandQuits("q", Flag.command | Flag.option));
    try std.testing.expect(!commandQuits("w", Flag.command));
}

const MacHit = struct { quit: bool = false, action: ?events.Action = null };

/// Bare Command (and Command+Shift) for the Edit menu. These are not
/// "try Ctrl+Shift first": Cmd+C copies, Cmd+V pastes, Cmd+A selects all
/// even when the binding table only has Ctrl+Shift+Alt+A for select-all.
fn macStandardEdit(sym: u32, flags: MacFlags) ?events.Action {
    if (!flags.command or flags.option or flags.control) return null;
    return switch (sym) {
        'c' => .copy,
        'v' => .paste,
        'a' => .select_all,
        else => null,
    };
}

fn resolveMac(b: *const events.Bindings, code: u16, chars: []const u8, flags: MacFlags) MacHit {
    const sym = keysymOf(code, chars) orelse return .{};
    if (macStandardEdit(sym, flags)) |a| return .{ .action = a };
    const plan = macMatchPlan(sym, chars, flags);
    if (plan.quit) return .{ .quit = true };
    for (plan.mods) |slot| if (slot) |m| if (b.match(sym, m)) |a| return .{ .action = a };
    return .{};
}

test "cocoa: key tables" {
    try std.testing.expectEqual(input.Key.up, keyOf(126).?);
    try std.testing.expectEqual(@as(?u32, 'c'), keysymOf(8, "C"));
    try std.testing.expectEqual(@as(?u32, 0xffbe), keysymOf(122, ""));
    // Control held: charactersIgnoringModifiers is the C0 byte, not the letter.
    try std.testing.expectEqual(@as(?u32, 'h'), keysymOf(0x04, "\x08"));
    try std.testing.expectEqual(@as(?u32, 'h'), keysymOf(0x04, ""));
    try std.testing.expectEqual(@as(?u32, 'g'), keysymOf(0x05, "\x07"));
    try std.testing.expectEqual(@as(?u32, 'q'), keysymOf(0x0C, "\x11"));
    try std.testing.expectEqual(@as(?u32, 'j'), keysymOf(0x26, "\x0a"));
    try std.testing.expectEqual(@as(?u32, 't'), keysymOf(0x11, "\x14"));
}

test "cocoa: mac chords for share, ask, and time travel" {
    const b = events.Bindings.defaults();
    const cmd: MacFlags = .{ .command = true };
    const cmd_shift: MacFlags = .{ .command = true, .shift = true };
    const cmd_opt: MacFlags = .{ .command = true, .option = true };
    const cmd_shift_opt: MacFlags = .{ .command = true, .shift = true, .option = true };

    // Cmd+Shift+H shares. Cmd+H is Hide and Cmd+Option+H is Hide Others.
    try std.testing.expectEqual(events.Action.share_pane, resolveMac(&b, 0x04, "H", cmd_shift).action.?);
    try std.testing.expect(resolveMac(&b, 0x04, "h", cmd).action == null);
    try std.testing.expect(!resolveMac(&b, 0x04, "h", cmd).quit);
    try std.testing.expect(resolveMac(&b, 0x04, "h", cmd_opt).action == null);

    // Physical Ctrl+Shift+H: the event text is BS, the key code is H.
    const ctrl_shift: MacFlags = .{ .control = true, .shift = true };
    try std.testing.expectEqual(events.Action.share_pane, resolveMac(&b, 0x04, "\x08", ctrl_shift).action.?);

    try std.testing.expectEqual(events.Action.share_grant, resolveMac(&b, 0x05, "G", cmd_shift).action.?);
    try std.testing.expect(resolveMac(&b, 0x05, "g", cmd).action == null);
    try std.testing.expectEqual(events.Action.share_grant, resolveMac(&b, 0x05, "\x07", .{ .control = true, .shift = true }).action.?);

    try std.testing.expectEqual(events.Action.share_join, resolveMac(&b, 0x26, "J", cmd_shift).action.?);
    try std.testing.expect(resolveMac(&b, 0x26, "j", cmd).action == null);
    try std.testing.expectEqual(events.Action.share_join, resolveMac(&b, 0x26, "\x0a", .{ .control = true, .shift = true }).action.?);

    try std.testing.expectEqual(events.Action.share_stop, resolveMac(&b, 0x04, "H", cmd_shift_opt).action.?);
    const ctrl_shift_opt: MacFlags = .{ .control = true, .shift = true, .option = true };
    try std.testing.expectEqual(events.Action.share_stop, resolveMac(&b, 0x04, "\x08", ctrl_shift_opt).action.?);

    // Cmd+Q quits. Cmd+Shift+Q asks. Cmd+Option+Q is neither.
    const quit = resolveMac(&b, 0x0C, "q", cmd);
    try std.testing.expect(quit.quit);
    try std.testing.expect(quit.action == null);
    const ask = resolveMac(&b, 0x0C, "Q", cmd_shift);
    try std.testing.expect(!ask.quit);
    try std.testing.expectEqual(events.Action.ai_ask, ask.action.?);
    const opt_q = resolveMac(&b, 0x0C, "q", cmd_opt);
    try std.testing.expect(!opt_q.quit);
    try std.testing.expect(opt_q.action == null);
    try std.testing.expectEqual(events.Action.ai_ask, resolveMac(&b, 0x0C, "\x11", .{ .control = true, .shift = true }).action.?);

    // Time Travel is Cmd+Option+T. Cmd+T and Cmd+Shift+T stay New Tab.
    try std.testing.expectEqual(events.Action.time_travel, resolveMac(&b, 0x11, "t", cmd_opt).action.?);
    try std.testing.expectEqual(events.Action.new_tab, resolveMac(&b, 0x11, "t", cmd).action.?);
    try std.testing.expectEqual(events.Action.new_tab, resolveMac(&b, 0x11, "T", cmd_shift).action.?);
    try std.testing.expectEqual(events.Action.time_travel, resolveMac(&b, 0x11, "\x14", .{ .control = true, .option = true }).action.?);
    try std.testing.expectEqual(events.Action.copy, resolveMac(&b, 0x08, "c", cmd).action.?);
    try std.testing.expectEqual(events.Action.paste, resolveMac(&b, 0x09, "v", cmd).action.?);
    try std.testing.expectEqual(events.Action.select_all, resolveMac(&b, 0x00, "a", cmd).action.?);
    // Command+Shift still edits. It is not a different chord from Command.
    try std.testing.expectEqual(events.Action.paste, resolveMac(&b, 0x09, "V", cmd_shift).action.?);
    try std.testing.expectEqual(events.Action.select_all, resolveMac(&b, 0x00, "A", cmd_shift).action.?);
}

test "cocoa: Cmd+Shift+letter reaches the matcher through performKeyEquivalent" {
    const cmd: MacFlags = .{ .command = true };
    const cmd_shift: MacFlags = .{ .command = true, .shift = true };
    const cmd_opt: MacFlags = .{ .command = true, .option = true };
    // AppKit does not send these as keyDown. The view's performKeyEquivalent:
    // must hand them to macMatchPlan.
    try std.testing.expectEqual(KeyDelivery.key_equivalent, keyDelivery(cmd_shift, 'h'));
    try std.testing.expectEqual(KeyDelivery.key_equivalent, keyDelivery(cmd_shift, 'g'));
    try std.testing.expectEqual(KeyDelivery.key_equivalent, keyDelivery(cmd_shift, 'j'));
    try std.testing.expectEqual(KeyDelivery.key_equivalent, keyDelivery(cmd_shift, 'q'));
    try std.testing.expectEqual(KeyDelivery.key_equivalent, keyDelivery(cmd_opt, 't'));
    try std.testing.expectEqual(KeyDelivery.key_equivalent, keyDelivery(cmd, 'c'));
    try std.testing.expectEqual(KeyDelivery.key_equivalent, keyDelivery(cmd, 'v'));
    try std.testing.expectEqual(KeyDelivery.key_equivalent, keyDelivery(cmd, 'a'));
    try std.testing.expectEqual(KeyDelivery.key_equivalent, keyDelivery(cmd, 'q'));
    try std.testing.expectEqual(KeyDelivery.system, keyDelivery(cmd, 'h'));
    try std.testing.expectEqual(KeyDelivery.system, keyDelivery(cmd_opt, 'h'));
    try std.testing.expectEqual(KeyDelivery.key_down, keyDelivery(.{ .control = true, .shift = true }, 'h'));
    try std.testing.expectEqual(KeyDelivery.key_down, keyDelivery(.{}, 'a'));

    const hide = macMatchPlan('h', "h", cmd);
    try std.testing.expectEqual(HideTarget.app, hide.hide);
    try std.testing.expect(hide.mods[0] == null);
    try std.testing.expect(!hide.quit);
    try std.testing.expectEqual(HideTarget.others, macMatchPlan('h', "h", cmd_opt).hide);
    const share = macMatchPlan('h', "H", cmd_shift);
    try std.testing.expectEqual(HideTarget.none, share.hide);
    try std.testing.expect(share.mods[0] != null);

    const b = events.Bindings.defaults();
    try std.testing.expectEqual(events.Action.share_pane, resolveMac(&b, 0x04, "H", cmd_shift).action.?);
    try std.testing.expectEqual(events.Action.share_grant, resolveMac(&b, 0x05, "G", cmd_shift).action.?);
    try std.testing.expectEqual(events.Action.share_join, resolveMac(&b, 0x26, "J", cmd_shift).action.?);
    try std.testing.expectEqual(events.Action.ai_ask, resolveMac(&b, 0x0C, "Q", cmd_shift).action.?);
}
