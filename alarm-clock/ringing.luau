--!nonstrict
-- Small persistent alarm surface. The service opens it when an alarm fires.
-- It is deliberately separate from the attached editor panel: persistent
-- Noctalia panels are floating and do not support ui.select dropdowns.

local alarms = {}
local ringingId = ""

local function findRingingAlarm()
  for _, alarm in ipairs(alarms) do
    if alarm.id == ringingId then return alarm end
  end
  return nil
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

local DAY_LABELS = { "MO", "TU", "WE", "TH", "FR", "SA", "SU" }
local function repeatText(alarm)
  local labels = {}
  if type(alarm.repeatDays) == "table" then
    for day = 1, 7 do
      for _, selected in ipairs(alarm.repeatDays) do
        if selected == day then table.insert(labels, DAY_LABELS[day]) end
      end
    end
  elseif alarm.repeatMode == "daily" then
    return "Every day"
  elseif alarm.repeatMode == "weekdays" then
    return "Weekdays"
  elseif alarm.repeatMode == "weekends" then
    return "Weekends"
  end
  return #labels == 0 and "One-time alarm" or table.concat(labels, " · ")
end

local function sendCommand(action)
  noctalia.state.set("alarm.command", {
    action = action,
    nonce = tostring(noctalia.nowMs()),
  })
end

local function rootPanelProps(props)
  if noctalia.getConfig("opaque_ringer") == true then
    props.fill = "surface"
  end
  return props
end

local function render()
  local alarm = findRingingAlarm()
  if alarm == nil then
    panel.render(ui.column(rootPanelProps({ flexGrow = 1, gap = 8, padding = 14, align = "center" }), {
      ui.label({ text = "Alarm", fontWeight = "bold", color = "primary" }),
      ui.label({ text = "No active alarm" , color = "on_surface_variant" }),
      ui.button({ text = "Close", variant = "outline", onClick = function() panel.close() end }),
    }))
    return
  end

  local title = type(alarm.label) == "string" and alarm.label ~= "" and alarm.label or "Alarm"
  local snoozeMinutes = math.clamp(math.floor(tonumber(alarm.snoozeMinutes) or 5), 1, 60)
  panel.render(ui.column(rootPanelProps({ flexGrow = 1, gap = 7, padding = 12, align = "center", justify = "center" }), {
    ui.glyph({ name = "bell", size = 25, color = "error" }),
    ui.label({ text = "It's time", fontSize = 16, fontWeight = "bold", color = "primary" }),
    ui.label({ text = title, fontSize = 14, fontWeight = "bold" }),
    ui.label({ text = formatTime12(alarm.time), fontSize = 27, fontWeight = "bold", color = "primary" }),
    ui.label({ text = repeatText(alarm), fontSize = 11, color = "on_surface_variant" }),
    ui.row({ gap = 8, justify = "center" }, {
      ui.button({
        text = "Snooze · " .. tostring(snoozeMinutes) .. " min",
        glyph = "bell",
        variant = "secondary",
        controlSize = "sm",
        onClick = function() sendCommand("snooze") end,
      }),
      ui.button({
        text = "Dismiss",
        glyph = "check",
        variant = "primary",
        controlSize = "sm",
        onClick = function() sendCommand("dismiss") end,
      }),
    }),
  }))
end

function onOpen(_context)
  noctalia.state.set("alarm.ringingPanelOpen", true)
  alarms = noctalia.state.get("alarm.alarms") or {}
  ringingId = noctalia.state.get("alarm.ringingId") or ""
  render()
end

function onClose()
  noctalia.state.set("alarm.ringingPanelOpen", false)
end

noctalia.state.watch("alarm.alarms", function(value)
  if type(value) == "table" then alarms = value end
  render()
end)

noctalia.state.watch("alarm.ringingId", function(value)
  ringingId = type(value) == "string" and value or ""
  render()
end)
