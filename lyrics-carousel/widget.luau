--!nonstrict
-- Bar widget of the lyrics carousel.
--
-- Left click opens the panel; right click opens the lyrics window directly.
-- It also accepts IPC to change settings without opening the panel (useful
-- for keyboard shortcuts):
--   noctalia msg plugin faminec/lyrics-carousel:widget all set visible_above 4 int
--   noctalia msg plugin faminec/lyrics-carousel:widget all toggle karaoke

local settings = require("./lib/settings.luau")
local launch = require("./lib/launch.luau")

-- The glyph is read from the overrides layer and not only from the
-- configuration: the panel writes there and flushes it when it closes, so
-- if the widget only looked at the configuration, the bar icon would not
-- change until the panel was closed.
local function currentGlyph()
  local value = settings.value("glyph")
  if type(value) == "string" and value ~= "" then
    return value
  end
  return "music"
end

local glyph = currentGlyph()

local function render()
  barWidget.setGlyph(glyph)
  barWidget.setTooltip(noctalia.tr("tooltip"))
end

function update()
  glyph = currentGlyph()
  render()
end

function onClick()
  noctalia.togglePanel("faminec/lyrics-carousel:panel")
end

-- Right click opens the window without going through the panel.
function onRightClick()
  launch.launch()
end

function onConfigChanged()
  render()
end

function onIpc(event, payload)
  if event == "launch" then
    launch.launch()
  elseif event == "set" then
    local key, value = settings.parse(payload)
    if key ~= nil then
      settings.apply(key, value)
    end
  elseif event == "toggle" then
    -- Only toggles are toggled: toggling a number makes no sense.
    if type(payload) == "string" and settings.BOOL_KEYS[payload] then
      settings.apply(payload, nil)
    end
  elseif event == "refresh" then
    render()
  end
end

render()
