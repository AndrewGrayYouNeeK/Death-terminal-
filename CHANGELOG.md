# Changelog

All notable changes to YouNeeK Death Terminal will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Ask the Output (`Ctrl+Shift+Q`, `Cmd+Shift+Q` on macOS; `Cmd+Q` still quits): a prompt bar sends the redacted selection, last command output, or visible screen to the configured model and highlights the cited lines. `config.ai.ask.enabled` and `config.ai.ask.max_lines` (default 200) control it. Long output is truncated with a note; an unreachable endpoint says "AI offline"
- GitHub Pages download page at https://andrewgrayyouneek.github.io/Death-terminal-/ (`site/`). `.github/workflows/pages.yml` deploys it with `actions/deploy-pages` on push to `main`. The page reads the latest published release and falls back to the Releases page. The owner sets Settings → Pages → Source to GitHub Actions once (`actions/configure-pages` cannot do that with `GITHUB_TOKEN`)
- Bundled `youneek-time` plugin: a YouNeeK Time status segment (civil hour, 100 minutes per hour, `#7CFF6B`, local suncalc moon phase). The status bar is on by default. `config.plugins["youneek-time"]` can disable it, switch to regular `HH:MM`, pick 12/24h, set a timezone, and turn on an hourly toast (`settings.chime`, off by default)
- The release workflow signs and notarizes macOS `.app` / `.dmg` artifacts on `macos-latest` when the Apple secrets in `packaging/SIGNING.md` are all set (Developer ID, hardened runtime, `notarytool`, staple). The cross build bundles MoltenVK 1.4.2 (`libMoltenVK.dylib` and `MoltenVK_icd.json` in `Contents/Frameworks`). The loader resolves that directory from the executable because `dlopen` does not expand `@executable_path`. The signing job signs that dylib and fails if it is missing. If any Apple secret is missing the workflow uploads the unsigned artifacts and still succeeds. Windows signing is unchanged. The linux release job also installs `mesa-vulkan-drivers` so the Vulkan instance test passes without a GPU
- Installable desktop packages from `zig build release -Dpackages=true`: macOS `.app` plus `.dmg` (`packaging/macos/make-dmg.sh`; `hdiutil` on a Mac, HFS-hybrid UDIF on Linux), Windows NSIS setup exe with the app icon and a Start Menu shortcut (`packaging/windows/build-installer.sh`), alongside the existing Linux AppImage, `.deb` (installs `deathterminal.desktop`) and `.rpm`. The tag release workflow uploads them
- `docs/MOBILE.md`: iOS/Android plan. No mobile target is built
- Grok 4.7 on `api.x.ai` and `us.api.x.ai` (the model Grok Bot uses) goes through the Responses API: `reasoning.effort` defaults to `low` (`config.ai.reasoning`: `low` / `medium` / `high` / `xhigh`), live search is off, responses are not stored, and reasoning text is not shown as the suggestion. `ai.max_tokens` is sent as `max_output_tokens`, which caps the visible answer. Other endpoints stay on chat/completions. xAI requests wait at least 15s; `ai.timeout_ms` now allows up to 600000

### Fixed
- GitHub Actions CI matches the build: `.github/workflows/ci.yml` installs FreeType, HarfBuzz, fontconfig and libssl, and cross-compiles Windows and macOS. `.github/workflows/release.yml` publishes a draft release on a `v*` tag. The previous workflow was missing those packages, so `zig build` failed on GitHub the same way it did on `main`

## [0.1.0] - 2026-10-17

First versioned release. Everything below (milestones 1–12) ships in it.

### Changed
- Version 0.1.0 comes from `build.zig` (`-Dversion=` to override); `--version`, `dt.version` and the packages use it (the plugin API used to report 0.11.0)
- Vulkan is no longer linked: the loader is always opened at run time and the headers are vendored (`vendor/vulkan-headers`, v1.4.309), so builds need no Vulkan SDK
- DECCOLM (`CSI ?3 h/l`) now really switches 80/132 columns in headless mode when `window.allow_column_switch` (default true) and `?40` allow it; GUI panes keep their layout width and get the clear/home/margin reset only. vttest's 132-column screens pass headless
- X11 windows set WM_CLASS `deathterminal` (matches the .desktop file)
- The SSH tunnel-manager stub (`src/ssh/tunnel.zig`) is replaced by the real client
- The AI client is HTTP/JSON (OpenAI-compatible) instead of the originally planned gRPC service; the gRPC stub (`src/ai/autocomplete.zig`) is gone
- `select_all` moved from Ctrl+Shift+A to Ctrl+Shift+Alt+A (Ctrl+Shift+A is now `ai_explain`)

### Deprecated
- `config.txt` (`key = value`): still read when no config.lua exists, with a warning

### Fixed
- AI "offline" with endpoints that answer HTTP/1.0 or `Connection: close` and label an SSE stream as `application/json` (or send no Content-Type): the body is now sniffed (`data:` vs `{`), so these replies are parsed instead of failing as bad JSON. Close-delimited and Content-Length bodies are covered by tests
- Windows: AI requests can now time out and be cancelled. std's socket reads (ReadFile) ignore SO_RCVTIMEO and can't be interrupted, so requests go through a small relay thread
- Windows: plugin directories are under `%APPDATA%` and `%LOCALAPPDATA%` instead of a relative `.config` path when HOME is unset
- Windows: `config.example.lua` no longer sets `links.open_command = "xdg-open"`
- Windows: each wait in the event layer gets its own socket event, so concurrent waiters don't steal each other's wake-ups
- Plugin status text treats CRLF as one line break

### Added
- Windows: ConPTY PTY (pwsh → powershell → %COMSPEC%, or `config.shell.program`), socket-based event loop with zero idle CPU, Win32 clipboard and `ShellExecuteW` URL opening, FreeType + HarfBuzz built from source with a Windows font-folder scan, config in `%APPDATA%\death-terminal`, config watching, exe icon + version info. Cross-compiles with `zig build -Dtarget=x86_64-windows`; checked under Wine 10 (GUI, Vulkan, fonts, input) — see docs/PLATFORMS.md for what could not be verified
- macOS: Cocoa window backend (AppKit via dlopen, CAMetalLayer + MoltenVK through `VK_EXT_metal_surface`, CoreGraphics software fallback), NSPasteboard clipboard, Cmd shortcuts, posix PTY on Darwin, kqueue config watching, font-folder scan. Cross-compiles for aarch64/x86_64; **untested at runtime**
- `window.allow_column_switch` and DECSET 40; DECRQM reports modes 3 and 40
- `zig build release`: stripped ReleaseFast staged tree + .tar.gz/.zip + SHA256SUMS in `zig-out/release`; `-Dpackages=true` adds the AppImage, .deb and .rpm (nfpm)
- Packaging: .desktop file, skull/terminal icon (SVG + PNG 16–512, .ico), man page `deathterminal(1)`, AUR PKGBUILD, winget manifests, WiX MSI skeleton, macOS `.app` script, Homebrew cask and formula (packaging/README.md)
- CI workflow updates (font/SSH deps, cross-compile checks) and a release workflow, kept in `packaging/ci/` and installed under `.github/workflows/`
- Tabs and split panes (docs/TABS.md): every pane has its own PTY, grid, scrollback, selection, search and AI context. Layout tree with right/down splits, resize from the keyboard (Alt+Shift+arrows) or by dragging dividers, directional (Alt+arrows) and click focus, zoom (Ctrl+Shift+Z), equalize, close pane
- Tab bar (`config.tabs.bar` = auto/top/bottom/hidden): themed, title + cwd, bell / failed / running / activity markers, close buttons, `+`, drag to reorder, double-click (or Ctrl+Shift+Alt+R) to rename, wheel to cycle; new/close/next/prev/move/goto-N actions
- New tabs and panes start in the focused pane's OSC 7 directory (`config.tabs.inherit_cwd`); SSH palette opens profiles in a tab (Enter), split (Shift+Enter) or window (Alt+Enter)
- `config.tabs.dim_inactive` fades unfocused panes; `config.tabs.confirm_close` asks before closing a pane/tab/window with a running program (foreground process group)
- `config.layout`: startup tabs with nested splits, ratios, cwd, commands, SSH targets and initial focus
- Plugins: tab_new/tab_close/tab_focus/pane_new/pane_close/pane_focus events, `pane`/`tab` ids in payloads, `dt.tabs.*`, `dt.panes.*`, `dt.term.tab()/pane()`, all tab/pane actions via `dt.action`; the command palette lists tabs and the new actions
- Lua plugins (`~/.config/death-terminal/plugins/<name>/{manifest.lua,init.lua}`): each runs in its own sandboxed Lua state with memory and per-callback CPU limits (enforced even through `pcall`), and gets only the permissions granted in `config.plugins.<name>.allow` (`screen`, `input`, `pty`, `clipboard`, `network` + `hosts`, `exec` + `exec` allowlist, `fs` in its data dir, `ai`)
- Hooks: startup, config_reload, shutdown, key (can consume), command_start / command_finish with exit code and duration (OSC 133), output_line, cwd, title, bell, focus, ssh_connect / ssh_disconnect (built-in client, OSC 7799 with a per-window nonce), ai_suggestion (filter / rewrite)
- Plugin API: palette commands, keybindings, status-bar segments, toasts (+ desktop notifications), timers, custom themes, built-in actions, async HTTP and exec, scoped files, `require` within the plugin
- Errors are contained: logged with tracebacks to `plugins.log`, shown as toasts, and a plugin with 5 errors in 60 s is disabled for the session
- Command palette (Ctrl+Shift+P, `command_palette`): plugin commands and every built-in action with its chord. The SSH palette shares the same widget
- Optional status bar (`config.status_bar.enabled`, Ctrl+Shift+B `toggle_status_bar`)
- `deathterminal --plugins list|enable|disable`, `--no-plugins`, `config.plugins_enabled`, `config.plugins_dir`
- Example plugins: `git_branch`, `long_command`, `theme_cycle`; docs/PLUGINS.md
- Built-in SSH via libssh2 1.11.1 (vendored, built by `zig build`, links system libcrypto): `deathterminal --ssh <profile|~/.ssh/config Host|user@host[:port]>` opens a window running the client; `--ssh-session` runs it in any terminal
- `config.ssh.profiles` (host, port, user, identity_file, jump/ProxyJump, env, command, theme, forwards, keepalive_s, reconnect) with validation, and `config.ssh.known_hosts`; `~/.ssh/config` parsing (Host patterns, HostName, User, Port, IdentityFile, ProxyJump, Include)
- Auth: ssh-agent, public keys incl. encrypted (passphrase prompt), keyboard-interactive, password, all drawn in-terminal; secrets are wiped from memory and never logged or stored
- Host-key verification against known_hosts: SHA256 fingerprint, accept and save / once / reject for unknown hosts, a hard block on changed or revoked keys
- Remote PTY with window-change on resize, env requests, exit status (128+signal, 255 for connection errors), keepalives with dead-peer detection, optional reconnect with backoff
- Port forwarding: local (-L), remote (-R) and dynamic SOCKS4/4a/5 (-D), per profile or on the command line; toggled at runtime from the Ctrl+Shift+S palette (`ssh_palette`) or `deathterminal --ssh-ctl <pid> list|toggle|on|off|add|status|reconnect`
- Ctrl+Shift+S palette: the session's forwards, Reconnect, and every profile / `~/.ssh/config` alias (opens a new window)
- AI context marks SSH sessions as remote ("over SSH to user@host"); redaction unchanged
- `zig build test-ssh`: integration tests against local sshd instances (auth methods, host-key paths, forwarding via curl, resize, reconnect); docs/SSH.md

- AI command suggestions over an OpenAI-compatible chat/completions endpoint (HTTP/JSON with SSE streaming; default local Ollama `qwen2.5-coder:0.5b` at `http://localhost:11434/v1`), replacing the stub. Dim ghost text after the cursor; Tab (`ai.accept_key`) accepts, Esc dismisses, Alt+] / Alt+[ cycle alternatives; never inserted without accept
- "Explain / fix last error" (Ctrl+Shift+A, `ai_explain`): streaming overlay with the cause and a corrected command
- Background AI worker thread with cancel-on-keystroke and debounce; an unreachable endpoint shows an "AI offline" badge and backs off (5–60 s) instead of erroring
- Context: typed input, cwd (OSC 7), last commands with exit codes, recent output, shell, OS; secrets (provider tokens, AWS/GitHub/OpenAI keys, JWTs, PEM keys, passwords, auth headers, `KEY=value` assignments, URL credentials, random-looking strings) are redacted before sending
- `ai.*` options: `endpoint`, `model`, `api_key_env` (env var name; keys are rejected), `timeout_ms`, `debounce_ms`, `max_tokens`, `explain_max_tokens`, `history`, `output_lines`, `accept_key`
- OSC 133 shell integration for bash/zsh/fish (`shell-integration/`), injected automatically (`shell.integration`), `--print-shell-integration <shell>`; the terminal tracks prompt input, commands, exit codes and output
- docs/AI.md
- Lua 5.4 configuration: `~/.config/death-terminal/config.lua` (XDG paths, `--config`), Lua 5.4.7 vendored and built by `zig build` (no system dependency)
- Typed config API covering every option (window, font, theme/colours/palette, cursor, render, scrollback, selection, clipboard/OSC 52, links, keys, shell program/args/env/cwd, AI and SSH placeholders), with `dt.theme()`, `dt.bind()`, `dt.themes`, `dt.os`
- Validation errors with `file:line` and "did you mean" hints, shown in a notice bar in the window (Esc dismisses) and on stderr; a broken config falls back to the defaults at startup and keeps the previous settings on reload
- Live reload when config.lua is saved (inotify, debounced) and with Ctrl+Shift+R (`reload_config`); theme, fonts, cursor shape, present mode, FPS cap and bindings apply live
- Bundled themes: default, death, dracula, gruvbox-dark, nord, solarized-dark, solarized-light; indexed/default colours resolve at render time so theme changes recolour existing text
- `deathterminal --print-default-config`; `config.example.lua` is now real and documented; `docs/CONFIG.md`
- Config sandbox: no io / os.execute / require / debug, text-only `load`, 64 MiB memory cap and an instruction limit; `--lua-unsafe` opts out
- `shell.program/args/env/cwd`; `cursor.shape` sets the DECSCUSR 0 default
- Frame pacing: 2 frames in flight with per-slot fences/semaphores, no per-frame `vkQueueWaitIdle`; `present_mode = fifo|mailbox|immediate|fifo_relaxed` (or `vsync = true|false`) with fallback to what the surface supports; `max_fps` cap while output streams; the GUI loop sleeps in `poll(-1)` when nothing changes (0 CPU ticks over 10 s idle)
- Damage tracking: per-row quad caches, only rows whose cells/marks/cursor changed are re-shaped; unchanged frames are not drawn; GPU instance uploads cover only damaged ranges; the software renderer redraws only dirty row bands
- Instanced cell drawing: 32-byte instances (was 64) in pixel units with push constants, one draw per frame, persistently mapped per-frame instance buffers; glyph-atlas uploads are recorded into the frame's command buffer
- PTY read coalescing: 64 KiB reads, parse up to `read_budget_kb` (default 1024) or ~8 ms per batch, then service input and draw
- `zig build bench` (parser MiB/s, frame build/damage/raster timings, streaming, reflow) and `docs/PERFORMANCE.md`
- Reflow on resize: soft-wrapped lines (screen and scrollback) are re-wrapped to the new width, wide characters kept intact; the alternate screen is cropped
- Search matches span soft-wrapped rows and refresh incrementally as output arrives
- Mouse selection: drag, double-click word, triple-click line, Shift+click extend, Ctrl+Alt/Alt+drag block; wide-char aware, joins soft-wrapped rows, anchored to absolute lines so it survives scrolling; Shift overrides application mouse reporting
- Clipboard: CLIPBOARD and PRIMARY on X11 (incl. INCR receive) and Wayland (data-device + primary-selection-unstable-v1), CF_UNICODETEXT on Win32; `copy_on_select`; paste via Ctrl+Shift+V, Shift+Insert, middle-click with bracketed paste; multi-line paste prompt (`paste_confirm`)
- OSC 52 set and (opt-in, `osc52 = read-write`) query
- Scrollback viewport: Shift+PgUp/PgDn, Shift+Home/End, Ctrl+Shift+Up/Down, mouse wheel on the normal screen, optional scrollbar
- Search overlay (Ctrl+Shift+F): incremental highlight, older/newer, case toggle, POSIX regex
- Ctrl+click opens URLs and OSC 8 links via `url_open_command` (default `xdg-open`, no shell)
- Configurable keybindings (`keybind = chord=action`) and selection colours; `docs/SELECTION.md`
- Scrollback is a ring buffer with O(1) line recycling
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
- AI requests now honour `ai.timeout_ms` during name resolution and connect (`src/net/dial.zig`); an unroutable endpoint no longer blocks the worker until the OS gives up
- Scrolling no longer copies the whole screen per line (row map), scrollback stores trimmed lines: `cat` of a 23 MB file in the GUI takes 1.8 s instead of 18.4 s
- The selection is cleared when output rewrites the selected text
- The search bar no longer hides the prompt on the last row
- Headless mode puts the controlling tty in raw mode, so Ctrl+C reaches the shell instead of quitting YouNeeK Death Terminal; the tty is restored on exit
- Ctrl+C in the GUI is sent to the shell (0x03) instead of closing the window
- The shell starts with default signal dispositions and an empty mask, so Ctrl+C works even when YouNeeK Death Terminal was launched with SIGINT ignored
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
- YouNeeK Death Terminal development guide (`DEVELOPMENT.md`)

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
  - AI autocomplete via gRPC stub (replaced by the HTTP/JSON client in Unreleased)
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
