//! Host-key verification against an OpenSSH known_hosts file.
//!
//! Hosts on port 22 are looked up as "host", others as "[host]:port"
//! (exactly; unlike libssh2's checkp there is no fallback from one to the
//! other, matching OpenSSH). The file is read line by line so a line
//! libssh2 cannot parse (e.g. @cert-authority, sk-* keys) is skipped
//! instead of hiding everything after it. Accepted keys are appended; the
//! file is never rewritten.

const std = @import("std");
const c = @import("c.zig").c;

pub const KeyType = struct {
    name: []const u8,
    mask: c_int,
    /// Host-key algorithms that produce this key type.
    methods: []const u8,
};

const key_types = [_]struct { c_int, KeyType }{
    .{ c.LIBSSH2_HOSTKEY_TYPE_ED25519, .{ .name = "ED25519", .mask = c.LIBSSH2_KNOWNHOST_KEY_ED25519, .methods = "ssh-ed25519" } },
    .{ c.LIBSSH2_HOSTKEY_TYPE_ECDSA_256, .{ .name = "ECDSA", .mask = c.LIBSSH2_KNOWNHOST_KEY_ECDSA_256, .methods = "ecdsa-sha2-nistp256" } },
    .{ c.LIBSSH2_HOSTKEY_TYPE_ECDSA_384, .{ .name = "ECDSA", .mask = c.LIBSSH2_KNOWNHOST_KEY_ECDSA_384, .methods = "ecdsa-sha2-nistp384" } },
    .{ c.LIBSSH2_HOSTKEY_TYPE_ECDSA_521, .{ .name = "ECDSA", .mask = c.LIBSSH2_KNOWNHOST_KEY_ECDSA_521, .methods = "ecdsa-sha2-nistp521" } },
    .{ c.LIBSSH2_HOSTKEY_TYPE_RSA, .{ .name = "RSA", .mask = c.LIBSSH2_KNOWNHOST_KEY_SSHRSA, .methods = "rsa-sha2-512,rsa-sha2-256,ssh-rsa" } },
};

pub fn keyType(hostkey_type: c_int) ?KeyType {
    for (key_types) |k| if (k[0] == hostkey_type) return k[1];
    return null;
}

pub const Check = enum { match, not_found, mismatch, failure };

/// "host" for port 22, else "[host]:port".
pub fn hostName(buf: []u8, host: []const u8, port: u16) [:0]const u8 {
    return (if (port == 22)
        std.fmt.bufPrintZ(buf, "{s}", .{host})
    else
        std.fmt.bufPrintZ(buf, "[{s}]:{d}", .{ host, port })) catch buf[0..0 :0];
}

/// "SHA256:<base64>" as OpenSSH prints it.
pub fn fingerprint(buf: []u8, key: []const u8) []const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(key, &digest, .{});
    const enc = std.base64.standard_no_pad.Encoder;
    @memcpy(buf[0..7], "SHA256:");
    return buf[0 .. 7 + enc.encode(buf[7..], &digest).len];
}

pub const KnownHosts = struct {
    hosts: *c.LIBSSH2_KNOWNHOSTS,
    path: []const u8,
    /// Lines libssh2 could not parse (skipped).
    skipped: usize = 0,
    /// Base64 keys from @revoked lines.
    revoked: [16][]const u8 = undefined,
    revoked_len: usize = 0,

    pub fn open(session: *c.LIBSSH2_SESSION, path: []const u8) !KnownHosts {
        const hosts = c.libssh2_knownhost_init(session) orelse return error.OutOfMemory;
        var kh = KnownHosts{ .hosts = hosts, .path = path };
        const data = std.fs.cwd().readFileAlloc(std.heap.page_allocator, path, 16 << 20) catch |err| switch (err) {
            error.FileNotFound => return kh,
            else => return kh,
        };
        defer std.heap.page_allocator.free(data);
        var it = std.mem.splitScalar(u8, data, '\n');
        // libssh2 scans to a NUL, not to `len`: hand it one line at a time.
        var lb: [8192]u8 = undefined;
        while (it.next()) |raw| {
            var line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '@') {
                // "@revoked <hosts> <type> <key>": refuse that key for any
                // host. @cert-authority needs certificate support: skipped.
                if (std.mem.startsWith(u8, line, "@revoked ")) {
                    var w = std.mem.tokenizeAny(u8, line, " \t");
                    _ = w.next();
                    _ = w.next();
                    _ = w.next();
                    if (w.next()) |key| if (kh.revoked_len < kh.revoked.len and key.len <= 1024) {
                        kh.revoked[kh.revoked_len] = std.heap.page_allocator.dupe(u8, key) catch continue;
                        kh.revoked_len += 1;
                    };
                }
                kh.skipped += 1;
                continue;
            }
            if (line.len >= lb.len) {
                kh.skipped += 1;
                continue;
            }
            @memcpy(lb[0..line.len], line);
            lb[line.len] = 0;
            line = lb[0..line.len];
            if (c.libssh2_knownhost_readline(hosts, line.ptr, line.len, c.LIBSSH2_KNOWNHOST_FILE_OPENSSH) != 0) kh.skipped += 1;
        }
        return kh;
    }

    pub fn deinit(self: *KnownHosts) void {
        for (self.revoked[0..self.revoked_len]) |k| std.heap.page_allocator.free(k);
        c.libssh2_knownhost_free(self.hosts);
    }

    pub fn isRevoked(self: *const KnownHosts, key: []const u8) bool {
        var b: [1400]u8 = undefined;
        if (std.base64.standard.Encoder.calcSize(key.len) > b.len) return false;
        const enc = std.base64.standard.Encoder.encode(&b, key);
        for (self.revoked[0..self.revoked_len]) |r| if (std.mem.eql(u8, r, enc)) return true;
        return false;
    }

    pub fn check(self: *KnownHosts, host: []const u8, port: u16, key: []const u8, kt: KeyType) Check {
        var nb: [300]u8 = undefined;
        const name = hostName(&nb, host, port);
        const mask = c.LIBSSH2_KNOWNHOST_TYPE_PLAIN | c.LIBSSH2_KNOWNHOST_KEYENC_RAW | kt.mask;
        const rc = c.libssh2_knownhost_checkp(self.hosts, name.ptr, -1, key.ptr, key.len, mask, null);
        return switch (rc) {
            c.LIBSSH2_KNOWNHOST_CHECK_MATCH => .match,
            c.LIBSSH2_KNOWNHOST_CHECK_MISMATCH => .mismatch,
            c.LIBSSH2_KNOWNHOST_CHECK_NOTFOUND => .not_found,
            else => .failure,
        };
    }

    /// Host-key algorithms to offer, those already recorded for this host
    /// first (so a host known by its ECDSA key isn't asked for ED25519).
    pub fn methodPref(self: *KnownHosts, buf: []u8, host: []const u8, port: u16) []const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();
        var known: [key_types.len]bool = undefined;
        const dummy = "\x00";
        for (key_types, 0..) |k, i| known[i] = self.check(host, port, dummy, k[1]) == .mismatch;
        var first = true;
        for ([_]bool{ true, false }) |want| for (key_types, 0..) |k, i| {
            if (known[i] != want) continue;
            if (!first) w.writeByte(',') catch {};
            w.writeAll(k[1].methods) catch {};
            first = false;
        };
        return fbs.getWritten();
    }

    /// Records the key and appends it to the file (mode 0600, directory 0700).
    pub fn add(self: *KnownHosts, host: []const u8, port: u16, key: []const u8, kt: KeyType) !void {
        var nb: [300]u8 = undefined;
        const name = hostName(&nb, host, port);
        const mask = c.LIBSSH2_KNOWNHOST_TYPE_PLAIN | c.LIBSSH2_KNOWNHOST_KEYENC_RAW | kt.mask;
        var node: ?*c.libssh2_knownhost = null;
        if (c.libssh2_knownhost_addc(self.hosts, name.ptr, null, key.ptr, key.len, null, 0, mask, &node) != 0) return error.AddFailed;
        var line: [4096]u8 = undefined;
        var len: usize = 0;
        if (c.libssh2_knownhost_writeline(self.hosts, node, &line, line.len, &len, c.LIBSSH2_KNOWNHOST_FILE_OPENSSH) != 0) return error.AddFailed;
        if (std.fs.path.dirname(self.path)) |dir| {
            // A new ~/.ssh is private, like OpenSSH makes it.
            std.posix.mkdir(dir, 0o700) catch |err| if (err != error.PathAlreadyExists) {
                std.fs.cwd().makePath(dir) catch {};
            };
        }
        var f = try std.fs.cwd().createFile(self.path, .{ .truncate = false, .read = true, .mode = 0o600 });
        defer f.close();
        const end = try f.getEndPos();
        try f.seekTo(end);
        if (end > 0) {
            var last: [1]u8 = undefined;
            _ = try f.preadAll(&last, end - 1);
            if (last[0] != '\n') try f.writeAll("\n");
        }
        try f.writeAll(line[0..len]);
    }
};

// ------------------------------------------------------------------- tests

const t = std.testing;

fn rawKey(buf: []u8, b64: []const u8) []const u8 {
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(b64) catch unreachable;
    dec.decode(buf[0..n], b64) catch unreachable;
    return buf[0..n];
}

test "known_hosts: match, mismatch, unknown, port-specific names, append" {
    try t.expectEqual(@as(c_int, 0), c.libssh2_init(0));
    const s = c.libssh2_session_init_ex(null, null, null, null).?;
    defer _ = c.libssh2_session_free(s);
    const ed = "AAAAC3NzaC1lZDI1NTE5AAAAIDCj7gAaYADVgfhak36afi4S3u87HOeMU5dxxvSvqvHh";
    const ec = "AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBDgtQ9z9VRbScUKlgaxYiZIkFedVsJv/LVKGmUYZJqXGwoCYfxTWcvQTXOtEnCK2bDKWhtvnbzOpurVyLjZRlI8=";
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "known_hosts", .data = "# comment\n@cert-authority *.example.com ssh-ed25519 " ++ ed ++ "\n" ++
        "@revoked * ecdsa-sha2-nistp256 " ++ ec ++ "\n" ++
        "[127.0.0.1]:2222 ssh-ed25519 " ++ ed ++ "\n" ++
        "box.lan ecdsa-sha2-nistp256 " ++ ec }); // no trailing newline
    const path = try @import("../testutil.zig").tmpPath(t.allocator, &tmp, "known_hosts");
    defer t.allocator.free(path);

    var kh = try KnownHosts.open(s, path);
    var b1: [128]u8 = undefined;
    var b2: [128]u8 = undefined;
    const ed_raw = rawKey(&b1, ed);
    const ec_raw = rawKey(&b2, ec);
    const ed_t = keyType(c.LIBSSH2_HOSTKEY_TYPE_ED25519).?;
    const ec_t = keyType(c.LIBSSH2_HOSTKEY_TYPE_ECDSA_256).?;
    try t.expectEqual(Check.match, kh.check("127.0.0.1", 2222, ed_raw, ed_t));
    // Same address, other port: unknown, not a mismatch.
    try t.expectEqual(Check.not_found, kh.check("127.0.0.1", 22, ed_raw, ed_t));
    try t.expectEqual(Check.not_found, kh.check("127.0.0.1", 2223, ed_raw, ed_t));
    var bad: [128]u8 = undefined;
    @memcpy(bad[0..ed_raw.len], ed_raw);
    bad[ed_raw.len - 1] ^= 1;
    try t.expectEqual(Check.mismatch, kh.check("127.0.0.1", 2222, bad[0..ed_raw.len], ed_t));
    try t.expectEqual(Check.match, kh.check("box.lan", 22, ec_raw, ec_t));
    try t.expect(kh.isRevoked(ec_raw) and !kh.isRevoked(ed_raw));
    try t.expectEqual(@as(usize, 2), kh.skipped);
    var pb: [256]u8 = undefined;
    try t.expect(std.mem.startsWith(u8, kh.methodPref(&pb, "box.lan", 22), "ecdsa-sha2-nistp256,ssh-ed25519"));
    try t.expect(std.mem.startsWith(u8, kh.methodPref(&pb, "new.host", 22), "ssh-ed25519,"));

    try kh.add("new.host", 2200, ed_raw, ed_t);
    kh.deinit();
    const text = try tmp.dir.readFileAlloc(t.allocator, "known_hosts", 1 << 16);
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, ec ++ "\n[new.host]:2200 ssh-ed25519 " ++ ed) != null);
    try t.expect(std.mem.startsWith(u8, text, "# comment\n@cert-authority")); // untouched
    var kh2 = try KnownHosts.open(s, path);
    defer kh2.deinit();
    try t.expectEqual(Check.match, kh2.check("new.host", 2200, ed_raw, ed_t));

    var fb: [64]u8 = undefined;
    // Same text as `ssh-keygen -lf`.
    try t.expectEqualStrings("SHA256:QRwT++NsGSwhTwOXMMNgp3hmLcueXZe8rCBetYM9Sls", fingerprint(&fb, ed_raw));
}
