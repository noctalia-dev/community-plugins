--!nonstrict
-- Binance desktop card: the total with today's change, the return for the
-- panel's selected range, a 7-day value sparkline and today's top movers.
-- Keyless it says what the plugin does and offers to open the panel.
--
-- Presentation only, like the bar: everything comes from the service's
-- report. Click anywhere to open the panel.
--
-- The host tells a plugin desktop widget nothing about its box: with
-- box_width and box_height set, it scales the content uniformly to fit and
-- centres it (src/shell/desktop/desktop_widget.cpp, layout and
-- applyBackground). So each size has a fixed natural width, the 480 and
-- 260 px tiles minus the host's default 10 px background padding, and the
-- height of whatever there is to show. Unboxed, the tile is 480 px wide;
-- boxed, the card fills the box width whenever the box is at least as tall,
-- proportionally, as the card. Sections without data take no space.
-- "small" drops the sparkline and the movers.

local state = require("./lib/state.luau")
local allocation = require("./lib/allocation.luau")
local fmt = require("./ui/fmt.luau")
local parts = require("./ui/parts.luau")
local status = require("./ui/status.luau")

-- Type sizes match Noctalia's own desktop widgets at the 480 px tile: the
-- total like the weather temperature, lines like the calendar's text,
-- captions a step down. Small is roughly half, like its tile.
local SIZES = {
  small = { width = 240, total = 24, body = 14, caption = 12, glyph = 14 },
  large = { width = 460, total = 48, body = 17, caption = 15, glyph = 18 },
}
local MOVERS = 3
local SPARK_DAYS = 7
-- Holdings worth less than this (report currency) are dust, as in Holdings.
local DUST = 1

local size = SIZES[noctalia.getConfig("size")] or SIZES.large
local small = size == SIZES.small
local showMovers = not small and noctalia.getConfig("show_movers") ~= false
local showSpark = not small and noctalia.getConfig("show_sparkline") ~= false

local report = noctalia.state.get(state.REPORT)

local function tr(key: string, subst)
  return noctalia.tr(key, subst)
end

local function openPanel()
  noctalia.togglePanel(state.PANEL_ID)
end

-- Today's biggest moves among priced, non-dust, non-stablecoin holdings.
local function movers(holdings): { any }
  local list = {}
  for _, h in holdings or {} do
    if h.today and h.today.pct and h.value >= DUST and allocation.classOf(h.kind, h.asset) ~= "stable" then
      table.insert(list, h)
    end
  end
  table.sort(list, function(a, b)
    return math.abs(a.today.pct) > math.abs(b.today.pct)
  end)
  local out = {}
  for i = 1, math.min(MOVERS, #list) do
    out[i] = list[i]
  end
  return out
end

-- The last SPARK_DAYS daily values, oldest first.
local function lastDays(history): { number }?
  local days = history and history.days or {}
  if #days < 2 then
    return nil
  end
  local out = {}
  for i = math.max(1, #days - SPARK_DAYS + 1), #days do
    table.insert(out, days[i].value)
  end
  return out
end

-- The return the panel's range picker shows, else the return on deposits.
-- Percent only, so privacy has nothing to hide.
local function caption(text: string, color: string?, extra)
  return parts.caption(text, color, parts.merge({ fontSize = size.caption }, extra))
end

local function returnRow()
  local range = report.range
  local label, pct
  if range and range.error == nil and range.pct ~= nil then
    local name = tr(`panel.range.{range.preset}`)
    label = tr(if range.kind == "market" then "desktop.market_return" else "desktop.return", { range = name })
    pct = range.pct
  else
    local net = report.totals.netDeposit
    if net and net.pct ~= nil then
      label = tr("desktop.return_since", { day = fmt.day(net.since) })
      pct = net.pct
    end
  end
  if pct == nil then
    return nil
  end
  return ui.row({ gap = 8, align = "center", key = "return" }, {
    caption(label, nil, { maxLines = 1 }),
    ui.label({ text = fmt.pct(pct), fontSize = size.caption, fontWeight = "medium", color = fmt.signColor(fmt.pctSign(pct)) }),
  })
end

-- Right side of the header: the first error, else when data last arrived
-- while it is stale. An error title ("Keyring locked: account data
-- paused") doesn't fit the small card's 240 px beside the name, so small
-- shows the glyph alone; the panel has the details.
local function headerStatus(issue)
  if issue and issue.tone == "error" then
    return ui.row({ gap = 6, align = "center" }, parts.nodes(
      ui.glyph({ name = issue.glyph, size = size.glyph, color = "error" }),
      if small then nil else caption(issue.title, "error", { maxLines = 1 })
    ))
  end
  if type(report) == "table" and report.status.stale and report.status.lastRefreshAt then
    return caption(tr("desktop.updated", { ago = fmt.ago(report.status.lastRefreshAt) }), nil, { maxLines = 1 })
  end
  return nil
end

local function header(issue)
  return ui.row({ gap = 8, align = "center", key = "header" }, parts.nodes(
    ui.glyph({ name = "currency-bitcoin", size = size.glyph, color = "primary" }),
    caption(tr("desktop.title"), nil, { flexGrow = 1 }),
    headerStatus(issue)
  ))
end

-- One line and a way into the panel: keyless, first sync, or an error with
-- nothing to show yet.
local function message(glyph: string, text: string, color: string?, button: boolean)
  return ui.column({ gap = 10, key = "message" }, parts.nodes(
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = glyph, size = size.glyph, color = color or "on_surface_variant" }),
      ui.label({ text = text, fontSize = size.body, color = color or "on_surface", maxLines = 2, flexGrow = 1 }),
    }),
    if button
      then ui.row({}, {
        ui.button({
          text = tr("desktop.open"),
          glyph = "external-link",
          fontSize = size.body,
          variant = "outline",
          controlSize = if small then "sm" else "md",
          onClick = openPanel,
        }),
      })
      else nil
  ))
end

local function moversRow()
  local list = movers(report.holdings)
  if #list == 0 then
    return nil
  end
  -- Equal cells, so three long tickers ("1000SATS +12.34%") still fit.
  local chips = {}
  for _, h in list do
    local pct = h.today.pct
    table.insert(chips, ui.row({ gap = 6, align = "center", key = h.asset, flexGrow = 1 }, {
      ui.label({ text = h.asset, fontSize = size.body, fontWeight = "semibold" }),
      ui.label({ text = fmt.pct(pct), fontSize = size.body, color = fmt.signColor(fmt.pctSign(pct)) }),
    }))
  end
  return ui.column({ gap = 6, key = "movers" }, {
    caption(tr("desktop.movers")),
    ui.row({ gap = 8, align = "center" }, chips),
  })
end

local function portfolio()
  local totals = report.totals
  local currency, privacy = report.currency, report.privacy == true
  -- totals.today is what the bar and the Overview show too. Until it
  -- exists (no opening prices yet, or most of the value without one), a
  -- dimmed dash holds its place, as in the Overview.
  local today = ui.row({ gap = 8, align = "center" }, {
    if totals.today
      then parts.pnl(totals.today, currency, privacy, size.body)
      else ui.label({ text = "—", fontSize = size.body, fontWeight = "medium", color = "on_surface_variant" }),
    caption(tr("panel.overview.today"), nil, { fontSize = size.body }),
  })
  local numbers = ui.column({ gap = 6, key = "numbers" }, parts.nodes(
    ui.label({
      -- From a million up, "12,345,678.90 USDT" at 48 px is wider than the
      -- card; "12.35M USDT" is not.
      text = fmt.money(totals.value, currency, { privacy = privacy, compact = totals.value >= 1e6 }),
      fontSize = size.total,
      fontWeight = "bold",
      maxLines = 1,
    }),
    today,
    returnRow()
  ))
  -- Full width under the numbers: beside a 48 px total there is no room.
  local spark = if showSpark then lastDays(report.history) else nil
  return parts.nodes(
    numbers,
    if spark then parts.spark(spark, size.width - 12, 56, "spark") else nil,
    if showMovers then moversRow() else nil
  )
end

local function render()
  local body
  local issue = nil
  local dim = 1
  if type(report) ~= "table" then
    body = { message("loader-2", tr("desktop.starting"), nil, false) }
  else
    issue = status.issues(report)[1]
    if report.mode ~= "connected" then
      body = { message("plug-connected", tr("desktop.keyless"), nil, true) }
    elseif report.totals == nil then
      if issue and issue.tone == "error" then
        body = { message(issue.glyph, issue.title, "error", true) }
        issue = nil -- said in the body; the header needn't repeat it
      else
        body = { message("loader-2", tr("desktop.syncing"), nil, false) }
      end
    else
      body = portfolio()
      dim = if report.status.stale then 0.6 else 1
    end
  end

  -- Top-aligned, no fixed height: the card is as tall as its content.
  desktopWidget.render(ui.column({
    width = size.width,
    gap = if small then 8 else 12,
    padding = 6,
    onClick = openPanel,
  }, {
    header(issue),
    ui.column({ gap = if small then 6 else 14, opacity = dim }, body),
  }))
end

noctalia.state.watch(state.REPORT, function(value)
  report = value
  render()
end)

-- Data arrives through the watch; ticks only age "updated 2h ago".
function update()
  render()
end

noctalia.setUpdateInterval(30000)
render()
