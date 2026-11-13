--!nonstrict
-- Social Block service: owns the on/off state, timers, schedule, stats,
-- enforcement and the per-service allowlist. Entries talk to it over IPC;
-- state is shared via noctalia.state.

local HELPER = "/usr/local/bin/social-block-net"
local PLUGIN = "treeonlinux/social-block"
local BACKUP = "/etc/hosts.social-block.bak"

local function readConfig()
  return {
    closeApps = noctalia.getConfig("close_apps") ~= false,
    closeWindows = noctalia.getConfig("close_windows") == true,
    scheduleEnabled = noctalia.getConfig("schedule_enabled") == true,
    scheduleStart = noctalia.getConfig("schedule_start") or "09:00",
    scheduleEnd = noctalia.getConfig("schedule_end") or "17:00",
  }
end

local cfg = readConfig()
local closeApps = cfg.closeApps
local closeWindows = cfg.closeWindows
local scheduleEnabled = cfg.scheduleEnabled
local scheduleStart = cfg.scheduleStart
local scheduleEnd = cfg.scheduleEnd

local blocked = false
local since = 0
local untilMs = 0
local mode = "manual"          -- manual | timer | schedule
local busy = false
local appCheckBusy = false
local winCheckBusy = false
local servicesBusy = false
local statusBusy = false
local lastPublishRemaining = -1
local lastStatusCheck = 0

local services = {}
local servicesLoaded = false
local setupRequired = false
local helperError = ""

local stats = {}               -- { ["YYYY-MM-DD"] = minutes }
local lastStatMs = 0
local lastScheduleDate = ""

local patterns = {
  { "youtube.com", "youtube" }, { "youtube", "youtube" },
  { "netflix", "netflix" }, { "discord", "discord" },
  { "instagram", "instagram" }, { "tiktok", "tiktok" },
  { "twitter", "x" }, { "x.com", "x" }, { "reddit", "reddit" },
  { "twitch", "twitch" }, { "facebook", "facebook" }, { "slack", "slack" },
  { "hulu", "hulu" }, { "disney+", "disneyplus" }, { "disneyplus", "disneyplus" },
  { "prime video", "primevideo" }, { "crunchyroll", "crunchyroll" },
  { "peacock", "peacock" }, { "paramount", "paramountplus" },
  { "bilibili", "bilibili" }, { "tubi", "tubi" }, { "pluto", "pluto" },
  { "vimeo", "vimeo" }, { "dailymotion", "dailymotion" },
  { "pinterest", "pinterest" }, { "tumblr", "tumblr" },
  { "linkedin", "linkedin" }, { "telegram", "telegram" },
  { "whatsapp", "whatsapp" }, { "snapchat", "snapchat" },
  { "9gag", "9gag" }, { "4chan", "4chan" },
}

local dataDir = noctalia.pluginDataDir()
local statePath = dataDir and (dataDir .. "/state.json") or nil

local function trim(s)
  return (string.gsub(s or "", "^%s*(.-)%s*$", "%1"))
end

local function truncate(s, n)
  s = trim(s)
  if #s > n then return string.sub(s, 1, n) .. "…" end
  return s
end

local function dayKey(offsetDays)
  local secs = (noctalia.nowMs() // 1000) + (offsetDays or 0) * 86400
  return noctalia.formatTime("%Y-%m-%d", secs)
end

local function parseHHMM(value)
  local h, m = string.match(value or "", "^(%d%d?):(%d%d)$")
  if not h then return nil end
  h, m = tonumber(h), tonumber(m)
  if h > 23 or m > 59 then return nil end
  return h * 60 + m
end

local function privilegeTool()
  if noctalia.commandExists("sudo") then return "sudo" end
  return "doas"
end

local function helperArgs(action, arg)
  local args = { privilegeTool(), "-n", HELPER, action }
  if arg and arg ~= "" then args[#args + 1] = arg end
  return args
end

local function listArgs()
  return { HELPER, "list" }
end

local function serviceLabel(id)
  for _, s in ipairs(services) do
    if s.id == id then return s.name end
  end
  return id
end

local function persist()
  if not statePath then return end
  noctalia.writeFile(statePath, noctalia.json.encode({
    blocked = blocked,
    since = since,
    untilMs = untilMs,
    mode = mode,
    stats = stats,
    lastStatMs = lastStatMs,
    lastScheduleDate = lastScheduleDate,
  }))
end

local function streak()
  local n = 0
  local i = 0
  if (stats[dayKey(0)] or 0) == 0 then i = 1 end
  while (stats[dayKey(-i)] or 0) > 0 and n < 365 do
    n = n + 1
    i = i + 1
  end
  return n
end

local publish  -- forward declaration

publish = function()
  local now = noctalia.nowMs()
  local remaining = 0
  if blocked and untilMs > 0 then
    remaining = math.max(0, math.ceil((untilMs - now) / 60000))
  end

  local graph, maxv = {}, 1
  for i = 6, 0, -1 do
    local v = stats[dayKey(-i)] or 0
    if v > maxv then maxv = v end
    graph[#graph + 1] = v
  end
  for i = 1, #graph do graph[i] = graph[i] / maxv end

  noctalia.state.set("blocked", blocked)
  noctalia.state.set("since", since)
  noctalia.state.set("untilMs", untilMs)
  noctalia.state.set("remaining", remaining)
  noctalia.state.set("mode", mode)
  noctalia.state.set("todayMinutes", stats[dayKey(0)] or 0)
  noctalia.state.set("streak", streak())
  noctalia.state.set("graph", graph)
  noctalia.state.set("services", services)
  noctalia.state.set("servicesLoaded", servicesLoaded)
  noctalia.state.set("setupRequired", setupRequired)
  noctalia.state.set("helperError", helperError or "")
  lastPublishRemaining = remaining
end

local function notify(body)
  noctalia.notify("Social Block", body)
end

local function serviceBlocked(id)
  if #services == 0 then return id == "discord" end
  local legacy = nil
  for _, s in ipairs(services) do
    if s.id == "all" then legacy = s.blocked end
    if s.id == id then return s.blocked end
  end
  if legacy ~= nil then return legacy end
  return id == "discord"
end

local function closeAppsNow()
  if serviceBlocked("discord") then
    noctalia.runAsync({ "flatpak", "kill", "com.discordapp.Discord" })
    noctalia.runAsync({ "pkill", "-x", "Discord" })
    noctalia.runAsync({ "pkill", "-x", "discord" })
    noctalia.runAsync({ "pkill", "-x", "vesktop" })
    noctalia.runAsync({ "pkill", "-x", "webcord" })
    noctalia.runAsync({ "pkill", "-x", "armcord" })
    noctalia.runAsync({ "pkill", "-x", "discordcanary" })
    noctalia.runAsync({ "pkill", "-x", "discordptb" })
  end
  if serviceBlocked("slack") then
    noctalia.runAsync({ "flatpak", "kill", "com.slack.Slack" })
    noctalia.runAsync({ "pkill", "-x", "slack" })
    noctalia.runAsync({ "pkill", "-x", "Slack" })
  end
end

local function closeSocialWindows()
  if winCheckBusy then return end
  winCheckBusy = true
  noctalia.runAsync({ "hyprctl", "clients", "-j" }, function(res)
    winCheckBusy = false
    if res.exitCode ~= 0 or not res.stdout or res.stdout == "" then return end
    local ok, clients = pcall(noctalia.json.decode, res.stdout)
    if not ok or type(clients) ~= "table" then return end
    for _, c in ipairs(clients) do
      local hay = string.lower((c.class or "") .. " " .. (c.title or ""))
      for _, p in ipairs(patterns) do
        if serviceBlocked(p[2]) and string.find(hay, p[1], 1, true) then
          if c.address then
            noctalia.runAsync({ "hyprctl", "dispatch", "closewindow", "address:" .. c.address })
          end
          break
        end
      end
    end
  end, 5000)
end

local function parseServices(stdout)
  local out = {}
  for line in string.gmatch(stdout or "", "[^\r\n]+") do
    local id, category, name, count, state = string.match(
      line, "^([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
    if id then
      out[#out + 1] = {
        id = id,
        category = trim(category),
        name = trim(name),
        count = tonumber(count) or 0,
        blocked = trim(state) ~= "allowed",
      }
    end
  end
  return out
end

local function fetchServices()
  if servicesBusy then return end
  servicesBusy = true
  noctalia.runAsync(listArgs(), function(res)
    servicesBusy = false
    servicesLoaded = true
    if res.exitCode == 0 and res.stdout and res.stdout ~= "" then
      services = parseServices(res.stdout)
      if #services == 0 then
        helperError = "No services found in /etc/social-block/domains."
      else
        -- A successful list also clears the "helper out of date" migration
        -- error from before the installer update.
        helperError = ""
      end
    else
      services = {}
      local err = truncate((res.stderr and res.stderr ~= "") and res.stderr or "", 300)
      if not noctalia.fileExists(HELPER) then
        setupRequired = true
      elseif string.find(string.lower(err), "usage", 1, true) then
        helperError = "The installed helper is out of date. Run install-helper.sh --update-domains."
      else
        helperError = err ~= "" and err
          or ("helper list failed (exit " .. tostring(res.exitCode) .. ")")
      end
    end
    publish()
  end, 5000)
end

local function apply(on, opts)
  if busy then return end
  if on and #services > 0 then
    local any = false
    for _, s in ipairs(services) do
      if s.blocked then any = true; break end
    end
    if not any then
      notify("Allow at least one service before turning the block on.")
      return
    end
  end
  busy = true
  opts = opts or {}

  noctalia.runAsync(helperArgs(on and "on" or "off"), function(res)
    busy = false
    lastStatusCheck = noctalia.nowMs()
    if res.exitCode ~= 0 then
      local detail = truncate((res.stderr and res.stderr ~= "") and res.stderr or "", 200)
      helperError = detail ~= "" and detail
        or ("helper " .. (on and "on" or "off") .. " failed (exit " .. tostring(res.exitCode) .. ")")
      setupRequired = true
      persist()
      publish()
      noctalia.notifyError(
        "Social Block",
        "Could not change the block. " .. detail .. " Run install-helper.sh (see README)."
      )
      return
    end

    helperError = ""
    setupRequired = false
    local wasBlocked = blocked
    blocked = on
    if on then
      local now = noctalia.nowMs()
      if not wasBlocked then
        since = now
        lastStatMs = now
      end
      mode = opts.mode or "manual"
      untilMs = (opts.duration and opts.duration > 0)
        and (now + opts.duration * 60000)
        or 0
      if closeApps then closeAppsNow() end
    else
      since = 0
      untilMs = 0
      mode = "manual"
      lastStatMs = 0
    end

    persist()
    publish()
    fetchServices()

    if on then
      if untilMs > 0 then
        notify("Blocked for " .. math.ceil((untilMs - noctalia.nowMs()) / 60000) .. " minutes.")
      else
        notify("Social sites blocked until you turn it off.")
      end
    else
      notify("Social Block is off.")
    end
  end, 20000)
end

local function blockedServiceCount()
  local n = 0
  for _, s in ipairs(services) do
    if s.blocked then n = n + 1 end
  end
  return n
end

local function setService(id, shouldBlock)
  if busy then return end

  -- Allowing the last blocked service while the block is on should end the
  -- block instead of writing an empty hosts block (and then still allow it).
  if not shouldBlock and blocked and blockedServiceCount() <= 1 then
    busy = true
    noctalia.runAsync(helperArgs("off"), function(res)
      busy = false
      lastStatusCheck = noctalia.nowMs()
      if res.exitCode ~= 0 then
        local detail = truncate((res.stderr and res.stderr ~= "") and res.stderr or "", 200)
        helperError = detail ~= "" and detail or "helper off failed"
        setupRequired = true
        persist()
        publish()
        noctalia.notifyError("Social Block", "Could not turn the block off. " .. detail)
        return
      end
      blocked = false
      since = 0
      untilMs = 0
      mode = "manual"
      lastStatMs = 0
      helperError = ""
      setupRequired = false
      persist()
      publish()
      setService(id, false)
    end, 20000)
    return
  end

  busy = true

  noctalia.runAsync(helperArgs(shouldBlock and "block" or "allow", id), function(res)
    busy = false
    lastStatusCheck = noctalia.nowMs()
    if res.exitCode ~= 0 then
      local detail = truncate((res.stderr and res.stderr ~= "") and res.stderr or "", 200)
      helperError = detail ~= "" and detail
        or ("helper allow/block failed (exit " .. tostring(res.exitCode) .. ")")
      setupRequired = true
      persist()
      publish()
      noctalia.notifyError(
        "Social Block",
        "Could not update " .. serviceLabel(id) .. ". " .. detail
      )
      return
    end

    helperError = ""
    setupRequired = false
    if shouldBlock and blocked and closeApps then closeAppsNow() end
    persist()
    publish()
    fetchServices()
    notify((shouldBlock and "Blocking " or "Allowing ") .. serviceLabel(id) .. ".")
  end, 15000)
end

local function extend(minutes)
  if not blocked or busy then return end
  local base = math.max(noctalia.nowMs(), untilMs)
  untilMs = base + minutes * 60000
  mode = "timer"
  persist()
  publish()
  notify("Timer extended by " .. minutes .. " minutes.")
end

local function forever()
  if not blocked then return end
  untilMs = 0
  mode = "manual"
  persist()
  publish()
  notify("Timer cleared; blocking until you turn it off.")
end

function toggle()
  if busy then return end
  apply(not blocked)
end

local function checkStatus(initial, savedSince)
  if statusBusy then return end
  statusBusy = true
  local started = noctalia.nowMs()

  noctalia.runAsync(helperArgs("status"), function(res)
    statusBusy = false
    lastStatusCheck = noctalia.nowMs()
    local wasBlocked = blocked

    if res.exitCode == 0 then
      local raw = res.stdout or ""
      local s = string.lower((string.gsub(raw, "%s+", "")))
      if s == "on" then
        blocked = true
        if initial then
          since = (savedSince and savedSince > 0) and savedSince or started
          lastStatMs = started
        elseif not wasBlocked then
          since = started
          lastStatMs = started
        end
        if since == 0 then since = started end
        if #services > 0 or not servicesLoaded then helperError = "" end
        setupRequired = false
      elseif s == "off" then
        blocked = false
        since = 0
        untilMs = 0
        mode = "manual"
        lastStatMs = 0
        if #services > 0 or not servicesLoaded then helperError = "" end
        setupRequired = false
      elseif s == "incomplete" then
        blocked = true
        helperError = "The /etc/hosts block is incomplete (BEGIN without END). "
          .. "Restore " .. BACKUP .. " or edit /etc/hosts by hand."
        setupRequired = false
      else
        helperError = "Unexpected helper status: " .. truncate(raw, 120)
      end
    else
      helperError = truncate(
        (res.stderr and res.stderr ~= "") and res.stderr
          or ("helper status failed (exit " .. tostring(res.exitCode) .. ")"), 300)
      setupRequired = true
      -- Keep the last known blocked state instead of reporting a false OFF.
    end

    if not initial and wasBlocked ~= blocked then
      notify(blocked and "Blocking is on." or "Blocking is off.")
    end
    -- After a helper update the service list may have been empty at load;
    -- retry it on the periodic check so the panel fills in by itself.
    if not initial and #services == 0 then fetchServices() end

    persist()
    publish()
  end, 8000)
end

function onConfigChanged()
  local nextCfg = readConfig()
  local scheduleChanged = nextCfg.scheduleEnabled ~= scheduleEnabled
    or nextCfg.scheduleStart ~= scheduleStart
    or nextCfg.scheduleEnd ~= scheduleEnd

  closeApps = nextCfg.closeApps
  closeWindows = nextCfg.closeWindows
  scheduleEnabled = nextCfg.scheduleEnabled
  scheduleStart = nextCfg.scheduleStart
  scheduleEnd = nextCfg.scheduleEnd

  if scheduleChanged then
    lastScheduleDate = ""
    persist()
    if scheduleEnabled and (not parseHHMM(scheduleStart) or not parseHHMM(scheduleEnd)) then
      noctalia.notifyError("Social Block", "Schedule start and end must be valid 24-hour HH:MM times.")
    end
  end

  if not scheduleEnabled and blocked and mode == "schedule" then
    apply(false)
  end
end

function onExit(_signal, reason)
  persist()
  if reason == "disable" or reason == "uninstall" then
    noctalia.runAsync(helperArgs("off"))
  end
end

function onIpc(event, payload)
  if event == "toggle" then
    toggle()
  elseif event == "on" then
    apply(true, { mode = "manual" })
  elseif event == "off" then
    apply(false)
  elseif event == "timer" then
    local minutes = tonumber(payload) or 0
    if minutes <= 0 then return end
    if blocked then extend(minutes) else apply(true, { mode = "timer", duration = minutes }) end
  elseif event == "forever" then
    forever()
  elseif event == "refresh" then
    fetchServices()
    checkStatus(false, 0)
  elseif event == "services" then
    fetchServices()
  elseif event == "allow" or event == "block" then
    local id = payload and string.match(payload, "^([a-z0-9-]+)$")
    if id then setService(id, event == "block") end
  else
    -- Lua/Luau patterns have no alternation; validate each action explicitly.
    local text = event or ""
    local id = string.match(text, "^allow%s+([a-z0-9-]+)$")
    if id then
      setService(id, false)
      return
    end
    id = string.match(text, "^block%s+([a-z0-9-]+)$")
    if id then setService(id, true) end
  end
end

local function insideSchedule()
  if not scheduleEnabled then return false end
  local s, e = parseHHMM(scheduleStart), parseHHMM(scheduleEnd)
  if not s or not e or s == e then return false end
  local now = tonumber(noctalia.formatTime("%H")) * 60 + tonumber(noctalia.formatTime("%M"))
  if s < e then
    return now >= s and now < e
  end
  return now >= s or now < e -- window crosses midnight
end

function load()
  local saved = nil
  if statePath then
    local raw = noctalia.readFile(statePath)
    if raw then
      local ok, value = pcall(noctalia.json.decode, raw)
      if ok and type(value) == "table" then saved = value end
    end
  end

  local savedSince = 0
  if saved then
    stats = type(saved.stats) == "table" and saved.stats or {}
    untilMs = tonumber(saved.untilMs) or 0
    mode = saved.mode or "manual"
    lastScheduleDate = saved.lastScheduleDate or ""
    lastStatMs = tonumber(saved.lastStatMs) or 0
    blocked = saved.blocked == true
    savedSince = tonumber(saved.since) or 0
  end

  publish()
  fetchServices()
  checkStatus(true, savedSince)
end

noctalia.setUpdateInterval(2000)

function update()
  if busy then return end
  local now = noctalia.nowMs()

  -- Credit whole minutes before any path that turns the block off, so timer
  -- and schedule endings do not lose the last minute. A gap larger than two
  -- minutes means the machine slept or Noctalia was not running: do not count
  -- that wall-clock time as focus time.
  if blocked then
    if lastStatMs == 0 then lastStatMs = now end
    if now - lastStatMs > 120000 then lastStatMs = now end
    local mins = math.floor((now - lastStatMs) / 60000)
    if mins > 0 then
      local key = dayKey(0)
      stats[key] = (stats[key] or 0) + mins
      lastStatMs = lastStatMs + mins * 60000
      local cutoff = dayKey(-365)
      for k in pairs(stats) do
        if k < cutoff then stats[k] = nil end
      end
      persist()
      publish()
    end
  end

  -- timer expiry
  if blocked and untilMs > 0 and now >= untilMs then
    apply(false)
    return
  end

  -- daily schedule
  if scheduleEnabled then
    if insideSchedule() then
      local key = dayKey(0)
      if lastScheduleDate ~= key then
        lastScheduleDate = key
        persist()
        -- Auto-start once per day; a manual "off" during the window stays off.
        if not blocked then
          apply(true, { mode = "schedule" })
          return
        end
      end
    elseif blocked and mode == "schedule" then
      apply(false)
      return
    end
  elseif blocked and mode == "schedule" then
    -- The schedule was switched off while its block was active.
    apply(false)
    return
  end

  -- Reconcile with /etc/hosts every 30 s, so an external off/on or a helper
  -- repair is reflected in the UI without a restart.
  if not statusBusy and now - lastStatusCheck >= 60000 then
    checkStatus(false, 0)
  end

  -- enforcement
  if blocked then
    if closeApps and not appCheckBusy then
      appCheckBusy = true
      noctalia.processMatches(function(matched)
        appCheckBusy = false
        if matched then closeAppsNow() end
      end, "discord", "vesktop", "webcord", "armcord", "slack")
    end
    if closeWindows then closeSocialWindows() end

    -- keep the countdown fresh without re-rendering every 2 s
    local rem = untilMs > 0 and math.max(0, math.ceil((untilMs - now) / 60000)) or 0
    if rem ~= lastPublishRemaining then publish() end
  end
end

load()
