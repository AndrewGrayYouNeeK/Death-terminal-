//! CA certificates for the relay's `wss://` dial.
//!
//! Linux and Windows use the stdlib scan. macOS does not: Zig 0.13 reads
//! `/System/Library/Keychains/SystemRootCertificates.keychain` and asserts
//! that the header is `kych`. Current macOS keychains are not that file, so
//! the assert aborts the process from the relay thread. This loader uses the
//! Security framework, then a PEM file on disk, then the roots embedded in
//! the binary. It never opens the keychain file.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const Bundle = std.crypto.Certificate.Bundle;

const embedded = @embedFile("cacert.pem");

const pem_paths = [_][]const u8{
    "/etc/ssl/cert.pem",
    "/etc/ssl/certs/ca-certificates.crt",
    "/opt/homebrew/etc/ca-certificates/cert.pem",
    "/opt/homebrew/etc/openssl@3/cert.pem",
    "/usr/local/etc/openssl@3/cert.pem",
    "/usr/local/etc/openssl/cert.pem",
    "/opt/local/etc/openssl/cert.pem",
};

/// Replace `bundle` with a set of roots. Empty means no trust anchor was found.
pub fn scan(bundle: *Bundle, gpa: Allocator) !void {
    bundle.bytes.clearRetainingCapacity();
    bundle.map.clearRetainingCapacity();
    if (comptime builtin.os.tag != .macos) {
        bundle.rescan(gpa) catch {};
        if (bundle.bytes.items.len != 0) return;
        bundle.bytes.clearRetainingCapacity();
        bundle.map.clearRetainingCapacity();
    } else if (fillFromSecurity(bundle, gpa) and bundle.bytes.items.len != 0) {
        return;
    }
    addPemFiles(bundle, gpa);
    if (bundle.bytes.items.len != 0) return;
    try addPemBytes(bundle, gpa, embedded);
    if (bundle.bytes.items.len == 0) return error.NoCertificates;
}

pub fn addPemBytes(bundle: *Bundle, gpa: Allocator, pem: []const u8) !void {
    const begin_marker = "-----BEGIN CERTIFICATE-----";
    const end_marker = "-----END CERTIFICATE-----";
    const now_sec = std.time.timestamp();
    var start_index: usize = 0;
    while (std.mem.indexOfPos(u8, pem, start_index, begin_marker)) |begin| {
        const cert_start = begin + begin_marker.len;
        const cert_end = std.mem.indexOfPos(u8, pem, cert_start, end_marker) orelse return error.MissingEndCertificateMarker;
        start_index = cert_end + end_marker.len;
        const encoded = std.mem.trim(u8, pem[cert_start..cert_end], " \t\r\n");
        if (encoded.len == 0) continue;
        const decoder = std.base64.standard.decoderWithIgnore(" \t\r\n");
        const upper = decoder.calcSizeUpperBound(encoded.len) catch continue;
        const decoded_start: u32 = @intCast(bundle.bytes.items.len);
        try bundle.bytes.resize(gpa, decoded_start + upper);
        const written = decoder.decode(bundle.bytes.items[decoded_start..], encoded) catch {
            bundle.bytes.items.len = decoded_start;
            continue;
        };
        bundle.bytes.items.len = decoded_start + written;
        bundle.parseCert(gpa, decoded_start, now_sec) catch {
            bundle.bytes.items.len = decoded_start;
        };
    }
}

fn addPemFiles(bundle: *Bundle, gpa: Allocator) void {
    for (pem_paths) |path| {
        const before = bundle.bytes.items.len;
        bundle.addCertsFromFilePathAbsolute(gpa, path) catch continue;
        if (bundle.bytes.items.len != before) return;
    }
}

fn fillFromSecurity(bundle: *Bundle, gpa: Allocator) bool {
    if (comptime builtin.os.tag != .macos) return false;
    return fillFromSecurityMac(bundle, gpa);
}

fn fillFromSecurityMac(bundle: *Bundle, gpa: Allocator) bool {
    var security = std.DynLib.open("/System/Library/Frameworks/Security.framework/Security") catch return false;
    defer security.close();
    var cf = std.DynLib.open("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation") catch return false;
    defer cf.close();

    const CopyAnchors = *const fn (*?*anyopaque) callconv(.C) i32;
    const ArrayCount = *const fn (?*anyopaque) callconv(.C) isize;
    const ArrayAt = *const fn (?*anyopaque, isize) callconv(.C) ?*anyopaque;
    const CopyData = *const fn (?*anyopaque) callconv(.C) ?*anyopaque;
    const DataPtr = *const fn (?*anyopaque) callconv(.C) ?[*]const u8;
    const DataLen = *const fn (?*anyopaque) callconv(.C) isize;
    const Release = *const fn (?*anyopaque) callconv(.C) void;

    const copy_anchors = security.lookup(CopyAnchors, "SecTrustCopyAnchorCertificates") orelse return false;
    const count = cf.lookup(ArrayCount, "CFArrayGetCount") orelse return false;
    const at = cf.lookup(ArrayAt, "CFArrayGetValueAtIndex") orelse return false;
    const copy_data = security.lookup(CopyData, "SecCertificateCopyData") orelse return false;
    const bytes_ptr = cf.lookup(DataPtr, "CFDataGetBytePtr") orelse return false;
    const bytes_len = cf.lookup(DataLen, "CFDataGetLength") orelse return false;
    const release = cf.lookup(Release, "CFRelease") orelse return false;

    var anchors: ?*anyopaque = null;
    if (copy_anchors(&anchors) != 0 or anchors == null) return false;
    defer release(anchors);

    const now_sec = std.time.timestamp();
    const n = count(anchors);
    var i: isize = 0;
    while (i < n) : (i += 1) {
        const cert = at(anchors, i) orelse continue;
        const data = copy_data(cert) orelse continue;
        defer release(data);
        const ptr = bytes_ptr(data) orelse continue;
        const len = bytes_len(data);
        if (len <= 0) continue;
        const der = ptr[0..@intCast(len)];
        const decoded_start: u32 = @intCast(bundle.bytes.items.len);
        bundle.bytes.appendSlice(gpa, der) catch continue;
        bundle.parseCert(gpa, decoded_start, now_sec) catch {
            bundle.bytes.items.len = decoded_start;
        };
    }
    return true;
}

test "embedded roots parse without the macOS keychain file" {
    var bundle = Bundle{};
    defer bundle.deinit(std.testing.allocator);
    try addPemBytes(&bundle, std.testing.allocator, embedded);
    try std.testing.expect(bundle.map.count() > 10);
    try std.testing.expect(std.mem.indexOf(u8, embedded, "kych") == null);
}
