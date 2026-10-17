//! What `--ssh <name>` connects to: a Lua profile (config.ssh.profiles),
//! else a ~/.ssh/config Host alias, else "[user@]host[:port]" (or
//! ssh://user@host:port). Profile values win over ~/.ssh/config, which
//! wins over the defaults.

const std = @import("std");
const forward = @import("forward.zig");
const ssh_config = @import("ssh_config.zig");

/// One `config.ssh.profiles.<name>` entry (strings in the config arena).
pub const Profile = struct {
    name: []const u8,
    /// "" = the profile name (which may be a ~/.ssh/config alias).
    host: []const u8 = "",
    /// 0 = from ~/.ssh/config, else 22.
    port: u16 = 0,
    user: []const u8 = "",
    identity_file: []const u8 = "",
    /// ProxyJump syntax: "[user@]host[:port][,...]"; "none" disables a
    /// ~/.ssh/config ProxyJump.
    jump: []const u8 = "",
    /// NAME=value pairs sent with the session (the server's AcceptEnv decides).
    env: []const []const u8 = &.{},
    /// Typed into the remote shell once it starts.
    command: []const u8 = "",
    /// Theme for windows connected to this profile ("" = keep).
    theme: []const u8 = "",
    forwards: []const forward.Forward = &.{},
    /// null = config.ssh.keepalive_s.
    keepalive_s: ?u16 = null,
    reconnect: bool = false,
};

pub const Hop = struct {
    host: []const u8,
    port: u16 = 22,
    user: []const u8,
    identity_files: []const []const u8 = &.{},
};

pub const Target = struct {
    /// What the user picked (profile name / alias / spec), for titles.
    label: []const u8,
    profile: ?[]const u8 = null,
    host: []const u8,
    port: u16 = 22,
    user: []const u8,
    identity_files: []const []const u8 = &.{},
    jumps: []const Hop = &.{},
    env: []const []const u8 = &.{},
    command: []const u8 = "",
    theme: []const u8 = "",
    forwards: []const forward.Forward = &.{},
    keepalive_s: u16 = 30,
    reconnect: bool = false,

    /// "user@host" or "user@host:port".
    pub fn display(self: *const Target, buf: []u8) []const u8 {
        if (self.port == 22) return std.fmt.bufPrint(buf, "{s}@{s}", .{ self.user, self.host }) catch self.host;
        return std.fmt.bufPrint(buf, "{s}@{s}:{d}", .{ self.user, self.host, self.port }) catch self.host;
    }
};

pub const Env = struct {
    home: []const u8,
    local_user: []const u8,
    keepalive_s: u16 = 30,
};

pub const Spec = struct { user: ?[]const u8 = null, host: []const u8, port: ?u16 = null };

pub const SpecError = error{BadTarget};

/// "[user@]host[:port]", "[user@][v6addr]:port", "ssh://[user@]host[:port]".
pub fn parseSpec(spec_in: []const u8) SpecError!Spec {
    var spec = spec_in;
    if (std.mem.startsWith(u8, spec, "ssh://")) spec = std.mem.trimRight(u8, spec[6..], "/");
    var out = Spec{ .host = "" };
    if (std.mem.lastIndexOfScalar(u8, spec, '@')) |at| {
        out.user = spec[0..at];
        if (out.user.?.len == 0) return error.BadTarget;
        spec = spec[at + 1 ..];
    }
    if (spec.len > 0 and spec[0] == '[') {
        const close = std.mem.indexOfScalar(u8, spec, ']') orelse return error.BadTarget;
        out.host = spec[1..close];
        const rest = spec[close + 1 ..];
        if (rest.len > 0) {
            if (rest[0] != ':') return error.BadTarget;
            out.port = std.fmt.parseInt(u16, rest[1..], 10) catch return error.BadTarget;
        }
    } else if (std.mem.indexOfScalar(u8, spec, ':')) |colon| {
        // A bare IPv6 address has several colons: no port then.
        if (std.mem.indexOfScalarPos(u8, spec, colon + 1, ':') != null) {
            out.host = spec;
        } else {
            out.host = spec[0..colon];
            out.port = std.fmt.parseInt(u16, spec[colon + 1 ..], 10) catch return error.BadTarget;
        }
    } else out.host = spec;
    if (out.host.len == 0) return error.BadTarget;
    for (out.host) |ch| if (ch <= ' ' or ch == '/' or ch == '\\') return error.BadTarget;
    if (out.port) |p| if (p == 0) return error.BadTarget;
    return out;
}

pub fn findProfile(profiles: []const Profile, name: []const u8) ?*const Profile {
    for (profiles) |*p| if (std.mem.eql(u8, p.name, name)) return p;
    return null;
}

/// Builds the connection plan. Strings are allocated in `a`.
pub fn resolve(a: std.mem.Allocator, name: []const u8, profiles: []const Profile, cfg: *ssh_config.SshConfig, env: Env) !Target {
    const prof = findProfile(profiles, name);
    var spec: Spec = undefined;
    if (prof) |p| {
        spec = try parseSpec(if (p.host.len > 0) p.host else p.name);
        if (p.user.len > 0) spec.user = p.user;
        if (p.port != 0) spec.port = p.port;
    } else spec = try parseSpec(name);

    const sc = try cfg.resolve(spec.host, .{ .home = env.home, .local_user = env.local_user, .remote_user = spec.user orelse env.local_user, .port = spec.port orelse 22 });
    var t = Target{
        .label = try a.dupe(u8, name),
        .profile = if (prof) |p| p.name else null,
        .host = try a.dupe(u8, sc.hostname orelse spec.host),
        .port = spec.port orelse sc.port orelse 22,
        .user = try a.dupe(u8, spec.user orelse sc.user orelse env.local_user),
        .keepalive_s = env.keepalive_s,
    };

    var ids = std.ArrayList([]const u8).init(a);
    if (prof) |p| if (p.identity_file.len > 0) try ids.append(try ssh_config.expandTokens(a, p.identity_file, .{ .host = t.host, .home = env.home, .local_user = env.local_user, .remote_user = t.user, .port = t.port }));
    for (sc.identity_files) |f| try ids.append(try a.dupe(u8, f));
    if (ids.items.len == 0) try defaultIdentities(a, &ids, env.home);
    t.identity_files = ids.items;

    var jump: []const u8 = sc.proxy_jump orelse "";
    if (prof) |p| if (p.jump.len > 0) {
        jump = if (std.ascii.eqlIgnoreCase(p.jump, "none")) "" else p.jump;
    };
    // Hops use their own ~/.ssh/config IdentityFile, then the profile's key.
    const extra_id: ?[]const u8 = if (prof != null and prof.?.identity_file.len > 0) ids.items[0] else null;
    t.jumps = try resolveJumps(a, jump, cfg, env, extra_id);

    if (prof) |p| {
        t.env = p.env;
        t.command = p.command;
        t.theme = p.theme;
        t.forwards = p.forwards;
        if (p.keepalive_s) |k| t.keepalive_s = k;
        t.reconnect = p.reconnect;
    }
    return t;
}

/// `resolve` with ~/.ssh/config read from `config_file` ("" = none) and
/// $HOME / $USER from the environment.
pub fn resolveForConfig(arena: std.mem.Allocator, profiles: []const Profile, config_file: []const u8, keepalive_s: u16, name: []const u8) !Target {
    const home = std.posix.getenv("HOME") orelse "/";
    const user = std.posix.getenv("USER") orelse std.posix.getenv("LOGNAME") orelse "root";
    var sc = ssh_config.SshConfig.init(arena);
    if (config_file.len > 0) sc.loadFile(config_file, home) catch {};
    return resolve(arena, name, profiles, &sc, .{ .home = home, .local_user = user, .keepalive_s = keepalive_s });
}

/// Host aliases from ~/.ssh/config (no wildcards), for the palette.
pub fn configAliases(arena: std.mem.Allocator, config_file: []const u8, out: *std.ArrayList([]const u8)) void {
    if (config_file.len == 0) return;
    const home = std.posix.getenv("HOME") orelse "/";
    var sc = ssh_config.SshConfig.init(arena);
    sc.loadFile(config_file, home) catch return;
    sc.aliases(out) catch {};
}

fn defaultIdentities(a: std.mem.Allocator, ids: *std.ArrayList([]const u8), home: []const u8) !void {
    for ([_][]const u8{ "id_ed25519", "id_ecdsa", "id_rsa" }) |n| try ids.append(try std.fs.path.join(a, &.{ home, ".ssh", n }));
}

fn resolveJumps(a: std.mem.Allocator, list: []const u8, cfg: *ssh_config.SshConfig, env: Env, extra_id: ?[]const u8) ![]const Hop {
    var hops = std.ArrayList(Hop).init(a);
    var it = std.mem.tokenizeAny(u8, list, ", \t");
    while (it.next()) |item| {
        const s = try parseSpec(item);
        const sc = try cfg.resolve(s.host, .{ .home = env.home, .local_user = env.local_user, .remote_user = s.user orelse env.local_user, .port = s.port orelse 22 });
        var ids = std.ArrayList([]const u8).init(a);
        for (sc.identity_files) |f| try ids.append(try a.dupe(u8, f));
        if (extra_id) |x| try ids.append(x);
        if (sc.identity_files.len == 0) try defaultIdentities(a, &ids, env.home);
        try hops.append(.{
            .host = try a.dupe(u8, sc.hostname orelse s.host),
            .port = s.port orelse sc.port orelse 22,
            .user = try a.dupe(u8, s.user orelse sc.user orelse env.local_user),
            .identity_files = ids.items,
        });
        if (hops.items.len >= 8) return error.TooManyJumps;
    }
    return hops.items;
}

// ------------------------------------------------------------------- tests

const t_ = std.testing;

test "parseSpec" {
    const a = try parseSpec("andrew@example.com:2222");
    try t_.expectEqualStrings("andrew", a.user.?);
    try t_.expectEqualStrings("example.com", a.host);
    try t_.expectEqual(@as(u16, 2222), a.port.?);
    const b = try parseSpec("host");
    try t_.expect(b.user == null and b.port == null);
    const c = try parseSpec("ssh://me@[::1]:22/");
    try t_.expectEqualStrings("::1", c.host);
    try t_.expectEqual(@as(u16, 22), c.port.?);
    const d = try parseSpec("fe80::1");
    try t_.expectEqualStrings("fe80::1", d.host);
    try t_.expectError(error.BadTarget, parseSpec("@host"));
    try t_.expectError(error.BadTarget, parseSpec("host:x"));
    try t_.expectError(error.BadTarget, parseSpec("a b"));
    try t_.expectError(error.BadTarget, parseSpec(""));
}

test "resolve: profile over ssh_config over defaults" {
    var arena = std.heap.ArenaAllocator.init(t_.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg = ssh_config.SshConfig.init(t_.allocator);
    defer cfg.deinit();
    try cfg.parseString(
        \\Host work
        \\  HostName work.example.com
        \\  User cfguser
        \\  Port 2200
        \\  ProxyJump bastion
        \\Host bastion
        \\  HostName 10.1.1.1
        \\  User hop
        \\  IdentityFile ~/.ssh/hop_key
    );
    const env = Env{ .home = "/h", .local_user = "me", .keepalive_s = 30 };
    const fwd = [_]forward.Forward{try forward.parse("L 8080:localhost:80")};
    const profiles = [_]Profile{
        .{ .name = "prod", .host = "work", .user = "andrew", .identity_file = "~/.ssh/prod_%r", .env = &.{"LANG=C"}, .command = "tmux a", .theme = "dracula", .forwards = &fwd, .keepalive_s = 5, .reconnect = true },
        .{ .name = "direct", .host = "work", .jump = "none" },
    };
    const p = try resolve(a, "prod", &profiles, &cfg, env);
    try t_.expectEqualStrings("work.example.com", p.host);
    try t_.expectEqualStrings("andrew", p.user);
    try t_.expectEqual(@as(u16, 2200), p.port);
    try t_.expectEqualStrings("/h/.ssh/prod_andrew", p.identity_files[0]);
    try t_.expectEqual(@as(usize, 1), p.jumps.len);
    try t_.expectEqualStrings("10.1.1.1", p.jumps[0].host);
    try t_.expectEqualStrings("hop", p.jumps[0].user);
    try t_.expectEqualStrings("/h/.ssh/hop_key", p.jumps[0].identity_files[0]);
    try t_.expectEqualStrings("/h/.ssh/prod_andrew", p.jumps[0].identity_files[1]);
    try t_.expectEqualStrings("dracula", p.theme);
    try t_.expectEqual(@as(u16, 5), p.keepalive_s);
    try t_.expect(p.reconnect);
    var buf: [64]u8 = undefined;
    try t_.expectEqualStrings("andrew@work.example.com:2200", p.display(&buf));

    const d = try resolve(a, "direct", &profiles, &cfg, env);
    try t_.expectEqual(@as(usize, 0), d.jumps.len);
    try t_.expectEqualStrings("cfguser", d.user);

    // ssh_config alias, then a plain spec with defaults.
    const w = try resolve(a, "root@work", &profiles, &cfg, env);
    try t_.expectEqualStrings("root", w.user);
    try t_.expectEqualStrings("work.example.com", w.host);
    const plain = try resolve(a, "box.lan", &profiles, &cfg, env);
    try t_.expectEqualStrings("me", plain.user);
    try t_.expectEqual(@as(u16, 22), plain.port);
    try t_.expectEqual(@as(usize, 3), plain.identity_files.len);
    try t_.expectEqualStrings("/h/.ssh/id_ed25519", plain.identity_files[0]);
    const j = try resolve(a, "x@y:2", &.{}, &cfg, .{ .home = "/h", .local_user = "me" });
    try t_.expectEqual(@as(u16, 2), j.port);
}
