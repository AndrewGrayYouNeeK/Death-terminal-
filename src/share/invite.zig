//! Invite codes for a Shared Haunting.
//!
//! `dt1.` plus unpadded base64url. The payload carries the address the guest
//! dials, a 16-byte secret, and an optional relay. The Noise PSK is derived
//! from the secret; the relay only ever sees an id (the first 8 bytes of
//! SHA-256(secret)), not the secret itself.
//!
//! A code is also accepted as `deathterminal://join/<code>`.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const io = @import("../platform/io.zig");
const noise = @import("noise.zig");

pub const prefix = "dt1.";
pub const link_prefix = "deathterminal://join/";
pub const secret_len: usize = 16;
pub const max_host: usize = 63;
pub const max_relay: usize = 120;

pub const Invite = struct {
    host: []const u8,
    port: u16,
    secret: [secret_len]u8,
    relay: []const u8,

    pub fn psk(self: *const Invite) [32]u8 {
        return noise.pskFromSecret(&self.secret);
    }

    pub fn relayId(self: *const Invite) [8]u8 {
        var sum: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&self.secret, &sum, .{});
        return sum[0..8].*;
    }
};

pub const Error = error{
    BadInvite,
    NoSpace,
    OutOfMemory,
};

pub const Owned = struct {
    allocator: std.mem.Allocator,
    host: []u8,
    port: u16,
    secret: [secret_len]u8,
    relay: []u8,

    pub fn deinit(self: *Owned) void {
        self.allocator.free(self.host);
        self.allocator.free(self.relay);
        std.crypto.utils.secureZero(u8, &self.secret);
    }

    pub fn view(self: *const Owned) Invite {
        return .{ .host = self.host, .port = self.port, .secret = self.secret, .relay = self.relay };
    }
};

pub fn randomSecret() [secret_len]u8 {
    var s: [secret_len]u8 = undefined;
    std.crypto.random.bytes(&s);
    return s;
}

/// Best-effort IPv4 of the interface that would reach the LAN. Falls back
/// to loopback when the host has no route. This does not punch NAT.
pub fn detectLanHost(buf: []u8) []const u8 {
    const fallback = "127.0.0.1";
    io.ensureSockets();
    const flags: u32 = posix.SOCK.DGRAM | if (builtin.os.tag == .windows) 0 else posix.SOCK.CLOEXEC;
    const fd = posix.socket(posix.AF.INET, flags, 0) catch return fallback;
    defer {
        if (builtin.os.tag == .windows) {
            _ = std.os.windows.ws2_32.closesocket(fd);
        } else posix.close(fd);
    }
    const dest = std.net.Address.parseIp("192.0.2.1", 9) catch return fallback;
    posix.connect(fd, &dest.any, dest.getOsSockLen()) catch return fallback;
    var addr: std.net.Address = undefined;
    var len: posix.socklen_t = dest.getOsSockLen();
    posix.getsockname(fd, &addr.any, &len) catch return fallback;
    if (addr.any.family != posix.AF.INET) return fallback;
    const bytes = std.mem.asBytes(&addr.in.sa.addr);
    if (bytes[0] == 0 and bytes[1] == 0 and bytes[2] == 0 and bytes[3] == 0) return fallback;
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ bytes[0], bytes[1], bytes[2], bytes[3] }) catch fallback;
}

pub fn encode(dst: []u8, inv: Invite) Error![]u8 {
    if (inv.host.len == 0 or inv.host.len > max_host) return error.BadInvite;
    if (inv.relay.len > max_relay) return error.BadInvite;
    var raw: [1 + 2 + 1 + max_host + secret_len + 1 + max_relay]u8 = undefined;
    var n: usize = 0;
    raw[n] = 1;
    n += 1;
    std.mem.writeInt(u16, raw[n..][0..2], inv.port, .big);
    n += 2;
    raw[n] = @intCast(inv.host.len);
    n += 1;
    @memcpy(raw[n..][0..inv.host.len], inv.host);
    n += inv.host.len;
    @memcpy(raw[n..][0..secret_len], &inv.secret);
    n += secret_len;
    raw[n] = @intCast(inv.relay.len);
    n += 1;
    @memcpy(raw[n..][0..inv.relay.len], inv.relay);
    n += inv.relay.len;

    if (dst.len < prefix.len) return error.NoSpace;
    @memcpy(dst[0..prefix.len], prefix);
    const enc = std.base64.url_safe_no_pad.Encoder;
    const need = enc.calcSize(n);
    if (dst.len < prefix.len + need) return error.NoSpace;
    _ = enc.encode(dst[prefix.len..][0..need], raw[0..n]);
    return dst[0 .. prefix.len + need];
}

pub fn encodeAlloc(allocator: std.mem.Allocator, inv: Invite) Error![]u8 {
    var buf: [512]u8 = undefined;
    const code = try encode(&buf, inv);
    return allocator.dupe(u8, code) catch return error.OutOfMemory;
}

fn strip(text: []const u8) []const u8 {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.startsWith(u8, t, link_prefix)) return t[link_prefix.len..];
    return t;
}

pub fn decodeOwned(allocator: std.mem.Allocator, text: []const u8) Error!Owned {
    const code = strip(text);
    if (!std.mem.startsWith(u8, code, prefix)) return error.BadInvite;
    const b64 = code[prefix.len..];
    const dec = std.base64.url_safe_no_pad.Decoder;
    const size = dec.calcSizeForSlice(b64) catch return error.BadInvite;
    if (size > 1 + 2 + 1 + max_host + secret_len + 1 + max_relay) return error.BadInvite;
    var raw: [1 + 2 + 1 + max_host + secret_len + 1 + max_relay]u8 = undefined;
    dec.decode(raw[0..size], b64) catch return error.BadInvite;
    if (size < 1 + 2 + 1 + secret_len + 1 or raw[0] != 1) return error.BadInvite;
    var i: usize = 1;
    const port = std.mem.readInt(u16, raw[i..][0..2], .big);
    i += 2;
    const host_len = raw[i];
    i += 1;
    if (host_len == 0 or i + host_len + secret_len + 1 > size) return error.BadInvite;
    const host = allocator.dupe(u8, raw[i..][0..host_len]) catch return error.OutOfMemory;
    errdefer allocator.free(host);
    i += host_len;
    var secret: [secret_len]u8 = undefined;
    @memcpy(&secret, raw[i..][0..secret_len]);
    i += secret_len;
    const relay_len = raw[i];
    i += 1;
    if (i + relay_len != size) return error.BadInvite;
    const relay = allocator.dupe(u8, raw[i..][0..relay_len]) catch return error.OutOfMemory;
    return .{ .allocator = allocator, .host = host, .port = port, .secret = secret, .relay = relay };
}

/// `tcp://host:port` or `host:port`.
pub fn parseRelay(text: []const u8) error{BadRelay}!struct { host: []const u8, port: u16 } {
    const rest = if (std.mem.startsWith(u8, text, "tcp://")) text["tcp://".len..] else text;
    const colon = std.mem.lastIndexOfScalar(u8, rest, ':') orelse return error.BadRelay;
    if (colon == 0 or colon + 1 >= rest.len) return error.BadRelay;
    const port = std.fmt.parseInt(u16, rest[colon + 1 ..], 10) catch return error.BadRelay;
    if (port == 0) return error.BadRelay;
    return .{ .host = rest[0..colon], .port = port };
}

test "invite roundtrip including a link and a relay" {
    const secret = [_]u8{0xAB} ** secret_len;
    var buf: [400]u8 = undefined;
    const code = try encode(&buf, .{
        .host = "192.168.1.20",
        .port = 9753,
        .secret = secret,
        .relay = "tcp://10.0.0.8:9754",
    });
    var owned = try decodeOwned(std.testing.allocator, code);
    defer owned.deinit();
    try std.testing.expectEqualStrings("192.168.1.20", owned.host);
    try std.testing.expectEqual(@as(u16, 9753), owned.port);
    try std.testing.expectEqualStrings("tcp://10.0.0.8:9754", owned.relay);
    try std.testing.expect(std.mem.eql(u8, &secret, &owned.secret));

    var link_buf: [480]u8 = undefined;
    const link = try std.fmt.bufPrint(&link_buf, "{s}{s}", .{ link_prefix, code });
    var owned2 = try decodeOwned(std.testing.allocator, link);
    defer owned2.deinit();
    try std.testing.expectEqual(@as(u16, 9753), owned2.port);

    const view = owned.view();
    const id1 = view.relayId();
    var flipped = secret;
    flipped[3] ^= 1;
    const other = Invite{ .host = "h", .port = 1, .secret = flipped, .relay = "" };
    try std.testing.expect(!std.mem.eql(u8, &id1, &other.relayId()));
    try std.testing.expect(!std.mem.eql(u8, &view.psk(), &other.psk()));
}

test "bad invites are rejected" {
    try std.testing.expectError(error.BadInvite, decodeOwned(std.testing.allocator, "nope"));
    try std.testing.expectError(error.BadInvite, decodeOwned(std.testing.allocator, "dt1.!!!!"));
    try std.testing.expectError(error.BadRelay, parseRelay(""));
    const ok = try parseRelay("tcp://relay.example:9754");
    try std.testing.expectEqualStrings("relay.example", ok.host);
    try std.testing.expectEqual(@as(u16, 9754), ok.port);
}
