//! Finding plugins and deciding which run.
//!
//! A plugin is a directory `<plugins_dir>/<name>/` with `manifest.lua` and
//! `init.lua`. Whether it runs: `config.plugins.<name>.enabled` if set, else
//! the state file written by `deathterminal --plugins enable|disable`, else
//! yes. What it may do is only ever granted by config.lua
//! (`config.plugins.<name>.allow`).
//!
//! Locations (XDG):
//!   plugins     $XDG_CONFIG_HOME/death-terminal/plugins   (config.plugins_dir)
//!   data        $XDG_DATA_HOME/death-terminal/plugins/<name>
//!   state, log  $XDG_STATE_HOME/death-terminal/plugins.json, plugins.log

const std = @import("std");
const manifest = @import("manifest.zig");
const permissions = @import("permissions.zig");
const PluginConfig = @import("plugin_config.zig").PluginConfig;
const plugin_config = @import("plugin_config.zig");
const host = @import("host.zig");

pub const Paths = struct {
    plugins_dir: []const u8,
    data_root: []const u8,
    state_file: []const u8,
    log_file: []const u8,

    /// `configured` is config.plugins_dir ("" = default); "~/" is expanded.
    pub fn resolve(a: std.mem.Allocator, configured: []const u8) !Paths {
        return resolveEnv(a, configured, std.posix.getenv);
    }

    pub fn resolveEnv(a: std.mem.Allocator, configured: []const u8, env: *const fn ([]const u8) ?[]const u8) !Paths {
        const home = env("HOME") orelse "";
        const config_home = try xdg(a, env, "XDG_CONFIG_HOME", home, ".config");
        const data_home = try xdg(a, env, "XDG_DATA_HOME", home, ".local/share");
        const state_home = try xdg(a, env, "XDG_STATE_HOME", home, ".local/state");
        const dir = if (configured.len == 0)
            try std.fs.path.join(a, &.{ config_home, "death-terminal", "plugins" })
        else if (std.mem.startsWith(u8, configured, "~/"))
            try std.fs.path.join(a, &.{ home, configured[2..] })
        else
            try a.dupe(u8, configured);
        return .{
            .plugins_dir = dir,
            .data_root = try std.fs.path.join(a, &.{ data_home, "death-terminal", "plugins" }),
            .state_file = try std.fs.path.join(a, &.{ state_home, "death-terminal", "plugins.json" }),
            .log_file = try std.fs.path.join(a, &.{ state_home, "death-terminal", "plugins.log" }),
        };
    }

    fn xdg(a: std.mem.Allocator, env: *const fn ([]const u8) ?[]const u8, name: []const u8, home: []const u8, fallback: []const u8) ![]const u8 {
        if (env(name)) |v| if (v.len > 0 and std.fs.path.isAbsolute(v)) return a.dupe(u8, v);
        return std.fs.path.join(a, &.{ home, fallback });
    }
};

pub const Found = struct {
    name: []const u8,
    dir: []const u8,
    manifest: ?manifest.Manifest = null,
    /// Why it can't run (bad manifest, no init.lua), if anything.
    problem: ?[]const u8 = null,
    /// init.lua + manifest.lua modification times, for "did it change?".
    mtime: i128 = 0,
};

/// Every subdirectory of `dir`, sorted by name (memory from `a`, an arena).
pub fn discover(a: std.mem.Allocator, dir_path: []const u8) ![]Found {
    var list = std.ArrayList(Found).init(a);
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return list.items,
        else => return err,
    };
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |e| {
        if (e.kind != .directory and e.kind != .sym_link) continue;
        if (e.name[0] == '.') continue;
        var f = Found{ .name = try a.dupe(u8, e.name), .dir = try std.fs.path.join(a, &.{ dir_path, e.name }) };
        if (!manifest.validName(e.name)) {
            f.problem = "invalid directory name (use lowercase letters, digits, _ and -, starting with a letter)";
            try list.append(f);
            continue;
        }
        var sub = dir.openDir(e.name, .{}) catch {
            continue; // a symlink to a file, or unreadable
        };
        defer sub.close();
        const init_stat = sub.statFile("init.lua") catch null;
        const src = sub.readFileAlloc(a, "manifest.lua", manifest.max_bytes) catch |err| {
            f.problem = switch (err) {
                error.FileNotFound => "missing manifest.lua",
                error.FileTooBig => "manifest.lua is too large",
                else => "cannot read manifest.lua",
            };
            try list.append(f);
            continue;
        };
        var eb: [400]u8 = undefined;
        var db: [200]u8 = undefined;
        const display = std.fmt.bufPrint(&db, "{s}/manifest.lua", .{e.name}) catch "manifest.lua";
        if (manifest.parse(a, src, display, e.name, &eb)) |m| {
            f.manifest = m;
        } else |err| switch (err) {
            error.Invalid => f.problem = try a.dupe(u8, manifest.message(&eb)),
            error.OutOfMemory => return error.OutOfMemory,
        }
        if (init_stat) |st| {
            f.mtime = st.mtime;
        } else if (f.problem == null) f.problem = "missing init.lua";
        if (sub.statFile("manifest.lua")) |st| f.mtime +%= st.mtime else |_| {}
        try list.append(f);
    }
    std.mem.sort(Found, list.items, {}, struct {
        fn lt(_: void, x: Found, y: Found) bool {
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.lt);
    return list.items;
}

// ---------------------------------------------------------------- state file

/// `{"enabled": [...], "disabled": [...]}` written by the CLI.
pub const StateFile = struct {
    enabled: []const []const u8 = &.{},
    disabled: []const []const u8 = &.{},

    pub fn load(a: std.mem.Allocator, path: []const u8) StateFile {
        const src = std.fs.cwd().readFileAlloc(a, path, 1024 * 1024) catch return .{};
        const parsed = std.json.parseFromSliceLeaky(StateFile, a, src, .{ .ignore_unknown_fields = true }) catch return .{};
        return parsed;
    }

    pub fn save(self: StateFile, path: []const u8) !void {
        if (std.fs.path.dirname(path)) |d| try std.fs.cwd().makePath(d);
        var buf = std.ArrayList(u8).init(std.heap.page_allocator);
        defer buf.deinit();
        try std.json.stringify(self, .{ .whitespace = .indent_2 }, buf.writer());
        try buf.append('\n');
        var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});
        try std.fs.cwd().writeFile(.{ .sub_path = tmp, .data = buf.items });
        try std.fs.cwd().rename(tmp, path);
    }

    fn contains(list: []const []const u8, name: []const u8) bool {
        for (list) |n| if (std.mem.eql(u8, n, name)) return true;
        return false;
    }

    /// Set `name` on or off (memory from `a`).
    pub fn set(self: *StateFile, a: std.mem.Allocator, name: []const u8, on: bool) !void {
        var en = std.ArrayList([]const u8).init(a);
        var dis = std.ArrayList([]const u8).init(a);
        for (self.enabled) |n| if (!std.mem.eql(u8, n, name)) try en.append(n);
        for (self.disabled) |n| if (!std.mem.eql(u8, n, name)) try dis.append(n);
        try (if (on) &en else &dis).append(name);
        self.enabled = en.items;
        self.disabled = dis.items;
    }
};

pub const Decision = struct {
    enabled: bool,
    source: enum { config, state_file, default },

    pub fn describe(self: Decision) []const u8 {
        return switch (self.source) {
            .config => if (self.enabled) "enabled in config.lua" else "disabled in config.lua",
            .state_file => if (self.enabled) "enabled (--plugins enable)" else "disabled (--plugins disable)",
            .default => "enabled (default)",
        };
    }
};

pub fn decide(name: []const u8, configs: []const PluginConfig, state: StateFile) Decision {
    if (plugin_config.find(configs, name)) |pc| if (pc.enabled) |e| return .{ .enabled = e, .source = .config };
    if (StateFile.contains(state.disabled, name)) return .{ .enabled = false, .source = .state_file };
    if (StateFile.contains(state.enabled, name)) return .{ .enabled = true, .source = .state_file };
    return .{ .enabled = true, .source = .default };
}

/// What the host should load. `hash` changes when anything that matters
/// for a running plugin does (files, grants, settings, enabled state).
pub const Plan = struct {
    paths: Paths,
    found: []Found,
    specs: []host.Spec,
    hash: u64,
};

pub fn plan(a: std.mem.Allocator, plugins_dir_cfg: []const u8, configs: []const PluginConfig) !Plan {
    const paths = try Paths.resolve(a, plugins_dir_cfg);
    return planAt(a, paths, configs);
}

pub fn planAt(a: std.mem.Allocator, paths: Paths, configs: []const PluginConfig) !Plan {
    const found = try discover(a, paths.plugins_dir);
    const state = StateFile.load(a, paths.state_file);
    var specs = std.ArrayList(host.Spec).init(a);
    var h = std.hash.Wyhash.init(0x9e3779b9);
    h.update(paths.plugins_dir);
    for (found) |f| {
        const m = f.manifest orelse continue;
        if (f.problem != null) continue;
        if (!decide(f.name, configs, state).enabled) continue;
        const cfg: PluginConfig = if (plugin_config.find(configs, f.name)) |pc| pc.* else .{ .name = f.name };
        try specs.append(.{
            .name = f.name,
            .version = m.version,
            .description = m.description,
            .dir = f.dir,
            .requested = m.permissions,
            .config = cfg,
        });
        h.update(f.name);
        h.update(std.mem.asBytes(&f.mtime));
        h.update(std.mem.asBytes(&m.permissions.bits.mask));
        cfg.hash(&h);
    }
    return .{ .paths = paths, .found = found, .specs = specs.items, .hash = h.final() };
}

// ---------------------------------------------------------------- CLI

/// `deathterminal --plugins list|enable <name>|disable <name>`.
pub fn cli(a: std.mem.Allocator, args: []const []const u8, plugins_dir_cfg: []const u8, configs: []const PluginConfig, plugins_on: bool, out: anytype) !u8 {
    const usage = "usage: deathterminal --plugins list | enable <name> | disable <name>\n";
    const sub = if (args.len > 0) args[0] else "list";
    const p = try plan(a, plugins_dir_cfg, configs);
    if (std.mem.eql(u8, sub, "list")) {
        try printList(p, configs, plugins_on, out);
        return 0;
    }
    const on = std.mem.eql(u8, sub, "enable");
    if (!on and !std.mem.eql(u8, sub, "disable")) {
        try out.writeAll(usage);
        return 2;
    }
    if (args.len < 2) {
        try out.writeAll(usage);
        return 2;
    }
    const name = args[1];
    const exists = for (p.found) |f| {
        if (std.mem.eql(u8, f.name, name)) break true;
    } else false;
    if (!exists) {
        try out.print("no plugin named \"{s}\" in {s}\n", .{ name, p.paths.plugins_dir });
        if (p.found.len > 0) {
            try out.writeAll("installed:");
            for (p.found) |f| try out.print(" {s}", .{f.name});
            try out.writeAll("\n");
        }
        return 1;
    }
    var state = StateFile.load(a, p.paths.state_file);
    try state.set(a, name, on);
    state.save(p.paths.state_file) catch |err| {
        try out.print("cannot write {s}: {s}\n", .{ p.paths.state_file, @errorName(err) });
        return 1;
    };
    try out.print("{s} {s} (saved in {s}; takes effect on the next start or config reload, Ctrl+Shift+R)\n", .{ name, if (on) "enabled" else "disabled", p.paths.state_file });
    if (plugin_config.find(configs, name)) |pc| if (pc.enabled) |e| if (e != on) {
        try out.print("note: config.lua sets plugins[\"{s}\"].enabled = {s}, which takes precedence\n", .{ name, if (e) "true" else "false" });
    };
    if (!plugins_on) try out.writeAll("note: plugins are switched off (config.plugins_enabled = false)\n");
    return 0;
}

fn printList(p: Plan, configs: []const PluginConfig, plugins_on: bool, out: anytype) !void {
    const state = StateFile.load(std.heap.page_allocator, p.paths.state_file);
    try out.print("Plugins in {s}{s}\n", .{ p.paths.plugins_dir, if (plugins_on) "" else "  (all off: config.plugins_enabled = false)" });
    if (p.found.len == 0) try out.writeAll("  (none installed; see docs/PLUGINS.md)\n");
    for (p.found) |f| {
        const m = f.manifest orelse {
            try out.print("\n  {s}  BROKEN: {s}\n", .{ f.name, f.problem orelse "?" });
            continue;
        };
        const d = decide(f.name, configs, state);
        try out.print("\n  {s} {s}  {s}\n", .{ f.name, m.version, d.describe() });
        if (m.description.len > 0) try out.print("      {s}\n", .{m.description});
        if (f.problem) |why| try out.print("      BROKEN: {s}\n", .{why});
        const allow = if (plugin_config.find(configs, f.name)) |pc| pc.allow else permissions.Set.initEmpty();
        var granted = m.permissions;
        granted.setIntersection(allow);
        var missing = m.permissions;
        missing.setIntersection(allow.complement());
        var b1: [160]u8 = undefined;
        var b2: [160]u8 = undefined;
        var b3: [160]u8 = undefined;
        try out.print("      requests: {s}   granted: {s}", .{ permissions.format(m.permissions, &b1), permissions.format(granted, &b2) });
        if (missing.count() > 0) {
            try out.print("   not granted: {s}\n", .{permissions.format(missing, &b3)});
            try out.print("      grant with: config.plugins[\"{s}\"] = {{ allow = {{", .{f.name});
            var it = missing.iterator();
            var first = true;
            while (it.next()) |perm| {
                try out.print("{s} \"{s}\"", .{ if (first) "" else ",", @tagName(perm) });
                first = false;
            }
            try out.writeAll(" } }\n");
        } else try out.writeAll("\n");
    }
    for (configs) |pc| {
        const installed = for (p.found) |f| {
            if (std.mem.eql(u8, f.name, pc.name)) break true;
        } else false;
        if (!installed) try out.print("\n  {s}  configured in config.lua but not installed\n", .{pc.name});
    }
    try out.print("\nData: {s}/<name>   Log: {s}\n", .{ p.paths.data_root, p.paths.log_file });
}

test "discover, decide and plan" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = tmp.dir;
    try d.makePath("plugins/good");
    try d.writeFile(.{ .sub_path = "plugins/good/manifest.lua", .data = "return { name = 'good', version = '1.2', permissions = { 'exec', 'screen' } }" });
    try d.writeFile(.{ .sub_path = "plugins/good/init.lua", .data = "" });
    try d.makePath("plugins/noinit");
    try d.writeFile(.{ .sub_path = "plugins/noinit/manifest.lua", .data = "return { name = 'noinit', version = '1' }" });
    try d.makePath("plugins/badname");
    try d.writeFile(.{ .sub_path = "plugins/badname/manifest.lua", .data = "return { name = 'other', version = '1' }" });
    try d.writeFile(.{ .sub_path = "plugins/badname/init.lua", .data = "" });
    try d.makePath("plugins/off");
    try d.writeFile(.{ .sub_path = "plugins/off/manifest.lua", .data = "return { name = 'off', version = '1' }" });
    try d.writeFile(.{ .sub_path = "plugins/off/init.lua", .data = "" });
    const root = try d.realpathAlloc(a, ".");
    const paths = Paths{
        .plugins_dir = try std.fs.path.join(a, &.{ root, "plugins" }),
        .data_root = try std.fs.path.join(a, &.{ root, "data" }),
        .state_file = try std.fs.path.join(a, &.{ root, "state/plugins.json" }),
        .log_file = try std.fs.path.join(a, &.{ root, "state/plugins.log" }),
    };
    var state = StateFile{};
    try state.set(a, "off", false);
    try state.save(paths.state_file);

    var allow = permissions.Set.initEmpty();
    allow.insert(.exec);
    const configs = [_]PluginConfig{.{ .name = "good", .allow = allow, .exec = &.{"git"} }};
    const p = try planAt(a, paths, &configs);
    try std.testing.expectEqual(@as(usize, 4), p.found.len);
    try std.testing.expectEqualStrings("badname", p.found[0].name);
    try std.testing.expect(std.mem.indexOf(u8, p.found[0].problem.?, "does not match") != null);
    try std.testing.expectEqualStrings("missing init.lua", p.found[2].problem.?);
    try std.testing.expectEqual(@as(usize, 1), p.specs.len);
    try std.testing.expectEqualStrings("good", p.specs[0].name);
    try std.testing.expectEqualStrings("git", p.specs[0].config.exec[0]);

    // The state file turns "off" back on; config.lua beats it.
    try state.set(a, "off", true);
    try state.save(paths.state_file);
    const p2 = try planAt(a, paths, &configs);
    try std.testing.expectEqual(@as(usize, 2), p2.specs.len);
    try std.testing.expect(p2.hash != p.hash);
    const configs2 = [_]PluginConfig{ configs[0], .{ .name = "off", .enabled = false } };
    const p3 = try planAt(a, paths, &configs2);
    try std.testing.expectEqual(@as(usize, 1), p3.specs.len);
    try std.testing.expectEqual(Decision{ .enabled = false, .source = .config }, decide("off", &configs2, StateFile.load(a, paths.state_file)));

    var out = std.ArrayList(u8).init(a);
    try printList(p3, &configs2, true, out.writer());
    const text = out.items;
    try std.testing.expect(std.mem.indexOf(u8, text, "good 1.2  enabled (default)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "not granted: screen") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "off 1  disabled in config.lua") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "BROKEN: missing init.lua") != null);
}

test "paths follow XDG" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const env = struct {
        fn get(name: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, name, "HOME")) return "/home/u";
            if (std.mem.eql(u8, name, "XDG_STATE_HOME")) return "/var/st";
            if (std.mem.eql(u8, name, "XDG_DATA_HOME")) return "relative/ignored";
            return null;
        }
    }.get;
    const p = try Paths.resolveEnv(arena.allocator(), "", env);
    try std.testing.expectEqualStrings("/home/u/.config/death-terminal/plugins", p.plugins_dir);
    try std.testing.expectEqualStrings("/home/u/.local/share/death-terminal/plugins", p.data_root);
    try std.testing.expectEqualStrings("/var/st/death-terminal/plugins.json", p.state_file);
    const q = try Paths.resolveEnv(arena.allocator(), "~/dt", env);
    try std.testing.expectEqualStrings("/home/u/dt", q.plugins_dir);
}
