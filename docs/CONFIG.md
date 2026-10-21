# Configuration (config.lua)

YouNeeK Death Terminal is configured with a Lua 5.4 file. Lua is vendored
(`vendor/lua-5.4.7`) and compiled into the binary, so there's nothing to install.

```sh
mkdir -p ~/.config/death-terminal
deathterminal --print-default-config > ~/.config/death-terminal/config.lua
```

That file, [`config.example.lua`](../config.example.lua), documents every option
and sets each one to its default, so it changes nothing until you edit it.

## Where the file is looked for

1. `--config <file>`: a `.lua` file is read as Lua. Any other extension is read in the
   legacy `key = value` format.
2. `$XDG_CONFIG_HOME/death-terminal/config.lua`. If `XDG_CONFIG_HOME` is unset, this is `~/.config/...`.
3. `death-terminal/config.lua` in each directory of `$XDG_CONFIG_DIRS` (default `/etc/xdg`).
4. Legacy `~/.config/death-terminal/config.txt`, with a deprecation note.

The final settings are built in this order: built-in defaults, then the file, then
command-line flags (`--gui`, `--font-size`, `--no-ai`, …). Flags win on every reload too.

## Syntax

```lua
config.theme = "nord"
config.font.size = 13
config.font = { family = "Fira Code", ligatures = true }   -- several at once
config.colors.palette[1] = "#ff5555"
config.keys["ctrl+shift+t"] = "search"
config.keys["ctrl+shift+c"] = false                         -- unbind
config.shell.env.EDITOR = "nvim"

if os.getenv("SSH_CONNECTION") then config.theme = "death" end
```

You can also `return { font = { size = 13 }, theme = "nord" }`. Mistakes in a returned table
are reported against the file name, not a specific line.

Reading an option gives you its current value: `config.font.size + 2`.
`config.colors.*` returns the effective colour, meaning the theme plus your overrides.

### The `dt` table

| | |
|---|---|
| `dt.version` | YouNeeK Death Terminal version string |
| `dt.os` | `"linux"`, `"macos"`, `"windows"`, … |
| `dt.themes` | List of bundled theme names |
| `dt.theme(name)` | Copy of a theme's colours (`foreground`, `background`, `cursor`, `cursor_text`, `selection_background`, `selection_foreground`, `palette[0..15]`). Use it to copy and tweak a theme: `config.colors = dt.theme("nord")` |
| `dt.bind(chord, action)` | Same as `config.keys[chord] = action` |

## Options

Options marked **restart** only apply to new terminals. All others apply when the
config is reloaded.

| Option | Default | |
|---|---|---|
| `window.rows`, `window.cols` | `24`, `80` | Initial grid size (**restart**) |
| `window.scale` | `0` | UI scale 1–4. `0` picks it automatically from DPI, the compositor and the environment (**restart**) |
| `window.backend` | `"auto"` | `auto`, `x11`, `wayland`, `win32` (**restart**) |
| `window.headless` | `true` | `false` opens a window. `--gui` and `--headless` override it (**restart**) |
| `font.family` | `""` | fontconfig family. `""` uses the bundled JetBrains Mono |
| `font.size` | `11` | Points, 4–96 |
| `font.line_height` | `1.0` | Cell height multiplier, 0.5–3 |
| `font.ligatures` | `true` | HarfBuzz calt/liga/dlig |
| `font.retro` | `false` | Built-in 8×8 bitmap font |
| `theme` | `"death"` | `death` when unset, plus `default` (classic ANSI), `dracula`, `gruvbox-dark`, `nord`, `solarized-dark`, `solarized-light` |
| `colors.foreground`, `colors.background` | theme | `"#rrggbb"`, `"#rgb"` or `0xRRGGBB` |
| `colors.cursor`, `colors.cursor_text` | theme | `"none"` inverts the cell under the cursor |
| `colors.selection_background` | theme | |
| `colors.selection_foreground` | theme | `"none"` keeps the text colour |
| `colors.palette` | theme | Table indexed 0–255. A plain list `{ "#000", "#c00", … }` starts at colour 0 |
| `cursor.shape` | `"block"` | `block`, `underline`, `bar`. Programs can still change it with DECSCUSR. `CSI 0 q` returns to this shape |
| `render.present_mode` | `"fifo"` | `fifo` (vsync), `mailbox`, `immediate`, `fifo_relaxed`. `"vsync"` is an alias for `fifo` |
| `render.max_fps` | `120` | Redraw cap while output streams. `0` leaves the limit to the present mode |
| `render.read_budget_kb` | `1024` | PTY bytes parsed per batch, 16–65536 |
| `scrollback.lines` | `10000` | History length (**restart**) |
| `scrollback.scrollbar` | `true` | Show a thumb while scrolled back |
| `scrollback.wheel_lines` | `3` | Lines per wheel notch, 1–100 |
| `selection.copy_on_select` | `false` | Also copy to CLIPBOARD on release |
| `selection.word_chars` | ``-_./~:@%+#?&=`` | Extra characters treated as part of a word on double-click |
| `clipboard.paste_confirm` | `true` | Confirm multi-line pastes when bracketed paste is off |
| `clipboard.osc52` | `"write"` | `off`, `write`, `read-write` |
| `links.open_command` | `xdg-open` / `open` (macOS) / `""` = ShellExecute (Windows) | Runs as `<cmd> <url>` for Ctrl+click, with no shell involved |
| `keys` | — | `{ [chord] = action or false }`, applied over the defaults |
| `default_keybindings` | `true` | `false` starts from an empty binding table |
| `shell.program` | `""` | `""` uses `$SHELL`, falling back to `/bin/sh`. Names without `/` are searched in `$PATH` (**restart**) |
| `shell.args` | `{}` | e.g. `{ "-l" }` (**restart**) |
| `shell.env` | `{}` | Extra environment, e.g. `{ EDITOR = "nvim" }`. These values beat inherited ones and even `TERM` (**restart**) |
| `shell.cwd` | `""` | Starting directory. `""` inherits it; a leading `~` means `$HOME` (**restart**) |
| `shell.integration` | `true` | Load the OSC 133 prompt marks for bash/zsh/fish so AI suggestions know the typed command, history and exit codes ([AI.md](AI.md#shell-integration-osc-133)) (**restart**) |
| `ghost_run.enabled` | `true` | Intercept Enter on a risky command and show a read-only impact preview ([GHOST_RUN.md](GHOST_RUN.md)) |
| `ghost_run.ai_explain` | `true` | Add a plain-English explanation when `ai.enabled` is on. The preview itself stays local |
| `ghost_run.patterns` | built-in | List of patterns. Assigning one, even `{}`, replaces the built-in list instead of extending it |
| `ai.enabled` | `true` | AI command suggestions on/off (`--no-ai` overrides). See [AI.md](AI.md) |
| `ai.endpoint` | `"http://localhost:11434/v1"` | Base URL (http/https). Ollama and other OpenAI-compatible servers use `/chat/completions`. `api.x.ai` and `us.api.x.ai` use `/responses` (Grok 4.7) |
| `ai.model` | `"qwen2.5-coder:0.5b"` | Model name (`grok-4.7` on xAI) |
| `ai.reasoning` | `""` | `""` sends `low` on xAI and nothing elsewhere. Or `low`, `medium`, `high`, `xhigh` |
| `ai.api_key_env` | `""` | **Name** of an environment variable holding the API key; the key itself never goes in the file (values that look like keys are rejected). `XAI_API_KEY` for Grok |
| `ai.timeout_ms` | `5000` | Request timeout, 200–600000. x.ai waits at least 15s |
| `ai.debounce_ms` | `300` | Typing pause before a suggestion is requested, 0–10000 |
| `ai.max_tokens` | `64` | Visible tokens per suggestion, 8–4096. On xAI this is `max_output_tokens` (reasoning is not counted) |
| `ai.explain_max_tokens` | `400` | Tokens per "explain last error" answer, 16–8192 |
| `ai.history` | `5` | Previous commands (with exit codes) sent as context, 0–32 |
| `ai.output_lines` | `20` | Lines of recent output sent as context, 0–200 |
| `ai.accept_key` | `"tab"` | Chord that accepts the ghost text |
| `ssh.enabled` | `true` | Built-in SSH client (`--ssh`, Ctrl+Shift+S). See [SSH.md](SSH.md) |
| `ssh.config_file` | `"~/.ssh/config"` | OpenSSH config to read Host aliases from (`""` = none) |
| `ssh.keepalive_s` | `30` | Default keepalive interval, 0–3600 (0 = off); profiles can override |
| `ssh.known_hosts` | `"~/.ssh/known_hosts"` | Host keys file (shared with OpenSSH; appended to, never rewritten) |
| `status_bar.enabled` | `true` | A one-row status bar under the grid for plugin segments (the bundled YouNeeK Time clock uses it). Ctrl+Shift+B (`toggle_status_bar`) toggles it |
| `tabs.bar` | `"auto"` | Tab bar: `"auto"` (only with 2+ tabs), `"top"`, `"bottom"`, `"hidden"`. `toggle_tab_bar` flips it. See [TABS.md](TABS.md) |
| `tabs.confirm_close` | `true` | Ask before closing a pane / tab / the window while a program (not just the shell) runs in it |
| `tabs.dim_inactive` | `0` | 0–0.9: fade the text of panes without the focus (0 = off) |
| `tabs.inherit_cwd` | `true` | New tabs and panes start in the focused pane's directory (from OSC 7) |
| `layout` | `{}` | Tabs to open at startup: a list of `{ title, cwd, command, ssh, focus }` panes or `{ split = "right"\|"down", ratio, panes = {...} }` splits ([TABS.md](TABS.md#startup-layouts)) |
| `plugins_enabled` | `true` | Load plugins (`--no-plugins` overrides). See [PLUGINS.md](PLUGINS.md) |
| `plugins_dir` | `""` | Where plugins live. `""` = `$XDG_CONFIG_HOME/death-terminal/plugins`; `~/` is expanded |
| `plugins` | `{}` | Per plugin: `enabled`, `allow` (permissions), `exec`, `hosts`, `memory_mb` (32), `cpu_ms` (100), `settings` ([PLUGINS.md](PLUGINS.md#configuration)) |
| `ssh.profiles` | `{}` | Named connections: `host`, `port`, `user`, `identity_file`, `jump`, `env`, `command`, `theme`, `forwards`, `keepalive_s`, `reconnect` ([SSH.md](SSH.md#profiles)) |

Key chords use `ctrl`, `shift` and `alt` plus a key name: letters, digits, `f1`–`f12`,
`page_up`, `home`, `insert`, `equal`, `minus`, `plus`, `kp_add`, … (see
[SELECTION.md](SELECTION.md)).

Actions: `copy`, `paste`, `paste_selection`, `search`, `scroll_page_up`,
`scroll_page_down`, `scroll_line_up`, `scroll_line_down`, `scroll_top`,
`scroll_bottom`, `zoom_in`, `zoom_out`, `zoom_reset`, `select_all`,
`clear_selection`, `reload_config` (default Ctrl+Shift+R), `ai_accept` (Tab, only
while a suggestion shows), `ai_dismiss` (Esc, likewise), `ai_next` / `ai_prev`
(Alt+] / Alt+[), `ai_explain` (Ctrl+Shift+A), `ssh_palette` (Ctrl+Shift+S),
`command_palette` (Ctrl+Shift+P), `toggle_status_bar` (Ctrl+Shift+B). `select_all` is Ctrl+Shift+Alt+A.

Tabs and panes ([TABS.md](TABS.md)): `new_tab` (Ctrl+Shift+T), `close_tab`
(Ctrl+Shift+Alt+W), `next_tab` / `prev_tab` (Ctrl+PgDn / Ctrl+PgUp, Ctrl+Tab /
Ctrl+Shift+Tab), `move_tab_left` / `move_tab_right` (Ctrl+Shift+PgUp / PgDn),
`goto_tab_1` … `goto_tab_9` (Alt+1 … Alt+9), `rename_tab` (Ctrl+Shift+Alt+R),
`toggle_tab_bar`, `split_right` (Ctrl+Shift+E), `split_down` (Ctrl+Shift+O),
`close_pane` (Ctrl+Shift+W), `focus_left` / `focus_right` / `focus_up` / `focus_down`
(Alt+arrows), `next_pane` / `prev_pane`, `resize_left` … `resize_down`
(Alt+Shift+arrows), `zoom_pane` (Ctrl+Shift+Z), `equalize_panes` (Ctrl+Shift+Alt+E).
When one doesn't apply (Alt+3 with two tabs, Alt+Left with no pane to the left) the key
goes to the program as usual.

## Errors

Every assignment is checked for type and range. A bad value doesn't stop the rest of the
file: all problems are collected and reported together with `file:line`:

```
~/.config/death-terminal/config.lua:2: font.size: expected a number from 4 to 96, got 300
~/.config/death-terminal/config.lua:3: unknown option 'font.famly' (did you mean 'font.family'?)
~/.config/death-terminal/config.lua:4: clipboard.osc52: expected one of "off", "write", "read-write", got "rw"
```

These messages appear on stderr and in a red bar at the top of the window. Press Esc to
dismiss the bar. If the cursor has room, the view moves down so the prompt stays visible.
Syntax errors and runtime errors (`attempt to index a nil value`) are reported the same way.

- **At startup**, a file with errors is ignored as a whole and the defaults are used, so a
  half-applied config can't leave the terminal in an odd state.
- **On reload**, a file with errors leaves the running settings unchanged ("kept the previous
  settings"). A typo while you edit doesn't throw away your theme.

## Live reload

Saving the file reloads it. The directory is watched with inotify, so editors that save
through a temporary file and rename it over the original (vim, VS Code, …) also trigger a
reload, and so does creating the file for the first time. Events are debounced by about
100 ms. Ctrl+Shift+R (the `reload_config` action) reloads on demand. A green bar confirms the
reload for 3 s. If options marked restart changed, a yellow bar names them.

These apply live: theme and colours (text already on screen is recoloured), fonts (the grid
reflows to the new cell size), cursor shape, present mode, FPS cap, read budget,
selection/clipboard/scrollbar options, key bindings, the status bar and plugins (the
plugin host restarts when a plugin's files, grants or settings changed; otherwise plugins get
a `config_reload` event).

Watching uses inotify on Linux, kqueue on macOS and change notifications on Windows (the
last two compare modification times, and are untested on real hardware).

## Sandbox

The config runs in its own environment with `string`, `table`, `math`, `utf8`, `coroutine`,
the safe base functions, and `os.getenv`/`os.time`/`os.clock`/`os.date`. The following are
not available: `io`, `os.execute`, `os.remove`, `require`, `dofile`, `loadfile`, `debug`.
`load` only accepts text chunks, never bytecode. A script that loops forever is stopped after
200 M VM instructions, and allocations are capped at 64 MiB. Either limit produces a normal
error message. `--lua-unsafe` exposes the full standard library for people who really want
`io.popen` in their config.

## Legacy config.txt

The old flat format (`font_size = 12`, `keybind = ctrl+shift+c=copy`, …) still works. It is
read only when no config.lua exists, or through `--config file.txt`, and it shows a one-time
deprecation warning. It will be removed in a later release.

## Plugins

Plugins are separate from config.lua: they live in their own directories, run in their
own sandboxed Lua states and can only do what `config.plugins.<name>.allow` grants. See
[PLUGINS.md](PLUGINS.md).
