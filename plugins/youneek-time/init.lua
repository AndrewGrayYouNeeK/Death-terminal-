-- YouNeeK Time in the status bar: civil hour, 100 YouNeeK minutes per hour
-- (1 minute = 36 real seconds), YouNeeK green, and the local moon phase.
--
--   config.status_bar.enabled = true          -- default
--   config.plugins["youneek-time"] = {
--     enabled = true,                         -- false hides the clock
--     settings = {
--       mode = "youneek",                     -- "youneek" or "regular" (civil minutes)
--       hours = 24,                           -- 12 or 24; applies to the hour either way
--       timezone = "",                        -- "" = local, "UTC", or "-05:00"
--       chime = false,                        -- toast when the civil hour changes
--     },
--   }
--
-- The plugin API has no bell or sound output, so the chime is a toast.

local clock = require("lib.clock")
local moon = require("lib.moon")

local settings = dt.settings or {}
local mode = clock.normalize_mode(settings.mode)
local hours = clock.normalize_hours(settings.hours, settings.hour12)
local chime = settings.chime == true
local tz = clock.parse_timezone(settings.timezone)
if tz == nil then
  dt.warn("timezone " .. tostring(settings.timezone) .. " is not local, UTC, or an offset like -05:00; using local")
  tz = { kind = "local" }
end

local view = { mode = mode, hours = hours }
local accent = "#7CFF6B"
local seen_hour = nil

local function refresh()
  local unix = os.time()
  local h, m, s = clock.civil(unix, tz)
  local phase = moon.at(unix)
  dt.status.set("youneek", clock.segment(h, m, s, view, phase), { align = "right", fg = accent })
  if chime and seen_hour ~= nil and h ~= seen_hour then
    dt.notify("YouNeeK Time " .. clock.format_time(h, m, s, view), { timeout_ms = 5000 })
  end
  seen_hour = h
end

dt.timer.every(1000, refresh)
dt.on("startup", refresh)
dt.on("config_reload", refresh)
refresh()
