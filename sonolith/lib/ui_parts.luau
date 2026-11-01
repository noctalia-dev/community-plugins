--!nonstrict
-- UI pieces shared by the Now Playing and Library panels. Palette roles only, spacing on 4/8/12/16.
--
-- Retained nodes are matched to the previous render by key, else by position, and a prop left out keeps
-- its old value. So siblings that come and go, or change node type (art: placeholder -> image), carry
-- keys; otherwise a neighbour takes over the old node with its size and fill.

local format = require("./format.luau")

local M = {}

-- Album art, or a placeholder tile while it downloads (or when there is none).
function M.art(path, size, opts)
  opts = opts or {}
  local radius = opts.round and size / 2 or (opts.radius or 8)
  local key = opts.key or "art"
  if path then
    return ui.image({ key = key .. "-img", path = path, width = size, height = size, radius = radius, fit = "cover" })
  end
  return ui.column({
    key = key .. "-ph",
    width = size,
    height = size,
    radius = radius,
    fill = "surface_container_high",
    align = "center",
    justify = "center",
  }, {
    ui.glyph({ name = opts.glyph or "music", size = math.max(12, math.floor(size * 0.4)), color = "on_surface_variant/0.6" }),
  })
end

function M.explicitBadge()
  return ui.row({ key = "explicit", paddingH = 4, radius = 4, fill = "on_surface_variant/0.2", align = "center" }, {
    ui.label({ text = "E", fontSize = 10, fontWeight = "bold", color = "on_surface_variant" }),
  })
end

-- A section heading with an optional trailing control.
function M.sectionHeader(text, trailing)
  local children = {
    ui.label({ text = text, fontWeight = "semibold", color = "on_surface", flexGrow = 1 }),
  }
  if trailing then
    table.insert(children, trailing)
  end
  return ui.row({ gap = 8, align = "center" }, children)
end

-- A grid card: art, name, subtitle; the button under it plays on click and opens the menu on right click.
--   opts: key, artPath, size, round, onClick, onPlay, onMenuRight, playTooltip
function M.card(item, opts)
  local size = opts.size or 124
  local nameRow = {
    ui.label({ key = "name", text = format.name(item), fontWeight = "medium", color = "on_surface", maxLines = 1, flexGrow = 1 }),
  }
  if opts.onPlay or opts.onMenuRight then
    table.insert(nameRow, ui.button({
      key = "act",
      glyph = opts.onPlay and "player-play" or "dots-vertical",
      variant = "ghost",
      controlSize = "sm",
      tooltip = opts.playTooltip,
      onClick = opts.onPlay,
      onRightClick = opts.onMenuRight,
    }))
  end
  local glyph = ({ artist = "user", podcast = "microphone", episode = "microphone", playlist = "playlist", album = "disc" })[item.type]
  return ui.column({ key = opts.key, width = size, gap = 4, onClick = opts.onClick }, {
    M.art(opts.artPath, size, { radius = 10, round = opts.round, glyph = glyph }),
    ui.row({ key = "name-row", gap = 2, align = "center", width = size }, nameRow),
    ui.label({ key = "sub", text = format.subtitle(item), fontSize = 12, color = "on_surface_variant", maxLines = 1, width = size }),
  })
end

-- Loading placeholders.
function M.skeletonRows(n)
  local rows = {}
  for i = 1, n do
    table.insert(rows, ui.row({ key = "sk" .. i, gap = 12, paddingH = 8, paddingV = 4, align = "center" }, {
      ui.box({ width = 40, height = 40, radius = 6, fill = "surface_container_high" }),
      ui.column({ gap = 6, flexGrow = 1 }, {
        ui.box({ height = 12, width = 180 + (i % 3) * 40, radius = 4, fill = "surface_container_high" }),
        ui.box({ height = 10, width = 110 + (i % 2) * 30, radius = 4, fill = "surface_container_high" }),
      }),
    }))
  end
  return rows
end

function M.skeletonGrid(cols, rows, size)
  local out = {}
  for r = 1, rows do
    local cells = {}
    for c = 1, cols do
      table.insert(cells, ui.column({ key = `skc{r}-{c}`, width = size, gap = 6 }, {
        ui.box({ width = size, height = size, radius = 10, fill = "surface_container_high" }),
        ui.box({ width = size - 24, height = 12, radius = 4, fill = "surface_container_high" }),
        ui.box({ width = size - 52, height = 10, radius = 4, fill = "surface_container_high" }),
      }))
    end
    table.insert(out, ui.row({ key = "skr" .. r, gap = 12 }, cells))
  end
  return out
end

-- One media row: art, title (+E), artist, duration, and an optional menu button.
--   opts: key, artPath, artSize (40), dim, onClick, onMenu (left click), onMenuRight (right click: native menu),
--         selected, subtitle (overrides the artist line)
function M.mediaRow(item, opts)
  opts = opts or {}
  local size = opts.artSize or 40
  local titleRow = {
    ui.label({ key = "title", text = format.name(item), color = opts.dim and "on_surface/0.6" or "on_surface", maxLines = 1, flexGrow = 1 }),
  }
  if item.explicit then
    table.insert(titleRow, M.explicitBadge())
  end
  local children = {
    M.art(opts.artPath, size, { radius = 6, round = item.type == "artist", glyph = item.type == "episode" and "microphone" or "music" }),
    ui.column({ key = "info", gap = 2, flexGrow = 1 }, {
      ui.row({ key = "title-row", gap = 6, align = "center" }, titleRow),
      ui.label({ key = "sub", text = opts.subtitle or format.subtitle(item), fontSize = 12, color = "on_surface_variant", maxLines = 1 }),
    }),
  }
  if item.durationMs then
    table.insert(children, ui.label({ key = "dur", text = format.duration(item.durationMs), fontSize = 12, color = "on_surface_variant" }))
  end
  if opts.onMenu or opts.onMenuRight then
    table.insert(children, ui.button({
      key = "menu",
      glyph = "dots-vertical",
      variant = "ghost",
      controlSize = "sm",
      onClick = opts.onMenu,
      onRightClick = opts.onMenuRight,
    }))
  end
  return ui.row({
    key = opts.key,
    gap = 12,
    paddingH = 8,
    paddingV = 4,
    radius = 8,
    align = "center",
    -- Explicitly transparent, not nil: a retained node keeps a prop that is left out.
    fill = opts.selected and "surface_container_high" or "surface_container_high/0",
    onClick = opts.onClick,
  }, children)
end

return M
