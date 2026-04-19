const std = @import("std");
const builtin = @import("builtin");
const os = std.os;
const posix = std.posix;
const ansi_parser = @import("ansi_parser.zig");

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
    saved_cursor_row: u16,
    saved_cursor_col: u16,
    current_fg: u32,
    current_bg: u32,
    current_bold: bool,
    current_italic: bool,
    current_underline: bool,
    pty: ?PTY,
    parser: ansi_parser.Parser,
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
            .saved_cursor_row = 0,
            .saved_cursor_col = 0,
            .current_fg = 0xFFFFFF,
            .current_bg = 0x000000,
            .current_bold = false,
            .current_italic = false,
            .current_underline = false,
            .pty = pty,
            .parser = ansi_parser.Parser.init(allocator),
            .initialized = true,
        };
    }

    pub fn deinit(self: *Terminal) void {
        self.parser.deinit();
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

    /// Process PTY output and update terminal state
    pub fn processOutput(self: *Terminal, data: []const u8) !void {
        for (data) |byte| {
            if (try self.parser.advance(byte)) |action| {
                try ansi_parser.applyAction(action, self);
            }
        }
    }

    // ANSI command implementations
    pub fn putChar(self: *Terminal, ch: u21) !void {
        if (self.cursor_row >= self.rows) return;
        if (self.cursor_col >= self.cols) {
            try self.lineFeed();
            self.cursor_col = 0;
        }

        const idx = self.cursor_row * self.cols + self.cursor_col;
        self.buffer[idx] = Cell{
            .char = ch,
            .fg_color = self.current_fg,
            .bg_color = self.current_bg,
            .bold = self.current_bold,
            .italic = self.current_italic,
            .underline = self.current_underline,
        };
        self.cursor_col += 1;
    }

    pub fn clear(self: *Terminal) !void {
        for (self.buffer) |*cell| {
            cell.* = Cell.init();
        }
        self.cursor_row = 0;
        self.cursor_col = 0;
    }

    pub fn backspace(self: *Terminal) !void {
        if (self.cursor_col > 0) {
            self.cursor_col -= 1;
        }
    }

    pub fn tab(self: *Terminal) !void {
        const next_tab = ((self.cursor_col / 8) + 1) * 8;
        self.cursor_col = @min(next_tab, self.cols - 1);
    }

    pub fn lineFeed(self: *Terminal) !void {
        if (self.cursor_row < self.rows - 1) {
            self.cursor_row += 1;
        } else {
            // Scroll up
            try self.scrollUp(1);
        }
    }

    pub fn carriageReturn(self: *Terminal) !void {
        self.cursor_col = 0;
    }

    pub fn cursorUp(self: *Terminal, n: u32) !void {
        if (n > self.cursor_row) {
            self.cursor_row = 0;
        } else {
            self.cursor_row -= @intCast(n);
        }
    }

    pub fn cursorDown(self: *Terminal, n: u32) !void {
        self.cursor_row = @min(self.cursor_row + @as(u16, @intCast(n)), self.rows - 1);
    }

    pub fn cursorForward(self: *Terminal, n: u32) !void {
        self.cursor_col = @min(self.cursor_col + @as(u16, @intCast(n)), self.cols - 1);
    }

    pub fn cursorBack(self: *Terminal, n: u32) !void {
        if (n > self.cursor_col) {
            self.cursor_col = 0;
        } else {
            self.cursor_col -= @intCast(n);
        }
    }

    pub fn eraseDisplay(self: *Terminal, mode: u32) !void {
        switch (mode) {
            0 => {
                // Clear from cursor to end of screen
                const start = self.cursor_row * self.cols + self.cursor_col;
                for (self.buffer[start..]) |*cell| {
                    cell.* = Cell.init();
                }
            },
            1 => {
                // Clear from beginning to cursor
                const end = self.cursor_row * self.cols + self.cursor_col + 1;
                for (self.buffer[0..end]) |*cell| {
                    cell.* = Cell.init();
                }
            },
            2, 3 => {
                // Clear entire screen
                try self.clear();
            },
            else => {},
        }
    }

    pub fn eraseLine(self: *Terminal, mode: u32) !void {
        const row_start = self.cursor_row * self.cols;
        switch (mode) {
            0 => {
                // Clear from cursor to end of line
                const start = row_start + self.cursor_col;
                const end = row_start + self.cols;
                for (self.buffer[start..end]) |*cell| {
                    cell.* = Cell.init();
                }
            },
            1 => {
                // Clear from beginning of line to cursor
                const end = row_start + self.cursor_col + 1;
                for (self.buffer[row_start..end]) |*cell| {
                    cell.* = Cell.init();
                }
            },
            2 => {
                // Clear entire line
                const end = row_start + self.cols;
                for (self.buffer[row_start..end]) |*cell| {
                    cell.* = Cell.init();
                }
            },
            else => {},
        }
    }

    pub fn scrollUp(self: *Terminal, n: u32) !void {
        const lines_to_scroll = @min(n, self.rows);
        const cells_to_move = (self.rows - lines_to_scroll) * self.cols;
        const src_start = lines_to_scroll * self.cols;

        // Move lines up
        std.mem.copyForwards(Cell, self.buffer[0..cells_to_move], self.buffer[src_start..]);

        // Clear bottom lines
        const clear_start = cells_to_move;
        for (self.buffer[clear_start..]) |*cell| {
            cell.* = Cell.init();
        }
    }

    pub fn scrollDown(self: *Terminal, n: u32) !void {
        const lines_to_scroll = @min(n, self.rows);
        const cells_to_move = (self.rows - lines_to_scroll) * self.cols;
        const dest_start = lines_to_scroll * self.cols;

        // Move lines down
        std.mem.copyBackwards(Cell, self.buffer[dest_start..], self.buffer[0..cells_to_move]);

        // Clear top lines
        const clear_end = lines_to_scroll * self.cols;
        for (self.buffer[0..clear_end]) |*cell| {
            cell.* = Cell.init();
        }
    }

    pub fn saveCursor(self: *Terminal) !void {
        self.saved_cursor_row = self.cursor_row;
        self.saved_cursor_col = self.cursor_col;
    }

    pub fn restoreCursor(self: *Terminal) !void {
        self.cursor_row = self.saved_cursor_row;
        self.cursor_col = self.saved_cursor_col;
    }

    pub fn resetAttributes(self: *Terminal) !void {
        self.current_fg = 0xFFFFFF;
        self.current_bg = 0x000000;
        self.current_bold = false;
        self.current_italic = false;
        self.current_underline = false;
    }

    pub fn setBold(self: *Terminal, value: bool) !void {
        self.current_bold = value;
    }

    pub fn setItalic(self: *Terminal, value: bool) !void {
        self.current_italic = value;
    }

    pub fn setUnderline(self: *Terminal, value: bool) !void {
        self.current_underline = value;
    }

    pub fn setFgColor(self: *Terminal, color_index: u32) !void {
        // Convert ANSI color index to RGB
        const colors = [_]u32{
            0x000000, // Black
            0xCD0000, // Red
            0x00CD00, // Green
            0xCDCD00, // Yellow
            0x0000EE, // Blue
            0xCD00CD, // Magenta
            0x00CDCD, // Cyan
            0xE5E5E5, // White
            // Bright colors
            0x7F7F7F, // Bright Black
            0xFF0000, // Bright Red
            0x00FF00, // Bright Green
            0xFFFF00, // Bright Yellow
            0x5C5CFF, // Bright Blue
            0xFF00FF, // Bright Magenta
            0x00FFFF, // Bright Cyan
            0xFFFFFF, // Bright White
        };
        if (color_index < colors.len) {
            self.current_fg = colors[color_index];
        }
    }

    pub fn setBgColor(self: *Terminal, color_index: u32) !void {
        const colors = [_]u32{
            0x000000, 0xCD0000, 0x00CD00, 0xCDCD00,
            0x0000EE, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
            0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00,
            0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF,
        };
        if (color_index < colors.len) {
            self.current_bg = colors[color_index];
        }
    }

    pub fn resetFgColor(self: *Terminal) !void {
        self.current_fg = 0xFFFFFF;
    }

    pub fn resetBgColor(self: *Terminal) !void {
        self.current_bg = 0x000000;
    }

    pub fn setMode(self: *Terminal, params: ansi_parser.CSIParams) !void {
        _ = self;
        _ = params;
        // TODO: Implement mode setting (e.g., cursor visibility, mouse tracking)
    }

    pub fn resetMode(self: *Terminal, params: ansi_parser.CSIParams) !void {
        _ = self;
        _ = params;
        // TODO: Implement mode resetting
    }

    pub fn setTitle(self: *Terminal, title: []const u8) !void {
        _ = self;
        _ = title;
        // TODO: Store and expose window title
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
