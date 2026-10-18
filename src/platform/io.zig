//! Small portability layer for the event loops: what `poll()` waits on.
//!
//! On Linux and macOS every waitable thing is a file descriptor and this is
//! plain `poll(2)`. On Windows `WSAPoll` only takes sockets, so everything
//! the loops wait on (ConPTY output, AI and plugin wake-ups, headless stdin)
//! is turned into a socket: a reader thread pumps a pipe into one end of a
//! loopback socket pair (`socketPair`) and the loop polls the other end.
//! `wait` additionally wakes on window messages (`MsgWaitForMultipleObjects`)
//! so the Win32 window needs no timer.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const is_windows = builtin.os.tag == .windows;
const windows = std.os.windows;
const ws2 = windows.ws2_32;

/// What goes into `pollfd.fd`.
pub const Fd = if (is_windows) ws2.SOCKET else posix.fd_t;
/// "No descriptor" (skipped by `poll`).
pub const none: Fd = if (is_windows) ws2.INVALID_SOCKET else -1;

pub fn isNone(fd: Fd) bool {
    return if (is_windows) fd == ws2.INVALID_SOCKET else fd < 0;
}

pub const PollFd = posix.pollfd;
pub const POLL = posix.POLL;

pub fn pollFd(fd: Fd, events: i16) PollFd {
    return .{ .fd = fd, .events = events, .revents = 0 };
}

/// `poll(2)`; entries with `none` are skipped. Returns how many are ready
/// (0 on timeout or error).
pub fn poll(fds: []PollFd, timeout_ms: i32) usize {
    return wait(fds, timeout_ms, false);
}

/// Like `poll`, but on Windows also returns when the calling thread has
/// window messages queued (`with_messages`). Elsewhere the window
/// connection is an fd in `fds` like any other.
pub fn wait(fds: []PollFd, timeout_ms: i32, with_messages: bool) usize {
    if (!is_windows) return posix.poll(fds, timeout_ms) catch 0;
    return Win.wait(fds, timeout_ms, with_messages);
}

/// Read from something `poll` reported readable (pipe/pty fd, or socket on
/// Windows). 0 = end of file. error.WouldBlock when nothing is there.
pub fn read(fd: Fd, buf: []u8) !usize {
    if (!is_windows) return posix.read(fd, buf);
    return Win.recv(fd, buf);
}

/// Write to an fd / socket. Returns how much was written.
pub fn write(fd: Fd, data: []const u8) !usize {
    if (!is_windows) return posix.write(fd, data);
    return Win.send(fd, data);
}

pub fn close(fd: Fd) void {
    if (isNone(fd)) return;
    if (!is_windows) return posix.close(fd);
    _ = ws2.closesocket(fd);
}

/// One-way wake-up channel: another thread calls `signal`, the loop polls
/// `fd()` and calls `drain`. A pipe on POSIX, a socket pair on Windows.
pub const Wake = struct {
    r: Fd,
    w: Fd,

    pub fn init() !Wake {
        if (!is_windows) {
            const p = try posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
            return .{ .r = p[0], .w = p[1] };
        }
        const p = try socketPair();
        try setNonBlocking(p[0]);
        try setNonBlocking(p[1]);
        return .{ .r = p[0], .w = p[1] };
    }

    pub fn deinit(self: *Wake) void {
        close(self.r);
        close(self.w);
        self.* = .{ .r = none, .w = none };
    }

    pub fn fd(self: *const Wake) Fd {
        return self.r;
    }

    pub fn signal(self: *const Wake) void {
        _ = write(self.w, "x") catch {};
    }

    pub fn drain(self: *const Wake) void {
        var buf: [64]u8 = undefined;
        while (true) {
            const n = read(self.r, &buf) catch break;
            if (n < buf.len) break;
        }
    }
};

pub fn setNonBlocking(fd: Fd) !void {
    if (!is_windows) {
        const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
        _ = try posix.fcntl(fd, posix.F.SETFL, flags | (@as(usize, 1) << @bitOffsetOf(posix.O, "NONBLOCK")));
        return;
    }
    var on: c_ulong = 1;
    if (ws2.ioctlsocket(fd, ws2.FIONBIO, &on) != 0) return error.Unexpected;
}

/// Connected pair of loopback TCP sockets (Windows has no socketpair()).
/// Both ends are blocking; Nagle is off so single bytes go out at once.
pub fn socketPair() ![2]Fd {
    if (!is_windows) {
        var fds: [2]posix.fd_t = undefined;
        const rc = std.c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0, &fds);
        if (rc != 0) return error.SocketPairFailed;
        return fds;
    }
    return Win.socketPair();
}

/// Windows: start Winsock once (std.net does it lazily too).
pub fn ensureSockets() void {
    if (is_windows) Win.startup();
}

const Win = if (is_windows) struct {
    var started = std.once(doStartup);
    fn doStartup() void {
        _ = windows.WSAStartup(2, 2) catch {};
    }
    fn startup() void {
        started.call();
    }

    extern "user32" fn MsgWaitForMultipleObjectsEx(n: windows.DWORD, handles: ?[*]const windows.HANDLE, ms: windows.DWORD, wake_mask: windows.DWORD, flags: windows.DWORD) callconv(windows.WINAPI) windows.DWORD;
    extern "user32" fn GetQueueStatus(flags: windows.UINT) callconv(windows.WINAPI) windows.DWORD;
    const QS_ALLINPUT: windows.DWORD = 0x04FF;
    const MWMO_INPUTAVAILABLE: windows.DWORD = 0x0004;
    const FD_READ: i32 = 1;
    const FD_ACCEPT: i32 = 8;
    const FD_CLOSE: i32 = 32;


    /// Compact the live entries, poll them without blocking; if nothing is
    /// ready, arm an event on every socket and sleep until a socket event,
    /// a window message (optionally) or the timeout, then poll again.
    fn wait(fds: []PollFd, timeout_ms: i32, with_messages: bool) usize {
        startup();
        for (fds) |*f| f.revents = 0;
        var live_buf: [256]PollFd = undefined;
        var map: [256]usize = undefined;
        var n: usize = 0;
        for (fds, 0..) |f, i| {
            if (f.fd == ws2.INVALID_SOCKET or n == live_buf.len) continue;
            live_buf[n] = f;
            map[n] = i;
            n += 1;
        }
        const live = live_buf[0..n];
        var ready = pollNow(live);
        if (ready == 0 and timeout_ms != 0) {
            if (with_messages and GetQueueStatus(QS_ALLINPUT) != 0) return 0;
            // One event per call: several threads wait at once (jobs, AI
            // worker, relays), and a shared event would let one thread reset
            // another's wake-up.
            const ev = ws2.WSACreateEvent();
            defer _ = ws2.WSACloseEvent(ev);
            for (live) |f| _ = ws2.WSAEventSelect(f.fd, ev, FD_READ | FD_ACCEPT | FD_CLOSE);
            const ms: windows.DWORD = if (timeout_ms < 0) windows.INFINITE else @intCast(timeout_ms);
            const handles = [1]windows.HANDLE{ev};
            if (with_messages) {
                _ = MsgWaitForMultipleObjectsEx(1, &handles, ms, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
            } else {
                _ = windows.kernel32.WaitForSingleObjectEx(ev, ms, windows.FALSE);
            }
            // WSAEventSelect left the sockets non-blocking, which is what
            // the loops want anyway.
            for (live) |f| _ = ws2.WSAEventSelect(f.fd, ev, 0);
            ready = pollNow(live);
        }
        for (live, 0..) |f, k| fds[map[k]].revents = f.revents;
        return ready;
    }

    fn pollNow(live: []PollFd) usize {
        if (live.len == 0) return 0;
        const rc = ws2.WSAPoll(live.ptr, @intCast(live.len), 0);
        return if (rc > 0) @intCast(rc) else 0;
    }

    fn recv(fd: Fd, buf: []u8) !usize {
        const rc = ws2.recv(fd, buf.ptr, @intCast(@min(buf.len, std.math.maxInt(i32))), 0);
        if (rc == ws2.SOCKET_ERROR) {
            return switch (ws2.WSAGetLastError()) {
                .WSAEWOULDBLOCK => error.WouldBlock,
                .WSAECONNRESET, .WSAECONNABORTED, .WSAESHUTDOWN => 0,
                else => error.InputOutput,
            };
        }
        return @intCast(rc);
    }

    fn send(fd: Fd, data: []const u8) !usize {
        const rc = ws2.send(fd, data.ptr, @intCast(@min(data.len, std.math.maxInt(i32))), 0);
        if (rc == ws2.SOCKET_ERROR) {
            return switch (ws2.WSAGetLastError()) {
                .WSAEWOULDBLOCK => error.WouldBlock,
                else => error.BrokenPipe,
            };
        }
        return @intCast(rc);
    }

    fn socketPair() ![2]Fd {
        startup();
        const listener = ws2.socket(ws2.AF.INET, ws2.SOCK.STREAM, ws2.IPPROTO.TCP);
        if (listener == ws2.INVALID_SOCKET) return error.SocketPairFailed;
        defer _ = ws2.closesocket(listener);
        var addr = ws2.sockaddr.in{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
        var len: i32 = @sizeOf(ws2.sockaddr.in);
        if (ws2.bind(listener, @ptrCast(&addr), len) != 0) return error.SocketPairFailed;
        if (ws2.getsockname(listener, @ptrCast(&addr), &len) != 0) return error.SocketPairFailed;
        if (ws2.listen(listener, 1) != 0) return error.SocketPairFailed;
        const a = ws2.socket(ws2.AF.INET, ws2.SOCK.STREAM, ws2.IPPROTO.TCP);
        if (a == ws2.INVALID_SOCKET) return error.SocketPairFailed;
        errdefer _ = ws2.closesocket(a);
        if (ws2.connect(a, @ptrCast(&addr), len) != 0) return error.SocketPairFailed;
        const b = ws2.accept(listener, null, null);
        if (b == ws2.INVALID_SOCKET) return error.SocketPairFailed;
        const one: i32 = 1;
        _ = ws2.setsockopt(a, ws2.IPPROTO.TCP, ws2.TCP.NODELAY, std.mem.asBytes(&one), @sizeOf(i32));
        _ = ws2.setsockopt(b, ws2.IPPROTO.TCP, ws2.TCP.NODELAY, std.mem.asBytes(&one), @sizeOf(i32));
        return .{ b, a };
    }
} else struct {};

test "wake pipe signals and drains" {
    var w = try Wake.init();
    defer w.deinit();
    var fds = [_]PollFd{ pollFd(w.fd(), POLL.IN), pollFd(none, POLL.IN) };
    try std.testing.expectEqual(@as(usize, 0), poll(&fds, 0));
    w.signal();
    w.signal();
    try std.testing.expectEqual(@as(usize, 1), poll(&fds, 100));
    try std.testing.expect(fds[0].revents & POLL.IN != 0);
    w.drain();
    try std.testing.expectEqual(@as(usize, 0), poll(&fds, 0));
}

test "socket pair carries bytes both ways" {
    const p = try socketPair();
    defer close(p[0]);
    defer close(p[1]);
    try std.testing.expectEqual(@as(usize, 3), try write(p[1], "abc"));
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), try read(p[0], &buf));
    try std.testing.expectEqualStrings("abc", buf[0..3]);
}
