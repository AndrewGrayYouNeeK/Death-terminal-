//! Length-prefixed frames for a Shared Haunting session.
//!
//! Every handshake message and every encrypted transport message is one
//! frame: a 2-byte big-endian length, then that many payload bytes. The
//! length counts only the payload. Payloads larger than `max_payload` are
//! rejected so a peer cannot force an unbounded buffer.

const std = @import("std");

pub const max_payload: usize = 32 * 1024;

pub const Error = error{
    BadFrame,
    TooBig,
    NoSpace,
};

/// Write `payload` as one frame into `dst`. Returns the number of bytes used.
pub fn encode(dst: []u8, payload: []const u8) Error!usize {
    if (payload.len > max_payload) return error.TooBig;
    if (dst.len < 2 + payload.len) return error.NoSpace;
    std.mem.writeInt(u16, dst[0..2], @intCast(payload.len), .big);
    @memcpy(dst[2..][0..payload.len], payload);
    return 2 + payload.len;
}

/// Reassembles frames from a byte stream. `payload` stays valid until the
/// next successful `next` call.
pub const Framer = struct {
    buf: [2 + max_payload]u8 = undefined,
    len: usize = 0,
    payload: [max_payload]u8 = undefined,
    payload_len: usize = 0,

    pub fn append(self: *Framer, bytes: []const u8) Error!void {
        if (self.len + bytes.len > self.buf.len) return error.TooBig;
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    /// One complete payload, or null when more bytes are needed.
    pub fn next(self: *Framer) Error!?[]const u8 {
        if (self.len < 2) return null;
        const n = std.mem.readInt(u16, self.buf[0..2], .big);
        if (n > max_payload) return error.BadFrame;
        if (self.len < 2 + @as(usize, n)) return null;
        @memcpy(self.payload[0..n], self.buf[2..][0..n]);
        const rest = self.len - (2 + @as(usize, n));
        std.mem.copyForwards(u8, self.buf[0..rest], self.buf[2 + n ..][0..rest]);
        self.len = rest;
        self.payload_len = n;
        return self.payload[0..n];
    }
};

test "frame roundtrip and partial delivery" {
    var raw: [64]u8 = undefined;
    const n = try encode(&raw, "ping");
    try std.testing.expectEqual(@as(usize, 6), n);
    try std.testing.expectEqual(@as(u16, 4), std.mem.readInt(u16, raw[0..2], .big));

    var fr = Framer{};
    try fr.append(raw[0..1]);
    try std.testing.expect(try fr.next() == null);
    try fr.append(raw[1..3]);
    try std.testing.expect(try fr.next() == null);
    try fr.append(raw[3..n]);
    const payload = (try fr.next()).?;
    try std.testing.expectEqualStrings("ping", payload);
    try std.testing.expect(try fr.next() == null);
}

test "frame rejects an oversized length and two frames back to back" {
    var fr = Framer{};
    var bad = [_]u8{ 0x80, 0x01 };
    try fr.append(&bad);
    try std.testing.expectError(error.BadFrame, fr.next());

    var fr2 = Framer{};
    var raw: [32]u8 = undefined;
    const a = try encode(&raw, "ab");
    const b = try encode(raw[a..], "cdef");
    try fr2.append(raw[0 .. a + b]);
    try std.testing.expectEqualStrings("ab", (try fr2.next()).?);
    try std.testing.expectEqualStrings("cdef", (try fr2.next()).?);
    try std.testing.expect(try fr2.next() == null);
}

test "encode refuses a payload past the cap" {
    var tiny: [4]u8 = undefined;
    try std.testing.expectError(error.NoSpace, encode(&tiny, "hello"));
    try std.testing.expectError(error.TooBig, encode(&tiny, &([_]u8{0} ** (max_payload + 1))));
}
