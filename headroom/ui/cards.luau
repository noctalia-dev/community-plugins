--!nonstrict
-- Card components: the provider card (windows, error banner, notes), the
-- disconnected row and the empty state, plus the logo and caption used by the
-- bar as well. Pure functions of their arguments: no state, no side effects.

local state = require("../lib/state.luau")
local theme = require("../lib/theme.luau")
local view = require("../lib/view.luau")
local time = require("../lib/time.luau")

local M = {}

local CARD_FILL = "surface_variant/0.45"
local TRACK = "on_surface/0.10"

function M.logo(provider, size: number, opacity: number?)
  local path = theme.logo(provider)
  if path then
    return ui.image({ path = path, width = size, height = size, fit = "contain", opacity = opacity or 1 })
  end
  return ui.glyph({ name = provider.brand.glyph, size = size, color = "on_surface", opacity = opacity or 1 })
end

function M.caption(text: string, color: string?, extra)
  local props = { text = text, fontSize = 11, color = color or "on_surface_variant" }
  if extra then
    for k, v in extra do
      props[k] = v
    end
  end
  return ui.label(props)
end

local function windowRow(provider, window, now: number, dimmed: boolean)
  local severity = view.severity(window, now)
  local paceText, paceColor, pace = view.pace(window, now)
  local resets = view.resetsIn(window, now)

  local children = {
    ui.row({ align = "center", gap = 8 }, {
      ui.label({ text = window.label, fontSize = 13, color = "on_surface", flexGrow = 1, maxLines = 1 }),
      ui.label({
        text = view.percent(window, view.showsRemaining()),
        fontSize = 13,
        fontWeight = "semibold",
        color = view.textColor(severity),
      }),
    }),
    ui.progress({
      progress = view.shownPercent(window) / 100,
      height = 8,
      radius = 4,
      fill = theme.meterColor(severity),
      track = TRACK,
    }),
  }

  if pace then
    -- The time track, on the same scale as the meter above it: time elapsed
    -- under a "used" meter, time remaining under a "left" one. A meter that
    -- outruns its track (used) or falls short of it (left) is burning fast.
    local remaining = view.showsRemaining()
    local fraction = if remaining then 1 - pace.elapsedFraction else pace.elapsedFraction
    table.insert(children, ui.column({
      tooltip = noctalia.tr(if remaining then "panel.remaining_tooltip" else "panel.elapsed_tooltip", {
        percent = math.floor(fraction * 100 + 0.5),
      }),
    }, {
      ui.progress({
        progress = fraction,
        height = 3,
        radius = 2,
        fill = "on_surface_variant/0.55",
        track = "on_surface/0.05",
      }),
    }))
  end

  if resets or paceText then
    table.insert(children, ui.row({ align = "center", gap = 8 }, {
      M.caption(resets or "", nil, { flexGrow = 1, maxLines = 1 }),
      M.caption(paceText or "", paceColor, { maxLines = 1 }),
    }))
  end

  return ui.column({ gap = 6, key = window.id, opacity = if dimmed then 0.6 else 1 }, children)
end

-- What failed and how to fix it; when older data is still shown below, says
-- how old it is.
local function errorBanner(provider, now: number)
  local err = provider.error
  local title = noctalia.tr(`error.{err.code}.title`)
  local body = err.hint or noctalia.tr(`error.{err.code}.body`)
  if provider.snapshot and provider.snapshot.fetchedAt then
    body = noctalia.tr("panel.showing_cached", { ago = time.ago(now - provider.snapshot.fetchedAt) }) .. " " .. body
  end
  return ui.row({ gap = 10, align = "center", padding = 10, radius = 10, fill = "error/0.12" }, {
    ui.glyph({ name = "alert-circle", size = 18, color = "error" }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = title, fontSize = 12, fontWeight = "semibold", color = "on_surface" }),
      M.caption(body, nil, { maxLines = 3 }),
    }),
    ui.button({
      glyph = "refresh",
      variant = "ghost",
      controlSize = "sm",
      tooltip = noctalia.tr("panel.retry"),
      onClick = function()
        state.requestRefresh()
      end,
    }),
  })
end

local function notesBlock(notes)
  local rows = {}
  for i, note in notes do
    table.insert(rows, ui.row({ align = "center", key = `note{i}` }, {
      M.caption(note.label, nil, { flexGrow = 1 }),
      ui.label({ text = note.value, fontSize = 11, fontWeight = "medium", color = "on_surface" }),
    }))
  end
  return ui.column({ gap = 4 }, rows)
end

-- options.onOpenDashboard(url): shows the usage-page button when given.
function M.providerCard(provider, now: number, options)
  local snapshot = provider.snapshot
  local subtitle = snapshot and snapshot.plan or nil
  if provider.busy then
    subtitle = noctalia.tr("status.refreshing")
  elseif provider.stale and snapshot and provider.status ~= "error" then
    subtitle = (if subtitle then subtitle .. " · " else "") .. noctalia.tr("status.cached")
  end

  local headerChildren = {
    M.logo(provider, 22),
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = provider.name, fontSize = 14, fontWeight = "semibold", color = "on_surface" }),
      M.caption(subtitle or " ", nil, { visible = subtitle ~= nil }),
    }),
  }
  if provider.brand.dashboard and options and options.onOpenDashboard then
    table.insert(headerChildren, ui.button({
      glyph = "external-link",
      variant = "ghost",
      controlSize = "sm",
      tooltip = noctalia.tr("panel.open_dashboard", { provider = provider.name }),
      onClick = function()
        options.onOpenDashboard(provider.brand.dashboard)
      end,
    }))
  end
  local header = ui.row({ align = "center", gap = 10 }, headerChildren)

  local body = { header }
  local dimmed = provider.status == "error"

  if provider.status == "error" and provider.error then
    table.insert(body, errorBanner(provider, now))
  end

  if snapshot and #snapshot.windows > 0 then
    for _, window in snapshot.windows do
      table.insert(body, windowRow(provider, window, now, dimmed))
    end
    if snapshot.notes and #snapshot.notes > 0 then
      table.insert(body, ui.separator({ color = "outline/0.25" }))
      table.insert(body, notesBlock(snapshot.notes))
    end
  elseif provider.status == "loading" then
    table.insert(body, M.caption(noctalia.tr("status.fetching")))
  end

  return ui.column({ key = provider.id, gap = 12, padding = 14, radius = 14, fill = CARD_FILL }, body)
end

function M.disconnectedRow(provider)
  return ui.row({ key = `off-{provider.id}`, align = "center", gap = 10, padding = 10, radius = 12, border = "outline/0.25", borderWidth = 1 }, {
    M.logo(provider, 18, 0.5),
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = noctalia.tr("panel.not_connected", { provider = provider.name }), fontSize = 12, color = "on_surface_variant" }),
      M.caption(provider.hint, "on_surface_variant/0.8", { maxLines = 2 }),
    }),
  })
end

function M.emptyState()
  return ui.column({ flexGrow = 1, gap = 10, align = "center", justify = "center", padding = 24 }, {
    ui.glyph({ name = "gauge", size = 40, color = "on_surface_variant" }),
    ui.label({ text = noctalia.tr("panel.empty_title"), fontSize = 15, fontWeight = "semibold", color = "on_surface" }),
    ui.label({ text = noctalia.tr("panel.empty_body"), fontSize = 12, color = "on_surface_variant", textAlign = "center", maxLines = 4 }),
  })
end

return M
