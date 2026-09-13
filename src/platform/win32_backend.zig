const std = @import("std");
const builtin = @import("builtin");
const Event = @import("window.zig").Event;
const dpi = @import("dpi.zig");

const w = if (builtin.os.tag == .windows) @cImport({
    @cInclude("windows.h");
}) else struct {};

pub const State = struct {
    allocator: std.mem.Allocator = undefined,
    hwnd: ?*anyopaque = null,
    hinstance: ?*anyopaque = null,
    width: u32 = 0,
    height: u32 = 0,
    scale: f32 = 1.0,
    pending_close: bool = false,
    pending_redraw: bool = false,
    pending_resize: bool = false,
    input_scratch: [32]u8 = undefined,
    input_len: u8 = 0,
    has_input: bool = false,
    class_atom: usize = 0,
    dib_pixels: []u32 = &.{},
};

pub fn open(st: *State, allocator: std.mem.Allocator, title: []const u8, width: u32, height: u32, scale: f32) !void {
    if (builtin.os.tag == .windows) {
        try Win.open(st, allocator, title, width, height, scale);
    } else {
        return error.UnsupportedPlatform;
    }
}

pub fn close(st: *State) void {
    if (builtin.os.tag == .windows) Win.close(st);
}

pub fn poll(st: *State) Event {
    if (builtin.os.tag == .windows) return Win.poll(st);
    return .none;
}

pub fn presentRgba(st: *State, pixels: []const u32, width: u32, height: u32) void {
    if (builtin.os.tag == .windows) Win.presentRgba(st, pixels, width, height);
}

pub fn hwndPtr(st: *const State) ?*anyopaque {
    return st.hwnd;
}

pub fn instancePtr(st: *const State) ?*anyopaque {
    return st.hinstance;
}

const Win = if (builtin.os.tag == .windows) struct {
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("DeathTerminal");

    fn open(st: *State, allocator: std.mem.Allocator, title: []const u8, width: u32, height: u32, scale: f32) !void {
        st.* = .{
            .allocator = allocator,
            .width = @max(1, width),
            .height = @max(1, height),
            .scale = dpi.normalize(scale),
        };

        const hinstance: w.HINSTANCE = w.GetModuleHandleW(null);
        st.hinstance = hinstance;

        enableDpiAwareness();

        var wc = std.mem.zeroes(w.WNDCLASSW);
        wc.lpfnWndProc = wndProc;
        wc.hInstance = hinstance;
        wc.lpszClassName = class_name;
        wc.hCursor = w.LoadCursorW(null, w.IDC_ARROW);
        wc.hbrBackground = @ptrFromInt(@as(usize, @intCast(w.COLOR_WINDOW + 1)));
        const atom = w.RegisterClassW(&wc);
        if (atom == 0) {
            const err = w.GetLastError();
            if (err != w.ERROR_CLASS_ALREADY_EXISTS) return error.RegisterClassFailed;
        }
        st.class_atom = atom;

        var title_w: [256]u16 = undefined;
        const n = try std.unicode.utf8ToUtf16Le(title_w[0 .. title_w.len - 1], title);
        title_w[n] = 0;

        const hwnd = w.CreateWindowExW(
            0,
            class_name,
            @ptrCast(&title_w),
            w.WS_OVERLAPPEDWINDOW | w.WS_VISIBLE,
            w.CW_USEDEFAULT,
            w.CW_USEDEFAULT,
            @intCast(st.width),
            @intCast(st.height),
            null,
            null,
            hinstance,
            st,
        );
        if (hwnd == null) return error.CreateWindowFailed;
        st.hwnd = hwnd;

        const detected = windowScale(hwnd);
        if (detected > st.scale) st.scale = detected;

        _ = w.ShowWindow(hwnd, w.SW_SHOW);
        _ = w.UpdateWindow(hwnd);
        std.debug.print("  → Win32 window mapped ({d}x{d}) scale={d:.2}\n", .{ st.width, st.height, st.scale });
    }

    fn close(st: *State) void {
        if (st.dib_pixels.len != 0) {
            st.allocator.free(st.dib_pixels);
            st.dib_pixels = &.{};
        }
        if (st.hwnd) |hwnd| {
            _ = w.DestroyWindow(@ptrCast(hwnd));
            st.hwnd = null;
        }
        st.* = .{};
    }

    fn poll(st: *State) Event {
        var msg: w.MSG = undefined;
        while (w.PeekMessageW(&msg, null, 0, 0, w.PM_REMOVE) != 0) {
            if (msg.message == w.WM_QUIT) st.pending_close = true;
            _ = w.TranslateMessage(&msg);
            _ = w.DispatchMessageW(&msg);
        }
        if (st.pending_close) {
            st.pending_close = false;
            return .close;
        }
        if (st.has_input) {
            st.has_input = false;
            return .{ .input = st.input_scratch[0..st.input_len] };
        }
        if (st.pending_resize) {
            st.pending_resize = false;
            return .{ .resize = .{ .width = st.width, .height = st.height } };
        }
        if (st.pending_redraw) {
            st.pending_redraw = false;
            return .redraw;
        }
        return .none;
    }

    fn presentRgba(st: *State, pixels: []const u32, width: u32, height: u32) void {
        const hwnd_ptr = st.hwnd orelse return;
        const hwnd: w.HWND = @ptrCast(hwnd_ptr);
        if (width == 0 or height == 0) return;
        const count = @as(usize, width) * @as(usize, height);
        if (pixels.len < count) return;

        const hdc = w.GetDC(hwnd);
        if (hdc == null) return;
        defer _ = w.ReleaseDC(hwnd, hdc);

        var info = std.mem.zeroes(w.BITMAPINFO);
        info.bmiHeader.biSize = @sizeOf(w.BITMAPINFOHEADER);
        info.bmiHeader.biWidth = @intCast(width);
        info.bmiHeader.biHeight = -@as(i32, @intCast(height));
        info.bmiHeader.biPlanes = 1;
        info.bmiHeader.biBitCount = 32;
        info.bmiHeader.biCompression = w.BI_RGB;

        _ = w.StretchDIBits(
            hdc,
            0,
            0,
            @intCast(width),
            @intCast(height),
            0,
            0,
            @intCast(width),
            @intCast(height),
            pixels.ptr,
            &info,
            w.DIB_RGB_COLORS,
            w.SRCCOPY,
        );
    }

    fn wndProc(hwnd: w.HWND, msg: w.UINT, wparam: w.WPARAM, lparam: w.LPARAM) callconv(w.WINAPI) w.LRESULT {
        if (msg == w.WM_NCCREATE) {
            const cs: *w.CREATESTRUCTW = @ptrFromInt(@as(usize, @intCast(lparam)));
            _ = w.SetWindowLongPtrW(hwnd, w.GWLP_USERDATA, @intFromPtr(cs.lpCreateParams));
        }
        const raw = w.GetWindowLongPtrW(hwnd, w.GWLP_USERDATA);
        if (raw == 0) return w.DefWindowProcW(hwnd, msg, wparam, lparam);
        const st: *State = @ptrFromInt(@as(usize, @intCast(raw)));

        switch (msg) {
            w.WM_CLOSE => {
                st.pending_close = true;
                return 0;
            },
            w.WM_DESTROY => {
                w.PostQuitMessage(0);
                return 0;
            },
            w.WM_PAINT => {
                var ps: w.PAINTSTRUCT = undefined;
                _ = w.BeginPaint(hwnd, &ps);
                _ = w.EndPaint(hwnd, &ps);
                st.pending_redraw = true;
                return 0;
            },
            w.WM_SIZE => {
                const wpx: u32 = @intCast(lparam & 0xFFFF);
                const hpx: u32 = @intCast((lparam >> 16) & 0xFFFF);
                if (wpx > 0 and hpx > 0 and (wpx != st.width or hpx != st.height)) {
                    st.width = wpx;
                    st.height = hpx;
                    st.pending_resize = true;
                }
                return 0;
            },
            w.WM_DPICHANGED => {
                const dpi_x: u32 = @intCast(wparam & 0xFFFF);
                st.scale = dpi.fromDpi(@floatFromInt(dpi_x));
                st.pending_resize = true;
                return 0;
            },
            w.WM_CHAR => {
                const cp: u21 = @intCast(wparam);
                if (cp == 0x03) {
                    st.pending_close = true;
                    return 0;
                }
                var buf: [8]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch 0;
                if (n > 0) {
                    @memcpy(st.input_scratch[0..n], buf[0..n]);
                    st.input_len = @intCast(n);
                    st.has_input = true;
                }
                return 0;
            },
            w.WM_KEYDOWN => {
                if (keySeq(wparam)) |seq| {
                    const ncopy = @min(seq.len, st.input_scratch.len);
                    @memcpy(st.input_scratch[0..ncopy], seq[0..ncopy]);
                    st.input_len = @intCast(ncopy);
                    st.has_input = true;
                    return 0;
                }
                if (wparam == 'C' and (w.GetKeyState(w.VK_CONTROL) & 0x8000) != 0) {
                    st.pending_close = true;
                    return 0;
                }
                return w.DefWindowProcW(hwnd, msg, wparam, lparam);
            },
            else => return w.DefWindowProcW(hwnd, msg, wparam, lparam),
        }
    }

    fn keySeq(wparam: w.WPARAM) ?[]const u8 {
        return switch (wparam) {
            w.VK_RETURN => "\r",
            w.VK_BACK => "\x7f",
            w.VK_TAB => "\t",
            w.VK_ESCAPE => "\x1b",
            w.VK_UP => "\x1b[A",
            w.VK_DOWN => "\x1b[B",
            w.VK_RIGHT => "\x1b[C",
            w.VK_LEFT => "\x1b[D",
            w.VK_HOME => "\x1b[H",
            w.VK_END => "\x1b[F",
            w.VK_DELETE => "\x1b[3~",
            else => null,
        };
    }

    fn enableDpiAwareness() void {
        const user32 = w.GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("user32.dll"));
        if (user32 == null) return;
        const SetContext = *const fn (w.DPI_AWARENESS_CONTEXT) callconv(w.WINAPI) w.BOOL;
        const proc = w.GetProcAddress(user32, "SetProcessDpiAwarenessContext");
        if (proc) |p| {
            const fn_ptr: SetContext = @ptrCast(p);
            _ = fn_ptr(w.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        }
    }

    fn windowScale(hwnd: w.HWND) f32 {
        const user32 = w.GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("user32.dll"));
        if (user32 == null) return 1.0;
        const GetDpi = *const fn (w.HWND) callconv(w.WINAPI) w.UINT;
        const proc = w.GetProcAddress(user32, "GetDpiForWindow");
        if (proc) |p| {
            const fn_ptr: GetDpi = @ptrCast(p);
            const val = fn_ptr(hwnd);
            if (val > 0) return dpi.fromDpi(@floatFromInt(val));
        }
        return 1.0;
    }
} else struct {};

test "win32 state defaults to inert" {
    const st = State{};
    try std.testing.expect(st.hwnd == null);
    try std.testing.expectEqual(@as(f32, 1.0), st.scale);
}
