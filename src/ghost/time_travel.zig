//! Hook for Time Travel snapshots.
//!
//! Another part of the terminal may register a provider. Ghost Run calls
//! it only after the user picks "Run with Time Travel snapshot". Preview
//! never calls it, and Ghost Run does not ship an implementation.
//!
//! The provider must not run `req.command`. A snapshot copies state; the
//! risky command stays in the shell's input until Ghost Run sends Enter.

const std = @import("std");

pub const SnapshotRequest = struct {
    /// Shell working directory (OSC 7), or "" when it is unknown.
    cwd: []const u8,
    /// Command line that is about to run. Not executed by this call.
    command: []const u8,
    /// Pane the command was typed in.
    pane: u32,
};

pub const SnapshotResult = union(enum) {
    /// `id` is borrowed from the provider and only needs to live until
    /// `snapshot` returns (Ghost Run copies what it shows).
    ok: struct { id: []const u8 },
    unavailable,
    /// Borrowed message, same lifetime as `id`.
    failed: []const u8,
};

pub const Provider = struct {
    ctx: *anyopaque,
    /// False hides the snapshot choice. Must not take a snapshot.
    available: *const fn (ctx: *anyopaque) bool,
    /// Take a snapshot before the risky command runs.
    snapshot: *const fn (ctx: *anyopaque, req: SnapshotRequest) SnapshotResult,
};

var provider: ?Provider = null;

pub fn register(p: Provider) void {
    provider = p;
}

pub fn unregister() void {
    provider = null;
}

pub fn isAvailable() bool {
    const p = provider orelse return false;
    return p.available(p.ctx);
}

pub fn snapshot(req: SnapshotRequest) SnapshotResult {
    const p = provider orelse return .unavailable;
    if (!p.available(p.ctx)) return .unavailable;
    return p.snapshot(p.ctx, req);
}

test "unregistered provider is unavailable and does not invent a snapshot" {
    unregister();
    try std.testing.expect(!isAvailable());
    const r = snapshot(.{ .cwd = "/tmp", .command = "rm -rf x", .pane = 1 });
    try std.testing.expect(r == .unavailable);
}
