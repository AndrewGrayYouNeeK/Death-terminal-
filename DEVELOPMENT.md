# DeathTerminal Development Guide

This document tracks development status and priorities for the DeathTerminal desktop terminal emulator.

## Project Overview

DeathTerminal is a Zig-based, GPU-accelerated terminal emulator with AI-native workflows, SSH tunneling, and Lua scripting. It is a **native desktop application** — not a web app.

## Architecture

```
PTY ↔ Terminal Core ↔ Software rasterizer  →  X11 window (optional)
                         ↕
                  Vulkan loader/instance (when libvulkan is present)
                         ↓
                      AI Engine (local fallback + future gRPC)
                         ↓
                      Lua Scripting
```

## Module Status

| Module | Path | Status |
|--------|------|--------|
| Terminal core | `src/terminal/` | PTY, ANSI parser, cell buffer — functional |
| Scrollback | `src/terminal/scrollback.zig` | Functional + search |
| Event loop | `src/app/event_loop.zig` | Headless + GUI (X11) |
| Software renderer | `src/renderer/software.zig` | 8×16 glyph rasterizer |
| Window | `src/platform/window.zig` | X11 via `libX11.so.6` |
| Vulkan loader | `src/renderer/vk_loader.zig` | Dynamic `libvulkan` load + instance |
| Vulkan renderer | `src/renderer/` | Instance + device pick; present still software |
| AI autocomplete | `src/ai/` | Local prefix match; gRPC stub |
| SSH tunneling | `src/ssh/` | Stub |
| Lua scripting | `src/scripting/` | Stub |
| Configuration | `src/config/` | CLI + file loading |

## Build Requirements

- Zig 0.13+
- Vulkan SDK / `libvulkan-dev` (link-time; runtime falls back if missing)
- Lua 5.4 (for future scripting integration)
- `libX11` for `--gui` on Linux

```bash
zig build
zig build run -- --headless
zig build run -- --gui
zig build test
./dev.sh run
```

## Development Phases

### Phase 1 — Terminal Core (complete)
- [x] PTY creation and shell spawning
- [x] ANSI/VT100 escape sequence parser
- [x] Cell buffer and cursor control
- [x] Scrollback buffer
- [x] Cross-platform PTY (Unix)

### Phase 2 — Rendering (in progress)
- [x] Vulkan module structure
- [x] Vulkan function loading (`vk_loader.zig`)
- [x] Vulkan instance creation when possible
- [x] Software text pipeline (cells → RGBA)
- [x] X11 window + present
- [ ] Swapchain + GPU text shaders
- [ ] Wayland / Win32 / Cocoa surfaces

### Phase 3 — Application Layer (partial)
- [x] Main event loop with PTY polling
- [x] Signal handling
- [x] Configuration file loading
- [x] Headless terminal mode
- [x] GUI mode (X11)

### Phase 4 — AI Integration
- [x] Local command prefix fallback
- [ ] gRPC client
- [ ] Context gathering and sanitization
- [ ] Suggestion UI

### Phase 5 — SSH & Scripting
- [ ] libssh2 integration
- [ ] Lua 5.4 bindings
- [ ] Plugin system

## Branch Policy

- `main` — stable development branch
- `cursor/*` — cloud agent feature branches

## CI/CD

GitHub Actions runs `zig build` and `zig build test` on every push and pull request.
