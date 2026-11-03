--!nonstrict
-- Usage tab: each plan window with where the current rate takes it by the reset, then
-- token use and estimated cost (today, 7 days, 30 days), the last 7 days day by day,
-- the costliest sessions and the models used. Layout after claude-cockpit (nightwatch75,
-- MIT) and jrohland/noctalia-v5-claudecode (MIT); the projection model is new.
local shared = require("./shared.luau")
local kit = require("./kit.luau")
local M = {}

local hoveredDay = nil

function M.opened() hoveredDay = nil end

local function windowTitle(w)
  if w.kind == "session" then return "5-hour session" end
  if w.model then return `{w.model} · weekly` end
  return "Weekly · all models"
end

-- Usage across the whole window as two graphs side by side, split at "now": what
-- happened (from the service's samples, starting at 0 when the window opened) and where
-- the current rate takes it by the reset, faint. The thin line is even pace: straight
-- from 0 at the start to 100% at the reset.
local POINTS = 48

local function forecast(w, p, color)
  if not w.resetsAt or not p.timeFrac then return nil end
  local dur = w.durationMs or 7 * shared.DAY_MS
  local start, now = w.resetsAt - dur, noctalia.nowMs()
  local pts = { { start, 0 } }
  for _, smp in ipairs(w.samples or {}) do
    if smp[1] > start and smp[1] <= now then pts[#pts + 1] = smp end
  end
  if pts[#pts][1] < now then pts[#pts + 1] = { now, w.percent } end
  local function at(t)
    for i = 2, #pts do
      if t <= pts[i][1] then
        local a, b = pts[i - 1], pts[i]
        local f = b[1] > a[1] and (t - a[1]) / (b[1] - a[1]) or 1
        return a[2] + (b[2] - a[2]) * f
      end
    end
    return pts[#pts][2]
  end
  local left = math.max(2, math.min(POINTS - 2, shared.round(POINTS * p.timeFrac)))
  local past, pastEven, ahead, aheadEven = {}, {}, {}, {}
  for i = 0, left - 1 do
    local t = start + (now - start) * i / (left - 1)
    past[#past + 1] = at(t) / 100
    pastEven[#pastEven + 1] = (t - start) / dur
  end
  local rate = p.rate or 0
  for i = 0, POINTS - left - 1 do
    local t = now + (w.resetsAt - now) * i / math.max(1, POINTS - left - 1)
    ahead[#ahead + 1] = math.min(1, (w.percent + rate * (t - now) / shared.HOUR_MS) / 100)
    aheadEven[#aheadEven + 1] = (t - start) / dur
  end
  -- ui.graph draws points 2..n only (the first two just shape the curve, for scrolling
  -- graphs), so repeat each series' first value twice to start the line at its first point.
  local function lead(v) return { v[1], v[1], table.unpack(v) } end
  local graph = function(values, even, c, grow)
    return ui.graph({ values = lead(values), values2 = lead(even), color = c, color2 = "on_surface/0.25", lineWidth = 2,
      fillOpacity = 0.15, height = 56, flexGrow = grow })
  end
  return ui.column({ gap = 3 }, {
    ui.row({ gap = 0, height = 56 }, {
      graph(past, pastEven, color, math.max(0.05, p.timeFrac)),
      ui.box({ width = 1, height = 56, fill = "on_surface/0.35" }),
      graph(ahead, aheadEven, color .. "/0.45", math.max(0.05, 1 - p.timeFrac)),
    }),
    ui.row({ gap = 4 }, {
      kit.muted(shared.clock(start) or "", 9),
      ui.spacer({ flexGrow = 1 }),
      kit.muted(p.recent and "projection: recent rate" or p.rate and "projection: average rate" or "too early to project", 9),
      ui.spacer({ flexGrow = 1 }),
      kit.muted(`reset {shared.clock(w.resetsAt) or ""}`, 9),
    }),
  })
end

local function windowCard(w)
  local p = shared.pace(w)
  local color = shared.paceColor(p.status, "primary")
  local headline, detail = shared.paceText(w, p)
  local right = p.status == "idle" and kit.muted("idle", 13)
    or ui.label({ text = `{shared.round(w.percent)}%`, fontSize = 18, fontWeight = "bold", color = color })
  local rows = {
    ui.row({ align = "center", gap = 8 }, {
      kit.heading(windowTitle(w)),
      ui.spacer({ flexGrow = 1 }),
      right,
    }),
    forecast(w, p, color) or kit.paceBar(p, color, 8, true),
    ui.label({ text = headline, fontSize = 12, color = color == "primary" and "on_surface" or color, maxLines = 1 }),
  }
  if detail then rows[#rows + 1] = kit.muted(detail, 11, { maxLines = 1 }) end
  return kit.card(rows, { gap = 6 })
end

-- "Since 11 Jul" from the all-time total's first day ("2026-07-11").
local function sinceLabel(day)
  local y, m, d = string.match(tostring(day or ""), "^(%d+)-(%d+)-(%d+)$")
  if not y then return "All time" end
  local t = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
  return `Since {tonumber(d)} {os.date("%b", t)}`
end

local function metric(label, tokens, cost, rates)
  return ui.column({ gap = 2, align = "center", flexGrow = 1 }, {
    kit.muted(label, 11),
    ui.label({ text = shared.money(cost, rates), fontSize = 17, fontWeight = "bold", color = "primary" }),
    kit.muted(shared.tokens(tokens) .. " tokens", 11),
  })
end

local function dailyChart(ctx, u)
  local daily, costs, labels = u.daily or {}, u.dailyCost or {}, u.days or {}
  local maxVal = 1
  for _, v in ipairs(daily) do maxVal = math.max(maxVal, tonumber(v) or 0) end
  local barH = 70
  local cols = {}
  for i = 1, 7 do
    local v = tonumber(daily[i]) or 0
    local h = v > 0 and math.max(3, math.floor(v / maxVal * barH)) or 0
    local isToday, isHover = i == 7, i == hoveredDay
    local fill = isToday and "primary" or "on_surface/0.18"
    if isHover then fill = isToday and "primary/0.75" or "on_surface/0.4" end
    cols[#cols + 1] = ui.column({
      key = `day-{i}`, flexGrow = 1, gap = 4, align = "center",
      onHover = function(state)
        if state == "true" then hoveredDay = i elseif hoveredDay == i then hoveredDay = nil else return end
        ctx.markDirty()
      end,
    }, {
      ui.column({ height = barH, justify = "end", align = "center" }, {
        ui.box({ width = isHover and 24 or 20, height = h, radius = 3, fill = fill }),
      }),
      ui.label({ text = isToday and "Today" or (labels[i] or ""), fontSize = 10,
        color = (isToday or isHover) and "primary" or "on_surface_variant" }),
    })
  end
  local i = hoveredDay or 7
  local detail = `{i == 7 and "Today" or labels[i] or ""}: {shared.money(costs[i], ctx.rates())} · {shared.tokens(daily[i])} tokens`
  return kit.card({
    ui.row({ align = "center", gap = 8 }, {
      kit.heading("Last 7 days"),
      ui.spacer({ flexGrow = 1 }),
      ui.label({ text = detail, fontSize = 11, color = hoveredDay and "primary" or "on_surface_variant", maxLines = 1 }),
    }),
    ui.row({ gap = 6, align = "end" }, cols),
  })
end

local function topSessionsCard(ctx, u)
  local list = u.topSessions or {}
  if #list == 0 then return nil end
  local rows = { kit.heading("Costliest sessions · 7 days") }
  local top = tonumber(list[1].cost) or 0
  for _, s in ipairs(list) do
    local title = (s.title or "") ~= "" and s.title or `session {string.sub(s.id, 1, 8)}`
    rows[#rows + 1] = ui.column({ gap = 3 }, {
      ui.row({ gap = 8, align = "center" }, {
        ui.label({ text = title, fontSize = 12, maxLines = 1, flexGrow = 1 }),
        ui.label({ text = shared.money(s.cost, ctx.rates()), fontSize = 12, fontWeight = "bold" }),
      }),
      ui.row({ gap = 8, align = "center" }, {
        ui.progress({ progress = top > 0 and (tonumber(s.cost) or 0) / top or 0, height = 4, flexGrow = 1,
          fill = "secondary", track = "on_surface/0.10" }),
        kit.muted(`{shared.projectPath(s.cwd or "")} · {shared.tokens(s.tokens)}`, 10, { maxLines = 1 }),
      }),
    })
  end
  return kit.card(rows)
end

-- When Claude gets used: cost by weekday and hour over 30 days, as one SVG (168 boxes
-- would be re-laid out every second this tab is open). Redrawn when the usage changes.
local HEAT_DIR = (noctalia.pluginDataDir() or "/tmp") .. "/heat"
local CELL_W, CELL_H, GAP = 24, 16, 2

local function heatImage(u)
  local path = `{HEAT_DIR}/heat-{u.updated or 0}.svg`
  if noctalia.fileExists(path) then return path end
  noctalia.mkdirAll(HEAT_DIR)
  for _, f in ipairs(noctalia.listDir(HEAT_DIR) or {}) do
    noctalia.removeFile(string.find(f, "/") and f or HEAT_DIR .. "/" .. f)
  end
  local max = 0
  for _, row in ipairs(u.heat) do for _, v in ipairs(row) do max = math.max(max, v) end end
  local fill = noctalia.getColor("primary") or "#33b1ff"
  local empty = noctalia.getColor("on_surface") or "#ffffff"
  local svg = { string.format('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d">', 24 * CELL_W, 7 * CELL_H) }
  for d, row in ipairs(u.heat) do
    for h, v in ipairs(row) do
      -- Square root, so a few heavy hours do not wash out the rest.
      local a = v > 0 and max > 0 and 0.15 + 0.85 * math.sqrt(v / max) or 0
      svg[#svg + 1] = string.format('<rect x="%d" y="%d" width="%d" height="%d" rx="3" fill="%s" fill-opacity="%.2f"/>',
        (h - 1) * CELL_W, (d - 1) * CELL_H, CELL_W - GAP, CELL_H - GAP, a > 0 and fill or empty, a > 0 and a or 0.05)
    end
  end
  svg[#svg + 1] = "</svg>"
  noctalia.writeFile(path, table.concat(svg))
  return path
end

local function heatCard(ctx, u)
  if type(u.heat) ~= "table" or #u.heat ~= 7 then return nil end
  local best, bd, bh = 0, 1, 1
  for d, row in ipairs(u.heat) do
    for h, v in ipairs(row) do if v > best then best, bd, bh = v, d, h end end
  end
  if best == 0 then return nil end
  local names = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }
  local labels = {}
  -- Labels take their text's size, so each sits in a container sized to its cells.
  for _, n in ipairs(names) do
    labels[#labels + 1] = ui.column({ height = CELL_H, justify = "center" }, { kit.muted(n, 9) })
  end
  local hours = {}
  for _, h in ipairs({ "0h", "6h", "12h", "18h" }) do
    hours[#hours + 1] = ui.column({ width = 6 * CELL_W }, { kit.muted(h, 9) })
  end
  return kit.card({
    ui.row({ align = "center", gap = 8 }, {
      kit.heading("When you use Claude · 30 days"),
      ui.spacer({ flexGrow = 1 }),
      kit.muted(`busiest: {names[bd]} {bh - 1}:00`, 11),
    }),
    ui.row({ gap = 6, align = "start" }, {
      ui.column({ gap = 0, width = 26 }, labels),
      ui.column({ gap = 2 }, {
        ui.image({ path = heatImage(u), width = 24 * CELL_W, height = 7 * CELL_H }),
        ui.row({ gap = 0 }, hours),
      }),
    }),
  })
end

local function modelsCard(u)
  local list = {}
  for name, tokens in pairs(u.d7Models or {}) do list[#list + 1] = { name = name, tokens = tonumber(tokens) or 0 } end
  if #list == 0 then return nil end
  table.sort(list, function(a, b) return a.tokens > b.tokens end)
  local total = tonumber(u.d7Tokens) or 0
  local rows = { kit.heading("Models · 7 days") }
  for _, m in ipairs(list) do
    local share = total > 0 and math.min(1, m.tokens / total) or 0
    rows[#rows + 1] = ui.column({ gap = 2, align = "stretch" }, {
      ui.row({ align = "center", gap = 8 }, {
        ui.label({ text = string.upper(string.sub(m.name, 1, 1)) .. string.sub(m.name, 2), fontSize = 12, flexGrow = 1 }),
        kit.muted(`{shared.tokens(m.tokens)} · {shared.round(share * 100)}%`, 11),
      }),
      ui.progress({ progress = share, fill = "primary", track = "on_surface/0.12", height = 5, radius = 2 }),
    })
  end
  return kit.card(rows)
end

function M.render(ctx)
  local S = ctx.S
  local limits = S.accounts[1] and S.accounts[1].limits
  local u = S.usage
  local cards = {}
  if limits then
    if limits.stale then
      cards[#cards + 1] = kit.iconLine("clock-exclamation",
        `Limits from {shared.ago(limits.updated)} ago` .. (limits.error and ` · {limits.error}` or ""), "tertiary", 11)
    end
    for _, w in ipairs(limits.windows or {}) do cards[#cards + 1] = windowCard(w) end
    cards[#cards + 1] = kit.muted("Solid: usage so far. Faint: where the current rate takes it by the reset. Thin line: even pace to 100%.", 10, { maxLines = 2 })
  end
  if type(u) == "table" then
    local rates = ctx.rates()
    cards[#cards + 1] = kit.card({
      ui.row({ gap = 8, align = "center" }, {
        kit.heading("Estimated cost"),
        ui.spacer({ flexGrow = 1 }),
        kit.muted(`{u.d7Messages or 0} replies in {u.d7Sessions or 0} sessions`, 10),
      }),
      ui.row({ gap = 8, align = "start" }, {
        metric("Today", u.todayTokens, u.todayCost, rates),
        metric("7 days", u.d7Tokens, u.d7Cost, rates),
        metric("30 days", u.d30Tokens, u.d30Cost, rates),
        u.allCost and metric(sinceLabel(u.allSince), u.allTokens, u.allCost, rates) or nil,
      }),
      kit.muted("What these tokens would cost at API prices; a subscription is billed flat. The all-time total "
        .. "keeps counting after Claude Code deletes old transcripts (after 30 days by default).", 10, { maxLines = 3 }),
    })
    cards[#cards + 1] = dailyChart(ctx, u)
    local heat = heatCard(ctx, u)
    if heat then cards[#cards + 1] = heat end
    local top = topSessionsCard(ctx, u)
    if top then cards[#cards + 1] = top end
    local models = modelsCard(u)
    if models then cards[#cards + 1] = models end
  end
  if #cards == 0 then return kit.notice("chart-bar", "Loading usage…") end
  return ui.scroll({ key = "usage-scroll", flexGrow = 1, gap = 10, align = "stretch" }, cards)
end

return M
