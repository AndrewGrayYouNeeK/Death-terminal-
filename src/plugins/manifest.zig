//! `plugins/<name>/manifest.lua`: a data-only Lua file returning
//!
//!     return {
//!       name = "git_branch",           -- must match the directory name
//!       version = "1.0.0",
//!       description = "Git branch in the status bar",
//!       permissions = { "exec" },      -- what it asks for (see permissions.zig)
//!     }
//!
//! It runs in an empty environment (no functions at all) with tiny limits.

const std = @import("std");
const lua = @import("../scripting/lua.zig");
const c = lua.c;
const permissions = @import("permissions.zig");

pub const Manifest = struct {
    name: []const u8,
    version: []const u8,
    description: []const u8 = "",
    permissions: permissions.Set = permissions.Set.initEmpty(),
};

pub const max_bytes = 64 * 1024;

/// Plugin names: what the directory, `config.plugins.<name>` and the data
/// directory use.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |ch| if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '_' or ch == '-')) return false;
    return std.ascii.isLower(name[0]);
}

/// Parses `src` (display name `display`). On failure `err_buf` holds the
/// message ("manifest.lua:3: ...") and error.Invalid is returned.
pub fn parse(a: std.mem.Allocator, src: []const u8, display: []const u8, dir_name: []const u8, err_buf: []u8) error{ Invalid, OutOfMemory }!Manifest {
    var vm = lua.Vm.init(.{ .memory = 1024 * 1024, .instructions = 1_000_000 }) catch return error.OutOfMemory;
    defer vm.deinit();
    const L = vm.L;
    var nb: [256]u8 = undefined;
    const chunk = std.fmt.bufPrintZ(&nb, "={s}", .{display[0..@min(display.len, 200)]}) catch unreachable;
    lua.loadText(L, src, chunk) catch return fail(err_buf, "{s}", .{lua.toString(L, -1) orelse "syntax error"});
    // Empty _ENV: the manifest is data, nothing to call.
    lua.newTable(L);
    _ = c.lua_setupvalue(L, -2, 1);
    lua.pcall(L, 0, 1) catch return fail(err_buf, "{s}", .{lua.toString(L, -1) orelse "error"});
    if (c.lua_type(L, -1) != c.LUA_TTABLE) return fail(err_buf, "{s}: must return a table like {{ name = \"{s}\", version = \"1.0.0\" }}", .{ display, dir_name });
    const t = c.lua_gettop(L);

    var m = Manifest{ .name = "", .version = "" };
    c.lua_pushnil(L);
    while (c.lua_next(L, t) != 0) {
        defer lua.pop(L, 1);
        const key = lua.toString(L, -2) orelse return fail(err_buf, "{s}: keys must be strings", .{display});
        if (std.mem.eql(u8, key, "name")) {
            const s = lua.toString(L, -1) orelse return fail(err_buf, "{s}: name must be a string", .{display});
            if (!std.mem.eql(u8, s, dir_name)) return fail(err_buf, "{s}: name \"{s}\" does not match the directory \"{s}\"", .{ display, s[0..@min(s.len, 64)], dir_name });
            m.name = try a.dupe(u8, s);
        } else if (std.mem.eql(u8, key, "version")) {
            const s = lua.toString(L, -1) orelse return fail(err_buf, "{s}: version must be a string like \"1.0.0\"", .{display});
            if (s.len == 0 or s.len > 32) return fail(err_buf, "{s}: version must be 1-32 characters", .{display});
            m.version = try a.dupe(u8, s);
        } else if (std.mem.eql(u8, key, "description")) {
            const s = lua.toString(L, -1) orelse return fail(err_buf, "{s}: description must be a string", .{display});
            m.description = try a.dupe(u8, s[0..@min(s.len, 200)]);
        } else if (std.mem.eql(u8, key, "permissions")) {
            if (c.lua_type(L, -1) != c.LUA_TTABLE) return fail(err_buf, "{s}: permissions must be a list like {{ \"screen\" }}", .{display});
            const n = c.lua_rawlen(L, -1);
            var i: c.lua_Integer = 1;
            while (i <= n) : (i += 1) {
                _ = c.lua_rawgeti(L, -1, i);
                defer lua.pop(L, 1);
                const s = lua.toString(L, -1) orelse return fail(err_buf, "{s}: permissions[{d}] must be a string", .{ display, i });
                const p = permissions.Permission.parse(s) orelse {
                    var lb: [160]u8 = undefined;
                    return fail(err_buf, "{s}: unknown permission \"{s}\" (known: {s})", .{ display, s[0..@min(s.len, 32)], permissions.namesList(&lb) });
                };
                m.permissions.insert(p);
            }
        } else {
            return fail(err_buf, "{s}: unknown field \"{s}\" (known: name, version, description, permissions)", .{ display, key[0..@min(key.len, 32)] });
        }
    }
    if (m.name.len == 0) return fail(err_buf, "{s}: missing name (should be \"{s}\")", .{ display, dir_name });
    if (m.version.len == 0) return fail(err_buf, "{s}: missing version", .{display});
    return m;
}

fn fail(buf: []u8, comptime fmt: []const u8, args: anytype) error{Invalid} {
    const msg = std.fmt.bufPrint(buf, fmt, args) catch blk: {
        const tail = "...";
        @memcpy(buf[buf.len - tail.len ..], tail);
        break :blk buf;
    };
    // Callers read the message back with `message`.
    if (msg.len < buf.len) buf[msg.len] = 0;
    return error.Invalid;
}

/// The NUL-terminated message `parse` left in `buf`.
pub fn message(buf: []const u8) []const u8 {
    return std.mem.sliceTo(buf, 0);
}

test "manifest parsing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var eb: [512]u8 = undefined;
    const m = try parse(a, "return { name = 'git_branch', version = '1.2.0', description = 'x', permissions = { 'exec', 'screen' } }", "manifest.lua", "git_branch", &eb);
    try std.testing.expectEqualStrings("1.2.0", m.version);
    try std.testing.expect(m.permissions.contains(.exec) and m.permissions.contains(.screen) and !m.permissions.contains(.pty));

    try std.testing.expectError(error.Invalid, parse(a, "return { name = 'other', version = '1' }", "manifest.lua", "git_branch", &eb));
    try std.testing.expect(std.mem.indexOf(u8, message(&eb), "does not match") != null);
    try std.testing.expectError(error.Invalid, parse(a, "return { name = 'p', version = '1', permissions = { 'root' } }", "manifest.lua", "p", &eb));
    try std.testing.expect(std.mem.indexOf(u8, message(&eb), "unknown permission \"root\"") != null);
    try std.testing.expectError(error.Invalid, parse(a, "return { name = 'p', version = '1', main = 'x' }", "manifest.lua", "p", &eb));
    // Data only: no functions to call, and loops are cut short.
    try std.testing.expectError(error.Invalid, parse(a, "os.execute('id') return {}", "manifest.lua", "p", &eb));
    try std.testing.expectError(error.Invalid, parse(a, "while true do end", "manifest.lua", "p", &eb));
    try std.testing.expect(std.mem.indexOf(u8, message(&eb), "too long") != null);
    try std.testing.expectError(error.Invalid, parse(a, "return {", "manifest.lua", "p", &eb));
    try std.testing.expect(std.mem.startsWith(u8, message(&eb), "manifest.lua:1:"));

    try std.testing.expect(validName("git_branch") and validName("a-b2"));
    try std.testing.expect(!validName("Git") and !validName("../x") and !validName("") and !validName("1abc"));
}
