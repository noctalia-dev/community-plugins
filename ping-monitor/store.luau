--!nonstrict
-- Ping Monitor storage: devices, groups and the global mute (config.json), per-device history (history.json).
local M = {}

local INTERVALS = { 5, 10, 15, 30, 60, 120, 300 }
M.INTERVALS = INTERVALS

local function path(name)
  local dir = noctalia.pluginDataDir()
  return dir and (dir .. "/" .. name) or nil
end

-- Returns the decoded table, or nil plus a reason: "missing" (no file yet) or "unreadable" (present but not readable
-- or not valid JSON). Callers must never overwrite an unreadable file: it may be the user's only copy of the list.
local function readJson(name)
  local p = path(name)
  if not p then return nil, "unreadable" end
  if not noctalia.fileExists(p) then return nil, "missing" end
  local text = noctalia.readFile(p)
  if not text then return nil, "unreadable" end
  local ok, data = pcall(noctalia.json.decode, text)
  if ok and type(data) == "table" then return data end
  return nil, "unreadable"
end

-- writeFile truncates the destination before writing, so an interrupted or failed write would leave an empty or
-- partial file. Write a sibling temp file and move it over the real one only after the write succeeded.
local function writeJson(name, data)
  local p = path(name)
  if not p then return false end
  local tmp = p .. ".tmp"
  local ok, err = noctalia.writeFile(tmp, noctalia.json.encode(data))
  if not ok then
    noctalia.removeFile(tmp)
    noctalia.log("ping-monitor: could not save " .. name .. ": " .. tostring(err))
    return false
  end
  local moved, merr = noctalia.renameFile(tmp, p)
  if not moved then
    noctalia.removeFile(tmp)
    noctalia.log("ping-monitor: could not replace " .. name .. ": " .. tostring(merr))
    return false
  end
  return true
end

-- `readonly` is set when config.json exists but cannot be read: the plugin then runs on an empty list in memory and
-- refuses to save until the file is fixed, so a broken file is never replaced by an empty one.
M.readonly = false

function M.loadConfig()
  local cfg, why = readJson("config.json")
  if cfg == nil or type(cfg.devices) ~= "table" then
    cfg = { muted = false, devices = {}, groups = {} }
    if why == "missing" then
      M.readonly = false
      writeJson("config.json", cfg) -- genuine first run
    else
      M.readonly = true
      noctalia.log("ping-monitor: config.json exists but is unreadable or invalid; leaving it untouched")
      return cfg
    end
  else
    M.readonly = false
  end
  if M.ensureGroups(cfg) then writeJson("config.json", cfg) end
  return cfg
end

-- Groups live in the config next to the devices. First run after the version that kept group names in the plugin
-- settings: seed the list from those names and from the groups already set on devices.
function M.ensureGroups(cfg)
  if type(cfg.groups) == "table" then return false end
  cfg.groups = {}
  local seen = {}
  local function add(name)
    if type(name) == "string" and name ~= "" and not seen[name] then
      seen[name] = true
      table.insert(cfg.groups, { name = name, collapsed = false })
    end
  end
  local ok, names = pcall(noctalia.getConfig, "groups")
  if ok and type(names) == "table" then
    for _, g in names do add(g) end
  end
  for _, d in cfg.devices do add(d.group) end
  return true
end

function M.groupIndex(cfg, name)
  for i, g in cfg.groups do
    if g.name == name then return i end
  end
  return nil
end

-- returns the name actually stored (trimmed), or nil when empty
function M.addGroup(cfg, raw)
  local name = noctalia.string.trim(raw or "")
  if name == "" then return nil end
  if not M.groupIndex(cfg, name) then table.insert(cfg.groups, { name = name, collapsed = false }) end
  return name
end

function M.renameGroup(cfg, old, raw)
  local name = noctalia.string.trim(raw or "")
  local i = M.groupIndex(cfg, old)
  if name == "" or not i or name == old then return false end
  if M.groupIndex(cfg, name) then return false end
  cfg.groups[i].name = name
  for _, d in cfg.devices do
    if d.group == old then d.group = name end
  end
  return true
end

-- devices of a removed group are not deleted: they fall back to "no group"
function M.removeGroup(cfg, name)
  local i = M.groupIndex(cfg, name)
  if not i then return end
  table.remove(cfg.groups, i)
  for _, d in cfg.devices do
    if d.group == name then d.group = "" end
  end
end

-- move group `from` (index) in front of the group called `beforeName`, or to the end when that is empty
function M.moveGroup(cfg, from, beforeName)
  local g = cfg.groups[from]
  if not g then return end
  local to = #cfg.groups
  if beforeName and beforeName ~= "" then
    to = M.groupIndex(cfg, beforeName) or to
  end
  table.remove(cfg.groups, from)
  if beforeName and beforeName ~= "" then
    if to > from then to = to - 1 end
  else
    to = #cfg.groups + 1
  end
  table.insert(cfg.groups, to, g)
end

function M.setCollapsed(cfg, name, value)
  local i = M.groupIndex(cfg, name)
  if i then cfg.groups[i].collapsed = value == true end
end

-- device `from` goes to the end of group `name` ("" = no group)
function M.moveDeviceToGroup(cfg, from, name)
  local dev = cfg.devices[from]
  if not dev then return end
  table.remove(cfg.devices, from)
  dev.group = name
  local last = 0
  for i, d in cfg.devices do
    if (d.group or "") == name then last = i end
  end
  table.insert(cfg.devices, last == 0 and (#cfg.devices + 1) or (last + 1), dev)
end

-- false when the change could not be stored (the file was unreadable at load, or the write failed)
function M.saveConfig(cfg)
  if M.readonly then return false end
  return writeJson("config.json", cfg)
end

-- history: { [ip] = { [yyyy-mm-dd] = true } }; a legacy flat map (date -> true) moves to the first device
M.historyReadonly = false

function M.loadHistory(cfg)
  local h, why = readJson("history.json")
  M.historyReadonly = h == nil and why ~= "missing"
  h = h or {}
  for key, value in h do
    if value == true then
      local first = cfg.devices[1]
      local ip = first and first.ip or "unknown"
      h[ip] = h[ip] or {}
      h[ip][key] = true
      h[key] = nil
    end
  end
  return h
end

function M.saveHistory(h)
  if M.historyReadonly then return false end -- never replace an unreadable history with a fresh one
  return writeJson("history.json", h)
end

function M.intervalIndex(seconds)
  for i, v in INTERVALS do
    if v == seconds then return i end
  end
  return 3
end

-- Address parsing (IP, host name or link), adapted from nilsonlinux/link-ip-monitor (MIT): scheme, port, path and query are dropped, leaving the host that is pinged.

local function trim(x)
  return noctalia.string.trim(x or "")
end

local function isValidIPv4(host)
  local a, b, c, d = host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then return false end
  for _, n in ipairs({ a, b, c, d }) do
    local v = tonumber(n)
    if v == nil or v < 0 or v > 255 then return false end
  end
  return true
end

local function isValidHostname(host)
  if host == "" or #host > 253 then return false end
  local labels = 0
  for label in host:gmatch("[^%.]+") do
    labels = labels + 1
    if #label == 0 or #label > 63 then return false end
    if not label:match("^%w[%w%-]*%w$") and not label:match("^%w$") then return false end
  end
  return labels > 0
end

function M.normalizeHost(raw)
  local s = trim(raw)
  s = s:gsub("^%a[%w+.-]*://", "")
  s = s:match("^([^/%?#]+)") or s
  s = s:match("^([^:]+)") or s
  if s == "" then return nil end
  if isValidIPv4(s) or isValidHostname(s) then return s end
  return nil
end

-- device order: move one position up or down
function M.move(cfg, index, delta)
  local j = index + delta
  if j < 1 or j > #cfg.devices then return false end
  cfg.devices[index], cfg.devices[j] = cfg.devices[j], cfg.devices[index]
  return true
end

return M
