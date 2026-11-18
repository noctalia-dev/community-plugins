--!nonstrict
-- Shift bar widget (spec §7.3): status glyph · today's worked time · progress ring, live
-- from the core snapshot. The glyph turns to an attention state for pending absences and
-- suggestions. Left click opens the dashboard; right click checks in or out.

local Commands = require("./lib/commands.luau")
local Format = require("./lib/format.luau")
local Host = require("./lib/host.luau")
local Model = require("./lib/model.luau")
local Ring = require("./lib/ring.luau")
local Types = require("./lib/types.luau")

local DASHBOARD = "hbollon/shift:dashboard"

local host = Host.new()
local snapshot: Types.Snapshot? = host.state.get("shift.snapshot")
local rendered: string? = nil -- signature of the last rendered content

local sender = Commands.sender(host, "bar", function(cmd, err)
  host.log(string.format("bar: command %s failed: %s", tostring(cmd.type), tostring(err)))
  host.notifyError(host.tr("errors.command.title"), host.tr("errors.command.body"))
end)

local function tooltip(snapshot: Types.Snapshot, live: Types.Live, fmt: Types.DurationFormat): { TooltipRow }
  local rows = {}
  local status = snapshot.status
  local statusText = host.tr("status." .. status)
  if snapshot.since then
    statusText = host.tr("status." .. status .. "_since", { time = Format.clock(host, snapshot.since) })
  end
  table.insert(rows, { key = host.tr("bar.tooltip.status"), value = statusText })

  local today = Format.duration(live.workedMs, fmt)
  if live.targetMs > 0 then
    today = host.tr("bar.tooltip.of_target", { worked = today, target = Format.duration(live.targetMs, fmt) })
  end
  table.insert(rows, { key = host.tr("bar.tooltip.today"), value = today })

  if live.etaS then
    local remaining = host.tr("bar.tooltip.remaining_eta", {
      remaining = Format.duration(live.remainingMs, fmt),
      time = Format.clock(host, live.etaS),
    })
    table.insert(rows, { key = host.tr("bar.tooltip.remaining"), value = remaining })
  elseif live.targetMs > 0 and live.overtimeMs > 0 then
    table.insert(rows, { key = host.tr("bar.tooltip.overtime"), value = "+" .. Format.duration(live.overtimeMs, fmt) })
  end

  local week = host.tr("bar.tooltip.of_target", {
    worked = Format.duration(live.weekWorkedMs, fmt),
    target = Format.duration(live.weekTargetMs, fmt),
  })
  table.insert(rows, { key = host.tr("bar.tooltip.week"), value = week })

  if #snapshot.pending > 0 then
    table.insert(rows, { key = host.tr("bar.tooltip.pending"), value = host.trp("bar.tooltip.pending_count", #snapshot.pending) })
  end
  if snapshot.suggestion then
    table.insert(rows, { key = host.tr("bar.tooltip.suggestion"), value = host.tr("bar.tooltip.suggest_" .. snapshot.suggestion) })
  end
  return rows
end

-- Status glyph (spec §7.3): what needs attention first, then the tracking status.
local function glyphOf(snapshot: Types.Snapshot): (string, boolean)
  if #snapshot.pending > 0 then
    return "clock-exclamation", true
  elseif snapshot.suggestion == "checkin" then
    return "clock-play", true
  elseif snapshot.suggestion == "checkout" then
    return "clock-pause", true
  elseif snapshot.status == "away" then
    return "clock-exclamation", true
  end
  return snapshot.status == "working" and "briefcase" or "briefcase-off", false
end

-- Widget settings (spec §7.3), per bar instance.
local STYLES = { full = true, compact = true, minimal = true }
local VALUES = { worked = true, remaining = true }
local WHEN_OFF = { show = true, dim = true, hide = true }

local function setting(key: string, allowed: { [string]: boolean }, default: string): string
  local value = host.getConfig(key)
  return allowed[value] and value or default
end

-- The ring is a secondary indicator: about 0.75x the glyph, with a thin stroke.
local RING_SIZE = 13
local RING_STROKE = 2

local function counterText(live: Types.Live, value: string, fmt: Types.DurationFormat, vertical: boolean): string
  if value == "remaining" and live.targetMs > 0 then
    if live.overtimeMs > 0 then
      return "+" .. (vertical and Format.compact(live.overtimeMs) or Format.duration(live.overtimeMs, fmt))
    end
    return vertical and Format.compact(live.remainingMs) or Format.duration(live.remainingMs, fmt)
  end
  return vertical and Format.compact(live.workedMs) or Format.duration(live.workedMs, fmt)
end

local function render()
  local vertical = barWidget.isVertical()
  if not snapshot then
    -- The core service has not published yet (it is starting or failed to load).
    if rendered ~= "waiting" then
      rendered = "waiting"
      barWidget.setVisible(true)
      barWidget.render(ui.glyph({ name = "briefcase-off", color = "on_surface_variant" }))
      barWidget.setTooltip(host.tr("bar.waiting"))
    end
    return
  end

  local style = setting("style", STYLES, "full")
  local whenOff = setting("when_off", WHEN_OFF, "dim")
  local fmt = snapshot.display.durationFormat
  local live = Model.live(snapshot, host.nowMs())
  local working = snapshot.status ~= "off"
  local muted = not working and whenOff == "dim"
  local glyph, attention = glyphOf(snapshot)

  local glyphColor = "primary"
  if attention then
    glyphColor = "secondary"
  elseif muted then
    glyphColor = "on_surface_variant"
  elseif live.targetMs > 0 and live.overtimeMs > 0 then
    glyphColor = "tertiary"
  end

  local ring
  if style == "full" and not vertical and live.targetMs > 0 then
    ring = Ring.path(host, RING_SIZE, RING_STROKE, live.workedMs / live.targetMs, muted)
  end

  local text = counterText(live, setting("value", VALUES, "worked"), fmt, vertical)
  local rows = tooltip(snapshot, live, fmt)
  -- Something to act on keeps the widget visible.
  local hidden = not working and not attention and whenOff == "hide"

  -- Re-render only when what is displayed changes, not on every tick.
  local parts = { style, text, glyph, glyphColor, tostring(working), tostring(vertical), tostring(ring), tostring(hidden) }
  for _, row in rows do
    table.insert(parts, row.key .. "=" .. row.value)
  end
  local signature = table.concat(parts, "|")
  if signature == rendered then
    return
  end
  rendered = signature

  barWidget.setVisible(not hidden)
  local children = {}
  if style ~= "minimal" then
    table.insert(children, ui.glyph({ name = glyph, color = glyphColor }))
  end
  table.insert(children, ui.label({ text = text, color = muted and "on_surface_variant" or nil }))
  if ring then
    table.insert(children, ui.image({ path = ring, width = RING_SIZE, height = RING_SIZE }))
  end
  local container = vertical and ui.column or ui.row
  barWidget.render(container({ gap = vertical and 2 or 6, align = "center" }, children))
  barWidget.setTooltip(rows)
end

host.state.watch("shift.snapshot", function(value)
  snapshot = value
  render()
end)

host.setUpdateInterval(1000)

function update()
  sender.tick()
  render()
end

function onClick()
  host.togglePanel(DASHBOARD)
end

-- Explicit check-in/check-out rather than toggle: a retried command stays harmless.
function onRightClick()
  local working = snapshot and snapshot.status ~= "off"
  sender.send({ type = working and "checkout" or "checkin" })
end
