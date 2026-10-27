--!nonstrict
-- Small ui.* building blocks shared by the panel tabs, and the keyboard selection
-- model every tab uses (up/down move, Return activates, the scroll reveals it).
local M = {}

-- Children list without the holes an optional (nil) element would leave.
function M.compact(...)
  local out = {}
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    if v ~= nil then out[#out + 1] = v end
  end
  return out
end

function M.muted(text, size, props)
  local p = { text = text, fontSize = size or 12, color = "on_surface_variant" }
  for k, v in pairs(props or {}) do p[k] = v end
  return ui.label(p)
end

function M.heading(text) return ui.label({ text = text, fontSize = 14, fontWeight = "medium" }) end

function M.card(children, props)
  local p = { gap = 8, padding = 14, fill = "surface_container", radius = 12, align = "stretch" }
  for k, v in pairs(props or {}) do p[k] = v end
  return ui.column(p, children)
end

function M.iconLine(glyph, text, color, size)
  return ui.row({ gap = 6, align = "center" }, {
    ui.glyph({ name = glyph, size = (size or 11) + 1, color = color or "on_surface_variant" }),
    ui.label({ text = text, fontSize = size or 11, color = color or "on_surface_variant", maxLines = 1, flexGrow = 1 }),
  })
end

function M.chip(glyph, text, extra, color)
  local kids = {
    ui.glyph({ name = glyph, size = 11, color = color or "on_surface_variant" }),
    ui.label({ text = text, fontSize = 10, color = color or "on_surface_variant", maxLines = 1 }),
  }
  if extra then kids[#kids + 1] = extra end
  return ui.row({ gap = 4, align = "center", paddingH = 6, paddingV = 2, radius = 6, fill = "on_surface/0.07" }, kids)
end

function M.iconButton(glyph, tooltip, onClick, props)
  local p = { glyph = glyph, tooltip = tooltip, variant = "ghost", controlSize = "sm", onClick = onClick }
  for k, v in pairs(props or {}) do p[k] = v end
  return ui.button(p)
end

-- A plan window as one bar: used (solid), where the current rate takes it by the reset
-- (faint, capped at 100%), and what is left; with `marker`, a tick under the bar shows
-- how much of the window's time has gone. Built from flex-weighted boxes, so it fills
-- whatever width its container has.
function M.paceBar(p, color, height, marker)
  height = height or 8
  local used = math.max(0, math.min(100, p.util or 0))
  local ahead = p.projected and math.max(0, math.min(100, p.projected) - used) or 0
  local rest = 100 - used - ahead
  local segs = {}
  local function seg(weight, fill)
    if weight > 0.2 then
      segs[#segs + 1] = ui.box({ flexGrow = weight, height = height, radius = height / 2, fill = fill })
    end
  end
  seg(used, color)
  seg(ahead, color .. "/0.3")
  seg(rest, "on_surface/0.12")
  local bar = ui.row({ gap = 2, height = height }, segs)
  if not marker or not p.timeFrac then return bar end
  local f = math.max(0.001, math.min(0.999, p.timeFrac))
  return ui.column({ gap = 2 }, {
    bar,
    ui.row({ gap = 0, height = 5, align = "start" }, {
      ui.spacer({ flexGrow = f }),
      ui.box({ width = 2, height = 5, radius = 1, fill = "on_surface/0.6" }),
      ui.spacer({ flexGrow = 1 - f }),
    }),
  })
end

-- The last hour of a session as a strip: working, waiting and idle stretches in their
-- colours, an unknown stretch (before the plugin saw the session) as track.
local STATUS_FILL = { waiting = "error", busy = "primary", idle = "on_surface/0.22" }

function M.timeline(tl, height)
  local now = noctalia.nowMs()
  local start = now - 3600000
  local segs = {}
  local function seg(weight, fill)
    if weight > 0 then segs[#segs + 1] = ui.box({ flexGrow = weight, height = height or 4, radius = 1, fill = fill }) end
  end
  if tl and tl[1] and tl[1][1] > start then seg(tl[1][1] - start, "on_surface/0.07") end
  for i, e in ipairs(tl or {}) do
    local from = math.max(e[1], start)
    local to = tl[i + 1] and tl[i + 1][1] or now
    seg(to - from, STATUS_FILL[e[2]] or STATUS_FILL.idle)
  end
  if #segs == 0 then seg(1, "on_surface/0.07") end
  return ui.row({ gap = 1, height = height or 4, flexGrow = 1 }, segs)
end

-- The one line the panel header leads with: the most urgent thing on the board.
-- Returns text, color role and glyph.
function M.statusLine(S, shared)
  for _, s in ipairs(S.sessions) do
    if s.status == "waiting" then
      local title = s.d and s.d.title or s.name
      return `{title} needs you` .. (s.waitingFor ~= "" and `: {s.waitingFor}` or ""), "error", "bell-ringing"
    end
  end
  for _, r in ipairs(S.elsewhere) do
    if r.category == "need_input" then return `{r.title} needs you (elsewhere)`, "error", "bell-ringing" end
  end
  local limits = S.accounts[1] and S.accounts[1].limits
  local worst, worstP, rank = nil, nil, { soon = 3, limit = 4, hit = 2 }
  for _, w in ipairs(limits and limits.windows or {}) do
    local p = shared.pace(w)
    if rank[p.status] and (not worstP or rank[p.status] > rank[worstP.status]) then worst, worstP = w, p end
  end
  if worst then
    return `{worst.label} limit: {shared.paceShort(worst, worstP)}`, shared.paceColor(worstP.status, "primary"), "gauge"
  end
  local busy, idle = 0, 0
  for _, s in ipairs(S.sessions) do if s.status == "busy" then busy += 1 else idle += 1 end end
  if busy + idle == 0 then return "All quiet: no sessions running", "on_surface_variant", "moon" end
  return `{busy} working · {idle} idle`, busy > 0 and "primary" or "on_surface_variant", "activity"
end

-- Inline "are you sure" row under the thing it confirms.
function M.confirmStrip(key, text, yesText, onYes, onNo)
  return ui.row({ key = "confirm-" .. key, gap = 8, align = "center", paddingH = 4 }, {
    ui.label({ text = text, fontSize = 12, color = "on_surface", flexGrow = 1, maxLines = 2 }),
    ui.button({ text = yesText, variant = "destructive", controlSize = "sm", onClick = onYes }),
    ui.button({ text = "Cancel", variant = "ghost", controlSize = "sm", onClick = onNo }),
  })
end

function M.notice(glyph, text, color)
  return ui.column({ gap = 8, align = "center", justify = "center", paddingV = 40 }, {
    ui.glyph({ name = glyph, size = 32, color = color or "on_surface_variant" }),
    ui.label({ text = text, color = color or "on_surface_variant", maxLines = 3, textAlign = "center" }),
  })
end

-- Keyboard selection. A tab calls nav:begin() before drawing its rows and nav:add()
-- for each selectable one, in display order; add() returns whether that row is the
-- selected one, and the tab passes nav.reveal to its ui.scroll as revealKey.
-- sel = 0 means nothing is selected until the first arrow press.
function M.nav()
  local nav = { items = {}, sel = 0, reveal = nil }
  function nav:begin()
    self.items, self.reveal = {}, nil
  end
  function nav:add(key, act)
    self.items[#self.items + 1] = { key = key, act = act }
    local on = #self.items == self.sel
    if on then self.reveal = key end
    return on
  end
  function nav:selectedKey()
    local it = self.items[self.sel]
    return it and it.key or nil
  end
  -- Moves without wrapping (a held key stops at the ends); false when nothing moved.
  function nav:move(step)
    local target = math.max(1, math.min(#self.items, self.sel + step))
    if #self.items == 0 or target == self.sel then return false end
    self.sel = target
    return true
  end
  function nav:activate()
    local it = self.items[self.sel]
    if it then it.act() end
  end
  function nav:reset() self.sel = 0 end
  return nav
end

return M
