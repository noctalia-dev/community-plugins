--!nonstrict
-- [[panel]] entry: the detail view, opened from the bar widget or the cog.
--
-- Noctalia owns the placement — attached to the bar, next to whatever opened it —
-- so unlike an external window this needs no compositor configuration at all.
-- The two columns follow the shape other Noctalia plugins use: the models as a
-- list of cards on the left, the selected one's detail on the right, and the
-- actions as icon buttons in the header rather than a footer.
--
-- The poller publishes what it read on the plugin's shared state, and shared.luau
-- turns that into the record this file paints, so the panel decides nothing itself:
-- levels, projections and the text of every caption come from the model. The
-- refresh button asks the poller to go now.

local shared = require("./shared.luau")

-- Read per render rather than once, so a change in the settings page lands without
-- a reload. `~= false` for a setting whose manifest default is true, `== true` for
-- one whose default is false: an unset value must mean what the manifest says.
local function iconStyle()
  return noctalia.getConfig("icon_style") or "ghost"
end

local function siteAction()
  return noctalia.getConfig("site_action") or "open"
end

-- Read per render rather than once, so a change in the settings page lands without
-- a reload.
local function config()
  return {
    panelModel = noctalia.getConfig("panel_model") or "worst",
    panelModelId = noctalia.getConfig("panel_model_id") or "deepseek-v4-flash",
    gauge = noctalia.getConfig("panel_gauge") or "bar",
    hideUnused = noctalia.getConfig("hide_unused") == true,
    showMetrics = noctalia.getConfig("show_metrics") ~= false,
    showPercentage = noctalia.getConfig("show_percentage") ~= false,
    showReset = noctalia.getConfig("show_reset") ~= false,
    showModel = noctalia.getConfig("show_model") ~= false,
    pollSeconds = tonumber(noctalia.getConfig("interval")) or 60,
  }
end

-- The two alarm colours, the same ones the bar widget uses. The
-- healthy level keeps the theme's own colour. Surfaces and text come from the
-- palette, so the panel tracks the theme.
local COLOR_WARN = "#ff7800"
local COLOR_CRIT = "#e01b24"

-- The list's first entry: the account-wide totals, which belong to no model. A
-- model id cannot start with "#", so this cannot collide with one.
local OVERALL = "#overall"

-- Where the link button goes. Kept in step with nanclient.PanelURL.
local PANEL_URL = "https://cloud.nan.builders"

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
  fill = "surface_variant/0.30", radius = 12, padding = 12, gap = 8,
  border = "outline/0.08", borderWidth = 1,
}
-- The selected row of the list, in the same shape as the reference plugin's.
local CARD_SELECTED_FILL = "primary/0.10"
local CARD_SELECTED_BORDER = "primary/0.55"
local CARD_PLAIN_FILL = "surface_variant/0.30"
local CARD_PLAIN_BORDER = "outline/0.12"
local MUTED = "on_surface/0.6"
local TRACK = "on_surface/0.10"
local ACCENT = "primary"

local record = nil
local selected = OVERALL -- the model id, or OVERALL, that the right column describes
local busy = false

-- Declared before their users: a model card's click closes over render, and the
-- detail column calls usageCard, both of which are defined further down. A name
-- used above its `local function` is compiled as a global lookup, and there is no
-- such global, so the call raises. Both tests fail on that.
local render
local usageCard

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

-- A percentage of a whole, the way their plugin prints them.
local function share(part, whole)
  if whole <= 0 then
    return "0%"
  end
  return string.format("%d%%", math.floor(part / whole * 100 + 0.5))
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

local function card(children, extra)
  return ui.column(merge(CARD, extra), children)
end

local function muted(text, extra)
  return ui.label(merge({ text = text, color = MUTED, fontSize = 12 }, extra))
end

local function bar(window, height)
  return ui.progress({
    progress = math.max(0, math.min(window.percent, 100)) / 100,
    fill = levelColor(window.level),
    track = TRACK,
    height = height,
    radius = height / 2,
  })
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

-- A pill, for the tier and the cached marker: a rounded row with a translucent
-- fill around a label.
local function pill(text, color)
  return ui.row({ fill = "surface_variant/0.6", radius = 10, paddingH = 8, paddingV = 2, align = "center" }, {
    ui.label({ text = text, color = color or "on_surface", fontSize = 12, fontWeight = "medium" }),
  })
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

-- The overall row: the account's totals belong to no model, so they get their own
-- entry at the top of the list instead of a card repeated in every model's
-- detail.
local function overallCard()
  local buckets = (record and record.usage) or {}
  local headline, recent = "", ""
  for _, bucket in ipairs(buckets) do
    if bucket.label == "month" then
      headline = bucket.text
    end
  end
  if headline == "" and #buckets > 0 then
    headline = buckets[#buckets].text
  end
  if #buckets > 0 then
    recent = tr("panel.recent", { label = buckets[1].label, value = buckets[1].text })
  end

  local isSelected = selected == OVERALL
  return card({
    ui.row({ gap = 10, align = "center" }, {
      ui.glyph({ name = "chart-pie", size = 16, color = isSelected and ACCENT or MUTED }),
      ui.column({ gap = 5, flexGrow = 1 }, {
        ui.label({ text = tr("panel.overall"), fontWeight = "bold" }),
        ui.label({ text = recent, color = MUTED, fontSize = 12 }),
      }),
      ui.label({ text = headline, fontSize = 20, fontWeight = "bold" }),
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

-- One model in the list: name, a thin bar, the percentage. Clicking it picks the
-- model the right column describes.
local function modelCard(window)
  local isSelected = window.model == selected
  local extra = {
    key = "model-" .. window.model,
    fill = isSelected and CARD_SELECTED_FILL or CARD_PLAIN_FILL,
    border = isSelected and CARD_SELECTED_BORDER or CARD_PLAIN_BORDER,
    borderWidth = 1,
    onClick = function()
      selected = window.model
      noctalia.state.set("selected", selected)
      render()
    end,
  }
  return card({
    ui.row({ gap = 10, align = "center" }, {
      ui.column({ gap = 5, flexGrow = 1 }, {
        ui.label({ text = window.model, fontWeight = "bold" }),
        bar(window, 4),
        muted(window.short or ""),
      }),
      ui.label({ text = window.percentText, fontSize = 20, fontWeight = "bold", color = levelColor(window.level) }),
    }),
  }, extra)
end

-- --------------------------------------------------------------- right column

-- ensureSelection keeps the selection pointing at a model that is there: the
-- first one until the user picks another, and still something after a refresh
-- that drops models from the period.
local function ensureSelection()
  if selected == OVERALL then
    return
  end
  local windows = (record and record.windows) or {}
  for _, window in ipairs(windows) do
    if window.model == selected then
      return
    end
  end
  if #windows > 0 then
    selected = windows[1].model
  else
    selected = nil
  end
end

local function selectedWindow()
  for _, window in ipairs((record and record.windows) or {}) do
    if window.model == selected then
      return window
    end
  end
  return nil
end

-- The tier and the stale marker: both headers carry them.
local function accountPills()
  local right = {}
  if record ~= nil and record.account ~= nil and record.account.tier ~= nil and record.account.tier ~= "" then
    table.insert(right, pill(record.account.tier, "primary"))
  end
  if record ~= nil and record.stale == true then
    table.insert(right, pill(tr("panel.cached"), MUTED))
  end
  return right
end

local function detailHeader(window)
  return ui.column({ gap = 4 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = window.model, fontWeight = "bold", fontSize = 20, flexGrow = 1 }),
      ui.row({ gap = 6, align = "center" }, accountPills()),
    }),
    ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "clock", size = 14, color = MUTED }),
      muted(record ~= nil and record.updated or ""),
    }),
  })
end

-- The selected model as a card: the percentage, a thick bar, when it resets,
-- what it has used, and the tool's own verdict on the burn rate.
local function detailCards(window)
  local cards = {}

  local resetRow = {}
  if window.resetsIn ~= nil and window.resetsIn ~= "" then
    table.insert(resetRow, ui.glyph({ name = "clock", size = 14, color = MUTED }))
    table.insert(resetRow, muted(tr("panel.resets_in", { when = window.resetsIn })))
  end

  local usedRow = {
    muted((window.usedText or "") .. " / " .. (window.capText or "")),
    ui.spacer({ flexGrow = 1 }),
  }
  if window.note ~= nil and window.note ~= "" then
    table.insert(usedRow, ui.label({ text = window.note, color = levelColor(window.level), fontSize = 12 }))
  end

  local body = {
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = window.short ~= "" and window.short or window.model, fontWeight = "semibold", flexGrow = 1 }),
      ui.label({ text = window.percentText, fontSize = 24, fontWeight = "bold", color = levelColor(window.level) }),
    }),
    bar(window, 10),
  }
  if #resetRow > 0 then
    table.insert(body, ui.row({ gap = 6, align = "center" }, resetRow))
  end
  table.insert(body, ui.row({ gap = 8, align = "center" }, usedRow))
  table.insert(cards, card(body))

  -- The totals and the period are the account's, not this model's: they live in
  -- the overall entry now, which is where someone looks for them.
  return cards
end

-- The aggregates as bars: one row per period the tool reports, each drawn against
-- the largest of them, so the 24 h bar reads as its share of the month. The tool
-- sends the numbers now; if it is an older build and only sends the printed line,
-- that line is what the card shows.
function usageCard()
  if record == nil then
    return nil
  end
  local usage = record.usage
  if usage == nil or #usage == 0 then
    if record.metrics == nil or record.metrics == "" then
      return nil
    end
    return card({
      ui.label({ text = tr("panel.consumption"), fontWeight = "semibold" }),
      muted(record.metrics),
    }, { key = "usage-line" })
  end

  local largest = 0
  for _, bucket in ipairs(usage) do
    largest = math.max(largest, tonumber(bucket.tokens) or 0)
  end

  local rows = { ui.label({ text = tr("panel.consumption"), fontWeight = "semibold" }) }
  for _, bucket in ipairs(usage) do
    local tokens = tonumber(bucket.tokens) or 0
    table.insert(rows, ui.column({ key = "usage-" .. tostring(bucket.label), gap = 4 }, {
      ui.row({ gap = 8, align = "center" }, {
        muted(bucket.label, { flexGrow = 1 }),
        ui.label({ text = bucket.text or "", fontSize = 13, fontWeight = "semibold" }),
      }),
      ui.progress({
        progress = largest > 0 and (tokens / largest) or 0,
        fill = ACCENT,
        track = TRACK,
        height = 3,
        radius = 2,
      }),
    }))
  end
  return card(rows, { key = "usage-bars" })
end

-- Where the totals came from: each model's share of the period's token usage. It
-- is the period's figure, not the last 24 hours, so the period line travels with
-- the card rather than being implied.
local function contributionsCard()
  local windows = (record and record.windows) or {}
  local total = 0
  for _, window in ipairs(windows) do
    total = total + (tonumber(window.used) or 0)
  end
  local rows = {}
  for _, window in ipairs(windows) do
    local used = tonumber(window.used) or 0
    table.insert(rows, ui.column({ key = "share-" .. window.model, gap = 4 }, {
      ui.row({ gap = 8, align = "center" }, {
        ui.label({ text = window.model, fontSize = 13, flexGrow = 1 }),
        muted(window.usedText or ""),
        ui.label({ text = share(used, total), fontSize = 13, fontWeight = "semibold", color = levelColor(window.level) }),
      }),
      ui.progress({
        progress = total > 0 and (used / total) or 0,
        fill = levelColor(window.level),
        track = TRACK,
        height = 3,
        radius = 2,
      }),
    }))
  end
  if #rows == 0 then
    return nil
  end
  table.insert(rows, 1, ui.label({ text = tr("panel.contributions"), fontWeight = "semibold" }))
  if record.period ~= nil and record.period ~= "" then
    table.insert(rows, 2, muted(record.period))
  end
  return card(rows, { key = "contributions" })
end

-- The overall column: no model, so no per-model card.
local function overallColumn()
  local contents = {
    ui.column({ gap = 4 }, {
      ui.row({ gap = 8, align = "center" }, {
        ui.label({ text = tr("panel.overall"), fontWeight = "bold", fontSize = 20, flexGrow = 1 }),
        ui.row({ gap = 6, align = "center" }, accountPills()),
      }),
      ui.row({ gap = 6, align = "center" }, {
        ui.glyph({ name = "clock", size = 14, color = MUTED }),
        muted(record.updated or ""),
      }),
    }),
  }
  local usage = usageCard()
  if usage ~= nil then
    table.insert(contents, usage)
  end
  local contributions = contributionsCard()
  if contributions ~= nil then
    table.insert(contents, contributions)
  end
  return contents
end

local function detailColumn()
  if record == nil then
    return {
      ui.label({ text = tr("panel.waiting"), color = MUTED }),
      muted(tr("panel.waiting_hint")),
    }
  end
  if selected == OVERALL then
    return overallColumn()
  end
  local window = selectedWindow()
  if window == nil then
    local text = tr("panel.no_data")
    if (record.totalWindows or 0) > 0 then
      text = tr("panel.no_usage")
    end
    return { ui.label({ text = text, color = MUTED }) }
  end
  local contents = { detailHeader(window) }
  for _, item in ipairs(detailCards(window)) do
    table.insert(contents, item)
  end
  return contents
end

local function modelColumn()
  local contents = { overallCard() }
  for _, window in ipairs((record and record.windows) or {}) do
    table.insert(contents, modelCard(window))
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

function render()
  -- Before anything reads it: the list highlights the selected card, and the
  -- detail column describes the selected model, so they have to agree even on
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
-- what the link button falls back on when no browser opener exists.
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
function onOpenSite()
  if siteAction() == "copy" then
    copyURL(PANEL_URL)
    return
  end
  openURL(PANEL_URL)
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
    record = shared.build(data, config(), os.time())
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
-- reload — comes back to the model you were looking at.
selected = noctalia.state.get("selected") or OVERALL

-- One line so a blank panel is answerable from Noctalia's log: if this is
-- missing, the script did not load at all.
noctalia.log("NaN Usage panel: loaded")
