//! TCP connect with a real deadline, covering name resolution and the
//! connect itself (std.net.tcpConnectToHost can block for minutes on an
//! unroutable host). Used by the AI client and the SSH client.
//!
//! getaddrinfo cannot be interrupted, so it runs on a short-lived helper
//! thread; if the deadline passes first the caller gives up and the helper
//! cleans up after itself when the lookup eventually returns.

const std = @import("std");
const builtin = @import("builtin");
const io = @import("../platform/io.zig");
const posix = std.posix;

pub const Error = error{
    Timeout,
    Cancelled,
    /// Nothing listening (every address refused).
    Refused,
    /// No route / network down.
    Unreachable,
    UnknownHost,
    OutOfMemory,
    Unexpected,
};

pub const max_addrs = 8;

pub const AddrList = struct {
    items: [max_addrs]std.net.Address = undefined,
    len: usize = 0,

    pub fn slice(self: *const AddrList) []const std.net.Address {
        return self.items[0..self.len];
    }
};

/// Polled while waiting; return true to abort with error.Cancelled.
pub const CancelFn = struct {
    ctx: *anyopaque,
    f: *const fn (*anyopaque) bool,

    pub fn check(self: ?CancelFn) bool {
        const c = self orelse return false;
        return c.f(c.ctx);
    }
};

/// Name lookup used by `resolve`; tests swap it for a slow one.
pub var lookup: *const fn (host: []const u8, port: u16, out: *AddrList) anyerror!void = systemLookup;

fn systemLookup(host: []const u8, port: u16, out: *AddrList) anyerror!void {
    const list = try std.net.getAddressList(std.heap.page_allocator, host, port);
    defer list.deinit();
    for (list.addrs) |a| {
        if (out.len == max_addrs) break;
        out.items[out.len] = a;
        out.len += 1;
    }
    if (out.len == 0) return error.UnknownHostName;
}

const Lookup = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    done: bool = false,
    abandoned: bool = false,
    err: ?anyerror = null,
    result: AddrList = .{},
    host: [256]u8 = undefined,
    host_len: usize = 0,
    port: u16 = 0,

    fn run(self: *Lookup) void {
        var res = AddrList{};
        const err: ?anyerror = if (lookup(self.host[0..self.host_len], self.port, &res)) null else |e| e;
        self.mutex.lock();
        if (self.abandoned) {
            self.mutex.unlock();
            std.heap.page_allocator.destroy(self);
            return;
        }
        self.result = res;
        self.err = err;
        self.done = true;
        self.cond.signal();
        self.mutex.unlock();
    }
};

fn mapLookupError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnknownHostName, error.HostLacksNetworkAddresses, error.TemporaryNameServerFailure, error.NameServerFailure, error.InvalidCharacter => error.UnknownHost,
        error.NetworkUnreachable => error.Unreachable,
        else => error.UnknownHost,
    };
}

/// Resolve `host` (IP literals skip the lookup) before `deadline_ms`.
pub fn resolve(host: []const u8, port: u16, deadline_ms: i64, cancel: ?CancelFn) Error!AddrList {
    var out = AddrList{};
    if (std.net.Address.parseIp(host, port)) |a| {
        out.items[0] = a;
        out.len = 1;
        return out;
    } else |_| {}
    if (host.len == 0 or host.len > 255) return error.UnknownHost;

    const st = std.heap.page_allocator.create(Lookup) catch return error.OutOfMemory;
    st.* = .{ .port = port };
    @memcpy(st.host[0..host.len], host);
    st.host_len = host.len;
    const th = std.Thread.spawn(.{}, Lookup.run, .{st}) catch {
        std.heap.page_allocator.destroy(st);
        return error.Unexpected;
    };
    th.detach();

    st.mutex.lock();
    while (!st.done) {
        const now = std.time.milliTimestamp();
        const left = deadline_ms - now;
        const cancelled = CancelFn.check(cancel);
        if (left <= 0 or cancelled) {
            // The helper frees `st` when getaddrinfo finally returns.
            st.abandoned = true;
            st.mutex.unlock();
            return if (cancelled) error.Cancelled else error.Timeout;
        }
        const slice_ms: u64 = @intCast(@min(left, 50));
        st.cond.timedWait(&st.mutex, slice_ms * std.time.ns_per_ms) catch {};
    }
    const err = st.err;
    out = st.result;
    st.mutex.unlock();
    std.heap.page_allocator.destroy(st);
    if (err) |e| return mapLookupError(e);
    return out;
}

/// Connect to one address before `deadline_ms`. The socket comes back in
/// blocking mode.
/// shutdown(2) that never traps. On Windows std's posix.shutdown treats
/// WSAEINVAL/WSAENOTSOCK as unreachable, and Wine returns them for a socket
/// another thread is blocked reading. Errors don't matter to callers here.
pub fn shutdownSocket(fd: posix.socket_t, how: posix.ShutdownHow) void {
    if (builtin.os.tag == .windows) {
        const ws2 = std.os.windows.ws2_32;
        _ = ws2.shutdown(fd, switch (how) {
            .recv => ws2.SD_RECEIVE,
            .send => ws2.SD_SEND,
            .both => ws2.SD_BOTH,
        });
    } else posix.shutdown(fd, how) catch {};
}

pub fn closeSocket(fd: posix.socket_t) void {
    if (builtin.os.tag == .windows) {
        _ = std.os.windows.ws2_32.closesocket(fd);
    } else posix.close(fd);
}

pub fn connectAddress(addr: std.net.Address, deadline_ms: i64, cancel: ?CancelFn) Error!posix.socket_t {
    const fd = posix.socket(addr.any.family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK, posix.IPPROTO.TCP) catch return error.Unexpected;
    errdefer closeSocket(fd);
    posix.connect(fd, &addr.any, addr.getOsSockLen()) catch |err| switch (err) {
        error.WouldBlock => {},
        error.ConnectionRefused => return error.Refused,
        error.NetworkUnreachable, error.AddressNotAvailable => return error.Unreachable,
        else => return error.Unexpected,
    };
    while (true) {
        if (CancelFn.check(cancel)) return error.Cancelled;
        const left = deadline_ms - std.time.milliTimestamp();
        if (left <= 0) return error.Timeout;
        var fds = [_]io.PollFd{io.pollFd(fd, io.POLL.OUT)};
        const n = io.poll(&fds, @intCast(@min(left, 50)));
        if (n == 0) continue;
        if (builtin.os.tag == .windows) {
            const ws2 = std.os.windows.ws2_32;
            var so_err: i32 = 0;
            var len: i32 = @sizeOf(i32);
            if (ws2.getsockopt(fd, ws2.SOL.SOCKET, ws2.SO.ERROR, @ptrCast(&so_err), &len) != 0) return error.Unexpected;
            switch (so_err) {
                0 => break,
                10061 => return error.Refused, // WSAECONNREFUSED
                10051, 10065 => return error.Unreachable, // WSAENETUNREACH, WSAEHOSTUNREACH
                10060 => return error.Timeout, // WSAETIMEDOUT
                else => return error.Unexpected,
            }
        }
        var so_err: i32 = 0;
        var len: posix.socklen_t = @sizeOf(i32);
        if (std.c.getsockopt(fd, posix.SOL.SOCKET, posix.SO.ERROR, std.mem.asBytes(&so_err), &len) != 0) return error.Unexpected;
        switch (@as(posix.E, @enumFromInt(so_err))) {
            .SUCCESS => break,
            .CONNREFUSED => return error.Refused,
            .NETUNREACH, .HOSTUNREACH => return error.Unreachable,
            .TIMEDOUT => return error.Timeout,
            else => return error.Unexpected,
        }
    }
    if (builtin.os.tag == .windows) {
        var off: c_ulong = 0;
        if (std.os.windows.ws2_32.ioctlsocket(fd, std.os.windows.ws2_32.FIONBIO, &off) != 0) return error.Unexpected;
        return fd;
    }
    const flags = posix.fcntl(fd, posix.F.GETFL, 0) catch return error.Unexpected;
    _ = posix.fcntl(fd, posix.F.SETFL, flags & ~@as(usize, 1 << @bitOffsetOf(posix.O, "NONBLOCK"))) catch return error.Unexpected;
    return fd;
}

/// Resolve and connect, trying each address in turn, all before
/// `timeout_ms` from now.
pub fn connect(host: []const u8, port: u16, timeout_ms: u32, cancel: ?CancelFn) Error!posix.socket_t {
    const deadline = std.time.milliTimestamp() + timeout_ms;
    const addrs = try resolve(host, port, deadline, cancel);
    var last: Error = error.Refused;
    for (addrs.slice()) |a| {
        return connectAddress(a, deadline, cancel) catch |err| switch (err) {
            error.Refused, error.Unreachable, error.Unexpected => {
                last = err;
                continue;
            },
            else => return err,
        };
    }
    return last;
}

// ------------------------------------------------------------------ tests

const t = std.testing;

test "connect: listening socket, refused port, IP literal" {
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var srv = try addr.listen(.{ .reuse_address = true });
    const port = srv.listen_address.getPort();
    const fd = try connect("127.0.0.1", port, 1000, null);
    posix.close(fd);
    const fd2 = try connect("localhost", port, 1000, null);
    posix.close(fd2);
    srv.deinit();
    try t.expectError(error.Refused, connect("127.0.0.1", port, 1000, null));
}

fn slowLookup(host: []const u8, port: u16, out: *AddrList) anyerror!void {
    _ = host;
    std.time.sleep(800 * std.time.ns_per_ms);
    out.items[0] = try std.net.Address.parseIp("127.0.0.1", port);
    out.len = 1;
}

test "resolve: a hanging lookup times out instead of blocking" {
    const saved = lookup;
    lookup = slowLookup;
    defer lookup = saved;
    const start = std.time.milliTimestamp();
    try t.expectError(error.Timeout, connect("slow.invalid", 80, 200, null));
    try t.expect(std.time.milliTimestamp() - start < 600);
    // Let the abandoned helper finish before the hook is restored.
    std.time.sleep(900 * std.time.ns_per_ms);
}

test "connect: an unroutable address gives up at the deadline" {
    // TEST-NET-1 is never routed; depending on the network this either
    // hangs (and must time out) or fails fast as unreachable.
    const start = std.time.milliTimestamp();
    const r = connect("192.0.2.1", 9, 300, null);
    try t.expect(r == error.Timeout or r == error.Unreachable or r == error.Unexpected);
    try t.expect(std.time.milliTimestamp() - start < 1000);
}

fn alwaysCancelled(_: *anyopaque) bool {
    return true;
}

test "connect: cancellation" {
    var dummy: u8 = 0;
    try t.expectError(error.Cancelled, connect("192.0.2.1", 9, 5000, .{ .ctx = &dummy, .f = alwaysCancelled }));
}
