//! The SSH client's control socket: a unix socket the window (and
//! `deathterminal --ssh-ctl <pid> <command>`) uses to list and toggle
//! port forwards or force a reconnect. One command per connection:
//!
//!   status            "connected <label> <user@host:port>" (or connecting / disconnected)
//!   list              one line per forward: "<n> <on|off> <spec> <state>"
//!   toggle|on|off <n> "ok on" / "ok off" / "error <why>"
//!   add <spec>        add a forward for this session ("ok <n>")
//!   reconnect         "ok"
//!
//! The socket lives in a 0700 directory ($XDG_RUNTIME_DIR/deathterminal,
//! else /tmp/deathterminal-<uid>) and carries no secrets.

const std = @import("std");
const posix = std.posix;

pub fn dirPath(buf: []u8) ![]const u8 {
    if (posix.getenv("XDG_RUNTIME_DIR")) |rt| if (rt.len > 0) {
        return std.fmt.bufPrint(buf, "{s}/deathterminal", .{rt});
    };
    return std.fmt.bufPrint(buf, "/tmp/deathterminal-{d}", .{std.os.linux.getuid()});
}

pub fn socketPath(buf: []u8, pid: posix.pid_t) ![]const u8 {
    var db: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try dirPath(&db);
    return std.fmt.bufPrint(buf, "{s}/ssh-{d}.sock", .{ dir, pid });
}

/// Creates the private directory (refusing one owned by someone else).
fn ensureDir(dir: []const u8) !void {
    posix.mkdir(dir, 0o700) catch |err| if (err != error.PathAlreadyExists) return err;
    var sb: std.os.linux.Stat = undefined;
    var zb: [std.fs.max_path_bytes]u8 = undefined;
    const z = try std.fmt.bufPrintZ(&zb, "{s}", .{dir});
    if (posix.errno(std.os.linux.stat(z.ptr, &sb)) != .SUCCESS) return error.BadControlDir;
    if (sb.uid != std.os.linux.getuid() or sb.mode & 0o077 != 0) return error.BadControlDir;
}

pub const Server = struct {
    fd: posix.fd_t,
    path_buf: [std.fs.max_path_bytes]u8 = undefined,
    path_len: usize = 0,

    pub fn listen() !Server {
        var db: [std.fs.max_path_bytes]u8 = undefined;
        try ensureDir(try dirPath(&db));
        var s = Server{ .fd = -1 };
        const p = try socketPath(&s.path_buf, std.os.linux.getpid());
        s.path_len = p.len;
        std.fs.cwd().deleteFile(p) catch {};
        const addr = try std.net.Address.initUnix(p);
        const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK, 0);
        errdefer posix.close(fd);
        try posix.bind(fd, &addr.any, addr.getOsSockLen());
        try posix.listen(fd, 4);
        s.fd = fd;
        return s;
    }

    pub fn path(self: *const Server) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    pub fn deinit(self: *Server) void {
        posix.close(self.fd);
        std.fs.cwd().deleteFile(self.path()) catch {};
    }

    /// Accepts one pending client and reads its command line (short wait).
    pub fn accept(self: *Server, buf: []u8) ?struct { fd: posix.fd_t, cmd: []const u8 } {
        const cfd = posix.accept(self.fd, null, null, posix.SOCK.CLOEXEC) catch return null;
        var n: usize = 0;
        while (n < buf.len) {
            var pfd = [_]posix.pollfd{.{ .fd = cfd, .events = posix.POLL.IN, .revents = 0 }};
            const r = posix.poll(&pfd, 200) catch break;
            if (r == 0) break;
            const got = posix.read(cfd, buf[n..]) catch break;
            if (got == 0) break;
            n += got;
            if (std.mem.indexOfScalar(u8, buf[0..n], '\n') != null) break;
        }
        const line = std.mem.trim(u8, std.mem.sliceTo(buf[0..n], '\n'), " \r\t");
        return .{ .fd = cfd, .cmd = line };
    }
};

pub fn reply(fd: posix.fd_t, text: []const u8) void {
    var rest = text;
    while (rest.len > 0) {
        const n = posix.write(fd, rest) catch break;
        rest = rest[n..];
    }
    posix.close(fd);
}

/// Sends `cmd` to the session client with pid `pid`; returns the reply.
pub fn request(pid: posix.pid_t, cmd: []const u8, out: []u8) ![]const u8 {
    var pb: [std.fs.max_path_bytes]u8 = undefined;
    const p = try socketPath(&pb, pid);
    const addr = try std.net.Address.initUnix(p);
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    defer posix.close(fd);
    try posix.connect(fd, &addr.any, addr.getOsSockLen());
    _ = try posix.write(fd, cmd);
    _ = try posix.write(fd, "\n");
    var n: usize = 0;
    while (n < out.len) {
        var pfd = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
        if (try posix.poll(&pfd, 2000) == 0) return error.Timeout;
        const got = try posix.read(fd, out[n..]);
        if (got == 0) break;
        n += got;
    }
    return out[0..n];
}

test "control socket round trip" {
    var srv = try Server.listen();
    defer srv.deinit();
    const th = try std.Thread.spawn(.{}, struct {
        fn f(s: *Server) void {
            var buf: [256]u8 = undefined;
            var tries: usize = 0;
            while (tries < 200) : (tries += 1) {
                if (s.accept(&buf)) |cl| {
                    var out: [64]u8 = undefined;
                    reply(cl.fd, std.fmt.bufPrint(&out, "got {s}\n", .{cl.cmd}) catch "?");
                    return;
                }
                std.time.sleep(10 * std.time.ns_per_ms);
            }
        }
    }.f, .{&srv});
    var out: [64]u8 = undefined;
    const r = try request(std.os.linux.getpid(), "list", &out);
    th.join();
    try std.testing.expectEqualStrings("got list\n", r);
}
