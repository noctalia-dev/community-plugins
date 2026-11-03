--!nonstrict
-- Watchlist & Alerts tab. Works keyless: tickers come from public prices.
-- The watchlist has an add field and an Edit mode for reordering and
-- removal; each ticker offers a one-click alert. Alerts are listed with an
-- on/off toggle and edit/delete, and share one form for add and edit. Every
-- change is a command to the service, which owns prefs.json.

local state = require("../lib/state.luau")
local fmt = require("./fmt.luau")
local parts = require("./parts.luau")

local M = {}

local KINDS = { "above", "below", "move_pct" }
local COOLDOWNS = { 15, 60, 240, 1440 }

local function tr(key: string, subst)
  return noctalia.tr(key, subst)
end

local function indexOf(list, value): number?
  for i, v in list do
    if v == value then
      return i
    end
  end
  return nil
end

-- "BTCUSDT" -> "BTC/USDT" using the ticker's own split when known; a stock
-- ("EQ_AAPL") is just its ticker.
local function pairLabel(symbol: string, report): string
  if string.sub(symbol, 1, 3) == "EQ_" then
    return string.sub(symbol, 4)
  end
  for _, t in report.watchlist or {} do
    if t.symbol == symbol and t.base and t.quote then
      return `{t.base}/{t.quote}`
    end
  end
  return symbol
end

local function isStock(symbol: string?): boolean
  return symbol ~= nil and string.sub(symbol, 1, 3) == "EQ_"
end

function M.alertText(alert, report): string
  local pair = pairLabel(alert.symbol, report)
  if alert.kind == "move_pct" then
    -- Stocks move by their day change; crypto by the 24h ticker change.
    return tr(if isStock(alert.symbol) then "panel.alerts.text_move_stock" else "panel.alerts.text_move",
      { pair = pair, pct = string.format("%g%%", alert.value * 100) })
  end
  return tr(`panel.alerts.text_{alert.kind}`, { pair = pair, price = fmt.price(alert.value) })
end

local function cooldownLabel(minutes: number): string
  return tr("panel.alerts.every", { d = fmt.duration(minutes * 60000) })
end

-- ── Watchlist ─────────────────────────────────────────────────────────────

local function openAlertForm(ctx, fields)
  ctx.alertForm = {
    id = fields.id,
    symbol = fields.symbol,
    kind = fields.kind or "above",
    value = fields.value or "",
    cooldown = fields.cooldown or 60,
    seed = (ctx.alertForm and ctx.alertForm.seed or 0) + 1,
  }
  ctx.render()
end

local function tickerRow(ticker, index: number, count: number, report, ctx)
  local trailing
  if ctx.watchEdit then
    trailing = ui.row({ gap = 2, align = "center" }, {
      ui.button({
        glyph = "arrow-up",
        variant = "ghost",
        controlSize = "sm",
        enabled = index > 1,
        tooltip = tr("panel.watch.move_up"),
        onClick = function()
          state.watchMove(ticker.symbol, index - 1)
        end,
      }),
      ui.button({
        glyph = "arrow-down",
        variant = "ghost",
        controlSize = "sm",
        enabled = index < count,
        tooltip = tr("panel.watch.move_down"),
        onClick = function()
          state.watchMove(ticker.symbol, index + 1)
        end,
      }),
      ui.button({
        glyph = "trash",
        variant = "ghost",
        controlSize = "sm",
        tooltip = tr("panel.watch.remove"),
        onClick = function()
          state.watchRemove(ticker.symbol)
        end,
      }),
    })
  else
    trailing = ui.button({
      glyph = if (ticker.alerts or 0) > 0 then "bell-ringing" else "bell-plus",
      variant = "ghost",
      controlSize = "sm",
      tooltip = if (ticker.alerts or 0) > 0
        then noctalia.trp("panel.watch.alerts_count", ticker.alerts, { n = ticker.alerts })
        else tr("panel.watch.add_alert"),
      onClick = function()
        openAlertForm(ctx, { symbol = ticker.symbol, value = if ticker.price then (fmt.price(ticker.price):gsub(",", "")) else "" })
      end,
    })
  end

  local isStock = ticker.kind == "stock"
  local range
  if isStock then
    range = if ticker.note then tr(`panel.watch.stock_{ticker.note}`)
      elseif ticker.quoteStale or (ticker.session == "closed" and ticker.quoteAt) then tr("panel.watch.stock_stale", { ago = fmt.ago(ticker.quoteAt) })
      elseif ticker.price then tr("panel.watch.stock_quote")
      else tr("panel.watch.no_price")
  else
    range = if ticker.high24h and ticker.low24h
      then tr("panel.watch.range", { low = fmt.price(ticker.low24h), high = fmt.price(ticker.high24h) })
      else tr("panel.watch.no_price")
  end

  return ui.row({ gap = 8, align = "center", key = ticker.symbol, paddingV = 2 }, {
    ui.column({ gap = 1, width = 84 }, {
      ui.row({ gap = if isStock then 4 else 0, align = "end" }, {
        ui.label({ text = ticker.base or ticker.symbol, fontSize = 13, fontWeight = "semibold" }),
        if isStock
          then ui.label({ text = tr("panel.holdings.stock_tag"), fontSize = 9, fontWeight = "semibold", color = "on_surface_variant" })
          else ui.label({ text = if ticker.quote then "/" .. ticker.quote else "", fontSize = 10, color = "on_surface_variant" }),
      }),
      parts.caption(fmt.pct(ticker.change24h), fmt.signColor(fmt.pctSign(ticker.change24h))),
    }),
    parts.spark(ticker.spark, 64, 22),
    ui.column({ gap = 1, flexGrow = 1, align = "end" }, {
      -- Outside trading hours a stock shows its last quote, dimmed.
      ui.label({
        text = fmt.price(ticker.price),
        fontSize = 13,
        fontWeight = "medium",
        color = if isStock and (ticker.session == "closed" or ticker.quoteStale) then "on_surface_variant" else nil,
      }),
      if isStock and ticker.session and not ticker.note
        then ui.row({ gap = 6, align = "center" }, { parts.session(ticker.session), parts.caption(range, nil, { maxLines = 1 }) })
        else parts.caption(range, nil, { maxLines = if ticker.note then 2 else 1 }),
    }),
    trailing,
  })
end

local function addField(report, ctx)
  local function submit()
    local symbol = noctalia.string.trim(ctx.watchDraft or ""):upper():gsub("[/%-%s]", "")
    if symbol ~= "" then
      state.watchAdd(symbol)
    end
    ctx.watchDraft = ""
    ctx.watchSeed += 1
    ctx.render()
  end
  local notice = report.watchNotice
  local row = ui.row({ gap = 6, align = "center" }, {
    ui.input({
      key = `watch-input-{ctx.watchSeed}`,
      placeholder = tr("panel.watch.add_placeholder"),
      controlSize = "sm",
      flexGrow = 1,
      onChange = function(text)
        ctx.watchDraft = text
      end,
      onSubmit = submit,
    }),
    ui.button({ glyph = "plus", text = tr("panel.watch.add"), variant = "outline", controlSize = "sm", onClick = submit }),
  })
  return ui.column({ gap = 4, key = "watch-add" }, parts.nodes(
    row,
    if notice then parts.caption(tr(`panel.watch.notice_{notice.code}`, { symbol = notice.symbol }), "error", { maxLines = 2 }) else nil
  ))
end

-- ── Alerts ────────────────────────────────────────────────────────────────

local function alertRow(alert, report, ctx)
  local detail = cooldownLabel(alert.cooldownMin or 60)
  if alert.lastFiredAt then
    detail ..= " · " .. tr("panel.alerts.last_fired", { ago = fmt.ago(alert.lastFiredAt) })
  end
  return ui.row({ gap = 8, align = "center", key = alert.id, opacity = if alert.enabled then 1 else 0.6 }, {
    ui.toggle({
      checked = alert.enabled == true,
      onChange = function(value)
        state.alertUpdate(alert.id, { enabled = value == "true" })
      end,
    }),
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = M.alertText(alert, report), fontSize = 12, fontWeight = "medium", maxLines = 1 }),
      parts.caption(detail, nil, { maxLines = 1 }),
    }),
    ui.button({
      glyph = "pencil",
      variant = "ghost",
      controlSize = "sm",
      tooltip = tr("panel.alerts.edit"),
      onClick = function()
        openAlertForm(ctx, {
          id = alert.id,
          symbol = alert.symbol,
          kind = alert.kind,
          value = string.format("%g", if alert.kind == "move_pct" then alert.value * 100 else alert.value),
          cooldown = alert.cooldownMin,
        })
      end,
    }),
    ui.button({
      glyph = "trash",
      variant = "ghost",
      controlSize = "sm",
      tooltip = tr("panel.alerts.remove"),
      onClick = function()
        state.alertRemove(alert.id)
      end,
    }),
  })
end

local function alertForm(report, ctx)
  local form = ctx.alertForm
  local symbols = {}
  for _, t in report.watchlist or {} do
    table.insert(symbols, t.symbol)
  end
  if form.symbol and not indexOf(symbols, form.symbol) then
    table.insert(symbols, form.symbol)
  end
  if form.symbol == nil then
    form.symbol = symbols[1]
  end

  local symbolLabels = {}
  for i, symbol in symbols do
    symbolLabels[i] = pairLabel(symbol, report)
  end

  local kindLabels, cooldownLabels = {}, {}
  for i, kind in KINDS do
    kindLabels[i] = tr(if kind == "move_pct" and isStock(form.symbol) then "panel.alerts.kind_move_pct_stock" else `panel.alerts.kind_{kind}`)
  end
  for i, minutes in COOLDOWNS do
    cooldownLabels[i] = cooldownLabel(minutes)
  end

  local function save()
    local raw = noctalia.string.trim(tostring(form.value)):gsub(",", "")
    local number = tonumber(raw)
    if form.symbol == nil then
      form.error = tr("panel.alerts.need_symbol")
    elseif number == nil or number <= 0 then
      form.error = tr("panel.alerts.bad_value")
    else
      local value = if form.kind == "move_pct" then number / 100 else number
      if form.id then
        state.alertUpdate(form.id, { kind = form.kind, value = value, cooldownMin = form.cooldown })
      else
        state.alertAdd(form.symbol, form.kind, value, form.cooldown)
      end
      ctx.alertForm = nil
    end
    ctx.render()
  end

  local isMove = form.kind == "move_pct"
  return parts.card(parts.nodes(
    parts.title(tr(if form.id then "panel.alerts.edit_title" else "panel.alerts.new_title")),
    ui.row({ gap = 6, align = "center" }, {
      ui.select({
        key = "alert-symbol",
        options = if #symbols > 0 then symbolLabels else { tr("panel.alerts.need_symbol") },
        selectedIndex = (indexOf(symbols, form.symbol) or 1) - 1,
        enabled = form.id == nil and #symbols > 0,
        controlSize = "sm",
        flexGrow = 1,
        onChange = function(index)
          form.symbol = symbols[(tonumber(index) or 0) + 1]
          ctx.render()
        end,
      }),
      ui.select({
        key = "alert-kind",
        options = kindLabels,
        selectedIndex = (indexOf(KINDS, form.kind) or 1) - 1,
        controlSize = "sm",
        flexGrow = 1,
        onChange = function(index)
          form.kind = KINDS[(tonumber(index) or 0) + 1] or "above"
          ctx.render()
        end,
      }),
    }),
    ui.row({ gap = 6, align = "center" }, {
      ui.input({
        key = `alert-value-{form.seed}`,
        value = tostring(form.value),
        placeholder = tr(if isMove then "panel.alerts.value_pct" else "panel.alerts.value_price"),
        controlSize = "sm",
        flexGrow = 1,
        onChange = function(text)
          form.value = text
        end,
        onSubmit = save,
      }),
      parts.caption(if isMove then "%" else ""),
      ui.select({
        key = "alert-cooldown",
        options = cooldownLabels,
        selectedIndex = (indexOf(COOLDOWNS, form.cooldown) or 2) - 1,
        controlSize = "sm",
        width = 150,
        onChange = function(index)
          form.cooldown = COOLDOWNS[(tonumber(index) or 1) + 1] or 60
          ctx.render()
        end,
      }),
    }),
    if form.error then parts.caption(form.error, "error") else parts.caption(tr("panel.alerts.form_hint"), nil, { maxLines = 2 }),
    ui.row({ gap = 6, justify = "end" }, {
      ui.button({
        text = tr("panel.cancel"),
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          ctx.alertForm = nil
          ctx.render()
        end,
      }),
      ui.button({ text = tr("panel.save"), variant = "primary", controlSize = "sm", onClick = save }),
    })
  ), { key = "alert-form", fill = "surface_container/0.7" })
end

function M.render(report, ctx): { any }
  local watchlist = report.watchlist or {}
  local rows = {}
  for i, ticker in watchlist do
    if i > 1 then
      table.insert(rows, ui.separator({ color = "outline_variant/0.15", key = `sep-{ticker.symbol}` }))
    end
    table.insert(rows, tickerRow(ticker, i, #watchlist, report, ctx))
  end
  if #rows == 0 then
    table.insert(rows, parts.caption(tr("panel.watch.empty"), nil, { key = "empty" }))
  end

  local out = {
    parts.section(tr("panel.watch.title"), if #watchlist > 0
      then ui.button({
        text = tr(if ctx.watchEdit then "panel.watch.done" else "panel.watch.edit"),
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          ctx.watchEdit = not ctx.watchEdit
          ctx.render()
        end,
      })
      else nil, "watch-head"),
    addField(report, ctx),
    parts.card(rows, { key = "tickers", gap = 6, paddingV = 8 }),
  }

  table.insert(out, parts.section(tr("panel.alerts.title"), if ctx.alertForm == nil
    then ui.button({
      glyph = "plus",
      text = tr("panel.alerts.new"),
      variant = "ghost",
      controlSize = "sm",
      onClick = function()
        openAlertForm(ctx, {})
      end,
    })
    else nil, "alerts-head"))
  if ctx.alertForm then
    table.insert(out, alertForm(report, ctx))
  end
  local alertRows = {}
  for _, alert in report.alerts or {} do
    table.insert(alertRows, alertRow(alert, report, ctx))
  end
  if #alertRows > 0 then
    table.insert(out, parts.card(alertRows, { key = "alerts", gap = 8 }))
  elseif ctx.alertForm == nil then
    table.insert(out, parts.caption(tr("panel.alerts.empty"), nil, { key = "alerts-empty", maxLines = 2 }))
  end
  return out
end

return M
