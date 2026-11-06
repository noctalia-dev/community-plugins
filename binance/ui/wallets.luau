--!nonstrict
-- Wallets tab: where the money sits, one card per Binance wallet in
-- Binance's order with Stocks last. Click a wallet to fold it. Empty wallets
-- collapse into one line instead of a stack of zeros.

local fmt = require("./fmt.luau")
local parts = require("./parts.luau")

local M = {}

local GLYPHS = {
  Spot = "wallet",
  Funding = "building-bank",
  Earn = "pig-money",
  Stocks = "chart-candle",
  ["Cross Margin"] = "scale",
  ["Isolated Margin"] = "scale",
  ["Trading Bots"] = "robot",
  ["Copy Trading"] = "copy",
  Options = "arrows-split",
}

local function tr(key: string, subst)
  return noctalia.tr(key, subst)
end

local function glyphFor(name: string): string
  if GLYPHS[name] then
    return GLYPHS[name]
  end
  return if name:find("Futures", 1, true) then "chart-arrows" else "wallet"
end

local function walletCard(wallet, total: number, report, ctx)
  local currency, privacy = report.currency, report.privacy
  local folded = ctx.folded[wallet.name] == true
  local shareText = if total > 0 then fmt.share(wallet.value / total) else ""

  local header = ui.row({
    gap = 10,
    align = "center",
    onClick = function()
      ctx.folded[wallet.name] = not folded
      ctx.render()
    end,
  }, {
    ui.glyph({ name = glyphFor(wallet.name), size = 18, color = "primary" }),
    ui.column({ gap = 1, flexGrow = 1 }, {
      parts.title(wallet.name),
      parts.caption(noctalia.trp("panel.wallets.assets", wallet.assets, { n = wallet.assets })),
    }),
    ui.column({ gap = 1, align = "end" }, {
      ui.label({ text = fmt.money(wallet.value, currency, { privacy = privacy }), fontSize = 13, fontWeight = "semibold" }),
      parts.caption(shareText),
    }),
    ui.glyph({ name = if folded then "chevron-down" else "chevron-up", size = 14, color = "on_surface_variant" }),
  })

  local children = { header }
  if not folded and #(wallet.holdings or {}) > 0 then
    local rows = {}
    -- Largest first inside the wallet too.
    local holdings = table.clone(wallet.holdings)
    table.sort(holdings, function(a, b)
      return a.value > b.value
    end)
    for _, h in holdings do
      table.insert(rows, ui.row({ gap = 8, align = "center", key = h.asset }, {
        ui.label({ text = h.asset, fontSize = 12, fontWeight = "medium", width = 64 }),
        parts.caption(fmt.qty(h.qty, privacy), nil, { flexGrow = 1, fontSize = 12 }),
        ui.label({ text = fmt.money(h.value, currency, { privacy = privacy }), fontSize = 12 }),
      }))
    end
    table.insert(children, ui.separator({ color = "outline_variant/0.2" }))
    table.insert(children, ui.column({ gap = 6, paddingH = 4 }, rows))
  end
  return parts.card(children, { key = wallet.name, gap = 8 })
end

function M.render(report, ctx): { any }
  local wallets = report.wallets or {}
  local total = report.totals and report.totals.value or 0
  local out, empty = {}, {}
  for _, wallet in wallets do
    if wallet.value > 0 or wallet.assets > 0 then
      table.insert(out, walletCard(wallet, total, report, ctx))
    else
      table.insert(empty, wallet.name)
    end
  end
  if #out == 0 then
    table.insert(out, parts.card({ parts.caption(tr("panel.wallets.empty_all"), nil, { maxLines = 2 }) }, { key = "none" }))
  end
  if #empty > 0 then
    table.insert(out, parts.caption(tr("panel.wallets.empty", { list = table.concat(empty, ", ") }), nil, {
      key = "empty",
      maxLines = 3,
    }))
  end
  return out
end

return M
