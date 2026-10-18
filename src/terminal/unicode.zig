const std = @import("std");
const tables = @import("unicode_width.zig");

/// U+FFFD, substituted for malformed UTF-8 and unrenderable codepoints.
pub const replacement_char: u21 = 0xFFFD;

fn inTable(cp: u21, table: []const tables.Range) bool {
    var lo: usize = 0;
    var hi: usize = table.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = table[mid];
        if (cp < r.lo) {
            hi = mid;
        } else if (cp > r.hi) {
            lo = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

/// Number of terminal columns a codepoint occupies: 0 (combining/format),
/// 1, or 2 (East Asian wide/fullwidth, emoji presentation).
pub fn width(cp: u21) u2 {
    if (cp < 0x7F) return 1; // fast path; C0 controls never reach the grid
    if (inTable(cp, &tables.zero_width)) return 0;
    if (inTable(cp, &tables.wide)) return 2;
    return 1;
}

test "unicode width" {
    const t = std.testing;
    try t.expectEqual(@as(u2, 1), width('a'));
    try t.expectEqual(@as(u2, 1), width(0x00E9)); // é
    try t.expectEqual(@as(u2, 0), width(0x0301)); // combining acute
    try t.expectEqual(@as(u2, 0), width(0x200D)); // ZWJ
    try t.expectEqual(@as(u2, 0), width(0xFE0F)); // VS16
    try t.expectEqual(@as(u2, 2), width(0x65E5)); // 日
    try t.expectEqual(@as(u2, 2), width(0x672C)); // 本
    try t.expectEqual(@as(u2, 2), width(0x1F642)); // 🙂
    try t.expectEqual(@as(u2, 2), width(0xFF21)); // fullwidth A
    try t.expectEqual(@as(u2, 1), width(0xFFFD));
    try t.expectEqual(@as(u2, 1), width(0x00AD)); // soft hyphen
}
