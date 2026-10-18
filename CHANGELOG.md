# Changelog

All notable changes to DeathTerminal will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Real font rendering (Linux): FreeType rasterisation, HarfBuzz shaping with ligatures, fontconfig family lookup and per-codepoint fallback (CJK, colour emoji via Noto Color Emoji, monochrome symbols)
- Bundled JetBrains Mono (OFL 1.1) Regular/Bold/Italic/BoldItalic; synthetic bold/oblique when a family lacks a face
- Dynamic glyph atlas shared by the Vulkan and software renderers: rasterised on demand, shelf-packed, grows 512→2048, reset + frame rebuild when full; dirty-rect GPU uploads
- Procedural box drawing, block elements, braille and powerline glyphs that line up across cells
- Underline styles (SGR 4:1–4:5, 21) and underline colour (SGR 58/59); hollow cursor when unfocused
- Config keys `font = retro|default`, `font_family`, `font_size`, `line_height`, `font_ligatures`, and matching `--font`, `--font-family`, `--font-size`, `--line-height` flags
- Runtime zoom with Ctrl+= / Ctrl+- / Ctrl+0 (grid and PTY resize); HiDPI scale applied to font size
- `docs/FONTS.md`
- xterm-compatible VT emulation for full-screen apps: DECSTBM scroll regions with SU/SD/IND/RI/NEL, IL/DL/ICH/DCH/ECH/REP, insert mode, tab stops (HTS/TBC/CHT/CBT), origin mode, DECAWM, DECSC/DECRC and `CSI s`/`u`, alternate screens (?47/?1047/?1049), DEC special graphics (`ESC ( 0`, SO/SI), DECALN, RIS/DECSTR
- 256-colour and true-colour SGR (semicolon and colon forms), faint, inverse, strikethrough, hidden; erase uses the current background
- Replies: DA1, DA2, DSR/CPR (incl. DECXCPR), DECRQM, XTVERSION, OSC 10/11 colour queries
- OSC 0/2 titles (window title follows the shell on X11/Wayland/Win32), OSC 7 cwd, OSC 8 hyperlinks (length/count bounded, control bytes rejected)
- DECSCUSR cursor shapes (block/underline/bar) in both renderers; underline and strikethrough drawn
- Key encoding per xterm: DECCKM, keypad application mode, SS3 F1–F4, modifier parameters, Alt as ESC prefix
- GUI mouse reporting (?1000/?1002/?1003, legacy and SGR ?1006 encodings), focus reports (?1004), wheel → arrow keys in the alternate screen when mouse reporting is off
- Bracketed paste encoder (?2004) with embedded end-marker stripping
- Shell environment sets `TERM=xterm-256color`, `COLORTERM=truecolor`, `TERM_PROGRAM=DeathTerminal`
- `src/terminal/vt_test.zig` emulation tests, `tools/headless_drive.py`, `docs/VT_SUPPORT.md`

### Fixed
- Ctrl+C in the GUI is sent to the shell (0x03) instead of closing the window
- The shell starts with default signal dispositions and an empty mask, so Ctrl+C works even when DeathTerminal was launched with SIGINT ignored
- `ESC[m` resets attributes; `ESC ( B` no longer prints `B`; DCS/APC/PM/SOS strings are swallowed; ST-terminated OSC works; empty/zero CSI params default correctly; huge params saturate; `38;5;n` uses the full 256 palette; private-marker CSI (e.g. XTMODKEYS `CSI > 4 ; 1 m`) is no longer treated as SGR; ED 2 no longer homes the cursor (xterm behaviour)

### Added
- UTF-8 decoding in the parser (split-chunk safe; malformed, overlong, and surrogate sequences become U+FFFD)
- Grid cells store codepoints with a column width: wide chars (East Asian wide/fullwidth, emoji) take 2 cells, combining marks attach to the previous cell
- `src/terminal/unicode.zig` width lookup over tables generated from Unicode 15.1 (`tools/gen_unicode_width.py`)
- Headless output, `visibleText`, and scrollback search are UTF-8 aware

### Fixed
- Overwriting or erasing half of a wide char no longer leaves an orphaned half
- `ESC[1K` / `ESC[1J` no longer index past the row/grid when the cursor is in the pending-wrap column

### Changed
- Renderers draw a dedicated replacement glyph for non-ASCII codepoints (until real fonts land); wide-char spacer cells draw blank

### Fixed
- Headless redraw keeps blank cells, so spaces and column alignment survive (`echo HELLO_DT` no longer renders as `echoHELLO_DT`)
- Event loop exits cleanly when the shell exits (PTY hang-up / EIO) instead of spinning
- `--no-ai` no longer prints the AI stub initialization message

### Removed
- `vercel.json` / `.vercelignore` (native app, no web deployment)
- Unused `src/renderer/swapchain.zig` stub (the real swapchain lives in `gpu_present.zig`)

### Added
- `src/terminal/grid_test.zig` grid tests (ported from PR #19) and a headless-frame test

### Added
- Wayland window backend (`xdg-shell` + xkbcommon) with Vulkan `VK_KHR_wayland_surface` and SHM fallback
- Win32 window backend with Vulkan `VK_KHR_win32_surface` and GDI fallback
- HiDPI cell scaling via `--scale`, `DT_SCALE`/`GDK_SCALE`/`QT_SCALE_FACTOR`, Xft.dpi, Wayland output scale, and Win32 DPI
- `--backend auto|x11|wayland|win32` to force a window backend
- SPIR-V GPU text pipeline: glyph atlas, instanced cell quads, `vkCmdDrawIndexed`
- Window resize recreates the swapchain and resizes the PTY grid
- Real Vulkan loader (`vkGetInstanceProcAddr`) with instance creation and optional device selection
- X11 window backend with `XPutImage` present and keyboard-to-PTY translation
- Software cell rasterizer (`src/renderer/software.zig`) used as a blit/XPutImage fallback
- Vulkan swapchain present: copies the software framebuffer to the GPU and `vkQueuePresentKHR`s it
- Headless terminal event loop with PTY polling and stdin forwarding
- Scrollback buffer for terminal history (`src/terminal/scrollback.zig`)
- Runtime configuration module with CLI and file loading (`src/config/config.zig`)
- GitHub Actions CI workflow for build and test
- DeathTerminal-focused `DEVELOPMENT.md` guide

### Changed
- Updated terminal core for Zig 0.13 POSIX APIs
- Main entry point now runs the real event loop instead of a placeholder sleep
- Fixed ANSI parser duplicate switch case and Execute action typing for Zig 0.13

### Removed
- Cross-repository `REPOSITORY_AUDIT.md` (Base44/Vercel deployment audit unrelated to this project)

### Added (prior releases)
- build.zig.zon for dependency management
- Modular architecture with core subsystems:
  - **Terminal emulator core** - Fully functional PTY + ANSI/VT100 parser (Phase 1 complete)
  - **Vulkan renderer module** - Complete structural foundation for GPU rendering (Phase 2 in progress)
    - Vulkan instance and device management
    - Swapchain for presentation
    - Graphics pipeline infrastructure
    - Glyph atlas system for text rendering
    - Text rendering pipeline with vertex generation
  - AI autocomplete via gRPC stub
  - SSH tunneling module stub
  - Lua scripting engine stub
- Terminal Core (Phase 1):
  - PTY (pseudo-terminal) creation and management
  - Process spawning with shell integration
  - Complete ANSI/VT100 escape sequence parser
  - Terminal buffer management with cell-based rendering
  - Input/output handling
  - Cursor movement and control
  - Cross-platform PTY compatibility (Unix/Linux/macOS support)
  - Color support (16-color ANSI palette)
  - Text attributes (bold, italic, underline)
  - Screen manipulation (scroll, clear, erase)
- Comprehensive README with build instructions
- Example Lua configuration file
- Contributing guidelines with Conventional Commits
- MIT License
- Project checklist (ISSUES.md) tracking implementation progress

### Changed
- Updated build.zig to link against system Vulkan library
- Enhanced ISSUES.md with detailed Phase 2 progress tracking

### Deprecated
- N/A

### Removed
- N/A

### Fixed
- N/A

### Security
- N/A

## [0.1.0] - TBD

### Added
- Initial alpha release
- Basic terminal emulation
- Vulkan-accelerated rendering
- Cross-platform support (Linux, macOS, Windows)

---

**Legend:**
- `Added` for new features
- `Changed` for changes in existing functionality
- `Deprecated` for soon-to-be removed features
- `Removed` for now removed features
- `Fixed` for any bug fixes
- `Security` in case of vulnerabilities
