-- Moon phase, ported from suncalc 1.9.0 `getMoonIllumination`
-- (https://github.com/mourner/suncalc, the library YouNeeK Time uses).
-- Phase names and cutoffs match YouNeeK Time `src/lib/moonPhase.js`.
-- No network and no location: illumination does not need coordinates.

local M = {}

local PI = math.pi
local sin, cos, tan = math.sin, math.cos, math.tan
local asin, acos = math.asin, math.acos
local rad = PI / 180
local day_ms = 1000 * 60 * 60 * 24
local J1970 = 2440588
local J2000 = 2451545
local e = rad * 23.4397

local function atan(y, x)
  return math.atan(y, x)
end

local function clamp1(x)
  if x ~= x then return 0 end
  if x < -1 then return -1 end
  if x > 1 then return 1 end
  return x
end

local function to_days(unix)
  local ms = unix * 1000
  return (ms / day_ms - 0.5 + J1970) - J2000
end

local function right_ascension(l, b)
  return atan(sin(l) * cos(e) - tan(b) * sin(e), cos(l))
end

local function declination(l, b)
  return asin(sin(b) * cos(e) + cos(b) * sin(e) * sin(l))
end

local function solar_mean_anomaly(d)
  return rad * (357.5291 + 0.98560028 * d)
end

local function ecliptic_longitude(M)
  local C = rad * (1.9148 * sin(M) + 0.02 * sin(2 * M) + 0.0003 * sin(3 * M))
  local P = rad * 102.9372
  return M + C + P + PI
end

local function sun_coords(d)
  local L = ecliptic_longitude(solar_mean_anomaly(d))
  return { dec = declination(L, 0), ra = right_ascension(L, 0) }
end

local function moon_coords(d)
  local L = rad * (218.316 + 13.176396 * d)
  local M = rad * (134.963 + 13.064993 * d)
  local F = rad * (93.272 + 13.229350 * d)
  local l = L + rad * 6.289 * sin(M)
  local b = rad * 5.128 * sin(F)
  local dist = 385001 - 20905 * cos(M)
  return { ra = right_ascension(l, b), dec = declination(l, b), dist = dist }
end

-- { phase = 0..1, fraction = illuminated fraction, angle = radians }
function M.illumination(unix)
  local d = to_days(unix)
  local s = sun_coords(d)
  local m = moon_coords(d)
  local sdist = 149598000
  local phi = acos(clamp1(sin(s.dec) * sin(m.dec) + cos(s.dec) * cos(m.dec) * cos(s.ra - m.ra)))
  local inc = atan(sdist * sin(phi), m.dist - sdist * cos(phi))
  local angle = atan(cos(s.dec) * sin(s.ra - m.ra), sin(s.dec) * cos(m.dec) - cos(s.dec) * sin(m.dec) * cos(s.ra - m.ra))
  local sign = -1
  if angle >= 0 then sign = 1 end
  return {
    fraction = (1 + cos(inc)) / 2,
    phase = 0.5 + 0.5 * inc * sign / PI,
    angle = angle,
  }
end

function M.phase_name(phase)
  if phase < 0.03 then return "New Moon" end
  if phase < 0.22 then return "Waxing Crescent" end
  if phase < 0.28 then return "First Quarter" end
  if phase < 0.47 then return "Waxing Gibbous" end
  if phase < 0.53 then return "Full Moon" end
  if phase < 0.72 then return "Waning Gibbous" end
  if phase < 0.78 then return "Last Quarter" end
  if phase < 0.97 then return "Waning Crescent" end
  return "New Moon"
end

local glyphs = {
  ["New Moon"] = "🌑",
  ["Waxing Crescent"] = "🌒",
  ["First Quarter"] = "🌓",
  ["Waxing Gibbous"] = "🌔",
  ["Full Moon"] = "🌕",
  ["Waning Gibbous"] = "🌖",
  ["Last Quarter"] = "🌗",
  ["Waning Crescent"] = "🌘",
}

function M.glyph(name)
  return glyphs[name] or "🌙"
end

function M.at(unix)
  local ill = M.illumination(unix)
  local name = M.phase_name(ill.phase)
  return {
    phase = ill.phase,
    fraction = ill.fraction,
    illumination = math.floor(ill.fraction * 100 + 0.5),
    name = name,
    glyph = M.glyph(name),
  }
end

return M
