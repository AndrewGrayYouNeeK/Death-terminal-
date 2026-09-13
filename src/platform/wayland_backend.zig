const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Event = @import("window.zig").Event;

const c = if (builtin.os.tag == .linux) @cImport({
    @cInclude("wayland-client.h");
    @cInclude("xkbcommon/xkbcommon.h");
    @cInclude("xdg_shim.h");
}) else struct {};

pub const State = struct {
    allocator: std.mem.Allocator = undefined,
    display: if (builtin.os.tag == .linux) ?*c.wl_display else ?*anyopaque = null,
    registry: if (builtin.os.tag == .linux) ?*c.wl_registry else ?*anyopaque = null,
    compositor: if (builtin.os.tag == .linux) ?*c.wl_compositor else ?*anyopaque = null,
    shm: if (builtin.os.tag == .linux) ?*c.wl_shm else ?*anyopaque = null,
    seat: if (builtin.os.tag == .linux) ?*c.wl_seat else ?*anyopaque = null,
    output: if (builtin.os.tag == .linux) ?*c.wl_output else ?*anyopaque = null,
    keyboard: if (builtin.os.tag == .linux) ?*c.wl_keyboard else ?*anyopaque = null,
    surface: if (builtin.os.tag == .linux) ?*c.wl_surface else ?*anyopaque = null,
    xdg_base: ?*anyopaque = null,
    xdg_surface: ?*anyopaque = null,
    xdg_toplevel: ?*anyopaque = null,
    xkb_ctx: if (builtin.os.tag == .linux) ?*c.xkb_context else ?*anyopaque = null,
    xkb_keymap: if (builtin.os.tag == .linux) ?*c.xkb_keymap else ?*anyopaque = null,
    xkb_state: if (builtin.os.tag == .linux) ?*c.xkb_state else ?*anyopaque = null,
    configured: bool = false,
    pending_close: bool = false,
    pending_redraw: bool = false,
    pending_resize: bool = false,
    pending_w: u32 = 0,
    pending_h: u32 = 0,
    buffer_scale: u32 = 1,
    output_scale: i32 = 1,
    width: u32 = 0,
    height: u32 = 0,
    input_scratch: [32]u8 = undefined,
    input_len: u8 = 0,
    has_input: bool = false,
    shm_fd: i32 = -1,
    shm_ptr: ?[]align(std.mem.page_size) u8 = null,
    shm_pool: if (builtin.os.tag == .linux) ?*c.wl_shm_pool else ?*anyopaque = null,
    shm_buffer: if (builtin.os.tag == .linux) ?*c.wl_buffer else ?*anyopaque = null,
    shm_w: u32 = 0,
    shm_h: u32 = 0,
};

pub fn open(st: *State, allocator: std.mem.Allocator, title: []const u8, width: u32, height: u32) !void {
    if (builtin.os.tag == .linux) {
        try Linux.open(st, allocator, title, width, height);
    } else {
        return error.UnsupportedPlatform;
    }
}

pub fn close(st: *State) void {
    if (builtin.os.tag == .linux) Linux.destroy(st);
}

pub fn connectionFd(st: *const State) ?posix.fd_t {
    if (builtin.os.tag == .linux) return Linux.connectionFd(st);
    return null;
}

pub fn poll(st: *State) Event {
    if (builtin.os.tag == .linux) return Linux.poll(st);
    return .none;
}

pub fn presentRgba(st: *State, pixels: []const u32, width: u32, height: u32) void {
    if (builtin.os.tag == .linux) Linux.presentRgba(st, pixels, width, height);
}

pub fn displayPtr(st: *const State) ?*anyopaque {
    return if (builtin.os.tag == .linux) @ptrCast(st.display) else null;
}

pub fn surfacePtr(st: *const State) ?*anyopaque {
    return if (builtin.os.tag == .linux) @ptrCast(st.surface) else null;
}

const Linux = if (builtin.os.tag == .linux) struct {
    const registry_listener = c.wl_registry_listener{
        .global = registryGlobal,
        .global_remove = registryRemove,
    };
    const seat_listener = c.wl_seat_listener{
        .capabilities = seatCaps,
        .name = seatName,
    };
    const output_listener = c.wl_output_listener{
        .geometry = outputGeometry,
        .mode = outputMode,
        .done = outputDone,
        .scale = outputScale,
    };
    const keyboard_listener = c.wl_keyboard_listener{
        .keymap = keyboardKeymap,
        .enter = keyboardEnter,
        .leave = keyboardLeave,
        .key = keyboardKey,
        .modifiers = keyboardMods,
        .repeat_info = keyboardRepeat,
    };

    fn open(st: *State, allocator: std.mem.Allocator, title: []const u8, width: u32, height: u32) !void {
        st.* = .{
            .allocator = allocator,
            .width = @max(1, width),
            .height = @max(1, height),
            .buffer_scale = 1,
        };

        const dpy = c.wl_display_connect(null) orelse return error.NoWaylandDisplay;
        st.display = dpy;
        errdefer destroy(st);

        st.registry = c.wl_display_get_registry(dpy);
        _ = c.wl_registry_add_listener(st.registry, &registry_listener, st);
        _ = c.wl_display_roundtrip(dpy);

        if (st.compositor == null or st.xdg_base == null) return error.MissingWaylandGlobals;

        st.surface = c.wl_compositor_create_surface(st.compositor);
        if (st.surface == null) return error.CreateSurfaceFailed;

        st.xdg_surface = @ptrCast(c.dt_xdg_get_surface(@ptrCast(st.xdg_base), st.surface));
        if (st.xdg_surface == null) return error.CreateXdgSurfaceFailed;
        c.dt_xdg_listen_surface(@ptrCast(st.xdg_surface), st, surfaceConfigure);
        st.xdg_toplevel = @ptrCast(c.dt_xdg_get_toplevel(@ptrCast(st.xdg_surface)));
        if (st.xdg_toplevel == null) return error.CreateToplevelFailed;
        c.dt_xdg_listen_toplevel(@ptrCast(st.xdg_toplevel), st, toplevelConfigure, toplevelClose);

        const title_z = try allocator.allocSentinel(u8, title.len, 0);
        defer allocator.free(title_z);
        @memcpy(title_z, title);
        c.dt_xdg_toplevel_set_title(@ptrCast(st.xdg_toplevel), title_z);
        c.dt_xdg_toplevel_set_app_id(@ptrCast(st.xdg_toplevel), "deathterminal");
        c.dt_xdg_listen_wm_base(@ptrCast(st.xdg_base), st, wmPing);

        c.wl_surface_commit(st.surface);
        while (!st.configured) {
            if (c.wl_display_dispatch(dpy) < 0) return error.WaylandDispatchFailed;
        }

        if (st.seat != null) {
            _ = c.wl_seat_add_listener(st.seat, &seat_listener, st);
        }
        if (st.output != null) {
            _ = c.wl_output_add_listener(st.output, &output_listener, st);
            _ = c.wl_display_roundtrip(dpy);
            if (st.output_scale > 1) {
                st.buffer_scale = @intCast(st.output_scale);
                c.wl_surface_set_buffer_scale(st.surface, st.output_scale);
            }
        } else {
            c.wl_surface_set_buffer_scale(st.surface, @intCast(st.buffer_scale));
        }

        _ = c.wl_display_flush(dpy);
        std.debug.print("  → Wayland window mapped ({d}x{d}) buffer_scale={d}\n", .{ st.width, st.height, st.buffer_scale });
    }

    fn destroy(st: *State) void {
        destroyShm(st);
        if (st.xkb_state) |s| c.xkb_state_unref(s);
        if (st.xkb_keymap) |k| c.xkb_keymap_unref(k);
        if (st.xkb_ctx) |ctx| c.xkb_context_unref(ctx);
        st.xkb_state = null;
        st.xkb_keymap = null;
        st.xkb_ctx = null;
        if (st.keyboard) |kb| c.wl_keyboard_destroy(kb);
        if (st.xdg_toplevel) |t| c.dt_xdg_toplevel_destroy(@ptrCast(t));
        if (st.xdg_surface) |s| c.dt_xdg_surface_destroy(@ptrCast(s));
        if (st.xdg_base) |b| c.dt_xdg_wm_base_destroy(@ptrCast(b));
        if (st.surface) |s| c.wl_surface_destroy(s);
        if (st.output) |o| c.wl_output_destroy(o);
        if (st.seat) |s| c.wl_seat_destroy(s);
        if (st.shm) |s| c.wl_shm_destroy(s);
        if (st.compositor) |comp| c.wl_compositor_destroy(comp);
        if (st.registry) |r| c.wl_registry_destroy(r);
        if (st.display) |d| c.wl_display_disconnect(d);
        st.* = .{};
    }

    fn connectionFd(st: *const State) ?posix.fd_t {
        const dpy = st.display orelse return null;
        const fd = c.wl_display_get_fd(dpy);
        if (fd < 0) return null;
        return fd;
    }

    fn poll(st: *State) Event {
        const dpy = st.display orelse return .none;
        _ = c.wl_display_dispatch_pending(dpy);
        var pfd = [_]posix.pollfd{.{ .fd = c.wl_display_get_fd(dpy), .events = posix.POLL.IN, .revents = 0 }};
        _ = posix.poll(&pfd, 0) catch 0;
        if (pfd[0].revents & posix.POLL.IN != 0) {
            _ = c.wl_display_dispatch(dpy);
        }
        _ = c.wl_display_flush(dpy);

        if (st.pending_close) {
            st.pending_close = false;
            return .close;
        }
        if (st.has_input) {
            st.has_input = false;
            return .{ .input = st.input_scratch[0..st.input_len] };
        }
        if (st.pending_resize) {
            st.pending_resize = false;
            return .{ .resize = .{ .width = st.width, .height = st.height } };
        }
        if (st.pending_redraw) {
            st.pending_redraw = false;
            return .redraw;
        }
        return .none;
    }

    fn presentRgba(st: *State, pixels: []const u32, width: u32, height: u32) void {
        const surface = st.surface orelse return;
        const shm = st.shm orelse return;
        if (width == 0 or height == 0) return;
        ensureShm(st, shm, width, height) catch return;
        const dest = st.shm_ptr orelse return;
        const count = @as(usize, width) * @as(usize, height);
        if (pixels.len < count or dest.len < count * 4) return;
        @memcpy(dest[0 .. count * 4], std.mem.sliceAsBytes(pixels[0..count]));
        c.wl_surface_attach(surface, st.shm_buffer, 0, 0);
        c.wl_surface_damage(surface, 0, 0, @intCast(width), @intCast(height));
        c.wl_surface_commit(surface);
        if (st.display) |d| _ = c.wl_display_flush(d);
    }

    fn ensureShm(st: *State, shm: *c.wl_shm, width: u32, height: u32) !void {
        if (st.shm_buffer != null and st.shm_w == width and st.shm_h == height) return;
        destroyShm(st);
        const bytes = @as(usize, width) * @as(usize, height) * 4;
        const fd = try posix.memfd_create("dt-wl-shm", 0);
        errdefer posix.close(fd);
        try posix.ftruncate(fd, @intCast(bytes));
        const mapped = try posix.mmap(null, bytes, posix.PROT.READ | posix.PROT.WRITE, .{ .TYPE = .SHARED }, fd, 0);
        const pool = c.wl_shm_create_pool(shm, fd, @intCast(bytes));
        const buf = c.wl_shm_pool_create_buffer(pool, 0, @intCast(width), @intCast(height), @intCast(width * 4), c.WL_SHM_FORMAT_ARGB8888);
        st.shm_fd = fd;
        st.shm_ptr = mapped;
        st.shm_pool = pool;
        st.shm_buffer = buf;
        st.shm_w = width;
        st.shm_h = height;
    }

    fn destroyShm(st: *State) void {
        if (st.shm_buffer) |b| c.wl_buffer_destroy(b);
        if (st.shm_pool) |p| c.wl_shm_pool_destroy(p);
        if (st.shm_ptr) |ptr| posix.munmap(ptr);
        if (st.shm_fd >= 0) posix.close(st.shm_fd);
        st.shm_buffer = null;
        st.shm_pool = null;
        st.shm_ptr = null;
        st.shm_fd = -1;
    }

    fn registryGlobal(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32, interface_name: ?[*:0]const u8, version: u32) callconv(.C) void {
        const st: *State = @ptrCast(@alignCast(data.?));
        const iface = std.mem.span(interface_name orelse return);
        if (std.mem.eql(u8, iface, "wl_compositor") and st.compositor == null) {
            st.compositor = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_compositor_interface, @min(version, 4)));
        } else if (std.mem.eql(u8, iface, "wl_shm") and st.shm == null) {
            st.shm = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_shm_interface, 1));
        } else if (std.mem.eql(u8, iface, "wl_seat") and st.seat == null) {
            st.seat = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_seat_interface, @min(version, 4)));
        } else if (std.mem.eql(u8, iface, "wl_output") and st.output == null) {
            st.output = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_output_interface, @min(version, 2)));
        } else if (std.mem.eql(u8, iface, "xdg_wm_base") and st.xdg_base == null) {
            st.xdg_base = @ptrCast(c.dt_xdg_bind(registry, name, 1));
        }
    }

    fn registryRemove(_: ?*anyopaque, _: ?*c.wl_registry, _: u32) callconv(.C) void {}

    fn wmPing(data: ?*anyopaque, serial: u32) callconv(.C) void {
        const st: *State = @ptrCast(@alignCast(data.?));
        if (st.xdg_base) |base| c.dt_xdg_wm_base_pong(@ptrCast(base), serial);
    }

    fn surfaceConfigure(data: ?*anyopaque, serial: u32) callconv(.C) void {
        const st: *State = @ptrCast(@alignCast(data.?));
        if (st.xdg_surface) |s| c.dt_xdg_surface_ack_configure(@ptrCast(s), serial);
        st.configured = true;
        st.pending_redraw = true;
        if (st.surface) |surf| c.wl_surface_commit(surf);
    }

    fn toplevelConfigure(data: ?*anyopaque, width: i32, height: i32) callconv(.C) void {
        const st: *State = @ptrCast(@alignCast(data.?));
        if (width <= 0 or height <= 0) return;
        const buf_w = @as(u32, @intCast(width)) * st.buffer_scale;
        const buf_h = @as(u32, @intCast(height)) * st.buffer_scale;
        if (buf_w != st.width or buf_h != st.height) {
            st.width = buf_w;
            st.height = buf_h;
            st.pending_resize = true;
        }
    }

    fn toplevelClose(data: ?*anyopaque) callconv(.C) void {
        const st: *State = @ptrCast(@alignCast(data.?));
        st.pending_close = true;
    }

    fn seatCaps(data: ?*anyopaque, seat: ?*c.wl_seat, caps: u32) callconv(.C) void {
        const st: *State = @ptrCast(@alignCast(data.?));
        if (caps & c.WL_SEAT_CAPABILITY_KEYBOARD != 0 and st.keyboard == null) {
            st.keyboard = c.wl_seat_get_keyboard(seat);
            _ = c.wl_keyboard_add_listener(st.keyboard, &keyboard_listener, st);
        }
    }

    fn seatName(_: ?*anyopaque, _: ?*c.wl_seat, _: ?[*:0]const u8) callconv(.C) void {}

    fn outputGeometry(_: ?*anyopaque, _: ?*c.wl_output, _: i32, _: i32, _: i32, _: i32, _: i32, _: ?[*:0]const u8, _: ?[*:0]const u8, _: i32) callconv(.C) void {}

    fn outputMode(_: ?*anyopaque, _: ?*c.wl_output, _: u32, _: i32, _: i32, _: i32) callconv(.C) void {}

    fn outputDone(_: ?*anyopaque, _: ?*c.wl_output) callconv(.C) void {}

    fn outputScale(data: ?*anyopaque, _: ?*c.wl_output, factor: i32) callconv(.C) void {
        const st: *State = @ptrCast(@alignCast(data.?));
        if (factor > 0) st.output_scale = factor;
    }

    fn keyboardKeymap(data: ?*anyopaque, _: ?*c.wl_keyboard, format: u32, fd: i32, size: u32) callconv(.C) void {
        const st: *State = @ptrCast(@alignCast(data.?));
        defer posix.close(fd);
        if (format != c.WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1 or size < 2) return;
        const map_shm = posix.mmap(null, size, posix.PROT.READ, .{ .TYPE = .PRIVATE }, fd, 0) catch return;
        defer posix.munmap(map_shm);
        if (st.xkb_ctx == null) st.xkb_ctx = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS);
        const ctx = st.xkb_ctx orelse return;
        const keymap = c.xkb_keymap_new_from_buffer(ctx, map_shm.ptr, size - 1, c.XKB_KEYMAP_FORMAT_TEXT_V1, c.XKB_KEYMAP_COMPILE_NO_FLAGS);
        if (keymap == null) return;
        const xstate = c.xkb_state_new(keymap);
        if (st.xkb_state) |s| c.xkb_state_unref(s);
        if (st.xkb_keymap) |k| c.xkb_keymap_unref(k);
        st.xkb_keymap = keymap;
        st.xkb_state = xstate;
    }

    fn keyboardEnter(_: ?*anyopaque, _: ?*c.wl_keyboard, _: u32, _: ?*c.wl_surface, _: ?*c.wl_array) callconv(.C) void {}

    fn keyboardLeave(_: ?*anyopaque, _: ?*c.wl_keyboard, _: u32, _: ?*c.wl_surface) callconv(.C) void {}

    fn keyboardKey(data: ?*anyopaque, _: ?*c.wl_keyboard, _: u32, _: u32, key: u32, state: u32) callconv(.C) void {
        const st: *State = @ptrCast(@alignCast(data.?));
        if (state != c.WL_KEYBOARD_KEY_STATE_PRESSED) return;
        const xkb_key = key + 8;
        const xs = st.xkb_state orelse return;
        var buf: [32]u8 = undefined;
        const n = c.xkb_state_key_get_utf8(xs, xkb_key, &buf, buf.len);
        const sym = c.xkb_state_key_get_one_sym(xs, xkb_key);
        if (sym == c.XKB_KEY_c or sym == c.XKB_KEY_C) {
            const mods = c.xkb_state_mod_name_is_active(xs, "Control", c.XKB_STATE_MODS_EFFECTIVE);
            if (mods == 1) {
                st.pending_close = true;
                return;
            }
        }
        if (specialSym(sym)) |seq| {
            const ncopy = @min(seq.len, st.input_scratch.len);
            @memcpy(st.input_scratch[0..ncopy], seq[0..ncopy]);
            st.input_len = @intCast(ncopy);
            st.has_input = true;
            return;
        }
        if (n > 0) {
            const ncopy: usize = @intCast(n);
            const use = @min(ncopy, st.input_scratch.len);
            @memcpy(st.input_scratch[0..use], buf[0..use]);
            st.input_len = @intCast(use);
            st.has_input = true;
        }
    }

    fn keyboardMods(data: ?*anyopaque, _: ?*c.wl_keyboard, _: u32, mods_depressed: u32, mods_latched: u32, mods_locked: u32, group: u32) callconv(.C) void {
        const st: *State = @ptrCast(@alignCast(data.?));
        if (st.xkb_state) |xs| {
            _ = c.xkb_state_update_mask(xs, mods_depressed, mods_latched, mods_locked, 0, 0, group);
        }
    }

    fn keyboardRepeat(_: ?*anyopaque, _: ?*c.wl_keyboard, _: i32, _: i32) callconv(.C) void {}

    fn specialSym(sym: u32) ?[]const u8 {
        return switch (sym) {
            c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => "\r",
            c.XKB_KEY_BackSpace => "\x7f",
            c.XKB_KEY_Tab => "\t",
            c.XKB_KEY_Escape => "\x1b",
            c.XKB_KEY_Up => "\x1b[A",
            c.XKB_KEY_Down => "\x1b[B",
            c.XKB_KEY_Right => "\x1b[C",
            c.XKB_KEY_Left => "\x1b[D",
            c.XKB_KEY_Home => "\x1b[H",
            c.XKB_KEY_End => "\x1b[F",
            c.XKB_KEY_Delete => "\x1b[3~",
            else => null,
        };
    }
} else struct {};

test "wayland state defaults to inert" {
    const st = State{};
    try std.testing.expect(st.display == null);
    try std.testing.expectEqual(@as(u32, 1), st.buffer_scale);
}
