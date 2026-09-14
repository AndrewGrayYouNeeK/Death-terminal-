const std = @import("std");
const builtin = @import("builtin");

/// Clamp and snap a UI scale so 8×16 glyphs stay on integer pixel sizes.
pub fn normalize(scale: f32) f32 {
    if (!std.math.isFinite(scale) or scale < 1.0) return 1.0;
    return @min(scale, 4.0);
}

/// Env-based scale when the user did not pass `--scale`.
pub fn detectEnvScale() f32 {
    if (parseEnv("DT_SCALE")) |s| return normalize(s);
    if (parseEnv("GDK_SCALE")) |s| return normalize(s);
    if (parseEnv("QT_SCALE_FACTOR")) |s| return normalize(s);
    return 1.0;
}

pub fn fromDpi(dpi: f32) f32 {
    if (dpi <= 0) return 1.0;
    return normalize(dpi / 96.0);
}

pub fn parseXftDpi(resources: []const u8) ?f32 {
    const key = "Xft.dpi:";
    const idx = std.mem.indexOf(u8, resources, key) orelse return null;
    var rest = std.mem.trimLeft(u8, resources[idx + key.len ..], " \t");
    const end = std.mem.indexOfAny(u8, rest, " \t\n\r") orelse rest.len;
    const num = std.mem.trim(u8, rest[0..end], " \t");
    const dpi = std.fmt.parseFloat(f32, num) catch return null;
    return fromDpi(dpi);
}

fn parseEnv(name: []const u8) ?f32 {
    if (builtin.os.tag == .windows) return null;
    const raw = std.posix.getenv(name) orelse return null;
    return normalize(std.fmt.parseFloat(f32, raw) catch return 1.0);
}

test "normalize rejects sub-1 scales" {
    try std.testing.expectEqual(@as(f32, 1.0), normalize(0.5));
    try std.testing.expectEqual(@as(f32, 2.0), normalize(2.0));
    try std.testing.expectEqual(@as(f32, 4.0), normalize(8.0));
}

test "fromDpi maps 96 and 192" {
    try std.testing.expectEqual(@as(f32, 1.0), fromDpi(96));
    try std.testing.expectEqual(@as(f32, 2.0), fromDpi(192));
}
