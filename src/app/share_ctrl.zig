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
    announce_pending: bool = false,
    /// "ip:port\ndeathterminal --join <code>\n" while hosting. Clipboard and overlay.
    invite: [640]u8 = undefined,
    invite_len: usize = 0,
    addr: [80]u8 = undefined,
    addr_len: usize = 0,
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
        if (self.host != null and self.bound and self.pane == pane and self.invite_len > 0) {
            self.announce_pending = true;
            self.rebuildBanner();
            return;
        }
        self.stop();
        var detected: [64]u8 = undefined;
        const adv: []const u8 = if (self.advertise_len > 0)
            self.advertise[0..self.advertise_len]
        else
            invite.detectLanHost(&detected);
        const relay_cfg = invite.resolveConfigured(self.relay[0..self.relay_len]) catch {
            self.setErr("bad relay");
            return;
        };
        const relay_url: []const u8 = switch (relay_cfg.kind) {
            .off => "",
            .tcp => self.relay[0..self.relay_len],
            .ws => relay_cfg.ws_url,
        };
        const host = session.Host.listen(
            self.a,
            self.bind_ip[0..self.bind_len],
            self.port,
            adv,
            relay_url,
            null,
        ) catch |err| {
            self.setErr(@errorName(err));
            return;
        };
        self.host = host;
        self.pane = pane;
        self.bound = true;
        const addr = std.fmt.bufPrint(&self.addr, "{s}:{d}", .{ adv, host.port() }) catch adv;
        self.addr_len = addr.len;
        const inv = std.fmt.bufPrint(&self.invite, "{s}:{d}\ndeathterminal --join {s}\n", .{ adv, host.port(), host.code }) catch
            std.fmt.bufPrint(&self.invite, "deathterminal --join {s}\n", .{host.code}) catch "";
        self.invite_len = inv.len;
        self.announce_pending = self.invite_len > 0;
        self.saw_cursor = false;
        self.a.free(self.fp);
        self.fp = &.{};
        self.fp_rows = 0;
        self.fp_cols = 0;
        self.rebuildBanner();
        std.debug.print("share: listening\n{s}", .{self.invite[0..self.invite_len]});
    }

    /// The text copied to the clipboard: LAN address, port, and join command.
    pub fn inviteText(self: *const Controller) ?[]const u8 {
        if (self.invite_len == 0) return null;
        return self.invite[0..self.invite_len];
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
        self.announce_pending = false;
        self.invite_len = 0;
        self.addr_len = 0;
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
        if (!self.announce_pending or self.invite_len == 0) return null;
        self.announce_pending = false;
        return self.invite[0..self.invite_len];
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
        if (self.banner_len > 0) {
            self.paintBar(cells, marks, stride, x, y, w, self.banner[0..self.banner_len], self.barColors());
        }
        if (self.host != null and self.invite_len > 0 and h > 1) {
            const rows = @min(h - 1, 6);
            self.paintWrapped(cells, marks, stride, x, y + 1, w, rows, self.invite[0..self.invite_len]);
        }
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

    fn paintWrapped(self: *Controller, cells: []Cell, marks: []Mark, stride: u16, x: u16, y: u16, w: u16, h: u16, text: []const u8) void {
        if (w == 0 or h == 0) return;
        var row: u16 = 0;
        var col: u16 = 0;
        var line_started = false;
        for (text) |ch| {
            if (row >= h) break;
            if (ch == '\n') {
                if (line_started) {
                    while (col < w) : (col += 1) self.putOverlay(cells, marks, stride, x, y, row, col, ' ');
                }
                row += 1;
                col = 0;
                line_started = false;
                continue;
            }
            if (col >= w) {
                row += 1;
                col = 0;
                if (row >= h) break;
            }
            self.putOverlay(cells, marks, stride, x, y, row, col, ch);
            col += 1;
            line_started = true;
        }
    }

    fn putOverlay(self: *Controller, cells: []Cell, marks: []Mark, stride: u16, x: u16, y: u16, row: u16, col: u16, ch: u8) void {
        _ = self;
        const at = @as(usize, y + row) * stride + (x + col);
        if (at >= cells.len) return;
        var cell = Cell.init();
        cell.fg_color = paint_waiting.fg;
        cell.bg_color = paint_waiting.bg;
        cell.char = ch;
        cells[at] = cell;
        if (at < marks.len) marks[at] = .none;
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
        if (self.guest) |g| {
            const text: []const u8 = if (g.kicked)
                " KICKED by the host"
            else if (g.phase == .waiting)
                " JOINING shared haunting..."
            else if (g.access == .control)
                " WATCHING | you have CONTROL | keys go to the host"
            else
                " WATCHING | read-only | arrows move your cursor";
            self.banner_len = @min(text.len, self.banner.len);
            @memcpy(self.banner[0..self.banner_len], text[0..self.banner_len]);
            return;
        }
        const h = self.host orelse {
            self.banner_len = 0;
            return;
        };
        const status = hostBanner(builtin.os.tag == .macos, h.phase, h.access);
        if (self.addr_len == 0) {
            self.copyBanner(status);
            return;
        }
        const formatted = if (h.phase == .waiting)
            std.fmt.bufPrint(&self.banner, " SHARING {s} | waiting for a guest | invite copied | F12 stop", .{self.addr[0..self.addr_len]})
        else
            std.fmt.bufPrint(&self.banner, "{s} | {s}", .{ status, self.addr[0..self.addr_len] });
        if (formatted) |t| {
            self.banner_len = t.len;
        } else |_| self.copyBanner(status);
    }

    fn copyBanner(self: *Controller, text: []const u8) void {
        self.banner_len = @min(text.len, self.banner.len);
        @memcpy(self.banner[0..self.banner_len], text[0..self.banner_len]);
    }

    fn setErr(self: *Controller, text: []const u8) void {
        const shown = explainFailure(text);
        const n = @min(shown.len, self.err.len);
        if (self.err_len == n and std.mem.eql(u8, self.err[0..n], shown[0..n])) {
            self.err_pending = true;
            return;
        }
        self.err_len = n;
        @memcpy(self.err[0..n], shown[0..n]);
        self.err_pending = true;
        std.debug.print("share: {s}\n", .{self.err[0..self.err_len]});
    }
};

/// Plain-language share failures. Zig error names stay in the log via the caller
/// only when they are already a sentence (they contain a space).
fn explainFailure(name: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, name, ' ') != null) return name;
    if (std.mem.eql(u8, name, "BadInvite")) return "bad invite code";
    if (std.mem.eql(u8, name, "Refused") or std.mem.eql(u8, name, "ConnectionRefused")) {
        return "connection refused - the host is not listening, or the firewall blocked it";
    }
    if (std.mem.eql(u8, name, "Timeout")) return "timed out - the host did not answer (check the address and the firewall)";
    if (std.mem.eql(u8, name, "Unreachable") or std.mem.eql(u8, name, "NetworkUnreachable")) {
        return "cannot reach the host - check the address and the firewall";
    }
    if (std.mem.eql(u8, name, "Handshake") or std.mem.eql(u8, name, "BadFrame")) return "handshake failed - the invite does not match the host";
    if (std.mem.eql(u8, name, "PermissionDenied")) return "cannot listen - permission denied (the firewall or the port blocked it)";
    if (std.mem.eql(u8, name, "AddressInUse")) return "that share port is already in use";
    if (std.mem.eql(u8, name, "BadAddress")) return "bad share bind address";
    if (std.mem.eql(u8, name, "Unexpected")) return "could not connect - the firewall may be blocking it";
    return name;
}

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

test "share failures are sentences a guest can read" {
    try std.testing.expectEqualStrings("bad invite code", explainFailure("BadInvite"));
    try std.testing.expect(std.mem.indexOf(u8, explainFailure("Refused"), "connection refused") != null);
    try std.testing.expect(std.mem.indexOf(u8, explainFailure("Refused"), "firewall") != null);
    try std.testing.expect(std.mem.indexOf(u8, explainFailure("Timeout"), "timed out") != null);
    try std.testing.expect(std.mem.indexOf(u8, explainFailure("Timeout"), "firewall") != null);
    try std.testing.expect(std.mem.indexOf(u8, explainFailure("Unreachable"), "firewall") != null);
    try std.testing.expectEqualStrings("sharing is disabled in config", explainFailure("sharing is disabled in config"));
}

test "host invite shows the address, port, and join command" {
    var c = Controller.init(std.testing.allocator);
    defer c.deinit();
    c.setBind("127.0.0.1");
    // LAN only. An empty relay would dial the hosted default.
    const off = "off";
    c.relay_len = off.len;
    @memcpy(c.relay[0..off.len], off);
    const adv = "127.0.0.1";
    c.advertise_len = adv.len;
    @memcpy(c.advertise[0..adv.len], adv);
    c.startHost(7);
    const text = c.inviteText() orelse return error.NoInvite;
    try std.testing.expect(std.mem.startsWith(u8, text, "127.0.0.1:"));
    try std.testing.expect(std.mem.indexOf(u8, text, "\ndeathterminal --join dt1.") != null);
    try std.testing.expect(c.takeAnnounce() != null);
    try std.testing.expect(std.mem.indexOf(u8, c.banner[0..c.banner_len], "127.0.0.1:") != null);
    try std.testing.expect(std.mem.indexOf(u8, c.banner[0..c.banner_len], "invite copied") != null);
    try std.testing.expect(std.mem.indexOf(u8, c.banner[0..c.banner_len], "F12 stop") != null);

    const again = try std.testing.allocator.dupe(u8, c.inviteText().?);
    defer std.testing.allocator.free(again);
    c.startHost(7);
    try std.testing.expectEqualStrings(again, c.inviteText().?);

    const cols: usize = 48;
    const rows: usize = 5;
    var cells = [_]Cell{Cell.init()} ** (cols * rows);
    var marks = [_]Mark{.none} ** (cols * rows);
    c.paint(&cells, &marks, @intCast(cols), 0, 0, @intCast(cols), @intCast(rows));
    var flat: [cols * rows]u8 = undefined;
    for (cells, 0..) |cell, i| {
        flat[i] = if (cell.char < 128) @intCast(cell.char) else ' ';
    }
    try std.testing.expect(std.mem.indexOf(u8, &flat, "127.0.0.1:") != null);
    try std.testing.expect(std.mem.indexOf(u8, &flat, "deathterminal --join dt1.") != null);
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
