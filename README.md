# DeathTerminal 💀

**A brutalist, GPU-accelerated terminal with AI-native command workflows.**

Fast. Minimal. Unapologetically powerful.

## ⚡ Why DeathTerminal?

Most terminals are either:

- fast but dumb (like Alacritty), or
- smart but heavy (like Warp)

DeathTerminal aims for both:

- low-level performance
- AI-native workflows
- zero visual fluff

## 🚀 Demo

```
$ docker run -
# → AI suggests (ghost text, Tab to accept):
docker run -it --rm ubuntu:latest /bin/bash

$ ssh prod
# → Auto-expands with config + port forwarding
```

Context-aware, not just history-based.

## 🔥 Core Features

### 🤖 AI-Native Autocomplete
- Context-aware command suggestions: typed input, working directory, recent commands with exit codes, recent output, shell and OS
- OpenAI-compatible HTTP/JSON endpoint with SSE streaming — local Ollama (`qwen2.5-coder:0.5b`) by default, any compatible server configurable; Grok 4.7 (`https://api.x.ai/v1`, model `grok-4.7`) uses the Responses API; the API key comes from an env var you name
- Dim ghost text after the cursor: Tab accepts, Esc dismisses, Alt+] / Alt+[ cycle alternatives; nothing is inserted unless you accept
- Ctrl+Shift+A explains the last failed command and suggests a fix
- Secrets (tokens, keys, passwords, env assignments) are redacted before anything is sent; offline endpoints just show a small "AI offline" badge
- bash/zsh/fish OSC 133 shell integration, injected automatically (see [docs/AI.md](docs/AI.md))

### ⚡ GPU Rendering (Vulkan)
- Vulkan swapchain + SPIR-V glyph pipeline, with a software fallback
- FreeType + HarfBuzz text (ligatures), fontconfig fallback for CJK and colour emoji, dynamic glyph atlas
- Bundled JetBrains Mono, so it works without any system fonts; Ctrl+= / Ctrl+- / Ctrl+0 zoom
- Smooth under extreme output (logs, builds, streaming data)
- Designed for future effects + massive scrollback

### 🔐 Built-in SSH + Tunneling
- `deathterminal --ssh <profile|user@host>`: libssh2 (vendored) with Lua profiles (`config.ssh.profiles`) and your existing `~/.ssh/config` (Host/HostName/User/Port/IdentityFile/ProxyJump/Include)
- ssh-agent, keys (incl. encrypted), keyboard-interactive and password, all prompted in-terminal; secrets never logged or stored
- known_hosts verification: accept/once/reject for new hosts, hard block on changed keys
- `-L` / `-R` / `-D` (SOCKS) forwards per profile, toggled live from the Ctrl+Shift+S palette; keepalives and reconnect (see [docs/SSH.md](docs/SSH.md))

### 🔧 Lua Config + Plugins
- Lua 5.4 config with live reload (see [docs/CONFIG.md](docs/CONFIG.md))
- Sandboxed Lua plugins, each in its own state with memory/CPU limits and only the permissions you grant: hooks for commands (OSC 133), output, cwd, title, bell, focus, keys, SSH and AI suggestions; command palette (Ctrl+Shift+P), keybindings, status bar, toasts, timers, themes; `deathterminal --plugins list|enable|disable` (see [docs/PLUGINS.md](docs/PLUGINS.md))

### 🗂 Tabs + Split Panes
- Tabs and horizontal/vertical splits, each pane with its own shell, scrollback, selection, search and AI context
- Themed tab bar with cwd, activity, bell and exit-status markers; drag to reorder, double-click to rename; drag dividers to resize; zoom, equalize, optional dimming of inactive panes
- New tabs/panes inherit the cwd (OSC 7); SSH profiles open in a tab or split; startup layouts in Lua (see [docs/TABS.md](docs/TABS.md))

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
| Windowing  | X11, Wayland, Win32                    |
| AI Backend | OpenAI-compatible HTTP/JSON (Ollama); xAI Responses API (Grok 4.7) |
| SSH        | libssh2                                |
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
- Linux: `libx11-dev`, `libwayland-dev`, `wayland-protocols`, `libxkbcommon-dev`, `libfreetype-dev`, `libharfbuzz-dev`, `libfontconfig-dev`, `libssl-dev`; a Vulkan loader + driver (`libvulkan1`, `mesa-vulkan-drivers`) at run time, or the software renderer is used
- Windows / macOS: nothing extra to build. `zig build -Dtarget=x86_64-windows` / `-Dtarget=aarch64-macos` cross-compiles from Linux; FreeType and HarfBuzz are fetched and built from source. See [docs/PLATFORMS.md](docs/PLATFORMS.md)
- Optional fallback fonts: `fonts-noto-cjk`, `fonts-noto-color-emoji`

See [QUICKSTART.md](QUICKSTART.md) and [DEVELOPMENT.md](DEVELOPMENT.md) for details.

### Install (0.1.0)

`zig build release` writes versioned archives to `zig-out/release/`. On Linux,
`zig build release -Dpackages=true` also builds the AppImage, `.deb` and `.rpm`.
Package skeletons for AUR, winget/MSI and Homebrew (cask and formula) are in
[packaging/](packaging/README.md).

## 🧪 Current Status

🚧 Actively in development — not yet a daily-driver terminal.

**Done**
- PTY + shell spawning (Unix), UTF-8 decoding with wide (2-column) and combining characters, xterm-compatible VT emulation (scroll regions, alternate screen, insert/delete, 256/true color, mouse, bracketed paste, focus events, DA/DSR replies, titles, hyperlinks — vim, less, htop and tmux work; see [docs/VT_SUPPORT.md](docs/VT_SUPPORT.md))
- Selection (word/line/block, wide-char aware), CLIPBOARD + PRIMARY copy/paste with bracketed paste and a multi-line paste prompt, OSC 52, scrollback viewport with scrollbar, search overlay (regex optional), Ctrl+click URLs and OSC 8 links (see [docs/SELECTION.md](docs/SELECTION.md))
- Event loop with headless and native GUI modes, signal handling, clean exit when the shell exits
- Vulkan loader, instance/device, swapchain present, SPIR-V glyph pipeline, software fallback
- Frame pacing with 2 frames in flight, vsync/mailbox/immediate present modes, zero idle CPU, damage-tracked rows and instanced cell draws, coalesced PTY reads so `cat bigfile`/`yes` don't stall input; `zig build bench` (see [docs/PERFORMANCE.md](docs/PERFORMANCE.md))
- Real fonts: FreeType/HarfBuzz/fontconfig, bold/italic faces, CJK + colour emoji fallback, procedural box drawing, underline styles/colours, runtime zoom, optional retro 8×8 font (see [docs/FONTS.md](docs/FONTS.md))
- X11 / Wayland / Win32 / Cocoa windows, resize, HiDPI scaling; ConPTY on Windows (see [docs/PLATFORMS.md](docs/PLATFORMS.md))
- Lua 5.4 config (`~/.config/death-terminal/config.lua`, vendored Lua, sandboxed): typed options with file:line errors shown in the window, bundled themes, key bindings, shell/env/cwd, live reload on save or Ctrl+Shift+R; `deathterminal --print-default-config` (see [docs/CONFIG.md](docs/CONFIG.md))
- Built-in SSH (libssh2): profiles + `~/.ssh/config`, ProxyJump, agent/key/keyboard-interactive/password auth, known_hosts checks, remote PTY with resize, `-L/-R/-D` forwards togglable at runtime (Ctrl+Shift+S), keepalive/reconnect; `zig build test-ssh` against a local sshd (see [docs/SSH.md](docs/SSH.md))
- Lua plugins: sandboxed per-plugin states, permission grants in config.lua, hooks, command palette (Ctrl+Shift+P), optional status bar, toasts, timers, themes, three example plugins (see [docs/PLUGINS.md](docs/PLUGINS.md))
- Tabs and split panes: layout tree, keyboard/mouse resize and focus, zoom, equalize, tab bar, confirm-close for running programs, startup layouts, plugin tab/pane events and actions (see [docs/TABS.md](docs/TABS.md))
- CI (build + unit tests)
- Packaging: `zig build release`, AppImage / .deb / .rpm, AUR, Windows zip (+ winget/MSI skeletons), macOS .app + Homebrew skeletons; 80/132-column DECCOLM

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

Works with local models (offline, e.g. Ollama) or remote OpenAI-compatible inference servers.
The client is plain HTTP/JSON (it replaces the gRPC service planned originally); see [docs/AI.md](docs/AI.md).

## 🔐 Security

- No credential logging
- SSH handled via libssh2
- AI context is redacted before sending (provider tokens, AWS/GitHub/OpenAI keys, passwords, `KEY=value` assignments, private keys); API keys are read from an environment variable, never stored in the config

## 🛣 Roadmap

1. **Cleanup** — headless redraw fix, stale code/docs removed
2. **UTF-8** — codepoint cells, wide chars, replacement glyphs
3. **Full-screen apps** — scroll regions, alt screen, insert/delete, 256/true color, mouse, bracketed paste
4. **Fonts** — real font rendering + optional retro 8×8 bitmap font
5. **Selection & scrollback** — copy/paste, scrollback navigation, search
6. **Performance** — frame sync, damage tracking, benchmarks
7. **Lua config** — real Lua 5.4 for colors, keybindings, fonts
8. **AI** — ghost-text suggestions via OpenAI-compatible HTTP/JSON
9. **SSH** — libssh2 connections, profiles, port forwarding
10. **Plugins** — sandboxed Lua plugins, hooks, palette, status bar
11. **Tabs + splits** — tabs, split panes, layouts
12. **Packaging** — Linux packages, Windows, macOS

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

DeathTerminal isn't trying to be everything.

It's trying to be the terminal you don't outgrow.
