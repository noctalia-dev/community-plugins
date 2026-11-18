--!nonstrict
local filtersLib = require("./lib/filters.luau")
local platforms = require("./lib/platforms.luau")
local state = require("./lib/state.luau")
local types = require("./lib/types.luau")
local rows = require("./views/rows.luau")

local contests: { types.Contest } = noctalia.state.get(state.CONTESTS) or {}
local loaded = noctalia.state.get(state.UPDATED) ~= nil
local filters: types.Filters = noctalia.state.get(state.FILTERS) or filtersLib.load()

local PADDING = 12
local LOGO = 24

local function contestRow(c: types.Contest, now: number, width: number): UiNode
  local logo = platforms.icons[c.src]
  local textWidth = width - LOGO - 8
  local fav = filters.favorites[c.url] == true
  return ui.row({
    key = c.url,
    width = width,
    gap = 8,
    align = "center",
    tooltip = c.url,
    onClick = function()
      noctalia.runAsync({ "xdg-open", c.url })
    end,
  }, {
    if logo
      then ui.image({ path = logo, width = LOGO, height = LOGO, fit = "contain", radius = 5 })
      else ui.glyph({ name = "trophy", size = 20 }),
    ui.column({ width = textWidth, gap = 1 }, {
      ui.label({
        text = (fav and "♥ " or "") .. c.name,
        fontSize = 13,
        fontWeight = "medium",
        maxLines = 1,
        maxWidth = textWidth,
      }),
      ui.label({
        text = rows.upcomingSubtitle(c, now),
        fontSize = 11,
        color = "on_surface_variant",
        maxLines = 1,
        maxWidth = textWidth,
      }),
    }),
  })
end

local function render()
  local width = math.max(240, math.min(640, tonumber(noctalia.getConfig("widget_width")) or 340))
  local limit = math.max(1, math.min(12, math.floor(tonumber(noctalia.getConfig("visible_items")) or 5)))
  local inner = width - PADDING * 2
  local now = os.time()

  local children: { UiNode } = {
    ui.label({
      text = noctalia.tr("desktop.title"),
      fontSize = 13,
      fontWeight = "bold",
      color = "primary",
      maxLines = 1,
    }),
  }
  local shown = 0
  for _, c in ipairs(contests) do
    if shown >= limit then
      break
    end
    if filtersLib.visible(c, filters, now, false) then
      shown += 1
      table.insert(children, contestRow(c, now, inner))
    end
  end
  if shown == 0 then
    table.insert(children, ui.label({
      text = noctalia.tr(loaded and "desktop.empty" or "desktop.loading"),
      fontSize = 11,
      color = "on_surface_variant",
    }))
  end

  desktopWidget.render(ui.column({ width = width, gap = 8, padding = PADDING, align = "stretch" }, children))
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

noctalia.setUpdateInterval(30 * 1000)
function update()
  render()
end

function onConfigChanged()
  render()
end

render()
