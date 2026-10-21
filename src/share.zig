//! Shared Haunting: one pane, live, end to end encrypted, no central server.
//!
//! See docs/SHARING.md. The pieces are split so the terminal can keep using
//! them independently of the window loop:
//!   frame   length-prefixed messages
//!   noise   Noise_NNpsk0 handshake (X25519 + ChaCha20-Poly1305)
//!   msg     grid / input / permission messages
//!   invite  dt1. codes and deathterminal://join/ links
//!   relay   optional TCP rendezvous (not a decryption point)
//!   session host and guest, including the input gate

pub const frame = @import("share/frame.zig");
pub const noise = @import("share/noise.zig");
pub const msg = @import("share/msg.zig");
pub const invite = @import("share/invite.zig");
pub const relay = @import("share/relay.zig");
pub const link = @import("share/link.zig");
pub const session = @import("share/session.zig");

test {
    _ = frame;
    _ = noise;
    _ = msg;
    _ = invite;
    _ = relay;
    _ = link;
    _ = session;
}
