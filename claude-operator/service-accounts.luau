--!nonstrict
-- Accounts: every Claude config dir the service knows (~/.claude, the dirs remembered in
-- accounts.json, and the config dirs of running claude processes), each with its label,
-- email and the plan limits it last saw, and the `accounts` list the panel shows.

local core = require("./service-core.luau")
local accounts = core.accounts
local decode, publish, script = core.decode, core.publish, core.script
local HOME, DEFAULT_DIR = core.HOME, core.DEFAULT_DIR
local SAVED_ACCOUNTS, SAVED_LIMITS = core.SAVED_ACCOUNTS, core.SAVED_LIMITS
local M = {}

local function normDir(dir)
  if type(dir) ~= "string" or dir == "" then return nil end
  return (string.gsub(noctalia.expandPath(dir), "/+$", ""))
end

-- "~/.claude" -> "default", "~/.claude-work" -> "work".
local function labelFor(dir)
  if dir == DEFAULT_DIR then return "default" end
  local base = string.match(dir, "([^/]+)$") or dir
  local name = string.gsub(string.gsub(base, "^%.", ""), "^claude[%-_%.]?", "")
  return name ~= "" and name or base
end

-- Account metadata lives in .claude.json: inside the config dir, or beside ~/.claude for
-- the default one. It grows to hundreds of KB, so it is decoded only when it changed.
local function refreshEmail(a)
  local file = a.dir == DEFAULT_DIR and HOME .. "/.claude.json" or a.dir .. "/.claude.json"
  local info = noctalia.fileInfo(file)
  local stamp = info and `{info.size}:{info.mtime}` or nil
  if stamp == a.infoStamp then return end
  a.infoStamp = stamp
  local meta = decode(noctalia.readFile(file))
  a.email = meta and type(meta.oauthAccount) == "table" and meta.oauthAccount.emailAddress or nil
end

local savedLimits = decode(noctalia.readFile(SAVED_LIMITS)) or {}

local function addAccount(dir)
  dir = normDir(dir)
  if not dir or accounts[dir] or not noctalia.fileExists(dir) then return false end
  local saved = savedLimits[dir]
  if type(saved) == "table" then saved.stale = true end
  accounts[dir] = {
    dir = dir, label = labelFor(dir),
    -- Last known limits survive a restart; marked stale until the next fetch lands.
    limits = type(saved) == "table" and saved or nil,
    limitsAt = -math.huge,
    remote = { list = {}, at = -math.huge },
  }
  refreshEmail(accounts[dir])
  return true
end

-- Non-default accounts are remembered so their Recent sessions survive a restart.
local function saveAccounts()
  local dirs = {}
  for dir in pairs(accounts) do if dir ~= DEFAULT_DIR then dirs[#dirs + 1] = dir end end
  table.sort(dirs)
  noctalia.writeFile(SAVED_ACCOUNTS, noctalia.json.encode(dirs))
end

-- Known accounts: ~/.claude, dirs seen before, and (async, via running.sh) the config
-- dirs of running claude processes, including bind mounts over ~/.claude.
function M.discoverAccounts()
  local added = addAccount(DEFAULT_DIR)
  for _, d in ipairs(decode(noctalia.readFile(SAVED_ACCOUNTS)) or {}) do added = addAccount(d) or added end
  for dir, a in pairs(accounts) do
    if noctalia.fileExists(dir) then refreshEmail(a) else accounts[dir] = nil; added = true end
  end
  if added then saveAccounts() end
  noctalia.runAsync(script("running.sh"), function(r)
    local found = false
    for line in string.gmatch(r.stdout or "", "[^\n]+") do found = addAccount(line) or found end
    if found then saveAccounts() end
  end, 10000)
end

-- Default first, then by label.
function M.accountList()
  local list = {}
  for _, a in pairs(accounts) do list[#list + 1] = a end
  table.sort(list, function(x, y)
    if (x.dir == DEFAULT_DIR) ~= (y.dir == DEFAULT_DIR) then return x.dir == DEFAULT_DIR end
    return x.label < y.label
  end)
  return list
end

function M.publishAccounts()
  local out = {}
  for _, a in ipairs(M.accountList()) do
    out[#out + 1] = { dir = a.dir, label = a.label, email = a.email, default = a.dir == DEFAULT_DIR, limits = a.limits }
  end
  publish("accounts", out)
end

return M
