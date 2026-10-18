-- theme_cycle: switch colour themes at runtime. Registers a custom
-- "crimson" theme, palette commands, and Ctrl+Alt+T to step through every
-- theme. Shows the theme name in the status bar.

dt.theme.register({
  name = "crimson",
  fg = "#e6d6d6", bg = "#140a0c", cursor = "#ff4060",
  selection_bg = "#5a1a24", selection_fg = "#ffffff",
  ansi = {
    "#1c1012", "#e0303f", "#7fbf6a", "#e0b050", "#5a8fd0", "#c0609a", "#50b0b0", "#c8b8b8",
    "#4a3034", "#ff5a66", "#9ad884", "#ffd070", "#7aaaf0", "#e080b8", "#70d0d0", "#ffffff",
  },
})

local function show() dt.status.set("theme", "◐ " .. dt.theme.current(), { align = "right", fg = "#8a8a8a" }) end

local function step(delta)
  local list = dt.theme.list()
  local cur = dt.theme.current()
  local idx = 0
  for i, name in ipairs(list) do if name == cur then idx = i end end
  local next_name = list[((idx - 1 + delta) % #list) + 1]
  dt.theme.set(next_name)
  show()
  dt.notify("Theme: " .. next_name, { timeout_ms = 1500 })
end

dt.command({ id = "theme.next", title = "Theme: next", run = function() step(1) end })
dt.command({ id = "theme.prev", title = "Theme: previous", run = function() step(-1) end })
dt.command({ id = "theme.crimson", title = "Theme: crimson (plugin theme)", run = function() dt.theme.set("crimson") show() end })
dt.bind("ctrl+alt+t", "theme.next")

dt.on("startup", show)
dt.on("config_reload", show)
