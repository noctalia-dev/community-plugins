--!nonstrict
-- Bar widget of the lyrics carousel.
--
-- Left click: open the settings panel. Right click: open the lyrics window.
-- Also accepts IPC for settings refresh/toggle without opening the panel.

local settings = require("./lib/settings.luau")
local launch = require("./lib/launch.luau")

local function currentGlyph()
  local value = settings.value("glyph")
  if type(value) == "string" and value ~= "" then
    return value
  end
  return "music"
end

local function tooltip()
  local text = "Lyrics Carousel"
  pcall(function()
    if noctalia and noctalia.tr then
      text = noctalia.tr("bar_tooltip") or text
    end
  end)
  if text == "Lyrics Carousel" then
    text = "Lyrics Carousel · left click: panel · right click: open window"
  end
  return text
end

local function render()
  barWidget.render(ui.row({ key = "lyrics-carousel", gap = 0, align = "center" }, {
    ui.glyph({ name = currentGlyph(), size = 14 }),
  }))
  barWidget.setTooltip(tooltip())
end

function update()
  render()
end

function onClick()
  noctalia.togglePanel("faminec/lyrics-carousel:panel")
end

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
    local key = settings.normalizeKey(payload)
    if type(payload) == "string" and settings.BOOL_KEYS[key] then
      settings.apply(key, nil)
    end
  elseif event == "refresh" then
    render()
  end
end

render()
