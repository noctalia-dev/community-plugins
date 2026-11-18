--!nonstrict
-- Small building blocks shared by the panel tabs: cards, captions, banners,
-- sparklines, P&L labels and segmented pickers. Pure functions of their
-- arguments; theme roles only.

local fmt = require("./fmt.luau")

local M = {}

M.CARD_FILL = "surface_container/0.45"
M.TRACK = "on_surface/0.08"

function M.merge(props, extra)
  if extra then
    for k, v in extra do
      props[k] = v
    end
  end
  return props
end

-- Children list from optional nodes: nil arguments are dropped, so a tree
-- never has holes.
function M.nodes(...)
  local out = {}
  for i = 1, select("#", ...) do
    local node = select(i, ...)
    if node ~= nil then
      table.insert(out, node)
    end
  end
  return out
end

function M.caption(text: string, color: string?, extra)
  return ui.label(M.merge({ text = text, fontSize = 11, color = color or "on_surface_variant" }, extra))
end

function M.title(text: string, extra)
  return ui.label(M.merge({ text = text, fontSize = 13, fontWeight = "semibold", color = "on_surface" }, extra))
end

function M.card(children, extra)
  return ui.column(M.merge({ gap = 10, padding = 12, radius = 12, fill = M.CARD_FILL }, extra), children)
end

-- A section heading with an optional control on the right.
function M.section(text: string, right, key: string?)
  return ui.row({ align = "center", gap = 8, key = key }, M.nodes(
    ui.label({ text = text, fontSize = 12, fontWeight = "semibold", color = "on_surface_variant", flexGrow = 1 }),
    right
  ))
end

-- A status line across the panel. tone: "error" for something the user must
-- act on, "info" for a temporary condition that resolves itself.
function M.banner(tone: string, glyph: string, title: string, body: string?, action, key: string?)
  local isError = tone == "error"
  return ui.row({
    key = key,
    gap = 10,
    align = "center",
    paddingH = 12,
    paddingV = 8,
    radius = 10,
    fill = if isError then "error/0.12" else "surface_container/0.6",
  }, M.nodes(
    ui.glyph({ name = glyph, size = 16, color = if isError then "error" else "on_surface_variant" }),
    ui.column({ gap = 1, flexGrow = 1 }, M.nodes(
      ui.label({ text = title, fontSize = 12, fontWeight = "medium", color = "on_surface", maxLines = 2 }),
      if body and body ~= "" then M.caption(body, nil, { maxLines = 3 }) else nil
    )),
    action
  ))
end

-- Values scaled into 0..1 for ui.graph over a shared min/max, so two series
-- drawn together stay comparable. A flat series sits in the middle.
function M.normalize(series: { number }, other: { number }?): ({ number }, { number }?)
  local lo, hi = math.huge, -math.huge
  for _, list in { series, other or {} } do
    for _, v in list do
      lo, hi = math.min(lo, v), math.max(hi, v)
    end
  end
  local span = hi - lo
  local function scale(list)
    local out = table.create(#list)
    for i, v in list do
      out[i] = if span > 0 then (v - lo) / span else 0.5
    end
    return out
  end
  return scale(series), if other then scale(other) else nil
end

-- A tiny trend line. It spans 30 days while the change shown beside it is
-- 24h, so it stays neutral rather than contradict that change's color.
function M.spark(values: { number }?, width: number, height: number, key: string?)
  if values == nil or #values < 2 then
    -- An empty column, not a ui.box: a box without `fill` draws opaque black.
    return ui.column({ width = width, height = height, key = key }, {})
  end
  local scaled = M.normalize(values)
  return ui.graph({
    key = key,
    values = scaled,
    color = "on_surface_variant",
    lineWidth = 1.5,
    fillOpacity = 0.12,
    width = width,
    height = height,
  })
end

-- "+$37.00 (+0.45%)", or just the percentage while privacy is on.
function M.pnlText(pnl, currency: string, privacy: boolean): string
  if pnl == nil then
    return "—"
  end
  local pct = if pnl.pct ~= nil then fmt.pct(pnl.pct) else nil
  if privacy then
    return pct or fmt.MASK
  end
  local money = fmt.money(pnl.pnl, currency, { signed = true })
  return if pct then `{money} ({pct})` else money
end

-- A P&L label with its trend arrow, colored by sign.
function M.pnl(pnl, currency: string, privacy: boolean, size: number?, extra)
  local sign = fmt.pnlSign(pnl)
  local color = fmt.signColor(sign)
  local arrow = fmt.arrow(sign)
  return ui.row(M.merge({ gap = 4, align = "center" }, extra), M.nodes(
    if arrow then ui.glyph({ name = arrow, size = (size or 12) + 1, color = color }) else nil,
    ui.label({ text = M.pnlText(pnl, currency, privacy), fontSize = size or 12, fontWeight = "medium", color = color })
  ))
end

-- A stock's market session ("pre" | "open" | "post" | "overnight" |
-- "closed"): a dot and a word. Only the regular session is in the accent
-- colour, so a quote outside it never reads as live.
local SESSION_COLORS = { open = "primary", pre = "tertiary", post = "tertiary", overnight = "tertiary" }

function M.session(session: string?)
  if session == nil then
    return nil
  end
  local color = SESSION_COLORS[session] or "on_surface_variant"
  return ui.row({ gap = 3, align = "center", tooltip = noctalia.tr("panel.session.tooltip") }, {
    ui.box({ width = 6, height = 6, radius = 3, fill = color }),
    ui.label({ text = noctalia.tr(`panel.session.{session}`), fontSize = 9, fontWeight = "semibold", color = color }),
  })
end

-- A row of small toggle buttons; `selected` is the chosen id.
--   options: { { id, label, enabled?, tooltip? } }
function M.segmented(options, selected: string?, onSelect: (string) -> (), extra)
  local buttons = {}
  for _, option in options do
    table.insert(buttons, ui.button({
      key = option.id,
      text = option.label,
      controlSize = "sm",
      variant = "ghost",
      selected = option.id == selected,
      enabled = option.enabled ~= false,
      tooltip = option.tooltip,
      onClick = function()
        onSelect(option.id)
      end,
    }))
  end
  return ui.row(M.merge({ gap = 2, align = "center" }, extra), buttons)
end

-- Label on the left, value on the right.
function M.stat(label: string, value: string, valueColor: string?, key: string?)
  return ui.row({ align = "center", gap = 8, key = key }, {
    M.caption(label, nil, { flexGrow = 1, fontSize = 12 }),
    ui.label({ text = value, fontSize = 12, fontWeight = "medium", color = valueColor or "on_surface" }),
  })
end

-- A small icon + text row used for explanations and checklists.
function M.bullet(glyph: string, text: string, color: string?, key: string?)
  return ui.row({ gap = 8, align = "start", key = key }, {
    ui.glyph({ name = glyph, size = 14, color = color or "primary" }),
    ui.label({ text = text, fontSize = 12, color = "on_surface", flexGrow = 1, maxLines = 4 }),
  })
end

return M
