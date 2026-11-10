# Cursor Prompt — Death Terminal Fix List

You are working in the YouNeeK Death Terminal repo (Zig 0.13, build.zig). Fix everything below in priority order. Do not skip items or mark them done without evidence — run the relevant build/test step and report the actual output.

## 1. Runtime testing on macOS (highest priority)

- Build and run on aarch64-macos (native, not cross-compile): `zig build -Dtarget=aarch64-macos`, then launch the GUI binary.
- Verify: Vulkan instance + device come up via MoltenVK (check loader resolves libMoltenVK next to the exe and in ../Frameworks), window opens, swapchain presents, text renders with the embedded JetBrains Mono font.
- Test keyboard input: command palette (Cmd+Shift+P), tabs (Cmd+T), copy/paste (Cmd+C/V/A), quit (Cmd+Q), Time Travel (Cmd+Option+T).
- Test PTY: spawn a shell, type commands, confirm VT output (clear, title, cursor movement) renders correctly.
- Specifically investigate and fix if broken:
  - Live resize: AppKit nested loop during resize — grid should catch up after.
  - IME / dead keys: `interpretKeyEvents` is not used.
  - Retina scale changes between displays — the view's backing scale factor should update without a restart.
- Document whatever you find in docs/PLATFORMS.md under the macOS section, including any crash logs or stderr output.

## 2. Runtime testing on real Windows

- If you have access to a Windows machine (or can use a VM), build with `zig build -Dtarget=x86_64-windows` and test: ConPTY shell I/O (cmd.exe and pwsh.exe), ResizePseudoConsole on window resize, clipboard round-trip, URL opening via ShellExecuteW, and the config watcher via FindFirstChangeNotification.
- If no real Windows box is available, note that in the report and do not fake results. Wine-only verification is already documented.

## 3. Missing test coverage

- Integration tests for PTY handling.
- Rendering tests (glyph atlas, instanced draw, damage tracking).
- Lua scripting tests (plugin host, sandbox, hooks).
- Performance benchmarks.
- Memory leak detection (valgrind or similar on Linux).
- Cross-platform test matrix: Linux done; Windows under Wine; macOS compile-only — extend where possible.

## 4. Open feature gaps (from ISSUES.md)

- DECCOLM 80/132 switching side effects, left/right margins (DECSLRM), double-size lines.
- Blinking text.
- Multi-line AI suggestions; keep-alive connections.
- SSH certificates (@cert-authority), Match, agent/X11 forwarding, SFTP.
- Recursive ProxyJump for hops; partial-success multi-factor chains get no special UI.
- macOS/Windows builds of the SSH client (Linux only for now).
- Plugin hot reload of `require`d modules (only manifest/init.lua mtimes trigger a restart).
- SSH hooks for `ssh` run inside a local shell (only the built-in client reports).
- Colour emoji from sbix/CBDT fonts (Apple Color Emoji) on macOS/Windows: needs libpng in the FreeType build.
- Emoji ZWJ sequences / flags composed into one glyph.
- Preferences persistence.
- Tabs: SSH profile themes in tabs/splits (only new windows get the profile theme).
- Tabs: detach a pane into its own window / move panes between tabs.
- Tabs: session restore of layouts on restart.
- Image protocol support (optional).
- Notifications.
- Session persistence.

## 5. Documentation & release

- API documentation generation.
- Wiki for in-depth guides.
- Troubleshooting guide.
- Video demos or GIFs.
- Community chat setup.
- Runtime testing on real Windows and macOS hardware (ties to sections 1 and 2).

## 6. CodeQL alerts

- Alerts 3 and 4: missing explicit `permissions` blocks in `.github/workflows/ci.yml`. Add a `permissions` key with least privilege (e.g. `contents: read`, plus whatever write scope each job actually needs).
- Alert 2: redundant null check in `vendor/libssh2-1.11.1/src/userauth.c` line 1497. This is upstream vendored code — document it as upstream noise and dismiss the alert rather than patching the vendor tree, unless a local patch mechanism already exists.

## 7. Housekeeping

- ISSUES.md contains a stale status summary claiming ~40% progress with "no UTF-8, full-screen app support, AI, SSH, or Lua yet" — that is outdated. Update the summary to reflect current reality (Phases 1–5 largely complete).
- Keep this file (CURSOR_PROMPT.md) updated as items get resolved: check them off or move them to a DONE section with dates.
