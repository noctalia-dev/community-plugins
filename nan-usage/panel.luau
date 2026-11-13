--!nonstrict
-- [[panel]] entry: the detail view, opened from the bar widget or the cog.
--
-- Noctalia owns the placement — attached to the bar, next to whatever opened it —
-- so unlike an external window this needs no compositor configuration at all.
-- The two columns follow the shape other Noctalia plugins use: the period overall
-- and the models as a list of cards on the left, the selected one's detail on the
-- right, and the actions as icon buttons in the header rather than a footer.
--
-- The poller publishes what it read on the plugin's shared state, and shared.luau
-- turns that into the record this file paints, so the panel decides nothing itself:
-- levels, the pace, the token split and every figure come from the model. The
-- refresh button asks the poller to go now.

local shared = require("./shared.luau")
local prices = require("./prices.luau")

local function siteAction()
  return noctalia.getConfig("site_action") or "open"
end

local function iconStyle()
  return noctalia.getConfig("icon_style") or "ghost"
end

-- Read per render rather than once, so a change in the settings page lands without
-- a reload.
local function config()
  return {
    gauge = noctalia.getConfig("panel_gauge") or "bar",
    pollSeconds = tonumber(noctalia.getConfig("interval")) or 300,
  }
end

-- The two alarm colours, the same ones the bar widget uses. The healthy level
-- keeps the theme's own colour. Surfaces and text come from the palette, so the
-- panel tracks the theme.
local COLOR_WARN = "#ff7800"
local COLOR_CRIT = "#e01b24"

-- The three token types, one colour each, the same in every bar and legend: new
-- input in the theme's ink, cached input in teal, output in NaN's violet.
local COLOR_NEW = "on_surface"
local COLOR_CACHED = "#3fb8a8"
local COLOR_OUTPUT = "#a97bff"

-- The list's first entry: the account-wide totals, which belong to no model. A
-- model id cannot start with "#", so this cannot collide with one.
local OVERALL = "#overall"

-- Where the link button goes, and where NaN's own out-of-credits error sends you.
local PANEL_URL = "https://cloud.nan.builders"
local BUY_URL = "https://cloud.nan.builders/dashboard?buy=credits"

-- The logos, rasterised from the SVG next to them: whether the shell's Qt build
-- can render an SVG is not something to bet on, and a PNG always works. The ghost
-- pair is the silhouette in the theme's own ink, so the mark sits in a row of
-- glyphs instead of shouting; see generate-icons.sh next to this plugin.
local ICON_COLOR = "nan.png"
local ICON_GHOST_ON_DARK = "nan-ghost-white.png"
local ICON_GHOST_ON_LIGHT = "nan-ghost-black.png"

-- Every card carries a border and a fill, including the unselected ones: the
-- host updates the props it is given and leaves the rest as they were, so a prop
-- that is only set sometimes stays behind when the condition stops holding.
local CARD = {
  fill = "surface_container/0.30", radius = 12, padding = 12, gap = 8,
  border = "outline_variant/0.08", borderWidth = 1,
}
-- The selected row of the list, in the same shape as the reference plugin's.
local CARD_SELECTED_FILL = "primary/0.10"
local CARD_SELECTED_BORDER = "primary/0.55"
local CARD_PLAIN_FILL = "surface_container/0.30"
local CARD_PLAIN_BORDER = "outline_variant/0.12"
local MUTED = "on_surface/0.6"
local TRACK = "on_surface/0.10"
local ACCENT = "primary"

-- The per-day chart: a row of boxes standing on one baseline. Days still to come
-- are drawn as faint full-height columns, so the chart shows how much of the period
-- is left.
local CHART_HEIGHT = 72
local FUTURE_FILL = "on_surface/0.05"

local record = nil
local selected = OVERALL -- the model id, or OVERALL, that the right column describes
local busy = false

-- Declared before its users: a card's click closes over render, which is defined
-- further down. A name used above its `local function` is compiled as a global
-- lookup, and there is no such global, so the call raises.
local render

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

-- merge is how the shared card style takes a per-card override; Luau has no
-- table spread.
local function merge(base, extra)
  local out = {}
  for key, value in pairs(base) do
    out[key] = value
  end
  for key, value in pairs(extra or {}) do
    out[key] = value
  end
  return out
end

-- Which raster to draw: the coloured mark, or the ghost in whichever ink the
-- theme will read.
local function iconFile()
  if iconStyle() == "color" then
    return ICON_COLOR
  end
  if noctalia.isDarkMode() then
    return ICON_GHOST_ON_DARK
  end
  return ICON_GHOST_ON_LIGHT
end

local function levelColor(level)
  if level == "crit" then
    return COLOR_CRIT
  end
  if level == "warn" then
    return COLOR_WARN
  end
  return "on_surface"
end

-- The accent a bar fills with: the theme's primary while things are fine, the
-- alarm colour otherwise.
local function levelFill(level)
  if level == "ok" then
    return ACCENT
  end
  return levelColor(level)
end

-- The same, faint, for what the pace projects beyond what is used. A role takes its
-- alpha after a slash; a hex colour takes it as a fourth byte.
local function levelFillFaint(level)
  if level == "ok" then
    return ACCENT .. "/0.32"
  end
  return levelColor(level) .. "52"
end

local function card(children, extra)
  return ui.column(merge(CARD, extra), children)
end

local function muted(text, extra)
  return ui.label(merge({ text = text, color = MUTED, fontSize = 12 }, extra))
end

local function title(text)
  return ui.label({ text = text, fontWeight = "semibold", flexGrow = 1 })
end

-- An icon-only button, the way the header actions are done elsewhere: ghost
-- variant, a tooltip, nothing else.
local function iconButton(glyph, tooltip, handler, enabled)
  return ui.button({
    glyph = glyph,
    variant = "ghost",
    controlSize = "sm",
    tooltip = tooltip,
    onClick = handler,
    enabled = enabled ~= false,
  })
end

-- A pill, for the cache share, the estimate marker and the stale marker: a rounded
-- row with a translucent fill around a label.
local function pill(text, color)
  return ui.row({ fill = "surface_container/0.6", radius = 10, paddingH = 8, paddingV = 2, align = "center" }, {
    ui.label({ text = text, color = color or "on_surface", fontSize = 12, fontWeight = "medium" }),
  })
end

-- A bar made of segments, each as wide as its share of the whole. Every segment
-- sets every prop, for the same reason the cards do. A segment that would be too
-- thin to see gets a sliver, so a small but real share is not drawn as nothing.
local function segments(parts, whole, height)
  local children = {}
  local drawn = 0
  for index, part in ipairs(parts) do
    local value = math.max(0, part.value)
    if value > 0 then
      value = math.max(value, whole * 0.006)
    end
    drawn = drawn + value
    children[#children + 1] = ui.box({
      key = "segment-" .. index,
      flexGrow = value,
      height = height,
      fill = part.fill,
      radius = height / 2,
    })
  end
  children[#children + 1] = ui.box({
    key = "segment-rest",
    flexGrow = math.max(0, whole - drawn),
    height = height,
    fill = "on_surface/0.0",
    radius = height / 2,
  })
  return ui.row({ height = height, gap = 2, fill = TRACK, radius = height / 2 }, children)
end

-- One line of a legend: the colour, what it is, the figure, its share.
-- The two figure columns every list shares: fixed widths with right-aligned text,
-- so values and shares line up down a card whatever their length ("287", "<0.01",
-- "2,790.1"), and the same columns sit in the same place on every card.
local VALUE_WIDTH = 64
local SHARE_WIDTH = 40

-- A label sizes to its text whatever width it is given, so the fixed width lives
-- on a row around it, which pushes the text to its right edge.
local function column(width, child)
  return ui.row({ width = width, justify = "end", align = "center" }, { child })
end

local function valueLabel(text, weight)
  return column(VALUE_WIDTH, ui.label({ text = text, fontSize = 13, fontWeight = weight or "semibold", maxLines = 1 }))
end

local function shareLabel(text)
  return column(SHARE_WIDTH, muted(text, { fontSize = 12, maxLines = 1 }))
end

local function legendRow(color, label, value, share)
  return ui.row({ gap = 8, align = "center" }, {
    ui.box({ width = 10, height = 10, radius = 3, fill = color }),
    muted(label, { flexGrow = 1, fontSize = 13 }),
    valueLabel(value),
    shareLabel(share),
  })
end

-- The line a legend adds up to: a rule, then the total, so the rows above it read
-- as parts of it. The transparent swatch keeps the label in line with theirs.
local function totalRow(label, value)
  return ui.column({ gap = 6 }, {
    ui.box({ height = 1, fill = "outline_variant/0.20" }),
    ui.row({ gap = 8, align = "center" }, {
      ui.box({ width = 10, height = 10, radius = 3, fill = "on_surface/0.0" }),
      ui.label({ text = label, fontSize = 13, fontWeight = "semibold", flexGrow = 1 }),
      valueLabel(value, "bold"),
      shareLabel("100%"),
    }),
  })
end

-- "Total", or "Total since 11 Nov" while the token figures start later than the
-- period.
local function totalLabel()
  if record.tokensSince ~= "" then
    return tr("panel.total_since", { date = record.tokensSince })
  end
  return tr("panel.total")
end

local function pct(part, whole)
  if whole <= 0 then
    return "0%"
  end
  return shared.fmtPct(part / whole * 100, false)
end

-- ---------------------------------------------------------------- left column

local function headerRow()
  return ui.row({ gap = 6, align = "center" }, {
    ui.image({ path = iconFile(), width = 20, height = 20 }),
    ui.label({ text = tr("panel.title"), fontWeight = "bold", fontSize = 18, flexGrow = 1 }),
    iconButton("refresh", tr("panel.tooltip_refresh"), "onRefresh", not busy),
    iconButton("settings", tr("panel.tooltip_settings"), "onOpenSettings"),
    iconButton("external-link", tr("panel.tooltip_site"), "onOpenSite"),
  })
end

-- The overall row: the period's credits belong to no model, so they get their own
-- entry at the top of the list.
local function overallCard()
  local account = record and record.account
  local parts = {}
  local headline, of = "", ""
  if account ~= nil then
    parts[#parts + 1] = account.pctText
    headline = account.usedText
    of = tr("panel.of", { total = account.allowanceText })
  end
  if record ~= nil and record.tokens ~= nil and record.tokens.cachedPctText ~= "" then
    parts[#parts + 1] = tr("panel.cached_share", { share = record.tokens.cachedPctText })
  end
  if account ~= nil and account.resetsIn ~= "" then
    parts[#parts + 1] = tr("panel.resets_in", { when = account.resetsIn })
  end

  local isSelected = selected == OVERALL
  return card({
    ui.row({ gap = 10, align = "center" }, {
      ui.glyph({ name = "chart-pie", size = 16, color = isSelected and ACCENT or MUTED }),
      ui.column({ gap = 4, flexGrow = 1 }, {
        ui.label({ text = tr("panel.overall"), fontWeight = "bold" }),
        muted(table.concat(parts, " · ")),
      }),
      ui.column({ gap = 0, align = "end" }, {
        ui.label({ text = headline, fontSize = 20, fontWeight = "bold", color = levelColor(account and account.level) }),
        muted(of),
      }),
    }),
  }, {
    key = "overall",
    fill = isSelected and CARD_SELECTED_FILL or CARD_PLAIN_FILL,
    border = isSelected and CARD_SELECTED_BORDER or CARD_PLAIN_BORDER,
    borderWidth = 1,
    onClick = function()
      selected = OVERALL
      noctalia.state.set("selected", OVERALL)
      render()
    end,
  })
end

-- One model in the list: name, its credits, a thin bar of its share, and how much
-- of its input came from the cache. Clicking it picks the model the right column
-- describes.
local function modelCard(model)
  local isSelected = model.model == selected
  local sub = tr("panel.share_of_credits", { share = model.shareText })
  if not model.used then
    sub = tr("panel.no_usage")
  elseif model.tokenSplit.cachedPctText ~= "" then
    sub = sub .. " · " .. tr("panel.cached_share", { share = model.tokenSplit.cachedPctText })
  end
  return card({
    ui.row({ gap = 10, align = "center" }, {
      ui.label({ text = model.model, fontWeight = "bold", flexGrow = 1 }),
      ui.label({ text = model.creditsText, fontSize = 20, fontWeight = "bold" }),
    }),
    ui.progress({
      progress = math.max(0, math.min(model.share, 100)) / 100,
      fill = isSelected and ACCENT or "on_surface",
      track = TRACK,
      height = 4,
      radius = 2,
    }),
    muted(sub),
  }, {
    key = "model-" .. model.model,
    fill = isSelected and CARD_SELECTED_FILL or CARD_PLAIN_FILL,
    border = isSelected and CARD_SELECTED_BORDER or CARD_PLAIN_BORDER,
    borderWidth = 1,
    onClick = function()
      selected = model.model
      noctalia.state.set("selected", selected)
      render()
    end,
  })
end

local function modelColumn()
  local contents = { overallCard() }
  for _, model in ipairs((record and record.models) or {}) do
    table.insert(contents, modelCard(model))
  end

  if record ~= nil and record.error ~= nil and record.error ~= "" then
    local text = record.error
    if record.stale == true then
      text = text .. " · " .. tr("panel.cached")
    end
    table.insert(contents, card({
      ui.label({ text = text, color = COLOR_CRIT, fontSize = 12, maxLines = 4 }),
    }))
  end
  return contents
end

-- --------------------------------------------------------------- right column

-- ensureSelection keeps the selection pointing at something that is there: a
-- model that drops out of the period sends the panel back to the overall view.
local function ensureSelection()
  if selected == OVERALL then
    return
  end
  for _, model in ipairs((record and record.models) or {}) do
    if model.model == selected then
      return
    end
  end
  selected = OVERALL
end

local function selectedModel()
  for _, model in ipairs((record and record.models) or {}) do
    if model.model == selected then
      return model
    end
  end
  return nil
end

local function detailHeader(text, pills)
  local meta = record.updated or ""
  if record.account ~= nil and record.account.periodText ~= "" then
    meta = meta .. " · " .. record.account.periodText
  end
  if record.stale == true then
    table.insert(pills, pill(tr("panel.cached"), MUTED))
  end
  return ui.column({ gap = 4 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = text, fontWeight = "bold", fontSize = 20, flexGrow = 1 }),
      ui.row({ gap = 6, align = "center" }, pills),
    }),
    ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "clock", size = 14, color = MUTED }),
      muted(meta),
    }),
  })
end

-- What stops requests, said first: a paused subscription, or no credits left. An
-- account not billed in credits is said too, more quietly.
local function banners()
  local out = {}
  local account = record.account
  local function banner(text, color, button, handler)
    local body = { ui.label({ text = text, fontSize = 13, maxLines = 4 }) }
    if button ~= nil then
      table.insert(body, ui.row({ gap = 0 }, {
        ui.button({ text = button, variant = "secondary", controlSize = "sm", onClick = handler }),
      }))
    end
    return card({
      ui.row({ gap = 10 }, {
        ui.glyph({ name = "alert-triangle", size = 16, color = color }),
        ui.column({ gap = 6, flexGrow = 1 }, body),
      }),
    }, { key = "banner", border = color, fill = "surface_container/0.30" })
  end
  if account == nil then
    if record.ok then
      table.insert(out, banner(tr("panel.not_billed"), MUTED))
    end
  elseif account.frozen then
    table.insert(out, banner(tr("panel.frozen"), COLOR_CRIT, tr("panel.open_dashboard"), "onOpenSite"))
  elseif account.outOfCredits then
    table.insert(out, banner(tr("panel.out_of_credits", { date = account.resetsAtText }), COLOR_CRIT,
      tr("panel.buy_credits"), "onBuyCredits"))
  end
  return out
end

-- The period's credits: used, left, packs, a bar with the pace's projection drawn
-- lighter beyond what is used, and when it renews.
local function creditsCard()
  local account = record.account
  if account == nil then
    return nil
  end
  local function stat(label, value, color)
    return ui.column({ gap = 1, flexGrow = 1 }, {
      muted(label),
      ui.label({ text = value, fontSize = 19, fontWeight = "bold", color = color or "on_surface" }),
    })
  end
  local used = math.min(account.pct, 100)
  local projected = 0
  if account.projected ~= nil and account.allowance > 0 then
    projected = math.max(0, math.min(account.projected / account.allowance * 100, 100) - used)
  end
  local rows = {
    ui.row({ gap = 8, align = "center" }, {
      title(tr("panel.credits")),
      account.usingPacks and pill(tr("panel.using_packs"), COLOR_WARN) or ui.spacer({ width = 0 }),
    }),
    ui.row({ gap = 8 }, {
      stat(tr("panel.used"), account.usedText, levelColor(account.level)),
      stat(tr("panel.left"), account.remainingText),
      stat(tr("panel.packs"), account.packsText),
    }),
    segments({
      { value = used, fill = levelFill(account.level) },
      { value = projected, fill = levelFillFaint(account.level) },
    }, 100, 8),
  }
  if account.paceNote ~= "" then
    table.insert(rows, ui.label({ text = account.paceNote, fontSize = 12, color = levelColor(account.level) }))
  end
  if account.resetsInLong ~= "" then
    table.insert(rows, muted(tr("panel.resets_on", { when = account.resetsInLong, at = account.resetsAtText })))
  end
  if account.packs > 0 and account.packsExpire ~= "" then
    table.insert(rows, muted(tr("panel.packs_expire", { date = account.packsExpire })))
  end
  return card(rows, { key = "credits" })
end

-- Tokens split three ways, and how much of the input the cache served. extra is a
-- line to add under the legend, or nil.
local function tokensCard(split, extra)
  if split == nil or (split.new + split.cached + split.output) <= 0 then
    return nil
  end
  local whole = split.new + split.cached + split.output
  local header = { title(tr("panel.tokens")) }
  if split.cachedPctText ~= "" then
    table.insert(header, pill(tr("panel.cached_pill", { share = split.cachedPctText }), COLOR_CACHED))
  end
  local rows = {
    ui.row({ gap = 8, align = "center" }, header),
    segments({
      { value = split.new, fill = COLOR_NEW },
      { value = split.cached, fill = COLOR_CACHED },
      { value = split.output, fill = COLOR_OUTPUT },
    }, whole, 10),
    legendRow(COLOR_NEW, tr("panel.new_input"), split.newText, pct(split.new, whole)),
    legendRow(COLOR_CACHED, tr("panel.cached_input"), split.cachedText, pct(split.cached, whole)),
    legendRow(COLOR_OUTPUT, tr("panel.output"), split.outputText, pct(split.output, whole)),
    totalRow(totalLabel(), split.totalText),
  }
  if extra ~= nil and extra ~= "" then
    table.insert(rows, muted(extra))
  end
  return card(rows, { key = "tokens" })
end

-- The model's credits split by token type. NaN bills one figure per model, so the
-- split comes from its prices per type, scaled to that figure; the total row is the
-- figure itself, which is what the three rows add up to.
local function splitCard(model)
  local split = model.creditSplit
  if split == nil then
    return nil
  end
  local whole = split.new + split.cached + split.output
  return card({
    title(tr("panel.split_title")),
    segments({
      { value = split.new, fill = COLOR_NEW },
      { value = split.cached, fill = COLOR_CACHED },
      { value = split.output, fill = COLOR_OUTPUT },
    }, whole, 10),
    legendRow(COLOR_NEW, tr("panel.new_input"), split.newText, split.newPct),
    legendRow(COLOR_CACHED, tr("panel.cached_input"), split.cachedText, split.cachedPct),
    legendRow(COLOR_OUTPUT, tr("panel.output"), split.outputText, split.outputPct),
    totalRow(totalLabel(), split.totalText),
    muted(tr("panel.split_note", { date = record.pricesDate }), { maxLines = 3 }),
  }, { key = "split" })
end

-- Credits per day across the period: one column per day on a shared baseline, its
-- credits printed over it and its day of the month under it, today's day in the
-- accent, the days to come faint.
local function daysCard(days, peak)
  if days == nil or #days == 0 then
    return nil
  end
  local top = (peak and peak.credits) or 0
  local columns = {}
  for _, day in ipairs(days) do
    local height = 2
    local fill = TRACK
    if day.future then
      height = CHART_HEIGHT
      fill = FUTURE_FILL
    elseif day.credits > 0 and top > 0 then
      height = math.max(3, day.credits / top * CHART_HEIGHT)
      fill = ACCENT
    end
    -- Stretch, not centre: a box takes its width from the column, and a centred
    -- child with no width of its own would be drawn zero wide.
    table.insert(columns, ui.column({ key = "col-" .. day.date, flexGrow = 1, gap = 2, align = "stretch" }, {
      ui.label({
        text = day.future and "" or day.valueText,
        fontSize = 9,
        color = "on_surface",
        textAlign = "center",
        maxLines = 1,
      }),
      ui.box({
        key = "day-" .. day.date,
        height = height,
        fill = fill,
        radius = 2,
        border = day.today and ACCENT or "on_surface/0.0",
        borderWidth = day.today and 1 or 0,
      }),
      ui.label({
        text = day.day,
        fontSize = 9,
        color = day.today and ACCENT or MUTED,
        fontWeight = day.today and "bold" or "normal",
        textAlign = "center",
        maxLines = 1,
      }),
    }))
  end
  return card({
    ui.row({ gap = 8, align = "center" }, {
      title(tr("panel.per_day")),
      muted(days[1].label .. " – " .. days[#days].label),
    }),
    ui.row({ gap = 3, align = "end" }, columns),
  }, { key = "days" })
end

-- Each model's share of the period's credits.
local function contributionsCard()
  local models = {}
  for _, model in ipairs(record.models or {}) do
    if model.used then
      models[#models + 1] = model
    end
  end
  if #models == 0 then
    return nil
  end
  local rows = { title(tr("panel.contributions")) }
  for _, model in ipairs(models) do
    table.insert(rows, ui.column({ key = "share-" .. model.model, gap = 4 }, {
      ui.row({ gap = 8, align = "center" }, {
        ui.label({ text = model.model, fontSize = 13, flexGrow = 1 }),
        -- The same columns as the legends: the amount bold, its share muted.
        valueLabel(model.creditsText),
        shareLabel(model.shareText),
      }),
      ui.progress({
        progress = math.max(0, math.min(model.share, 100)) / 100,
        fill = "on_surface",
        track = TRACK,
        height = 3,
        radius = 2,
      }),
    }))
  end
  table.insert(rows, totalRow(tr("panel.total"), record.modelsTotalText))
  return card(rows, { key = "contributions" })
end

-- One model's credits: the figure, what a million tokens cost on average, and its
-- share of the period.
local function modelCreditsCard(model)
  local rows = {
    ui.row({ gap = 10, align = "center" }, {
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.label({ text = tr("panel.credits"), fontWeight = "semibold" }),
        muted(tr("panel.requests", { count = model.requestsText })),
      }),
      ui.label({ text = model.creditsText, fontSize = 24, fontWeight = "bold" }),
    }),
    segments({ { value = model.share, fill = ACCENT } }, 100, 8),
  }
  if record.account ~= nil then
    table.insert(rows, muted(tr("panel.share_of_period", { share = model.shareText, total = record.account.usedText })))
  end
  return card(rows, { key = "model-credits" })
end

local function append(list, item)
  if item ~= nil then
    table.insert(list, item)
  end
end

local function overallColumn()
  local cards = banners()
  append(cards, creditsCard())
  local saved = ""
  if record.savedText ~= "" then
    saved = tr("panel.saved", { value = record.savedText })
  end
  append(cards, tokensCard(record.tokens, saved))
  append(cards, daysCard(record.days, record.peak))
  append(cards, contributionsCard())
  if record.allTime ~= "" then
    append(cards, muted(tr("panel.all_time", { value = record.allTime })))
  end
  return {
    detailHeader(tr("panel.this_period"), {}),
    ui.scroll({ flexGrow = 1, gap = 10 }, cards),
  }
end

-- What a model costs, per kind of token, from NaN's price list: the three rates the
-- split by token type is worked out from.
local function pricesCard(model)
  local price = model.price
  if price == nil then
    return nil
  end
  return card({
    title(tr("panel.prices")),
    legendRow(COLOR_NEW, tr("panel.new_input"), price.newText, ""),
    legendRow(COLOR_CACHED, tr("panel.cached_input"), price.cachedText, ""),
    legendRow(COLOR_OUTPUT, tr("panel.output"), price.outputText, ""),
    muted(tr("panel.prices_note", { date = record.pricesDate }), { maxLines = 2 }),
  }, { key = "prices" })
end

local function modelDetail(model)
  local cards = banners()
  if model.used then
    append(cards, modelCreditsCard(model))
    append(cards, tokensCard(model.tokenSplit, nil))
    append(cards, splitCard(model))
    append(cards, daysCard(model.days, model.peak))
  else
    append(cards, card({ muted(tr("panel.no_usage"), { fontSize = 13 }) }, { key = "unused" }))
  end
  append(cards, pricesCard(model))
  return {
    detailHeader(model.model, { pill(tr("panel.share_pill", { share = model.shareText }), ACCENT) }),
    ui.scroll({ flexGrow = 1, gap = 10 }, cards),
  }
end

local function detailColumn()
  if record == nil then
    return {
      ui.label({ text = tr("panel.waiting"), color = MUTED }),
      muted(tr("panel.waiting_hint")),
    }
  end
  if not record.ok then
    return {
      ui.label({ text = tr("panel.no_data"), color = MUTED }),
      muted(record.error or ""),
    }
  end
  local model = selectedModel()
  if model ~= nil then
    return modelDetail(model)
  end
  return overallColumn()
end

function render()
  -- Before anything reads it: the list highlights the selected card, and the
  -- detail column describes the selected entry, so they have to agree even on
  -- the first paint.
  ensureSelection()
  panel.render(ui.row({ gap = 14, flexGrow = 1 }, {
    ui.column({ gap = 10, flexGrow = 2 }, {
      headerRow(),
      -- The gap belongs to the scrolling container: without it the cards stack
      -- flush against each other.
      ui.scroll({ flexGrow = 1, gap = 10 }, modelColumn()),
    }),
    ui.column({ gap = 10, flexGrow = 3 }, detailColumn()),
  }))
end

-- ------------------------------------------------------------------ actions

-- The address to the clipboard. Nothing installed is needed for this, so it is also
-- what the link buttons fall back on when no browser opener exists.
local function copyURL(url)
  if noctalia.copyToClipboard(url, "text/plain") then
    noctalia.notify(tr("panel.title"), tr("panel.copied"))
    return true
  end
  noctalia.notifyError(tr("panel.title"), tr("panel.copy_failed"))
  return false
end

-- Noctalia has no API to open a URL, so it goes through the shell. `gio` ships with
-- glib2 and is on practically every system; `xdg-open` is the familiar one but
-- belongs to xdg-utils, which is often not installed. Whichever runs, a failure is
-- reported rather than swallowed; when neither exists, the address is copied
-- instead, so the button does something useful rather than nothing.
local function openURL(url)
  for _, candidate in ipairs({ "gio open", "xdg-open" }) do
    local program = candidate:match("^%S+")
    if noctalia.commandExists(program) then
      noctalia.runAsync(candidate .. " " .. url, function(result)
        if result.exitCode ~= 0 then
          local reason = noctalia.string.trim(result.stderr or "")
          if reason == "" then
            reason = tr("panel.open_failed")
          end
          noctalia.notifyError(tr("panel.title"), reason)
        end
      end)
      return
    end
  end
  copyURL(url)
  noctalia.notify(tr("panel.title"), tr("panel.no_opener_copied"))
end

-- open | copy. Opening is the default because it is what a link button is for; the
-- setting is there for anyone who would rather not have a process started at all.
local function visit(url)
  if siteAction() == "copy" then
    copyURL(url)
    return
  end
  openURL(url)
end

function onOpenSite()
  visit(PANEL_URL)
end

-- Only offered when the period's credits and the packs are spent: the page NaN's
-- own out-of-credits error points to.
function onBuyCredits()
  visit(BUY_URL)
end

function onOpenSettings()
  noctalia.openSettings()
end

-- A fresh poll, asked for over the shared state channel: one VM cannot call into
-- another, and the poller is the only part of the plugin that talks to NaN. It
-- bypasses the poller's rate limit, so pressing this twice in a second is one
-- request, not two.
function onRefresh()
  if busy then
    return
  end
  busy = true
  render()
  noctalia.state.set("refresh", os.time())
end

-- ----------------------------------------------------------------- lifecycle

-- The poller publishes as soon as a poll lands; opening the panel before the first
-- one is fine, and this fills it in as soon as it arrives.
local function ingest(data)
  record = nil
  if data ~= nil then
    record = shared.build(data, config(), os.time(), prices)
    busy = false
  end
  render()
end

noctalia.state.watch("data", ingest)

function onOpen(_context)
  render()
  if record == nil then
    onRefresh()
  end
end

-- The stored data is reused as-is: the model rebuilds the record from it with the
-- current clock, so the countdowns are right even if the poll was a while ago.
ingest(noctalia.state.get("data"))
-- The selection lives in the plugin's shared state, so reopening the panel — or a
-- reload — comes back to the entry you were looking at.
selected = noctalia.state.get("selected") or OVERALL

-- One line so a blank panel is answerable from Noctalia's log: if this is
-- missing, the script did not load at all.
noctalia.log("NaN Usage panel: loaded")
