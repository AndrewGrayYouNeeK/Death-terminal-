//! Per-session command timeline: snapshot before a command, diff after it,
//! draw the overlay, and rewind (with one undo) into that same directory.

const std = @import("std");
const input = @import("../terminal/input.zig");
const terminal = @import("../terminal/terminal.zig");
const store_mod = @import("store.zig");

const Cell = terminal.Cell;
const Store = store_mod.Store;

const max_names = 200;
const show_names = 8;

pub const KeyResult = enum { ignored, handled, close, rewind, undo };

pub const Opts = struct {
    enabled: bool = true,
    remote: bool = false,
    max_bytes: u64,
    excludes: []const []const u8 = &.{},
    cwd: []const u8 = "",
    command: []const u8 = "",
    now_ms: i64 = 0,
};

pub const Entry = struct {
    id: u64,
    command: []u8,
    cwd: []u8,
    when_ms: i64,
    snap_id: []u8,
    skip: []u8,
    exit_code: ?i32 = null,
    finished: bool = false,
    added: std.ArrayList([]u8),
    removed: std.ArrayList([]u8),
    modified: std.ArrayList([]u8),
    added_total: usize = 0,
    removed_total: usize = 0,
    modified_total: usize = 0,
    summary: []u8,
    bytes: u64 = 0,

    pub fn deinit(self: *Entry, a: std.mem.Allocator) void {
        a.free(self.command);
        a.free(self.cwd);
        a.free(self.snap_id);
        a.free(self.skip);
        a.free(self.summary);
        freeNames(a, &self.added);
        freeNames(a, &self.removed);
        freeNames(a, &self.modified);
    }

    pub fn changed(self: *const Entry) bool {
        return self.added_total + self.removed_total + self.modified_total > 0;
    }
};

fn freeNames(a: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |s| a.free(s);
    list.deinit();
}

pub const Timeline = struct {
    a: std.mem.Allocator,
    entries: std.ArrayList(Entry),
    selected: usize = 0,
    confirm: bool = false,
    undo_id: []u8,
    undo_cwd: []u8,
    seen_started: u64 = 0,
    seen_finished: u64 = 0,
    note: []u8,

    pub fn init(a: std.mem.Allocator) !Timeline {
        return .{
            .a = a,
            .entries = std.ArrayList(Entry).init(a),
            .undo_id = try a.dupe(u8, ""),
            .undo_cwd = try a.dupe(u8, ""),
            .note = try a.dupe(u8, ""),
        };
    }

    pub fn deinit(self: *Timeline) void {
        for (self.entries.items) |*e| e.deinit(self.a);
        self.entries.deinit();
        self.a.free(self.undo_id);
        self.a.free(self.undo_cwd);
        self.a.free(self.note);
    }

    pub fn arm(self: *Timeline) void {
        self.confirm = false;
        if (self.entries.items.len > 0) self.selected = self.entries.items.len - 1;
    }

    /// Snapshot `opts.cwd` unless this command should be skipped. Returns
    /// the id of a previous command that this call closed, if it was still
    /// running.
    pub fn begin(self: *Timeline, st: ?*Store, id: u64, opts: Opts) !?u64 {
        const closed = try self.closeOpen(st, opts.excludes, opts.max_bytes);
        var entry = try self.blank(id, opts.command, opts.cwd, opts.now_ms);
        errdefer entry.deinit(self.a);
        if (!opts.enabled) {
            try self.replace(&entry.skip, "disabled");
        } else if (opts.remote) {
            try self.replace(&entry.skip, "remote");
        } else if (opts.cwd.len == 0) {
            try self.replace(&entry.skip, "cwd unknown");
        } else if (!std.fs.path.isAbsolute(opts.cwd)) {
            try self.replace(&entry.skip, "relative");
        } else if (st == null) {
            try self.replace(&entry.skip, "store unavailable");
        } else {
            var snap = st.?.capture(opts.cwd, .{
                .max_bytes = opts.max_bytes,
                .excludes = opts.excludes,
            }) catch |err| {
                try self.replace(&entry.skip, @errorName(err));
                try self.entries.append(entry);
                return closed;
            };
            defer snap.deinit(self.a);
            entry.bytes = snap.bytes;
            if (snap.skip) |why| {
                try self.replace(&entry.skip, if (why == .too_big) "too big" else "too many");
            } else {
                try self.replace(&entry.snap_id, snap.id);
            }
        }
        try self.entries.append(entry);
        self.selected = self.entries.items.len - 1;
        return closed;
    }

    pub fn finish(self: *Timeline, st: ?*Store, exit_code: ?i32, excludes: []const []const u8, max_bytes: u64) !?u64 {
        if (self.entries.items.len == 0) return null;
        const entry = &self.entries.items[self.entries.items.len - 1];
        if (entry.finished) return null;
        return self.finishEntry(entry, st, exit_code, excludes, max_bytes);
    }

    pub fn trim(self: *Timeline, retention: usize) void {
        const keep = @max(retention, 1);
        while (self.entries.items.len > keep) {
            var old = self.entries.orderedRemove(0);
            old.deinit(self.a);
            if (self.selected > 0) self.selected -= 1;
        }
    }

    pub fn pin(self: *const Timeline, out: *std.ArrayList([]const u8)) !void {
        for (self.entries.items) |e| if (e.snap_id.len > 0) try out.append(e.snap_id);
        if (self.undo_id.len > 0) try out.append(self.undo_id);
    }

    pub fn setSummary(self: *Timeline, id: u64, text: []const u8) !void {
        const entry = self.find(id) orelse return;
        try self.replace(&entry.summary, text);
    }

    pub fn find(self: *Timeline, id: u64) ?*Entry {
        for (self.entries.items) |*e| if (e.id == id) return e;
        return null;
    }

    pub fn onKey(self: *Timeline, key: input.Key) KeyResult {
        self.clearNote();
        if (self.confirm) {
            switch (key) {
                .enter, .kp_enter => return .rewind,
                .escape => {
                    self.confirm = false;
                    return .handled;
                },
                else => return .handled,
            }
        }
        switch (key) {
            .up => self.move(-1),
            .down => self.move(1),
            .page_up => self.move(-8),
            .page_down => self.move(8),
            .home => self.move(-100000),
            .end => self.move(100000),
            .enter, .kp_enter => if (self.entries.items.len > 0) {
                self.confirm = true;
            },
            .escape => return .close,
            else => {},
        }
        return .handled;
    }

    /// `rewind` / `undo` are requests; the caller performs them.
    pub fn onText(self: *Timeline, bytes: []const u8) KeyResult {
        if (bytes.len != 1) return .handled;
        self.clearNote();
        switch (bytes[0]) {
            'y', 'Y' => if (self.confirm) return .rewind,
            'n', 'N' => if (self.confirm) {
                self.confirm = false;
            },
            0x1b => if (self.confirm) {
                self.confirm = false;
            } else return .close,
            'u', 'U' => if (!self.confirm) return .undo,
            else => {},
        }
        return .handled;
    }

    pub fn click(self: *Timeline, row: u16, rows: u16) void {
        if (rows < 4) return;
        const top: u16 = 2;
        const bot = rows - 2;
        if (row < top or row >= bot) return;
        const vis = self.window(bot - top);
        const idx = vis + (row - top);
        if (idx < self.entries.items.len) {
            self.selected = idx;
            self.confirm = false;
            self.clearNote();
        }
    }

    pub fn rewind(self: *Timeline, st: *Store, excludes: []const []const u8, max_bytes: u64) !void {
        self.confirm = false;
        if (self.entries.items.len == 0) {
            self.setNote("no snapshot");
            return;
        }
        if (!self.entries.items[self.entries.items.len - 1].finished) {
            self.setNote("command still running");
            return;
        }
        const entry = self.entries.items[self.selected];
        if (entry.snap_id.len == 0) {
            self.setNote(if (entry.skip.len > 0) entry.skip else "no snapshot");
            return;
        }
        var undo_snap = try st.capture(entry.cwd, .{ .max_bytes = max_bytes, .excludes = excludes });
        if (!undo_snap.saved()) {
            undo_snap.deinit(self.a);
            self.setNote("can't rewind: folder larger than max_dir_mb, rewind would not be undoable");
            return;
        }
        var before = st.load(entry.snap_id) catch |err| {
            undo_snap.deinit(self.a);
            self.setNote(explain(err));
            return;
        };
        defer before.deinit(self.a);
        st.restoreExcluding(&before, entry.cwd, excludes) catch |err| {
            self.keepUndo(&undo_snap) catch {};
            self.setNote(explain(err));
            return;
        };
        try self.keepUndo(&undo_snap);
        self.setNote("rewound");
        std.debug.print("→ time travel: rewound {s} to before `{s}`\n", .{ entry.cwd, entry.command });
    }

    pub fn undo(self: *Timeline, st: *Store, excludes: []const []const u8) !void {
        if (self.undo_id.len == 0) {
            self.setNote("nothing to undo");
            return;
        }
        var snap = st.load(self.undo_id) catch |err| {
            self.setNote(explain(err));
            return;
        };
        defer snap.deinit(self.a);
        st.restoreExcluding(&snap, self.undo_cwd, excludes) catch |err| {
            self.setNote(explain(err));
            return;
        };
        self.setNote("undo restored the folder");
        const blank_id = try self.a.dupe(u8, "");
        const blank_cwd = try self.a.dupe(u8, "");
        self.a.free(self.undo_id);
        self.a.free(self.undo_cwd);
        self.undo_id = blank_id;
        self.undo_cwd = blank_cwd;
    }

    pub fn draw(self: *const Timeline, cells: []Cell, rows: u16, cols: u16) void {
        paintOverlay(cells, rows, cols, self);
    }

    fn closeOpen(self: *Timeline, st: ?*Store, excludes: []const []const u8, max_bytes: u64) !?u64 {
        if (self.entries.items.len == 0) return null;
        const entry = &self.entries.items[self.entries.items.len - 1];
        if (entry.finished) return null;
        return self.finishEntry(entry, st, null, excludes, max_bytes);
    }

    fn finishEntry(self: *Timeline, entry: *Entry, st: ?*Store, exit_code: ?i32, excludes: []const []const u8, max_bytes: u64) !?u64 {
        entry.finished = true;
        entry.exit_code = exit_code;
        if (entry.snap_id.len == 0 or st == null) return entry.id;
        var before = st.?.load(entry.snap_id) catch return entry.id;
        defer before.deinit(self.a);
        var after = st.?.scan(entry.cwd, .{
            .max_bytes = max_bytes,
            .excludes = excludes,
            .prior = before.files.items,
        }) catch return entry.id;
        defer after.deinit(self.a);
        if (after.skip != null) {
            try self.replace(&entry.skip, "diff skipped");
            return entry.id;
        }
        var delta = try store_mod.diffRecs(self.a, before.files.items, after.files.items);
        defer delta.deinit(self.a);
        entry.added_total = delta.added.items.len;
        entry.removed_total = delta.removed.items.len;
        entry.modified_total = delta.modified.items.len;
        try takeNames(self.a, delta.added.items, &entry.added);
        try takeNames(self.a, delta.removed.items, &entry.removed);
        try takeNames(self.a, delta.modified.items, &entry.modified);
        return entry.id;
    }

    fn blank(self: *Timeline, id: u64, command: []const u8, cwd: []const u8, now_ms: i64) !Entry {
        const cmd = command[0..@min(command.len, 240)];
        const command_s = try self.a.dupe(u8, cmd);
        errdefer self.a.free(command_s);
        const cwd_s = try self.a.dupe(u8, cwd);
        errdefer self.a.free(cwd_s);
        const snap_id = try self.a.dupe(u8, "");
        errdefer self.a.free(snap_id);
        const skip = try self.a.dupe(u8, "");
        errdefer self.a.free(skip);
        const summary = try self.a.dupe(u8, "");
        return .{
            .id = id,
            .command = command_s,
            .cwd = cwd_s,
            .when_ms = now_ms,
            .snap_id = snap_id,
            .skip = skip,
            .added = std.ArrayList([]u8).init(self.a),
            .removed = std.ArrayList([]u8).init(self.a),
            .modified = std.ArrayList([]u8).init(self.a),
            .summary = summary,
        };
    }

    fn replace(self: *Timeline, slot: *[]u8, text: []const u8) !void {
        const next = try self.a.dupe(u8, text);
        self.a.free(slot.*);
        slot.* = next;
    }

    fn keepUndo(self: *Timeline, snap: *store_mod.Snapshot) !void {
        defer snap.deinit(self.a);
        const id = try self.a.dupe(u8, snap.id);
        errdefer self.a.free(id);
        const cwd = try self.a.dupe(u8, snap.cwd);
        self.a.free(self.undo_id);
        self.a.free(self.undo_cwd);
        self.undo_id = id;
        self.undo_cwd = cwd;
    }

    fn move(self: *Timeline, delta: i32) void {
        if (self.entries.items.len == 0) return;
        const last: i32 = @intCast(self.entries.items.len - 1);
        const cur: i32 = @intCast(self.selected);
        const sum = cur + delta;
        const next = if (sum < 0) 0 else if (sum > last) last else sum;
        self.selected = @intCast(next);
        self.confirm = false;
    }

    fn window(self: *const Timeline, rows: u16) usize {
        const n = self.entries.items.len;
        if (n == 0 or rows == 0) return 0;
        if (n <= rows) return 0;
        if (self.selected + 1 > rows) return self.selected + 1 - rows;
        return 0;
    }

    pub fn setNote(self: *Timeline, text: []const u8) void {
        const n = self.a.dupe(u8, text[0..@min(text.len, 160)]) catch return;
        self.a.free(self.note);
        self.note = n;
    }

    fn clearNote(self: *Timeline) void {
        if (self.note.len == 0) return;
        self.setNote("");
    }
};

fn takeNames(a: std.mem.Allocator, src: []const []u8, dst: *std.ArrayList([]u8)) !void {
    const n = @min(src.len, max_names);
    for (src[0..n]) |s| try dst.append(try a.dupe(u8, s));
}

fn explain(err: anyerror) []const u8 {
    return switch (err) {
        error.PathMismatch => "folder moved; not rewinding",
        error.NotSaved => "no snapshot",
        error.UnsafePath => "unsafe path",
        else => "rewind failed",
    };
}

const bg = 0x101010;
const fg = 0xE8E4D9;
const dim = 0x8A8478;
const accent = 0xAF1F1F;
const hi = 0x242018;

pub fn drawEmpty(cells: []Cell, rows: u16, cols: u16) void {
    fill(cells, rows, cols);
    _ = blit(cells, cols, 0, 1, "TIME TRAVEL", 0xFFFFFF, accent);
    _ = blit(cells, cols, 2, 2, "no commands in this session yet", dim, bg);
    footer(cells, rows, cols, "esc close", false);
}

fn paintOverlay(cells: []Cell, rows: u16, cols: u16, tl: *const Timeline) void {
    fill(cells, rows, cols);
    var hc: u16 = 0;
    while (hc < cols) : (hc += 1) paint(cells, cols, 0, hc, ' ', 0xFFFFFF, accent);
    var head: [64]u8 = undefined;
    const head_s = std.fmt.bufPrint(&head, "TIME TRAVEL  {d}", .{tl.entries.items.len}) catch "TIME TRAVEL";
    _ = blit(cells, cols, 0, 1, head_s, 0xFFFFFF, accent);
    const cwd = if (tl.entries.items.len > 0) tl.entries.items[tl.selected].cwd else "";
    _ = blit(cells, cols, 1, 1, if (cwd.len > 0) cwd else "(no directory)", dim, bg);
    if (rows < 4) return;
    const top: u16 = 2;
    const bot = rows - 2;
    const start = tl.window(bot - top);
    var row = top;
    var i = start;
    while (row < bot and i < tl.entries.items.len) {
        const entry = tl.entries.items[i];
        const on = i == tl.selected;
        const row_bg: u32 = if (on) hi else bg;
        const row_fg: u32 = if (on) fg else dim;
        var line: [512]u8 = undefined;
        const text = entryLine(&line, entry) catch continue;
        _ = blit(cells, cols, row, 1, text, row_fg, row_bg);
        row += 1;
        i += 1;
    }
    if (tl.entries.items.len > 0 and rows > 2) {
        detail(cells, cols, rows - 2, &tl.entries.items[tl.selected]);
    }
    if (tl.confirm) {
        footer(cells, rows, cols, "rewind this folder to before this command?  y rewind   n cancel", true);
    } else if (tl.note.len > 0) {
        footer(cells, rows, cols, tl.note, false);
    } else {
        footer(cells, rows, cols, "up/down scrub   enter rewind   u undo   esc close", false);
    }
}

fn entryLine(buf: []u8, entry: Entry) ![]const u8 {
    var clock: [8]u8 = undefined;
    const clk = fmtClock(&clock, entry.when_ms);
    if (entry.snap_id.len == 0) {
        const why = if (entry.skip.len > 0) entry.skip else "no snapshot";
        return std.fmt.bufPrint(buf, "{s}  {s}  ({s})", .{ clk, entry.command, why });
    }
    const sum = if (entry.summary.len > 0) entry.summary else "";
    return std.fmt.bufPrint(buf, "{s}  {s}  +{d} ~{d} -{d}  {s}", .{
        clk, entry.command, entry.added_total, entry.modified_total, entry.removed_total, sum,
    });
}

fn detail(cells: []Cell, cols: u16, row: u16, entry: *const Entry) void {
    var buf: [480]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const w = stream.writer();
    w.print("+{d} ", .{entry.added_total}) catch {};
    writeSome(w, entry.added.items);
    w.print("  ~{d} ", .{entry.modified_total}) catch {};
    writeSome(w, entry.modified.items);
    w.print("  -{d} ", .{entry.removed_total}) catch {};
    writeSome(w, entry.removed.items);
    if (entry.exit_code) |code| w.print("  exit {d}", .{code}) catch {};
    _ = blit(cells, cols, row, 1, stream.getWritten(), fg, bg);
}

fn writeSome(w: anytype, names: []const []u8) void {
    const n = @min(names.len, show_names);
    if (n == 0) {
        w.writeAll("-") catch {};
        return;
    }
    for (names[0..n], 0..) |name, i| {
        if (i > 0) w.writeAll(" ") catch {};
        w.writeAll(name) catch {};
    }
    if (names.len > n) w.print(" +{d}", .{names.len - n}) catch {};
}

fn fmtClock(buf: *[8]u8, ms: i64) []const u8 {
    var secs = @divFloor(ms, 1000);
    secs = @mod(secs, 86_400);
    if (secs < 0) secs += 86_400;
    const h = @divFloor(secs, 3600);
    const m = @divFloor(@mod(secs, 3600), 60);
    const s = @mod(secs, 60);
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ h, m, s }) catch "00:00:00";
}

fn footer(cells: []Cell, rows: u16, cols: u16, text: []const u8, hot: bool) void {
    if (rows == 0) return;
    const row = rows - 1;
    const row_bg: u32 = if (hot) accent else 0x181818;
    const row_fg: u32 = if (hot) 0xFFFFFF else dim;
    var c: u16 = 0;
    while (c < cols) : (c += 1) paint(cells, cols, row, c, ' ', row_fg, row_bg);
    _ = blit(cells, cols, row, 1, text, row_fg, row_bg);
}

fn fill(cells: []Cell, rows: u16, cols: u16) void {
    const n = @min(cells.len, @as(usize, rows) * cols);
    for (cells[0..n]) |*cell| {
        cell.* = Cell.init();
        cell.fg_color = fg;
        cell.bg_color = bg;
    }
}

fn blit(cells: []Cell, cols: u16, row: u16, col: u16, text: []const u8, ink: u32, paper: u32) u16 {
    var c = col;
    for (text) |ch| {
        if (c >= cols) break;
        const glyph: u21 = if (ch < 0x20 or ch > 0x7e) '?' else ch;
        paint(cells, cols, row, c, glyph, ink, paper);
        c += 1;
    }
    return c;
}

fn paint(cells: []Cell, cols: u16, row: u16, col: u16, ch: u21, ink: u32, paper: u32) void {
    const i = @as(usize, row) * cols + col;
    if (i >= cells.len) return;
    cells[i] = Cell.init();
    cells[i].char = ch;
    cells[i].fg_color = ink;
    cells[i].bg_color = paper;
}

test "rewind restores the tree and undo puts the edit back" {
    const a = std.testing.allocator;
    var parent = std.testing.tmpDir(.{});
    defer parent.cleanup();
    try parent.dir.makeDir("work");
    try parent.dir.writeFile(.{ .sub_path = "work/a.txt", .data = "hello" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try parent.dir.realpath(".", &root_buf);
    var work_buf: [std.fs.max_path_bytes]u8 = undefined;
    var store_buf: [std.fs.max_path_bytes]u8 = undefined;
    const work = try std.fmt.bufPrint(&work_buf, "{s}/work", .{root});
    const store_path = try std.fmt.bufPrint(&store_buf, "{s}/store", .{root});
    var st = try Store.open(a, store_path);
    defer st.deinit();
    var tl = try Timeline.init(a);
    defer tl.deinit();

    _ = try tl.begin(&st, 1, .{ .max_bytes = 1024 * 1024, .cwd = work, .command = "echo hi", .now_ms = 1_700_000_000_000 });
    try parent.dir.writeFile(.{ .sub_path = "work/a.txt", .data = "changed" });
    try parent.dir.writeFile(.{ .sub_path = "work/c.txt", .data = "new" });
    _ = try tl.finish(&st, 0, &.{}, 1024 * 1024);
    try std.testing.expect(tl.entries.items[0].modified_total == 1);
    try std.testing.expect(tl.entries.items[0].added_total == 1);

    tl.confirm = true;
    try tl.rewind(&st, &.{}, 1024 * 1024);
    const now = try parent.dir.readFileAlloc(a, "work/a.txt", 64);
    defer a.free(now);
    try std.testing.expectEqualStrings("hello", now);
    try std.testing.expectError(error.FileNotFound, parent.dir.statFile("work/c.txt"));

    try tl.undo(&st, &.{});
    const back = try parent.dir.readFileAlloc(a, "work/a.txt", 64);
    defer a.free(back);
    try std.testing.expectEqualStrings("changed", back);
    _ = try parent.dir.statFile("work/c.txt");
}

test "rewind refuses a tree that cannot be undone" {
    const a = std.testing.allocator;
    var parent = std.testing.tmpDir(.{});
    defer parent.cleanup();
    try parent.dir.makeDir("work");
    try parent.dir.writeFile(.{ .sub_path = "work/a.txt", .data = "hello" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try parent.dir.realpath(".", &root_buf);
    var work_buf: [std.fs.max_path_bytes]u8 = undefined;
    var store_buf: [std.fs.max_path_bytes]u8 = undefined;
    const work = try std.fmt.bufPrint(&work_buf, "{s}/work", .{root});
    const store_path = try std.fmt.bufPrint(&store_buf, "{s}/store", .{root});
    var st = try Store.open(a, store_path);
    defer st.deinit();
    var tl = try Timeline.init(a);
    defer tl.deinit();
    _ = try tl.begin(&st, 1, .{ .max_bytes = 1024, .cwd = work, .command = "grow" });
    try parent.dir.writeFile(.{ .sub_path = "work/a.txt", .data = "0123456789abcdef" });
    _ = try tl.finish(&st, 0, &.{}, 1024);
    try tl.rewind(&st, &.{}, 8);
    try std.testing.expect(std.mem.indexOf(u8, tl.note, "max_dir_mb") != null);
    const body = try parent.dir.readFileAlloc(a, "work/a.txt", 64);
    defer a.free(body);
    try std.testing.expectEqualStrings("0123456789abcdef", body);
}

test "a running command is not rewound" {
    const a = std.testing.allocator;
    var parent = std.testing.tmpDir(.{});
    defer parent.cleanup();
    try parent.dir.makeDir("work");
    try parent.dir.writeFile(.{ .sub_path = "work/a.txt", .data = "hello" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try parent.dir.realpath(".", &root_buf);
    var work_buf: [std.fs.max_path_bytes]u8 = undefined;
    var store_buf: [std.fs.max_path_bytes]u8 = undefined;
    const work = try std.fmt.bufPrint(&work_buf, "{s}/work", .{root});
    const store_path = try std.fmt.bufPrint(&store_buf, "{s}/store", .{root});
    var st = try Store.open(a, store_path);
    defer st.deinit();
    var tl = try Timeline.init(a);
    defer tl.deinit();
    _ = try tl.begin(&st, 1, .{ .max_bytes = 1024, .cwd = work, .command = "sleep" });
    try tl.rewind(&st, &.{}, 1024);
    try std.testing.expectEqualStrings("command still running", tl.note);
}

test "disabled and relative paths do not snapshot" {
    const a = std.testing.allocator;
    var parent = std.testing.tmpDir(.{});
    defer parent.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try parent.dir.realpath(".", &root_buf);
    var store_buf: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try std.fmt.bufPrint(&store_buf, "{s}/store", .{root});
    var st = try Store.open(a, store_path);
    defer st.deinit();
    var tl = try Timeline.init(a);
    defer tl.deinit();
    _ = try tl.begin(&st, 1, .{ .enabled = false, .max_bytes = 100, .cwd = root, .command = "true" });
    _ = try tl.begin(&st, 2, .{ .max_bytes = 100, .cwd = "relative", .command = "true" });
    try std.testing.expectEqualStrings("disabled", tl.entries.items[0].skip);
    try std.testing.expectEqualStrings("relative", tl.entries.items[1].skip);
    try std.testing.expect(tl.entries.items[0].finished);
    var objects = try st.root.openDir("objects", .{ .iterate = true });
    defer objects.close();
    var it = objects.iterate();
    try std.testing.expect((try it.next()) == null);
}

test "overlay paints the timeline" {
    const a = std.testing.allocator;
    var tl = try Timeline.init(a);
    defer tl.deinit();
    _ = try tl.begin(null, 7, .{ .enabled = false, .max_bytes = 1, .cwd = "/tmp/work", .command = "make", .now_ms = 0 });
    _ = try tl.finish(null, 0, &.{}, 1);
    const cells = try a.alloc(Cell, 10 * 60);
    defer a.free(cells);
    tl.draw(cells, 10, 60);
    try std.testing.expectEqual(@as(u21, 'T'), cells[1].char);
    try std.testing.expectEqual(@as(u21, 'I'), cells[2].char);
    try std.testing.expect(cells[0].bg_color == accent);
}
