-- YouNeeK Time for the status bar.
--
-- YouNeeKTimeTheFinalBoss (`src/lib/decimalTime.js`) keeps the civil hour
-- (`armyHours`) and maps each hour onto 100 minutes:
--
--   armyMinutes = floor(fractionalRealMinutes * (100 / 60)) % 100
--
-- At a whole second that is floor(seconds_into_hour / 36): one YouNeeK
-- minute is 36 real seconds, so the minute runs 00-99
-- (14:30:00 real = 14:50, 14:59:59 real = 14:99). The native army clock
-- prints HH:MM:SS. YouNeeK mode prints a 12-hour clock (12 AM at hour 0,
-- 12 PM at hour 12) and the 24-hour clock in parentheses, both on 100-minute
-- hours: `6:62 PM (18:62)`. `hours` 12/24 applies only to `mode = "regular"`,
-- which shows the civil minute.

local M = {}

function M.youneek_minute(seconds_into_hour)
  local sec = seconds_into_hour
  if sec < 0 then sec = 0 end
  if sec > 3599 then sec = 3599 end
  return math.floor(sec / 36)
end

-- "" / "local" = the machine zone, "UTC"/"GMT" = UTC, otherwise "+HH:MM" / "-H".
function M.parse_timezone(s)
  if s == nil or s == "" then return { kind = "local" } end
  if type(s) ~= "string" then return nil end
  local lower = string.lower(s)
  if lower == "local" then return { kind = "local" } end
  if lower == "utc" or lower == "gmt" or lower == "z" then return { kind = "utc" } end
  local sign, hh, mm = string.match(s, "^([+-])(%d%d?):(%d%d)$")
  if not sign then
    sign, hh = string.match(s, "^([+-])(%d%d?)$")
    mm = "00"
  end
  if not sign then return nil end
  local h = tonumber(hh)
  local m = tonumber(mm)
  if h == nil or m == nil or h > 14 or m > 59 then return nil end
  local off = (h * 60 + m) * 60
  if sign == "-" then off = -off end
  return { kind = "offset", offset = off }
end

-- hour, minute, second in the chosen zone. `unix` is seconds since the epoch.
function M.civil(unix, tz)
  local spec = tz or { kind = "local" }
  local t
  if spec.kind == "offset" then
    t = os.date("!*t", unix + spec.offset)
  elseif spec.kind == "utc" then
    t = os.date("!*t", unix)
  else
    t = os.date("*t", unix)
  end
  return t.hour, t.min, t.sec
end

function M.normalize_mode(mode)
  if type(mode) ~= "string" then return "youneek" end
  local m = string.lower(mode)
  if m == "regular" or m == "normal" or m == "civilian" then return "regular" end
  return "youneek"
end

function M.normalize_hours(hours, hour12)
  if hours == 12 or hours == "12" then return 12 end
  if hours == 24 or hours == "24" then return 24 end
  if hour12 == true then return 12 end
  return 24
end

-- YouNeeK mode: `H:MM AM/PM (HH:MM)` with 100-minute hours in both parts.
-- Regular mode: civil `HH:MM`, or `HH:MM AM/PM` when hours is 12.
function M.format_time(hour, minute, second, opts)
  local o = opts or {}
  local mode = M.normalize_mode(o.mode)
  local hours = M.normalize_hours(o.hours, o.hour12)
  local mm = minute
  if mode ~= "regular" then
    mm = M.youneek_minute(minute * 60 + second)
  end
  if mm < 0 then mm = 0 end
  if mm > 99 then mm = 99 end
  if mode ~= "regular" then
    local h12 = hour % 12
    if h12 == 0 then h12 = 12 end
    local suffix = (hour >= 12) and "PM" or "AM"
    return string.format("%d:%02d %s (%02d:%02d)", h12, mm, suffix, hour, mm)
  end
  local h = hour
  local suffix = ""
  if hours == 12 then
    suffix = (h >= 12) and " PM" or " AM"
    h = h % 12
    if h == 0 then h = 12 end
  end
  return string.format("%02d:%02d%s", h, mm, suffix)
end

-- Status-bar text. `moon` is { glyph, name, illumination } from lib/moon.
function M.segment(hour, minute, second, opts, moon)
  local o = opts or {}
  local mode = M.normalize_mode(o.mode)
  local text = "YouNeeK " .. M.format_time(hour, minute, second, o)
  if mode ~= "regular" then text = text .. " YNK" end
  return string.format("%s  %s %s %d%%", text, moon.glyph, moon.name, moon.illumination)
end

return M
