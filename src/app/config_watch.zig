//! Watches the config file for changes (Linux inotify) so a running
//! terminal reloads it on save. The directory is watched, not the file,
//! because editors save by writing a temp file and renaming it over the
//! original. Elsewhere `init` returns null and only the reload keybinding
//! works.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;

pub const Watcher = struct {
    fd: posix.fd_t,
    name_buf: [256]u8 = undefined,
    name_len: usize = 0,

    /// Watch for changes to `path` (which need not exist yet; its
    /// directory must).
    pub fn init(path: []const u8) ?Watcher {
        if (builtin.os.tag != .linux) return null;
        const dir = std.fs.path.dirname(path) orelse ".";
        const base = std.fs.path.basename(path);
        if (base.len > 255) return null;
        const fd = posix.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC) catch return null;
        const mask = linux.IN.CLOSE_WRITE | linux.IN.MOVED_TO | linux.IN.CREATE | linux.IN.DELETE | linux.IN.MOVED_FROM;
        _ = posix.inotify_add_watch(fd, dir, mask) catch {
            posix.close(fd);
            return null;
        };
        var w = Watcher{ .fd = fd };
        @memcpy(w.name_buf[0..base.len], base);
        w.name_len = base.len;
        return w;
    }

    pub fn deinit(self: *Watcher) void {
        posix.close(self.fd);
    }

    /// Read pending events; true if any concerned the config file.
    pub fn drain(self: *Watcher) bool {
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

test "watcher sees writes and renames over the file" {
    if (builtin.os.tag != .linux) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
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
