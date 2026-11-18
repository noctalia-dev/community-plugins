--!nonstrict

local status = noctalia.state.get("quick_alarm.status") or "IDLE"
local closest = noctalia.state.get("quick_alarm.closest") or ""
local tooltip = noctalia.state.get("quick_alarm.tooltip") or "Quick Alarm"

local function render()
  local iconColor = "on_surface"
  if status == "RINGING" then
    iconColor = "error"
  elseif status == "ACTIVE" then
    iconColor = "primary"
  end

  local children = {
    ui.glyph({
      name = status == "RINGING" and "bell-ringing" or "bell",
      size = 16,
      color = iconColor,
    }),
  }

  if status == "RINGING" then
    table.insert(children, ui.label({
      text = "Alarm!",
      fontWeight = "bold",
      color = "error",
    }))
  elseif status == "ACTIVE" and closest ~= "" then
    table.insert(children, ui.label({
      text = closest,
      fontWeight = "bold",
      color = "primary",
    }))
  end

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 6, align = "center" }, children))
  barWidget.setTooltip(tooltip ~= "" and tooltip or "No alarms")
end

noctalia.state.watch("quick_alarm.status", function(val)
  status = val or "IDLE"
  render()
end)

noctalia.state.watch("quick_alarm.closest", function(val)
  closest = val or ""
  render()
end)

noctalia.state.watch("quick_alarm.tooltip", function(val)
  tooltip = val or "Quick Alarm"
  render()
end)

function update()
  render()
end

function onClick()
  if status == "RINGING" then
    noctalia.state.set("quick_alarm.cmd", "DISMISS_RING")
    return
  end
  noctalia.togglePanel("rsmendes/quick-alarm:panel")
end

function onRightClick()
  noctalia.togglePanel("rsmendes/quick-alarm:panel")
end

render()
