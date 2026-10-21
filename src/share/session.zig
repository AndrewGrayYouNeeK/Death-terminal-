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
const trace = @import("trace.zig");
const ws_relay = @import("ws_relay.zig");

const DialMode = enum { direct, tcp, ws };
const Fallback = enum { none, tcp, ws };

pub const Access = msg.Access;

pub const Phase = enum { waiting, open, closed };

const Dial = struct {
    cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mu: std.Thread.Mutex = .{},
    done: bool = false,
    stream: ?std.net.Stream = null,
    err: [160]u8 = [_]u8{0} ** 160,
    err_len: usize = 0,
    thread: std.Thread = undefined,
    joined: bool = false,
    role: relay.Role = .guest,
    id: [8]u8 = [_]u8{0} ** 8,
    host: [invite.max_host]u8 = undefined,
    host_len: usize = 0,
    port: u16 = 0,
    relay_host: [invite.max_relay]u8 = undefined,
    relay_host_len: usize = 0,
    relay_port: u16 = 0,
    mode: DialMode = .direct,
    fallback: Fallback = .none,
    wait_peer: bool = false,
    used_fallback: bool = false,
    ws_url: [invite.max_relay]u8 = undefined,
    ws_url_len: usize = 0,

    fn cancelled(ctx: *anyopaque) bool {
        const self: *Dial = @ptrCast(@alignCast(ctx));
        return self.cancel.load(.seq_cst);
    }

    fn succeed(self: *Dial, stream: std.net.Stream) void {
        self.mu.lock();
        self.stream = stream;
        self.done = true;
        self.mu.unlock();
    }

    fn run(self: *Dial) void {
        const cancel = netdial.CancelFn{ .ctx = self, .f = cancelled };
        if (self.mode == .direct) {
            const host = self.host[0..self.host_len];
            if (invite.isThisMachine(host)) {
                trace.log("lan connect 127.0.0.1:{d} (invite host {s} is this machine)", .{ self.port, host });
                if (netdial.connect("127.0.0.1", self.port, 400, cancel)) |fd| {
                    trace.log("lan connected 127.0.0.1:{d}", .{self.port});
                    self.succeed(.{ .handle = fd });
                    return;
                } else |err| {
                    trace.log("lan 127.0.0.1:{d} {s}", .{ self.port, @errorName(err) });
                    if (err == error.Cancelled or cancel.check()) {
                        self.fail(err);
                        return;
                    }
                }
            }
            const ms: u32 = if (self.fallback == .none) 8000 else invite.lan_probe_ms;
            trace.log("lan connect {s}:{d} timeout {d}ms", .{ host, self.port, ms });
            if (netdial.connect(host, self.port, ms, cancel)) |fd| {
                trace.log("lan connected {s}:{d}", .{ host, self.port });
                self.succeed(.{ .handle = fd });
                return;
            } else |err| {
                trace.log("lan {s}:{d} {s}", .{ host, self.port, @errorName(err) });
                if (self.fallback == .none or err == error.Cancelled or cancel.check()) {
                    self.fail(err);
                    return;
                }
            }
        }
        self.relayUntil(cancel);
    }

    fn relayUntil(self: *Dial, cancel: netdial.CancelFn) void {
        const kind: DialMode = if (self.mode == .direct) switch (self.fallback) {
            .none => .direct,
            .tcp => .tcp,
            .ws => .ws,
        } else self.mode;
        while (true) {
            if (cancel.check()) {
                self.fail(error.Cancelled);
                return;
            }
            const opened: ?std.net.Stream = switch (kind) {
                .direct => null,
                .tcp => self.openTcp(cancel) catch |err| {
                    self.remember(err);
                    if (!self.retry(err, cancel)) return;
                    continue;
                },
                .ws => ws_relay.open(self.ws_url[0..self.ws_url_len], self.role, &self.id, cancel, self.wait_peer) catch |err| {
                    if (err != error.Cancelled and !cancel.check() and self.useHostedFallback()) continue;
                    self.remember(err);
                    if (!self.retry(err, cancel)) return;
                    continue;
                },
            };
            if (opened) |stream| {
                self.succeed(stream);
                return;
            }
            self.fail(error.Closed);
            return;
        }
    }

    /// `relay.youneek.xyz` can answer an empty 404 or a 403 before the Worker
    /// runs. The session id is the Durable Object name, so the workers.dev
    /// hostname of the same Worker pairs with a peer that took the same path.
    fn useHostedFallback(self: *Dial) bool {
        if (self.used_fallback) return false;
        if (!invite.isDefaultHostedRelay(self.ws_url[0..self.ws_url_len])) return false;
        const detail = ws_relay.takeDetail();
        if (!invite.edgeRejectedUpgrade(detail)) return false;
        const next = invite.hosted_ws_fallback;
        if (next.len > self.ws_url.len) return false;
        self.used_fallback = true;
        @memcpy(self.ws_url[0..next.len], next);
        self.ws_url_len = next.len;
        std.debug.print("share: relay.youneek.xyz rejected the WebSocket ({s}); dialing {s}\n", .{ detail, next });
        return true;
    }

    fn retry(self: *Dial, err: anyerror, cancel: netdial.CancelFn) bool {
        if (!self.wait_peer or err == error.Cancelled or cancel.check()) {
            self.fail(err);
            return false;
        }
        var i: u32 = 0;
        while (i < 20) : (i += 1) {
            if (cancel.check()) {
                self.fail(error.Cancelled);
                return false;
            }
            std.time.sleep(50 * std.time.ns_per_ms);
        }
        return true;
    }

    fn openTcp(self: *Dial, cancel: netdial.CancelFn) !std.net.Stream {
        const fd = try netdial.connect(self.relay_host[0..self.relay_host_len], self.relay_port, 15000, cancel);
        const stream = std.net.Stream{ .handle = fd };
        errdefer stream.close();
        const wait_ms: u32 = if (self.wait_peer) std.math.maxInt(u32) else 20000;
        try relay.preface(stream, self.role, &self.id, wait_ms, cancel);
        return stream;
    }

    /// Keep the real reason (TLS alert, connect errno, certificate load).
    /// A hosting dial keeps retrying; the first failure is printed and the
    /// LAN listener stays up. Giving up sets `done` via `fail`.
    fn remember(self: *Dial, err: anyerror) void {
        const detail = ws_relay.takeDetail();
        const text: []const u8 = if (detail.len > 0) detail else @errorName(err);
        self.mu.lock();
        const first = self.err_len == 0;
        const n = @min(text.len, self.err.len);
        @memcpy(self.err[0..n], text[0..n]);
        self.err_len = n;
        self.mu.unlock();
        if (!first) return;
        // The host cancels this dial when a LAN guest connects, and --join
        // cancels it when the wait is over. That is not a relay failure.
        if (err == error.Cancelled) return;
        if (self.wait_peer) {
            std.debug.print("share: relay failed ({s}); hosting on the LAN only\n", .{text});
        } else {
            std.debug.print("share: relay failed ({s})\n", .{text});
        }
    }

    fn fail(self: *Dial, err: anyerror) void {
        self.remember(err);
        self.mu.lock();
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
    mode: DialMode = .direct,
    fallback: Fallback = .none,
    wait_peer: bool = false,
    role: relay.Role,
    id: [8]u8,
    host: []const u8,
    port: u16,
    relay_host: []const u8 = "",
    relay_port: u16 = 0,
    ws_url: []const u8 = "",
}) !*Dial {
    const d = try allocator.create(Dial);
    d.* = .{
        .mode = spec.mode,
        .fallback = spec.fallback,
        .wait_peer = spec.wait_peer,
        .role = spec.role,
        .id = spec.id,
        .port = spec.port,
        .relay_port = spec.relay_port,
    };
    d.host_len = @min(spec.host.len, d.host.len);
    @memcpy(d.host[0..d.host_len], spec.host[0..d.host_len]);
    d.relay_host_len = @min(spec.relay_host.len, d.relay_host.len);
    @memcpy(d.relay_host[0..d.relay_host_len], spec.relay_host[0..d.relay_host_len]);
    d.ws_url_len = @min(spec.ws_url.len, d.ws_url.len);
    @memcpy(d.ws_url[0..d.ws_url_len], spec.ws_url[0..d.ws_url_len]);
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
    relay_kind: invite.RelayKind = .off,
    relay_url: [invite.max_relay]u8 = [_]u8{0} ** invite.max_relay,
    relay_url_len: usize = 0,
    relay_tcp_host: [invite.max_relay]u8 = [_]u8{0} ** invite.max_relay,
    relay_tcp_host_len: usize = 0,
    relay_tcp_port: u16 = 0,
    fail: [160]u8 = [_]u8{0} ** 160,
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

        const mode = invite.classifyRelay(relay_url) catch return error.BadRelay;
        self.relay_kind = mode.kind;
        if (mode.kind == .ws) {
            self.relay_url_len = @min(mode.ws_url.len, self.relay_url.len);
            @memcpy(self.relay_url[0..self.relay_url_len], mode.ws_url[0..self.relay_url_len]);
        } else if (mode.kind == .tcp) {
            self.relay_tcp_host_len = @min(mode.tcp_host.len, self.relay_tcp_host.len);
            @memcpy(self.relay_tcp_host[0..self.relay_tcp_host_len], mode.tcp_host[0..self.relay_tcp_host_len]);
            self.relay_tcp_port = mode.tcp_port;
        }

        const addr = std.net.Address.parseIp(bind_ip, port_n) catch return error.BadAddress;
        io.ignoreSigpipe();
        if (addr.listen(.{ .reuse_address = true, .force_nonblocking = true })) |listener| {
            self.listener = listener;
            io.armSocket(listener.stream.handle);
            self.port_n = listener.listen_address.getPort();
        } else |err| {
            if (mode.kind == .off) return err;
            self.port_n = port_n;
        }
        var code_buf: [512]u8 = undefined;
        const code = try invite.encode(&code_buf, .{
            .host = advertise,
            .port = self.port_n,
            .secret = sec,
            .relay = relay_url,
        });
        self.code = try allocator.dupe(u8, code);
        code_owned = true;
        self.armRelay();
        if (self.listener == null and self.dial == null) return error.BadAddress;
        return self;
    }

    fn relayId(self: *const Host) [8]u8 {
        return (invite.Invite{ .host = "", .port = self.port_n, .secret = self.secret, .relay = "" }).relayId();
    }

    fn armRelay(self: *Host) void {
        if (self.relay_kind == .off or self.dial != null) return;
        const mode: DialMode = switch (self.relay_kind) {
            .off => return,
            .tcp => .tcp,
            .ws => .ws,
        };
        self.dial = spawnDial(self.allocator, .{
            .mode = mode,
            .wait_peer = true,
            .role = .host,
            .id = self.relayId(),
            .host = "",
            .port = self.port_n,
            .relay_host = self.relay_tcp_host[0..self.relay_tcp_host_len],
            .relay_port = self.relay_tcp_port,
            .ws_url = self.relay_url[0..self.relay_url_len],
        }) catch |err| {
            self.note(@errorName(err));
            return;
        };
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
        if (self.link == null) if (self.listener) |*s| {
            const conn = s.accept() catch |err| switch (err) {
                error.WouldBlock, error.ConnectionAborted => null,
                else => return err,
            };
            if (conn) |c| {
                self.link = link_mod.Link.responder(self.allocator, c.stream, &self.psk) catch |err| {
                    c.stream.close();
                    return err;
                };
                trace.log("noise handshake", .{});
                io.setNonBlocking(self.link.?.stream.handle) catch {};
                link_mod.setNoDelay(self.link.?.stream);
                if (self.dial) |d| {
                    d.finish(self.allocator);
                    self.dial = null;
                }
            }
        };
        if (self.link == null) if (self.dial) |d| {
            if (d.errorName()) |name| {
                const alone = self.listener == null;
                d.finish(self.allocator);
                self.dial = null;
                if (alone) {
                    self.note(name);
                    self.phase = .closed;
                    return;
                }
                // The dial thread already printed the reason. The LAN socket
                // keeps accepting. A relay error must not end the share.
            } else if (d.take()) |stream| {
                d.finish(self.allocator);
                self.dial = null;
                self.link = link_mod.Link.responder(self.allocator, stream, &self.psk) catch |err| {
                    stream.close();
                    return err;
                };
                trace.log("noise handshake", .{});
                io.setNonBlocking(self.link.?.stream.handle) catch {};
                link_mod.setNoDelay(self.link.?.stream);
            }
        };
        const l = self.link orelse return;
        l.pump() catch |err| {
            self.dropGuest();
            if (err == error.Closed or err == error.Handshake or err == error.BadFrame) return;
            return err;
        };
        if (self.phase == .waiting and l.isOpen()) {
            trace.log("noise open", .{});
            std.debug.print("share: guest connected\n", .{});
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
        if (self.phase != .closed) {
            self.phase = .waiting;
            self.armRelay();
        }
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
    fail: [160]u8 = [_]u8{0} ** 160,
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
        io.ignoreSigpipe();
        var owned = try invite.decodeOwned(allocator, code);
        defer owned.deinit();
        const view = owned.view();
        const mode = invite.classifyRelay(view.relay) catch return error.BadRelay;
        const fallback: Fallback = switch (mode.kind) {
            .off => .none,
            .tcp => .tcp,
            .ws => .ws,
        };
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
            .mode = .direct,
            .fallback = fallback,
            .role = .guest,
            .id = view.relayId(),
            .host = view.host,
            .port = view.port,
            .relay_host = mode.tcp_host,
            .relay_port = mode.tcp_port,
            .ws_url = mode.ws_url,
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
                trace.log("noise handshake", .{});
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
        if (self.phase == .waiting and l.isOpen()) {
            trace.log("noise open", .{});
            self.phase = .open;
        }
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

test "same-machine guest dials loopback when the invite names this LAN address" {
    io.ensureSockets();
    var buf: [64]u8 = undefined;
    const lan = invite.detectLanHost(&buf);
    if (std.mem.eql(u8, lan, "127.0.0.1")) return;
    // Listener is loopback only. The LAN address in the invite is not
    // accepting. The session opens only if the guest tries 127.0.0.1.
    const host = try Host.listen(std.testing.allocator, "127.0.0.1", 0, lan, "", null);
    defer host.deinit();
    const guest = try Guest.start(std.testing.allocator, host.code);
    defer guest.deinit();
    try waitOpen(host, guest);
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

fn waitOpen(host: *Host, guest: *Guest) !void {
    var i: usize = 0;
    while (i < 400 and (host.phase != .open or guest.phase != .open)) : (i += 1) {
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
}

test "guest uses the relay when the LAN port does not answer" {
    io.ensureSockets();
    const mock = try ws_relay.Mock.start(std.testing.allocator);
    defer mock.deinit();
    var url_buf: [80]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "ws://127.0.0.1:{d}", .{mock.port()});
    const secret = [_]u8{ 4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 6, 6, 7, 7, 7, 7 };
    const host = try Host.listen(std.testing.allocator, "127.0.0.1", 0, "127.0.0.1", url, secret);
    defer host.deinit();
    var code_buf: [512]u8 = undefined;
    const code = try invite.encode(&code_buf, .{
        .host = "127.0.0.1",
        .port = 1,
        .secret = secret,
        .relay = url,
    });
    const guest = try Guest.start(std.testing.allocator, code);
    defer guest.deinit();
    try waitOpen(host, guest);

    var rowbuf: [msg.wire_len]u8 = undefined;
    msg.writeCell(&rowbuf, 'Q', 0xAABBCC, 0x101010, 0);
    try host.sendRow(.{
        .rows = 1,
        .cols = 1,
        .cursor_row = 0,
        .cursor_col = 0,
        .cursor_on = true,
        .index = 0,
        .cells = &rowbuf,
    });
    // The relay pump is another thread. An empty send buffer only means the
    // bytes left this process's socket, not that the guest has decrypted them.
    var saw: usize = 0;
    while (saw < 80 and guest.grid.items.len < msg.wire_len) : (saw += 1) {
        try host.tick();
        try guest.tick();
        std.time.sleep(5 * std.time.ns_per_ms);
    }
    try std.testing.expectEqual(@as(u21, 'Q'), msg.readCell(guest.grid.items[0..msg.wire_len]).cp);
    try std.testing.expect(mock.forwardedLen() > 0);
    try std.testing.expect(!mock.contains(&secret));
    try std.testing.expect(mock.guestCount() >= 1);
}

fn relayTcpUp(host: []const u8) bool {
    var stream = std.net.tcpConnectToHost(std.testing.allocator, host, 443) catch return false;
    stream.close();
    return true;
}

fn waitOpenFor(host: *Host, guest: *Guest, rounds: usize, step_ms: u64) !void {
    var i: usize = 0;
    while (i < rounds and (host.phase != .open or guest.phase != .open)) : (i += 1) {
        try host.tick();
        try guest.tick();
        if (guest.failure()) |why| {
            std.debug.print("join failed: {s}\n", .{why});
            return error.JoinFailed;
        }
        if (host.phase == .closed) return error.JoinFailed;
        std.time.sleep(step_ms * std.time.ns_per_ms);
    }
    try pumpBoth(host, guest);
    try std.testing.expectEqual(Phase.open, host.phase);
    try std.testing.expectEqual(Phase.open, guest.phase);
}

fn proveHostedSession(relay_url: []const u8) !void {
    // 192.0.2.1 is TEST-NET. The guest cannot prefer the LAN, so both sides
    // meet on the deployed relay. The listener stays on loopback.
    const host = try Host.listen(std.testing.allocator, "127.0.0.1", 0, "192.0.2.1", relay_url, null);
    defer host.deinit();
    const guest = try Guest.start(std.testing.allocator, host.code);
    defer guest.deinit();
    try waitOpenFor(host, guest, 400, 50);

    var rowbuf: [msg.wire_len]u8 = undefined;
    msg.writeCell(&rowbuf, 'R', 0xAABBCC, 0x101010, 0);
    try host.sendRow(.{
        .rows = 1,
        .cols = 1,
        .cursor_row = 0,
        .cursor_col = 0,
        .cursor_on = true,
        .index = 0,
        .cells = &rowbuf,
    });
    var saw: usize = 0;
    while (saw < 200 and guest.grid.items.len < msg.wire_len) : (saw += 1) {
        try host.tick();
        try guest.tick();
        std.time.sleep(50 * std.time.ns_per_ms);
    }
    try std.testing.expect(guest.grid.items.len >= msg.wire_len);
    try std.testing.expectEqual(@as(u21, 'R'), msg.readCell(guest.grid.items[0..msg.wire_len]).cp);

    try guest.sendInput("nope");
    const dropped_before = host.dropped;
    var dropped: usize = 0;
    while (dropped < 80 and host.dropped == dropped_before) : (dropped += 1) {
        try host.tick();
        try guest.tick();
        std.time.sleep(50 * std.time.ns_per_ms);
    }
    try std.testing.expect(host.dropped > dropped_before);
    try std.testing.expectEqual(@as(usize, 0), host.input.items.len);

    try host.setControl(true);
    var grant: usize = 0;
    while (grant < 80 and guest.access != .control) : (grant += 1) {
        try host.tick();
        try guest.tick();
        std.time.sleep(50 * std.time.ns_per_ms);
    }
    try std.testing.expectEqual(Access.control, guest.access);
    try guest.sendInput("hi\n");
    var got: usize = 0;
    while (got < 80 and !std.mem.eql(u8, host.input.items, "hi\n")) : (got += 1) {
        try host.tick();
        try guest.tick();
        std.time.sleep(50 * std.time.ns_per_ms);
    }
    try std.testing.expectEqualStrings("hi\n", host.input.items);
    std.debug.print("hosted session ok via {s}\n", .{relay_url});
}

test "workers.dev relay: guest sees the screen and types after the grant" {
    io.ensureSockets();
    if (!relayTcpUp("youneek-share-relay.youneekartifacts.workers.dev")) return;
    try proveHostedSession(invite.hosted_ws_fallback);
}

test "custom domain edge reject falls back to the workers.dev relay" {
    io.ensureSockets();
    if (!relayTcpUp("youneek-share-relay.youneekartifacts.workers.dev")) return;
    try proveHostedSession(invite.default_ws_relay);
}

test "guest prefers the LAN and does not dial the relay" {
    io.ensureSockets();
    const mock = try ws_relay.Mock.start(std.testing.allocator);
    defer mock.deinit();
    var url_buf: [80]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "ws://127.0.0.1:{d}", .{mock.port()});
    const host = try Host.listen(std.testing.allocator, "127.0.0.1", 0, "127.0.0.1", url, null);
    defer host.deinit();
    const guest = try Guest.start(std.testing.allocator, host.code);
    defer guest.deinit();
    try waitOpen(host, guest);
    try std.testing.expectEqual(@as(usize, 0), mock.guestCount());
}
