--!nonstrict
-- Overview tab: total balance and today's P&L, the return since deposits
-- were first covered, and the value chart with its range picker. Keyless, it
-- explains the plugin and offers to connect, above a glance at the watchlist.

local state = require("../lib/state.luau")
local allocation = require("../lib/allocation.luau")
local driftLib = require("../lib/drift.luau")
local fmt = require("./fmt.luau")
local parts = require("./parts.luau")

local M = {}

local PRESETS = { "7d", "30d", "ytd", "all" }
local DAY_PATTERN = "^%d%d%d%d%-%d%d%-%d%d$"

local function tr(key: string, subst)
  return noctalia.tr(key, subst)
end

-- ── Connected ─────────────────────────────────────────────────────────────

-- One color per asset class, in allocation.ORDER. Theme roles only; none
-- of them is the gain or loss color.
local CLASS_COLORS = { crypto = "primary", stocks = "tertiary", stable = "secondary", other = "outline_variant" }

-- The split by asset class: a segmented bar (Noctalia's UI has no arcs, so
-- no donut), then one column per class with its share always shown and its
-- amount masked under privacy. The three lines per class match the old
-- crypto/stocks split, so the chart moves down by the 6 px bar only.
local function allocationView(report)
  local totals = report.totals
  local slices = allocation.split(report.holdings or {})
  if #slices == 0 and totals.value > 0 then
    -- Holdings not listed yet: the totals still split crypto and stocks.
    for _, id in { "crypto", "stocks" } do
      local value = totals[id]
      if value > 0 then
        table.insert(slices, { id = id, value = value, share = value / totals.value })
      end
    end
  end
  if #slices == 0 then
    return nil
  end
  local segments, columns = {}, {}
  for _, slice in slices do
    local color = CLASS_COLORS[slice.id]
    local name = tr(`panel.overview.class.{slice.id}`)
    table.insert(segments, ui.box({
      key = slice.id,
      fill = color,
      height = 6,
      radius = 3,
      -- Thousandths, so a small share still gets a sliver.
      flexGrow = math.max(1, math.floor(slice.share * 1000 + 0.5)),
      tooltip = `{name} {fmt.share(slice.share)}`,
    }))
    table.insert(columns, ui.column({ gap = 2, flexGrow = 1, key = slice.id }, {
      ui.row({ gap = 5, align = "center" }, {
        ui.box({ width = 7, height = 7, radius = 4, fill = color }),
        parts.caption(name, nil, { maxLines = 1 }),
      }),
      -- Compact: four "12,345.67 USDT" columns don't fit 460 px.
      ui.label({ text = fmt.money(slice.value, report.currency, { compact = true, privacy = report.privacy }), fontSize = 13, fontWeight = "medium" }),
      parts.caption(fmt.share(slice.share)),
    }))
  end
  return ui.column({ gap = 8, key = "allocation" }, {
    ui.row({ gap = 2, height = 6 }, segments),
    ui.row({ gap = 12 }, columns),
  })
end

local function statusLabel(r, off: boolean)
  return ui.label({
    text = if off
      then tr(if r.diff > 0 then "panel.overview.drift.over" else "panel.overview.drift.under", { pts = string.format("%.1f", math.abs(r.diff) * 100) })
      else tr("panel.overview.drift.on_target"),
    fontSize = 11,
    fontWeight = if off then "semibold" else "normal",
    color = if off then "error" else "on_surface_variant",
    width = 84,
    textAlign = "end",
  })
end

-- Share, target and status columns, shared by class and holding rows.
local function targetColumns(r, d)
  return {
    ui.label({ text = fmt.share(r.share), fontSize = 12, fontWeight = "medium" }),
    parts.caption(tr("panel.overview.drift.target", { target = fmt.share(r.target) }), nil, { width = 80, textAlign = "end" }),
    statusLabel(r, table.find(d.off, r.id) ~= nil),
  }
end

-- A holding's target row, indented under its class; clicking it edits it.
local function assetRow(a, d, ctx)
  local cells = {
    ui.column({ width = 15 }, {}), -- indents the holding under its class
    ui.label({ text = a.asset, fontSize = 12, color = "on_surface", flexGrow = 1 }),
  }
  for _, cell in targetColumns(a, d) do
    table.insert(cells, cell)
  end
  return ui.row({
    gap = 8,
    align = "center",
    key = `asset-{a.id}`,
    tooltip = tr("panel.overview.drift.asset_edit", { asset = a.asset }),
    onClick = function()
      ctx.targetForm = { edit = true, key = a.id, value = string.format("%g", math.floor(a.target * 10000 + 0.5) / 100), seed = (ctx.targetForm and ctx.targetForm.seed or 0) + 1 }
      ctx.render()
    end,
  }, cells)
end

-- Add or edit one holding's target: the holding (fixed when editing), its
-- share of the portfolio in percent, then save, remove and cancel.
local function targetForm(report, d, ctx)
  local form = ctx.targetForm
  local editing = form.edit == true
  local keys, labels = {}, {}
  if editing then
    keys = { form.key }
  else
    local targeted = {}
    for _, a in d.assets do
      targeted[a.id] = true
    end
    for _, h in report.holdings or {} do
      local k = driftLib.key(h.kind, h.asset)
      if not targeted[k] and not table.find(keys, k) and (h.value or 0) > 0 then
        table.insert(keys, k)
      end
    end
  end
  for i, k in keys do
    labels[i] = if string.sub(k, 1, 3) == "EQ_" then string.sub(k, 4) else k
  end
  if form.key == nil or not table.find(keys, form.key) then
    form.key = keys[1]
  end

  -- The selected holding's share now, as the hint in the empty field.
  local shareNow = nil
  for _, h in report.holdings or {} do
    if form.key and driftLib.key(h.kind, h.asset) == form.key and d.total > 0 then
      shareNow = (shareNow or 0) + (h.value or 0) / d.total
    end
  end

  local function save()
    local pct = driftLib.parseAmount(tostring(form.value))
    if form.key == nil then
      form.error = tr("panel.overview.drift.asset_none")
    elseif pct == nil or pct <= 0 or pct > 100 then
      form.error = tr("panel.overview.drift.asset_bad")
    else
      state.setAssetTarget(form.key, pct / 100)
      ctx.targetForm = nil
    end
    ctx.render()
  end

  return ui.column({ gap = 6, key = "target-form" }, parts.nodes(
    ui.row({ gap = 6, align = "center" }, parts.nodes(
      ui.select({
        key = `target-asset-{form.seed}`,
        options = if #keys > 0 then labels else { tr("panel.overview.drift.asset_none") },
        selectedIndex = (table.find(keys, form.key) or 1) - 1,
        enabled = not editing and #keys > 0,
        controlSize = "sm",
        flexGrow = 1,
        onChange = function(index)
          form.key = keys[(tonumber(index) or 0) + 1]
          ctx.render()
        end,
      }),
      ui.input({
        key = `target-value-{form.seed}`,
        value = tostring(form.value or ""),
        placeholder = if shareNow then tr("panel.overview.drift.asset_now", { share = fmt.share(shareNow) }) else tr("panel.overview.drift.asset_placeholder"),
        controlSize = "sm",
        width = 70,
        onChange = function(text)
          form.value = text
        end,
        onSubmit = save,
      }),
      parts.caption("%")
    )),
    if form.error then parts.caption(form.error, "error") else nil,
    ui.row({ gap = 6, align = "center" }, parts.nodes(
      ui.button({ text = tr("panel.overview.drift.asset_save"), variant = "primary", controlSize = "sm", enabled = form.key ~= nil, onClick = save }),
      if editing
        then ui.button({
          text = tr("panel.overview.drift.asset_remove"),
          variant = "ghost",
          controlSize = "sm",
          onClick = function()
            state.setAssetTarget(form.key, nil)
            ctx.targetForm = nil
            ctx.render()
          end,
        })
        else nil,
      ui.button({
        text = tr("panel.overview.drift.asset_cancel"),
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          ctx.targetForm = nil
          ctx.render()
        end,
      })
    ))
  ))
end

-- An estimate to buy: two decimals from 1 up, six below ("1.62", "0.004123").
local function roughQty(q: number, privacy: boolean): string
  if privacy then
    return fmt.MASK
  end
  local text = string.format(if q >= 1 then "%.2f" else "%.6f", q):gsub("0+$", ""):gsub("%.$", "")
  return text
end

local function planLabel(step): string
  if step.asset then
    return step.asset
  end
  local class = tr(`panel.overview.class.{step.class}`)
  return if step.rest then tr("panel.overview.drift.rest", { class = class }) else class
end

-- Target allocation: each class against its target with its targeted
-- holdings under it, then a deposit planner that splits new money toward
-- what is below target.
local function driftCard(report, ctx)
  local d = report.drift
  if d == nil then
    return nil
  end
  local currency, privacy = report.currency, report.privacy
  local rows = {}
  local shown: { [string]: boolean } = {}
  for _, r in d.rows do
    local hasAssets = false
    for _, a in d.assets do
      hasAssets = hasAssets or a.class == r.id
    end
    -- A class you don't target (weight 0) only matters once it drifts.
    if r.target == 0 and not hasAssets and not table.find(d.off, r.id) then
      continue
    end
    local cells = {
      ui.box({ width = 7, height = 7, radius = 4, fill = CLASS_COLORS[r.id] }),
      ui.label({ text = tr(`panel.overview.class.{r.id}`), fontSize = 12, color = "on_surface", flexGrow = 1 }),
    }
    for _, cell in targetColumns(r, d) do
      table.insert(cells, cell)
    end
    table.insert(rows, ui.row({ gap = 8, align = "center", key = r.id }, cells))
    for _, a in d.assets do
      if a.class == r.id then
        table.insert(rows, assetRow(a, d, ctx))
        shown[a.id] = true
      end
    end
  end
  for _, a in d.assets do
    if not shown[a.id] then
      table.insert(rows, assetRow(a, d, ctx))
    end
  end
  for _, id in d.crowded do
    table.insert(rows, parts.caption(tr("panel.overview.drift.crowded", { class = tr(`panel.overview.class.{id}`) }), "error", { key = `crowded-{id}`, maxLines = 2 }))
  end
  if ctx.targetForm then
    table.insert(rows, targetForm(report, d, ctx))
  else
    table.insert(rows, ui.button({
      key = "add-target",
      text = tr("panel.overview.drift.asset_add"),
      glyph = "plus",
      variant = "ghost",
      controlSize = "sm",
      contentAlign = "start",
      onClick = function()
        ctx.targetForm = { value = "", seed = 1 }
        ctx.render()
      end,
    }))
  end

  local amount = driftLib.parseAmount(ctx.depositDraft or "")
  local planRows = {}
  if #d.rows == 0 and #d.assets == 0 then
    table.insert(planRows, parts.caption(tr("panel.overview.drift.no_targets"), nil, { maxLines = 2 }))
  elseif amount == nil or amount <= 0 then
    table.insert(planRows, parts.caption(tr("panel.overview.drift.plan_empty"), nil, { maxLines = 2 }))
  else
    local plan = driftLib.plan(d, amount)
    if #plan == 0 then
      table.insert(planRows, parts.caption(tr("panel.overview.drift.plan_none"), nil, { maxLines = 2 }))
    end
    local prices = {}
    for _, h in report.holdings or {} do
      if h.price and h.price > 0 then
        prices[driftLib.key(h.kind, h.asset)] = h.price
      end
    end
    for _, step in plan do
      local price = if step.asset then prices[step.id] else nil
      table.insert(planRows, ui.row({ gap = 8, align = "center", key = `plan-{step.id}` }, parts.nodes(
        ui.glyph({ name = "arrow-right", size = 12, color = CLASS_COLORS[step.class] }),
        ui.label({ text = planLabel(step), fontSize = 12, flexGrow = 1 }),
        -- What the amount buys at today's price: "≈ 1.62 sh", "≈ 0.0041 BTC".
        if price
          then parts.caption(tr("panel.overview.drift.plan_qty", {
            qty = if string.sub(step.id, 1, 3) == "EQ_"
              then tr("panel.holdings.shares", { qty = roughQty(step.amount / price, privacy) })
              else `{roughQty(step.amount / price, privacy)} {step.asset}`,
          }))
          else nil,
        ui.label({ text = fmt.money(step.amount, currency, { privacy = privacy }), fontSize = 12, fontWeight = "semibold" })
      )))
    end
    local spent = 0
    for _, step in plan do
      spent += step.amount
    end
    if #plan > 0 and amount - spent > amount * 0.001 then
      table.insert(planRows, parts.caption(tr("panel.overview.drift.plan_left", { amount = fmt.money(amount - spent, currency, { privacy = privacy }) }), nil, { maxLines = 2 }))
    end
  end

  return parts.card(parts.nodes(
    parts.section(tr("panel.overview.drift.title"), ui.button({
      text = tr("panel.overview.drift.edit"),
      variant = "ghost",
      controlSize = "sm",
      onClick = function()
        ctx.openSettings()
      end,
    })),
    ui.column({ gap = 6, tooltip = tr("panel.overview.drift.band_tooltip", { band = string.format("%g", d.band * 100) }) }, rows),
    ui.separator({ color = "outline_variant/0.2" }),
    ui.row({ gap = 8, align = "center" }, {
      parts.title(tr("panel.overview.drift.next_deposit"), { flexGrow = 1 }),
      ui.input({
        key = `deposit-{ctx.depositSeed or 0}`,
        value = ctx.depositDraft or "",
        placeholder = tr("panel.overview.drift.plan_placeholder", { currency = currency }),
        controlSize = "sm",
        width = 170,
        onChange = function(text)
          ctx.depositDraft = text
          ctx.render()
        end,
      }),
    }),
    ui.column({ gap = 4 }, planRows),
    parts.caption(tr("panel.overview.drift.plan_hint"), nil, { maxLines = 2 })
  ), { key = "drift" })
end

local function hero(report, ctx)
  local totals = report.totals
  local currency, privacy = report.currency, report.privacy

  local todayRow
  if totals.today or totals.todayPartial then
    -- Partial with no figure: most of the value has no basis yet, so a
    -- neutral dash and the tooltip say why.
    todayRow = ui.row({ gap = 6, align = "center" }, parts.nodes(
      if totals.today
        then parts.pnl(totals.today, currency, privacy, 13)
        else ui.label({ text = "—", fontSize = 13, fontWeight = "medium", color = "on_surface_variant" }),
      parts.caption(tr("panel.overview.today")),
      if totals.todayPartial
        then ui.row({ tooltip = tr("panel.overview.today_partial_tooltip") }, {
          ui.glyph({ name = "info-circle", size = 13, color = "on_surface_variant" }),
        })
        else nil
    ))
  else
    todayRow = parts.caption(tr("panel.overview.today_pending"))
  end

  local split = allocationView(report)
  local children = parts.nodes(
    parts.caption(tr("panel.overview.total", { currency = currency })),
    ui.label({
      text = fmt.money(totals.value, currency, { privacy = privacy }),
      fontSize = 28,
      fontWeight = "bold",
      color = "on_surface",
    }),
    -- Decision 2026-10-19: USDT shows a dollar line like the Binance app;
    -- stocks are USD-quoted and treated at par.
    if currency == "USDT" and not privacy
      then parts.caption(tr("panel.overview.approx_usd", { value = fmt.money(totals.value, "USD") }))
      else nil,
    todayRow,
    if split then ui.separator({ color = "outline_variant/0.2" }) else nil,
    split
  )

  -- Return against net deposits. Until flows are synced, or when there are
  -- none, say so.
  local net = totals.netDeposit
  local syncing = report.status.busyWhat == "flows"
  local syncButton = ui.button({
    text = tr(if syncing then "panel.busy.flows" else "panel.overview.sync_now"),
    glyph = if syncing then "loader-2" else "refresh",
    variant = "outline",
    controlSize = "sm",
    enabled = not syncing,
    onClick = function()
      state.requestRefresh("flows")
    end,
  })
  if net then
    local rows = {
      ui.row({ align = "center", gap = 8 }, {
        parts.caption(tr("panel.overview.net_since", { day = fmt.day(net.since, true) }), nil, { flexGrow = 1, fontSize = 12 }),
        if net.pnl ~= nil then parts.pnl(net, currency, privacy, 12) else parts.caption(tr("panel.overview.net_unavailable")),
      }),
    }
    if net.unavailable then
      table.insert(rows, parts.caption(tr(`panel.overview.unavailable.{net.unavailable}`), nil, { maxLines = 3 }))
    end
    if net.uncovered and #net.uncovered > 0 then
      local names = {}
      for _, id in net.uncovered do
        local key = `panel.uncovered.{id}`
        local text = tr(key)
        table.insert(names, if text == key then id else text)
      end
      table.insert(rows, parts.caption(tr("panel.overview.net_uncovered", { list = table.concat(names, ", ") }), nil, { maxLines = 3 }))
    end
    table.insert(rows, ui.row({ justify = "end" }, { syncButton }))
    table.insert(children, ui.separator({ color = "outline_variant/0.2" }))
    table.insert(children, ui.column({ gap = 4 }, rows))
  elseif table.find(report.gaps or {}, "flows_pending") or table.find(report.gaps or {}, "no_flows") then
    local text = if table.find(report.gaps or {}, "no_flows") then "panel.overview.net_none" else "panel.overview.net_pending"
    table.insert(children, ui.row({ align = "center", gap = 8 }, {
      parts.caption(tr(text), nil, { maxLines = 2, flexGrow = 1 }),
      syncButton,
    }))
  end

  return parts.card(children, { key = "hero", gap = 8, padding = 14 })
end

-- Days of the chart: the selected range, else the whole ledger.
local function chartDays(report)
  local history = report.history
  local range = report.range
  local days = history.days or {}
  if range == nil or range.error then
    return days
  end
  local out = {}
  for _, d in days do
    if d.day >= range.from and d.day <= range.to then
      table.insert(out, d)
    end
  end
  return if #out >= 2 then out else days
end

local function rangeHeader(report, ctx, days)
  local currency, privacy = report.currency, report.privacy
  local hovered = ctx.chartHover and days[ctx.chartHover]
  if hovered then
    return ui.row({ align = "center", gap = 8, key = "range-head" }, {
      parts.title(fmt.day(hovered.day), { flexGrow = 1 }),
      ui.label({
        text = fmt.money(hovered.value, currency, { privacy = privacy }),
        fontSize = 13,
        fontWeight = "semibold",
      }),
    })
  end

  local range = report.range
  if range == nil then
    return parts.title(tr("panel.overview.history"), { key = "range-head" })
  end
  if range.error == "outside_coverage" then
    return parts.caption(tr("panel.overview.range_outside", { from = fmt.day(report.history.from) }), "error", { key = "range-head" })
  end
  local label = tr(if range.kind == "market" then "panel.overview.market_return" else "panel.overview.return")
  return ui.row({ align = "center", gap = 8, key = "range-head" }, {
    ui.row({
      gap = 4,
      align = "center",
      flexGrow = 1,
      tooltip = tr(if range.kind == "market" then "panel.overview.market_tooltip" else "panel.overview.net_tooltip"),
    }, {
      parts.title(label),
      ui.glyph({ name = "info-circle", size = 12, color = "on_surface_variant" }),
    }),
    parts.pnl(range, currency, privacy, 13),
  })
end

local function presetOptions(report, ctx)
  local available = {}
  for _, p in report.history.presets or {} do
    available[p] = true
  end
  local options = {}
  for _, p in PRESETS do
    table.insert(options, {
      id = p,
      label = tr(`panel.range.{p}`),
      enabled = available[p] == true,
      tooltip = if available[p] then nil else tr("panel.range.unavailable", { from = fmt.day(report.history.from) }),
    })
  end
  table.insert(options, { id = "custom", label = tr("panel.range.custom") })
  return options
end

local function customForm(report, ctx)
  local history = report.history
  local custom = ctx.custom
  local function apply()
    local from, to = noctalia.string.trim(custom.from), noctalia.string.trim(custom.to)
    if not from:match(DAY_PATTERN) or not to:match(DAY_PATTERN) then
      custom.error = tr("panel.range.bad_format")
    elseif from >= to then
      custom.error = tr("panel.range.bad_order")
    elseif from < history.from or to > history.to then
      custom.error = tr("panel.range.bad_bounds", { from = history.from, to = history.to })
    else
      custom.error = nil
      ctx.chartHover = nil
      state.setRange("custom", from, to)
    end
    ctx.render()
  end
  return ui.column({ gap = 6, key = "custom-range" }, parts.nodes(
    ui.row({ gap = 6, align = "center" }, {
      ui.input({
        key = `range-from-{custom.seed}`,
        value = custom.from,
        placeholder = history.from,
        controlSize = "sm",
        flexGrow = 1,
        onChange = function(text)
          custom.from = text
        end,
        onSubmit = apply,
      }),
      parts.caption("→"),
      ui.input({
        key = `range-to-{custom.seed}`,
        value = custom.to,
        placeholder = history.to,
        controlSize = "sm",
        flexGrow = 1,
        onChange = function(text)
          custom.to = text
        end,
        onSubmit = apply,
      }),
      ui.button({ text = tr("panel.range.apply"), controlSize = "sm", variant = "outline", onClick = apply }),
    }),
    if custom.error
      then parts.caption(custom.error, "error")
      else parts.caption(tr("panel.range.custom_hint", { from = fmt.day(history.from, true), to = fmt.day(history.to, true) }))
  ))
end

local function chart(report, ctx)
  local history = report.history
  local days = chartDays(report)
  local values, netValues = {}, {}
  for i, d in days do
    values[i] = d.value
    -- Proposed additive field (step3-notes): net deposits to date per day.
    if netValues and d.netDeposit then
      netValues[i] = d.netDeposit
    else
      netValues = nil
    end
  end
  ctx.chartDays = days

  local selected = if ctx.custom.open then "custom" elseif report.range then report.range.preset else "all"
  local children = {
    rangeHeader(report, ctx, days),
    parts.segmented(presetOptions(report, ctx), selected, function(id)
      ctx.chartHover = nil
      if id == "custom" then
        ctx.custom.open = true
        ctx.custom.seed += 1
        ctx.custom.from = (report.range and report.range.from) or history.from
        ctx.custom.to = (report.range and report.range.to) or history.to
        ctx.custom.error = nil
      else
        ctx.custom.open = false
        state.setRange(id)
      end
      ctx.render()
    end, { key = "presets" }),
  }
  if ctx.custom.open then
    table.insert(children, customForm(report, ctx))
  end

  if #values >= 2 then
    local scaled, scaled2 = parts.normalize(values, netValues)
    local first, last = values[1], values[#values]
    table.insert(children, ui.graph({
      key = "value-chart",
      values = scaled,
      values2 = scaled2,
      color = fmt.signColor(last - first),
      color2 = "on_surface_variant/0.7",
      lineWidth = 2,
      fillOpacity = 0.12,
      height = 120,
      -- Named handlers: the panel owns hover state, and a leave that arrives
      -- after this render was replaced still needs a live callback.
      onPointerMove = "onChartMove",
      onPointerLeave = "onChartLeave",
    }))
    table.insert(children, ui.row({ align = "center", key = "axis" }, {
      parts.caption(fmt.day(days[1].day), nil, { flexGrow = 1 }),
      parts.caption(fmt.day(days[#days].day)),
    }))
    if netValues then
      table.insert(children, ui.row({ gap = 6, align = "center", key = "legend" }, {
        ui.box({ width = 10, height = 2, fill = "on_surface_variant/0.7" }),
        parts.caption(tr("panel.overview.legend_net")),
      }))
    end
  else
    table.insert(children, ui.column({ height = 120, justify = "center", align = "center", key = "value-chart-empty" }, {
      parts.caption(tr("panel.overview.history_empty"), nil, { textAlign = "center", maxLines = 3 }),
    }))
  end

  -- Caveats, each only when it applies to what is drawn.
  local atCostUntil
  for _, d in days do
    if d.stocksAtCost then
      atCostUntil = d.day
    end
  end
  if atCostUntil then
    table.insert(children, parts.caption(tr("panel.overview.stocks_at_cost", { day = fmt.day(atCostUntil) }), nil, { maxLines = 2, key = "at-cost" }))
  end
  if #(history.presets or {}) < #PRESETS then
    table.insert(children, parts.caption(tr("panel.overview.history_grows", { from = fmt.day(history.from, true) }), nil, { maxLines = 2, key = "grows" }))
  end

  return parts.card(children, { key = "chart" })
end

local function gapsNote(report)
  local names = {}
  for _, gap in report.gaps or {} do
    if gap ~= "flows_pending" and gap ~= "no_flows" then
      table.insert(names, tr(`panel.gap.{gap}`))
    end
  end
  if #names == 0 then
    return nil
  end
  return parts.caption(tr("panel.overview.not_included", { list = table.concat(names, ", ") }), nil, { key = "gaps", maxLines = 2 })
end

-- ── Keyless ───────────────────────────────────────────────────────────────

local function intro(report, ctx)
  return parts.card({
    ui.row({ gap = 10, align = "center" }, {
      ui.glyph({ name = "currency-bitcoin", size = 22, color = "primary" }),
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.label({ text = tr("panel.intro.title"), fontSize = 15, fontWeight = "bold", color = "on_surface" }),
        parts.caption(tr("panel.intro.subtitle"), nil, { maxLines = 2 }),
      }),
    }),
    ui.column({ gap = 6 }, {
      parts.bullet("chart-pie", tr("panel.intro.point_portfolio"), nil, "p1"),
      parts.bullet("shield-check", tr("panel.intro.point_readonly"), nil, "p2"),
      parts.bullet("lock", tr("panel.intro.point_keyring"), nil, "p3"),
    }),
    ui.row({ gap = 8, align = "center" }, {
      ui.button({
        text = tr("panel.intro.connect"),
        glyph = "plug-connected",
        variant = "primary",
        controlSize = "sm",
        onClick = function()
          ctx.setTab("account")
        end,
      }),
      parts.caption(tr("panel.intro.connect_time"), nil, { flexGrow = 1 }),
    }),
  }, { key = "intro", padding = 14 })
end

local function watchGlance(report, ctx)
  local rows = {}
  for i, ticker in report.watchlist or {} do
    if i > 5 then
      break
    end
    table.insert(rows, ui.row({ gap = 8, align = "center", key = ticker.symbol }, {
      ui.label({ text = ticker.base, fontSize = 13, fontWeight = "semibold", width = 56 }),
      parts.spark(ticker.spark, 64, 18),
      ui.label({ text = fmt.price(ticker.price), fontSize = 13, flexGrow = 1, textAlign = "end" }),
      ui.label({
        text = if ticker.change24h then fmt.pct(ticker.change24h) else "",
        fontSize = 12,
        color = fmt.signColor(fmt.pctSign(ticker.change24h)),
        width = 64,
        textAlign = "end",
      }),
    }))
  end
  if #rows == 0 then
    table.insert(rows, parts.caption(tr("panel.watch.empty")))
  end
  return parts.card({
    parts.section(tr("panel.overview.watchlist"), ui.button({
      text = tr("panel.watch.edit"),
      variant = "ghost",
      controlSize = "sm",
      onClick = function()
        ctx.setTab("watchlist")
      end,
    })),
    ui.column({ gap = 8 }, rows),
  }, { key = "glance" })
end

function M.render(report, ctx): { any }
  if report.mode ~= "connected" then
    return { intro(report, ctx), watchGlance(report, ctx) }
  end
  if report.totals == nil then
    return {
      parts.card({
        ui.row({ gap = 8, align = "center" }, {
          ui.glyph({ name = "loader-2", size = 16, color = "on_surface_variant" }),
          parts.caption(tr("panel.overview.first_sync"), nil, { flexGrow = 1, maxLines = 2 }),
        }),
      }, { key = "first-sync" }),
    }
  end
  return parts.nodes(
    hero(report, ctx),
    driftCard(report, ctx),
    if report.history then chart(report, ctx) else nil,
    gapsNote(report)
  )
end

return M
