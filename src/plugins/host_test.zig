//! Plugin host tests: sandbox, permissions, hook dispatch, error isolation.

const std = @import("std");
const builtin = @import("builtin");
const io = @import("../platform/io.zig");
const t = std.testing;
const host_mod = @import("host.zig");
const Host = host_mod.Host;
const Spec = host_mod.Spec;
const permissions = @import("permissions.zig");
const value = @import("value.zig");
const PluginConfig = @import("plugin_config.zig").PluginConfig;

const FakeApp = struct {
    screen: []const u8 = "line one\nline two",
    fn text(ctx: *anyopaque, out: *std.ArrayList(u8), _: u32) void {
        const self: *FakeApp = @ptrCast(@alignCast(ctx));
        out.appendSlice(self.screen) catch {};
    }
    fn cursor(_: *anyopaque) [2]u32 {
        return .{ 1, 4 };
    }
    fn app(self: *FakeApp) host_mod.App {
        return .{ .ctx = self, .screenText = text, .cursor = cursor };
    }
};

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: []u8,
    fake: FakeApp = .{},
    host_opt: ?*Host = null,
    host: *Host = undefined,
    taken: ?*const fn (@import("../platform/events.zig").Chord) bool = null,

    fn init() !*Fixture {
        const f = try t.allocator.create(Fixture);
        f.* = .{ .tmp = std.testing.tmpDir(.{}), .root = undefined };
        f.root = try @import("../testutil.zig").tmpPath(t.allocator, &f.tmp, ".");
        return f;
    }

    fn deinit(f: *Fixture) void {
        if (f.host_opt) |h| h.deinit();
        t.allocator.free(f.root);
        f.tmp.cleanup();
        t.allocator.destroy(f);
    }

    fn write(f: *Fixture, name: []const u8, file: []const u8, src: []const u8) !void {
        var pb: [256]u8 = undefined;
        const dir = try std.fmt.bufPrint(&pb, "plugins/{s}", .{name});
        try f.tmp.dir.makePath(dir);
        var fb: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&fb, "{s}/{s}", .{ dir, file });
        try f.tmp.dir.makePath(std.fs.path.dirname(path).?);
        try f.tmp.dir.writeFile(.{ .sub_path = path, .data = src });
    }

    /// Start a host with one plugin per (name, init.lua, requested, granted).
    fn start(f: *Fixture, plugins: []const struct { []const u8, []const u8, []const permissions.Permission, PluginConfig }) !void {
        var lb: [300]u8 = undefined;
        var db: [300]u8 = undefined;
        f.host = try Host.init(t.allocator, f.fake.app(), .{
            .log_path = try std.fmt.bufPrint(&lb, "{s}/plugins.log", .{f.root}),
            .data_root = try std.fmt.bufPrint(&db, "{s}/data", .{f.root}),
            .version = "test",
        });
        f.host_opt = f.host;
        if (f.taken) |tk| f.host.taken = tk;
        var specs = std.ArrayList(Spec).init(t.allocator);
        defer specs.deinit();
        var dirs = std.ArrayList([]u8).init(t.allocator);
        defer {
            for (dirs.items) |d| t.allocator.free(d);
            dirs.deinit();
        }
        for (plugins) |pl| {
            try f.write(pl[0], "init.lua", pl[1]);
            var req = permissions.Set.initEmpty();
            for (pl[2]) |p| req.insert(p);
            const d = try std.fmt.allocPrint(t.allocator, "{s}/plugins/{s}", .{ f.root, pl[0] });
            try dirs.append(d);
            var cfg = pl[3];
            cfg.name = pl[0];
            try specs.append(.{ .name = pl[0], .version = "1.0", .dir = d, .requested = req, .config = cfg });
        }
        try f.host.start(specs.items);
    }

    fn plugin(f: *Fixture, i: usize) *host_mod.Plugin {
        return f.host.plugins.items[i];
    }

    fn noticeContains(f: *Fixture, needle: []const u8) bool {
        for (f.host.effects.items) |e| if (e == .notify and std.mem.indexOf(u8, e.notify.text, needle) != null) return true;
        return false;
    }

    fn logContains(f: *Fixture, needle: []const u8) !bool {
        const s = try f.tmp.dir.readFileAlloc(t.allocator, "plugins.log", 1 << 20);
        defer t.allocator.free(s);
        return std.mem.indexOf(u8, s, needle) != null;
    }
};

fn allow(perms: []const permissions.Permission) permissions.Set {
    var s = permissions.Set.initEmpty();
    for (perms) |p| s.insert(p);
    return s;
}

test "sandbox: no io, os.execute, debug, getenv or bytecode" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.start(&.{.{
        "sb",
        \\results = {}
        \\local function try(name, fn) local ok, err = pcall(fn) results[#results + 1] = name .. "=" .. tostring(ok) end
        \\try("io", function() return io.open("/etc/passwd") end)
        \\try("execute", function() return os.execute("true") end)
        \\try("getenv", function() return os.getenv("HOME") end)
        \\try("debug", function() return debug.getinfo(1) end)
        \\try("dofile", function() return dofile("/etc/passwd") end)
        \\try("bytecode", function() assert(load(string.dump(function() end))) end)
        \\try("require_escape", function() return require("..secret") end)
        \\try("collect", function() return collectgarbage() end)
        \\try("time", function() return os.time() end)
        \\dt.status.set("sb", table.concat(results, " "))
        ,
        &.{},
        .{ .name = "" },
    }});
    const p = f.plugin(0);
    try t.expectEqual(host_mod.Status.running, p.status);
    try t.expectEqualStrings("io=false execute=false getenv=false debug=false dofile=false bytecode=false require_escape=false collect=false time=true", f.host.segments.items[0].text);
}

test "sandbox: require loads modules from the plugin directory only" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.write("mods", "util.lua", "return { twice = function(x) return x * 2 end }");
    try f.write("mods", "lib/deep.lua", "return 'deep'");
    try f.start(&.{.{
        "mods",
        \\local u = require("util")
        \\assert(require("util") == u)
        \\dt.status.set("m", tostring(u.twice(21)) .. " " .. require("lib.deep"))
        \\local ok, err = pcall(require, "missing")
        \\assert(not ok and err:find("not found"))
        ,
        &.{},
        .{ .name = "" },
    }});
    try t.expectEqual(host_mod.Status.running, f.plugin(0).status);
    try t.expectEqualStrings("42 deep", f.host.segments.items[0].text);
}

test "permissions: gated APIs need both the manifest request and the config grant" {
    const f = try Fixture.init();
    defer f.deinit();
    const probe =
        \\local out = {}
        \\for _, name in ipairs({ "screen", "pty", "clipboard", "exec", "fs", "network" }) do
        \\  local ok, err = pcall(function()
        \\    if name == "screen" then return dt.screen.text()
        \\    elseif name == "pty" then return dt.pty.write("x")
        \\    elseif name == "clipboard" then return dt.clipboard.set("x")
        \\    elseif name == "exec" then return dt.exec({ "true" }, function() end)
        \\    elseif name == "fs" then return dt.fs.exists("x")
        \\    else return dt.http.get("http://example.com/", function() end) end
        \\  end)
        \\  out[#out + 1] = name .. (ok and "+" or "-")
        \\  if not ok then last_error = err end
        \\end
        \\dt.status.set("p", table.concat(out, " "))
        \\dt.status.set("e", last_error)
    ;
    try f.start(&.{
        // Asked for, not granted.
        .{ "asked", probe, &.{ .screen, .pty, .clipboard, .exec, .fs, .network }, .{ .name = "" } },
        // Granted in config but never asked for in the manifest.
        .{ "granted", probe, &.{}, .{ .name = "", .allow = allow(&.{ .screen, .pty }) } },
        // Both: screen + pty + clipboard + fs only.
        .{ "both", probe, &.{ .screen, .pty, .clipboard, .fs }, .{ .name = "", .allow = allow(&.{ .screen, .pty, .clipboard, .fs }) } },
    });
    const segs = f.host.segments.items;
    try t.expectEqualStrings("screen- pty- clipboard- exec- fs- network-", segs[0].text);
    try t.expect(std.mem.indexOf(u8, segs[1].text, "config.plugins[\"asked\"].allow") != null);
    try t.expectEqualStrings("screen- pty- clipboard- exec- fs- network-", segs[2].text);
    try t.expect(std.mem.indexOf(u8, segs[3].text, "manifest.lua") != null);
    try t.expectEqualStrings("screen+ pty+ clipboard+ exec- fs+ network-", segs[4].text);
    // The granted calls queued their effects.
    var writes: usize = 0;
    var clips: usize = 0;
    for (f.host.effects.items) |e| switch (e) {
        .write => writes += 1,
        .set_clipboard => clips += 1,
        else => {},
    };
    try t.expectEqual(@as(usize, 1), writes);
    try t.expectEqual(@as(usize, 1), clips);
}

test "permissions: exec and http allowlists, fs stays in the data dir" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.start(&.{.{
        "lists",
        \\local function err(fn) local ok, e = pcall(fn) return ok and "ok" or e end
        \\results = {
        \\  exec = err(function() dt.exec({ "sh", "-c", "id" }, function() end) end),
        \\  http = err(function() dt.http.get("https://evil.example.org/", function() end) end),
        \\  port = err(function() dt.http.get("http://api.example.com:8080/", function() end) end),
        \\  scheme = err(function() dt.http.get("file:///etc/passwd", function() end) end),
        \\  dotdot = err(function() dt.fs.read("../../etc/passwd") end),
        \\  abs = err(function() dt.fs.read("/etc/passwd") end),
        \\}
        \\assert(dt.fs.write("notes/a.txt", "hello"))
        \\assert(dt.fs.append("notes/a.txt", " world"))
        \\local listed = table.concat(dt.fs.list("notes"), ",")
        \\local missing, why = dt.fs.read("nope.txt")
        \\dt.status.set("fs", dt.fs.read("notes/a.txt") .. "|" .. listed .. "|" .. tostring(missing) .. ":" .. why)
        \\for k, v in pairs(results) do dt.status.set(k, v) end
        ,
        &.{ .exec, .network, .fs },
        .{
            .name = "",
            .allow = allow(&.{ .exec, .network, .fs }),
            .exec = &.{"git"},
            .hosts = &.{ "api.example.com", "*.example.net" },
        },
    }});
    const h = f.host;
    try t.expectEqual(host_mod.Status.running, f.plugin(0).status);
    var found: usize = 0;
    for (h.segments.items) |s| {
        if (std.mem.eql(u8, s.id, "fs")) {
            try t.expectEqualStrings("hello world|a.txt|nil:not found", s.text);
            found += 1;
        } else {
            try t.expect(!std.mem.eql(u8, s.text, "ok"));
            found += 1;
        }
    }
    try t.expectEqual(@as(usize, 7), found);
    // The file really is under <data_root>/lists.
    const data = try f.tmp.dir.readFileAlloc(t.allocator, "data/lists/notes/a.txt", 100);
    defer t.allocator.free(data);
    try t.expectEqualStrings("hello world", data);

    try t.expect(host_mod.hostAllowed(&.{"*.example.net"}, "a.b.example.net", 443, 443));
    try t.expect(!host_mod.hostAllowed(&.{"*.example.net"}, "example.net", 443, 443));
    try t.expect(host_mod.hostAllowed(&.{"localhost:8080"}, "localhost", 8080, 80));
    try t.expect(!host_mod.hostAllowed(&.{"localhost"}, "localhost", 8080, 80));
    try t.expect(!host_mod.safeRelPath("a/../b"));
    try t.expect(host_mod.safeRelPath("a/b.txt"));
}

test "hooks: dispatch, key consumption, private fields, ai filter" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.start(&.{
        .{
            "watcher",
            \\seen = {}
            \\dt.on("command_finish", function(e)
            \\  dt.status.set("cmd", string.format("%s:%d:%s", tostring(e.command), e.exit_code, e.cwd))
            \\end)
            \\dt.on("key", function(k) if k.key == "f5" then return true end end)
            \\dt.on("ai_suggestion", function(s)
            \\  if s.text:find("rm %-rf") then return false end
            \\  return s.text .. " --dry-run"
            \\end)
            \\dt.on("startup", function() dt.status.set("start", "yes") end)
            ,
            &.{ .input, .ai },
            .{ .name = "", .allow = allow(&.{ .input, .ai }) },
        },
        .{
            "screenful",
            \\dt.on("command_finish", function(e) dt.status.set("cmd2", tostring(e.command)) end)
            \\dt.on("output_line", function(l) dt.status.set("out", l.text) end)
            ,
            &.{.screen},
            .{ .name = "", .allow = allow(&.{.screen}) },
        },
        // Subscribing without the permission fails the load.
        .{ "sneaky", "dt.on('key', function() return true end)", &.{}, .{ .name = "" } },
    });
    const h = f.host;
    try t.expectEqual(host_mod.Status.failed, f.plugin(2).status);
    try t.expect(std.mem.indexOf(u8, f.plugin(2).message, "'input' permission") != null);

    const V = value.Value;
    h.emitWithPrivate(.command_finish, &.{
        .{ .key = "exit_code", .value = V{ .integer = 2 } },
        .{ .key = "cwd", .value = V{ .string = "/tmp" } },
    }, &.{.{ .key = "command", .value = V{ .string = "make test" } }});
    h.outputLines(&.{ "first", "second" });
    try t.expect(h.key(.{ .map = &.{.{ .key = "key", .value = V{ .string = "f5" } }} }));
    try t.expect(!h.key(.{ .map = &.{.{ .key = "key", .value = V{ .string = "a" } }} }));

    const r1 = h.filterSuggestion("ls -la", "ls");
    try t.expectEqualStrings("ls -la --dry-run", r1.replace);
    t.allocator.free(r1.replace);
    try t.expect(h.filterSuggestion("rm -rf /", "rm") == .drop);

    var got: usize = 0;
    for (h.segments.items) |s| {
        if (std.mem.eql(u8, s.id, "cmd")) {
            try t.expectEqualStrings("nil:2:/tmp", s.text);
            got += 1;
        } else if (std.mem.eql(u8, s.id, "cmd2")) {
            try t.expectEqualStrings("make test", s.text);
            got += 1;
        } else if (std.mem.eql(u8, s.id, "out")) {
            try t.expectEqualStrings("second", s.text);
            got += 1;
        } else if (std.mem.eql(u8, s.id, "start")) got += 1;
    }
    try t.expectEqual(@as(usize, 4), got);
}

test "isolation: errors are contained, logged, and a repeat offender is disabled" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.start(&.{
        .{
            "flaky",
            \\dt.status.set("flaky", "here")
            \\dt.command({ id = "boom", title = "Boom", run = function() error("kaboom") end })
            \\dt.on("bell", function() error("bell broke") end)
            ,
            &.{},
            .{ .name = "" },
        },
        .{
            "steady",
            \\n = 0
            \\dt.on("bell", function() n = n + 1 dt.status.set("steady", tostring(n)) end)
            ,
            &.{},
            .{ .name = "" },
        },
        .{ "broken", "this is not lua", &.{}, .{ .name = "" } },
    });
    const h = f.host;
    try t.expectEqual(host_mod.Status.failed, f.plugin(2).status);
    try t.expect(f.noticeContains("Plugin broken failed to load"));
    try t.expectEqual(@as(usize, 1), h.commands.items.len);

    h.runCommand(0);
    try t.expectEqual(host_mod.Status.running, f.plugin(0).status);
    try t.expect(try f.logContains("kaboom"));
    try t.expect(try f.logContains("flaky/init.lua:2:"));
    for (0..4) |_| h.emit(.bell, null);
    // 1 command error + 4 bell errors = 5 within a minute: disabled.
    try t.expectEqual(host_mod.Status.failed, f.plugin(0).status);
    try t.expect(std.mem.indexOf(u8, f.plugin(0).message, "disabled for this session") != null);
    try t.expect(f.noticeContains("Plugin flaky was disabled"));
    // Everything it registered is gone; the other plugin is unaffected.
    try t.expectEqual(@as(usize, 0), h.commands.items.len);
    for (h.segments.items) |s| try t.expect(s.plugin != f.plugin(0));
    h.emit(.bell, null);
    for (h.segments.items) |s| if (std.mem.eql(u8, s.id, "steady")) try t.expectEqualStrings("5", s.text);
}

test "isolation: runaway loops and memory bombs are stopped" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.start(&.{
        .{
            "spin",
            \\dt.command({ id = "spin", title = "Spin", run = function() while true do end end })
            \\dt.command({ id = "swallow", title = "Swallow", run = function()
            \\  while true do pcall(function() while true do end end) end
            \\end })
            \\dt.command({ id = "ok", title = "OK", run = function() dt.status.set("ok", "still alive") end })
            ,
            &.{},
            .{ .name = "", .cpu_ms = 30 },
        },
        .{
            "hog",
            \\dt.command({ id = "hog", title = "Hog", run = function()
            \\  local t = {} for i = 1, 1e8 do t[i] = string.rep("x", 1000) .. i end
            \\end })
            \\dt.command({ id = "ok2", title = "OK", run = function() dt.status.set("ok2", "fine") end })
            ,
            &.{},
            .{ .name = "", .memory_mb = 4 },
        },
    });
    const h = f.host;
    const t0 = std.time.milliTimestamp();
    h.runCommand(0);
    h.runCommand(1);
    try t.expect(std.time.milliTimestamp() - t0 < 2000);
    try t.expect(try f.logContains("took longer than 30 ms"));
    h.runCommand(2);
    h.runCommand(3);
    try t.expect(try f.logContains("out of memory (limit 4 MB"));
    h.runCommand(4);
    var ok: usize = 0;
    for (h.segments.items) |s| {
        if (std.mem.eql(u8, s.id, "ok") or std.mem.eql(u8, s.id, "ok2")) ok += 1;
    }
    try t.expectEqual(@as(usize, 2), ok);
    try t.expectEqual(host_mod.Status.running, f.plugin(0).status);
    try t.expectEqual(host_mod.Status.running, f.plugin(1).status);
}

test "timers, commands, bindings, themes and notifications" {
    const f = try Fixture.init();
    defer f.deinit();
    f.taken = struct {
        fn taken(ch: @import("../platform/events.zig").Chord) bool {
            return ch.sym == 'c' and ch.mods.ctrl and ch.mods.shift;
        }
    }.taken;
    try f.start(&.{.{
        "misc",
        \\ticks, once = 0, 0
        \\local every = dt.timer.every(100, function() ticks = ticks + 1 dt.status.set("ticks", tostring(ticks)) end)
        \\dt.timer.after(0, function() once = once + 1 dt.status.set("once", tostring(once)) end)
        \\local gone = dt.timer.after(0, function() dt.status.set("cancelled", "fired!") end)
        \\dt.timer.cancel(gone)
        \\assert(not pcall(dt.timer.every, 10, function() end))
        \\dt.command({ id = "theme", title = "Use Mono theme", run = function() dt.theme.set("mono") end })
        \\dt.bind("ctrl+alt+m", "theme")
        \\assert(not pcall(dt.bind, "m", "theme"))
        \\assert(not pcall(dt.bind, "ctrl+shift+c", function() end))
        \\dt.theme.register({ name = "mono", fg = "#dddddd", bg = "#111111" })
        \\assert(not pcall(dt.theme.register, { name = "dracula", fg = "#fff", bg = "#000" }))
        \\local names = table.concat(dt.theme.list(), ",")
        \\assert(names:find("mono") and names:find("nord"))
        \\for i = 1, 7 do dt.notify("hello " .. i) end
        \\assert(not pcall(dt.action, "paste"))
        \\dt.action("toggle_status_bar")
        ,
        &.{},
        .{ .name = "" },
    }});
    const h = f.host;
    try t.expectEqual(host_mod.Status.running, f.plugin(0).status);
    const now = std.time.milliTimestamp();
    try t.expect(h.nextDeadline(now) != null);
    h.tick(now + 1);
    h.tick(now + 150);
    h.tick(now + 300);
    var ticks: []const u8 = "";
    var once: []const u8 = "";
    for (h.segments.items) |s| {
        if (std.mem.eql(u8, s.id, "ticks")) ticks = s.text;
        if (std.mem.eql(u8, s.id, "once")) once = s.text;
        try t.expect(!std.mem.eql(u8, s.id, "cancelled"));
    }
    try t.expectEqualStrings("1", once);
    try t.expectEqualStrings("2", ticks);

    try t.expectEqual(@as(usize, 1), h.binds.items.len);
    h.runBinding(h.binds.items[0].id);
    var themed = false;
    var notes: usize = 0;
    var toggled = false;
    for (h.effects.items) |e| switch (e) {
        .theme => |th| themed = std.mem.eql(u8, th.name, "mono") and th.palette.bg == 0x111111,
        .notify => notes += 1,
        .action => |a| toggled = a == .toggle_status_bar,
        else => {},
    };
    try t.expect(themed);
    try t.expect(toggled);
    try t.expectEqual(@as(usize, 5), notes); // rate limited
    try t.expectEqualStrings("mono", h.info.theme.items);
}

test "async: exec results arrive through the wake fd" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.start(&.{.{
        "runner",
        if (builtin.os.tag == .windows)
            \\dt.exec({ "cmd.exe", "/d", "/c", "echo out&exit /b 4" }, { cwd = "C:\\" }, function(r)
            \\  dt.status.set("r", string.format("%s|%d|%s", tostring(r.ok), r.code, r.stdout))
            \\end)
        else
            \\dt.exec({ "sh", "-c", "echo out; exit 4" }, { cwd = "/" }, function(r)
            \\  dt.status.set("r", string.format("%s|%d|%s", tostring(r.ok), r.code, r.stdout))
            \\end)
        ,
        &.{.exec},
        .{ .name = "", .allow = allow(&.{.exec}), .exec = &.{if (builtin.os.tag == .windows) "cmd.exe" else "sh"} },
    }});
    const h = f.host;
    try t.expectEqual(host_mod.Status.running, f.plugin(0).status);
    const deadline = std.time.milliTimestamp() + 5000;
    while (h.segments.items.len == 0 and std.time.milliTimestamp() < deadline) {
        var pfd = [1]io.PollFd{io.pollFd(h.wakeFd(), io.POLL.IN)};
        _ = io.poll(&pfd, 100);
        h.tick(std.time.milliTimestamp());
    }
    try t.expectEqualStrings("false|4|out ", h.segments.items[0].text);
}

test "examples: the bundled plugins load and do their job" {
    const registry = @import("registry.zig");
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const dir = @import("../testutil.zig").cwdPath(aa, &.{"plugins"}) catch return error.SkipZigTest;
    const f = try Fixture.init();
    defer f.deinit();
    const paths = registry.Paths{
        .plugins_dir = dir,
        .data_root = try std.fmt.allocPrint(aa, "{s}/data", .{f.root}),
        .state_file = try std.fmt.allocPrint(aa, "{s}/state.json", .{f.root}),
        .log_file = try std.fmt.allocPrint(aa, "{s}/plugins.log", .{f.root}),
    };
    const configs = [_]PluginConfig{
        .{ .name = "git_branch", .allow = allow(&.{.exec}), .exec = &.{"git"} },
        .{ .name = "long_command", .settings = .{ .map = &.{.{ .key = "threshold_s", .value = .{ .integer = 5 } }} } },
    };
    const plan = try registry.planAt(aa, paths, &configs);
    try t.expectEqual(@as(usize, 4), plan.specs.len);
    f.host = try Host.init(t.allocator, f.fake.app(), .{ .log_path = paths.log_file, .data_root = paths.data_root, .version = "test" });
    f.host_opt = f.host;
    f.host.setInfo(.theme, "default");
    try f.host.start(plan.specs);
    for (f.host.plugins.items) |p| {
        if (!p.running()) std.debug.print("{s}: {s}\n", .{ p.name, p.message });
        try t.expect(p.running());
    }

    // theme_cycle: commands, a binding, a theme and a status segment.
    var next: ?usize = null;
    for (f.host.commands.items, 0..) |c, i| if (std.mem.eql(u8, c.id, "theme.next")) {
        next = i;
    };
    try t.expectEqual(@as(usize, 1), f.host.binds.items.len);
    f.host.clearEffects();
    f.host.runCommand(next.?);
    var themed = false;
    for (f.host.effects.items) |e| if (e == .theme) {
        themed = true;
    };
    try t.expect(themed);
    try t.expect(host_mod.findTheme(f.host, "crimson") != null);

    // long_command: slow failures get a notice.
    f.host.clearEffects();
    const V = value.Value;
    f.host.emitWithPrivate(.command_finish, &.{
        .{ .key = "exit_code", .value = V{ .integer = 1 } },
        .{ .key = "duration_ms", .value = V{ .integer = 7000 } },
        .{ .key = "focused", .value = V{ .boolean = true } },
    }, &.{});
    try t.expect(f.noticeContains("failed (exit 1) after 7s"));
    f.host.clearEffects();
    f.host.emitWithPrivate(.command_finish, &.{
        .{ .key = "exit_code", .value = V{ .integer = 0 } },
        .{ .key = "duration_ms", .value = V{ .integer = 100 } },
    }, &.{});
    try t.expect(!f.noticeContains("after"));

    // git_branch: the repo's branch shows up once the cwd is known.
    const repo = try @import("../testutil.zig").cwdPath(aa, &.{"."});
    f.host.setInfo(.cwd, repo);
    f.host.emit(.cwd, .{ .map = &.{.{ .key = "cwd", .value = V{ .string = repo } }} });
    const deadline = std.time.milliTimestamp() + 5000;
    var seg: ?[]const u8 = null;
    while (std.time.milliTimestamp() < deadline and seg == null) {
        var fds = [_]io.PollFd{io.pollFd(f.host.wakeFd(), io.POLL.IN)};
        _ = io.poll(&fds, 100);
        f.host.pollJobs();
        for (f.host.segments.items) |s| if (std.mem.eql(u8, s.id, "branch")) {
            seg = s.text;
        };
    }
    // No git in the environment: nothing to check beyond "no error".
    if (seg) |s| try t.expect(s.len > 2);
    try t.expect(f.host.plugins.items[0].running());

    // youneek-time: branded clock, decimal minute, moon phase, green accent.
    var ynk: ?host_mod.Segment = null;
    for (f.host.segments.items) |s| if (std.mem.eql(u8, s.id, "youneek")) {
        ynk = s;
    };
    try t.expect(ynk != null);
    try t.expect(!f.noticeContains("YouNeeK Time"));
    const clock = ynk.?;
    try t.expect(std.mem.startsWith(u8, clock.text, "YouNeeK "));
    try t.expect(std.mem.indexOf(u8, clock.text, " YNK  ") != null);
    try t.expect(clock.right);
    try t.expectEqual(@as(?u32, 0x7CFF6B), clock.fg);
    const phases = [_][]const u8{
        "New Moon",        "Waxing Crescent", "First Quarter", "Waxing Gibbous",
        "Full Moon",       "Waning Gibbous",  "Last Quarter",  "Waning Crescent",
    };
    var named = false;
    for (phases) |name| {
        if (std.mem.indexOf(u8, clock.text, name) != null) {
            named = true;
        }
    }
    try t.expect(named);
}

test "tabs and panes: events, list and layout requests" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.start(&.{.{
        "tabby",
        \\local seen = {}
        \\dt.on("tab_new", function(e) seen[#seen + 1] = "tab_new:" .. e.tab end)
        \\dt.on("pane_focus", function(e) seen[#seen + 1] = "pane_focus:" .. e.tab .. "/" .. e.pane end)
        \\dt.command({ id = "go", title = "Go", run = function()
        \\  local tabs = dt.tabs.list()
        \\  assert(#tabs == 2, "tabs " .. #tabs)
        \\  assert(tabs[1].id == 1 and tabs[1].title == "one" and not tabs[1].active)
        \\  assert(tabs[2].active and #tabs[2].panes == 2 and tabs[2].focused_pane == 3)
        \\  assert(dt.tabs.current() == 2 and dt.panes.current() == 3)
        \\  assert(dt.tabs.focus(1))
        \\  assert(not dt.tabs.focus(99))
        \\  assert(dt.tabs.rename(2, "build"))
        \\  assert(dt.panes.split("down"))
        \\  assert(not pcall(dt.panes.split, "diagonal"))
        \\  assert(dt.panes.close(2))
        \\  assert(not dt.panes.focus(7))
        \\  assert(dt.tabs.new({ cwd = "/tmp" }))
        \\  dt.status.set("seen", table.concat(seen, ","))
        \\end })
        ,
        &.{},
        .{ .name = "" },
    }});
    const h = f.host;
    try t.expectEqual(host_mod.Status.running, f.plugin(0).status);
    h.setTabs(&.{
        .{ .id = 1, .title = "one", .active = false, .panes = &.{1}, .focused_pane = 1 },
        .{ .id = 2, .title = "two", .active = true, .panes = &.{ 2, 3 }, .focused_pane = 3 },
    }, 2, 3);
    h.emitLayout(.tab_new, 2, null);
    h.emitLayout(.pane_focus, 2, 3);
    h.runCommand(0);
    var seen: []const u8 = "";
    for (h.segments.items) |s| if (std.mem.eql(u8, s.id, "seen")) {
        seen = s.text;
    };
    try t.expectEqualStrings("tab_new:2,pane_focus:2/3", seen);
    var ops: [8]std.meta.Tag(host_mod.LayoutOp) = undefined;
    var n: usize = 0;
    for (h.effects.items) |e| if (e == .layout) {
        ops[n] = e.layout;
        n += 1;
        switch (e.layout) {
            .tab_rename => |r| try t.expectEqualStrings("build", r.name),
            .tab_new => |d| try t.expectEqualStrings("/tmp", d.?),
            .pane_split => |d| try t.expect(d == .down),
            .pane_close => |id| try t.expectEqual(@as(u32, 2), id),
            else => {},
        }
    };
    try t.expectEqualSlices(std.meta.Tag(host_mod.LayoutOp), &.{ .tab_focus, .tab_rename, .pane_split, .pane_close, .tab_new }, ops[0..n]);
}

test "youneek-time: decimal minutes, 12/24h, timezone and moon phase" {
    const util = @import("../testutil.zig");
    const clock_path = util.cwdPath(t.allocator, &.{ "plugins", "youneek-time", "lib", "clock.lua" }) catch return error.SkipZigTest;
    defer t.allocator.free(clock_path);
    const moon_path = try util.cwdPath(t.allocator, &.{ "plugins", "youneek-time", "lib", "moon.lua" });
    defer t.allocator.free(moon_path);
    const clock_src = try std.fs.cwd().readFileAlloc(t.allocator, clock_path, 1 << 16);
    defer t.allocator.free(clock_src);
    const moon_src = try std.fs.cwd().readFileAlloc(t.allocator, moon_path, 1 << 16);
    defer t.allocator.free(moon_src);

    const f = try Fixture.init();
    defer f.deinit();
    try f.write("ynk", "lib/clock.lua", clock_src);
    try f.write("ynk", "lib/moon.lua", moon_src);
    try f.start(&.{.{
        "ynk",
        \\local clock = require("lib.clock")
        \\local moon = require("lib.moon")
        \\local function eq(got, want, msg)
        \\  if got ~= want then error(msg .. ": got " .. tostring(got) .. " want " .. tostring(want)) end
        \\end
        \\eq(clock.youneek_minute(30 * 60), 50, "14:30")
        \\eq(clock.youneek_minute(30 * 60 + 35), 50, "14:30:35 still 50")
        \\eq(clock.youneek_minute(59 * 60 + 59), 99, "14:59:59")
        \\eq(clock.youneek_minute(0), 0, "top of the hour")
        \\eq(clock.youneek_minute(35), 0, "35s")
        \\eq(clock.youneek_minute(36), 1, "36s")
        \\eq(clock.youneek_minute(-10), 0, "clamp low")
        \\eq(clock.youneek_minute(4000), 99, "clamp high")
        \\eq(clock.format_time(14, 30, 0, { mode = "youneek", hours = 24 }), "14:50", "ynk 24")
        \\eq(clock.format_time(14, 59, 59, { mode = "youneek", hours = 24 }), "14:99", "ynk 99")
        \\eq(clock.format_time(14, 30, 0, { mode = "youneek", hours = 12 }), "02:50 PM", "ynk 12")
        \\eq(clock.format_time(0, 15, 0, { mode = "youneek", hours = 12 }), "12:25 AM", "midnight 12")
        \\eq(clock.format_time(12, 0, 0, { hours = 12 }), "12:00 PM", "noon 12")
        \\eq(clock.format_time(14, 30, 45, { mode = "regular", hours = 24 }), "14:30", "regular")
        \\eq(clock.format_time(14, 30, 45, { mode = "normal", hours = 24 }), "14:30", "normal")
        \\eq(clock.format_time(9, 5, 0, { mode = "regular", hours = 12 }), "09:05 AM", "regular 12")
        \\eq(clock.normalize_hours(nil, true), 12, "hour12")
        \\eq(clock.normalize_mode("Civilian"), "regular", "mode")
        \\local utc = { kind = "utc" }
        \\local h, m, s = clock.civil(52200, utc)
        \\eq(h, 14, "utc hour")
        \\eq(m, 30, "utc minute")
        \\eq(s, 0, "utc second")
        \\eq(clock.format_time(h, m, s, { mode = "youneek", hours = 24 }), "14:50", "utc 14:30")
        \\local h2, m2, s2 = clock.civil(52200, { kind = "offset", offset = -5 * 3600 })
        \\eq(clock.format_time(h2, m2, s2, { mode = "youneek", hours = 24 }), "09:50", "-05:00")
        \\local h3, m3, s3 = clock.civil(52200, { kind = "offset", offset = -15 * 3600 })
        \\eq(clock.format_time(h3, m3, s3, { mode = "youneek", hours = 24 }), "23:50", "day wrap")
        \\eq(clock.parse_timezone("").kind, "local", "empty tz")
        \\eq(clock.parse_timezone("UTC").kind, "utc", "utc")
        \\eq(clock.parse_timezone("-05:00").offset, -5 * 3600, "parse offset")
        \\eq(clock.parse_timezone("nope"), nil, "bad tz")
        \\local function phase_name(p) return moon.phase_name(p) end
        \\eq(phase_name(0), "New Moon", "0")
        \\eq(phase_name(0.0299), "New Moon", "just under 0.03")
        \\eq(phase_name(0.03), "Waxing Crescent", "0.03")
        \\eq(phase_name(0.22), "First Quarter", "0.22")
        \\eq(phase_name(0.28), "Waxing Gibbous", "0.28")
        \\eq(phase_name(0.47), "Full Moon", "0.47")
        \\eq(phase_name(0.53), "Waning Gibbous", "0.53")
        \\eq(phase_name(0.72), "Last Quarter", "0.72")
        \\eq(phase_name(0.78), "Waning Crescent", "0.78")
        \\eq(phase_name(0.97), "New Moon", "0.97")
        \\eq(moon.glyph("Full Moon"), "🌕", "glyph")
        \\eq(moon.glyph("nope"), "🌙", "fallback glyph")
        \\local known = moon.at(947182440)
        \\eq(known.name, "New Moon", "suncalc new")
        \\eq(known.illumination, 0, "suncalc new illum")
        \\if known.phase < 0.97 then error("new phase " .. known.phase) end
        \\local full = moon.at(948458136)
        \\eq(full.name, "Full Moon", "suncalc full")
        \\eq(full.illumination, 100, "suncalc full illum")
        \\if full.phase < 0.47 or full.phase >= 0.53 then error("full phase " .. full.phase) end
        \\local sample = moon.at(947182440)
        \\local label = clock.segment(14, 30, 0, { mode = "youneek", hours = 24 }, sample)
        \\eq(label, "YouNeeK 14:50 YNK  " .. sample.glyph .. " New Moon 0%", "segment")
        \\dt.status.set("out", "ok")
        ,
        &.{},
        .{ .name = "" },
    }});
    const p = f.plugin(0);
    if (!p.running()) std.debug.print("youneek conversion: {s}\n", .{p.message});
    try t.expect(p.running());
    try t.expectEqualStrings("ok", f.host.segments.items[0].text);
}

test "youneek-time: regular 12h settings and a quiet chime" {
    const util = @import("../testutil.zig");
    const dir = util.cwdPath(t.allocator, &.{ "plugins", "youneek-time" }) catch return error.SkipZigTest;
    defer t.allocator.free(dir);
    const f = try Fixture.init();
    defer f.deinit();
    var lb: [300]u8 = undefined;
    var db: [300]u8 = undefined;
    f.host = try Host.init(t.allocator, f.fake.app(), .{
        .log_path = try std.fmt.bufPrint(&lb, "{s}/plugins.log", .{f.root}),
        .data_root = try std.fmt.bufPrint(&db, "{s}/data", .{f.root}),
        .version = "test",
    });
    f.host_opt = f.host;
    const V = value.Value;
    try f.host.start(&.{.{
        .name = "youneek-time",
        .version = "1.0.0",
        .dir = dir,
        .config = .{
            .name = "youneek-time",
            .settings = .{ .map = &.{
                .{ .key = "mode", .value = V{ .string = "regular" } },
                .{ .key = "hours", .value = V{ .integer = 12 } },
                .{ .key = "timezone", .value = V{ .string = "UTC" } },
                .{ .key = "chime", .value = V{ .boolean = true } },
            } },
        },
    }});
    const p = f.plugin(0);
    if (!p.running()) std.debug.print("youneek settings: {s}\n", .{p.message});
    try t.expect(p.running());
    var text: []const u8 = "";
    for (f.host.segments.items) |s| if (std.mem.eql(u8, s.id, "youneek")) {
        text = s.text;
    };
    try t.expect(std.mem.startsWith(u8, text, "YouNeeK "));
    try t.expect(std.mem.indexOf(u8, text, " YNK") == null);
    try t.expect(std.mem.indexOf(u8, text, " AM") != null or std.mem.indexOf(u8, text, " PM") != null);
    try t.expect(!f.noticeContains("YouNeeK Time"));
}
