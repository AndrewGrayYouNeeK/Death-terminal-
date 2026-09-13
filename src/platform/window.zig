const std = @import("std");
const builtin = @import("builtin");

pub const Event = union(enum) {
    none,
    close,
    resize: struct { width: u32, height: u32 },
    text: u8,
    key_special: SpecialKey,
};

pub const SpecialKey = enum { enter, backspace, tab, escape, up, down, left, right };

pub const Window = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    live: bool,
    lib: ?std.DynLib = null,
    display: ?*anyopaque = null,
    window: usize = 0,
    gc: usize = 0,
    XPending: ?*const fn (*anyopaque) callconv(.C) c_int = null,
    XFlush: ?*const fn (*anyopaque) callconv(.C) c_int = null,
    XCloseDisplay: ?*const fn (*anyopaque) callconv(.C) c_int = null,
    XDestroyWindow: ?*const fn (*anyopaque, usize) callconv(.C) c_int = null,
    XPutImage: ?*const fn (*anyopaque, usize, usize, *anyopaque, c_int, c_int, c_int, c_int, c_uint, c_uint) callconv(.C) c_int = null,

    pub fn open(allocator: std.mem.Allocator, title: []const u8, width: u32, height: u32) !Window {
        _ = title;
        var win = Window{ .allocator = allocator, .width = width, .height = height, .live = false };
        if (builtin.os.tag != .linux) return win;
        var lib = std.DynLib.open("libX11.so.6") catch {
            std.debug.print("  → X11 unavailable\n", .{});
            return win;
        };
        const XOpenDisplay = lib.lookup(*const fn (?[*:0]const u8) callconv(.C) ?*anyopaque, "XOpenDisplay") orelse {
            lib.close();
            return win;
        };
        const display = XOpenDisplay(null) orelse {
            lib.close();
            return win;
        };
        win.lib = lib;
        win.display = display;
        win.live = true;
        std.debug.print("  → X11 display opened ({d}x{d})\n", .{ width, height });
        return win;
    }

    pub fn deinit(self: *Window) void {
        if (self.display) |d| {
            if (self.XCloseDisplay) |close| _ = close(d);
        }
        if (self.lib) |*lib| lib.close();
        self.live = false;
    }

    pub fn isLive(self: *const Window) bool {
        return self.live;
    }

    pub fn poll(self: *Window) Event {
        _ = self;
        return .none;
    }

    pub fn presentRgba(self: *Window, pixels: []const u32, width: u32, height: u32) void {
        _ = self;
        _ = pixels;
        _ = width;
        _ = height;
    }

    pub fn encodeSpecial(key: SpecialKey) []const u8 {
        return switch (key) {
            .enter => "\r",
            .backspace => "\x7f",
            .tab => "\t",
            .escape => "\x1b",
            .up => "\x1b[A",
            .down => "\x1b[B",
            .right => "\x1b[C",
            .left => "\x1b[D",
        };
    }
};
