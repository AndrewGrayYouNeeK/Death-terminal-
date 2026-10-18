-- Builds a plugin's environment. Runs once per plugin, in that plugin's own
-- Lua state, with the full standard library still visible here; only what
-- is copied into `env` is reachable from the plugin.
--
-- Arguments: `api` (C functions bound to this plugin), `info` (plain data).
-- Returns: env, dispatch(event, payload), invoke(callback_id, drop, payload).

local api, info = ...

local raw_pcall, raw_xpcall, raw_error = pcall, xpcall, error
local pairs, ipairs, type, select, tostring = pairs, ipairs, type, select, tostring
local co_create, co_resume = coroutine.create, coroutine.resume
local unpack, pack, concat, remove = table.unpack, table.pack, table.concat, table.remove
local traceback = debug.traceback
local killed = api.killed

-- Once the time budget ran out the hook stops the plugin at its next
-- instruction; these wrappers make sure a pcall that caught that error
-- can't carry on either.
local function guard(...)
  if killed() then raw_error("plugin stopped: time limit exceeded", 0) end
  return ...
end

local function copy(t)
  local r = {}
  for k, v in pairs(t) do r[k] = v end
  return r
end

local env = {}
for _, k in ipairs({ "assert", "error", "ipairs", "next", "pairs", "select", "tonumber",
  "tostring", "type", "rawequal", "rawget", "rawset", "rawlen", "setmetatable",
  "getmetatable", "_VERSION" }) do
  env[k] = _G[k]
end
env.string = copy(string)
env.table = copy(table)
env.math = copy(math)
env.utf8 = copy(utf8)
env.coroutine = copy(coroutine)
env.os = { time = os.time, clock = os.clock, date = os.date, difftime = os.difftime }
env._G = env

env.pcall = function(f, ...) return guard(raw_pcall(f, ...)) end
env.xpcall = function(f, h, ...) return guard(raw_xpcall(f, h, ...)) end
env.coroutine.resume = function(co, ...) return guard(co_resume(co, ...)) end
env.coroutine.wrap = function(f)
  local co = co_create(f)
  return function(...)
    local r = pack(guard(co_resume(co, ...)))
    if not r[1] then raw_error(r[2], 0) end
    return unpack(r, 2, r.n)
  end
end

local function tostr_all(...)
  local n = select("#", ...)
  local parts = {}
  for i = 1, n do parts[i] = tostring((select(i, ...))) end
  return concat(parts, "\t")
end
env.print = function(...) api.log("info", tostr_all(...)) end

-- Text chunks only (no precompiled bytecode), in this plugin's env.
env.load = function(chunk, name, _, e) return load(chunk, name, "t", e or env) end

-- require("mod") / require("dir.mod") loads <plugin dir>/mod.lua or
-- <plugin dir>/dir/mod.lua, nothing else.
local loaded = {}
env.require = function(name)
  if type(name) ~= "string" then raw_error("require: expected a module name", 2) end
  local m = loaded[name]
  if m ~= nil then return m end
  local src, chunkname = api.module(name)
  local f, err = load(src, chunkname, "t", env)
  if not f then raw_error(err, 0) end
  local r = f(name)
  if r == nil then r = true end
  loaded[name] = r
  return r
end

-- ------------------------------------------------------------ callbacks
-- Functions handed to the host (timers, commands, async results) are kept
-- here by id; the host only ever sees the number.

local callbacks, next_cb = {}, 0
local function newcb(fn, what)
  if type(fn) ~= "function" then raw_error(what .. ": expected a function", 3) end
  next_cb = next_cb + 1
  callbacks[next_cb] = fn
  return next_cb
end

local function invoke(id, drop, payload)
  local fn = callbacks[id]
  if drop then callbacks[id] = nil end
  if fn == nil then return nil end
  return fn(payload)
end

-- ------------------------------------------------------------ events

local handlers, next_handler = {}, 0

local function dispatch(event, payload)
  local list = handlers[event]
  if list == nil then return nil end
  local result
  local snapshot = { unpack(list) }
  for _, h in ipairs(snapshot) do
    local ok, r = raw_xpcall(h.fn, traceback, payload)
    if not ok then
      api.report(tostring(r), event)
    elseif event == "key" then
      if r == true then return true end
    elseif event == "ai_suggestion" then
      if r == false then return false end
      if type(r) == "string" then
        payload.text = r
        result = r
      end
    end
  end
  return result
end

-- ------------------------------------------------------------ dt

local dt = {
  version = info.version,
  os = info.os,
  plugin = info.plugin,
  settings = info.settings or {},
  permissions = info.permissions,
}

function dt.has(perm) return api.has(perm) end
function dt.log(...) api.log("info", tostr_all(...)) end
function dt.warn(...) api.log("warn", tostr_all(...)) end

function dt.on(event, fn)
  if type(event) ~= "string" then raw_error("dt.on: expected an event name", 2) end
  if type(fn) ~= "function" then raw_error("dt.on: expected a function", 2) end
  api.subscribe(event)
  next_handler = next_handler + 1
  local list = handlers[event]
  if list == nil then
    list = {}
    handlers[event] = list
  end
  list[#list + 1] = { id = next_handler, fn = fn }
  return next_handler
end

function dt.off(id)
  for event, list in pairs(handlers) do
    for i, h in ipairs(list) do
      if h.id == id then
        remove(list, i)
        if #list == 0 then
          handlers[event] = nil
          api.unsubscribe(event)
        end
        return true
      end
    end
  end
  return false
end

-- Command palette entries.
local commands = {}
function dt.command(spec)
  if type(spec) ~= "table" then raw_error("dt.command: expected { id = ..., title = ..., run = function() end }", 2) end
  if type(spec.id) ~= "string" then raw_error("dt.command: 'id' must be a string", 2) end
  local cb = newcb(spec.run, "dt.command: 'run'")
  api.command(spec.id, spec.title or spec.id, cb)
  commands[spec.id] = cb
  return spec.id
end

-- dt.bind("ctrl+alt+t", fn) or dt.bind("ctrl+alt+t", "<command id>").
function dt.bind(chord, target)
  local cb
  if type(target) == "string" then
    cb = commands[target]
    if cb == nil then raw_error("dt.bind: no command '" .. target .. "' (register it with dt.command first)", 2) end
  else
    cb = newcb(target, "dt.bind")
  end
  return api.bind(chord, cb)
end

dt.status = {
  set = function(id, text, opts) return api.status_set(id, text, opts) end,
  clear = function(id) return api.status_clear(id) end,
}

function dt.notify(text, opts) return api.notify(tostring(text), opts) end

dt.timer = {
  after = function(ms, fn) local id = newcb(fn, "dt.timer.after") api.timer(id, ms, false) return id end,
  every = function(ms, fn) local id = newcb(fn, "dt.timer.every") api.timer(id, ms, true) return id end,
  cancel = function(id)
    if callbacks[id] == nil then return false end
    callbacks[id] = nil
    return api.timer_cancel(id)
  end,
}

dt.theme = {
  register = function(t) return api.theme_register(t) end,
  set = function(name) return api.theme_set(name) end,
  list = function() return api.theme_list() end,
  current = function() return api.theme_current() end,
}

function dt.action(name) return api.action(name) end

dt.term = {
  cwd = function() return api.term("cwd") end,
  title = function() return api.term("title") end,
  ssh = function() return api.term("ssh") end,
  size = function() return api.term("rows"), api.term("cols") end,
  focused = function() return api.term("focused") end,
}

dt.screen = {
  text = function(scrollback) return api.screen_text(scrollback or 0) end,
  lines = function(n)
    local t = api.screen_text(0)
    local lines = {}
    for line in (t .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
    if n ~= nil and n < #lines then
      local tail = {}
      for i = #lines - n + 1, #lines do tail[#tail + 1] = lines[i] end
      return tail
    end
    return lines
  end,
  cursor = function() return api.screen_cursor() end,
}

dt.pty = { write = function(s) return api.pty_write(s) end }

dt.clipboard = {
  set = function(s) return api.clipboard_set(s) end,
  get = function(fn) return api.clipboard_get(newcb(fn, "dt.clipboard.get")) end,
}

dt.http = {
  request = function(req, fn)
    if type(req) ~= "table" then raw_error("dt.http.request: expected { url = ..., method = ... }", 2) end
    return api.http(req, newcb(fn, "dt.http.request"))
  end,
  get = function(url, fn) return api.http({ url = url }, newcb(fn, "dt.http.get")) end,
}

function dt.exec(argv, opts, fn)
  if type(opts) == "function" then
    fn, opts = opts, nil
  end
  return api.exec(argv, opts, newcb(fn, "dt.exec"))
end

dt.fs = {
  read = function(p) return api.fs("read", p) end,
  write = function(p, data) return api.fs("write", p, data) end,
  append = function(p, data) return api.fs("append", p, data) end,
  list = function(p) return api.fs("list", p or ".") end,
  remove = function(p) return api.fs("remove", p) end,
  exists = function(p) return api.fs("exists", p) end,
  mkdir = function(p) return api.fs("mkdir", p) end,
  dir = info.data_dir,
}

env.dt = dt
return env, dispatch, invoke
