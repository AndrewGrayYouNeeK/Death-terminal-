const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;

/// PTY represents a pseudo-terminal
pub const PTY = struct {
    master_fd: posix.fd_t,
    slave_fd: posix.fd_t,
    child_pid: ?posix.pid_t,
    slave_name_buf: [64]u8,

    /// Open a new PTY pair (master and slave)
    pub fn open() !PTY {
        if (builtin.os.tag == .windows) {
            return error.UnsupportedPlatform;
        }

        // Open PTY master using posix_openpt
        const master_fd = try openPtyMaster();
        errdefer posix.close(master_fd);

        // Grant access to slave PTY
        try grantpt(master_fd);

        // Unlock slave PTY
        try unlockpt(master_fd);

        // Get slave PTY name
        var pty: PTY = .{
            .master_fd = master_fd,
            .slave_fd = -1,
            .child_pid = null,
            .slave_name_buf = undefined,
        };

        const slave_name = try ptsname(master_fd, &pty.slave_name_buf);

        // Open slave PTY
        const slave_fd = try posix.open(slave_name, .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);
        errdefer posix.close(slave_fd);

        pty.slave_fd = slave_fd;
        return pty;
    }

    pub fn close(self: *PTY) void {
        posix.close(self.master_fd);
        if (self.slave_fd >= 0) {
            posix.close(self.slave_fd);
        }
    }

    /// Set PTY window size
    pub fn setWindowSize(self: PTY, rows: u16, cols: u16) !void {
        const ws = linux.winsize{
            .ws_row = rows,
            .ws_col = cols,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };

        const TIOCSWINSZ = 0x5414;
        const result = linux.ioctl(self.master_fd, TIOCSWINSZ, @intFromPtr(&ws));
        if (result != 0) {
            return error.IoctlFailed;
        }
    }

    /// Spawn a shell process in the PTY
    pub fn spawnShell(self: *PTY, allocator: std.mem.Allocator) !void {
        const shell: [*:0]const u8 = posix.getenv("SHELL") orelse "/bin/sh";

        // Build the child environment before fork (no allocation after fork).
        var env = try ChildEnv.init(allocator);
        defer env.deinit();

        const pid = try posix.fork();

        if (pid == 0) {
            // Child process
            self.setupChildProcess(shell, env.envp()) catch |err| {
                std.debug.print("Failed to setup child process: {}\n", .{err});
                std.posix.exit(1);
            };
        } else {
            // Parent process
            self.child_pid = pid;
            // Close slave FD in parent (child will use it)
            posix.close(self.slave_fd);
            self.slave_fd = -1;
        }
    }

    fn setupChildProcess(self: *PTY, shell: [*:0]const u8, envp: [*:null]const ?[*:0]const u8) !void {
        // The shell must start with default signal dispositions and an
        // empty mask even if we were launched with SIGINT ignored (e.g. as a
        // background job), otherwise Ctrl+C would never interrupt anything.
        resetSignals();

        // Create a new session
        _ = linux.syscall0(.setsid);

        // Make slave the controlling terminal
        const TIOCSCTTY = 0x540E;
        _ = linux.ioctl(self.slave_fd, TIOCSCTTY, 0);

        // Redirect stdin, stdout, stderr to slave
        try posix.dup2(self.slave_fd, posix.STDIN_FILENO);
        try posix.dup2(self.slave_fd, posix.STDOUT_FILENO);
        try posix.dup2(self.slave_fd, posix.STDERR_FILENO);

        // Close master in child
        posix.close(self.master_fd);
        if (self.slave_fd > 2) {
            posix.close(self.slave_fd);
        }

        const argv = [_:null]?[*:0]const u8{shell};
        const err = linux.execve(shell, &argv, envp);
        posix.exit(@intCast(err));
    }

    fn resetSignals() void {
        const dfl = posix.Sigaction{
            .handler = .{ .handler = posix.SIG.DFL },
            .mask = posix.empty_sigset,
            .flags = 0,
        };
        const sigs = [_]u6{ posix.SIG.INT, posix.SIG.QUIT, posix.SIG.TERM, posix.SIG.HUP, posix.SIG.PIPE, posix.SIG.CHLD, posix.SIG.TSTP, posix.SIG.TTIN, posix.SIG.TTOU, posix.SIG.WINCH, posix.SIG.USR1, posix.SIG.USR2 };
        for (sigs) |sig| posix.sigaction(sig, &dfl, null) catch {};
        const empty = posix.empty_sigset;
        posix.sigprocmask(posix.SIG.SETMASK, &empty, null);
    }

    /// Write data to PTY master
    pub fn write(self: PTY, data: []const u8) !usize {
        return posix.write(self.master_fd, data);
    }

    /// Read data from PTY master
    pub fn read(self: PTY, buffer: []u8) !usize {
        return posix.read(self.master_fd, buffer);
    }
};

/// Environment for the shell: the parent's, with the terminal identity
/// overridden (TERM=xterm-256color, COLORTERM=truecolor, TERM_PROGRAM).
pub const ChildEnv = struct {
    allocator: std.mem.Allocator,
    owned: std.ArrayList([:0]u8),
    ptrs: std.ArrayList(?[*:0]const u8),

    pub const overrides = [_][]const u8{
        "TERM=xterm-256color",
        "COLORTERM=truecolor",
        "TERM_PROGRAM=DeathTerminal",
    };

    pub fn init(allocator: std.mem.Allocator) !ChildEnv {
        var self = ChildEnv{
            .allocator = allocator,
            .owned = std.ArrayList([:0]u8).init(allocator),
            .ptrs = std.ArrayList(?[*:0]const u8).init(allocator),
        };
        errdefer self.deinit();

        // Zig 0.13: std.c.environ is [*:null]?[*:0]u8, not optional.
        var i: usize = 0;
        while (std.c.environ[i]) |entry| : (i += 1) {
            const kv = std.mem.span(entry);
            if (isOverridden(kv)) continue;
            try self.ptrs.append(entry);
        }
        for (overrides) |kv| {
            const z = try allocator.dupeZ(u8, kv);
            try self.owned.append(z);
            try self.ptrs.append(z.ptr);
        }
        try self.ptrs.append(null);
        return self;
    }

    fn isOverridden(kv: []const u8) bool {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse return false;
        for (overrides) |o| {
            const o_eq = std.mem.indexOfScalar(u8, o, '=').?;
            if (std.mem.eql(u8, kv[0 .. eq + 1], o[0 .. o_eq + 1])) return true;
        }
        return false;
    }

    pub fn envp(self: *const ChildEnv) [*:null]const ?[*:0]const u8 {
        return @ptrCast(self.ptrs.items.ptr);
    }

    pub fn deinit(self: *ChildEnv) void {
        for (self.owned.items) |z| self.allocator.free(z);
        self.owned.deinit();
        self.ptrs.deinit();
    }
};

test "child env sets TERM=xterm-256color exactly once" {
    if (builtin.os.tag != .linux) return;
    var env = try ChildEnv.init(std.testing.allocator);
    defer env.deinit();
    var count: usize = 0;
    var i: usize = 0;
    const e = env.envp();
    while (e[i]) |entry| : (i += 1) {
        const kv = std.mem.span(entry);
        if (std.mem.startsWith(u8, kv, "TERM=")) {
            count += 1;
            try std.testing.expectEqualStrings("TERM=xterm-256color", kv);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

// Platform-specific PTY functions
fn openPtyMaster() !posix.fd_t {
    if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
        return posix.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);
    }
    return error.UnsupportedPlatform;
}

fn grantpt(fd: posix.fd_t) !void {
    // On Linux, grantpt is typically not needed with /dev/ptmx
    // The kernel handles permissions automatically
    _ = fd;
}

fn unlockpt(fd: posix.fd_t) !void {
    if (builtin.os.tag == .linux) {
        const TIOCSPTLCK = 0x40045431;
        const unlock: c_int = 0;
        const result = linux.ioctl(fd, TIOCSPTLCK, @intFromPtr(&unlock));
        if (result != 0) {
            return error.UnlockFailed;
        }
    }
}

fn ptsname(fd: posix.fd_t, buffer: []u8) ![]const u8 {
    if (builtin.os.tag == .linux) {
        var n: u32 = 0;
        const TIOCGPTN = 0x80045430;
        const result = linux.ioctl(fd, TIOCGPTN, @intFromPtr(&n));
        if (result != 0) {
            return error.PtsnameFailed;
        }

        return try std.fmt.bufPrint(buffer, "/dev/pts/{d}", .{n});
    }
    return error.UnsupportedPlatform;
}
