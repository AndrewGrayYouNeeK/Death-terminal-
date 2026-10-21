//! Muscle memory for one window: record finished commands, offer a shortcut
//! when a sequence repeats, and run the saved commands until one fails.
//!
//! The GUI calls this. Mining, the shortcut file and execution do not
//! import the window, so they stay testable on their own.

const std = @import("std");
const project = @import("project.zig");
const history = @import("history.zig");
const mine = @import("mine.zig");
const store = @import("store.zig");
const exec = @import("exec.zig");
const paths = @import("paths.zig");

pub const offer_text = "You run these together a lot. Make it a shortcut?";

pub const Settings = struct {
    enabled: bool = true,
    min_repeats: u16 = 3,
    max_len: u16 = 5,
};

pub const Op = enum(u8) {
    run = 1,
    rename = 2,
    delete = 3,
    save = 4,
    save_global = 5,
};

pub fn pack(op: Op, index: usize) usize {
    return (@as(usize, @intFromEnum(op)) << 24) | (index & 0x00ffffff);
}

pub fn unpack(v: usize) ?struct { op: Op, index: usize } {
    const op = std.meta.intToEnum(Op, @as(u8, @intCast((v >> 24) & 0xff))) catch return null;
    return .{ .op = op, .index = v & 0x00ffffff };
}

pub const InputResult = enum { idle, stay, saved, dismissed, invalid };

pub const Key = enum { enter, escape, backspace, clear };

pub const RunStep = union(enum) {
    ignore,
    send: []u8,
    stopped: []u8,
    finished,
};

pub const PalItem = struct {
    arg: usize,
    title: []u8,
    detail: []u8,
};

const NameFor = union(enum) { create, rename: usize };

const Pending = struct {
    project: []u8,
    commands: [][]u8,
    global: bool = false,

    fn deinit(self: *Pending, a: std.mem.Allocator) void {
        a.free(self.project);
        for (self.commands) |c| a.free(c);
        a.free(self.commands);
    }
};

const Active = struct {
    pane: u32,
    commands: [][]u8,
    runner: exec.Runner,

    fn deinit(self: *Active, a: std.mem.Allocator) void {
        for (self.commands) |c| a.free(c);
        a.free(self.commands);
    }
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    settings: Settings = .{},
    log: history.Log,
    book: store.Book,
    mode: enum { idle, offer, name } = .idle,
    pending: ?Pending = null,
    name: std.ArrayList(u8),
    name_for: NameFor = .create,
    run: ?Active = null,
    asked: std.ArrayList(u64),
    dismissed: std.ArrayList(u64),
    dismissed_path: ?[]u8 = null,
    pal_items: std.ArrayList(PalItem),
    status_buf: [240]u8 = undefined,
    status_len: usize = 0,

    pub fn open(a: std.mem.Allocator) !Session {
        if (paths.resolve(a)) |resolved| {
            var files = resolved;
            defer files.deinit(a);
            return Session.init(a, files.history, files.shortcuts, files.dismissed);
        } else |_| return Session.init(a, null, null, null);
    }

    pub fn init(a: std.mem.Allocator, history_path: ?[]const u8, shortcuts_path: ?[]const u8, dismissed_path: ?[]const u8) !Session {
        var self = Session{
            .allocator = a,
            .log = try history.Log.init(a, history_path),
            .book = try store.Book.init(a, shortcuts_path),
            .name = std.ArrayList(u8).init(a),
            .asked = std.ArrayList(u64).init(a),
            .dismissed = std.ArrayList(u64).init(a),
            .pal_items = std.ArrayList(PalItem).init(a),
            .dismissed_path = if (dismissed_path) |p| try a.dupe(u8, p) else null,
        };
        errdefer self.deinit();
        if (self.dismissed_path) |p| self.loadDismissed(p) catch |err| {
            std.debug.print("muscle: cannot read dismissals: {s}\n", .{@errorName(err)});
        };
        return self;
    }

    pub fn deinit(self: *Session) void {
        self.cancelRun();
        self.clearPending();
        self.clearPalette();
        self.pal_items.deinit();
        self.name.deinit();
        self.asked.deinit();
        self.dismissed.deinit();
        if (self.dismissed_path) |p| self.allocator.free(p);
        self.log.deinit();
        self.book.deinit();
    }

    pub fn setSettings(self: *Session, s: Settings) void {
        self.settings = s;
        if (self.settings.max_len < 2) self.settings.max_len = 2;
        if (self.settings.max_len > 8) self.settings.max_len = 8;
        if (self.settings.min_repeats < 2) self.settings.min_repeats = 2;
        if (!self.settings.enabled) {
            self.clearPending();
            self.mode = .idle;
            self.cancelRun();
        }
    }

    pub fn capturing(self: *const Session) bool {
        return self.mode != .idle;
    }

    pub fn running(self: *const Session) bool {
        return self.run != null;
    }

    pub fn status(self: *const Session) []const u8 {
        return self.status_buf[0..self.status_len];
    }

    pub fn offerCommands(self: *const Session) []const []const u8 {
        const p = self.pending orelse return &.{};
        return p.commands;
    }

    pub fn nameText(self: *const Session) []const u8 {
        return self.name.items;
    }

    pub fn shortcutCount(self: *const Session) usize {
        return self.book.items.items.len;
    }

    /// Record one finished command. True when a new offer should be shown.
    pub fn observe(self: *Session, cwd: []const u8, command: []const u8, exit_code: ?i32) !bool {
        if (!self.settings.enabled) return false;
        const kept = self.log.record(cwd, command, exit_code) catch |err| {
            std.debug.print("muscle: history: {s}\n", .{@errorName(err)});
            return false;
        };
        if (!kept) return false;
        if (self.mode != .idle or self.run != null) return false;
        return self.considerOffer();
    }

    pub fn acceptOffer(self: *Session, global: bool) void {
        if (self.pending == null) return;
        self.pending.?.global = global;
        self.mode = .name;
        self.name_for = .create;
        self.name.clearRetainingCapacity();
        self.status_len = 0;
    }

    pub fn dismiss(self: *Session, persist: bool) !void {
        if (self.pending) |p| {
            const fp = mine.fingerprint(p.project, p.commands);
            if (persist) try self.rememberDismiss(fp);
        }
        self.clearPending();
        self.name.clearRetainingCapacity();
        self.mode = .idle;
    }

    pub fn beginRename(self: *Session, index: usize) !void {
        if (index >= self.book.items.items.len) return;
        self.clearPending();
        self.mode = .name;
        self.name_for = .{ .rename = index };
        self.name.clearRetainingCapacity();
        try self.name.appendSlice(self.book.items.items[index].name);
        self.status_len = 0;
    }

    pub fn deleteAt(self: *Session, index: usize) !bool {
        if (index >= self.book.items.items.len) return false;
        var name_buf: [32]u8 = undefined;
        const n = @min(name_buf.len, self.book.items.items[index].name.len);
        @memcpy(name_buf[0..n], self.book.items.items[index].name[0..n]);
        self.book.remove(index);
        try self.book.save();
        self.setStatus("shortcut deleted: {s}", .{name_buf[0..n]});
        return true;
    }

    pub fn onText(self: *Session, bytes: []const u8) !InputResult {
        if (self.mode == .idle) return .idle;
        if (self.mode == .offer) {
            if (bytes.len == 1) switch (bytes[0]) {
                'y', 'Y', '\r', '\n' => {
                    self.acceptOffer(false);
                    return .stay;
                },
                'n', 'N', 0x1b, 0x03 => {
                    try self.dismiss(true);
                    return .dismissed;
                },
                else => {},
            };
            return .stay;
        }
        if (bytes.len == 1) switch (bytes[0]) {
            '\r', '\n' => return self.commitName(),
            0x1b, 0x03 => {
                self.cancelName();
                return .dismissed;
            },
            0x7f, 0x08 => {
                deleteLast(&self.name);
                self.status_len = 0;
                return .stay;
            },
            0x15 => {
                self.name.clearRetainingCapacity();
                self.status_len = 0;
                return .stay;
            },
            else => {},
        };
        for (bytes) |b| if (b < 0x20 or b == 0x7f) return .stay;
        if (self.name.items.len + bytes.len > 32) return .stay;
        try self.name.appendSlice(bytes);
        self.status_len = 0;
        return .stay;
    }

    pub fn onKey(self: *Session, key: Key) !InputResult {
        if (self.mode == .idle) return .idle;
        return switch (key) {
            .enter => self.onText("\r"),
            .escape => self.onText("\x1b"),
            .backspace => self.onText("\x7f"),
            .clear => self.onText("\x15"),
        };
    }

    pub fn lookup(self: *Session, cwd: []const u8, name: []const u8) ?usize {
        if (!self.settings.enabled) return null;
        self.reloadIfIdle();
        const trimmed = std.mem.trim(u8, name, " \t");
        if (trimmed.len == 0 or std.mem.indexOfAny(u8, trimmed, " \t") != null) return null;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const key = project.into(cwd, &buf) orelse "";
        return self.book.find(key, trimmed);
    }

    /// Bytes to write to the PTY, or null when `index` is not a shortcut.
    /// When a run is already active the caller should swallow a duplicate
    /// Enter instead of calling this.
    pub fn begin(self: *Session, index: usize, pane: u32, shell_seen: bool, clear: bool) !?[]u8 {
        if (!self.settings.enabled or self.run != null) return null;
        if (index >= self.book.items.items.len) return null;
        const cmds = self.book.items.items[index].commands;
        if (cmds.len == 0) return null;
        if (!shell_seen) {
            const joined = try exec.chain(self.allocator, cmds);
            defer self.allocator.free(joined);
            return try exec.launchLine(self.allocator, clear, joined);
        }
        const owned = try dupeCommands(self.allocator, cmds);
        self.run = .{
            .pane = pane,
            .commands = owned,
            .runner = .{ .len = owned.len },
        };
        const started = self.run.?.runner.begin();
        if (started != .send) {
            self.cancelRun();
            return null;
        }
        return exec.launchLine(self.allocator, clear, self.run.?.commands[0]) catch |err| {
            self.cancelRun();
            return err;
        };
    }

    pub fn runExit(self: *Session, pane: u32, command: []const u8, code: ?i32) !RunStep {
        const run = &(self.run orelse return .ignore);
        if (run.pane != pane or !run.runner.waiting) return .ignore;
        const expect = std.mem.trim(u8, run.commands[run.runner.index], " \t");
        if (!std.mem.eql(u8, expect, std.mem.trim(u8, command, " \t"))) {
            self.cancelRun();
            return .ignore;
        }
        switch (run.runner.onExit(code)) {
            .send => |i| return .{ .send = try exec.launchLine(self.allocator, false, self.run.?.commands[i]) },
            .stop => |s| {
                const msg = try std.fmt.allocPrint(self.allocator, "shortcut stopped: {s} (exit {d})", .{ self.run.?.commands[s.index], s.exit_code });
                self.cancelRun();
                return .{ .stopped = msg };
            },
            .done => {
                self.cancelRun();
                return .finished;
            },
            .ignore => return .ignore,
        }
    }

    pub fn paletteItems(self: *Session) ![]const PalItem {
        self.clearPalette();
        if (!self.settings.enabled) return self.pal_items.items;
        self.reloadIfIdle();
        if (self.mode == .offer) {
            try self.addPal(.save, 0, "Make this a shortcut", "this project");
            try self.addPal(.save_global, 0, "Make this a global shortcut", "every directory");
        }
        for (self.book.items.items, 0..) |s, i| {
            const scope = if (s.project.len == 0) "global" else std.fs.path.basename(s.project);
            const preview = try commandPreview(self.allocator, s.commands);
            defer self.allocator.free(preview);
            var detail: [180]u8 = undefined;
            const detail_text = std.fmt.bufPrint(&detail, "{s} · {s}", .{ scope, preview }) catch scope;
            var run_title: [48]u8 = undefined;
            const title = std.fmt.bufPrint(&run_title, "{s}", .{s.name}) catch s.name;
            try self.addPal(.run, i, title, detail_text);
            var rename_title: [64]u8 = undefined;
            const rt = std.fmt.bufPrint(&rename_title, "Rename shortcut: {s}", .{s.name}) catch "Rename shortcut";
            try self.addPal(.rename, i, rt, scope);
            var delete_title: [64]u8 = undefined;
            const dt = std.fmt.bufPrint(&delete_title, "Delete shortcut: {s}", .{s.name}) catch "Delete shortcut";
            try self.addPal(.delete, i, dt, scope);
        }
        return self.pal_items.items;
    }

    fn addPal(self: *Session, op: Op, index: usize, title: []const u8, detail: []const u8) !void {
        try self.pal_items.append(.{
            .arg = pack(op, index),
            .title = try self.allocator.dupe(u8, title),
            .detail = try self.allocator.dupe(u8, detail),
        });
    }

    fn considerOffer(self: *Session) !bool {
        if (self.log.entries.items.len < @as(usize, self.settings.min_repeats) * 2) return false;
        var keys = std.StringHashMap([]u8).init(self.allocator);
        defer {
            var it = keys.iterator();
            while (it.next()) |e| self.allocator.free(e.value_ptr.*);
            keys.deinit();
        }
        var recs = std.ArrayList(mine.Record).init(self.allocator);
        defer recs.deinit();
        for (self.log.entries.items) |e| {
            const key = try self.projectKey(&keys, e.cwd);
            if (key.len == 0) continue;
            try recs.append(.{ .project = key, .command = e.command });
        }
        const hits = try mine.mine(self.allocator, recs.items, .{
            .min_repeats = self.settings.min_repeats,
            .max_len = self.settings.max_len,
        });
        defer mine.freeHits(self.allocator, hits);
        for (hits) |h| {
            const fp = mine.fingerprint(h.project, h.commands);
            if (self.seenHash(fp) or self.book.hasCommands(h.project, h.commands)) continue;
            try self.setPending(h.project, h.commands);
            try self.asked.append(fp);
            self.mode = .offer;
            return true;
        }
        return false;
    }

    fn projectKey(self: *Session, keys: *std.StringHashMap([]u8), cwd: []const u8) ![]const u8 {
        if (keys.get(cwd)) |k| return k;
        const key = try project.alloc(self.allocator, cwd);
        errdefer self.allocator.free(key);
        try keys.put(cwd, key);
        return key;
    }

    fn setPending(self: *Session, project_key: []const u8, cmds: []const []const u8) !void {
        self.clearPending();
        const commands = try dupeCommands(self.allocator, cmds);
        errdefer {
            for (commands) |c| self.allocator.free(c);
            self.allocator.free(commands);
        }
        const copy = try self.allocator.dupe(u8, project_key);
        self.pending = .{ .project = copy, .commands = commands };
    }

    fn clearPending(self: *Session) void {
        if (self.pending) |*p| p.deinit(self.allocator);
        self.pending = null;
    }

    fn cancelName(self: *Session) void {
        self.name.clearRetainingCapacity();
        self.clearPending();
        self.mode = .idle;
        self.status_len = 0;
    }

    fn cancelRun(self: *Session) void {
        if (self.run) |*r| r.deinit(self.allocator);
        self.run = null;
    }

    fn commitName(self: *Session) !InputResult {
        var raw = std.mem.trim(u8, self.name.items, " ");
        var scope: []const u8 = "";
        switch (self.name_for) {
            .create => {
                const p = self.pending orelse {
                    self.setStatus("nothing to save", .{});
                    return .invalid;
                };
                var global = p.global;
                if (raw.len > 0 and raw[0] == '*') {
                    global = true;
                    raw = std.mem.trim(u8, raw[1..], " ");
                }
                scope = if (global) "" else p.project;
            },
            .rename => |idx| {
                if (idx >= self.book.items.items.len) return .invalid;
                scope = self.book.items.items[idx].project;
            },
        }
        if (!store.validName(raw)) {
            self.setStatus("use a short name: letters, digits, _ - .", .{});
            return .invalid;
        }
        const except: ?usize = switch (self.name_for) {
            .rename => |idx| idx,
            .create => null,
        };
        if (self.book.nameTaken(scope, raw, except)) {
            self.setStatus("that name is already used here", .{});
            return .invalid;
        }
        switch (self.name_for) {
            .create => {
                const p = self.pending orelse return .invalid;
                self.book.add(scope, raw, p.commands) catch |err| switch (err) {
                    error.Secret => {
                        self.setStatus("that sequence contains a secret and was not saved", .{});
                        return .invalid;
                    },
                    error.InvalidShortcut => {
                        self.setStatus("that shortcut is not valid", .{});
                        return .invalid;
                    },
                    else => return err,
                };
            },
            .rename => |idx| try self.book.rename(idx, raw),
        }
        try self.book.save();
        const where: []const u8 = if (scope.len == 0) "global" else "this project";
        self.setStatus("shortcut saved: {s} ({s})", .{ raw, where });
        self.clearPending();
        self.name.clearRetainingCapacity();
        self.mode = .idle;
        return .saved;
    }

    fn seenHash(self: *const Session, fp: u64) bool {
        for (self.asked.items) |h| if (h == fp) return true;
        for (self.dismissed.items) |h| if (h == fp) return true;
        return false;
    }

    fn rememberDismiss(self: *Session, fp: u64) !void {
        for (self.dismissed.items) |h| if (h == fp) return;
        try self.dismissed.append(fp);
        const path = self.dismissed_path orelse return;
        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        try buf.appendSlice("# sequences the user did not want as shortcuts\n");
        for (self.dismissed.items) |h| try buf.writer().print("{x}\n", .{h});
        try paths.replaceFile(path, buf.items);
    }

    fn loadDismissed(self: *Session, path: []const u8) !void {
        const data = try paths.readFile(self.allocator, path, 256 * 1024) orelse return;
        defer self.allocator.free(data);
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;
            const fp = std.fmt.parseInt(u64, trimmed, 16) catch continue;
            try self.dismissed.append(fp);
        }
    }

    pub fn refreshShortcuts(self: *Session) void {
        if (self.run != null) return;
        self.book.reload() catch |err| {
            std.debug.print("muscle: reload shortcuts: {s}\n", .{@errorName(err)});
        };
    }

    fn reloadIfIdle(self: *Session) void {
        if (self.mode != .idle or self.run != null) return;
        if (!self.book.changedOnDisk()) return;
        self.refreshShortcuts();
    }

    fn clearPalette(self: *Session) void {
        for (self.pal_items.items) |it| {
            self.allocator.free(it.title);
            self.allocator.free(it.detail);
        }
        self.pal_items.clearRetainingCapacity();
    }

    fn setStatus(self: *Session, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.status_buf, fmt, args) catch {
            self.status_len = 0;
            return;
        };
        self.status_len = text.len;
    }
};

fn dupeCommands(a: std.mem.Allocator, cmds: []const []const u8) ![][]u8 {
    const out = try a.alloc([]u8, cmds.len);
    errdefer a.free(out);
    var n: usize = 0;
    errdefer for (out[0..n]) |c| a.free(c);
    for (cmds) |c| {
        out[n] = try a.dupe(u8, c);
        n += 1;
    }
    return out;
}

fn commandPreview(a: std.mem.Allocator, cmds: []const []const u8) ![]u8 {
    var buf = std.ArrayList(u8).init(a);
    errdefer buf.deinit();
    for (cmds, 0..) |c, i| {
        if (buf.items.len > 80) {
            try buf.appendSlice(" …");
            break;
        }
        if (i != 0) try buf.appendSlice(" → ");
        try buf.appendSlice(c);
    }
    return buf.toOwnedSlice();
}

fn deleteLast(buf: *std.ArrayList(u8)) void {
    if (buf.items.len == 0) return;
    var i = buf.items.len - 1;
    while (i > 0 and buf.items[i] & 0xC0 == 0x80) i -= 1;
    buf.shrinkRetainingCapacity(i);
}

const t = std.testing;

fn tempSession(dir: []const u8) !Session {
    const a = t.allocator;
    const hist = try std.fs.path.join(a, &.{ dir, "hist" });
    errdefer a.free(hist);
    const shorts = try std.fs.path.join(a, &.{ dir, "shortcuts.lua" });
    errdefer a.free(shorts);
    const dis = try std.fs.path.join(a, &.{ dir, "dismissed" });
    errdefer a.free(dis);
    var s = try Session.init(a, hist, shorts, dis);
    s.allocator.free(hist);
    s.allocator.free(shorts);
    s.allocator.free(dis);
    return s;
}

test "session offers a repeated sequence, saves it, and stops on failure" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try @import("../testutil.zig").tmpPath(t.allocator, &tmp, ".");
    defer t.allocator.free(dir);
    var s = try tempSession(dir);
    defer s.deinit();

    const cwd = "/work/app";
    const seq = [_][]const u8{ "git status", "git diff" };
    var i: usize = 0;
    while (i < 2) : (i += 1) {
        try t.expect(!try s.observe(cwd, seq[0], 0));
        try t.expect(!try s.observe(cwd, seq[1], 0));
    }
    try t.expect(!try s.observe(cwd, seq[0], 0));
    try t.expect(try s.observe(cwd, seq[1], 0));
    try t.expect(s.mode == .offer);
    try t.expect(!try s.observe(cwd, "tool --password hunter2", 0));
    try t.expectEqual(@as(usize, 6), s.log.entries.items.len);

    try t.expect(try s.onText("y") == .stay);
    try t.expect(s.mode == .name);
    try t.expect(try s.onText("ship") == .stay);
    try t.expect(try s.onKey(.enter) == .saved);
    try t.expect(s.mode == .idle);
    try t.expect(std.mem.indexOf(u8, s.status(), "ship") != null);

    const idx = s.lookup(cwd, "ship").?;
    const first = (try s.begin(idx, 7, true, true)).?;
    defer t.allocator.free(first);
    try t.expectEqual(@as(u8, 0x15), first[0]);
    try t.expect(std.mem.endsWith(u8, first, "git status\r"));

    const second = try s.runExit(7, "git status", 0);
    defer t.allocator.free(second.send);
    try t.expectEqualStrings("git diff\r", second.send);
    const stopped = try s.runExit(7, "git diff", 2);
    defer t.allocator.free(stopped.stopped);
    try t.expect(std.mem.indexOf(u8, stopped.stopped, "exit 2") != null);
    try t.expect(std.mem.indexOf(u8, stopped.stopped, "git diff") != null);
    try t.expect(s.runExit(7, "git diff", 0) catch unreachable == .ignore);

    // Without shell integration the whole sequence is one `&&` chain.
    const chained = (try s.begin(idx, 7, false, false)).?;
    defer t.allocator.free(chained);
    try t.expectEqualStrings("git status && git diff\r", chained);
    try t.expect(s.run == null);
}

test "dismissed sequences are not offered again" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try @import("../testutil.zig").tmpPath(t.allocator, &tmp, ".");
    defer t.allocator.free(dir);
    var s = try tempSession(dir);
    const cwd = "/work/app";
    var n: usize = 0;
    while (n < 3) : (n += 1) {
        _ = try s.observe(cwd, "make", 0);
        _ = try s.observe(cwd, "make test", 0);
    }
    try t.expect(s.mode == .offer);
    try s.dismiss(true);
    s.deinit();

    var again = try tempSession(dir);
    defer again.deinit();
    // A new command re-mines the saved history. The dismissed pair is still
    // there three times; it must not be offered. (`make` again would form
    // a different pair, `make test` then `make`, which was not dismissed.)
    try t.expect(!try again.observe(cwd, "echo done", 0));
    try t.expect(again.mode == .idle);
}

test "a star name is global and the palette lists run, rename and delete" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try @import("../testutil.zig").tmpPath(t.allocator, &tmp, ".");
    defer t.allocator.free(dir);
    var s = try tempSession(dir);
    defer s.deinit();
    try s.book.add("/work/app", "ship", &.{ "git status", "git diff" });
    try s.book.save();
    s.mode = .offer;
    s.pending = .{
        .project = try t.allocator.dupe(u8, "/work/app"),
        .commands = try dupeCommands(t.allocator, &.{ "git status", "git diff" }),
    };
    s.acceptOffer(false);
    s.name.clearRetainingCapacity();
    try s.name.appendSlice("*ship");
    // Project already has `ship`. The star saves a different scope.
    try t.expect(try s.commitName() == .saved);
    try t.expect(s.lookup("/somewhere/else", "ship") != null);
    const items = try s.paletteItems();
    try t.expect(items.len >= 3);
    var saw_run = false;
    var saw_delete = false;
    for (items) |it| {
        const decoded = unpack(it.arg) orelse continue;
        if (decoded.op == .run) saw_run = true;
        if (decoded.op == .delete) saw_delete = true;
    }
    try t.expect(saw_run and saw_delete);
}
