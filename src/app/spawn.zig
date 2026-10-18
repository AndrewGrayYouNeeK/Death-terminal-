//! Building the child process for a pane: the user's shell (with the
//! OSC 133 integration injected) or the built-in SSH client.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config/config.zig");
const terminal = @import("../terminal/terminal.zig");
const pty = @import("../terminal/pty.zig");
const shell_inject = @import("shell_inject.zig");
const ssh_target = @import("../ssh/target.zig");

/// How this process was started (re-used for every new pane).
pub const Context = struct {
    config_arg: ?[]const u8 = null,
    lua_unsafe: bool = false,
};

pub const Request = struct {
    /// Starting directory ("" = config.shell.cwd, else inherit).
    cwd: []const u8 = "",
    /// Run the built-in SSH client for this target instead of a shell.
    ssh: ?[]const u8 = null,
};

pub const Spawn = struct {
    opts: pty.ShellOptions,
    /// Per-pane secret for the SSH client's OSC 7799 reports ("" = none).
    nonce: []const u8 = "",
    /// "user@host:port" for SSH panes.
    display: []const u8 = "",
};

pub const Error = error{ SshUnsupported, SshDisabled, SshTarget, OutOfMemory };

/// Options for the child of a pane (memory from `arena`).
pub fn options(arena: std.mem.Allocator, cfg: *const config.Config, ctx: Context, req: Request) Error!Spawn {
    const cwd = if (req.cwd.len > 0) req.cwd else cfg.shell_cwd;
    if (req.ssh) |name| {
        if (builtin.os.tag != .linux) return error.SshUnsupported;
        if (!cfg.ssh_enabled) return error.SshDisabled;
        const t = ssh_target.resolveForConfig(arena, cfg.ssh_profiles.items, cfg.ssh_config_file, cfg.ssh_keepalive_s, name) catch return error.SshTarget;
        var db: [300]u8 = undefined;
        const display = try arena.dupe(u8, t.display(&db));
        // A per-pane secret for the client's connect/disconnect reports
        // (OSC 7799), so remote output can't fake them.
        var nb: [16]u8 = undefined;
        std.crypto.random.bytes(&nb);
        const nonce = try std.fmt.allocPrint(arena, "{s}", .{std.fmt.fmtSliceHexLower(&nb)});
        var env = std.ArrayList([]const u8).init(arena);
        try env.appendSlice(cfg.shell_env.items);
        try env.append(try std.fmt.allocPrint(arena, "DT_SSH_NONCE={s}", .{nonce}));
        var args = std.ArrayList([]const u8).init(arena);
        try args.appendSlice(&.{ "--ssh-session", name });
        if (ctx.config_arg) |c| try args.appendSlice(&.{ "--config", c });
        if (ctx.lua_unsafe) try args.append("--lua-unsafe");
        const exe = std.fs.selfExePathAlloc(arena) catch return error.SshUnsupported;
        return .{
            .opts = .{ .program = exe, .args = args.items, .env = env.items, .cwd = cwd },
            .nonce = nonce,
            .display = display,
        };
    }
    return .{ .opts = shell_inject.apply(arena, .{
        .program = cfg.shell_program,
        .args = cfg.shell_args.items,
        .env = cfg.shell_env.items,
        .cwd = cwd,
    }, cfg.shell_integration) };
}

pub fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.SshUnsupported => "the built-in SSH client is only available on Linux builds for now",
        error.SshDisabled => "the built-in SSH client is disabled (config.ssh.enabled = false)",
        error.SshTarget => "unknown SSH target (expected a profile from config.ssh.profiles, a ~/.ssh/config Host, or user@host[:port])",
        else => @errorName(err),
    };
}

/// A heap-allocated terminal running the pane's child.
pub fn terminalFor(a: std.mem.Allocator, cfg: *const config.Config, ctx: Context, req: Request, rows: u16, cols: u16) !struct { term: *terminal.Terminal, display: []u8 } {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const sp = try options(arena.allocator(), cfg, ctx, req);
    const term = try a.create(terminal.Terminal);
    errdefer a.destroy(term);
    term.* = try terminal.Terminal.initWithShell(a, @max(rows, 1), @max(cols, 1), cfg.scrollback_lines, sp.opts);
    errdefer term.deinit();
    term.setSshNonce(sp.nonce);
    return .{ .term = term, .display = try a.dupe(u8, sp.display) };
}

/// Directory a new pane should start in, taken from `term`'s OSC 7 report
/// (local file:// URIs only, and only if it still exists). "" = none.
pub fn inheritedCwd(term: *const terminal.Terminal, buf: []u8) []const u8 {
    var dir = terminal.shell_integration.cwdFromUri(term.cwd_uri, buf) orelse return "";
    if (!localUri(term.cwd_uri)) return "";
    // Windows: file:///C:/Users/me → C:/Users/me.
    if (builtin.os.tag == .windows and dir.len >= 3 and dir[0] == '/' and dir[2] == ':') dir = dir[1..];
    var d = std.fs.openDirAbsolute(dir, .{}) catch return "";
    d.close();
    return dir;
}

/// file://host/path where host is empty, localhost or this machine.
fn localUri(uri: []const u8) bool {
    const rest = uri["file://".len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return false;
    const host = rest[0..slash];
    if (host.len == 0 or std.mem.eql(u8, host, "localhost")) return true;
    if (builtin.os.tag == .windows) {
        const me = @import("../platform/env.zig").get("COMPUTERNAME") orelse return false;
        return std.ascii.eqlIgnoreCase(host, me);
    }
    var hb: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const me = std.posix.gethostname(&hb) catch return false;
    return std.mem.eql(u8, host, me);
}

test "inheritedCwd: local URIs only" {
    var term = try terminal.Terminal.initBuffer(std.testing.allocator, 2, 10, 0);
    defer term.deinit();
    var buf: [4096]u8 = undefined;
    try std.testing.expectEqualStrings("", inheritedCwd(&term, &buf));
    try term.processOutput("\x1b]7;file://localhost/tmp\x07");
    try std.testing.expectEqualStrings("/tmp", inheritedCwd(&term, &buf));
    try term.processOutput("\x1b]7;file://some-remote-box/tmp\x07");
    try std.testing.expectEqualStrings("", inheritedCwd(&term, &buf));
    try term.processOutput("\x1b]7;file://localhost/definitely/not/here\x07");
    try std.testing.expectEqualStrings("", inheritedCwd(&term, &buf));
}
