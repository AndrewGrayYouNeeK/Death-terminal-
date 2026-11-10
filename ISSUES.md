# YouNeeK Death Terminal Project Checklist

## ✅ COMPLETED

### Project Foundation
- [x] Project structure created with modular architecture
- [x] Build system configured (build.zig with Zig 0.13.0+)
- [x] Git repository initialized
- [x] MIT License added
- [x] README.md with project vision and features
- [x] CONTRIBUTING.md with coding standards and guidelines
- [x] CHANGELOG.md for tracking changes
- [x] QUICKSTART.md with installation instructions
- [x] Example Lua configuration file (config.example.lua)
- [x] Development helper script (dev.sh)

### Code Structure
- [x] Main entry point (src/main.zig) with CLI parsing
- [x] Module stubs created for all core subsystems:
  - [x] Vulkan renderer (src/renderer/vulkan_renderer.zig)
  - [x] Terminal core (src/terminal/terminal.zig)
  - [x] AI autocomplete (stub, replaced by src/ai/ in milestone 8)
  - [x] SSH tunneling (src/ssh/tunnel.zig)
  - [x] Lua scripting engine (src/scripting/lua_engine.zig)
- [x] Basic initialization flow for all subsystems
- [x] Version information and help text
- [x] ASCII art banner

### Documentation
- [x] Project philosophy and design principles documented
- [x] Conventional Commits guidelines
- [x] Code formatting standards (zig fmt)
- [x] Platform-specific installation instructions (Linux, macOS, Windows)
- [x] Security considerations documented
- [x] Module-specific contribution guidelines

## 🚧 IN PROGRESS / NOT STARTED

### Phase 1 - Terminal Core (High Priority)
- [x] PTY (pseudo-terminal) creation and management
- [x] Process spawning and lifecycle management
- [x] ANSI/VT100 escape sequence parser
- [x] Terminal buffer management
- [x] Input/output handling
- [x] Cursor movement and control
- [x] Scrollback buffer implementation
- [x] PTY on Unix (Linux/macOS)
- [x] PTY on Windows (ConPTY; checked under Wine only, see docs/PLATFORMS.md)
- [x] UTF-8 decoding with U+FFFD for malformed input
- [x] Wide characters (East Asian wide/fullwidth, emoji) as 2-column cells
- [x] Combining marks stored on the base cell (up to 2; shaping waits for real fonts)
- [x] Non-ASCII glyphs (FreeType + fontconfig fallback chain; see docs/FONTS.md)
- [x] Scroll regions (DECSTBM, SU/SD, IND/RI/NEL), insert/delete line/char, erase/repeat char, insert mode
- [x] Tab stops (HTS/TBC/CHT/CBT), origin mode, DECAWM, DECSC/DECRC + CSI s/u, DEC special graphics
- [x] Alternate screen (?1049/?1047/?47), bracketed paste (?2004), mouse reporting (?1000/?1002/?1003/?1006), focus events (?1004)
- [x] Application cursor/keypad (DECCKM/DECKPAM), xterm modifier encoding for special keys
- [x] 256-color and true-color SGR (`;` and `:` forms), faint/inverse/strikethrough/hidden
- [x] Device status / attribute replies (DSR/CPR, DA1/DA2, DECRQM, XTVERSION, OSC 10/11 queries)
- [x] OSC 0/2 window title, OSC 7 cwd, OSC 8 hyperlinks (parsed, bounded), DECSCUSR cursor shapes
- [x] `TERM=xterm-256color`, `COLORTERM=truecolor` in the shell environment
- [x] DECCOLM 80/132 switching (side effects only), left/right margins (DECSLRM), double-size lines
- [x] Reflow on resize (screen + scrollback), underline colour/styles
- [x] Blinking text
- [x] Shell integration

### Phase 2 - Vulkan Rendering (High Priority)
- [x] Vulkan instance initialization (loader + vkCreateInstance)
- [x] Physical device selection and logical device creation (creates a device when a GPU is present)
- [x] Swapchain setup (X11/Wayland/Win32 surface + graphics present)
- [x] Graphics pipeline creation (SPIR-V vertex/fragment text shaders)
- [x] Text rendering pipeline (glyph atlas + instanced quads)
- [x] Glyph atlas generation and caching (dynamic RGBA atlas, rasterised on demand, grows to 2048², resets when full)
- [x] GPU buffer management (structure in place)
- [x] Window creation and management
- [x] High-DPI display support
- [x] Window resize handling
- [x] Frame synchronization (2 frames in flight, fences/semaphores, fifo/mailbox/immediate)
- [x] Performance optimization (damage tracking, one instanced draw, coalesced PTY reads; see docs/PERFORMANCE.md)

### Phase 3 - AI Integration (Medium Priority)
- [x] OpenAI-compatible HTTP/JSON client with SSE streaming (default: local Ollama, configurable) — src/ai/openai.zig (replaces the gRPC plan). `api.x.ai` / `us.api.x.ai` use the Responses API for Grok 4.7 (`ai.reasoning`, search off, store false)
- [x] AI service connection management (worker thread, cancel on keystroke, timeouts) — src/ai/engine.zig
- [x] Context gathering (working directory, command history + exit codes, output tail, shell, OS) via OSC 133/OSC 7 shell integration (bash/zsh/fish, auto-injected)
- [x] Context sanitization for privacy — src/ai/redact.zig with tests
- [x] Suggestion request/response handling, debounce
- [x] Async suggestion processing (no UI stalls)
- [x] Ghost-text suggestion UI (Tab accepts, Esc dismisses, Alt+]/Alt+[ cycle)
- [x] "Explain / fix last error" overlay (Ctrl+Shift+A)
- [x] Local vs remote model support (endpoint, model, API key from an env var)
- [x] Offline mode handling ("AI offline" badge, backoff)
- [x] Configuration for AI endpoints (`config.ai.*`)
- [x] Rate limiting and error handling (one request at a time, backoff)
- [x] Connect timeout: DNS + connect obey `ai.timeout_ms` (src/net/dial.zig)
- [x] Multi-line suggestions; keep-alive connections

### Phase 4 - SSH (Medium Priority)
- [x] SSH library integration (libssh2 1.11.1 vendored, system libcrypto) — src/ssh/, docs/SSH.md
- [x] Connection manager: `--ssh` windows run `--ssh-session`; ProxyJump hops via direct-tcpip
- [x] SSH profile management (`config.ssh.profiles`, Ctrl+Shift+S palette)
- [x] Authentication: agent, keys (incl. encrypted), keyboard-interactive, password, prompted in-terminal
- [x] Host key verification (known_hosts; accept/once/reject; hard block on changed/revoked)
- [x] Port forwarding -L / -R / -D (SOCKS4/4a/5), runtime toggles (palette, `--ssh-ctl`)
- [x] Keepalives, dead-peer detection, reconnect with backoff
- [x] Standard SSH config file support (Host/HostName/User/Port/IdentityFile/ProxyJump/Include)
- [x] Security: secrets wiped, never logged or stored; known_hosts append-only
- [x] Integration tests against a local sshd (`zig build test-ssh`)
- [x] `Match` (`all`, `host`, `user`, `localuser`) and recursive ProxyJump
- [ ] SSH certificates (@cert-authority), agent/X11 forwarding, SFTP
- [ ] Partial-success (multi-factor) chains get no special UI
- [ ] macOS/Windows builds of the SSH client (Linux only: vendored libssh2 is OpenSSL-only, and cross builds have no libcrypto)

### Phase 5 - Lua Scripting (Lower Priority)
- [x] Lua state initialization (vendored Lua 5.4.7, built by zig)
- [x] C API bindings for Lua 5.4
- [x] Lua API design and implementation (config API; `dt` table)
- [x] Hook system (startup, commands, output, cwd, title, bell, focus, keys, SSH, AI) — milestone 10
- [x] Configuration loading from Lua files (live reload)
- [x] Plugin system: sandboxed per-plugin states, permissions, palette, status bar (docs/PLUGINS.md)
- [x] Sandboxing for dangerous operations (config; `--lua-unsafe` opt-out)
- [x] Error handling and reporting (file:line, in-window notice)
- [x] API documentation for script authors (docs/CONFIG.md, docs/PLUGINS.md)
- [x] Example plugins (plugins/: git_branch, long_command, theme_cycle, youneek-time)
- [ ] Plugin hot reload of `require`d modules (only manifest/init.lua mtimes trigger a restart)
- [ ] SSH hooks for `ssh` run inside a local shell (only the built-in client reports)

### Main Event Loop
- [x] Event loop architecture
- [x] Keyboard input handling
- [x] Mouse input handling
- [x] Rendering loop integration (GPU text pipeline with blit/XPutImage fallback)
- [x] Event dispatching to subsystems
- [x] Graceful shutdown handling
- [x] Signal handling (SIGTERM, SIGINT, etc.)

### Testing & Quality
- [x] Unit tests for terminal emulation (basic)
- [x] Unit tests for ANSI parser (basic)
- [ ] Integration tests for PTY handling
- [ ] Rendering tests
- [x] AI integration tests (mock HTTP server: streaming, errors, timeouts, cancel, offline)
- [ ] SSH connection tests
- [ ] Lua scripting tests
- [ ] Cross-platform testing (Linux done; Windows under Wine; macOS compile-only)
- [ ] Performance benchmarks
- [ ] Memory leak detection
- [x] CI/CD pipeline setup

### Configuration & UX
- [x] Configuration file loading (config.lua via XDG paths; legacy config.txt deprecated)
- [x] Theme system implementation (7 bundled themes + per-colour overrides)
- [x] Keybinding customization
- [x] Font selection and management (real fonts + optional retro 8x8 bitmap font)
- [x] Fonts on macOS/Windows (FreeType + HarfBuzz from source, font-folder scan instead of fontconfig)
- [ ] Colour emoji from sbix/CBDT fonts (Apple Color Emoji) on macOS/Windows: needs libpng in the FreeType build
- [ ] Emoji ZWJ sequences / flags composed into one glyph
- [x] Color scheme support
- [x] Terminal size configuration
- [ ] Preferences persistence

### Additional Features
- [x] Copy/paste functionality (CLIPBOARD/PRIMARY, bracketed paste, paste prompt, OSC 52)
- [x] Search in scrollback (Ctrl+Shift+F overlay)
- [x] Scrollback navigation (Shift+PageUp/PageDown, wheel, Shift+Home/End, scrollbar)
- [x] Tabs and splits (milestone 11, docs/TABS.md)
- [ ] Tabs: SSH profile themes in tabs/splits (only new windows get the profile theme)
- [ ] Tabs: detach a pane into its own window / move panes between tabs
- [ ] Tabs: session restore of layouts on restart
- [x] Hyperlink detection and handling (Ctrl+click URLs and OSC 8)
- [ ] Image protocol support (optional)
- [ ] Notifications
- [ ] Session persistence

### Documentation & Release
- [ ] API documentation generation
- [ ] Wiki for in-depth guides
- [ ] Troubleshooting guide
- [ ] Video demos or GIFs
- [ ] Community chat setup
- [x] GitHub Actions for CI
- [x] Release automation (`.github/workflows/release.yml`, draft release on a `v*` tag)
- [x] Package managers: AUR PKGBUILD, winget, Homebrew cask/formula skeletons (not submitted)
- [x] macOS window backend (Cocoa + MoltenVK; untested at runtime)
- [ ] Runtime testing on real Windows and macOS hardware

### Windows real-hardware testing (unverified)

No Windows machine and no Windows VM were available on the Linux host that
produced this note. Wine 10 is not a substitute (see docs/PLATFORMS.md).
These items are still unverified on real Windows hardware:

- ConPTY shell I/O: `cmd.exe` or `pwsh.exe` stays alive and VT output flows
- `ResizePseudoConsole` when the window grid changes
- Win32 clipboard read and write
- URL opening via `ShellExecuteW`
- Config watcher via `FindFirstChangeNotification`

Build when a machine is available:

```sh
zig build -Dtarget=x86_64-windows
# then run zig-out/bin/deathterminal.exe --gui
```

### CodeQL

`cpp/redundant-null-check-simple` in `vendor/libssh2-1.11.1/src/userauth.c`
(around the `if (!key_method)` check near line 1497) is upstream libssh2.
That tree is vendored and is not patched in-tree. `.github/codeql/codeql-config.yml`
excludes `vendor/` from analysis. `.github/workflows/ci.yml` sets
`permissions: contents: read` at the workflow root. No job comments on pull
requests, so `pull-requests: write` is not granted.

## 📊 Current Status Summary

**Overall Progress**: ~85–90%. Phases 1–5 are in: terminal core (PTY, UTF-8, wide characters, full-screen VT, scrollback), Vulkan text on Wayland/X11/Win32 plus a Cocoa backend, AI suggestions, built-in SSH on Linux, Lua config and plugins, tabs and splits, packaging.

The old "~40%, no UTF-8 / full-screen apps / AI / SSH / Lua" line is out of date. Those subsystems ship. What is left is the open boxes above, not the core.

**Still open**:

- Real macOS runtime verification (Cocoa + MoltenVK is compile-only today; see docs/PLATFORMS.md)
- Real Windows hardware verification (list above; Wine 10 covered the GUI, not ConPTY shell I/O)
- DECCOLM side effects still owed: left/right margins (DECSLRM) and double-size lines; blinking text (SGR 5)
- AI: multi-line suggestions and HTTP keep-alive
- SSH: certificates (`@cert-authority`), `Match`, agent/X11 forwarding, SFTP, recursive ProxyJump, a UI for partial-success multi-factor chains, and macOS/Windows builds (libssh2 is Linux-only)
- Lua: hot reload of `require`d modules; SSH hooks for an `ssh` started inside the local shell
- Colour emoji (sbix/CBDT needs libpng in the FreeType build), ZWJ sequences and flags as one glyph, preferences persistence
- Tabs: SSH profile themes inside tabs/splits, detach/move panes, session restore of layouts
- Optional image protocol, notifications, session persistence
- Extra docs (generated API docs, wiki, troubleshooting, video demos, community chat)

**Where the code lives now**:

- `src/terminal/`: grid, VT parser, scrollback, PTY (POSIX + ConPTY)
- `src/renderer/`: Vulkan loader, swapchain, glyph atlas, software fallback
- `src/app/`: GUI event loop, tabs, splits, palette
- `src/ai/`: OpenAI-compatible HTTP/SSE client, worker, redaction
- `src/ssh/`: libssh2 client (Linux), known_hosts, forwards, config parser
- `src/scripting/` and `src/plugins/`: Lua 5.4 and the plugin host
- `src/platform/`: X11, Wayland, Win32, Cocoa

**Done already** (do not re-open these):

1. PTY and terminal emulation
2. Headless and GUI event loops
3. Vulkan instance, device, and swapchain
4. Windows, Wayland, X11, and Cocoa window backends
5. GPU text pipeline and software fallback
6. HiDPI scaling
7. UTF-8, wide characters, and full-screen app sequences
8. Fonts, selection, scrollback search
9. Lua config, AI ghost text, Linux SSH, plugins, tabs, packaging skeletons
