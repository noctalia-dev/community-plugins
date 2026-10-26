--!nonstrict
local filtersLib = require("./lib/filters.luau")
local format = require("./lib/format.luau")
local platforms = require("./lib/platforms.luau")
local state = require("./lib/state.luau")
local types = require("./lib/types.luau")

local contests: { types.Contest } = noctalia.state.get(state.CONTESTS) or {}
local loaded = noctalia.state.get(state.UPDATED) ~= nil
local filters: types.Filters = noctalia.state.get(state.FILTERS) or filtersLib.load()

local function render()
  local now = os.time()

  local upcoming: { types.Contest } = {}
  for _, c in ipairs(contests) do
    if filtersLib.visible(c, filters, now, false) then
      table.insert(upcoming, c)
    end
  end

  local nextC = upcoming[1]
  if not nextC then
    barWidget.setGlyph("trophy")
    barWidget.setText(loaded and noctalia.tr("widget.none") or "…")
    barWidget.setTooltip(noctalia.tr("widget.click"))
    return
  end

  local logo = platforms.icons[nextC.src]
  if logo then
    barWidget.setImage(logo, false, 16)
  else
    barWidget.setGlyph("trophy")
  end

  if nextC.start <= now then
    barWidget.setText(noctalia.tr("widget.live", { src = nextC.src }))
  else
    barWidget.setText(noctalia.tr("widget.next", { src = nextC.src, time = format.fmtDur(nextC.start - now) }))
  end

  local rows = {}
  for i = 1, math.min(#upcoming, 5) do
    local c = upcoming[i]
    local when = c.start <= now and noctalia.tr("widget.row_live")
      or noctalia.tr("widget.row_in", { time = format.fmtDur(c.start - now) })
    local heart = filters.favorites[c.url] and "♥ " or ""
    table.insert(rows, { key = c.src, value = `{heart}{c.name} ({when})` })
  end
  barWidget.setTooltip(rows)
end

noctalia.state.watch(state.CONTESTS, function(value: any)
  contests = value or {}
  loaded = true
  render()
end)

noctalia.state.watch(state.FILTERS, function(value: any)
  if type(value) == "table" then
    filters = value
    render()
  end
end)

function update()
  noctalia.setUpdateInterval(30 * 1000)
  render()
end

function onClick()
  noctalia.togglePanel("quantinium/competitive-programming-contest-tracker:panel")
end
