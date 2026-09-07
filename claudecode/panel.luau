--!nonstrict
-- Claude Code Usage — click panel (the DMS popout).
--
-- Opened from the bar pill (panel-toggle / noctalia.togglePanel), attached under
-- it. A thin client of the service's published "usage" / "status" state, laid out
-- like ClaudeCodeUsageWidget.qml's popout: header, profile selector, 5h / 7d rate
-- windows with pacing, token consumption, daily activity (hover a bar for that
-- day's tokens + cost), per-model breakdown, all-time stats.
--
--   panel.render(tree)              declarative UI tree
--   panel.close()                   close the surface
--   panel.setWantsSecondTicks(b)    update() on second boundaries (live countdowns)
--   onOpen / onClose                lifecycle

local shared = require("./shared.luau")
local formatTokens, formatCost, shortModelName = shared.formatTokens, shared.formatCost, shared.shortModelName
local formatCountdown, pace, paceLabel, paceColor = shared.formatCountdown, shared.pace, shared.paceLabel, shared.paceColor
local round = shared.round

local ACCENT = "primary"

local usage = noctalia.state.get("usage")
local status = noctalia.state.get("status")
local selected = noctalia.state.get("selected_profile") or "all"

local isOpen = false
local hoveredDay = nil -- 1..7 while the pointer is over a daily bar

-- ── small ui.* helpers ──────────────────────────────────────────────────────

local function muted(text, size)
  return ui.label({ text = text, fontSize = size or 12, color = "on_surface_variant" })
end

local function heading(text)
  return ui.label({ text = text, fontSize = 14, fontWeight = "medium" })
end

local function card(children)
  return ui.column({
    gap = 8, padding = 14, fill = "surface_variant/0.45", radius = 12, align = "stretch",
  }, children)
end

-- ── header ──────────────────────────────────────────────────────────────────

local function header(pd)
  local plan = pd and shared.planName(pd.subscription, pd.tier) or ""
  local loading = type(status) == "table" and status.state == "loading"

  return ui.row({ gap = 10, align = "center" }, {
    ui.glyph({ name = "robot", size = 22, color = ACCENT }),
    ui.column({ gap = 0, flexGrow = 1 }, {
      ui.label({ text = noctalia.tr("title"), fontSize = 16, fontWeight = "bold" }),
      muted(plan, 11),
    }),
    ui.button({
      glyph = loading and "loader-2" or "refresh",
      variant = "ghost", controlSize = "sm",
      tooltip = noctalia.tr(loading and "refreshing" or "refresh"),
      enabled = not loading,
      onClick = shared.requestRefresh,
    }),
    ui.button({
      glyph = "settings", variant = "ghost", controlSize = "sm",
      tooltip = noctalia.tr("settings_tooltip"),
      onClick = function() noctalia.openSettings() end,
    }),
    ui.button({
      glyph = "x", variant = "ghost", controlSize = "sm",
      tooltip = noctalia.tr("close"),
      onClick = function() panel.close() end,
    }),
  })
end

-- ── profile selector (DMS hybrid: tabs up to 4 profiles, dropdown beyond) ──

local function selectProfile(name)
  selected = name
  noctalia.state.set("selected_profile", name)
  render()
end

local function profileSelector()
  local order = shared.profileOrder(usage)
  if #order <= 2 then return nil end -- "all" + a single profile: nothing to choose

  local function label(name)
    return (name == "all") and noctalia.tr("all") or name
  end

  if #order - 1 <= 4 then
    local tabs = {}
    for _, name in order do
      table.insert(tabs, ui.button({
        key = `profile-{name}`,
        text = label(name),
        variant = "ghost", controlSize = "sm", flexGrow = 1,
        selected = (name == selected),
        onClick = function() selectProfile(name) end,
      }))
    end
    return ui.row({ gap = 4, align = "center" }, tabs)
  end

  local options, idx = {}, 0
  for i, name in order do
    table.insert(options, label(name))
    if name == selected then idx = i - 1 end
  end
  return ui.select({
    key = "profile-select",
    options = options,
    selectedIndex = idx,
    controlSize = "sm",
    onChange = function(index)
      local i = (tonumber(index) or 0) + 1
      if order[i] then selectProfile(order[i]) end
    end,
  })
end

-- ── rate window card ────────────────────────────────────────────────────────
-- Usage bar over a thin time-elapsed bar: a fill longer than the clock bar is
-- quota burning ahead of time. Panels stretch children, so no fixed widths.

-- `w` is one row of shared.windows(): the 5-hour session, the plan-wide week, or
-- a week scoped to a single model. Its `status` already folds the vendor's own
-- severity into the pace reading, so a window Anthropic calls high never draws
-- calm here.
local function rateCard(w)
  local util = w.percent
  local p = w.pace
  local fill = paceColor(w.status, ACCENT)

  local rows = {
    ui.row({ align = "center", justify = "space_between" }, {
      heading(w.label),
      ui.label({ text = `{round(util)}% {noctalia.tr("used")}`, fontSize = 14, color = fill }),
    }),
    ui.progress({
      progress = math.max(0, math.min(1, util / 100)),
      fill = fill, track = "on_surface/0.14", radius = 4, height = 8,
    }),
  }
  if p.timeFrac ~= nil then
    table.insert(rows, ui.progress({
      progress = p.timeFrac,
      fill = "on_surface/0.45", track = "on_surface/0.10", radius = 2, height = 3,
    }))
  end

  -- "9% under pace · Resets in 3h 59m (19:30)". The clock time saves the reader
  -- doing the arithmetic when the window lands hours or days out.
  local caption = paceLabel(p)
  local cd = formatCountdown(w.resetIso)
  if cd then
    local clock = shared.formatResetClock(w.resetIso, true)
    local resets = `{noctalia.tr("resets_in")} {cd}`
    if clock then resets = `{resets} ({clock})` end
    caption = caption and `{caption} · {resets}` or resets
  end
  if caption then table.insert(rows, muted(caption, 11)) end
  return card(rows)
end

-- ── token consumption ───────────────────────────────────────────────────────

local function metricCol(label, tokens, cost, rate)
  return ui.column({ gap = 2, align = "center", flexGrow = 1 }, {
    muted(label, 12),
    ui.label({ text = formatTokens(tokens), fontSize = 16, fontWeight = "bold", color = ACCENT }),
    ui.label({ text = formatCost(cost, rate), fontSize = 11, color = "on_surface_variant" }),
  })
end

local function tokensCard(pd, rate, todayTokens)
  return card({
    heading(noctalia.tr("token_consumption")),
    ui.row({ gap = 8, align = "start" }, {
      metricCol(noctalia.tr("today"), todayTokens, pd.today_cost, rate),
      metricCol(noctalia.tr("week"), pd.week_tokens, pd.week_cost, rate),
      metricCol(noctalia.tr("month"), pd.month_tokens, pd.month_cost, rate),
    }),
  })
end

-- ── daily activity (Mon→Sun, hover a bar for its detail) ────────────────────

local function dailyChart(daily, dailyCosts, rate)
  if type(daily) ~= "table" then daily = {} end
  if type(dailyCosts) ~= "table" then dailyCosts = {} end
  local maxVal = 1
  for _, v in daily do maxVal = math.max(maxVal, tonumber(v) or 0) end

  local labels = {}
  for w in (noctalia.tr("days")):gmatch("[^,]+") do table.insert(labels, w) end

  local todayIdx = shared.todayIndex()
  local barH = 64

  local cols = {}
  for i = 1, 7 do
    local v = tonumber(daily[i]) or 0
    local h = (v > 0) and math.max(3, math.floor(v / maxVal * barH)) or 0
    local isToday = (i == todayIdx)
    local isHover = (i == hoveredDay)
    local fill = isToday and ACCENT or "on_surface/0.14"
    if isHover then fill = isToday and `{ACCENT}/0.75` or "on_surface/0.35" end

    table.insert(cols, ui.column({
      key = `day-{i}`, flexGrow = 1, gap = 4, align = "center",
      onHover = function(state)
        if state == "true" then
          hoveredDay = i
        elseif hoveredDay == i then
          hoveredDay = nil
        else
          return
        end
        render()
      end,
    }, {
      ui.column({ height = barH, justify = "end", align = "center" }, {
        ui.box({ width = isHover and 22 or 18, height = h, radius = 3, fill = fill }),
      }),
      ui.label({
        text = labels[i] or tostring(i), fontSize = 10,
        color = (isToday or isHover) and ACCENT or "on_surface_variant",
      }),
    }))
  end

  -- Header: title left; hovered day's detail right (empty label keeps the height stable).
  local detail = ""
  if hoveredDay then
    detail = noctalia.tr("day_detail", {
      day = labels[hoveredDay] or tostring(hoveredDay),
      tokens = formatTokens(daily[hoveredDay]),
      cost = formatCost(dailyCosts[hoveredDay], rate),
    })
  end

  return card({
    ui.row({ align = "center", justify = "space_between" }, {
      heading(noctalia.tr("daily_activity")),
      ui.label({ text = detail, fontSize = 11, color = ACCENT, maxLines = 1 }),
    }),
    ui.row({ gap = 6, align = "end" }, cols),
  })
end

-- ── per-model breakdown ─────────────────────────────────────────────────────

local function modelsCard(weekModels, weekTokens)
  local list = shared.modelList(weekModels)
  if #list == 0 then return nil end
  weekTokens = tonumber(weekTokens) or 0

  local rows = { heading(noctalia.tr("models_this_week")) }
  for _, m in list do
    local share = (weekTokens > 0) and math.min(1, m.tokens / weekTokens) or 0
    table.insert(rows, ui.column({ gap = 2, align = "stretch" }, {
      ui.row({ align = "center", justify = "space_between" }, {
        ui.label({ text = shortModelName(m.name), fontSize = 12 }),
        muted(`{formatTokens(m.tokens)} · {round(share * 100)}%`, 12),
      }),
      ui.progress({ progress = share, fill = ACCENT, track = "on_surface/0.14", height = 5, radius = 2 }),
    }))
  end
  return card(rows)
end

-- ── all-time footer ─────────────────────────────────────────────────────────

local function allTimeRow()
  local parts = {}
  local first = usage.first_session
  if type(first) == "string" and first ~= "" and first ~= "unknown" then
    table.insert(parts, `{noctalia.tr("since")} {first}`)
  end
  local s = tonumber(usage.alltime_sessions) or 0
  local m = tonumber(usage.alltime_messages) or 0
  if s > 0 then table.insert(parts, `{s} {noctalia.tr("sessions")}`) end
  if m > 0 then table.insert(parts, `{m} {noctalia.tr("msgs")}`) end
  if #parts == 0 then return nil end
  return ui.row({ gap = 6, align = "center", paddingH = 2 }, {
    ui.glyph({ name = "calendar", size = 14, color = "on_surface_variant" }),
    muted(table.concat(parts, " · "), 11),
  })
end

-- ── render ──────────────────────────────────────────────────────────────────

local function notice(glyph, text)
  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, {
    header(nil),
    card({
      ui.row({ gap = 8, align = "center" }, {
        ui.glyph({ name = glyph, size = 20, color = "on_surface_variant" }),
        ui.label({ text = text, color = "on_surface_variant", flexGrow = 1, maxLines = 3 }),
      }),
    }),
  }))
end

function render()
  if not isOpen then return end

  if type(status) == "table" and status.available == false then
    notice("robot-off", status.message ~= "" and status.message or noctalia.tr("unavailable"))
    return
  end

  local pd = shared.projection(usage, selected)
  if not pd then
    -- Unknown profile (renamed / removed): fall back to the aggregate.
    if type(usage) == "table" and selected ~= "all" then
      selected = "all"
      pd = shared.projection(usage, selected)
    end
    if not pd then
      notice("robot", noctalia.tr("loading"))
      return
    end
  end

  local rate = usage.usd_eur_rate
  local todayTokens = (type(pd.daily) == "table" and pd.daily[shared.todayIndex()]) or 0

  local top = { header(pd) }
  local selector = profileSelector()
  if selector then table.insert(top, selector) end

  local cards = {}
  for _, w in shared.windows(pd) do
    table.insert(cards, rateCard(w))
  end
  for _, c in {
    tokensCard(pd, rate, todayTokens),
    dailyChart(pd.daily, pd.daily_costs, rate),
  } do
    table.insert(cards, c)
  end
  local models = modelsCard(pd.week_models, pd.week_tokens)
  if models then table.insert(cards, models) end
  if pd.is_all then
    local footer = allTimeRow()
    if footer then table.insert(cards, footer) end
  end

  table.insert(top, ui.scroll({ flexGrow = 1, gap = 10, align = "stretch" }, cards))
  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, top))
end

-- ── wiring ──────────────────────────────────────────────────────────────────

noctalia.state.watch("usage", function(value)
  usage = value
  render()
end)

noctalia.state.watch("status", function(value)
  status = value
  render()
end)

noctalia.state.watch("selected_profile", function(value)
  selected = value or "all"
  render()
end)

function onOpen(_context)
  isOpen = true
  hoveredDay = nil
  usage = noctalia.state.get("usage")
  status = noctalia.state.get("status")
  selected = noctalia.state.get("selected_profile") or "all"
  -- Tick on second boundaries so the reset countdowns stay live while open.
  panel.setWantsSecondTicks(true)
  render()
end

function onClose()
  isOpen = false
  panel.setWantsSecondTicks(false)
end

function update()
  render()
end
