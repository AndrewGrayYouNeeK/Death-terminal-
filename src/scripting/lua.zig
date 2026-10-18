//! Thin Zig layer over the vendored Lua 5.4 C API (vendor/lua-5.4.7).
//!
//! `Vm` owns a `lua_State` whose allocator enforces a memory cap and whose
//! count hook aborts runaway scripts, so untrusted config (and, later,
//! plugins) cannot hang or exhaust the terminal. C macros that translate-c
//! can't express are re-implemented here.

const std = @import("std");

pub const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
});

pub const State = c.lua_State;
pub const CFn = *const fn (?*State) callconv(.C) c_int;

pub const Limits = struct {
    /// Bytes the state may allocate in total.
    memory: usize = 64 * 1024 * 1024,
    /// VM instructions before the script is aborted (0 = unlimited).
    instructions: u64 = 200_000_000,
};

const hook_every: c_int = 10_000;

pub const AllocState = struct {
    used: usize = 0,
    limit: usize,
    instructions: u64 = 0,
    instruction_limit: u64,
    /// Wall-clock deadline for the current call (std.time.nanoTimestamp,
    /// 0 = none). Checked by the count hook, so it bounds Lua code but not
    /// a single long-running C function.
    deadline_ns: i128 = 0,
    /// Set once a budget ran out; the hook keeps raising until the next
    /// `startBudget`, so `pcall` inside the script can't swallow it.
    killed: bool = false,
    /// An allocation was refused by the memory cap since `startBudget`.
    memory_hit: bool = false,
};

fn luaAlloc(ud: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.C) ?*anyopaque {
    const st: *AllocState = @ptrCast(@alignCast(ud.?));
    const old: usize = if (ptr == null) 0 else osize;
    if (nsize == 0) {
        std.c.free(ptr);
        st.used -|= old;
        return null;
    }
    if (nsize > old and st.used + (nsize - old) > st.limit) {
        st.memory_hit = true;
        return null;
    }
    const p = std.c.realloc(ptr, nsize) orelse return null;
    st.used = st.used - old + nsize;
    return p;
}

fn countHook(L: ?*State, ar: ?*c.lua_Debug) callconv(.C) void {
    _ = ar;
    var ud: ?*anyopaque = null;
    _ = c.lua_getallocf(L, &ud);
    const st: *AllocState = @ptrCast(@alignCast(ud.?));
    if (st.killed) {
        _ = c.luaL_error(L, "script took too long (stopped)");
    }
    // A coroutine that was stopped earlier still has the every-instruction
    // hook; put it back to the normal rate now that a new budget runs.
    if (c.lua_gethookcount(L) != hook_every) {
        c.lua_sethook(L, countHook, c.LUA_MASKCOUNT, hook_every);
        st.instructions += 1;
        return;
    }
    st.instructions += @intCast(hook_every);
    if (st.instruction_limit != 0 and st.instructions > st.instruction_limit) {
        kill(L, st);
        _ = c.luaL_error(L, "script took too long (more than %d million instructions)", @as(c_int, @intCast(@max(st.instruction_limit / 1_000_000, 1))));
    }
    if (st.deadline_ns != 0 and std.time.nanoTimestamp() > st.deadline_ns) {
        kill(L, st);
        _ = c.luaL_error(L, "script took too long (time limit)");
    }
}

/// Mark the state as stopped and make the hook fire on every instruction, so
/// a script that catches the error with `pcall` is stopped again at its very
/// next instruction instead of 10k instructions later (which could always
/// land back inside the protected call). `startBudget` restores the rate.
fn kill(L: ?*State, st: *AllocState) void {
    st.killed = true;
    c.lua_sethook(L, countHook, c.LUA_MASKCOUNT, 1);
}

pub const Vm = struct {
    L: *State,
    alloc_state: *AllocState,

    pub fn init(limits: Limits) !Vm {
        const st = try std.heap.c_allocator.create(AllocState);
        errdefer std.heap.c_allocator.destroy(st);
        st.* = .{ .limit = limits.memory, .instruction_limit = limits.instructions };
        const L = c.lua_newstate(luaAlloc, st) orelse return error.LuaOutOfMemory;
        c.lua_sethook(L, countHook, c.LUA_MASKCOUNT, hook_every);
        // All standard libraries are loaded into the VM's own globals; code
        // that must be sandboxed runs with a separate environment table.
        c.luaL_openlibs(L);
        return .{ .L = L, .alloc_state = st };
    }

    pub fn deinit(self: *Vm) void {
        c.lua_close(self.L);
        std.heap.c_allocator.destroy(self.alloc_state);
    }

    pub fn memoryUsed(self: *const Vm) usize {
        return self.alloc_state.used;
    }

    /// Fresh budget for the next call: `instructions` VM instructions
    /// (0 = unlimited) and `ms` of wall-clock time (0 = no deadline).
    pub fn startBudget(self: *Vm, instructions: u64, ms: u32) void {
        const st = self.alloc_state;
        st.instructions = 0;
        st.instruction_limit = instructions;
        st.deadline_ns = if (ms == 0) 0 else std.time.nanoTimestamp() + @as(i128, ms) * std.time.ns_per_ms;
        if (st.killed) c.lua_sethook(self.L, countHook, c.LUA_MASKCOUNT, hook_every);
        st.killed = false;
        st.memory_hit = false;
    }

    pub fn killed(self: *const Vm) bool {
        return self.alloc_state.killed;
    }
};

// ---------------------------------------------------------------- macros

pub fn pop(L: *State, n: c_int) void {
    c.lua_settop(L, -n - 1);
}

pub fn upvalueIndex(i: c_int) c_int {
    return c.LUA_REGISTRYINDEX - i;
}

pub fn pushCFn(L: *State, f: CFn) void {
    c.lua_pushcclosure(L, f, 0);
}

pub fn pushString(L: *State, s: []const u8) void {
    _ = c.lua_pushlstring(L, s.ptr, s.len);
}

pub fn newTable(L: *State) void {
    c.lua_createtable(L, 0, 0);
}

pub fn toString(L: *State, idx: c_int) ?[]const u8 {
    if (c.lua_type(L, idx) != c.LUA_TSTRING) return null;
    var len: usize = 0;
    const p = c.lua_tolstring(L, idx, &len) orelse return null;
    return p[0..len];
}

pub fn typeName(L: *State, idx: c_int) []const u8 {
    return std.mem.span(c.lua_typename(L, c.lua_type(L, idx)));
}

pub fn isNil(L: *State, idx: c_int) bool {
    return c.lua_type(L, idx) <= c.LUA_TNIL;
}

/// Push `src`, compiled as a text-only chunk named `name` (binary chunks are
/// refused). On error the message is left on the stack.
pub fn loadText(L: *State, src: []const u8, name: [:0]const u8) !void {
    if (c.luaL_loadbufferx(L, src.ptr, src.len, name.ptr, "t") != c.LUA_OK) return error.LuaLoad;
}

pub fn pcall(L: *State, nargs: c_int, nresults: c_int) !void {
    if (c.lua_pcallk(L, nargs, nresults, 0, 0, null) != c.LUA_OK) return error.LuaRuntime;
}

test "vm runs code and enforces limits" {
    var vm = try Vm.init(.{ .memory = 4 * 1024 * 1024, .instructions = 1_000_000 });
    defer vm.deinit();
    const L = vm.L;
    try loadText(L, "return 6 * 7", "=t");
    try pcall(L, 0, 1);
    try std.testing.expectEqual(@as(c.lua_Integer, 42), c.lua_tointegerx(L, -1, null));
    pop(L, 1);

    try loadText(L, "while true do end", "=loop");
    try std.testing.expectError(error.LuaRuntime, pcall(L, 0, 0));
    try std.testing.expect(std.mem.indexOf(u8, toString(L, -1).?, "took too long") != null);
    pop(L, 1);

    vm.startBudget(1_000_000, 0);
    try loadText(L, "local t = {} for i = 1, 1e7 do t[i] = ('x'):rep(100) .. i end", "=mem");
    try std.testing.expectError(error.LuaRuntime, pcall(L, 0, 0));
    try std.testing.expect(std.mem.indexOf(u8, toString(L, -1).?, "memory") != null);
    pop(L, 1);
}

test "kill flag survives pcall and the deadline stops loops" {
    var vm = try Vm.init(.{ .memory = 4 * 1024 * 1024, .instructions = 0 });
    defer vm.deinit();
    const L = vm.L;
    // A script that tries to swallow the abort with pcall still ends.
    vm.startBudget(2_000_000, 0);
    try loadText(L, "local n = 0 while true do pcall(function() while true do end end) n = n + 1 end", "=swallow");
    try std.testing.expectError(error.LuaRuntime, pcall(L, 0, 0));
    try std.testing.expect(vm.killed());
    pop(L, 1);
    // Wall-clock budget without an instruction cap.
    vm.startBudget(0, 30);
    const t0 = std.time.milliTimestamp();
    try loadText(L, "while true do end", "=spin");
    try std.testing.expectError(error.LuaRuntime, pcall(L, 0, 0));
    try std.testing.expect(std.mem.indexOf(u8, toString(L, -1).?, "time limit") != null);
    try std.testing.expect(std.time.milliTimestamp() - t0 < 2000);
    pop(L, 1);
    // A fresh budget runs normally again.
    vm.startBudget(1_000_000, 100);
    try loadText(L, "return 1", "=ok");
    try pcall(L, 0, 1);
    pop(L, 1);
}
