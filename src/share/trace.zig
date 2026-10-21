//! One-line share dial trace. `DT_SHARE_DEBUG=1` prints each step. The last
//! step is kept either way so a timeout can name where the dial stopped.

const std = @import("std");
const env = @import("../platform/env.zig");

var mu: std.Thread.Mutex = .{};
var step_buf: [180]u8 = undefined;
var step_len: usize = 0;
var debug_on: ?bool = null;

pub fn enabled() bool {
    mu.lock();
    defer mu.unlock();
    if (debug_on) |v| return v;
    const raw = env.get("DT_SHARE_DEBUG") orelse "";
    const on = raw.len > 0 and !std.mem.eql(u8, raw, "0") and !std.ascii.eqlIgnoreCase(raw, "false") and !std.ascii.eqlIgnoreCase(raw, "off");
    debug_on = on;
    return on;
}

pub fn copyStep(dst: []u8) usize {
    mu.lock();
    defer mu.unlock();
    const n = @min(dst.len, step_len);
    @memcpy(dst[0..n], step_buf[0..n]);
    return n;
}

pub fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [180]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch "share step";
    mu.lock();
    const n = @min(text.len, step_buf.len);
    @memcpy(step_buf[0..n], text[0..n]);
    step_len = n;
    mu.unlock();
    if (enabled()) std.debug.print("share: {s}\n", .{text});
}
