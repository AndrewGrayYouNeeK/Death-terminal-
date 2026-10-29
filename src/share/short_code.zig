//! Six-character join codes. The host registers the invite on the workers.dev
//! relay (the custom domain answers an empty 404). The guest looks the code
//! up and then dials like a long `dt1` invite.
//!
//! Alphabet skips 0/O and 1/I. Spoken form is `K7Q-4MZ`. `K7Q4MZ` is the same
//! code. The mapping lives for about an hour and only a few lookups.

const std = @import("std");
const certs = @import("certs.zig");
const invite = @import("invite.zig");
const io = @import("../platform/io.zig");
const netdial = @import("../net/dial.zig");

pub const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
pub const len: usize = 6;

const lookup_host = "youneek-share-relay.youneekartifacts.workers.dev";

pub const Error = error{
    BadInvite,
    NotFound,
    RateLimited,
    Timeout,
    Tls,
    Closed,
    OutOfMemory,
    Unexpected,
};

pub fn randomCode() [len]u8 {
    var out: [len]u8 = undefined;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        var b: [1]u8 = undefined;
        std.crypto.random.bytes(&b);
        out[i] = alphabet[b[0] % alphabet.len];
    }
    return out;
}

/// `K7Q-4MZ` (the form shown on the banner and copied to the clipboard).
pub fn hyphen(code: *const [len]u8) [len + 1]u8 {
    var out: [len + 1]u8 = undefined;
    @memcpy(out[0..3], code[0..3]);
    out[3] = '-';
    @memcpy(out[4..7], code[3..6]);
    return out;
}

/// `K 7 Q - 4 M Z`, so the banner row reads larger than body text.
pub fn spaced(code: *const [len]u8, dst: []u8) usize {
    const shown = hyphen(code);
    var n: usize = 0;
    for (shown, 0..) |ch, i| {
        if (n >= dst.len) break;
        dst[n] = ch;
        n += 1;
        if (i + 1 != shown.len and n < dst.len) {
            dst[n] = ' ';
            n += 1;
        }
    }
    return n;
}

/// True when `text` is exactly one short code, ignoring case, spaces, and a hyphen.
pub fn normalize(dst: *[len]u8, text: []const u8) bool {
    var n: usize = 0;
    for (text) |ch| {
        if (ch == '-' or ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n') continue;
        if (n >= len) return false;
        const up = std.ascii.toUpper(ch);
        if (std.mem.indexOfScalar(u8, alphabet, up) == null) return false;
        dst[n] = up;
        n += 1;
    }
    return n == len;
}

/// Register `code`'s invite. 409 means try another code. null means give up.
pub fn register(host: []const u8, port: u16, secret: *const [invite.secret_len]u8, relay: []const u8) ?[len]u8 {
    var attempt: u8 = 0;
    while (attempt < 3) : (attempt += 1) {
        const code = randomCode();
        const status = put(&code, host, port, secret, relay) catch return null;
        if (status == 201) return code;
        if (status == 409) continue;
        return null;
    }
    return null;
}

/// Turn a short code into a long `dt1` invite. Other text is returned unchanged.
pub fn resolve(allocator: std.mem.Allocator, text: []const u8) Error![]u8 {
    var code: [len]u8 = undefined;
    if (!normalize(&code, text)) return allocator.dupe(u8, text) catch return error.OutOfMemory;
    const owned = try lookup(allocator, &code);
    defer {
        var tmp = owned;
        tmp.deinit();
    }
    return invite.encodeAlloc(allocator, owned.view()) catch |err| switch (err) {
        error.BadInvite => return error.BadInvite,
        error.NoSpace => return error.BadInvite,
        error.OutOfMemory => return error.OutOfMemory,
    };
}

fn lookup(allocator: std.mem.Allocator, code: *const [len]u8) Error!invite.Owned {
    var path: [32]u8 = undefined;
    const p = std.fmt.bufPrint(&path, "/v1/code/{s}", .{code}) catch return error.Unexpected;
    const body = get(allocator, p) catch |err| switch (err) {
        error.NotFound => return error.NotFound,
        error.RateLimited => return error.RateLimited,
        error.Timeout => return error.Timeout,
        error.Tls => return error.Tls,
        error.Closed => return error.Closed,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Unexpected,
    };
    defer allocator.free(body);
    return parseInvite(allocator, body);
}

fn put(code: *const [len]u8, host: []const u8, port: u16, secret: *const [invite.secret_len]u8, relay: []const u8) !u16 {
    var secret_hex: [invite.secret_len * 2]u8 = undefined;
    const hex = std.fmt.bufPrint(&secret_hex, "{}", .{std.fmt.fmtSliceHexLower(secret)}) catch return error.Unexpected;
    var body_buf: [512]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf, "{{\"host\":\"{s}\",\"port\":{d},\"secret\":\"{s}\",\"relay\":\"{s}\"}}", .{ host, port, hex, relay }) catch return error.Unexpected;
    var path: [32]u8 = undefined;
    const p = std.fmt.bufPrint(&path, "/v1/code/{s}", .{code}) catch return error.Unexpected;
    return httpsStatus("PUT", p, body);
}

fn get(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return httpsBody(allocator, "GET", path, "");
}

const HttpResult = struct {
    status: u16,
    body: []u8,
};

fn httpsStatus(method: []const u8, path: []const u8, body: []const u8) !u16 {
    const res = try https(std.heap.page_allocator, method, path, body);
    std.heap.page_allocator.free(res.body);
    return res.status;
}

fn httpsBody(allocator: std.mem.Allocator, method: []const u8, path: []const u8, body: []const u8) ![]u8 {
    const res = try https(allocator, method, path, body);
    errdefer allocator.free(res.body);
    if (res.status == 404) return error.NotFound;
    if (res.status == 429) return error.RateLimited;
    if (res.status != 200 and res.status != 201) return error.Closed;
    return res.body;
}

fn https(allocator: std.mem.Allocator, method: []const u8, path: []const u8, body: []const u8) !HttpResult {
    io.ensureSockets();
    io.ignoreSigpipe();
    const fd = netdial.connect(lookup_host, 443, 8000, null) catch |err| switch (err) {
        error.Timeout, error.Cancelled => return error.Timeout,
        else => return error.Closed,
    };
    var tcp = std.net.Stream{ .handle = fd };
    defer tcp.close();
    netdial.setSocketTimeout(fd, 8000);
    var bundle = std.crypto.Certificate.Bundle{};
    certs.scan(&bundle, allocator) catch return error.Tls;
    defer bundle.deinit(allocator);
    var tls = std.crypto.tls.Client.init(tcp, bundle, lookup_host) catch return error.Tls;
    tls.allow_truncation_attacks = true;
    netdial.setSocketTimeout(fd, 0);

    var req_buf: [640]u8 = undefined;
    const req = std.fmt.bufPrint(&req_buf, "{s} {s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: deathterminal\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ method, path, lookup_host, body.len, body }) catch return error.Unexpected;
    try writeAll(&tls, tcp, req);

    var raw: [4096]u8 = undefined;
    var n: usize = 0;
    while (n < raw.len) {
        const got = tls.read(tcp, raw[n..]) catch return error.Closed;
        if (got == 0) break;
        n += got;
        if (std.mem.indexOf(u8, raw[0..n], "\r\n\r\n") != null and contentReady(raw[0..n])) break;
    }
    const head_end = std.mem.indexOf(u8, raw[0..n], "\r\n\r\n") orelse return error.Closed;
    const status = parseStatus(raw[0..head_end]) orelse return error.Closed;
    const payload = raw[head_end + 4 .. n];
    const copy = allocator.dupe(u8, payload) catch return error.OutOfMemory;
    return .{ .status = status, .body = copy };
}

fn contentReady(raw: []const u8) bool {
    const head_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return false;
    const head = raw[0..head_end];
    const body = raw[head_end + 4 ..];
    var it = std.mem.splitSequence(u8, head, "\r\n");
    while (it.next()) |line| {
        if (!std.ascii.startsWithIgnoreCase(line, "content-length:")) continue;
        const num = std.mem.trim(u8, line["content-length:".len..], " \t");
        const want = std.fmt.parseInt(usize, num, 10) catch return true;
        return body.len >= want;
    }
    return body.len > 0;
}

fn parseStatus(head: []const u8) ?u16 {
    const line_end = std.mem.indexOf(u8, head, "\r\n") orelse head.len;
    const line = head[0..line_end];
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    _ = it.next() orelse return null;
    const code = it.next() orelse return null;
    return std.fmt.parseInt(u16, code, 10) catch null;
}

fn parseInvite(allocator: std.mem.Allocator, body: []const u8) Error!invite.Owned {
    const host = jsonString(body, "host") orelse return error.BadInvite;
    const relay = jsonString(body, "relay") orelse return error.BadInvite;
    const secret_hex = jsonString(body, "secret") orelse return error.BadInvite;
    const port = jsonInt(body, "port") orelse return error.BadInvite;
    if (host.len == 0 or host.len > invite.max_host or relay.len > invite.max_relay) return error.BadInvite;
    if (port < 1 or port > 65535 or secret_hex.len != invite.secret_len * 2) return error.BadInvite;
    var secret: [invite.secret_len]u8 = undefined;
    _ = std.fmt.hexToBytes(&secret, secret_hex) catch return error.BadInvite;
    const host_copy = allocator.dupe(u8, host) catch return error.OutOfMemory;
    errdefer allocator.free(host_copy);
    const relay_copy = allocator.dupe(u8, relay) catch return error.OutOfMemory;
    return .{
        .allocator = allocator,
        .host = host_copy,
        .port = @intCast(port),
        .secret = secret,
        .relay = relay_copy,
    };
}

fn jsonString(body: []const u8, key: []const u8) ?[]const u8 {
    var pat: [24]u8 = undefined;
    const p = std.fmt.bufPrint(&pat, "\"{s}\":\"", .{key}) catch return null;
    const at = std.mem.indexOf(u8, body, p) orelse return null;
    const rest = body[at + p.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..end];
}

fn jsonInt(body: []const u8, key: []const u8) ?u32 {
    var pat: [24]u8 = undefined;
    const p = std.fmt.bufPrint(&pat, "\"{s}\":", .{key}) catch return null;
    const at = std.mem.indexOf(u8, body, p) orelse return null;
    const rest = body[at + p.len ..];
    var n: usize = 0;
    while (n < rest.len and rest[n] >= '0' and rest[n] <= '9') n += 1;
    if (n == 0) return null;
    return std.fmt.parseInt(u32, rest[0..n], 10) catch null;
}

fn writeAll(tls: *std.crypto.tls.Client, tcp: std.net.Stream, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        const n = tls.write(tcp, data[off..]) catch return error.Closed;
        if (n == 0) return error.Closed;
        off += n;
    }
}

test "short code: hyphen, spaces, and case" {
    const code = "K7Q4MZ".*;
    try std.testing.expectEqualStrings("K7Q-4MZ", &hyphen(&code));
    var got: [len]u8 = undefined;
    try std.testing.expect(normalize(&got, "k7q-4mz"));
    try std.testing.expectEqualStrings(&code, &got);
    try std.testing.expect(normalize(&got, "  K7Q 4MZ "));
    try std.testing.expect(!normalize(&got, "K7Q-4M0"));
    try std.testing.expect(!normalize(&got, "dt1.abc"));
    try std.testing.expect(!normalize(&got, "K7Q4M"));
    var wide: [16]u8 = undefined;
    const n = spaced(&code, &wide);
    try std.testing.expectEqualStrings("K 7 Q - 4 M Z", wide[0..n]);
}

test "short code: json invite" {
    const body =
        \\{"host":"192.168.1.9","port":4242,"secret":"00112233445566778899aabbccddeeff","relay":"wss://relay.youneek.xyz"}
    ;
    var owned = try parseInvite(std.testing.allocator, body);
    defer owned.deinit();
    try std.testing.expectEqualStrings("192.168.1.9", owned.host);
    try std.testing.expectEqual(@as(u16, 4242), owned.port);
    try std.testing.expectEqual(@as(u8, 0x00), owned.secret[0]);
    try std.testing.expectEqual(@as(u8, 0xff), owned.secret[15]);
    try std.testing.expectEqualStrings("wss://relay.youneek.xyz", owned.relay);
    const code = try invite.encodeAlloc(std.testing.allocator, owned.view());
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.startsWith(u8, code, "dt1."));
}
