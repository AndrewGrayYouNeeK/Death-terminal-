//! Application messages inside a Shared Haunting transport.
//!
//! These bytes are what ChaCha20-Poly1305 protects. Nothing here calls the
//! AI redactor: a pane share is the host's screen, secrets included. The
//! codec round-trips codepoints unchanged so a test can hold that line.

const std = @import("std");

pub const wire_len: usize = 13;

pub const flag_bold: u8 = 1;
pub const flag_italic: u8 = 2;
pub const flag_underline: u8 = 4;
pub const flag_inverse: u8 = 8;
pub const flag_faint: u8 = 16;
pub const flag_strike: u8 = 32;
pub const flag_wide: u8 = 64;
pub const flag_spacer: u8 = 128;

pub const Tag = enum(u8) {
    welcome = 1,
    row = 2,
    pointer = 3,
    input = 4,
    access = 5,
    kick = 6,
    bye = 7,
    ping = 8,
    cursor = 9,
};

pub const Access = enum(u8) {
    read_only = 0,
    control = 1,

    pub fn fromByte(b: u8) ?Access {
        return std.meta.intToEnum(Access, b) catch null;
    }
};

pub const Pointer = struct {
    row: u16 = 0,
    col: u16 = 0,
    sel: bool = false,
    r0: u16 = 0,
    c0: u16 = 0,
    r1: u16 = 0,
    c1: u16 = 0,
};

pub const Row = struct {
    rows: u16,
    cols: u16,
    cursor_row: u16,
    cursor_col: u16,
    cursor_on: bool,
    index: u16,
    cells: []const u8,
};

pub const Cursor = struct { row: u16, col: u16, on: bool };

pub const Decoded = union(enum) {
    welcome: Access,
    row: Row,
    pointer: Pointer,
    input: []const u8,
    access: Access,
    kick,
    bye,
    ping,
    cursor: Cursor,
};

pub const Error = error{ BadMessage, NoSpace };

pub fn writeCell(dst: []u8, cp: u21, fg: u32, bg: u32, flags: u8) void {
    std.mem.writeInt(u32, dst[0..4], cp, .little);
    std.mem.writeInt(u32, dst[4..8], fg, .little);
    std.mem.writeInt(u32, dst[8..12], bg, .little);
    dst[12] = flags;
}

pub const WireCell = struct { cp: u21, fg: u32, bg: u32, flags: u8 };

pub fn readCell(src: []const u8) WireCell {
    return .{
        .cp = @intCast(std.mem.readInt(u32, src[0..4], .little) & 0x10FFFF),
        .fg = std.mem.readInt(u32, src[4..8], .little),
        .bg = std.mem.readInt(u32, src[8..12], .little),
        .flags = src[12],
    };
}

fn putU16(dst: []u8, v: u16) void {
    std.mem.writeInt(u16, dst[0..2], v, .big);
}

fn takeU16(src: []const u8) u16 {
    return std.mem.readInt(u16, src[0..2], .big);
}

pub fn encodeWelcome(dst: []u8, access: Access) Error![]u8 {
    if (dst.len < 2) return error.NoSpace;
    dst[0] = @intFromEnum(Tag.welcome);
    dst[1] = @intFromEnum(access);
    return dst[0..2];
}

pub fn encodeAccess(dst: []u8, access: Access) Error![]u8 {
    if (dst.len < 2) return error.NoSpace;
    dst[0] = @intFromEnum(Tag.access);
    dst[1] = @intFromEnum(access);
    return dst[0..2];
}

pub fn encodeBare(dst: []u8, tag: Tag) Error![]u8 {
    if (dst.len < 1) return error.NoSpace;
    dst[0] = @intFromEnum(tag);
    return dst[0..1];
}

pub fn encodeInput(dst: []u8, bytes: []const u8) Error![]u8 {
    if (dst.len < 1 + bytes.len) return error.NoSpace;
    dst[0] = @intFromEnum(Tag.input);
    @memcpy(dst[1..][0..bytes.len], bytes);
    return dst[0 .. 1 + bytes.len];
}

pub fn encodePointer(dst: []u8, p: Pointer) Error![]u8 {
    if (dst.len < 14) return error.NoSpace;
    dst[0] = @intFromEnum(Tag.pointer);
    putU16(dst[1..3], p.row);
    putU16(dst[3..5], p.col);
    dst[5] = @intFromBool(p.sel);
    putU16(dst[6..8], p.r0);
    putU16(dst[8..10], p.c0);
    putU16(dst[10..12], p.r1);
    putU16(dst[12..14], p.c1);
    return dst[0..14];
}

pub fn encodeCursor(dst: []u8, c: Cursor) Error![]u8 {
    if (dst.len < 6) return error.NoSpace;
    dst[0] = @intFromEnum(Tag.cursor);
    putU16(dst[1..3], c.row);
    putU16(dst[3..5], c.col);
    dst[5] = @intFromBool(c.on);
    return dst[0..6];
}

pub fn encodeRow(dst: []u8, row: Row) Error![]u8 {
    const need = 12 + row.cells.len;
    if (dst.len < need) return error.NoSpace;
    if (row.cells.len != @as(usize, row.cols) * wire_len) return error.BadMessage;
    dst[0] = @intFromEnum(Tag.row);
    putU16(dst[1..3], row.rows);
    putU16(dst[3..5], row.cols);
    putU16(dst[5..7], row.cursor_row);
    putU16(dst[7..9], row.cursor_col);
    dst[9] = @intFromBool(row.cursor_on);
    putU16(dst[10..12], row.index);
    @memcpy(dst[12..][0..row.cells.len], row.cells);
    return dst[0..need];
}

pub fn decode(bytes: []const u8) Error!Decoded {
    if (bytes.len == 0) return error.BadMessage;
    const tag = std.meta.intToEnum(Tag, bytes[0]) catch return error.BadMessage;
    switch (tag) {
        .welcome => {
            if (bytes.len != 2) return error.BadMessage;
            return .{ .welcome = Access.fromByte(bytes[1]) orelse return error.BadMessage };
        },
        .access => {
            if (bytes.len != 2) return error.BadMessage;
            return .{ .access = Access.fromByte(bytes[1]) orelse return error.BadMessage };
        },
        .kick => {
            if (bytes.len != 1) return error.BadMessage;
            return .kick;
        },
        .bye => {
            if (bytes.len != 1) return error.BadMessage;
            return .bye;
        },
        .ping => {
            if (bytes.len != 1) return error.BadMessage;
            return .ping;
        },
        .input => return .{ .input = bytes[1..] },
        .cursor => {
            if (bytes.len != 6) return error.BadMessage;
            return .{ .cursor = .{
                .row = takeU16(bytes[1..3]),
                .col = takeU16(bytes[3..5]),
                .on = bytes[5] != 0,
            } };
        },
        .pointer => {
            if (bytes.len != 14) return error.BadMessage;
            return .{ .pointer = .{
                .row = takeU16(bytes[1..3]),
                .col = takeU16(bytes[3..5]),
                .sel = bytes[5] != 0,
                .r0 = takeU16(bytes[6..8]),
                .c0 = takeU16(bytes[8..10]),
                .r1 = takeU16(bytes[10..12]),
                .c1 = takeU16(bytes[12..14]),
            } };
        },
        .row => {
            if (bytes.len < 12) return error.BadMessage;
            const cols = takeU16(bytes[3..5]);
            const cells = bytes[12..];
            if (cells.len != @as(usize, cols) * wire_len) return error.BadMessage;
            return .{ .row = .{
                .rows = takeU16(bytes[1..3]),
                .cols = cols,
                .cursor_row = takeU16(bytes[5..7]),
                .cursor_col = takeU16(bytes[7..9]),
                .cursor_on = bytes[9] != 0,
                .index = takeU16(bytes[10..12]),
                .cells = cells,
            } };
        },
    }
}

/// Guest keystrokes are delivered only when the host has granted control
/// for this session. Read-only is the default; a kick closes the gate.
pub fn admitInput(access: Access, open: bool, bytes: []const u8) bool {
    return open and access == .control and bytes.len > 0;
}

test "row codec keeps secret-looking text" {
    const token = "sk-live-secret";
    var cells: [wire_len * token.len]u8 = undefined;
    for (token, 0..) |ch, i| {
        writeCell(cells[i * wire_len ..][0..wire_len], ch, 0xE0E0E0, 0x000000, flag_bold);
    }
    var buf: [256]u8 = undefined;
    const enc = try encodeRow(&buf, .{
        .rows = 1,
        .cols = token.len,
        .cursor_row = 0,
        .cursor_col = 3,
        .cursor_on = true,
        .index = 0,
        .cells = &cells,
    });
    const dec = try decode(enc);
    switch (dec) {
        .row => |row| {
            try std.testing.expectEqual(@as(u16, 3), row.cursor_col);
            var got: [token.len]u8 = undefined;
            for (0..token.len) |i| {
                const cell = readCell(row.cells[i * wire_len ..][0..wire_len]);
                got[i] = @intCast(cell.cp);
                try std.testing.expect(cell.flags & flag_bold != 0);
            }
            try std.testing.expectEqualStrings(token, &got);
        },
        else => return error.BadMessage,
    }
}

test "pointer, access and kick roundtrip" {
    var buf: [32]u8 = undefined;
    const p = try encodePointer(&buf, .{ .row = 2, .col = 4, .sel = true, .r0 = 2, .c0 = 4, .r1 = 3, .c1 = 8 });
    switch (try decode(p)) {
        .pointer => |g| {
            try std.testing.expect(g.sel);
            try std.testing.expectEqual(@as(u16, 8), g.c1);
        },
        else => return error.BadMessage,
    }
    switch (try decode(try encodeAccess(&buf, .control))) {
        .access => |a| try std.testing.expectEqual(Access.control, a),
        else => return error.BadMessage,
    }
    switch (try decode(try encodeBare(&buf, .kick))) {
        .kick => {},
        else => return error.BadMessage,
    }
    try std.testing.expectError(error.BadMessage, decode(&[_]u8{ 9, 0 }));
}

test "permission gate defaults to read-only" {
    try std.testing.expect(!admitInput(.read_only, true, "ls\n"));
    try std.testing.expect(!admitInput(.control, false, "ls\n"));
    try std.testing.expect(!admitInput(.control, true, ""));
    try std.testing.expect(admitInput(.control, true, "ls\n"));
}
