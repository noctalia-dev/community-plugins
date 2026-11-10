--!nonstrict
-- Wallpaper Brightness bar widget

local i18n = require("./i18n.luau")

local brightness = tonumber(noctalia.state.get("brightness")) or tonumber(noctalia.getConfig("brightness")) or 100
local isBusy = (noctalia.state.get("busy") == "true")

local function render()
  local active = (brightness ~= 100)
  local iconColor = active and "primary" or "on_surface"

  local children = {
    ui.glyph({
      name = "sun",
      size = 16,
      color = iconColor,
    }),
  }

  if active or isBusy then
    table.insert(children, ui.label({
      text = tostring(brightness) .. "%",
      fontWeight = "bold",
      color = iconColor,
    }))
  end

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 6, align = "center" }, children))

  local tooltip = i18n.tr("entries.bar") .. ": " .. tostring(brightness) .. "%"
  if isBusy then
    tooltip = tooltip .. " (" .. i18n.tr("panel.applying") .. ")"
  end
  barWidget.setTooltip(tooltip)
end

function onClick()
  noctalia.togglePanel("rsmendes/wallpaper-brightness:panel")
end

function onRightClick()
  noctalia.openSettings()
end

function onScroll(delta)
  local d = tonumber(delta) or 0
  if d > 0 then
    noctalia.state.set("cmd", "STEP:5")
  elseif d < 0 then
    noctalia.state.set("cmd", "STEP:-5")
  end
end

noctalia.state.watch("brightness", function(val)
  local parsed = tonumber(val)
  if parsed and parsed ~= brightness then
    brightness = parsed
    render()
  end
end)

noctalia.state.watch("busy", function(val)
  local nextBusy = (val == "true")
  if nextBusy ~= isBusy then
    isBusy = nextBusy
    render()
  end
end)

function onConfigChanged()
  brightness = tonumber(noctalia.getConfig("brightness")) or brightness or 100
  render()
end

function update()
  render()
end

render()
