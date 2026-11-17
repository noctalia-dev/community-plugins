local Layouts = require("./layouts.luau")

local layouts = {}
local activeSymbol = ""
local discovering = false
local polling = false
local lastAttempt = -math.huge
local nextRefresh = 0

local function render()
  local current = Layouts.find(layouts, activeSymbol)
  local showGlyph = noctalia.getConfig("show_glyph")
  local showText = noctalia.getConfig("show_text")
  local customColor = noctalia.getConfig("custom_color")
  if showGlyph == nil or showGlyph == true or showGlyph == "true" then
    barWidget.setGlyph(if current then Layouts.glyph(current) else "layout")
  else
    barWidget.setGlyph("")
  end
  if showText == true or showText == "true" then
    barWidget.setText(if current then Layouts.label(current) else
      if activeSymbol ~= "" then activeSymbol else noctalia.tr("layout_unavailable"))
  else
    barWidget.setText("")
  end
  if customColor and customColor ~= "" then
    barWidget.setColor(customColor)
    barWidget.setGlyphColor(customColor)
  end
end

local function refreshLayouts(force)
  local now = os.time()
  if discovering or now - lastAttempt < 5 or (not force and now < nextRefresh) then return end
  discovering = true
  lastAttempt = now
  Layouts.discover(function(result)
    discovering = false
    nextRefresh = os.time() + (if result then 30 else 5)
    if result then layouts = result end
    render()
  end)
end

function update()
  noctalia.setUpdateInterval(noctalia.getConfig("update_interval") or 1000)
  refreshLayouts(false)
  if polling then return end
  polling = true
  Layouts.query("all-monitors", function(data)
    polling = false
    activeSymbol = Layouts.active(data)
    render()
    if activeSymbol ~= "" and not Layouts.find(layouts, activeSymbol) then
      refreshLayouts(true)
    end
  end)
end

function onClick()
  noctalia.togglePanel("ezequiel/mango_layouts:panel")
end
