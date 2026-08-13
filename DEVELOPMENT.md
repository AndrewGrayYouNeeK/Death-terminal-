# DeathTerminal Development Guide

This document tracks development status and priorities for the DeathTerminal desktop terminal emulator.

## Project Overview

DeathTerminal is a Zig-based, GPU-accelerated terminal emulator with AI-native workflows, SSH tunneling, and Lua scripting. It is a **native desktop application** — not a web app.

## Architecture

```
PTY ↔ Terminal Core ↔ Renderer (Vulkan)
           ↓
        AI Engine (gRPC)
           ↓
        Lua Scripting
```

## Module Status

| Module | Path | Status |
|--------|------|--------|
| Terminal core | `src/terminal/` | PTY, ANSI parser, cell buffer — functional |
| Scrollback | `src/terminal/scrollback.zig` | In progress |
| Event loop | `src/app/event_loop.zig` | In progress |
| Vulkan renderer | `src/renderer/` | Structural stubs, needs function loading |
| AI autocomplete | `src/ai/` | gRPC stub |
| SSH tunneling | `src/ssh/` | Stub |
| Lua scripting | `src/scripting/` | Stub |
| Configuration | `src/config/` | Basic file loading |

## Build Requirements

- Zig 0.13+
- Vulkan SDK (`libvulkan-dev` on Linux)
- Lua 5.4 (for future scripting integration)

```bash
zig build          # Build
zig build run      # Run
zig build test     # Test
./dev.sh run       # Dev helper
```

## Development Phases

### Phase 1 — Terminal Core (mostly complete)
- [x] PTY creation and shell spawning
- [x] ANSI/VT100 escape sequence parser
- [x] Cell buffer and cursor control
- [ ] Scrollback buffer
- [x] Cross-platform PTY (Unix)

### Phase 2 — Rendering
- [x] Vulkan module structure
- [ ] Vulkan function loading
- [ ] Window/surface creation
- [ ] Text rendering pipeline

### Phase 3 — Application Layer
- [ ] Main event loop with PTY polling
- [ ] Signal handling (SIGINT, SIGTERM)
- [ ] Configuration file loading
- [ ] Headless terminal mode (no window)

### Phase 4 — AI Integration
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
