const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const dpi = @import("dpi.zig");
const wayland = @import("wayland_backend.zig");
const win32 = @import("win32_backend.zig");
const Config = @import("../config/config.zig").Config;

const x11 = if (builtin.os.tag == .linux) @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xutil.h");
    @cInclude("X11/keysym.h");
}) else struct {};

pub const Event = union(enum) {
    none,
    close,
    redraw,
    resize: struct { width: u32, height: u32 },
    input: []const u8,
};

pub const Backend = enum { none, x11, wayland, win32 };

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
            .auto => {
                if (builtin.os.tag == .windows) {
                    tryOpenWin32(&win, opts.title) catch |err| {
                        std.debug.print("  → Win32 unavailable ({s})\n", .{@errorName(err)});
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
        if (self.backend == .x11) X11.close(self);
        self.live = false;
        self.backend = .none;
    }

    pub fn isLive(self: *const Window) bool {
        return self.live;
    }

    pub fn connectionFd(self: *const Window) ?posix.fd_t {
        return switch (self.backend) {
            .x11 => X11.connectionFd(self),
            .wayland => if (self.wayland) |st| wayland.connectionFd(st) else null,
            else => null,
        };
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
            .none => .none,
        };
    }

    pub fn presentRgba(self: *Window, pixels: []const u32, width: u32, height: u32) void {
        switch (self.backend) {
            .x11 => X11.present(self, pixels, width, height),
            .wayland => if (self.wayland) |st| wayland.presentRgba(st, pixels, width, height),
            .win32 => if (self.win32) |st| win32.presentRgba(st, pixels, width, height),
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

    fn syncWin32(self: *Window, st: *win32.State) void {
        self.width = st.width;
        self.height = st.height;
        if (!self.forced_scale) self.scale = dpi.normalize(@max(self.scale, st.scale));
    }
};

fn preferWayland() bool {
    if (builtin.os.tag != .linux) return false;
    return posix.getenv("WAYLAND_DISPLAY") != null;
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

fn tryOpenX11(win: *Window, title: []const u8) !void {
    try X11.open(win, title);
}

fn keyEscape(keysym: c_ulong) ?[]const u8 {
    if (builtin.os.tag != .linux) return null;
    return X11.keyEscape(keysym);
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

        _ = x11.XSelectInput(dpy, xwin, x11.KeyPressMask | x11.ExposureMask | x11.StructureNotifyMask);
        const title_z = try win.allocator.allocSentinel(u8, title.len, 0);
        defer win.allocator.free(title_z);
        @memcpy(title_z, title);
        _ = x11.XStoreName(dpy, xwin, title_z);

        var protocols = [_]x11.Atom{x11.XInternAtom(dpy, "WM_DELETE_WINDOW", 0)};
        _ = x11.XSetWMProtocols(dpy, xwin, &protocols, 1);

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

    fn poll(self: *Window) Event {
        const dpy_ptr = self.display orelse return .none;
        const dpy: *x11.Display = @ptrCast(@alignCast(dpy_ptr));
        if (x11.XPending(dpy) == 0) return .none;

        var ev: x11.XEvent = undefined;
        _ = x11.XNextEvent(dpy, &ev);

        if (ev.type == x11.ClientMessage) {
            if (ev.xclient.data.l[0] == @as(c_long, @intCast(self.wm_delete))) return .close;
            return .none;
        }
        if (ev.type == x11.DestroyNotify) return .close;
        if (ev.type == x11.ConfigureNotify) {
            const w: u32 = @intCast(ev.xconfigure.width);
            const h: u32 = @intCast(ev.xconfigure.height);
            if (w != self.width or h != self.height) {
                self.width = @max(1, w);
                self.height = @max(1, h);
                return .{ .resize = .{ .width = self.width, .height = self.height } };
            }
            return .none;
        }
        if (ev.type == x11.Expose) {
            return .redraw;
        }
        if (ev.type == x11.KeyPress) {
            var buf: [8]u8 = undefined;
            var keysym: x11.KeySym = 0;
            const n = x11.XLookupString(&ev.xkey, &buf, buf.len, &keysym, null);
            const ctrl = (ev.xkey.state & x11.ControlMask) != 0;
            if (ctrl and (keysym == x11.XK_c or keysym == x11.XK_C)) {
                return .close;
            }
            if (@This().keyEscape(keysym)) |seq| {
                const copy_len = @min(seq.len, self.input_scratch.len);
                @memcpy(self.input_scratch[0..copy_len], seq[0..copy_len]);
                self.input_len = @intCast(copy_len);
                return .{ .input = self.input_scratch[0..self.input_len] };
            }
            if (n > 0) {
                const copy_len: usize = @intCast(n);
                const ncopy = @min(copy_len, self.input_scratch.len);
                @memcpy(self.input_scratch[0..ncopy], buf[0..ncopy]);
                self.input_len = @intCast(ncopy);
                return .{ .input = self.input_scratch[0..self.input_len] };
            }
            return .none;
        }
        return .none;
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

    fn keyEscape(keysym: c_ulong) ?[]const u8 {
        return switch (keysym) {
            x11.XK_Return, x11.XK_KP_Enter => "\r",
            x11.XK_BackSpace => "\x7f",
            x11.XK_Tab => "\t",
            x11.XK_Escape => "\x1b",
            x11.XK_Up => "\x1b[A",
            x11.XK_Down => "\x1b[B",
            x11.XK_Right => "\x1b[C",
            x11.XK_Left => "\x1b[D",
            x11.XK_Home => "\x1b[H",
            x11.XK_End => "\x1b[F",
            x11.XK_Delete => "\x1b[3~",
            else => null,
        };
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
    fn present(_: *Window, _: []const u32, _: u32, _: u32) void {}
};

test "keyEscape maps arrows" {
    if (builtin.os.tag != .linux) return;
    try std.testing.expectEqualStrings("\x1b[A", keyEscape(x11.XK_Up).?);
    try std.testing.expectEqualStrings("\r", keyEscape(x11.XK_Return).?);
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
