const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const x11 = if (builtin.os.tag == .linux) @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xutil.h");
    @cInclude("X11/keysym.h");
}) else struct {};

pub const Event = union(enum) {
    none,
    close,
    resize: struct { width: u32, height: u32 },
    input: []const u8,
};

/// Native window. Linux uses X11; other OS stay inert so `--gui` can fall back.
pub const Window = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    live: bool,
    display: if (builtin.os.tag == .linux) ?*x11.Display else ?*anyopaque,
    window: if (builtin.os.tag == .linux) x11.Window else usize,
    gc: if (builtin.os.tag == .linux) x11.GC else ?*anyopaque,
    visual: if (builtin.os.tag == .linux) ?*x11.Visual else ?*anyopaque,
    depth: c_uint,
    wm_delete: if (builtin.os.tag == .linux) x11.Atom else usize,
    packed_pixels: []u32,
    ximage: if (builtin.os.tag == .linux) [*c]x11.XImage else ?*anyopaque,
    input_scratch: [8]u8,
    input_len: u8,

    pub fn open(allocator: std.mem.Allocator, title: []const u8, width: u32, height: u32) !Window {
        var win = Window{
            .allocator = allocator,
            .width = width,
            .height = height,
            .live = false,
            .display = null,
            .window = 0,
            .gc = undefined,
            .visual = null,
            .depth = 24,
            .wm_delete = 0,
            .packed_pixels = &.{},
            .ximage = null,
            .input_scratch = undefined,
            .input_len = 0,
        };

        if (builtin.os.tag != .linux) {
            std.debug.print("  → GUI backend unavailable on this OS\n", .{});
            return win;
        }

        return openX11(&win, title) catch |err| {
            std.debug.print("  → X11 unavailable ({s})\n", .{@errorName(err)});
            return win;
        };
    }

    pub fn deinit(self: *Window) void {
        if (self.packed_pixels.len != 0) {
            self.allocator.free(self.packed_pixels);
            self.packed_pixels = &.{};
        }
        if (builtin.os.tag == .linux) {
            closeX11(self);
        }
        self.live = false;
    }

    pub fn isLive(self: *const Window) bool {
        return self.live;
    }

    pub fn connectionFd(self: *const Window) ?posix.fd_t {
        if (builtin.os.tag != .linux) return null;
        const dpy = self.display orelse return null;
        const fd = x11.XConnectionNumber(dpy);
        if (fd < 0) return null;
        return fd;
    }

    pub fn poll(self: *Window) Event {
        if (builtin.os.tag != .linux) return .none;
        return pollX11(self);
    }

    pub fn presentRgba(self: *Window, pixels: []const u32, width: u32, height: u32) void {
        if (builtin.os.tag != .linux) return;
        presentX11(self, pixels, width, height);
    }

    pub fn x11DisplayPtr(self: *const Window) ?*anyopaque {
        return if (builtin.os.tag == .linux) @ptrCast(self.display) else null;
    }

    pub fn x11WindowId(self: *const Window) usize {
        return if (builtin.os.tag == .linux) self.window else 0;
    }

    pub fn encodeSpecial(seq: []const u8) []const u8 {
        return seq;
    }
};

pub fn keyEscape(keysym: c_ulong) ?[]const u8 {
    if (builtin.os.tag != .linux) return null;
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

fn openX11(win: *Window, title: []const u8) !Window {
    const dpy = x11.XOpenDisplay(null) orelse return error.NoDisplay;
    errdefer _ = x11.XCloseDisplay(dpy);

    const screen = x11.XDefaultScreen(dpy);
    const visual = x11.XDefaultVisual(dpy, screen) orelse return error.NoVisual;
    const depth: c_uint = @intCast(x11.XDefaultDepth(dpy, screen));
    const root = x11.XRootWindow(dpy, screen);
    const black = x11.XBlackPixel(dpy, screen);
    const white = x11.XWhitePixel(dpy, screen);

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
    win.live = true;
    _ = white;

    std.debug.print("  → X11 window mapped ({d}x{d})\n", .{ win.width, win.height });
    return win.*;
}

fn closeX11(self: *Window) void {
    if (self.ximage) |image| {
        image.*.data = null;
        self.ximage = null;
    }
    if (self.display) |dpy| {
        if (self.window != 0) {
            _ = x11.XDestroyWindow(dpy, self.window);
            self.window = 0;
        }
        _ = x11.XCloseDisplay(dpy);
        self.display = null;
    }
}

fn pollX11(self: *Window) Event {
    const dpy = self.display orelse return .none;
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
        return .{ .resize = .{ .width = self.width, .height = self.height } };
    }
    if (ev.type == x11.KeyPress) {
        var buf: [8]u8 = undefined;
        var keysym: x11.KeySym = 0;
        const n = x11.XLookupString(&ev.xkey, &buf, buf.len, &keysym, null);
        const ctrl = (ev.xkey.state & x11.ControlMask) != 0;
        if (ctrl and (keysym == x11.XK_c or keysym == x11.XK_C)) {
            return .close;
        }
        if (keyEscape(keysym)) |seq| {
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

fn presentX11(self: *Window, pixels: []const u32, width: u32, height: u32) void {
    const dpy = self.display orelse return;
    const visual = self.visual orelse return;
    if (self.window == 0) return;
    if (width == 0 or height == 0) return;

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

    var image = self.ximage;
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

test "keyEscape maps arrows" {
    if (builtin.os.tag != .linux) return;
    try std.testing.expectEqualStrings("\x1b[A", keyEscape(x11.XK_Up).?);
    try std.testing.expectEqualStrings("\r", keyEscape(x11.XK_Return).?);
}

test "Window open is safe without requiring a mapped window" {
    var w = try Window.open(std.testing.allocator, "DeathTerminalTest", 80, 48);
    defer w.deinit();
    _ = w.isLive();
}
