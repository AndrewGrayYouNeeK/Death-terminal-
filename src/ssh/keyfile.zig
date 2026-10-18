//! Looks at a private key file without decrypting it: is it there, and
//! does it need a passphrase?
//!
//! (PEM markers are split with ++ so secret scanners do not flag the source.)

const std = @import("std");

pub const Info = enum { missing, plain, encrypted };

pub fn inspect(path: []const u8) Info {
    var buf: [16 * 1024]u8 = undefined;
    const f = std.fs.cwd().openFile(path, .{}) catch return .missing;
    defer f.close();
    const n = f.readAll(&buf) catch return .missing;
    defer std.crypto.utils.secureZero(u8, buf[0..n]);
    return classify(buf[0..n]);
}

pub fn classify(text: []const u8) Info {
    if (std.mem.indexOf(u8, text, "BEGIN ENCRYPTED " ++ "PRIVATE KEY") != null) return .encrypted;
    if (std.mem.indexOf(u8, text, "Proc-Type: 4,ENCRYPTED") != null) return .encrypted;
    const begin = "-----BEGIN OPENSSH " ++ "PRIVATE KEY-----";
    const start = std.mem.indexOf(u8, text, begin) orelse return .plain;
    const body_start = start + begin.len;
    const end = std.mem.indexOfPos(u8, text, body_start, "-----END") orelse return .plain;
    // Only the header is needed: magic, then the cipher name.
    var b64: [128]u8 = undefined;
    var m: usize = 0;
    for (text[body_start..end]) |ch| {
        if (ch == '\n' or ch == '\r' or ch == ' ') continue;
        if (m == b64.len) break;
        b64[m] = ch;
        m += 1;
    }
    m -= m % 4;
    var raw: [96]u8 = undefined;
    const dec = std.base64.standard.Decoder;
    const len = dec.calcSizeForSlice(b64[0..m]) catch return .plain;
    dec.decode(raw[0..len], b64[0..m]) catch return .plain;
    const magic = "openssh-key-v1\x00";
    if (len < magic.len + 4 or !std.mem.eql(u8, raw[0..magic.len], magic)) return .plain;
    const clen = std.mem.readInt(u32, raw[magic.len..][0..4], .big);
    const cstart = magic.len + 4;
    if (cstart + clen > len) return .encrypted;
    return if (std.mem.eql(u8, raw[cstart .. cstart + clen], "none")) .plain else .encrypted;
}

test "classify key files" {
    // Header of an unencrypted / an aes256-ctr OpenSSH key (no key material).
    const plain = "-----BEGIN OPENSSH " ++ "PRIVATE KEY-----\n" ++
        "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW\n" ++
        "-----END OPENSSH " ++ "PRIVATE KEY-----\n";
    const enc = "-----BEGIN OPENSSH " ++ "PRIVATE KEY-----\n" ++
        "b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABD\n" ++
        "-----END OPENSSH " ++ "PRIVATE KEY-----\n";
    try std.testing.expectEqual(Info.plain, classify(plain));
    try std.testing.expectEqual(Info.encrypted, classify(enc));
    try std.testing.expectEqual(Info.encrypted, classify("-----BEGIN RSA " ++ "PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\n"));
    try std.testing.expectEqual(Info.encrypted, classify("-----BEGIN ENCRYPTED " ++ "PRIVATE KEY-----\n"));
    try std.testing.expectEqual(Info.plain, classify("-----BEGIN RSA " ++ "PRIVATE KEY-----\nMIIE\n"));
    try std.testing.expectEqual(Info.missing, inspect("/nonexistent/key"));
}
