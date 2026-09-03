--!nonstrict

local PANEL_ID = "raycursive/niri-displays:panel"
local snapshot = noctalia.state.get("display_snapshot") or {
  status = "loading",
  displays = {},
}

local function focusedDisplay()
  for _, display in ipairs(snapshot.displays) do
    if display.focused then
      return display
    end
  end
  return nil
end

local function resolutionText(display)
  if display.width == 0 then
    return "—"
  end
  return string.format("%d×%d", display.width, display.height)
end

local function render()
  local glyph = noctalia.getConfig("glyph")
  if type(glyph) ~= "string" or glyph == "" then
    glyph = "device-desktop"
  end

  local focused = focusedDisplay()
  local showDetails = noctalia.getConfig("show_resolution") ~= false
  local children = {
    ui.glyph({
      name = glyph,
      size = 16,
      color = snapshot.status == "error" and "error" or "on_surface",
    }),
  }

  if focused ~= nil and showDetails then
    table.insert(children, ui.label({ text = focused.port, fontWeight = "bold", color = "on_surface" }))
    table.insert(children, ui.label({
      text = resolutionText(focused),
      fontSize = 11,
      color = "on_surface_variant",
    }))
  elseif snapshot.status == "error" and showDetails then
    table.insert(children, ui.label({ text = "!", color = "error", fontWeight = "bold" }))
  elseif focused == nil and showDetails then
    table.insert(children, ui.label({ text = tostring(#snapshot.displays), color = "on_surface" }))
  end

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 5, align = "center", paddingH = 4, paddingV = 2 }, children))
end

noctalia.state.watch("display_snapshot", function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

render()

function update()
  noctalia.setUpdateInterval(5000)
  render()
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onConfigChanged()
  render()
end
