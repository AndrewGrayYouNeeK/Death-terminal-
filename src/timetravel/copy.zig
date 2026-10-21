//! Cheap file placement for the content-addressed store.
//!
//! Order: APFS `clonefile` (macOS), `FICLONE` reflink (Linux), hardlink
//! (only when the caller says the destination is an immutable store
//! path), then a byte copy. Hardlinks share an inode, so they are never
//! used to publish a snapshot into the live working tree: an editor
//! saving in place would rewrite the snapshot.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const Method = enum { clonefile, reflink, hardlink, copy };

extern "c" fn clonefile(src: [*:0]const u8, dst: [*:0]const u8, flags: u32) c_int;

/// Place `src` at `dst` (`dst` must not exist). `allow_hardlink` is for
/// links inside the store. Live-tree restores pass false.
pub fn place(src: []const u8, dst: []const u8, allow_hardlink: bool) !Method {
    if (tryClonefile(src, dst)) return .clonefile;
    if (tryReflink(src, dst)) return .reflink;
    if (allow_hardlink and tryHardlink(src, dst)) return .hardlink;
    try copyBytes(src, dst);
    return .copy;
}

fn tryClonefile(src: []const u8, dst: []const u8) bool {
    if (comptime builtin.os.tag != .macos) return false;
    var sb: [std.fs.max_path_bytes:0]u8 = undefined;
    var db: [std.fs.max_path_bytes:0]u8 = undefined;
    if (src.len >= sb.len or dst.len >= db.len) return false;
    @memcpy(sb[0..src.len], src);
    sb[src.len] = 0;
    @memcpy(db[0..dst.len], dst);
    db[dst.len] = 0;
    return clonefile(&sb, &db, 0) == 0;
}

fn tryReflink(src_path: []const u8, dst_path: []const u8) bool {
    if (comptime builtin.os.tag != .linux) return false;
    const src = posix.open(src_path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, 0) catch return false;
    defer posix.close(src);
    const dst = posix.open(dst_path, .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .CLOEXEC = true }, 0o644) catch return false;
    errdefer posix.close(dst);
    const FICLONE = std.os.linux.IOCTL.IOW(0x94, 9, c_int);
    const rc = std.os.linux.ioctl(dst, FICLONE, @as(usize, @intCast(src)));
    // `ioctl` here is the raw syscall (0 on success), not libc's -1.
    if (rc != 0) {
        posix.close(dst);
        std.fs.deleteFileAbsolute(dst_path) catch {};
        return false;
    }
    posix.close(dst);
    return true;
}

fn tryHardlink(src: []const u8, dst: []const u8) bool {
    if (comptime builtin.os.tag == .windows) return false;
    posix.link(src, dst, 0) catch return false;
    return true;
}

fn copyBytes(src_path: []const u8, dst_path: []const u8) !void {
    if (comptime builtin.os.tag == .windows) {
        try std.fs.copyFileAbsolute(src_path, dst_path, .{});
        return;
    }
    const src = try posix.open(src_path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, 0);
    defer posix.close(src);
    const dst = try posix.open(dst_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
    defer posix.close(dst);
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try posix.read(src, &buf);
        if (n == 0) break;
        try writeFull(dst, buf[0..n]);
    }
}

fn writeFull(fd: posix.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = try posix.write(fd, bytes[off..]);
        if (n == 0) return error.Unexpected;
        off += n;
    }
}

pub fn inodeOf(path: []const u8) !u64 {
    const f = try std.fs.openFileAbsolute(path, .{});
    defer f.close();
    const st = try f.stat();
    return @intCast(st.inode);
}

test "place copies bytes and does not hardlink into a live destination" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "src.txt", .data = "snapshot-bytes" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &buf);
    var src_buf: [std.fs.max_path_bytes]u8 = undefined;
    var dst_buf: [std.fs.max_path_bytes]u8 = undefined;
    var live_buf: [std.fs.max_path_bytes]u8 = undefined;
    const src = try std.fmt.bufPrint(&src_buf, "{s}/src.txt", .{root});
    const dst = try std.fmt.bufPrint(&dst_buf, "{s}/stored.txt", .{root});
    const live = try std.fmt.bufPrint(&live_buf, "{s}/live.txt", .{root});

    const stored = try place(src, dst, true);
    const live_method = try place(src, live, false);
    try std.testing.expect(live_method != .hardlink);
    const got = try tmp.dir.readFileAlloc(std.testing.allocator, "live.txt", 64);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("snapshot-bytes", got);
    if (stored == .hardlink) {
        try std.testing.expectEqual(try inodeOf(src), try inodeOf(dst));
    }
    try std.testing.expect(try inodeOf(src) != try inodeOf(live) or live_method == .reflink or live_method == .clonefile);
}
