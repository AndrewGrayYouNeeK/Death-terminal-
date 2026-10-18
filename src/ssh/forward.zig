//! Port-forward specs in OpenSSH syntax:
//!
//!   "L [bind:]port:host:hostport"   local  (-L): listen here, connect there
//!   "R [bind:]port:host:hostport"   remote (-R): listen there, connect here
//!   "D [bind:]port"                 dynamic (-D): SOCKS4/5 proxy here
//!
//! The leading letter may also be written "-L", "local", "remote" or
//! "dynamic". IPv6 addresses go in brackets: "L [::1]:8080:[::1]:80".

const std = @import("std");

pub const Kind = enum {
    local,
    remote,
    dynamic,

    pub fn letter(self: Kind) u8 {
        return switch (self) {
            .local => 'L',
            .remote => 'R',
            .dynamic => 'D',
        };
    }
};

pub const Forward = struct {
    kind: Kind,
    /// Address to listen on ("" = loopback; for -R the server decides,
    /// usually loopback unless GatewayPorts allows more).
    bind_host: []const u8 = "",
    bind_port: u16,
    /// Destination (empty for dynamic).
    host: []const u8 = "",
    port: u16 = 0,
    enabled: bool = true,

    /// "L 8080:localhost:80" (or with the bind address when set).
    pub fn toText(self: Forward, buf: []u8) []const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();
        w.print("{c} ", .{self.kind.letter()}) catch return buf[0..0];
        if (self.bind_host.len > 0) writeHost(w, self.bind_host) catch {};
        if (self.bind_host.len > 0) w.writeByte(':') catch {};
        w.print("{d}", .{self.bind_port}) catch {};
        if (self.kind != .dynamic) {
            w.writeByte(':') catch {};
            writeHost(w, self.host) catch {};
            w.print(":{d}", .{self.port}) catch {};
        }
        return fbs.getWritten();
    }

    /// Copies the strings into `allocator`.
    pub fn dupe(self: Forward, allocator: std.mem.Allocator) !Forward {
        var f = self;
        f.bind_host = try allocator.dupe(u8, self.bind_host);
        f.host = try allocator.dupe(u8, self.host);
        return f;
    }
};

fn writeHost(w: anytype, host: []const u8) !void {
    if (std.mem.indexOfScalar(u8, host, ':') != null) {
        try w.print("[{s}]", .{host});
    } else try w.writeAll(host);
}

pub const ParseError = error{ BadKind, BadSpec, BadPort };

/// Parses a spec; the returned strings point into `spec`.
pub fn parse(spec_in: []const u8) ParseError!Forward {
    const spec = std.mem.trim(u8, spec_in, " \t");
    var it_end: usize = 0;
    while (it_end < spec.len and spec[it_end] != ' ' and spec[it_end] != '\t') it_end += 1;
    var word = spec[0..it_end];
    if (word.len > 0 and word[0] == '-') word = word[1..];
    const kind: Kind = if (std.ascii.eqlIgnoreCase(word, "l") or std.ascii.eqlIgnoreCase(word, "local"))
        .local
    else if (std.ascii.eqlIgnoreCase(word, "r") or std.ascii.eqlIgnoreCase(word, "remote"))
        .remote
    else if (std.ascii.eqlIgnoreCase(word, "d") or std.ascii.eqlIgnoreCase(word, "dynamic"))
        .dynamic
    else
        return error.BadKind;
    const rest = std.mem.trim(u8, spec[it_end..], " \t");
    if (rest.len == 0) return error.BadSpec;

    var parts: [4][]const u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i <= rest.len) {
        if (n == parts.len) return error.BadSpec;
        if (i < rest.len and rest[i] == '[') {
            const close = std.mem.indexOfScalarPos(u8, rest, i, ']') orelse return error.BadSpec;
            parts[n] = rest[i + 1 .. close];
            n += 1;
            i = close + 1;
            if (i == rest.len) break;
            if (rest[i] != ':') return error.BadSpec;
            i += 1;
            continue;
        }
        const end = std.mem.indexOfScalarPos(u8, rest, i, ':') orelse rest.len;
        parts[n] = rest[i..end];
        n += 1;
        if (end == rest.len) break;
        i = end + 1;
    }

    var f = Forward{ .kind = kind, .bind_port = 0 };
    switch (kind) {
        .dynamic => switch (n) {
            1 => f.bind_port = try port(parts[0]),
            2 => {
                f.bind_host = parts[0];
                f.bind_port = try port(parts[1]);
            },
            else => return error.BadSpec,
        },
        else => {
            const base: usize = switch (n) {
                3 => 0,
                4 => 1,
                else => return error.BadSpec,
            };
            if (base == 1) f.bind_host = parts[0];
            f.bind_port = try portOrZero(parts[base], kind);
            f.host = parts[base + 1];
            if (f.host.len == 0) return error.BadSpec;
            f.port = try port(parts[base + 2]);
        },
    }
    if (std.mem.eql(u8, f.bind_host, "*")) f.bind_host = if (kind == .remote) "" else "0.0.0.0";
    return f;
}

fn port(s: []const u8) ParseError!u16 {
    const v = std.fmt.parseInt(u16, s, 10) catch return error.BadPort;
    if (v == 0) return error.BadPort;
    return v;
}

/// -R allows port 0 (the server picks one).
fn portOrZero(s: []const u8, kind: Kind) ParseError!u16 {
    if (kind == .remote and std.mem.eql(u8, s, "0")) return 0;
    return port(s);
}

pub fn errorText(err: ParseError) []const u8 {
    return switch (err) {
        error.BadKind => "expected \"L\", \"R\" or \"D\" first, like \"L 8080:localhost:80\" or \"D 1080\"",
        error.BadSpec => "expected \"L [bind:]port:host:hostport\", \"R [bind:]port:host:hostport\" or \"D [bind:]port\"",
        error.BadPort => "ports must be 1-65535",
    };
}

// ------------------------------------------------------------------- SOCKS

/// Incremental SOCKS4/4a/5 server-side request parser (CONNECT only, no
/// authentication), used by dynamic forwards.
pub const Socks = struct {
    stage: enum { start, v5_request } = .start,
    version: u8 = 0,
    host_buf: [256]u8 = undefined,

    pub const Result = union(enum) {
        /// Not enough bytes yet.
        need_more,
        /// Send `reply`, drop `consumed` bytes, keep feeding.
        reply: struct { consumed: usize, bytes: []const u8 },
        /// Open a channel to host:port; then send `successReply`.
        connect: struct { consumed: usize, host: []const u8, port: u16 },
        /// Send `bytes` (may be empty) and close.
        fail: []const u8,
    };

    const v5_ok_method = [_]u8{ 5, 0 };
    const v5_no_method = [_]u8{ 5, 0xFF };
    const v5_cmd_unsupported = [_]u8{ 5, 7, 0, 1, 0, 0, 0, 0, 0, 0 };
    const v5_atyp_unsupported = [_]u8{ 5, 8, 0, 1, 0, 0, 0, 0, 0, 0 };
    const v4_rejected = [_]u8{ 0, 91, 0, 0, 0, 0, 0, 0 };

    pub fn feed(self: *Socks, buf: []const u8) Result {
        if (buf.len == 0) return .need_more;
        switch (self.stage) {
            .start => {
                self.version = buf[0];
                if (buf[0] == 5) {
                    if (buf.len < 2) return .need_more;
                    const n = buf[1];
                    if (buf.len < 2 + @as(usize, n)) return .need_more;
                    const has_noauth = std.mem.indexOfScalar(u8, buf[2 .. 2 + n], 0) != null;
                    if (!has_noauth) return .{ .fail = &v5_no_method };
                    self.stage = .v5_request;
                    return .{ .reply = .{ .consumed = 2 + n, .bytes = &v5_ok_method } };
                }
                if (buf[0] == 4) return self.feed4(buf);
                return .{ .fail = "" };
            },
            .v5_request => {
                if (buf.len < 5) return .need_more;
                if (buf[0] != 5) return .{ .fail = "" };
                if (buf[1] != 1) return .{ .fail = &v5_cmd_unsupported };
                var host: []const u8 = undefined;
                var at: usize = 4;
                switch (buf[3]) {
                    1 => {
                        if (buf.len < 10) return .need_more;
                        host = std.fmt.bufPrint(&self.host_buf, "{d}.{d}.{d}.{d}", .{ buf[4], buf[5], buf[6], buf[7] }) catch unreachable;
                        at = 8;
                    },
                    3 => {
                        const n = buf[4];
                        if (buf.len < 5 + @as(usize, n) + 2) return .need_more;
                        if (n == 0) return .{ .fail = &v5_atyp_unsupported };
                        @memcpy(self.host_buf[0..n], buf[5 .. 5 + n]);
                        host = self.host_buf[0..n];
                        at = 5 + n;
                    },
                    4 => {
                        if (buf.len < 22) return .need_more;
                        var a: [16]u8 = undefined;
                        @memcpy(&a, buf[4..20]);
                        const addr = std.net.Ip6Address.init(a, 0, 0, 0);
                        var tmp: [64]u8 = undefined;
                        const s = std.fmt.bufPrint(&tmp, "{}", .{addr}) catch unreachable;
                        // "[addr]:0" → "addr"
                        const inner = s[1 .. std.mem.lastIndexOfScalar(u8, s, ']') orelse s.len];
                        @memcpy(self.host_buf[0..inner.len], inner);
                        host = self.host_buf[0..inner.len];
                        at = 20;
                    },
                    else => return .{ .fail = &v5_atyp_unsupported },
                }
                const p = std.mem.readInt(u16, buf[at..][0..2], .big);
                return .{ .connect = .{ .consumed = at + 2, .host = host, .port = p } };
            },
        }
    }

    fn feed4(self: *Socks, buf: []const u8) Result {
        if (buf.len < 9) return .need_more;
        if (buf[1] != 1) return .{ .fail = &v4_rejected };
        const p = std.mem.readInt(u16, buf[2..4], .big);
        const ip = buf[4..8];
        const user_end = std.mem.indexOfScalarPos(u8, buf, 8, 0) orelse return .need_more;
        // SOCKS4a: 0.0.0.x (x != 0) means a host name follows.
        if (ip[0] == 0 and ip[1] == 0 and ip[2] == 0 and ip[3] != 0) {
            const host_end = std.mem.indexOfScalarPos(u8, buf, user_end + 1, 0) orelse return .need_more;
            const name = buf[user_end + 1 .. host_end];
            if (name.len == 0 or name.len > self.host_buf.len) return .{ .fail = &v4_rejected };
            @memcpy(self.host_buf[0..name.len], name);
            return .{ .connect = .{ .consumed = host_end + 1, .host = self.host_buf[0..name.len], .port = p } };
        }
        const host = std.fmt.bufPrint(&self.host_buf, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] }) catch unreachable;
        return .{ .connect = .{ .consumed = user_end + 1, .host = host, .port = p } };
    }

    pub fn successReply(self: *const Socks) []const u8 {
        return if (self.version == 4) &[_]u8{ 0, 90, 0, 0, 0, 0, 0, 0 } else &[_]u8{ 5, 0, 0, 1, 0, 0, 0, 0, 0, 0 };
    }

    pub fn failureReply(self: *const Socks) []const u8 {
        return if (self.version == 4) &v4_rejected else &[_]u8{ 5, 5, 0, 1, 0, 0, 0, 0, 0, 0 };
    }
};

// ------------------------------------------------------------------- tests

const t = std.testing;

test "forward specs parse in OpenSSH syntax" {
    const l = try parse("L 8080:localhost:80");
    try t.expectEqual(Kind.local, l.kind);
    try t.expectEqual(@as(u16, 8080), l.bind_port);
    try t.expectEqualStrings("localhost", l.host);
    try t.expectEqual(@as(u16, 80), l.port);
    try t.expectEqualStrings("", l.bind_host);

    const r = try parse("-R 0.0.0.0:9000:127.0.0.1:3000");
    try t.expectEqual(Kind.remote, r.kind);
    try t.expectEqualStrings("0.0.0.0", r.bind_host);
    try t.expectEqual(@as(u16, 9000), r.bind_port);
    try t.expectEqual(@as(u16, 3000), r.port);

    const d = try parse("dynamic 1080");
    try t.expectEqual(Kind.dynamic, d.kind);
    try t.expectEqual(@as(u16, 1080), d.bind_port);
    const d2 = try parse("D 127.0.0.1:1080");
    try t.expectEqualStrings("127.0.0.1", d2.bind_host);

    const v6 = try parse("L [::1]:8080:[fe80::1]:80");
    try t.expectEqualStrings("::1", v6.bind_host);
    try t.expectEqualStrings("fe80::1", v6.host);
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("L [::1]:8080:[fe80::1]:80", v6.toText(&buf));
    try t.expectEqualStrings("L 8080:localhost:80", l.toText(&buf));
    try t.expectEqualStrings("D 1080", d.toText(&buf));
    try t.expectEqual(@as(u16, 0), (try parse("R 0:localhost:22")).bind_port);

    try t.expectError(error.BadKind, parse("X 1:2:3"));
    try t.expectError(error.BadSpec, parse("L 8080:localhost"));
    try t.expectError(error.BadPort, parse("L 99999:localhost:80"));
    try t.expectError(error.BadPort, parse("D 0"));
    try t.expectError(error.BadSpec, parse("L"));
}

test "socks5 greeting, domain and IPv4 CONNECT" {
    var s = Socks{};
    try t.expect(s.feed(&.{5}) == .need_more);
    const g = s.feed(&.{ 5, 2, 0, 2 });
    try t.expectEqual(@as(usize, 4), g.reply.consumed);
    try t.expectEqualSlices(u8, &.{ 5, 0 }, g.reply.bytes);
    const req = [_]u8{ 5, 1, 0, 3, 9 } ++ "localhost".* ++ [_]u8{ 0x1F, 0x90 };
    try t.expect(s.feed(req[0..8]) == .need_more);
    const c = s.feed(&req);
    try t.expectEqualStrings("localhost", c.connect.host);
    try t.expectEqual(@as(u16, 8080), c.connect.port);
    try t.expectEqual(req.len, c.connect.consumed);
    try t.expectEqual(@as(u8, 5), s.successReply()[0]);

    var s2 = Socks{ .stage = .v5_request };
    const c2 = s2.feed(&.{ 5, 1, 0, 1, 10, 0, 0, 7, 0, 22 });
    try t.expectEqualStrings("10.0.0.7", c2.connect.host);
    try t.expectEqual(@as(u16, 22), c2.connect.port);
    var s3 = Socks{ .stage = .v5_request };
    try t.expect(s3.feed(&.{ 5, 2, 0, 1, 0, 0, 0, 0, 0, 0 }) == .fail);
    var s4 = Socks{};
    try t.expectEqualSlices(u8, &.{ 5, 0xFF }, s4.feed(&.{ 5, 1, 2 }).fail);
}

test "socks4 and 4a CONNECT" {
    var s = Socks{};
    const r = s.feed(&[_]u8{ 4, 1, 0, 80, 127, 0, 0, 1, 'u', 0 });
    try t.expectEqualStrings("127.0.0.1", r.connect.host);
    try t.expectEqual(@as(u16, 80), r.connect.port);
    try t.expectEqual(@as(usize, 10), r.connect.consumed);
    var a = Socks{};
    const req = [_]u8{ 4, 1, 1, 187, 0, 0, 0, 1, 0 } ++ "example.org".* ++ [_]u8{0};
    try t.expect(a.feed(req[0 .. req.len - 1]) == .need_more);
    const r2 = a.feed(&req);
    try t.expectEqualStrings("example.org", r2.connect.host);
    try t.expectEqual(@as(u16, 443), r2.connect.port);
    try t.expectEqualSlices(u8, &.{ 0, 90 }, a.successReply()[0..2]);
}
