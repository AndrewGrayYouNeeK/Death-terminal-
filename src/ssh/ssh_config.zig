//! A reader for the basics of OpenSSH's ~/.ssh/config: Host blocks with
//! wildcard / negated patterns, HostName, User, Port, IdentityFile,
//! ProxyJump and Include (globs, relative to ~/.ssh). Match blocks are
//! skipped; unknown keywords are ignored. As in OpenSSH, the first value
//! obtained for each keyword wins, except IdentityFile, which accumulates.

const std = @import("std");

pub const Entry = struct {
    /// Patterns of the enclosing Host line ("*" before any Host line;
    /// null inside a Match block, which never applies).
    patterns: ?[]const u8,
    /// Lower-cased keyword.
    key: []const u8,
    value: []const u8,
};

pub const Resolved = struct {
    hostname: ?[]const u8 = null,
    user: ?[]const u8 = null,
    port: ?u16 = null,
    identity_files: []const []const u8 = &.{},
    proxy_jump: ?[]const u8 = null,
};

pub const SshConfig = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayListUnmanaged(Entry) = .{},
    /// Directory relative Include paths are resolved against (~/.ssh).
    base_dir: []const u8 = "",

    pub fn init(allocator: std.mem.Allocator) SshConfig {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *SshConfig) void {
        self.arena.deinit();
    }

    /// Reads `path` ("~" expanded); a missing file is not an error.
    pub fn loadFile(self: *SshConfig, path: []const u8, home: []const u8) !void {
        const a = self.arena.allocator();
        if (self.base_dir.len == 0) self.base_dir = try std.fs.path.join(a, &.{ home, ".ssh" });
        const full = try expandTilde(a, path, home);
        try self.loadPath(full, home, null, 0);
    }

    pub fn parseString(self: *SshConfig, text: []const u8) !void {
        try self.parse(text, "", null, 0);
    }

    fn loadPath(self: *SshConfig, path: []const u8, home: []const u8, ctx: ?[]const u8, depth: u8) anyerror!void {
        const a = self.arena.allocator();
        const text = std.fs.cwd().readFileAlloc(a, path, 1 << 20) catch |err| switch (err) {
            error.FileNotFound, error.IsDir, error.AccessDenied, error.NotDir => return,
            else => return err,
        };
        try self.parse(text, home, ctx, depth);
    }

    fn parse(self: *SshConfig, text: []const u8, home: []const u8, start_ctx: ?[]const u8, depth: u8) anyerror!void {
        const a = self.arena.allocator();
        var patterns: ?[]const u8 = start_ctx orelse "*";
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            var key_end: usize = 0;
            while (key_end < line.len and line[key_end] != ' ' and line[key_end] != '\t' and line[key_end] != '=') key_end += 1;
            const key = try std.ascii.allocLowerString(a, line[0..key_end]);
            var rest = std.mem.trimLeft(u8, line[key_end..], " \t");
            if (rest.len > 0 and rest[0] == '=') rest = std.mem.trimLeft(u8, rest[1..], " \t");
            if (std.mem.eql(u8, key, "host")) {
                patterns = rest;
                continue;
            }
            if (std.mem.eql(u8, key, "match")) {
                patterns = null;
                continue;
            }
            if (std.mem.eql(u8, key, "include")) {
                if (depth >= 16 or patterns == null) continue;
                var words = Words{ .s = rest };
                while (words.next()) |w| try self.include(w, home, patterns, depth);
                continue;
            }
            var words = Words{ .s = rest };
            const value = words.next() orelse continue;
            const v = if (std.mem.eql(u8, key, "proxyjump")) unquote(rest) else value;
            try self.entries.append(a, .{ .patterns = patterns, .key = key, .value = v });
        }
    }

    fn include(self: *SshConfig, pattern: []const u8, home: []const u8, ctx: ?[]const u8, depth: u8) !void {
        const a = self.arena.allocator();
        var path = try expandTilde(a, pattern, home);
        if (!std.fs.path.isAbsolute(path)) path = try std.fs.path.join(a, &.{ self.base_dir, path });
        const dir_path = std.fs.path.dirname(path) orelse "/";
        const base = std.fs.path.basename(path);
        if (std.mem.indexOfAny(u8, dir_path, "*?") != null) return; // globs only in the last component
        if (std.mem.indexOfAny(u8, base, "*?") == null) return self.loadPath(path, home, ctx, depth + 1);
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
        defer dir.close();
        var names = std.ArrayList([]const u8).init(a);
        var it = dir.iterate();
        while (try it.next()) |e| {
            if (e.kind == .directory) continue;
            if (wildMatch(base, e.name)) try names.append(try a.dupe(u8, e.name));
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        for (names.items) |n| try self.loadPath(try std.fs.path.join(a, &.{ dir_path, n }), home, ctx, depth + 1);
    }

    /// Settings for `alias` (what the user typed). Strings live in the
    /// config's arena; %h/%u/%r/%p/%d and ~ are expanded in IdentityFile.
    pub fn resolve(self: *SshConfig, alias: []const u8, ctx: Expand) !Resolved {
        const a = self.arena.allocator();
        var r = Resolved{};
        var ids = std.ArrayList([]const u8).init(a);
        for (self.entries.items) |e| {
            const pats = e.patterns orelse continue;
            if (!hostMatches(pats, alias)) continue;
            if (std.mem.eql(u8, e.key, "hostname")) {
                if (r.hostname == null) r.hostname = e.value;
            } else if (std.mem.eql(u8, e.key, "user")) {
                if (r.user == null) r.user = e.value;
            } else if (std.mem.eql(u8, e.key, "port")) {
                if (r.port == null) r.port = std.fmt.parseInt(u16, e.value, 10) catch null;
            } else if (std.mem.eql(u8, e.key, "proxyjump")) {
                if (r.proxy_jump == null) r.proxy_jump = e.value;
            } else if (std.mem.eql(u8, e.key, "identityfile")) {
                try ids.append(e.value);
            }
        }
        if (r.hostname) |h| r.hostname = try expandTokens(a, h, .{ .host = alias, .home = ctx.home, .local_user = ctx.local_user, .remote_user = ctx.remote_user, .port = ctx.port });
        if (r.proxy_jump) |pj| if (std.ascii.eqlIgnoreCase(pj, "none")) {
            r.proxy_jump = "";
        };
        const host = r.hostname orelse alias;
        const ruser = r.user orelse ctx.remote_user;
        for (ids.items) |*p| p.* = try expandTokens(a, p.*, .{ .host = host, .home = ctx.home, .local_user = ctx.local_user, .remote_user = ruser, .port = r.port orelse ctx.port });
        r.identity_files = ids.items;
        return r;
    }

    /// Host aliases without wildcards, for the profile picker.
    pub fn aliases(self: *SshConfig, out: *std.ArrayList([]const u8)) !void {
        var seen = std.StringHashMap(void).init(out.allocator);
        defer seen.deinit();
        for (self.entries.items) |e| {
            const pats = e.patterns orelse continue;
            var w = Words{ .s = pats };
            while (w.next()) |p| {
                if (p.len == 0 or p[0] == '!' or std.mem.indexOfAny(u8, p, "*?") != null) continue;
                if (seen.contains(p)) continue;
                try seen.put(p, {});
                try out.append(p);
            }
        }
    }
};

pub const Expand = struct {
    host: []const u8 = "",
    home: []const u8 = "",
    local_user: []const u8 = "",
    remote_user: []const u8 = "",
    port: u16 = 22,
};

pub fn expandTilde(a: std.mem.Allocator, path: []const u8, home: []const u8) ![]const u8 {
    if (std.mem.eql(u8, path, "~")) return a.dupe(u8, home);
    if (std.mem.startsWith(u8, path, "~/")) return std.fs.path.join(a, &.{ home, path[2..] });
    return a.dupe(u8, path);
}

pub fn expandTokens(a: std.mem.Allocator, s: []const u8, x: Expand) ![]const u8 {
    var out = std.ArrayList(u8).init(a);
    var i: usize = 0;
    if (std.mem.startsWith(u8, s, "~/") or std.mem.eql(u8, s, "~")) {
        try out.appendSlice(x.home);
        i = 1;
    }
    while (i < s.len) : (i += 1) {
        if (s[i] != '%' or i + 1 >= s.len) {
            try out.append(s[i]);
            continue;
        }
        i += 1;
        switch (s[i]) {
            'h' => try out.appendSlice(x.host),
            'u' => try out.appendSlice(x.local_user),
            'r' => try out.appendSlice(x.remote_user),
            'd' => try out.appendSlice(x.home),
            'p' => try out.writer().print("{d}", .{x.port}),
            '%' => try out.append('%'),
            else => {
                try out.append('%');
                try out.append(s[i]);
            },
        }
    }
    return out.items;
}

/// Whitespace-separated words; double quotes group.
const Words = struct {
    s: []const u8,
    i: usize = 0,
    fn next(self: *Words) ?[]const u8 {
        while (self.i < self.s.len and (self.s[self.i] == ' ' or self.s[self.i] == '\t')) self.i += 1;
        if (self.i >= self.s.len) return null;
        if (self.s[self.i] == '"') {
            const start = self.i + 1;
            const end = std.mem.indexOfScalarPos(u8, self.s, start, '"') orelse self.s.len;
            self.i = @min(end + 1, self.s.len);
            return self.s[start..end];
        }
        const start = self.i;
        while (self.i < self.s.len and self.s[self.i] != ' ' and self.s[self.i] != '\t') self.i += 1;
        return self.s[start..self.i];
    }
};

fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1 .. s.len - 1];
    return s;
}

/// A Host line applies when any pattern matches and no negated one does.
pub fn hostMatches(patterns: []const u8, host: []const u8) bool {
    var any = false;
    var it = std.mem.tokenizeAny(u8, patterns, " \t,");
    while (it.next()) |raw| {
        const p = unquote(raw);
        if (p.len > 0 and p[0] == '!') {
            if (wildMatchIgnoreCase(p[1..], host)) return false;
        } else if (wildMatchIgnoreCase(p, host)) any = true;
    }
    return any;
}

fn wildMatchIgnoreCase(p: []const u8, s: []const u8) bool {
    var pb: [256]u8 = undefined;
    var sb: [256]u8 = undefined;
    if (p.len > pb.len or s.len > sb.len) return false;
    return wildMatch(std.ascii.lowerString(&pb, p), std.ascii.lowerString(&sb, s));
}

/// `*` and `?` globbing.
pub fn wildMatch(p: []const u8, s: []const u8) bool {
    var pi: usize = 0;
    var si: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;
    while (si < s.len) {
        if (pi < p.len and (p[pi] == '?' or p[pi] == s[si])) {
            pi += 1;
            si += 1;
        } else if (pi < p.len and p[pi] == '*') {
            star = pi;
            pi += 1;
            mark = si;
        } else if (star) |st| {
            pi = st + 1;
            mark += 1;
            si = mark;
        } else return false;
    }
    while (pi < p.len and p[pi] == '*') pi += 1;
    return pi == p.len;
}

// ------------------------------------------------------------------- tests

const t = std.testing;

test "ssh_config: host patterns, first value wins, identity files accumulate" {
    var cfg = SshConfig.init(t.allocator);
    defer cfg.deinit();
    try cfg.parseString(
        \\# global
        \\IdentityFile ~/.ssh/global_%r
        \\Host web*.example.com !web9.example.com
        \\  User deploy
        \\  Port=2200
        \\Host bastion
        \\  HostName 10.0.0.1
        \\  User jump
        \\Host db
        \\  HostName %h.internal
        \\  ProxyJump bastion,jump2:2222
        \\  IdentityFile ~/.ssh/id_%h
        \\Match host db
        \\  User wrong
        \\Host *
        \\  User fallback
        \\  Port 22
    );
    const x = Expand{ .home = "/home/me", .local_user = "me", .remote_user = "me" };
    const w = try cfg.resolve("web1.example.com", x);
    try t.expectEqualStrings("deploy", w.user.?);
    try t.expectEqual(@as(u16, 2200), w.port.?);
    try t.expectEqual(@as(usize, 1), w.identity_files.len);
    try t.expectEqualStrings("/home/me/.ssh/global_deploy", w.identity_files[0]);

    const w9 = try cfg.resolve("WEB9.example.com", x);
    try t.expectEqualStrings("fallback", w9.user.?);
    try t.expectEqual(@as(u16, 22), w9.port.?);

    const db = try cfg.resolve("db", x);
    try t.expectEqualStrings("db.internal", db.hostname.?);
    try t.expectEqualStrings("bastion,jump2:2222", db.proxy_jump.?);
    try t.expectEqualStrings("fallback", db.user.?);
    try t.expectEqual(@as(usize, 2), db.identity_files.len);
    try t.expectEqualStrings("/home/me/.ssh/id_db.internal", db.identity_files[1]);

    var names = std.ArrayList([]const u8).init(t.allocator);
    defer names.deinit();
    try cfg.aliases(&names);
    try t.expectEqual(@as(usize, 2), names.items.len);
    try t.expectEqualStrings("bastion", names.items[0]);
    try t.expectEqualStrings("db", names.items[1]);
}

test "ssh_config: Include with globs relative to ~/.ssh" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath(".ssh/conf.d");
    try tmp.dir.writeFile(.{ .sub_path = ".ssh/config", .data = "Include conf.d/*.conf\nHost *\n  User last\n" });
    try tmp.dir.writeFile(.{ .sub_path = ".ssh/conf.d/b.conf", .data = "Host box\n  Port 2022\n" });
    try tmp.dir.writeFile(.{ .sub_path = ".ssh/conf.d/a.conf", .data = "Host box\n  HostName box.lan\n  Port 1111\n" });
    try tmp.dir.writeFile(.{ .sub_path = ".ssh/conf.d/skip.txt", .data = "Host box\n  User nope\n" });
    const home = try tmp.dir.realpathAlloc(t.allocator, ".");
    defer t.allocator.free(home);
    var cfg = SshConfig.init(t.allocator);
    defer cfg.deinit();
    try cfg.loadFile("~/.ssh/config", home);
    const r = try cfg.resolve("box", .{ .home = home });
    try t.expectEqualStrings("box.lan", r.hostname.?);
    try t.expectEqual(@as(u16, 1111), r.port.?); // a.conf sorts first
    try t.expectEqualStrings("last", r.user.?);
    // A missing file is fine.
    var none = SshConfig.init(t.allocator);
    defer none.deinit();
    try none.loadFile("~/.ssh/nope", home);
    try t.expect((try none.resolve("x", .{})).hostname == null);
}

test "wildMatch" {
    try t.expect(wildMatch("*", "anything"));
    try t.expect(wildMatch("a?c", "abc"));
    try t.expect(!wildMatch("a?c", "abbc"));
    try t.expect(wildMatch("*.conf", "x.conf"));
    try t.expect(!wildMatch("*.conf", "x.conf.bak"));
    try t.expect(hostMatches("a b,c", "c"));
    try t.expect(!hostMatches("* !secret", "secret"));
}
