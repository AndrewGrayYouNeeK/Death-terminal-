//! The filterable palette overlay, in two modes:
//!  * `.commands` (Ctrl+Shift+P): built-in actions and plugin commands;
//!  * `.ssh` (Ctrl+Shift+S): this session's port forwards (toggle),
//!    "Reconnect", and SSH profiles / Host aliases (open in a new window).
//! The event loop fills the items; picks come back as `Pick`s.

const std = @import("std");
const terminal = @import("../terminal/terminal.zig");
const input = @import("../terminal/input.zig");
const unicode = @import("../terminal/unicode.zig");
const Cell = terminal.Cell;

pub const Item = struct {
    kind: Kind,
    /// Profile / alias name, or the forward's spec ("L 8080:localhost:80").
    name: []u8,
    /// Grey text after the name (owned).
    detail: []u8,
    /// Forward number for the control socket (1-based), the action's enum
    /// value, or the plugin command's index.
    arg: usize = 0,
    on: bool = false,

    pub const Kind = enum { forward, reconnect, profile, alias, action, command };
};

pub const Mode = enum { ssh, commands };

pub const Pick = union(enum) {
    /// Open this profile / alias in a new window (owned).
    open: []u8,
    toggle: usize,
    reconnect,
    /// A built-in action (`events.Action` value).
    action: usize,
    /// A plugin command (index into the host's command list).
    command: usize,
};

pub const Result = union(enum) { none, close, pick: Pick };

pub const Palette = struct {
    allocator: std.mem.Allocator,
    mode: Mode,
    items: std.ArrayList(Item),
    query: std.ArrayList(u8),
    /// Index into the filtered list.
    sel: usize = 0,
    scroll: usize = 0,
    /// Shown in the frame ("SSH: andrew@host" / "SSH profiles"), owned.
    title: []u8,
    /// Shown under the list (e.g. the result of a toggle), owned.
    status: []u8,

    pub fn init(allocator: std.mem.Allocator, mode: Mode, title: []const u8) !Palette {
        return .{
            .allocator = allocator,
            .mode = mode,
            .items = std.ArrayList(Item).init(allocator),
            .query = std.ArrayList(u8).init(allocator),
            .title = try allocator.dupe(u8, title),
            .status = try allocator.dupe(u8, ""),
        };
    }

    pub fn deinit(self: *Palette) void {
        self.clearItems();
        self.items.deinit();
        self.query.deinit();
        self.allocator.free(self.title);
        self.allocator.free(self.status);
    }

    fn clearItems(self: *Palette) void {
        for (self.items.items) |it| {
            self.allocator.free(it.name);
            self.allocator.free(it.detail);
        }
        self.items.clearRetainingCapacity();
    }

    /// Replaces the list (keeps the filter and, where possible, the selection).
    pub fn setItems(self: *Palette, items: []const Item) !void {
        self.clearItems();
        for (items) |it| {
            const name = try self.allocator.dupe(u8, it.name);
            errdefer self.allocator.free(name);
            try self.items.append(.{ .kind = it.kind, .name = name, .detail = try self.allocator.dupe(u8, it.detail), .arg = it.arg, .on = it.on });
        }
        self.clamp();
    }

    pub fn addItem(self: *Palette, kind: Item.Kind, name: []const u8, detail: []const u8, arg: usize, on: bool) !void {
        const n = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(n);
        try self.items.append(.{ .kind = kind, .name = n, .detail = try self.allocator.dupe(u8, detail), .arg = arg, .on = on });
        self.clamp();
    }

    pub fn setStatus(self: *Palette, text: []const u8) !void {
        const s = try self.allocator.dupe(u8, text);
        self.allocator.free(self.status);
        self.status = s;
    }

    /// Case-insensitive subsequence match on "name detail".
    fn matches(self: *const Palette, it: Item) bool {
        const q = self.query.items;
        if (q.len == 0) return true;
        var qi: usize = 0;
        for ([_][]const u8{ it.name, " ", it.detail }) |part| for (part) |ch| {
            if (qi < q.len and std.ascii.toLower(ch) == std.ascii.toLower(q[qi])) qi += 1;
        };
        return qi == q.len;
    }

    pub fn visibleCount(self: *const Palette) usize {
        var n: usize = 0;
        for (self.items.items) |it| n += @intFromBool(self.matches(it));
        return n;
    }

    /// The `k`-th item passing the filter.
    pub fn visible(self: *const Palette, k: usize) ?*const Item {
        var n: usize = 0;
        for (self.items.items) |*it| if (self.matches(it.*)) {
            if (n == k) return it;
            n += 1;
        };
        return null;
    }

    fn clamp(self: *Palette) void {
        const n = self.visibleCount();
        if (n == 0) self.sel = 0 else if (self.sel >= n) self.sel = n - 1;
    }

    fn move(self: *Palette, delta: i64) void {
        const n = self.visibleCount();
        if (n == 0) return;
        const cur: i64 = @intCast(self.sel);
        self.sel = @intCast(@mod(cur + delta, @as(i64, @intCast(n))));
    }

    fn pick(self: *Palette) !Result {
        const it = self.visible(self.sel) orelse return .none;
        return switch (it.kind) {
            .forward => .{ .pick = .{ .toggle = it.arg } },
            .action => .{ .pick = .{ .action = it.arg } },
            .command => .{ .pick = .{ .command = it.arg } },
            .reconnect => .{ .pick = .reconnect },
            .profile, .alias => .{ .pick = .{ .open = try self.allocator.dupe(u8, it.name) } },
        };
    }

    pub fn handleText(self: *Palette, bytes: []const u8) !Result {
        if (bytes.len == 1) switch (bytes[0]) {
            '\r', '\n' => return self.pick(),
            0x03, 0x07, 0x1b => return .close,
            0x7f, 0x08 => {
                deleteLast(&self.query);
                self.clamp();
                return .none;
            },
            0x15 => {
                self.query.clearRetainingCapacity();
                self.clamp();
                return .none;
            },
            0x0e => {
                self.move(1);
                return .none;
            },
            0x10 => {
                self.move(-1);
                return .none;
            },
            else => {},
        };
        for (bytes) |b| if (b < 0x20) return .none;
        if (self.query.items.len + bytes.len > 128) return .none;
        try self.query.appendSlice(bytes);
        self.sel = 0;
        self.clamp();
        return .none;
    }

    pub fn handleKey(self: *Palette, key: input.Key) !Result {
        switch (key) {
            .escape => return .close,
            .enter, .kp_enter => return self.pick(),
            .up => self.move(-1),
            .down, .tab => self.move(1),
            .page_up => self.move(-8),
            .page_down => self.move(8),
            .home => self.sel = 0,
            .end => self.sel = self.visibleCount() -| 1,
            .backspace => {
                deleteLast(&self.query);
                self.clamp();
            },
            else => {},
        }
        return .none;
    }

    // ------------------------------------------------------------ drawing

    const bg: u32 = 0x161616;
    const fg: u32 = 0xE0E0E0;
    const frame_fg: u32 = 0x9A9A9A;
    const dim_fg: u32 = 0x8A8A8A;
    const sel_bg: u32 = 0xD0D0D0;
    const sel_fg: u32 = 0x101010;
    const on_fg: u32 = 0x5FD75F;
    const accent: u32 = 0xFF5F5F;

    /// Draws a centred box over `cells` (rows × cols).
    pub fn draw(self: *Palette, cells: []Cell, rows: u16, cols: u16) void {
        if (rows < 5 or cols < 24) return;
        const w: usize = @min(@as(usize, cols) - 2, 84);
        const n = self.visibleCount();
        const list_rows: usize = @max(@min(n, @as(usize, rows) -| 7), 1);
        const h: usize = list_rows + 5;
        const x0: usize = (cols - w) / 2;
        const y0: usize = @max((@as(usize, rows) -| h) / 3, 0);
        if (self.sel < self.scroll) self.scroll = self.sel;
        if (self.sel >= self.scroll + list_rows) self.scroll = self.sel + 1 - list_rows;

        var y: usize = 0;
        while (y < h) : (y += 1) {
            const row = cells[(y0 + y) * cols ..][0..cols];
            const box = row[x0 .. x0 + w];
            fill(box, ' ', fg, bg);
            box[0].char = '│';
            box[w - 1].char = '│';
            box[0].fg_color = frame_fg;
            box[w - 1].fg_color = frame_fg;
        }
        // Frame.
        const top = cells[y0 * cols ..][x0 .. x0 + w];
        hline(top, '┌', '─', '┐');
        var tb: [160]u8 = undefined;
        const head: []const u8 = switch (self.mode) {
            .ssh => "SSH",
            .commands => "Commands",
        };
        const ttl = std.fmt.bufPrint(&tb, " {s}  {s} ", .{ head, self.title }) catch " ";
        _ = put(top[2..], ttl, accent, bg);
        const sep = cells[(y0 + 2) * cols ..][x0 .. x0 + w];
        hline(sep, '├', '─', '┤');
        const bottom = cells[(y0 + h - 1) * cols ..][x0 .. x0 + w];
        hline(bottom, '└', '─', '┘');
        _ = put(bottom[2..], switch (self.mode) {
            .ssh => " Enter open/toggle  ↑↓ move  type to filter  Esc close ",
            .commands => " Enter run  ↑↓ move  type to filter  Esc close ",
        }, dim_fg, bg);

        // Query line.
        const ql = cells[(y0 + 1) * cols ..][x0 + 2 .. x0 + w - 1];
        var qb: [200]u8 = undefined;
        const qt = std.fmt.bufPrint(&qb, "› {s}\u{2588}", .{self.query.items}) catch "› ";
        _ = put(ql, qt, fg, bg);

        // Items.
        var k: usize = 0;
        while (k < list_rows) : (k += 1) {
            const idx = self.scroll + k;
            const line = cells[(y0 + 3 + k) * cols ..][x0 + 1 .. x0 + w - 1];
            const it = self.visible(idx) orelse {
                if (k == 0 and n == 0) _ = put(line[2..], if (self.items.items.len > 0) "no match" else switch (self.mode) {
                    .ssh => "no SSH profiles: add config.ssh.profiles or Host entries in ~/.ssh/config",
                    .commands => "no commands",
                }, dim_fg, bg);
                continue;
            };
            const selected = idx == self.sel;
            const lfg: u32 = if (selected) sel_fg else fg;
            const lbg: u32 = if (selected) sel_bg else bg;
            fill(line, ' ', lfg, lbg);
            var col: usize = 1;
            switch (it.kind) {
                .forward => {
                    col += put(line[col..], if (it.on) "[on]  " else "[off] ", if (selected) sel_fg else if (it.on) on_fg else dim_fg, lbg);
                },
                .reconnect => col += put(line[col..], "⟳ ", lfg, lbg),
                .profile => col += put(line[col..], "▸ ", lfg, lbg),
                .alias => col += put(line[col..], "· ", lfg, lbg),
                .action => col += put(line[col..], "› ", lfg, lbg),
                .command => col += put(line[col..], "◆ ", if (selected) sel_fg else accent, lbg),
            }
            col += put(line[col..], it.name, lfg, lbg);
            col += 2;
            const dfg: u32 = if (selected) 0x404040 else dim_fg;
            if (self.mode == .commands) {
                // Commands: chord / plugin name right-aligned.
                const dw = textWidth(it.detail);
                if (dw + 1 < line.len and col + dw + 1 <= line.len) {
                    _ = put(line[line.len - dw - 1 ..], it.detail, dfg, lbg);
                } else if (col < line.len) _ = put(line[col..], it.detail, dfg, lbg);
            } else if (col < line.len) _ = put(line[col..], it.detail, dfg, lbg);
        }
        // Status in the separator.
        if (self.status.len > 0) _ = put(sep[2..], self.status, on_fg, bg);
    }
};

fn fill(cells: []Cell, ch: u21, f: u32, b: u32) void {
    var c = Cell.init();
    c.char = ch;
    c.fg_color = f;
    c.bg_color = b;
    @memset(cells, c);
}

fn hline(cells: []Cell, l: u21, m: u21, r: u21) void {
    for (cells) |*c| c.char = m;
    cells[0].char = l;
    cells[cells.len - 1].char = r;
    for (cells) |*c| c.fg_color = Palette.frame_fg;
}

/// Writes `text` from the left of `cells` (clipped); returns columns used.
fn put(cells: []Cell, text: []const u8, f: u32, b: u32) usize {
    var col: usize = 0;
    var it = (std.unicode.Utf8View.init(text) catch return 0).iterator();
    while (it.nextCodepoint()) |cp| {
        const w = unicode.width(cp);
        if (w == 0) continue;
        if (col + w > cells.len) break;
        cells[col].char = cp;
        cells[col].width = @intCast(w);
        cells[col].fg_color = f;
        cells[col].bg_color = b;
        if (w == 2) {
            cells[col + 1].width = 0;
            cells[col + 1].bg_color = b;
        }
        col += w;
    }
    return col;
}

fn textWidth(text: []const u8) usize {
    var n: usize = 0;
    var it = (std.unicode.Utf8View.init(text) catch return text.len).iterator();
    while (it.nextCodepoint()) |cp| n += unicode.width(cp);
    return n;
}

fn deleteLast(buf: *std.ArrayList(u8)) void {
    var n = buf.items.len;
    if (n == 0) return;
    n -= 1;
    while (n > 0 and buf.items[n] & 0xC0 == 0x80) n -= 1;
    buf.items.len = n;
}

// ------------------------------------------------------------------- tests

const t = std.testing;

test "palette filters, moves and picks" {
    var p = try Palette.init(t.allocator, .ssh, "andrew@box");
    defer p.deinit();
    try p.addItem(.forward, "L 8080:localhost:80", "listening on 127.0.0.1:8080", 1, true);
    try p.addItem(.reconnect, "Reconnect", "andrew@box", 0, false);
    try p.addItem(.profile, "prod", "andrew@prod.example.com", 0, false);
    try p.addItem(.alias, "bastion", "~/.ssh/config", 0, false);
    try t.expectEqual(@as(usize, 4), p.visibleCount());
    _ = try p.handleText("pr");
    try t.expectEqual(@as(usize, 1), p.visibleCount());
    const r = try p.handleText("\r");
    try t.expectEqualStrings("prod", r.pick.open);
    t.allocator.free(r.pick.open);
    _ = try p.handleText("\x15");
    try t.expectEqual(@as(usize, 4), p.visibleCount());
    try t.expect((try p.handleKey(.enter)).pick.toggle == 1);
    _ = try p.handleKey(.down);
    try t.expect((try p.handleKey(.enter)).pick == .reconnect);
    _ = try p.handleKey(.up);
    _ = try p.handleKey(.up);
    try t.expectEqual(@as(usize, 3), p.sel); // wraps
    try t.expect(try p.handleKey(.escape) == .close);
    _ = try p.handleText("zzz");
    try t.expectEqual(@as(usize, 0), p.visibleCount());
    try t.expect(try p.handleKey(.enter) == .none);
}

test "palette draws inside small and large grids" {
    var p = try Palette.init(t.allocator, .ssh, "x");
    defer p.deinit();
    var i: usize = 0;
    while (i < 40) : (i += 1) try p.addItem(if (i % 2 == 0) .profile else .command, "host-with-a-long-name", "detail detail detail detail detail detail detail detail", 0, false);
    p.sel = 39;
    for (0..2) |m| {
        p.mode = if (m == 0) .ssh else .commands;
        for ([_][2]u16{ .{ 4, 20 }, .{ 6, 24 }, .{ 24, 80 }, .{ 10, 200 } }) |d| {
            const cells = try t.allocator.alloc(Cell, @as(usize, d[0]) * d[1]);
            defer t.allocator.free(cells);
            @memset(cells, Cell.init());
            p.draw(cells, d[0], d[1]);
        }
    }
    try t.expect(p.scroll > 0);
}

test "command palette picks actions and plugin commands" {
    var p = try Palette.init(t.allocator, .commands, "");
    defer p.deinit();
    try p.addItem(.action, "Copy selection", "Ctrl+Shift+C", 1, false);
    try p.addItem(.command, "Git: show branch", "git_branch", 3, false);
    _ = try p.handleText("git");
    try t.expectEqual(@as(usize, 3), (try p.handleText("\r")).pick.command);
    _ = try p.handleText("\x15");
    try t.expectEqual(@as(usize, 1), (try p.handleKey(.enter)).pick.action);
    const cells = try t.allocator.alloc(Cell, 24 * 80);
    defer t.allocator.free(cells);
    @memset(cells, Cell.init());
    p.draw(cells, 24, 80);
}
