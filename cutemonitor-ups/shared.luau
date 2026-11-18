--!nonstrict
-- Shared by the service and every UI entry: shared-state keys, the stat
-- catalog, value formatting, and how a snapshot maps to words, icons and
-- colors.
--
-- Everything above "Words" is pure and covered by tests/shared_test.luau.
-- The "Words" functions translate and read Noctalia's clock, so they only run
-- inside Noctalia.

local M = {}

-- Shared-state keys

M.KEYS = {
  snapshot = "cmups.snapshot", -- latest snapshot; the last good one while the link is lost
  link = "cmups.link", -- { state = "starting"|"ok"|"lost"|"unavailable", kind, message, source, ups, lastOkAt }
  events = "cmups.events", -- event log, newest first
  policy = "cmups.policy", -- shutdown policy for the panel's Protection section
  test = "cmups.test", -- last self-test { result, text, at }, tracked for both sources
  request = "cmups.request", -- panel -> service: { id, action }
  reply = "cmups.reply", -- service -> panel: { id, ok, message }
}

-- Graph history, one key per span so an entry only receives the span it shows.
function M.seriesKey(span: string): string
  return "cmups.series." .. span
end

M.GRAPH_POINTS = 120
M.SPAN_SECONDS = { ["2m"] = 120, ["10m"] = 600, ["1h"] = 3600 }

-- Stats
-- `field` is the snapshot field; `scale` picks how graphs and gauges fill.

M.STATS = {
  battery_pct = { label = "stats.battery_pct", field = "batteryPct", icon = "battery-4", scale = "percent" },
  load_pct = { label = "stats.load_pct", field = "loadPct", icon = "bolt", scale = "percent" },
  load_w = { label = "stats.load_w", field = "loadW", icon = "bolt", scale = "rating" },
  runtime = { label = "stats.runtime", field = "runtimeSec", icon = "clock", scale = "runtime" },
  input_v = { label = "stats.input_v", field = "inputV", icon = "plug", scale = "voltage" },
  output_v = { label = "stats.output_v", field = "outputV", icon = "outlet", scale = "voltage" },
  input_hz = { label = "stats.input_hz", field = "inputHz", icon = "wave-sine", scale = "frequency" },
  output_hz = { label = "stats.output_hz", field = "outputHz", icon = "wave-sine", scale = "frequency" },
}

M.STAT_ORDER = { "battery_pct", "load_pct", "load_w", "runtime", "input_v", "output_v", "input_hz", "output_hz" }

-- Readout rows in pwrstat's order; `setting` is the desktop widget's switch,
-- shared by the rows pwrstat lists together.
M.ROWS = {
  { key = "model", setting = "row_model_firmware" },
  { key = "firmware", setting = "row_model_firmware" },
  { key = "rating_voltage", setting = "row_ratings" },
  { key = "rating_power", setting = "row_ratings" },
  { key = "state", setting = "row_state" },
  { key = "supply", setting = "row_state" },
  { key = "utility_voltage", setting = "row_voltages" },
  { key = "output_voltage", setting = "row_voltages" },
  { key = "utility_frequency", setting = "row_frequencies" },
  { key = "output_frequency", setting = "row_frequencies" },
  { key = "battery", setting = "row_battery" },
  { key = "runtime", setting = "row_battery" },
  { key = "load", setting = "row_load" },
  { key = "line", setting = "row_line" },
  { key = "test", setting = "row_test" },
  { key = "last_event", setting = "row_last_event" },
  { key = "battery_voltage", setting = "extra_nut" },
  { key = "charging", setting = "extra_nut" },
  { key = "beeper", setting = "extra_nut" },
  { key = "transfer", setting = "extra_nut" },
}

-- Formatting

local function round(x: number): number
  return math.floor(x + 0.5)
end
M.round = round

-- 4500 -> "1 h 15 min", 2220 -> "37 min", 40 -> "40 s"
function M.formatRuntime(seconds: number?): string
  if seconds == nil then
    return "—"
  end
  local s = math.max(0, round(seconds))
  if s < 60 then
    return `{s} s`
  end
  local minutes = s // 60
  if minutes < 60 then
    return `{minutes} min`
  end
  local hours, rest = minutes // 60, minutes % 60
  return if rest == 0 then `{hours} h` else `{hours} h {rest} min`
end

function M.statValue(statKey: string, snap): number?
  local stat = M.STATS[statKey]
  if stat == nil or snap == nil then
    return nil
  end
  return snap[stat.field]
end

-- One stat as display text; "—" when the UPS doesn't report it.
function M.formatStat(statKey: string, snap): string
  local value = M.statValue(statKey, snap)
  if value == nil then
    return "—"
  elseif statKey == "battery_pct" or statKey == "load_pct" then
    return `{round(value)}%`
  elseif statKey == "load_w" then
    return `{round(value)} W`
  elseif statKey == "runtime" then
    return M.formatRuntime(value)
  elseif statKey == "input_v" or statKey == "output_v" then
    return `{round(value)} V`
  end
  return string.format("%.1f Hz", value)
end

-- A stat split for big-number display: percentages stay whole ("100%"),
-- other units are drawn smaller: ("180", "W"), ("45", "min"), ("1:15", "h").
function M.heroParts(statKey: string, snap): (string, string)
  local value = M.statValue(statKey, snap)
  if value == nil then
    return "—", ""
  elseif statKey == "battery_pct" or statKey == "load_pct" then
    return `{round(value)}%`, ""
  elseif statKey == "load_w" then
    return tostring(round(value)), "W"
  elseif statKey == "runtime" then
    local s = math.max(0, round(value))
    if s < 60 then
      return tostring(s), "s"
    end
    local minutes = s // 60
    if minutes < 60 then
      return tostring(minutes), "min"
    end
    return string.format("%d:%02d", minutes // 60, minutes % 60), "h"
  elseif statKey == "input_v" or statKey == "output_v" then
    return tostring(round(value)), "V"
  end
  return string.format("%.1f", value), "Hz"
end

-- "180 W · 18%" from whichever parts are known
function M.formatLoad(snap): string?
  local parts = {}
  if snap.loadW ~= nil then
    table.insert(parts, `{round(snap.loadW)} W`)
  end
  if snap.loadPct ~= nil then
    table.insert(parts, `{round(snap.loadPct)}%`)
  end
  return if #parts > 0 then table.concat(parts, " · ") else nil
end

-- "1000 W · 1500 VA" from whichever parts are known
function M.formatRating(snap): string?
  local parts = {}
  if snap.ratingPowerW ~= nil then
    table.insert(parts, `{round(snap.ratingPowerW)} W`)
  end
  if snap.ratingPowerVA ~= nil then
    table.insert(parts, `{round(snap.ratingPowerVA)} VA`)
  end
  return if #parts > 0 then table.concat(parts, " · ") else nil
end

-- "Over Voltage" -> "Over voltage"; all-caps words such as "AVR" stay as they are.
function M.sentenceCase(text: string): string
  local index = 0
  return (text:gsub("%a+", function(word)
    index += 1
    if #word > 1 and word == word:upper() then
      return word
    end
    local lower = word:lower()
    return if index == 1 then lower:sub(1, 1):upper() .. lower:sub(2) else lower
  end))
end

-- Fills values a source leaves out but that follow from what it reports:
-- watts from load % × rating, the same arithmetic pwrstat uses.
function M.enrich(snap)
  if snap.loadW == nil and snap.loadPct ~= nil and snap.ratingPowerW ~= nil then
    snap.loadW = round(snap.loadPct * snap.ratingPowerW / 100)
    snap.loadWEstimated = true
  end
  return snap
end

-- Conditions

local ALERT_STATUSES = {
  low_battery = true,
  fault = true,
  overload = true,
  replace_battery = true,
  off = true,
  shutdown = true,
}

-- How serious things are: "none" (no UPS), "lost" (stale data), "alert",
-- "warning" (on battery, bypass, calibrating) or "normal".
function M.level(snap, link): string
  if snap == nil then
    return "none"
  elseif (link ~= nil and link.state == "lost") or snap.status == "lost_comm" then
    return "lost"
  elseif ALERT_STATUSES[snap.status] or snap.overload or snap.replaceBattery or (snap.lowBattery and snap.onBattery) then
    return "alert"
  elseif snap.onBattery or snap.status == "bypass" or snap.status == "calibrating" then
    return "warning"
  end
  return "normal"
end

-- Color for the condition as a whole: the State row, status lines, the power icon.
function M.levelColor(level: string, normal: string, colors): string
  if level == "alert" then
    return colors.alert
  elseif level == "warning" then
    return colors.warning
  elseif level == "lost" or level == "none" then
    return "on_surface_variant"
  end
  return normal
end

-- Color for one stat's number, icon, bar or line. colors = { warning, alert };
-- highLoad is the plugin-wide "High Load At" percentage.
function M.statColor(statKey: string, snap, base: string, colors, highLoad: number): string
  if snap == nil then
    return base
  end
  if statKey == "load_pct" or statKey == "load_w" then
    if snap.overload or (snap.loadPct ~= nil and snap.loadPct >= highLoad) then
      return colors.alert
    end
  elseif statKey == "battery_pct" or statKey == "runtime" then
    if snap.lowBattery and snap.onBattery then
      return colors.alert
    elseif snap.onBattery then
      return colors.warning
    end
  end
  return base
end

-- Icons

function M.batteryIcon(pct: number?): string
  if pct == nil then
    return "battery"
  elseif pct >= 75 then
    return "battery-4"
  elseif pct >= 50 then
    return "battery-3"
  elseif pct >= 25 then
    return "battery-2"
  end
  return "battery-1"
end

function M.statIcon(statKey: string, snap): string
  if statKey == "battery_pct" then
    if snap ~= nil and snap.charging == "charging" then
      return "battery-charging"
    end
    return M.batteryIcon(snap and snap.batteryPct)
  end
  return M.STATS[statKey].icon
end

-- Power-source icon: plug on utility power, the battery's charge while on
-- battery, plug-x when communication is lost, plug-off with no UPS.
function M.powerIcon(snap, level: string): string
  if level == "none" then
    return "plug-off"
  elseif level == "lost" then
    return "plug-x"
  elseif snap.onBattery then
    return M.batteryIcon(snap.batteryPct)
  end
  return "plug-connected"
end

-- Scaling

-- Graph range, following System Monitor: percentages 0–100, watts 0–rating,
-- everything else between the lowest and highest values in view (a flat line
-- sits at mid-height).
function M.graphRange(statKey: string, values: { number }, snap): (number, number)
  local scale = M.STATS[statKey].scale
  if scale == "percent" then
    return 0, 100
  elseif scale == "rating" and snap ~= nil and snap.ratingPowerW ~= nil then
    return 0, snap.ratingPowerW
  end
  local lo, hi = math.huge, -math.huge
  for _, v in values do
    lo = math.min(lo, v)
    hi = math.max(hi, v)
  end
  if lo > hi then
    return 0, 1
  elseif hi - lo < 1e-6 then
    return lo - 1, hi + 1
  end
  return lo, hi
end

-- Values mapped into 0..1 for ui.graph.
function M.normalize(values: { number }, lo: number, hi: number): { number }
  local out = table.create(#values)
  local span = hi - lo
  for i, v in values do
    out[i] = math.clamp((v - lo) / span, 0, 1)
  end
  return out
end

-- Gauge fill 0..1. Runtime is measured against the runtime reported the last
-- time the battery was full (snapshot.runtimeFullSec, kept by the service), so
-- the bar drains during an outage. Volts sit within the UPS's input range
-- (transfer points when known, else nominal ±20%); frequency within ±5% of
-- 50 or 60 Hz.
function M.gaugeFraction(statKey: string, snap): number
  local value = M.statValue(statKey, snap)
  if value == nil then
    return 0
  end
  local scale = M.STATS[statKey].scale
  if scale == "percent" then
    return math.clamp(value / 100, 0, 1)
  elseif scale == "rating" then
    return if snap.ratingPowerW then math.clamp(value / snap.ratingPowerW, 0, 1) else 0
  elseif scale == "runtime" then
    local full = snap.runtimeFullSec or value
    return if full > 0 then math.clamp(value / full, 0, 1) else 0
  elseif scale == "voltage" then
    local nominal = snap.ratingVoltage or value
    local lo = snap.transferLowV or nominal * 0.8
    local hi = snap.transferHighV or nominal * 1.2
    return if hi > lo then math.clamp((value - lo) / (hi - lo), 0, 1) else 0.5
  end
  local nominal = if value > 55 then 60 else 50
  return math.clamp((value - nominal * 0.95) / (nominal * 0.1), 0, 1)
end

-- Age as a translation key and count for the Relative date style.
function M.relativeParts(at: number, now: number): (string, number)
  local diff = math.max(0, now - at)
  if diff < 60 then
    return "time.just_now", 0
  elseif diff < 3600 then
    return "time.minutes_ago", diff // 60
  elseif diff < 86400 then
    return "time.hours_ago", diff // 3600
  end
  return "time.days_ago", diff // 86400
end

-- The newest logged power event (outages and line events, not Boost/Buck or
-- communication): the stand-in for pwrstat's "Last Power Event" with NUT.
local POWER_CATEGORIES = { outages = true, line_events = true }

function M.lastPowerEvent(events)
  for _, event in events or {} do
    if POWER_CATEGORIES[event.category] then
      return event
    end
  end
  return nil
end

-- Words: these need Noctalia for translations and the clock

-- Translated text for `key`, or nil when the key has no translation
-- (noctalia.tr returns the key itself then).
local function trOrNil(key: string, subst: { [string]: any }?): string?
  local text = noctalia.tr(key, subst)
  return if text == key then nil else text
end

-- "other" means wording we don't recognize. It's shown as the source wrote it,
-- and looking it up would only make Noctalia log a missing key.
local function known(value: string?): boolean
  return value ~= nil and value ~= "other" and value:sub(-6) ~= "_other"
end

function M.formatDate(at: number?, style: string, now: number): string
  if at == nil then
    return ""
  elseif style == "pwrstat" then
    return noctalia.formatTime("%Y/%m/%d %H:%M:%S", at)
  elseif style == "relative" then
    local key, count = M.relativeParts(at, now)
    return noctalia.trp(key, count)
  end
  -- %e pads single-digit days with a space; collapse it ("Oct  5" -> "Oct 5").
  local day = noctalia.formatTime("%b %e", at):gsub("%s+", " ")
  return `{day}, {noctalia.formatTime(noctalia.timeFormat(), at)}`
end

-- "Lost communication · last data 12 s ago"
function M.lostText(link, now: number): string
  local age = if link and link.lastOkAt then M.formatRuntime(now - link.lastOkAt) else "—"
  return noctalia.tr("link.lost", { age = age })
end

function M.statusText(snap): string
  if snap == nil then
    return noctalia.tr("status.none")
  end
  local word = if known(snap.status) then trOrNil("status." .. snap.status) else nil
  return word or M.sentenceCase(snap.stateText or snap.statusText or "")
end

function M.sourceText(snap): string?
  return if snap.supply ~= nil then noctalia.tr("source." .. snap.supply) else nil
end

function M.lineText(snap): string?
  if snap.line == nil then
    return nil
  end
  local word = if known(snap.line) then trOrNil("line." .. snap.line) else nil
  return word or (if snap.lineText then M.sentenceCase(snap.lineText) else nil)
end

-- "Passed · Oct 5, 08:22"; the date is left out when unknown.
function M.testText(test, style: string, now: number): string?
  if test == nil then
    return nil
  end
  local word = (if known(test.result) then trOrNil("test." .. test.result) else nil) or M.sentenceCase(test.text or "")
  return if test.at then `{word} · {M.formatDate(test.at, style, now)}` else word
end

-- "Over voltage · Oct 9, 00:13 · 3 s"
function M.eventText(event, style: string, now: number): string?
  if event == nil then
    return nil
  end
  local word = (if known(event.key) then trOrNil("event." .. event.key) else nil)
    or M.sentenceCase(event.text or event.key or "")
  local parts = { word }
  if event.at then
    table.insert(parts, M.formatDate(event.at, style, now))
  end
  if event.durationSec then
    table.insert(parts, M.formatRuntime(event.durationSec))
  end
  return table.concat(parts, " · ")
end

-- Value text for one Readout row, or nil when the UPS doesn't report it (the
-- row is then left out, as pwrstat does). ctx = { style, now, test, lastEvent }:
-- the service's tracked self-test and newest logged power event, for NUT,
-- which reports neither with a time.
function M.rowValue(key: string, snap, ctx): string?
  if key == "model" then
    return snap.model
  elseif key == "firmware" then
    return snap.firmware
  elseif key == "rating_voltage" then
    return if snap.ratingVoltage then `{round(snap.ratingVoltage)} V` else nil
  elseif key == "rating_power" then
    return M.formatRating(snap)
  elseif key == "state" then
    return M.statusText(snap)
  elseif key == "supply" then
    return M.sourceText(snap)
  elseif key == "utility_voltage" then
    return if snap.inputV then M.formatStat("input_v", snap) else nil
  elseif key == "output_voltage" then
    return if snap.outputV then M.formatStat("output_v", snap) else nil
  elseif key == "utility_frequency" then
    return if snap.inputHz then M.formatStat("input_hz", snap) else nil
  elseif key == "output_frequency" then
    return if snap.outputHz then M.formatStat("output_hz", snap) else nil
  elseif key == "battery" then
    return if snap.batteryPct then M.formatStat("battery_pct", snap) else nil
  elseif key == "runtime" then
    return if snap.runtimeSec then M.formatRuntime(snap.runtimeSec) else nil
  elseif key == "load" then
    return M.formatLoad(snap)
  elseif key == "line" then
    return M.lineText(snap)
  elseif key == "test" then
    local test = if snap.test and snap.test.at then snap.test else (ctx.test or snap.test)
    return M.testText(test, ctx.style, ctx.now)
  elseif key == "last_event" then
    return M.eventText(snap.lastEvent or ctx.lastEvent, ctx.style, ctx.now)
  elseif key == "battery_voltage" then
    return if snap.batteryVoltage then string.format("%.1f V", snap.batteryVoltage) else nil
  elseif key == "charging" then
    return if snap.charging then noctalia.tr("charging." .. snap.charging) else nil
  elseif key == "beeper" then
    return if snap.beeper then (trOrNil("beeper." .. snap.beeper) or M.sentenceCase(snap.beeper)) else nil
  elseif key == "transfer" then
    if snap.transferLowV and snap.transferHighV then
      return `{round(snap.transferLowV)}–{round(snap.transferHighV)} V`
    end
  end
  return nil
end

-- Text for one Status-layout detail; on battery, runtime reads "38 min left".
function M.detailText(detailKey: string, snap, ctx): string?
  if detailKey == "source" then
    return M.sourceText(snap)
  elseif detailKey == "state" then
    return M.statusText(snap)
  elseif detailKey == "line" then
    return M.lineText(snap)
  elseif detailKey == "test" or detailKey == "last_event" then
    return M.rowValue(detailKey, snap, ctx)
  elseif detailKey == "runtime" and snap.onBattery and snap.runtimeSec then
    return noctalia.tr("detail.runtime_left", { time = M.formatRuntime(snap.runtimeSec) })
  elseif M.STATS[detailKey] and M.statValue(detailKey, snap) ~= nil then
    return M.formatStat(detailKey, snap)
  end
  return nil
end

return M
