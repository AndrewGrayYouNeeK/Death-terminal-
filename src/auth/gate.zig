//! The sign-in gate. Every pane's child is started as
//! `deathterminal --auth-gate -- <shell or ssh client> [args...]`: with a
//! valid saved session the gate execs the command at once; otherwise the
//! pane shows the sign-up / log-in screen first, so no shell ever starts
//! signed out.
//!
//! Offline: an account is required once. After that a saved session is
//! trusted offline even when its access token has expired; it is dropped
//! only when the server rejects the refresh token (revoked, signed out
//! elsewhere, account deleted).

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const env_mod = @import("../platform/env.zig");
const supabase = @import("supabase.zig");
const store = @import("store.zig");

pub const Session = supabase.Session;

/// Compiled with `-Dauth=false`: no gate at all (developer builds).
pub const required = build_options.auth_required;

pub const flag = "--auth-gate";

/// Refresh this many seconds before the access token expires.
const refresh_margin_s = 120;

pub const Check = union(enum) {
    /// Signed in. `offline` = the token could not be refreshed for lack of
    /// a network, and the cached session was used.
    ok: struct { session: Session, offline: bool },
    signed_out,
};

/// The saved session, refreshed when it is close to expiry.
pub fn check(arena: std.mem.Allocator, project: supabase.Project) Check {
    const s = store.load(arena) orelse return .signed_out;
    if (s.expires_at - std.time.timestamp() > refresh_margin_s) return .{ .ok = .{ .session = s, .offline = false } };
    switch (supabase.refresh(arena, project, s.refresh_token)) {
        .session => |fresh| {
            var n = fresh;
            if (n.email.len == 0) n.email = s.email;
            if (n.user_id.len == 0) n.user_id = s.user_id;
            store.save(arena, n) catch {};
            return .{ .ok = .{ .session = n, .offline = false } };
        },
        .unreachable_ => return .{ .ok = .{ .session = s, .offline = true } },
        .rejected, .confirm_email => {
            store.clear(arena);
            return .signed_out;
        },
    }
}

// ---------------------------------------------------------------- screen

const green = "\x1b[1;92m";
const dim = "\x1b[32m";
const red = "\x1b[1;91m";
const reset = "\x1b[0m";

const skull =
    green ++ "            ▄▄██████████▄▄\n" ++
    "          ▄████████████████▄\n" ++
    "         ████████████████████\n" ++
    "         ███▀    ████    ▀███\n" ++
    "         ███▄   ▄█▀▀█▄   ▄███\n" ++
    "          ▀█████▀ ▄▄ ▀█████▀\n" ++
    "            ▀███▄▄▄▄▄▄███▀\n" ++
    dim ++ "             █▌█▌█▌█▌█▌█▌\n" ++
    "             ▀▀▀▀▀▀▀▀▀▀▀▀\n" ++
    green ++ "         >-\n" ++ reset;

const Io = struct {
    out: std.fs.File.Writer,
    in: std.fs.File,

    fn print(self: Io, comptime fmt: []const u8, args: anytype) void {
        self.out.print(fmt, args) catch {};
    }

    /// One line from the keyboard (null at EOF).
    fn line(self: Io, buf: []u8) ?[]const u8 {
        const got = self.in.reader().readUntilDelimiterOrEof(buf, '\n') catch |err| switch (err) {
            error.StreamTooLong => {
                // Drain the rest of the line.
                while (true) {
                    const b = self.in.reader().readByte() catch return null;
                    if (b == '\n') break;
                }
                return "";
            },
            else => return null,
        } orelse return null;
        return std.mem.trim(u8, got, " \t\r");
    }

    fn prompt(self: Io, label: []const u8, buf: []u8) ?[]const u8 {
        self.print(green ++ "  {s}" ++ reset, .{label});
        return self.line(buf);
    }

    fn secret(self: Io, label: []const u8, buf: []u8) ?[]const u8 {
        self.print(green ++ "  {s}" ++ reset, .{label});
        const restore = echoOff(self.in);
        defer {
            echoRestore(self.in, restore);
            self.print("\n", .{});
        }
        const got = self.in.reader().readUntilDelimiterOrEof(buf, '\n') catch return null;
        const s = got orelse return null;
        return std.mem.trimRight(u8, s, "\r");
    }
};

const EchoState = if (builtin.os.tag == .windows) ?u32 else ?std.posix.termios;

fn echoOff(f: std.fs.File) EchoState {
    if (builtin.os.tag == .windows) {
        const k = std.os.windows.kernel32;
        var mode: u32 = 0;
        if (k.GetConsoleMode(f.handle, &mode) == 0) return null;
        const ENABLE_ECHO_INPUT: u32 = 0x0004;
        _ = k.SetConsoleMode(f.handle, mode & ~ENABLE_ECHO_INPUT);
        return mode;
    } else {
        const old = std.posix.tcgetattr(f.handle) catch return null;
        var t = old;
        t.lflag.ECHO = false;
        std.posix.tcsetattr(f.handle, .NOW, t) catch return null;
        return old;
    }
}

fn echoRestore(f: std.fs.File, st: EchoState) void {
    const old = st orelse return;
    if (builtin.os.tag == .windows) {
        _ = std.os.windows.kernel32.SetConsoleMode(f.handle, old);
    } else {
        std.posix.tcsetattr(f.handle, .NOW, old) catch {};
    }
}

fn header(io: Io, note: []const u8, note_color: []const u8) void {
    io.print("\x1b[2J\x1b[H\n{s}\n" ++ green ++ "     YouNeeK Death Terminal" ++ reset ++ "\n" ++
        dim ++ "     The terminal you'll never leave." ++ reset ++ "\n\n", .{skull});
    if (note.len > 0) io.print("  {s}{s}" ++ reset ++ "\n\n", .{ note_color, note });
}

fn validEmail(e: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, e, '@') orelse return false;
    return at > 0 and std.mem.indexOfScalarPos(u8, e, at + 1, '.') != null and std.mem.indexOfAny(u8, e, " \t") == null and e.len < 256;
}

const min_password = 8;

/// Interactive sign-in. Returns the new session, or null if the user quit
/// (or stdin closed).
pub fn interactive(arena: std.mem.Allocator, project: supabase.Project) ?Session {
    const io = Io{ .out = std.io.getStdOut().writer(), .in = std.io.getStdIn() };
    var note: []const u8 = "Sign in or create a free account to start.";
    var note_color: []const u8 = dim;
    var email_buf: [320]u8 = undefined;
    var pw_buf: [256]u8 = undefined;
    var pw2_buf: [256]u8 = undefined;
    var choice_buf: [64]u8 = undefined;
    defer {
        std.crypto.utils.secureZero(u8, &pw_buf);
        std.crypto.utils.secureZero(u8, &pw2_buf);
    }
    while (true) {
        header(io, note, note_color);
        io.print(green ++ "  [1]" ++ reset ++ " Log in\n" ++
            green ++ "  [2]" ++ reset ++ " Create account\n" ++
            green ++ "  [3]" ++ reset ++ " Forgot password\n" ++
            green ++ "  [q]" ++ reset ++ " Quit\n\n", .{});
        const c = io.prompt("> ", &choice_buf) orelse return null;
        note_color = red;
        if (c.len == 0) {
            note_color = dim;
            continue;
        }
        switch (std.ascii.toLower(c[0])) {
            '1', 'l' => {
                header(io, "Log in", green);
                const email = io.prompt("Email:    ", &email_buf) orelse return null;
                if (!validEmail(email)) {
                    note = "That doesn't look like an email address.";
                    continue;
                }
                const pw = io.secret("Password: ", &pw_buf) orelse return null;
                if (pw.len == 0) {
                    note = "Enter your password.";
                    continue;
                }
                io.print(dim ++ "\n  Signing in...\n" ++ reset, .{});
                switch (supabase.logIn(arena, project, email, pw)) {
                    .session => |s| return s,
                    .rejected => |m| note = m,
                    .unreachable_ => |m| note = std.fmt.allocPrint(arena, "Can't reach the sign-in server: {s}. Signing in needs the internet the first time.", .{m}) catch "Can't reach the sign-in server.",
                    .confirm_email => note = "Confirm your email first, then log in.",
                }
            },
            '2', 'c' => {
                header(io, "Create your account", green);
                const email = io.prompt("Email:            ", &email_buf) orelse return null;
                if (!validEmail(email)) {
                    note = "That doesn't look like an email address.";
                    continue;
                }
                const pw = io.secret("Password (8+):    ", &pw_buf) orelse return null;
                if (pw.len < min_password) {
                    note = "Use a password of at least 8 characters.";
                    continue;
                }
                const pw2 = io.secret("Confirm password: ", &pw2_buf) orelse return null;
                if (!std.mem.eql(u8, pw, pw2)) {
                    note = "The passwords don't match.";
                    continue;
                }
                io.print(dim ++ "\n  Creating your account...\n" ++ reset, .{});
                switch (supabase.signUp(arena, project, email, pw)) {
                    .session => |s| return s,
                    .confirm_email => {
                        note = std.fmt.allocPrint(arena, "Almost there: we emailed a confirmation link to {s}. Click it, then choose [1] Log in.", .{email}) catch "Check your email for a confirmation link, then log in.";
                        note_color = green;
                    },
                    .rejected => |m| note = m,
                    .unreachable_ => |m| note = std.fmt.allocPrint(arena, "Can't reach the sign-in server: {s}.", .{m}) catch "Can't reach the sign-in server.",
                }
            },
            '3', 'f' => {
                header(io, "Reset your password", green);
                const email = io.prompt("Email: ", &email_buf) orelse return null;
                if (!validEmail(email)) {
                    note = "That doesn't look like an email address.";
                    continue;
                }
                if (supabase.recover(arena, project, email)) |m| {
                    note = m;
                } else {
                    note = "If that email has an account, a password reset link is on its way.";
                    note_color = green;
                }
            },
            'q' => return null,
            else => {
                note = "Choose 1, 2, 3 or q.";
            },
        }
    }
}

// ---------------------------------------------------------------- entry

fn isTty() bool {
    return std.io.getStdIn().isTty();
}

/// Signed in (cached or new), or null when the user quit.
pub fn ensure(arena: std.mem.Allocator, project: supabase.Project) ?Session {
    switch (check(arena, project)) {
        .ok => |ok| return ok.session,
        .signed_out => {},
    }
    if (!isTty()) {
        std.io.getStdErr().writeAll("deathterminal: sign in required. Run `deathterminal --login` in a terminal.\n") catch {};
        return null;
    }
    const s = interactive(arena, project) orelse return null;
    store.save(arena, s) catch |err| {
        std.io.getStdErr().writer().print("deathterminal: signed in, but could not save the session ({s}); you will be asked again next time.\n", .{@errorName(err)}) catch {};
    };
    std.io.getStdOut().writeAll("\x1b[2J\x1b[H") catch {};
    return s;
}

/// `deathterminal --auth-gate [-- cmd args...]`.
pub fn main(a: std.mem.Allocator, args: []const []const u8) u8 {
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cmd: []const []const u8 = &.{};
    for (args, 0..) |x, i| if (std.mem.eql(u8, x, "--")) {
        cmd = args[i + 1 ..];
        break;
    };
    if (required) {
        // Quit on the sign-in screen closes the pane; no terminal at all is an error.
        _ = ensure(arena, .{}) orelse return if (isTty()) 0 else 1;
    }
    return exec(arena, cmd);
}

fn exec(arena: std.mem.Allocator, cmd: []const []const u8) u8 {
    var argv = std.ArrayList([]const u8).init(arena);
    const prog: []const u8 = if (cmd.len > 0 and cmd[0].len > 0) cmd[0] else if (builtin.os.tag == .windows)
        @import("../terminal/pty_windows.zig").defaultShell(arena) catch "cmd.exe"
    else
        env_mod.get("SHELL") orelse "/bin/sh";
    argv.append(prog) catch return 1;
    if (cmd.len > 1) argv.appendSlice(cmd[1..]) catch return 1;
    if (builtin.os.tag == .windows) {
        var child = std.process.Child.init(argv.items, arena);
        const term = child.spawnAndWait() catch |err| {
            std.debug.print("deathterminal: cannot start {s}: {s}\n", .{ prog, @errorName(err) });
            return 1;
        };
        return switch (term) {
            .Exited => |c| c,
            else => 1,
        };
    }
    const err = std.process.execv(arena, argv.items);
    std.debug.print("deathterminal: cannot start {s}: {s}\n", .{ prog, @errorName(err) });
    return 127;
}

/// `deathterminal --login`: sign in (or show who is signed in).
pub fn loginCli(a: std.mem.Allocator) u8 {
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const s = ensure(arena_state.allocator(), .{}) orelse return 1;
    std.io.getStdOut().writer().print("Signed in as {s}\n", .{s.email}) catch {};
    return 0;
}

/// `deathterminal --whoami`.
pub fn whoamiCli(a: std.mem.Allocator) u8 {
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const w = std.io.getStdOut().writer();
    switch (check(arena_state.allocator(), .{})) {
        .ok => |ok| {
            w.print("Signed in as {s}{s}\n", .{ ok.session.email, if (ok.offline) " (offline; using the saved session)" else "" }) catch {};
            return 0;
        },
        .signed_out => {
            w.writeAll("Signed out. Run `deathterminal --login`.\n") catch {};
            return 1;
        },
    }
}

/// `deathterminal --sign-out` (alias `--logout`).
pub fn signOutCli(a: std.mem.Allocator) u8 {
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const w = std.io.getStdOut().writer();
    const s = store.load(arena) orelse {
        w.writeAll("Already signed out.\n") catch {};
        return 0;
    };
    _ = supabase.logOut(arena, .{}, s.access_token);
    store.clear(arena);
    if (store.load(arena) != null) {
        std.io.getStdErr().writeAll("deathterminal: could not remove the saved session\n") catch {};
        return 1;
    }
    w.print("Signed out {s}. New tabs and windows will ask you to log in.\n", .{s.email}) catch {};
    return 0;
}

test "email check" {
    try std.testing.expect(validEmail("a@b.co"));
    try std.testing.expect(!validEmail("ab.co"));
    try std.testing.expect(!validEmail("@b.co"));
    try std.testing.expect(!validEmail("a@bco"));
    try std.testing.expect(!validEmail("a b@c.io"));
}
