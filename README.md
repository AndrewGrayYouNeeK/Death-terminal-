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

### 🤖 AI-Native Autocomplete *(planned)*
- Context-aware command suggestions (not just history)
- OpenAI-compatible HTTP/JSON endpoint — local Ollama by default, any compatible server configurable
- Inline ghost-text suggestions, accepted with Tab
- Works with shell state, not just text

### ⚡ GPU Rendering (Vulkan)
- Vulkan swapchain + SPIR-V glyph pipeline, with a software fallback
- FreeType + HarfBuzz text (ligatures), fontconfig fallback for CJK and colour emoji, dynamic glyph atlas
- Bundled JetBrains Mono, so it works without any system fonts; Ctrl+= / Ctrl+- / Ctrl+0 zoom
- Smooth under extreme output (logs, builds, streaming data)
- Designed for future effects + massive scrollback

### 🔐 Built-in SSH + Tunneling *(planned)*
- libssh2-based connections with persistent profiles
- Port forwarding made first-class
- Reads your existing `~/.ssh/config`

### 🔧 Lua Scripting Engine *(planned)*
- Lua 5.4 for config, hooks, and automation
- Plugin system

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
| AI Backend | OpenAI-compatible HTTP/JSON (Ollama)   |
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

- Zig 0.13.x
- Vulkan loader + headers (`libvulkan-dev`; `mesa-vulkan-drivers` for a software GPU)
- Linux: `libx11-dev`, `libwayland-dev`, `wayland-protocols`, `libxkbcommon-dev`, `libfreetype-dev`, `libharfbuzz-dev`, `libfontconfig-dev`
- Optional fallback fonts: `fonts-noto-cjk`, `fonts-noto-color-emoji`

See [QUICKSTART.md](QUICKSTART.md) and [DEVELOPMENT.md](DEVELOPMENT.md) for details.

## 🧪 Current Status

🚧 Actively in development — not yet a daily-driver terminal.

**Done**
- PTY + shell spawning (Unix), UTF-8 decoding with wide (2-column) and combining characters, xterm-compatible VT emulation (scroll regions, alternate screen, insert/delete, 256/true color, mouse, bracketed paste, focus events, DA/DSR replies, titles, hyperlinks — vim, less, htop and tmux work; see [docs/VT_SUPPORT.md](docs/VT_SUPPORT.md))
- Scrollback storage
- Event loop with headless and native GUI modes, signal handling, clean exit when the shell exits
- Vulkan loader, instance/device, swapchain present, SPIR-V glyph pipeline, software fallback
- Real fonts: FreeType/HarfBuzz/fontconfig, bold/italic faces, CJK + colour emoji fallback, procedural box drawing, underline styles/colours, runtime zoom, optional retro 8×8 font (see [docs/FONTS.md](docs/FONTS.md))
- X11 / Wayland / Win32 windows, resize, HiDPI scaling
- CI (build + unit tests)

**Not done yet** (tracked in [ISSUES.md](ISSUES.md))
- Selection + copy/paste (so bracketed paste has no GUI trigger yet), scrollback navigation
- AI suggestions, SSH, Lua, tabs/splits, packaging, macOS

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

## 🔐 Security

- No credential logging
- SSH handled via libssh2
- AI context is sanitized before sending

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
10. **Plugins + tabs/splits**
11. **Packaging** — Linux packages, Windows, macOS

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
