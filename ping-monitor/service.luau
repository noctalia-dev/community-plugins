--!nonstrict
-- Ping Monitor service: polls every device (own interval and sound each), keeps history, publishes a snapshot.
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
      name = d.name, ip = d.ip, group = d.group, interval = d.interval, sound = d.sound,
      status = r.status, lastPing = r.lastPing, lastCheck = r.lastCheck, since = r.since, latency = r.latency,
      history = history[d.ip] or {},
    })
  end
  noctalia.state.set("snap", noctalia.json.encode({
    devices = list, groups = cfg.groups or {}, muted = cfg.muted, days = tonumber(noctalia.getConfig("history_days")) or 14,
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

-- A device counts as down only after `fail_threshold` failed checks in a row. One check sends three pings
-- (any reply is enough), and a failed check is repeated after a few seconds instead of waiting for the full interval.
-- A single lost packet (Wi-Fi power saving, a sleeping laptop waking up) no longer shows up as "offline".
local function check(d)
  local r = rt(d.ip)
  if r.pinging then return end
  r.pinging = true
  local timeout = tonumber(noctalia.getConfig("timeout_seconds")) or 2
  local threshold = math.max(1, tonumber(noctalia.getConfig("fail_threshold")) or 2)
  noctalia.runAsync({ "ping", "-c", "3", "-i", "0.3", "-W", tostring(timeout), d.ip }, function(result)
    r.pinging = false
    local now = math.floor(noctalia.nowMs() / 1000)
    r.lastCheck = now
    local up = result.exitCode == 0
    r.latency = up and tonumber(string.match(result.stdout or "", "time=([%d%.]+)")) or nil
    if up then
      r.fails = 0
      r.lastPing = now
      markToday(d.ip)
    else
      r.fails = (r.fails or 0) + 1
      -- evidence for the "false offline" reports: why the check failed
      noctalia.log(string.format("ping-grid: %s check failed (%d/%d) exit=%s timedOut=%s stderr=%s",
        d.ip, r.fails, threshold, tostring(result.exitCode), tostring(result.timedOut), string.sub(result.stderr or "", 1, 120)))
      if r.fails < threshold then
        -- not confirmed yet: keep the shown state and look again soon
        r.nextCheck = now + 3
        r.checkedOnce = true
        publish()
        return
      end
    end
    local new = up and "up" or "down"
    if new ~= r.status then
      r.status = new
      r.since = now
      local label = (d.name and d.name ~= "") and (d.name .. " (" .. d.ip .. ")") or d.ip
      if up and r.checkedOnce and noctalia.getConfig("notify_on_recovery") ~= false then
        if d.sound ~= false and not cfg.muted then playSound() end
        noctalia.notify(noctalia.tr("title"), noctalia.tr("online") .. ": " .. label)
      elseif not up and r.checkedOnce and noctalia.getConfig("notify_on_down") ~= false then
        noctalia.notifyError(noctalia.tr("title"), noctalia.tr("offline") .. ": " .. label)
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

-- Right click on the bar icon: check every device now instead of waiting for its interval.
noctalia.state.watch("refresh_rev", function()
  for _, r in runtime do r.nextCheck = 0 end
  for _, d in cfg.devices do rt(d.ip).nextCheck = 0 end
end)

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
