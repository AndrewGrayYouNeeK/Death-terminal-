# Shared Haunting

Share the focused pane, live, with one other YouNeeK Death Terminal. There is no
central server. The host listens on TCP, the invite carries the address and a
secret, and the session is end-to-end encrypted with a Noise handshake
(`std.crypto`: X25519 + ChaCha20-Poly1305). A relay is optional and only splices
ciphertext.

```sh
# host, in the window: Ctrl+Shift+H  (macOS: Cmd+Shift+H, or the command palette)
# the notice and stderr print:
deathterminal --join dt1....

# guest
deathterminal --join dt1....
deathterminal --join 'deathterminal://join/dt1....'
deathterminal --gui --join dt1....     # same view, in a window
```

`Ctrl+Shift+J` (macOS: `Cmd+Shift+J`) opens a join prompt in the window. Paste
the code or the `deathterminal://join/` link.

## What is shared

The host pins the pane that was focused when the share started. Later focus
changes do not follow. Other panes, tabs, the invite notice, and the
"being watched" banner are not in the snapshot. The guest receives the live
screen (the cells on screen), not the scrollback.

AI redaction does not run on this path. Tokens, passwords, and env assignments
visible in the pane are sent as they appear. The share is the screen, not a
prompt to a model. Do not share a pane you would not show the guest.

The guest paints that grid and draws their own cursor and selection on top
(amber cursor, purple selection). The host sees the same pointer on the shared
pane. The host's cursor stays the terminal cursor.

A guest window smaller than the host grid clips. Combining characters and
underline styles are not on the wire; colors are resolved RGB.

## Permission

Guest input is off. Arrows, Home, and Escape move the guest's cursor. Other
keys are swallowed. The mouse sets the cursor and a rectangular selection.

`Ctrl+Shift+G` (macOS: `Cmd+Shift+G`) grants or revokes **control for this session**. The host's gate
is the boundary: input is queued into the pane only when access is control,
the gate is open, and the bytes are non-empty. A new guest after a kick starts
at read-only again.

The host's shared pane shows a banner on row 0 (local overlay, not sent):

| State | Banner |
| --- | --- |
| Waiting | `SHARING \| waiting for a guest \| F12 stop` |
| Read-only guest | `BEING WATCHED \| read-only \| F12 kick \| Ctrl+Shift+G grant` |
| Guest has control | `BEING WATCHED \| guest has CONTROL \| F12 kick \| Ctrl+Shift+G revoke` |

On macOS the grant/revoke hint is `Cmd+Shift+G`, the chord that reaches the app.

`F12` kicks the current guest and keeps the same invite so someone else can
join. When nobody is connected, `F12` stops the share. `Ctrl+Shift+Alt+H`
(macOS: `Cmd+Shift+Option+H`) always stops it. When you are not sharing, `F12`
still reaches the shell.

`config.share.enabled = false` refuses to host. `--join` still works.

## Keys

Linux and Windows use Control. On macOS the same bindings are reached with
Command+Shift. Bare Cmd+H is Hide and Cmd+Option+H is Hide Others, so those
are not share shortcuts. The command palette lists `Share: share this pane`.

| Action | Linux / Windows | macOS |
| --- | --- | --- |
| `share_pane` — share the focused pane | `Ctrl+Shift+H` | `Cmd+Shift+H` |
| `share_grant` — grant or revoke guest control | `Ctrl+Shift+G` | `Cmd+Shift+G` |
| `share_kick` — kick the guest, or stop if you are only waiting | `F12` | `F12` |
| `share_stop` — stop the share | `Ctrl+Shift+Alt+H` | `Cmd+Shift+Option+H` |
| `share_join` — paste an invite | `Ctrl+Shift+J` | `Cmd+Shift+J` |

## Config

```lua
config.share.enabled = true       -- false refuses to host
config.share.bind = "0.0.0.0"     -- listen address (IPv4)
config.share.port = 0             -- 0 picks a free port
config.share.advertise = ""       -- "" = detected LAN IPv4, else the host guests dial
config.share.relay = ""           -- "" = direct; or "host:port" / "tcp://host:port"
```

`advertise` is what goes in the invite. Set it when the detected address is
not the one the guest can route to (a public IP, a VPN address). The guest
does not need `share.relay` set: the relay URL is inside the invite.

## Direct TCP

The host binds `share.bind:share.port` (non-blocking, one guest at a time).
A second TCP connection sits in the backlog until the first guest is kicked
or drops. The LAN address is the IPv4 of the interface that would send a UDP
packet to `192.0.2.1:9`, or `127.0.0.1` when there is no route. That probe
does not open a path through NAT.

**NAT.** There is no hole punching, STUN, or UPnP. Two machines on the same
LAN can connect with the detected address. Across the internet, either
forward the port and set `share.advertise` to an address the guest can dial,
or run the relay below. IPv6 is not in the invite.

## Invite

`dt1.` plus unpadded base64url. Also accepted as `deathterminal://join/<code>`.

Payload, version 1:

| Field | Size |
| --- | --- |
| version | 1 byte, `1` |
| port | u16 big-endian |
| host length | 1 byte, 1–63 |
| host | ASCII, no spaces |
| secret | 16 bytes |
| relay length | 1 byte |
| relay | optional `host:port` or `tcp://host:port`, up to 120 bytes |

The Noise PSK is HKDF-SHA256: extract with salt `deathterminal-share-v1` and
the 16-byte secret, expand info `noise-psk` to 32 bytes. The relay id is
`SHA-256(secret)[0..8]`. The secret is not the relay id.

## Handshake and frames

Pattern `Noise_NNpsk0_25519_ChaChaPoly_SHA256`, prologue `dt-share-v1`:

```
-> psk, e
<- e, ee
```

Each ephemeral public key is mixed into the key (`MixKey`) because a PSK is
already in the chain. The handshake payload is one version byte (`1`), sealed
with ChaCha20-Poly1305. `Split()` yields transport keys; the initiator's send
key is the responder's receive key. Nonce is 4 zero bytes plus a little-endian
u64 counter.

Every handshake message and every sealed transport message is one frame:
u16 big-endian length, then that many bytes. Payloads larger than 32 KiB are
rejected.

Application messages (inside the seal):

| Tag | Name | Body |
| --- | --- | --- |
| 1 | welcome | access byte |
| 2 | row | grid size, host cursor, row index, cells |
| 3 | pointer | guest cursor and selection rectangle |
| 4 | input | raw bytes (admitted only in control mode) |
| 5 | access | `0` read-only, `1` control |
| 6 | kick | empty |
| 7 | bye | empty |
| 8 | ping | empty, echoed |
| 9 | cursor | host cursor |

A cell is 13 bytes: u32le codepoint, u32le fg, u32le bg, flags
(bold, italic, underline, inverse, faint, strike, wide, spacer).

## Relay

The relay never decrypts. It matches two TCP clients on an 8-byte id and
splices the sockets. Noise then runs through that pipe.

Run one anywhere both sides can reach:

```sh
deathterminal --share-relay 9754
deathterminal --share-relay 0.0.0.0:9754
deathterminal --share-relay relay.example:9754
```

On the host:

```lua
config.share.relay = "tcp://relay.example:9754"
```

Start the share as usual. The invite contains the relay, so the guest dials it
with `--join` and does not need the same config. The host registers as role 1
and does not listen locally.

Preface, 14 bytes, then raw Noise bytes:

| Offset | Value |
| --- | --- |
| 0 | `DTSH` |
| 4 | version `1` |
| 5 | role `1` host, `2` guest |
| 6 | 8-byte id |

The server writes one status byte to each side once both have registered:
`0` ok, `1` busy (that role, or every slot, is taken), `2` bad preface. After
`0`, bytes are copied both ways. The relay sees the id, sizes, and timing. It
does not see the secret or the grid.

Eight sessions can be waiting at once. A second guest for an id that already
has a guest gets status `1`.

To replace this with your own rendezvous, keep the preface and the splice: the
bytes after the status byte are the Noise stream, unchanged. A future relay
can sit at `config.share.relay` without a client change as long as it speaks
that preface. Anything that terminates TLS or inspects the payload would stop
being a splice and would break the handshake on purpose.

## Headless guest

The default build is headless. `--join` without `--gui` attaches, drains the
local PTY so it cannot overwrite the remote grid, and prints the host's
screen. `Ctrl+C` leaves. In read-only mode, arrow keys move the local cursor.
After the host grants control, those bytes go to the host's pane.
