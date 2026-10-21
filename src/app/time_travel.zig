//! GUI-facing Time Travel hub. One store, one timeline per pane.
//! Snapshots are taken when the terminal parses OSC 133 C (see
//! `notifyStart`); the diff is recorded when the command finishes.

const std = @import("std");
const builtin = @import("builtin");
const env_mod = @import("../platform/env.zig");
const input = @import("../terminal/input.zig");
const terminal = @import("../terminal/terminal.zig");
const config = @import("../config/config.zig");
const ai_controller = @import("ai_controller.zig");
const exclude = @import("../timetravel/exclude.zig");
const summary = @import("../timetravel/summary.zig");
const travel = @import("../timetravel/travel.zig");
const store_mod = @import("../timetravel/store.zig");

const Cell = terminal.Cell;
const Store = store_mod.Store;

var current: ?*Hub = null;

pub const Start = struct {
    pane: u32,
    started: u64,
    cwd: []const u8,
    remote: bool,
    command: []const u8,
    ai: *ai_controller.Controller,
};

pub const Hub = struct {
    a: std.mem.Allocator,
    store: ?Store = null,
    logs: std.AutoHashMap(u32, travel.Timeline),
    excludes: std.ArrayList([]const u8),
    enabled: bool = true,
    ai_summary: bool = true,
    ai_enabled: bool = true,
    max_bytes: u64 = 200 * 1024 * 1024,
    retention: u32 = 50,
    open: bool = false,
    dirty: bool = false,
    next_id: u64 = 1,
    /// Borrowed by `snapshotFor` until the next call.
    borrow_id: [96]u8 = undefined,
    borrow_fail: [96]u8 = undefined,

    pub fn open(a: std.mem.Allocator, cfg: *const config.Config) Hub {
        const dir = dataDir(a) catch return blank(a, cfg);
        defer a.free(dir);
        return openAt(a, cfg, dir);
    }

    pub fn openAt(a: std.mem.Allocator, cfg: *const config.Config, dir: []const u8) Hub {
        var hub = blank(a, cfg);
        hub.store = Store.open(a, dir) catch return hub;
        return hub;
    }

    pub fn deinit(self: *Hub) void {
        if (current == self) current = null;
        var it = self.logs.iterator();
        while (it.next()) |e| e.value_ptr.deinit();
        self.logs.deinit();
        for (self.excludes.items) |p| self.a.free(p);
        self.excludes.deinit();
        if (self.store) |*st| st.deinit();
    }

    /// The hub must already live at its final address.
    pub fn activate(self: *Hub) void {
        current = self;
    }

    pub fn apply(self: *Hub, cfg: *const config.Config) void {
        self.enabled = cfg.tt_enabled;
        self.ai_summary = cfg.tt_ai_summary;
        self.ai_enabled = cfg.ai_enabled;
        self.max_bytes = @as(u64, cfg.tt_max_dir_mb) * 1024 * 1024;
        self.retention = cfg.tt_retention;
        for (self.excludes.items) |p| self.a.free(p);
        self.excludes.clearRetainingCapacity();
        for (cfg.tt_excludes.items) |p| {
            const copy = self.a.dupe(u8, p) catch continue;
            self.excludes.append(copy) catch {
                self.a.free(copy);
            };
        }
    }

    pub fn isOpen(self: *const Hub) bool {
        return self.open;
    }

    /// Ghost Run shows `t` when a snapshot can be taken. This does not capture.
    pub fn snapshotReady(self: *const Hub) bool {
        return self.enabled and self.store != null;
    }

    /// Result of a Ghost Run snapshot. `ok` and `failed` text is borrowed
    /// from this hub until the next `snapshotFor`.
    pub const ManualSnap = union(enum) {
        ok: []const u8,
        unavailable,
        failed: []const u8,
    };

    /// Snapshot `cwd` before `command` runs. Does not run `command`.
    pub fn snapshotFor(self: *Hub, cwd: []const u8, command: []const u8, pane: u32) ManualSnap {
        if (!self.snapshotReady()) return .unavailable;
        if (cwd.len == 0 or !std.fs.path.isAbsolute(cwd)) return .unavailable;
        const tl = self.timeline(pane) catch return self.borrowFail("out of memory");
        const id = self.next_id;
        self.next_id += 1;
        const st: ?*Store = if (self.store) |*p| p else null;
        _ = tl.begin(st, id, .{
            .enabled = true,
            .remote = false,
            .max_bytes = self.max_bytes,
            .excludes = self.excludeSlice(),
            .cwd = cwd,
            .command = command,
            .now_ms = std.time.milliTimestamp(),
        }) catch return self.borrowFail("out of memory");
        tl.trim(self.retention);
        self.gc();
        const entry = tl.find(id) orelse return self.borrowFail("snapshot failed");
        if (entry.snap_id.len == 0) {
            const why = if (entry.skip.len > 0) entry.skip else "snapshot failed";
            return self.borrowFail(why);
        }
        return self.borrowOk(entry.snap_id);
    }

    fn borrowOk(self: *Hub, text: []const u8) ManualSnap {
        const n = @min(text.len, self.borrow_id.len);
        @memcpy(self.borrow_id[0..n], text[0..n]);
        return .{ .ok = self.borrow_id[0..n] };
    }

    fn borrowFail(self: *Hub, text: []const u8) ManualSnap {
        const n = @min(text.len, self.borrow_fail.len);
        @memcpy(self.borrow_fail[0..n], text[0..n]);
        return .{ .failed = self.borrow_fail[0..n] };
    }

    pub fn takeDirty(self: *Hub) bool {
        const d = self.dirty;
        self.dirty = false;
        return d;
    }

    pub fn toggle(self: *Hub, pane: u32) void {
        if (self.open) {
            self.open = false;
            if (self.logs.getPtr(pane)) |tl| tl.confirm = false;
            return;
        }
        self.open = true;
        const tl = self.timeline(pane) catch return;
        tl.arm();
    }

    pub fn close(self: *Hub) void {
        self.open = false;
    }

    /// Clear a confirm prompt, or close the overlay. True when it closed.
    pub fn cancel(self: *Hub, pane: u32) bool {
        const tl = self.logs.getPtr(pane) orelse {
            self.open = false;
            return true;
        };
        if (tl.confirm) {
            tl.confirm = false;
            return false;
        }
        self.open = false;
        return true;
    }

    pub fn drop(self: *Hub, pane: u32) void {
        if (self.logs.fetchRemove(pane)) |kv| {
            var tl = kv.value;
            tl.deinit();
        }
    }

    pub fn onKey(self: *Hub, pane: u32, key: input.Key) travel.KeyResult {
        const tl = self.logs.getPtr(pane) orelse return .handled;
        const result = tl.onKey(key);
        self.applyResult(tl, result);
        return result;
    }

    pub fn onText(self: *Hub, pane: u32, bytes: []const u8) travel.KeyResult {
        const tl = self.logs.getPtr(pane) orelse return .handled;
        const result = tl.onText(bytes);
        self.applyResult(tl, result);
        return result;
    }

    pub fn click(self: *Hub, pane: u32, row: u16, rows: u16) void {
        const tl = self.logs.getPtr(pane) orelse return;
        tl.click(row, rows);
    }

    pub fn draw(self: *Hub, pane: u32, cells: []Cell, rows: u16, cols: u16) void {
        if (self.logs.getPtr(pane)) |tl| tl.draw(cells, rows, cols) else travel.drawEmpty(cells, rows, cols);
    }

    pub fn observe(self: *Hub, s: Start, finished: u64, exit_code: ?i32) void {
        self.onStart(s) catch |err| {
            std.debug.print("time travel: {s}\n", .{@errorName(err)});
        };
        self.onFinish(s.pane, finished, exit_code, s.ai) catch |err| {
            std.debug.print("time travel: {s}\n", .{@errorName(err)});
        };
    }

    fn applyResult(self: *Hub, tl: *travel.Timeline, result: travel.KeyResult) void {
        switch (result) {
            .rewind => self.rewind(tl),
            .undo => self.undo(tl),
            .close => self.open = false,
            .ignored, .handled => {},
        }
    }

    fn rewind(self: *Hub, tl: *travel.Timeline) void {
        const st = if (self.store) |*s| s else {
            tl.setNote("store unavailable");
            return;
        };
        tl.rewind(st, self.excludeSlice(), self.max_bytes) catch |err| {
            std.debug.print("time travel: {s}\n", .{@errorName(err)});
        };
        self.gc();
    }

    fn undo(self: *Hub, tl: *travel.Timeline) void {
        const st = if (self.store) |*s| s else {
            tl.setNote("store unavailable");
            return;
        };
        tl.undo(st, self.excludeSlice()) catch |err| {
            std.debug.print("time travel: {s}\n", .{@errorName(err)});
        };
    }

    fn onStart(self: *Hub, s: Start) !void {
        const tl = try self.timeline(s.pane);
        if (tl.seen_started == s.started) return;
        tl.seen_started = s.started;
        const id = self.next_id;
        self.next_id += 1;
        const opts = travel.Opts{
            .enabled = self.enabled,
            .remote = s.remote,
            .max_bytes = self.max_bytes,
            .excludes = self.excludeSlice(),
            .cwd = s.cwd,
            .command = s.command,
            .now_ms = std.time.milliTimestamp(),
        };
        const st = if (self.store) |*p| p else null;
        if (try tl.begin(st, id, opts)) |closed| self.summarize(s.ai, tl, closed);
        tl.trim(self.retention);
        self.gc();
    }

    fn onFinish(self: *Hub, pane: u32, finished: u64, exit_code: ?i32, ai: *ai_controller.Controller) !void {
        const tl = self.logs.getPtr(pane) orelse return;
        if (tl.seen_finished == finished) return;
        tl.seen_finished = finished;
        const st = if (self.store) |*p| p else null;
        if (try tl.finish(st, exit_code, self.excludeSlice(), self.max_bytes)) |id| self.summarize(ai, tl, id);
    }

    fn summarize(self: *Hub, ai: *ai_controller.Controller, tl: *travel.Timeline, id: u64) void {
        if (!self.ai_summary or !self.ai_enabled) return;
        const entry = tl.find(id) orelse return;
        if (!entry.changed()) return;
        if (ai.suggesting()) return;
        var built = summary.build(self.a, entry.command, entry.added.items, entry.removed.items, entry.modified.items) catch return;
        defer built.deinit(self.a);
        ai.on_summary = summaryCb;
        ai.summary_ctx = self;
        ai.summary_for = id;
        ai.summary_gen = ai.submitSummary(&built.messages) catch return;
    }

    fn gc(self: *Hub) void {
        const st = if (self.store) |*s| s else return;
        var keep = std.ArrayList([]const u8).init(self.a);
        defer keep.deinit();
        var it = self.logs.iterator();
        while (it.next()) |e| e.value_ptr.pin(&keep) catch return;
        st.prune(keep.items, self.retention) catch {};
    }

    fn excludeSlice(self: *Hub) []const []const u8 {
        return self.excludes.items;
    }

    fn timeline(self: *Hub, pane: u32) !*travel.Timeline {
        if (self.logs.getPtr(pane)) |tl| return tl;
        var tl = try travel.Timeline.init(self.a);
        self.logs.put(pane, tl) catch |err| {
            tl.deinit();
            return err;
        };
        return self.logs.getPtr(pane).?;
    }
};

fn blank(a: std.mem.Allocator, cfg: *const config.Config) Hub {
    var hub = Hub{
        .a = a,
        .logs = std.AutoHashMap(u32, travel.Timeline).init(a),
        .excludes = std.ArrayList([]const u8).init(a),
    };
    hub.apply(cfg);
    return hub;
}

fn summaryCb(ctx: *anyopaque, id: u64, text: []const u8, done: bool, failed: bool) void {
    const hub: *Hub = @ptrCast(@alignCast(ctx));
    var it = hub.logs.iterator();
    while (it.next()) |e| {
        const entry = e.value_ptr.find(id) orelse continue;
        if (failed) {
            if (done and entry.summary.len == 0) e.value_ptr.setSummary(id, "summary unavailable") catch {};
        } else {
            const line = summary.oneLine(text);
            if (line.len == 0 and !done) return;
            e.value_ptr.setSummary(id, line) catch {};
        }
        hub.dirty = true;
        return;
    }
}

pub fn notifyStart(s: Start) void {
    const hub = current orelse return;
    hub.onStart(s) catch |err| {
        std.debug.print("time travel: {s}\n", .{@errorName(err)});
    };
}

pub fn dataDir(a: std.mem.Allocator) ![]u8 {
    const win = builtin.os.tag == .windows;
    const home = (if (win) env_mod.get("USERPROFILE") orelse env_mod.get("HOME") else env_mod.get("HOME")) orelse "";
    const local = if (win) env_mod.get("LOCALAPPDATA") else null;
    const data_home = if (local) |x|
        try a.dupe(u8, x)
    else if (env_mod.get("XDG_DATA_HOME")) |v|
        if (v.len > 0 and std.fs.path.isAbsolute(v)) try a.dupe(u8, v) else try std.fs.path.join(a, &.{ home, ".local/share" })
    else
        try std.fs.path.join(a, &.{ home, ".local/share" });
    defer a.free(data_home);
    return std.fs.path.join(a, &.{ data_home, "death-terminal", "time-travel" });
}

test "hub records a diff and rewinds through the store" {
    const a = std.testing.allocator;
    var cfg = config.Config.init(a);
    defer cfg.deinit();
    cfg.tt_ai_summary = false;
    var parent = std.testing.tmpDir(.{});
    defer parent.cleanup();
    try parent.dir.makeDir("work");
    try parent.dir.writeFile(.{ .sub_path = "work/a.txt", .data = "hello" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try parent.dir.realpath(".", &root_buf);
    var work_buf: [std.fs.max_path_bytes]u8 = undefined;
    var store_buf: [std.fs.max_path_bytes]u8 = undefined;
    const work = try std.fmt.bufPrint(&work_buf, "{s}/work", .{root});
    const store_path = try std.fmt.bufPrint(&store_buf, "{s}/tt", .{root});
    var hub = Hub.openAt(a, &cfg, store_path);
    defer hub.deinit();
    var ai = ai_controller.Controller.init(a, .{});
    defer ai.deinit();
    hub.observe(.{
        .pane = 1,
        .started = 1,
        .cwd = work,
        .remote = false,
        .command = "edit",
        .ai = &ai,
    }, 0, null);
    try parent.dir.writeFile(.{ .sub_path = "work/a.txt", .data = "bye" });
    hub.observe(.{
        .pane = 1,
        .started = 1,
        .cwd = work,
        .remote = false,
        .command = "edit",
        .ai = &ai,
    }, 1, 0);
    const tl = hub.logs.getPtr(1).?;
    try std.testing.expect(tl.entries.items[0].finished);
    try std.testing.expect(tl.entries.items[0].modified_total == 1);
    hub.toggle(1);
    _ = hub.onKey(1, .enter);
    _ = hub.onText(1, "y");
    const body = try parent.dir.readFileAlloc(a, "work/a.txt", 16);
    defer a.free(body);
    try std.testing.expectEqualStrings("hello", body);
    _ = hub.onText(1, "u");
    const back = try parent.dir.readFileAlloc(a, "work/a.txt", 16);
    defer a.free(back);
    try std.testing.expectEqualStrings("bye", back);
    try std.testing.expectEqual(@as(usize, exclude.default_patterns.len), hub.excludes.items.len);
}

test "hub snapshotFor copies the tree and does not run the command" {
    const a = std.testing.allocator;
    var cfg = config.Config.init(a);
    defer cfg.deinit();
    cfg.tt_ai_summary = false;
    var parent = std.testing.tmpDir(.{});
    defer parent.cleanup();
    try parent.dir.makeDir("work");
    try parent.dir.writeFile(.{ .sub_path = "work/a.txt", .data = "hello" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try parent.dir.realpath(".", &root_buf);
    var work_buf: [std.fs.max_path_bytes]u8 = undefined;
    var store_buf: [std.fs.max_path_bytes]u8 = undefined;
    const work = try std.fmt.bufPrint(&work_buf, "{s}/work", .{root});
    const store_path = try std.fmt.bufPrint(&store_buf, "{s}/tt", .{root});
    var hub = Hub.openAt(a, &cfg, store_path);
    defer hub.deinit();
    try std.testing.expect(hub.snapshotReady());
    const snap = hub.snapshotFor(work, "rm -rf x", 1);
    const id = switch (snap) {
        .ok => |got| got,
        .unavailable, .failed => return error.ExpectedSnapshot,
    };
    try std.testing.expect(id.len > 0);
    const body = try parent.dir.readFileAlloc(a, "work/a.txt", 16);
    defer a.free(body);
    try std.testing.expectEqualStrings("hello", body);
    try std.testing.expect(hub.snapshotFor("", "rm -rf x", 1) == .unavailable);
    hub.enabled = false;
    try std.testing.expect(!hub.snapshotReady());
    try std.testing.expect(hub.snapshotFor(work, "rm -rf x", 1) == .unavailable);
}
