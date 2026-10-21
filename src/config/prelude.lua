-- DeathTerminal config prelude (embedded in the binary, see lua_config.zig).
--
-- Runs with the full standard library and builds the sandboxed environment
-- the user's config.lua runs in. Every assignment to `config.*` goes
-- through the Zig `set` function, which validates the type and range;
-- problems are collected with the file:line they came from instead of
-- aborting the load, so one typo reports every mistake at once.
--
-- Milestone 10 (plugins/hooks) reuses this shape: plugins get their own
-- sandboxed env plus `dt` API tables registered from Zig.

local set, get, kinds, display, source, unsafe, theme_names, theme_fn, print_fn, version, os_name = ...

local getinfo = debug.getinfo
local chunk_source = "=" .. display
local errors = {}

-- The innermost frame that belongs to the user's file: "file:line".
local function where()
  for level = 2, 100 do
    local info = getinfo(level, "Sl")
    if not info then break end
    if info.source == chunk_source then return display .. ":" .. info.currentline end
  end
  return display
end

local function report(loc, msg)
  errors[#errors + 1] = loc .. ": " .. msg
end

-- Levenshtein distance, for "did you mean" hints.
local function distance(a, b)
  if a == b then return 0 end
  local prev = {}
  for j = 0, #b do prev[j] = j end
  for i = 1, #a do
    local cur = { [0] = i }
    local ai = a:sub(i, i)
    for j = 1, #b do
      local cost = (ai == b:sub(j, j)) and 0 or 1
      cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
    end
    prev = cur
  end
  return prev[#b]
end

local function suggest(path)
  local best, best_d
  for p in pairs(kinds) do
    local d = distance(p, path)
    if d <= math.max(2, #path // 4) and (best_d == nil or d < best_d or (d == best_d and p < best)) then
      best, best_d = p, d
    end
  end
  if best then return " (did you mean '" .. best .. "'?)" end
  local prefix = path:match("^(.*)%.") or ""
  if kinds[prefix] == "section" then
    local opts = {}
    for p in pairs(kinds) do
      if p:match("^(.*)%.") == prefix then opts[#opts + 1] = p:sub(#prefix + 2) end
    end
    table.sort(opts)
    return " (" .. prefix .. " has: " .. table.concat(opts, ", ") .. ")"
  end
  return ""
end

local function join(prefix, key)
  if prefix == "" then return key end
  return prefix .. "." .. key
end

local collection = { keys = true, string_map = true, string_list = true, palette = true, ssh_profiles = true, plugins = true, layout = true, ghost_patterns = true }

local function unknown(path, loc)
  report(loc, "unknown option '" .. path .. "'" .. suggest(path))
end

local assign

local function assign_item(path, key, value, loc)
  local err = set(path, value, key)
  if err then report(loc, err) end
end

assign = function(path, value, loc)
  local kind = kinds[path]
  if kind == nil then return unknown(path, loc) end
  if kind == "section" then
    if type(value) ~= "table" then
      return report(loc, path .. ": expected a table of options, got " .. type(value))
    end
    for k, v in pairs(value) do
      if type(k) ~= "string" then
        report(loc, path .. ": option names must be strings, got " .. type(k) .. " " .. tostring(k))
      else
        assign(join(path, k), v, loc)
      end
    end
    return
  end
  local err = set(path, value)
  if err then report(loc, err) end
end

-- Swallows everything after an unknown section so a typo reports once.
local sink = setmetatable({}, {
  __index = function(self) return self end,
  __newindex = function() end,
  __call = function(self) return self end,
  __metatable = false,
})

local proxies = {}
local function proxy(prefix)
  if proxies[prefix] then return proxies[prefix] end
  local kind = prefix == "" and "section" or kinds[prefix]
  local mt = { __metatable = false }
  if collection[kind] then
    mt.__index = function(_, key) return get(prefix, key) end
    mt.__newindex = function(_, key, value) assign_item(prefix, key, value, where()) end
  else
    mt.__index = function(_, key)
      if type(key) ~= "string" then return nil end
      local path = join(prefix, key)
      local k = kinds[path]
      if k == nil then
        unknown(path, where())
        return sink
      elseif k == "section" or collection[k] then
        return proxy(path)
      end
      return get(path)
    end
    mt.__newindex = function(_, key, value)
      if type(key) ~= "string" then
        return report(where(), (prefix == "" and "config" or prefix) .. ": option names must be strings")
      end
      assign(join(prefix, key), value, where())
    end
  end
  local p = setmetatable({}, mt)
  proxies[prefix] = p
  return p
end

local themes_list = {}
for i, n in ipairs(theme_names) do themes_list[i] = n end

local dt = {
  version = version,
  os = os_name,
  themes = themes_list,
}

-- dt.theme("nord") -> a table of the theme's colours, usable as
-- `config.colors = dt.theme("nord")` or to tweak one entry.
function dt.theme(name)
  local t, err = theme_fn(name)
  if not t then error(err, 2) end
  return t
end

-- dt.bind("ctrl+shift+t", "search") is the same as
-- config.keys["ctrl+shift+t"] = "search".
function dt.bind(chord, action)
  assign_item("keys", chord, action, where())
end

local env = {
  config = proxy(""),
  dt = dt,
  assert = assert, error = error, ipairs = ipairs, next = next, pairs = pairs,
  pcall = pcall, xpcall = xpcall, select = select, tonumber = tonumber,
  tostring = tostring, type = type, rawequal = rawequal, rawget = rawget,
  rawset = rawset, rawlen = rawlen, setmetatable = setmetatable,
  getmetatable = getmetatable, _VERSION = _VERSION,
  string = string, table = table, math = math, utf8 = utf8, coroutine = coroutine,
  os = { getenv = os.getenv, time = os.time, clock = os.clock, date = os.date },
  print = print_fn,
}
env._G = env
-- Text chunks only: binary chunks can crash the VM.
env.load = function(chunk, name, _, chunk_env)
  return load(chunk, name, "t", chunk_env or env)
end

if unsafe then
  env.io, env.os, env.require, env.dofile, env.loadfile, env.package, env.debug =
    io, os, require, dofile, loadfile, package, debug
end

local fn, err = load(source, chunk_source, "t", env)
if not fn then
  errors[#errors + 1] = err
  return errors
end

local ok, result = pcall(fn)
if not ok then
  local msg = tostring(result)
  if msg:sub(1, #display) ~= display then msg = display .. ": " .. msg end
  errors[#errors + 1] = msg
elseif type(result) == "table" then
  -- `return { font = { size = 12 } }` style.
  local loc = display .. " (returned table)"
  for k, v in pairs(result) do
    if type(k) ~= "string" then
      report(loc, "option names must be strings, got " .. type(k))
    else
      assign(k, v, loc)
    end
  end
elseif result ~= nil then
  report(display, "config.lua must return nothing or a table, got " .. type(result))
end

return errors
