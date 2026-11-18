--!nonstrict
-- /bn launcher: price lookup and portfolio summary.
--
--   /bn          portfolio summary (connected), then the watchlist
--   /bn sol      matches from the watchlist and holdings at once, then the
--                service's public lookup when it answers on the lookup key
--
-- Selecting a price copies it; selecting a pair that is not watched adds it
-- to the watchlist; the summary opens the panel. Amounts are masked while
-- privacy is on.

local state = require("./lib/state.luau")
local fmt = require("./ui/fmt.luau")

local GLYPH = "currency-bitcoin"

local report = noctalia.state.get(state.REPORT)
local query = "" -- trimmed, as sent to the service
local rawQuery = "" -- as typed; setResults must echo it

local function tr(key: string, subst)
  return noctalia.tr(key, subst)
end

local function privacy(): boolean
  return type(report) == "table" and report.privacy == true
end

local function tickerResult(t, score: number, watched: boolean)
  local subtitle = {}
  if t.change24h then
    table.insert(subtitle, tr("launcher.change", { pct = fmt.pct(t.change24h) }))
  end
  if t.high24h and t.low24h then
    table.insert(subtitle, tr("launcher.range", { low = fmt.price(t.low24h), high = fmt.price(t.high24h) }))
  end
  if not watched then
    table.insert(subtitle, tr("launcher.watch_hint"))
  elseif t.price then
    table.insert(subtitle, tr("launcher.copy_hint"))
  end
  local pair = if t.base and t.quote then `{t.base}/{t.quote}` else t.symbol
  return {
    id = if watched and t.price then `copy:{fmt.price(t.price)}` elseif watched then "panel" else `watch:{t.symbol}`,
    title = `{pair}  {fmt.price(t.price)}`,
    subtitle = table.concat(subtitle, " · "),
    glyph = if t.change24h and t.change24h < 0 then "trending-down" else "trending-up",
    score = score,
  }
end

local function summaryResult()
  local totals = report.totals
  local currency = report.currency
  local parts = {}
  if totals.today then
    local today = totals.today
    local text = if privacy() then fmt.pct(today.pct)
      else fmt.money(today.pnl, currency, { signed = true }) .. (if today.pct then ` ({fmt.pct(today.pct)})` else "")
    table.insert(parts, tr("launcher.today", { value = text }))
  end
  table.insert(parts, tr("launcher.crypto", { value = fmt.money(totals.crypto, currency, { privacy = privacy() }) }))
  if totals.stocks > 0 then
    table.insert(parts, tr("launcher.stocks", { value = fmt.money(totals.stocks, currency, { privacy = privacy() }) }))
  end
  return {
    id = "panel",
    title = tr("launcher.portfolio", { value = fmt.money(totals.value, currency, { privacy = privacy() }) }),
    subtitle = table.concat(parts, " · "),
    glyph = GLYPH,
    score = 1000,
  }
end

local function holdingResult(h, score: number)
  local currency = report.currency
  local detail = `{fmt.qty(h.qty, privacy())} {h.asset}`
  if h.today then
    detail ..= " · " .. tr("launcher.today", { value = fmt.pct(h.today.pct) })
  end
  return {
    id = "panel",
    title = tr("launcher.holding", { asset = h.asset, value = fmt.money(h.value, currency, { privacy = privacy() }) }),
    subtitle = detail,
    glyph = if h.kind == "stock" then "chart-candle" else "coin",
    score = score,
  }
end

local function results(text: string)
  local out = {}
  local seen = {}
  local hasReport = type(report) == "table"
  local watched = {}
  for _, t in (if hasReport then report.watchlist else nil) or {} do
    watched[t.symbol] = true
  end

  if text == "" then
    if hasReport and report.mode == "connected" and report.totals then
      table.insert(out, summaryResult())
    end
    for i, t in (if hasReport then report.watchlist else nil) or {} do
      table.insert(out, tickerResult(t, 500 - i, true))
    end
    if #out == 0 then
      table.insert(out, { id = "panel", title = tr("launcher.empty_title"), subtitle = tr("launcher.empty_hint"), glyph = GLYPH })
    end
    return out
  end

  if hasReport then
    for _, t in report.watchlist or {} do
      local score = noctalia.fuzzyScore(text, t.symbol)
      if score then
        seen[t.symbol] = true
        table.insert(out, tickerResult(t, score + 100, true))
      end
    end
    for _, h in report.holdings or {} do
      local score = noctalia.fuzzyScore(text, h.asset .. " " .. (h.name or ""))
      if score then
        table.insert(out, holdingResult(h, score + 50))
      end
    end
  end

  -- The service's public lookup for this exact query, when it has answered.
  local lookup = noctalia.state.get(state.LOOKUP)
  if type(lookup) == "table" and lookup.query == text then
    if lookup.error then
      table.insert(out, {
        id = "panel",
        title = tr("launcher.lookup_failed"),
        subtitle = fmt.errorTitle(lookup.error.code),
        glyph = "alert-circle",
        score = -1,
      })
    end
    for i, t in lookup.results or {} do
      if not seen[t.symbol] then
        table.insert(out, tickerResult(t, 10 - i, watched[t.symbol] == true))
      end
    end
    if #out == 0 then
      table.insert(out, { id = "noop", title = tr("launcher.no_match", { query = text }), glyph = "search" })
    end
  else
    table.insert(out, { id = "noop", title = tr("launcher.searching", { query = text }), glyph = "loader-2", score = -2 })
  end
  return out
end

function onQuery(text)
  rawQuery = text
  query = noctalia.string.trim(text)
  launcher.setResults(text, results(query))
  if query ~= "" then
    state.lookup(query)
  end
end

function onActivate(id)
  if id == "panel" then
    noctalia.togglePanel(state.PANEL_ID)
  elseif id:sub(1, 5) == "copy:" then
    noctalia.copyToClipboard((id:sub(6):gsub(",", "")), "text/plain")
  elseif id:sub(1, 6) == "watch:" then
    state.watchAdd(id:sub(7))
  end
end

noctalia.state.watch(state.REPORT, function(value)
  report = value
end)

-- Late answers: re-publish when the lookup for the current query lands.
noctalia.state.watch(state.LOOKUP, function(value)
  if type(value) == "table" and value.query == query then
    launcher.setResults(rawQuery, results(query))
  end
end)
