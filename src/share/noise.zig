//! Noise_NNpsk0_25519_ChaChaPoly_SHA256, the Shared Haunting handshake.
//!
//! Both sides already know the invite secret. It is mixed as a pre-shared
//! key (`psk0`) before the ephemeral exchange, so a connection that does not
//! have the invite cannot complete the handshake or read later frames.
//!
//! Pattern (Noise spec, psk0 placement):
//!
//!   -> psk, e
//!   <- e, ee
//!
//! `e` public keys travel in the clear. Because a PSK is already mixed, each
//! `e` also calls MixKey on that public key. Handshake payloads (a version
//! byte) are encrypted with ChaCha20-Poly1305. Transport keys come from
//! Split(); the initiator's sending key is the responder's receiving key.

const std = @import("std");

const X25519 = std.crypto.dh.X25519;
const ChaCha20Poly1305 = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
const Sha256 = std.crypto.hash.sha2.Sha256;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

pub const protocol_name = "Noise_NNpsk0_25519_ChaChaPoly_SHA256";
pub const prologue = "dt-share-v1";
pub const version: u8 = 1;
pub const handshake_len: usize = 32 + 1 + ChaCha20Poly1305.tag_length;

pub const Error = error{Handshake};

pub const Role = enum { initiator, responder };

const Derived = struct { o1: [32]u8, o2: [32]u8, o3: [32]u8 };

/// Noise HKDF: HMAC-SHA256, two or three outputs (spec section 4.3).
fn hkdf(ck: *const [32]u8, ikm: []const u8, outputs: u2) Derived {
    var temp: [32]u8 = undefined;
    HmacSha256.create(&temp, ikm, ck);
    var o1: [32]u8 = undefined;
    HmacSha256.create(&o1, &[_]u8{0x01}, &temp);
    var second = [_]u8{0} ** 33;
    @memcpy(second[0..32], &o1);
    second[32] = 0x02;
    var o2: [32]u8 = undefined;
    HmacSha256.create(&o2, second[0..33], &temp);
    var o3: [32]u8 = [_]u8{0} ** 32;
    if (outputs == 3) {
        var third = [_]u8{0} ** 33;
        @memcpy(third[0..32], &o2);
        third[32] = 0x03;
        HmacSha256.create(&o3, third[0..33], &temp);
        std.crypto.utils.secureZero(u8, &third);
    }
    std.crypto.utils.secureZero(u8, &temp);
    std.crypto.utils.secureZero(u8, &second);
    return .{ .o1 = o1, .o2 = o2, .o3 = o3 };
}

fn mixHash(h: *[32]u8, data: []const u8) void {
    var st = Sha256.init(.{});
    st.update(h);
    st.update(data);
    st.final(h);
}

fn nonce(n: u64) [12]u8 {
    var npub = [_]u8{0} ** 12;
    std.mem.writeInt(u64, npub[4..12], n, .little);
    return npub;
}

fn ephemeral() Error!X25519.KeyPair {
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        if (X25519.KeyPair.create(null)) |kp| return kp else |_| {}
    }
    return error.Handshake;
}

pub const Handshake = struct {
    role: Role,
    h: [32]u8,
    ck: [32]u8,
    k: [32]u8 = [_]u8{0} ** 32,
    n: u64 = 0,
    has_k: bool = false,
    e_secret: [32]u8 = [_]u8{0} ** 32,
    re: [32]u8 = [_]u8{0} ** 32,
    /// Invite PSK, mixed as the `psk` token of the first message, then wiped.
    pending_psk: [32]u8 = [_]u8{0} ** 32,
    psk_mixed: bool = false,
    step: u2 = 0,

    pub fn init(role: Role, psk: *const [32]u8) Handshake {
        var h: [32]u8 = undefined;
        Sha256.hash(protocol_name, &h, .{});
        var self = Handshake{ .role = role, .h = h, .ck = h };
        mixHash(&self.h, prologue);
        // psk0 is the first token of the first message. Mix it only when
        // that message is written or read, so both sides agree.
        self.pending_psk = psk.*;
        return self;
    }

    fn mixKey(self: *Handshake, ikm: []const u8) void {
        const d = hkdf(&self.ck, ikm, 2);
        self.ck = d.o1;
        self.k = d.o2;
        self.n = 0;
        self.has_k = true;
    }

    fn mixKeyAndHash(self: *Handshake, ikm: []const u8) void {
        const d = hkdf(&self.ck, ikm, 3);
        self.ck = d.o1;
        mixHash(&self.h, &d.o2);
        self.k = d.o3;
        self.n = 0;
        self.has_k = true;
    }

    fn encryptAndHash(self: *Handshake, plain: []const u8, out: []u8) Error!usize {
        if (!self.has_k) {
            @memcpy(out[0..plain.len], plain);
            mixHash(&self.h, plain);
            return plain.len;
        }
        var tag: [ChaCha20Poly1305.tag_length]u8 = undefined;
        const npub = nonce(self.n);
        ChaCha20Poly1305.encrypt(out[0..plain.len], &tag, plain, &self.h, npub, self.k);
        @memcpy(out[plain.len..][0..tag.len], &tag);
        self.n += 1;
        mixHash(&self.h, out[0 .. plain.len + tag.len]);
        return plain.len + tag.len;
    }

    fn decryptAndHash(self: *Handshake, cipher: []const u8, out: []u8) Error!usize {
        if (!self.has_k) {
            if (out.len < cipher.len) return error.Handshake;
            @memcpy(out[0..cipher.len], cipher);
            mixHash(&self.h, cipher);
            return cipher.len;
        }
        if (cipher.len < ChaCha20Poly1305.tag_length) return error.Handshake;
        const mlen = cipher.len - ChaCha20Poly1305.tag_length;
        if (out.len < mlen) return error.Handshake;
        var tag: [ChaCha20Poly1305.tag_length]u8 = undefined;
        @memcpy(&tag, cipher[mlen..][0..tag.len]);
        const npub = nonce(self.n);
        ChaCha20Poly1305.decrypt(out[0..mlen], cipher[0..mlen], tag, &self.h, npub, self.k) catch return error.Handshake;
        self.n += 1;
        mixHash(&self.h, cipher);
        return mlen;
    }

    fn mixPsk(self: *Handshake) void {
        if (self.psk_mixed) return;
        self.mixKeyAndHash(&self.pending_psk);
        self.psk_mixed = true;
        std.crypto.utils.secureZero(u8, &self.pending_psk);
    }

    fn mixEPublic(self: *Handshake, public_key: *const [32]u8) void {
        mixHash(&self.h, public_key);
        if (self.psk_mixed) self.mixKey(public_key);
    }

    /// Initiator message `-> psk, e` plus an encrypted version byte.
    pub fn writeMsg1(self: *Handshake, out: []u8) Error!usize {
        if (self.role != .initiator or self.step != 0) return error.Handshake;
        if (out.len < handshake_len) return error.Handshake;
        self.mixPsk();
        const kp = try ephemeral();
        self.e_secret = kp.secret_key;
        @memcpy(out[0..32], &kp.public_key);
        self.mixEPublic(&kp.public_key);
        const n = try self.encryptAndHash(&[_]u8{version}, out[32..]);
        if (32 + n != handshake_len) return error.Handshake;
        self.step = 1;
        return handshake_len;
    }

    pub fn readMsg1(self: *Handshake, msg: []const u8) Error!void {
        if (self.role != .responder or self.step != 0) return error.Handshake;
        if (msg.len != handshake_len) return error.Handshake;
        self.mixPsk();
        @memcpy(&self.re, msg[0..32]);
        self.mixEPublic(&self.re);
        var plain: [4]u8 = undefined;
        const n = try self.decryptAndHash(msg[32..], &plain);
        if (n != 1 or plain[0] != version) return error.Handshake;
        self.step = 1;
    }

    /// Responder message `<- e, ee` plus an encrypted version byte.
    pub fn writeMsg2(self: *Handshake, out: []u8) Error!usize {
        if (self.role != .responder or self.step != 1) return error.Handshake;
        if (out.len < handshake_len) return error.Handshake;
        const kp = try ephemeral();
        self.e_secret = kp.secret_key;
        @memcpy(out[0..32], &kp.public_key);
        self.mixEPublic(&kp.public_key);
        const shared = X25519.scalarmult(self.e_secret, self.re) catch return error.Handshake;
        self.mixKey(&shared);
        const n = try self.encryptAndHash(&[_]u8{version}, out[32..]);
        if (32 + n != handshake_len) return error.Handshake;
        self.step = 2;
        return handshake_len;
    }

    pub fn readMsg2(self: *Handshake, msg: []const u8) Error!void {
        if (self.role != .initiator or self.step != 1) return error.Handshake;
        if (msg.len != handshake_len) return error.Handshake;
        @memcpy(&self.re, msg[0..32]);
        self.mixEPublic(&self.re);
        const shared = X25519.scalarmult(self.e_secret, self.re) catch return error.Handshake;
        self.mixKey(&shared);
        var plain: [4]u8 = undefined;
        const n = try self.decryptAndHash(msg[32..], &plain);
        if (n != 1 or plain[0] != version) return error.Handshake;
        self.step = 2;
    }

    pub fn split(self: *Handshake) Error!Transport {
        if (self.step != 2) return error.Handshake;
        const d = hkdf(&self.ck, "", 2);
        const send = if (self.role == .initiator) d.o1 else d.o2;
        const recv = if (self.role == .initiator) d.o2 else d.o1;
        std.crypto.utils.secureZero(u8, &self.k);
        std.crypto.utils.secureZero(u8, &self.ck);
        std.crypto.utils.secureZero(u8, &self.e_secret);
        std.crypto.utils.secureZero(u8, &self.pending_psk);
        return .{ .send_k = send, .recv_k = recv };
    }
};

pub const Transport = struct {
    send_k: [32]u8,
    recv_k: [32]u8,
    send_n: u64 = 0,
    recv_n: u64 = 0,

    pub fn seal(self: *Transport, plain: []const u8, out: []u8) Error!usize {
        if (out.len < plain.len + ChaCha20Poly1305.tag_length) return error.Handshake;
        var tag: [ChaCha20Poly1305.tag_length]u8 = undefined;
        const npub = nonce(self.send_n);
        ChaCha20Poly1305.encrypt(out[0..plain.len], &tag, plain, "", npub, self.send_k);
        @memcpy(out[plain.len..][0..tag.len], &tag);
        self.send_n += 1;
        return plain.len + tag.len;
    }

    pub fn open(self: *Transport, cipher: []const u8, out: []u8) Error!usize {
        if (cipher.len < ChaCha20Poly1305.tag_length) return error.Handshake;
        const mlen = cipher.len - ChaCha20Poly1305.tag_length;
        if (out.len < mlen) return error.Handshake;
        var tag: [ChaCha20Poly1305.tag_length]u8 = undefined;
        @memcpy(&tag, cipher[mlen..][0..tag.len]);
        const npub = nonce(self.recv_n);
        ChaCha20Poly1305.decrypt(out[0..mlen], cipher[0..mlen], tag, "", npub, self.recv_k) catch return error.Handshake;
        self.recv_n += 1;
        return mlen;
    }

    pub fn deinit(self: *Transport) void {
        std.crypto.utils.secureZero(u8, &self.send_k);
        std.crypto.utils.secureZero(u8, &self.recv_k);
    }
};

/// 32-byte Noise PSK from the 16-byte invite secret.
pub fn pskFromSecret(secret: *const [16]u8) [32]u8 {
    const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;
    const prk = HkdfSha256.extract("deathterminal-share-v1", secret);
    var out: [32]u8 = undefined;
    HkdfSha256.expand(&out, "noise-psk", prk);
    return out;
}

test "handshake agrees and transport is directional" {
    var secret: [16]u8 = undefined;
    std.crypto.random.bytes(&secret);
    const psk = pskFromSecret(&secret);
    var ini = Handshake.init(.initiator, &psk);
    var res = Handshake.init(.responder, &psk);
    var m1: [handshake_len]u8 = undefined;
    var m2: [handshake_len]u8 = undefined;
    try std.testing.expectEqual(handshake_len, try ini.writeMsg1(&m1));
    try res.readMsg1(&m1);
    try std.testing.expectEqual(handshake_len, try res.writeMsg2(&m2));
    try ini.readMsg2(&m2);
    var a = try ini.split();
    defer a.deinit();
    var b = try res.split();
    defer b.deinit();

    var sealed: [64]u8 = undefined;
    const n = try a.seal("grid", &sealed);
    var opened: [64]u8 = undefined;
    const m = try b.open(sealed[0..n], &opened);
    try std.testing.expectEqualStrings("grid", opened[0..m]);

    const n2 = try b.seal("ok", &sealed);
    const got = try a.open(sealed[0..n2], &opened);
    try std.testing.expectEqualStrings("ok", opened[0..got]);

    // A frame sealed by the initiator is not a frame the initiator can open.
    const n3 = try a.seal("nope", &sealed);
    try std.testing.expectError(error.Handshake, a.open(sealed[0..n3], &opened));
}

test "wrong invite secret and a flipped bit both fail" {
    var secret: [16]u8 = undefined;
    std.crypto.random.bytes(&secret);
    const psk = pskFromSecret(&secret);
    var other = secret;
    other[0] ^= 0x01;
    const bad = pskFromSecret(&other);

    var ini = Handshake.init(.initiator, &psk);
    var res = Handshake.init(.responder, &bad);
    var m1: [handshake_len]u8 = undefined;
    try std.testing.expectEqual(handshake_len, try ini.writeMsg1(&m1));
    try std.testing.expectError(error.Handshake, res.readMsg1(&m1));

    var ini2 = Handshake.init(.initiator, &psk);
    var res2 = Handshake.init(.responder, &psk);
    _ = try ini2.writeMsg1(&m1);
    try res2.readMsg1(&m1);
    var m2: [handshake_len]u8 = undefined;
    _ = try res2.writeMsg2(&m2);
    m2[40] ^= 0x80;
    try std.testing.expectError(error.Handshake, ini2.readMsg2(&m2));
}

test "psk derivation changes when the secret changes" {
    const a = pskFromSecret(&([_]u8{1} ** 16));
    const b = pskFromSecret(&([_]u8{2} ** 16));
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}
