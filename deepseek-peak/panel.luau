--!nonstrict
-- DeepSeek Peak Hours - Noctalia v5 panel entry.
-- Info panel: state, countdown, schedule, per-timezone windows, holidays,
-- drift status, plus actions (provider switch, refresh, settings).
-- Schedule logic lives in lib/schedule.luau; provider overrides in
-- lib/settings.luau.

local schedule = require("./lib/schedule.luau")
local settings = require("./lib/settings.luau")

local drift = false
local checkedAtMs = 0
local source = schedule.sourceUrl("deepseek")

local function provider()
  return settings.provider()
end

local function row(label, value, color)
  return ui.row({ gap = 8, justify = "space_between" }, {
    ui.label({ text = label, color = "on_surface_variant", fontSize = 12 }),
    ui.label({ text = value, color = color or "on_surface", fontSize = 12,
               fontWeight = "bold" }),
  })
end

local function checkedText(nowMs)
  local info = schedule.checkedInfo(nowMs, checkedAtMs)
  if info.key == "" then
    return "never"
  end
  if info.key == "checked.date" then
    return info.text
  end
  return noctalia.tr(info.key, { n = info.n })
end

local function windowLine(now, which, tz)
  local line = schedule.windowLine(now, which, tz)
  if line == nil then
    return noctalia.tr("panel.weekend-all-day")
  end
  return line
end

local function holidayText(now, which)
  local info = schedule.holidayRangeInfo(now, which)
  if not info then
    return nil
  end
  if info.active then
    return noctalia.tr("panel.holiday-ends", { date = os.date("%b %d", info.endMs) })
  end
  return noctalia.tr("panel.next-holiday", {
    range = os.date("%b %d", info.startMs) .. "–" .. os.date("%b %d", info.endMs),
    n = info.inDays,
  })
end

local function offPeakLineText(which)
  -- Mirrors v4: providers with holiday off-peak mention holidays.
  if which == "deepseek" then
    return noctalia.tr("panel.off-peak-line-holidays")
  end
  return noctalia.tr("panel.off-peak-line")
end

local function render()
  local now = os.time()
  local which = provider()
  local peak = schedule.isPeakAt(now, which)
  local state = peak and noctalia.tr("panel.peak") or noctalia.tr("panel.off-peak")
  local stateColor = peak and settings.get("peakColor", "#f87171")
    or settings.get("offPeakColor", "#4ade80")
  if drift then
    stateColor = settings.get("driftColor", "#fbbf24")
  end
  local snap = schedule.snapshot(now, which)
  local progress = snap.progress
  local holiday = holidayText(now, which)

  panel.render(ui.column({ gap = 10, padding = 14 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "circle-filled", size = 12, color = stateColor }),
      ui.label({ text = state, fontWeight = "bold", color = stateColor, flexGrow = 1 }),
    }),
    row(noctalia.tr("panel.provider"), schedule.providerName(which)),
    -- While peak, the countdown runs to off-peak and vice versa (v4 semantics).
    row(noctalia.tr(schedule.countdownLabelKey(peak)),
        schedule.formatHMS(snap.secondsToNext)),
    ui.progress({
      progress = progress,
      fill = stateColor,
      track = "surface_variant",
      radius = 2,
      height = 4,
    }),
    holiday and ui.label({ text = holiday, color = "primary", fontSize = 12 })
      or ui.spacer({}),
    ui.separator({}),
    row(noctalia.tr("panel.schedule"), schedule.scheduleText(which)),
    ui.label({ text = offPeakLineText(which), color = "on_surface_variant", fontSize = 11 }),
    ui.separator({}),
    row(noctalia.tr("panel.local"), windowLine(now, which, "local")),
    row(noctalia.tr("panel.utc"), windowLine(now, which, "utc")),
    row(noctalia.tr("panel.beijing"), windowLine(now, which, "beijing")),
    row(noctalia.tr("panel.checked"), checkedText(noctalia.nowMs())),
    drift and ui.label({ text = noctalia.tr("panel.drift"), color = "error", fontSize = 11 })
      or ui.spacer({}),
    ui.separator({}),
    ui.button({
      text = noctalia.tr("panel.provider") .. ": " .. schedule.providerName(which),
      glyph = "switch-horizontal",
      variant = "ghost",
      onClick = function()
        settings.toggleProvider()
        render()
      end,
    }),
    ui.button({
      text = noctalia.tr("menu.refresh"),
      glyph = "refresh",
      variant = "ghost",
      onClick = function()
        noctalia.state.set("deepseek-peak.cmd", "CHECK")
      end,
    }),
    ui.button({
      text = noctalia.tr("menu.settings"),
      glyph = "settings",
      variant = "ghost",
      onClick = function()
        noctalia.openSettings()
      end,
    }),
    ui.label({ text = source, color = "on_surface_variant", fontSize = 10, maxLines = 2 }),
  }))
end

function onOpen(_context)
  render()
end

function onClose()
end

function update()
  render()
end

drift = noctalia.state.get("deepseek-peak.drift") == true
checkedAtMs = noctalia.state.get("deepseek-peak.checkedAtMs") or 0
source = noctalia.state.get("deepseek-peak.source") or schedule.sourceUrl(provider())

noctalia.state.watch("deepseek-peak.drift", function(value)
  drift = value == true
  render()
end)

noctalia.state.watch("deepseek-peak.checkedAtMs", function(value)
  checkedAtMs = value or 0
  render()
end)

noctalia.state.watch("deepseek-peak.source", function(value)
  source = value or source
  render()
end)

settings.watch(function()
  render()
end)

panel.setWantsSecondTicks(true)
