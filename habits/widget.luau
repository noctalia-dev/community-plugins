--!nonstrict
-- Bar widget for Habits tracker with progressive circular fill.

local store = require("./store.luau")

local PANEL_ID = "mumenosman/habits:panel"

local function getRingIcon(percent)
  local rounded = math.clamp(math.round(percent / 10) * 10, 0, 100)
  return `icons/ring-{rounded}.svg`
end

local function render()
  local showCount = noctalia.getConfig("show_count")
  if showCount == nil then
    showCount = true
  end

  local today = store.today()
  local data = store.load()
  local summary = store.summary(data, today)

  local container = barWidget.isVertical() and ui.column or ui.row
  local percent = summary.percent
  local ringIcon = getRingIcon(percent)

  local isComplete = summary.total > 0 and summary.completed == summary.total

  local children = {
    ui.image({
      path = ringIcon,
      width = 16,
      height = 16,
      fit = "contain",
    }),
  }

  if showCount and summary.total > 0 then
    table.insert(children, ui.label({
      text = string.format("%d/%d", summary.completed, summary.total),
      fontSize = 11,
      fontWeight = "medium",
      color = isComplete and "primary" or "on_surface",
    }))
  end

  barWidget.render(container({ gap = 5, align = "center" }, children))

  -- Also set glyph as native fallback
  if summary.total == 0 or summary.completed == 0 then
    barWidget.setGlyph("circle")
    barWidget.setGlyphColor("on_surface_variant")
  elseif isComplete then
    barWidget.setGlyph("circle-check")
    barWidget.setGlyphColor("primary")
  else
    barWidget.setGlyph("circle-dot")
    barWidget.setGlyphColor("primary")
  end

  local tip = summary.total == 0
    and "Habits — No habits tracked"
    or string.format("Habits — %d of %d completed (%d%%)", summary.completed, summary.total, percent)
  barWidget.setTooltip(tip)
end

noctalia.state.watch("habits_updated", function()
  render()
end)

function update()
  noctalia.setUpdateInterval(30000)
  render()
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onConfigChanged()
  render()
end

render()
