//! Where the signed-in session lives.
//!
//!   macOS    the login Keychain (generic password, service below), written
//!            through /usr/bin/security with the secret on stdin, never argv
//!   others   $XDG_CONFIG_HOME/death-terminal/session.json (mode 0600;
//!            %APPDATA%\death-terminal\session.json on Windows)
//!
//! If the Keychain cannot be written, macOS falls back to the 0600 file.
//! `DT_AUTH_SESSION_FILE` forces the file store at that path (tests).

const std = @import("std");
const builtin = @import("builtin");
const env_mod = @import("../platform/env.zig");
const paths = @import("../muscle/paths.zig");
const supabase = @import("supabase.zig");

pub const Session = supabase.Session;

pub const keychain_service = "com.github.andrewgrayyouneek.deathterminal.auth";
const keychain_account = "session";
const security = "/usr/bin/security";

fn useKeychain() bool {
    return builtin.os.tag == .macos and env_mod.get("DT_AUTH_SESSION_FILE") == null;
}

/// The session file path (file store only).
pub fn filePath(a: std.mem.Allocator) ![]u8 {
    if (env_mod.get("DT_AUTH_SESSION_FILE")) |p| if (p.len > 0) return a.dupe(u8, p);
    const win = builtin.os.tag == .windows;
    const home = env_mod.home() orelse return error.NoHome;
    const config_home = blk: {
        if (win) if (env_mod.get("APPDATA")) |x| break :blk try a.dupe(u8, x);
        if (env_mod.get("XDG_CONFIG_HOME")) |v| if (v.len > 0 and std.fs.path.isAbsolute(v)) break :blk try a.dupe(u8, v);
        break :blk try std.fs.path.join(a, &.{ home, ".config" });
    };
    defer a.free(config_home);
    return std.fs.path.join(a, &.{ config_home, "death-terminal", "session.json" });
}

pub fn encode(a: std.mem.Allocator, s: Session) ![]u8 {
    return std.json.stringifyAlloc(a, s, .{});
}

pub fn decode(arena: std.mem.Allocator, data: []const u8) ?Session {
    const s = std.json.parseFromSliceLeaky(Session, arena, std.mem.trim(u8, data, " \r\n\t"), .{ .ignore_unknown_fields = true }) catch return null;
    if (s.access_token.len == 0 or s.refresh_token.len == 0) return null;
    return s;
}

/// The saved session, or null when signed out.
pub fn load(arena: std.mem.Allocator) ?Session {
    if (useKeychain()) return loadKeychain(arena) orelse loadFile(arena);
    return loadFile(arena);
}

fn loadKeychain(arena: std.mem.Allocator) ?Session {
    {
        const r = std.process.Child.run(.{
            .allocator = arena,
            .argv = &.{ security, "find-generic-password", "-s", keychain_service, "-a", keychain_account, "-w" },
            .max_output_bytes = 64 * 1024,
        }) catch return null;
        if (r.term != .Exited or r.term.Exited != 0) return null;
        const b64 = std.mem.trim(u8, r.stdout, " \r\n\t");
        const dec = std.base64.standard.Decoder;
        const n = dec.calcSizeForSlice(b64) catch return null;
        const buf = arena.alloc(u8, n) catch return null;
        dec.decode(buf, b64) catch return null;
        return decode(arena, buf);
    }
}

fn loadFile(arena: std.mem.Allocator) ?Session {
    const path = filePath(arena) catch return null;
    const data = (paths.readFile(arena, path, 64 * 1024) catch return null) orelse return null;
    return decode(arena, data);
}

pub fn save(a: std.mem.Allocator, s: Session) !void {
    const json = try encode(a, s);
    defer {
        std.crypto.utils.secureZero(u8, json);
        a.free(json);
    }
    if (useKeychain()) {
        if (saveKeychain(a, json, s.refresh_token)) {
            deleteFile(a);
            return;
        } else |_| {}
    }
    const path = try filePath(a);
    defer a.free(path);
    try paths.replaceFile(path, json);
}

fn saveKeychain(a: std.mem.Allocator, json: []const u8, refresh_token: []const u8) !void {
    {
        // Base64 so the value is one shell-safe word for `security -i`.
        const enc = std.base64.standard.Encoder;
        const b64 = try a.alloc(u8, enc.calcSize(json.len));
        defer a.free(b64);
        _ = enc.encode(b64, json);
        const cmd = try std.fmt.allocPrint(a, "add-generic-password -U -s {s} -a {s} -l DeathTerminal -w {s}\n", .{ keychain_service, keychain_account, b64 });
        defer {
            std.crypto.utils.secureZero(u8, cmd);
            a.free(cmd);
        }
        var child = std.process.Child.init(&.{ security, "-i" }, a);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        try child.spawn();
        child.stdin.?.writeAll(cmd) catch {};
        child.stdin.?.close();
        child.stdin = null;
        const term = try child.wait();
        if (term != .Exited or term.Exited != 0) return error.KeychainWrite;
        // `security -i` can exit 0 after a failed command; read it back.
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const back = loadKeychain(arena.allocator()) orelse return error.KeychainWrite;
        if (!std.mem.eql(u8, back.refresh_token, refresh_token)) return error.KeychainWrite;
    }
}

fn deleteFile(a: std.mem.Allocator) void {
    const path = filePath(a) catch return;
    defer a.free(path);
    std.fs.cwd().deleteFile(path) catch {};
}

/// Forget the session (signed out). Missing is fine.
pub fn clear(a: std.mem.Allocator) void {
    if (useKeychain()) {
        if (std.process.Child.run(.{
            .allocator = a,
            .argv = &.{ security, "delete-generic-password", "-s", keychain_service, "-a", keychain_account },
        })) |r| {
            a.free(r.stdout);
            a.free(r.stderr);
        } else |_| {}
    }
    deleteFile(a);
}

test "session round trip through the file store format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = Session{ .access_token = "a.b.c", .refresh_token = "r", .expires_at = 42, .email = "e@x.io", .user_id = "u" };
    const json = try encode(arena.allocator(), s);
    const back = decode(arena.allocator(), json).?;
    try std.testing.expectEqualStrings("r", back.refresh_token);
    try std.testing.expectEqual(@as(i64, 42), back.expires_at);
    try std.testing.expect(decode(arena.allocator(), "{\"access_token\":\"\",\"refresh_token\":\"\",\"expires_at\":0}") == null);
    try std.testing.expect(decode(arena.allocator(), "garbage") == null);
}
