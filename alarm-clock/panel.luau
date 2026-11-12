--!nonstrict
-- Alarm panel. Compact editor on the left, alarm list on the right.
-- The list has its own flex-growing scroll region so multiple alarms remain
-- visible without pushing the editor beyond the attached panel bounds.

local alarms = {}
local inputTime = "07:00 AM"
local inputLabel = ""
local selectedDays = {}
local errorText = ""
local editingId = ""
local schedulerActive = false
local inputKey = 0
local customSoundPath = ""

local SNOOZE_OPTIONS = { 5, 10, 15, 20, 30, 45, 60 }
local SNOOZE_LABELS = { "5 min", "10 min", "15 min", "20 min", "30 min", "45 min", "60 min" }
local DAY_LABELS = { "MO", "TU", "WE", "TH", "FR", "SA", "SU" }

local function snoozeIndex(minutes)
  for index, value in ipairs(SNOOZE_OPTIONS) do
    if value == minutes then return index - 1 end
  end
  return 0
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

local function parseTime12(value)
  if type(value) ~= "string" then return nil end
  local normalized = string.upper(value)
  local hourText, minuteText, suffix = string.match(normalized, "^%s*(%d%d?):(%d%d)%s*([AP]M)%s*$")
  local hour = tonumber(hourText)
  local minute = tonumber(minuteText)
  if hour == nil or minute == nil or hour < 1 or hour > 12 or minute > 59 then
    return nil
  end
  if suffix == "AM" then
    if hour == 12 then hour = 0 end
  elseif suffix == "PM" then
    if hour < 12 then hour = hour + 12 end
  else
    return nil
  end
  return string.format("%02d:%02d", hour, minute)
end

local function normalizeDays(days)
  local result = {}
  if type(days) == "table" then
    for _, value in ipairs(days) do
      local day = tonumber(value)
      if day ~= nil and day >= 1 and day <= 7 and day % 1 == 0 then
        result[day] = true
      end
    end
  end
  return result
end

local function daysToArray()
  local result = {}
  for day = 1, 7 do
    if selectedDays[day] then table.insert(result, day) end
  end
  return result
end

local function daySummary(days)
  local parts = {}
  for day = 1, 7 do
    if type(days) == "table" and table.find(days, day) ~= nil then
      table.insert(parts, DAY_LABELS[day])
    end
  end
  return #parts == 0 and "Once" or table.concat(parts, " · ")
end

local function alarmDaySummary(alarm)
  if type(alarm.repeatDays) == "table" then
    return daySummary(alarm.repeatDays)
  end
  if alarm.repeatMode == "daily" then return "MO · TU · WE · TH · FR · SA · SU" end
  if alarm.repeatMode == "weekdays" then return "MO · TU · WE · TH · FR" end
  if alarm.repeatMode == "weekends" then return "SA · SU" end
  return "Once"
end

local function sendCommand(action, extra)
  local request = extra or {}
  request.action = action
  request.nonce = tostring(noctalia.nowMs())
  noctalia.state.set("alarm.command", request)
end

local function resetEditor()
  editingId = ""
  inputTime = "07:00 AM"
  inputLabel = ""
  selectedDays = {}
  errorText = ""
  inputKey = inputKey + 1
end

local function renderNormal()
  local alarmRows = {}

  for _, alarm in ipairs(alarms) do
    local id = alarm.id
    local title = alarm.label ~= "" and alarm.label or "Alarm"
    local subtitle = alarmDaySummary(alarm)
    if alarm.snoozeUntil ~= nil then subtitle = "Snoozed" end
    local selectedSnooze = snoozeIndex(tonumber(alarm.snoozeMinutes) or 5)

    table.insert(alarmRows, ui.row({
      key = id,
      gap = 6,
      align = "center",
      padding = 7,
      radius = 8,
      fill = "surface_variant/0.25",
    }, {
      ui.toggle({
        checked = alarm.enabled,
        onChange = function(value)
          sendCommand("toggle", { id = id, enabled = value == "true" })
        end,
      }),
      ui.column({ gap = 1, flexGrow = 1 }, {
        ui.label({ text = formatTime12(alarm.time), fontWeight = "bold", fontSize = 14 }),
        ui.label({ text = title .. " · " .. subtitle, color = "on_surface_variant", fontSize = 10, maxLines = 1 }),
      }),
      ui.select({
        options = SNOOZE_LABELS,
        selectedIndex = selectedSnooze,
        controlSize = "sm",
        width = 88,
        onChange = function(index)
          local selected = (tonumber(index) or 0) + 1
          local minutes = SNOOZE_OPTIONS[selected]
          if minutes ~= nil then
            sendCommand("set_alarm_snooze", { id = id, minutes = minutes })
          end
        end,
      }),
      ui.button({
        glyph = "pencil",
        variant = "ghost",
        controlSize = "sm",
        tooltip = "Edit alarm",
        onClick = function()
          editingId = id
          inputTime = formatTime12(alarm.time)
          inputLabel = alarm.label or ""
          selectedDays = normalizeDays(alarm.repeatDays)
          if type(alarm.repeatDays) ~= "table" or #alarm.repeatDays == 0 then
            if alarm.repeatMode == "daily" then selectedDays = normalizeDays({1,2,3,4,5,6,7}) end
            if alarm.repeatMode == "weekdays" then selectedDays = normalizeDays({1,2,3,4,5}) end
            if alarm.repeatMode == "weekends" then selectedDays = normalizeDays({6,7}) end
          end
          errorText = ""
          inputKey = inputKey + 1
          renderNormal()
        end,
      }),
      ui.button({
        glyph = "trash-2",
        variant = "ghost",
        controlSize = "sm",
        tooltip = "Delete alarm",
        onClick = function() sendCommand("delete", { id = id }) end,
      }),
    }))
  end

  if #alarmRows == 0 then
    table.insert(alarmRows, ui.label({
      text = "No alarms yet. Create your first one on the left.",
      color = "on_surface_variant",
      fontSize = 12,
    }))
  end

  local recurrenceButtons = {}
  for day = 1, 7 do
    local dayIndex = day
    local selected = selectedDays[dayIndex] == true
    table.insert(recurrenceButtons, ui.column({
      width = 32,
      height = 32,
      radius = 16,
      fill = selected and "primary" or "surface_variant/0.22",
      border = selected and "primary" or "outline_variant",
      borderWidth = 1,
      align = "center",
      justify = "center",
      onClick = function()
        selectedDays[dayIndex] = not selectedDays[dayIndex]
        errorText = ""
        renderNormal()
      end,
    }, {
      ui.label({
        text = DAY_LABELS[dayIndex],
        fontSize = 9,
        fontWeight = "bold",
        color = selected and "on_primary" or "on_surface",
        textAlign = "center",
      }),
    }))
  end

  local soundDescription = customSoundPath ~= ""
    and "Custom sound selected"
    or "Built-in alarm sound"

  local editorAction = editingId ~= "" and "Save" or "Add"
  local editorGlyph = editingId ~= "" and "check" or "plus"
  local editorActions = {
    ui.button({
      text = editorAction,
      glyph = editorGlyph,
      variant = "primary",
      controlSize = "sm",
      onClick = "onAddAlarm",
    }),
  }
  if editingId ~= "" then
    table.insert(editorActions, ui.button({
      glyph = "x",
      variant = "ghost",
      controlSize = "sm",
      tooltip = "Cancel editing",
      onClick = function()
        resetEditor()
        renderNormal()
      end,
    }))
  end

  local editorContents = {
    ui.row({ align = "center", justify = "space_between", gap = 6 }, {
      ui.column({ gap = 1, flexGrow = 1 }, {
        ui.label({ text = editingId ~= "" and "Edit alarm" or "New alarm", fontWeight = "bold" }),
        ui.label({ text = "Set time and repeat", fontSize = 10, color = "on_surface_variant" }),
      }),
      ui.row({ gap = 4 }, editorActions),
    }),
    ui.column({ gap = 4 }, {
      ui.label({ text = "Time · 12-hour", fontSize = 11, color = "on_surface_variant" }),
      ui.input({ key = "time-" .. tostring(inputKey), value = inputTime, placeholder = "07:30 AM", onChange = "onTimeChange" }),
    }),
    ui.column({ gap = 4 }, {
      ui.label({ text = "Label · optional", fontSize = 11, color = "on_surface_variant" }),
      ui.input({ key = "label-" .. tostring(inputKey), value = inputLabel, placeholder = "Wake up", onChange = "onLabelChange" }),
    }),
    ui.column({ gap = 6 }, {
      ui.label({ text = "Repeat · choose days", fontSize = 11, color = "on_surface_variant" }),
      ui.row({ gap = 4, justify = "space_between" }, recurrenceButtons),
      ui.label({ text = "No days selected = once", fontSize = 10, color = "on_surface_variant" }),
    }),
  }
  if errorText ~= "" then
    table.insert(editorContents, ui.label({ text = errorText, color = "error", fontSize = 11, maxLines = 2 }))
  end

  panel.render(ui.column({ flexGrow = 1, gap = 8, padding = 12 }, {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.label({ text = "Alarm", fontSize = 18, fontWeight = "bold", color = "primary" }),
        ui.label({ text = "Your alarms, quietly on time", fontSize = 11, color = "on_surface_variant" }),
      }),
      ui.button({ glyph = "x", variant = "ghost", tooltip = "Close", onClick = function() panel.close() end }),
    }),
    ui.row({ gap = 5, align = "center" }, {
      ui.glyph({ name = "music", size = 12, color = "on_surface_variant" }),
      ui.label({ text = soundDescription, fontSize = 10, color = "on_surface_variant" }),
      ui.spacer({ flexGrow = 1 }),
      ui.button({ text = "Sound settings", variant = "ghost", controlSize = "sm", onClick = function() noctalia.openSettings() end }),
    }),
    ui.separator({ thickness = 1 }),

    -- Two-column layout: a compact editor at left and a tall scrollable list at right.
    ui.row({ flexGrow = 1, gap = 12, align = "stretch" }, {
      ui.column({ width = 278, gap = 10, padding = 10, radius = 10, fill = "surface_variant/0.16" }, editorContents),

      ui.column({ flexGrow = 1, gap = 8 }, {
        ui.row({ align = "center", justify = "space_between" }, {
          ui.column({ gap = 2, flexGrow = 1 }, {
            ui.label({ text = "Your alarms", fontWeight = "bold", fontSize = 15 }),
            ui.label({
              text = schedulerActive and "Scheduler active" or "Scheduler not responding",
              color = schedulerActive and "on_surface_variant" or "error",
              fontSize = 10,
            }),
          }),
          ui.label({ text = tostring(#alarms), color = "on_surface_variant", fontSize = 11 }),
        }),
        ui.scroll({ flexGrow = 1, gap = 6 }, alarmRows),
      }),
    }),
  }))
end

local function render()
  renderNormal()
end

function onOpen(_context)
  alarms = noctalia.state.get("alarm.alarms") or {}
  local heartbeat = tonumber(noctalia.state.get("alarm.schedulerTick")) or 0
  schedulerActive = heartbeat > 0 and (noctalia.nowMs() - heartbeat) < 3500
  customSoundPath = noctalia.getConfig("custom_sound") or ""
  inputKey = inputKey + 1
  render()
end

function onTimeChange(value)
  inputTime = value
  errorText = ""
end

function onLabelChange(value)
  inputLabel = value
end

function onAddAlarm()
  local internalTime = parseTime12(inputTime)
  if internalTime == nil then
    errorText = "Use 12-hour time, for example 7:30 PM."
    renderNormal()
    return
  end
  sendCommand(editingId ~= "" and "edit" or "add", {
    id = editingId,
    time = internalTime,
    label = inputLabel,
    repeatDays = daysToArray(),
  })
  resetEditor()
  renderNormal()
end

noctalia.state.watch("alarm.alarms", function(value)
  if type(value) == "table" then alarms = value end
  if editingId ~= "" then
    local stillExists = false
    for _, alarm in ipairs(alarms) do
      if alarm.id == editingId then stillExists = true break end
    end
    if not stillExists then resetEditor() end
  end
  render()
end)

noctalia.state.watch("alarm.schedulerTick", function(value)
  local heartbeat = tonumber(value) or 0
  schedulerActive = heartbeat > 0 and (noctalia.nowMs() - heartbeat) < 3500
  render()
end)
