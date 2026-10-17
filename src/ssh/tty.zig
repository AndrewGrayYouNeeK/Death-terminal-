//! The SSH client's terminal: raw mode, window size and the in-terminal
//! prompts (host keys, passphrases, passwords, keyboard-interactive).
//! Secret answers live in caller-provided buffers that are wiped with
//! `std.crypto.utils.secureZero` after use; nothing typed is ever logged.

const std = @import("std");
const posix = std.posix;

pub const Tty = struct {
    in: posix.fd_t = posix.STDIN_FILENO,
    out: posix.fd_t = posix.STDOUT_FILENO,
    saved: ?posix.termios = null,
    /// A status line ("Connecting to …") is showing without a newline.
    status_open: bool = false,

    pub fn isTty(self: *const Tty) bool {
        return posix.isatty(self.in);
    }

    /// No echo, no line editing, no signals: keys go to the remote side.
    pub fn enterRaw(self: *Tty) void {
        if (self.saved != null or !self.isTty()) return;
        const t = posix.tcgetattr(self.in) catch return;
        self.saved = t;
        var raw = t;
        raw.iflag.IGNBRK = false;
        raw.iflag.BRKINT = false;
        raw.iflag.PARMRK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.INLCR = false;
        raw.iflag.IGNCR = false;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;
        raw.oflag.OPOST = false;
        raw.lflag.ECHO = false;
        raw.lflag.ECHONL = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;
        posix.tcsetattr(self.in, .NOW, raw) catch {};
    }

    pub fn restore(self: *Tty) void {
        if (self.saved) |t| posix.tcsetattr(self.in, .DRAIN, t) catch {};
        self.saved = null;
    }

    pub fn size(self: *const Tty) struct { rows: u16, cols: u16, xpx: u16, ypx: u16 } {
        var ws: posix.winsize = .{ .ws_row = 0, .ws_col = 0, .ws_xpixel = 0, .ws_ypixel = 0 };
        const rc = std.os.linux.ioctl(self.in, std.os.linux.T.IOCGWINSZ, @intFromPtr(&ws));
        if (posix.errno(rc) != .SUCCESS or ws.ws_row == 0 or ws.ws_col == 0) return .{ .rows = 24, .cols = 80, .xpx = 0, .ypx = 0 };
        return .{ .rows = ws.ws_row, .cols = ws.ws_col, .xpx = ws.ws_xpixel, .ypx = ws.ws_ypixel };
    }

    pub fn write(self: *const Tty, bytes: []const u8) void {
        var rest = bytes;
        while (rest.len > 0) {
            const n = posix.write(self.out, rest) catch |err| switch (err) {
                error.WouldBlock => {
                    var pfd = [_]posix.pollfd{.{ .fd = self.out, .events = posix.POLL.OUT, .revents = 0 }};
                    _ = posix.poll(&pfd, 1000) catch {};
                    continue;
                },
                else => return,
            };
            rest = rest[n..];
        }
    }

    /// A one-line status that `clearStatus` erases (or the next message
    /// moves below).
    pub fn status(self: *Tty, comptime fmt: []const u8, args: anytype) void {
        self.clearStatus();
        var buf: [512]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
        self.write(dim);
        self.write(s);
        self.write(reset);
        self.status_open = true;
    }

    pub fn clearStatus(self: *Tty) void {
        if (!self.status_open) return;
        self.write("\r\x1b[2K");
        self.status_open = false;
    }

    /// Text for the user; "\n" becomes "\r\n" (raw mode has no OPOST).
    pub fn print(self: *Tty, comptime fmt: []const u8, args: anytype) void {
        if (self.status_open) {
            self.write("\r\n");
            self.status_open = false;
        }
        var buf: [2048]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
        var start: usize = 0;
        for (s, 0..) |ch, i| if (ch == '\n') {
            self.write(s[start..i]);
            self.write("\r\n");
            start = i + 1;
        };
        self.write(s[start..]);
    }

    pub const ReadError = error{ Cancelled, EndOfInput };

    /// Reads one line after printing `prompt`. With `echo` false nothing
    /// is shown while typing (like OpenSSH). Backspace, Ctrl+U and Ctrl+W
    /// edit; Ctrl+C / Ctrl+D (empty line) cancel. The result is a slice
    /// of `buf`; the caller wipes `buf` when done with a secret.
    pub fn readLine(self: *Tty, prompt: []const u8, echo: bool, buf: []u8) ReadError![]u8 {
        const was_raw = self.saved != null;
        self.enterRaw();
        defer if (!was_raw) self.restore();
        self.print("{s}", .{prompt});
        var n: usize = 0;
        while (true) {
            var b: [1]u8 = undefined;
            const got = posix.read(self.in, &b) catch |err| switch (err) {
                error.WouldBlock => {
                    var pfd = [_]posix.pollfd{.{ .fd = self.in, .events = posix.POLL.IN, .revents = 0 }};
                    _ = posix.poll(&pfd, -1) catch {};
                    continue;
                },
                else => return error.EndOfInput,
            };
            if (got == 0) {
                self.write("\r\n");
                return error.EndOfInput;
            }
            const ch = b[0];
            b[0] = 0;
            switch (ch) {
                '\r', '\n' => {
                    self.write("\r\n");
                    return buf[0..n];
                },
                3 => {
                    std.crypto.utils.secureZero(u8, buf[0..n]);
                    self.write("^C\r\n");
                    return error.Cancelled;
                },
                4 => if (n == 0) {
                    self.write("\r\n");
                    return error.Cancelled;
                },
                0x7f, 8 => if (n > 0) {
                    n -= 1;
                    // Drop a whole UTF-8 sequence.
                    while (n > 0 and buf[n] & 0xC0 == 0x80) n -= 1;
                    buf[n] = 0;
                    if (echo) self.write("\x08 \x08");
                },
                0x15 => { // Ctrl+U
                    if (echo) {
                        var i: usize = 0;
                        while (i < n) : (i += 1) if (buf[i] & 0xC0 != 0x80) self.write("\x08 \x08");
                    }
                    std.crypto.utils.secureZero(u8, buf[0..n]);
                    n = 0;
                },
                0x17 => if (echo) { // Ctrl+W (visible prompts only)
                    while (n > 0 and buf[n - 1] == ' ') : (n -= 1) self.write("\x08 \x08");
                    while (n > 0 and buf[n - 1] != ' ') : (n -= 1) if (buf[n - 1] & 0xC0 != 0x80) self.write("\x08 \x08");
                },
                else => if (ch >= 0x20 or ch == '\t') {
                    if (n < buf.len) {
                        buf[n] = ch;
                        n += 1;
                        if (echo) self.write(&.{ch});
                    }
                },
            }
        }
    }

    /// One key from a set, e.g. "yon" for yes/once/no. Enter picks
    /// `default` when non-zero; Ctrl+C returns 0.
    /// "y, o or n" for keys "yon".
    fn keyList(buf: []u8, keys: []const u8) []const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();
        for (keys, 0..) |k, i| {
            if (i > 0) w.writeAll(if (i + 1 == keys.len) " or " else ", ") catch break;
            w.writeByte(k) catch break;
        }
        return fbs.getWritten();
    }

    pub fn choose(self: *Tty, prompt: []const u8, keys: []const u8, default: u8) u8 {
        var buf: [32]u8 = undefined;
        while (true) {
            const line = self.readLine(prompt, true, &buf) catch return 0;
            const word = std.mem.trim(u8, line, " \t");
            if (word.len == 0 and default != 0) return default;
            if (word.len > 0) {
                const k = std.ascii.toLower(word[0]);
                if (std.mem.indexOfScalar(u8, keys, k) != null and (word.len == 1 or isWord(word, k))) return k;
            }
            var lb: [64]u8 = undefined;
            self.print("Please answer {s}.\n", .{keyList(&lb, keys)});
        }
    }

    fn isWord(word: []const u8, k: u8) bool {
        const words = [_][]const u8{ "yes", "no", "once" };
        for (words) |w| if (w[0] == k and std.ascii.eqlIgnoreCase(word, w)) return true;
        return false;
    }
};

/// Text that came from the server (prompt names, instructions): drop
/// control characters so it cannot inject escape sequences.
pub fn sanitize(buf: []u8, s: []const u8) []const u8 {
    var n: usize = 0;
    for (s) |ch| {
        if (n == buf.len) break;
        if (ch == '\n' or ch == '\t' or (ch >= 0x20 and ch != 0x7f)) {
            buf[n] = ch;
            n += 1;
        }
    }
    return buf[0..n];
}

// Styles for prompts drawn in the terminal.
pub const bold = "\x1b[1m";
pub const dim = "\x1b[2m";
pub const yellow = "\x1b[1;33m";
pub const red = "\x1b[1;37;41m";
pub const cyan = "\x1b[36m";
pub const reset = "\x1b[0m";

test "readLine edits and hides secrets" {
    const fds = try posix.pipe();
    const out = try posix.pipe();
    defer for ([_]posix.fd_t{ fds[0], out[0], out[1] }) |f| posix.close(f);
    var tty = Tty{ .in = fds[0], .out = out[1] };
    _ = try posix.write(fds[1], "hunterX\x7f2\r");
    var buf: [64]u8 = undefined;
    const got = try tty.readLine("Password: ", false, &buf);
    try std.testing.expectEqualStrings("hunter2", got);
    var shown: [256]u8 = undefined;
    const n = try posix.read(out[0], &shown);
    // The prompt, then just the newline: the secret never reaches the screen.
    try std.testing.expectEqualStrings("Password: \r\n", shown[0..n]);
    std.crypto.utils.secureZero(u8, &buf);

    _ = try posix.write(fds[1], "abc\x15yes\r");
    try std.testing.expectEqualStrings("yes", try tty.readLine("? ", true, &buf));
    _ = try posix.write(fds[1], "x\x03");
    try std.testing.expectError(error.Cancelled, tty.readLine("? ", false, &buf));
    _ = try posix.write(fds[1], "maybe\rO\r");
    try std.testing.expectEqual(@as(u8, 'o'), tty.choose("[y/o/n] ", "yon", 0));
    _ = try posix.write(fds[1], "\r");
    try std.testing.expectEqual(@as(u8, 'n'), tty.choose("[y/o/N] ", "yon", 'n'));
    posix.close(fds[1]);
}

test "keyList" {
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("y, o or n", Tty.keyList(&b, "yon"));
    try std.testing.expectEqualStrings("y or n", Tty.keyList(&b, "yn"));
}
