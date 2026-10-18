# Built-in SSH

Death Terminal has an SSH client built on [libssh2](https://libssh2.org) 1.11.1. It is
vendored in `vendor/libssh2-1.11.1` and compiled by `zig build` against the system
`libcrypto`. Prompts for host keys, passphrases and passwords are drawn in the terminal
itself.

```sh
deathterminal --ssh devbox            # a config.ssh.profiles entry
deathterminal --ssh prod              # a Host from ~/.ssh/config
deathterminal --ssh me@example.com:2200
```

`--ssh` opens a window whose PTY runs the client (`deathterminal --ssh-session <target>`)
instead of a local shell. You can also run `deathterminal --ssh-session <target>
[-L spec] [-R spec] [-D spec]` inside any terminal.

## Targets

A target is resolved in this order. The first source that sets a field wins:

1. A `config.ssh.profiles` entry with that name.
2. `~/.ssh/config` (`config.ssh.config_file`). Supported: `Host` (patterns, `!negation`),
   `HostName`, `User`, `Port`, `IdentityFile` (several allowed; `~`, `%h %u %r %d %p %%`),
   `ProxyJump` (comma-separated hops, `none`), and `Include` (globs, relative to `~/.ssh`).
   `Match` blocks are skipped. As in OpenSSH, the first value wins.
3. The spec itself, `[user@]host[:port]` (also `ssh://…` and `[v6]:port`). Otherwise
   `$USER`, port 22, and `~/.ssh/id_ed25519`, `id_ecdsa`, `id_rsa`.

## Profiles

```lua
config.ssh.profiles = {
  devbox = {
    host = "dev.example.com",        -- or "me@dev.example.com:2222", or a ~/.ssh/config alias
    port = 2222,                     -- default: ~/.ssh/config, else 22
    user = "me",
    identity_file = "~/.ssh/id_ed25519",
    jump = "me@bastion.example.com", -- ProxyJump syntax, comma-separated hops; "none" disables
    env = { LANG = "en_US.UTF-8" },  -- sent as SSH env requests (the server's AcceptEnv decides)
    command = "tmux new -A -s main", -- typed into the remote shell once it starts
    theme = "dracula",               -- theme for windows opened on this profile
    forwards = {
      "L 8080:localhost:80",         -- OpenSSH syntax: L/R [bind:]port:host:hostport, D [bind:]port
      "D 1080",                      -- SOCKS4/4a/5 proxy
      { "R 9000:localhost:9000", enabled = false },  -- configured but off until toggled
    },
    keepalive_s = 15,                -- default config.ssh.keepalive_s (30); 0 = off
    reconnect = true,                -- reconnect after a dropped connection (default false)
  },
}
config.ssh.known_hosts = "~/.ssh/known_hosts"
```

Every field is validated (`file:line` errors in the window): port range, forward syntax,
jump hops, theme names, and unknown keys.

## Host keys

Keys are checked against `config.ssh.known_hosts` (default `~/.ssh/known_hosts`, which is
shared with OpenSSH, including hashed entries).

- **Unknown host:** the prompt shows the key type and SHA256 fingerprint (the same as
  `ssh-keygen -lf`). The choices are `[y]es and save`, `[o]nce` (don't save) and `[n]o`.
  "Yes" appends one line to the file and never rewrites it. The file is created 0600 in
  a 0700 directory.
- **Changed key:** a red warning, the new fingerprint, and the `ssh-keygen -R` command to
  run. The connection is refused and there is no override.
- **`@revoked`** keys are refused. `@cert-authority` lines are ignored (no certificate
  support).

## Authentication

Methods are tried in this order, as the server allows them:

1. **ssh-agent** (`$SSH_AUTH_SOCK`), every identity.
2. **Public key files**, from the profile, `IdentityFile`, or the defaults. Encrypted
   keys (PEM, PKCS#8, and new OpenSSH format) ask for the passphrase in the terminal,
   up to 3 tries. An empty answer skips that key.
3. **Keyboard-interactive**: the server's prompts, echo as the server asks.
4. **Password**, 3 tries.

Ctrl+C or Ctrl+D at any prompt cancels the connection. Secrets are read without echo
into fixed buffers that are zeroed after use. libssh2 runs with an allocator that wipes
memory before freeing it. Nothing is logged, cached or written to disk, so a reconnect
asks again.

## Session

- Remote PTY with your `TERM`, the window size (window-change on resize), and modes
  (`VINTR`, `VERASE`, `IUTF8`).
- The window title is `ssh user@host` until the remote shell sets its own.
- Exit status: the remote command's status, `128+n` for a remote signal, and `255` for
  connection errors, as with OpenSSH.
- Keepalives (`keepalive@openssh.com`) every `keepalive_s`. Three missed intervals count
  as a dead connection.
- `reconnect = true`: after a drop, the client retries with backoff (1–30 s) and shows a
  status line. Press `r` to retry now or `q` to give up. A clean exit (`exit`) never
  reconnects.

## Port forwarding

| Spec | Meaning |
|---|---|
| `L [bind:]port:host:hostport` | Local `bind:port` → `host:hostport` from the server |
| `R [bind:]port:host:hostport` | Server `bind:port` → `host:hostport` from here |
| `D [bind:]port` | Local SOCKS4/4a/5 proxy (names resolved remotely for 4a/5h) |

Local binds default to `127.0.0.1`. `-L 8080:host:80`-style and IPv6 `[::1]` forms work
too. Forwards come from the profile, plus `-L/-R/-D` on the `--ssh-session` command line.

**At runtime:** press **Ctrl+Shift+S** (`ssh_palette`) in an SSH window. It lists the
session's forwards with their state (`[on]`/`[off]`, "listening on …", errors), a
**Reconnect** item, every profile, and every `~/.ssh/config` alias. Type to filter,
Enter toggles a forward or opens the profile in a new window, and Esc closes the palette.
In a local window, the palette is a profile picker.

Each session also has a control socket at
`$XDG_RUNTIME_DIR/deathterminal/ssh-<pid>.sock` (directory 0700, owner-checked):

```sh
deathterminal --ssh-ctl <pid> list        # "1 on L 8080:localhost:80 | listening on 127.0.0.1:8080"
deathterminal --ssh-ctl <pid> toggle 2    # also: on <n>, off <n>
deathterminal --ssh-ctl <pid> add "D 1081"
deathterminal --ssh-ctl <pid> status | reconnect
```

## AI

When the window is an SSH session, the AI context says so: "Session: remote, over SSH
to user@host. Commands run on that host…". The local OS and shell are left out.
Redaction applies as usual. Without OSC 133 integration on the remote shell, prompts are
found heuristically. Source `shell-integration/*` on the server for better context.

## Tests

`zig build test-ssh` runs `tests/ssh/run.py` against throwaway local sshd instances. It
needs `openssh-server`, passwordless `sudo` (to create the `dttest` user) and `python3`,
and is skipped with exit 77 when they're missing. It listens on 127.0.0.1 only: ports
2222 (publickey), 2223 (keyboard-interactive) and 2224 (password), plus 2232–2234 with
a different host key. It covers the following (71 checks):

- unknown, accepted, once, rejected, changed and revoked host keys
- agent, plain key, encrypted key, keyboard-interactive and password auth, and Ctrl+C at
  a prompt
- pty size and resize, env, the startup command, and exit status and signals
- `-L`, SOCKS5/5h/4a, `-R`, and 20 parallel connections
- runtime toggles over the control socket
- `-L` on the command line, ProxyJump, and reconnect after the server kills the session
- no secrets on disk or on screen

## Limits

- No SSH certificates (`@cert-authority`), no `Match`, no X11/agent forwarding, no SFTP.
- Hops in `jump` don't follow their own ProxyJump (no recursion). Each hop uses its own
  `~/.ssh/config` identity, then the profile's.
- Multi-step (`partial success`) auth chains work only when each step is one of the
  supported methods. There is no special prompt for them.
- An encrypted key asks for its passphrase before the server says whether it would
  accept that key.
- `command` is typed into the interactive shell rather than run as an exec request, so
  the shell stays open afterwards.
- Linux only for now: the build skips libssh2 on other targets, where `--ssh` reports
  that it's unavailable.
