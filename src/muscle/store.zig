//! ~/.config/death-terminal/shortcuts.lua
//!
//! The file is ordinary Lua that returns a table. It is loaded in a
//! sandbox (no io, os, or debug) and written back in a stable form.
//! `global` shortcuts run in every directory. `projects` is keyed by
//! git root, or by cwd when the directory is not in a repository.

const std = @import("std");
const lua = @import("../scripting/lua.zig");
const c = lua.c;
const paths = @import("paths.zig");
const history = @import("history.zig");

const wrapper =
    \\local src = ...
    \\local env = {
    \\  pairs = pairs, ipairs = ipairs, type = type,
    \\  tostring = tostring, tonumber = tonumber,
    \\  string = string, table = table,
    \\  math = { max = math.max, min = math.min, floor = math.floor },
    \\}
    \\local chunk, err = load(src, "@shortcuts.lua", "t", env)
    \\if not chunk then return nil, err end
    \\local ok, value = pcall(chunk)
    \\if not ok then return nil, value end
    \\if value == nil then return {} end
    \\return value
;

pub const Shortcut = struct {
    name: []u8,
    /// Empty string = global.
    project: []u8,
    commands: [][]u8,

    pub fn deinit(self: Shortcut, a: std.mem.Allocator) void {
        a.free(self.name);
        a.free(self.project);
        for (self.commands) |cmd| a.free(cmd);
        a.free(self.commands);
    }
};

pub const Book = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Shortcut),
    path: ?[]u8,
    mtime: i128 = 0,
    /// Set only while `loadFrom` walks the Lua table.
    live: ?*lua.State = null,

    pub fn init(a: std.mem.Allocator, path: ?[]const u8) !Book {
        var self = Book{
            .allocator = a,
            .items = std.ArrayList(Shortcut).init(a),
            .path = if (path) |p| try a.dupe(u8, p) else null,
        };
        errdefer self.deinit();
        if (self.path) |p| {
            self.loadFrom(p) catch |err| {
                std.debug.print("muscle: cannot read shortcuts: {s}\n", .{@errorName(err)});
            };
            self.noteMtime();
        }
        return self;
    }

    pub fn deinit(self: *Book) void {
        for (self.items.items) |s| s.deinit(self.allocator);
        self.items.deinit();
        if (self.path) |p| self.allocator.free(p);
    }

    pub fn reload(self: *Book) !void {
        const path = self.path orelse return;
        for (self.items.items) |s| s.deinit(self.allocator);
        self.items.clearRetainingCapacity();
        try self.loadFrom(path);
        self.noteMtime();
    }

    pub fn changedOnDisk(self: *Book) bool {
        const path = self.path orelse return false;
        const st = std.fs.cwd().statFile(path) catch return false;
        return st.mtime != self.mtime;
    }

    pub fn find(self: *const Book, project: []const u8, name: []const u8) ?usize {
        var global: ?usize = null;
        for (self.items.items, 0..) |s, i| {
            if (!std.mem.eql(u8, s.name, name)) continue;
            if (s.project.len == 0) global = i else if (std.mem.eql(u8, s.project, project)) return i;
        }
        return global;
    }

    pub fn nameTaken(self: *const Book, project: []const u8, name: []const u8, except: ?usize) bool {
        for (self.items.items, 0..) |s, i| {
            if (except) |e| if (e == i) continue;
            if (!std.mem.eql(u8, s.project, project)) continue;
            if (std.mem.eql(u8, s.name, name)) return true;
        }
        return false;
    }

    pub fn hasCommands(self: *const Book, project: []const u8, cmds: []const []const u8) bool {
        for (self.items.items) |s| {
            if (s.project.len != 0 and !std.mem.eql(u8, s.project, project)) continue;
            if (sameCommands(s.commands, cmds)) return true;
        }
        return false;
    }

    pub fn add(self: *Book, project: []const u8, name: []const u8, cmds: []const []const u8) !void {
        if (!validName(name) or cmds.len == 0) return error.InvalidShortcut;
        for (cmds) |cmd| if (history.containsSecret(self.allocator, cmd)) return error.Secret;
        const commands = try dupeCommands(self.allocator, cmds);
        errdefer {
            for (commands) |one| self.allocator.free(one);
            self.allocator.free(commands);
        }
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_project = try self.allocator.dupe(u8, project);
        errdefer self.allocator.free(owned_project);
        try self.items.append(.{
            .name = owned_name,
            .project = owned_project,
            .commands = commands,
        });
    }

    pub fn rename(self: *Book, index: usize, name: []const u8) !void {
        if (index >= self.items.items.len or !validName(name)) return error.InvalidShortcut;
        const copy = try self.allocator.dupe(u8, name);
        self.allocator.free(self.items.items[index].name);
        self.items.items[index].name = copy;
    }

    pub fn remove(self: *Book, index: usize) void {
        if (index >= self.items.items.len) return;
        var s = self.items.swapRemove(index);
        s.deinit(self.allocator);
    }

    pub fn save(self: *Book) !void {
        const path = self.path orelse return;
        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        const w = buf.writer();
        try w.writeAll(
            \\-- YouNeeK Death Terminal muscle-memory shortcuts.
            \\-- Reloaded when the command palette opens and when config reloads.
            \\-- global: every directory. projects: keyed by git root (or cwd).
            \\-- Commands run in order and stop after the first non-zero exit.
            \\
        );
        try w.writeAll("return {\n  global = {\n");
        for (self.items.items) |s| if (s.project.len == 0) try writeShortcut(w, s, 4);
        try w.writeAll("  },\n  projects = {\n");
        var projects = std.ArrayList([]const u8).init(self.allocator);
        defer projects.deinit();
        for (self.items.items) |s| {
            if (s.project.len == 0) continue;
            var seen = false;
            for (projects.items) |p| if (std.mem.eql(u8, p, s.project)) {
                seen = true;
                break;
            };
            if (!seen) try projects.append(s.project);
        }
        std.sort.insertion([]const u8, projects.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.less);
        for (projects.items) |p| {
            try w.writeAll("    [");
            try writeLuaString(w, p);
            try w.writeAll("] = {\n");
            for (self.items.items) |s| if (std.mem.eql(u8, s.project, p)) try writeShortcut(w, s, 6);
            try w.writeAll("    },\n");
        }
        try w.writeAll("  },\n}\n");
        try paths.replaceFile(path, buf.items);
        self.noteMtime();
    }

    fn noteMtime(self: *Book) void {
        const path = self.path orelse return;
        const st = std.fs.cwd().statFile(path) catch return;
        self.mtime = st.mtime;
    }

    fn loadFrom(self: *Book, path: []const u8) !void {
        const src = try paths.readFile(self.allocator, path, 1024 * 1024) orelse return;
        defer self.allocator.free(src);
        var vm = try lua.Vm.init(.{ .memory = 4 * 1024 * 1024, .instructions = 2_000_000 });
        defer vm.deinit();
        vm.startBudget(2_000_000, 500);
        const L = vm.L;
        try lua.loadText(L, wrapper, "muscle-shortcuts");
        lua.pushString(L, src);
        try lua.pcall(L, 1, 2);
        if (lua.isNil(L, -2)) {
            const msg = lua.toString(L, -1) orelse "invalid shortcuts.lua";
            std.debug.print("muscle: shortcuts.lua: {s}\n", .{msg});
            return error.BadShortcuts;
        }
        if (c.lua_type(L, -2) != c.LUA_TTABLE) return error.BadShortcuts;
        self.live = L;
        defer self.live = null;
        const root = c.lua_absindex(L, -2);
        _ = c.lua_getfield(L, root, "global");
        if (c.lua_type(L, -1) == c.LUA_TTABLE) try self.readList(-1, "");
        lua.pop(L, 1);
        _ = c.lua_getfield(L, root, "projects");
        if (c.lua_type(L, -1) == c.LUA_TTABLE) {
            const projects = c.lua_absindex(L, -1);
            c.lua_pushnil(L);
            while (c.lua_next(L, projects) != 0) {
                if (lua.toString(L, -2)) |key| {
                    const project = try self.allocator.dupe(u8, key);
                    defer self.allocator.free(project);
                    if (c.lua_type(L, -1) == c.LUA_TTABLE) self.readList(-1, project) catch |err| {
                        std.debug.print("muscle: skip project {s}: {s}\n", .{ project, @errorName(err) });
                    };
                }
                lua.pop(L, 1);
            }
        }
        lua.pop(L, 1);
    }

    fn readList(self: *Book, idx_in: c_int, project: []const u8) !void {
        const L = self.live orelse return error.BadShortcuts;
        const abs = c.lua_absindex(L, idx_in);
        const n = c.lua_rawlen(L, abs);
        var i: c.lua_Unsigned = 1;
        while (i <= n) : (i += 1) {
            _ = c.lua_rawgeti(L, abs, @intCast(i));
            self.readOne(-1, project) catch |err| {
                std.debug.print("muscle: skip shortcut: {s}\n", .{@errorName(err)});
            };
            lua.pop(L, 1);
        }
    }

    fn readOne(self: *Book, idx_in: c_int, project: []const u8) !void {
        const L = self.live orelse return error.BadShortcuts;
        const idx = c.lua_absindex(L, idx_in);
        if (c.lua_type(L, idx) != c.LUA_TTABLE) return error.InvalidShortcut;
        _ = c.lua_getfield(L, idx, "name");
        const name_src = lua.toString(L, -1) orelse {
            lua.pop(L, 1);
            return error.InvalidShortcut;
        };
        const name = try self.allocator.dupe(u8, name_src);
        errdefer self.allocator.free(name);
        lua.pop(L, 1);
        if (!validName(name)) return error.InvalidShortcut;
        _ = c.lua_getfield(L, idx, "commands");
        defer lua.pop(L, 1);
        if (c.lua_type(L, -1) != c.LUA_TTABLE) return error.InvalidShortcut;
        const commands_idx = c.lua_absindex(L, -1);
        const n = c.lua_rawlen(L, commands_idx);
        if (n == 0 or n > 8) return error.InvalidShortcut;
        const commands = try self.allocator.alloc([]u8, @intCast(n));
        errdefer self.allocator.free(commands);
        var filled: usize = 0;
        errdefer for (commands[0..filled]) |cmd| self.allocator.free(cmd);
        var i: c.lua_Unsigned = 1;
        while (i <= n) : (i += 1) {
            _ = c.lua_rawgeti(L, commands_idx, @intCast(i));
            const text = lua.toString(L, -1) orelse {
                lua.pop(L, 1);
                return error.InvalidShortcut;
            };
            if (text.len == 0 or history.containsSecret(self.allocator, text)) {
                lua.pop(L, 1);
                return error.Secret;
            }
            commands[filled] = try self.allocator.dupe(u8, text);
            filled += 1;
            lua.pop(L, 1);
        }
        if (self.nameTaken(project, name, null)) return error.InvalidShortcut;
        const project_copy = try self.allocator.dupe(u8, project);
        errdefer self.allocator.free(project_copy);
        try self.items.append(.{
            .name = name,
            .project = project_copy,
            .commands = commands,
        });
    }
};

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 32) return false;
    if (!std.ascii.isAlphanumeric(name[0]) and name[0] != '_') return false;
    for (name) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '.')) return false;
    }
    return true;
}

pub fn sameCommands(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

fn dupeCommands(a: std.mem.Allocator, cmds: []const []const u8) ![][]u8 {
    const out = try a.alloc([]u8, cmds.len);
    errdefer a.free(out);
    var n: usize = 0;
    errdefer for (out[0..n]) |one| a.free(one);
    for (cmds) |cmd| {
        out[n] = try a.dupe(u8, cmd);
        n += 1;
    }
    return out;
}

fn writeShortcut(w: anytype, s: Shortcut, indent: usize) !void {
    try w.writeByteNTimes(' ', indent);
    try w.writeAll("{ name = ");
    try writeLuaString(w, s.name);
    try w.writeAll(", commands = { ");
    for (s.commands, 0..) |cmd, i| {
        if (i != 0) try w.writeAll(", ");
        try writeLuaString(w, cmd);
    }
    try w.writeAll(" } },\n");
}

fn writeLuaString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |ch| switch (ch) {
        '\\' => try w.writeAll("\\\\"),
        '"' => try w.writeAll("\\\""),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (ch < 0x20) try w.print("\\{d:0>3}", .{ch}) else try w.writeByte(ch),
    };
    try w.writeByte('"');
}

test "shortcuts.lua round-trips and project names beat global" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try @import("../testutil.zig").tmpPath(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(dir);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, "shortcuts.lua" });
    defer std.testing.allocator.free(path);

    var book = try Book.init(std.testing.allocator, path);
    defer book.deinit();
    try book.add("", "ship", &.{ "git status", "git diff" });
    try book.add("/work/app", "ship", &.{ "zig build", "zig build test" });
    try book.add("/work/app", "fmt", &.{"zig fmt --check ."});
    try std.testing.expectError(error.Secret, book.add("/work/app", "leak", &.{"tool --password hunter2"}));
    try std.testing.expectError(error.InvalidShortcut, book.add("/work/app", "has space", &.{"ls"}));
    try book.save();

    const project = book.find("/work/app", "ship").?;
    try std.testing.expectEqualStrings("zig build", book.items.items[project].commands[0]);
    const global = book.find("/elsewhere", "ship").?;
    try std.testing.expectEqualStrings("git status", book.items.items[global].commands[0]);
    try std.testing.expect(book.hasCommands("/work/app", &.{ "zig build", "zig build test" }));
    try std.testing.expect(book.hasCommands("/elsewhere", &.{ "git status", "git diff" }));

    var again = try Book.init(std.testing.allocator, path);
    defer again.deinit();
    try std.testing.expectEqual(@as(usize, 3), again.items.items.len);
    const again_project = again.find("/work/app", "ship").?;
    try std.testing.expectEqualStrings("zig build test", again.items.items[again_project].commands[1]);
    try again.rename(again.find("/work/app", "fmt").?, "format");
    try std.testing.expect(again.find("/work/app", "format") != null);
    again.remove(again.find("/work/app", "format").?);
    try again.save();

    var third = try Book.init(std.testing.allocator, path);
    defer third.deinit();
    try std.testing.expectEqual(@as(usize, 2), third.items.items.len);
    try std.testing.expect(third.find("/work/app", "format") == null);
}

test "a shortcut that contains a secret is not loaded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try @import("../testutil.zig").tmpPath(std.testing.allocator, &tmp, ".");
    defer std.testing.allocator.free(dir);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, "shortcuts.lua" });
    defer std.testing.allocator.free(path);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = 
    \\return {
    \\  global = {
    \\    { name = "ok", commands = { "git status" } },
    \\    { name = "nope", commands = { "tool --password hunter2" } },
    \\  },
    \\  projects = {},
    \\}
    });
    var book = try Book.init(std.testing.allocator, path);
    defer book.deinit();
    try std.testing.expectEqual(@as(usize, 1), book.items.items.len);
    try std.testing.expectEqualStrings("ok", book.items.items[0].name);
}
