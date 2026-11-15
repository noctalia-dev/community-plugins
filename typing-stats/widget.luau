--!nonstrict
-- Typing Stats - bar widget.
--
-- A glyph for the current mode (today/total), a progress bar to the next
-- block, and the completed block count after it. Left click switches between
-- today's count and the all-time count; right click opens the heatmap panel.

local mode = "today"
local lastStats = nil

-- Keep the tooltip minimal: mode, today, total and progress to the next block.
-- Do not add app, action or right-click hints here.

local function render(stats)
  lastStats = stats
  local known = type(stats) == "table"
  if known and (stats.mode == "today" or stats.mode == "total") then
    mode = stats.mode
  end

  local todayChars = known and tonumber(stats.today_chars) or 0
  local totalChars = known and tonumber(stats.total_chars) or 0
  local blockSize = known and math.max(1, math.floor(tonumber(stats.block_size) or 100)) or 100

  local useTotal = mode == "total"
  local progress = known and tonumber(useTotal and stats.total_progress or stats.today_progress) or 0
  local blocks = known and tonumber(useTotal and stats.total_blocks or stats.today_blocks) or 0
  local chars = useTotal and totalChars or todayChars

  barWidget.render(ui.row({ align = "center", gap = 5 }, {
    ui.glyph({
      key = "mode",
      name = useTotal and "infinity" or "sun",
    }),
    ui.progress({
      key = "progress",
      width = 56,
      height = 6,
      progress = math.max(0, math.min(1, progress)),
      fill = "primary",
      track = "surface_container_highest",
      radius = 3,
    }),
    ui.label({
      key = "count",
      text = tostring(math.floor(blocks)),
      color = "primary",
      fontWeight = "bold",
      fontSize = 12,
    }),
  }))

  barWidget.setTooltip({
    {
      key = noctalia.tr("widget.mode.label"),
      value = noctalia.tr(useTotal and "widget.mode.total" or "widget.mode.today"),
    },
    { key = noctalia.tr("widget.today"), value = tostring(math.floor(todayChars)) },
    { key = noctalia.tr("widget.total"), value = tostring(math.floor(totalChars)) },
    {
      key = noctalia.tr("widget.next"),
      value = string.format("%d/%d", math.floor(chars) % blockSize, blockSize),
    },
  })
end

render(noctalia.state.get("stats"))

noctalia.state.watch("stats", render)

noctalia.state.watch("display_mode", function(value)
  if value ~= "today" and value ~= "total" then
    return
  end
  mode = value
  if lastStats ~= nil then
    render(lastStats)
  end
end)

function onClick()
  local next = mode == "total" and "today" or "total"
  mode = next
  if lastStats ~= nil then
    render(lastStats)
  end
  noctalia.state.set("display_mode", next)
end

function onRightClick()
  noctalia.togglePanel("goldesquemoon/typing-stats:calendar")
end
