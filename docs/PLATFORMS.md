# Platforms

| | Linux | Windows | macOS |
|---|---|---|---|
| Window | Wayland, X11 | Win32 | Cocoa (AppKit, loaded at run time) |
| GPU | Vulkan (`libvulkan.so.1`) | Vulkan (`vulkan-1.dll`) | Vulkan via MoltenVK (`VK_EXT_metal_surface` on a `CAMetalLayer`) |
| Software fallback | XPutImage / wl_shm | DIB section | CGImage as the layer contents |
| PTY | posix pty | ConPTY | posix pty |
| Default shell | `$SHELL` | `pwsh.exe`, then `powershell.exe`, then `%COMSPEC%` | `$SHELL` |
| Fonts | FreeType + HarfBuzz + fontconfig (system) | FreeType + HarfBuzz (built from source) + font-folder scan | same as Windows |
| Clipboard | CLIPBOARD + PRIMARY | Win32 clipboard; PRIMARY emulated in-process | NSPasteboard; PRIMARY emulated |
| URL open | `xdg-open` | `ShellExecuteW` | `open` |
| Config reload | inotify | `FindFirstChangeNotification` | kqueue |
| Built-in SSH | yes | no (`--ssh` reports unsupported) | no |
| Tested | yes | under Wine 10 (see below) | **compile only** |

The Vulkan loader is always loaded at run time (no `-lvulkan`). The headers are
vendored in `vendor/vulkan-headers` (Vulkan-Headers v1.4.309), so no Vulkan SDK
is needed to build for any target.

## Windows

```sh
zig build -Dtarget=x86_64-windows                              # Debug
zig build release -Dtarget=x86_64-windows -Dpackages=true  # zip + NSIS setup exe
```

The setup exe is `deathterminal-<ver>-x86_64-setup.exe` (per-user, Start Menu
shortcut runs `--gui`, same icon as the exe). It is unsigned
(`packaging/SIGNING.md`). WiX remains an optional skeleton and is not built.

- **Config:** `%APPDATA%\death-terminal\config.lua`.
- **Shell:** pick it with `config.shell.program` (for example `"cmd.exe"` or `"pwsh.exe"`) and `config.shell.args`.
- **Fonts:** the bundled JetBrains Mono is the default. `font.family` is matched against the fonts in `%WINDIR%\Fonts` and `%LOCALAPPDATA%\Microsoft\Windows\Fonts`. The `monospace` fallback tries Cascadia Mono, then Consolas. Glyph fallback covers Segoe UI Symbol and Segoe UI Emoji (COLR).
- **Waiting:** everything the event loop waits on is a socket. A ConPTY reader thread pumps the output pipe into a loopback socket pair, and `MsgWaitForMultipleObjectsEx` also wakes the loop on window messages. Idle CPU stays at zero.
- **Executable:** the `.exe` carries an icon and version info (`packaging/windows/deathterminal.rc`).

### What was verified under Wine 10.0 (on the Linux build box)

- `--version` and `--help` work.
- **Headless:** the Vulkan instance and device come up (winevulkan → llvmpipe). A pseudo console is created, and its VT output (clear, title) arrives through the reader-thread → socket path.
- **GUI:** the Win32 window opens and the Vulkan swapchain presents. Text is drawn with the source-built FreeType and HarfBuzz. Keyboard input works: the command palette opens and filters.
- **Not verifiable under Wine:** an interactive shell inside ConPTY. Wine 10 does not connect a pseudo-console child's standard handles to the console when `STARTF_USESTDHANDLES` is set with null handles. With the flag unset, Wine passes the child our own handles instead. Either way `cmd.exe` exits at once. Real Windows connects them, and that is what the code relies on (the flag is set as Microsoft documents). **Shell I/O, resize (`ResizePseudoConsole`), the clipboard, URL opening and the config watcher have therefore not been run on real Windows.**

### Unit tests under Wine

```sh
# Wine 10 ships only `wine`; zig's -fwine runs `wine64`
mkdir -p /tmp/wshim && printf '#!/bin/sh\nexec wine "$@"\n' > /tmp/wshim/wine64 && chmod +x /tmp/wshim/wine64
PATH=/tmp/wshim:$PATH zig build test -Dtarget=x86_64-windows -fwine --summary all
# one area: -Dtest-filter=plugins.host_test (repeatable)
```

Result on Wine 10: **332 passed, 2 skipped, 0 failed** (Linux runs 343,
including the SSH suites, which are Linux-only).

The two skips are POSIX-only code that Windows never runs:
`resolveProgram` (PosixPty; ConPTY resolves the shell itself) and the
termios raw-mode test (no termios on Windows).

What was failing, and why:

| Area | Cause | Fix |
|---|---|---|
| Plugin host, registry, config, Lua config (`error.Unexpected`) | Zig's Windows `realpath` asks the mount manager (IOCTL_MOUNTMGR_QUERY_POINTS), which Wine doesn't implement. Only tests call realpath. | `src/testutil.zig`: `tmpPath`/`cwdPath` build absolute paths from the cwd on Windows. |
| Plugin dir, data and state paths | **Bug:** used `$HOME/.config/...`, so with HOME unset they became relative paths. | `%APPDATA%\death-terminal\plugins`, with data/state in `%LOCALAPPDATA%`; `~` is `%USERPROFILE%`. |
| `config.example.lua` | **Bug:** set `links.open_command = "xdg-open"` on Windows. | `""` on Windows (ShellExecute default handler). |
| AI `chatStream` timeout/cancel hang; engine "new submit cancels" crash | **Bug:** std.net reads sockets with ReadFile, which ignores SO_RCVTIMEO and retries on ERROR_OPERATION_ABORTED. Under Wine, `shutdown()` from another thread doesn't wake it either, and a shutdown during the read makes it fail with ERROR_IO_PENDING, which std treats as unreachable (the crash). | `src/net/relay.zig`: on Windows std talks to a loopback pair, and a relay thread copies bytes, polls cancel and deadline every 50 ms, and closes its end to end the stream. Cancel no longer calls shutdown on Windows. |
| `io.wait` | **Bug:** one global WSA event shared by every thread, so one waiter could reset another's wake-up. | One event per call. |
| Plugin status segments | CRLF from Windows commands showed as two spaces. | CRLF counts as one line break. |
| bash `--rcfile` path, default SSH identity paths | Mixed `\` and `/`. | Always `/`, like the other shells and `~/` expansion. |
| Jobs / async exec, Lua `os.getenv("HOME")`, engine API-key env tests | Tests assumed `sh`, `sleep` and `HOME`. | cmd.exe, `PATH` and `SystemRoot` on Windows. |

## macOS (untested at runtime)

```sh
zig build -Dtarget=aarch64-macos           # or x86_64-macos
zig build release -Dtarget=aarch64-macos -Dpackages=true
# writes zig-out/release/YouNeeK Death Terminal.app, DeathTerminal-<ver>-<arch>.zip
# and DeathTerminal-<ver>-<arch>.dmg (zip and dmg filenames stay DeathTerminal-*)
```

The `.dmg` is an `hdiutil` UDZO image when built on a Mac, and an HFS hybrid
wrapped as UDIF when built on Linux. `make-app.sh` ad-hoc signs with
`codesign -` when that tool exists. The release workflow downloads MoltenVK
1.4.2 into `Contents/Frameworks`, then signs that dylib and the `.app` with
a Developer ID, rebuilds the `.dmg` with `hdiutil`, notarizes, and staples
when the Apple secrets in `packaging/SIGNING.md` are set. When any of those
secrets are missing, the unsigned cross-compiled zip and dmg are what the
draft release gets.

The Cocoa backend (`src/platform/cocoa_backend.zig`) loads libobjc, AppKit, QuartzCore, CoreGraphics and CoreFoundation with `dlopen`. That is why it cross-compiles without an SDK. It uses no delegate and no NSView subclass:

- **Events:** read straight off the AppKit queue. Keys are handled without `sendEvent:`, so unhandled keys don't beep.
- **Cmd shortcuts:** map onto the Ctrl+Shift bindings (Cmd+C/V/T/W…), and Cmd+Q quits.
- **Option:** acts as Meta.
- **Waiting:** a helper thread `poll()`s the PTY and wake fds and posts an application-defined NSEvent. The main thread sleeps in `nextEventMatchingMask:`.
- **Vulkan:** needs MoltenVK. The loader resolves paths next to the executable and in `../Frameworks` (`dlopen` does not expand `@executable_path`), then `/opt/homebrew/lib` and `/usr/local/lib`. The release workflow bundles `libMoltenVK.dylib` and `MoltenVK_icd.json` in `Contents/Frameworks`. The instance enables `VK_KHR_portability_enumeration` and the device enables `VK_KHR_portability_subset` when offered.

None of this has run on a Mac yet. Expect fixes after a first test, especially in the areas below:

- **Live resize:** AppKit runs a nested loop, and the grid catches up afterwards.
- **IME / dead keys:** `interpretKeyEvents` is not used.
- **Retina scale changes** between displays.

## 80/132 columns (DECCOLM)

`CSI ? 3 h` / `CSI ? 3 l` switch to 132 or 80 columns when allowed. Two settings control this:

- `window.allow_column_switch` (default `true`) is the configured policy.
- `CSI ? 40 h` / `CSI ? 40 l` toggle it at run time, as in xterm.

When not allowed, DECCOLM is ignored entirely.

- **Headless:** the grid really changes width, so vttest's 132-column screens pass.
- **GUI panes:** these follow the window layout, so DECCOLM only does what the VT100 does besides the resize: it clears the screen, homes the cursor and resets the margins. The window is not resized.
