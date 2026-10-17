-- git_branch: shows the branch of the shell's working directory in the
-- status bar. Needs the shell to report its cwd (OSC 7; the bundled shell
-- integration does) and, in config.lua:
--
--   config.status_bar = { enabled = true }
--   config.plugins.git_branch = { allow = { "exec" }, exec = { "git" } }

local last_dir = nil
local busy = false

local function show(text)
  if text and text ~= "" then
    dt.status.set("branch", "⎇ " .. text, { fg = "#a3be8c" })
  else
    dt.status.clear("branch")
  end
end

local function refresh(force)
  local dir = dt.term.cwd()
  if dir == "" or busy then return end
  if dir == last_dir and not force then return end
  last_dir = dir
  if not dt.has("exec") then
    show("git_branch: allow exec")
    return
  end
  busy = true
  dt.exec({ "git", "status", "--porcelain=v1", "--branch", "--untracked-files=no" },
    { cwd = dir, timeout_ms = 2000 },
    function(r)
      busy = false
      if not r.ok then return show(nil) end
      local head = r.stdout:match("^## ([^\n]*)") or ""
      local branch = head:match("^No commits yet on (%S+)") or head:match("^([^%.%s]+)") or head
      if branch:match("^HEAD") then branch = "(detached)" end
      local dirty = r.stdout:find("\n[^#]") ~= nil
      show(branch .. (dirty and " *" or ""))
    end)
end

dt.on("startup", function() refresh(true) end)
dt.on("cwd", function() refresh(false) end)
-- A commit / checkout changes the branch without changing directory.
dt.on("command_finish", function() refresh(true) end)
dt.on("focus", function(e) if e.focused then refresh(true) end end)

dt.command({ id = "git_branch.refresh", title = "Git: refresh branch", run = function() refresh(true) end })
