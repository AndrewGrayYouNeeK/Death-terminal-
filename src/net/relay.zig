//! Windows: a socket that std.http can block on and that we can still
//! interrupt.
//!
//! std.net.Stream reads sockets with ReadFile. ReadFile ignores SO_RCVTIMEO,
//! retries on ERROR_OPERATION_ABORTED (so CancelIoEx doesn't help), and
//! shutdown() from another thread doesn't wake it. Under Wine a blocked read
//! never returns. On Windows SO_RCVTIMEO applies only to recv/WSARecv.
//!
//! So std gets one end of a loopback socket pair (`theirs`). A relay thread
//! copies bytes between the other end and the real connection. It polls in
//! short slices, and on cancel, deadline or `finish` it closes its sockets.
//! The blocked ReadFile on `theirs` then sees end-of-stream and returns.
//!
//! On POSIX this is not needed: SO_RCVTIMEO and shutdown() both work.

const std = @import("std");
const io = @import("../platform/io.zig");

pub const Reason = enum(u8) { none, timeout, cancelled, closed };

pub const Relay = struct {
    allocator: std.mem.Allocator,
    real: io.Fd,
    mine: io.Fd,
    /// Hand this to std (as a std.net.Stream handle); std closes it.
    theirs: io.Fd,
    deadline: std.atomic.Value(i64),
    cancelled: *const fn (ctx: *anyopaque) bool,
    ctx: *anyopaque,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    reason: std.atomic.Value(Reason) = std.atomic.Value(Reason).init(.none),
    thread: std.Thread = undefined,

    /// Takes ownership of `real` (closed when the relay ends, also on error).
    pub fn start(a: std.mem.Allocator, real: io.Fd, deadline_ms: i64, ctx: *anyopaque, cancelled: *const fn (*anyopaque) bool) !*Relay {
        errdefer io.close(real);
        const pair = try io.socketPair();
        errdefer {
            io.close(pair[0]);
            io.close(pair[1]);
        }
        const self = try a.create(Relay);
        errdefer a.destroy(self);
        self.* = .{
            .allocator = a,
            .real = real,
            .mine = pair[0],
            .theirs = pair[1],
            .deadline = std.atomic.Value(i64).init(deadline_ms),
            .ctx = ctx,
            .cancelled = cancelled,
        };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    /// Move the deadline (e.g. once connected).
    pub fn setDeadline(self: *Relay, deadline_ms: i64) void {
        self.deadline.store(deadline_ms, .seq_cst);
    }

    /// Why the relay stopped early, if it did.
    pub fn why(self: *Relay) Reason {
        return self.reason.load(.seq_cst);
    }

    /// Stop the thread and free the relay. `theirs` is std's to close.
    pub fn finish(self: *Relay) void {
        self.stop.store(true, .seq_cst);
        self.thread.join();
        self.allocator.destroy(self);
    }

    fn run(self: *Relay) void {
        defer {
            io.close(self.mine);
            io.close(self.real);
        }
        // up: std -> server (mine -> real); down: server -> std (real -> mine)
        var up_open = true;
        var down_open = true;
        var buf: [16 * 1024]u8 = undefined;
        while (up_open or down_open) {
            if (self.stop.load(.seq_cst)) return;
            if (self.cancelled(self.ctx)) return self.reason.store(.cancelled, .seq_cst);
            if (std.time.milliTimestamp() >= self.deadline.load(.seq_cst)) return self.reason.store(.timeout, .seq_cst);
            var fds = [2]io.PollFd{
                io.pollFd(if (up_open) self.mine else io.none, io.POLL.IN),
                io.pollFd(if (down_open) self.real else io.none, io.POLL.IN),
            };
            if (io.poll(&fds, 50) == 0) continue;
            const pairs = [2]struct { *bool, io.Fd, io.Fd }{ .{ &up_open, self.mine, self.real }, .{ &down_open, self.real, self.mine } };
            for (pairs, fds) |p, f| {
                if (!p[0].* or f.revents == 0) continue;
                const n = io.read(p[1], &buf) catch |err| switch (err) {
                    error.WouldBlock => continue,
                    else => 0,
                };
                if (n == 0) {
                    // Pass the half-close on; the other direction keeps going.
                    p[0].* = false;
                    shutdownSend(p[2]);
                    continue;
                }
                if (!self.writeAll(p[2], buf[0..n])) return self.reason.store(.closed, .seq_cst);
            }
        }
    }

    fn writeAll(self: *Relay, fd: io.Fd, data: []const u8) bool {
        var off: usize = 0;
        while (off < data.len) {
            if (self.stop.load(.seq_cst) or self.cancelled(self.ctx)) return false;
            off += io.write(fd, data[off..]) catch |err| switch (err) {
                error.WouldBlock => {
                    var f = [1]io.PollFd{io.pollFd(fd, io.POLL.OUT)};
                    _ = io.poll(&f, 50);
                    continue;
                },
                else => return false,
            };
        }
        return true;
    }

    fn shutdownSend(fd: io.Fd) void {
        if (io.is_windows) {
            _ = std.os.windows.ws2_32.shutdown(fd, 1);
        } else std.posix.shutdown(fd, .send) catch {};
    }
};

test "relay copies both ways and stops at the deadline" {
    io.ensureSockets();
    const server = try io.socketPair();
    defer io.close(server[1]);
    const Never = struct {
        fn f(_: *anyopaque) bool {
            return false;
        }
    };
    var dummy: u8 = 0;
    const r = try Relay.start(std.testing.allocator, server[0], std.time.milliTimestamp() + 300, &dummy, Never.f);
    const theirs = r.theirs;
    defer {
        r.finish();
        io.close(theirs);
    }
    const s = std.net.Stream{ .handle = theirs };
    try s.writeAll("ping");
    var buf: [8]u8 = undefined;
    var got: usize = 0;
    while (got < 4) {
        var f = [1]io.PollFd{io.pollFd(server[1], io.POLL.IN)};
        _ = io.poll(&f, 1000);
        got += try io.read(server[1], buf[got..]);
    }
    try std.testing.expectEqualStrings("ping", buf[0..4]);
    _ = try io.write(server[1], "pong");
    try std.testing.expectEqual(@as(usize, 4), try s.readAll(buf[0..4]));
    try std.testing.expectEqualStrings("pong", buf[0..4]);
    // Nothing more arrives: the blocked read ends at the deadline.
    const t0 = std.time.milliTimestamp();
    try std.testing.expectEqual(@as(usize, 0), s.read(&buf) catch 0);
    try std.testing.expect(std.time.milliTimestamp() - t0 < 2000);
    try std.testing.expectEqual(Reason.timeout, r.why());
}
