//! Opening an authenticated SSH session: TCP connect (with a timeout),
//! jump hosts, handshake, host-key verification and authentication.
//! Everything here runs in blocking mode before the client's event loop
//! starts; prompts are drawn in the terminal through `Tty`.
//!
//! Secrets: passphrases and passwords are read into stack buffers that
//! are wiped right after libssh2 has used them, and libssh2's own heap
//! blocks are wiped before they are freed (see `zfree`). Nothing typed is
//! logged or kept for reconnects.

const std = @import("std");
const posix = std.posix;
const c = @import("c.zig").c;
const dial = @import("../net/dial.zig");
const target_mod = @import("target.zig");
const known_hosts = @import("known_hosts.zig");
const keyfile = @import("keyfile.zig");
const bridge = @import("bridge.zig");
const tty_mod = @import("tty.zig");
const Tty = tty_mod.Tty;

pub const Error = error{ Connect, Handshake, HostKeyRejected, HostKeyChanged, AuthFailed, Cancelled, Forwarding, OutOfMemory };

/// Errors that a reconnect cannot fix.
pub fn isFatal(err: Error) bool {
    return switch (err) {
        error.HostKeyRejected, error.HostKeyChanged, error.AuthFailed, error.Cancelled => true,
        else => false,
    };
}

pub const Options = struct {
    known_hosts_path: []const u8,
    /// Connect / handshake / each blocking step.
    timeout_ms: u32 = 15_000,
    tty: *Tty,
    use_agent: bool = true,
    home: []const u8 = "",
};

pub const Endpoint = struct {
    host: []const u8,
    port: u16,
    user: []const u8,
    identity_files: []const []const u8,
};

// ---------------------------------------------------- allocator: wipe on free

extern "c" fn malloc_usable_size(ptr: ?*anyopaque) usize;

fn zalloc(count: usize, abstract: [*c]?*anyopaque) callconv(.C) ?*anyopaque {
    _ = abstract;
    return std.c.malloc(count);
}

fn wipeFree(p: *anyopaque) void {
    const n = malloc_usable_size(p);
    std.crypto.utils.secureZero(u8, @as([*]u8, @ptrCast(p))[0..n]);
    std.c.free(p);
}

fn zfree(ptr: ?*anyopaque, abstract: [*c]?*anyopaque) callconv(.C) void {
    _ = abstract;
    if (ptr) |p| wipeFree(p);
}

fn zrealloc(ptr: ?*anyopaque, count: usize, abstract: [*c]?*anyopaque) callconv(.C) ?*anyopaque {
    _ = abstract;
    const old = ptr orelse return std.c.malloc(count);
    const fresh = std.c.malloc(count) orelse return null;
    const n = @min(malloc_usable_size(old), count);
    @memcpy(@as([*]u8, @ptrCast(fresh))[0..n], @as([*]u8, @ptrCast(old))[0..n]);
    wipeFree(old);
    return fresh;
}

/// Per-session state the keyboard-interactive callback reaches through
/// libssh2's `abstract` pointer.
const AuthCtx = struct {
    tty: *Tty,
    cancelled: bool = false,
};

pub fn lastError(s: *c.LIBSSH2_SESSION) []const u8 {
    var msg: [*c]u8 = null;
    var len: c_int = 0;
    _ = c.libssh2_session_last_error(s, &msg, &len, 0);
    if (msg == null or len <= 0) return "unknown error";
    return msg[0..@intCast(len)];
}

/// A ProxyJump hop: owns the hop's session and moves the tunnel's bytes
/// between its direct-tcpip channel and one end of a socketpair (the
/// other end is the next session's socket).
const Pump = struct {
    session: *c.LIBSSH2_SESSION,
    ctx: *AuthCtx,
    tcp_fd: posix.fd_t,
    br: bridge.Bridge,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    keepalive_s: u16,

    fn run(self: *Pump) void {
        c.libssh2_session_set_blocking(self.session, 0);
        if (self.keepalive_s > 0) c.libssh2_keepalive_config(self.session, 1, self.keepalive_s);
        bridge.setNonBlocking(self.br.fd);
        while (!self.stop.load(.acquire) and !self.br.done()) {
            while (self.br.step()) {}
            if (self.br.done()) break;
            _ = sendKeepalive(self.session, self.tcp_fd);
            // Hop sessions never send global requests: just drop the replies.
            _ = dt_libssh2_drop_global_replies(self.session);
            const dirs = c.libssh2_session_block_directions(self.session);
            var fds = [_]posix.pollfd{
                .{ .fd = self.tcp_fd, .events = posix.POLL.IN | @as(i16, if (dirs & c.LIBSSH2_SESSION_BLOCK_OUTBOUND != 0) posix.POLL.OUT else 0), .revents = 0 },
                .{ .fd = self.br.fd, .events = @as(i16, if (self.br.wantsRead()) posix.POLL.IN else 0) | @as(i16, if (self.br.wantsWrite()) posix.POLL.OUT else 0), .revents = 0 },
            };
            _ = posix.poll(&fds, 500) catch break;
            if (fds[0].revents & (posix.POLL.HUP | posix.POLL.ERR) != 0 and fds[0].revents & posix.POLL.IN == 0) break;
        }
        posix.shutdown(self.br.fd, .both) catch {};
    }

    fn destroy(self: *Pump, a: std.mem.Allocator) void {
        self.stop.store(true, .release);
        posix.shutdown(self.br.fd, .both) catch {};
        if (self.thread) |th| th.join();
        _ = c.libssh2_channel_free(self.br.chan);
        closeSession(self.session, "jump closed");
        posix.close(self.tcp_fd);
        posix.close(self.br.fd);
        a.destroy(self.ctx);
        a.destroy(self);
    }
};

/// Sends a keepalive only when the socket can take it at once: libssh2
/// drops a keepalive that hits EAGAIN, and a half-sent one would wedge
/// the transport.
/// Returns true when a keepalive expecting a reply went out.
pub fn sendKeepalive(s: *c.LIBSSH2_SESSION, fd: posix.fd_t) bool {
    if (c.libssh2_session_block_directions(s) & c.LIBSSH2_SESSION_BLOCK_OUTBOUND != 0) return false;
    var pfd = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 }};
    const n = posix.poll(&pfd, 0) catch return false;
    if (n == 0 or pfd[0].revents & posix.POLL.OUT == 0) return false;
    var next: c_int = 0;
    return dt_libssh2_keepalive_send(s, &next) == 1;
}

// src/ssh/libssh2_extra.c: libssh2 queues the server's replies to
// keepalives until a global request takes one (see that file).
extern fn dt_libssh2_keepalive_send(s: *c.LIBSSH2_SESSION, next: *c_int) c_int;
pub extern fn dt_libssh2_drop_global_replies(s: *c.LIBSSH2_SESSION) c_int;

fn closeSession(s: *c.LIBSSH2_SESSION, reason: [*:0]const u8) void {
    c.libssh2_session_set_blocking(s, 1);
    c.libssh2_session_set_timeout(s, 1000);
    _ = c.libssh2_session_disconnect_ex(s, c.SSH_DISCONNECT_BY_APPLICATION, reason, "");
    _ = c.libssh2_session_free(s);
}

pub const Connection = struct {
    allocator: std.mem.Allocator,
    session: *c.LIBSSH2_SESSION,
    fd: posix.fd_t,
    ctx: *AuthCtx,
    pumps: [8]*Pump = undefined,
    npumps: usize = 0,
    /// "user@host:port" of the final hop, and how many jumps it took.
    via: usize = 0,

    pub fn close(self: *Connection, reason: [*:0]const u8) void {
        closeSession(self.session, reason);
        posix.close(self.fd);
        var i = self.npumps;
        while (i > 0) {
            i -= 1;
            self.pumps[i].destroy(self.allocator);
        }
        self.allocator.destroy(self.ctx);
        self.npumps = 0;
    }
};

var lib_once = std.once(libInit);
fn libInit() void {
    _ = c.libssh2_init(0);
}

/// Connects to `t` (through its jump hosts), verifies the host key and
/// authenticates. Problems are explained on the terminal.
pub fn open(a: std.mem.Allocator, t: *const target_mod.Target, opts: Options) Error!Connection {
    lib_once.call();
    var eps: [9]Endpoint = undefined;
    var n: usize = 0;
    for (t.jumps) |h| {
        eps[n] = .{ .host = h.host, .port = h.port, .user = h.user, .identity_files = h.identity_files };
        n += 1;
    }
    eps[n] = .{ .host = t.host, .port = t.port, .user = t.user, .identity_files = t.identity_files };
    n += 1;

    var conn = Connection{ .allocator = a, .session = undefined, .fd = -1, .ctx = undefined, .via = n - 1 };
    errdefer {
        var i = conn.npumps;
        while (i > 0) {
            i -= 1;
            conn.pumps[i].destroy(a);
        }
    }
    var fd = dial.connect(eps[0].host, eps[0].port, opts.timeout_ms, null) catch |err| {
        opts.tty.print("ssh: connect to {s} port {d}: {s}\n", .{ eps[0].host, eps[0].port, dialText(err) });
        return error.Connect;
    };
    for (eps[0..n], 0..) |ep, i| {
        const ctx = try a.create(AuthCtx);
        ctx.* = .{ .tty = opts.tty };
        const s = establish(fd, ep, ctx, opts) catch |err| {
            posix.close(fd);
            a.destroy(ctx);
            return err;
        };
        if (i == n - 1) {
            conn.session = s;
            conn.fd = fd;
            conn.ctx = ctx;
            return conn;
        }
        // Tunnel to the next hop.
        const next = eps[i + 1];
        var hb: [256]u8 = undefined;
        const host_z = std.fmt.bufPrintZ(&hb, "{s}", .{next.host}) catch {
            closeSession(s, "bad host");
            posix.close(fd);
            a.destroy(ctx);
            return error.Connect;
        };
        const chan = c.libssh2_channel_direct_tcpip_ex(s, host_z.ptr, next.port, "127.0.0.1", 22) orelse {
            opts.tty.print("ssh: jump host {s} could not open a connection to {s}:{d}: {s}\n", .{ ep.host, next.host, next.port, lastError(s) });
            closeSession(s, "jump failed");
            posix.close(fd);
            a.destroy(ctx);
            return error.Connect;
        };
        const pair = socketPair() catch {
            _ = c.libssh2_channel_free(chan);
            closeSession(s, "socketpair");
            posix.close(fd);
            a.destroy(ctx);
            return error.Connect;
        };
        const pump = try a.create(Pump);
        pump.* = .{ .session = s, .ctx = ctx, .tcp_fd = fd, .br = .{ .chan = chan, .fd = pair[0] }, .keepalive_s = t.keepalive_s };
        pump.thread = std.Thread.spawn(.{}, Pump.run, .{pump}) catch {
            pump.thread = null;
            pump.destroy(a);
            posix.close(pair[1]);
            return error.Connect;
        };
        conn.pumps[conn.npumps] = pump;
        conn.npumps += 1;
        fd = pair[1];
    }
    unreachable;
}

fn socketPair() ![2]posix.fd_t {
    var fds: [2]posix.fd_t = undefined;
    const rc = std.os.linux.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0, &fds);
    if (posix.errno(rc) != .SUCCESS) return error.SocketPair;
    return fds;
}

pub fn dialText(err: dial.Error) []const u8 {
    return switch (err) {
        error.Timeout => "Connection timed out",
        error.Cancelled => "Cancelled",
        error.Refused => "Connection refused",
        error.Unreachable => "Network is unreachable",
        error.UnknownHost => "Could not resolve hostname",
        error.OutOfMemory => "Out of memory",
        error.Unexpected => "Connection failed",
    };
}

fn establish(fd: posix.fd_t, ep: Endpoint, ctx: *AuthCtx, opts: Options) Error!*c.LIBSSH2_SESSION {
    const tty = opts.tty;
    const s = c.libssh2_session_init_ex(zalloc, zfree, zrealloc, ctx) orelse return error.OutOfMemory;
    var ok = false;
    defer if (!ok) closeSession(s, "connection aborted");
    c.libssh2_session_set_blocking(s, 1);
    c.libssh2_session_set_timeout(s, @intCast(opts.timeout_ms));

    var kh = known_hosts.KnownHosts.open(s, opts.known_hosts_path) catch return error.OutOfMemory;
    defer kh.deinit();
    var pref: [512]u8 = undefined;
    const methods = kh.methodPref(&pref, ep.host, ep.port);
    if (methods.len > 0 and methods.len < pref.len) {
        pref[methods.len] = 0;
        _ = c.libssh2_session_method_pref(s, c.LIBSSH2_METHOD_HOSTKEY, &pref);
    }

    if (c.libssh2_session_handshake(s, fd) != 0) {
        tty.print("ssh: {s}:{d}: handshake failed: {s}\n", .{ ep.host, ep.port, lastError(s) });
        return error.Handshake;
    }
    try verifyHostKey(s, &kh, ep, opts);
    try authenticate(s, ep, ctx, opts);
    ok = true;
    return s;
}

fn verifyHostKey(s: *c.LIBSSH2_SESSION, kh: *known_hosts.KnownHosts, ep: Endpoint, opts: Options) Error!void {
    const tty = opts.tty;
    var len: usize = 0;
    var ktype: c_int = 0;
    const kp = c.libssh2_session_hostkey(s, &len, &ktype) orelse {
        tty.print("ssh: {s}: no host key\n", .{ep.host});
        return error.Handshake;
    };
    const key = kp[0..len];
    var nb: [300]u8 = undefined;
    const name = known_hosts.hostName(&nb, ep.host, ep.port);
    var fb: [64]u8 = undefined;
    const fp = known_hosts.fingerprint(&fb, key);
    var pb: [std.fs.max_path_bytes]u8 = undefined;
    const kh_disp = homeShort(&pb, kh.path, opts.home);
    const kt = known_hosts.keyType(ktype) orelse {
        tty.print("ssh: {s} offered an unsupported host key type\n", .{name});
        return error.HostKeyRejected;
    };
    if (kh.isRevoked(key)) {
        tty.print("{s} REVOKED HOST KEY {s}\nThe {s} host key for {s} ({s}) is marked @revoked in {s}.\nConnection refused.\n", .{ tty_mod.red, tty_mod.reset, kt.name, name, fp, kh_disp });
        return error.HostKeyChanged;
    }
    switch (kh.check(ep.host, ep.port, key, kt)) {
        .match => return,
        .mismatch => {
            tty.print(
                \\{s}@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@{s}
                \\{s}@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!    @{s}
                \\{s}@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@{s}
                \\The {s} host key for {s} is different from the one in {s}.
                \\Someone could be eavesdropping on you right now (man-in-the-middle),
                \\or the host's key was replaced. The key offered now is:
                \\  {s}
                \\Connection refused. If you know the key changed legitimately, remove
                \\the old one and connect again:
                \\  ssh-keygen -R '{s}' -f {s}
                \\
            , .{ tty_mod.red, tty_mod.reset, tty_mod.red, tty_mod.reset, tty_mod.red, tty_mod.reset, kt.name, name, kh_disp, fp, name, kh_disp });
            return error.HostKeyChanged;
        },
        .not_found => {
            tty.print("{s}The authenticity of host '{s}' can't be established.{s}\n{s} key fingerprint is {s}.\nThis key is not known by any other names.\n", .{ tty_mod.yellow, name, tty_mod.reset, kt.name, fp });
            const answer = tty.choose("Accept? [y]es and save / [o]nce / [n]o: ", "yon", 0);
            switch (answer) {
                'y' => {
                    kh.add(ep.host, ep.port, key, kt) catch |err| {
                        tty.print("ssh: could not save the key to {s}: {s} (accepted for this session)\n", .{ kh_disp, @errorName(err) });
                        return;
                    };
                    tty.print("Permanently added '{s}' ({s}) to {s}.\n", .{ name, kt.name, kh_disp });
                },
                'o' => tty.print("Accepted '{s}' for this session only.\n", .{name}),
                else => {
                    tty.print("Host key verification failed.\n", .{});
                    return error.HostKeyRejected;
                },
            }
        },
        .failure => {
            tty.print("ssh: could not check the host key of {s}\n", .{name});
            return error.HostKeyRejected;
        },
    }
}

fn homeShort(buf: []u8, path: []const u8, home: []const u8) []const u8 {
    if (home.len > 1 and std.mem.startsWith(u8, path, home) and path.len > home.len and path[home.len] == '/')
        return std.fmt.bufPrint(buf, "~{s}", .{path[home.len..]}) catch path;
    return path;
}

fn hasMethod(list: []const u8, m: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |x| if (std.mem.eql(u8, x, m)) return true;
    return false;
}

fn authenticate(s: *c.LIBSSH2_SESSION, ep: Endpoint, ctx: *AuthCtx, opts: Options) Error!void {
    const tty = opts.tty;
    var ub: [256]u8 = undefined;
    const user = std.fmt.bufPrintZ(&ub, "{s}", .{ep.user}) catch return error.AuthFailed;
    const ulen: c_uint = @intCast(user.len);
    const list_p = c.libssh2_userauth_list(s, user.ptr, ulen);
    if (list_p == null) {
        if (c.libssh2_userauth_authenticated(s) == 1) return; // "none" was enough
        tty.print("ssh: {s}: {s}\n", .{ ep.host, lastError(s) });
        return error.AuthFailed;
    }
    var lb: [256]u8 = undefined;
    const methods = std.fmt.bufPrint(&lb, "{s}", .{std.mem.span(list_p)}) catch "";

    if (hasMethod(methods, "publickey")) {
        if (opts.use_agent and tryAgent(s, user)) return;
        for (ep.identity_files) |path| {
            if (try tryKeyFile(s, user, path, opts)) return;
        }
    }
    if (hasMethod(methods, "keyboard-interactive")) {
        var tries: usize = 0;
        while (tries < 3) : (tries += 1) {
            const rc = c.libssh2_userauth_keyboard_interactive_ex(s, user.ptr, ulen, kbdCallback);
            if (ctx.cancelled) return error.Cancelled;
            if (rc == 0) return;
            if (rc != c.LIBSSH2_ERROR_AUTHENTICATION_FAILED) break;
            tty.print("Permission denied, please try again.\n", .{});
        }
    }
    if (hasMethod(methods, "password")) {
        var tries: usize = 0;
        while (tries < 3) : (tries += 1) {
            var pw: [1024]u8 = undefined;
            defer std.crypto.utils.secureZero(u8, &pw);
            var prompt: [320]u8 = undefined;
            const p = std.fmt.bufPrint(&prompt, "{s}@{s}'s password: ", .{ ep.user, ep.host }) catch "Password: ";
            const got = tty.readLine(p, false, pw[0 .. pw.len - 1]) catch return error.Cancelled;
            const rc = c.libssh2_userauth_password_ex(s, user.ptr, ulen, got.ptr, @intCast(got.len), null);
            if (rc == 0) return;
            if (rc != c.LIBSSH2_ERROR_AUTHENTICATION_FAILED) break;
            tty.print("Permission denied, please try again.\n", .{});
        }
    }
    tty.print("{s}@{s}: Permission denied ({s}).\n", .{ ep.user, ep.host, methods });
    return error.AuthFailed;
}

fn tryAgent(s: *c.LIBSSH2_SESSION, user: [:0]const u8) bool {
    if (std.posix.getenv("SSH_AUTH_SOCK") == null) return false;
    const agent = c.libssh2_agent_init(s) orelse return false;
    defer c.libssh2_agent_free(agent);
    if (c.libssh2_agent_connect(agent) != 0) return false;
    defer _ = c.libssh2_agent_disconnect(agent);
    if (c.libssh2_agent_list_identities(agent) != 0) return false;
    var prev: ?*c.libssh2_agent_publickey = null;
    while (true) {
        var id: ?*c.libssh2_agent_publickey = null;
        const rc = c.libssh2_agent_get_identity(agent, &id, prev);
        if (rc != 0) return false;
        if (c.libssh2_agent_userauth(agent, user.ptr, id) == 0) return true;
        prev = id;
    }
}

/// true = authenticated. A key the server rejects moves on to the next.
fn tryKeyFile(s: *c.LIBSSH2_SESSION, user: [:0]const u8, path: []const u8, opts: Options) Error!bool {
    const info = keyfile.inspect(path);
    if (info == .missing) return false;
    var pb: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&pb, "{s}", .{path}) catch return false;
    if (info == .plain) {
        return c.libssh2_userauth_publickey_fromfile_ex(s, user.ptr, @intCast(user.len), null, path_z.ptr, "") == 0;
    }
    var db: [std.fs.max_path_bytes]u8 = undefined;
    const disp = homeShort(&db, path, opts.home);
    var tries: usize = 0;
    while (tries < 3) : (tries += 1) {
        var pp: [1024]u8 = undefined;
        defer std.crypto.utils.secureZero(u8, &pp);
        var prompt: [std.fs.max_path_bytes + 40]u8 = undefined;
        const p = std.fmt.bufPrint(&prompt, "Enter passphrase for key '{s}': ", .{disp}) catch "Enter passphrase: ";
        const got = opts.tty.readLine(p, false, pp[0 .. pp.len - 1]) catch return error.Cancelled;
        if (got.len == 0) return false; // skip this key, like OpenSSH
        pp[got.len] = 0;
        const rc = c.libssh2_userauth_publickey_fromfile_ex(s, user.ptr, @intCast(user.len), null, path_z.ptr, @ptrCast(&pp));
        if (rc == 0) return true;
        if (rc != c.LIBSSH2_ERROR_FILE) return false; // decrypted, but the server said no
        opts.tty.print("Bad passphrase, try again for '{s}'.\n", .{disp});
    }
    return false;
}

fn kbdCallback(
    name: [*c]const u8,
    name_len: c_int,
    instruction: [*c]const u8,
    instruction_len: c_int,
    num_prompts: c_int,
    prompts: [*c]const c.LIBSSH2_USERAUTH_KBDINT_PROMPT,
    responses: [*c]c.LIBSSH2_USERAUTH_KBDINT_RESPONSE,
    abstract: [*c]?*anyopaque,
) callconv(.C) void {
    const ctx: *AuthCtx = @ptrCast(@alignCast(abstract.*.?));
    const tty = ctx.tty;
    var sb: [1024]u8 = undefined;
    if (name_len > 0) tty.print("{s}{s}{s}\n", .{ tty_mod.bold, tty_mod.sanitize(&sb, name[0..@intCast(name_len)]), tty_mod.reset });
    if (instruction_len > 0) tty.print("{s}\n", .{tty_mod.sanitize(&sb, instruction[0..@intCast(instruction_len)])});
    var i: usize = 0;
    while (i < @as(usize, @intCast(@max(num_prompts, 0)))) : (i += 1) {
        responses[i].text = null;
        responses[i].length = 0;
        if (ctx.cancelled) continue;
        const pr = prompts[i];
        const text = tty_mod.sanitize(&sb, pr.text[0..pr.length]);
        var ans: [1024]u8 = undefined;
        defer std.crypto.utils.secureZero(u8, &ans);
        const got = tty.readLine(if (text.len > 0) text else "Response: ", pr.echo != 0, &ans) catch {
            ctx.cancelled = true;
            continue;
        };
        // libssh2 frees this with zfree, which wipes it.
        const mem: ?[*]u8 = @ptrCast(std.c.malloc(@max(got.len, 1)));
        if (mem) |m| {
            @memcpy(m[0..got.len], got);
            responses[i].text = @ptrCast(m);
            responses[i].length = @intCast(got.len);
        }
    }
}

test "hasMethod" {
    try std.testing.expect(hasMethod("publickey,password", "password"));
    try std.testing.expect(!hasMethod("publickey,password", "pass"));
}
