--!nonstrict
-- Live tab: plan limits, then every running session grouped by what it needs from
-- you, Remote Control sessions on other machines, and recently closed sessions to
-- resume. Click a card to jump to its terminal; hover (or select) it for actions.
-- The cards themselves, and the hover and selection state behind them, are in
-- live-cards.luau; this file lays out the board around them.
local shared = require("./shared.luau")
local actions = require("./actions.luau")
local kit = require("./kit.luau")
local cards = require("./live-cards.luau")
local M = {}
M.nav = cards.nav

local showRecent, showPicker = false, false

function M.opened()
  cards.opened()
  showPicker = false
end

-- ── Sections ────────────────────────────────────────────────────────────────

local function sectionHeader(text, count, color, onClick, glyph)
  local kids = {}
  if glyph then kids[#kids + 1] = ui.glyph({ name = glyph, size = 12, color = color }) end
  kids[#kids + 1] = ui.label({ text = string.upper(text), fontSize = 10, fontWeight = "bold", color = color })
  kids[#kids + 1] = ui.label({ text = tostring(count), fontSize = 10, color = "on_surface_variant" })
  kids[#kids + 1] = ui.separator({ orientation = "horizontal", color = "outline_variant", opacity = 0.5, flexGrow = 1 })
  return ui.row({ gap = 6, align = "center", paddingH = 2, paddingV = onClick and 4 or 0, onClick = onClick }, kids)
end

-- One meter per plan window: used and projected, and where it is heading. Click the
-- strip for the full picture on the Usage tab.
local function limitsStrip(ctx, limits)
  if not limits or #(limits.windows or {}) == 0 then return nil end
  local meters = {}
  for _, w in ipairs(limits.windows) do
    local p = shared.pace(w)
    local color = shared.paceColor(p.status, "primary")
    meters[#meters + 1] = ui.column({ gap = 4, flexGrow = 1 }, {
      ui.row({ gap = 4, align = "center" }, {
        ui.label({ text = w.label, fontSize = 11, fontWeight = "bold" }),
        ui.spacer({ flexGrow = 1 }),
        ui.label({ text = `{shared.round(w.percent)}%`, fontSize = 12, fontWeight = "bold", color = color }),
      }),
      kit.paceBar(p, color, 5),
      ui.label({ text = shared.paceShort(w, p), fontSize = 10, maxLines = 1,
        color = color == "primary" and "on_surface_variant" or color }),
    })
  end
  local strip = { ui.row({ gap = 16, align = "start" }, meters) }
  if limits.stale then
    strip[#strip + 1] = kit.iconLine("clock-exclamation",
      `limits from {shared.ago(limits.updated)} ago` .. (limits.error and ` · {limits.error}` or ""), "tertiary")
  end
  return ui.column({ key = "limits-strip", gap = 6, padding = 10, radius = 10, fill = "on_surface/0.04",
    opacity = limits.stale and 0.75 or 1, tooltip = "Open Usage for details", onClick = function() ctx.setTab("usage") end }, strip)
end

local function countPill(g, n)
  return ui.row({ gap = 5, align = "center", paddingH = 9, paddingV = 4, radius = 10, fill = g.color .. "/0.14" }, {
    ui.glyph({ name = g.glyph, size = 12, color = g.color }),
    ui.label({ text = `{n} {g.pill}`, fontSize = 11, fontWeight = "bold", color = g.color }),
  })
end

local function picker(ctx)
  local seen, dirs, pinnedDir = {}, {}, {}
  local function add(d) if d and d ~= "" and not seen[d] then seen[d] = true; dirs[#dirs + 1] = d end end
  -- Pinned projects first (pin them from the Sessions tab), then where you worked last.
  for _, p in ipairs(type(ctx.S.pins) == "table" and ctx.S.pins or {}) do pinnedDir[p] = true; add(p) end
  for _, s in ipairs(ctx.S.sessions) do add(s.cwd) end
  for _, r in ipairs(ctx.S.recent) do add(r.cwd) end
  add(shared.workRoot())
  local rows = { ui.label({ text = "START CLAUDE IN…", fontSize = 10, fontWeight = "bold", color = "primary" }) }
  for i, d in ipairs(dirs) do
    if i > 10 then break end
    local key = "dir:" .. d
    rows[#rows + 1] = ui.row({
      key = key, gap = 8, align = "center", paddingH = 8, paddingV = 6, radius = 8,
      fill = cards.hovering(key) and "on_surface/0.10" or "on_surface/0.04",
      onHover = cards.hoverHandler(ctx, key),
      onClick = function() actions.newSession(d); ctx.close() end,
    }, {
      ui.glyph({ name = pinnedDir[d] and "pinned" or "folder-plus", size = 14, color = "primary" }),
      ui.label({ text = shared.projectPath(d), fontSize = 12, maxLines = 1, flexGrow = 1 }),
    })
  end
  return ui.column({ gap = 4, padding = 10, radius = 10, fill = "primary/0.06", border = "primary/0.3", borderWidth = 1 }, rows)
end

function M.render(ctx)
  local S = ctx.S
  M.nav:begin()
  local by = { waiting = {}, busy = {}, idle = {} }
  for _, s in ipairs(S.sessions) do table.insert(by[s.status] or by.idle, s) end

  local toolbar = {}
  for _, g in ipairs(cards.GROUPS) do
    if #by[g.status] > 0 then toolbar[#toolbar + 1] = countPill(g, #by[g.status]) end
  end
  toolbar[#toolbar + 1] = ui.spacer({ flexGrow = 1 })
  toolbar[#toolbar + 1] = ui.button({ glyph = showPicker and "x" or "plus", text = "New session", variant = showPicker and "secondary" or "ghost",
    controlSize = "sm", onClick = function() showPicker = not showPicker; ctx.render() end })

  local content = {}
  if showPicker then content[#content + 1] = picker(ctx) end
  local strip = limitsStrip(ctx, S.accounts[1] and S.accounts[1].limits)
  if strip then content[#content + 1] = strip end

  local lineNo = 0
  for _, g in ipairs(cards.GROUPS) do
    if #by[g.status] > 0 then
      content[#content + 1] = sectionHeader(g.title, #by[g.status], g.color)
      for _, s in ipairs(by[g.status]) do
        local key = "live:" .. s.pid
        M.nav:add(key, function() actions.focus(s); ctx.close() end)
        lineNo += 1
        content[#content + 1] = cards.liveCard(ctx, s, key, `L{lineNo}`)
      end
    end
  end
  if #S.elsewhere > 0 then
    content[#content + 1] = sectionHeader("Elsewhere", #S.elsewhere, "secondary", nil, "world")
    for _, r in ipairs(S.elsewhere) do
      local key = "remote:" .. r.id
      M.nav:add(key, function() actions.open(r.url); ctx.close() end)
      content[#content + 1] = cards.remoteCard(ctx, r, key)
    end
  end
  if #S.sessions == 0 and #S.elsewhere == 0 then
    content[#content + 1] = kit.notice("moon", "No Claude sessions running")
  end
  if #S.recent > 0 then
    content[#content + 1] = sectionHeader("Recent", #S.recent, "on_surface_variant",
      function() showRecent = not showRecent; ctx.render() end, showRecent and "chevron-down" or "chevron-right")
    if showRecent then
      for _, r in ipairs(S.recent) do
        local key = "recent:" .. r.sessionId
        M.nav:add(key, function() actions.resume(r.account, r.cwd, r.sessionId); ctx.close() end)
        content[#content + 1] = cards.recentCard(ctx, r, key)
      end
    end
  end

  return ui.column({ gap = 10, flexGrow = 1 }, {
    ui.row({ gap = 6, align = "center" }, toolbar),
    ui.scroll({ key = "live-scroll", flexGrow = 1, gap = 8, revealKey = M.nav.reveal }, content),
    ui.row({ gap = 12, align = "center" }, {
      kit.iconLine("pointer", "Click a card to jump to it · hover or select it for actions"),
      kit.iconLine("keyboard", "↑↓ ⏎"),
    }),
  })
end

return M
