# Plugins

DeathTerminal plugins are small Lua 5.4 programs that react to terminal events
(commands finishing, the working directory changing, key presses, AI suggestions, ...)
and extend the UI: command palette entries, keybindings, status-bar segments, toasts,
timers and colour themes.

Each plugin runs in **its own sandboxed Lua state**, with a memory cap and a time budget
per callback. It can **only do what you grant it** in config.lua. A plugin that errors is
logged and shown, and one that keeps failing is switched off. It can't crash the terminal.

```
~/.config/death-terminal/plugins/
  git_branch/
    manifest.lua      -- name, version, description, requested permissions
    init.lua          -- the code
    lib/util.lua      -- optional modules: require("lib.util")
```

Three example plugins ship in [`plugins/`](../plugins). Copy or symlink them to try:

```sh
mkdir -p ~/.config/death-terminal/plugins
cp -r plugins/* ~/.config/death-terminal/plugins/
deathterminal --plugins list
```

| Plugin | What it does | Needs |
|---|---|---|
| `git_branch` | Branch of the shell's cwd (and `*` when dirty) in the status bar | `allow = { "exec" }, exec = { "git" }`, OSC 7 cwd (bundled shell integration) |
| `long_command` | Toast (and a desktop notification while unfocused) when a command that ran longer than `threshold_s` (default 10) finishes, with its exit code; a running timer in the status bar | OSC 133 shell integration; `screen` to include the command line |
| `theme_cycle` | Registers a `crimson` theme, palette commands "Theme: next/previous/crimson" and Ctrl+Alt+T; the theme name in the status bar | nothing |

## Configuration

```lua
config.status_bar = { enabled = true }      -- segments need the bar (Ctrl+Shift+B toggles it)
config.plugins = {
  git_branch = { allow = { "exec" }, exec = { "git" } },
  long_command = { settings = { threshold_s = 5 } },
  weather = { allow = { "network" }, hosts = { "wttr.in" } },
  noisy = { enabled = false },
}
```

| Key | Default | |
|---|---|---|
| `enabled` | unset | `true`/`false` overrides `--plugins enable/disable`. Unset: the state file decides, else on |
| `allow` | `{}` | Permissions granted. A plugin gets the **intersection** with what its manifest requests |
| `exec` | `{}` | Programs `dt.exec` may run: bare names (looked up in `$PATH`) or absolute paths |
| `hosts` | `{}` | Hosts `dt.http` may reach: `"api.example.com"`, `"*.example.com"`, `"host:8443"`. Without a port only the scheme's default port matches |
| `memory_mb` | `32` | Memory cap of the plugin's Lua state, 1–1024 |
| `cpu_ms` | `100` | Time budget per callback, 5–10000. Loading `init.lua` gets 10× |
| `settings` | `{}` | Plain data handed to the plugin as `dt.settings` |

Also: `config.plugins_enabled = false` (or `--no-plugins`) loads none, and
`config.plugins_dir` moves the directory.

Installed plugins are **on by default but have no permissions** until you grant them.
Unknown permission names and unknown keys are reported like any other config error.

### Permissions

| Permission | Grants |
|---|---|
| `screen` | `dt.screen.*`, the `output_line` event, and the command line in `command_start`/`command_finish` |
| `input` | the `key` event (see and consume key presses) |
| `pty` | `dt.pty.write` (type into the terminal) |
| `clipboard` | `dt.clipboard.get/set` |
| `network` | `dt.http.*` to the `hosts` allowlist (http/https, no redirects, 1 MiB replies) |
| `exec` | `dt.exec` for programs in the `exec` allowlist (no shell, timeout, 1 MiB output) |
| `fs` | `dt.fs.*` inside the plugin's own data directory (`$XDG_DATA_HOME/death-terminal/plugins/<name>`) |
| `ai` | the `ai_suggestion` event (filter or rewrite AI suggestions) |

Everything else (events like `cwd` and `command_finish`, commands, keybindings, status
segments, toasts, timers, themes, `dt.term.*`) needs no permission.

### `deathterminal --plugins`

```sh
deathterminal --plugins list              # installed plugins, enabled state, requested vs granted
deathterminal --plugins disable noisy     # saved in $XDG_STATE_HOME/death-terminal/plugins.json
deathterminal --plugins enable noisy
```

`enable`/`disable` take effect on the next start or config reload (Ctrl+Shift+R). If
config.lua sets `enabled` for that plugin, the command says so, because config wins.

## Writing a plugin

`manifest.lua` is data only (it runs with no functions available):

```lua
return {
  name = "hello",                 -- must match the directory; a-z, 0-9, _ and -
  version = "1.0.0",
  description = "Says hello",
  permissions = { "screen" },     -- what it asks for
}
```

`init.lua` runs once at load. It registers handlers on the global `dt` table:

```lua
dt.on("command_finish", function(e)
  if e.exit_code ~= 0 then dt.notify("exit " .. tostring(e.exit_code), { level = "warn" }) end
end)

dt.command({ id = "hello.say", title = "Hello: say hi", run = function() dt.notify("hi") end })
dt.bind("ctrl+alt+h", "hello.say")
dt.status.set("hello", "👋", { align = "right" })
```

### Events

`dt.on(event, fn)` returns an id for `dt.off(id)`. Handlers get one table argument.

| Event | Payload | Notes |
|---|---|---|
| `startup` | — | after every plugin loaded |
| `config_reload` | — | config.lua reloaded and the plugin set didn't change (otherwise plugins restart) |
| `shutdown` | — | the window is closing |
| `key` | `key`, `text`, `ctrl`, `alt`, `shift` | needs `input`. Return `true` to consume the key (it doesn't reach the shell). `key` is a name like `"a"`, `"enter"`, `"f5"`, `"page_up"` |
| `command_start` | `cwd`, `command`* | OSC 133 `C` |
| `command_finish` | `exit_code`, `duration_ms`, `cwd`, `focused`, `command`* | OSC 133 `D`. `exit_code` is `false` if the shell didn't report one |
| `output_line` | `text` | needs `screen`. Each completed row on the main screen (not in full-screen apps), up to 200 per batch |
| `cwd` | `cwd` | OSC 7 |
| `title` | `title` | |
| `bell` | — | |
| `focus` | `focused` | |
| `ssh_connect` / `ssh_disconnect` | `target` | built-in SSH sessions (`--ssh`) only |
| `ai_suggestion` | `input`, `text` | needs `ai`. Return `false` to drop the suggestion or a string to replace the whole command line (it must still start with what was typed) |
| `tab_new` / `tab_close` | `tab` | a tab was opened / closed |
| `tab_focus` | `tab`, `pane` | another tab became the current one |
| `pane_new` / `pane_close` | `tab`, `pane` | a pane was opened (new tab or split) / closed |
| `pane_focus` | `tab`, `pane` | the focus moved to another pane (also on tab switches) |

\* `command` only for plugins holding `screen`.

`command_start`, `command_finish`, `cwd`, `title`, `bell` and the SSH events come from
every pane, not just the focused one; their payloads carry the pane's `pane` and `tab`
ids. `command_finish`'s `focused` is true only when the window has the focus *and* the
command ran in the focused pane.

SSH events come from the built-in client, which reports with a per-window secret (OSC 7799
plus `DT_SSH_NONCE`), so output from a remote host can't fake them. Running OpenSSH's `ssh`
inside a normal window doesn't produce them.

### API

| | |
|---|---|
| `dt.version`, `dt.os`, `dt.plugin` | strings |
| `dt.settings` | `config.plugins.<name>.settings` (a table) |
| `dt.permissions`, `dt.has(perm)` | granted permissions |
| `dt.log(...)`, `dt.warn(...)`, `print(...)` | to the plugin log |
| `dt.command{ id, title, run }` | add to the command palette (Ctrl+Shift+P), max 32 |
| `dt.bind(chord, fn or command_id)` | keybinding; must use Ctrl, Alt or an F-key and can't take a chord the terminal or another plugin uses. Max 16 |
| `dt.status.set(id, text, { align = "left"/"right", fg = "#rrggbb" })`, `dt.status.clear(id)` | status-bar segments, max 8 |
| `dt.notify(text, { level = "info"/"success"/"warn"/"error", timeout_ms, desktop })` | toast in the top-right corner; `desktop = true` also uses `notify-send` while the window is unfocused. At most 5 per 10 s |
| `dt.timer.after(ms, fn)`, `dt.timer.every(ms, fn)`, `dt.timer.cancel(id)` | minimum 100 ms, max 64 timers |
| `dt.theme.register{ name, fg, bg, cursor, cursor_text, selection_bg, selection_fg, ansi = {16} }` | a custom theme |
| `dt.theme.set(name)`, `dt.theme.list()`, `dt.theme.current()` | switch themes (bundled or registered). A config reload goes back to the configured theme |
| `dt.action(name)` | run a built-in action: `search`, `scroll_*`, `zoom_*`, `select_all`, `clear_selection`, `reload_config`, `ai_explain`, `ssh_palette`, `command_palette`, `toggle_status_bar`, and the tab / pane actions (`new_tab`, `close_tab`, `next_tab`, `prev_tab`, `move_tab_left/right`, `goto_tab_1`…`9`, `toggle_tab_bar`, `split_right`, `split_down`, `close_pane`, `focus_left/right/up/down`, `next_pane`, `prev_pane`, `resize_left/right/up/down`, `zoom_pane`, `equalize_panes`) |
| `dt.term.cwd()`, `.title()`, `.ssh()`, `.size()`, `.focused()`, `.tab()`, `.pane()` | the focused pane's terminal info and ids |
| `dt.tabs.list()` | `{ { id, title, active, panes = { pane ids }, focused_pane }, ... }` left to right |
| `dt.tabs.new{ cwd = ... }`, `dt.tabs.focus(id)`, `dt.tabs.close(id)`, `dt.tabs.rename(id, name)`, `dt.tabs.current()` | false for an unknown id. `close` asks first like the user's close does |
| `dt.panes.split("right"/"down")`, `dt.panes.focus(id)`, `dt.panes.close(id)`, `dt.panes.current()` | split the focused pane; focus / close any pane |
| `dt.screen.text(scrollback)`, `.lines(n)`, `.cursor()` | `screen`. Cursor is 1-based `row, col` |
| `dt.pty.write(s)` | `pty`, up to 64 KiB |
| `dt.clipboard.set(s)`, `dt.clipboard.get(fn)` | `clipboard` |
| `dt.http.request({ method, url, headers, body }, fn)`, `dt.http.get(url, fn)` | `network`. `fn{ ok, status, body, error }`. Max 4 jobs at once |
| `dt.exec(argv, { cwd, stdin, timeout_ms }, fn)` | `exec`. `fn{ ok, code, stdout, stderr, error, truncated }` |
| `dt.fs.read/write/append/list/remove/exists/mkdir(path)`, `dt.fs.dir` | `fs`. Relative paths inside the data dir only (no `..`, no absolute paths) |
| `require("mod.name")` | loads `mod/name.lua` from the plugin's directory |

Plugins get `string`, `table`, `math`, `utf8`, `coroutine`, `os.time/clock/date/difftime`
and the safe base functions. There's no `io`, `os.execute`, `os.getenv`, `debug`,
`dofile`/`loadfile`, and `load` only takes text.

### Tabs and panes

Each pane is tracked separately: hooks fire for output in background panes too (with
`pane` / `tab` in the payload) while `dt.term`, `dt.screen` and `dt.pty.write` act on the
focused pane. Layout requests (`dt.tabs.*`, `dt.panes.*`, tab / pane actions) are applied
by the window after the callback returns; the ids stay valid until the tab / pane closes.

```lua
dt.on("pane_new", function(e)
  dt.notify("pane " .. e.pane .. " in tab " .. e.tab)
end)
dt.command({ id = "dev", title = "Dev layout: editor + shell", run = function()
  dt.tabs.new()
  dt.panes.split("right")
end })
```

### Errors and limits

- A runtime error in a handler is caught. It goes to the log with a traceback and shows a
  toast (at most one every 10 s per plugin). The other plugins and the terminal carry on.
- **5 errors within 60 s switch the plugin off** for the session, with a toast saying why.
- A callback that runs past `cpu_ms` (or 10× that while loading) is stopped, even inside
  `pcall`, and counts as an error. The same goes for allocations past `memory_mb`.
- A plugin whose manifest or `init.lua` fails to load, or that subscribes to an event it
  lacks the permission for, doesn't start ("Plugin X failed to load").
- Log: `$XDG_STATE_HOME/death-terminal/plugins.log`. Lines look like `2026-10-17 16:56:36 [git_branch] info: ...`.
  It rotates (one old copy) past 1 MiB.

### Reloading

Saving config.lua or pressing Ctrl+Shift+R restarts the plugin host if any plugin's
`manifest.lua` / `init.lua` changed (mtime), a plugin was added, removed, enabled or
disabled, or its grants/settings changed. Otherwise plugins just get `config_reload`.
Edits to other modules a plugin `require`s need a change to `init.lua` (or a restart).

## Built-in palette

Ctrl+Shift+P opens the command palette: "Go to tab N: title" entries (with two or more
tabs), plugin commands (with the plugin's name), then every built-in action with its
current chord, including the tab and pane actions. Type to filter, arrows to move, Enter
to run, Esc to close. Ctrl+Shift+S still opens the SSH palette.
