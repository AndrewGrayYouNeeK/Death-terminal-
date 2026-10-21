//! Window-side Shared Haunting. Owns at most one host or one guest.
//!
//! The host snapshots a single pane (`pane`) and never reads another. Guest
//! keystrokes are forwarded only after the host grants control. The banner
//! and the guest cursor are painted onto the composed frame, not into the
//! terminal grid, so they are not part of the bytes sent to the guest.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config/config.zig");
const frame_mod = @import("../renderer/frame.zig");
const input = @import("../terminal/input.zig");
const io = @import("../platform/io.zig");
const terminal = @import("../terminal/terminal.zig");
const invite = @import("../share/invite.zig");
const msg = @import("../share/msg.zig");
const session = @import("../share/session.zig");

const Cell = terminal.Cell;
const Mark = frame_mod.Mark;

const BarPaint = struct { fg: u32, bg: u32 };
const paint_watched: BarPaint = .{ .fg = 0x000000, .bg = 0xFF0033 };
const paint_reading: BarPaint = .{ .fg = 0x000000, .bg = 0xFFB000 };
const paint_waiting: BarPaint = .{ .fg = 0xFFB000, .bg = 0x1A0000 };

pub const KeyResult = enum { ignore, consumed, send };

pub const PromptAction = enum { idle, stay, cancel, join };

pub const Controller = struct {
    a: std.mem.Allocator,
    enabled: bool = true,
    bind_ip: [64]u8 = undefined,
    bind_len: usize = 0,
    advertise: [invite.max_host]u8 = undefined,
    advertise_len: usize = 0,
    relay: [invite.max_relay]u8 = undefined,
    relay_len: usize = 0,
    port: u16 = 0,

    host: ?*session.Host = null,
    guest: ?*session.Guest = null,
    pane: u32 = 0,
    bound: bool = false,

    row: u16 = 0,
    col: u16 = 0,
    sel: bool = false,
    anchor_r: u16 = 0,
    anchor_c: u16 = 0,
    dragging: bool = false,

    prompt: ?std.ArrayList(u8) = null,
    pending: [480]u8 = undefined,
    pending_len: usize = 0,
    announce: ?[]u8 = null,
    announce_pending: bool = false,
    err: [160]u8 = undefined,
    err_len: usize = 0,
    err_pending: bool = false,
    banner: [180]u8 = undefined,
    banner_len: usize = 0,
    fp: []u64 = &.{},
    fp_rows: u16 = 0,
    fp_cols: u16 = 0,
    saw_cursor: bool = false,
    last_cr: u16 = 0,
    last_cc: u16 = 0,
    last_on: bool = false,
    saw_kick: bool = false,

    pub fn init(a: std.mem.Allocator) Controller {
        var c = Controller{ .a = a };
        c.setBind("0.0.0.0");
        return c;
    }

    pub fn deinit(self: *Controller) void {
        self.stop();
        if (self.prompt) |*p| p.deinit();
        self.a.free(self.fp);
    }

    pub fn configure(self: *Controller, cfg: *const config.Config) void {
        self.enabled = cfg.share_enabled;
        self.port = cfg.share_port;
        self.setBind(if (cfg.share_bind.len == 0) "0.0.0.0" else cfg.share_bind);
        self.advertise_len = @min(cfg.share_advertise.len, self.advertise.len);
        @memcpy(self.advertise[0..self.advertise_len], cfg.share_advertise[0..self.advertise_len]);
        self.relay_len = @min(cfg.share_relay.len, self.relay.len);
        @memcpy(self.relay[0..self.relay_len], cfg.share_relay[0..self.relay_len]);
    }

    fn setBind(self: *Controller, ip: []const u8) void {
        self.bind_len = @min(ip.len, self.bind_ip.len);
        @memcpy(self.bind_ip[0..self.bind_len], ip[0..self.bind_len]);
    }

    pub fn active(self: *const Controller) bool {
        return self.host != null or self.guest != null or self.prompt != null;
    }

    pub fn isGuest(self: *const Controller) bool {
        return self.guest != null;
    }

    pub fn claims(self: *const Controller, id: u32) bool {
        return self.bound and self.pane == id and (self.host != null or self.guest != null);
    }

    pub fn access(self: *const Controller) session.Access {
        if (self.guest) |g| return g.access;
        if (self.host) |h| return h.access;
        return .read_only;
    }

    pub fn startHost(self: *Controller, pane: u32) void {
        if (!self.enabled) {
            self.setErr("sharing is disabled in config");
            return;
        }
        self.stop();
        var detected: [64]u8 = undefined;
        const adv: []const u8 = if (self.advertise_len > 0)
            self.advertise[0..self.advertise_len]
        else
            invite.detectLanHost(&detected);
        const host = session.Host.listen(
            self.a,
            self.bind_ip[0..self.bind_len],
            self.port,
            adv,
            self.relay[0..self.relay_len],
            null,
        ) catch |err| {
            self.setErr(@errorName(err));
            return;
        };
        self.host = host;
        self.pane = pane;
        self.bound = true;
        self.announce = self.a.dupe(u8, host.code) catch null;
        self.announce_pending = self.announce != null;
        self.saw_cursor = false;
        self.a.free(self.fp);
        self.fp = &.{};
        self.fp_rows = 0;
        self.fp_cols = 0;
        self.rebuildBanner();
        std.debug.print("Shared Haunting\n  deathterminal --join {s}\n", .{host.code});
    }

    pub fn join(self: *Controller, pane: u32) void {
        if (self.pending_len == 0) {
            self.setErr("empty invite code");
            return;
        }
        self.stop();
        const guest = session.Guest.start(self.a, self.pending[0..self.pending_len]) catch |err| {
            self.setErr(@errorName(err));
            return;
        };
        self.guest = guest;
        self.pane = pane;
        self.bound = true;
        self.row = 0;
        self.col = 0;
        self.sel = false;
        self.saw_kick = false;
        self.rebuildBanner();
    }

    pub fn joinCode(self: *Controller, pane: u32, code: []const u8) void {
        self.pending_len = @min(code.len, self.pending.len);
        @memcpy(self.pending[0..self.pending_len], code[0..self.pending_len]);
        self.join(pane);
    }

    pub fn stop(self: *Controller) void {
        if (self.host) |h| h.deinit();
        if (self.guest) |g| g.deinit();
        self.host = null;
        self.guest = null;
        self.bound = false;
        if (self.announce) |s| self.a.free(s);
        self.announce = null;
        self.announce_pending = false;
        self.banner_len = 0;
        self.a.free(self.fp);
        self.fp = &.{};
        self.fp_rows = 0;
        self.fp_cols = 0;
    }

    /// F12: kick the guest, or stop sharing if nobody is connected.
    pub fn kickOrStop(self: *Controller) void {
        if (self.host) |h| {
            if (h.phase == .open) {
                h.kick();
                self.rebuildBanner();
                return;
            }
        }
        self.stop();
    }

    pub fn toggleControl(self: *Controller) void {
        const h = self.host orelse {
            self.setErr("only the host can grant control");
            return;
        };
        if (h.phase != .open) {
            self.setErr("nobody is watching yet");
            return;
        }
        h.setControl(h.access != .control) catch |err| self.setErr(@errorName(err));
        self.rebuildBanner();
    }

    pub fn onPaneClosed(self: *Controller, id: u32) void {
        if (self.bound and self.pane == id) self.stop();
    }

    pub fn openPrompt(self: *Controller) void {
        if (self.prompt != null) {
            self.closePrompt();
            return;
        }
        self.prompt = std.ArrayList(u8).init(self.a);
    }

    pub fn promptOpen(self: *const Controller) bool {
        return self.prompt != null;
    }

    pub fn closePrompt(self: *Controller) void {
        if (self.prompt) |*p| p.deinit();
        self.prompt = null;
    }

    pub fn feedPrompt(self: *Controller, bytes: []const u8) PromptAction {
        const p = &(self.prompt orelse return .idle);
        if (bytes.len == 1) switch (bytes[0]) {
            '\r', '\n' => {
                self.pending_len = @min(p.items.len, self.pending.len);
                @memcpy(self.pending[0..self.pending_len], p.items[0..self.pending_len]);
                self.closePrompt();
                return .join;
            },
            0x1b, 0x03 => {
                self.closePrompt();
                return .cancel;
            },
            0x7f, 0x08 => {
                if (p.items.len > 0) p.shrinkRetainingCapacity(p.items.len - 1);
                return .stay;
            },
            else => {},
        };
        for (bytes) |b| if (b < 0x20 or b > 0x7e) return .stay;
        if (p.items.len + bytes.len > 400) return .stay;
        p.appendSlice(bytes) catch return .stay;
        return .stay;
    }

    pub fn promptPaste(self: *Controller, bytes: []const u8) void {
        const p = &(self.prompt orelse return);
        for (bytes) |b| {
            if (b == '\r' or b == '\n' or b == ' ' or b == '\t') continue;
            if (b < 0x20 or b > 0x7e) continue;
            if (p.items.len >= 400) break;
            p.append(b) catch break;
        }
    }

    pub fn fillPoll(self: *Controller, out: *[2]io.Fd) usize {
        if (self.host) |h| return h.fds(out);
        if (self.guest) |g| {
            const fd = g.fd();
            if (io.isNone(fd)) return 0;
            out[0] = fd;
            return 1;
        }
        return 0;
    }

    pub fn tick(self: *Controller) void {
        if (self.host) |h| {
            h.tick() catch |err| self.setErr(@errorName(err));
            if (h.failure()) |name| self.setErr(name);
        }
        if (self.guest) |g| {
            g.tick() catch |err| self.setErr(@errorName(err));
            if (g.failure()) |name| self.setErr(name);
            if (g.kicked and !self.saw_kick) {
                self.saw_kick = true;
                self.setErr("kicked by the host");
            }
        }
        self.rebuildBanner();
    }

    pub fn takeInput(self: *Controller, dst: []u8) usize {
        const h = self.host orelse return 0;
        return h.takeInput(dst);
    }

    pub fn takeAnnounce(self: *Controller) ?[]const u8 {
        if (!self.announce_pending) return null;
        self.announce_pending = false;
        return self.announce;
    }

    pub fn takeError(self: *Controller) ?[]const u8 {
        if (!self.err_pending) return null;
        self.err_pending = false;
        return self.err[0..self.err_len];
    }

    /// Headless input: raw bytes. Control forwards them; otherwise arrow keys
    /// move this guest's cursor.
    pub fn onGuestBytes(self: *Controller, bytes: []const u8) void {
        const g = self.guest orelse return;
        if (g.access == .control and g.phase == .open) {
            self.sendGuestInput(bytes);
            return;
        }
        var i: usize = 0;
        while (i < bytes.len) {
            if (bytes[i] == 0x1b and i + 2 < bytes.len and bytes[i + 1] == '[') {
                const key: ?input.Key = switch (bytes[i + 2]) {
                    'A' => .up,
                    'B' => .down,
                    'C' => .right,
                    'D' => .left,
                    'H' => .home,
                    else => null,
                };
                if (key) |k| {
                    _ = self.onKey(k, .{});
                    i += 3;
                    continue;
                }
            }
            i += 1;
        }
    }

    pub fn sendGuestInput(self: *Controller, bytes: []const u8) void {
        const g = self.guest orelse return;
        g.sendInput(bytes) catch |err| self.setErr(@errorName(err));
    }

    pub fn onKey(self: *Controller, key: input.Key, mods: input.Mods) KeyResult {
        const g = self.guest orelse return .ignore;
        if (g.phase != .open) return .consumed;
        if (g.access == .control) return .send;
        const shift = mods.shift;
        const moved = switch (key) {
            .up => self.step(-1, 0, shift, g.rows, g.cols),
            .down => self.step(1, 0, shift, g.rows, g.cols),
            .left => self.step(0, -1, shift, g.rows, g.cols),
            .right => self.step(0, 1, shift, g.rows, g.cols),
            .home => self.stepHome(shift, g.cols),
            .escape => blk: {
                self.sel = false;
                break :blk true;
            },
            else => false,
        };
        if (moved) self.pushPointer();
        return .consumed;
    }

    pub fn onMouse(self: *Controller, row: u16, col: u16, action: input.MouseAction, button: input.MouseButton) void {
        if (self.guest == null) return;
        if (button != .left and action == .press) return;
        const g = self.guest.?;
        const r = if (g.rows == 0) row else @min(row, g.rows - 1);
        const c = if (g.cols == 0) col else @min(col, g.cols - 1);
        switch (action) {
            .press => {
                self.anchor_r = r;
                self.anchor_c = c;
                self.row = r;
                self.col = c;
                self.sel = false;
                self.dragging = true;
            },
            .motion => {
                if (!self.dragging) return;
                self.row = r;
                self.col = c;
                self.sel = r != self.anchor_r or c != self.anchor_c;
            },
            .release => {
                self.row = r;
                self.col = c;
                self.dragging = false;
                self.sel = r != self.anchor_r or c != self.anchor_c;
            },
        }
        self.pushPointer();
    }

    fn step(self: *Controller, dr: i32, dc: i32, shift: bool, rows: u16, cols: u16) bool {
        if (rows == 0 or cols == 0) return false;
        if (shift and !self.sel) {
            self.anchor_r = self.row;
            self.anchor_c = self.col;
            self.sel = true;
        }
        if (!shift) self.sel = false;
        const nr = @as(i32, self.row) + dr;
        const nc = @as(i32, self.col) + dc;
        self.row = @intCast(std.math.clamp(nr, 0, @as(i32, rows) - 1));
        self.col = @intCast(std.math.clamp(nc, 0, @as(i32, cols) - 1));
        return true;
    }

    fn stepHome(self: *Controller, shift: bool, cols: u16) bool {
        if (cols == 0) return false;
        if (shift and !self.sel) {
            self.anchor_r = self.row;
            self.anchor_c = self.col;
            self.sel = true;
        }
        self.col = 0;
        return true;
    }

    fn pushPointer(self: *Controller) void {
        const g = self.guest orelse return;
        g.sendPointer(.{
            .row = self.row,
            .col = self.col,
            .sel = self.sel,
            .r0 = self.anchor_r,
            .c0 = self.anchor_c,
            .r1 = self.row,
            .c1 = self.col,
        }) catch |err| self.setErr(@errorName(err));
    }

    pub fn flushGrid(self: *Controller, term: *terminal.Terminal) void {
        const h = self.host orelse return;
        if (h.phase != .open) return;
        const rows = term.rows;
        const cols = term.cols;
        if (rows == 0 or cols == 0) return;
        if (self.fp_rows != rows or self.fp_cols != cols or self.fp.len != @as(usize, rows) * cols) {
            self.a.free(self.fp);
            self.fp = self.a.alloc(u64, @as(usize, rows) * cols) catch return;
            @memset(self.fp, 0);
            self.fp_rows = rows;
            self.fp_cols = cols;
            h.full = true;
        }
        var scratch = self.a.alloc(u8, @as(usize, cols) * msg.wire_len) catch return;
        defer self.a.free(scratch);
        var r: u16 = 0;
        while (r < rows) : (r += 1) {
            const line = term.screenRow(r);
            var changed = h.full;
            var c: u16 = 0;
            while (c < cols) : (c += 1) {
                const sig = cellSig(line[c]);
                const i = @as(usize, r) * cols + c;
                if (self.fp[i] != sig) {
                    changed = true;
                    self.fp[i] = sig;
                }
                writeTermCell(scratch[c * msg.wire_len ..][0..msg.wire_len], line[c]);
            }
            if (!changed) continue;
            h.sendRow(.{
                .rows = rows,
                .cols = cols,
                .cursor_row = term.cursor_row,
                .cursor_col = term.cursor_col,
                .cursor_on = term.cursor_visible,
                .index = r,
                .cells = scratch[0 .. @as(usize, cols) * msg.wire_len],
            }) catch |err| self.setErr(@errorName(err));
        }
        h.full = false;
        if (!self.saw_cursor or self.last_cr != term.cursor_row or self.last_cc != term.cursor_col or self.last_on != term.cursor_visible) {
            self.saw_cursor = true;
            self.last_cr = term.cursor_row;
            self.last_cc = term.cursor_col;
            self.last_on = term.cursor_visible;
            h.sendCursor(.{ .row = term.cursor_row, .col = term.cursor_col, .on = term.cursor_visible }) catch {};
        }
    }

    /// Copy the host grid into `term`. Returns true when the screen changed.
    pub fn applyGrid(self: *Controller, term: *terminal.Terminal) bool {
        const g = self.guest orelse return false;
        if (!g.dirty or g.cols == 0 or g.rows == 0) return false;
        const rows = @min(term.rows, g.rows);
        const cols = @min(term.cols, g.cols);
        var r: u16 = 0;
        while (r < term.rows) : (r += 1) {
            var c: u16 = 0;
            while (c < term.cols) : (c += 1) {
                if (r < rows and c < cols) {
                    const off = (@as(usize, r) * g.cols + c) * msg.wire_len;
                    if (off + msg.wire_len <= g.grid.items.len) {
                        term.setCell(r, c, cellFromWire(msg.readCell(g.grid.items[off..][0..msg.wire_len])));
                        continue;
                    }
                }
                term.setCell(r, c, Cell.init());
            }
        }
        term.cursor_row = @min(g.cursor_row, term.rows -| 1);
        term.cursor_col = @min(g.cursor_col, term.cols -| 1);
        term.cursor_visible = g.cursor_on;
        g.dirty = false;
        return true;
    }

    pub fn paint(self: *Controller, cells: []Cell, marks: []Mark, stride: u16, x: u16, y: u16, w: u16, h: u16) void {
        if (w == 0 or h == 0 or !self.active()) return;
        if (self.prompt != null) {
            self.paintPrompt(cells, marks, stride, x, y, w);
            return;
        }
        if (self.host) |host| if (host.has_pointer) self.paintPointer(cells, marks, stride, x, y, w, h, host.pointer);
        if (self.guest != null) {
            const p = msg.Pointer{
                .row = self.row,
                .col = self.col,
                .sel = self.sel,
                .r0 = self.anchor_r,
                .c0 = self.anchor_c,
                .r1 = self.row,
                .c1 = self.col,
            };
            self.paintPointer(cells, marks, stride, x, y, w, h, p);
        }
        if (self.banner_len == 0) return;
        self.paintBar(cells, marks, stride, x, y, w, self.banner[0..self.banner_len], self.barColors());
    }

    fn paintPrompt(self: *Controller, cells: []Cell, marks: []Mark, stride: u16, x: u16, y: u16, w: u16) void {
        var buf: [180]u8 = undefined;
        const text = self.prompt.?.items;
        const shown = std.fmt.bufPrint(&buf, " join: {s}_", .{text}) catch " join: ";
        self.paintBar(cells, marks, stride, x, y, w, shown, paint_reading);
    }

    fn paintPointer(self: *Controller, cells: []Cell, marks: []Mark, stride: u16, x: u16, y: u16, w: u16, h: u16, p: msg.Pointer) void {
        _ = self;
        _ = cells;
        if (p.sel) {
            const r_lo = @min(p.r0, p.r1);
            const r_hi = @max(p.r0, p.r1);
            const c_lo = @min(p.c0, p.c1);
            const c_hi = @max(p.c0, p.c1);
            var r = r_lo;
            while (r <= r_hi) : (r += 1) {
                if (r >= h) break;
                var c = c_lo;
                while (c <= c_hi) : (c += 1) {
                    if (c >= w) break;
                    const i = @as(usize, y + r) * stride + (x + c);
                    if (i < marks.len) marks[i] = .guest;
                }
                if (r == std.math.maxInt(u16)) break;
            }
        }
        if (p.row < h and p.col < w) {
            const i = @as(usize, y + p.row) * stride + (x + p.col);
            if (i < marks.len) marks[i] = .guest_cursor;
        }
    }

    fn paintBar(self: *Controller, cells: []Cell, marks: []Mark, stride: u16, x: u16, y: u16, w: u16, text: []const u8, colors: BarPaint) void {
        _ = self;
        var i: u16 = 0;
        while (i < w) : (i += 1) {
            const at = @as(usize, y) * stride + (x + i);
            if (at >= cells.len) break;
            var cell = Cell.init();
            cell.fg_color = colors.fg;
            cell.bg_color = colors.bg;
            cell.char = if (i < text.len) text[i] else ' ';
            cells[at] = cell;
            if (at < marks.len) marks[at] = .none;
        }
    }

    fn barColors(self: *const Controller) BarPaint {
        if (self.guest) |g| {
            if (g.kicked or g.access == .control) return paint_watched;
            if (g.phase != .open) return paint_waiting;
            return paint_reading;
        }
        if (self.host) |h| if (h.phase == .open) return paint_watched;
        return paint_waiting;
    }

    fn rebuildBanner(self: *Controller) void {
        const text: []const u8 = if (self.guest) |g| blk: {
            if (g.kicked) break :blk " KICKED by the host";
            if (g.phase == .waiting) break :blk " JOINING shared haunting...";
            if (g.access == .control) break :blk " WATCHING | you have CONTROL | keys go to the host";
            break :blk " WATCHING | read-only | arrows move your cursor";
        } else if (self.host) |h| blk: {
            break :blk hostBanner(builtin.os.tag == .macos, h.phase, h.access);
        } else "";
        self.banner_len = @min(text.len, self.banner.len);
        @memcpy(self.banner[0..self.banner_len], text[0..self.banner_len]);
    }

    fn setErr(self: *Controller, text: []const u8) void {
        self.err_len = @min(text.len, self.err.len);
        @memcpy(self.err[0..self.err_len], text[0..self.err_len]);
        self.err_pending = true;
    }
};

/// Host banner. `mac` selects the chord that reaches a Mac (Cmd+Shift+G).
/// Ctrl+Shift+G is the binding everywhere else.
fn hostBanner(mac: bool, phase: session.Phase, access: session.Access) []const u8 {
    switch (phase) {
        .closed => return " share stopped",
        .waiting => return " SHARING | waiting for a guest | F12 stop",
        .open => {},
    }
    if (mac and access == .control) return " BEING WATCHED | guest has CONTROL | F12 kick | Cmd+Shift+G revoke";
    if (mac) return " BEING WATCHED | read-only | F12 kick | Cmd+Shift+G grant";
    if (access == .control) return " BEING WATCHED | guest has CONTROL | F12 kick | Ctrl+Shift+G revoke";
    return " BEING WATCHED | read-only | F12 kick | Ctrl+Shift+G grant";
}

fn cellSig(cell: Cell) u64 {
    const colors = cell.resolvedColors();
    var h = std.hash.Wyhash.init(0);
    h.update(std.mem.asBytes(&cell.char));
    h.update(std.mem.asBytes(&colors.fg));
    h.update(std.mem.asBytes(&colors.bg));
    h.update(&[_]u8{ cellFlags(cell) });
    return h.final();
}

fn cellFlags(cell: Cell) u8 {
    var f: u8 = 0;
    if (cell.bold) f |= msg.flag_bold;
    if (cell.italic) f |= msg.flag_italic;
    if (cell.underline) f |= msg.flag_underline;
    if (cell.inverse) f |= msg.flag_inverse;
    if (cell.faint) f |= msg.flag_faint;
    if (cell.strikethrough) f |= msg.flag_strike;
    if (cell.width == 2) f |= msg.flag_wide;
    if (cell.width == 0) f |= msg.flag_spacer;
    return f;
}

fn writeTermCell(dst: []u8, cell: Cell) void {
    const colors = cell.resolvedColors();
    msg.writeCell(dst, cell.char, colors.fg, colors.bg, cellFlags(cell));
}

fn cellFromWire(w: msg.WireCell) Cell {
    var cell = Cell.init();
    cell.char = w.cp;
    cell.fg_color = w.fg;
    cell.bg_color = w.bg;
    cell.bold = w.flags & msg.flag_bold != 0;
    cell.italic = w.flags & msg.flag_italic != 0;
    cell.underline = w.flags & msg.flag_underline != 0;
    cell.inverse = w.flags & msg.flag_inverse != 0;
    cell.faint = w.flags & msg.flag_faint != 0;
    cell.strikethrough = w.flags & msg.flag_strike != 0;
    if (w.flags & msg.flag_wide != 0) cell.width = 2;
    if (w.flags & msg.flag_spacer != 0) cell.width = 0;
    return cell;
}

test "host banner names the Mac grant chord" {
    try std.testing.expectEqualStrings(" BEING WATCHED | read-only | F12 kick | Cmd+Shift+G grant", hostBanner(true, .open, .read_only));
    try std.testing.expectEqualStrings(" BEING WATCHED | guest has CONTROL | F12 kick | Cmd+Shift+G revoke", hostBanner(true, .open, .control));
    try std.testing.expectEqualStrings(" BEING WATCHED | read-only | F12 kick | Ctrl+Shift+G grant", hostBanner(false, .open, .read_only));
    try std.testing.expectEqualStrings(" SHARING | waiting for a guest | F12 stop", hostBanner(true, .waiting, .read_only));
}

test "read-only guest keys move the local cursor and do not require a socket" {
    var c = Controller.init(std.testing.allocator);
    defer c.deinit();
    c.guest = try std.testing.allocator.create(session.Guest);
    c.guest.?.* = .{
        .allocator = std.testing.allocator,
        .psk = [_]u8{0} ** 32,
        .grid = std.ArrayList(u8).init(std.testing.allocator),
        .phase = .open,
        .rows = 10,
        .cols = 20,
        .access = .read_only,
    };
    defer {
        c.guest.?.grid.deinit();
        std.testing.allocator.destroy(c.guest.?);
        c.guest = null;
    }
    try std.testing.expectEqual(KeyResult.consumed, c.onKey(.right, .{}));
    try std.testing.expectEqual(@as(u16, 1), c.col);
    try std.testing.expectEqual(KeyResult.send, blk: {
        c.guest.?.access = .control;
        break :blk c.onKey(.right, .{});
    });
}
