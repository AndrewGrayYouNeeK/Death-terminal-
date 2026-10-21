//! Optional TCP rendezvous for Shared Haunting.
//!
//! The relay never sees plaintext. A client sends a fixed header (magic,
//! role, 8-byte id) and then the socket becomes a raw pipe. The id is
//! SHA-256(invite secret) truncated; it is not the Noise key. After both
//! the host and the guest register the same id, the relay writes one status
//! byte to each and splices the two TCP streams. The Noise handshake runs
//! through that splice.
//!
//! Direct LAN connections do not use this. `deathterminal --share-relay
//! host:port` runs the server. See docs/SHARING.md.

const std = @import("std");
const io = @import("../platform/io.zig");
const netdial = @import("../net/dial.zig");
const invite = @import("invite.zig");

pub const magic = "DTSH";
pub const version: u8 = 1;
pub const status_ok: u8 = 0;
pub const status_busy: u8 = 1;
pub const status_bad: u8 = 2;

pub const Role = enum(u8) { host = 1, guest = 2 };

const header_len: usize = 4 + 1 + 1 + 8;

pub const OpenError = netdial.Error || error{ Closed, RelayRejected };

fn deadlineOf(timeout_ms: u32) i64 {
    return std.time.milliTimestamp() + @as(i64, timeout_ms);
}

fn writeAll(stream: std.net.Stream, data: []const u8, deadline: i64, cancel: ?netdial.CancelFn) OpenError!void {
    var off: usize = 0;
    while (off < data.len) {
        if (netdial.CancelFn.check(cancel)) return error.Cancelled;
        if (std.time.milliTimestamp() >= deadline) return error.Timeout;
        const n = stream.write(data[off..]) catch |err| switch (err) {
            error.WouldBlock => {
                var fds = [_]io.PollFd{io.pollFd(stream.handle, io.POLL.OUT)};
                _ = io.poll(&fds, 50);
                continue;
            },
            else => return error.Closed,
        };
        if (n == 0) return error.Closed;
        off += n;
    }
}

fn readAll(stream: std.net.Stream, buf: []u8, deadline: i64, cancel: ?netdial.CancelFn) OpenError!void {
    var got: usize = 0;
    while (got < buf.len) {
        if (netdial.CancelFn.check(cancel)) return error.Cancelled;
        const left = deadline - std.time.milliTimestamp();
        if (left <= 0) return error.Timeout;
        var fds = [_]io.PollFd{io.pollFd(stream.handle, io.POLL.IN)};
        if (io.poll(&fds, @intCast(@min(left, 50))) == 0) continue;
        const n = stream.read(buf[got..]) catch return error.Closed;
        if (n == 0) return error.Closed;
        got += n;
    }
}

pub fn preface(stream: std.net.Stream, role: Role, id: *const [8]u8, timeout_ms: u32, cancel: ?netdial.CancelFn) OpenError!void {
    var hdr: [header_len]u8 = undefined;
    @memcpy(hdr[0..4], magic);
    hdr[4] = version;
    hdr[5] = @intFromEnum(role);
    @memcpy(hdr[6..14], id);
    const deadline = deadlineOf(timeout_ms);
    try writeAll(stream, &hdr, deadline, cancel);
    var st: [1]u8 = undefined;
    try readAll(stream, &st, deadline, cancel);
    if (st[0] != status_ok) return error.RelayRejected;
}

/// TCP connect, then the relay preface. The returned stream is blocking and
/// speaks raw Noise bytes from the first byte.
pub fn open(host: []const u8, port: u16, role: Role, id: *const [8]u8, timeout_ms: u32, cancel: ?netdial.CancelFn) OpenError!std.net.Stream {
    io.ensureSockets();
    const fd = try netdial.connect(host, port, timeout_ms, cancel);
    const stream = std.net.Stream{ .handle = fd };
    errdefer stream.close();
    try preface(stream, role, id, timeout_ms, cancel);
    return stream;
}

const Slot = struct {
    used: bool = false,
    id: [8]u8 = [_]u8{0} ** 8,
    host: ?std.net.Stream = null,
    guest: ?std.net.Stream = null,
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    listener: std.net.Server,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: std.Thread = undefined,
    mu: std.Thread.Mutex = .{},
    slots: [8]Slot = [_]Slot{.{}} ** 8,

    pub fn start(allocator: std.mem.Allocator, host: []const u8, listen_port: u16) !*Server {
        io.ensureSockets();
        const addr = std.net.Address.parseIp(host, listen_port) catch return error.BadAddress;
        const listener = try addr.listen(.{ .reuse_address = true, .force_nonblocking = true });
        const self = try allocator.create(Server);
        self.* = .{ .allocator = allocator, .listener = listener };
        self.thread = try std.Thread.spawn(.{}, loop, .{self});
        return self;
    }

    pub fn port(self: *Server) u16 {
        return self.listener.listen_address.getPort();
    }

    pub fn shutdown(self: *Server) void {
        self.stop.store(true, .seq_cst);
        self.thread.join();
        self.dropSlots();
        self.listener.deinit();
        self.allocator.destroy(self);
    }

    fn dropSlots(self: *Server) void {
        self.mu.lock();
        defer self.mu.unlock();
        for (&self.slots) |*s| {
            if (s.host) |st| st.close();
            if (s.guest) |st| st.close();
            s.* = .{};
        }
    }

    fn loop(self: *Server) void {
        while (!self.stop.load(.seq_cst)) {
            var fds = [_]io.PollFd{io.pollFd(self.listener.stream.handle, io.POLL.IN)};
            if (io.poll(&fds, 50) == 0) continue;
            const conn = self.listener.accept() catch continue;
            self.greet(conn.stream);
        }
    }

    fn greet(self: *Server, stream: std.net.Stream) void {
        var hdr: [header_len]u8 = undefined;
        readAll(stream, &hdr, std.time.milliTimestamp() + 2000, null) catch {
            stream.close();
            return;
        };
        if (!std.mem.eql(u8, hdr[0..4], magic) or hdr[4] != version) {
            _ = stream.write(&[_]u8{status_bad}) catch {};
            stream.close();
            return;
        }
        const role = std.meta.intToEnum(Role, hdr[5]) catch {
            stream.close();
            return;
        };
        var id: [8]u8 = undefined;
        @memcpy(&id, hdr[6..14]);
        self.pair(stream, role, id);
    }

    fn pair(self: *Server, stream: std.net.Stream, role: Role, id: [8]u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        var slot: *Slot = undefined;
        var found = false;
        for (&self.slots) |*s| {
            if (s.used and std.mem.eql(u8, &s.id, &id)) {
                slot = s;
                found = true;
                break;
            }
        }
        if (!found) {
            for (&self.slots) |*s| if (!s.used) {
                s.* = .{ .used = true, .id = id };
                slot = s;
                found = true;
                break;
            };
        }
        if (!found) {
            _ = stream.write(&[_]u8{status_busy}) catch {};
            stream.close();
            return;
        }
        switch (role) {
            .host => {
                if (slot.host != null) {
                    _ = stream.write(&[_]u8{status_busy}) catch {};
                    stream.close();
                    return;
                }
                slot.host = stream;
            },
            .guest => {
                if (slot.guest != null) {
                    _ = stream.write(&[_]u8{status_busy}) catch {};
                    stream.close();
                    return;
                }
                slot.guest = stream;
            },
        }
        if (slot.host != null and slot.guest != null) {
            const a = slot.host.?;
            const b = slot.guest.?;
            slot.* = .{};
            // Unlock before spawning: the lock is a defer. Copy the streams
            // out and spawn after the function returns... we still hold the
            // lock here. Spawning under the lock is fine; splice doesn't
            // take it.
            _ = a.write(&[_]u8{status_ok}) catch {
                a.close();
                b.close();
                return;
            };
            _ = b.write(&[_]u8{status_ok}) catch {
                a.close();
                b.close();
                return;
            };
            const th = std.Thread.spawn(.{}, splice, .{ a, b }) catch {
                a.close();
                b.close();
                return;
            };
            th.detach();
        }
    }
};

fn splice(a: std.net.Stream, b: std.net.Stream) void {
    defer a.close();
    defer b.close();
    var buf: [8192]u8 = undefined;
    var a_open = true;
    var b_open = true;
    while (a_open or b_open) {
        var fds = [_]io.PollFd{
            io.pollFd(if (a_open) a.handle else io.none, io.POLL.IN),
            io.pollFd(if (b_open) b.handle else io.none, io.POLL.IN),
        };
        if (io.poll(&fds, 200) == 0) continue;
        const ends = [_]struct { *bool, std.net.Stream, std.net.Stream }{
            .{ &a_open, a, b },
            .{ &b_open, b, a },
        };
        for (ends, &fds) |e, *f| {
            if (!e[0].* or f.revents == 0) continue;
            const n = e[1].read(&buf) catch {
                e[0].* = false;
                continue;
            };
            if (n == 0) {
                e[0].* = false;
                continue;
            }
            var off: usize = 0;
            while (off < n) {
                const w = e[2].write(buf[off..n]) catch {
                    e[0].* = false;
                    break;
                };
                if (w == 0) {
                    e[0].* = false;
                    break;
                }
                off += w;
            }
        }
    }
}

/// Run until the process is killed. Used by `deathterminal --share-relay`.
pub fn serveUntilSignal(spec: []const u8) u8 {
    if (std.mem.indexOfScalar(u8, spec, ':') == null) {
        const port = std.fmt.parseInt(u16, spec, 10) catch {
            std.debug.print("share-relay: expected host:port or a port\n", .{});
            return 2;
        };
        return run("0.0.0.0", port);
    }
    const parsed = invite.parseRelay(spec) catch {
        std.debug.print("share-relay: expected host:port or a port\n", .{});
        return 2;
    };
    return run(parsed.host, parsed.port);
}

fn run(host: []const u8, port: u16) u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const server = Server.start(gpa.allocator(), host, port) catch |err| {
        std.debug.print("share-relay: {s}\n", .{@errorName(err)});
        return 1;
    };
    std.debug.print("Shared Haunting relay on {s}:{d} (Ctrl+C stops the process)\n", .{ host, server.port() });
    // The process exits on SIGINT/SIGTERM; the OS reclaims the socket.
    while (true) std.time.sleep(200 * std.time.ns_per_ms);
}

test "relay splices bytes end to end" {
    io.ensureSockets();
    const server = try Server.start(std.testing.allocator, "127.0.0.1", 0);
    const port = server.port();
    const id = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };

    const Ctx = struct {
        port: u16,
        id: [8]u8,
        role: Role,
        stream: ?std.net.Stream = null,
        err: ?anyerror = null,
        fn go(self: *@This()) void {
            self.stream = open("127.0.0.1", self.port, self.role, &self.id, 3000, null) catch |e| {
                self.err = e;
                return;
            };
        }
    };
    var host_c = Ctx{ .port = port, .id = id, .role = .host };
    var guest_c = Ctx{ .port = port, .id = id, .role = .guest };
    const th = try std.Thread.spawn(.{}, Ctx.go, .{&host_c});
    const tg = try std.Thread.spawn(.{}, Ctx.go, .{&guest_c});
    th.join();
    tg.join();
    defer {
        if (host_c.stream) |s| s.close();
        if (guest_c.stream) |s| s.close();
        server.shutdown();
    }
    try std.testing.expect(host_c.err == null);
    try std.testing.expect(guest_c.err == null);
    const hs = host_c.stream.?;
    const gs = guest_c.stream.?;
    try hs.writeAll("ping");
    var buf: [4]u8 = undefined;
    try readAll(gs, &buf, std.time.milliTimestamp() + 2000, null);
    try std.testing.expectEqualStrings("ping", &buf);
    try gs.writeAll("pong");
    try readAll(hs, &buf, std.time.milliTimestamp() + 2000, null);
    try std.testing.expectEqualStrings("pong", &buf);
}
