--!nonstrict
local filtersLib = require("./lib/filters.luau")
local state = require("./lib/state.luau")
local types = require("./lib/types.luau")
local filterBar = require("./views/filter_bar.luau")
local rows = require("./views/rows.luau")

local contests: { types.Contest } = noctalia.state.get(state.CONTESTS) or {}
local past: { types.Contest } = noctalia.state.get(state.PAST) or {}
local filters: types.Filters = filtersLib.load()
local isOpen = false
local refreshCount = 0

local render: () -> ()

local function openUrl(url: string)
  noctalia.runAsync({ "xdg-open", url })
  panel.close()
end

local function setFilters()
  filtersLib.save(filters)
  noctalia.state.set(state.FILTERS, filters)
  render()
end

local function toggleFavorite(url: string)
  if filters.favorites[url] then
    filters.favorites[url] = nil
  else
    filters.favorites[url] = true
  end
  local present: { [string]: boolean } = {}
  for _, c in ipairs(contests) do
    present[c.url] = true
  end
  if next(present) ~= nil then
    for u in pairs(filters.favorites) do
      if not present[u] then
        filters.favorites[u] = nil
      end
    end
  end
  setFilters()
end

local function toggleSaved(c: types.Contest)
  if filters.saved[c.url] then
    filters.saved[c.url] = nil
  else
    filters.saved[c.url] = { src = c.src, name = c.name, start = c.start, dur = c.dur, url = c.url }
  end
  setFilters()
end

local ctx: types.Ctx = {
  filters = filters,
  view = { tab = "upcoming", hoveredUrl = nil },
  rerender = function()
    render()
  end,
  openUrl = openUrl,
  setFilters = setFilters,
  toggleFavorite = toggleFavorite,
  toggleSaved = toggleSaved,
}

local function upcomingList(now: number): { types.Contest }
  local list: { types.Contest } = {}
  for _, c in ipairs(contests) do
    if filtersLib.visible(c, filters, now, true) then
      table.insert(list, c)
    end
  end
  return list
end

local function previousLists(): ({ types.Contest }, { types.Contest })
  local savedList: { types.Contest } = {}
  local recent: { types.Contest } = {}
  for _, c in pairs(filters.saved) do
    if filtersLib.visiblePast(c, filters) then
      table.insert(savedList, c)
    end
  end
  table.sort(savedList, function(a: types.Contest, b: types.Contest)
    return a.start > b.start
  end)
  for _, c in ipairs(past) do
    if filters.saved[c.url] == nil and filtersLib.visiblePast(c, filters) then
      table.insert(recent, c)
    end
  end
  return savedList, recent
end

local function upcomingRows(upcoming: { types.Contest }, now: number): { UiNode }
  local out: { UiNode } = {}
  for _, c in ipairs(upcoming) do
    table.insert(out, rows.upcoming(c, now, ctx))
  end
  if #out == 0 then
    table.insert(out, ui.label({ text = noctalia.tr("panel.empty_upcoming"), color = "on_surface_variant" }))
  end
  return out
end

local function previousRows(savedList: { types.Contest }, recent: { types.Contest }, now: number): { UiNode }
  local out: { UiNode } = {}
  if #savedList > 0 then
    table.insert(out, rows.sectionLabel(noctalia.tr("rows.saved_section")))
    for _, c in ipairs(savedList) do
      table.insert(out, rows.past(c, now, ctx))
    end
  end
  if #recent > 0 then
    if #savedList > 0 then
      table.insert(out, rows.sectionLabel(noctalia.tr("rows.recent_section")))
    end
    for _, c in ipairs(recent) do
      table.insert(out, rows.past(c, now, ctx))
    end
  end
  if #out == 0 then
    table.insert(out, ui.label({
      text = noctalia.tr(filters.savedOnly and "panel.empty_saved" or "panel.empty_previous"),
      color = "on_surface_variant",
    }))
  end
  return out
end

render = function()
  if not isOpen then
    return
  end
  local now = os.time()
  local upcoming = upcomingList(now)
  local savedList, recent = previousLists()

  local body: { UiNode }
  if ctx.view.tab == "upcoming" then
    body = upcomingRows(upcoming, now)
  else
    body = previousRows(savedList, recent, now)
  end

  panel.render(ui.column({ flexGrow = 1, gap = 12 }, {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.label({ text = noctalia.tr("panel.title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
      ui.button({ glyph = "refresh", variant = "ghost", tooltip = noctalia.tr("panel.refresh"), onClick = "onRefresh" }),
      ui.button({ glyph = "close", variant = "ghost", onClick = "onCloseClicked" }),
    }),
    filterBar.tabs(ctx, #upcoming, #savedList + #recent),
    filterBar.build(ctx),
    ui.scroll({ flexGrow = 1, gap = 10 }, body),
  }))
end

noctalia.state.watch(state.CONTESTS, function(value: any)
  contests = value or {}
  render()
end)

noctalia.state.watch(state.PAST, function(value: any)
  past = value or {}
  render()
end)

noctalia.state.set(state.FILTERS, filters)

function onOpen(_context: any)
  isOpen = true
  contests = noctalia.state.get(state.CONTESTS) or contests
  past = noctalia.state.get(state.PAST) or past
  render()
end

function onClose()
  isOpen = false
end

function onRefresh()
  refreshCount += 1
  noctalia.state.set(state.REFRESH, os.time() * 100 + (refreshCount % 100))
end

function onCloseClicked()
  panel.close()
end

function onIpc(event: string, payload: string?)
  if event == "tab" and (payload == "upcoming" or payload == "previous") then
    ctx.view.tab = payload
    render()
  end
end
