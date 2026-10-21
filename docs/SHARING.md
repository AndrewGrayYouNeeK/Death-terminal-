# Shared Haunting

Share the focused pane, live, with one other YouNeeK Death Terminal. The host
listens on TCP. The invite carries the address and a secret, and the session
is end-to-end encrypted with a Noise handshake (`std.crypto`: X25519 +
ChaCha20-Poly1305). A guest on the same LAN connects directly. A guest
anywhere else uses the relay already in the invite: both sides dial out over
WebSocket, so neither needs a port forward. The relay only forwards opaque
frames. It never sees plaintext.

```sh
# host, in the window: Ctrl+Shift+H  (macOS: Cmd+Shift+H, or the command palette)
# a banner shows the address and this command, and copies it to the clipboard:
deathterminal --share                  # same thing from the shell: prints the invite and stays up

# guest
deathterminal --join dt1....
deathterminal --join 'deathterminal://join/dt1....'
deathterminal --gui --join dt1....     # same view, in a window
```

`Ctrl+Shift+J` (macOS: `Cmd+Shift+J`) opens a join prompt in the window. Paste
the code or the `deathterminal://join/` link. The command palette also lists
`Share: copy invite`.

The host banner is the join address: LAN IP, port, and `deathterminal --join`
with the full code. That same text is on the clipboard. If listening or joining
fails, the window says why: a bad invite code, a refused connection, a timeout,
or the firewall.

On macOS the first share listens on a new port. The system may ask to allow
incoming connections. Allow them. If you deny the prompt, the guest times out
or the connection is refused. The same prompt can appear for `deathterminal
--share`. A failed relay dial does not exit that process. Hosting stays on
the LAN and the log prints the real reason (`share: relay failed (...);
hosting on the LAN only`). `relay.youneek.xyz` can answer the WebSocket
upgrade with an empty HTTP 404, or with a 403 challenge, before the Worker
runs. `/health` can still be ok. That response is not `parseSessionId` (a
Worker miss body is `not found`) and it is not the per-IP gate (429 `full`,
`ip`, or `rate`). The client dials the same Worker at
`wss://youneek-share-relay.youneekartifacts.workers.dev` and the session id
is unchanged, so the host and the guest still meet. `--join` prints
`join failed: ...` and returns when the relay cannot be reached. It does not
exit with `error: Unexpected` when stdin is not a terminal. macOS loads trust
anchors from the Security framework, then a PEM file, then the roots
bundled in the binary. It does not read the system keychain file.

Click the banner, or click the invite without dragging, to copy the whole
invite again. Drag to highlight a slice. Double-click a word and
triple-click a line. The highlight is the selection color. Cmd+C (Ctrl+Shift+C
elsewhere) copies that slice.

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

The host's shared pane shows a banner on row 0 (local overlay, not sent). The rows under it are the invite (address, then `deathterminal --join` and the code), in amber on black, also not sent:

| State | Banner |
| --- | --- |
| Waiting | `SHARING <ip>:<port> \| waiting for a guest \| invite copied \| F12 stop` |
| Read-only guest | `BEING WATCHED \| read-only \| F12 kick \| Ctrl+Shift+G grant \| <ip>:<port>` |
| Guest has control | `BEING WATCHED \| guest has CONTROL \| F12 kick \| Ctrl+Shift+G revoke \| <ip>:<port>` |

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
| `share_copy` — copy the invite again | command palette | command palette (`Share: copy invite`) |

## Config

```lua
config.share.enabled = true       -- false refuses to host
config.share.bind = "0.0.0.0"     -- listen address (IPv4)
config.share.port = 0             -- 0 picks a free port
config.share.advertise = ""       -- "" = detected LAN IPv4, else the host guests dial
config.share.relay = ""           -- "" = wss://relay.youneek.xyz; "off" = LAN only
```

| `share.relay` | Meaning |
| --- | --- |
| `""` | Hosted relay `wss://relay.youneek.xyz`, and the LAN listener |
| `"off"`, `"none"`, `"false"`, `"direct"` | LAN only. Case insensitive |
| `wss://host` | That origin. A path in the URL is ignored; the client always uses `/v1/<id>` |
| `ws://host[:port]` | Same, without TLS. For a local `wrangler dev`, not for guests on the internet |
| `host:port` or `tcp://host:port` | Self-hosted TCP rendezvous (`deathterminal --share-relay`) |

`advertise` is the LAN address in the invite. Set it when the detected
address is not the one a guest on your network can route to. The guest does
not need `share.relay` set: the relay URL is inside the invite. An empty
relay field in an invite means LAN only. The hosted default is applied when
the host builds the invite, not when the guest reads an empty field.

## Direct TCP

The host binds `share.bind:share.port` (non-blocking, one guest at a time).
A second TCP connection sits in the backlog until the first guest is kicked
or drops. The LAN address is the IPv4 of the interface that would send a UDP
packet to `192.0.2.1:9`, or `127.0.0.1` when there is no route. That probe
does not open a path through NAT.

**NAT.** There is no hole punching, STUN, or UPnP. Two machines on the same
LAN connect to the address in the invite. The guest gives that address about
one second (`lan_probe_ms`). If it does not connect, and the invite names a
relay, the guest dials the relay. The host is already waiting there. Both
sockets are outbound, so a guest NAT and a host NAT do not need a forwarded
port. IPv6 is not in the invite.

The default invite names `wss://relay.youneek.xyz`
(`https://relay.youneek.xyz/health`, and
`https://youneek-share-relay.youneekartifacts.workers.dev/health`). A guest
off the LAN uses that relay. An empty 404 or a 403 on the custom domain is
retried on the workers.dev hostname above. `"off"` keeps the share on the
LAN. See [Deploy the hosted relay](#deploy-the-hosted-relay).

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
| relay | optional, up to 120 bytes: a `wss://` or `ws://` origin, or `host:port` / `tcp://host:port` |

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

The relay never decrypts. Noise already seals the byte stream with the invite
secret. The relay matches the two peers on an 8-byte id (`SHA-256(secret)`
truncated) and copies opaque chunks both ways. It sees that id, frame sizes,
and timing. It does not see the secret or the grid. Cloudflare terminates
`wss`, so the Worker can see the path. The path is the id, not the secret.

The host always tries to listen on the LAN as well. A guest that connects
there cancels the relay dial. If the LAN accept is not the real guest (a
middlebox that completes TCP and then fails the handshake), that attempt does
not fall through to the relay.

### Hosted WebSocket relay

`relay/` is a Cloudflare Worker. One Durable Object (`ShareSession`) per
session id, plus a `RelayGate` object that counts sessions. The app default
is `wss://relay.youneek.xyz`. A `workers.dev` hostname works the same way
once it is set in `config.share.relay`.

```
GET /v1/<16 lowercase hex id>?role=host|guest
Upgrade: websocket
```

The first binary frame from the server is one status byte, sent only when
both roles are connected: `0` paired, `1` busy (a second guest). Later binary
frames are opaque slices of the Noise stream. Client frames are masked.
Server frames are not. Ping is answered with pong. Text frames are rejected.
The host blocks on that status byte until a guest arrives or the share stops,
and retries the dial about once a second. A new host socket replaces the old
one (so a kick can rejoin). A second guest is busy.

Limits in `relay/wrangler.jsonc` (the test config is tighter and must not be
deployed):

| Limit | Production |
| --- | --- |
| Live sessions | 128 |
| Live sessions per IP | 8 |
| New sessions per IP per hour | 30 |
| Session lifetime | 2 hours |
| Idle after the peers are paired | 15 minutes |
| Wait if nobody pairs | 30 minutes |
| One frame | 64 KiB |
| Bytes forwarded per session | 64 MiB |

Over the cap, the socket closes with `4001` (expiry, idle, wait, or byte
cap), `1009` (frame too big), `1008` (busy guest), or `4000` (the host was
replaced). `GET /health` returns `{ "ok": true, "service": "youneek-share-relay" }`.
A bad path is HTTP 404 with body `not found`. A missing `Upgrade: websocket`
is 426 `websocket required`. The gate is 429 with body `full`, `ip`, or
`rate`. An empty 404 is the Cloudflare edge in front of the custom domain
(WebSockets turned off for the zone, or a bot challenge), not this router.
`workers.dev` is the same Worker and accepts the upgrade. Logs record the
first 8 hex characters of the id and a reason. They do not record payloads.
Observability redacts the query string, which is where `role` sits.

### Deploy the hosted relay

The Worker is deployed. `https://relay.youneek.xyz/health` returns ok, and
`relay/wrangler.jsonc` routes `relay.youneek.xyz` as a custom domain. The app
default `wss://relay.youneek.xyz` matches that. `"off"` is LAN only.

To redeploy from the Cloudflare account that owns `youneek.xyz`:

```sh
cd relay
npm ci
npx wrangler login
npx wrangler deploy
```

`npm ci` uses `relay/.npmrc` (`legacy-peer-deps=true`). Do not deploy
`relay/wrangler.test.jsonc`. Do not put an API token in the repo.
`npx wrangler deploy --dry-run` checks the config without publishing. Keep
`workers_dev` true: that hostname is the fallback when
`relay.youneek.xyz` returns an empty 404 or a 403 on the WebSocket upgrade.
To make the custom domain itself return 101, turn WebSockets on for the
`youneek.xyz` zone (Network → WebSockets) and do not challenge non-browser
clients on `relay.youneek.xyz`. That is a zone setting. Redeploying the
Worker does not change it. The route pattern `relay.youneek.xyz` with
`custom_domain: true` already sends every path to this Worker.

`npx wrangler dev` in `relay/` speaks the same WebSocket protocol on
localhost. The Zig tests use an in-process `ws://` mock instead of that
process. `cd relay && npm test` runs the Worker in the Workers runtime.

### Self-hosted TCP rendezvous

`deathterminal --share-relay` is the older splice, for a host you run
yourself:

```sh
deathterminal --share-relay 9754
deathterminal --share-relay 0.0.0.0:9754
deathterminal --share-relay relay.example:9754
```

```lua
config.share.relay = "tcp://relay.example:9754"
```

The invite contains that address. The guest still tries the LAN first, then
the TCP relay. The host listens locally and also registers as role 1.

Preface, 14 bytes, then raw Noise bytes:

| Offset | Value |
| --- | --- |
| 0 | `DTSH` |
| 4 | version `1` |
| 5 | role `1` host, `2` guest |
| 6 | 8-byte id |

The server writes one status byte to each side once both have registered:
`0` ok, `1` busy (that role, or every slot, is taken), `2` bad preface. After
`0`, bytes are copied both ways.

Eight sessions can be waiting at once. A second guest for an id that already
has a guest gets status `1`.

To replace the TCP rendezvous with your own, keep the preface and the splice:
the bytes after the status byte are the Noise stream, unchanged. Anything
that terminates the Noise stream or inspects the payload would stop being a
splice and would break the handshake on purpose.

## Headless guest

The default build is headless. `--share` listens, prints the invite on stdout
(the LAN address and `deathterminal --join …`), and keeps the local shell.
`--join` without `--gui` attaches, drains the local PTY so it cannot overwrite
the remote grid, and prints the host's screen. `Ctrl+C` leaves. In read-only
mode, arrow keys move the local cursor. After the host grants control, those
bytes go to the host's pane.
