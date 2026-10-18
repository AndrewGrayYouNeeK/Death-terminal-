const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;
const ansi_parser = @import("ansi_parser.zig");
const unicode = @import("unicode.zig");
const scrollback_mod = @import("scrollback.zig");

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

        const pid = try posix.fork();

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
            posix.close(self.slave_fd);
            self.slave_fd = -1;

            _ = allocator;
        }
    }

    fn setupChildProcess(self: *PTY, shell: [*:0]const u8) !void {
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
        // Zig 0.13: std.c.environ is [*:null]?[*:0]u8, not optional.
        const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
        const err = linux.execve(shell, &argv, envp);
        posix.exit(@intCast(err));
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

/// Cell represents a single character cell in the terminal
pub const Cell = struct {
    char: u21, // Unicode codepoint
    fg_color: u32,
    bg_color: u32,
    bold: bool,
    italic: bool,
    underline: bool,
    /// Columns this cell's glyph covers: 1 normally, 2 for the leading half
    /// of a wide character, 0 for the trailing spacer of a wide character
    /// (spacers hold ' ' so renderers that ignore `width` draw a blank).
    width: u2 = 1,
    /// Combining marks attached to `char` (0 = empty slot). Extra marks
    /// beyond the slots are dropped.
    combining: [max_combining]u21 = .{0} ** max_combining,

    pub const max_combining = 2;

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

    pub fn isSpacer(self: Cell) bool {
        return self.width == 0;
    }

    /// Append `char` and its combining marks to `writer` as UTF-8.
    pub fn writeUtf8(self: Cell, writer: anytype) !void {
        try writeCodepoint(writer, self.char);
        for (self.combining) |cp| {
            if (cp == 0) break;
            try writeCodepoint(writer, cp);
        }
    }
};

fn writeCodepoint(writer: anytype, cp: u21) !void {
    if (cp < 0x20 or cp == 0x7F) return writer.writeByte(' ');
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch return writer.writeAll("\u{FFFD}");
    try writer.writeAll(buf[0..n]);
}

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
    scrollback: scrollback_mod.Scrollback,
    initialized: bool,
    title: []u8,
    cursor_visible: bool,

    pub fn init(allocator: std.mem.Allocator) !Terminal {
        return initWithSize(allocator, 24, 80, 10_000);
    }

    pub fn initBuffer(
        allocator: std.mem.Allocator,
        rows: u16,
        cols: u16,
        scrollback_lines: usize,
    ) !Terminal {
        const buffer = try allocator.alloc(Cell, rows * cols);
        errdefer allocator.free(buffer);

        for (buffer) |*cell| {
            cell.* = Cell.init();
        }

        const title = try allocator.dupe(u8, "DeathTerminal");
        errdefer allocator.free(title);

        return Terminal{
            .allocator = allocator,
            .rows = rows,
            .cols = cols,
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
            .pty = null,
            .parser = ansi_parser.Parser.init(allocator),
            .scrollback = scrollback_mod.Scrollback.init(allocator, scrollback_lines),
            .initialized = true,
            .title = title,
            .cursor_visible = true,
        };
    }

    pub fn initWithSize(
        allocator: std.mem.Allocator,
        rows: u16,
        cols: u16,
        scrollback_lines: usize,
    ) !Terminal {
        std.debug.print("  → Initializing terminal core...\n", .{});

        var term = try initBuffer(allocator, rows, cols, scrollback_lines);
        errdefer term.deinit();

        var pty = try PTY.open();
        errdefer pty.close();
        try pty.setWindowSize(rows, cols);
        try pty.spawnShell(allocator);
        term.pty = pty;

        std.debug.print("  → Terminal core initialized ({d}x{d})\n", .{ cols, rows });
        return term;
    }

    pub fn deinit(self: *Terminal) void {
        self.parser.deinit();
        self.scrollback.deinit();
        self.allocator.free(self.buffer);
        self.allocator.free(self.title);
        if (self.pty) |*pty| {
            pty.close();
        }
        self.initialized = false;
    }

    pub fn getPtyFd(self: *const Terminal) ?posix.fd_t {
        if (self.pty) |pty| return pty.master_fd;
        return null;
    }

    pub fn scrollbackLen(self: *const Terminal) usize {
        return self.scrollback.len();
    }

    pub fn resize(self: *Terminal, rows: u16, cols: u16) !void {
        const new_rows = @max(rows, 1);
        const new_cols = @max(cols, 1);

        if (self.pty) |pty| {
            try pty.setWindowSize(new_rows, new_cols);
        }

        const new_buffer = try self.allocator.alloc(Cell, new_rows * new_cols);
        for (new_buffer) |*cell| cell.* = Cell.init();

        const min_rows = @min(self.rows, new_rows);
        const min_cols = @min(self.cols, new_cols);

        var row: u16 = 0;
        while (row < min_rows) : (row += 1) {
            var col: u16 = 0;
            while (col < min_cols) : (col += 1) {
                const old_idx = row * self.cols + col;
                const new_idx = row * new_cols + col;
                new_buffer[new_idx] = self.buffer[old_idx];
            }
        }

        self.allocator.free(self.buffer);
        self.buffer = new_buffer;
        self.rows = new_rows;
        self.cols = new_cols;
        self.cursor_row = @min(self.cursor_row, new_rows - 1);
        self.cursor_col = @min(self.cursor_col, new_cols - 1);
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
            if (self.parser.takePending()) |action| {
                try ansi_parser.applyAction(action, self);
            }
        }
    }

    // ANSI command implementations
    pub fn putChar(self: *Terminal, ch: u21) !void {
        if (self.cursor_row >= self.rows) return;
        var cp = ch;
        var w: u16 = unicode.width(cp);
        if (w == 0) return self.attachCombining(cp);
        if (w == 2 and self.cols < 2) {
            cp = unicode.replacement_char;
            w = 1;
        }

        if (self.cursor_col + w > self.cols) {
            // A wide char that doesn't fit in the last column: blank that
            // column and wrap, like xterm.
            if (self.cursor_col < self.cols) {
                self.breakWideAt(self.cursor_row, self.cursor_col);
                self.buffer[self.cellIndex(self.cursor_row, self.cursor_col)] = self.blankCell();
            }
            try self.lineFeed();
            self.cursor_col = 0;
        }

        const row = self.cursor_row;
        const col = self.cursor_col;
        self.breakWideAt(row, col);
        if (w == 2) self.breakWideAt(row, col + 1);

        var cell = self.blankCell();
        cell.char = cp;
        cell.width = @intCast(w);
        self.buffer[self.cellIndex(row, col)] = cell;
        if (w == 2) {
            var spacer = self.blankCell();
            spacer.width = 0;
            self.buffer[self.cellIndex(row, col + 1)] = spacer;
        }
        self.cursor_col += w;
    }

    fn cellIndex(self: *const Terminal, row: u16, col: u16) usize {
        return @as(usize, row) * @as(usize, self.cols) + col;
    }

    /// Cell with the current pen attributes and a blank glyph.
    fn blankCell(self: *const Terminal) Cell {
        var cell = Cell.init();
        cell.fg_color = self.current_fg;
        cell.bg_color = self.current_bg;
        cell.bold = self.current_bold;
        cell.italic = self.current_italic;
        cell.underline = self.current_underline;
        return cell;
    }

    /// Before overwriting (row, col), dissolve any wide pair it belongs to
    /// so no orphaned half is left behind.
    fn breakWideAt(self: *Terminal, row: u16, col: u16) void {
        if (row >= self.rows or col >= self.cols) return;
        const cell = &self.buffer[self.cellIndex(row, col)];
        if (cell.width == 0 and col > 0) {
            const lead = &self.buffer[self.cellIndex(row, col - 1)];
            if (lead.width == 2) lead.* = blankLike(lead.*);
        } else if (cell.width == 2 and col + 1 < self.cols) {
            const spacer = &self.buffer[self.cellIndex(row, col + 1)];
            if (spacer.width == 0) spacer.* = blankLike(spacer.*);
        }
    }

    fn blankLike(cell: Cell) Cell {
        var out = cell;
        out.char = ' ';
        out.width = 1;
        out.combining = .{0} ** Cell.max_combining;
        return out;
    }

    /// Attach a zero-width codepoint to the previously written cell.
    fn attachCombining(self: *Terminal, cp: u21) void {
        if (self.cursor_col == 0) return; // nothing to combine with on this row
        var col = @min(self.cursor_col, self.cols) - 1;
        if (self.buffer[self.cellIndex(self.cursor_row, col)].width == 0 and col > 0) col -= 1;
        const cell = &self.buffer[self.cellIndex(self.cursor_row, col)];
        for (&cell.combining) |*slot| {
            if (slot.* == 0) {
                slot.* = cp;
                return;
            }
        }
    }

    /// Repair wide pairs on one row after a bulk erase/move touched it.
    fn fixWideRow(self: *Terminal, row: u16) void {
        if (row >= self.rows) return;
        var col: u16 = 0;
        while (col < self.cols) : (col += 1) {
            const cell = &self.buffer[self.cellIndex(row, col)];
            if (cell.width == 2) {
                const ok = col + 1 < self.cols and self.buffer[self.cellIndex(row, col + 1)].width == 0;
                if (!ok) cell.* = blankLike(cell.*) else col += 1;
            } else if (cell.width == 0) {
                cell.* = blankLike(cell.*); // spacer without a lead
            }
        }
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
        const col = @min(self.cursor_col, self.cols - 1);
        const here = self.cellIndex(self.cursor_row, col);
        switch (mode) {
            0 => {
                // Clear from cursor to end of screen
                for (self.buffer[here..]) |*cell| cell.* = Cell.init();
            },
            1 => {
                // Clear from beginning to cursor
                for (self.buffer[0 .. here + 1]) |*cell| cell.* = Cell.init();
            },
            2, 3 => {
                // Clear entire screen
                try self.clear();
                return;
            },
            else => return,
        }
        self.fixWideRow(self.cursor_row);
    }

    pub fn eraseLine(self: *Terminal, mode: u32) !void {
        const row_start = self.cellIndex(self.cursor_row, 0);
        const row_end = row_start + self.cols;
        const here = row_start + @min(self.cursor_col, self.cols - 1);
        const range: []Cell = switch (mode) {
            0 => self.buffer[here..row_end],
            1 => self.buffer[row_start .. here + 1],
            2 => self.buffer[row_start..row_end],
            else => return,
        };
        for (range) |*cell| cell.* = Cell.init();
        self.fixWideRow(self.cursor_row);
    }

    pub fn scrollUp(self: *Terminal, n: u32) !void {
        const lines_to_scroll = @min(n, self.rows);
        var scrolled: u32 = 0;
        while (scrolled < lines_to_scroll) : (scrolled += 1) {
            const row_start: usize = 0;
            const row_end: usize = self.cols;
            try self.scrollback.pushLine(self.buffer[row_start..row_end]);

            const cells_to_move = (self.rows - 1) * self.cols;
            const src_start = self.cols;
            std.mem.copyForwards(Cell, self.buffer[0..cells_to_move], self.buffer[src_start..]);

            const clear_start = cells_to_move;
            for (self.buffer[clear_start..]) |*cell| {
                cell.* = Cell.init();
            }
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
        if (params.intermediate == '?' and params.getParam(0, 0) == 25) {
            self.cursor_visible = true;
        }
    }

    pub fn resetMode(self: *Terminal, params: ansi_parser.CSIParams) !void {
        if (params.intermediate == '?' and params.getParam(0, 0) == 25) {
            self.cursor_visible = false;
        }
    }

    pub fn setTitle(self: *Terminal, title: []const u8) !void {
        self.allocator.free(self.title);
        self.title = try self.allocator.dupe(u8, title);
    }

    /// The grid as UTF-8 text, one line per row. Wide-char spacers are
    /// skipped (the wide glyph already covers two columns).
    pub fn visibleText(self: *const Terminal, allocator: std.mem.Allocator) ![]u8 {
        var list = std.ArrayList(u8).init(allocator);
        errdefer list.deinit();
        var row: u16 = 0;
        while (row < self.rows) : (row += 1) {
            try appendRowText(self.buffer[self.cellIndex(row, 0)..][0..self.cols], list.writer());
            if (row + 1 < self.rows) try list.append('\n');
        }
        return list.toOwnedSlice();
    }
};

/// Write a row of cells as UTF-8, skipping wide-char spacers.
pub fn appendRowText(cells: []const Cell, writer: anytype) !void {
    for (cells) |cell| {
        if (cell.isSpacer()) continue;
        try cell.writeUtf8(writer);
    }
}

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

test "buffer emulation and title" {
    const testing = std.testing;
    var term = try Terminal.initBuffer(testing.allocator, 24, 80, 8);
    defer term.deinit();

    try term.processOutput("hello\r\nworld");
    try testing.expectEqual(@as(u21, 'h'), term.getCell(0, 0).?.char);
    try testing.expectEqual(@as(u21, 'w'), term.getCell(1, 0).?.char);

    try term.processOutput("\x1b]0;ssh prod\x07");
    try testing.expectEqualStrings("ssh prod", term.title);

    try term.processOutput("\x1b[2J\x1b[H");
    try testing.expectEqual(@as(u16, 0), term.cursor_row);
    try testing.expectEqual(@as(u21, ' '), term.getCell(0, 0).?.char);
}

test "buffer resize copies cells and clamps cursor" {
    const testing = std.testing;
    var term = try Terminal.initBuffer(testing.allocator, 4, 8, 4);
    defer term.deinit();

    term.getCell(0, 0).?.char = 'A';
    term.cursor_row = 3;
    term.cursor_col = 7;
    try term.resize(2, 4);

    try testing.expectEqual(@as(u16, 2), term.rows);
    try testing.expectEqual(@as(u16, 4), term.cols);
    try testing.expectEqual(@as(u21, 'A'), term.getCell(0, 0).?.char);
    try testing.expectEqual(@as(u16, 1), term.cursor_row);
    try testing.expectEqual(@as(u16, 3), term.cursor_col);
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

fn expectRowText(term: *const Terminal, row: u16, expected: []const u8) !void {
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    try appendRowText(term.buffer[@as(usize, row) * term.cols ..][0..term.cols], list.writer());
    try std.testing.expectEqualStrings(expected, std.mem.trimRight(u8, list.items, " "));
}

test "UTF-8 lands in the grid as codepoints with wide cells" {
    const t = std.testing;
    var term = try Terminal.initBuffer(t.allocator, 2, 20, 4);
    defer term.deinit();

    try term.processOutput("h\xc3\xa9llo \xe6\x97\xa5\xe6\x9c\xac \xf0\x9f\x99\x82");
    try t.expectEqual(@as(u21, 0xE9), term.getCell(0, 1).?.char);
    try t.expectEqual(@as(u21, 0x65E5), term.getCell(0, 6).?.char);
    try t.expectEqual(@as(u2, 2), term.getCell(0, 6).?.width);
    try t.expect(term.getCell(0, 7).?.isSpacer());
    try t.expectEqual(@as(u21, 0x672C), term.getCell(0, 8).?.char);
    try t.expect(term.getCell(0, 9).?.isSpacer());
    try t.expectEqual(@as(u21, 0x1F642), term.getCell(0, 11).?.char);
    try t.expect(term.getCell(0, 12).?.isSpacer());
    try t.expectEqual(@as(u16, 13), term.cursor_col);
    try expectRowText(&term, 0, "h\u{e9}llo \u{65e5}\u{672c} \u{1f642}");
}

test "combining marks attach to the previous cell" {
    const t = std.testing;
    var term = try Terminal.initBuffer(t.allocator, 1, 10, 4);
    defer term.deinit();

    // e + U+0301, then wide 日 + U+0301 + two more marks (third is dropped)
    try term.processOutput("e\xcc\x81x\xe6\x97\xa5\xcc\x81\xcc\x82\xcc\x83y");
    try t.expectEqual(@as(u21, 'e'), term.getCell(0, 0).?.char);
    try t.expectEqual(@as(u21, 0x0301), term.getCell(0, 0).?.combining[0]);
    try t.expectEqual(@as(u21, 'x'), term.getCell(0, 1).?.char);
    try t.expectEqual(@as(u21, 0x65E5), term.getCell(0, 2).?.char);
    try t.expectEqual(@as(u21, 0x0301), term.getCell(0, 2).?.combining[0]);
    try t.expectEqual(@as(u21, 0x0302), term.getCell(0, 2).?.combining[1]);
    try t.expect(term.getCell(0, 3).?.isSpacer());
    try t.expectEqual(@as(u21, 'y'), term.getCell(0, 4).?.char);
    try t.expectEqual(@as(u16, 5), term.cursor_col);

    // A combining mark at column 0 must not corrupt anything.
    try term.processOutput("\r\xcc\x81");
    try t.expectEqual(@as(u16, 0), term.cursor_col);
    try t.expectEqual(@as(u21, 'e'), term.getCell(0, 0).?.char);
}

test "wide char wraps instead of splitting at the last column" {
    const t = std.testing;
    var term = try Terminal.initBuffer(t.allocator, 2, 5, 4);
    defer term.deinit();

    try term.processOutput("abcd\xe6\x97\xa5");
    try t.expectEqual(@as(u21, ' '), term.getCell(0, 4).?.char);
    try t.expectEqual(@as(u2, 1), term.getCell(0, 4).?.width);
    try t.expectEqual(@as(u21, 0x65E5), term.getCell(1, 0).?.char);
    try t.expect(term.getCell(1, 1).?.isSpacer());
    try t.expectEqual(@as(u16, 2), term.cursor_col);
}

test "overwriting half of a wide char clears the other half" {
    const t = std.testing;
    var term = try Terminal.initBuffer(t.allocator, 1, 6, 4);
    defer term.deinit();

    try term.processOutput("\xe6\x97\xa5\xe6\x9c\xac");
    // Overwrite the spacer of 日 (col 1) and the lead of 本 (col 2).
    try term.processOutput("\x1b[1;2HXY");
    try t.expectEqual(@as(u21, ' '), term.getCell(0, 0).?.char);
    try t.expectEqual(@as(u2, 1), term.getCell(0, 0).?.width);
    try t.expectEqual(@as(u21, 'X'), term.getCell(0, 1).?.char);
    try t.expectEqual(@as(u21, 'Y'), term.getCell(0, 2).?.char);
    try t.expectEqual(@as(u2, 1), term.getCell(0, 3).?.width);
    try t.expectEqual(@as(u21, ' '), term.getCell(0, 3).?.char);
}

test "erase that splits a wide char leaves no orphan half" {
    const t = std.testing;
    var term = try Terminal.initBuffer(t.allocator, 1, 6, 4);
    defer term.deinit();

    try term.processOutput("\xe6\x97\xa5\xe6\x9c\xac");
    // Cursor onto the spacer of 日 and erase to end of line.
    try term.processOutput("\x1b[1;2H\x1b[K");
    try t.expectEqual(@as(u2, 1), term.getCell(0, 0).?.width);
    try t.expectEqual(@as(u21, ' '), term.getCell(0, 0).?.char);
}

test "erase with pending-wrap cursor stays in bounds" {
    const t = std.testing;
    var term = try Terminal.initBuffer(t.allocator, 2, 4, 4);
    defer term.deinit();

    try term.processOutput("\x1b[2;1Habcd"); // cursor_col == cols on last row
    try term.processOutput("\x1b[1K");
    try term.processOutput("abcd\x1b[1J");
    try t.expectEqual(@as(u21, ' '), term.getCell(1, 3).?.char);
}

test "invalid UTF-8 becomes U+FFFD in the grid" {
    const t = std.testing;
    var term = try Terminal.initBuffer(t.allocator, 1, 8, 4);
    defer term.deinit();

    try term.processOutput("a\xffb\xe6\x97c");
    try t.expectEqual(unicode.replacement_char, term.getCell(0, 1).?.char);
    try t.expectEqual(@as(u21, 'b'), term.getCell(0, 2).?.char);
    try t.expectEqual(unicode.replacement_char, term.getCell(0, 3).?.char);
    try t.expectEqual(@as(u21, 'c'), term.getCell(0, 4).?.char);
}
