--!nonstrict
-- Holdings tab: what you own, largest first. A filter (all / crypto /
-- stocks), an allocation bar, then one row per holding: value and today's
-- move on the right, a 30-day sparkline for crypto, average cost and a
-- floating P&L line for stocks. Small balances fold away behind one line.
-- Clicking a row opens the asset on binance.com.

local state = require("../lib/state.luau")
local links = require("../lib/links.luau")
local driftLib = require("../lib/drift.luau")
local fmt = require("./fmt.luau")
local parts = require("./parts.luau")

local M = {}

-- Holdings worth less than this (report currency) fold into "small balances".
local DUST = 1

-- Allocation segments: the largest holdings get their own color, the rest
-- share the last one.
local SEGMENT_COLORS = { "primary", "secondary", "tertiary", "on_surface_variant/0.8", "outline_variant" }

local function tr(key: string, subst)
  return noctalia.tr(key, subst)
end

local function allocationBar(list, report)
  local segments, legend = {}, {}
  local other = 0
  for i, h in list do
    if i < #SEGMENT_COLORS and h.allocation >= 0.02 then
      local color = SEGMENT_COLORS[i]
      local label = `{h.asset} {fmt.share(h.allocation)}`
      table.insert(segments, ui.box({
        key = h.asset,
        fill = color,
        height = 8,
        -- flexGrow in thousandths, so small shares still get a sliver.
        flexGrow = math.max(1, math.floor(h.allocation * 1000 + 0.5)),
        tooltip = label,
      }))
      table.insert(legend, ui.row({ gap = 4, align = "center", key = h.asset }, {
        ui.box({ width = 8, height = 8, radius = 4, fill = color }),
        parts.caption(label),
      }))
    else
      other += h.allocation
    end
  end
  if other > 0.0005 then
    local color = SEGMENT_COLORS[#SEGMENT_COLORS]
    local label = `{tr("panel.holdings.other")} {fmt.share(other)}`
    table.insert(segments, ui.box({
      key = "other",
      fill = color,
      height = 8,
      flexGrow = math.max(1, math.floor(other * 1000 + 0.5)),
      tooltip = label,
    }))
    table.insert(legend, ui.row({ gap = 4, align = "center", key = "other" }, {
      ui.box({ width = 8, height = 8, radius = 4, fill = color }),
      parts.caption(label),
    }))
  end
  if #segments == 0 then
    return nil
  end
  return ui.column({ gap = 8, key = "allocation" }, {
    ui.row({ gap = 2, radius = 4, height = 8 }, segments),
    ui.row({ gap = 12, align = "center" }, legend),
  })
end

local function quoteBadge(h)
  if not h.quoteStale then
    return nil
  end
  return ui.row({
    gap = 3,
    align = "center",
    tooltip = tr("panel.holdings.stale_quote_tooltip", { ago = fmt.ago(h.quoteAt) }),
  }, {
    ui.glyph({ name = "clock-pause", size = 12, color = "on_surface_variant" }),
    parts.caption(fmt.ago(h.quoteAt)),
  })
end

-- "target 20%" beside a holding with a target in the Overview.
local function targetTag(h, report)
  local d = report.drift
  local key = driftLib.key(h.kind, h.asset)
  for _, a in if d then d.assets else {} do
    if a.id == key then
      return parts.caption(tr("panel.overview.drift.target", { target = fmt.share(a.target) }), if table.find(d.off, key) then "error" else nil)
    end
  end
  return nil
end

local function detailLine(h, report): string
  local privacy, currency = report.privacy, report.currency
  local qty = fmt.qty(h.qty, privacy)
  if h.kind == "stock" then
    local text = tr("panel.holdings.shares", { qty = qty })
    if h.avgCost then
      text ..= " · " .. tr(if h.costApprox then "panel.holdings.avg_approx" else "panel.holdings.avg", { price = fmt.money(h.avgCost, currency) })
    end
    return text
  end
  -- With a cost basis the average takes the price's place: both don't fit
  -- beside the sparkline, and the value on the right already prices it.
  if h.avgCost then
    return `{qty} {h.asset} · ` .. tr(if h.costApprox then "panel.holdings.avg_approx" else "panel.holdings.avg", { price = fmt.money(h.avgCost, currency) })
  end
  return `{qty} {h.asset} · {fmt.money(h.price, currency)}`
end

local function costTooltip(h, report): string?
  local lines = {}
  local privacy, currency = report.privacy, report.currency
  if h.cost then
    table.insert(lines, tr("panel.holdings.cost", { value = fmt.money(h.cost, currency, { privacy = privacy }) }))
  end
  if h.costApprox then
    table.insert(lines, tr(if h.kind == "stock" then "panel.holdings.cost_approx" else "panel.holdings.cost_approx_crypto"))
  end
  if h.realized then
    table.insert(lines, tr("panel.holdings.realized", { value = fmt.money(h.realized, currency, { signed = true, privacy = privacy }) }))
  end
  if h.tokenizedQty and h.tokenizedQty > 0 then
    table.insert(lines, tr("panel.holdings.tokenized", { qty = fmt.qty(h.tokenizedQty, privacy) }))
  end
  return if #lines > 0 then table.concat(lines, "\n") else nil
end

-- Click handler and hover text for a row; none for a symbol links.luau
-- refuses.
local function linkProps(h, ctx)
  local url = links.holdingUrl(h.kind, h.asset)
  if url == nil then
    return {}
  end
  return {
    tooltip = tr(if ctx.canOpenUrls then "panel.holdings.open" else "panel.holdings.copy_link", { asset = h.asset }),
    onClick = function()
      ctx.openUrl(url)
    end,
  }
end

local function holdingRow(h, report, ctx)
  local currency, privacy = report.currency, report.privacy
  local noPrice = h.price == nil

  local left = ui.column({ gap = 2, flexGrow = 1 }, {
    ui.row({ gap = 6, align = "center" }, parts.nodes(
      ui.label({ text = h.asset, fontSize = 13, fontWeight = "semibold", color = "on_surface" }),
      -- The session badge says "stock" too, so it takes the tag's place.
      if h.kind == "stock"
        then parts.session(h.session) or ui.label({ text = tr("panel.holdings.stock_tag"), fontSize = 9, fontWeight = "semibold", color = "on_surface_variant" })
        else nil,
      quoteBadge(h),
      targetTag(h, report)
    )),
    parts.caption(detailLine(h, report), nil, { maxLines = 1 }),
  })

  -- The right column sizes to its text and the left one takes what is left,
  -- so long amounts squeeze the detail caption instead of overlapping it.
  local right = ui.column({ gap = 2, align = "end" }, {
    ui.label({
      text = if noPrice then "—" else fmt.money(h.value, currency, { privacy = privacy }),
      fontSize = 13,
      fontWeight = "semibold",
      color = "on_surface",
    }),
    if h.today
      then parts.pnl(h.today, currency, privacy, 11)
      else parts.caption(if noPrice then tr("panel.holdings.no_price") else "—"),
  })

  local key = `{h.kind}:{h.asset}`
  local link = linkProps(h, ctx)
  local top
  if h.kind ~= "stock" then
    -- The sparkline sits in the amount's row so the 12 px between them is a
    -- gap, not centring inside a wider column (which left ~8 px on screen).
    local trailing = ui.row({ gap = 12, align = "center" }, { parts.spark(h.spark, 72, 22), right })
    if h.avgCost == nil then
      return ui.row(parts.merge({ gap = 8, align = "center", key = key, paddingV = 4 }, link), { left, trailing })
    end
    top = ui.row({ gap = 8, align = "center", tooltip = link.tooltip }, { left, trailing })
  else
    top = ui.row({ gap = 8, align = "center", tooltip = link.tooltip }, { left, right })
  end

  -- With a cost basis, floating P&L gets its own full-width line under the
  -- row. The link's hover text sits on the top line, so the P&L line keeps
  -- its own.
  return ui.column({ gap = 4, key = key, paddingV = 4, onClick = link.onClick }, {
    top,
    ui.row({ gap = 6, align = "center", tooltip = costTooltip(h, report) }, {
      parts.caption(tr("panel.holdings.floating")),
      if h.floating then parts.pnl(h.floating, currency, privacy, 11) else parts.caption("—"),
    }),
  })
end

-- Export to CSV, then the file it wrote (with Open) or why it couldn't.
-- Only an export asked for since the panel opened is shown.
local function exportRow(report, ctx)
  local result = report.export
  if result and (ctx.exportAskedAt == nil or result.at < ctx.exportAskedAt) then
    result = nil
  end
  local status = nil
  if result and result.path then
    status = ui.row({ gap = 6, align = "center", flexGrow = 1, tooltip = result.path }, parts.nodes(
      ui.glyph({ name = "circle-check", size = 14, color = "primary" }),
      parts.caption(tr("panel.export.saved", { name = result.name }), nil, { flexGrow = 1, maxLines = 1 }),
      if noctalia.commandExists("xdg-open")
        then ui.button({
          text = tr("panel.export.open"),
          glyph = "external-link",
          variant = "ghost",
          controlSize = "sm",
          onClick = function()
            noctalia.runAsync({ "xdg-open", result.path })
          end,
        })
        else nil
    ))
  elseif result then
    status = parts.caption(tr(`panel.export.error_{result.error}`, { dir = result.dir or "" }), "error", { flexGrow = 1, maxLines = 2 })
  end
  return ui.row({ gap = 8, align = "center", key = "export" }, parts.nodes(
    status or ui.column({ flexGrow = 1 }, {}),
    ui.button({
      text = tr("panel.export.button"),
      glyph = "file-download",
      variant = "outline",
      controlSize = "sm",
      tooltip = tr("panel.export.tooltip"),
      onClick = function()
        ctx.exportAskedAt = fmt.now()
        state.exportCsv()
      end,
    })
  ))
end

function M.render(report, ctx): { any }
  local all = report.holdings or {}
  if #all == 0 then
    return {
      parts.card({ parts.caption(tr("panel.holdings.empty"), nil, { maxLines = 2 }) }, { key = "empty" }),
    }
  end

  local counts = { all = #all, crypto = 0, stock = 0 }
  for _, h in all do
    counts[h.kind] = (counts[h.kind] or 0) + 1
  end

  local filter = ctx.holdingsFilter
  local list, small = {}, {}
  for _, h in all do
    if filter == "all" or h.kind == filter then
      if h.value < DUST and h.price ~= nil and not ctx.showDust then
        table.insert(small, h)
      else
        table.insert(list, h)
      end
    end
  end

  local rows = {}
  for i, h in list do
    if i > 1 then
      table.insert(rows, ui.separator({ color = "outline_variant/0.15", key = `sep-{h.kind}:{h.asset}` }))
    end
    table.insert(rows, holdingRow(h, report, ctx))
  end
  if #small > 0 then
    table.insert(rows, ui.button({
      key = "dust",
      text = tr("panel.holdings.small_hidden", { n = #small }),
      variant = "ghost",
      controlSize = "sm",
      contentAlign = "start",
      onClick = function()
        ctx.showDust = true
        ctx.render()
      end,
    }))
  end

  local hasStocks = counts.stock > 0
  local out = parts.nodes(
    ui.row({ align = "center", gap = 8, key = "filter" }, {
      parts.segmented({
        { id = "all", label = tr("panel.holdings.filter_all", { n = counts.all }) },
        { id = "crypto", label = tr("panel.holdings.filter_crypto", { n = counts.crypto }) },
        { id = "stock", label = tr("panel.holdings.filter_stocks", { n = counts.stock }), enabled = hasStocks },
      }, filter, function(id)
        ctx.holdingsFilter = id
        ctx.render()
      end, { flexGrow = 1 }),
    }),
    -- Allocation is a share of the whole portfolio, so it only reads right
    -- unfiltered.
    if filter == "all" then allocationBar(list, report) else nil,
    parts.card(rows, { key = "rows", gap = 4, paddingV = 8 })
  )
  if hasStocks and filter ~= "crypto" then
    table.insert(out, parts.caption(tr("panel.holdings.stocks_note"), nil, { key = "stocks-note", maxLines = 2 }))
  end
  table.insert(out, exportRow(report, ctx))
  return out
end

return M
