//! One TCP connection speaking framed Noise messages.
//!
//! The socket is non-blocking. `pump` reads whatever is available, finishes
//! the handshake, and queues decrypted application messages. Outbound bytes
//! sit in `out` until the socket accepts them.

const std = @import("std");
const frame = @import("frame.zig");
const noise = @import("noise.zig");

pub const Error = error{
    Closed,
    Handshake,
    BadFrame,
    TooBig,
    NoSpace,
    OutOfMemory,
    Unexpected,
};

pub const Link = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    hs: noise.Handshake,
    tr: ?noise.Transport = null,
    fr: frame.Framer = .{},
    out: std.ArrayList(u8),
    out_at: usize = 0,
    apps: std.ArrayList(u8),
    apps_at: usize = 0,
    /// 0 = nothing sent, 1 = msg1 sent (initiator), 2 = handshake finished locally.
    hs_step: u2 = 0,

    pub fn initiator(allocator: std.mem.Allocator, stream: std.net.Stream, psk: *const [32]u8) Error!*Link {
        const self = try allocator.create(Link);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .stream = stream,
            .hs = noise.Handshake.init(.initiator, psk),
            .out = std.ArrayList(u8).init(allocator),
            .apps = std.ArrayList(u8).init(allocator),
        };
        errdefer self.out.deinit();
        errdefer self.apps.deinit();
        var msg: [noise.handshake_len]u8 = undefined;
        const n = self.hs.writeMsg1(&msg) catch return error.Handshake;
        try self.queueFrame(msg[0..n]);
        self.hs_step = 1;
        return self;
    }

    pub fn responder(allocator: std.mem.Allocator, stream: std.net.Stream, psk: *const [32]u8) Error!*Link {
        const self = try allocator.create(Link);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .stream = stream,
            .hs = noise.Handshake.init(.responder, psk),
            .out = std.ArrayList(u8).init(allocator),
            .apps = std.ArrayList(u8).init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *Link) void {
        if (self.tr) |*t| t.deinit();
        self.out.deinit();
        self.apps.deinit();
        self.stream.close();
        self.allocator.destroy(self);
    }

    pub fn isOpen(self: *const Link) bool {
        return self.tr != null;
    }

    pub fn sendApp(self: *Link, plain: []const u8) Error!void {
        const t = &(self.tr orelse return error.Handshake);
        if (plain.len + 16 > frame.max_payload) return error.TooBig;
        var sealed: [frame.max_payload]u8 = undefined;
        const n = t.seal(plain, &sealed) catch return error.Handshake;
        try self.queueFrame(sealed[0..n]);
    }

    pub fn nextApp(self: *Link) ?[]u8 {
        if (self.apps_at + 4 > self.apps.items.len) return null;
        const n = std.mem.readInt(u32, self.apps.items[self.apps_at..][0..4], .little);
        const start = self.apps_at + 4;
        const end = start + n;
        if (end > self.apps.items.len) return null;
        self.apps_at = end;
        return self.apps.items[start..end];
    }

    pub fn compact(self: *Link) void {
        if (self.apps_at == 0) return;
        const rest = self.apps.items.len - self.apps_at;
        std.mem.copyForwards(u8, self.apps.items[0..rest], self.apps.items[self.apps_at..]);
        self.apps.shrinkRetainingCapacity(rest);
        self.apps_at = 0;
        if (self.out_at == 0) return;
        const orest = self.out.items.len - self.out_at;
        std.mem.copyForwards(u8, self.out.items[0..orest], self.out.items[self.out_at..]);
        self.out.shrinkRetainingCapacity(orest);
        self.out_at = 0;
    }

    fn queueFrame(self: *Link, payload: []const u8) Error!void {
        var tmp: [2 + frame.max_payload]u8 = undefined;
        const n = frame.encode(&tmp, payload) catch return error.TooBig;
        self.out.appendSlice(tmp[0..n]) catch return error.OutOfMemory;
    }

    fn queueApp(self: *Link, plain: []const u8) Error!void {
        var lenb: [4]u8 = undefined;
        std.mem.writeInt(u32, &lenb, @intCast(plain.len), .little);
        self.apps.appendSlice(&lenb) catch return error.OutOfMemory;
        self.apps.appendSlice(plain) catch return error.OutOfMemory;
    }

    pub fn flush(self: *Link) Error!void {
        while (self.out_at < self.out.items.len) {
            const n = self.stream.write(self.out.items[self.out_at..]) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return error.Closed,
            };
            if (n == 0) return error.Closed;
            self.out_at += n;
        }
    }

    pub fn pump(self: *Link) Error!void {
        try self.flush();
        var buf: [8192]u8 = undefined;
        while (true) {
            const n = self.stream.read(&buf) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return error.Closed,
            };
            if (n == 0) return error.Closed;
            try self.ingest(buf[0..n]);
        }
    }

    fn ingest(self: *Link, bytes: []const u8) Error!void {
        var off: usize = 0;
        while (off < bytes.len) {
            const room = self.fr.buf.len - self.fr.len;
            if (room == 0) return error.TooBig;
            const take = @min(room, bytes.len - off);
            self.fr.append(bytes[off..][0..take]) catch return error.TooBig;
            off += take;
            while (true) {
                const payload = self.fr.next() catch return error.BadFrame;
                const p = payload orelse break;
                try self.onFrame(p);
            }
        }
    }

    fn onFrame(self: *Link, payload: []const u8) Error!void {
        if (self.tr == null) {
            try self.onHandshake(payload);
            return;
        }
        var plain: [frame.max_payload]u8 = undefined;
        const n = self.tr.?.open(payload, &plain) catch return error.Handshake;
        try self.queueApp(plain[0..n]);
    }

    fn onHandshake(self: *Link, payload: []const u8) Error!void {
        if (self.hs.role == .responder and self.hs_step == 0) {
            self.hs.readMsg1(payload) catch return error.Handshake;
            var msg: [noise.handshake_len]u8 = undefined;
            const n = self.hs.writeMsg2(&msg) catch return error.Handshake;
            try self.queueFrame(msg[0..n]);
            self.tr = self.hs.split() catch return error.Handshake;
            self.hs_step = 2;
            try self.flush();
            return;
        }
        if (self.hs.role == .initiator and self.hs_step == 1) {
            self.hs.readMsg2(payload) catch return error.Handshake;
            self.tr = self.hs.split() catch return error.Handshake;
            self.hs_step = 2;
            return;
        }
        return error.Handshake;
    }
};

pub fn setNoDelay(stream: std.net.Stream) void {
    const one: c_int = 1;
    // TCP_NODELAY is 1 on Linux, Windows, and Darwin. `posix.TCP` is that
    // option set on Linux and an IPPROTO number on Darwin, so the literal
    // is the portable form. The relay presents a socketpair, where this
    // option is unsupported; ignore that without treating it as a fault.
    if (@import("builtin").os.tag == .windows) {
        _ = std.os.windows.ws2_32.setsockopt(stream.handle, std.posix.IPPROTO.TCP, 1, std.mem.asBytes(&one).ptr, @intCast(@sizeOf(c_int)));
        return;
    }
    _ = std.posix.system.setsockopt(stream.handle, std.posix.IPPROTO.TCP, 1, std.mem.asBytes(&one).ptr, @sizeOf(c_int));
}
