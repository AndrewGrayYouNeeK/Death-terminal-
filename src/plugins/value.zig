//! Plain data copied between Lua states: `config.plugins.<name>.settings`
//! is read from the config's Lua state and pushed into the plugin's own
//! state as `dt.settings`. Only booleans, numbers, strings and tables of
//! those (no functions, userdata or cycles).

const std = @import("std");
const lua = @import("../scripting/lua.zig");
const c = lua.c;
const State = lua.State;

pub const Value = union(enum) {
    boolean: bool,
    integer: i64,
    number: f64,
    string: []const u8,
    list: []const Value,
    map: []const Entry,
};

pub const Entry = struct { key: []const u8, value: Value };

pub const max_depth = 8;
pub const max_items = 4096;

pub const Error = error{ Unsupported, TooDeep, TooBig, BadKey, OutOfMemory };

const Budget = struct { items: usize = 0 };

/// Copies the value at `idx` (memory from `a`, typically an arena).
pub fn fromLua(a: std.mem.Allocator, L: *State, idx: c_int) Error!Value {
    var b = Budget{};
    return fromLuaDepth(a, L, c.lua_absindex(L, idx), 0, &b);
}

fn fromLuaDepth(a: std.mem.Allocator, L: *State, idx: c_int, depth: usize, b: *Budget) Error!Value {
    b.items += 1;
    if (b.items > max_items) return error.TooBig;
    switch (c.lua_type(L, idx)) {
        c.LUA_TBOOLEAN => return .{ .boolean = c.lua_toboolean(L, idx) != 0 },
        c.LUA_TNUMBER => return if (c.lua_isinteger(L, idx) != 0)
            .{ .integer = c.lua_tointegerx(L, idx, null) }
        else
            .{ .number = c.lua_tonumberx(L, idx, null) },
        c.LUA_TSTRING => return .{ .string = try a.dupe(u8, lua.toString(L, idx).?) },
        c.LUA_TTABLE => {
            if (depth >= max_depth) return error.TooDeep;
            if (c.lua_checkstack(L, 4) == 0) return error.OutOfMemory;
            const n: usize = @intCast(@max(c.lua_rawlen(L, idx), 0));
            // Count keys to tell a list from a map.
            var count: usize = 0;
            c.lua_pushnil(L);
            while (c.lua_next(L, idx) != 0) {
                lua.pop(L, 1);
                count += 1;
                if (count > max_items) {
                    lua.pop(L, 1);
                    return error.TooBig;
                }
            }
            if (count == n and n > 0) {
                const items = try a.alloc(Value, n);
                for (items, 1..) |*v, i| {
                    _ = c.lua_rawgeti(L, idx, @intCast(i));
                    v.* = fromLuaDepth(a, L, c.lua_gettop(L), depth + 1, b) catch |err| {
                        lua.pop(L, 1);
                        return err;
                    };
                    lua.pop(L, 1);
                }
                return .{ .list = items };
            }
            const entries = try a.alloc(Entry, count);
            var i: usize = 0;
            c.lua_pushnil(L);
            while (c.lua_next(L, idx) != 0) {
                if (c.lua_type(L, -2) != c.LUA_TSTRING) {
                    lua.pop(L, 2);
                    return error.BadKey;
                }
                const key = try a.dupe(u8, lua.toString(L, -2).?);
                const v = fromLuaDepth(a, L, c.lua_gettop(L), depth + 1, b) catch |err| {
                    lua.pop(L, 2);
                    return err;
                };
                entries[i] = .{ .key = key, .value = v };
                i += 1;
                lua.pop(L, 1);
            }
            std.mem.sort(Entry, entries, {}, struct {
                fn lt(_: void, x: Entry, y: Entry) bool {
                    return std.mem.lessThan(u8, x.key, y.key);
                }
            }.lt);
            return .{ .map = entries };
        },
        else => return error.Unsupported,
    }
}

/// Pushes `v` (may raise a Lua error on out-of-memory: call only from
/// protected code).
pub fn push(L: *State, v: Value) void {
    _ = c.luaL_checkstack(L, 4, "settings too deep");
    switch (v) {
        .boolean => |x| c.lua_pushboolean(L, @intFromBool(x)),
        .integer => |x| c.lua_pushinteger(L, x),
        .number => |x| c.lua_pushnumber(L, x),
        .string => |s| lua.pushString(L, s),
        .list => |items| {
            c.lua_createtable(L, @intCast(items.len), 0);
            for (items, 1..) |it, i| {
                push(L, it);
                c.lua_rawseti(L, -2, @intCast(i));
            }
        },
        .map => |entries| {
            c.lua_createtable(L, 0, @intCast(entries.len));
            for (entries) |e| {
                lua.pushString(L, e.key);
                push(L, e.value);
                c.lua_rawset(L, -3);
            }
        },
    }
}

/// Stable hash (for "did the plugin settings change?").
pub fn hash(h: *std.hash.Wyhash, v: Value) void {
    h.update(@tagName(std.meta.activeTag(v)));
    switch (v) {
        .boolean => |x| h.update(if (x) "1" else "0"),
        .integer => |x| h.update(std.mem.asBytes(&x)),
        .number => |x| h.update(std.mem.asBytes(&x)),
        .string => |s| h.update(s),
        .list => |items| for (items) |it| hash(h, it),
        .map => |entries| for (entries) |e| {
            h.update(e.key);
            hash(h, e.value);
        },
    }
}

/// Message for an `Error` from `fromLua`.
pub fn errorText(err: Error) []const u8 {
    return switch (err) {
        error.Unsupported => "only booleans, numbers, strings and tables of those are allowed",
        error.TooDeep => "tables nested too deeply (max 8)",
        error.TooBig => "too many entries (max 4096)",
        error.BadKey => "table keys must be strings (or a 1..n list)",
        error.OutOfMemory => "out of memory",
    };
}

test "copy a table between states" {
    var src = try lua.Vm.init(.{});
    defer src.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try lua.loadText(src.L, "return { threshold = 10, name = 'x', ratio = 0.5, on = true, list = { 'a', 'b' }, nested = { k = { 1, 2, 3 } } }", "=t");
    try lua.pcall(src.L, 0, 1);
    const v = try fromLua(arena.allocator(), src.L, -1);
    try std.testing.expectEqual(@as(usize, 6), v.map.len);

    var dst = try lua.Vm.init(.{});
    defer dst.deinit();
    push(dst.L, v);
    c.lua_setglobal(dst.L, "s");
    try lua.loadText(dst.L, "return s.threshold + #s.list + s.nested.k[3] + (s.on and 1 or 0)", "=u");
    try lua.pcall(dst.L, 0, 1);
    try std.testing.expectEqual(@as(c.lua_Integer, 16), c.lua_tointegerx(dst.L, -1, null));

    try lua.loadText(src.L, "return { f = print }", "=bad");
    try lua.pcall(src.L, 0, 1);
    try std.testing.expectError(error.Unsupported, fromLua(arena.allocator(), src.L, -1));
    try lua.loadText(src.L, "local t = {} t.self = t return t", "=cycle");
    try lua.pcall(src.L, 0, 1);
    try std.testing.expectError(error.TooDeep, fromLua(arena.allocator(), src.L, -1));
}
