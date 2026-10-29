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
const short_code = @import("../share/short_code.zig");

const Cell = terminal.Cell;
const Mark = frame_mod.Mark;

const OverlayKind = enum { char, word, line, all };

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
    /// Selection inside the host invite overlay, as byte offsets into `invite`.
    /// A click with no drag selects the whole invite. Drag, double-click, and
    /// triple-click select a slice. `ov_copy` asks the window to put that
    /// slice on the clipboard once.
    ov_on: bool = false,
    ov_lo: usize = 0,
    ov_hi: usize = 0,
    ov_anchor: usize = 0,
    ov_drag: bool = false,
    ov_moved: bool = false,
    ov_copy: bool = false,
    ov_kind: OverlayKind = .char,
    addr: [80]u8 = undefined,
    addr_len: usize = 0,
    err: [160]u8 = undefined,
    err_len: usize = 0,
    err_pending: bool = false,
    banner: [180]u8 = undefined,
    banner_len: usize = 0,
    /// `[Copy]` flips to `Copied!` until this timestamp, then back.
    showing_copied: bool = false,
    copied_until: i64 = 0,
    /// Spaced short code columns at the start of the banner, drawn bold.
    bold_cols: u16 = 0,
    short_on: bool = false,
    short_raw: [short_code.len]u8 = [_]u8{0} ** short_code.len,
    /// `deathterminal --join K7Q-4MZ\n` when a short code was registered.
    copy_buf: [80]u8 = undefined,
    copy_len: usize = 0,
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
        self.short_on = false;
        self.copy_len = 0;
        self.bold_cols = 0;
        if (relay_cfg.kind == .ws and invite.isDefaultHostedRelay(relay_url)) {
            if (short_code.register(adv, host.port(), &host.secret, relay_url)) |raw| {
                self.short_raw = raw;
                self.short_on = true;
                const shown = short_code.hyphen(&raw);
                if (std.fmt.bufPrint(&self.copy_buf, "deathterminal --join {s}\n", .{&shown})) |line| {
                    self.copy_len = line.len;
                } else |_| {}
            }
        }
        const addr = std.fmt.bufPrint(&self.addr, "{s}:{d}", .{ adv, host.port() }) catch adv;
        self.addr_len = addr.len;
        const shown = if (self.short_on) short_code.hyphen(&self.short_raw) else [_]u8{0} ** 7;
        const join_code: []const u8 = if (self.short_on) shown[0..] else host.code;
        const inv = std.fmt.bufPrint(&self.invite, "{s}:{d}\ndeathterminal --join {s}\n", .{ adv, host.port(), join_code }) catch
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

    /// Highlighted slice of the invite, when the host has one.
    pub fn overlayText(self: *const Controller) ?[]const u8 {
        if (!self.ov_on or self.invite_len == 0) return null;
        const lo = @min(self.ov_lo, self.ov_hi);
        const hi = @min(self.invite_len, @max(self.ov_lo, self.ov_hi));
        if (lo >= hi) return null;
        return self.invite[lo..hi];
    }

    /// One clipboard payload for the gesture that just finished. The highlight stays.
    pub fn takeOverlayCopy(self: *Controller) ?[]const u8 {
        if (!self.ov_copy) return null;
        self.ov_copy = false;
        if (self.ov_kind == .all and self.copy_len > 0) return self.copy_buf[0..self.copy_len];
        return self.overlayText();
    }

    pub fn clearOverlaySel(self: *Controller) void {
        self.ov_on = false;
        self.ov_lo = 0;
        self.ov_hi = 0;
        self.ov_anchor = 0;
        self.ov_drag = false;
        self.ov_moved = false;
        self.ov_copy = false;
        self.ov_kind = .char;
    }

    /// Host invite overlay. `row` 0 is the banner; the invite is wrapped on the
    /// rows under it, the same way `paint` draws it. Returns true when the
    /// event belongs to the overlay (including a drag that started there).
    pub fn feedHostOverlay(
        self: *Controller,
        col: u16,
        row: u16,
        w: u16,
        h: u16,
        action: input.MouseAction,
        button: input.MouseButton,
        clicks: u8,
    ) bool {
        const hosting = self.host != null and self.invite_len > 0 and w > 0 and h > 1;
        if (!hosting) {
            if (action == .press) self.clearOverlaySel();
            return false;
        }
        const invite_rows: u16 = @min(h - 1, 6);
        const on_banner = row == 0;
        const on_body = row >= 1 and row - 1 < invite_rows;
        const hit = on_banner or on_body;
        if (action == .press and button != .left) return false;
        if (action == .press and !hit) {
            self.clearOverlaySel();
            return false;
        }
        if (!self.ov_drag and !hit) return false;
        switch (action) {
            .press => {
                if (on_banner) {
                    self.selectOverlayAll();
                    self.ov_drag = true;
                    self.ov_kind = .all;
                    self.ov_moved = false;
                    self.ov_copy = true;
                    return true;
                }
                const at = self.caretAt(w, invite_rows, row, col);
                const n: u8 = if (clicks >= 3) 3 else if (clicks == 2) 2 else 1;
                if (n >= 3) {
                    self.selectOverlayLine(at);
                    self.ov_kind = .line;
                } else if (n == 2) {
                    self.selectOverlayWord(at);
                    self.ov_kind = .word;
                } else {
                    self.ov_anchor = @min(at, self.invite_len);
                    self.ov_lo = self.ov_anchor;
                    self.ov_hi = self.ov_anchor;
                    self.ov_on = false;
                    self.ov_kind = .char;
                }
                self.ov_drag = true;
                self.ov_moved = false;
                return true;
            },
            .motion => {
                if (!self.ov_drag) return false;
                if (self.ov_kind == .char) self.extendOverlay(self.caretAt(w, invite_rows, row, col));
                return true;
            },
            .release => {
                if (!self.ov_drag) return false;
                self.ov_drag = false;
                if (self.ov_kind == .char and !self.ov_moved) self.selectOverlayAll();
                if (self.ov_on) self.ov_copy = true;
                return true;
            },
        }
    }

    pub fn join(self: *Controller, pane: u32) void {
        if (self.pending_len == 0) {
            self.setErr("empty invite code");
            return;
        }
        self.stop();
        const resolved = short_code.resolve(self.a, self.pending[0..self.pending_len]) catch |err| {
            self.setErr(@errorName(err));
            return;
        };
        defer self.a.free(resolved);
        const guest = session.Guest.start(self.a, resolved) catch |err| {
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
        self.clearOverlaySel();
        self.addr_len = 0;
        self.banner_len = 0;
        self.showing_copied = false;
        self.copied_until = 0;
        self.bold_cols = 0;
        self.short_on = false;
        self.copy_len = 0;
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
            self.paintBar(cells, marks, stride, x, y, w, self.banner[0..self.banner_len], self.barColors(), self.bold_cols);
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
        self.paintBar(cells, marks, stride, x, y, w, shown, paint_reading, 0);
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
        for (text, 0..) |ch, i| {
            if (row >= h) break;
            if (ch == '\n') {
                if (line_started) {
                    while (col < w) : (col += 1) self.putOverlay(cells, marks, stride, x, y, row, col, ' ', null);
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
            self.putOverlay(cells, marks, stride, x, y, row, col, ch, i);
            col += 1;
            line_started = true;
        }
    }

    fn putOverlay(self: *Controller, cells: []Cell, marks: []Mark, stride: u16, x: u16, y: u16, row: u16, col: u16, ch: u8, index: ?usize) void {
        const at = @as(usize, y + row) * stride + (x + col);
        if (at >= cells.len) return;
        var cell = Cell.init();
        cell.fg_color = paint_waiting.fg;
        cell.bg_color = paint_waiting.bg;
        cell.char = ch;
        cells[at] = cell;
        if (at < marks.len) {
            const on = if (index) |i| self.byteSelected(i) else false;
            marks[at] = if (on) .selected else .none;
        }
    }

    fn byteSelected(self: *const Controller, index: usize) bool {
        if (!self.ov_on) return false;
        const lo = @min(self.ov_lo, self.ov_hi);
        const hi = @max(self.ov_lo, self.ov_hi);
        return index >= lo and index < hi;
    }

    fn caretAt(self: *const Controller, w: u16, invite_rows: u16, row: u16, col: u16) usize {
        if (row == 0) return 0;
        if (row >= 1 and row - 1 < invite_rows) {
            return indexAt(self.invite[0..self.invite_len], w, invite_rows, row - 1, col) orelse self.invite_len;
        }
        return self.invite_len;
    }

    fn selectOverlayAll(self: *Controller) void {
        self.ov_on = self.invite_len > 0;
        self.ov_lo = 0;
        self.ov_hi = self.invite_len;
        self.ov_kind = .all;
    }

    fn selectOverlayWord(self: *Controller, at: usize) void {
        const b = wordBounds(self.invite[0..self.invite_len], at);
        self.ov_on = b.lo < b.hi;
        self.ov_lo = b.lo;
        self.ov_hi = b.hi;
        self.ov_kind = .word;
    }

    fn selectOverlayLine(self: *Controller, at: usize) void {
        const b = lineBounds(self.invite[0..self.invite_len], at);
        self.ov_on = b.lo < b.hi;
        self.ov_lo = b.lo;
        self.ov_hi = b.hi;
        self.ov_kind = .line;
    }

    fn extendOverlay(self: *Controller, at: usize) void {
        const end = self.invite_len;
        const a = @min(self.ov_anchor, end);
        const b = @min(at, end);
        if (a == b) return;
        self.ov_moved = true;
        self.ov_on = true;
        const lo = @min(a, b);
        var hi = @max(a, b);
        if (hi < end and self.invite[hi] != '\n') hi += 1;
        self.ov_lo = lo;
        self.ov_hi = hi;
    }

    fn paintBar(self: *Controller, cells: []Cell, marks: []Mark, stride: u16, x: u16, y: u16, w: u16, text: []const u8, colors: BarPaint, bold_cols: u16) void {
        _ = self;
        var i: u16 = 0;
        while (i < w) : (i += 1) {
            const at = @as(usize, y) * stride + (x + i);
            if (at >= cells.len) break;
            var cell = Cell.init();
            cell.fg_color = colors.fg;
            cell.bg_color = colors.bg;
            cell.bold = i < bold_cols and i < text.len and text[i] != ' ';
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
        const word = if (self.showing_copied) "Copied!" else "[Copy]";
        self.bold_cols = 0;
        const formatted = if (self.short_on) blk: {
            var wide: [16]u8 = undefined;
            const sn = short_code.spaced(&self.short_raw, &wide);
            self.bold_cols = 1 + @as(u16, @intCast(sn));
            break :blk std.fmt.bufPrint(&self.banner, " {s}  {s} | {s} | F12 stop", .{ wide[0..sn], word, self.addr[0..self.addr_len] });
        } else if (h.phase == .waiting)
            std.fmt.bufPrint(&self.banner, " SHARING {s} {s} | waiting for a guest | F12 stop", .{ self.addr[0..self.addr_len], word })
        else
            std.fmt.bufPrint(&self.banner, "{s} | {s} {s}", .{ status, self.addr[0..self.addr_len], word });
        if (formatted) |t| {
            self.banner_len = t.len;
        } else |_| self.copyBanner(status);
    }

    /// Remember a clipboard write. The banner shows `Copied!` for two seconds.
    pub fn markCopied(self: *Controller, now: i64) void {
        self.showing_copied = true;
        self.copied_until = now + 2000;
        self.rebuildBanner();
    }

    /// Restore `[Copy]` after the confirmation expires. True when the text changed.
    pub fn tickBanner(self: *Controller, now: i64) bool {
        if (!self.showing_copied or now < self.copied_until) return false;
        self.showing_copied = false;
        self.copied_until = 0;
        self.rebuildBanner();
        return true;
    }

    /// True when `col` is on the banner's `[Copy]` or `Copied!` label.
    pub fn copyControlAt(self: *const Controller, col: u16) bool {
        const text = self.banner[0..self.banner_len];
        const label = if (self.showing_copied) "Copied!" else "[Copy]";
        const at = std.mem.indexOf(u8, text, label) orelse return false;
        return col >= at and col < at + label.len;
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

const Span = struct { lo: usize, hi: usize };

/// Byte index of the invite cell at (`row`, `col`) in the same wrap `paintWrapped` uses.
/// `row` is 0 on the first invite line (the banner is not part of the string).
fn indexAt(text: []const u8, width: u16, max_rows: u16, row: u16, col: u16) ?usize {
    if (width == 0 or row >= max_rows) return null;
    var r: u16 = 0;
    var c: u16 = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (r >= max_rows) return null;
        const ch = text[i];
        if (ch == '\n') {
            if (r == row) return i;
            r += 1;
            c = 0;
            continue;
        }
        if (c >= width) {
            r += 1;
            c = 0;
            if (r >= max_rows) return null;
        }
        if (r == row and c == col) return i;
        c += 1;
    }
    if (r == row) return text.len;
    return null;
}

fn isInviteWord(ch: u8) bool {
    if (ch >= 'a' and ch <= 'z') return true;
    if (ch >= 'A' and ch <= 'Z') return true;
    if (ch >= '0' and ch <= '9') return true;
    return std.mem.indexOfScalar(u8, "-_./~:@%+#?&=", ch) != null;
}

fn wordBounds(text: []const u8, at: usize) Span {
    if (at >= text.len or !isInviteWord(text[at])) {
        if (at >= text.len) return .{ .lo = text.len, .hi = text.len };
        return .{ .lo = at, .hi = at + 1 };
    }
    var lo = at;
    while (lo > 0 and isInviteWord(text[lo - 1])) lo -= 1;
    var hi = at + 1;
    while (hi < text.len and isInviteWord(text[hi])) hi += 1;
    return .{ .lo = lo, .hi = hi };
}

fn lineBounds(text: []const u8, at: usize) Span {
    var lo: usize = @min(at, text.len);
    if (lo == text.len and lo > 0) lo -= 1;
    while (lo > 0 and text[lo - 1] != '\n') lo -= 1;
    var hi: usize = lo;
    while (hi < text.len and text[hi] != '\n') hi += 1;
    return .{ .lo = lo, .hi = hi };
}

/// Plain-language share failures. Zig error names stay in the log via the caller
/// only when they are already a sentence (they contain a space).
fn explainFailure(name: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, name, ' ') != null) return name;
    if (std.mem.eql(u8, name, "BadInvite")) return "bad invite code";
    if (std.mem.eql(u8, name, "NotFound")) return "that join code expired or was used up";
    if (std.mem.eql(u8, name, "RateLimited")) return "too many join attempts - wait and try again";
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
    if (std.mem.eql(u8, name, "Cancelled")) return "the relay connection was cancelled before the session opened";
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
    try std.testing.expect(std.mem.indexOf(u8, explainFailure("Cancelled"), "cancelled") != null);
    try std.testing.expect(std.mem.indexOf(u8, explainFailure("Unexpected"), "could not connect") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, c.banner[0..c.banner_len], "[Copy]") != null);
    try std.testing.expect(c.copyControlAt(@intCast(std.mem.indexOf(u8, c.banner[0..c.banner_len], "[Copy]").?)));
    c.short_raw = "K7Q4MZ".*;
    c.short_on = true;
    c.rebuildBanner();
    try std.testing.expect(std.mem.indexOf(u8, c.banner[0..c.banner_len], "K 7 Q - 4 M Z") != null);
    try std.testing.expect(c.bold_cols > 10);
    c.short_on = false;
    c.rebuildBanner();
    c.markCopied(1_000);
    try std.testing.expect(std.mem.indexOf(u8, c.banner[0..c.banner_len], "Copied!") != null);
    try std.testing.expect(!c.tickBanner(2_000));
    try std.testing.expect(c.tickBanner(3_000));
    try std.testing.expect(std.mem.indexOf(u8, c.banner[0..c.banner_len], "[Copy]") != null);
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

test "host invite overlay: click copies all, drag and multi-click select a slice" {
    var c = Controller.init(std.testing.allocator);
    defer c.deinit();
    c.setBind("127.0.0.1");
    const off = "off";
    c.relay_len = off.len;
    @memcpy(c.relay[0..off.len], off);
    const adv = "127.0.0.1";
    c.advertise_len = adv.len;
    @memcpy(c.advertise[0..adv.len], adv);
    c.startHost(7);
    const full = c.inviteText() orelse return error.NoInvite;
    const nl = std.mem.indexOfScalar(u8, full, '\n') orelse return error.NoInvite;
    const width: u16 = 48;

    try std.testing.expect(c.feedHostOverlay(0, 0, width, 8, .press, .left, 1));
    try std.testing.expectEqualStrings(full, c.takeOverlayCopy().?);
    try std.testing.expectEqualStrings(full, c.overlayText().?);

    try std.testing.expect(c.feedHostOverlay(0, 1, width, 8, .press, .left, 1));
    try std.testing.expect(c.feedHostOverlay(3, 1, width, 8, .motion, .left, 0));
    try std.testing.expect(c.feedHostOverlay(3, 1, width, 8, .release, .left, 1));
    try std.testing.expectEqualStrings(full[0..4], c.takeOverlayCopy().?);

    try std.testing.expect(c.feedHostOverlay(0, 2, width, 8, .press, .left, 2));
    try std.testing.expect(c.feedHostOverlay(0, 2, width, 8, .release, .left, 2));
    try std.testing.expectEqualStrings("deathterminal", c.overlayText().?);

    try std.testing.expect(c.feedHostOverlay(4, 2, width, 8, .press, .left, 3));
    try std.testing.expect(c.feedHostOverlay(4, 2, width, 8, .release, .left, 3));
    const line = full[nl + 1 ..];
    const line_end = std.mem.indexOfScalar(u8, line, '\n') orelse line.len;
    try std.testing.expectEqualStrings(line[0..line_end], c.overlayText().?);

    const cols: usize = width;
    const rows: usize = 5;
    var cells = [_]Cell{Cell.init()} ** (cols * rows);
    var marks = [_]Mark{.none} ** (cols * rows);
    c.paint(&cells, &marks, @intCast(cols), 0, 0, @intCast(cols), @intCast(rows));
    try std.testing.expectEqual(Mark.selected, marks[2 * cols]);
    try std.testing.expectEqual(@as(u21, 'd'), cells[2 * cols].char);

    try std.testing.expect(!c.feedHostOverlay(0, 7, width, 8, .press, .left, 1));
    try std.testing.expect(c.overlayText() == null);

    const mapped = indexAt(full, width, 6, 0, 3) orelse return error.NoInvite;
    try std.testing.expectEqual(@as(usize, 3), mapped);
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
