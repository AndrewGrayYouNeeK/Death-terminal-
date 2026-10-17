//! `deathterminal --ssh-session <target>`: the built-in SSH client.
//!
//! The window runs this inside its PTY (like it would run a shell), so
//! prompts, the remote shell and errors all draw in the terminal. It also
//! works on its own in any terminal. One thread runs a poll loop over
//! stdin, the SSH socket, forward listeners/connections, the control
//! socket and a signal pipe; jump hosts get a pump thread each.

const std = @import("std");
const posix = std.posix;
const c = @import("c.zig").c;
const config = @import("../config/config.zig");
const dial = @import("../net/dial.zig");
const forward = @import("forward.zig");
const ssh_config = @import("ssh_config.zig");
const target_mod = @import("target.zig");
const session = @import("session.zig");
const bridge = @import("bridge.zig");
const control = @import("control.zig");
const tty_mod = @import("tty.zig");
const Tty = tty_mod.Tty;

const exit_conn_error: u8 = 255;

// ------------------------------------------------------------- signals

var sig_pipe: [2]posix.fd_t = .{ -1, -1 };

fn onSignal(sig: i32) callconv(.C) void {
    const b: [1]u8 = .{@intCast(sig & 0xff)};
    _ = posix.write(sig_pipe[1], &b) catch {};
}

fn installSignals() !void {
    sig_pipe = try posix.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
    const act = posix.Sigaction{ .handler = .{ .handler = onSignal }, .mask = posix.empty_sigset, .flags = posix.SA.RESTART };
    for ([_]u6{ posix.SIG.WINCH, posix.SIG.TERM, posix.SIG.HUP, posix.SIG.INT }) |s| try posix.sigaction(s, &act, null);
    const ign = posix.Sigaction{ .handler = .{ .handler = posix.SIG.IGN }, .mask = posix.empty_sigset, .flags = 0 };
    try posix.sigaction(posix.SIG.PIPE, &ign, null);
}

// ------------------------------------------------------------- forwards

const FwdState = struct {
    spec: forward.Forward,
    /// -L / -D listening socket.
    listen_fd: ?posix.fd_t = null,
    /// -R listener on the server.
    listener: ?*c.LIBSSH2_LISTENER = null,
    bound_port: c_int = 0,
    /// Pending -R request (needs the session; retried until done).
    op: enum { none, listen, cancel } = .none,
    msg_buf: [160]u8 = undefined,
    msg_len: usize = 0,
    conns: usize = 0,

    fn setMsg(self: *FwdState, comptime fmt: []const u8, args: anytype) void {
        self.msg_len = (std.fmt.bufPrint(&self.msg_buf, fmt, args) catch "").len;
    }
    fn msg(self: *const FwdState) []const u8 {
        return self.msg_buf[0..self.msg_len];
    }
};

const Conn = struct {
    fwd: usize,
    fd: posix.fd_t,
    state: enum { socks, opening, open, closing },
    socks: forward.Socks = .{},
    host_buf: [256]u8 = undefined,
    host_len: usize = 0,
    port: u16 = 0,
    peer_buf: [64]u8 = undefined,
    peer_len: usize = 0,
    peer_port: u16 = 0,
    /// `br.chan` is set (and must be freed).
    has_chan: bool = false,
    br: bridge.Bridge,

    fn host(self: *const Conn) []const u8 {
        return self.host_buf[0..self.host_len];
    }
};

// ------------------------------------------------------------- client

const Outcome = union(enum) {
    exited: u8,
    lost: []const u8,
    quit,
    reconnect,
};

pub const Client = struct {
    a: std.mem.Allocator,
    tty: Tty = .{},
    target: target_mod.Target,
    opts: session.Options,
    fwds: std.ArrayList(FwdState),
    conns: std.ArrayList(*Conn),
    ctl: ?control.Server = null,
    conn: ?session.Connection = null,
    chan: ?*c.LIBSSH2_CHANNEL = null,
    state: enum { connecting, connected, disconnected } = .connecting,
    reconnect_requested: bool = false,
    /// A connect report went out (OSC 7799); a disconnect one is owed.
    announced: bool = false,
    in_buf: bridge.Buf = .{},
    stdin_eof: bool = false,
    eof_sent: bool = false,
    resize_pending: bool = false,
    last_rx_ms: i64 = 0,
    last_ka_ms: i64 = 0,
    /// One libssh2 "open" at a time (direct-tcpip / forward listen / cancel).
    busy_conn: ?*Conn = null,
    /// Keepalives whose reply has not been dropped yet. A tcpip-forward
    /// request is only sent at 0, or it would take a keepalive's reply.
    ka_pending: u32 = 0,
    /// A tcpip-forward request is in flight (no keepalives meanwhile).
    global_busy: bool = false,

    fn sess(self: *Client) *c.LIBSSH2_SESSION {
        return self.conn.?.session;
    }

    // --------------------------------------------------------- main

    pub fn run(self: *Client) u8 {
        self.tty.enterRaw();
        defer self.tty.restore();
        self.ctl = control.Server.listen() catch null;
        defer if (self.ctl) |*s| s.deinit();

        var attempt: u32 = 0;
        while (true) {
            var db: [300]u8 = undefined;
            self.state = .connecting;
            self.tty.status("Connecting to {s}{s}…", .{ self.target.display(&db), if (self.target.jumps.len > 0) " (via jump host)" else "" });
            const conn = session.open(self.a, &self.target, self.opts) catch |err| {
                self.tty.clearStatus();
                self.state = .disconnected;
                if (session.isFatal(err) or !self.target.reconnect) return exit_conn_error;
                attempt += 1;
                if (!self.waitReconnect(attempt, "could not connect")) return exit_conn_error;
                continue;
            };
            self.tty.clearStatus();
            self.conn = conn;
            attempt = 0;
            const out = self.runSession();
            self.teardown();
            switch (out) {
                .exited => |code| {
                    self.tty.print("{s}Connection to {s} closed.{s}\n", .{ tty_mod.dim, self.target.host, tty_mod.reset });
                    return code;
                },
                .quit => return exit_conn_error,
                .reconnect => {
                    self.tty.print("\n{s}[reconnecting to {s}]{s}\n", .{ tty_mod.yellow, self.target.display(&db), tty_mod.reset });
                    continue;
                },
                .lost => |why| {
                    if (!self.target.reconnect) {
                        self.tty.print("\n{s}Connection to {s} lost: {s}{s}\n", .{ tty_mod.yellow, self.target.host, why, tty_mod.reset });
                        return exit_conn_error;
                    }
                    attempt += 1;
                    if (!self.waitReconnect(attempt, why)) return exit_conn_error;
                },
            }
        }
    }

    /// Backoff 1, 2, 4 … 30 s. r / Enter retries now; q / Ctrl+C quits.
    fn waitReconnect(self: *Client, attempt: u32, why: []const u8) bool {
        const delay_s: u32 = @min(@as(u32, 1) << @intCast(@min(attempt - 1, 5)), 30);
        self.tty.print("\n{s}[connection to {s}: {s} — reconnecting in {d}s; r = now, q = quit]{s}\n", .{ tty_mod.yellow, self.target.host, why, delay_s, tty_mod.reset });
        const deadline = std.time.milliTimestamp() + @as(i64, delay_s) * 1000;
        while (true) {
            const left = deadline - std.time.milliTimestamp();
            if (left <= 0 or self.reconnect_requested) {
                self.reconnect_requested = false;
                return true;
            }
            var fds = [_]posix.pollfd{
                .{ .fd = self.tty.in, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = sig_pipe[0], .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = if (self.ctl) |s| s.fd else -1, .events = posix.POLL.IN, .revents = 0 },
            };
            _ = posix.poll(&fds, @intCast(@min(left, 1000))) catch return false;
            if (fds[0].revents != 0) {
                var b: [64]u8 = undefined;
                const n = posix.read(self.tty.in, &b) catch 0;
                if (n == 0) return false;
                for (b[0..n]) |ch| switch (ch) {
                    'q', 'Q', 3, 4 => return false,
                    'r', 'R', '\r', '\n' => return true,
                    else => {},
                };
            }
            if (fds[1].revents != 0) {
                var b: [16]u8 = undefined;
                const n = posix.read(sig_pipe[0], &b) catch 0;
                for (b[0..n]) |sg| if (sg == posix.SIG.TERM or sg == posix.SIG.HUP or sg == posix.SIG.INT) return false;
            }
            if (fds[2].revents != 0) self.serveControl();
        }
    }

    /// Tell the terminal (and so plugins' ssh_connect / ssh_disconnect)
    /// with the per-window secret it gave us in DT_SSH_NONCE.
    fn announce(self: *Client, up: bool) void {
        if (up == self.announced) return;
        self.announced = up;
        const nonce = posix.getenv("DT_SSH_NONCE") orelse return;
        if (nonce.len == 0 or nonce.len > 64) return;
        for (nonce) |ch| if (!std.ascii.isAlphanumeric(ch)) return;
        var db: [300]u8 = undefined;
        self.tty.print("\x1b]7799;{s};{s};{s}\x07", .{ nonce, if (up) "connect" else "disconnect", self.target.display(&db) });
    }

    fn teardown(self: *Client) void {
        self.announce(false);
        for (self.conns.items) |cn| {
            posix.close(cn.fd);
            self.a.destroy(cn);
        }
        self.conns.clearRetainingCapacity();
        self.busy_conn = null;
        for (self.fwds.items) |*f| {
            if (f.listen_fd) |fd| posix.close(fd);
            f.listen_fd = null;
            f.listener = null; // freed with the session
            f.op = .none;
            f.conns = 0;
            if (f.spec.enabled) f.setMsg("waiting for the connection", .{});
        }
        if (self.conn) |*cn| {
            if (self.chan) |ch| _ = c.libssh2_channel_free(ch);
            cn.close("bye");
        }
        self.chan = null;
        self.conn = null;
        self.state = .disconnected;
        self.in_buf = .{};
        self.eof_sent = false;
    }

    // --------------------------------------------------------- session

    fn runSession(self: *Client) Outcome {
        const s = self.sess();
        const chan = c.libssh2_channel_open_ex(s, "session", 7, c.LIBSSH2_CHANNEL_WINDOW_DEFAULT, c.LIBSSH2_CHANNEL_PACKET_DEFAULT, null, 0) orelse
            return .{ .lost = session.lastError(s) };
        self.chan = chan;
        for (self.target.env) |kv| {
            const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
            // Refused names (the server's AcceptEnv) are not an error.
            _ = c.libssh2_channel_setenv_ex(chan, kv.ptr, @intCast(eq), kv[eq + 1 ..].ptr, @intCast(kv.len - eq - 1));
        }
        if (self.tty.isTty()) {
            const sz = self.tty.size();
            const term = posix.getenv("TERM") orelse "xterm-256color";
            // VINTR ^C, VERASE ^?, IUTF8 on, TTY_OP_END.
            const modes = [_]u8{ 1, 0, 0, 0, 3, 3, 0, 0, 0, 0x7f, 42, 0, 0, 0, 1, 0 };
            if (c.libssh2_channel_request_pty_ex(chan, term.ptr, @intCast(term.len), &modes, modes.len, sz.cols, sz.rows, sz.xpx, sz.ypx) != 0)
                return .{ .lost = session.lastError(s) };
        }
        if (c.libssh2_channel_process_startup(chan, "shell", 5, null, 0) != 0) return .{ .lost = session.lastError(s) };
        var db: [300]u8 = undefined;
        self.tty.print("\x1b]2;ssh {s}\x07", .{self.target.display(&db)});
        if (self.target.command.len > 0) {
            _ = self.in_buf.append(self.target.command);
            _ = self.in_buf.append("\r");
        }
        self.state = .connected;
        self.announce(true);
        if (self.target.keepalive_s > 0) c.libssh2_keepalive_config(s, 1, self.target.keepalive_s);
        c.libssh2_session_set_blocking(s, 0);
        const now = std.time.milliTimestamp();
        self.last_rx_ms = now;
        self.last_ka_ms = now;
        self.ka_pending = 0;
        self.global_busy = false;
        for (self.fwds.items, 0..) |*f, i| if (f.spec.enabled) self.startForward(i);

        var fds = std.ArrayList(posix.pollfd).init(self.a);
        defer fds.deinit();
        var kinds = std.ArrayList(PollKind).init(self.a);
        defer kinds.deinit();
        while (true) {
            var spins: usize = 0;
            while (spins < 64) : (spins += 1) {
                const r = self.pump();
                switch (r) {
                    .progress => continue,
                    .idle => break,
                    .done => |o| return o,
                }
            }
            if (self.reconnect_requested) {
                self.reconnect_requested = false;
                return .reconnect;
            }
            // Keepalives, and declaring a silent server dead (3 misses).
            const t = std.time.milliTimestamp();
            if (self.target.keepalive_s > 0) {
                const iv: i64 = @as(i64, self.target.keepalive_s) * 1000;
                if (!self.global_busy) {
                    self.ka_pending -|= @intCast(session.dt_libssh2_drop_global_replies(s));
                    if (t - self.last_ka_ms >= iv) {
                        if (session.sendKeepalive(s, self.conn.?.fd)) self.ka_pending += 1;
                        self.last_ka_ms = t;
                    }
                }
                if (t - self.last_rx_ms > iv * 3 + 1000) return .{ .lost = "no reply to keepalives" };
            }

            fds.clearRetainingCapacity();
            kinds.clearRetainingCapacity();
            const dirs = c.libssh2_session_block_directions(s);
            self.addFd(&fds, &kinds, self.conn.?.fd, posix.POLL.IN | @as(i16, if (dirs & c.LIBSSH2_SESSION_BLOCK_OUTBOUND != 0) posix.POLL.OUT else 0), .ssh) catch return .quit;
            if (!self.stdin_eof and self.in_buf.data.len - self.in_buf.end + self.in_buf.start > 256)
                self.addFd(&fds, &kinds, self.tty.in, posix.POLL.IN, .stdin) catch return .quit;
            self.addFd(&fds, &kinds, sig_pipe[0], posix.POLL.IN, .signal) catch return .quit;
            if (self.ctl) |srv| self.addFd(&fds, &kinds, srv.fd, posix.POLL.IN, .control) catch return .quit;
            for (self.fwds.items, 0..) |f, i| if (f.listen_fd) |lfd| self.addFd(&fds, &kinds, lfd, posix.POLL.IN, .{ .listener = i }) catch return .quit;
            for (self.conns.items) |cn| {
                var ev: i16 = 0;
                if (cn.state == .socks or (cn.state == .open and cn.br.wantsRead())) ev |= posix.POLL.IN;
                if (cn.state == .open and cn.br.wantsWrite()) ev |= posix.POLL.OUT;
                if (ev != 0) self.addFd(&fds, &kinds, cn.fd, ev, .conn) catch return .quit;
            }
            const busy = self.busy_conn != null or self.hasRemoteOps();
            const timeout: i32 = if (busy) 50 else 1000;
            _ = posix.poll(fds.items, timeout) catch return .quit;
            for (fds.items, kinds.items) |pfd, k| {
                if (pfd.revents == 0) continue;
                switch (k) {
                    .ssh => self.last_rx_ms = std.time.milliTimestamp(),
                    .stdin => self.readStdin(),
                    .signal => if (self.readSignals()) return .quit,
                    .control => self.serveControl(),
                    .listener => |i| self.acceptLocal(i),
                    .conn => {},
                }
            }
        }
    }

    const PollKind = union(enum) { ssh, stdin, signal, control, listener: usize, conn };

    fn addFd(self: *Client, fds: *std.ArrayList(posix.pollfd), kinds: *std.ArrayList(PollKind), fd: posix.fd_t, ev: i16, k: PollKind) !void {
        _ = self;
        try fds.append(.{ .fd = fd, .events = ev, .revents = 0 });
        try kinds.append(k);
    }

    fn readStdin(self: *Client) void {
        const f = self.in_buf.free();
        if (f.len == 0) return;
        const n = posix.read(self.tty.in, f) catch |err| switch (err) {
            error.WouldBlock => return,
            else => 0,
        };
        if (n == 0) {
            self.stdin_eof = true;
            return;
        }
        self.in_buf.commit(n);
    }

    /// true = quit.
    fn readSignals(self: *Client) bool {
        var b: [32]u8 = undefined;
        const n = posix.read(sig_pipe[0], &b) catch return false;
        var quit = false;
        for (b[0..n]) |sg| switch (sg) {
            posix.SIG.WINCH => self.resize_pending = true,
            posix.SIG.TERM, posix.SIG.HUP => quit = true,
            posix.SIG.INT => if (!self.tty.isTty()) {
                quit = true;
            },
            else => {},
        };
        return quit;
    }

    const Pump = union(enum) { progress, idle, done: Outcome };

    /// One non-blocking pass over everything libssh2 owns.
    fn pump(self: *Client) Pump {
        const s = self.sess();
        const chan = self.chan.?;
        var progress = false;

        // keyboard → remote
        while (!self.in_buf.isEmpty()) {
            const p = self.in_buf.pending();
            const rc = c.libssh2_channel_write_ex(chan, 0, p.ptr, p.len);
            if (rc == c.LIBSSH2_ERROR_EAGAIN) break;
            if (rc < 0) return .{ .done = .{ .lost = session.lastError(s) } };
            self.in_buf.consume(@intCast(rc));
            progress = true;
        }
        if (self.stdin_eof and self.in_buf.isEmpty() and !self.eof_sent) {
            const rc = c.libssh2_channel_send_eof(chan);
            if (rc != c.LIBSSH2_ERROR_EAGAIN) self.eof_sent = true;
        }

        // remote → screen (stdout, then stderr)
        var buf: [32 * 1024]u8 = undefined;
        for ([_]c_int{ 0, c.SSH_EXTENDED_DATA_STDERR }) |stream| {
            while (true) {
                const rc = c.libssh2_channel_read_ex(chan, stream, &buf, buf.len);
                if (rc > 0) {
                    self.tty.write(buf[0..@intCast(rc)]);
                    progress = true;
                    continue;
                }
                if (rc == 0 or rc == c.LIBSSH2_ERROR_EAGAIN) break;
                if (rc == c.LIBSSH2_ERROR_CHANNEL_CLOSED) break;
                return .{ .done = .{ .lost = session.lastError(s) } };
            }
        }

        if (self.resize_pending) {
            const sz = self.tty.size();
            const rc = c.libssh2_channel_request_pty_size_ex(chan, sz.cols, sz.rows, sz.xpx, sz.ypx);
            if (rc != c.LIBSSH2_ERROR_EAGAIN) self.resize_pending = false;
        }

        if (self.remoteOps()) progress = true;
        if (self.acceptRemote()) progress = true;
        if (self.pumpConns()) progress = true;

        if (c.libssh2_channel_eof(chan) == 1) return .{ .done = self.finish(chan) };
        // A dead transport shows up as an error on the next call.
        const errno_ = c.libssh2_session_last_errno(s);
        if (errno_ == c.LIBSSH2_ERROR_SOCKET_RECV or errno_ == c.LIBSSH2_ERROR_SOCKET_DISCONNECT or errno_ == c.LIBSSH2_ERROR_SOCKET_SEND)
            return .{ .done = .{ .lost = session.lastError(s) } };
        return if (progress) .progress else .idle;
    }

    /// The remote shell sent EOF: collect the exit status.
    fn finish(self: *Client, chan: *c.LIBSSH2_CHANNEL) Outcome {
        const s = self.sess();
        const deadline = std.time.milliTimestamp() + 2000;
        while (std.time.milliTimestamp() < deadline) {
            var buf: [4096]u8 = undefined;
            const rd = c.libssh2_channel_read_ex(chan, 0, &buf, buf.len);
            if (rd > 0) self.tty.write(buf[0..@intCast(rd)]);
            const rc = c.libssh2_channel_wait_closed(chan);
            if (rc != c.LIBSSH2_ERROR_EAGAIN) break;
            var pfd = [_]posix.pollfd{.{ .fd = self.conn.?.fd, .events = posix.POLL.IN, .revents = 0 }};
            _ = posix.poll(&pfd, 50) catch break;
        }
        var sig: [*c]u8 = null;
        var sig_len: usize = 0;
        _ = c.libssh2_channel_get_exit_signal(chan, &sig, &sig_len, null, null, null, null);
        if (sig != null) {
            defer c.libssh2_free(s, sig);
            const name = sig[0..sig_len];
            self.tty.print("{s}Remote shell killed by signal {s}.{s}\n", .{ tty_mod.yellow, name, tty_mod.reset });
            return .{ .exited = 128 + signalNumber(name) };
        }
        const code = c.libssh2_channel_get_exit_status(chan);
        return .{ .exited = @intCast(code & 0xff) };
    }

    // --------------------------------------------------------- forwards

    fn startForward(self: *Client, i: usize) void {
        const f = &self.fwds.items[i];
        f.spec.enabled = true;
        if (self.state != .connected) {
            f.setMsg("waiting for the connection", .{});
            return;
        }
        switch (f.spec.kind) {
            .local, .dynamic => {
                if (f.listen_fd != null) return;
                const host = if (f.spec.bind_host.len > 0) f.spec.bind_host else "127.0.0.1";
                const addrs = dial.resolve(host, f.spec.bind_port, 3000, null) catch |err| {
                    f.setMsg("cannot resolve {s}: {s}", .{ host, @errorName(err) });
                    return;
                };
                const addr = addrs.slice()[0];
                var a = addr;
                const fd = posix.socket(a.any.family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK, 0) catch |err| {
                    f.setMsg("socket: {s}", .{@errorName(err)});
                    return;
                };
                posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1))) catch {};
                posix.bind(fd, &a.any, a.getOsSockLen()) catch |err| {
                    posix.close(fd);
                    f.setMsg("cannot listen on {s}:{d}: {s}", .{ host, f.spec.bind_port, if (err == error.AddressInUse) "address in use" else @errorName(err) });
                    return;
                };
                posix.listen(fd, 16) catch |err| {
                    posix.close(fd);
                    f.setMsg("listen: {s}", .{@errorName(err)});
                    return;
                };
                f.listen_fd = fd;
                if (f.spec.kind == .dynamic)
                    f.setMsg("SOCKS proxy on {s}:{d}", .{ host, f.spec.bind_port })
                else
                    f.setMsg("listening on {s}:{d}", .{ host, f.spec.bind_port });
            },
            .remote => {
                if (f.listener != null) return;
                f.op = .listen;
                f.setMsg("asking the server to listen", .{});
            },
        }
    }

    fn stopForward(self: *Client, i: usize) void {
        const f = &self.fwds.items[i];
        f.spec.enabled = false;
        if (f.listen_fd) |fd| posix.close(fd);
        f.listen_fd = null;
        if (f.listener != null) {
            f.op = .cancel;
        } else if (f.op == .listen) f.op = .none;
        f.setMsg("off", .{});
    }

    fn hasRemoteOps(self: *Client) bool {
        for (self.fwds.items) |f| if (f.op != .none) return true;
        return false;
    }

    /// -R listen / cancel requests, one at a time and only while no
    /// direct-tcpip open is in flight (both use session-level state).
    fn remoteOps(self: *Client) bool {
        if (self.busy_conn != null) return false;
        const s = self.sess();
        for (self.fwds.items) |*f| {
            switch (f.op) {
                .none => continue,
                .listen => {
                    if (!self.global_busy) {
                        // Replies to earlier keepalives must be gone first.
                        self.ka_pending -|= @intCast(session.dt_libssh2_drop_global_replies(s));
                        if (self.ka_pending > 0) return false;
                    }
                    var hb: [256]u8 = undefined;
                    const hz: ?[*:0]const u8 = if (f.spec.bind_host.len > 0) (std.fmt.bufPrintZ(&hb, "{s}", .{f.spec.bind_host}) catch return false).ptr else null;
                    var bound: c_int = 0;
                    const l = c.libssh2_channel_forward_listen_ex(s, hz, f.spec.bind_port, &bound, 16);
                    if (l == null) {
                        if (c.libssh2_session_last_errno(s) == c.LIBSSH2_ERROR_EAGAIN) {
                            self.global_busy = true;
                            return false;
                        }
                        self.global_busy = false;
                        f.op = .none;
                        f.setMsg("the server refused to listen on port {d}", .{f.spec.bind_port});
                        return true;
                    }
                    self.global_busy = false;
                    f.listener = l;
                    f.bound_port = bound;
                    f.op = .none;
                    f.setMsg("server listening on port {d}", .{if (bound != 0) bound else f.spec.bind_port});
                    return true;
                },
                .cancel => {
                    const rc = c.libssh2_channel_forward_cancel(f.listener.?);
                    if (rc == c.LIBSSH2_ERROR_EAGAIN) return false;
                    f.listener = null;
                    f.op = .none;
                    return true;
                },
            }
        }
        return false;
    }

    fn acceptLocal(self: *Client, i: usize) void {
        const f = &self.fwds.items[i];
        const lfd = f.listen_fd orelse return;
        var addr: std.net.Address = undefined;
        var alen: posix.socklen_t = @sizeOf(std.net.Address);
        const fd = posix.accept(lfd, &addr.any, &alen, posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK) catch return;
        const cn = self.a.create(Conn) catch {
            posix.close(fd);
            return;
        };
        cn.* = .{ .fwd = i, .fd = fd, .state = if (f.spec.kind == .dynamic) .socks else .opening, .br = .{ .chan = undefined, .fd = fd } };
        var pb: [80]u8 = undefined;
        const ps = std.fmt.bufPrint(&pb, "{}", .{addr}) catch "127.0.0.1:0";
        const colon = std.mem.lastIndexOfScalar(u8, ps, ':') orelse ps.len;
        const ph = std.mem.trim(u8, ps[0..colon], "[]");
        cn.peer_len = @min(ph.len, cn.peer_buf.len);
        @memcpy(cn.peer_buf[0..cn.peer_len], ph[0..cn.peer_len]);
        cn.peer_port = addr.getPort();
        if (f.spec.kind == .local) {
            cn.host_len = @min(f.spec.host.len, cn.host_buf.len);
            @memcpy(cn.host_buf[0..cn.host_len], f.spec.host[0..cn.host_len]);
            cn.port = f.spec.port;
        }
        self.conns.append(cn) catch {
            posix.close(fd);
            self.a.destroy(cn);
            return;
        };
        f.conns += 1;
    }

    /// Connections the server forwards to us (-R).
    fn acceptRemote(self: *Client) bool {
        var progress = false;
        for (self.fwds.items, 0..) |*f, i| {
            const l = f.listener orelse continue;
            if (f.op != .none) continue;
            const ch = c.libssh2_channel_forward_accept(l) orelse continue;
            progress = true;
            const fd = dial.connect(f.spec.host, f.spec.port, 3000, null) catch {
                _ = c.libssh2_channel_free(ch);
                continue;
            };
            bridge.setNonBlocking(fd);
            const cn = self.a.create(Conn) catch {
                posix.close(fd);
                _ = c.libssh2_channel_free(ch);
                continue;
            };
            cn.* = .{ .fwd = i, .fd = fd, .state = .open, .has_chan = true, .br = .{ .chan = ch, .fd = fd } };
            self.conns.append(cn) catch {
                posix.close(fd);
                _ = c.libssh2_channel_free(ch);
                self.a.destroy(cn);
                continue;
            };
            f.conns += 1;
        }
        return progress;
    }

    fn pumpConns(self: *Client) bool {
        const s = self.sess();
        var progress = false;
        var i: usize = 0;
        while (i < self.conns.items.len) {
            const cn = self.conns.items[i];
            switch (cn.state) {
                .socks => {
                    const f = cn.br.to_chan.free();
                    if (f.len > 0) {
                        if (posix.read(cn.fd, f)) |n| {
                            if (n == 0) cn.state = .closing else cn.br.to_chan.commit(n);
                            progress = true;
                        } else |err| if (err != error.WouldBlock) {
                            cn.state = .closing;
                        }
                    }
                    if (cn.state == .socks) switch (cn.socks.feed(cn.br.to_chan.pending())) {
                        .need_more => {},
                        .reply => |r| {
                            writeAll(cn.fd, r.bytes);
                            cn.br.to_chan.consume(r.consumed);
                            progress = true;
                        },
                        .connect => |r| {
                            cn.host_len = r.host.len;
                            @memcpy(cn.host_buf[0..r.host.len], r.host);
                            cn.port = r.port;
                            cn.br.to_chan.consume(r.consumed);
                            cn.state = .opening;
                            progress = true;
                        },
                        .fail => |bytes| {
                            writeAll(cn.fd, bytes);
                            cn.state = .closing;
                        },
                    };
                },
                .opening => if (self.busy_conn == null or self.busy_conn == cn) {
                    if (!self.hasRemoteOps() or self.busy_conn == cn) {
                        var hb: [257]u8 = undefined;
                        const hz = std.fmt.bufPrintZ(&hb, "{s}", .{cn.host()}) catch "";
                        var pb: [65]u8 = undefined;
                        const pz = std.fmt.bufPrintZ(&pb, "{s}", .{cn.peer_buf[0..cn.peer_len]}) catch "127.0.0.1";
                        const ch = c.libssh2_channel_direct_tcpip_ex(s, hz.ptr, cn.port, pz.ptr, cn.peer_port);
                        if (ch) |chp| {
                            self.busy_conn = null;
                            cn.br.chan = chp;
                            cn.has_chan = true;
                            cn.state = .open;
                            if (self.fwds.items[cn.fwd].spec.kind == .dynamic) writeAll(cn.fd, cn.socks.successReply());
                            progress = true;
                        } else if (c.libssh2_session_last_errno(s) == c.LIBSSH2_ERROR_EAGAIN) {
                            self.busy_conn = cn;
                        } else {
                            self.busy_conn = null;
                            if (self.fwds.items[cn.fwd].spec.kind == .dynamic) writeAll(cn.fd, cn.socks.failureReply());
                            cn.state = .closing;
                            progress = true;
                        }
                    }
                },
                .open => {
                    if (cn.br.step()) progress = true;
                    if (cn.br.done()) {
                        cn.state = .closing;
                        progress = true;
                    }
                },
                .closing => {},
            }
            if (cn.state == .closing) {
                if (cn.has_chan) {
                    const rc = c.libssh2_channel_free(cn.br.chan);
                    if (rc == c.LIBSSH2_ERROR_EAGAIN) {
                        i += 1;
                        continue;
                    }
                    cn.has_chan = false;
                }
                posix.close(cn.fd);
                const f = &self.fwds.items[cn.fwd];
                if (f.conns > 0) f.conns -= 1;
                _ = self.conns.orderedRemove(i);
                self.a.destroy(cn);
                progress = true;
                continue;
            }
            i += 1;
        }
        return progress;
    }

    // --------------------------------------------------------- control

    fn serveControl(self: *Client) void {
        var srv = &(self.ctl orelse return);
        var buf: [512]u8 = undefined;
        const req = srv.accept(&buf) orelse return;
        var out: [4096]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&out);
        const w = fbs.writer();
        var it = std.mem.tokenizeAny(u8, req.cmd, " \t");
        const verb = it.next() orelse "";
        const arg = std.mem.trim(u8, it.rest(), " \t");
        var db: [300]u8 = undefined;
        if (std.mem.eql(u8, verb, "status")) {
            w.print("{s} {s} {s}\n", .{ @tagName(self.state), self.target.label, self.target.display(&db) }) catch {};
        } else if (std.mem.eql(u8, verb, "list")) {
            for (self.fwds.items, 0..) |f, i| {
                var sb: [128]u8 = undefined;
                w.print("{d} {s} {s} | {s}{s}\n", .{ i + 1, if (f.spec.enabled) "on" else "off", f.spec.toText(&sb), f.msg(), if (f.conns > 0) " (active)" else "" }) catch {};
            }
        } else if (std.mem.eql(u8, verb, "toggle") or std.mem.eql(u8, verb, "on") or std.mem.eql(u8, verb, "off")) {
            const n = std.fmt.parseInt(usize, arg, 10) catch 0;
            if (n == 0 or n > self.fwds.items.len) {
                w.print("error no forward {s} (have {d})\n", .{ arg, self.fwds.items.len }) catch {};
            } else {
                const f = &self.fwds.items[n - 1];
                const want = if (std.mem.eql(u8, verb, "on")) true else if (std.mem.eql(u8, verb, "off")) false else !f.spec.enabled;
                if (want) self.startForward(n - 1) else self.stopForward(n - 1);
                w.print("ok {s} {s}\n", .{ if (want) "on" else "off", f.msg() }) catch {};
            }
        } else if (std.mem.eql(u8, verb, "add")) {
            if (forward.parse(arg)) |fw| {
                const owned = fw.dupe(self.a) catch fw;
                if (self.fwds.append(.{ .spec = owned })) {
                    self.startForward(self.fwds.items.len - 1);
                    w.print("ok {d} {s}\n", .{ self.fwds.items.len, self.fwds.items[self.fwds.items.len - 1].msg() }) catch {};
                } else |_| w.writeAll("error out of memory\n") catch {};
            } else |err| w.print("error {s}\n", .{forward.errorText(err)}) catch {};
        } else if (std.mem.eql(u8, verb, "reconnect")) {
            self.reconnect_requested = true;
            w.writeAll("ok\n") catch {};
        } else {
            w.writeAll("error commands: status, list, toggle <n>, on <n>, off <n>, add <spec>, reconnect\n") catch {};
        }
        control.reply(req.fd, fbs.getWritten());
    }
};

fn writeAll(fd: posix.fd_t, bytes: []const u8) void {
    var rest = bytes;
    var tries: usize = 0;
    while (rest.len > 0 and tries < 100) : (tries += 1) {
        const n = posix.write(fd, rest) catch |err| switch (err) {
            error.WouldBlock => {
                var pfd = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 }};
                _ = posix.poll(&pfd, 100) catch {};
                continue;
            },
            else => return,
        };
        rest = rest[n..];
    }
}

fn signalNumber(name: []const u8) u8 {
    const names = [_]struct { []const u8, u8 }{
        .{ "HUP", 1 },   .{ "INT", 2 },   .{ "QUIT", 3 },  .{ "ILL", 4 },   .{ "ABRT", 6 },
        .{ "FPE", 8 },   .{ "KILL", 9 },  .{ "SEGV", 11 }, .{ "PIPE", 13 }, .{ "ALRM", 14 },
        .{ "TERM", 15 }, .{ "USR1", 10 }, .{ "USR2", 12 },
    };
    for (names) |n| if (std.mem.eql(u8, n[0], name)) return n[1];
    return 0;
}

// ------------------------------------------------------------- entry

pub fn resolveTarget(arena: std.mem.Allocator, cfg: *const config.Config, name: []const u8) !target_mod.Target {
    return target_mod.resolveForConfig(arena, cfg.ssh_profiles.items, cfg.ssh_config_file, cfg.ssh_keepalive_s, name);
}

pub fn main(a: std.mem.Allocator, args: []const []const u8) u8 {
    var name: ?[]const u8 = null;
    var i: usize = 1;
    var extra_forwards = std.ArrayList([]const u8).init(a);
    defer extra_forwards.deinit();
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--ssh-session")) {
            if (i + 1 < args.len) name = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "-L") or std.mem.eql(u8, arg, "-R") or std.mem.eql(u8, arg, "-D")) {
            if (i + 1 < args.len) extra_forwards.append(args[i]) catch {};
            if (i + 1 < args.len) extra_forwards.append(args[i + 1]) catch {};
            i += 1;
        }
    }
    const tname = name orelse {
        std.debug.print("usage: deathterminal --ssh-session <profile | alias | user@host[:port]> [-L spec] [-R spec] [-D spec] [--config file]\n", .{});
        return 2;
    };

    var diags = config.Diagnostics.init(a);
    defer diags.deinit();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const src = config.locate(&path_buf, config.configArg(args));
    var cfg = config.load(a, src, args, .{ .lua_unsafe = hasFlag(args, "--lua-unsafe") }, &diags) catch {
        std.debug.print("ssh: cannot load the config\n", .{});
        return exit_conn_error;
    };
    defer cfg.deinit();
    for (diags.items.items) |d| if (d.severity == .err and std.mem.indexOf(u8, d.text, "ssh") != null) std.debug.print("config: {s}\r\n", .{d.text});
    if (!cfg.ssh_enabled) {
        std.debug.print("ssh: the built-in SSH client is disabled (config.ssh.enabled = false)\n", .{});
        return exit_conn_error;
    }

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const target = resolveTarget(aa, &cfg, tname) catch |err| {
        std.debug.print("ssh: cannot use \"{s}\": {s} (expected a profile from config.ssh.profiles, a ~/.ssh/config Host, or user@host[:port])\n", .{ tname, @errorName(err) });
        return exit_conn_error;
    };
    const home = posix.getenv("HOME") orelse "/";
    const kh_path = ssh_config.expandTilde(aa, cfg.ssh_known_hosts, home) catch return exit_conn_error;

    installSignals() catch {};
    var client = Client{
        .a = a,
        .target = target,
        .opts = .{ .known_hosts_path = kh_path, .tty = undefined, .home = home },
        .fwds = std.ArrayList(FwdState).init(a),
        .conns = std.ArrayList(*Conn).init(a),
    };
    defer client.fwds.deinit();
    defer client.conns.deinit();
    client.opts.tty = &client.tty;
    for (target.forwards) |f| client.fwds.append(.{ .spec = f }) catch {};
    var j: usize = 0;
    while (j + 1 < extra_forwards.items.len) : (j += 2) {
        var spec_buf: [300]u8 = undefined;
        const spec = std.fmt.bufPrint(&spec_buf, "{s} {s}", .{ extra_forwards.items[j], extra_forwards.items[j + 1] }) catch continue;
        const f = forward.parse(spec) catch |err| {
            std.debug.print("ssh: {s}: {s}\n", .{ spec, forward.errorText(err) });
            return 2;
        };
        client.fwds.append(.{ .spec = f.dupe(aa) catch f }) catch {};
    }
    for (client.fwds.items) |*f| f.setMsg("{s}", .{if (f.spec.enabled) "waiting for the connection" else "off"});
    return client.run();
}

pub fn libssh2Version() []const u8 {
    return std.mem.span(c.libssh2_version(0) orelse return "?");
}

fn hasFlag(args: []const []const u8, flag: []const u8) bool {
    for (args[1..]) |x| if (std.mem.eql(u8, x, flag)) return true;
    return false;
}

test "libssh2 links (vendored 1.11.1)" {
    try std.testing.expectEqualStrings("1.11.1", libssh2Version());
}

test "signalNumber" {
    try std.testing.expectEqual(@as(u8, 9), signalNumber("KILL"));
    try std.testing.expectEqual(@as(u8, 0), signalNumber("WHAT"));
}
