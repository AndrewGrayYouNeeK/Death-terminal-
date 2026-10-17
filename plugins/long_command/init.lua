-- long_command: a toast (and a desktop notification while the window is
-- unfocused) when a command that ran longer than `threshold_s` finishes.
-- Needs OSC 133 shell integration. Optional settings:
--
--   config.plugins.long_command = { settings = { threshold_s = 10 } }
--
-- The command line itself is only shown if you also grant "screen".

local threshold_ms = (tonumber(dt.settings.threshold_s) or 10) * 1000

local function fmt(ms)
  local s = math.floor(ms / 1000)
  if s < 60 then return s .. "s" end
  if s < 3600 then return string.format("%dm%02ds", s // 60, s % 60) end
  return string.format("%dh%02dm", s // 3600, (s % 3600) // 60)
end

dt.on("command_finish", function(e)
  if (e.duration_ms or 0) < threshold_ms then return end
  local ok = e.exit_code == 0
  local what = e.command and e.command ~= "" and ("'" .. e.command .. "'") or "Command"
  local how = ok and "finished" or ("failed (exit " .. tostring(e.exit_code) .. ")")
  dt.notify(string.format("%s %s after %s", what, how, fmt(e.duration_ms)), {
    level = ok and "success" or "error",
    timeout_ms = 8000,
    desktop = not e.focused,
  })
end)

local status_timer = nil
dt.on("command_start", function()
  local started = os.time()
  if status_timer then dt.timer.cancel(status_timer) end
  status_timer = dt.timer.every(1000, function()
    local s = os.time() - started
    if s * 1000 >= threshold_ms then dt.status.set("running", "⏱ " .. fmt(s * 1000), { align = "right" }) end
  end)
end)
dt.on("command_finish", function()
  if status_timer then dt.timer.cancel(status_timer) status_timer = nil end
  dt.status.clear("running")
end)
