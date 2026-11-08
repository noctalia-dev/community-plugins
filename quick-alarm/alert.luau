--!nonstrict
local Time = require("./time.luau")

panel.setWantsSecondTicks(true)

local ringingLabel = noctalia.state.get("quick_alarm.ringing_label") or ""
local ringingTime = noctalia.state.get("quick_alarm.ringing_time") or ""
local ringingDue = tonumber(noctalia.state.get("quick_alarm.ringing_due") or "0") or 0

local function dismiss()
  noctalia.state.set("quick_alarm.cmd", "DISMISS_RING")
end

local function snooze(mins)
  local label = ringingLabel ~= "" and ringingLabel or "Snooze"
  noctalia.state.set("quick_alarm.cmd", "DISMISS_RING")
  noctalia.state.set("quick_alarm.cmd", "ADD:" .. tostring(mins) .. "m " .. label)
end

local function render()
  local now = os.time()
  local displayTime = ringingTime ~= "" and ringingTime or Time.formatTime(now, false)
  local timeAgoStr = ringingDue > 0 and Time.formatTimeAgo(ringingDue, now) or "just now"

  panel.render(ui.column({
    key = "alert_dialog",
    flexGrow = 1,
    padding = 24,
    gap = 12,
    fill = "#09090be6",
    radius = 16,
    align = "center",
    justify = "center",
  }, {
    ui.glyph({
      key = "alert_bell",
      name = "bell-ringing",
      size = 52,
      color = "primary",
    }),
    ui.label({
      key = "alert_time",
      text = displayTime,
      fontSize = 42,
      fontWeight = "bold",
      color = "on_surface",
      textAlign = "center",
    }),
    ui.label({
      key = "alert_label",
      text = ringingLabel,
      fontSize = 20,
      fontWeight = "bold",
      color = "primary",
      textAlign = "center",
      maxLines = 2,
      visible = (ringingLabel ~= ""),
    }),
    ui.label({
      key = "alert_ago",
      text = timeAgoStr,
      fontSize = 14,
      color = "on_surface_variant",
      textAlign = "center",
    }),
    ui.row({
      key = "alert_actions",
      gap = 12,
      padding = { top = 8, bottom = 0, left = 0, right = 0 },
      align = "center",
      justify = "center",
    }, {
      ui.button({
        key = "snooze_5m",
        text = "+5 min",
        variant = "outline",
        onClick = function()
          snooze(5)
        end,
      }),
      ui.button({
        key = "dismiss_btn",
        text = "Close",
        variant = "primary",
        width = 140,
        onClick = "onDismiss",
      }),
      ui.button({
        key = "snooze_10m",
        text = "+10 min",
        variant = "outline",
        onClick = function()
          snooze(10)
        end,
      }),
    }),
  }))
end

function onDismiss()
  dismiss()
end

function onKey(chord, pressed)
  if pressed and (chord == "escape" or chord == "return" or chord == "space") then
    dismiss()
  end
end

function onOpen(_ctx)
  noctalia.state.set("quick_alarm.alert_open", "1")
  ringingLabel = noctalia.state.get("quick_alarm.ringing_label") or ""
  ringingTime = noctalia.state.get("quick_alarm.ringing_time") or ""
  ringingDue = tonumber(noctalia.state.get("quick_alarm.ringing_due") or "0") or 0
  render()
end

function onClose()
  noctalia.state.set("quick_alarm.alert_open", "0")
end

function update()
  render()
end

noctalia.state.watch("quick_alarm.ringing_label", function(val)
  ringingLabel = val or ""
  render()
end)

noctalia.state.watch("quick_alarm.ringing_time", function(val)
  ringingTime = val or ""
  render()
end)

noctalia.state.watch("quick_alarm.ringing_due", function(val)
  ringingDue = tonumber(val or "0") or 0
  render()
end)

render()
