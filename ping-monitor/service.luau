--!nonstrict
-- Ping Monitor service: polls every device (own interval and sound per device), keeps history, publishes a snapshot.
local store = require("./store.luau")

local cfg = store.loadConfig()
local history = store.loadHistory(cfg)
local runtime = {} -- [ip] = { status, lastPing, lastCheck, since, nextCheck, pinging, checkedOnce }

local function rt(ip)
  if not runtime[ip] then
    runtime[ip] = { status = "unknown", lastPing = 0, lastCheck = 0, since = 0, nextCheck = 0, pinging = false, checkedOnce = false }
  end
  return runtime[ip]
end

local function today()
  return noctalia.formatTime("%Y-%m-%d")
end

local function markToday(ip)
  history[ip] = history[ip] or {}
  local key = today()
  if history[ip][key] then return end
  history[ip][key] = true
  local keys = {}
  for k in history[ip] do table.insert(keys, k) end
  table.sort(keys)
  local maxKeep = (tonumber(noctalia.getConfig("history_days")) or 14) * 3
  while #keys > maxKeep do
    history[ip][table.remove(keys, 1)] = nil
  end
  store.saveHistory(history)
end

local function publish()
  local list = {}
  for _, d in cfg.devices do
    local r = rt(d.ip)
    table.insert(list, {
      name = d.name, ip = d.ip, interval = d.interval, sound = d.sound,
      status = r.status, lastPing = r.lastPing, lastCheck = r.lastCheck, since = r.since,
      history = history[d.ip] or {},
    })
  end
  noctalia.state.set("snap", noctalia.json.encode({
    devices = list, muted = cfg.muted, days = tonumber(noctalia.getConfig("history_days")) or 14,
  }))
end

local function playSound()
  if noctalia.getConfig("sound_enabled") == false then return end
  local file = noctalia.getConfig("sound_file")
  if not file or file == "" then return end
  noctalia.sound.load("online", file, function(ok, err)
    if ok then noctalia.sound.play("online") else noctalia.log("ping-monitor: sound failed: " .. tostring(err)) end
  end)
end

local function check(d)
  local r = rt(d.ip)
  if r.pinging then return end
  r.pinging = true
  noctalia.runAsync({ "ping", "-c", "1", "-W", "2", d.ip }, function(result)
    r.pinging = false
    local now = math.floor(noctalia.nowMs() / 1000)
    r.lastCheck = now
    local up = result.exitCode == 0
    if up then
      r.lastPing = now
      markToday(d.ip)
    end
    local new = up and "up" or "down"
    if new ~= r.status then
      r.status = new
      r.since = now
      if up and r.checkedOnce then
        if d.sound ~= false and not cfg.muted then playSound() end
        local label = (d.name and d.name ~= "") and (d.name .. " (" .. d.ip .. ")") or d.ip
        noctalia.notify(noctalia.tr("title"), noctalia.tr("online") .. ": " .. label)
      end
    end
    r.checkedOnce = true
    publish()
  end)
end

local function reload()
  cfg = store.loadConfig()
  -- forget devices that were removed
  local keep = {}
  for _, d in cfg.devices do keep[d.ip] = true end
  for ip in runtime do
    if not keep[ip] then runtime[ip] = nil end
  end
  publish()
end

noctalia.state.watch("cfg_rev", function() reload() end)

publish()

function update()
  noctalia.setUpdateInterval(1000)
  local now = math.floor(noctalia.nowMs() / 1000)
  for _, d in cfg.devices do
    local r = rt(d.ip)
    if now >= r.nextCheck then
      r.nextCheck = now + math.max(3, tonumber(d.interval) or 15)
      check(d)
    end
  end
end

function onConfigChanged()
  publish()
end
