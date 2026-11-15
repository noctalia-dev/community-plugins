--!nonstrict
-- Wallpaper Brightness Control Center shortcut

local i18n = require("./i18n.luau")

local brightness = tonumber(noctalia.state.get("brightness")) or tonumber(noctalia.getConfig("brightness")) or 100

local function refresh()
  shortcut.setIcon("sun")
  shortcut.setLabel(i18n.tr("entries.shortcut") .. " (" .. tostring(brightness) .. "%)")
  shortcut.setActive(brightness ~= 100)
end

function onClick()
  noctalia.togglePanel("rsmendes/wallpaper-brightness:panel")
end

noctalia.state.watch("brightness", function(val)
  local parsed = tonumber(val)
  if parsed and parsed ~= brightness then
    brightness = parsed
    refresh()
  end
end)

function onConfigChanged()
  brightness = tonumber(noctalia.getConfig("brightness")) or brightness or 100
  refresh()
end

function update()
  refresh()
end

refresh()
