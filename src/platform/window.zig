const std = @import("std");
const env_mod = @import("env.zig");
const io = @import("io.zig");
const builtin = @import("builtin");
const posix = std.posix;
const dpi = @import("dpi.zig");
const wayland = @import("wayland_backend.zig");
const win32 = @import("win32_backend.zig");
const cocoa = if (builtin.os.tag == .macos) @import("cocoa_backend.zig") else CocoaStub;

/// Keeps AppKit / libobjc references out of non-macOS binaries.
const CocoaStub = struct {
    const State = struct {
        width: u32 = 0,
        height: u32 = 0,
        scale: f32 = 1,
    };
    fn open(_: *State, _: std.mem.Allocator, _: []const u8, _: u32, _: u32, _: f32) !void {
        return error.UnsupportedPlatform;
    }
    fn close(_: *State) void {}
    fn wait(_: *State, fds: []io.PollFd, timeout_ms: i32) usize {
        return io.poll(fds, timeout_ms);
    }
    fn poll(_: *State) Event {
        return .none;
    }
    fn hasPending(_: *const State) bool {
        return false;
    }
    fn setTitle(_: *State, _: []const u8) void {}
    fn setClipboard(_: *State, _: ClipTarget, _: []const u8) void {}
    fn requestClipboard(_: *State, _: ClipTarget, _: PastePurpose) void {}
    fn presentRgba(_: *State, _: []const u32, _: u32, _: u32) void {}
    fn metalLayerPtr(_: *const State) ?*anyopaque {
        return null;
    }
};
const Config = @import("../config/config.zig").Config;
const events = @import("events.zig");
const input = @import("../terminal/input.zig");

const x11 = if (builtin.os.tag == .linux) @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xutil.h");
    @cInclude("X11/keysym.h");
    @cInclude("X11/Xatom.h");
}) else struct {};

pub const Event = events.Event;
pub const MouseInput = events.MouseInput;
pub const ClipTarget = events.ClipTarget;
pub const PastePurpose = events.PastePurpose;

const PendingPaste = struct {
    target: ClipTarget,
    purpose: PastePurpose,
    tried_string: bool = false,
    incr: bool = false,
};

pub const Backend = enum { none, x11, wayland, win32, cocoa };

pub const OpenOptions = struct {
    title: []const u8,
    width: u32,
    height: u32,
    scale: f32 = 0,
    backend: Config.Backend = .auto,
};

/// Native window. Linux prefers Wayland then X11; Windows uses Win32.
pub const Window = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    live: bool,
    backend: Backend,
    scale: f32,
    forced_scale: bool,
    display: ?*anyopaque,
    window: usize,
    gc: if (builtin.os.tag == .linux) x11.GC else ?*anyopaque,
    visual: ?*anyopaque,
    depth: c_uint,
    wm_delete: usize,
    packed_pixels: []u32,
    ximage: ?*anyopaque,
    input_scratch: [8]u8,
    input_len: u8,
    wayland: ?*wayland.State,
    win32: ?*win32.State,
    cocoa: ?*cocoa.State = null,
    queue: events.EventQueue = .{},
    net_wm_name: usize = 0,
    utf8_string: usize = 0,
    // X11 selections (CLIPBOARD / PRIMARY).
    clipboard_atom: usize = 0,
    targets_atom: usize = 0,
    text_atom: usize = 0,
    incr_atom: usize = 0,
    prop_atom: usize = 0,
    /// Text we own for [clipboard, primary].
    owned: [2]?[]u8 = .{ null, null },
    /// Timestamp of the latest user input (ICCCM wants real times).
    last_time: c_ulong = 0,
    paste_buf: std.ArrayListUnmanaged(u8) = .{},
    pending: ?PendingPaste = null,

    pub fn open(allocator: std.mem.Allocator, opts: OpenOptions) !Window {
        const forced = opts.scale >= 1.0;
        var win = Window{
            .allocator = allocator,
            .width = @max(1, opts.width),
            .height = @max(1, opts.height),
            .live = false,
            .backend = .none,
            .scale = if (forced) dpi.normalize(opts.scale) else dpi.detectEnvScale(),
            .forced_scale = forced,
            .display = null,
            .window = 0,
            .gc = if (builtin.os.tag == .linux) undefined else null,
            .visual = null,
            .depth = 24,
            .wm_delete = 0,
            .packed_pixels = &.{},
            .ximage = null,
            .input_scratch = undefined,
            .input_len = 0,
            .wayland = null,
            .win32 = null,
        };

        switch (opts.backend) {
            .wayland => tryOpenWayland(&win, opts.title) catch |err| {
                std.debug.print("  → Wayland unavailable ({s})\n", .{@errorName(err)});
                return win;
            },
            .x11 => tryOpenX11(&win, opts.title) catch |err| {
                std.debug.print("  → X11 unavailable ({s})\n", .{@errorName(err)});
                return win;
            },
            .win32 => tryOpenWin32(&win, opts.title) catch |err| {
                std.debug.print("  → Win32 unavailable ({s})\n", .{@errorName(err)});
                return win;
            },
            .cocoa => tryOpenCocoa(&win, opts.title) catch |err| {
                std.debug.print("  → Cocoa unavailable ({s})\n", .{@errorName(err)});
                return win;
            },
            .auto => {
                if (builtin.os.tag == .windows) {
                    tryOpenWin32(&win, opts.title) catch |err| {
                        std.debug.print("  → Win32 unavailable ({s})\n", .{@errorName(err)});
                        return win;
                    };
                } else if (builtin.os.tag == .macos) {
                    tryOpenCocoa(&win, opts.title) catch |err| {
                        std.debug.print("  → Cocoa unavailable ({s})\n", .{@errorName(err)});
                        return win;
                    };
                } else if (preferWayland()) {
                    tryOpenWayland(&win, opts.title) catch {
                        tryOpenX11(&win, opts.title) catch |err| {
                            std.debug.print("  → GUI backend unavailable ({s})\n", .{@errorName(err)});
                            return win;
                        };
                    };
                } else {
                    tryOpenX11(&win, opts.title) catch {
                        tryOpenWayland(&win, opts.title) catch |err| {
                            std.debug.print("  → GUI backend unavailable ({s})\n", .{@errorName(err)});
                            return win;
                        };
                    };
                }
            },
        }

        return win;
    }

    pub fn deinit(self: *Window) void {
        if (self.packed_pixels.len != 0) {
            self.allocator.free(self.packed_pixels);
            self.packed_pixels = &.{};
        }
        if (self.wayland) |st| {
            wayland.close(st);
            self.allocator.destroy(st);
            self.wayland = null;
        }
        if (self.win32) |st| {
            win32.close(st);
            self.allocator.destroy(st);
            self.win32 = null;
        }
        if (self.cocoa) |st| {
            cocoa.close(st);
            self.allocator.destroy(st);
            self.cocoa = null;
        }
        if (self.backend == .x11) X11.close(self);
        for (&self.owned) |*o| if (o.*) |t| {
            self.allocator.free(t);
            o.* = null;
        };
        self.paste_buf.deinit(self.allocator);
        self.live = false;
        self.backend = .none;
    }

    pub fn isLive(self: *const Window) bool {
        return self.live;
    }

    pub fn connectionFd(self: *const Window) ?io.Fd {
        if (builtin.os.tag != .linux) return null;
        return switch (self.backend) {
            .x11 => X11.connectionFd(self),
            .wayland => if (self.wayland) |st| wayland.connectionFd(st) else null,
            else => null,
        };
    }

    /// Sleep until one of `fds` is ready, a window event arrives or the
    /// timeout passes. X11/Wayland: the connection fd is in `fds`. Win32:
    /// also wakes on window messages. Cocoa: AppKit's queue is waited on
    /// while a helper thread polls `fds`.
    pub fn wait(self: *Window, fds: []io.PollFd, timeout_ms: i32) usize {
        return switch (self.backend) {
            .win32 => io.wait(fds, timeout_ms, true),
            .cocoa => if (self.cocoa) |st| cocoa.wait(st, fds, timeout_ms) else io.poll(fds, timeout_ms),
            else => io.poll(fds, timeout_ms),
        };
    }

    /// True when events are already buffered client-side (Xlib may read
    /// the socket during round trips such as selection calls), so the
    /// caller must not block in poll() on the connection fd.
    pub fn hasPending(self: *Window) bool {
        return switch (self.backend) {
            .x11 => X11.hasPending(self),
            .cocoa => if (self.cocoa) |st| cocoa.hasPending(st) else false,
            .wayland, .win32 => false,
            .none => false,
        } or self.queue.len > 0;
    }

    pub fn poll(self: *Window) Event {
        return switch (self.backend) {
            .x11 => X11.poll(self),
            .wayland => blk: {
                const st = self.wayland orelse break :blk Event.none;
                const ev = wayland.poll(st);
                self.syncWayland(st);
                break :blk ev;
            },
            .win32 => blk: {
                const st = self.win32 orelse break :blk Event.none;
                const ev = win32.poll(st);
                self.syncWin32(st);
                break :blk ev;
            },
            .cocoa => blk: {
                const st = self.cocoa orelse break :blk Event.none;
                const ev = cocoa.poll(st);
                self.syncCocoa(st);
                break :blk ev;
            },
            .none => .none,
        };
    }

    /// Update the window title (UTF-8).
    pub fn setTitle(self: *Window, title: []const u8) void {
        switch (self.backend) {
            .x11 => X11.setTitle(self, title),
            .wayland => if (self.wayland) |st| wayland.setTitle(st, title),
            .win32 => if (self.win32) |st| win32.setTitle(st, title),
            .cocoa => if (self.cocoa) |st| cocoa.setTitle(st, title),
            .none => {},
        }
    }

    /// Put `text` on the clipboard or primary selection.
    pub fn setClipboard(self: *Window, target: ClipTarget, text: []const u8) void {
        switch (self.backend) {
            .x11 => X11.setSelection(self, target, text),
            .wayland => if (self.wayland) |st| wayland.setSelection(st, target, text),
            .win32 => if (self.win32) |st| win32.setClipboard(st, target, text),
            .cocoa => if (self.cocoa) |st| cocoa.setClipboard(st, target, text),
            .none => {},
        }
    }

    /// Ask for the clipboard / primary contents; they arrive later as a
    /// `.paste` event (possibly empty).
    pub fn requestClipboard(self: *Window, target: ClipTarget, purpose: PastePurpose) void {
        switch (self.backend) {
            .x11 => X11.requestSelection(self, target, purpose),
            .wayland => if (self.wayland) |st| wayland.requestSelection(st, target, purpose),
            .win32 => if (self.win32) |st| win32.requestClipboard(st, target, purpose),
            .cocoa => if (self.cocoa) |st| cocoa.requestClipboard(st, target, purpose),
            .none => {},
        }
    }

    pub fn presentRgba(self: *Window, pixels: []const u32, width: u32, height: u32) void {
        switch (self.backend) {
            .x11 => X11.present(self, pixels, width, height),
            .wayland => if (self.wayland) |st| wayland.presentRgba(st, pixels, width, height),
            .win32 => if (self.win32) |st| win32.presentRgba(st, pixels, width, height),
            .cocoa => if (self.cocoa) |st| cocoa.presentRgba(st, pixels, width, height),
            .none => {},
        }
    }

    pub fn x11DisplayPtr(self: *const Window) ?*anyopaque {
        return if (self.backend == .x11) self.display else null;
    }

    pub fn x11WindowId(self: *const Window) usize {
        return if (self.backend == .x11) self.window else 0;
    }

    pub fn waylandDisplayPtr(self: *const Window) ?*anyopaque {
        return if (self.wayland) |st| wayland.displayPtr(st) else null;
    }

    pub fn waylandSurfacePtr(self: *const Window) ?*anyopaque {
        return if (self.wayland) |st| wayland.surfacePtr(st) else null;
    }

    pub fn win32InstancePtr(self: *const Window) ?*anyopaque {
        return if (self.win32) |st| win32.instancePtr(st) else null;
    }

    pub fn win32HwndPtr(self: *const Window) ?*anyopaque {
        return if (self.win32) |st| win32.hwndPtr(st) else null;
    }

    fn syncWayland(self: *Window, st: *wayland.State) void {
        self.width = st.width;
        self.height = st.height;
        if (!self.forced_scale) {
            const compositor = @as(f32, @floatFromInt(@max(@as(u32, 1), st.buffer_scale)));
            self.scale = dpi.normalize(@max(self.scale, compositor));
        }
    }

    /// CAMetalLayer of the Cocoa window (VK_EXT_metal_surface).
    pub fn metalLayerPtr(self: *const Window) ?*anyopaque {
        return if (self.cocoa) |st| cocoa.metalLayerPtr(st) else null;
    }

    fn syncCocoa(self: *Window, st: *cocoa.State) void {
        self.width = st.width;
        self.height = st.height;
        if (!self.forced_scale) self.scale = dpi.normalize(st.scale);
    }

    fn syncWin32(self: *Window, st: *win32.State) void {
        self.width = st.width;
        self.height = st.height;
        if (!self.forced_scale) self.scale = dpi.normalize(@max(self.scale, st.scale));
    }
};

fn preferWayland() bool {
    if (builtin.os.tag != .linux) return false;
    return env_mod.get("WAYLAND_DISPLAY") != null;
}

fn tryOpenWayland(win: *Window, title: []const u8) !void {
    const st = try win.allocator.create(wayland.State);
    errdefer win.allocator.destroy(st);
    st.* = .{};
    try wayland.open(st, win.allocator, title, win.width, win.height);
    win.wayland = st;
    win.backend = .wayland;
    win.live = true;
    win.syncWayland(st);
}

fn tryOpenWin32(win: *Window, title: []const u8) !void {
    const st = try win.allocator.create(win32.State);
    errdefer win.allocator.destroy(st);
    st.* = .{};
    try win32.open(st, win.allocator, title, win.width, win.height, win.scale);
    win.win32 = st;
    win.backend = .win32;
    win.live = true;
    win.syncWin32(st);
}

fn tryOpenCocoa(win: *Window, title: []const u8) !void {
    const st = try win.allocator.create(cocoa.State);
    errdefer win.allocator.destroy(st);
    st.* = .{};
    try cocoa.open(st, win.allocator, title, win.width, win.height, win.scale);
    win.cocoa = st;
    win.backend = .cocoa;
    win.live = true;
    win.syncCocoa(st);
}

fn tryOpenX11(win: *Window, title: []const u8) !void {
    try X11.open(win, title);
}

const X11 = if (builtin.os.tag == .linux) struct {
    fn open(win: *Window, title: []const u8) !void {
        const dpy = x11.XOpenDisplay(null) orelse return error.NoDisplay;
        errdefer _ = x11.XCloseDisplay(dpy);

        if (!win.forced_scale) {
            if (x11Scale(dpy)) |detected| {
                win.scale = dpi.normalize(@max(win.scale, detected));
            }
        }

        const screen = x11.XDefaultScreen(dpy);
        const visual = x11.XDefaultVisual(dpy, screen) orelse return error.NoVisual;
        const depth: c_uint = @intCast(x11.XDefaultDepth(dpy, screen));
        const root = x11.XRootWindow(dpy, screen);
        const black = x11.XBlackPixel(dpy, screen);

        const xwin = x11.XCreateSimpleWindow(
            dpy,
            root,
            0,
            0,
            win.width,
            win.height,
            0,
            black,
            black,
        );
        if (xwin == 0) return error.CreateWindowFailed;

        _ = x11.XSelectInput(dpy, xwin, x11.KeyPressMask | x11.ExposureMask | x11.StructureNotifyMask |
            x11.ButtonPressMask | x11.ButtonReleaseMask | x11.PointerMotionMask | x11.FocusChangeMask | x11.PropertyChangeMask);
        const title_z = try win.allocator.allocSentinel(u8, title.len, 0);
        defer win.allocator.free(title_z);
        @memcpy(title_z, title);
        _ = x11.XStoreName(dpy, xwin, title_z);

        var protocols = [_]x11.Atom{x11.XInternAtom(dpy, "WM_DELETE_WINDOW", 0)};
        _ = x11.XSetWMProtocols(dpy, xwin, &protocols, 1);
        // WM_CLASS matches StartupWMClass in deathterminal.desktop.
        var class_hint = x11.XClassHint{ .res_name = @constCast("deathterminal"), .res_class = @constCast("deathterminal") };
        _ = x11.XSetClassHint(dpy, xwin, &class_hint);

        const gc = x11.XDefaultGC(dpy, screen);
        _ = x11.XMapRaised(dpy, xwin);
        _ = x11.XFlush(dpy);

        const packed_pixels = try win.allocator.alloc(u32, win.width * win.height);
        @memset(packed_pixels, 0);

        win.display = dpy;
        win.window = xwin;
        win.gc = gc;
        win.visual = visual;
        win.depth = depth;
        win.wm_delete = protocols[0];
        win.net_wm_name = x11.XInternAtom(dpy, "_NET_WM_NAME", 0);
        win.utf8_string = x11.XInternAtom(dpy, "UTF8_STRING", 0);
        win.clipboard_atom = x11.XInternAtom(dpy, "CLIPBOARD", 0);
        win.targets_atom = x11.XInternAtom(dpy, "TARGETS", 0);
        win.text_atom = x11.XInternAtom(dpy, "TEXT", 0);
        win.incr_atom = x11.XInternAtom(dpy, "INCR", 0);
        win.prop_atom = x11.XInternAtom(dpy, "DT_SELECTION", 0);
        win.packed_pixels = packed_pixels;
        win.backend = .x11;
        win.live = true;

        std.debug.print("  → X11 window mapped ({d}x{d}) scale={d:.2}\n", .{ win.width, win.height, win.scale });
    }

    fn close(self: *Window) void {
        if (self.ximage) |image| {
            const img: [*c]x11.XImage = @ptrCast(@alignCast(image));
            img.*.data = null;
            self.ximage = null;
        }
        if (self.display) |dpy_ptr| {
            const dpy: *x11.Display = @ptrCast(@alignCast(dpy_ptr));
            if (self.window != 0) {
                _ = x11.XDestroyWindow(dpy, self.window);
                self.window = 0;
            }
            _ = x11.XCloseDisplay(dpy);
            self.display = null;
        }
    }

    fn connectionFd(self: *const Window) ?posix.fd_t {
        const dpy_ptr = self.display orelse return null;
        const dpy: *x11.Display = @ptrCast(@alignCast(dpy_ptr));
        const fd = x11.XConnectionNumber(dpy);
        if (fd < 0) return null;
        return fd;
    }

    fn hasPending(self: *Window) bool {
        const dpy_ptr = self.display orelse return false;
        const dpy: *x11.Display = @ptrCast(@alignCast(dpy_ptr));
        return x11.XEventsQueued(dpy, x11.QueuedAlready) > 0;
    }

    fn poll(self: *Window) Event {
        const dpy_ptr = self.display orelse return .none;
        const dpy: *x11.Display = @ptrCast(@alignCast(dpy_ptr));
        while (x11.XPending(dpy) != 0) {
            var ev: x11.XEvent = undefined;
            _ = x11.XNextEvent(dpy, &ev);
            translate(self, &ev);
        }
        return self.queue.pop();
    }

    fn mods(state: c_uint) input.Mods {
        return .{
            .shift = state & x11.ShiftMask != 0,
            .ctrl = state & x11.ControlMask != 0,
            .alt = state & x11.Mod1Mask != 0,
        };
    }

    fn mouseButton(button: c_uint) ?input.MouseButton {
        return switch (button) {
            1 => .left,
            2 => .middle,
            3 => .right,
            4 => .wheel_up,
            5 => .wheel_down,
            6 => .wheel_left,
            7 => .wheel_right,
            else => null,
        };
    }

    fn translate(self: *Window, ev: *x11.XEvent) void {
        const q = &self.queue;
        switch (ev.type) {
            x11.ClientMessage => {
                if (ev.xclient.data.l[0] == @as(c_long, @intCast(self.wm_delete))) q.pushClose();
            },
            x11.DestroyNotify => q.pushClose(),
            x11.ConfigureNotify => {
                const w: u32 = @intCast(@max(1, ev.xconfigure.width));
                const h: u32 = @intCast(@max(1, ev.xconfigure.height));
                if (w != self.width or h != self.height) {
                    self.width = w;
                    self.height = h;
                    q.pushResize(w, h);
                }
            },
            x11.Expose => q.pushRedraw(),
            x11.FocusIn => q.pushFocus(true),
            x11.FocusOut => q.pushFocus(false),
            x11.SelectionRequest => answerSelectionRequest(self, &ev.xselectionrequest),
            x11.SelectionClear => {
                const t = targetOf(self, ev.xselectionclear.selection) orelse return;
                if (self.owned[@intFromEnum(t)]) |old| self.allocator.free(old);
                self.owned[@intFromEnum(t)] = null;
            },
            x11.SelectionNotify => selectionNotify(self, &ev.xselection),
            x11.PropertyNotify => {
                const pe = &ev.xproperty;
                const pend = self.pending orelse return;
                if (pend.incr and pe.atom == self.prop_atom and pe.state == x11.PropertyNewValue) readIncrChunk(self);
            },
            x11.KeyPress => {
                self.last_time = ev.xkey.time;
                var buf: [32]u8 = undefined;
                var keysym: x11.KeySym = 0;
                const n = x11.XLookupString(&ev.xkey, &buf, buf.len, &keysym, null);
                const m = mods(ev.xkey.state);
                if (events.matchBinding(@intCast(keysym), m)) |a| {
                    q.pushAction(a);
                    return;
                }
                if (events.keysymToKey(@intCast(keysym))) |key| {
                    var km = m;
                    if (keysym == 0xfe20) km.shift = true; // ISO_Left_Tab
                    q.pushKey(key, km);
                    return;
                }
                if (m.ctrl and (keysym == x11.XK_space or keysym == x11.XK_2 or keysym == x11.XK_at)) {
                    q.pushText("\x00", m.alt);
                    return;
                }
                if (n > 0) q.pushText(buf[0..@intCast(n)], m.alt);
            },
            x11.ButtonPress, x11.ButtonRelease => {
                self.last_time = ev.xbutton.time;
                const b = mouseButton(ev.xbutton.button) orelse return;
                q.pushMouse(.{
                    .action = if (ev.type == x11.ButtonPress) .press else .release,
                    .button = b,
                    .x = ev.xbutton.x,
                    .y = ev.xbutton.y,
                    .mods = mods(ev.xbutton.state),
                });
            },
            x11.MotionNotify => {
                const st = ev.xmotion.state;
                const held: input.MouseButton = if (st & x11.Button1Mask != 0)
                    .left
                else if (st & x11.Button2Mask != 0)
                    .middle
                else if (st & x11.Button3Mask != 0)
                    .right
                else
                    .none;
                q.pushMouse(.{ .action = .motion, .button = held, .x = ev.xmotion.x, .y = ev.xmotion.y, .mods = mods(st) });
            },
            else => {},
        }
    }

    // -------------------------------------------------------- selections

    fn selAtom(self: *const Window, t: ClipTarget) x11.Atom {
        return switch (t) {
            .clipboard => self.clipboard_atom,
            .primary => x11.XA_PRIMARY,
        };
    }

    fn targetOf(self: *const Window, atom: x11.Atom) ?ClipTarget {
        if (atom == self.clipboard_atom) return .clipboard;
        if (atom == x11.XA_PRIMARY) return .primary;
        return null;
    }

    fn setSelection(self: *Window, target: ClipTarget, text: []const u8) void {
        const dpy_ptr = self.display orelse return;
        const dpy: *x11.Display = @ptrCast(@alignCast(dpy_ptr));
        const copy = self.allocator.dupe(u8, text) catch return;
        const slot = &self.owned[@intFromEnum(target)];
        if (slot.*) |old| self.allocator.free(old);
        slot.* = copy;
        const atom = selAtom(self, target);
        _ = x11.XSetSelectionOwner(dpy, atom, self.window, self.last_time);
        if (x11.XGetSelectionOwner(dpy, atom) != self.window) {
            self.allocator.free(copy);
            slot.* = null;
        }
        _ = x11.XFlush(dpy);
    }

    fn requestSelection(self: *Window, target: ClipTarget, purpose: PastePurpose) void {
        const dpy_ptr = self.display orelse return;
        const dpy: *x11.Display = @ptrCast(@alignCast(dpy_ptr));
        const atom = selAtom(self, target);
        const owner = x11.XGetSelectionOwner(dpy, atom);
        if (owner == self.window) {
            // Our own selection: no round trip.
            const own = self.owned[@intFromEnum(target)] orelse "";
            self.paste_buf.clearRetainingCapacity();
            self.paste_buf.appendSlice(self.allocator, own) catch return;
            self.queue.pushPaste(self.paste_buf.items, target, purpose);
            return;
        }
        if (owner == 0) {
            self.paste_buf.clearRetainingCapacity();
            self.queue.pushPaste(self.paste_buf.items, target, purpose);
            return;
        }
        self.pending = .{ .target = target, .purpose = purpose };
        _ = x11.XDeleteProperty(dpy, self.window, self.prop_atom);
        _ = x11.XConvertSelection(dpy, atom, self.utf8_string, self.prop_atom, self.window, self.last_time);
        _ = x11.XFlush(dpy);
    }

    fn finishPaste(self: *Window) void {
        const pend = self.pending orelse return;
        self.pending = null;
        self.queue.pushPaste(self.paste_buf.items, pend.target, pend.purpose);
    }

    fn selectionNotify(self: *Window, ev: *x11.XSelectionEvent) void {
        const dpy: *x11.Display = @ptrCast(@alignCast(self.display orelse return));
        var pend = self.pending orelse return;
        self.paste_buf.clearRetainingCapacity();
        if (ev.property == 0) {
            if (!pend.tried_string) {
                // Owner can't do UTF8_STRING; try Latin-1 STRING.
                pend.tried_string = true;
                self.pending = pend;
                _ = x11.XConvertSelection(dpy, ev.selection, x11.XA_STRING, self.prop_atom, self.window, self.last_time);
                _ = x11.XFlush(dpy);
                return;
            }
            return finishPaste(self);
        }
        var actual_type: x11.Atom = 0;
        var format: c_int = 0;
        var nitems: c_ulong = 0;
        var after: c_ulong = 0;
        var data: [*c]u8 = null;
        if (x11.XGetWindowProperty(dpy, self.window, self.prop_atom, 0, 0x7fffffff / 4, 1, x11.AnyPropertyType, &actual_type, &format, &nitems, &after, &data) != x11.Success) {
            return finishPaste(self);
        }
        defer if (data != null) {
            _ = x11.XFree(data);
        };
        if (actual_type == self.incr_atom) {
            // Large transfer: the owner now sends chunks via PropertyNotify
            // (the delete above started it).
            pend.incr = true;
            self.pending = pend;
            return;
        }
        appendProperty(self, actual_type, format, nitems, data);
        finishPaste(self);
    }

    fn readIncrChunk(self: *Window) void {
        const dpy: *x11.Display = @ptrCast(@alignCast(self.display orelse return));
        var actual_type: x11.Atom = 0;
        var format: c_int = 0;
        var nitems: c_ulong = 0;
        var after: c_ulong = 0;
        var data: [*c]u8 = null;
        if (x11.XGetWindowProperty(dpy, self.window, self.prop_atom, 0, 0x7fffffff / 4, 1, x11.AnyPropertyType, &actual_type, &format, &nitems, &after, &data) != x11.Success) {
            return finishPaste(self);
        }
        defer if (data != null) {
            _ = x11.XFree(data);
        };
        if (nitems == 0) return finishPaste(self); // zero-length chunk ends INCR
        appendProperty(self, actual_type, format, nitems, data);
        if (self.paste_buf.items.len > max_paste) finishPaste(self);
    }

    const max_paste = 16 << 20;

    fn appendProperty(self: *Window, actual_type: x11.Atom, format: c_int, nitems: c_ulong, data: [*c]u8) void {
        if (data == null or format != 8) return;
        const bytes = data[0..@intCast(nitems)];
        if (actual_type == x11.XA_STRING) {
            // Latin-1 -> UTF-8.
            for (bytes) |b| {
                var tmp: [2]u8 = undefined;
                const n = std.unicode.utf8Encode(b, &tmp) catch continue;
                self.paste_buf.appendSlice(self.allocator, tmp[0..n]) catch return;
            }
        } else {
            self.paste_buf.appendSlice(self.allocator, bytes) catch return;
        }
    }

    fn answerSelectionRequest(self: *Window, req: *x11.XSelectionRequestEvent) void {
        const dpy: *x11.Display = @ptrCast(@alignCast(self.display orelse return));
        var reply: x11.XEvent = undefined;
        reply.xselection = .{
            .type = x11.SelectionNotify,
            .serial = 0,
            .send_event = 1,
            .display = req.display,
            .requestor = req.requestor,
            .selection = req.selection,
            .target = req.target,
            .property = 0,
            .time = req.time,
        };
        // Obsolete clients pass None; use the target name as property.
        const property = if (req.property == 0) req.target else req.property;
        const t = targetOf(self, req.selection);
        const text: ?[]const u8 = if (t) |tt| self.owned[@intFromEnum(tt)] else null;
        if (text) |txt| {
            if (req.target == self.targets_atom) {
                var atoms = [_]x11.Atom{ self.targets_atom, self.utf8_string, x11.XA_STRING, self.text_atom };
                _ = x11.XChangeProperty(dpy, req.requestor, property, x11.XA_ATOM, 32, x11.PropModeReplace, @ptrCast(&atoms), atoms.len);
                reply.xselection.property = property;
            } else if (req.target == self.utf8_string or req.target == self.text_atom or req.target == x11.XA_STRING) {
                // No INCR on the sending side: refuse what one request can't carry.
                var limit: usize = @intCast(x11.XExtendedMaxRequestSize(dpy));
                if (limit == 0) limit = @intCast(x11.XMaxRequestSize(dpy));
                if (txt.len + 64 < limit * 4) {
                    const typ = if (req.target == x11.XA_STRING) x11.XA_STRING else self.utf8_string;
                    _ = x11.XChangeProperty(dpy, req.requestor, property, typ, 8, x11.PropModeReplace, txt.ptr, @intCast(txt.len));
                    reply.xselection.property = property;
                }
            }
        }
        _ = x11.XSendEvent(dpy, req.requestor, 0, 0, &reply);
        _ = x11.XFlush(dpy);
    }

    fn setTitle(self: *Window, title: []const u8) void {
        const dpy_ptr = self.display orelse return;
        const dpy: *x11.Display = @ptrCast(@alignCast(dpy_ptr));
        if (self.window == 0) return;
        const z = self.allocator.dupeZ(u8, title) catch return;
        defer self.allocator.free(z);
        _ = x11.XStoreName(dpy, self.window, z.ptr);
        if (self.net_wm_name != 0 and self.utf8_string != 0) {
            _ = x11.XChangeProperty(dpy, self.window, self.net_wm_name, self.utf8_string, 8, x11.PropModeReplace, z.ptr, @intCast(title.len));
        }
        _ = x11.XFlush(dpy);
    }

    fn present(self: *Window, pixels: []const u32, width: u32, height: u32) void {
        const dpy_ptr = self.display orelse return;
        const visual_ptr = self.visual orelse return;
        if (self.window == 0) return;
        if (width == 0 or height == 0) return;
        const dpy: *x11.Display = @ptrCast(@alignCast(dpy_ptr));
        const visual: *x11.Visual = @ptrCast(@alignCast(visual_ptr));

        const count = @as(usize, width) * @as(usize, height);
        if (pixels.len < count) return;

        if (self.packed_pixels.len < count) {
            self.allocator.free(self.packed_pixels);
            self.packed_pixels = self.allocator.alloc(u32, count) catch return;
        }

        var i: usize = 0;
        while (i < count) : (i += 1) {
            self.packed_pixels[i] = packPixel(visual, pixels[i]);
        }

        var image: [*c]x11.XImage = if (self.ximage) |img| @ptrCast(@alignCast(img)) else null;
        if (image == null) {
            image = x11.XCreateImage(
                dpy,
                visual,
                self.depth,
                x11.ZPixmap,
                0,
                @ptrCast(self.packed_pixels.ptr),
                width,
                height,
                32,
                @intCast(width * 4),
            ) orelse return;
            self.ximage = image;
        } else {
            image.*.data = @ptrCast(self.packed_pixels.ptr);
            image.*.width = @intCast(width);
            image.*.height = @intCast(height);
            image.*.bytes_per_line = @intCast(width * 4);
        }

        _ = x11.XPutImage(dpy, self.window, self.gc, image, 0, 0, 0, 0, width, height);
        _ = x11.XFlush(dpy);
    }

    fn x11Scale(dpy: *x11.Display) ?f32 {
        const res = x11.XResourceManagerString(dpy) orelse return null;
        return dpi.parseXftDpi(std.mem.span(res));
    }

    fn maskShift(mask: c_ulong) u6 {
        if (mask == 0) return 0;
        var m = mask;
        var shift: u6 = 0;
        while (m & 1 == 0) : (shift += 1) {
            m >>= 1;
        }
        return shift;
    }

    fn packPixel(visual: *x11.Visual, rgb: u32) u32 {
        const r: c_ulong = (rgb >> 16) & 0xFF;
        const g: c_ulong = (rgb >> 8) & 0xFF;
        const b: c_ulong = rgb & 0xFF;
        const r_shift = maskShift(visual.red_mask);
        const g_shift = maskShift(visual.green_mask);
        const b_shift = maskShift(visual.blue_mask);
        return @intCast(((r << r_shift) & visual.red_mask) |
            ((g << g_shift) & visual.green_mask) |
            ((b << b_shift) & visual.blue_mask));
    }
} else struct {
    fn open(_: *Window, _: []const u8) !void {
        return error.UnsupportedPlatform;
    }
    fn close(_: *Window) void {}
    fn connectionFd(_: *const Window) ?posix.fd_t {
        return null;
    }
    fn poll(_: *Window) Event {
        return .none;
    }
    fn hasPending(_: *Window) bool {
        return false;
    }
    fn setTitle(_: *Window, _: []const u8) void {}
    fn setSelection(_: *Window, _: ClipTarget, _: []const u8) void {}
    fn requestSelection(_: *Window, _: ClipTarget, _: PastePurpose) void {}
    fn present(_: *Window, _: []const u32, _: u32, _: u32) void {}
};

test "host links the objc ABI checks" {
    // Keep the arm64 objc_msgSend tests in the host suite. The Cocoa
    // backend is the production referencer; this import covers a
    // `zig test` of this file on its own.
    _ = @import("objc.zig");
}

test "X11 keysyms map through the shared table" {
    if (builtin.os.tag != .linux) return;
    try std.testing.expectEqual(input.Key.up, events.keysymToKey(x11.XK_Up).?);
    try std.testing.expectEqual(input.Key.enter, events.keysymToKey(x11.XK_Return).?);
    try std.testing.expectEqual(input.Key.f5, events.keysymToKey(x11.XK_F5).?);
}

test "Window open is safe without requiring a mapped window" {
    var w = try Window.open(std.testing.allocator, .{
        .title = "DeathTerminalTest",
        .width = 80,
        .height = 48,
        .backend = .x11,
        .scale = 1,
    });
    defer w.deinit();
    _ = w.isLive();
}

test "window backend enum has wayland and win32" {
    try std.testing.expectEqual(Backend.wayland, .wayland);
    try std.testing.expectEqual(Backend.win32, .win32);
}
