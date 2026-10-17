const std = @import("std");
const builtin = @import("builtin");
const events = @import("events.zig");
const Event = events.Event;
const input = @import("../terminal/input.zig");
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
    queue: events.EventQueue = .{},
    held: input.MouseButton = .none,
    /// Drop the WM_CHAR that follows a zoom shortcut.
    swallow_char: bool = false,
    class_atom: usize = 0,
    dib_pixels: []u32 = &.{},
    /// Windows has no PRIMARY selection; it is emulated in-process.
    primary_text: ?[]u8 = null,
    paste_buf: std.ArrayListUnmanaged(u8) = .{},
};

pub fn setClipboard(st: *State, target: events.ClipTarget, text: []const u8) void {
    switch (target) {
        .primary => {
            const copy = st.allocator.dupe(u8, text) catch return;
            if (st.primary_text) |old| st.allocator.free(old);
            st.primary_text = copy;
        },
        .clipboard => if (builtin.os.tag == .windows) Win.setClipboard(st, text),
    }
}

pub fn requestClipboard(st: *State, target: events.ClipTarget, purpose: events.PastePurpose) void {
    st.paste_buf.clearRetainingCapacity();
    switch (target) {
        .primary => if (st.primary_text) |t| st.paste_buf.appendSlice(st.allocator, t) catch {},
        .clipboard => if (builtin.os.tag == .windows) Win.readClipboard(st),
    }
    st.queue.pushPaste(st.paste_buf.items, target, purpose);
}

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

pub fn setTitle(st: *State, title: []const u8) void {
    if (builtin.os.tag == .windows) Win.setTitle(st, title);
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

    fn setClipboard(st: *State, text: []const u8) void {
        const hwnd: w.HWND = @ptrCast(@alignCast(st.hwnd orelse return));
        const wide = std.unicode.utf8ToUtf16LeAllocZ(st.allocator, text) catch return;
        defer st.allocator.free(wide);
        const bytes = (wide.len + 1) * 2;
        const mem = w.GlobalAlloc(w.GMEM_MOVEABLE, bytes) orelse return;
        const dst: [*]u16 = @ptrCast(@alignCast(w.GlobalLock(mem) orelse {
            _ = w.GlobalFree(mem);
            return;
        }));
        @memcpy(dst[0 .. wide.len + 1], wide[0 .. wide.len + 1]);
        _ = w.GlobalUnlock(mem);
        if (w.OpenClipboard(hwnd) == 0) {
            _ = w.GlobalFree(mem);
            return;
        }
        _ = w.EmptyClipboard();
        // On success the clipboard owns `mem`.
        if (w.SetClipboardData(w.CF_UNICODETEXT, mem) == null) _ = w.GlobalFree(mem);
        _ = w.CloseClipboard();
    }

    fn readClipboard(st: *State) void {
        const hwnd: w.HWND = @ptrCast(@alignCast(st.hwnd orelse return));
        if (w.OpenClipboard(hwnd) == 0) return;
        defer _ = w.CloseClipboard();
        const h = w.GetClipboardData(w.CF_UNICODETEXT) orelse return;
        const src: [*:0]const u16 = @ptrCast(@alignCast(w.GlobalLock(h) orelse return));
        defer _ = w.GlobalUnlock(h);
        const utf8 = std.unicode.utf16LeToUtf8Alloc(st.allocator, std.mem.span(src)) catch return;
        defer st.allocator.free(utf8);
        st.paste_buf.appendSlice(st.allocator, utf8) catch {};
    }

    fn close(st: *State) void {
        if (st.primary_text) |t| st.allocator.free(t);
        st.paste_buf.deinit(st.allocator);
        if (st.dib_pixels.len != 0) {
            st.allocator.free(st.dib_pixels);
            st.dib_pixels = &.{};
        }
        if (st.hwnd) |hwnd| {
            _ = w.DestroyWindow(@ptrCast(@alignCast(hwnd)));
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
        const queued = st.queue.pop();
        if (queued != .none) return queued;
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
        const hwnd: w.HWND = @ptrCast(@alignCast(hwnd_ptr));
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
                const cp: u21 = @intCast(wparam & 0x1FFFFF);
                if (st.swallow_char) {
                    st.swallow_char = false;
                    return 0;
                }
                // Backspace is sent from WM_KEYDOWN as DEL; drop its translated 0x08.
                if (cp == 0x08 and (w.GetKeyState(w.VK_BACK) & 0x8000) != 0) return 0;
                var buf: [8]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch 0;
                if (n > 0) st.queue.pushText(buf[0..n], false);
                return 0;
            },
            w.WM_SYSCHAR => {
                // Alt+key arrives as WM_SYSCHAR: meta sends ESC.
                const cp: u21 = @intCast(wparam & 0x1FFFFF);
                var buf: [8]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch 0;
                if (n > 0) st.queue.pushText(buf[0..n], true);
                return 0;
            },
            w.WM_KEYDOWN, w.WM_SYSKEYDOWN => {
                if (vkToKeysym(wparam)) |sym| {
                    if (events.matchBinding(sym, currentMods())) |a| {
                        st.queue.pushAction(a);
                        st.swallow_char = true;
                        return 0;
                    }
                }
                if (vkToKey(wparam)) |key| {
                    st.queue.pushKey(key, currentMods());
                    return 0;
                }
                return w.DefWindowProcW(hwnd, msg, wparam, lparam);
            },
            w.WM_SETFOCUS => {
                st.queue.pushFocus(true);
                return 0;
            },
            w.WM_KILLFOCUS => {
                st.queue.pushFocus(false);
                return 0;
            },
            w.WM_LBUTTONDOWN, w.WM_LBUTTONUP, w.WM_MBUTTONDOWN, w.WM_MBUTTONUP, w.WM_RBUTTONDOWN, w.WM_RBUTTONUP => {
                const b: input.MouseButton = switch (msg) {
                    w.WM_LBUTTONDOWN, w.WM_LBUTTONUP => .left,
                    w.WM_MBUTTONDOWN, w.WM_MBUTTONUP => .middle,
                    else => .right,
                };
                const pressed = msg == w.WM_LBUTTONDOWN or msg == w.WM_MBUTTONDOWN or msg == w.WM_RBUTTONDOWN;
                if (pressed) _ = w.SetCapture(hwnd) else _ = w.ReleaseCapture();
                st.held = if (pressed) b else .none;
                st.queue.pushMouse(.{ .action = if (pressed) .press else .release, .button = b, .x = lowX(lparam), .y = highY(lparam), .mods = currentMods() });
                return 0;
            },
            w.WM_MOUSEMOVE => {
                st.queue.pushMouse(.{ .action = .motion, .button = st.held, .x = lowX(lparam), .y = highY(lparam), .mods = currentMods() });
                return 0;
            },
            w.WM_MOUSEWHEEL => {
                const delta: i16 = @bitCast(@as(u16, @truncate(wparam >> 16)));
                var pt = w.POINT{ .x = lowX(lparam), .y = highY(lparam) };
                _ = w.ScreenToClient(hwnd, &pt);
                st.queue.pushMouse(.{ .action = .press, .button = if (delta > 0) .wheel_up else .wheel_down, .x = pt.x, .y = pt.y, .mods = currentMods() });
                return 0;
            },
            else => return w.DefWindowProcW(hwnd, msg, wparam, lparam),
        }
    }

    fn lowX(lparam: w.LPARAM) i32 {
        return @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam))))));
    }

    fn highY(lparam: w.LPARAM) i32 {
        return @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)) >> 16))));
    }

    /// Map a virtual key onto the X11 keysym numbering used by bindings.
    fn vkToKeysym(vk: w.WPARAM) ?u32 {
        return switch (vk) {
            'A'...'Z' => @as(u32, @intCast(vk)) + 32,
            '0'...'9' => @intCast(vk),
            0xBB => '=', // VK_OEM_PLUS
            0xBD => '-', // VK_OEM_MINUS
            0xBC => ',',
            0xBE => '.',
            0xBF => '/',
            w.VK_INSERT => 0xff63,
            w.VK_DELETE => 0xffff,
            w.VK_PRIOR => 0xff55,
            w.VK_NEXT => 0xff56,
            w.VK_HOME => 0xff50,
            w.VK_END => 0xff57,
            w.VK_UP => 0xff52,
            w.VK_DOWN => 0xff54,
            w.VK_LEFT => 0xff51,
            w.VK_RIGHT => 0xff53,
            w.VK_ADD => 0xffab,
            w.VK_SUBTRACT => 0xffad,
            w.VK_NUMPAD0 => 0xffb0,
            w.VK_F1...w.VK_F12 => 0xffbe + @as(u32, @intCast(vk - w.VK_F1)),
            else => null,
        };
    }

    fn currentMods() input.Mods {
        return .{
            .shift = (w.GetKeyState(w.VK_SHIFT) & 0x8000) != 0,
            .ctrl = (w.GetKeyState(w.VK_CONTROL) & 0x8000) != 0,
            .alt = (w.GetKeyState(w.VK_MENU) & 0x8000) != 0,
        };
    }

    fn vkToKey(wparam: w.WPARAM) ?input.Key {
        return switch (wparam) {
            w.VK_UP => .up,
            w.VK_DOWN => .down,
            w.VK_RIGHT => .right,
            w.VK_LEFT => .left,
            w.VK_HOME => .home,
            w.VK_END => .end,
            w.VK_PRIOR => .page_up,
            w.VK_NEXT => .page_down,
            w.VK_INSERT => .insert,
            w.VK_DELETE => .delete,
            w.VK_F1 => .f1,
            w.VK_F2 => .f2,
            w.VK_F3 => .f3,
            w.VK_F4 => .f4,
            w.VK_F5 => .f5,
            w.VK_F6 => .f6,
            w.VK_F7 => .f7,
            w.VK_F8 => .f8,
            w.VK_F9 => .f9,
            w.VK_F10 => .f10,
            w.VK_F11 => .f11,
            w.VK_F12 => .f12,
            // Enter/Tab/Escape arrive as WM_CHAR after TranslateMessage.
            w.VK_BACK => .backspace,
            else => null,
        };
    }

    fn setTitle(st: *State, title: []const u8) void {
        const hwnd_ptr = st.hwnd orelse return;
        const wide = std.unicode.utf8ToUtf16LeAllocZ(st.allocator, title) catch return;
        defer st.allocator.free(wide);
        _ = w.SetWindowTextW(@ptrCast(@alignCast(hwnd_ptr)), wide.ptr);
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
