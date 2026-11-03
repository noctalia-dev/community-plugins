--!nonstrict
-- Binance bar capsule. What it shows comes from the widget's settings:
-- the total value (default), today's P&L, one asset's price, or a cycle
-- through those every few seconds. Keyless, only prices exist: the chosen
-- assets that are in the watchlist, else one watchlist ticker (scroll to
-- step through the list). The style (full / value / icon) cycles on right
-- click and is kept in prefs by the service.
--
-- Presentation only. Problems stay quiet: stale numbers dim, and the glyph
-- turns into a lock, hourglass or warning, with the details in the tooltip.
-- Left click opens the panel, middle click refreshes.

local state = require("./lib/state.luau")
local fmt = require("./ui/fmt.luau")
local status = require("./ui/status.luau")

local GLYPH = "currency-bitcoin"
local GLYPH_SIZE = 15
local MODES = { "full", "value", "icon" }
local TICK_MS = 30000

local report = noctalia.state.get(state.REPORT)
local tickerIndex = 1

-- Widget settings. The widget is rebuilt when they change.
local show = noctalia.getConfig("show") or "total"
local cycleMs = math.max(3, tonumber(noctalia.getConfig("cycle_seconds")) or 10) * 1000
local chosen = {}
for _, name in noctalia.getConfig("assets") or {} do
  local symbol = noctalia.string.trim(tostring(name)):upper()
  if symbol ~= "" and not table.find(chosen, symbol) then
    table.insert(chosen, symbol)
  end
end
local viewIndex = 1

local function tr(key: string, subst)
  return noctalia.tr(key, subst)
end

-- Bar-sized price: whole units from 1 000 up, else fmt.price.
local function barPrice(value: number?): string
  if value ~= nil and value >= 1000 then
    return fmt.grouped(value, 0)
  end
  return fmt.price(value)
end

local function currentTicker()
  local list = report.watchlist or {}
  if #list == 0 then
    return nil
  end
  tickerIndex = math.clamp(tickerIndex, 1, #list)
  return list[tickerIndex]
end

-- The glyph doubles as the status light: the first issue replaces it.
local function statusGlyph(issue)
  if issue == nil then
    return ui.glyph({ name = GLYPH, size = GLYPH_SIZE })
  end
  return ui.glyph({
    name = issue.glyph,
    size = GLYPH_SIZE,
    color = if issue.tone == "error" then "error" else "on_surface_variant",
  })
end

local function tooltipRows(issues)
  local rows = {}
  local currency, privacy = report.currency, report.privacy == true
  if report.mode == "connected" and report.totals then
    local totals = report.totals
    table.insert(rows, { key = tr("bar.tooltip.total"), value = fmt.money(totals.value, currency, { privacy = privacy }) })
    if totals.today then
      local today = totals.today
      local text = if privacy
        then fmt.pct(today.pct)
        else fmt.money(today.pnl, currency, { signed = true }) .. (if today.pct then ` ({fmt.pct(today.pct)})` else "")
      if totals.todayPartial then
        text ..= " · " .. tr("bar.tooltip.partial")
      end
      table.insert(rows, { key = tr("bar.tooltip.today"), value = text })
    elseif totals.todayPartial then
      table.insert(rows, { key = tr("bar.tooltip.today"), value = "— · " .. tr("bar.tooltip.partial") })
    end
    table.insert(rows, { key = tr("bar.tooltip.crypto"), value = fmt.money(totals.crypto, currency, { privacy = privacy }) })
    if totals.stocks > 0 then
      table.insert(rows, { key = tr("bar.tooltip.stocks"), value = fmt.money(totals.stocks, currency, { privacy = privacy }) })
    end
  else
    for _, t in report.watchlist or {} do
      local value = fmt.price(t.price)
      if t.change24h then
        value ..= "  " .. fmt.pct(t.change24h)
      end
      table.insert(rows, { key = if t.base and t.quote then `{t.base}/{t.quote}` else t.symbol, value = value })
    end
  end
  for _, issue in issues do
    table.insert(rows, { key = tr("bar.tooltip.status"), value = issue.title })
  end
  if report.status.lastRefreshAt then
    table.insert(rows, { key = tr("bar.tooltip.updated"), value = fmt.ago(report.status.lastRefreshAt) })
  end
  if report.mode ~= "connected" then
    table.insert(rows, { key = "", value = tr("bar.tooltip.connect_hint") })
  end
  return rows
end

-- A chosen asset: a watchlist pair ("ETHBTC"), a watchlist base ("BTC"),
-- then a holding ("NVDA"). Keyless has no holdings.
local function findAsset(symbol: string)
  for _, t in report.watchlist or {} do
    if t.symbol == symbol then
      return t, nil
    end
  end
  for _, t in report.watchlist or {} do
    if t.base == symbol then
      return t, nil
    end
  end
  for _, h in report.holdings or {} do
    if h.asset == symbol then
      return nil, h
    end
  end
  return nil, nil
end

-- What the capsule can show now, in cycle order: "total", "today", or a
-- chosen asset's symbol. Keyless has no totals, so only assets remain.
local function views(): { string }
  local out = {}
  local connected = report.mode == "connected"
  if connected and (show == "total" or show == "cycle") then
    table.insert(out, "total")
  end
  if connected and (show == "today" or show == "cycle") then
    table.insert(out, "today")
  end
  if show == "price" or show == "cycle" then
    for _, symbol in chosen do
      -- Keyless, an asset outside the watchlist has no price at all.
      if connected or findAsset(symbol) ~= nil then
        table.insert(out, symbol)
        if show == "price" then
          break
        end
      end
    end
  end
  if #out == 0 and connected then
    table.insert(out, "total")
  end
  return out
end

-- Name, price and (full style) change for a ticker or a holding. Prices
-- are public, so privacy leaves them alone. A vertical bar drops the name
-- unless cycling, where the price alone would be ambiguous.
local function priceNodes(nodes, label: string?, price: number?, change: number?, mode: string, vertical: boolean, dim: number)
  if label and (not vertical or show == "cycle") then
    table.insert(nodes, ui.label({ text = label, fontWeight = "bold", opacity = dim }))
  end
  table.insert(nodes, ui.label({ text = barPrice(price), fontWeight = "medium", opacity = dim }))
  if mode == "full" and change then
    table.insert(nodes, ui.label({ text = fmt.pct(change, true, if vertical then 1 else nil), color = fmt.signColor(fmt.pctSign(change)), opacity = dim }))
  end
end

local function assetNodes(nodes, symbol: string, mode: string, vertical: boolean, dim: number)
  local ticker, holding = findAsset(symbol)
  if ticker then
    priceNodes(nodes, ticker.base or ticker.symbol, ticker.price, ticker.change24h, mode, vertical, dim)
  elseif holding then
    priceNodes(nodes, holding.asset, holding.price, holding.today and holding.today.pct, mode, vertical, dim)
  else
    -- Not in the watchlist or the holdings: say so instead of a stale number.
    priceNodes(nodes, symbol, nil, nil, mode, vertical, 0.6)
  end
end

local function totalNodes(nodes, view: string, mode: string, vertical: boolean, dim: number)
  local totals = report.totals
  if totals == nil then
    table.insert(nodes, ui.label({ text = "…", color = "on_surface_variant" }))
    return
  end
  local privacy = report.privacy == true
  local today = totals.today
  if view == "total" then
    table.insert(nodes, ui.label({
      text = fmt.money(totals.value, if vertical then nil else report.currency, {
        compact = true,
        short = vertical,
        privacy = privacy,
      }),
      fontWeight = "medium",
      opacity = dim,
    }))
    -- Cycling, today's P&L has a view of its own.
    if mode ~= "full" or today == nil or show == "cycle" then
      return
    end
  elseif today == nil then
    table.insert(nodes, ui.label({ text = "—", color = "on_surface_variant", opacity = dim }))
    return
  end

  local color = fmt.signColor(fmt.pnlSign(today))
  -- Today on its own: the amount leads in the full style, unless masked.
  if view == "today" and mode == "full" and not privacy and not vertical then
    table.insert(nodes, ui.label({
      text = fmt.money(today.pnl, report.currency, { signed = true, compact = true }),
      fontWeight = "medium",
      color = color,
      opacity = dim,
    }))
    if today.pct == nil then
      return
    end
  end
  table.insert(nodes, ui.label({
    text = if today.pct ~= nil then fmt.pct(today.pct, true, if vertical then 1 else nil)
      elseif privacy then fmt.MASK
      else fmt.money(today.pnl, report.currency, { signed = true, compact = true }),
    fontWeight = if view == "today" then "medium" else nil,
    color = color,
    opacity = dim,
  }))
end

local function render()
  local vertical = barWidget.isVertical()
  local container = if vertical then ui.column else ui.row

  if type(report) ~= "table" then
    barWidget.render(container({ gap = 4, align = "center" }, {
      ui.glyph({ name = GLYPH, size = GLYPH_SIZE, color = "on_surface_variant" }),
    }))
    barWidget.setTooltip(tr("bar.starting"))
    return
  end

  local issues = status.issues(report)
  local mode = report.barMode or "full"
  local dim = if report.status.stale then 0.6 else 1
  local nodes = { statusGlyph(issues[1]) }

  if mode ~= "icon" then
    local list = views()
    if #list > 0 then
      viewIndex = (viewIndex - 1) % #list + 1
      local view = list[viewIndex]
      if view == "total" or view == "today" then
        totalNodes(nodes, view, mode, vertical, dim)
      else
        assetNodes(nodes, view, mode, vertical, dim)
      end
    else
      local ticker = currentTicker()
      if ticker then
        priceNodes(nodes, ticker.base or ticker.symbol, ticker.price, ticker.change24h, mode, vertical, dim)
      end
    end
  end

  barWidget.render(container({ gap = if vertical then 2 else 6, align = "center" }, nodes))
  barWidget.setTooltip(tooltipRows(issues))
end

noctalia.state.watch(state.REPORT, function(value)
  report = value
  render()
end)

-- Data arrives through the watch. Ticks age "updated 2m ago" and, when
-- cycling, move to the next view.
function update()
  if show == "cycle" then
    viewIndex += 1
  end
  render()
end

function onClick()
  noctalia.togglePanel(state.PANEL_ID)
end

-- Right click cycles the style: full -> value -> icon -> full.
function onRightClick()
  if type(report) ~= "table" then
    return
  end
  local index = table.find(MODES, report.barMode or "full") or 1
  state.setBarMode(MODES[index % #MODES + 1])
end

-- Needs `middle = "none"` in [widget.actions]; the built-in binding opens
-- the widget's settings otherwise.
function onMiddleClick()
  state.requestRefresh()
end

-- The wheel steps through the cycle's views, or keyless without chosen
-- assets in the watchlist, through the watchlist. One step per gesture.
function onScroll(axis, steps, startsGesture)
  if axis ~= "vertical" or not startsGesture or type(report) ~= "table" then
    return
  end
  local delta = if steps > 0 then 1 else -1
  local count = #views()
  if count > 1 then
    viewIndex = (viewIndex - 1 + delta) % count + 1
  elseif count == 0 then
    local tickers = #(report.watchlist or {})
    if tickers < 2 then
      return
    end
    tickerIndex = (tickerIndex - 1 + delta) % tickers + 1
  else
    return
  end
  render()
end

noctalia.setUpdateInterval(if show == "cycle" then cycleMs else TICK_MS)
render()
