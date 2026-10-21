-- YouNeeK Death Terminal configuration
--
-- Save as ~/.config/death-terminal/config.lua (or $XDG_CONFIG_HOME/...).
-- Print this file at any time with:
--
--     deathterminal --print-default-config > ~/.config/death-terminal/config.lua
--
-- Every value below is the built-in default, so this file changes nothing
-- until you edit it; delete whatever you don't care about. Saving the file
-- reloads it in running terminals (or press Ctrl+Shift+R). Mistakes are
-- reported with file:line in a bar at the top of the window (Esc closes
-- it); a broken file never stops the terminal from starting -- it falls
-- back to the defaults (on reload: keeps the previous working config).
--
-- This is ordinary Lua 5.4, run in a sandbox: string/table/math/utf8 and
-- os.getenv/os.time/os.date are available, io, os.execute and require are
-- not (start with --lua-unsafe to allow them). Options marked (restart)
-- only apply to new terminals. Full reference: docs/CONFIG.md.

-- Window -------------------------------------------------------------------
config.window.rows = 24              -- initial size in cells (restart)
config.window.cols = 80              -- (restart)
config.window.scale = 0              -- UI scale 1-4; 0 = auto from DPI (restart)
config.window.backend = "auto"       -- auto | x11 | wayland | win32 (restart)
config.window.headless = true        -- false = open a window; --gui overrides (restart)
config.window.allow_column_switch = true  -- honour DECCOLM 80/132 switching (CSI ?3h/l; ?40 toggles)

-- Font ---------------------------------------------------------------------
config.font.family = ""              -- fontconfig family; "" = bundled JetBrains Mono
config.font.size = 11                -- points; Ctrl+= / Ctrl+- / Ctrl+0 zoom
config.font.line_height = 1.0        -- cell height multiplier (0.5-3)
config.font.ligatures = true         -- HarfBuzz calt/liga/dlig
config.font.retro = false            -- built-in 8x8 bitmap font

-- Colours ------------------------------------------------------------------
-- Bundled themes: default, death, dracula, gruvbox-dark, nord,
-- solarized-dark, solarized-light (also listed in dt.themes).
config.theme = "default"

-- Individual colours override the theme. Colours are "#rrggbb" or "#rgb";
-- cursor / cursor_text / selection_foreground also accept "none"
-- (= derived from the text under them).
-- config.colors.foreground = "#e0e0e0"
-- config.colors.background = "#000000"
-- config.colors.cursor = "#ff0033"
-- config.colors.cursor_text = "#000000"
-- config.colors.selection_background = "#3b5ba5"
-- config.colors.selection_foreground = "none"
-- config.colors.palette[1] = "#ff5555"         -- one ANSI colour (0-255)
-- config.colors.palette = { [0] = "#000000", "#cd0000", "#00cd00" }
-- config.colors = dt.theme("nord")             -- copy a whole theme...
-- config.colors.background = "#20242c"         -- ...then tweak it

-- Cursor -------------------------------------------------------------------
config.cursor.shape = "block"        -- block | underline | bar (apps can change it)

-- Rendering ----------------------------------------------------------------
config.render.present_mode = "fifo"  -- fifo (vsync) | mailbox | immediate | fifo_relaxed
config.render.max_fps = 120          -- redraw cap while output streams (0 = present mode only)
config.render.read_budget_kb = 1024  -- PTY bytes parsed per batch (16-65536)

-- Scrollback ---------------------------------------------------------------
config.scrollback.lines = 10000      -- history lines (restart)
config.scrollback.scrollbar = true   -- show a thumb while scrolled back
config.scrollback.wheel_lines = 3    -- lines per mouse-wheel notch

-- Selection, clipboard and links -------------------------------------------
config.selection.copy_on_select = false     -- also copy selections to CLIPBOARD
config.selection.word_chars = "-_./~:@%+#?&="  -- extra word characters for double-click
config.clipboard.paste_confirm = true       -- confirm multi-line pastes without bracketed paste
config.clipboard.osc52 = "write"            -- programs may: off | write | read-write the clipboard
config.links.open_command = dt.os == "macos" and "open" or dt.os == "windows" and "" or "xdg-open"  -- "" = default handler

-- Key bindings -------------------------------------------------------------
-- Chords are modifiers (ctrl, shift, alt) plus a key name: letters,
-- digits, f1-f12, page_up, home, insert, equal, minus, plus, kp_add, ...
-- Actions: copy, paste, paste_selection, search, scroll_page_up,
-- scroll_page_down, scroll_line_up, scroll_line_down, scroll_top,
-- scroll_bottom, zoom_in, zoom_out, zoom_reset, select_all,
-- clear_selection, reload_config, ai_accept, ai_dismiss, ai_next, ai_prev,
-- ai_explain, ssh_palette (Ctrl+Shift+S). `false` removes a binding.
config.default_keybindings = true    -- false = start from an empty table
-- config.keys["ctrl+shift+t"] = "search"
-- config.keys["ctrl+shift+c"] = false
-- dt.bind("alt+c", "copy")              -- same thing, as a function

-- Shell --------------------------------------------------------------------
config.shell.program = ""            -- "" = $SHELL, then /bin/sh (restart)
config.shell.args = {}               -- e.g. { "-l" } (restart)
config.shell.env = {}                -- e.g. { EDITOR = "nvim" } (restart)
config.shell.cwd = ""                -- "" = inherit; "~" is expanded (restart)
config.shell.integration = true      -- OSC 133 prompt marks for bash/zsh/fish (restart)

-- AI command suggestions (docs/AI.md) --------------------------------------
config.ai.enabled = true             -- --no-ai overrides
config.ai.endpoint = "http://localhost:11434/v1"  -- any OpenAI-compatible API (Ollama by default)
config.ai.model = "qwen2.5-coder:0.5b"
config.ai.reasoning = ""             -- "" = low on api.x.ai, ignored elsewhere; or low | medium | high | xhigh
config.ai.api_key_env = ""           -- NAME of an env var holding the key, e.g. "OPENAI_API_KEY" or "XAI_API_KEY"
config.ai.timeout_ms = 5000          -- give up on a request after this long (x.ai waits at least 15s)
-- Grok 4.7, the model Grok Bot uses. The key stays in the environment:
-- config.ai.endpoint = "https://api.x.ai/v1"   -- or "https://us.api.x.ai/v1"
-- config.ai.model = "grok-4.7"
-- config.ai.api_key_env = "XAI_API_KEY"
-- config.ai.reasoning = "low"        -- ghost text; "high" or "xhigh" thinks longer
-- config.ai.timeout_ms = 20000
config.ai.debounce_ms = 300          -- typing pause before asking
config.ai.max_tokens = 64            -- per suggestion request
config.ai.explain_max_tokens = 400   -- per "explain last error" answer
config.ai.history = 5                -- previous commands (with exit codes) sent as context
config.ai.output_lines = 20          -- lines of recent output sent as context
config.ai.accept_key = "tab"         -- accepts the ghost text (Esc dismisses)

-- SSH (built in, libssh2; see docs/SSH.md) --------------------------------
-- `deathterminal --gui --ssh <profile | ~/.ssh/config alias | user@host[:port]>`
-- or Ctrl+Shift+S in a window to pick a profile.
config.ssh.enabled = true
config.ssh.config_file = "~/.ssh/config"      -- Host aliases read from here ("" = none)
config.ssh.known_hosts = "~/.ssh/known_hosts" -- checked; accepted keys are appended
config.ssh.keepalive_s = 30          -- seconds; 0 = off
-- config.ssh.profiles = {
--   work = {
--     host = "build.example.com",     -- default: the profile name (may be a ~/.ssh/config alias)
--     port = 22, user = "andrew",
--     identity_file = "~/.ssh/id_ed25519",
--     jump = "bastion.example.com",   -- ProxyJump: "[user@]host[:port]", comma-separated
--     env = { LANG = "en_US.UTF-8" }, -- sent if the server's AcceptEnv allows it
--     command = "tmux new -A -s main",-- typed into the remote shell once it starts
--     theme = "dracula",              -- theme for this window
--     forwards = {                    -- toggle at runtime with Ctrl+Shift+S
--       "L 8080:localhost:80",        -- local:  localhost:8080 -> remote's localhost:80
--       "R 9000:localhost:3000",      -- remote: server's :9000 -> our localhost:3000
--       { "D 1080", enabled = false },-- SOCKS4/5 proxy on localhost:1080 (starts off)
--     },
--     keepalive_s = 15, reconnect = true,
--   },
-- }

-- Status bar ---------------------------------------------------------------
-- One row under the grid for plugin segments (git branch, theme, ...).
-- Ctrl+Shift+B toggles it at runtime.
config.status_bar.enabled = false

-- Tabs and split panes (see docs/TABS.md) ---------------------------------
config.tabs.bar = "auto"             -- "auto" (shown with 2+ tabs), "top", "bottom", "hidden"
config.tabs.confirm_close = true     -- ask before closing a pane that runs a program
config.tabs.dim_inactive = 0         -- 0..0.9: fade the panes that don't have the focus
config.tabs.inherit_cwd = true       -- new tabs / panes start in the focused pane's directory
-- Tabs to open at startup (instead of one shell). A pane is { cwd, command,
-- ssh, focus }; a split is { split = "right" | "down", ratio, panes = {...} }.
-- config.layout = {
--   { title = "dev", cwd = "~/src/app", split = "right", ratio = 0.6, panes = {
--       { command = "vim", focus = true },
--       { split = "down", panes = { { command = "htop" }, {} } },
--   } },
--   { title = "prod", ssh = "work" },
-- }

-- Plugins (see docs/PLUGINS.md) -------------------------------------------
-- Plugins live in ~/.config/death-terminal/plugins/<name>/ (manifest.lua +
-- init.lua). They run sandboxed and get only what you grant here.
-- `deathterminal --plugins list` shows what is installed and granted.
config.plugins_enabled = true        -- false (or --no-plugins) loads none
config.plugins_dir = ""              -- "" = $XDG_CONFIG_HOME/death-terminal/plugins
-- config.plugins = {
--   git_branch = { allow = { "exec" }, exec = { "git" } },
--   long_command = { settings = { threshold_s = 10 } },
--   weather = { allow = { "network" }, hosts = { "wttr.in" }, cpu_ms = 50 },
--   noisy = { enabled = false },
-- }

-- Lua tricks ---------------------------------------------------------------
-- if os.getenv("SSH_CONNECTION") then config.theme = "death" end
-- if dt.os == "macos" then config.font.size = 13 end
