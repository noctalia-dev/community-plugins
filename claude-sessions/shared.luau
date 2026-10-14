--!nonstrict
-- Helpers shared by the panel and the launcher provider.
local M = {}
local PLUGIN = noctalia.pluginDir()
local HOME = noctalia.getenv("HOME") or ""

local rootSetting = noctalia.string.trim(tostring(noctalia.getConfig("work_root") or ""))
local WORK = rootSetting ~= "" and (string.gsub(noctalia.expandPath(rootSetting), "/+$", "") .. "/") or nil

-- Projects under the projects root (if set) show relative to it; anything else shows its full path.
function M.projectPath(p)
  if WORK and string.sub(p, 1, #WORK) == WORK then return string.sub(p, #WORK + 1) end
  return p
end

function M.workRoot() return WORK and string.sub(WORK, 1, -2) or HOME end

local function quote(s) return "'" .. string.gsub(s, "'", "'\\''") .. "'" end

function M.dur(s)
  s = math.max(0, math.floor(s))
  if s < 60 then return `{s}s` elseif s < 3600 then return `{s // 60}m` elseif s < 86400 then return `{s // 3600}h` end
  return `{s // 86400}d`
end

function M.ago(ms) return M.dur((noctalia.nowMs() - ms) / 1000) end

-- Accounts are Claude config dirs (see service.luau); ~/.claude is the default one.
local DEFAULT_DIR = HOME .. "/.claude"

function M.accounts() return noctalia.state.get("accounts") or {} end

function M.multiAccount() return #M.accounts() > 1 end

function M.accountLabel(dir)
  for _, a in ipairs(M.accounts()) do if a.dir == dir then return a.label end end
  return dir and (string.match(dir, "([^/]+)$") or dir) or "default"
end

function M.transcript(account, cwd, sid)
  return `{account or DEFAULT_DIR}/projects/{(string.gsub(cwd, "[^%w]", "-"))}/{sid}.jsonl`
end

-- argv running claude (with extra args) under the given account.
function M.claudeArgv(account, ...)
  local argv = {}
  if account and account ~= DEFAULT_DIR then argv = { "env", "CLAUDE_CONFIG_DIR=" .. account } end
  argv[#argv + 1] = "claude"
  for _, a in ipairs({ ... }) do argv[#argv + 1] = a end
  return argv
end

-- Brings the session's terminal to the front; a Remote Control session without a findable
-- window (e.g. `claude remote-control` running headless) opens on claude.ai instead.
function M.focus(s)
  noctalia.runAsync({ PLUGIN .. "/focus.sh", tostring(s.pid) }, function(r)
    if r.exitCode ~= 0 and s.remote then noctalia.runAsync({ "xdg-open", s.remote }) end
  end, 10000)
end

-- Runs argv (or a shell when empty) in dir: a new tab in the most recently focused kitty when
-- kitty remote control is available, otherwise Noctalia's configured terminal.
function M.launch(dir, argv)
  argv = argv or {}
  local cmd = { PLUGIN .. "/launch.sh", dir }
  for _, a in ipairs(argv) do cmd[#cmd + 1] = a end
  local function fallback()
    local words = {}
    for _, a in ipairs(argv) do words[#words + 1] = quote(a) end
    local run = #words > 0 and table.concat(words, " ") or "exec \"${SHELL:-sh}\""
    noctalia.runInTerminal(`cd {quote(dir)} && {run}`)
  end
  if not noctalia.runAsync(cmd, function(r) if r.exitCode ~= 0 then fallback() end end, 15000) then fallback() end
end

function M.resume(account, cwd, sid) M.launch(cwd, M.claudeArgv(account, "--resume", sid)) end

function M.resumeCommand(account, cwd, sid)
  local env = account and account ~= DEFAULT_DIR and `CLAUDE_CONFIG_DIR={quote(account)} ` or ""
  return `cd {quote(cwd)} && {env}claude --resume {sid}`
end

return M
