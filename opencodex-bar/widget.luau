--!nonstrict
-- Compact bar view: one indicator and how much of the quota is spent across
-- every account.
-- All data comes from the service snapshot.

local common = require("./common.luau")

local PANEL_ID = "wy3z/opencodex-bar:panel"

-- The bar keeps the theme's own ink until things are actually urgent, then goes
-- red past 90% used. OpenCodex's --red, light and dark.
local CRITICAL_USED = 90
local RED = { light = "#b91c1c", dark = "#f87171" }

-- `theme_colors` (plugin-level, so the bar and the panel move together) swaps
-- OpenCodex's red for Noctalia's own error role.
local function pick(pair)
  if common.themeColors() then return "error" end
  return noctalia.isDarkMode() and pair.dark or pair.light
end

local function configured(key, fallback)
  local value = noctalia.getConfig(key)
  if value == nil then return fallback end
  return value
end

-- Mean consumption over every account that reports a quota: "you have spent
-- this much of your capacity".
local function cumulativeUsed(snapshot)
  local total, counted = 0, 0
  for _, provider in ipairs(snapshot.providers or {}) do
    if common.providerVisible(provider) then
      local hasAccountQuota = common.anyAccountQuota(provider)
      for _, account in ipairs(provider.accounts or {}) do
        local used = common.accountUsed(provider, account, hasAccountQuota)
        if used ~= nil then
          total = total + used
          counted = counted + 1
        end
      end
    end
  end
  if counted == 0 then return nil end
  return total / counted, counted
end

-- Which provider the mark speaks for: whichever account OpenCodex is currently
-- routing through. With nothing marked active, the tightest provider is a
-- better guess than an arbitrary first entry.
local function iconProvider(snapshot)
  local fallback, tightestId, tightestUsed = nil, nil, nil
  for _, provider in ipairs(snapshot.providers or {}) do
    if common.providerVisible(provider) then
      if fallback == nil then fallback = provider.id end
      local hasAccountQuota = common.anyAccountQuota(provider)
      for _, account in ipairs(provider.accounts or {}) do
        if account.active == true then return provider.id end
        local used = common.accountUsed(provider, account, hasAccountQuota)
        if used ~= nil and (tightestUsed == nil or used > tightestUsed) then
          tightestUsed = used
          tightestId = provider.id
        end
      end
    end
  end
  return tightestId or fallback
end

-- Provider marks are kept slightly smaller than the base glyph metric so their
-- dense brand shapes match the visual weight of the usage gauge.
local MARK_SIZE = 13
local GAUGE_H = 12
local GAUGE_W = 8
-- Keep a chip large enough that bar hide/show (Control Center) cannot collapse
-- the plugin InputArea to an unclickable sliver.
local CHIP_MIN = 18

local lastVisual = nil
local lastTooltip = nil

local function usedColorFor(used)
  if used == nil then return "on_surface" end
  return used >= CRITICAL_USED and pick(RED) or "on_surface"
end

-- A vertical gauge for the aggregate figure: it fills as quota is spent, so a
-- full gauge means no headroom left. ui.progress cannot do this: ProgressBar
-- supports a Vertical orientation internally, but the reconciler never exposes
-- it, so the gauge is a track column holding a level box pinned to the bottom.
-- Always draw the track, even with no quota: a nil icon made the chip vanish
-- after a bar hide/show until the next snapshot, which ate the first clicks.
local function usageGauge(used)
  local level = type(used) == "number" and math.max(0, math.min(100, used)) / 100 or 0
  -- Keep a sliver visible at zero so the gauge never reads as "no data".
  local filled = level <= 0 and 1 or math.max(2, math.floor(GAUGE_H * level + 0.5))
  return ui.column({
    key = "gauge",
    width = GAUGE_W,
    height = GAUGE_H,
    minWidth = GAUGE_W,
    minHeight = GAUGE_H,
    radius = 3,
    fill = "on_surface/0.18",
    justify = "end",
    align = "stretch",
  }, {
    ui.box({
      key = "level",
      width = GAUGE_W,
      height = filled,
      radius = 2,
      fill = usedColorFor(used),
    }),
  })
end

local function usedColor(used, status)
  if status == "offline" or status == "auth_error" then return pick(RED) end
  if used == nil then return "on_surface" end
  return usedColorFor(used)
end

local function tooltip(snapshot, used, counted)
  local lines = { noctalia.tr("panel.title") }
  if used ~= nil then
    table.insert(lines, noctalia.trp("bar.used_tooltip", counted, {
      used = string.format("%.0f", used),
      count = tostring(counted),
    }))
  else
    table.insert(lines, noctalia.tr("bar.no_quota"))
  end
  if snapshot.error ~= nil and snapshot.error.kind ~= nil then
    table.insert(lines, noctalia.tr("status." .. snapshot.error.kind))
  end
  return table.concat(lines, "\n")
end

local function render(snapshot)
  snapshot = snapshot or {}
  local status = snapshot.status or "loading"
  local used, counted = cumulativeUsed(snapshot)
  local color = usedColor(used, status)

  local mode = configured("icon_source", "bars")
  local showPct = configured("show_percentage", true)
  local critical = used ~= nil and used >= CRITICAL_USED
  local usedText = used ~= nil and string.format("%.0f%%", used) or "—"
  local glyph = nil
  if mode ~= "bars" then
    glyph = mode == "fixed"
      and configured("glyph", "brand-openai")
      or common.providerGlyph(iconProvider(snapshot)) or "robot"
    if critical and mode ~= "fixed" then glyph = "alert-triangle-filled" end
  end

  local tip = tooltip(snapshot, used, counted or 0)
  local visual = table.concat({
    mode, glyph or "", usedText, tostring(color), tostring(showPct), noctalia.isDarkMode() and "d" or "l",
  }, "|")
  if visual == lastVisual then
    if tip ~= lastTooltip then
      lastTooltip = tip
      barWidget.setTooltip(tip)
    end
    return
  end
  lastVisual = visual
  lastTooltip = tip

  local icon = mode == "bars" and usageGauge(used)
    or ui.glyph({ key = "glyph", name = glyph, size = MARK_SIZE, color = color })

  local children = { icon }
  if showPct then
    table.insert(children, ui.label({
      key = "used",
      text = usedText,
      color = color,
    }))
  end

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({
    key = "chip",
    gap = 4,
    align = "center",
    minWidth = CHIP_MIN,
    minHeight = CHIP_MIN,
    paddingH = 4,
  }, children))
  barWidget.setTooltip(tip)
end

noctalia.state.watch("snapshot", function(value)
  render(value)
end)

-- Fallback when the left widget action is unbound. With the default
-- `panel-toggle` binding, the host consumes left-click and this does not fire.
function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
  noctalia.state.set("command", { type = "refresh", nonce = noctalia.nowMs() })
end

-- Nothing here is time-driven: renders are pushed by the snapshot watcher, so
-- the host's update tick only needs to exist, not to be frequent.
noctalia.setUpdateInterval(600000)
render(noctalia.state.get("snapshot"))
