//! WebSocket client for the hosted Shared Haunting relay.
//!
//! The Noise handshake already encrypts the session. This layer only carries
//! those bytes: each binary frame is an opaque slice of the stream, and the
//! relay is expected to forward it unchanged. `open` returns a socket that
//! speaks that byte stream. The first server frame is a status byte, matching
//! the TCP rendezvous (`0` paired, anything else rejected).
//!
//! `ws://` is for tests. `wss://` is the hosted relay.

const std = @import("std");
const io = @import("../platform/io.zig");
const netdial = @import("../net/dial.zig");
const link_mod = @import("link.zig");
const invite = @import("invite.zig");
const relay = @import("relay.zig");
const trace = @import("trace.zig");

const posix = std.posix;
const certs = @import("certs.zig");

threadlocal var detail_buf: [192]u8 = undefined;
threadlocal var detail_len: usize = 0;

fn setDetail(text: []const u8) void {
    const n = @min(text.len, detail_buf.len);
    @memcpy(detail_buf[0..n], text[0..n]);
    detail_len = n;
}

fn setDetailFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [192]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    setDetail(text);
}

fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < head.len) {
        const line_end = std.mem.indexOfPos(u8, head, i, "\r\n") orelse break;
        const line = head[i..line_end];
        if (line.len > name.len + 1 and std.ascii.eqlIgnoreCase(line[0..name.len], name) and line[name.len] == ':') {
            return std.mem.trim(u8, line[name.len + 1 ..], " \t");
        }
        i = line_end + 2;
    }
    return null;
}

fn noteHttp(prefix: []const u8, bytes: []const u8) void {
    var shown: [64]u8 = undefined;
    const m = @min(bytes.len, shown.len);
    for (bytes[0..m], 0..) |b, i| shown[i] = if (b >= 32 and b < 127) b else '.';
    setDetailFmt("{s}: {s}", .{ prefix, shown[0..m] });
}

/// Last failure from this thread's `open`, or empty.
pub fn takeDetail() []const u8 {
    if (detail_len == 0) return "";
    return detail_buf[0..detail_len];
}

pub const max_frame: usize = 64 * 1024;
const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const Error = error{
    Timeout,
    Cancelled,
    Closed,
    RelayRejected,
    BadRelay,
    OutOfMemory,
    Tls,
    WouldBlock,
};

const Wait = struct {
    cancel: ?netdial.CancelFn,
    /// 0 means no deadline (still observes cancel).
    deadline: i64,

    fn check(self: Wait) Error!void {
        if (netdial.CancelFn.check(self.cancel)) return error.Cancelled;
        if (self.deadline != 0 and std.time.milliTimestamp() >= self.deadline) return error.Timeout;
    }
};

const Target = struct {
    buf: [253]u8 = undefined,
    host_len: usize = 0,
    port: u16 = 0,
    tls: bool = false,

    fn host(self: *const Target) []const u8 {
        return self.buf[0..self.host_len];
    }
};

fn parseUrl(url: []const u8) Error!Target {
    if (url.len == 0 or url.len > invite.max_relay) return error.BadRelay;
    const uri = std.Uri.parse(url) catch return error.BadRelay;
    const tls = if (std.ascii.eqlIgnoreCase(uri.scheme, "wss"))
        true
    else if (std.ascii.eqlIgnoreCase(uri.scheme, "ws"))
        false
    else
        return error.BadRelay;
    if (uri.user != null) return error.BadRelay;
    const host_c = uri.host orelse return error.BadRelay;
    var raw_buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&raw_buf);
    const host = host_c.toRawMaybeAlloc(fba.allocator()) catch return error.BadRelay;
    if (host.len == 0 or host.len > 253) return error.BadRelay;
    const port = uri.port orelse if (tls) @as(u16, 443) else @as(u16, 80);
    if (port == 0) return error.BadRelay;
    var t = Target{ .host_len = host.len, .port = port, .tls = tls };
    @memcpy(t.buf[0..host.len], host);
    return t;
}

fn mapDial(err: netdial.Error) Error {
    setDetailFmt("connect {s}", .{@errorName(err)});
    return switch (err) {
        error.Timeout => error.Timeout,
        error.Cancelled => error.Cancelled,
        error.OutOfMemory => error.OutOfMemory,
        else => error.Closed,
    };
}

fn mapIo(err: anyerror) Error {
    return switch (err) {
        error.WouldBlock, error.ConnectionTimedOut => error.WouldBlock,
        error.OutOfMemory => error.OutOfMemory,
        error.Cancelled => error.Cancelled,
        error.Timeout => error.Timeout,
        else => {
            setDetailFmt("io {s}", .{@errorName(err)});
            return error.Closed;
        },
    };
}

fn setRecvTimeout(fd: posix.socket_t, ms: u32) void {
    if (@import("builtin").os.tag == .windows) {
        const v: u32 = ms;
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&v)) catch {};
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&v)) catch {};
        return;
    }
    const tv = posix.timeval{ .tv_sec = @intCast(ms / 1000), .tv_usec = @intCast((ms % 1000) * 1000) };
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&tv)) catch {};
}

const Io = struct {
    tcp: std.net.Stream,
    tls: ?*std.crypto.tls.Client,

    fn readSome(self: Io, buf: []u8) Error!usize {
        if (self.tls) |t| return t.read(self.tcp, buf) catch |err| return mapIo(err);
        return io.read(self.tcp.handle, buf) catch |err| return mapIo(err);
    }

    fn writeSome(self: Io, data: []const u8) Error!usize {
        if (self.tls) |t| return t.write(self.tcp, data) catch |err| return mapIo(err);
        return io.write(self.tcp.handle, data) catch |err| return mapIo(err);
    }
};

fn readExact(pipe: Io, buf: []u8, wait: Wait) Error!void {
    var got: usize = 0;
    while (got < buf.len) {
        try wait.check();
        const n = pipe.readSome(buf[got..]) catch |err| switch (err) {
            error.WouldBlock => {
                var fds = [_]io.PollFd{io.pollFd(pipe.tcp.handle, io.POLL.IN)};
                _ = io.poll(&fds, 50);
                continue;
            },
            else => |e| return e,
        };
        if (n == 0) {
            setDetail("eof");
            return error.Closed;
        }
        got += n;
    }
}

fn writeAll(pipe: Io, data: []const u8, wait: Wait) Error!void {
    var off: usize = 0;
    while (off < data.len) {
        try wait.check();
        const n = pipe.writeSome(data[off..]) catch |err| switch (err) {
            error.WouldBlock => {
                var fds = [_]io.PollFd{io.pollFd(pipe.tcp.handle, io.POLL.OUT)};
                _ = io.poll(&fds, 50);
                continue;
            },
            else => |e| return e,
        };
        if (n == 0) return error.Closed;
        off += n;
    }
}

fn idHex(id: *const [8]u8, out: *[16]u8) void {
    const hex = "0123456789abcdef";
    for (id, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0xf];
    }
}

pub fn acceptKey(key: []const u8, out: *[28]u8) void {
    var hash = std.crypto.hash.Sha1.init(.{});
    hash.update(key);
    hash.update(guid);
    var dig: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    hash.final(&dig);
    const n = std.base64.standard.Encoder.encode(out, &dig).len;
    std.debug.assert(n == out.len);
}

fn sendFrame(pipe: Io, opcode: u8, payload: []const u8, masked: bool, wait: Wait) Error!void {
    if (payload.len > max_frame) return error.Closed;
    var hdr: [14]u8 = undefined;
    hdr[0] = 0x80 | opcode;
    var n: usize = 2;
    const mask_bit: u8 = if (masked) 0x80 else 0;
    if (payload.len < 126) {
        hdr[1] = mask_bit | @as(u8, @intCast(payload.len));
    } else {
        hdr[1] = mask_bit | 126;
        std.mem.writeInt(u16, hdr[2..4], @intCast(payload.len), .big);
        n = 4;
    }
    var mask: [4]u8 = .{ 0, 0, 0, 0 };
    if (masked) {
        std.crypto.random.bytes(&mask);
        @memcpy(hdr[n..][0..4], &mask);
        n += 4;
    }
    try writeAll(pipe, hdr[0..n], wait);
    if (!masked) {
        try writeAll(pipe, payload, wait);
        return;
    }
    var chunk: [2048]u8 = undefined;
    var off: usize = 0;
    while (off < payload.len) {
        const m = @min(chunk.len, payload.len - off);
        for (0..m) |j| chunk[j] = payload[off + j] ^ mask[(off + j) % 4];
        try writeAll(pipe, chunk[0..m], wait);
        off += m;
    }
}

/// Next binary message. Ping is answered. A close frame is `error.Closed`.
fn readData(pipe: Io, buf: []u8, wait: Wait) Error![]u8 {
    while (true) {
        var hdr: [2]u8 = undefined;
        try readExact(pipe, &hdr, wait);
        const fin = (hdr[0] & 0x80) != 0;
        const opcode = hdr[0] & 0x0f;
        const masked = (hdr[1] & 0x80) != 0;
        var len: usize = hdr[1] & 0x7f;
        if (len == 126) {
            var ext: [2]u8 = undefined;
            try readExact(pipe, &ext, wait);
            len = std.mem.readInt(u16, &ext, .big);
        } else if (len == 127) return error.Closed;
        if (len > max_frame) return error.Closed;
        var mask: [4]u8 = undefined;
        if (masked) try readExact(pipe, &mask, wait);
        var ctrl: [128]u8 = undefined;
        const dst = if (opcode == 0x2) buf else &ctrl;
        if (len > dst.len) return error.Closed;
        try readExact(pipe, dst[0..len], wait);
        if (masked) {
            for (dst[0..len], 0..) |*b, i| b.* ^= mask[i % 4];
        }
        switch (opcode) {
            0x9 => try sendFrame(pipe, 0xA, dst[0..len], true, wait),
            0xA => {},
            0x8 => {
                setDetail("websocket close");
                return error.Closed;
            },
            0x2 => {
                if (!fin) {
                    setDetail("fragmented websocket frame");
                    return error.Closed;
                }
                return dst[0..len];
            },
            else => {
                setDetailFmt("websocket opcode {d}", .{opcode});
                return error.Closed;
            },
        }
    }
}

fn httpUpgrade(pipe: Io, target: Target, role: relay.Role, id: *const [8]u8, wait: Wait) Error!void {
    var raw_key: [16]u8 = undefined;
    std.crypto.random.bytes(&raw_key);
    var key: [24]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&key, &raw_key);
    var hex_id: [16]u8 = undefined;
    idHex(id, &hex_id);
    const role_name = switch (role) {
        .host => "host",
        .guest => "guest",
    };
    var req: [512]u8 = undefined;
    const host_hdr = if ((target.tls and target.port == 443) or (!target.tls and target.port == 80))
        target.host()
    else
        "";
    const text = if (host_hdr.len > 0)
        std.fmt.bufPrint(&req, "GET /v1/{s}?role={s} HTTP/1.1\r\nHost: {s}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\nUser-Agent: deathterminal\r\n\r\n", .{ hex_id, role_name, host_hdr, key }) catch return error.BadRelay
    else
        std.fmt.bufPrint(&req, "GET /v1/{s}?role={s} HTTP/1.1\r\nHost: {s}:{d}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\nUser-Agent: deathterminal\r\n\r\n", .{ hex_id, role_name, target.host(), target.port, key }) catch return error.BadRelay;
    try writeAll(pipe, text, wait);

    // One byte at a time. A larger read would swallow the WebSocket frame
    // that the relay sends immediately after the headers.
    var hdr: [8192]u8 = undefined;
    var n: usize = 0;
    while (n + 1 < hdr.len) {
        try readExact(pipe, hdr[n .. n + 1], wait);
        n += 1;
        if (n >= 4 and std.mem.endsWith(u8, hdr[0..n], "\r\n\r\n")) break;
    } else {
        noteHttp("http header truncated", hdr[0..@min(n, hdr.len)]);
        return error.Closed;
    }
    const head = hdr[0..n];
    const line_end = std.mem.indexOf(u8, head, "\r\n") orelse {
        setDetail("http status missing");
        return error.Closed;
    };
    const status = head[0..line_end];
    trace.log("websocket upgrade {s}", .{status});
    if (std.mem.indexOf(u8, status, " 101 ") == null) {
        var peek: [64]u8 = undefined;
        var pn: usize = 0;
        while (pn < peek.len) {
            const nread = pipe.readSome(peek[pn..]) catch break;
            if (nread == 0) break;
            pn += nread;
        }
        var shown: [64]u8 = undefined;
        for (peek[0..pn], 0..) |b, i| shown[i] = if (b >= 32 and b < 127) b else '.';
        const req_line_end = std.mem.indexOf(u8, text, "\r\n") orelse text.len;
        setDetailFmt("{s} body {s} req {s}", .{ status, shown[0..pn], text[0..req_line_end] });
        return error.RelayRejected;
    }
    const got = headerValue(head, "Sec-WebSocket-Accept") orelse {
        noteHttp("missing accept", status);
        return error.RelayRejected;
    };
    var expect: [28]u8 = undefined;
    acceptKey(&key, &expect);
    if (!std.mem.eql(u8, got, &expect)) {
        setDetail("websocket accept mismatch");
        return error.RelayRejected;
    }
}

const Pump = struct {
    tcp: std.net.Stream,
    tls: ?*std.crypto.tls.Client,
    mine: io.Fd,

    fn run(self: *Pump) void {
        defer {
            if (self.tls) |t| std.heap.page_allocator.destroy(t);
            self.tcp.close();
            io.close(self.mine);
            std.heap.page_allocator.destroy(self);
        }
        const pipe = Io{ .tcp = self.tcp, .tls = self.tls };
        const wait = Wait{ .cancel = null, .deadline = 0 };
        var app: [16 * 1024]u8 = undefined;
        var net_buf: [max_frame]u8 = undefined;
        while (true) {
            const pending = if (self.tls) |t| t.partial_cleartext_idx < t.partial_ciphertext_idx else false;
            var fds = [_]io.PollFd{
                io.pollFd(self.mine, io.POLL.IN),
                io.pollFd(self.tcp.handle, io.POLL.IN),
            };
            if (!pending and io.poll(&fds, 50) == 0) continue;
            if ((fds[0].revents & (io.POLL.IN | io.POLL.HUP | io.POLL.ERR)) != 0) {
                const n = io.read(self.mine, &app) catch |err| switch (err) {
                    error.WouldBlock => 0,
                    else => return,
                };
                if (n == 0) return;
                sendFrame(pipe, 0x2, app[0..n], true, wait) catch return;
            }
            if (pending or (fds[1].revents & (io.POLL.IN | io.POLL.HUP | io.POLL.ERR)) != 0) {
                const msg = readData(pipe, &net_buf, wait) catch return;
                if (!writeFd(self.mine, msg)) return;
            }
        }
    }
};

fn writeFd(fd: io.Fd, data: []const u8) bool {
    var off: usize = 0;
    while (off < data.len) {
        const n = io.write(fd, data[off..]) catch |err| switch (err) {
            error.WouldBlock => {
                var fds = [_]io.PollFd{io.pollFd(fd, io.POLL.OUT)};
                _ = io.poll(&fds, 50);
                continue;
            },
            else => return false,
        };
        if (n == 0) return false;
        off += n;
    }
    return true;
}

/// Dial the relay and wait until the other role is present. The returned
/// socket is the clear byte stream (Noise), not WebSocket frames.
/// `wait_peer` is the host: it blocks until cancelled or the guest arrives.
pub fn open(url: []const u8, role: relay.Role, id: *const [8]u8, cancel: ?netdial.CancelFn, wait_peer: bool) Error!std.net.Stream {
    io.ensureSockets();
    io.ignoreSigpipe();
    detail_len = 0;
    const role_name = switch (role) {
        .host => "host",
        .guest => "guest",
    };
    trace.log("relay dial {s} role {s}", .{ url, role_name });
    const target = try parseUrl(url);
    const fd = netdial.connect(target.host(), target.port, 15000, cancel) catch |err| return mapDial(err);
    var tcp = std.net.Stream{ .handle = fd };
    var tcp_owned = true;
    errdefer if (tcp_owned) tcp.close();
    link_mod.setNoDelay(tcp);
    io.armSocket(tcp.handle);
    trace.log("tcp connected {s}:{d}", .{ target.host(), target.port });

    var tls_ptr: ?*std.crypto.tls.Client = null;
    errdefer if (tcp_owned and tls_ptr != null) std.heap.page_allocator.destroy(tls_ptr.?);
    if (target.tls) {
        var bundle = std.crypto.Certificate.Bundle{};
        certs.scan(&bundle, std.heap.page_allocator) catch |err| {
            setDetailFmt("certificates {s}", .{@errorName(err)});
            return error.Tls;
        };
        defer bundle.deinit(std.heap.page_allocator);
        const t = std.heap.page_allocator.create(std.crypto.tls.Client) catch return error.OutOfMemory;
        tls_ptr = t;
        // Client.init blocks in the handshake and does not see the dial
        // cancel flag. A socket timer is what makes a stuck workers.dev
        // handshake return instead of holding the join thread.
        trace.log("tls handshake {s}", .{target.host()});
        setRecvTimeout(tcp.handle, 10_000);
        t.* = std.crypto.tls.Client.init(tcp, bundle, target.host()) catch |err| {
            setRecvTimeout(tcp.handle, 0);
            trace.log("tls handshake {s} {s}", .{ target.host(), @errorName(err) });
            setDetailFmt("TLS {s}", .{@errorName(err)});
            return error.Tls;
        };
        setRecvTimeout(tcp.handle, 0);
        t.allow_truncation_attacks = true;
        trace.log("tls handshake done {s}", .{target.host()});
    }
    io.setNonBlocking(tcp.handle) catch {};

    const connect_wait = Wait{ .cancel = cancel, .deadline = std.time.milliTimestamp() + 15000 };
    const pipe = Io{ .tcp = tcp, .tls = tls_ptr };
    try httpUpgrade(pipe, target, role, id, connect_wait);
    const peer_wait = Wait{
        .cancel = cancel,
        .deadline = if (wait_peer) 0 else std.time.milliTimestamp() + 20000,
    };
    var status_buf: [8]u8 = undefined;
    const status = try readData(pipe, &status_buf, peer_wait);
    if (status.len != 1 or status[0] != relay.status_ok) return error.RelayRejected;
    trace.log("relay paired role {s}", .{role_name});

    const pair = io.socketPair() catch return error.Closed;
    errdefer io.close(pair[1]);
    io.setNonBlocking(pair[0]) catch {};
    const pump = std.heap.page_allocator.create(Pump) catch {
        io.close(pair[0]);
        return error.OutOfMemory;
    };
    pump.* = .{ .tcp = tcp, .tls = tls_ptr, .mine = pair[0] };
    const thread = std.Thread.spawn(.{}, Pump.run, .{pump}) catch {
        io.close(pair[0]);
        std.heap.page_allocator.destroy(pump);
        return error.OutOfMemory;
    };
    thread.detach();
    tcp_owned = false;
    return .{ .handle = pair[1] };
}

/// In-process relay that speaks the same WebSocket preface as the Worker.
/// Tests use it as a loopback. It stores forwarded payloads so a test can
/// see that the invite secret never appears as plaintext.
pub const Mock = struct {
    allocator: std.mem.Allocator,
    listener: std.net.Server,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    accept_thread: std.Thread = undefined,
    mu: std.Thread.Mutex = .{},
    threads: std.ArrayList(std.Thread),
    forwarded: std.ArrayList(u8),
    hosts: usize = 0,
    guests: usize = 0,
    slots: [4]Slot = [_]Slot{.{}} ** 4,

    const Slot = struct {
        used: bool = false,
        id: [8]u8 = [_]u8{0} ** 8,
        host: ?std.net.Stream = null,
        guest: ?std.net.Stream = null,
    };

    pub fn start(allocator: std.mem.Allocator) !*Mock {
        io.ensureSockets();
        const addr = try std.net.Address.parseIp("127.0.0.1", 0);
        const listener = try addr.listen(.{ .reuse_address = true, .force_nonblocking = true });
        const self = try allocator.create(Mock);
        self.* = .{
            .allocator = allocator,
            .listener = listener,
            .threads = std.ArrayList(std.Thread).init(allocator),
            .forwarded = std.ArrayList(u8).init(allocator),
        };
        self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
        return self;
    }

    pub fn port(self: *Mock) u16 {
        return self.listener.listen_address.getPort();
    }

    pub fn deinit(self: *Mock) void {
        self.stop.store(true, .seq_cst);
        self.accept_thread.join();
        self.mu.lock();
        for (&self.slots) |*s| {
            if (s.host) |st| st.close();
            if (s.guest) |st| st.close();
            s.* = .{};
        }
        self.mu.unlock();
        while (true) {
            self.mu.lock();
            const next = self.threads.popOrNull();
            self.mu.unlock();
            const thread = next orelse break;
            thread.join();
        }
        self.listener.deinit();
        self.forwarded.deinit();
        self.threads.deinit();
        self.allocator.destroy(self);
    }

    pub fn contains(self: *Mock, needle: []const u8) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return std.mem.indexOf(u8, self.forwarded.items, needle) != null;
    }

    pub fn forwardedLen(self: *Mock) usize {
        self.mu.lock();
        defer self.mu.unlock();
        return self.forwarded.items.len;
    }

    pub fn guestCount(self: *Mock) usize {
        self.mu.lock();
        defer self.mu.unlock();
        return self.guests;
    }

    fn acceptLoop(self: *Mock) void {
        while (!self.stop.load(.seq_cst)) {
            var fds = [_]io.PollFd{io.pollFd(self.listener.stream.handle, io.POLL.IN)};
            if (io.poll(&fds, 50) == 0) continue;
            const conn = self.listener.accept() catch continue;
            setRecvTimeout(conn.stream.handle, 200);
            const thread = std.Thread.spawn(.{}, greet, .{ self, conn.stream }) catch {
                conn.stream.close();
                continue;
            };
            self.mu.lock();
            self.threads.append(thread) catch {
                self.mu.unlock();
                conn.stream.close();
                continue;
            };
            self.mu.unlock();
        }
    }

    fn greet(self: *Mock, stream: std.net.Stream) void {
        var hdr: [2048]u8 = undefined;
        const head = readHttp(self, stream, &hdr) catch {
            stream.close();
            return;
        };
        const req = parseUpgrade(head) orelse {
            stream.close();
            return;
        };
        if (writeSwitching(stream, req.key[0..req.key_len])) |_| {} else |_| {
            stream.close();
            return;
        }
        self.mu.lock();
        var slot: *Slot = undefined;
        var found = false;
        for (&self.slots) |*s| {
            if (s.used and std.mem.eql(u8, &s.id, &req.id)) {
                slot = s;
                found = true;
                break;
            }
        }
        if (!found) {
            for (&self.slots) |*s| if (!s.used) {
                s.* = .{ .used = true, .id = req.id };
                slot = s;
                found = true;
                break;
            };
        }
        if (!found) {
            self.mu.unlock();
            writeStatus(stream, relay.status_busy) catch {};
            stream.close();
            return;
        }
        const taken = switch (req.role) {
            .host => slot.host != null,
            .guest => slot.guest != null,
        };
        if (taken) {
            self.mu.unlock();
            writeStatus(stream, relay.status_busy) catch {};
            stream.close();
            return;
        }
        switch (req.role) {
            .host => {
                slot.host = stream;
                self.hosts += 1;
            },
            .guest => {
                slot.guest = stream;
                self.guests += 1;
            },
        }
        if (slot.host == null or slot.guest == null) {
            self.mu.unlock();
            return;
        }
        const a = slot.host.?;
        const b = slot.guest.?;
        slot.* = .{};
        self.mu.unlock();
        if (writeStatus(a, relay.status_ok)) |_| {} else |_| {
            a.close();
            b.close();
            return;
        }
        if (writeStatus(b, relay.status_ok)) |_| {} else |_| {
            a.close();
            b.close();
            return;
        }
        splice(self, a, b);
    }
};

const Upgrade = struct {
    id: [8]u8,
    role: relay.Role,
    key: [64]u8 = undefined,
    key_len: usize = 0,
};

fn parseUpgrade(hdr: []const u8) ?Upgrade {
    const line_end = std.mem.indexOf(u8, hdr, "\r\n") orelse return null;
    const line = hdr[0..line_end];
    const path_at = std.mem.indexOf(u8, line, " /v1/") orelse return null;
    const path = line[path_at + 1 ..];
    const sp = std.mem.indexOfScalar(u8, path, ' ') orelse return null;
    const target = path[0..sp];
    if (target.len < 4 + 16 + "?role=host".len) return null;
    if (!std.mem.startsWith(u8, target, "/v1/")) return null;
    var up = Upgrade{ .id = undefined, .role = .host };
    _ = std.fmt.hexToBytes(&up.id, target[4..20]) catch return null;
    const q = target[20..];
    if (std.mem.eql(u8, q, "?role=host")) up.role = .host else if (std.mem.eql(u8, q, "?role=guest")) up.role = .guest else return null;
    const mark = "Sec-WebSocket-Key: ";
    const at = std.mem.indexOf(u8, hdr, mark) orelse return null;
    const rest = hdr[at + mark.len ..];
    const end = std.mem.indexOf(u8, rest, "\r\n") orelse return null;
    const key = std.mem.trim(u8, rest[0..end], " ");
    if (key.len == 0 or key.len > up.key.len) return null;
    @memcpy(up.key[0..key.len], key);
    up.key_len = key.len;
    return up;
}

fn readHttp(mock: *Mock, stream: std.net.Stream, buf: []u8) ![]u8 {
    var n: usize = 0;
    while (n + 1 < buf.len) {
        if (mock.stop.load(.seq_cst)) return error.Cancelled;
        const got = stream.read(buf[n .. n + 1]) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return error.Closed,
        };
        if (got == 0) return error.Closed;
        n += got;
        if (n >= 4 and std.mem.endsWith(u8, buf[0..n], "\r\n\r\n")) return buf[0..n];
    }
    return error.Closed;
}

fn writeSwitching(stream: std.net.Stream, key: []const u8) !void {
    var accept: [28]u8 = undefined;
    acceptKey(key, &accept);
    var resp: [256]u8 = undefined;
    const text = try std.fmt.bufPrint(&resp, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{accept});
    try stream.writeAll(text);
}

fn writeStatus(stream: std.net.Stream, status: u8) !void {
    // Server frames are not masked. One-byte binary payload.
    var frame = [_]u8{ 0x82, 1, status };
    try stream.writeAll(&frame);
}

fn readFrame(mock: *Mock, stream: std.net.Stream, buf: []u8) ![]u8 {
    while (true) {
        var hdr: [2]u8 = undefined;
        try readSock(mock, stream, &hdr);
        const opcode = hdr[0] & 0x0f;
        const masked = (hdr[1] & 0x80) != 0;
        var len: usize = hdr[1] & 0x7f;
        if (len == 126) {
            var ext: [2]u8 = undefined;
            try readSock(mock, stream, &ext);
            len = std.mem.readInt(u16, &ext, .big);
        } else if (len == 127) return error.Closed;
        if (len > buf.len) return error.Closed;
        var mask: [4]u8 = undefined;
        if (masked) try readSock(mock, stream, &mask);
        try readSock(mock, stream, buf[0..len]);
        if (masked) {
            for (buf[0..len], 0..) |*b, i| b.* ^= mask[i % 4];
        }
        switch (opcode) {
            0x9 => {
                var pong: [140]u8 = undefined;
                if (len + 2 > pong.len) return error.Closed;
                pong[0] = 0x8A;
                pong[1] = @intCast(len);
                @memcpy(pong[2..][0..len], buf[0..len]);
                stream.writeAll(pong[0 .. 2 + len]) catch return error.Closed;
            },
            0xA => {},
            0x8 => return error.Closed,
            0x2 => return buf[0..len],
            else => return error.Closed,
        }
    }
}

fn readSock(mock: *Mock, stream: std.net.Stream, buf: []u8) !void {
    var got: usize = 0;
    while (got < buf.len) {
        if (mock.stop.load(.seq_cst)) return error.Cancelled;
        const n = stream.read(buf[got..]) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return error.Closed,
        };
        if (n == 0) return error.Closed;
        got += n;
    }
}

fn splice(mock: *Mock, a: std.net.Stream, b: std.net.Stream) void {
    defer a.close();
    defer b.close();
    var buf: [max_frame]u8 = undefined;
    var a_open = true;
    var b_open = true;
    while (a_open or b_open) {
        if (mock.stop.load(.seq_cst)) return;
        var fds = [_]io.PollFd{
            io.pollFd(if (a_open) a.handle else io.none, io.POLL.IN),
            io.pollFd(if (b_open) b.handle else io.none, io.POLL.IN),
        };
        if (io.poll(&fds, 50) == 0) continue;
        const ends = [_]struct { *bool, std.net.Stream, std.net.Stream }{
            .{ &a_open, a, b },
            .{ &b_open, b, a },
        };
        for (ends, &fds) |e, *f| {
            if (!e[0].* or f.revents == 0) continue;
            const msg = readFrame(mock, e[1], &buf) catch {
                e[0].* = false;
                continue;
            };
            note(mock, msg);
            var frame_buf: [max_frame + 4]u8 = undefined;
            if (msg.len + 4 > frame_buf.len) {
                e[0].* = false;
                continue;
            }
            frame_buf[0] = 0x82;
            var n: usize = 2;
            if (msg.len < 126) {
                frame_buf[1] = @intCast(msg.len);
            } else {
                frame_buf[1] = 126;
                std.mem.writeInt(u16, frame_buf[2..4], @intCast(msg.len), .big);
                n = 4;
            }
            @memcpy(frame_buf[n..][0..msg.len], msg);
            e[2].writeAll(frame_buf[0 .. n + msg.len]) catch {
                e[0].* = false;
            };
        }
    }
}

fn note(self: *Mock, msg: []const u8) void {
    self.mu.lock();
    defer self.mu.unlock();
    if (self.forwarded.items.len > 256 * 1024) return;
    self.forwarded.appendSlice(msg) catch {};
}

test "websocket accept key matches RFC 6455" {
    var out: [28]u8 = undefined;
    acceptKey("dGhlIHNhbXBsZSBub25jZQ==", &out);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &out);
}

test "mock relay forwards opaque frames" {
    io.ensureSockets();
    const mock = try Mock.start(std.testing.allocator);
    defer mock.deinit();
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "ws://127.0.0.1:{d}", .{mock.port()});
    const id = [_]u8{ 9, 8, 7, 6, 5, 4, 3, 2 };

    const Ctx = struct {
        url: []const u8,
        id: [8]u8,
        role: relay.Role,
        stream: ?std.net.Stream = null,
        err: ?anyerror = null,
        fn go(self: *@This()) void {
            self.stream = open(self.url, self.role, &self.id, null, false) catch |e| {
                self.err = e;
                return;
            };
        }
    };
    var host_c = Ctx{ .url = url, .id = id, .role = .host };
    var guest_c = Ctx{ .url = url, .id = id, .role = .guest };
    const th = try std.Thread.spawn(.{}, Ctx.go, .{&host_c});
    std.time.sleep(20 * std.time.ns_per_ms);
    const tg = try std.Thread.spawn(.{}, Ctx.go, .{&guest_c});
    th.join();
    tg.join();
    defer {
        if (host_c.stream) |s| s.close();
        if (guest_c.stream) |s| s.close();
    }
    try std.testing.expect(host_c.err == null);
    try std.testing.expect(guest_c.err == null);
    const marker = "OPAQUE-MARKER-91";
    try host_c.stream.?.writeAll(marker);
    var buf: [64]u8 = undefined;
    var got: usize = 0;
    const deadline = std.time.milliTimestamp() + 2000;
    while (got < marker.len and std.time.milliTimestamp() < deadline) {
        var fds = [_]io.PollFd{io.pollFd(guest_c.stream.?.handle, io.POLL.IN)};
        if (io.poll(&fds, 50) == 0) continue;
        const n = io.read(guest_c.stream.?.handle, buf[got..]) catch break;
        if (n == 0) break;
        got += n;
    }
    try std.testing.expectEqualStrings(marker, buf[0..got]);
    try std.testing.expect(mock.forwardedLen() >= marker.len);
    try std.testing.expect(mock.contains(marker));
}
