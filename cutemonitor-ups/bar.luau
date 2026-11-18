--!nonstrict
-- Bar item: the power-source icon (or a drawn battery) with an optional label,
-- a summary tooltip, and the detail panel on left click. In the normal state
-- it sets no colors, so the icon and text follow the bar like every other
-- item; only outage and alert states add color.

local shared = require("./shared.luau")

local KEYS = shared.KEYS
local PANEL = "cutecaption/cutemonitor-ups:details"
local TOOLTIP_ROWS = { "state", "supply", "battery", "runtime", "load", "utility_voltage" }

local displayMode = noctalia.getConfig("display_mode") or "icon"
local batteryColor = noctalia.getConfig("battery_color") or "on_surface"
local showLabel = noctalia.getConfig("show_label") ~= false
local labelContent = noctalia.getConfig("label_content") or "battery_load"
local onlyOnBattery = noctalia.getConfig("only_on_battery") == true
local colors = {
  warning = noctalia.getConfig("warning_color") or "tertiary",
  alert = noctalia.getConfig("alert_color") or "error",
}
local highLoad = tonumber(noctalia.getConfig("high_load")) or 80

-- Label content -> the stats it shows, in order
local CONTENT = {
  battery_load = { "battery_pct", "load_pct" },
  battery = { "battery_pct" },
  load = { "load_pct" },
  load_w = { "load_w" },
  runtime = { "runtime" },
}

local snap = noctalia.state.get(KEYS.snapshot)
local link = noctalia.state.get(KEYS.link)

-- "" from the shared color rules means "the bar's own color": pass nil so the
-- host default applies.
local function tint(color: string): string?
  return if color == "" then nil else color
end

-- Battery outline filled to the charge level, with the terminal cap on the right.
-- `color` is the Warning/Alert color during those states, else nil.
local function drawnBattery(pct: number?, color: string?)
  local ink = color or batteryColor
  local filled = math.floor(math.clamp((pct or 0) / 100, 0, 1) * 18 + 0.5)
  local level = {}
  if filled > 0 then
    table.insert(level, ui.box({ width = filled, height = 7, radius = 1.5, fill = ink }))
  end
  return ui.row({ gap = 1, align = "center" }, {
    ui.row({ width = 24, height = 12, padding = 2.5, radius = 3, border = ink, borderWidth = 1.3, align = "center" }, level),
    ui.box({ width = 2, height = 5, radius = 1, fill = ink }),
  })
end

local function setTooltip(level: string)
  if level == "none" then
    local starting = link == nil or link.state == "starting"
    local title = noctalia.tr(if starting then "status.starting" else "status.none")
    local reason = if link and link.message and link.message ~= "" then link.message else nil
    barWidget.setTooltip(if reason then `{title}\n{reason}` else title)
    return
  end
  local now = os.time()
  local ctx = { style = "short", now = now }
  local rows = {}
  for _, key in TOOLTIP_ROWS do
    local value = if key == "state" and level == "lost"
      then shared.lostText(link, now)
      else shared.rowValue(key, snap, ctx)
    if value ~= nil then
      table.insert(rows, { key = noctalia.tr("rows." .. key), value = value })
    end
  end
  barWidget.setTooltip(rows)
end

local tickMs = 0

local function render()
  local level = shared.level(snap, link)

  -- Tick every second while the data is stale so its age counts up; otherwise
  -- the service's updates drive rendering. This goes before the visibility
  -- check because the bar's default tick is 250 ms.
  local wanted = if level == "lost" then 1000 else 60000
  if wanted ~= tickMs then
    tickMs = wanted
    noctalia.setUpdateInterval(wanted)
  end

  local visible = not onlyOnBattery or (snap ~= nil and snap.onBattery == true)
  barWidget.setVisible(visible)
  if not visible then
    return
  end

  local vertical = barWidget.isVertical()
  local iconColor = tint(shared.levelColor(level, "", colors))
  local children = {}
  if displayMode == "battery" and snap ~= nil then
    table.insert(children, drawnBattery(snap.batteryPct, iconColor))
  elseif displayMode ~= "none" or not showLabel or snap == nil then
    table.insert(children, ui.glyph({ name = shared.powerIcon(snap, level), color = iconColor }))
  end

  if showLabel and snap ~= nil then
    local stats = table.clone(CONTENT[labelContent] or CONTENT.battery_load)
    if snap.onBattery and labelContent ~= "runtime" then
      table.insert(stats, "runtime")
    end
    if vertical then
      stats = { stats[1] }
    end
    for i, statKey in stats do
      if i > 1 then
        table.insert(children, ui.label({ text = "·" }))
      end
      table.insert(children, ui.label({
        text = shared.formatStat(statKey, snap),
        color = tint(shared.statColor(statKey, snap, "", colors, highLoad)),
      }))
    end
  end

  local opacity = if level == "lost" then 0.5 else 1
  local container = if vertical
    then ui.column({ gap = 2, align = "center", opacity = opacity }, children)
    else ui.row({ gap = 4, align = "center", opacity = opacity }, children)
  barWidget.render(container)
  setTooltip(level)
end

-- The link always arrives right after the snapshot, so it does the rendering.
noctalia.state.watch(KEYS.snapshot, function(value)
  snap = value
end)
noctalia.state.watch(KEYS.link, function(value)
  link = value
  render()
end)

-- Left click is bound to the panel in plugin.toml; this covers a removed binding.
function onClick()
  noctalia.togglePanel(PANEL)
end

function update()
  render()
end
