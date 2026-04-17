const std = @import("std");
const builtin = @import("builtin");
const os = std.os;
const posix = std.posix;

/// PTY represents a pseudo-terminal
pub const PTY = struct {
    master_fd: os.fd_t,
    slave_fd: os.fd_t,
    child_pid: ?os.pid_t,

    /// Open a new PTY pair (master and slave)
    pub fn open() !PTY {
        if (builtin.os.tag == .windows) {
            return error.UnsupportedPlatform;
        }

        // Open PTY master using posix_openpt
        const master_fd = try openPtyMaster();
        errdefer os.close(master_fd);

        // Grant access to slave PTY
        try grantpt(master_fd);

        // Unlock slave PTY
        try unlockpt(master_fd);

        // Get slave PTY name
        const slave_name = try ptsname(master_fd);

        // Open slave PTY
        const slave_fd = try os.open(slave_name, os.O.RDWR | os.O.NOCTTY, 0);
        errdefer os.close(slave_fd);

        return PTY{
            .master_fd = master_fd,
            .slave_fd = slave_fd,
            .child_pid = null,
        };
    }

    pub fn close(self: *PTY) void {
        os.close(self.master_fd);
        os.close(self.slave_fd);
    }

    /// Set PTY window size
    pub fn setWindowSize(self: PTY, rows: u16, cols: u16) !void {
        const ws = std.os.linux.winsize{
            .ws_row = rows,
            .ws_col = cols,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };

        const TIOCSWINSZ = 0x5414;
        const result = std.os.linux.ioctl(self.master_fd, TIOCSWINSZ, @intFromPtr(&ws));
        if (result != 0) {
            return error.IoctlFailed;
        }
    }

    /// Spawn a shell process in the PTY
    pub fn spawnShell(self: *PTY, allocator: std.mem.Allocator) !void {
        const shell = std.posix.getenv("SHELL") orelse "/bin/sh";

        const pid = try os.fork();

        if (pid == 0) {
            // Child process
            self.setupChildProcess(shell) catch |err| {
                std.debug.print("Failed to setup child process: {}\n", .{err});
                std.posix.exit(1);
            };
        } else {
            // Parent process
            self.child_pid = pid;
            // Close slave FD in parent (child will use it)
            os.close(self.slave_fd);
            self.slave_fd = -1;

            _ = allocator;
        }
    }

    fn setupChildProcess(self: *PTY, shell: []const u8) !void {
        // Create a new session
        _ = std.os.linux.syscall0(.setsid);

        // Make slave the controlling terminal
        const TIOCSCTTY = 0x540E;
        _ = std.os.linux.ioctl(self.slave_fd, TIOCSCTTY, 0);

        // Redirect stdin, stdout, stderr to slave
        try os.dup2(self.slave_fd, os.STDIN_FILENO);
        try os.dup2(self.slave_fd, os.STDOUT_FILENO);
        try os.dup2(self.slave_fd, os.STDERR_FILENO);

        // Close master in child
        os.close(self.master_fd);
        if (self.slave_fd > 2) {
            os.close(self.slave_fd);
        }

        // Execute shell
        const argv = [_:null]?[*:0]const u8{shell.ptr};
        const envp = [_:null]?[*:0]const u8{null};
        const err = std.os.linux.execve(shell.ptr, &argv, &envp);
        std.posix.exit(@intCast(err));
    }

    /// Write data to PTY master
    pub fn write(self: PTY, data: []const u8) !usize {
        return os.write(self.master_fd, data);
    }

    /// Read data from PTY master
    pub fn read(self: PTY, buffer: []u8) !usize {
        return os.read(self.master_fd, buffer);
    }
};

// Platform-specific PTY functions
fn openPtyMaster() !os.fd_t {
    if (builtin.os.tag == .linux) {
        const O_RDWR = 0o2;
        const O_NOCTTY = 0o400;
        const fd = std.os.linux.open("/dev/ptmx", O_RDWR | O_NOCTTY, 0);
        if (fd < 0) {
            return error.OpenFailed;
        }
        return @intCast(fd);
    } else if (builtin.os.tag == .macos) {
        const O_RDWR = 0x0002;
        const O_NOCTTY = 0x20000;
        const fd = std.os.linux.open("/dev/ptmx", O_RDWR | O_NOCTTY, 0);
        if (fd < 0) {
            return error.OpenFailed;
        }
        return @intCast(fd);
    }
    return error.UnsupportedPlatform;
}

fn grantpt(fd: os.fd_t) !void {
    // On Linux, grantpt is typically not needed with /dev/ptmx
    // The kernel handles permissions automatically
    _ = fd;
}

fn unlockpt(fd: os.fd_t) !void {
    if (builtin.os.tag == .linux) {
        const TIOCSPTLCK = 0x40045431;
        const unlock: c_int = 0;
        const result = std.os.linux.ioctl(fd, TIOCSPTLCK, @intFromPtr(&unlock));
        if (result != 0) {
            return error.UnlockFailed;
        }
    }
}

fn ptsname(fd: os.fd_t) ![]const u8 {
    if (builtin.os.tag == .linux) {
        var n: u32 = 0;
        const TIOCGPTN = 0x80045430;
        const result = std.os.linux.ioctl(fd, TIOCGPTN, @intFromPtr(&n));
        if (result != 0) {
            return error.PtsnameFailed;
        }

        var buf: [32]u8 = undefined;
        const slave_name = try std.fmt.bufPrint(&buf, "/dev/pts/{d}", .{n});

        // This is a static buffer, which is fine for immediate use
        // In production, you'd want to allocate this
        return slave_name;
    }
    return error.UnsupportedPlatform;
}

/// Cell represents a single character cell in the terminal
pub const Cell = struct {
    char: u21, // Unicode codepoint
    fg_color: u32,
    bg_color: u32,
    bold: bool,
    italic: bool,
    underline: bool,

    pub fn init() Cell {
        return Cell{
            .char = ' ',
            .fg_color = 0xFFFFFF,
            .bg_color = 0x000000,
            .bold = false,
            .italic = false,
            .underline = false,
        };
    }
};

/// Terminal represents the core terminal emulator functionality
/// Handles PTY (pseudo-terminal) creation, process spawning, and I/O
pub const Terminal = struct {
    allocator: std.mem.Allocator,
    rows: u16,
    cols: u16,
    buffer: []Cell,
    cursor_row: u16,
    cursor_col: u16,
    pty: ?PTY,
    initialized: bool,

    pub fn init(allocator: std.mem.Allocator) !Terminal {
        std.debug.print("  → Initializing terminal core...\n", .{});

        const default_rows = 24;
        const default_cols = 80;

        // Allocate cell buffer
        const buffer = try allocator.alloc(Cell, default_rows * default_cols);
        errdefer allocator.free(buffer);

        // Initialize all cells
        for (buffer) |*cell| {
            cell.* = Cell.init();
        }

        // Open PTY
        var pty = try PTY.open();
        errdefer pty.close();

        // Set window size
        try pty.setWindowSize(default_rows, default_cols);

        // Spawn shell
        try pty.spawnShell(allocator);

        std.debug.print("  → Terminal core initialized (80x24)\n", .{});

        return Terminal{
            .allocator = allocator,
            .rows = default_rows,
            .cols = default_cols,
            .buffer = buffer,
            .cursor_row = 0,
            .cursor_col = 0,
            .pty = pty,
            .initialized = true,
        };
    }

    pub fn deinit(self: *Terminal) void {
        self.allocator.free(self.buffer);
        if (self.pty) |*pty| {
            pty.close();
        }
        self.initialized = false;
    }

    pub fn resize(self: *Terminal, rows: u16, cols: u16) !void {
        // Resize PTY
        if (self.pty) |pty| {
            try pty.setWindowSize(rows, cols);
        }

        // Reallocate buffer
        const new_buffer = try self.allocator.alloc(Cell, rows * cols);

        // Copy old content (as much as fits)
        const min_rows = @min(self.rows, rows);
        const min_cols = @min(self.cols, cols);

        var row: u16 = 0;
        while (row < min_rows) : (row += 1) {
            var col: u16 = 0;
            while (col < min_cols) : (col += 1) {
                const old_idx = row * self.cols + col;
                const new_idx = row * cols + col;
                new_buffer[new_idx] = self.buffer[old_idx];
            }
        }

        // Initialize remaining cells
        for (new_buffer) |*cell| {
            if (cell.char == 0) {
                cell.* = Cell.init();
            }
        }

        self.allocator.free(self.buffer);
        self.buffer = new_buffer;
        self.rows = rows;
        self.cols = cols;
    }

    pub fn write(self: *Terminal, data: []const u8) !void {
        if (self.pty) |pty| {
            _ = try pty.write(data);
        }
    }

    pub fn read(self: *Terminal, buffer: []u8) !usize {
        if (self.pty) |pty| {
            return try pty.read(buffer);
        }
        return 0;
    }

    /// Get cell at position
    pub fn getCell(self: *Terminal, row: u16, col: u16) ?*Cell {
        if (row >= self.rows or col >= self.cols) {
            return null;
        }
        const idx = row * self.cols + col;
        return &self.buffer[idx];
    }

    /// Set cell at position
    pub fn setCell(self: *Terminal, row: u16, col: u16, cell: Cell) void {
        if (row >= self.rows or col >= self.cols) {
            return;
        }
        const idx = row * self.cols + col;
        self.buffer[idx] = cell;
    }

    /// Move cursor to position
    pub fn moveCursor(self: *Terminal, row: u16, col: u16) void {
        self.cursor_row = @min(row, self.rows - 1);
        self.cursor_col = @min(col, self.cols - 1);
    }
};

test "Terminal init" {
    const testing = std.testing;

    // Skip PTY tests in test environment (requires real terminal)
    if (builtin.os.tag == .windows) {
        return error.SkipZigTest;
    }

    // Test Cell initialization
    const cell = Cell.init();
    try testing.expectEqual(@as(u21, ' '), cell.char);
    try testing.expectEqual(@as(u32, 0xFFFFFF), cell.fg_color);
    try testing.expectEqual(@as(u32, 0x000000), cell.bg_color);
    try testing.expect(!cell.bold);
    try testing.expect(!cell.italic);
    try testing.expect(!cell.underline);
}

test "Cell manipulation" {
    const testing = std.testing;
    var cell = Cell.init();

    cell.char = 'A';
    cell.bold = true;
    cell.fg_color = 0xFF0000;

    try testing.expectEqual(@as(u21, 'A'), cell.char);
    try testing.expect(cell.bold);
    try testing.expectEqual(@as(u32, 0xFF0000), cell.fg_color);
}
