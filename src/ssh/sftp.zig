//! SFTP list, get, and put on an already-authenticated libssh2 session.
//! The caller owns the session. Paths are remote paths as the server sees them.

const std = @import("std");
const c = @import("c.zig").c;

pub const Error = error{ SftpFailed, PathTooLong };

fn zpath(buf: []u8, path: []const u8) Error![:0]const u8 {
    if (path.len + 1 > buf.len) return error.PathTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

pub fn list(session: *c.LIBSSH2_SESSION, path: []const u8, out: *std.ArrayList(u8)) Error!void {
    const sftp = c.libssh2_sftp_init(session) orelse return error.SftpFailed;
    defer _ = c.libssh2_sftp_shutdown(sftp);
    var pb: [4096]u8 = undefined;
    const zp = try zpath(&pb, path);
    const dir = c.libssh2_sftp_open_ex(sftp, zp.ptr, @intCast(zp.len), 0, 0, c.LIBSSH2_SFTP_OPENDIR) orelse return error.SftpFailed;
    defer _ = c.libssh2_sftp_close_handle(dir);
    var name: [512]u8 = undefined;
    while (true) {
        var attrs: c.LIBSSH2_SFTP_ATTRIBUTES = undefined;
        const n = c.libssh2_sftp_readdir_ex(dir, &name, name.len, @as([*c]u8, null), 0, &attrs);
        if (n == 0) break;
        if (n < 0) return error.SftpFailed;
        out.writer().print("{s}\n", .{name[0..@intCast(n)]}) catch return error.SftpFailed;
    }
}

pub fn get(session: *c.LIBSSH2_SESSION, remote: []const u8, local: []const u8) Error!void {
    const sftp = c.libssh2_sftp_init(session) orelse return error.SftpFailed;
    defer _ = c.libssh2_sftp_shutdown(sftp);
    var pb: [4096]u8 = undefined;
    const zp = try zpath(&pb, remote);
    const h = c.libssh2_sftp_open_ex(sftp, zp.ptr, @intCast(zp.len), c.LIBSSH2_FXF_READ, 0, c.LIBSSH2_SFTP_OPENFILE) orelse return error.SftpFailed;
    defer _ = c.libssh2_sftp_close_handle(h);
    var f = std.fs.cwd().createFile(local, .{ .truncate = true }) catch return error.SftpFailed;
    defer f.close();
    var buf: [32 * 1024]u8 = undefined;
    while (true) {
        const n = c.libssh2_sftp_read(h, &buf, buf.len);
        if (n == 0) break;
        if (n < 0) return error.SftpFailed;
        f.writeAll(buf[0..@intCast(n)]) catch return error.SftpFailed;
    }
}

pub fn put(session: *c.LIBSSH2_SESSION, local: []const u8, remote: []const u8) Error!void {
    const sftp = c.libssh2_sftp_init(session) orelse return error.SftpFailed;
    defer _ = c.libssh2_sftp_shutdown(sftp);
    var pb: [4096]u8 = undefined;
    const zp = try zpath(&pb, remote);
    const flags = c.LIBSSH2_FXF_WRITE | c.LIBSSH2_FXF_CREAT | c.LIBSSH2_FXF_TRUNC;
    const h = c.libssh2_sftp_open_ex(sftp, zp.ptr, @intCast(zp.len), flags, 0o644, c.LIBSSH2_SFTP_OPENFILE) orelse return error.SftpFailed;
    defer _ = c.libssh2_sftp_close_handle(h);
    var f = std.fs.cwd().openFile(local, .{}) catch return error.SftpFailed;
    defer f.close();
    var buf: [32 * 1024]u8 = undefined;
    while (true) {
        const n = f.read(&buf) catch return error.SftpFailed;
        if (n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const w = c.libssh2_sftp_write(h, buf[off..].ptr, n - off);
            if (w < 0) return error.SftpFailed;
            off += @intCast(w);
        }
    }
}

test "sftp paths that do not fit are refused" {
    var buf: [4]u8 = undefined;
    try std.testing.expectError(error.PathTooLong, zpath(&buf, "abcde"));
    try std.testing.expectEqualStrings("ab", try zpath(&buf, "ab"));
}
