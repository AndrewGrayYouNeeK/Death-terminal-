//! Moves bytes between a libssh2 channel and a socket without blocking.
//! Used for port-forward connections and for the socketpair that carries
//! the next hop of a ProxyJump chain.
//!
//! libssh2 rule this respects: a call that returned EAGAIN must be made
//! again before other writes can progress, so `step` retries pending
//! writes on every call.

const std = @import("std");
const posix = std.posix;
const c = @import("c.zig").c;

pub const Buf = struct {
    data: [32 * 1024]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    pub fn pending(self: *const Buf) []const u8 {
        return self.data[self.start..self.end];
    }
    pub fn isEmpty(self: *const Buf) bool {
        return self.start == self.end;
    }
    pub fn free(self: *Buf) []u8 {
        if (self.start > 0 and self.end == self.data.len) {
            const n = self.end - self.start;
            std.mem.copyForwards(u8, self.data[0..n], self.data[self.start..self.end]);
            self.start = 0;
            self.end = n;
        }
        return self.data[self.end..];
    }
    pub fn commit(self: *Buf, n: usize) void {
        self.end += n;
    }
    pub fn consume(self: *Buf, n: usize) void {
        self.start += n;
        if (self.start == self.end) {
            self.start = 0;
            self.end = 0;
        }
    }
    pub fn append(self: *Buf, bytes: []const u8) bool {
        const f = self.free();
        if (f.len < bytes.len) return false;
        @memcpy(f[0..bytes.len], bytes);
        self.commit(bytes.len);
        return true;
    }
};

pub const Bridge = struct {
    chan: *c.LIBSSH2_CHANNEL,
    fd: posix.fd_t,
    to_chan: Buf = .{},
    to_sock: Buf = .{},
    sock_eof: bool = false,
    eof_sent: bool = false,
    chan_eof: bool = false,
    sock_shut: bool = false,
    failed: bool = false,
    /// Bytes moved in each direction (for status lines).
    up: u64 = 0,
    down: u64 = 0,

    pub fn wantsRead(self: *const Bridge) bool {
        return !self.sock_eof and !self.failed and self.to_chan.data.len - (self.to_chan.end - self.to_chan.start) > 0;
    }
    pub fn wantsWrite(self: *const Bridge) bool {
        return !self.to_sock.isEmpty();
    }

    pub fn done(self: *const Bridge) bool {
        if (self.failed) return true;
        return self.chan_eof and self.sock_shut and self.to_sock.isEmpty() and (self.sock_eof and self.eof_sent);
    }

    /// One non-blocking pass in both directions. Returns true when bytes
    /// moved (call again before sleeping).
    pub fn step(self: *Bridge) bool {
        var progress = false;
        // socket → channel
        if (!self.sock_eof and !self.failed) {
            const f = self.to_chan.free();
            if (f.len > 0) {
                if (posix.read(self.fd, f)) |n| {
                    if (n == 0) self.sock_eof = true else self.to_chan.commit(n);
                    progress = true;
                } else |err| switch (err) {
                    error.WouldBlock => {},
                    else => {
                        self.sock_eof = true;
                        progress = true;
                    },
                }
            }
        }
        while (!self.to_chan.isEmpty() and !self.failed) {
            const p = self.to_chan.pending();
            const rc = c.libssh2_channel_write_ex(self.chan, 0, p.ptr, p.len);
            if (rc == c.LIBSSH2_ERROR_EAGAIN) break;
            if (rc < 0) {
                self.failed = true;
                break;
            }
            self.to_chan.consume(@intCast(rc));
            self.up += @intCast(rc);
            progress = true;
        }
        if (self.sock_eof and self.to_chan.isEmpty() and !self.eof_sent and !self.failed) {
            const rc = c.libssh2_channel_send_eof(self.chan);
            if (rc == 0) {
                self.eof_sent = true;
                progress = true;
            } else if (rc != c.LIBSSH2_ERROR_EAGAIN) {
                self.eof_sent = true;
            }
        }
        // channel → socket
        while (!self.chan_eof and !self.failed) {
            const f = self.to_sock.free();
            if (f.len == 0) break;
            const rc = c.libssh2_channel_read_ex(self.chan, 0, f.ptr, f.len);
            if (rc > 0) {
                self.to_sock.commit(@intCast(rc));
                self.down += @intCast(rc);
                progress = true;
                continue;
            }
            if (rc == 0 or rc == c.LIBSSH2_ERROR_EAGAIN) {
                if (c.libssh2_channel_eof(self.chan) == 1) {
                    self.chan_eof = true;
                    progress = true;
                }
                break;
            }
            self.chan_eof = true;
            if (rc != c.LIBSSH2_ERROR_CHANNEL_CLOSED) self.failed = true;
            break;
        }
        while (!self.to_sock.isEmpty()) {
            const n = posix.write(self.fd, self.to_sock.pending()) catch |err| switch (err) {
                error.WouldBlock => break,
                else => {
                    self.failed = true;
                    break;
                },
            };
            self.to_sock.consume(n);
            progress = true;
        }
        if (self.chan_eof and self.to_sock.isEmpty() and !self.sock_shut) {
            posix.shutdown(self.fd, .send) catch {};
            self.sock_shut = true;
            progress = true;
        }
        return progress;
    }
};

pub fn setNonBlocking(fd: posix.fd_t) void {
    const fl = posix.fcntl(fd, posix.F.GETFL, 0) catch return;
    _ = posix.fcntl(fd, posix.F.SETFL, fl | @as(usize, 1 << @bitOffsetOf(posix.O, "NONBLOCK"))) catch {};
}

test "Buf compacts and appends" {
    var b = Buf{};
    try std.testing.expect(b.append("hello"));
    b.consume(2);
    try std.testing.expectEqualStrings("llo", b.pending());
    b.consume(3);
    try std.testing.expect(b.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), b.start);
}
