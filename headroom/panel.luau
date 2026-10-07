--!nonstrict
-- Headroom panel: one card per signed-in provider with every usage window.
--
-- Each window shows its usage meter with a thin time track beneath it: when the
-- meter runs ahead of the time track you are burning faster than the window
-- allows, and the pace line says when you would run out. Presentation only;
-- refreshes are requested from the service through shared state.

local state = require("./lib/state.luau")
local view = require("./lib/view.luau")
local time = require("./lib/time.luau")
local cards = require("./ui/cards.luau")

local report = noctalia.state.get(state.REPORT)
local isOpen = false
local lastRenderAt = 0

-- The vendor's own usage page, one click from its card. xdg-open runs as an
-- argv (no shell), and the URL is a constant from the provider's brand.
local canOpenUrls = noctalia.commandExists("xdg-open")

local cardOptions = {
  onOpenDashboard = if canOpenUrls
    then function(url: string)
      noctalia.runAsync({ "xdg-open", url })
      panel.close()
    end
    else nil,
}

local function isRefreshing(): boolean
  for _, provider in (if type(report) == "table" then report.providers else {}) do
    if provider.busy then
      return true
    end
  end
  return false
end

local function subtitle(now: number): string
  if type(report) ~= "table" then
    return noctalia.tr("panel.starting")
  elseif isRefreshing() then
    return noctalia.tr("status.refreshing")
  elseif report.lastRefreshAt then
    return noctalia.tr("panel.updated", { ago = time.ago(now - report.lastRefreshAt) })
  end
  return noctalia.tr("panel.not_refreshed")
end

-- ── Render ────────────────────────────────────────────────────────────────

local function render()
  if not isOpen then
    return
  end
  local now = view.now()
  lastRenderAt = now

  local connected, disconnected = {}, {}
  if type(report) == "table" and type(report.providers) == "table" then
    for _, provider in report.providers do
      if provider.status ~= "absent" then
        table.insert(connected, cards.providerCard(provider, now, cardOptions))
      else
        table.insert(disconnected, cards.disconnectedRow(provider))
      end
    end
  end

  local content
  if #connected == 0 then
    content = { cards.emptyState() }
    for _, row in disconnected do
      table.insert(content, row)
    end
  else
    content = connected
    if #disconnected > 0 then
      table.insert(content, ui.column({ gap = 8, key = "disconnected" }, disconnected))
    end
  end

  local refreshing = isRefreshing()

  panel.render(ui.column({ flexGrow = 1, gap = 14 }, {
    ui.row({ align = "center", gap = 6 }, {
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.label({ text = "Headroom", fontSize = 16, fontWeight = "bold", color = "on_surface" }),
        cards.caption(subtitle(now)),
      }),
      ui.button({
        glyph = "refresh",
        variant = "ghost",
        controlSize = "sm",
        enabled = not refreshing,
        tooltip = noctalia.tr("panel.refresh_tooltip"),
        onClick = function()
          state.requestRefresh()
        end,
      }),
      ui.button({
        glyph = "settings",
        variant = "ghost",
        controlSize = "sm",
        tooltip = noctalia.tr("panel.settings_tooltip"),
        onClick = function()
          panel.close()
          noctalia.openSettings()
        end,
      }),
    }),
    ui.scroll({ flexGrow = 1, gap = 12 }, content),
  }))
end

-- ── Host callbacks ────────────────────────────────────────────────────────

noctalia.state.watch(state.REPORT, function(value)
  report = value
  render()
end)

-- Opening the panel is a request to see current numbers: show what we have
-- immediately, and fetch anything older than this in the background.
local OPEN_FRESHNESS = 30

function onOpen(_context)
  isOpen = true
  report = noctalia.state.get(state.REPORT)
  panel.setWantsSecondTicks(true)
  render()
  state.requestRefresh(OPEN_FRESHNESS)
end

function onClose()
  isOpen = false
  panel.setWantsSecondTicks(false)
end

-- Second ticks keep "updated 2m ago" and the countdowns honest; minute
-- precision is all they show, so a re-render every 15s is plenty.
function update()
  if isOpen and view.now() - lastRenderAt >= 15 then
    render()
  end
end

function onKey(chord, pressed)
  if not pressed then
    return
  end
  if chord == "r" then
    state.requestRefresh()
  elseif chord == "escape" then
    panel.close()
  end
end
