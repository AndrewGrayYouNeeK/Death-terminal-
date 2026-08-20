# AGENTS.md

## Cursor Cloud specific instructions

DeathTerminal is a single native desktop **terminal emulator** written in **Zig 0.13.0**. There is no web server, database, or listening port — it spawns a shell in a PTY and (in the default headless mode) renders the terminal grid to stdout. There is only one product/binary (`deathterminal`); it is not a monorepo.

### Toolchain / system deps (already provided by the environment)

- `zig` 0.13.0 is installed at `/usr/local/lib/zig` and symlinked to `/usr/local/bin/zig` (on `PATH`). The startup update script re-installs it only if missing.
- `libvulkan-dev` (apt) is required to link — `build.zig` calls `exe.linkSystemLibrary("vulkan")`. Only the loader is used; actual Vulkan rendering is stubbed, so no GPU is needed.
- Lua/SSH/AI subsystems are stubs and are NOT linked or required. `liblua5.4-dev` mentioned in the docs is aspirational and not needed to build.

### Standard commands (see `DEVELOPMENT.md`, `dev.sh`, `.github/workflows/ci.yml`)

- Build: `zig build` → binary at `zig-out/bin/deathterminal`
- Test: `zig build test` (or `zig build test --summary all`)
- Format check (lint): `zig fmt --check src build.zig`
- Run: `zig build run -- <args>` or `./zig-out/bin/deathterminal <args>` (e.g. `--no-ai`, `--help`, `--version`)
- `dev.sh` is a convenience wrapper (`./dev.sh build|test|run|format|clean`).

### Non-obvious gotchas

- The app puts stdin into **raw mode via `tcgetattr`**, so it requires a real TTY. Piping (`echo ... | deathterminal`) fails with a terminal error. To drive it non-interactively, run it under a PTY (e.g. a Python `pty.fork()` harness, `script`, `expect`, or a `tmux` pane) and send keystrokes; exit with Ctrl+C (`0x03`).
- Headless renderer clears the screen (`\x1b[H\x1b[2J`) on every frame, so only the current grid state is visible in the latest frame; earlier command output scrolls off. Assert against the full captured byte stream, not just the final frame.
- Use `--no-ai` when running: the AI autocomplete expects a gRPC server at `localhost:50051` which is not present (it is a stub, but disabling avoids the dependency entirely).
- On clean exit the GeneralPurposeAllocator prints a harmless memory-leak trace for `config.ai_endpoint` (`src/config/config.zig`). This is a pre-existing minor issue and does not affect functionality.
