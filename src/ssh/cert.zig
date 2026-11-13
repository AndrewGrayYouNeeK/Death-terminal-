//! OpenSSH host certificates (`ssh-ed25519-cert-v01@openssh.com`).
//!
//! `@cert-authority` lines name a CA public key. A host key blob is trusted
//! when it is a host certificate, the CA key matches one of those lines for
//! this host, the Ed25519 signature checks, the validity window contains
//! now, principals allow the host (empty means any), and there are no
//! critical options. Other certificate types are recognized and rejected:
//! they are not saved as ordinary host keys.

const std = @import("std");
const ssh_config = @import("ssh_config.zig");
const Ed25519 = std.crypto.sign.Ed25519;

pub const Kind = enum { not_cert, ed25519, other };

pub const Info = struct {
    kind: Kind,
    /// Wire encoding of the CA public key (the signature-key field).
    ca_key: []const u8 = &.{},
    /// Bytes covered by the signature (the certificate up to that field).
    signed_bytes: []const u8 = &.{},
    signature: [64]u8 = undefined,
    valid_after: u64 = 0,
    valid_before: u64 = 0,
    /// Packed principals (each an SSH string). Empty means any host.
    principals: []const u8 = &.{},
    critical_len: usize = 0,
};

pub const Verdict = enum { trusted, rejected, no_ca };

const ed_cert = "ssh-ed25519-cert-v01@openssh.com";
const ed_plain = "ssh-ed25519";

pub fn inspect(blob: []const u8) Info {
    var i: usize = 0;
    const kind_s = sshStr(blob, &i) orelse return .{ .kind = .not_cert };
    if (std.mem.indexOf(u8, kind_s, "-cert-") == null) return .{ .kind = .not_cert };
    if (!std.mem.eql(u8, kind_s, ed_cert)) return .{ .kind = .other };
    _ = sshStr(blob, &i) orelse return .{ .kind = .other }; // nonce
    _ = sshStr(blob, &i) orelse return .{ .kind = .other }; // pk
    _ = sshU64(blob, &i) orelse return .{ .kind = .other }; // serial
    _ = sshU32(blob, &i) orelse return .{ .kind = .other }; // cert type, checked below via re-read
    // Re-parse type: the cursor is past it. Walk again for the fields we keep.
    return parseEd25519(blob) orelse .{ .kind = .other };
}

fn parseEd25519(blob: []const u8) ?Info {
    var i: usize = 0;
    const kind_s = sshStr(blob, &i) orelse return null;
    if (!std.mem.eql(u8, kind_s, ed_cert)) return null;
    _ = sshStr(blob, &i) orelse return null;
    _ = sshStr(blob, &i) orelse return null;
    _ = sshU64(blob, &i) orelse return null;
    const ctype = sshU32(blob, &i) orelse return null;
    if (ctype != 2) return null; // host certificate
    _ = sshStr(blob, &i) orelse return null; // key id
    const principals = sshStr(blob, &i) orelse return null;
    const after = sshU64(blob, &i) orelse return null;
    const before = sshU64(blob, &i) orelse return null;
    const critical = sshStr(blob, &i) orelse return null;
    _ = sshStr(blob, &i) orelse return null; // extensions
    _ = sshStr(blob, &i) orelse return null; // reserved
    const ca_key = sshStr(blob, &i) orelse return null;
    const signed_end = i;
    const sig_blob = sshStr(blob, &i) orelse return null;
    if (i != blob.len) return null;
    var sj: usize = 0;
    const alg = sshStr(sig_blob, &sj) orelse return null;
    const sig = sshStr(sig_blob, &sj) orelse return null;
    if (!std.mem.eql(u8, alg, ed_plain) or sig.len != 64 or sj != sig_blob.len) return null;
    var info = Info{
        .kind = .ed25519,
        .ca_key = ca_key,
        .signed_bytes = blob[0..signed_end],
        .valid_after = after,
        .valid_before = before,
        .principals = principals,
        .critical_len = critical.len,
    };
    @memcpy(info.signature[0..64], sig);
    return info;
}

pub fn principalAllows(principals: []const u8, host: []const u8) bool {
    if (principals.len == 0) return true;
    var i: usize = 0;
    var any = false;
    while (i < principals.len) {
        const name = sshStr(principals, &i) orelse return false;
        any = true;
        if (std.mem.eql(u8, name, host)) return true;
    }
    return !any;
}

pub fn signatureOk(info: Info, now_sec: i64) bool {
    if (info.kind != .ed25519 or info.critical_len != 0) return false;
    if (now_sec < 0) return false;
    const now: u64 = @intCast(now_sec);
    if (now < info.valid_after or now > info.valid_before) return false;
    var j: usize = 0;
    const alg = sshStr(info.ca_key, &j) orelse return false;
    const pk = sshStr(info.ca_key, &j) orelse return false;
    if (!std.mem.eql(u8, alg, ed_plain) or pk.len != 32 or j != info.ca_key.len) return false;
    const key = Ed25519.PublicKey.fromBytes(pk[0..32].*) catch return false;
    const sig = Ed25519.Signature.fromBytes(info.signature);
    sig.verify(info.signed_bytes, key) catch return false;
    return true;
}

/// `cas` are wire public keys (the base64-decoded known_hosts key) whose
/// host pattern already matched.
pub fn trusted(info: Info, cas: []const []const u8, host: []const u8, now_sec: i64) bool {
    if (!signatureOk(info, now_sec) or !principalAllows(info.principals, host)) return false;
    for (cas) |ca| if (std.mem.eql(u8, ca, info.ca_key)) return true;
    return false;
}

fn sshU32(data: []const u8, i: *usize) ?u32 {
    if (i.* + 4 > data.len) return null;
    const n = std.mem.readInt(u32, data[i.*..][0..4], .big);
    i.* += 4;
    return n;
}

fn sshU64(data: []const u8, i: *usize) ?u64 {
    if (i.* + 8 > data.len) return null;
    const n = std.mem.readInt(u64, data[i.*..][0..8], .big);
    i.* += 8;
    return n;
}

fn sshStr(data: []const u8, i: *usize) ?[]const u8 {
    const n = sshU32(data, i) orelse return null;
    if (i.* + n > data.len) return null;
    const s = data[i.*..][0..n];
    i.* += n;
    return s;
}

pub fn putU32(w: anytype, n: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, n, .big);
    try w.writeAll(&b);
}

pub fn putU64(w: anytype, n: u64) !void {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, n, .big);
    try w.writeAll(&b);
}

pub fn putStr(w: anytype, s: []const u8) !void {
    try putU32(w, @intCast(s.len));
    try w.writeAll(s);
}

/// Host pattern from an `@cert-authority` line matches `host`.
pub fn hostPatternMatches(patterns: []const u8, host: []const u8) bool {
    return ssh_config.hostMatches(patterns, host);
}

// ------------------------------------------------------------------- tests

const t = std.testing;

fn caKey(buf: *std.ArrayList(u8), pk: [32]u8) !void {
    try putStr(buf.writer(), ed_plain);
    try putStr(buf.writer(), &pk);
}

fn buildCert(buf: *std.ArrayList(u8), host_pk: [32]u8, ca: []const u8, principals: []const u8, after: u64, before: u64, critical: []const u8) !void {
    try putStr(buf.writer(), ed_cert);
    try putStr(buf.writer(), "nonce-bytes-for-the-test!!");
    try putStr(buf.writer(), &host_pk);
    try putU64(buf.writer(), 1);
    try putU32(buf.writer(), 2);
    try putStr(buf.writer(), "test-host");
    try putStr(buf.writer(), principals);
    try putU64(buf.writer(), after);
    try putU64(buf.writer(), before);
    try putStr(buf.writer(), critical);
    try putStr(buf.writer(), "");
    try putStr(buf.writer(), "");
    try putStr(buf.writer(), ca);
}

test "ed25519 host certificate verifies for the named host only" {
    const host_seed = [_]u8{2} ** 32;
    const ca_seed = [_]u8{9} ** 32;
    const host_kp = try Ed25519.KeyPair.create(host_seed);
    const ca_kp = try Ed25519.KeyPair.create(ca_seed);
    var ca_buf = std.ArrayList(u8).init(t.allocator);
    defer ca_buf.deinit();
    try caKey(&ca_buf, ca_kp.public_key.bytes);

    var body = std.ArrayList(u8).init(t.allocator);
    defer body.deinit();
    var principals = std.ArrayList(u8).init(t.allocator);
    defer principals.deinit();
    try putStr(principals.writer(), "db.example.com");
    try buildCert(&body, host_kp.public_key.bytes, ca_buf.items, principals.items, 1, 4_000_000_000, "");
    const sig = try ca_kp.sign(body.items, null);
    var sig_blob = std.ArrayList(u8).init(t.allocator);
    defer sig_blob.deinit();
    try putStr(sig_blob.writer(), ed_plain);
    try putStr(sig_blob.writer(), &sig.toBytes());
    try putStr(body.writer(), sig_blob.items);

    const info = inspect(body.items);
    try t.expectEqual(Kind.ed25519, info.kind);
    const cas = [_][]const u8{ca_buf.items};
    try t.expect(trusted(info, &cas, "db.example.com", 1_700_000_000));
    try t.expect(!trusted(info, &cas, "other.example.com", 1_700_000_000));
    try t.expect(!trusted(info, &cas, "db.example.com", 0));

    body.items[body.items.len - 1] ^= 1;
    const bad = inspect(body.items);
    try t.expect(!trusted(bad, &cas, "db.example.com", 1_700_000_000));
}

test "a plain host key is not a certificate" {
    try t.expectEqual(Kind.not_cert, inspect("ssh-ed25519").kind);
    try t.expect(hostPatternMatches("*.example.com", "db.example.com"));
    try t.expect(!hostPatternMatches("*.example.com", "example.org"));
}
