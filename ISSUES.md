# DeathTerminal Project Checklist

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
  - [x] AI autocomplete (src/ai/autocomplete.zig)
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
- [ ] PTY on Windows (ConPTY)
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
- [ ] DECCOLM 80/132 switching (side effects only), left/right margins (DECSLRM), double-size lines
- [ ] Reflow on resize, underline colour/styles, blinking text
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
- [ ] Frame synchronization
- [ ] Performance optimization (batching, minimal state changes)

### Phase 3 - AI Integration (Medium Priority)
- [ ] OpenAI-compatible HTTP/JSON client (default: local Ollama, configurable)
- [ ] AI service connection management
- [ ] Context gathering (working directory, command history, shell state)
- [ ] Context sanitization for privacy
- [ ] Suggestion request/response handling
- [ ] Async suggestion processing
- [ ] Ghost-text suggestion UI (Tab to accept)
- [ ] Local vs remote model support
- [ ] Offline mode handling
- [ ] Configuration for AI endpoints
- [ ] Rate limiting and error handling

### Phase 4 - SSH Tunneling (Medium Priority)
- [ ] SSH library integration (libssh2)
- [ ] Connection manager implementation
- [ ] SSH profile management
- [ ] Authentication handling (keys, passwords)
- [ ] Host key verification
- [ ] Port forwarding implementation
- [ ] Tunnel lifecycle management
- [ ] Connection retry logic
- [ ] Standard SSH config file support
- [ ] Security: credential handling (no logging)

### Phase 5 - Lua Scripting (Lower Priority)
- [ ] Lua state initialization
- [ ] C API bindings for Lua 5.4
- [ ] Lua API design and implementation
- [ ] Hook system (startup, command execution, etc.)
- [ ] Configuration loading from Lua files
- [ ] Plugin system architecture
- [ ] Sandboxing for dangerous operations
- [ ] Error handling and reporting
- [ ] API documentation for script authors
- [ ] Example scripts and plugins

### Main Event Loop
- [x] Event loop architecture
- [x] Keyboard input handling
- [ ] Mouse input handling
- [x] Rendering loop integration (GPU text pipeline with blit/XPutImage fallback)
- [x] Event dispatching to subsystems
- [x] Graceful shutdown handling
- [x] Signal handling (SIGTERM, SIGINT, etc.)

### Testing & Quality
- [x] Unit tests for terminal emulation (basic)
- [x] Unit tests for ANSI parser (basic)
- [ ] Integration tests for PTY handling
- [ ] Rendering tests
- [ ] AI integration tests
- [ ] SSH connection tests
- [ ] Lua scripting tests
- [ ] Cross-platform testing (Linux, macOS, Windows)
- [ ] Performance benchmarks
- [ ] Memory leak detection
- [x] CI/CD pipeline setup

### Configuration & UX
- [x] Configuration file loading (from ~/.config/death-terminal/; reads `config.txt` with flat `key = value` lines; `config.example.lua` is not read yet)
- [ ] Theme system implementation
- [ ] Keybinding customization
- [x] Font selection and management (real fonts + optional retro 8x8 bitmap font)
- [ ] Fonts on macOS/Windows (FreeType is Linux-only for now; other platforms use the retro font)
- [ ] Emoji ZWJ sequences / flags composed into one glyph
- [ ] Color scheme support
- [ ] Terminal size configuration
- [ ] Preferences persistence

### Additional Features
- [ ] Copy/paste functionality
- [ ] Search in scrollback (search function exists, no UI)
- [ ] Scrollback navigation (Shift+PageUp/PageDown)
- [ ] Tabs and splits
- [ ] Hyperlink detection and handling
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
- [ ] Release automation
- [ ] Package managers (Homebrew, AUR, etc.)
- [ ] macOS window backend

## 📊 Current Status Summary

**Overall Progress**: ~40% (basic terminal core + Wayland/X11/Win32 GUI + HiDPI + GPU SPIR-V text pipeline; no UTF-8, full-screen app support, AI, SSH, or Lua yet)

**Lines of Code**:
- terminal/terminal.zig: 650+ lines (PTY + ANSI parser + scrollback)
- terminal/scrollback.zig: scrollback history buffer
- terminal/ansi_parser.zig: 400+ lines (complete VT100/ANSI escape sequence parser)
- app/event_loop.zig: headless + GUI PTY event loop
- config/config.zig: runtime configuration
- renderer/vulkan_renderer.zig: loader-backed instance/device init
- renderer/loader.zig: DynLib Vulkan loader (`vkGetInstanceProcAddr`)
- renderer/text_pipeline.zig: SPIR-V glyph pipeline
- renderer/text_renderer.zig: cell instance packing
- renderer/pipeline.zig: shader module + embedded SPIR-V
- renderer/gpu_present.zig: swapchain creation, acquire/present (the real swapchain; the old `swapchain.zig` stub was removed)
- renderer/software.zig: CPU rasterizer fallback
- main.zig: CLI + subsystem wiring
- ssh/tunnel.zig: 70 lines (stub)
- ai/autocomplete.zig: 55 lines (stub)
- scripting/lua_engine.zig: 48 lines (stub)

**Next Immediate Steps**:
1. ✅ Implement PTY + terminal emulation (Phase 1) - COMPLETED
2. ✅ Main event loop with headless rendering - COMPLETED
3. ✅ Vulkan function loading + instance/device init - COMPLETED
4. ✅ Window management (X11/Wayland/Win32 present + keys) - COMPLETED
5. ✅ Connect GPU rendering to terminal output (swapchain blit) - COMPLETED
6. ✅ SPIR-V text pipeline (glyph atlas + instanced draw) - COMPLETED
7. ✅ HiDPI cell scaling (`--scale`, DPI, compositor buffer scale)
8. ✅ UTF-8 + wide characters
9. Full-screen app escape sequences (vim/htop/less/tmux)
10. Real fonts, selection/copy-paste, scrollback navigation
11. Lua config, AI suggestions, SSH, plugins, tabs/splits, packaging
