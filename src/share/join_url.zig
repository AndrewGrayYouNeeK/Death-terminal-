//! `deathterminal://join/<code-or-invite>` from a clicked link.
//!
//! The payload is the same string `deathterminal --join` accepts: a `dt1.`
//! invite or a six-character short code. Anything else is a fixed toast.
//! The URL is never passed to a shell.

const std = @import("std");
const invite = @import("invite.zig");
const short_code = @import("short_code.zig");

pub const not_join_toast = "That link is not a deathterminal://join/ invite.";
pub const malformed_toast = "That invite link is malformed.";

/// What the GUI does with a link. `join_focused` is `share.joinCode` on the
/// focused pane, the same call `--join` makes at startup. There is no new tab.
pub const Action = union(enum) {
    join_focused: []const u8,
    toast: []const u8,
};

const prefix = invite.link_prefix;

/// Classify `url`. `join_focused` borrows `url` (the payload slice).
pub fn route(url: []const u8) Action {
    const text = std.mem.trim(u8, url, " \t\r\n");
    if (!std.mem.startsWith(u8, text, prefix)) return .{ .toast = not_join_toast };
    const payload = text[prefix.len..];
    if (!payloadChars(payload)) return .{ .toast = malformed_toast };
    var short: [short_code.len]u8 = undefined;
    if (short_code.normalize(&short, payload)) return .{ .join_focused = payload };
    if (!std.mem.startsWith(u8, payload, invite.prefix)) return .{ .toast = malformed_toast };
    var storage: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&storage);
    var owned = invite.decodeOwned(fba.allocator(), payload) catch return .{ .toast = malformed_toast };
    owned.deinit();
    return .{ .join_focused = payload };
}

fn payloadChars(s: []const u8) bool {
    if (s.len == 0 or s.len > 400) return false;
    for (s) |c| {
        const ok = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.';
        if (!ok) return false;
    }
    return true;
}

const Slot = struct {
    mutex: std.Thread.Mutex = .{},
    buf: [401]u8 = undefined,
    len: usize = 0,
    join: bool = false,
    toast: ?[]const u8 = null,
};

var slot: Slot = .{};

/// Apple Event callback. Copies the payload so the NSString can go away.
pub fn deliver(url: []const u8) void {
    const action = route(url);
    slot.mutex.lock();
    defer slot.mutex.unlock();
    switch (action) {
        .join_focused => |payload| {
            const n = @min(payload.len, slot.buf.len);
            @memcpy(slot.buf[0..n], payload[0..n]);
            slot.len = n;
            slot.join = true;
            slot.toast = null;
        },
        .toast => |text| {
            slot.join = false;
            slot.len = 0;
            slot.toast = text;
        },
    }
}

/// One pending link, if the callback stored one. The join slice is valid
/// until the next `deliver`.
pub fn take() ?Action {
    slot.mutex.lock();
    defer slot.mutex.unlock();
    if (slot.toast) |text| {
        slot.toast = null;
        slot.join = false;
        return .{ .toast = text };
    }
    if (!slot.join) return null;
    slot.join = false;
    return .{ .join_focused = slot.buf[0..slot.len] };
}

fn sampleInvite(buf: []u8) ![]const u8 {
    const secret = [_]u8{0x11} ** invite.secret_len;
    return invite.encode(buf, .{
        .host = "192.168.1.20",
        .port = 9753,
        .secret = secret,
        .relay = "",
    });
}

test "link: deathterminal://join routes to the focused pane" {
    var code_buf: [400]u8 = undefined;
    const code = try sampleInvite(&code_buf);
    var url_buf: [480]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "{s}{s}", .{ prefix, code });
    switch (route(url)) {
        .join_focused => |payload| try std.testing.expectEqualStrings(code, payload),
        .toast => return error.UnexpectedToast,
    }
    switch (route("deathterminal://join/K7Q-4MZ")) {
        .join_focused => |payload| try std.testing.expectEqualStrings("K7Q-4MZ", payload),
        .toast => return error.UnexpectedToast,
    }
    switch (route("  deathterminal://join/k7q4mz")) {
        .join_focused => |payload| try std.testing.expectEqualStrings("k7q4mz", payload),
        .toast => return error.UnexpectedToast,
    }
}

test "link: malformed urls are a toast and are not joined" {
    const rejected = [_][]const u8{
        "deathterminal://open/calc",
        "deathterminal://join/",
        "deathterminal://join/dt1.!!!!",
        "https://example.com/join/dt1.abc",
        "deathterminal://join/dt1.abc?exec=1",
        "deathterminal://join/dt1.abc#frag",
        "deathterminal://join/dt1.abc/extra",
        "deathterminal://join/$(rm)",
        "deathterminal://join/rm -rf /",
        "deathterminal://join/K7Q-4M",
        "deathterminal:join/K7Q-4MZ",
        "deathterminal://join/%2e%2e",
    };
    for (rejected) |url| {
        switch (route(url)) {
            .join_focused => return error.JoinedBadUrl,
            .toast => |text| {
                try std.testing.expect(text.len > 0);
                try std.testing.expect(std.mem.indexOf(u8, text, "$(") == null);
                try std.testing.expect(std.mem.indexOf(u8, text, "rm ") == null);
            },
        }
    }
    switch (route("deathterminal://open/calc")) {
        .toast => |text| try std.testing.expectEqualStrings(not_join_toast, text),
        .join_focused => return error.JoinedBadUrl,
    }
    switch (route("deathterminal://join/dt1.!!!!")) {
        .toast => |text| try std.testing.expectEqualStrings(malformed_toast, text),
        .join_focused => return error.JoinedBadUrl,
    }
}

test "link: a delivered url is taken once" {
    var code_buf: [400]u8 = undefined;
    const code = try sampleInvite(&code_buf);
    var url_buf: [480]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "{s}{s}", .{ prefix, code });
    deliver("deathterminal://join/not a code");
    deliver(url);
    switch (take() orelse return error.Missing) {
        .join_focused => |payload| try std.testing.expectEqualStrings(code, payload),
        .toast => return error.UnexpectedToast,
    }
    try std.testing.expect(take() == null);
    deliver("deathterminal://join/");
    switch (take() orelse return error.Missing) {
        .toast => |text| try std.testing.expectEqualStrings(malformed_toast, text),
        .join_focused => return error.JoinedBadUrl,
    }
    try std.testing.expect(take() == null);
}
