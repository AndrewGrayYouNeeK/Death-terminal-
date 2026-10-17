//! Runs plugins: one isolated Lua state per plugin (memory cap, time budget
//! per call, only the capabilities granted in config), the hook dispatch,
//! and the APIs behind the `dt` table (see sandbox.lua and docs/PLUGINS.md).
//!
//! Nothing a plugin does can take the terminal down: every call into Lua is
//! protected, errors are logged and shown as a toast, and a plugin that keeps
//! failing (5 errors in a minute, or a failed load) is switched off for the
//! session. Plugins never touch the terminal directly; they queue `Effect`s
//! that the event loop applies, and they read state through `App` / `Info`.

const std = @import("std");
/// Plugin logs and data files: private to the user (no mode on Windows).
const file_mode: std.fs.File.Mode = if (@import("builtin").os.tag == .windows) 0 else 0o600;
const builtin = @import("builtin");
const lua = @import("../scripting/lua.zig");
const c = lua.c;
const State = lua.State;
const permissions = @import("permissions.zig");
const Permission = permissions.Permission;
const value = @import("value.zig");
const Value = value.Value;
const Entry = value.Entry;
const PluginConfig = @import("plugin_config.zig").PluginConfig;
const jobs = @import("jobs.zig");
const events = @import("../platform/events.zig");
const themes = @import("../config/themes.zig");
const color = @import("../terminal/color.zig");

const sandbox_src = @embedFile("sandbox.lua");

pub const Event = enum {
    startup,
    config_reload,
    key,
    command_start,
    command_finish,
    output_line,
    cwd,
    title,
    bell,
    focus,
    ssh_connect,
    ssh_disconnect,
    ai_suggestion,
    shutdown,
    /// Tabs and panes ({ tab = id, pane = id }).
    tab_new,
    tab_close,
    tab_focus,
    pane_new,
    pane_close,
    pane_focus,

    /// The permission a plugin needs to subscribe.
    pub fn needs(self: Event) ?Permission {
        return switch (self) {
            .key => .input,
            .output_line => .screen,
            .ai_suggestion => .ai,
            else => null,
        };
    }
};
pub const EventSet = std.EnumSet(Event);

/// One plugin to run (built by registry.zig from the plugins directory and
/// config.plugins).
pub const Spec = struct {
    name: []const u8,
    version: []const u8 = "0",
    description: []const u8 = "",
    /// Directory holding init.lua.
    dir: []const u8,
    /// Manifest `permissions`.
    requested: permissions.Set = permissions.Set.initEmpty(),
    config: PluginConfig = .{ .name = "" },
};

/// What plugins may read from the terminal (screen text needs `screen`).
pub const App = struct {
    ctx: *anyopaque,
    /// Visible screen (plus up to `scrollback` lines above it) as text,
    /// one line per row, trailing blanks trimmed.
    screenText: *const fn (ctx: *anyopaque, out: *std.ArrayList(u8), scrollback: u32) void,
    /// Cursor row and column (0-based).
    cursor: *const fn (ctx: *anyopaque) [2]u32,
};

pub const Level = enum { info, success, warn, @"error" };

pub const Notice = struct {
    /// Who it's from (plugin name).
    source: []u8,
    text: []u8,
    level: Level = .info,
    timeout_ms: u32 = 4000,
    /// Also send a desktop notification when the window is unfocused.
    desktop: bool = false,
};

/// Work for the event loop. Strings are owned by the host until
/// `clearEffects`.
pub const Effect = union(enum) {
    write: []u8,
    set_clipboard: []u8,
    request_clipboard,
    notify: Notice,
    theme: struct { name: []u8, palette: color.Palette },
    action: events.Action,
    /// Status bar, toasts or palette entries changed.
    redraw,
    /// Plugin keybindings changed: reinstall them (`Host.binds`).
    bindings_changed,
    /// dt.tabs / dt.panes requests.
    layout: LayoutOp,

    fn deinit(self: *Effect, a: std.mem.Allocator) void {
        switch (self.*) {
            .write, .set_clipboard => |s| a.free(s),
            .notify => |n| {
                a.free(n.source);
                a.free(n.text);
            },
            .theme => |t| a.free(t.name),
            .layout => |l| switch (l) {
                .tab_new => |cwd| if (cwd) |d| a.free(d),
                .tab_rename => |r| a.free(r.name),
                else => {},
            },
            else => {},
        }
    }
};

/// A tab / pane change a plugin asked for (ids from dt.tabs.list()).
pub const LayoutOp = union(enum) {
    /// Optional working directory (owned).
    tab_new: ?[]u8,
    tab_focus: u32,
    tab_close: u32,
    tab_rename: struct { id: u32, name: []u8 },
    /// Split the focused pane.
    pane_split: enum { right, down },
    pane_focus: u32,
    pane_close: u32,
};

/// Snapshot of one tab for dt.tabs.list() (kept current by the app).
pub const TabInfo = struct {
    id: u32,
    title: []const u8,
    active: bool,
    panes: []const u32,
    focused_pane: u32,
};

pub const Segment = struct {
    plugin: *Plugin,
    id: []u8,
    text: []u8,
    right: bool = false,
    fg: ?u32 = null,
};

pub const Command = struct {
    plugin: *Plugin,
    id: []u8,
    title: []u8,
    cb: i64,
};

pub const Bind = struct {
    /// Stable id passed back through `events.Action.plugin_binding`.
    id: u16,
    plugin: *Plugin,
    chord: events.Chord,
    spec: []u8,
    cb: i64,
};

pub const RegTheme = struct {
    plugin: *Plugin,
    theme: themes.Theme,
};

const Timer = struct {
    plugin: *Plugin,
    cb: i64,
    due_ms: i64,
    interval_ms: u32,
};

const PendingJob = struct {
    id: u32,
    plugin: *Plugin,
    cb: i64,
    deadline_ms: i64,
};

const ClipWaiter = struct { plugin: *Plugin, cb: i64 };

pub const Status = enum {
    /// Loaded and receiving events.
    running,
    /// Load failed or switched off after repeated errors (see `message`).
    failed,
};

pub const Limits = struct {
    pub const max_segments = 8;
    pub const max_commands = 32;
    pub const max_binds = 16;
    pub const max_timers = 64;
    pub const max_jobs = 4;
    pub const max_themes = 16;
    pub const min_interval_ms = 100;
    pub const max_write = 64 * 1024;
    pub const max_clipboard = 1024 * 1024;
    pub const max_file = 16 * 1024 * 1024;
    pub const max_module = 1024 * 1024;
    pub const errors_to_disable = 5;
    pub const error_window_ms = 60_000;
    pub const toast_every_ms = 10_000;
    pub const notices_per_10s = 5;
    pub const log_lines_per_10s = 100;
    pub const output_lines_per_batch = 200;
};

pub const Plugin = struct {
    host: *Host,
    name: []const u8,
    version: []const u8,
    description: []const u8,
    dir: []const u8,
    data_dir: []const u8,
    requested: permissions.Set,
    allowed: permissions.Set,
    /// requested ∩ allowed: what the plugin actually gets.
    granted: permissions.Set,
    exec: []const []const u8,
    hosts: []const []const u8,
    memory_mb: u16,
    cpu_ms: u16,
    settings: ?Value,

    vm: ?lua.Vm = null,
    dispatch_ref: c_int = c.LUA_NOREF,
    invoke_ref: c_int = c.LUA_NOREF,
    status: Status = .failed,
    /// Why it failed / was disabled (owned by the host allocator).
    message: []u8 = &.{},
    subscribed: EventSet = EventSet.initEmpty(),
    error_times: [Limits.errors_to_disable]i64 = [_]i64{0} ** Limits.errors_to_disable,
    error_next: usize = 0,
    errors_total: u32 = 0,
    last_toast_ms: i64 = -Limits.toast_every_ms,
    notice_times: [Limits.notices_per_10s]i64 = [_]i64{-100_000} ** Limits.notices_per_10s,
    notice_next: usize = 0,
    log_window_start: i64 = 0,
    log_lines: u32 = 0,
    disable_pending: bool = false,
    disable_reason: [256]u8 = undefined,
    disable_reason_len: usize = 0,
    in_call: u32 = 0,
    err_buf: [600:0]u8 = undefined,

    pub fn has(self: *const Plugin, p: Permission) bool {
        return self.granted.contains(p);
    }

    pub fn running(self: *const Plugin) bool {
        return self.status == .running and self.vm != null and !self.disable_pending;
    }

    fn raise(self: *Plugin, comptime fmt: []const u8, args: anytype) error{LuaMsg} {
        _ = std.fmt.bufPrintZ(&self.err_buf, fmt, args) catch {
            const tail = "...";
            const n = self.err_buf.len - tail.len - 1;
            @memcpy(self.err_buf[n..][0..tail.len], tail);
            self.err_buf[self.err_buf.len - 1] = 0;
        };
        return error.LuaMsg;
    }

    fn need(self: *Plugin, p: Permission, what: []const u8) error{LuaMsg}!void {
        if (self.has(p)) return;
        if (!self.requested.contains(p))
            return self.raise("{s}: needs the '{s}' permission (add it to permissions in {s}/manifest.lua)", .{ what, @tagName(p), self.name });
        return self.raise("{s}: needs the '{s}' permission (grant it with config.plugins[\"{s}\"].allow = {{ \"{s}\" }})", .{ what, @tagName(p), self.name, @tagName(p) });
    }
};

pub const Options = struct {
    /// Append-only log ("" = none).
    log_path: []const u8 = "",
    /// Plugin data directories live under here (<data_root>/<name>).
    data_root: []const u8 = "",
    /// `dt.version`.
    version: []const u8 = "0",
};

pub const Info = struct {
    rows: u32 = 24,
    cols: u32 = 80,
    focused: bool = true,
    cwd: std.ArrayListUnmanaged(u8) = .{},
    title: std.ArrayListUnmanaged(u8) = .{},
    ssh: std.ArrayListUnmanaged(u8) = .{},
    theme: std.ArrayListUnmanaged(u8) = .{},
    /// Focused tab / pane ids.
    tab: u32 = 1,
    pane: u32 = 1,
    /// Tabs, left to right (strings in `tabs_arena`).
    tabs: []const TabInfo = &.{},
    tabs_arena: ?std.heap.ArenaAllocator = null,
};

pub const SuggestionResult = union(enum) { keep, drop, replace: []u8 };

pub const Host = struct {
    a: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    app: App,
    opts: Options,
    info: Info = .{},
    plugins: std.ArrayList(*Plugin),
    effects: std.ArrayList(Effect),
    segments: std.ArrayList(Segment),
    commands: std.ArrayList(Command),
    binds: std.ArrayList(Bind),
    reg_themes: std.ArrayList(RegTheme),
    timers: std.ArrayList(Timer),
    pending: std.ArrayList(PendingJob),
    clip_waiters: std.ArrayList(ClipWaiter),
    queue: *jobs.Queue,
    scratch: std.ArrayList(u8),
    log_file: ?std.fs.File = null,
    next_job: u32 = 1,
    next_bind: u16 = 1,
    /// Chords the terminal itself uses; plugins can't take them.
    taken: *const fn (chord: events.Chord) bool = noneTaken,

    fn noneTaken(_: events.Chord) bool {
        return false;
    }

    pub fn init(a: std.mem.Allocator, app: App, opts: Options) !*Host {
        const h = try a.create(Host);
        errdefer a.destroy(h);
        const q = try jobs.Queue.create();
        h.* = .{
            .a = a,
            .arena = std.heap.ArenaAllocator.init(a),
            .app = app,
            .opts = undefined,
            .plugins = std.ArrayList(*Plugin).init(a),
            .effects = std.ArrayList(Effect).init(a),
            .segments = std.ArrayList(Segment).init(a),
            .commands = std.ArrayList(Command).init(a),
            .binds = std.ArrayList(Bind).init(a),
            .reg_themes = std.ArrayList(RegTheme).init(a),
            .timers = std.ArrayList(Timer).init(a),
            .pending = std.ArrayList(PendingJob).init(a),
            .clip_waiters = std.ArrayList(ClipWaiter).init(a),
            .queue = q,
            .scratch = std.ArrayList(u8).init(a),
        };
        const aa = h.arena.allocator();
        h.opts = .{
            .log_path = try aa.dupe(u8, opts.log_path),
            .data_root = try aa.dupe(u8, opts.data_root),
            .version = try aa.dupe(u8, opts.version),
        };
        if (opts.log_path.len > 0) h.openLog();
        return h;
    }

    pub fn deinit(self: *Host) void {
        const a = self.a;
        self.emit(.shutdown, null);
        for (self.plugins.items) |p| {
            self.teardown(p);
            a.free(p.message);
            a.destroy(p);
        }
        self.plugins.deinit();
        self.clearEffects();
        self.effects.deinit();
        self.segments.deinit();
        self.commands.deinit();
        self.binds.deinit();
        self.reg_themes.deinit();
        self.timers.deinit();
        self.pending.deinit();
        self.clip_waiters.deinit();
        self.scratch.deinit();
        self.info.cwd.deinit(a);
        self.info.title.deinit(a);
        self.info.ssh.deinit(a);
        self.info.theme.deinit(a);
        if (self.info.tabs_arena) |*ar| ar.deinit();
        self.queue.release();
        if (self.log_file) |f| f.close();
        self.arena.deinit();
        a.destroy(self);
    }

    // ------------------------------------------------------------ setup

    /// Load every plugin in `specs` (call once, after init). Failures are
    /// recorded on the plugin (status .failed) and logged.
    pub fn start(self: *Host, specs: []const Spec) !void {
        for (specs) |s| {
            const p = try self.addPlugin(s);
            self.load(p);
        }
        self.emit(.startup, null);
    }

    fn addPlugin(self: *Host, s: Spec) !*Plugin {
        const aa = self.arena.allocator();
        const p = try self.a.create(Plugin);
        errdefer self.a.destroy(p);
        const data_dir = if (self.opts.data_root.len > 0)
            try std.fs.path.join(aa, &.{ self.opts.data_root, s.name })
        else
            "";
        var settings: ?Value = null;
        if (s.config.settings) |v| settings = try cloneValue(aa, v);
        var granted = s.requested;
        granted.setIntersection(s.config.allow);
        p.* = .{
            .host = self,
            .name = try aa.dupe(u8, s.name),
            .version = try aa.dupe(u8, s.version),
            .description = try aa.dupe(u8, s.description),
            .dir = try aa.dupe(u8, s.dir),
            .data_dir = data_dir,
            .requested = s.requested,
            .allowed = s.config.allow,
            .granted = granted,
            .exec = try dupeList(aa, s.config.exec),
            .hosts = try dupeList(aa, s.config.hosts),
            .memory_mb = s.config.memory_mb,
            .cpu_ms = s.config.cpu_ms,
            .settings = settings,
        };
        try self.plugins.append(p);
        return p;
    }

    fn load(self: *Host, p: *Plugin) void {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/init.lua", .{p.dir}) catch return self.failLoad(p, "plugin path too long");
        const src = std.fs.cwd().readFileAlloc(self.a, path, Limits.max_module) catch |err|
            return self.failLoadFmt(p, "cannot read {s}: {s}", .{ path, @errorName(err) });
        defer self.a.free(src);

        p.vm = lua.Vm.init(.{ .memory = @as(usize, p.memory_mb) * 1024 * 1024, .instructions = 0 }) catch
            return self.failLoad(p, "cannot create a Lua state (out of memory)");
        p.status = .running;
        var setup = Call{ .p = p, .kind = .setup };
        if (!self.call(p, &setup, 2000, "setup")) return self.failLoadLast(p);
        var main = Call{ .p = p, .kind = .main, .src = src };
        const budget: u32 = @min(@as(u32, p.cpu_ms) * 10, 30_000);
        if (!self.call(p, &main, budget, "init.lua")) return self.failLoadLast(p);
        if (p.disable_pending) return self.afterCall(p);
        self.log(p, "info", "loaded {s} {s} (permissions: {s})", .{ p.name, p.version, fmtSet(p.granted) });
    }

    fn failLoadLast(self: *Host, p: *Plugin) void {
        // `call` already logged the error and put it in p.message.
        const msg = self.a.dupe(u8, p.message) catch "";
        defer if (msg.len > 0) self.a.free(msg);
        self.failLoad(p, msg);
    }

    fn failLoadFmt(self: *Host, p: *Plugin, comptime fmt: []const u8, args: anytype) void {
        var buf: [600]u8 = undefined;
        self.failLoad(p, std.fmt.bufPrint(&buf, fmt, args) catch fmt);
    }

    fn failLoad(self: *Host, p: *Plugin, msg: []const u8) void {
        self.teardown(p);
        p.status = .failed;
        self.setMessage(p, msg);
        self.log(p, "error", "not loaded: {s}", .{msg});
        self.notice(p, .@"error", "Plugin {s} failed to load: {s}", .{ p.name, firstLine(msg) }, 8000);
    }

    fn setMessage(self: *Host, p: *Plugin, msg: []const u8) void {
        const m = self.a.dupe(u8, msg[0..@min(msg.len, 2000)]) catch return;
        self.a.free(p.message);
        p.message = m;
    }

    /// Stop `p` and drop everything it registered.
    fn teardown(self: *Host, p: *Plugin) void {
        std.debug.assert(p.in_call == 0);
        var had_binds = false;
        var changed = false;
        var i: usize = 0;
        while (i < self.segments.items.len) {
            if (self.segments.items[i].plugin == p) {
                const s = self.segments.orderedRemove(i);
                self.a.free(s.id);
                self.a.free(s.text);
                changed = true;
            } else i += 1;
        }
        i = 0;
        while (i < self.commands.items.len) {
            if (self.commands.items[i].plugin == p) {
                const cmd = self.commands.orderedRemove(i);
                self.a.free(cmd.id);
                self.a.free(cmd.title);
                changed = true;
            } else i += 1;
        }
        i = 0;
        while (i < self.binds.items.len) {
            if (self.binds.items[i].plugin == p) {
                self.a.free(self.binds.orderedRemove(i).spec);
                had_binds = true;
            } else i += 1;
        }
        i = 0;
        while (i < self.reg_themes.items.len) {
            if (self.reg_themes.items[i].plugin == p) {
                self.a.free(self.reg_themes.orderedRemove(i).theme.name);
            } else i += 1;
        }
        removeWhere(Timer, &self.timers, p);
        removeWhere(PendingJob, &self.pending, p);
        removeWhere(ClipWaiter, &self.clip_waiters, p);
        if (p.vm) |*vm| vm.deinit();
        p.vm = null;
        p.subscribed = EventSet.initEmpty();
        if (changed) self.effect(.redraw);
        if (had_binds) self.effect(.bindings_changed);
    }

    fn removeWhere(comptime T: type, list: *std.ArrayList(T), p: *Plugin) void {
        var i: usize = 0;
        while (i < list.items.len) {
            if (list.items[i].plugin == p) _ = list.orderedRemove(i) else i += 1;
        }
    }

    // ------------------------------------------------------------ calls

    const Call = struct {
        p: *Plugin,
        kind: enum { setup, main, dispatch, invoke },
        src: []const u8 = "",
        event: []const u8 = "",
        cb: i64 = 0,
        drop: bool = false,
        payload: ?Value = null,
        result: Result = .none,
    };

    const Result = union(enum) { none, boolean: bool, string: []u8 };

    /// Runs `call` in the plugin's state with a fresh time budget. Returns
    /// false (and records the error) if it raised.
    fn call(self: *Host, p: *Plugin, cl: *Call, budget_ms: u32, what: []const u8) bool {
        const vm = &(p.vm orelse return false);
        const L = vm.L;
        if (c.lua_checkstack(L, 4) == 0) {
            self.recordError(p, what, "Lua stack exhausted");
            return false;
        }
        vm.startBudget(0, budget_ms);
        p.in_call += 1;
        c.lua_pushcclosure(L, msgHandler, 0);
        c.lua_pushcclosure(L, trampoline, 0);
        c.lua_pushlightuserdata(L, cl);
        const rc = c.lua_pcallk(L, 1, 0, -3, 0, null);
        p.in_call -= 1;
        if (rc == c.LUA_OK) {
            lua.pop(L, 1);
            return true;
        }
        var buf: [1200]u8 = undefined;
        const raw = lua.toString(L, -1) orelse "error object is not a string";
        var msg = buf[0..@min(raw.len, buf.len)];
        @memcpy(msg, raw[0..msg.len]);
        lua.pop(L, 2);
        if (vm.killed()) {
            msg = std.fmt.bufPrint(&buf, "{s}: took longer than {d} ms and was stopped", .{ what, budget_ms }) catch msg;
        } else if (rc == c.LUA_ERRMEM or vm.alloc_state.memory_hit) {
            msg = std.fmt.bufPrint(&buf, "{s}: out of memory (limit {d} MB; raise config.plugins[\"{s}\"].memory_mb)", .{ what, p.memory_mb, p.name }) catch msg;
        }
        // Lua may have kept the oversized garbage around; collect it so the
        // next call starts with room.
        _ = c.lua_gc(L, c.LUA_GCCOLLECT);
        self.recordError(p, what, msg);
        return false;
    }

    fn msgHandler(L_: ?*State) callconv(.C) c_int {
        const L = L_.?;
        const msg = c.lua_tolstring(L, 1, null);
        if (msg == null) {
            _ = c.lua_pushstring(L, "(error object is not a string)");
        } else if (c.lua_type(L, 1) == c.LUA_TSTRING) {
            // Already has a traceback (from the sandbox dispatcher)?
            if (std.mem.indexOf(u8, std.mem.span(msg), "stack traceback:") != null) return 1;
            c.luaL_traceback(L, L, msg, 1);
        }
        return 1;
    }

    fn trampoline(L_: ?*State) callconv(.C) c_int {
        const L = L_.?;
        const cl: *Call = @ptrCast(@alignCast(c.lua_touserdata(L, 1)));
        const p = cl.p;
        switch (cl.kind) {
            .setup => {
                if (c.luaL_loadbufferx(L, sandbox_src.ptr, sandbox_src.len, "=sandbox", "t") != c.LUA_OK) return c.lua_error(L);
                pushApi(L, p);
                pushInfo(L, p);
                c.lua_callk(L, 2, 3, 0, null);
                p.invoke_ref = c.luaL_ref(L, c.LUA_REGISTRYINDEX);
                p.dispatch_ref = c.luaL_ref(L, c.LUA_REGISTRYINDEX);
                // The environment stays referenced by the closures; keep it
                // in the registry too for `main`.
                c.lua_setfield(L, c.LUA_REGISTRYINDEX, "dt.env");
            },
            .main => {
                var nb: [160]u8 = undefined;
                const chunk = std.fmt.bufPrintZ(&nb, "@{s}/init.lua", .{p.name}) catch "@init.lua";
                if (c.luaL_loadbufferx(L, cl.src.ptr, cl.src.len, chunk.ptr, "t") != c.LUA_OK) return c.lua_error(L);
                _ = c.lua_getfield(L, c.LUA_REGISTRYINDEX, "dt.env");
                _ = c.lua_setupvalue(L, -2, 1);
                c.lua_callk(L, 0, 0, 0, null);
            },
            .dispatch => {
                _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, p.dispatch_ref);
                lua.pushString(L, cl.event);
                if (cl.payload) |v| value.push(L, v) else c.lua_pushnil(L);
                c.lua_callk(L, 2, 1, 0, null);
                readResult(L, cl);
            },
            .invoke => {
                _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, p.invoke_ref);
                c.lua_pushinteger(L, cl.cb);
                c.lua_pushboolean(L, @intFromBool(cl.drop));
                if (cl.payload) |v| value.push(L, v) else c.lua_pushnil(L);
                c.lua_callk(L, 3, 1, 0, null);
                readResult(L, cl);
            },
        }
        return 0;
    }

    fn readResult(L: *State, cl: *Call) void {
        switch (c.lua_type(L, -1)) {
            c.LUA_TBOOLEAN => cl.result = .{ .boolean = c.lua_toboolean(L, -1) != 0 },
            c.LUA_TSTRING => {
                const s = lua.toString(L, -1).?;
                if (cl.p.host.a.dupe(u8, s[0..@min(s.len, 64 * 1024)])) |d| {
                    cl.result = .{ .string = d };
                } else |_| {}
            },
            else => {},
        }
    }

    fn recordError(self: *Host, p: *Plugin, what: []const u8, msg: []const u8) void {
        p.errors_total += 1;
        self.setMessage(p, msg);
        self.log(p, "error", "{s}: {s}", .{ what, msg });
        const now = std.time.milliTimestamp();
        if (now - p.last_toast_ms >= Limits.toast_every_ms) {
            p.last_toast_ms = now;
            self.notice(p, .@"error", "Plugin {s}: {s}", .{ p.name, firstLine(msg) }, 6000);
        }
        p.error_times[p.error_next] = now;
        p.error_next = (p.error_next + 1) % p.error_times.len;
        const oldest = p.error_times[p.error_next];
        if (p.errors_total >= Limits.errors_to_disable and now - oldest <= Limits.error_window_ms and p.status == .running) {
            const r = std.fmt.bufPrint(&p.disable_reason, "{d} errors within a minute; last: {s}", .{ Limits.errors_to_disable, firstLine(msg) }) catch p.disable_reason[0..0];
            p.disable_reason_len = r.len;
            p.disable_pending = true;
        }
    }

    /// Applies a disable that was requested while the plugin was running.
    fn afterCall(self: *Host, p: *Plugin) void {
        if (!p.disable_pending or p.in_call > 0) return;
        p.disable_pending = false;
        const reason = p.disable_reason[0..p.disable_reason_len];
        self.teardown(p);
        p.status = .failed;
        var buf: [300]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "disabled for this session: {s}", .{reason}) catch "disabled";
        self.setMessage(p, msg);
        self.log(p, "error", "{s}", .{msg});
        self.notice(p, .@"error", "Plugin {s} was disabled: {s}", .{ p.name, reason }, 10_000);
    }

    // ------------------------------------------------------------ events

    /// Send `ev` to every running plugin that subscribed.
    pub fn emit(self: *Host, ev: Event, payload: ?Value) void {
        for (self.plugins.items) |p| {
            if (!p.running() or !p.subscribed.contains(ev)) continue;
            var cl = Call{ .p = p, .kind = .dispatch, .event = @tagName(ev), .payload = payload };
            _ = self.call(p, &cl, p.cpu_ms, @tagName(ev));
            self.freeResult(&cl);
            self.afterCall(p);
        }
    }

    /// `ev` with extra fields only plugins holding `screen` get (the command
    /// line in command_start / command_finish).
    pub fn emitWithPrivate(self: *Host, ev: Event, public: []const Entry, private: []const Entry) void {
        var buf: [16]Entry = undefined;
        const n = @min(public.len, buf.len);
        @memcpy(buf[0..n], public[0..n]);
        var m = n;
        for (private) |e| {
            if (m == buf.len) break;
            buf[m] = e;
            m += 1;
        }
        for (self.plugins.items) |p| {
            if (!p.running() or !p.subscribed.contains(ev)) continue;
            const fields = if (p.has(.screen)) buf[0..m] else buf[0..n];
            var cl = Call{ .p = p, .kind = .dispatch, .event = @tagName(ev), .payload = .{ .map = fields } };
            _ = self.call(p, &cl, p.cpu_ms, @tagName(ev));
            self.freeResult(&cl);
            self.afterCall(p);
        }
    }

    /// Whether anyone listens (so callers can skip building payloads).
    pub fn wants(self: *const Host, ev: Event) bool {
        for (self.plugins.items) |p| if (p.running() and p.subscribed.contains(ev)) return true;
        return false;
    }

    /// A key press; true if a plugin consumed it (it must not reach the shell).
    pub fn key(self: *Host, payload: Value) bool {
        for (self.plugins.items) |p| {
            if (!p.running() or !p.subscribed.contains(.key)) continue;
            var cl = Call{ .p = p, .kind = .dispatch, .event = "key", .payload = payload };
            const ok = self.call(p, &cl, p.cpu_ms, "key");
            const consumed = ok and cl.result == .boolean and cl.result.boolean;
            self.freeResult(&cl);
            self.afterCall(p);
            if (consumed) return true;
        }
        return false;
    }

    /// Completed output lines (main screen only; the caller filters).
    pub fn outputLines(self: *Host, lines: []const []const u8) void {
        for (self.plugins.items) |p| {
            if (!p.running() or !p.subscribed.contains(.output_line) or !p.has(.screen)) continue;
            for (lines[0..@min(lines.len, Limits.output_lines_per_batch)]) |line| {
                if (!p.running()) break;
                const fields = [_]Entry{.{ .key = "text", .value = .{ .string = line } }};
                var cl = Call{ .p = p, .kind = .dispatch, .event = "output_line", .payload = .{ .map = &fields } };
                _ = self.call(p, &cl, p.cpu_ms, "output_line");
                self.freeResult(&cl);
            }
            self.afterCall(p);
        }
    }

    /// Runs an AI suggestion through every `ai_suggestion` handler.
    pub fn filterSuggestion(self: *Host, text: []const u8, input: []const u8) SuggestionResult {
        var current: ?[]u8 = null;
        for (self.plugins.items) |p| {
            if (!p.running() or !p.subscribed.contains(.ai_suggestion) or !p.has(.ai)) continue;
            const fields = [_]Entry{
                .{ .key = "input", .value = .{ .string = input } },
                .{ .key = "text", .value = .{ .string = current orelse text } },
            };
            var cl = Call{ .p = p, .kind = .dispatch, .event = "ai_suggestion", .payload = .{ .map = &fields } };
            const ok = self.call(p, &cl, p.cpu_ms, "ai_suggestion");
            self.afterCall(p);
            if (!ok) continue;
            switch (cl.result) {
                .boolean => |b| if (!b) {
                    if (current) |s| self.a.free(s);
                    return .drop;
                },
                .string => |s| {
                    if (current) |old| self.a.free(old);
                    current = s;
                    cl.result = .none;
                },
                .none => {},
            }
            self.freeResult(&cl);
        }
        if (current) |s| return .{ .replace = s };
        return .keep;
    }

    fn freeResult(self: *Host, cl: *Call) void {
        if (cl.result == .string) self.a.free(cl.result.string);
        cl.result = .none;
    }

    fn invoke(self: *Host, p: *Plugin, cb: i64, drop: bool, payload: ?Value, what: []const u8) void {
        if (!p.running()) return;
        var cl = Call{ .p = p, .kind = .invoke, .cb = cb, .drop = drop, .payload = payload };
        _ = self.call(p, &cl, p.cpu_ms, what);
        self.freeResult(&cl);
        self.afterCall(p);
    }

    /// Run palette command `index` (into `commands`).
    pub fn runCommand(self: *Host, index: usize) void {
        if (index >= self.commands.items.len) return;
        const cmd = self.commands.items[index];
        var what: [80]u8 = undefined;
        self.invoke(cmd.plugin, cmd.cb, false, null, std.fmt.bufPrint(&what, "command {s}", .{cmd.id[0..@min(cmd.id.len, 60)]}) catch "command");
    }

    /// A plugin keybinding fired (`events.Action.plugin_binding`, arg = id).
    pub fn runBinding(self: *Host, id: u16) void {
        for (self.binds.items) |b| if (b.id == id) {
            self.invoke(b.plugin, b.cb, false, null, "keybinding");
            return;
        };
    }

    /// Clipboard text arrived for `dt.clipboard.get`.
    pub fn clipboardResult(self: *Host, text: []const u8) void {
        const waiters = self.clip_waiters.toOwnedSlice() catch return;
        defer self.a.free(waiters);
        for (waiters) |w| self.invoke(w.plugin, w.cb, true, .{ .string = text }, "clipboard callback");
    }

    pub fn wantsClipboard(self: *const Host) bool {
        return self.clip_waiters.items.len > 0;
    }

    // ------------------------------------------------------------ timers & jobs

    /// File descriptor that becomes readable when async results are ready.
    pub fn wakeFd(self: *const Host) @import("../platform/io.zig").Fd {
        return self.queue.wakeFd();
    }

    /// Milliseconds until the next timer or job deadline (null = none).
    pub fn nextDeadline(self: *const Host, now_ms: i64) ?i64 {
        var best: ?i64 = null;
        for (self.timers.items) |t| best = @min(best orelse t.due_ms, t.due_ms);
        for (self.pending.items) |j| best = @min(best orelse j.deadline_ms, j.deadline_ms);
        const b = best orelse return null;
        return @max(b - now_ms, 0);
    }

    /// Fire due timers, deliver finished jobs, time out stuck ones.
    pub fn tick(self: *Host, now_ms: i64) void {
        self.pollJobs();
        // Timers: collect the due ones first; callbacks may add or cancel.
        var due = std.ArrayList(Timer).init(self.a);
        defer due.deinit();
        var i: usize = 0;
        while (i < self.timers.items.len) {
            const t = &self.timers.items[i];
            if (t.due_ms <= now_ms) {
                due.append(t.*) catch break;
                if (t.interval_ms > 0) {
                    t.due_ms = now_ms + t.interval_ms;
                    i += 1;
                } else _ = self.timers.orderedRemove(i);
            } else i += 1;
        }
        for (due.items) |t| self.invoke(t.plugin, t.cb, t.interval_ms == 0, null, "timer");
        // Jobs past their deadline (an HTTP server that never answers).
        i = 0;
        while (i < self.pending.items.len) {
            const j = self.pending.items[i];
            if (j.deadline_ms <= now_ms) {
                _ = self.pending.orderedRemove(i);
                const fields = [_]Entry{
                    .{ .key = "ok", .value = .{ .boolean = false } },
                    .{ .key = "error", .value = .{ .string = "timed out" } },
                };
                self.invoke(j.plugin, j.cb, true, .{ .map = &fields }, "async callback");
            } else i += 1;
        }
    }

    pub fn pollJobs(self: *Host) void {
        var done = std.ArrayList(jobs.Done).init(self.a);
        defer {
            for (done.items) |*d| d.deinit();
            done.deinit();
        }
        self.queue.take(&done);
        for (done.items) |d| {
            const idx = for (self.pending.items, 0..) |j, k| {
                if (j.id == d.id) break k;
            } else continue;
            const j = self.pending.orderedRemove(idx);
            const ok = d.err.len == 0 and switch (d.kind) {
                .http => d.status >= 200 and d.status < 300,
                .exec => d.status == 0,
            };
            var fields: [6]Entry = undefined;
            var n: usize = 0;
            fields[n] = .{ .key = "ok", .value = .{ .boolean = ok } };
            n += 1;
            if (d.err.len > 0) {
                fields[n] = .{ .key = "error", .value = .{ .string = d.err } };
                n += 1;
            }
            switch (d.kind) {
                .http => {
                    fields[n] = .{ .key = "status", .value = .{ .integer = d.status } };
                    fields[n + 1] = .{ .key = "body", .value = .{ .string = d.body } };
                    n += 2;
                },
                .exec => {
                    fields[n] = .{ .key = "code", .value = .{ .integer = d.status } };
                    fields[n + 1] = .{ .key = "stdout", .value = .{ .string = d.body } };
                    fields[n + 2] = .{ .key = "stderr", .value = .{ .string = d.stderr } };
                    n += 3;
                },
            }
            if (d.truncated) {
                fields[n] = .{ .key = "truncated", .value = .{ .boolean = true } };
                n += 1;
            }
            self.invoke(j.plugin, j.cb, true, .{ .map = fields[0..n] }, if (d.kind == .http) "http callback" else "exec callback");
        }
    }

    // ------------------------------------------------------------ info

    pub fn setInfo(self: *Host, which: enum { cwd, title, ssh, theme }, s: []const u8) void {
        const list = switch (which) {
            .cwd => &self.info.cwd,
            .title => &self.info.title,
            .ssh => &self.info.ssh,
            .theme => &self.info.theme,
        };
        list.clearRetainingCapacity();
        list.appendSlice(self.a, s[0..@min(s.len, 4096)]) catch {};
    }

    /// Replace the tab snapshot (copied).
    pub fn setTabs(self: *Host, tabs: []const TabInfo, tab: u32, pane: u32) void {
        self.info.tab = tab;
        self.info.pane = pane;
        var ar = std.heap.ArenaAllocator.init(self.a);
        const copy = blk: {
            const al = ar.allocator();
            const out = al.alloc(TabInfo, tabs.len) catch break :blk null;
            for (tabs, out) |t, *o| {
                o.* = t;
                o.title = al.dupe(u8, t.title[0..@min(t.title.len, 256)]) catch break :blk null;
                o.panes = al.dupe(u32, t.panes) catch break :blk null;
            }
            break :blk out;
        };
        if (copy == null) {
            ar.deinit();
            return;
        }
        if (self.info.tabs_arena) |*old| old.deinit();
        self.info.tabs_arena = ar;
        self.info.tabs = copy.?;
    }

    /// Emit a tab / pane event ({ tab = .., pane = .. }).
    pub fn emitLayout(self: *Host, ev: Event, tab: u32, pane: ?u32) void {
        if (!self.wants(ev)) return;
        const S = struct {
            threadlocal var buf: [2]value.Entry = undefined;
        };
        S.buf[0] = .{ .key = "tab", .value = .{ .integer = tab } };
        var n: usize = 1;
        if (pane) |pn| {
            S.buf[1] = .{ .key = "pane", .value = .{ .integer = pn } };
            n = 2;
        }
        self.emit(ev, .{ .map = S.buf[0..n] });
    }

    // ------------------------------------------------------------ effects

    fn effect(self: *Host, e: Effect) void {
        if (self.effects.items.len >= 1024) {
            var d = e;
            d.deinit(self.a);
            return;
        }
        self.effects.append(e) catch {
            var d = e;
            d.deinit(self.a);
        };
    }

    pub fn clearEffects(self: *Host) void {
        for (self.effects.items) |*e| e.deinit(self.a);
        self.effects.clearRetainingCapacity();
    }

    fn notice(self: *Host, p: *Plugin, level: Level, comptime fmt: []const u8, args: anytype, timeout_ms: u32) void {
        const text = std.fmt.allocPrint(self.a, fmt, args) catch return;
        const src = self.a.dupe(u8, p.name) catch {
            self.a.free(text);
            return;
        };
        self.effect(.{ .notify = .{ .source = src, .text = text, .level = level, .timeout_ms = timeout_ms } });
    }

    // ------------------------------------------------------------ log

    fn openLog(self: *Host) void {
        const path = self.opts.log_path;
        if (std.fs.path.dirname(path)) |d| std.fs.cwd().makePath(d) catch {};
        // Keep it bounded: start over (keeping one old copy) past 1 MiB.
        if (std.fs.cwd().statFile(path)) |st| {
            if (st.size > 1024 * 1024) {
                var ob: [std.fs.max_path_bytes]u8 = undefined;
                if (std.fmt.bufPrint(&ob, "{s}.1", .{path})) |old| std.fs.cwd().rename(path, old) catch {} else |_| {}
            }
        } else |_| {}
        const f = std.fs.cwd().createFile(path, .{ .truncate = false, .mode = file_mode }) catch return;
        f.seekFromEnd(0) catch {};
        self.log_file = f;
    }

    pub fn log(self: *Host, p: ?*Plugin, level: []const u8, comptime fmt: []const u8, args: anytype) void {
        const f = self.log_file orelse return;
        var buf: [4400]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const w = fbs.writer();
        const now: u64 = @intCast(@max(std.time.timestamp(), 0));
        const es = std.time.epoch.EpochSeconds{ .secs = now };
        const day = es.getEpochDay().calculateYearDay();
        const md = day.calculateMonthDay();
        const ds = es.getDaySeconds();
        w.print("{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} [{s}] {s}: ", .{
            day.year,                        md.month.numeric(),      md.day_index + 1,
            ds.getHoursIntoDay(),            ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
            if (p) |pl| pl.name else "host", level,
        }) catch {};
        w.print(fmt, args) catch {
            const tail = "...";
            fbs.pos = buf.len - tail.len - 1;
            w.writeAll(tail) catch {};
        };
        w.writeByte('\n') catch {};
        f.writeAll(fbs.getWritten()) catch {};
    }

    /// Plugin-originated log lines are rate limited.
    fn pluginLog(self: *Host, p: *Plugin, level: []const u8, msg: []const u8) void {
        const now = std.time.milliTimestamp();
        if (now - p.log_window_start > 10_000) {
            p.log_window_start = now;
            p.log_lines = 0;
        }
        p.log_lines += 1;
        if (p.log_lines > Limits.log_lines_per_10s) {
            if (p.log_lines == Limits.log_lines_per_10s + 1) self.log(p, "warn", "too many log lines; dropping for a few seconds", .{});
            return;
        }
        self.log(p, level, "{s}", .{msg[0..@min(msg.len, 4000)]});
    }
};

fn firstLine(s: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, s, '\n') orelse s.len;
    return s[0..@min(end, 200)];
}

fn fmtSet(s: permissions.Set) []const u8 {
    const S = struct {
        threadlocal var buf: [160]u8 = undefined;
    };
    return permissions.format(s, &S.buf);
}

fn dupeList(a: std.mem.Allocator, list: []const []const u8) ![]const []const u8 {
    const out = try a.alloc([]const u8, list.len);
    for (list, out) |s, *o| o.* = try a.dupe(u8, s);
    return out;
}

fn cloneValue(a: std.mem.Allocator, v: Value) !Value {
    return switch (v) {
        .string => |s| .{ .string = try a.dupe(u8, s) },
        .list => |items| blk: {
            const out = try a.alloc(Value, items.len);
            for (items, out) |it, *o| o.* = try cloneValue(a, it);
            break :blk .{ .list = out };
        },
        .map => |entries| blk: {
            const out = try a.alloc(Entry, entries.len);
            for (entries, out) |e, *o| o.* = .{ .key = try a.dupe(u8, e.key), .value = try cloneValue(a, e.value) };
            break :blk .{ .map = out };
        },
        else => v,
    };
}

// ================================================================ dt API
//
// C functions behind sandbox.lua's `api` table. Each gets its plugin as a
// light-userdata upvalue. They run inside the protected call, so a Lua
// error is fine; but a raised error skips Zig `defer`s, so the rule here is:
// read arguments first, then allocate (into host-owned lists), then push
// results, and raise only by returning error.LuaMsg.

const ApiFn = fn (p: *Plugin, L: *State) error{LuaMsg}!c_int;

fn wrap(comptime f: ApiFn) lua.CFn {
    return struct {
        fn cf(L_: ?*State) callconv(.C) c_int {
            const L = L_.?;
            const p: *Plugin = @ptrCast(@alignCast(c.lua_touserdata(L, lua.upvalueIndex(1))));
            if (f(p, L)) |n| return n else |_| {}
            var where: [128:0]u8 = undefined;
            userLocation(L, &where);
            return c.luaL_error(L, "%s%s", @as([*:0]const u8, &where), @as([*:0]const u8, &p.err_buf));
        }
    }.cf;
}

/// "name/init.lua:12: " for the innermost frame in the plugin's own code
/// (skipping the sandbox glue), or "".
fn userLocation(L: *State, out: *[128:0]u8) void {
    out[0] = 0;
    var level: c_int = 1;
    while (level < 16) : (level += 1) {
        var ar: c.lua_Debug = undefined;
        if (c.lua_getstack(L, level, &ar) == 0) return;
        if (c.lua_getinfo(L, "Sl", &ar) == 0) continue;
        if (ar.source == null or ar.source[0] != '@' or ar.currentline <= 0) continue;
        const src = std.mem.sliceTo(&ar.short_src, 0);
        _ = std.fmt.bufPrintZ(out, "{s}:{d}: ", .{ src, ar.currentline }) catch {};
        return;
    }
}

const api_fns = .{
    .{ "killed", apiKilled },
    .{ "subscribe", apiSubscribe },
    .{ "unsubscribe", apiUnsubscribe },
    .{ "report", apiReport },
    .{ "log", apiLog },
    .{ "has", apiHas },
    .{ "module", apiModule },
    .{ "command", apiCommand },
    .{ "bind", apiBind },
    .{ "status_set", apiStatusSet },
    .{ "status_clear", apiStatusClear },
    .{ "notify", apiNotify },
    .{ "timer", apiTimer },
    .{ "timer_cancel", apiTimerCancel },
    .{ "theme_register", apiThemeRegister },
    .{ "theme_set", apiThemeSet },
    .{ "theme_list", apiThemeList },
    .{ "theme_current", apiThemeCurrent },
    .{ "action", apiAction },
    .{ "term", apiTerm },
    .{ "tabs_list", apiTabsList },
    .{ "tab", apiTab },
    .{ "pane", apiPane },
    .{ "screen_text", apiScreenText },
    .{ "screen_cursor", apiScreenCursor },
    .{ "pty_write", apiPtyWrite },
    .{ "clipboard_set", apiClipboardSet },
    .{ "clipboard_get", apiClipboardGet },
    .{ "http", apiHttp },
    .{ "exec", apiExec },
    .{ "fs", apiFs },
};

fn pushApi(L: *State, p: *Plugin) void {
    c.lua_createtable(L, 0, api_fns.len);
    inline for (api_fns) |entry| {
        c.lua_pushlightuserdata(L, p);
        c.lua_pushcclosure(L, wrap(entry[1]), 1);
        c.lua_setfield(L, -2, entry[0]);
    }
}

fn setStr(L: *State, key: [*:0]const u8, s: []const u8) void {
    lua.pushString(L, s);
    c.lua_setfield(L, -2, key);
}

fn pushInfo(L: *State, p: *Plugin) void {
    c.lua_createtable(L, 0, 8);
    setStr(L, "version", p.host.opts.version);
    setStr(L, "os", @tagName(builtin.os.tag));
    setStr(L, "data_dir", p.data_dir);
    c.lua_createtable(L, 0, 4);
    setStr(L, "name", p.name);
    setStr(L, "version", p.version);
    setStr(L, "description", p.description);
    setStr(L, "dir", p.dir);
    c.lua_setfield(L, -2, "plugin");
    if (p.settings) |s| {
        value.push(L, s);
        c.lua_setfield(L, -2, "settings");
    }
    c.lua_createtable(L, 0, 0);
    var it = p.granted.iterator();
    var i: c.lua_Integer = 1;
    while (it.next()) |perm| : (i += 1) {
        lua.pushString(L, @tagName(perm));
        c.lua_rawseti(L, -2, i);
    }
    c.lua_setfield(L, -2, "permissions");
}

// ---------------------------------------------------------------- arg helpers

fn argStr(p: *Plugin, L: *State, idx: c_int, what: []const u8, name: []const u8) error{LuaMsg}![]const u8 {
    return lua.toString(L, idx) orelse p.raise("{s}: '{s}' must be a string, got {s}", .{ what, name, lua.typeName(L, idx) });
}

fn optStr(p: *Plugin, L: *State, idx: c_int, what: []const u8, name: []const u8) error{LuaMsg}!?[]const u8 {
    if (lua.isNil(L, idx)) return null;
    return try argStr(p, L, idx, what, name);
}

fn argInt(p: *Plugin, L: *State, idx: c_int, what: []const u8, name: []const u8, min: i64, max: i64) error{LuaMsg}!i64 {
    var isnum: c_int = 0;
    const v = c.lua_tonumberx(L, idx, &isnum);
    if (isnum == 0 or c.lua_type(L, idx) != c.LUA_TNUMBER or v != @floor(v) or v < @as(f64, @floatFromInt(min)) or v > @as(f64, @floatFromInt(max)))
        return p.raise("{s}: '{s}' must be a whole number from {d} to {d}", .{ what, name, min, max });
    return @intFromFloat(v);
}

/// Push field `name` of the (optional) table at `idx`; nil if there is no table.
fn field(L: *State, idx: c_int, name: [*:0]const u8) void {
    if (c.lua_type(L, idx) == c.LUA_TTABLE) {
        _ = c.lua_getfield(L, idx, name);
    } else c.lua_pushnil(L);
}

fn optTable(p: *Plugin, L: *State, idx: c_int, what: []const u8) error{LuaMsg}!void {
    const t = c.lua_type(L, idx);
    if (t != c.LUA_TTABLE and t > c.LUA_TNIL) return p.raise("{s}: options must be a table, got {s}", .{ what, lua.typeName(L, idx) });
}

fn countOf(comptime T: type, list: []const T, p: *Plugin) usize {
    var n: usize = 0;
    for (list) |it| {
        if (it.plugin == p) n += 1;
    }
    return n;
}

fn parseHex(s: []const u8) ?u32 {
    const hex = if (s.len > 0 and s[0] == '#') s[1..] else s;
    if (hex.len == 3) {
        var v: u32 = 0;
        for (hex) |ch| {
            const d = std.fmt.charToDigit(ch, 16) catch return null;
            v = (v << 8) | (d * 17);
        }
        return v;
    }
    if (hex.len != 6) return null;
    return std.fmt.parseInt(u32, hex, 16) catch null;
}

// ---------------------------------------------------------------- core

fn apiKilled(p: *Plugin, L: *State) error{LuaMsg}!c_int {
    c.lua_pushboolean(L, @intFromBool(if (p.vm) |*vm| vm.killed() else true));
    return 1;
}

fn eventNames() []const u8 {
    comptime var s: []const u8 = "";
    inline for (@typeInfo(Event).Enum.fields, 0..) |f, i| s = s ++ (if (i > 0) ", " else "") ++ f.name;
    return s;
}

fn apiSubscribe(p: *Plugin, L: *State) error{LuaMsg}!c_int {
    const name = try argStr(p, L, 1, "dt.on", "event");
    const ev = std.meta.stringToEnum(Event, name) orelse
        return p.raise("dt.on: unknown event '{s}' (events: {s})", .{ name[0..@min(name.len, 40)], comptime eventNames() });
    if (ev.needs()) |perm| {
        var what: [40]u8 = undefined;
        try p.need(perm, std.fmt.bufPrint(&what, "dt.on('{s}')", .{name}) catch "dt.on");
    }
    p.subscribed.insert(ev);
    return 0;
}

fn apiUnsubscribe(p: *Plugin, L: *State) error{LuaMsg}!c_int {
    const name = try argStr(p, L, 1, "dt.off", "event");
    if (std.meta.stringToEnum(Event, name)) |ev| p.subscribed.remove(ev);
    return 0;
}

fn apiReport(p: *Plugin, L: *State) error{LuaMsg}!c_int {
    const msg = lua.toString(L, 1) orelse "error";
    const ev = lua.toString(L, 2) orelse "?";
    var what: [64]u8 = undefined;
    p.host.recordError(p, std.fmt.bufPrint(&what, "'{s}' handler", .{ev[0..@min(ev.len, 32)]}) catch "handler", msg);
    return 0;
}

fn apiLog(p: *Plugin, L: *State) error{LuaMsg}!c_int {
    const level = lua.toString(L, 1) orelse "info";
    const msg = lua.toString(L, 2) orelse "";
    p.host.pluginLog(p, if (std.mem.eql(u8, level, "warn")) "warn" else "info", msg);
    return 0;
}

fn apiHas(p: *Plugin, L: *State) error{LuaMsg}!c_int {
    const name = try argStr(p, L, 1, "dt.has", "permission");
    const perm = Permission.parse(name);
    c.lua_pushboolean(L, @intFromBool(perm != null and p.has(perm.?)));
    return 1;
}

fn apiModule(p: *Plugin, L: *State) error{LuaMsg}!c_int {
    const name = try argStr(p, L, 1, "require", "name");
    var ok = name.len > 0 and name.len <= 100 and name[0] != '.' and name[name.len - 1] != '.';
    for (name) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '.')) ok = false;
    }
    if (!ok or std.mem.indexOf(u8, name, "..") != null) return p.raise("require: invalid module name '{s}' (modules are files in the plugin's directory, e.g. require(\"util\") or require(\"lib.json\"))", .{name[0..@min(name.len, 60)]});
    var rel: [128]u8 = undefined;
    @memcpy(rel[0..name.len], name);
    std.mem.replaceScalar(u8, rel[0..name.len], '.', '/');
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const full = std.fmt.bufPrint(&path, "{s}/{s}.lua", .{ p.dir, rel[0..name.len] }) catch return p.raise("require: path too long", .{});
    const h = p.host;
    h.scratch.clearRetainingCapacity();
    {
        const f = std.fs.cwd().openFile(full, .{}) catch return p.raise("require: module '{s}' not found ({s}/{s}.lua)", .{ name, p.name, rel[0..name.len] });
        defer f.close();
        f.reader().readAllArrayList(&h.scratch, Limits.max_module) catch return p.raise("require: cannot read module '{s}'", .{name});
    }
    lua.pushString(L, h.scratch.items);
    var cn: [180]u8 = undefined;
    lua.pushString(L, std.fmt.bufPrint(&cn, "@{s}/{s}.lua", .{ p.name, rel[0..name.len] }) catch "@module");
    return 2;
}

// ---------------------------------------------------------------- palette, keys, status

fn apiCommand(p: *Plugin, L: *State) error{LuaMsg}!c_int {
    const id = try argStr(p, L, 1, "dt.command", "id");
    const title = try argStr(p, L, 2, "dt.command", "title");
    const cb = c.lua_tointegerx(L, 3, null);
    if (id.len == 0 or id.len > 64) return p.raise("dt.command: 'id' must be 1-64 characters", .{});
    if (title.len == 0 or title.len > 100) return p.raise("dt.command: 'title' must be 1-100 characters", .{});
    const h = p.host;
    for (h.commands.items) |*cmd| if (cmd.plugin == p and std.mem.eql(u8, cmd.id, id)) {
        const t = h.a.dupe(u8, title) catch return p.raise("out of memory", .{});
        h.a.free(cmd.title);
        cmd.title = t;
        cmd.cb = cb;
        h.effect(.redraw);
        return 0;
    };
    if (countOf(Command, h.commands.items, p) >= Limits.max_commands) return p.raise("dt.command: at most {d} commands per plugin", .{Limits.max_commands});
    const id_d = h.a.dupe(u8, id) catch return p.raise("out of memory", .{});
    const title_d = h.a.dupe(u8, title) catch {
        h.a.free(id_d);
        return p.raise("out of memory", .{});
    };
    h.commands.append(.{ .plugin = p, .id = id_d, .title = title_d, .cb = cb }) catch {
        h.a.free(id_d);
        h.a.free(title_d);
        return p.raise("out of memory", .{});
    };
    h.effect(.redraw);
    return 0;
}

fn apiBind(p: *Plugin, L: *State) error{LuaMsg}!c_int {
    const spec = try argStr(p, L, 1, "dt.bind", "chord");
    const cb = c.lua_tointegerx(L, 2, null);
    const chord = events.parseChord(spec) catch |err|
        return p.raise("dt.bind: bad key \"{s}\" ({s}; e.g. \"ctrl+alt+t\")", .{ spec[0..@min(spec.len, 40)], switch (err) {
        error.UnknownModifier => "modifiers are ctrl, shift, alt",
        else => "unknown key name",
    } });
    if (!chord.mods.ctrl and !chord.mods.alt and !(chord.sym >= 0xffbe and chord.sym <= 0xffc9))
        return p.raise("dt.bind: \"{s}\" would swallow normal typing; use ctrl or alt (or a function key)", .{spec});
    const h = p.host;
    if (h.taken(chord)) return p.raise("dt.bind: \"{s}\" is already a terminal shortcut", .{spec});
    for (h.binds.items) |*b| {
        if (b.chord.sym != chord.sym or @as(u3, @bitCast(b.chord.mods)) != @as(u3, @bitCast(chord.mods))) continue;
        if (b.plugin != p) return p.raise("dt.bind: \"{s}\" is already bound by plugin {s}", .{ spec, b.plugin.name });
        b.cb = cb;
        return 0;
    }
    if (countOf(Bind, h.binds.items, p) >= Limits.max_binds) return p.raise("dt.bind: at most {d} keybindings per plugin", .{Limits.max_binds});
    const sd = h.a.dupe(u8, spec) catch return p.raise("out of memory", .{});
    h.binds.append(.{ .id = h.next_bind, .plugin = p, .chord = chord, .spec = sd, .cb = cb }) catch {
        h.a.free(sd);
        return p.raise("out of memory", .{});
    };
    h.next_bind +%= 1;
    if (h.next_bind == 0) h.next_bind = 1;
    h.effect(.bindings_changed);
    return 0;
}

fn apiStatusSet(p: *Plugin, L: *State) error{LuaMsg}!c_int {
    const what = "dt.status.set";
    const id = try argStr(p, L, 1, what, "id");
    const text_in = if (lua.isNil(L, 2)) "" else lua.toString(L, 2) orelse blk: {
        // Numbers are fine too.
        if (c.lua_type(L, 2) == c.LUA_TNUMBER) {
            _ = c.lua_tolstring(L, 2, null);
            break :blk lua.toString(L, 2).?;
        }
        return p.raise("{s}: text must be a string", .{what});
    };
    try optTable(p, L, 3, what);
    field(L, 3, "align");
    const align_s = try optStr(p, L, -1, what, "align");
    field(L, 3, "fg");
    const fg_s = try optStr(p, L, -1, what, "fg");
    if (id.len == 0 or id.len > 32) return p.raise("{s}: 'id' must be 1-32 characters", .{what});
    var right = false;
    if (align_s) |a| {
        if (std.mem.eql(u8, a, "right")) right = true else if (!std.mem.eql(u8, a, "left")) return p.raise("{s}: align must be \"left\" or \"right\"", .{what});
    }
    var fg: ?u32 = null;
    if (fg_s) |s| fg = parseHex(s) orelse return p.raise("{s}: fg must be a colour like \"#88c0d0\"", .{what});
    // One line, bounded.
    var clean: [200]u8 = undefined;
    var n: usize = 0;
    for (text_in) |ch| {
        if (n == clean.len) break;
        clean[n] = if (ch < 0x20 or ch == 0x7f) ' ' else ch;
        n += 1;
    }
    const text = trimUtf8(clean[0..n]);
    const h = p.host;
    for (h.segments.items) |*s| if (s.plugin == p and std.mem.eql(u8, s.id, id)) {
        if (std.mem.eql(u8, s.text, text) and s.right == right and s.fg == fg) return 0;
        const t = h.a.dupe(u8, text) catch return p.raise("out of memory", .{});
        h.a.free(s.text);
        s.text = t;
        s.right = right;
        s.fg = fg;
        h.effect(.redraw);
        return 0;
    };
    if (countOf(Segment, h.segments.items, p) >= Limits.max_segments) return p.raise("{s}: at most {d} segments per plugin", .{ what, Limits.max_segments });
    const id_d = h.a.dupe(u8, id) catch return p.raise("out of memory", .{});
    const t = h.a.dupe(u8, text) catch {
        h.a.free(id_d);
        return p.raise("out of memory", .{});
    };
    h.segments.append(.{ .plugin = p, .id = id_d, .text = t, .right = right, .fg = fg }) catch {
        h.a.free(id_d);
        h.a.free(t);
        return p.raise("out of memory", .{});
    };
    h.effect(.redraw);
    return 0;
}

/// Drop a partial UTF-8 sequence at the end (after truncation).
fn trimUtf8(s: []const u8) []const u8 {
    var end = s.len;
    var back: usize = 0;
    while (end > 0 and back < 4) : (back += 1) {
        const ch = s[end - 1];
        if (ch < 0x80) break;
        if (ch >= 0xC0) {
            const need = std.unicode.utf8ByteSequenceLength(ch) catch return s[0 .. end - 1];
            if (need > back + 1) return s[0 .. end - 1];
            break;
        }
        end -= 1;
    }
    return s;
}

fn apiStatusClear(p: *Plugin, L: *State) error{LuaMsg}!c_int {
    const id = try optStr(p, L, 1, "dt.status.clear", "id");
    const h = p.host;
    var i: usize = 0;
    var changed = false;
    while (i < h.segments.items.len) {
        const s = h.segments.items[i];
        if (s.plugin == p and (id == null or std.mem.eql(u8, s.id, id.?))) {
            h.a.free(s.id);
            h.a.free(s.text);
            _ = h.segments.orderedRemove(i);
            changed = true;
        } else i += 1;
    }
    if (changed) h.effect(.redraw);
    return 0;
}

fn apiNotify(p: *Plugin, L: *State) error{LuaMsg}!c_int {
    const what = "dt.notify";
    const text = try argStr(p, L, 1, what, "text");
    try optTable(p, L, 2, what);
    field(L, 2, "level");
    const level_s = try optStr(p, L, -1, what, "level");
    field(L, 2, "timeout_ms");
    const timeout: i64 = if (lua.isNil(L, -1)) 4000 else try argInt(p, L, -1, what, "timeout_ms", 500, 60_000);
    field(L, 2, "desktop");
    const desktop = c.lua_toboolean(L, -1) != 0;
    const level: Level = if (level_s) |s| std.meta.stringToEnum(Level, s) orelse
        return p.raise("{s}: level must be \"info\", \"success\", \"warn\" or \"error\"", .{what}) else .info;
    const now = std.time.milliTimestamp();
    if (now - p.notice_times[p.notice_next] < 10_000) {
        p.host.log(p, "warn", "notification dropped (more than {d} in 10 s): {s}", .{ Limits.notices_per_10s, firstLine(text) });
        c.lua_pushboolean(L, 0);
        return 1;
    }
    p.notice_times[p.notice_next] = now;
    p.notice_next = (p.notice_next + 1) % p.notice_times.len;
    const h = p.host;
    const t = h.a.dupe(u8, text[0..@min(text.len, 500)]) catch return p.raise("out of memory", .{});
    const src = h.a.dupe(u8, p.name) catch {
        h.a.free(t);
        return p.raise("out of memory", .{});
    };
    h.effect(.{ .notify = .{ .source = src, .text = t, .level = level, .timeout_ms = @intCast(timeout), .desktop = desktop } });
    c.lua_pushboolean(L, 1);
    return 1;
}

fn apiTimer(p: *Plugin, L: *State) error{LuaMsg}!c_int {
    const cb = c.lua_tointegerx(L, 1, null);
    const repeat = c.lua_toboolean(L, 3) != 0;
    const what = if (repeat) "dt.timer.every" else "dt.timer.after";
    const min: i64 = if (repeat) Limits.min_interval_ms else 0;
    const ms = try argInt(p, L, 2, what, "ms", min, 24 * 3600 * 1000);
    const h = p.host;
    if (countOf(Timer, h.timers.items, p) >= Limits.max_timers) return p.raise("{s}: at most {d} timers per plugin", .{ what, Limits.max_timers });
    h.timers.append(.{ .plugin = p, .cb = cb, .due_ms = std.time.milliTimestamp() + ms, .interval_ms = if (repeat) @intCast(ms) else 0 }) catch return p.raise("out of memory", .{});
    return 0;
}

fn apiTimerCancel(p: *Plugin, L: *State) error{LuaMsg}!c_int {
    const cb = c.lua_tointegerx(L, 1, null);
    const h = p.host;
    for (h.timers.items, 0..) |t, i| if (t.plugin == p and t.cb == cb) {
        _ = h.timers.orderedRemove(i);
        c.lua_pushboolean(L, 1);
        return 1;
    };
    c.lua_pushboolean(L, 0);
    return 1;
}

// ---------------------------------------------------------------- themes

fn apiThemeRegister(p: *Plugin, L: *State) error{LuaMsg}!c_int {
    const what = "dt.theme.register";
    if (c.lua_type(L, 1) != c.LUA_TTABLE) return p.raise("{s}: expected a table like {{ name = \"mine\", fg = \"#ddd\", bg = \"#111\", ansi = {{ ...16 colours }} }}", .{what});
    field(L, 1, "name");
    const name = try argStr(p, L, -1, what, "name");
    if (name.len == 0 or name.len > 32) return p.raise("{s}: name must be 1-32 characters", .{what});
    for (name) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_')) return p.raise("{s}: name may only use letters, digits, - and _", .{what});
    if (themes.find(name) != null) return p.raise("{s}: \"{s}\" is a bundled theme; pick another name", .{ what, name });
    var t = themes.Theme{ .name = "", .fg = 0, .bg = 0, .ansi = color.ansi16 };
    const Slot = struct { []const u8, *u32, bool };
    const slots = [_]Slot{
        .{ "fg", &t.fg, true },
        .{ "bg", &t.bg, true },
        .{ "cursor", &t.cursor, false },
        .{ "cursor_text", &t.cursor_text, false },
        .{ "selection_bg", &t.selection_bg, false },
        .{ "selection_fg", &t.selection_fg, false },
    };
    inline for (slots) |s| {
        _ = c.lua_getfield(L, 1, s[0].ptr);
        if (lua.isNil(L, -1)) {
            if (s[2]) return p.raise("{s}: '{s}' is required", .{ what, s[0] });
        } else {
            const v = try argStr(p, L, -1, what, s[0]);
            s[1].* = parseHex(v) orelse return p.raise("{s}: '{s}' must be a colour like \"#1e1e2e\"", .{ what, s[0] });
        }
        lua.pop(L, 1);
    }
    field(L, 1, "ansi");
    if (!lua.isNil(L, -1)) {
        if (c.lua_type(L, -1) != c.LUA_TTABLE or c.lua_rawlen(L, -1) != 16) return p.raise("{s}: 'ansi' must list 16 colours", .{what});
        var i: c.lua_Integer = 1;
        while (i <= 16) : (i += 1) {
            _ = c.lua_rawgeti(L, -1, i);
            const v = lua.toString(L, -1) orelse return p.raise("{s}: ansi[{d}] must be a colour string", .{ what, i });
            t.ansi[@intCast(i - 1)] = parseHex(v) orelse return p.raise("{s}: ansi[{d}] must be a colour like \"#ff5555\"", .{ what, i });
            lua.pop(L, 1);
        }
    }
    const h = p.host;
    for (h.reg_themes.items) |*r| if (std.mem.eql(u8, r.theme.name, name)) {
        if (r.plugin != p) return p.raise("{s}: theme \"{s}\" already registered by plugin {s}", .{ what, name, r.plugin.name });
        t.name = r.theme.name;
        r.theme = t;
        return 0;
    };
    if (countOf(RegTheme, h.reg_themes.items, p) >= Limits.max_themes) return p.raise("{s}: at most {d} themes per plugin", .{ what, Limits.max_themes });
    t.name = h.a.dupe(u8, name) catch return p.raise("out of memory", .{});
    h.reg_themes.append(.{ .plugin = p, .theme = t }) catch {
        h.a.free(t.name);
        return p.raise("out of memory", .{});
    };
    return 0;
}

pub fn findTheme(h: *const Host, name: []const u8) ?themes.Theme {
    for (h.reg_themes.items) |r| if (std.mem.eql(u8, r.theme.name, name)) return r.theme;
    if (themes.find(name)) |t| return t.*;
    return null;
}

fn apiThemeSet(p: *Plugin, L: *State) error{LuaMsg}!c_int {
    const name = try argStr(p, L, 1, "dt.theme.set", "name");
    const h = p.host;
    const t = findTheme(h, name) orelse return p.raise("dt.theme.set: unknown theme \"{s}\" (see dt.theme.list())", .{name[0..@min(name.len, 40)]});
    const nd = h.a.dupe(u8, name) catch return p.raise("out of memory", .{});
    h.effect(.{ .theme = .{ .name = nd, .palette = t.palette() } });
    h.setInfo(.theme, name);
    return 0;
}

fn apiThemeList(p: *Plugin, L: *State) error{LuaMsg}!c_int {
    const h = p.host;
    c.lua_createtable(L, @intCast(themes.all.len + h.reg_themes.items.len), 0);
    var i: c.lua_Integer = 1;
    for (themes.all) |t| {
        lua.pushString(L, t.name);
        c.lua_rawseti(L, -2, i);
        i += 1;
    }
    for (h.reg_themes.items) |r| {
        lua.pushString(L, r.theme.name);
        c.lua_rawseti(L, -2, i);
        i += 1;
    }
    return 1;
}

fn apiThemeCurrent(p: *Plugin, L: *State) error{LuaMsg}!c_int {
    lua.pushString(L, p.host.info.theme.items);
    return 1;
}

/// Built-in actions a plugin may trigger (nothing that reads or writes the
/// clipboard or types into the shell: those have their own permissions).
pub const plugin_actions = [_]events.Action{
    .search,          .scroll_page_up,    .scroll_page_down, .scroll_line_up, .scroll_line_down,
    .scroll_top,      .scroll_bottom,     .zoom_in,          .zoom_out,       .zoom_reset,
    .select_all,      .clear_selection,   .reload_config,    .ai_explain,     .ssh_palette,
    .command_palette, .toggle_status_bar,
    // Tabs and panes.
    .new_tab,          .close_tab,      .next_tab,
    .prev_tab,        .move_tab_left,     .move_tab_right,   .toggle_tab_bar, .goto_tab_1,
    .goto_tab_2,      .goto_tab_3,        .goto_tab_4,       .goto_tab_5,     .goto_tab_6,
    .goto_tab_7,      .goto_tab_8,        .goto_tab_9,       .split_right,    .split_down,
    .close_pane,      .focus_left,        .focus_right,      .focus_up,       .focus_down,
    .next_pane,       .prev_pane,         .resize_left,      .resize_right,   .resize_up,
    .resize_down,     .zoom_pane,         .equalize_panes,
};

fn apiAction(p: *Plugin, L: *State) error{LuaMsg}!c_int {
    const name = try argStr(p, L, 1, "dt.action", "name");
    const act = events.Action.parse(name);
    const allowed = for (plugin_actions) |a| {
        if (act != null and a == act.?) break true;
    } else false;
    if (!allowed) {
        comptime var list: []const u8 = "";
        inline for (plugin_actions, 0..) |a, i| list = list ++ (if (i > 0) ", " else "") ++ @tagName(a);
        return p.raise("dt.action: \"{s}\" is not available to plugins (available: {s})", .{ name[0..@min(name.len, 40)], list });
    }
    p.host.effect(.{ .action = act.? });
    return 0;
}

fn apiTabsList(p: *Plugin, L: *State) error{LuaMsg}!c_int {
    const info = &p.host.info;
    c.lua_createtable(L, @intCast(info.tabs.len), 0);
    for (info.tabs, 1..) |t, i| {
        c.lua_createtable(L, 0, 5);
        c.lua_pushinteger(L, t.id);
        c.lua_setfield(L, -2, "id");
        setStr(L, "title", t.title);
        c.lua_pushboolean(L, @intFromBool(t.active));
        c.lua_setfield(L, -2, "active");
        c.lua_pushinteger(L, t.focused_pane);
        c.lua_setfield(L, -2, "focused_pane");
        c.lua_createtable(L, @intCast(t.panes.len), 0);
        for (t.panes, 1..) |pn, j| {
            c.lua_pushinteger(L, pn);
            c.lua_rawseti(L, -2, @intCast(j));
        }
        c.lua_setfield(L, -2, "panes");
        c.lua_rawseti(L, -2, @intCast(i));
    }
    return 1;
}

fn tabExists(p: *Plugin, id: u32) bool {
    for (p.host.info.tabs) |t| if (t.id == id) return true;
    return false;
}

fn paneExists(p: *Plugin, id: u32) bool {
    for (p.host.info.tabs) |t| for (t.panes) |pn| if (pn == id) return true;
    return false;
}

/// api.tab(op, id, arg): op = "new" | "focus" | "close" | "rename".
/// Returns false for an unknown id.
fn apiTab(p: *Plugin, L: *State) error{LuaMsg}!c_int {
    const op = try argStr(p, L, 1, "dt.tabs", "op");
    const a = p.host.a;
    if (std.mem.eql(u8, op, "new")) {
        const cwd = try optStr(p, L, 2, "dt.tabs.new", "cwd");
        const owned: ?[]u8 = if (cwd) |d| (a.dupe(u8, d[0..@min(d.len, 4096)]) catch return p.raise("out of memory", .{})) else null;
        p.host.effect(.{ .layout = .{ .tab_new = owned } });
        c.lua_pushboolean(L, 1);
        return 1;
    }
    const id: u32 = @intCast(try argInt(p, L, 2, "dt.tabs", "id", 0, std.math.maxInt(u32)));
    if (!tabExists(p, id)) {
        c.lua_pushboolean(L, 0);
        return 1;
    }
    if (std.mem.eql(u8, op, "focus")) {
        p.host.effect(.{ .layout = .{ .tab_focus = id } });
    } else if (std.mem.eql(u8, op, "close")) {
        p.host.effect(.{ .layout = .{ .tab_close = id } });
    } else if (std.mem.eql(u8, op, "rename")) {
        const name = try argStr(p, L, 3, "dt.tabs.rename", "name");
        const owned = a.dupe(u8, name[0..@min(name.len, 128)]) catch return p.raise("out of memory", .{});
        p.host.effect(.{ .layout = .{ .tab_rename = .{ .id = id, .name = owned } } });
    } else return p.raise("dt.tabs: unknown operation '{s}'", .{op[0..@min(op.len, 32)]});
    c.lua_pushboolean(L, 1);
    return 1;
}

/// api.pane(op, arg): op = "split" (arg "right"/"down") | "focus" | "close".
fn apiPane(p: *Plugin, L: *State) error{LuaMsg}!c_int {
    const op = try argStr(p, L, 1, "dt.panes", "op");
    if (std.mem.eql(u8, op, "split")) {
        const dir = (try optStr(p, L, 2, "dt.panes.split", "direction")) orelse "right";
        const d: @TypeOf(@as(LayoutOp, undefined).pane_split) = if (std.mem.eql(u8, dir, "right")) .right else if (std.mem.eql(u8, dir, "down")) .down else return p.raise("dt.panes.split: direction must be \"right\" or \"down\"", .{});
        p.host.effect(.{ .layout = .{ .pane_split = d } });
        c.lua_pushboolean(L, 1);
        return 1;
    }
    const id: u32 = @intCast(try argInt(p, L, 2, "dt.panes", "id", 0, std.math.maxInt(u32)));
    if (!paneExists(p, id)) {
        c.lua_pushboolean(L, 0);
        return 1;
    }
    if (std.mem.eql(u8, op, "focus")) {
        p.host.effect(.{ .layout = .{ .pane_focus = id } });
    } else if (std.mem.eql(u8, op, "close")) {
        p.host.effect(.{ .layout = .{ .pane_close = id } });
    } else return p.raise("dt.panes: unknown operation '{s}'", .{op[0..@min(op.len, 32)]});
    c.lua_pushboolean(L, 1);
    return 1;
}

fn apiTerm(p: *Plugin, L: *State) error{LuaMsg}!c_int {
    const k = try argStr(p, L, 1, "dt.term", "key");
    const info = &p.host.info;
    if (std.mem.eql(u8, k, "cwd")) {
        lua.pushString(L, info.cwd.items);
    } else if (std.mem.eql(u8, k, "title")) {
        lua.pushString(L, info.title.items);
    } else if (std.mem.eql(u8, k, "ssh")) {
        if (info.ssh.items.len == 0) c.lua_pushnil(L) else lua.pushString(L, info.ssh.items);
    } else if (std.mem.eql(u8, k, "rows")) {
        c.lua_pushinteger(L, info.rows);
    } else if (std.mem.eql(u8, k, "cols")) {
        c.lua_pushinteger(L, info.cols);
    } else if (std.mem.eql(u8, k, "focused")) {
        c.lua_pushboolean(L, @intFromBool(info.focused));
    } else if (std.mem.eql(u8, k, "tab")) {
        c.lua_pushinteger(L, info.tab);
    } else if (std.mem.eql(u8, k, "pane")) {
        c.lua_pushinteger(L, info.pane);
    } else c.lua_pushnil(L);
    return 1;
}

// ---------------------------------------------------------------- gated

fn apiScreenText(p: *Plugin, L: *State) error{LuaMsg}!c_int {
    try p.need(.screen, "dt.screen.text");
    const n = try argInt(p, L, 1, "dt.screen.text", "scrollback", 0, 10_000);
    const h = p.host;
    h.scratch.clearRetainingCapacity();
    h.app.screenText(h.app.ctx, &h.scratch, @intCast(n));
    lua.pushString(L, h.scratch.items);
    return 1;
}

fn apiScreenCursor(p: *Plugin, L: *State) error{LuaMsg}!c_int {
    try p.need(.screen, "dt.screen.cursor");
    const rc = p.host.app.cursor(p.host.app.ctx);
    c.lua_pushinteger(L, rc[0] + 1);
    c.lua_pushinteger(L, rc[1] + 1);
    return 2;
}

fn apiPtyWrite(p: *Plugin, L: *State) error{LuaMsg}!c_int {
    try p.need(.pty, "dt.pty.write");
    const s = try argStr(p, L, 1, "dt.pty.write", "text");
    if (s.len > Limits.max_write) return p.raise("dt.pty.write: at most {d} KiB per call", .{Limits.max_write / 1024});
    if (s.len == 0) return 0;
    const h = p.host;
    h.effect(.{ .write = h.a.dupe(u8, s) catch return p.raise("out of memory", .{}) });
    return 0;
}

fn apiClipboardSet(p: *Plugin, L: *State) error{LuaMsg}!c_int {
    try p.need(.clipboard, "dt.clipboard.set");
    const s = try argStr(p, L, 1, "dt.clipboard.set", "text");
    if (s.len > Limits.max_clipboard) return p.raise("dt.clipboard.set: at most 1 MiB", .{});
    const h = p.host;
    h.effect(.{ .set_clipboard = h.a.dupe(u8, s) catch return p.raise("out of memory", .{}) });
    return 0;
}

fn apiClipboardGet(p: *Plugin, L: *State) error{LuaMsg}!c_int {
    try p.need(.clipboard, "dt.clipboard.get");
    const cb = c.lua_tointegerx(L, 1, null);
    const h = p.host;
    if (countOf(ClipWaiter, h.clip_waiters.items, p) >= 4) return p.raise("dt.clipboard.get: too many pending reads", .{});
    const first = h.clip_waiters.items.len == 0;
    h.clip_waiters.append(.{ .plugin = p, .cb = cb }) catch return p.raise("out of memory", .{});
    if (first) h.effect(.request_clipboard);
    return 0;
}

/// Is `host:port` covered by `allow` ("api.example.com", "*.example.com",
/// "localhost:8080")? An entry without a port only matches the scheme's
/// default port.
pub fn hostAllowed(allow: []const []const u8, host: []const u8, port: u16, default_port: u16) bool {
    for (allow) |entry| {
        var name = entry;
        var want_port = default_port;
        if (std.mem.lastIndexOfScalar(u8, entry, ':')) |i| {
            if (std.mem.indexOfScalar(u8, entry, ']') == null or i > std.mem.indexOfScalar(u8, entry, ']').?) {
                if (std.fmt.parseInt(u16, entry[i + 1 ..], 10)) |pt| {
                    want_port = pt;
                    name = entry[0..i];
                } else |_| {}
            }
        }
        name = std.mem.trim(u8, name, "[]");
        if (port != want_port) continue;
        if (std.mem.startsWith(u8, name, "*.")) {
            const suffix = name[1..]; // ".example.com"
            if (host.len > suffix.len and std.ascii.endsWithIgnoreCase(host, suffix)) return true;
        } else if (std.ascii.eqlIgnoreCase(name, host)) return true;
    }
    return false;
}

fn apiHttp(p: *Plugin, L: *State) error{LuaMsg}!c_int {
    const what = "dt.http";
    try p.need(.network, what);
    const cb = c.lua_tointegerx(L, 2, null);
    field(L, 1, "url");
    const url = try argStr(p, L, -1, what, "url");
    field(L, 1, "method");
    const method_s = (try optStr(p, L, -1, what, "method")) orelse "GET";
    field(L, 1, "body");
    const body = try optStr(p, L, -1, what, "body");
    field(L, 1, "timeout_ms");
    const timeout: i64 = if (lua.isNil(L, -1)) 15_000 else try argInt(p, L, -1, what, "timeout_ms", 100, 120_000);
    var hdrs: [32]std.http.Header = undefined;
    var nh: usize = 0;
    field(L, 1, "headers");
    const ht = c.lua_gettop(L);
    if (!lua.isNil(L, ht)) {
        if (c.lua_type(L, ht) != c.LUA_TTABLE) return p.raise("{s}: headers must be a table like {{ [\"Content-Type\"] = \"application/json\" }}", .{what});
        c.lua_pushnil(L);
        while (c.lua_next(L, ht) != 0) {
            const k = lua.toString(L, -2) orelse return p.raise("{s}: header names must be strings", .{what});
            const v = lua.toString(L, -1) orelse return p.raise("{s}: header '{s}' must be a string", .{ what, k });
            if (nh == hdrs.len) return p.raise("{s}: at most {d} headers", .{ what, hdrs.len });
            if (k.len == 0 or std.mem.indexOfAny(u8, k, ": \r\n\t") != null or std.mem.indexOfAny(u8, v, "\r\n") != null)
                return p.raise("{s}: invalid header '{s}'", .{ what, k[0..@min(k.len, 40)] });
            hdrs[nh] = .{ .name = k, .value = v };
            nh += 1;
            lua.pop(L, 1); // value; the key stays for lua_next (strings stay alive: the table holds them)
        }
    }
    var upper: [8]u8 = undefined;
    const m = std.ascii.upperString(upper[0..@min(method_s.len, upper.len)], method_s[0..@min(method_s.len, upper.len)]);
    const method: std.http.Method = for ([_]std.http.Method{ .GET, .POST, .PUT, .PATCH, .DELETE, .HEAD }) |mm| {
        if (std.mem.eql(u8, @tagName(mm), m)) break mm;
    } else return p.raise("{s}: method must be GET, POST, PUT, PATCH, DELETE or HEAD", .{what});
    const uri = std.Uri.parse(url) catch return p.raise("{s}: invalid URL \"{s}\"", .{ what, url[0..@min(url.len, 80)] });
    const https = std.ascii.eqlIgnoreCase(uri.scheme, "https");
    if (!https and !std.ascii.eqlIgnoreCase(uri.scheme, "http")) return p.raise("{s}: only http:// and https:// URLs", .{what});
    if (uri.user != null or uri.password != null) return p.raise("{s}: credentials in the URL are not allowed (use a header)", .{what});
    var hb: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&hb);
    const host_raw = if (uri.host) |hc| (hc.toRawMaybeAlloc(fba.allocator()) catch return p.raise("{s}: host name too long", .{what})) else return p.raise("{s}: URL has no host", .{what});
    const default_port: u16 = if (https) 443 else 80;
    const port = uri.port orelse default_port;
    if (!hostAllowed(p.hosts, host_raw, port, default_port))
        return p.raise("{s}: {s}:{d} is not in config.plugins[\"{s}\"].hosts", .{ what, host_raw, port, p.name });
    const h = p.host;
    if (countOf(PendingJob, h.pending.items, p) >= Limits.max_jobs) return p.raise("{s}: at most {d} requests/programs in flight per plugin", .{ what, Limits.max_jobs });
    const id = h.next_job;
    h.pending.ensureUnusedCapacity(1) catch return p.raise("out of memory", .{});
    jobs.startHttp(h.queue, id, .{ .method = method, .url = url, .headers = hdrs[0..nh], .body = body }) catch |err|
        return p.raise("{s}: cannot start the request ({s})", .{ what, @errorName(err) });
    h.next_job +%= 1;
    h.pending.appendAssumeCapacity(.{ .id = id, .plugin = p, .cb = cb, .deadline_ms = std.time.milliTimestamp() + timeout });
    c.lua_pushinteger(L, id);
    return 1;
}

fn apiExec(p: *Plugin, L: *State) error{LuaMsg}!c_int {
    const what = "dt.exec";
    try p.need(.exec, what);
    const cb = c.lua_tointegerx(L, 3, null);
    if (c.lua_type(L, 1) != c.LUA_TTABLE) return p.raise("{s}: expected a list like {{ \"git\", \"status\" }}", .{what});
    const n = c.lua_rawlen(L, 1);
    if (n == 0 or n > 64) return p.raise("{s}: argv must have 1-64 entries", .{what});
    var argv: [64][]const u8 = undefined;
    var i: c.lua_Integer = 1;
    while (i <= n) : (i += 1) {
        _ = c.lua_rawgeti(L, 1, i);
        argv[@intCast(i - 1)] = lua.toString(L, -1) orelse return p.raise("{s}: argv[{d}] must be a string", .{ what, i });
        // The table keeps the string alive; leave it on the stack anyway.
    }
    const prog = argv[0];
    const allowed = for (p.exec) |e| {
        if (std.mem.eql(u8, e, prog)) break true;
    } else false;
    if (!allowed) return p.raise("{s}: \"{s}\" is not in config.plugins[\"{s}\"].exec", .{ what, prog[0..@min(prog.len, 60)], p.name });
    try optTable(p, L, 2, what);
    field(L, 2, "cwd");
    var cwd = try optStr(p, L, -1, what, "cwd");
    field(L, 2, "stdin");
    const stdin = try optStr(p, L, -1, what, "stdin");
    field(L, 2, "timeout_ms");
    const timeout: i64 = if (lua.isNil(L, -1)) 10_000 else try argInt(p, L, -1, what, "timeout_ms", 100, 120_000);
    const h = p.host;
    if (cwd == null and h.info.cwd.items.len > 0) cwd = h.info.cwd.items;
    if (cwd) |d| {
        if (!std.fs.path.isAbsolute(d)) return p.raise("{s}: cwd must be an absolute path", .{what});
        std.fs.cwd().access(d, .{}) catch {
            cwd = null;
        };
    }
    if (countOf(PendingJob, h.pending.items, p) >= Limits.max_jobs) return p.raise("{s}: at most {d} requests/programs in flight per plugin", .{ what, Limits.max_jobs });
    const id = h.next_job;
    h.pending.ensureUnusedCapacity(1) catch return p.raise("out of memory", .{});
    jobs.startExec(h.queue, id, .{ .argv = argv[0..@intCast(n)], .cwd = cwd, .stdin = stdin, .timeout_ms = @intCast(timeout) }) catch |err|
        return p.raise("{s}: cannot start {s} ({s})", .{ what, prog, @errorName(err) });
    h.next_job +%= 1;
    h.pending.appendAssumeCapacity(.{ .id = id, .plugin = p, .cb = cb, .deadline_ms = std.time.milliTimestamp() + timeout + 5000 });
    c.lua_pushinteger(L, id);
    return 1;
}

/// A relative path inside the data directory: no absolute paths, no "..".
pub fn safeRelPath(path: []const u8) bool {
    if (path.len == 0 or path.len > 512 or path[0] == '/' or std.mem.indexOfAny(u8, path, "\\\x00") != null) return false;
    if (std.mem.eql(u8, path, ".")) return true;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |comp| {
        if (comp.len == 0 or std.mem.eql(u8, comp, "..") or std.mem.eql(u8, comp, ".")) return false;
    }
    return true;
}

fn apiFs(p: *Plugin, L: *State) error{LuaMsg}!c_int {
    const op = lua.toString(L, 1) orelse "";
    var whatb: [24]u8 = undefined;
    const what = std.fmt.bufPrint(&whatb, "dt.fs.{s}", .{op[0..@min(op.len, 10)]}) catch "dt.fs";
    try p.need(.fs, what);
    const path = try argStr(p, L, 2, what, "path");
    if (!safeRelPath(path)) return p.raise("{s}: \"{s}\" must be a relative path inside the plugin's data directory (no \"..\")", .{ what, path[0..@min(path.len, 80)] });
    if (p.data_dir.len == 0) return p.raise("{s}: no data directory", .{what});
    std.fs.cwd().makePath(p.data_dir) catch return fsErr(L, error.AccessDenied);
    var dir = std.fs.cwd().openDir(p.data_dir, .{ .iterate = true }) catch |err| return fsErr(L, err);
    const h = p.host;
    if (std.mem.eql(u8, op, "read")) {
        h.scratch.clearRetainingCapacity();
        {
            defer dir.close();
            const f = dir.openFile(path, .{}) catch |err| return fsErr(L, err);
            defer f.close();
            f.reader().readAllArrayList(&h.scratch, Limits.max_file) catch |err| return fsErr(L, err);
        }
        lua.pushString(L, h.scratch.items);
        return 1;
    } else if (std.mem.eql(u8, op, "write") or std.mem.eql(u8, op, "append")) {
        defer dir.close();
        const data = try argStr(p, L, 3, what, "data");
        if (data.len > Limits.max_file) return p.raise("{s}: at most 16 MiB", .{what});
        if (std.fs.path.dirname(path)) |d| dir.makePath(d) catch |err| return fsErr(L, err);
        const f = dir.createFile(path, .{ .truncate = op[0] == 'w', .mode = file_mode }) catch |err| return fsErr(L, err);
        defer f.close();
        if (op[0] == 'a') f.seekFromEnd(0) catch |err| return fsErr(L, err);
        f.writeAll(data) catch |err| return fsErr(L, err);
        c.lua_pushboolean(L, 1);
        return 1;
    } else if (std.mem.eql(u8, op, "list")) {
        // Collect names first (NUL separated), then build the table.
        h.scratch.clearRetainingCapacity();
        var count: usize = 0;
        {
            defer dir.close();
            var sub = dir.openDir(path, .{ .iterate = true }) catch |err| return fsErr(L, err);
            defer sub.close();
            var it = sub.iterate();
            while (it.next() catch null) |e| {
                if (count == 10_000) break;
                h.scratch.appendSlice(e.name) catch break;
                if (e.kind == .directory) h.scratch.append('/') catch break;
                h.scratch.append(0) catch break;
                count += 1;
            }
        }
        c.lua_createtable(L, @intCast(count), 0);
        var names = std.mem.splitScalar(u8, h.scratch.items, 0);
        var i: c.lua_Integer = 1;
        while (names.next()) |nm| {
            if (nm.len == 0) continue;
            lua.pushString(L, nm);
            c.lua_rawseti(L, -2, i);
            i += 1;
        }
        // Sorted, for predictable output.
        _ = c.lua_getglobal(L, "table");
        _ = c.lua_getfield(L, -1, "sort");
        c.lua_pushvalue(L, -3);
        c.lua_callk(L, 1, 0, 0, null);
        lua.pop(L, 1);
        return 1;
    } else if (std.mem.eql(u8, op, "remove")) {
        defer dir.close();
        dir.deleteFile(path) catch |err| switch (err) {
            error.IsDir => dir.deleteDir(path) catch |e2| return fsErr(L, e2),
            else => return fsErr(L, err),
        };
        c.lua_pushboolean(L, 1);
        return 1;
    } else if (std.mem.eql(u8, op, "exists")) {
        defer dir.close();
        c.lua_pushboolean(L, @intFromBool(if (dir.access(path, .{})) true else |_| false));
        return 1;
    } else if (std.mem.eql(u8, op, "mkdir")) {
        defer dir.close();
        dir.makePath(path) catch |err| return fsErr(L, err);
        c.lua_pushboolean(L, 1);
        return 1;
    }
    dir.close();
    return p.raise("dt.fs: unknown operation", .{});
}

/// Lua convention for I/O failures: nil, "message".
fn fsErr(L: *State, err: anyerror) c_int {
    c.lua_pushnil(L);
    lua.pushString(L, switch (err) {
        error.FileNotFound => "not found",
        error.AccessDenied, error.PermissionDenied => "permission denied",
        error.IsDir => "is a directory",
        error.NotDir => "not a directory",
        error.DirNotEmpty => "directory not empty",
        error.NoSpaceLeft => "no space left",
        error.StreamTooLong => "file too large",
        error.SymLinkLoop => "symlink loop",
        else => @errorName(err),
    });
    return 2;
}
