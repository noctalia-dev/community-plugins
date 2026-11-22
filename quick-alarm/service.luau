--!nonstrict
local Time = require("./time.luau")

noctalia.setUpdateInterval(1000)

local alarms = {}
local nextId = 1
local ringing = false
local ringingLabel = ""
local ringingTime = ""
local ringingDue = 0
local ringingElapsed = 0
local missedGraceSecs = 120

-- Sound setup
local alarmReady = false
noctalia.sound.load("alarm", "sounds/alarm.wav", function(ok, err)
  if ok then
    alarmReady = true
  else
    noctalia.log("Quick Alarm sound failed to load: " .. tostring(err))
  end
end)

local function playAlarmSound()
  if alarmReady then
    noctalia.sound.play("alarm")
  end
end

-- Initialize state
noctalia.state.set("quick_alarm.status", "IDLE") -- IDLE, ACTIVE, RINGING
noctalia.state.set("quick_alarm.closest", "")
noctalia.state.set("quick_alarm.tooltip", "Quick Alarm")
noctalia.state.set("quick_alarm.ringing_label", "")
noctalia.state.set("quick_alarm.ringing_time", "")
noctalia.state.set("quick_alarm.ringing_due", "0")
noctalia.state.set("quick_alarm.alarms_json", "[]")
noctalia.state.set("quick_alarm.error_msg", "")
noctalia.state.set("quick_alarm.alert_open", "0")

local function syncState()
  table.sort(alarms, function(a, b)
    return a.target < b.target
  end)
  noctalia.state.set("quick_alarm.alarms_json", noctalia.json.encode(alarms))

  if #alarms > 0 then
    local nextAl = alarms[1]
    local now = os.time()
    local tipTime = Time.formatTime(nextAl.target, nextAl.showSeconds)
    local tip = nextAl.label ~= "" and (tipTime .. " " .. nextAl.label) or tipTime
    noctalia.state.set("quick_alarm.tooltip", tip)
    noctalia.state.set("quick_alarm.closest", Time.formatCountdown(nextAl.target, now))
    if not ringing then
      noctalia.state.set("quick_alarm.status", "ACTIVE")
    end
  else
    noctalia.state.set("quick_alarm.tooltip", "Quick Alarm")
    noctalia.state.set("quick_alarm.closest", "")
    if not ringing then
      noctalia.state.set("quick_alarm.status", "IDLE")
    end
  end
end

local function handleCommand(rawCmd)
  if not rawCmd or rawCmd == "" then return end

  if rawCmd:sub(1, 4) == "ADD:" then
    local payload = rawCmd:sub(5)
    local now = os.time()
    local parsed = Time.parseAlarmSpec(payload, now)
    if parsed.ok then
      local id = tostring(nextId)
      nextId = nextId + 1
      table.insert(alarms, {
        id = id,
        target = parsed.target,
        label = parsed.label or "",
        showSeconds = parsed.showSeconds and true or false,
      })
      noctalia.state.set("quick_alarm.error_msg", "")
      syncState()
    else
      noctalia.state.set("quick_alarm.error_msg", parsed.error or "Could not parse alarm time.")
    end

  elseif rawCmd:sub(1, 7) == "CANCEL:" then
    local targetId = rawCmd:sub(8)
    for i = #alarms, 1, -1 do
      if tostring(alarms[i].id) == targetId then
        table.remove(alarms, i)
        break
      end
    end
    syncState()

  elseif rawCmd == "CLEAR_ALL" then
    alarms = {}
    syncState()

  elseif rawCmd == "DISMISS_RING" then
    ringing = false
    if noctalia.state.get("quick_alarm.alert_open") == "1" then
      noctalia.togglePanel("rsmendes/quick-alarm:alert")
    end
    noctalia.state.set("quick_alarm.status", #alarms > 0 and "ACTIVE" or "IDLE")
    syncState()
  end
end

noctalia.state.watch("quick_alarm.cmd", function(rawCmd)
  if not rawCmd or rawCmd == "" then return end
  noctalia.state.set("quick_alarm.cmd", "")
  handleCommand(rawCmd)
end)

function onIpc(event, payload)
  if event == "add" and type(payload) == "string" and payload ~= "" then
    handleCommand("ADD:" .. payload)
  elseif event == "clear" then
    handleCommand("CLEAR_ALL")
  elseif event == "dismiss" then
    handleCommand("DISMISS_RING")
  end
end

function update()
  local now = os.time()

  -- Reconcile alarms (check due or missed)
  local firedAlarm = nil
  local changed = false
  for i = #alarms, 1, -1 do
    local al = alarms[i]
    if now >= al.target then
      changed = true
      table.remove(alarms, i)
      if (now - al.target) > missedGraceSecs then
        -- Missed alarm (e.g. after suspend)
        local dueText = Time.formatTime(al.target, al.showSeconds)
        local body = al.label ~= "" and (dueText .. " " .. al.label) or ("Alarm " .. dueText)
        noctalia.notify("Missed alarm", body)
      else
        firedAlarm = al
      end
    end
  end

  if firedAlarm then
    ringing = true
    ringingLabel = firedAlarm.label or ""
    ringingTime = Time.formatTime(firedAlarm.target, firedAlarm.showSeconds)
    ringingDue = firedAlarm.target
    ringingElapsed = 0

    noctalia.state.set("quick_alarm.ringing_label", ringingLabel)
    noctalia.state.set("quick_alarm.ringing_time", ringingTime)
    noctalia.state.set("quick_alarm.ringing_due", tostring(ringingDue))
    noctalia.state.set("quick_alarm.status", "RINGING")

    playAlarmSound()

    if noctalia.state.get("quick_alarm.alert_open") ~= "1" then
      noctalia.togglePanel("rsmendes/quick-alarm:alert")
    end
  end

  if changed then
    syncState()
  elseif #alarms > 0 then
    noctalia.state.set("quick_alarm.closest", Time.formatCountdown(alarms[1].target, now))
  end

  if ringing then
    ringingElapsed = ringingElapsed + 1
    if ringingElapsed % 3 == 0 and ringingElapsed < 30 then
      playAlarmSound()
    end
    if ringingElapsed >= 60 then
      ringing = false
      if noctalia.state.get("quick_alarm.alert_open") == "1" then
        noctalia.togglePanel("rsmendes/quick-alarm:alert")
      end
      noctalia.state.set("quick_alarm.status", #alarms > 0 and "ACTIVE" or "IDLE")
    end
  end
end
