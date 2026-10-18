//! Watches the config file for changes so a running terminal reloads it on
//! save. The directory is watched, not the file, because editors save by
//! writing a temp file and renaming it over the original.
//!
//! Linux: inotify. macOS: a kqueue on the directory (EVFILT_VNODE). Windows:
//! a thread waiting on FindFirstChangeNotification that signals a socket
//! the loop polls. On macOS and Windows the notification doesn't say which
//! file changed, so `drain` compares the file's mtime.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;
const io = @import("../platform/io.zig");

pub const Watcher = struct {
    fd: io.Fd,
    name_buf: [256]u8 = undefined,
    name_len: usize = 0,
    path_buf: [std.fs.max_path_bytes]u8 = undefined,
    path_len: usize = 0,
    mtime: i128 = 0,
    /// macOS: the watched directory (kept open for the kqueue).
    dir_fd: c_int = -1,
    win: ?*WinWatch = null,

    /// Watch for changes to `path` (which need not exist yet; its
    /// directory must).
    pub fn init(path: []const u8) ?Watcher {
        const dir = std.fs.path.dirname(path) orelse ".";
        const base = std.fs.path.basename(path);
        if (base.len > 255 or path.len > std.fs.max_path_bytes) return null;
        var w = Watcher{ .fd = io.none };
        @memcpy(w.name_buf[0..base.len], base);
        w.name_len = base.len;
        @memcpy(w.path_buf[0..path.len], path);
        w.path_len = path.len;
        w.mtime = w.currentMtime();
        switch (builtin.os.tag) {
            .linux => {
                const fd = posix.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC) catch return null;
                const mask = linux.IN.CLOSE_WRITE | linux.IN.MOVED_TO | linux.IN.CREATE | linux.IN.DELETE | linux.IN.MOVED_FROM;
                _ = posix.inotify_add_watch(fd, dir, mask) catch {
                    posix.close(fd);
                    return null;
                };
                w.fd = fd;
            },
            .macos => {
                const O_EVTONLY = 0x8000;
                var zb: [std.fs.max_path_bytes]u8 = undefined;
                const dz = std.fmt.bufPrintZ(&zb, "{s}", .{dir}) catch return null;
                const dfd = std.c.open(dz.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(c_uint, O_EVTONLY));
                if (dfd < 0) return null;
                const kq = std.c.kqueue();
                if (kq < 0) {
                    posix.close(dfd);
                    return null;
                }
                const NOTE_WRITE = 0x2;
                const NOTE_DELETE = 0x1;
                const NOTE_RENAME = 0x20;
                const NOTE_EXTEND = 0x4;
                var change = [1]std.c.Kevent{.{
                    .ident = @intCast(dfd),
                    .filter = std.c.EVFILT_VNODE,
                    .flags = std.c.EV_ADD | std.c.EV_CLEAR,
                    .fflags = NOTE_WRITE | NOTE_DELETE | NOTE_RENAME | NOTE_EXTEND,
                    .data = 0,
                    .udata = 0,
                }};
                var none_ev: [0]std.c.Kevent = .{};
                if (std.c.kevent(kq, &change, 1, &none_ev, 0, null) < 0) {
                    posix.close(kq);
                    posix.close(dfd);
                    return null;
                }
                w.fd = kq;
                w.dir_fd = dfd;
            },
            .windows => {
                w.win = WinWatch.start(dir) catch return null;
                w.fd = w.win.?.wake.fd();
            },
            else => return null,
        }
        return w;
    }

    pub fn deinit(self: *Watcher) void {
        switch (builtin.os.tag) {
            .windows => if (self.win) |ww| ww.stop(),
            else => {
                io.close(self.fd);
                if (builtin.os.tag != .windows and self.dir_fd >= 0) posix.close(self.dir_fd);
            },
        }
    }

    fn currentMtime(self: *const Watcher) i128 {
        const st = std.fs.cwd().statFile(self.path_buf[0..self.path_len]) catch return 0;
        return st.mtime;
    }

    /// Read pending events; true if any concerned the config file.
    pub fn drain(self: *Watcher) bool {
        if (builtin.os.tag != .linux) {
            switch (builtin.os.tag) {
                .windows => self.win.?.wake.drain(),
                .macos => {
                    var evs: [8]std.c.Kevent = undefined;
                    const zero = std.c.timespec{ .tv_sec = 0, .tv_nsec = 0 };
                    var none_ev: [0]std.c.Kevent = .{};
                    while (std.c.kevent(self.fd, &none_ev, 0, &evs, evs.len, &zero) > 0) {}
                },
                else => {},
            }
            const m = self.currentMtime();
            if (m == self.mtime) return false;
            self.mtime = m;
            return true;
        }
        var hit = false;
        var buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
        while (true) {
            const n = posix.read(self.fd, &buf) catch break;
            if (n == 0) break;
            var off: usize = 0;
            while (off + @sizeOf(linux.inotify_event) <= n) {
                const ev: *const linux.inotify_event = @ptrCast(@alignCast(&buf[off]));
                const name_start = off + @sizeOf(linux.inotify_event);
                const raw = buf[name_start..][0..ev.len];
                const name = std.mem.sliceTo(raw, 0);
                if (std.mem.eql(u8, name, self.name_buf[0..self.name_len])) hit = true;
                off = name_start + ev.len;
            }
        }
        return hit;
    }
};

/// Windows directory watch thread.
const WinWatch = if (builtin.os.tag == .windows) struct {
    const w = std.os.windows;
    extern "kernel32" fn FindFirstChangeNotificationW(path: [*:0]const u16, subtree: w.BOOL, filter: w.DWORD) callconv(w.WINAPI) w.HANDLE;
    extern "kernel32" fn FindNextChangeNotification(h: w.HANDLE) callconv(w.WINAPI) w.BOOL;
    extern "kernel32" fn FindCloseChangeNotification(h: w.HANDLE) callconv(w.WINAPI) w.BOOL;
    extern "kernel32" fn CreateEventW(attrs: ?*anyopaque, manual: w.BOOL, initial: w.BOOL, name: ?[*:0]const u16) callconv(w.WINAPI) ?w.HANDLE;
    extern "kernel32" fn SetEvent(h: w.HANDLE) callconv(w.WINAPI) w.BOOL;
    const FILE_NOTIFY_CHANGE_FILE_NAME = 0x1;
    const FILE_NOTIFY_CHANGE_LAST_WRITE = 0x10;

    wake: io.Wake,
    change: w.HANDLE,
    quit: w.HANDLE,
    thread: std.Thread,

    const Self = @This();

    fn start(dir: []const u8) !*Self {
        const a = std.heap.page_allocator;
        var zb: [std.fs.max_path_bytes]u16 = undefined;
        const n = try std.unicode.wtf8ToWtf16Le(zb[0 .. zb.len - 1], dir);
        zb[n] = 0;
        const change = FindFirstChangeNotificationW(@ptrCast(&zb), w.FALSE, FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_LAST_WRITE);
        if (change == w.INVALID_HANDLE_VALUE) return error.WatchFailed;
        errdefer _ = FindCloseChangeNotification(change);
        const quit = CreateEventW(null, w.TRUE, w.FALSE, null) orelse return error.WatchFailed;
        errdefer w.CloseHandle(quit);
        const self = try a.create(Self);
        errdefer a.destroy(self);
        self.* = .{ .wake = try io.Wake.init(), .change = change, .quit = quit, .thread = undefined };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    fn run(self: *Self) void {
        const hs = [2]w.HANDLE{ self.change, self.quit };
        while (true) {
            const r = w.kernel32.WaitForMultipleObjects(2, &hs, w.FALSE, w.INFINITE);
            if (r != w.WAIT_OBJECT_0) break;
            self.wake.signal();
            if (FindNextChangeNotification(self.change) == 0) break;
        }
    }

    fn stop(self: *Self) void {
        _ = SetEvent(self.quit);
        self.thread.join();
        _ = FindCloseChangeNotification(self.change);
        w.CloseHandle(self.quit);
        self.wake.deinit();
        std.heap.page_allocator.destroy(self);
    }
} else struct {
    wake: io.Wake,
    fn stop(_: *@This()) void {}
};

test "watcher sees writes and renames over the file" {
    if (builtin.os.tag != .linux) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try @import("../testutil.zig").tmpPath(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(dir);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, "config.lua" });
    defer std.testing.allocator.free(path);
    var w = Watcher.init(path) orelse return error.NoWatcher;
    defer w.deinit();
    try std.testing.expect(!w.drain());
    try tmp.dir.writeFile(.{ .sub_path = "other.lua", .data = "x" });
    try std.testing.expect(!w.drain());
    try tmp.dir.writeFile(.{ .sub_path = "config.lua", .data = "x" });
    try std.testing.expect(w.drain());
    // Editor-style save: write a temp file, rename it over.
    try tmp.dir.writeFile(.{ .sub_path = ".config.lua.swp", .data = "y" });
    _ = w.drain();
    try tmp.dir.rename(".config.lua.swp", "config.lua");
    try std.testing.expect(w.drain());
}
