--!nonstrict
local filtersLib = require("../lib/filters.luau")
local platforms = require("../lib/platforms.luau")
local types = require("../lib/types.luau")

local M = {}

local function variant(on: boolean, whenOn: types.Variant, whenOff: types.Variant): types.Variant
  return if on then whenOn else whenOff
end

function M.tabs(ctx: types.Ctx, upcomingCount: number, previousCount: number): UiNode
  local function tabButton(id: types.Tab, label: string): UiNode
    return ui.button({
      text = label,
      variant = variant(ctx.view.tab == id, "primary", "outline"),
      controlSize = "sm",
      onClick = function()
        ctx.view.tab = id
        ctx.rerender()
      end,
    })
  end
  return ui.row({ gap = 6, align = "center" }, {
    tabButton("upcoming", noctalia.tr("tabs.upcoming", { count = upcomingCount })),
    tabButton("previous", noctalia.tr("tabs.previous", { count = previousCount })),
  })
end

local function allPlatformsOn(filters: types.Filters): boolean
  for _, p in ipairs(platforms.list) do
    if filters.platforms[p.id] == false then
      return false
    end
  end
  return true
end

local function platformChip(p: types.Platform, ctx: types.Ctx): UiNode
  local on = ctx.filters.platforms[p.id] ~= false
  return ui.row({
    key = "platform:" .. p.id,
    minWidth = 40,
    minHeight = 32,
    align = "center",
    justify = "center",
    radius = 10,
    fill = on and "primary/0.35" or "on_surface/0",
    border = on and "primary" or "outline_variant",
    borderWidth = 1,
    tooltip = p.name,
    onClick = function()
      ctx.filters.platforms[p.id] = not on
      ctx.setFilters()
    end,
  }, {
    ui.image({
      path = p.icon,
      width = 20,
      height = 20,
      fit = "contain",
      radius = 4,
      opacity = on and 1 or 0.4,
    }),
  })
end

local function chipsRow(ctx: types.Ctx): UiNode
  local filters = ctx.filters
  local chips: { UiNode } = {}
  for _, p in ipairs(platforms.list) do
    table.insert(chips, platformChip(p, ctx))
  end
  table.insert(chips, ui.button({
    text = noctalia.tr("filters.all"),
    variant = variant(allPlatformsOn(filters), "secondary", "ghost"),
    controlSize = "sm",
    tooltip = noctalia.tr("filters.all_tooltip"),
    onClick = function()
      for _, p in ipairs(platforms.list) do
        filters.platforms[p.id] = true
      end
      ctx.setFilters()
    end,
  }))

  if ctx.view.tab == "upcoming" then
    table.insert(chips, ui.button({
      glyph = filters.favoritesOnly and "heart-filled" or "heart",
      variant = variant(filters.favoritesOnly, "primary", "outline"),
      controlSize = "sm",
      tooltip = noctalia.tr("filters.favorites_tooltip"),
      onClick = function()
        filters.favoritesOnly = not filters.favoritesOnly
        ctx.setFilters()
      end,
    }))
  else
    table.insert(chips, ui.button({
      glyph = filters.savedOnly and "bookmark-filled" or "bookmark",
      variant = variant(filters.savedOnly, "primary", "outline"),
      controlSize = "sm",
      tooltip = noctalia.tr("filters.saved_tooltip"),
      onClick = function()
        filters.savedOnly = not filters.savedOnly
        ctx.setFilters()
      end,
    }))
  end
  return ui.row({ gap = 6, align = "center" }, chips)
end

local function rangeRow(ctx: types.Ctx): UiNode
  local items: { UiNode } = {
    ui.label({ text = noctalia.tr("filters.starts_within"), color = "on_surface_variant", fontSize = 12 }),
  }
  for _, r in ipairs(filtersLib.RANGES) do
    table.insert(items, ui.button({
      text = noctalia.tr(r.labelKey),
      variant = variant(ctx.filters.range == r.id, "primary", "outline"),
      controlSize = "sm",
      onClick = function()
        ctx.filters.range = r.id
        ctx.setFilters()
      end,
    }))
  end
  return ui.row({ gap = 6, align = "center" }, items)
end

function M.build(ctx: types.Ctx): UiNode
  if ctx.view.tab == "upcoming" then
    return ui.column({ gap = 6 }, { chipsRow(ctx), rangeRow(ctx) })
  end
  return ui.column({ gap = 6 }, { chipsRow(ctx) })
end

return M
