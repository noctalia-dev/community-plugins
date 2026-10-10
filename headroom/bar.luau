--!nonstrict
-- Headroom bar capsule: a logo, a ring gauge and a percentage per provider
-- (per account, when the bar shows every account).
--
-- Presentation only: it watches the report the service publishes and never
-- fetches. Left click opens the panel; right click asks the service for a
-- refresh and middle click opens the settings (both bound in plugin.toml, so
-- users can rebind them).

local state = require("./lib/state.luau")
local theme = require("./lib/theme.luau")
local view = require("./lib/view.luau")
local time = require("./lib/time.luau")
local cards = require("./ui/cards.luau")

local ICON_SIZE = 15

local report = noctalia.state.get(state.REPORT)

local function itemNodes(item, vertical: boolean, style: string, now: number)
  local account, window = item.account, item.window
  local dimmed = account.stale or account.status == "error"
  local nodes = { cards.logo(item.provider, ICON_SIZE, if dimmed and window == nil then 0.55 else nil) }

  if window == nil then
    -- Signed in but no numbers yet (first fetch running) or nothing usable.
    if account.status == "error" then
      table.insert(nodes, ui.glyph({ name = "alert-triangle", size = ICON_SIZE - 2, color = "error" }))
    else
      table.insert(nodes, ui.label({ text = "…", color = "on_surface_variant" }))
    end
    return nodes
  end

  local severity = view.severity(window, now)
  if style ~= "value" then
    local ring = theme.ring(view.shownPercent(window), theme.meterColor(severity), "surface_variant")
    if ring then
      table.insert(nodes, ui.image({ path = ring, width = ICON_SIZE, height = ICON_SIZE, opacity = if dimmed then 0.6 else 1 }))
    end
  end
  if style ~= "ring" then
    -- At the limit the percentage says nothing new; when you get it back does.
    local exhausted = window.limitReached and window.resetsAt ~= nil and window.resetsAt > now
    local text = if exhausted then time.duration(window.resetsAt - now)
      elseif vertical and not view.isPastReset(window, now) then view.roundPercent(view.shownPercent(window))
      else view.percent(window)
    table.insert(nodes, ui.label({
      text = text,
      color = view.textColor(severity),
      fontWeight = if severity == "ok" then "medium" else "bold",
      opacity = if dimmed then 0.7 else 1,
    }))
  end
  return nodes
end

-- One short row per fact, so the tooltip never truncates:
--   Claude · Weekly   59% used (cached)
--   Resets            6h 5m · 07:59
--   Forecast          ≈ 61% by reset
-- With several accounts, the first key names the account: "Claude · Work · Weekly".
local function tooltipRows(items, now: number)
  local rows = {}
  for _, item in items do
    local account, window = item.account, item.window
    if window then
      local value = view.percent(window, true)
      if account.stale then
        value ..= ` ({noctalia.tr("status.cached")})`
      end
      table.insert(rows, { key = `{item.name} · {window.label}`, value = value })
      local untilReset = view.untilReset(window, now)
      if untilReset then
        table.insert(rows, { key = noctalia.tr("tooltip.resets"), value = untilReset })
      end
      local forecast = view.pace(window, now)
      if forecast and window.usedPercent < 100 then
        table.insert(rows, { key = noctalia.tr("tooltip.forecast"), value = forecast })
      end
    else
      local value = if account.status == "error" and account.error
        then noctalia.tr(`error.{account.error.code}.title`)
        else noctalia.tr("status.fetching")
      table.insert(rows, { key = item.name, value = value })
    end
  end
  return rows
end

local function render()
  local vertical = barWidget.isVertical()
  local now = view.now()
  local maxItems = math.clamp(state.config("max_providers", 3), 1, 8)
  local shown = function(id: string): boolean
    return state.providerMode(id) == "bar"
  end
  local items = view.barItems(report, shown, state.config("window", "tightest"), maxItems, now, state.barShowsAllAccounts())

  if #items == 0 then
    barWidget.render(ui.row({ gap = 4, align = "center" }, {
      ui.glyph({ name = "gauge", size = ICON_SIZE, color = "on_surface_variant" }),
    }))
    barWidget.setTooltip(noctalia.tr("bar.empty"))
    return
  end

  local style = state.config("bar_style", "full")
  local container = if vertical then ui.column else ui.row
  local groups = {}
  for _, item in items do
    table.insert(groups, container({ gap = 4, align = "center", key = item.account.key }, itemNodes(item, vertical, style, now)))
  end
  barWidget.render(container({ gap = if vertical then 8 else 10, align = "center" }, groups))
  barWidget.setTooltip(tooltipRows(items, now))
end

noctalia.state.watch(state.REPORT, function(value)
  report = value
  render()
end)

-- Ticks only keep countdowns and the tooltip current; data arrives via watch.
function update()
  render()
end

function onClick()
  noctalia.togglePanel(state.PANEL_ID)
end

noctalia.setUpdateInterval(30000)
render()
