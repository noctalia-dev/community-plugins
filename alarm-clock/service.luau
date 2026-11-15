--!nonstrict
-- Alarm service. Owns scheduling, persistence, and alarm playback.
-- UI entries are thin clients connected through noctalia.state.

local PLUGIN_ID = "spont-427/alarm-clock"
local RINGING_PANEL_ID = PLUGIN_ID .. ":ringing"
local DATA_DIR = noctalia.pluginDataDir()
local DATA_FILE = type(DATA_DIR) == "string" and (DATA_DIR .. "/alarms.json") or nil
if DATA_FILE == nil then
  noctalia.log("Alarm: persistent data directory is unavailable; alarms will not survive restarts")
end
local activeSoundName = "alarm-tone-1"
local soundGeneration = 1
local activeSoundPath = nil
local externalSoundActive = false
local unavailablePlayerNotified = false
local PLAYER_PID_FILE = DATA_DIR ~= nil and (DATA_DIR .. "/audio-player-" .. tostring(noctalia.nowMs()) .. ".pid") or nil

local alarms = {}
local ringingId = nil
local nextBeepAt = 0
local soundReady = false
local soundLoading = false
local soundRetryAt = 0
local soundEnabled = noctalia.getConfig("sound_enabled") ~= false
local loaded = false

noctalia.setUpdateInterval(1000)

local function isValidTime(value)
  if type(value) ~= "string" then return false end
  local h, m = string.match(value, "^(%d%d):(%d%d)$")
  local hour = tonumber(h)
  local minute = tonumber(m)
  return hour ~= nil and minute ~= nil and hour >= 0 and hour <= 23 and minute >= 0 and minute <= 59
end

local function formatTime12(timeText)
  local hourText, minuteText = string.match(timeText or "", "^(%d%d):(%d%d)$")
  local hour = tonumber(hourText)
  local minute = tonumber(minuteText)
  if hour == nil or minute == nil then return timeText or "" end
  local suffix = hour >= 12 and "PM" or "AM"
  local displayHour = hour % 12
  if displayHour == 0 then displayHour = 12 end
  return string.format("%02d:%02d %s", displayHour, minute, suffix)
end

local function configuredSoundPath()
  local customPath = noctalia.getConfig("custom_sound")
  if type(customPath) == "string" and customPath ~= "" then
    return customPath
  end
  return "sounds/alarm.wav"
end

local function dateKey(timestamp)
  return os.date("%Y-%m-%d", timestamp)
end

-- Alarm inputs have minute precision. Comparing against seconds caused an
-- alarm entered during its displayed minute (e.g. 16:27:35 for 16:27) to be
-- incorrectly postponed until tomorrow.
local function minuteStart(timestamp)
  return timestamp - (timestamp % 60)
end

-- Luau's os.time(dateTable) interprets the supplied wall-clock fields as UTC,
-- while os.date("*t", timestamp) returns fields in the system's local timezone.
-- Passing local fields directly to os.time therefore shifts every alarm by the
-- local UTC offset (for example, +05:30 in Asia/Kolkata). Convert local wall
-- time to an epoch by subtracting the local offset at the candidate instant.
local function localUtcOffset(timestamp)
  local localParts = os.date("*t", timestamp)
  return os.time(localParts) - timestamp
end

local function buildTimestamp(timestamp, timeText, dayOffset)
  local hourText, minuteText = string.match(timeText, "^(%d%d):(%d%d)$")
  local date = os.date("*t", timestamp)
  local utcGuess = os.time({
    year = date.year,
    month = date.month,
    day = date.day + dayOffset,
    hour = tonumber(hourText),
    min = tonumber(minuteText),
    sec = 0,
  })

  -- Iterate so a date near a daylight-saving boundary uses the offset at the
  -- intended local time, not necessarily the offset at the initial UTC guess.
  local candidate = utcGuess
  for _ = 1, 3 do
    local adjusted = utcGuess - localUtcOffset(candidate)
    if adjusted == candidate then
      break
    end
    candidate = adjusted
  end
  return candidate
end

-- Weekdays use ISO numbering: Monday=1 ... Sunday=7.
local function cleanRepeatDays(days)
  local cleaned = {}
  local seen = {}
  if type(days) == "table" then
    for _, value in ipairs(days) do
      local day = tonumber(value)
      if day ~= nil and day >= 1 and day <= 7 and day % 1 == 0 and not seen[day] then
        seen[day] = true
        table.insert(cleaned, day)
      end
    end
  end
  table.sort(cleaned)
  return cleaned
end

local function legacyRepeatDays(mode)
  if mode == "daily" then return { 1, 2, 3, 4, 5, 6, 7 } end
  if mode == "weekdays" then return { 1, 2, 3, 4, 5 } end
  if mode == "weekends" then return { 6, 7 } end
  return {}
end

local function isOneTime(alarm)
  return type(alarm.repeatDays) ~= "table" or #alarm.repeatDays == 0
end

local function isAllowedDay(repeatDays, timestamp)
  if type(repeatDays) ~= "table" or #repeatDays == 0 then return false end
  local weekday = os.date("*t", timestamp).wday -- Sunday=1 ... Saturday=7
  local isoWeekday = weekday == 1 and 7 or (weekday - 1)
  for _, day in ipairs(repeatDays) do
    if day == isoWeekday then return true end
  end
  return false
end

local function firstFutureOccurrence(timeText, repeatDays, now)
  if type(repeatDays) ~= "table" or #repeatDays == 0 then
    local today = buildTimestamp(now, timeText, 0)
    if today >= minuteStart(now) then return today end
    return buildTimestamp(now, timeText, 1)
  end

  for offset = 0, 7 do
    local candidate = buildTimestamp(now, timeText, offset)
    if isAllowedDay(repeatDays, candidate) and candidate > now then
      return candidate
    end
  end
  return buildTimestamp(now, timeText, 1)
end

local function resetScheduleForEnable(alarm, now)
  alarm.snoozeUntil = nil
  alarm.lastFiredDate = nil

  if isOneTime(alarm) then
    alarm.onceAt = firstFutureOccurrence(alarm.time, {}, now)
    return
  end

  alarm.onceAt = nil
  local today = buildTimestamp(now, alarm.time, 0)
  if today < minuteStart(now) and isAllowedDay(alarm.repeatDays, today) then
    alarm.lastFiredDate = dateKey(today)
  end
end

local function nextTarget(alarm, now)
  if alarm.snoozeUntil ~= nil then
    return alarm.snoozeUntil
  end
  if isOneTime(alarm) then
    return alarm.onceAt or 0
  end

  for offset = 0, 7 do
    local candidate = buildTimestamp(now, alarm.time, offset)
    local key = dateKey(candidate)
    if isAllowedDay(alarm.repeatDays, candidate) and key ~= alarm.lastFiredDate then
      return candidate
    end
  end
  return buildTimestamp(now, alarm.time, 1)
end

local function findAlarm(id)
  for index, alarm in ipairs(alarms) do
    if alarm.id == id then return alarm, index end
  end
  return nil, nil
end

local function saveData()
  local payload = {
    alarms = alarms,
    ringingId = ringingId or "",
  }
  local ok, encoded = pcall(function()
    return noctalia.json.encode(payload)
  end)
  if not ok then
    noctalia.log("Alarm: failed to encode saved data: " .. tostring(encoded))
    return
  end
  if DATA_FILE ~= nil then
    local written, err = noctalia.writeFile(DATA_FILE, encoded)
    if not written then
      noctalia.log("Alarm: could not save data: " .. tostring(err))
    end
  end
end

local function publish()
  noctalia.state.set("alarm.alarms", alarms)
  noctalia.state.set("alarm.ringingId", ringingId or "")

  local now = os.time()
  local earliest = nil
  for _, alarm in ipairs(alarms) do
    if alarm.enabled then
      local target = nextTarget(alarm, now)
      if earliest == nil or target < earliest then earliest = target end
    end
  end

  local barText = ""
  if ringingId ~= nil then
    barText = "RING"
  elseif earliest ~= nil then
    barText = formatTime12(os.date("%H:%M", earliest))
  end
  noctalia.state.set("alarm.barText", barText)
  noctalia.state.set("alarm.barRinging", ringingId ~= nil)
end

local function loadData()
  local legacySnoozeMinutes = 5
  local contents = DATA_FILE ~= nil and noctalia.readFile(DATA_FILE) or nil
  if contents ~= nil then
    local ok, decoded = pcall(function()
      return noctalia.json.decode(contents)
    end)
    if ok and type(decoded) == "table" then
      if type(decoded.alarms) == "table" then alarms = decoded.alarms end
      if type(decoded.snoozeMinutes) == "number" then
        legacySnoozeMinutes = math.clamp(math.floor(decoded.snoozeMinutes), 1, 60)
      end
      if type(decoded.ringingId) == "string" and decoded.ringingId ~= "" then
        ringingId = decoded.ringingId
      end
    else
      noctalia.log("Alarm: saved data was invalid; starting with an empty alarm list")
    end
  end

  -- Discard malformed entries so a bad row cannot stop the scheduler.
  local clean = {}
  for _, alarm in ipairs(alarms) do
    if type(alarm) == "table"
      and type(alarm.id) == "string"
      and isValidTime(alarm.time)
      and type(alarm.enabled) == "boolean"
      and (type(alarm.repeatDays) == "table" or alarm.repeatMode == "once" or alarm.repeatMode == "daily" or alarm.repeatMode == "weekdays" or alarm.repeatMode == "weekends") then
      alarm.label = type(alarm.label) == "string" and string.sub(alarm.label, 1, 40) or ""
      if type(alarm.repeatDays) ~= "table" then
        alarm.repeatDays = legacyRepeatDays(alarm.repeatMode)
      else
        alarm.repeatDays = cleanRepeatDays(alarm.repeatDays)
      end
      alarm.repeatMode = #alarm.repeatDays == 0 and "once" or "custom"
      if type(alarm.snoozeMinutes) ~= "number" then
        alarm.snoozeMinutes = legacySnoozeMinutes
      else
        alarm.snoozeMinutes = math.clamp(math.floor(alarm.snoozeMinutes), 1, 60)
      end
      if type(alarm.onceAt) ~= "number" then alarm.onceAt = nil end
      if type(alarm.snoozeUntil) ~= "number" then alarm.snoozeUntil = nil end
      if type(alarm.lastFiredDate) ~= "string" then alarm.lastFiredDate = nil end

      -- Existing v0.1.0-v0.1.4 timestamps were created from local date fields
      -- with os.time(table), which Luau treats as UTC. Rebuild active schedules
      -- using the corrected local-time conversion so old alarms are repaired.
      if alarm.enabled and alarm.snoozeUntil == nil and ringingId ~= alarm.id then
        local now = os.time()
        if isOneTime(alarm) then
          alarm.onceAt = firstFutureOccurrence(alarm.time, {}, now)
        else
          alarm.onceAt = nil
          local today = buildTimestamp(now, alarm.time, 0)
          if today < minuteStart(now) and isAllowedDay(alarm.repeatDays, today) then
            alarm.lastFiredDate = dateKey(today)
          end
        end
      elseif not isOneTime(alarm) then
        alarm.onceAt = nil
      end
      table.insert(clean, alarm)
    end
  end
  alarms = clean
  if ringingId ~= nil and findAlarm(ringingId) == nil then ringingId = nil end
  loaded = true
  saveData()
end

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function isCustomSoundSelected()
  local selected = noctalia.getConfig("custom_sound")
  return type(selected) == "string" and selected ~= ""
end

local function stopExternalSound(onStopped)
  if PLAYER_PID_FILE == nil or not externalSoundActive then
    externalSoundActive = false
    if onStopped ~= nil then onStopped() end
    return
  end

  -- runAsync() is detached. Wait briefly for the player wrapper to write its
  -- PID, then verify a unique marker in /proc before sending SIGTERM. The
  -- marker check prevents killing an unrelated process if a PID was reused.
  local pidFile = shellQuote(PLAYER_PID_FILE)
  local command = "pid_file=" .. pidFile .. "; "
    .. "for attempt in 1 2 3 4 5 6 7 8 9 10; do "
    .. "if [ -s \"$pid_file\" ]; then "
    .. "pid=$(cat \"$pid_file\" 2>/dev/null); "
    .. "case \"$pid\" in ''|*[!0-9]*) pid='' ;; esac; "
    .. "if [ -n \"$pid\" ] && [ -r \"/proc/$pid/cmdline\" ] "
    .. "&& grep -aFq -- 'NoctaliaAlarmPlayer' \"/proc/$pid/cmdline\"; then "
    .. "kill -TERM \"$pid\" 2>/dev/null || true; fi; "
    .. "rm -f \"$pid_file\"; exit 0; fi; sleep 0.1; done; "
    .. "rm -f \"$pid_file\""
  externalSoundActive = false
  local accepted = noctalia.runAsync(command, function(result)
    if result.exitCode ~= 0 then
      noctalia.log("Alarm: audio stop command exited with " .. tostring(result.exitCode))
    end
    if onStopped ~= nil then onStopped() end
  end)
  if not accepted then
    noctalia.log("Alarm: could not launch audio stop command")
    if onStopped ~= nil then onStopped() end
  end
end

local function startExternalSound(path)
  if PLAYER_PID_FILE == nil then
    noctalia.notifyError("Alarm audio", "The plugin data directory is unavailable, so custom audio cannot be stopped safely.")
    return false
  end

  local resolvedPath = noctalia.expandPath(path)
  if type(resolvedPath) ~= "string" or resolvedPath == "" then
    resolvedPath = path
  end
  if not noctalia.fileExists(resolvedPath) then
    noctalia.notifyError("Alarm audio unavailable", "The selected sound file could not be found.")
    noctalia.log("Alarm: custom sound file does not exist: " .. tostring(resolvedPath))
    return false
  end

  local player = nil
  local playerCommand = nil
  if noctalia.commandExists("mpv") then
    player = "mpv"
    playerCommand = "mpv --no-video --really-quiet --force-window=no --loop-file=inf --title=NoctaliaAlarmPlayer -- " .. shellQuote(resolvedPath)
  elseif noctalia.commandExists("ffplay") then
    player = "ffplay"
    playerCommand = "ffplay -nodisp -autoexit -loop 0 -loglevel quiet -window_title NoctaliaAlarmPlayer -i " .. shellQuote(resolvedPath)
  end

  if playerCommand == nil then
    if not unavailablePlayerNotified then
      noctalia.notifyError("Custom alarm sound needs a player", "Install mpv or ffmpeg (ffplay) to play and stop long custom sounds reliably.")
      unavailablePlayerNotified = true
    end
    noctalia.log("Alarm: custom sound needs mpv or ffplay for interruptible playback")
    return false
  end

  -- The PID file is unique to this service runtime. Older service instances
  -- use their own file, so a late stop callback cannot kill a new playback.
  -- The shell writes its PID and execs the player, keeping the PID stable.
  local command = "printf '%s\\n' \"$$\" > " .. shellQuote(PLAYER_PID_FILE) .. "; exec " .. playerCommand
  local accepted = noctalia.runAsync(command)
  if accepted then
    externalSoundActive = true
    unavailablePlayerNotified = false
    noctalia.log("Alarm: custom sound started with " .. player)
    return true
  end

  noctalia.notifyError("Alarm audio", "Noctalia could not start " .. player .. ".")
  noctalia.log("Alarm: failed to launch custom sound player " .. player)
  return false
end

local function loadSound()
  -- Noctalia's v5.4.1 sound API only exposes load() and play(); it has no stop
  -- operation. Custom files therefore use a managed mpv/ffplay process so
  -- Snooze and Dismiss can terminate long audio immediately.
  if isCustomSoundSelected() then
    soundReady = false
    return
  end
  if not soundEnabled or soundReady or soundLoading then return end
  if os.time() < soundRetryAt then return end
  if activeSoundPath == nil then activeSoundPath = configuredSoundPath() end

  soundLoading = true
  local requestedName = activeSoundName
  local requestedPath = activeSoundPath
  local accepted = noctalia.sound.load(requestedName, requestedPath, function(ok, err)
    if requestedName ~= activeSoundName then return end
    soundLoading = false
    if ok then
      soundReady = true
      soundRetryAt = 0
      noctalia.log("Alarm: built-in sound loaded successfully from " .. tostring(requestedPath))
    else
      soundRetryAt = os.time() + 10
      local message = "Alarm built-in sound failed to load from " .. tostring(requestedPath) .. ": " .. tostring(err)
      noctalia.log(message)
      noctalia.notifyError("Alarm sound unavailable", tostring(err))
    end
  end)
  if not accepted then
    soundLoading = false
    soundRetryAt = os.time() + 10
    noctalia.log("Alarm: built-in sound load request was not accepted; retrying in 10 seconds")
  end
end

local function playSound()
  if not soundEnabled then return end
  if isCustomSoundSelected() then
    if externalSoundActive then return true end
    local started = startExternalSound(configuredSoundPath())
    if not started then soundRetryAt = os.time() + 10 end
    return started
  elseif soundReady then
    noctalia.sound.play(activeSoundName)
    return true
  else
    loadSound()
    return false
  end
end

local function stopSound(onStopped)
  -- There is no sound.stop() in the v5.4.1 host API. This explicitly kills
  -- the player process used for custom sounds; the bundled short tone is a
  -- one-shot Noctalia sound and naturally finishes on its own.
  stopExternalSound(onStopped)
end

local function ensureRingingPanelVisible()
  if noctalia.state.get("alarm.ringingPanelOpen") ~= true then
    -- Persistent ring panel is separate from the attached alarm editor.
    noctalia.state.set("alarm.ringingPanelOpen", true)
    noctalia.togglePanel(RINGING_PANEL_ID)
  end
end

local function closeRingingPanel()
  local wasOpen = noctalia.state.get("alarm.ringingPanelOpen") == true
  noctalia.state.set("alarm.ringingPanelOpen", false)
  if wasOpen then
    noctalia.togglePanel(RINGING_PANEL_ID)
  end
end

local function startRinging(alarm, now)
  local wasSnoozed = alarm.snoozeUntil ~= nil
  ringingId = alarm.id
  noctalia.log("Alarm: firing " .. tostring(alarm.label ~= "" and alarm.label or alarm.id)
    .. " at " .. os.date("%H:%M:%S", now))
  -- Keep the original recurrence day when a snooze crosses midnight.
  if not wasSnoozed then
    alarm.lastFiredDate = dateKey(now)
  end
  alarm.snoozeUntil = nil
  nextBeepAt = 0
  saveData()
  publish()
  noctalia.notify("Alarm", (alarm.label ~= "" and alarm.label or "Alarm") .. " • " .. formatTime12(alarm.time))
  ensureRingingPanelVisible()
  playSound()
  nextBeepAt = now + 2
end

local function finishRinging(snooze)
  if ringingId == nil then return end
  stopSound()
  local alarm = findAlarm(ringingId)
  if alarm ~= nil then
    if snooze then
      local minutes = math.clamp(math.floor(tonumber(alarm.snoozeMinutes) or 5), 1, 60)
      alarm.snoozeUntil = os.time() + (minutes * 60)
    else
      alarm.snoozeUntil = nil
      if isOneTime(alarm) then
        alarm.enabled = false
      end
    end
  end
  ringingId = nil
  nextBeepAt = 0
  closeRingingPanel()
  saveData()
  publish()
end

local function processCommand(request)
  if type(request) ~= "table" or type(request.action) ~= "string" then return end
  local now = os.time()
  noctalia.log("Alarm: command received: " .. request.action)

  if request.action == "add" then
    if not isValidTime(request.time) then
      noctalia.notifyError("Alarm", "Enter a valid local alarm time (HH:MM).")
      return
    end
    local repeatDays = cleanRepeatDays(request.repeatDays)
    local label = type(request.label) == "string" and string.sub(request.label, 1, 40) or ""
    local alarm = {
      id = tostring(noctalia.nowMs()) .. "-" .. tostring(#alarms + 1),
      label = label,
      time = request.time,
      repeatDays = repeatDays,
      repeatMode = #repeatDays == 0 and "once" or "custom",
      snoozeMinutes = 5,
      enabled = true,
    }
    if #repeatDays == 0 then
      alarm.onceAt = firstFutureOccurrence(alarm.time, {}, now)
    else
      local today = buildTimestamp(now, alarm.time, 0)
      if today < minuteStart(now) and isAllowedDay(repeatDays, today) then
        alarm.lastFiredDate = dateKey(today)
      end
    end
    table.insert(alarms, alarm)
    local scheduledAt = nextTarget(alarm, now)
    noctalia.log("Alarm: scheduled " .. alarm.time .. " for " .. os.date("%Y-%m-%d %H:%M:%S", scheduledAt))
    saveData()
    publish()
    noctalia.notify("Alarm added", formatTime12(alarm.time) .. (label ~= "" and " · " .. label or ""))

  elseif request.action == "edit" then
    if not isValidTime(request.time) then return end
    local alarm = findAlarm(request.id)
    if alarm ~= nil then
      local repeatDays = cleanRepeatDays(request.repeatDays)
      alarm.time = request.time
      alarm.label = type(request.label) == "string" and string.sub(request.label, 1, 40) or ""
      alarm.repeatDays = repeatDays
      alarm.repeatMode = #repeatDays == 0 and "once" or "custom"
      alarm.snoozeUntil = nil
      alarm.lastFiredDate = nil
      if #repeatDays == 0 then
        alarm.onceAt = firstFutureOccurrence(alarm.time, {}, now)
      else
        alarm.onceAt = nil
        local today = buildTimestamp(now, alarm.time, 0)
        if today < minuteStart(now) and isAllowedDay(repeatDays, today) then
          alarm.lastFiredDate = dateKey(today)
        end
      end
      saveData()
      publish()
      noctalia.notify("Alarm updated", formatTime12(alarm.time) .. (alarm.label ~= "" and " · " .. alarm.label or ""))
    end

  elseif request.action == "toggle" then
    local alarm = findAlarm(request.id)
    if alarm ~= nil then
      alarm.enabled = request.enabled == true
      if alarm.enabled then
        -- Re-arming an alarm must calculate a fresh occurrence. In particular,
        -- a dismissed one-time alarm must not retain yesterday's timestamp.
        resetScheduleForEnable(alarm, now)
      elseif ringingId == alarm.id then
        stopSound()
        ringingId = nil
        nextBeepAt = 0
        noctalia.state.set("alarm.ringingId", "")
        closeRingingPanel()
      end
      saveData()
      publish()
    end

  elseif request.action == "delete" then
    local _, index = findAlarm(request.id)
    if index ~= nil then
      table.remove(alarms, index)
      if ringingId == request.id then
        stopSound()
        ringingId = nil
        nextBeepAt = 0
        closeRingingPanel()
      end
      saveData()
      publish()
    end

  elseif request.action == "snooze" then
    finishRinging(true)

  elseif request.action == "dismiss" then
    finishRinging(false)

  elseif request.action == "set_alarm_snooze" then
    local alarm = findAlarm(request.id)
    local minutes = tonumber(request.minutes)
    if alarm ~= nil and minutes ~= nil then
      alarm.snoozeMinutes = math.clamp(math.floor(minutes), 1, 60)
      saveData()
      publish()
    end
  end
end

function onConfigChanged()
  soundEnabled = noctalia.getConfig("sound_enabled") ~= false
  local selectedPath = configuredSoundPath()
  local changed = selectedPath ~= activeSoundPath

  local function applySoundConfig()
    if changed then
      activeSoundPath = selectedPath
      soundGeneration += 1
      activeSoundName = "alarm-tone-" .. tostring(soundGeneration)
      soundReady = false
      soundLoading = false
      soundRetryAt = 0
      unavailablePlayerNotified = false
      noctalia.log("Alarm: sound selection changed to " .. tostring(activeSoundPath))
    end
    if not soundEnabled then
      return
    end
    loadSound()
    if ringingId ~= nil then playSound() end
  end

  if changed or not soundEnabled then
    stopSound(applySoundConfig)
  else
    applySoundConfig()
  end
end

activeSoundPath = configuredSoundPath()
loadData()
loadSound()
publish()
noctalia.state.set("alarm.schedulerTick", noctalia.nowMs())
noctalia.log("Alarm: local timezone offset at startup is " .. tostring(localUtcOffset(os.time())) .. " seconds east of UTC")
noctalia.log("Alarm: scheduler started; checking every second; enabled alarms=" .. tostring(#alarms))
noctalia.state.watch("alarm.command", processCommand)

-- Restore a ringing alarm after a service restart and show its persistent panel again.
if ringingId ~= nil then
  ensureRingingPanelVisible()
end

function onEnable()
  noctalia.log("Alarm: plugin enabled; scheduler active")
  publish()
  if ringingId ~= nil then ensureRingingPanelVisible() end
end

function update()
  if not loaded then return end
  local now = os.time()
  noctalia.state.set("alarm.schedulerTick", noctalia.nowMs())

  if soundEnabled and not soundReady and not soundLoading and now >= soundRetryAt then
    loadSound()
  end

  if ringingId ~= nil then
    if noctalia.state.get("alarm.ringingPanelOpen") ~= true then
      ensureRingingPanelVisible()
    end
    local alarm = findAlarm(ringingId)
    if alarm == nil or not alarm.enabled then
      stopSound()
      ringingId = nil
      nextBeepAt = 0
      closeRingingPanel()
      saveData()
      publish()
    elseif now >= nextBeepAt then
      if isCustomSoundSelected() then
        -- Custom audio is already looping in its managed player. Retry only
        -- when it has not started (including a restored ring after a reload).
        if not externalSoundActive and now >= soundRetryAt then
          playSound()
        end
      else
        -- The bundled tone is a short native one-shot, so replay periodically.
        playSound()
      end
      nextBeepAt = now + 2
    end
    return
  end

  local dueAlarm = nil
  local dueTime = nil
  for _, alarm in ipairs(alarms) do
    if alarm.enabled then
      local target = nextTarget(alarm, now)
      if target <= now and (dueTime == nil or target < dueTime) then
        dueAlarm = alarm
        dueTime = target
      end
    end
  end

  if dueAlarm ~= nil then
    startRinging(dueAlarm, now)
  end
end


function onExit(signal, reason)
  -- The custom player is detached from Noctalia, so explicitly stop it when
  -- the service/plugin runtime is unloaded, disabled, or shut down.
  stopSound()
  noctalia.log("Alarm Clock: service exiting (" .. tostring(reason) .. ")")
end
