# YouNeeK Death Terminal 💀

**A brutalist, GPU-accelerated terminal with AI-native command workflows.**

Fast. Minimal. Unapologetically powerful.

## ⚡ Why YouNeeK Death Terminal?

Most terminals are either:

- fast but dumb (like Alacritty), or
- smart but heavy (like Warp)

YouNeeK Death Terminal aims for both:

- low-level performance
- AI-native workflows
- zero visual fluff

## 🚀 Demo

```
$ docker run -
# → AI suggests (ghost text, Tab to accept):
docker run -it --rm ubuntu:latest /bin/bash

$ deathterminal --ssh prod
# → Linux: profile from config.lua or ~/.ssh/config, forwards included
```

Context-aware, not just history-based.

## 🔥 Core Features

### 🤖 AI-Native Autocomplete
- Context-aware command suggestions: typed input, working directory, recent commands with exit codes, recent output, shell and OS
- OpenAI-compatible HTTP/JSON with SSE streaming — local Ollama (`qwen2.5-coder:0.5b`) by default, any other chat/completions server configurable. The API key comes from an env var you name
- `api.x.ai` and `us.api.x.ai` (model `grok-4.7`) use the Responses API: `config.ai.reasoning` is `low` / `medium` / `high` / `xhigh` (empty means `low`; it cannot be turned off), live search is off, responses are not stored, and the wait is at least 15s
- Dim ghost text after the cursor: Tab accepts, Esc dismisses, Alt+] / Alt+[ cycle alternatives; nothing is inserted unless you accept
- Ctrl+Shift+A explains the last failed command and suggests a fix
- Secrets (tokens, keys, passwords, env assignments) are redacted before anything is sent; offline endpoints just show a small "AI offline" badge
- bash/zsh/fish OSC 133 shell integration, injected automatically (see [docs/AI.md](docs/AI.md))

### 🔁 Muscle Memory
- Local only: repeated command sequences in one project (the same 2–5 commands, three or more times) raise “You run these together a lot. Make it a shortcut?”
- Accepting asks for a name and writes `~/.config/death-terminal/shortcuts.lua`. Typing that name, or picking it in the command palette, runs the sequence and stops on the first failure
- Per-project shortcuts (cwd / git root) and global ones. List, rename, and delete from the palette. Commands that contain secrets are skipped with the AI redaction pass (see [docs/MUSCLE_MEMORY.md](docs/MUSCLE_MEMORY.md))

### ⚡ GPU Rendering (Vulkan)
- Vulkan swapchain + SPIR-V glyph pipeline, with a software fallback
- FreeType + HarfBuzz text (ligatures), dynamic glyph atlas. CJK and colour emoji come from fontconfig on Linux; Windows and macOS scan font folders (COLR emoji — bitmap emoji fonts are not loaded yet)
- Bundled JetBrains Mono, so it works without any system fonts; Ctrl+= / Ctrl+- / Ctrl+0 zoom
- Smooth under extreme output (logs, builds, streaming data)
- Designed for future effects + massive scrollback

### 🔐 Built-in SSH + Tunneling
- `deathterminal --ssh <profile|user@host>` (Linux only): libssh2 1.11.1 (vendored) with Lua profiles (`config.ssh.profiles`) and your existing `~/.ssh/config` (Host/HostName/User/Port/IdentityFile/ProxyJump/Include; `Match` is skipped)
- ssh-agent, keys (incl. encrypted), keyboard-interactive and password, all prompted in-terminal; secrets never logged or stored
- known_hosts verification: accept/once/reject for new hosts, hard block on changed or revoked keys
- `-L` / `-R` / `-D` (SOCKS) forwards per profile, toggled live from the Ctrl+Shift+S palette; keepalives and reconnect (see [docs/SSH.md](docs/SSH.md))

### 🔧 Lua Config + Plugins
- Lua 5.4 config with live reload (see [docs/CONFIG.md](docs/CONFIG.md))
- Sandboxed Lua plugins, each in its own state with memory/CPU limits and only the permissions you grant: hooks for commands (OSC 133), output, cwd, title, bell, focus, keys, SSH and AI suggestions; command palette (Ctrl+Shift+P), keybindings, status bar, toasts, timers, themes; `deathterminal --plugins list|enable|disable` (see [docs/PLUGINS.md](docs/PLUGINS.md))

### 🗂 Tabs + Split Panes
- Tabs and horizontal/vertical splits, each pane with its own shell, scrollback, selection, search and AI context
- Themed tab bar with cwd, activity, bell and exit-status markers; drag to reorder, double-click to rename; drag dividers to resize; zoom, equalize, optional dimming of inactive panes
- New tabs/panes inherit the cwd (OSC 7); the SSH palette opens a profile in a tab, a split, or a new window; startup layouts in Lua (see [docs/TABS.md](docs/TABS.md))

### 🎯 Brutalist Design
- No animations
- No distractions
- Maximum contrast, maximum signal
- Optional "retro" 8×8 bitmap font alongside real fonts

## 🧠 Philosophy

- Speed is non-negotiable
- The terminal is a programming environment, not just a shell
- AI should assist, not interrupt
- Every feature must justify its complexity

## 🏗 Tech Stack

| Layer      | Tech                                   |
|------------|----------------------------------------|
| Core       | Zig 0.13                               |
| Rendering  | Vulkan (software fallback)             |
| Windowing  | X11, Wayland, Win32, Cocoa             |
| AI Backend | OpenAI-compatible HTTP/JSON (Ollama); xAI Responses API (`api.x.ai`, `us.api.x.ai`) |
| SSH        | libssh2 1.11.1 (Linux)                 |
| Scripting  | Lua 5.4                                |

## ⚡ Quick Start

```bash
git clone https://github.com/AndrewGrayYouNeeK/Death-terminal-.git
cd Death-terminal-

zig build run -- --gui        # native window
zig build run -- --headless   # render into the current terminal
zig build test                # unit tests
```

### Requirements

- Zig 0.13.x (Vulkan headers are vendored; the loader is loaded at run time)
- Linux: `pkg-config`, `libx11-dev`, `libwayland-dev`, `libxkbcommon-dev`, `libfreetype-dev`, `libharfbuzz-dev`, `libfontconfig-dev`, `libssl-dev` (libcrypto). A Vulkan loader + driver (`libvulkan1`, `mesa-vulkan-drivers`) at run time, or the software renderer is used
- Windows / macOS: nothing extra to build. `zig build -Dtarget=x86_64-windows`, `-Dtarget=aarch64-macos` or `-Dtarget=x86_64-macos` cross-compiles from Linux; FreeType 2.13.3 and HarfBuzz 10.1.0 are fetched and built from source. See [docs/PLATFORMS.md](docs/PLATFORMS.md)
- Optional fallback fonts: `fonts-noto-cjk`, `fonts-noto-color-emoji`

See [QUICKSTART.md](QUICKSTART.md) and [DEVELOPMENT.md](DEVELOPMENT.md) for details.

### Install (0.1.0)

`zig build release` writes versioned archives to `zig-out/release/`.
`zig build release -Dpackages=true` also builds the installable packages:
AppImage, `.deb` and `.rpm` on Linux; an NSIS setup exe on Windows; a
`.app` and `.dmg` on macOS. They are unsigned
([packaging/SIGNING.md](packaging/SIGNING.md)). AUR, winget and Homebrew
skeletons are in [packaging/](packaging/README.md). A phone port is planned
in [docs/MOBILE.md](docs/MOBILE.md) and is not built.

## 🧪 Current Status

🚧 Actively in development — not yet a daily-driver terminal.

**Done**
- PTY + shell spawning (Unix), UTF-8 decoding with wide (2-column) and combining characters, xterm-compatible VT emulation (scroll regions, alternate screen, insert/delete, 256/true color, mouse, bracketed paste, focus events, DA/DSR replies, titles, hyperlinks — vim, less, htop and tmux work; see [docs/VT_SUPPORT.md](docs/VT_SUPPORT.md))
- Selection (word/line/block, wide-char aware), CLIPBOARD + PRIMARY copy/paste with bracketed paste and a multi-line paste prompt, OSC 52, scrollback viewport with scrollbar, search overlay (regex optional), Ctrl+click URLs and OSC 8 links (see [docs/SELECTION.md](docs/SELECTION.md))
- Event loop with headless and native GUI modes, signal handling, clean exit when the shell exits
- Vulkan loader, instance/device, swapchain present, SPIR-V glyph pipeline, software fallback
- Frame pacing with 2 frames in flight, vsync/mailbox/immediate present modes, zero idle CPU, damage-tracked rows and instanced cell draws, coalesced PTY reads so `cat bigfile`/`yes` don't stall input; `zig build bench` (see [docs/PERFORMANCE.md](docs/PERFORMANCE.md))
- Real fonts: FreeType/HarfBuzz, bold/italic faces, CJK and colour-emoji fallback (fontconfig on Linux; font folders on Windows/macOS, COLR only), procedural box drawing, underline styles/colours, runtime zoom, optional retro 8×8 font (see [docs/FONTS.md](docs/FONTS.md))
- X11 / Wayland / Win32 / Cocoa windows, resize, HiDPI scaling; on macOS, Cmd mirrors the Ctrl and Ctrl+Shift chords. ConPTY on Windows (see [docs/PLATFORMS.md](docs/PLATFORMS.md))
- Lua 5.4 config (`~/.config/death-terminal/config.lua`, or `%APPDATA%\death-terminal\config.lua` on Windows; vendored Lua, sandboxed): typed options with file:line errors shown in the window, bundled themes, key bindings, shell/env/cwd, live reload on save or Ctrl+Shift+R; `deathterminal --print-default-config` (see [docs/CONFIG.md](docs/CONFIG.md))
- Built-in SSH (libssh2, Linux only): profiles + `~/.ssh/config`, ProxyJump, agent/key/keyboard-interactive/password auth, known_hosts checks, remote PTY with resize, `-L/-R/-D` forwards togglable at runtime (Ctrl+Shift+S), keepalive/reconnect; `zig build test-ssh` against a local sshd (see [docs/SSH.md](docs/SSH.md))
- Lua plugins: sandboxed per-plugin states, permission grants in config.lua, hooks, command palette (Ctrl+Shift+P), status bar (on by default), toasts, timers, themes, four example plugins including the bundled YouNeeK Time clock (see [docs/PLUGINS.md](docs/PLUGINS.md))
- Muscle memory: local mining of repeated command sequences, project and global shortcuts in `shortcuts.lua`, palette list/rename/delete, stop on the first failing command (see [docs/MUSCLE_MEMORY.md](docs/MUSCLE_MEMORY.md))
- Tabs and split panes: layout tree, keyboard/mouse resize and focus, zoom, equalize, tab bar, confirm-close for running programs, startup layouts, plugin tab/pane events and actions (see [docs/TABS.md](docs/TABS.md))
- CI: Linux build + unit tests, Windows and macOS cross-compiles; a `v*` tag opens a draft GitHub release
- Packaging: `zig build release -Dpackages=true` builds an AppImage, `.deb` (with a `.desktop` file) and `.rpm`, a Windows zip plus NSIS installer, and a macOS `.app` plus `.dmg`. A `v*` tag publishes them. Signing is not done yet ([packaging/SIGNING.md](packaging/SIGNING.md))
- 80/132-column DECCOLM: headless grids resize; GUI panes keep their width and only clear, home, and reset margins

**Not done yet** (tracked in [ISSUES.md](ISSUES.md))
- Runtime testing on real Windows and macOS (Windows was checked under Wine; macOS only cross-compiles). The built-in SSH client is Linux-only

## 🧩 Architecture (Simplified)

```
PTY ↔ Terminal Core ↔ Renderer (Vulkan / software)
           ↓
        AI Engine (HTTP/JSON, async)
           ↓
        Lua Scripting
```

- Terminal correctness comes first
- Rendering is fully decoupled
- AI is optional and async

## 🧠 AI Design

Unlike traditional autocomplete, suggestions understand:

- previous commands
- working directory
- partial input

Works with local models (offline, e.g. Ollama) or remote OpenAI-compatible servers.
`api.x.ai` and `us.api.x.ai` use the Responses API; every other host stays on chat/completions.
The client is plain HTTP/JSON (it replaces the gRPC service planned originally); see [docs/AI.md](docs/AI.md).

## 🔐 Security

- No credential logging
- SSH handled via libssh2
- AI context is redacted before sending (provider tokens, AWS/GitHub/OpenAI keys, passwords, `KEY=value` assignments, private keys); API keys are read from an environment variable, never stored in the config

## 🛣 Roadmap

Milestones 1–12 shipped in 0.1.0 (cleanup through packaging). See **Done** above.

1. **Windows and macOS for real** — runtime testing beyond Wine and cross-compiles; SSH on those builds
2. **SSH** — certificates, `Match`, agent and X11 forwarding, SFTP, recursive ProxyJump
3. **Tabs** — profile themes in tabs and splits, detach a pane, restore a layout on restart
4. **Still open** — multi-line suggestions, blinking text, left/right margins, image protocol, bitmap emoji (needs libpng)

## 🤝 Contributing

Looking for contributors interested in terminal emulation, low-level graphics, systems programming, and AI tooling. See [CONTRIBUTING.md](CONTRIBUTING.md).

## ❗ Non-Goals

- Beginner-friendly UX
- Feature bloat
- Replacing your shell

## 🙏 Inspiration

Alacritty · Warp · Ghostty

## 📜 License

MIT

## 💀 Final Word

YouNeeK Death Terminal isn't trying to be everything.

It's trying to be the terminal you don't outgrow.
