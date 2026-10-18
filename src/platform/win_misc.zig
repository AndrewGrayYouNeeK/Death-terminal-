//! Windows-only helpers for the event loop: opening URLs, detached
//! processes, and the console (raw mode + VT output + a stdin pump for the
//! headless mode).

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const k32 = windows.kernel32;
const io = @import("io.zig");

const HANDLE = windows.HANDLE;
const DWORD = windows.DWORD;

extern "shell32" fn ShellExecuteW(hwnd: ?*anyopaque, op: ?[*:0]const u16, file: [*:0]const u16, params: ?[*:0]const u16, dir: ?[*:0]const u16, show: c_int) callconv(windows.WINAPI) ?*anyopaque;

const SW_SHOWNORMAL = 1;
const DETACHED_PROCESS: DWORD = 0x00000008;
const CREATE_NEW_PROCESS_GROUP: DWORD = 0x00000200;
const CREATE_NO_WINDOW: DWORD = 0x08000000;

/// Open `url` with the default handler (`command` empty) or `command url`.
pub fn openUrl(command: []const u8, url: []const u8) void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    if (command.len == 0 or std.ascii.eqlIgnoreCase(command, "start")) {
        const url_w = std.unicode.wtf8ToWtf16LeAllocZ(a, url) catch return;
        _ = ShellExecuteW(null, std.unicode.utf8ToUtf16LeStringLiteral("open"), url_w.ptr, null, null, SW_SHOWNORMAL);
        return;
    }
    spawnDetached(&.{ command, url });
}

/// Run argv detached from us (no console, own process group).
pub fn spawnDetached(args: []const []const u8) void {
    if (args.len == 0) return;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var line = std.ArrayList(u8).init(a);
    for (args, 0..) |arg, i| {
        if (i > 0) line.append(' ') catch return;
        @import("../terminal/pty_windows.zig").quoteArg(&line, arg) catch return;
    }
    const cmd_w = std.unicode.wtf8ToWtf16LeAllocZ(a, line.items) catch return;
    var si = std.mem.zeroes(windows.STARTUPINFOW);
    si.cb = @sizeOf(windows.STARTUPINFOW);
    var pi: windows.PROCESS_INFORMATION = undefined;
    if (k32.CreateProcessW(null, cmd_w.ptr, null, null, windows.FALSE, DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW, null, null, &si, &pi) == 0) return;
    windows.CloseHandle(pi.hThread);
    windows.CloseHandle(pi.hProcess);
}

const ENABLE_PROCESSED_INPUT: DWORD = 0x0001;
const ENABLE_LINE_INPUT: DWORD = 0x0002;
const ENABLE_ECHO_INPUT: DWORD = 0x0004;
const ENABLE_VIRTUAL_TERMINAL_INPUT: DWORD = 0x0200;
const ENABLE_PROCESSED_OUTPUT: DWORD = 0x0001;
const ENABLE_VIRTUAL_TERMINAL_PROCESSING: DWORD = 0x0004;
const DISABLE_NEWLINE_AUTO_RETURN: DWORD = 0x0008;

var saved_in: ?DWORD = null;
var saved_out: ?DWORD = null;
var saved_cp: c_uint = 0;
extern "kernel32" fn GetConsoleOutputCP() callconv(windows.WINAPI) c_uint;

/// Raw, VT-mode console (keys arrive as VT sequences, Ctrl+C as a byte;
/// output understands escape sequences). False when stdin isn't a console.
pub fn enableRawConsole() bool {
    const in = k32.GetStdHandle(windows.STD_INPUT_HANDLE) orelse return false;
    const out = k32.GetStdHandle(windows.STD_OUTPUT_HANDLE) orelse return false;
    var mode: DWORD = 0;
    if (k32.GetConsoleMode(in, &mode) == 0) return false;
    saved_in = mode;
    _ = k32.SetConsoleMode(in, (mode & ~(ENABLE_PROCESSED_INPUT | ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT)) | ENABLE_VIRTUAL_TERMINAL_INPUT);
    if (k32.GetConsoleMode(out, &mode) != 0) {
        saved_out = mode;
        _ = k32.SetConsoleMode(out, mode | ENABLE_PROCESSED_OUTPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING | DISABLE_NEWLINE_AUTO_RETURN);
    }
    saved_cp = GetConsoleOutputCP();
    _ = k32.SetConsoleOutputCP(65001);
    return true;
}

pub fn restoreConsole() void {
    if (saved_in) |m| if (k32.GetStdHandle(windows.STD_INPUT_HANDLE)) |h| {
        _ = k32.SetConsoleMode(h, m);
    };
    if (saved_out) |m| if (k32.GetStdHandle(windows.STD_OUTPUT_HANDLE)) |h| {
        _ = k32.SetConsoleMode(h, m);
    };
    if (saved_cp != 0) _ = k32.SetConsoleOutputCP(saved_cp);
    saved_in = null;
    saved_out = null;
}

/// Our stdin as a pollable socket: a thread copies it over. The thread
/// is left running (blocked in ReadFile) at exit.
pub fn stdinSocket() !io.Fd {
    const pair = try io.socketPair();
    const in = k32.GetStdHandle(windows.STD_INPUT_HANDLE) orelse return error.NoStdin;
    const t = try std.Thread.spawn(.{}, pump, .{ in, pair[1] });
    t.detach();
    try io.setNonBlocking(pair[0]);
    return pair[0];
}

fn pump(h: HANDLE, sock: io.Fd) void {
    var buf: [4096]u8 = undefined;
    while (true) {
        var n: DWORD = 0;
        if (k32.ReadFile(h, &buf, buf.len, &n, null) == 0 or n == 0) break;
        var off: usize = 0;
        while (off < n) off += io.write(sock, buf[off..n]) catch return;
    }
    _ = windows.ws2_32.shutdown(sock, 1);
}
