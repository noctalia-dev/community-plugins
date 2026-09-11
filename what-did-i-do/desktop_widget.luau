-- desktop_widget.luau — standalone desktop widget entry ([[desktop_widget]]).
--
-- A compact glanceable summary of today's tracked time for the desktop:
-- total, top applications, application count and tracking state. It is a
-- pure consumer of the service's shared "wdid_state" — no polling, no
-- tracker, no background processes (only the [[service]] owns tracking).
-- The panel remains the detailed interface.
--
-- Interaction: clicking the summary opens/toggles the dashboard panel.
-- Application rows carry the technical app id as their tooltip (the human
-- label stays primary) — ui.button is the tooltip-capable control.
--
-- RTL: rows are plain label/duration pairs justified with space_between, so
-- they mirror with the surface's writing direction; no directional arrows.

local formatting = require("./lib/formatting.luau")
local appnames = require("./lib/appnames.luau")
local appicons = require("./lib/appicons.luau")

formatting._tr = noctalia.tr

local TOP_ROWS = 5

local displayNames = appnames.newResolver({
  readFile = noctalia.readFile,
  listDir = noctalia.listDir,
  getenv = noctalia.getenv,
})

-- Same shared icon helper as the panel: technical app_id → cached icon path
-- (misses cached too). No second data source, no extra polling — the widget
-- still consumes only the service's wdid_state.
local icons = appicons.newResolver({ appIconPath = noctalia.appIconPath })

noctalia.setUpdateInterval(1000) -- keep the open-session total ticking

local function snapshot()
  return noctalia.state.get("wdid_state") or {}
end

-- Drops nil entries from a children list: a nil in the array is a hole in
-- the UI tree (host warning per render). select("#", ...) is hole-safe.
local function kidsList(...)
  local n = select("#", ...)
  local out = {}
  for i = 1, n do
    local v = select(i, ...)
    if v ~= nil then
      out[#out + 1] = v
    end
  end
  return out
end

local function appRow(rank, app, total)
  local seconds = tonumber(app.seconds) or 0
  local appId = tostring(app.appId or app.appName or "?")
  local displayName = displayNames.resolve(app.appId, app.appName)
  -- Icon keyed on the technical app_id; nil simply omits the node so the
  -- compact row layout survives an unresolvable icon unchanged.
  local leading
  do
    local iconPath = icons.resolve(appId, 24)
    if iconPath then
      leading = ui.image({ path = iconPath, width = 16, height = 16, radius = 4 })
    end
  end
  local share = 0
  if total > 0 then
    share = math.min(1, seconds / total)
  end
  return ui.row({
    key = "dw-app-" .. rank .. "-" .. appId,
    gap = 8,
    align = "center",
    justify = "space_between",
  }, {
    ui.row({ gap = 8, align = "center" }, kidsList(
      ui.label({ text = tostring(rank), fontSize = 11, color = "on_surface/0.5", width = 14 }),
      leading,
      ui.button({
        key = "dw-app-name-" .. rank .. "-" .. appId,
        text = displayName,
        fontSize = 13,
        variant = "ghost",
        contentAlign = "start",
        tooltip = noctalia.tr("panel.app_id_tip") .. " " .. appId,
        onClick = function() end,
      })
    )),
    ui.row({ gap = 8, align = "center" }, {
      ui.progress({
        progress = share,
        width = 50,
        height = 4,
        radius = 2,
        fill = "primary/0.7",
        track = "on_surface/0.08",
      }),
      ui.label({
        text = formatting.fmtDuration(seconds),
        fontSize = 12,
        color = "on_surface/0.8",
      }),
    }),
  })
end

local function render()
  local s = snapshot()
  local paused = s.paused == true or s.tracking == false
  -- Phase 1 portability: on an unsupported compositor the service publishes
  -- trackingAvailable = false. The widget stays alive, keeps the historical
  -- summary, and never pretends the (non-existent) live session is ticking:
  -- the open-session extrapolation below is gated off.
  local unavailable = s.trackingAvailable == false

  -- Today's total plus the live open session since the last publish — only
  -- when tracking actually exists; history alone must not appear to tick.
  local total = tonumber(s.todayTotal) or 0
  local since = tonumber(s.currentAppSinceMs)
  if not paused and not unavailable and since then
    total = total + math.max(0, math.floor((noctalia.nowMs() - since) / 1000))
  end

  local kids = {}

  -- Header: title + tracking state (paused / unavailable / live).
  kids[#kids + 1] = ui.row({ gap = 6, align = "center" }, {
    ui.glyph({
      name = unavailable and "plug-off" or (paused and "player-pause" or "clock-hour-4"),
      size = 15,
      color = (paused or unavailable) and "on_surface/0.6" or "primary",
    }),
    ui.label({
      text = noctalia.tr("widget.tooltip.title"),
      fontSize = 13,
      fontWeight = "semibold",
      color = "on_surface/0.8",
    }),
  })

  -- Glanceable total.
  kids[#kids + 1] = ui.label({
    text = formatting.fmtDuration(total),
    fontSize = 28,
    fontWeight = "bold",
    color = "primary",
  })
  kids[#kids + 1] = ui.label({
    text = unavailable and noctalia.tr("panel.unavailable")
      or paused and noctalia.tr("panel.paused_banner")
      or noctalia.tr("widget.tooltip.active"),
    fontSize = 12,
    color = "on_surface/0.6",
  })

  -- Top applications (compact; the panel holds the full history). Rows the
  -- aggregator dropped as zero-second stay out; when nothing measurable
  -- happened today the widget shows a quiet hint instead of a "0m" list.
  local topApps = type(s.todayTopApps) == "table" and s.todayTopApps or {}
  if #topApps > 0 then
    kids[#kids + 1] = ui.separator({ spacing = 8 })
    for i = 1, math.min(#topApps, TOP_ROWS) do
      kids[#kids + 1] = appRow(i, topApps[i], tonumber(s.todayTotal) or 0)
    end
    kids[#kids + 1] = ui.label({
      text = noctalia.trp("panel.apps_count", tonumber(s.todayApps) or 0, { count = tonumber(s.todayApps) or 0 }),
      fontSize = 11,
      color = "on_surface/0.5",
    })
  else
    kids[#kids + 1] = ui.label({
      text = noctalia.tr("desktop_widget.empty_apps"),
      fontSize = 11,
      color = "on_surface/0.5",
    })
  end

  -- Click anywhere on the summary toggles the dashboard panel (a flex
  -- container's onClick makes the whole subtree a click target).
  desktopWidget.render(ui.column({ gap = 6, padding = 10, onClick = function()
    noctalia.togglePanel("alitura1/what-did-i-do:dashboard")
  end }, kids))
end

function update()
  render()
end

noctalia.state.watch("wdid_state", function(_value)
  render()
end)

render()
