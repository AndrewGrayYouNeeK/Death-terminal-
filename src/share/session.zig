//! Host and guest sessions for one shared pane.
//!
//! The host listens (or registers with the optional relay) and will accept
//! one guest. The guest is read-only until `setControl(true)`. `kick` drops
//! the guest and ignores any further input from that connection. A later
//! guest starts at read-only again. Only the bytes the caller hands to
//! `sendRow` are shared; this type never reads another pane.

const std = @import("std");
const io = @import("../platform/io.zig");
const netdial = @import("../net/dial.zig");
const frame = @import("frame.zig");
const invite = @import("invite.zig");
const link_mod = @import("link.zig");
const msg = @import("msg.zig");
const relay = @import("relay.zig");

pub const Access = msg.Access;

pub const Phase = enum { waiting, open, closed };

const Dial = struct {
    cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mu: std.Thread.Mutex = .{},
    done: bool = false,
    stream: ?std.net.Stream = null,
    err: [48]u8 = [_]u8{0} ** 48,
    err_len: usize = 0,
    thread: std.Thread = undefined,
    joined: bool = false,
    use_relay: bool = false,
    role: relay.Role = .guest,
    id: [8]u8 = [_]u8{0} ** 8,
    host: [invite.max_host]u8 = undefined,
    host_len: usize = 0,
    port: u16 = 0,
    relay_host: [invite.max_relay]u8 = undefined,
    relay_host_len: usize = 0,
    relay_port: u16 = 0,

    fn cancelled(ctx: *anyopaque) bool {
        const self: *Dial = @ptrCast(@alignCast(ctx));
        return self.cancel.load(.seq_cst);
    }

    fn run(self: *Dial) void {
        const cancel = netdial.CancelFn{ .ctx = self, .f = cancelled };
        const stream: std.net.Stream = if (self.use_relay)
            relay.open(self.relay_host[0..self.relay_host_len], self.relay_port, self.role, &self.id, 20000, cancel) catch |err| {
                self.fail(err);
                return;
            }
        else blk: {
            const fd = netdial.connect(self.host[0..self.host_len], self.port, 8000, cancel) catch |err| {
                self.fail(err);
                return;
            };
            break :blk .{ .handle = fd };
        };
        self.mu.lock();
        self.stream = stream;
        self.done = true;
        self.mu.unlock();
    }

    fn fail(self: *Dial, err: anyerror) void {
        const name = @errorName(err);
        self.mu.lock();
        const n = @min(name.len, self.err.len);
        @memcpy(self.err[0..n], name[0..n]);
        self.err_len = n;
        self.done = true;
        self.mu.unlock();
    }

    fn take(self: *Dial) ?std.net.Stream {
        self.mu.lock();
        defer self.mu.unlock();
        if (!self.done or self.stream == null) return null;
        const s = self.stream.?;
        self.stream = null;
        return s;
    }

    fn errorName(self: *Dial) ?[]const u8 {
        self.mu.lock();
        defer self.mu.unlock();
        if (!self.done or self.err_len == 0) return null;
        return self.err[0..self.err_len];
    }

    fn finish(self: *Dial, allocator: std.mem.Allocator) void {
        if (!self.joined) {
            self.cancel.store(true, .seq_cst);
            self.thread.join();
            self.joined = true;
        }
        self.mu.lock();
        if (self.stream) |s| s.close();
        self.stream = null;
        self.mu.unlock();
        allocator.destroy(self);
    }
};

fn spawnDial(allocator: std.mem.Allocator, spec: struct {
    use_relay: bool,
    role: relay.Role,
    id: [8]u8,
    host: []const u8,
    port: u16,
    relay_host: []const u8 = "",
    relay_port: u16 = 0,
}) !*Dial {
    const d = try allocator.create(Dial);
    d.* = .{ .use_relay = spec.use_relay, .role = spec.role, .id = spec.id, .port = spec.port, .relay_port = spec.relay_port };
    d.host_len = @min(spec.host.len, d.host.len);
    @memcpy(d.host[0..d.host_len], spec.host[0..d.host_len]);
    d.relay_host_len = @min(spec.relay_host.len, d.relay_host.len);
    @memcpy(d.relay_host[0..d.relay_host_len], spec.relay_host[0..d.relay_host_len]);
    d.thread = std.Thread.spawn(.{}, Dial.run, .{d}) catch |err| {
        allocator.destroy(d);
        return err;
    };
    return d;
}

pub const Host = struct {
    allocator: std.mem.Allocator,
    listener: ?std.net.Server = null,
    link: ?*link_mod.Link = null,
    dial: ?*Dial = null,
    psk: [32]u8,
    secret: [invite.secret_len]u8,
    code: []u8,
    access: Access = .read_only,
    gate_open: bool = true,
    input: std.ArrayList(u8),
    pointer: msg.Pointer = .{},
    has_pointer: bool = false,
    dropped: usize = 0,
    accepted: usize = 0,
    phase: Phase = .waiting,
    full: bool = true,
    port_n: u16 = 0,
    fail: [48]u8 = [_]u8{0} ** 48,
    fail_len: usize = 0,

    pub fn deinit(self: *Host) void {
        if (self.dial) |d| d.finish(self.allocator);
        if (self.link) |l| l.deinit();
        if (self.listener) |*s| s.deinit();
        self.allocator.free(self.code);
        self.input.deinit();
        std.crypto.utils.secureZero(u8, &self.psk);
        std.crypto.utils.secureZero(u8, &self.secret);
        self.allocator.destroy(self);
    }

    pub fn port(self: *const Host) u16 {
        return self.port_n;
    }

    /// Direct TCP. `advertise` is the host written into the invite (a LAN
    /// address, or `"127.0.0.1"` for a local guest). `relay` empty means no relay.
    pub fn listen(
        allocator: std.mem.Allocator,
        bind_ip: []const u8,
        port_n: u16,
        advertise: []const u8,
        relay_url: []const u8,
        secret: ?[invite.secret_len]u8,
    ) !*Host {
        const sec = secret orelse invite.randomSecret();
        const psk = invite.Invite.psk(&.{ .host = advertise, .port = 0, .secret = sec, .relay = relay_url });
        const self = try allocator.create(Host);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .psk = psk,
            .secret = sec,
            .code = &.{},
            .input = std.ArrayList(u8).init(allocator),
        };
        errdefer self.input.deinit();
        errdefer if (self.listener) |*ln| ln.deinit();
        errdefer if (self.dial) |d| d.finish(allocator);
        var code_owned = false;
        errdefer if (code_owned) allocator.free(self.code);

        var use_relay = false;
        var relay_host: []const u8 = "";
        var relay_port: u16 = 0;
        if (relay_url.len > 0) {
            const r = invite.parseRelay(relay_url) catch return error.BadRelay;
            use_relay = true;
            relay_host = r.host;
            relay_port = r.port;
        }

        var bound_port = port_n;
        if (!use_relay) {
            const addr = std.net.Address.parseIp(bind_ip, port_n) catch return error.BadAddress;
            const listener = try addr.listen(.{ .reuse_address = true, .force_nonblocking = true });
            self.listener = listener;
            bound_port = listener.listen_address.getPort();
        }
        self.port_n = bound_port;
        var code_buf: [512]u8 = undefined;
        const code = try invite.encode(&code_buf, .{
            .host = advertise,
            .port = bound_port,
            .secret = sec,
            .relay = relay_url,
        });
        self.code = try allocator.dupe(u8, code);
        code_owned = true;
        if (use_relay) {
            const id = (invite.Invite{ .host = advertise, .port = bound_port, .secret = sec, .relay = relay_url }).relayId();
            self.dial = try spawnDial(allocator, .{
                .use_relay = true,
                .role = .host,
                .id = id,
                .host = advertise,
                .port = bound_port,
                .relay_host = relay_host,
                .relay_port = relay_port,
            });
        }
        return self;
    }

    pub fn fds(self: *Host, out: *[2]io.Fd) usize {
        var n: usize = 0;
        if (self.listener) |s| {
            out[n] = s.stream.handle;
            n += 1;
        }
        if (self.link) |l| {
            out[n] = l.stream.handle;
            n += 1;
        }
        return n;
    }

    pub fn tick(self: *Host) !void {
        if (self.phase == .closed) return;
        if (self.dial) |d| {
            if (d.errorName()) |name| {
                self.note(name);
                d.finish(self.allocator);
                self.dial = null;
                self.phase = .closed;
                return;
            }
            if (d.take()) |stream| {
                d.finish(self.allocator);
                self.dial = null;
                self.link = link_mod.Link.responder(self.allocator, stream, &self.psk) catch |err| {
                    stream.close();
                    return err;
                };
                io.setNonBlocking(self.link.?.stream.handle) catch {};
            }
        }
        if (self.link == null) if (self.listener) |*s| {
            const conn = s.accept() catch |err| switch (err) {
                error.WouldBlock, error.ConnectionAborted => return,
                else => return err,
            };
            self.link = link_mod.Link.responder(self.allocator, conn.stream, &self.psk) catch |err| {
                conn.stream.close();
                return err;
            };
            io.setNonBlocking(self.link.?.stream.handle) catch {};
            link_mod.setNoDelay(self.link.?.stream);
        };
        const l = self.link orelse return;
        l.pump() catch |err| {
            self.dropGuest();
            if (err == error.Closed or err == error.Handshake or err == error.BadFrame) return;
            return err;
        };
        if (self.phase == .waiting and l.isOpen()) {
            var buf: [8]u8 = undefined;
            const hello = try msg.encodeWelcome(&buf, .read_only);
            l.sendApp(hello) catch {};
            self.access = .read_only;
            self.gate_open = true;
            self.phase = .open;
            self.full = true;
        }
        try self.drain();
        l.flush() catch {};
    }

    fn drain(self: *Host) !void {
        const l = self.link orelse return;
        while (l.nextApp()) |bytes| {
            const dec = msg.decode(bytes) catch continue;
            switch (dec) {
                .input => |b| {
                    if (msg.admitInput(self.access, self.gate_open, b)) {
                        self.input.appendSlice(b) catch return error.OutOfMemory;
                        self.accepted += 1;
                    } else self.dropped += 1;
                },
                .pointer => |p| {
                    self.pointer = p;
                    self.has_pointer = true;
                },
                .ping => {
                    var buf: [4]u8 = undefined;
                    const m = msg.encodeBare(&buf, .ping) catch continue;
                    l.sendApp(m) catch {};
                },
                .bye => {
                    self.dropGuest();
                    return;
                },
                .welcome, .row, .access, .kick, .cursor => {},
            }
        }
        l.compact();
    }

    pub fn sendApp(self: *Host, plain: []const u8) !void {
        const l = self.link orelse return error.Closed;
        try l.sendApp(plain);
        l.flush() catch {};
    }

    pub fn sendRow(self: *Host, row: msg.Row) !void {
        var buf: [frame.max_payload]u8 = undefined;
        const enc = try msg.encodeRow(&buf, row);
        try self.sendApp(enc);
    }

    pub fn sendCursor(self: *Host, c: msg.Cursor) !void {
        var buf: [8]u8 = undefined;
        try self.sendApp(try msg.encodeCursor(&buf, c));
    }

    pub fn setControl(self: *Host, on: bool) !void {
        if (self.phase != .open) return;
        self.access = if (on) .control else .read_only;
        var buf: [4]u8 = undefined;
        try self.sendApp(try msg.encodeAccess(&buf, self.access));
    }

    pub fn kick(self: *Host) void {
        self.gate_open = false;
        if (self.link) |l| {
            var buf: [4]u8 = undefined;
            if (msg.encodeBare(&buf, .kick)) |m| l.sendApp(m) catch {} else |_| {}
            l.flush() catch {};
        }
        self.dropGuest();
    }

    pub fn takeInput(self: *Host, dst: []u8) usize {
        const n = @min(dst.len, self.input.items.len);
        @memcpy(dst[0..n], self.input.items[0..n]);
        if (n == self.input.items.len) {
            self.input.clearRetainingCapacity();
        } else if (n > 0) {
            const rest = self.input.items.len - n;
            std.mem.copyForwards(u8, self.input.items[0..rest], self.input.items[n..]);
            self.input.shrinkRetainingCapacity(rest);
        }
        return n;
    }

    fn dropGuest(self: *Host) void {
        if (self.link) |l| l.deinit();
        self.link = null;
        self.access = .read_only;
        self.gate_open = true;
        self.has_pointer = false;
        self.pointer = .{};
        if (self.phase != .closed) self.phase = .waiting;
    }

    pub fn failure(self: *const Host) ?[]const u8 {
        if (self.fail_len == 0) return null;
        return self.fail[0..self.fail_len];
    }

    fn note(self: *Host, name: []const u8) void {
        const n = @min(name.len, self.fail.len);
        @memcpy(self.fail[0..n], name[0..n]);
        self.fail_len = n;
    }
};

pub const Guest = struct {
    allocator: std.mem.Allocator,
    link: ?*link_mod.Link = null,
    dial: ?*Dial = null,
    psk: [32]u8,
    access: Access = .read_only,
    phase: Phase = .waiting,
    rows: u16 = 0,
    cols: u16 = 0,
    cursor_row: u16 = 0,
    cursor_col: u16 = 0,
    cursor_on: bool = false,
    grid: std.ArrayList(u8),
    dirty: bool = false,
    kicked: bool = false,
    fail: [48]u8 = [_]u8{0} ** 48,
    fail_len: usize = 0,

    pub fn deinit(self: *Guest) void {
        if (self.dial) |d| d.finish(self.allocator);
        if (self.link) |l| l.deinit();
        self.grid.deinit();
        std.crypto.utils.secureZero(u8, &self.psk);
        self.allocator.destroy(self);
    }

    /// Parse `code` (or a deathterminal:// link) and dial in the background.
    pub fn start(allocator: std.mem.Allocator, code: []const u8) !*Guest {
        var owned = try invite.decodeOwned(allocator, code);
        defer owned.deinit();
        const view = owned.view();
        const use_relay = view.relay.len > 0;
        var relay_host: []const u8 = "";
        var relay_port: u16 = 0;
        if (use_relay) {
            const r = invite.parseRelay(view.relay) catch return error.BadRelay;
            relay_host = r.host;
            relay_port = r.port;
        }
        const self = try allocator.create(Guest);
        self.* = .{
            .allocator = allocator,
            .psk = view.psk(),
            .grid = std.ArrayList(u8).init(allocator),
        };
        errdefer {
            self.grid.deinit();
            std.crypto.utils.secureZero(u8, &self.psk);
            allocator.destroy(self);
        }
        self.dial = try spawnDial(allocator, .{
            .use_relay = use_relay,
            .role = .guest,
            .id = view.relayId(),
            .host = view.host,
            .port = view.port,
            .relay_host = relay_host,
            .relay_port = relay_port,
        });
        return self;
    }

    /// Blocking connect used by tests. `psk` is the Noise key, not the invite code.
    pub fn connectDirect(allocator: std.mem.Allocator, host: []const u8, port_n: u16, psk: *const [32]u8) !*Guest {
        const sock = try netdial.connect(host, port_n, 2000, null);
        const stream = std.net.Stream{ .handle = sock };
        io.setNonBlocking(stream.handle) catch {};
        link_mod.setNoDelay(stream);
        const l = link_mod.Link.initiator(allocator, stream, psk) catch |err| {
            stream.close();
            return err;
        };
        const self = allocator.create(Guest) catch |err| {
            l.deinit();
            return err;
        };
        self.* = .{
            .allocator = allocator,
            .link = l,
            .psk = psk.*,
            .grid = std.ArrayList(u8).init(allocator),
        };
        return self;
    }

    pub fn fd(self: *Guest) io.Fd {
        if (self.link) |l| return l.stream.handle;
        return io.none;
    }

    pub fn failure(self: *const Guest) ?[]const u8 {
        if (self.fail_len == 0) return null;
        return self.fail[0..self.fail_len];
    }

    pub fn tick(self: *Guest) !void {
        if (self.phase == .closed) return;
        if (self.dial) |d| {
            if (d.errorName()) |name| {
                self.setFail(name);
                d.finish(self.allocator);
                self.dial = null;
                self.phase = .closed;
                return;
            }
            if (d.take()) |stream| {
                d.finish(self.allocator);
                self.dial = null;
                io.setNonBlocking(stream.handle) catch {};
                link_mod.setNoDelay(stream);
                self.link = link_mod.Link.initiator(self.allocator, stream, &self.psk) catch |err| {
                    stream.close();
                    return err;
                };
            }
        }
        const l = self.link orelse return;
        l.pump() catch |err| {
            if (self.phase == .open) self.kicked = true;
            self.closeLink();
            self.phase = .closed;
            if (err == error.Closed or err == error.Handshake or err == error.BadFrame) return;
            return err;
        };
        if (self.phase == .waiting and l.isOpen()) self.phase = .open;
        try self.drain();
        l.flush() catch {};
    }

    fn drain(self: *Guest) !void {
        const l = self.link orelse return;
        while (l.nextApp()) |bytes| {
            const dec = msg.decode(bytes) catch continue;
            switch (dec) {
                .welcome => |a| self.access = a,
                .access => |a| self.access = a,
                .row => |row| try self.onRow(row),
                .cursor => |c| {
                    self.cursor_row = c.row;
                    self.cursor_col = c.col;
                    self.cursor_on = c.on;
                    self.dirty = true;
                },
                .kick => {
                    self.kicked = true;
                    self.closeLink();
                    self.phase = .closed;
                    return;
                },
                .bye => {
                    self.closeLink();
                    self.phase = .closed;
                    return;
                },
                .pointer, .input, .ping => {},
            }
        }
        l.compact();
    }

    fn onRow(self: *Guest, row: msg.Row) !void {
        if (row.cols == 0 or row.index >= row.rows) return;
        const n = @as(usize, row.rows) * row.cols * msg.wire_len;
        if (self.rows != row.rows or self.cols != row.cols or self.grid.items.len != n) {
            try self.grid.resize(n);
            @memset(self.grid.items, 0);
            self.rows = row.rows;
            self.cols = row.cols;
        }
        const off = @as(usize, row.index) * row.cols * msg.wire_len;
        if (off + row.cells.len > self.grid.items.len) return;
        @memcpy(self.grid.items[off..][0..row.cells.len], row.cells);
        self.cursor_row = row.cursor_row;
        self.cursor_col = row.cursor_col;
        self.cursor_on = row.cursor_on;
        self.dirty = true;
    }

    pub fn sendInput(self: *Guest, bytes: []const u8) !void {
        if (self.phase != .open) return error.Closed;
        var buf: [1024]u8 = undefined;
        if (bytes.len + 1 > buf.len) return error.TooBig;
        const enc = try msg.encodeInput(&buf, bytes);
        const l = self.link orelse return error.Closed;
        try l.sendApp(enc);
        l.flush() catch {};
    }

    pub fn sendPointer(self: *Guest, p: msg.Pointer) !void {
        if (self.phase != .open) return error.Closed;
        var buf: [16]u8 = undefined;
        const l = self.link orelse return error.Closed;
        try l.sendApp(try msg.encodePointer(&buf, p));
        l.flush() catch {};
    }

    fn closeLink(self: *Guest) void {
        if (self.link) |l| l.deinit();
        self.link = null;
    }

    fn setFail(self: *Guest, name: []const u8) void {
        const n = @min(name.len, self.fail.len);
        @memcpy(self.fail[0..n], name[0..n]);
        self.fail_len = n;
    }
};

fn pumpBoth(host: *Host, guest: *Guest) !void {
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        try host.tick();
        try guest.tick();
        if (host.phase == .open and guest.phase == .open and host.link != null and guest.link != null) {
            const h = host.link.?;
            const g = guest.link.?;
            if (h.out_at >= h.out.items.len and g.out_at >= g.out.items.len) return;
        }
        std.time.sleep(5 * std.time.ns_per_ms);
    }
}

test "live session gates input, shares a cell, then kick sticks" {
    io.ensureSockets();
    const secret = [_]u8{ 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 1, 2, 3, 4, 5, 6 };
    const host = try Host.listen(std.testing.allocator, "127.0.0.1", 0, "127.0.0.1", "", secret);
    defer host.deinit();
    const guest = try Guest.connectDirect(std.testing.allocator, "127.0.0.1", host.port(), &host.psk);
    defer guest.deinit();
    try pumpBoth(host, guest);
    try std.testing.expectEqual(Phase.open, host.phase);
    try std.testing.expectEqual(Phase.open, guest.phase);
    try std.testing.expectEqual(Access.read_only, guest.access);

    const token = "sk-live";
    var rowbuf: [msg.wire_len * token.len]u8 = undefined;
    for (token, 0..) |ch, i| msg.writeCell(rowbuf[i * msg.wire_len ..][0..msg.wire_len], ch, 0xAABBCC, 0x101010, msg.flag_bold);
    try host.sendRow(.{
        .rows = 1,
        .cols = token.len,
        .cursor_row = 0,
        .cursor_col = 1,
        .cursor_on = true,
        .index = 0,
        .cells = &rowbuf,
    });
    try pumpBoth(host, guest);
    try std.testing.expect(guest.dirty);
    try std.testing.expectEqual(@as(u16, token.len), guest.cols);
    const cell0 = msg.readCell(guest.grid.items[0..msg.wire_len]);
    try std.testing.expectEqual(@as(u21, 's'), cell0.cp);
    try std.testing.expectEqual(@as(u32, 0xAABBCC), cell0.fg);

    try guest.sendInput("rm -rf /");
    try pumpBoth(host, guest);
    try std.testing.expectEqual(@as(usize, 0), host.input.items.len);
    try std.testing.expect(host.dropped >= 1);
    try std.testing.expectEqual(@as(usize, 0), host.accepted);

    try host.setControl(true);
    try pumpBoth(host, guest);
    try std.testing.expectEqual(Access.control, guest.access);
    try guest.sendInput("ls\n");
    try pumpBoth(host, guest);
    try std.testing.expectEqualStrings("ls\n", host.input.items);
    try std.testing.expectEqual(@as(usize, 1), host.accepted);

    host.kick();
    var i: usize = 0;
    while (i < 20 and !guest.kicked) : (i += 1) {
        guest.tick() catch {};
        std.time.sleep(5 * std.time.ns_per_ms);
    }
    try std.testing.expect(guest.kicked);
    try std.testing.expectEqual(Phase.waiting, host.phase);
    const before = host.input.items.len;
    guest.sendInput("still") catch {};
    host.tick() catch {};
    try std.testing.expectEqual(before, host.input.items.len);
}

test "invite code: guest sees the screen and input waits for grant" {
    io.ensureSockets();
    const host = try Host.listen(std.testing.allocator, "127.0.0.1", 0, "127.0.0.1", "", null);
    defer host.deinit();
    const guest = try Guest.start(std.testing.allocator, host.code);
    defer guest.deinit();

    var i: usize = 0;
    while (i < 200 and (host.phase != .open or guest.phase != .open)) : (i += 1) {
        try host.tick();
        try guest.tick();
        if (guest.failure()) |why| {
            std.debug.print("join failed: {s}\n", .{why});
            return error.JoinFailed;
        }
        std.time.sleep(5 * std.time.ns_per_ms);
    }
    try pumpBoth(host, guest);
    try std.testing.expectEqual(Phase.open, host.phase);
    try std.testing.expectEqual(Phase.open, guest.phase);
    try std.testing.expectEqual(Access.read_only, guest.access);

    var rowbuf: [msg.wire_len]u8 = undefined;
    msg.writeCell(&rowbuf, 'Z', 0xAABBCC, 0x101010, 0);
    try host.sendRow(.{
        .rows = 1,
        .cols = 1,
        .cursor_row = 0,
        .cursor_col = 0,
        .cursor_on = true,
        .index = 0,
        .cells = &rowbuf,
    });
    try pumpBoth(host, guest);
    try std.testing.expect(guest.dirty);
    try std.testing.expectEqual(@as(u21, 'Z'), msg.readCell(guest.grid.items[0..msg.wire_len]).cp);

    try guest.sendInput("rm -rf /");
    try pumpBoth(host, guest);
    try std.testing.expectEqual(@as(usize, 0), host.input.items.len);
    try std.testing.expect(host.dropped >= 1);

    try host.setControl(true);
    try pumpBoth(host, guest);
    try std.testing.expectEqual(Access.control, guest.access);
    try guest.sendInput("ls\n");
    try pumpBoth(host, guest);
    try std.testing.expectEqualStrings("ls\n", host.input.items);
}
