--!nonstrict
-- Ping Monitor storage: devices, groups and the global mute (config.json), per-device history (history.json).
local M = {}

local INTERVALS = { 5, 10, 15, 30, 60, 120, 300 }
M.INTERVALS = INTERVALS

local function path(name)
  local dir = noctalia.pluginDataDir()
  return dir and (dir .. "/" .. name) or nil
end

local function readJson(name)
  local p = path(name)
  if not p then return nil end
  local text = noctalia.readFile(p)
  if not text then return nil end
  local ok, data = pcall(noctalia.json.decode, text)
  if ok and type(data) == "table" then return data end
  return nil
end

local function writeJson(name, data)
  local p = path(name)
  if p then noctalia.writeFile(p, noctalia.json.encode(data)) end
end

function M.loadConfig()
  local cfg = readJson("config.json")
  if cfg == nil or type(cfg.devices) ~= "table" then
    -- first run: start with an empty list
    cfg = { muted = false, devices = {}, groups = {} }
    writeJson("config.json", cfg)
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

function M.saveConfig(cfg)
  writeJson("config.json", cfg)
end

-- history: { [ip] = { [yyyy-mm-dd] = true } }; a legacy flat map (date -> true) moves to the first device
function M.loadHistory(cfg)
  local h = readJson("history.json") or {}
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
  writeJson("history.json", h)
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
