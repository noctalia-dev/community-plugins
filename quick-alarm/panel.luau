--!nonstrict
local Time = require("./time.luau")

panel.setWantsSecondTicks(true)

local inputValue = ""
local inputKey = 0
local errorMsg = ""
local status = noctalia.state.get("quick_alarm.status") or "IDLE"
local ringingLabel = noctalia.state.get("quick_alarm.ringing_label") or ""
local ringingTime = noctalia.state.get("quick_alarm.ringing_time") or ""
local alarms = {}

local function decodeAlarms(raw)
  if type(raw) ~= "string" or raw == "" then
    alarms = {}
    return
  end
  local ok, decoded = pcall(function()
    return noctalia.json.decode(raw)
  end)
  if ok and type(decoded) == "table" then
    alarms = decoded
  else
    alarms = {}
  end
end

decodeAlarms(noctalia.state.get("quick_alarm.alarms_json") or "[]")

local render

local function submitAlarm(specOverride)
  local text = specOverride or inputValue
  if type(text) ~= "string" then text = "" end
  text = text:match("^%s*(.-)%s*$") or ""
  if text == "" then return end

  local parsed = Time.parseAlarmSpec(text, os.time())
  if not parsed.ok then
    errorMsg = tostring(parsed.error or "Could not parse alarm time.")
    render()
    return
  end

  errorMsg = ""
  if not specOverride then
    inputValue = ""
    inputKey += 1
  end
  noctalia.state.set("quick_alarm.cmd", "ADD:" .. text)
  render()
end

local function presetBtn(label, spec)
  return ui.button({
    key = "preset_" .. spec,
    text = label,
    variant = "outline",
    onClick = function()
      submitAlarm(spec)
    end,
  })
end

render = function()
  local now = os.time()
  local rows = {}

  for _, al in ipairs(alarms) do
    local id = tostring(al.id or "")
    local target = tonumber(al.target) or now
    local showSecs = al.showSeconds == true
    local timeStr = Time.formatTime(target, showSecs)
    local countdownStr = Time.formatCountdown(target, now)
    local labelStr = tostring(al.label or "")

    table.insert(rows, ui.row({
      key = "alarm_item_" .. id,
      gap = 10,
      padding = { left = 12, right = 8, top = 8, bottom = 8 },
      fill = "surface_container/0.45",
      radius = 8,
      align = "center",
      justify = "space_between",
    }, {
      ui.label({
        key = "alarm_time_" .. id,
        text = timeStr,
        fontSize = 14,
        fontWeight = "bold",
        color = "on_surface",
      }),
      ui.label({
        key = "alarm_label_" .. id,
        text = labelStr,
        fontSize = 13,
        color = "on_surface_variant",
        flexGrow = 1,
        maxLines = 1,
      }),
      ui.label({
        key = "alarm_rem_" .. id,
        text = countdownStr,
        fontSize = 12,
        fontWeight = "bold",
        color = "primary",
      }),
      ui.button({
        key = "alarm_del_" .. id,
        glyph = "close",
        variant = "ghost",
        onClick = function()
          noctalia.state.set("quick_alarm.cmd", "CANCEL:" .. id)
        end,
      }),
    }))
  end

  local ringBannerTitle = ringingTime ~= "" and ("⏰ RINGING (" .. ringingTime .. ")") or "⏰ RINGING NOW"
  local ringBannerSub = ringingLabel ~= "" and ringingLabel or "Alarm triggered!"

  panel.render(ui.column({
    key = "panel_root",
    gap = 10,
    padding = 14,
    align = "stretch",
    justify = "start",
  }, {
    -- Header
    ui.row({
      key = "header_row",
      gap = 8,
      padding = 0,
      align = "center",
      justify = "space_between",
    }, {
      ui.row({
        key = "header_title_group",
        gap = 8,
        padding = 0,
        align = "center",
      }, {
        ui.glyph({ name = "bell", size = 18, color = "primary" }),
        ui.label({
          text = "Quick Alarm",
          fontSize = 16,
          fontWeight = "bold",
          color = "on_surface",
        }),
      }),
      ui.button({
        key = "clear_all_btn",
        text = "Clear all",
        variant = "ghost",
        visible = (#alarms > 1),
        onClick = "onClearAll",
      }),
    }),

    -- Ringing banner
    ui.row({
      key = "ringing_banner",
      gap = 10,
      padding = 12,
      fill = "error/0.2",
      radius = 8,
      align = "center",
      justify = "space_between",
      visible = (status == "RINGING"),
    }, {
      ui.column({
        key = "ringing_info",
        gap = 2,
        padding = 0,
        flexGrow = 1,
        align = "stretch",
      }, {
        ui.label({
          text = ringBannerTitle,
          fontSize = 12,
          fontWeight = "bold",
          color = "error",
        }),
        ui.label({
          text = ringBannerSub,
          fontSize = 14,
          fontWeight = "bold",
          color = "on_surface",
          maxLines = 1,
        }),
      }),
      ui.button({
        key = "dismiss_banner_btn",
        text = "Dismiss",
        variant = "destructive",
        onClick = "onDismissRing",
      }),
    }),

    -- Input row (exact Quick Alarm syntax)
    ui.row({
      key = "input_row",
      gap = 8,
      padding = 0,
      align = "center",
      justify = "space_between",
    }, {
      ui.input({
        key = "alarm_input_" .. tostring(inputKey),
        value = inputValue,
        placeholder = "e.g. 11:45 lunch, in 10m tea, 5s...",
        fontSize = 14,
        width = 285,
        flexGrow = 1,
        focus = true,
        onChange = "onInputChange",
        onSubmit = "onInputSubmit",
      }),
      ui.button({
        key = "add_btn",
        text = "Add",
        variant = "primary",
        onClick = "onAddClick",
      }),
    }),

    -- Validation error label
    ui.label({
      key = "error_label",
      text = errorMsg,
      fontSize = 12,
      color = "error",
      visible = (errorMsg ~= ""),
    }),

    -- Quick preset buttons
    ui.row({
      key = "presets_row",
      gap = 6,
      padding = 0,
      align = "center",
      justify = "start",
    }, {
      presetBtn("+5m", "5m"),
      presetBtn("+10m", "10m"),
      presetBtn("+15m", "15m"),
      presetBtn("+25m (Pomo)", "25m Pomodoro"),
      presetBtn("+1h", "1h"),
    }),

    -- Thin divider
    ui.box({
      key = "divider_line",
      height = 1,
      fill = "outline_variant/0.35",
    }),

    -- Queue title when alarms exist
    ui.label({
      key = "queue_header",
      text = "Queued alarms (" .. tostring(#alarms) .. ")",
      fontSize = 12,
      fontWeight = "bold",
      color = "on_surface_variant",
      visible = (#alarms > 0),
    }),

    -- Empty state (separate key so reconciler never reuses its padding/align on alarm list)
    ui.column({
      key = "empty_state_container",
      gap = 4,
      padding = { top = 10, bottom = 10, left = 8, right = 8 },
      align = "center",
      justify = "center",
      visible = (#alarms == 0),
    }, {
      ui.label({
        key = "empty_title",
        text = "No alarms queued",
        fontSize = 13,
        color = "on_surface_variant",
        textAlign = "center",
      }),
      ui.label({
        key = "empty_hint",
        text = "Formats: 11:45, 14:30 meeting, in 10m tea, 30s",
        fontSize = 11,
        color = "outline_variant",
        textAlign = "center",
      }),
    }),

    -- Active alarms list (distinct key and explicit padding = 0, align = "stretch")
    ui.column({
      key = "alarms_list_container",
      gap = 6,
      padding = 0,
      align = "stretch",
      justify = "start",
      visible = (#alarms > 0),
    }, rows),
  }))
end

function onInputChange(val)
  inputValue = val or ""
  if errorMsg ~= "" then
    errorMsg = ""
    render()
  end
end

function onInputSubmit(val)
  if type(val) == "string" then
    inputValue = val
  end
  submitAlarm(nil)
end

function onAddClick()
  submitAlarm(nil)
end

function onClearAll()
  noctalia.state.set("quick_alarm.cmd", "CLEAR_ALL")
end

function onDismissRing()
  noctalia.state.set("quick_alarm.cmd", "DISMISS_RING")
end

function onOpen(_ctx)
  status = noctalia.state.get("quick_alarm.status") or "IDLE"
  ringingLabel = noctalia.state.get("quick_alarm.ringing_label") or ""
  ringingTime = noctalia.state.get("quick_alarm.ringing_time") or ""
  decodeAlarms(noctalia.state.get("quick_alarm.alarms_json") or "[]")
  errorMsg = ""
  render()
end

function update()
  render()
end

noctalia.state.watch("quick_alarm.status", function(val)
  status = val or "IDLE"
  render()
end)

noctalia.state.watch("quick_alarm.ringing_label", function(val)
  ringingLabel = val or ""
  render()
end)

noctalia.state.watch("quick_alarm.ringing_time", function(val)
  ringingTime = val or ""
  render()
end)

noctalia.state.watch("quick_alarm.alarms_json", function(val)
  decodeAlarms(val or "[]")
  render()
end)

noctalia.state.watch("quick_alarm.error_msg", function(val)
  if type(val) == "string" and val ~= "" then
    errorMsg = val
    render()
  end
end)

render()
