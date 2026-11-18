--!nonstrict
local format = require("../lib/format.luau")
local platforms = require("../lib/platforms.luau")
local types = require("../lib/types.luau")

local M = {}

local function logoOf(c: types.Contest): UiNode
  local logo = platforms.icons[c.src]
  if logo then
    return ui.image({ path = logo, width = 28, height = 28, fit = "contain", radius = 6 })
  end
  return ui.glyph({ name = "trophy", size = 22 })
end

local function nameLink(c: types.Contest, ctx: types.Ctx): UiNode
  local hovered = ctx.view.hoveredUrl == c.url
  return ui.row({ align = "start" }, {
    ui.column({
      key = c.url,
      gap = 1,
      tooltip = c.url,
      onClick = function()
        ctx.openUrl(c.url)
      end,
      onHover = function(state: string)
        if state == "true" then
          ctx.view.hoveredUrl = c.url
        elseif ctx.view.hoveredUrl == c.url then
          ctx.view.hoveredUrl = nil
        end
        ctx.rerender()
      end,
    }, {
      ui.label({ text = c.name, fontWeight = "medium", color = "on_surface", maxWidth = 320, maxLines = 1 }),
      ui.box({ height = 1, fill = hovered and "on_surface" or "on_surface/0" }),
    }),
  })
end

local function row(c: types.Contest, subtitle: string, trailing: UiNode, ctx: types.Ctx): UiNode
  return ui.row({ gap = 8, align = "center" }, {
    logoOf(c),
    ui.column({ gap = 2, flexGrow = 1 }, {
      nameLink(c, ctx),
      ui.label({
        text = subtitle,
        fontSize = 12,
        color = "on_surface_variant",
        maxWidth = 300,
        maxLines = 1,
      }),
    }),
    trailing,
  })
end

function M.upcomingSubtitle(c: types.Contest, now: number): string
  local timing: string
  if c.start <= now then
    timing = noctalia.tr("rows.live", { time = format.fmtDur(c.start + c.dur - now) })
  else
    timing = noctalia.tr("rows.starts", {
      when = noctalia.formatTime("%a %d %b, %H:%M", c.start),
      time = format.fmtDur(c.start - now),
    })
  end
  return `{timing} · {format.fmtDur(c.dur)}`
end

function M.upcoming(c: types.Contest, now: number, ctx: types.Ctx): UiNode
  local fav = ctx.filters.favorites[c.url] == true
  return row(c, M.upcomingSubtitle(c, now), ui.button({
    key = "fav:" .. c.url,
    glyph = fav and "heart-filled" or "heart",
    variant = "ghost",
    controlSize = "sm",
    selected = fav,
    tooltip = noctalia.tr(fav and "rows.fav_on" or "rows.fav_off"),
    onClick = function()
      ctx.toggleFavorite(c.url)
    end,
  }), ctx)
end

function M.past(c: types.Contest, now: number, ctx: types.Ctx): UiNode
  local saved = ctx.filters.saved[c.url] ~= nil
  local ago = format.fmtDur(now - (c.start + c.dur))
  local subtitle = noctalia.tr("rows.past_subtitle", {
    date = noctalia.formatTime("%d %b", c.start),
    ago = ago,
    duration = format.fmtDur(c.dur),
  })
  return row(c, subtitle, ui.button({
    key = "save:" .. c.url,
    glyph = saved and "bookmark-filled" or "bookmark",
    variant = "ghost",
    controlSize = "sm",
    selected = saved,
    tooltip = noctalia.tr(saved and "rows.saved_on" or "rows.saved_off"),
    onClick = function()
      ctx.toggleSaved(c)
    end,
  }), ctx)
end

function M.sectionLabel(text: string): UiNode
  return ui.label({ text = text, fontSize = 12, fontWeight = "medium", color = "on_surface_variant" })
end

return M
