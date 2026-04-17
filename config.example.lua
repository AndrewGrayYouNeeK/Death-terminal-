-- DeathTerminal Default Configuration
-- This is an example configuration file for DeathTerminal
-- Place this file in one of the following locations:
--   Linux/macOS: ~/.config/death-terminal/config.lua
--   Windows: %APPDATA%/death-terminal/config.lua

-- Terminal settings
terminal = {
    -- Terminal dimensions (rows x columns)
    rows = 24,
    cols = 80,

    -- Font configuration
    font_size = 14,
    font_family = "FiraCode Nerd Font Mono",
    font_weight = "Regular",

    -- Scrollback buffer size (lines)
    scrollback = 10000,

    -- Cursor settings
    cursor_style = "block", -- Options: "block", "underline", "bar"
    cursor_blink = true,
    cursor_blink_interval = 500, -- milliseconds
}

-- AI Autocomplete settings
ai = {
    -- Enable/disable AI autocomplete
    enabled = true,

    -- gRPC endpoint for AI service
    -- Use "localhost:50051" for local model
    -- Use remote endpoint for cloud-based AI
    endpoint = "localhost:50051",

    -- Maximum number of suggestions to display
    max_suggestions = 5,

    -- Number of context lines to send to AI
    context_lines = 10,

    -- Minimum characters before triggering autocomplete
    min_chars = 3,

    -- Timeout for AI requests (milliseconds)
    timeout = 1000,
}

-- SSH settings
ssh = {
    -- Default SSH port
    default_port = 22,

    -- Keepalive interval (seconds)
    keepalive_interval = 60,

    -- Enable compression
    compression = true,

    -- Default username (leave empty to prompt)
    default_username = "",

    -- SSH key locations to try
    key_paths = {
        "~/.ssh/id_rsa",
        "~/.ssh/id_ed25519",
        "~/.ssh/id_ecdsa",
    },
}

-- Theme configuration (brutalist design)
theme = {
    -- Color scheme
    background = "#000000",
    foreground = "#FFFFFF",
    cursor = "#FF0000",
    selection = "#333333",

    -- ANSI colors (0-7: normal, 8-15: bright)
    colors = {
        -- Normal colors
        black = "#000000",
        red = "#FF0000",
        green = "#00FF00",
        yellow = "#FFFF00",
        blue = "#0000FF",
        magenta = "#FF00FF",
        cyan = "#00FFFF",
        white = "#FFFFFF",

        -- Bright colors
        bright_black = "#808080",
        bright_red = "#FF8080",
        bright_green = "#80FF80",
        bright_yellow = "#FFFF80",
        bright_blue = "#8080FF",
        bright_magenta = "#FF80FF",
        bright_cyan = "#80FFFF",
        bright_white = "#FFFFFF",
    },

    -- UI elements
    tab_bar_background = "#000000",
    tab_bar_foreground = "#FFFFFF",
    tab_active_background = "#FF0000",
    tab_active_foreground = "#000000",
}

-- Keybindings
keybindings = {
    -- Clipboard
    copy = "Ctrl+Shift+C",
    paste = "Ctrl+Shift+V",

    -- Tabs
    new_tab = "Ctrl+Shift+T",
    close_tab = "Ctrl+Shift+W",
    next_tab = "Ctrl+Tab",
    prev_tab = "Ctrl+Shift+Tab",

    -- Panes/splits
    split_horizontal = "Ctrl+Shift+H",
    split_vertical = "Ctrl+Shift+V",
    close_pane = "Ctrl+Shift+D",

    -- Navigation
    focus_next_pane = "Ctrl+Shift+N",
    focus_prev_pane = "Ctrl+Shift+P",

    -- Font size
    increase_font_size = "Ctrl+Plus",
    decrease_font_size = "Ctrl+Minus",
    reset_font_size = "Ctrl+0",

    -- AI Autocomplete
    trigger_autocomplete = "Ctrl+Space",
    accept_suggestion = "Tab",
    next_suggestion = "Ctrl+N",
    prev_suggestion = "Ctrl+P",

    -- Other
    search = "Ctrl+Shift+F",
    quit = "Ctrl+Shift+Q",
}

-- Performance settings
performance = {
    -- Enable GPU acceleration
    gpu_acceleration = true,

    -- FPS cap (0 = unlimited)
    fps_cap = 60,

    -- Triple buffering
    triple_buffering = true,

    -- VSync
    vsync = true,
}

-- Logging and debugging
logging = {
    -- Log level: "debug", "info", "warn", "error"
    level = "info",

    -- Log file location (empty = stderr only)
    file = "",

    -- Enable performance metrics
    show_fps = false,
}

-- Custom hooks (Lua functions called on events)
function on_startup()
    -- Called when DeathTerminal starts
    print("DeathTerminal initialized")
end

function on_shutdown()
    -- Called when DeathTerminal exits
    print("DeathTerminal shutting down")
end

function on_command(command)
    -- Called before executing a command
    -- Return false to prevent execution
    return true
end

function on_ai_suggestion(suggestions)
    -- Called when AI suggestions are received
    -- You can modify or filter suggestions here
    return suggestions
end

-- Custom commands
commands = {
    -- Define custom commands that can be invoked
    hello = function()
        print("Hello from DeathTerminal!")
    end,

    timestamp = function()
        print(os.date("%Y-%m-%d %H:%M:%S"))
    end,
}
