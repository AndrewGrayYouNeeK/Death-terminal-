//! Long-lived Lua state for scripting (plugins and hooks arrive in
//! milestone 10).
//!
//! Config loading uses its own short-lived, sandboxed state (see
//! config/lua_config.zig) so a reload never inherits leftovers. This engine
//! follows the same rules: the vendored Lua 5.4, a memory cap and an
//! instruction budget, and scripts run in a sandboxed environment table
//! (no io / os.execute / require) unless `unsafe` is set. Milestone 10 adds
//! a `dt.on(event, fn)` registry on top of `run`.

const std = @import("std");
const lua = @import("lua.zig");
const c = lua.c;

pub const LuaEngine = struct {
    allocator: std.mem.Allocator,
    vm: lua.Vm,
    initialized: bool,
    /// Registry reference of the sandbox environment table.
    env_ref: c_int,
    last_error: std.ArrayList(u8),

    pub const Options = struct {
        unsafe: bool = false,
        limits: lua.Limits = .{},
    };

    const sandbox_src =
        \\local unsafe = ...
        \\local env = {
        \\  assert = assert, error = error, ipairs = ipairs, next = next, pairs = pairs,
        \\  pcall = pcall, xpcall = xpcall, select = select, tonumber = tonumber,
        \\  tostring = tostring, type = type, rawequal = rawequal, rawget = rawget,
        \\  rawset = rawset, rawlen = rawlen, setmetatable = setmetatable,
        \\  getmetatable = getmetatable, print = print, _VERSION = _VERSION,
        \\  string = string, table = table, math = math, utf8 = utf8, coroutine = coroutine,
        \\  os = { getenv = os.getenv, time = os.time, clock = os.clock, date = os.date },
        \\}
        \\env._G = env
        \\env.load = function(chunk, name, _, e) return load(chunk, name, "t", e or env) end
        \\if unsafe then setmetatable(env, { __index = _G }) end
        \\return env
    ;

    pub fn init(allocator: std.mem.Allocator) !LuaEngine {
        return initWith(allocator, .{});
    }

    pub fn initWith(allocator: std.mem.Allocator, opts: Options) !LuaEngine {
        var vm = try lua.Vm.init(opts.limits);
        errdefer vm.deinit();
        const L = vm.L;
        lua.loadText(L, sandbox_src, "=sandbox") catch return error.LuaInit;
        c.lua_pushboolean(L, @intFromBool(opts.unsafe));
        lua.pcall(L, 1, 1) catch return error.LuaInit;
        const env_ref = c.luaL_ref(L, c.LUA_REGISTRYINDEX);
        return .{
            .allocator = allocator,
            .vm = vm,
            .initialized = true,
            .env_ref = env_ref,
            .last_error = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *LuaEngine) void {
        self.vm.deinit();
        self.last_error.deinit();
        self.initialized = false;
    }

    /// Run `code` in the sandbox. On failure `lastError()` has the message
    /// ("name:line: ...").
    pub fn run(self: *LuaEngine, code: []const u8, name: []const u8) !void {
        const L = self.vm.L;
        var name_buf: [256]u8 = undefined;
        const chunk = std.fmt.bufPrintZ(&name_buf, "={s}", .{name[0..@min(name.len, 200)]}) catch unreachable;
        self.vm.startBudget(self.vm.alloc_state.instruction_limit, 0);
        lua.loadText(L, code, chunk) catch return self.fail();
        _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, self.env_ref);
        _ = c.lua_setupvalue(L, -2, 1); // _ENV
        lua.pcall(L, 0, 0) catch return self.fail();
    }

    pub fn executeString(self: *LuaEngine, code: []const u8) !void {
        return self.run(code, "chunk");
    }

    pub fn loadScript(self: *LuaEngine, path: []const u8) !void {
        const src = try std.fs.cwd().readFileAlloc(self.allocator, path, 16 * 1024 * 1024);
        defer self.allocator.free(src);
        return self.run(src, std.fs.path.basename(path));
    }

    pub fn lastError(self: *const LuaEngine) []const u8 {
        return self.last_error.items;
    }

    fn fail(self: *LuaEngine) error{LuaError} {
        const L = self.vm.L;
        self.last_error.clearRetainingCapacity();
        self.last_error.appendSlice(lua.toString(L, -1) orelse "error object is not a string") catch {};
        lua.pop(L, 1);
        return error.LuaError;
    }

    /// Read a global from the sandbox (tests / future hook dispatch).
    pub fn getGlobalInt(self: *LuaEngine, name: [:0]const u8) ?i64 {
        const L = self.vm.L;
        _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, self.env_ref);
        defer lua.pop(L, 2);
        _ = c.lua_getfield(L, -1, name.ptr);
        if (c.lua_isinteger(L, -1) == 0) return null;
        return c.lua_tointegerx(L, -1, null);
    }
};

test "LuaEngine runs sandboxed code and reports errors" {
    const testing = std.testing;
    var e = try LuaEngine.init(testing.allocator);
    defer e.deinit();
    try testing.expect(e.initialized);
    try e.run("x = 6 * 7", "t.lua");
    try testing.expectEqual(@as(i64, 42), e.getGlobalInt("x").?);
    try testing.expectError(error.LuaError, e.run("\nos.execute('true')", "t.lua"));
    try testing.expect(std.mem.startsWith(u8, e.lastError(), "t.lua:2:"));
    try testing.expectError(error.LuaError, e.run("io.open('/etc/passwd')", "t.lua"));
    try testing.expectError(error.LuaError, e.run("while true do end", "loop.lua"));
    try testing.expect(std.mem.indexOf(u8, e.lastError(), "took too long") != null);
    // Still usable after an abort.
    try e.run("x = x + 1", "t.lua");
    try testing.expectEqual(@as(i64, 43), e.getGlobalInt("x").?);
}
