--!nonstrict
-- History tab (spec §6.8.1, §7.4.5): a week of bars against the target, or a month
-- calendar tinted by the worked time. Clicking a day opens the day editor. The days come
-- from `shift.history`, which the panel requests for the range it shows.

local Format = require("../format.luau")
local Time = require("../time.luau")
local Types = require("../types.luau")
local Widgets = require("./widgets.luau")

type View = Widgets.View
type DaySummary = Types.DaySummary
type HistoryInfo = Types.HistoryInfo

export type HistoryState = {
  mode: "week" | "month",
  anchor: string, -- a day of the week or month shown
}

local History = {}

local HOUR_MS = 3600000
local MINUTE_MS = 60000
local BAR_HEIGHT = 128
local BAR_WIDTH = 18
local MARKER_SIZE = 12
local CELL_HEIGHT = 46

local function firstOfMonth(dateKey: string): string
  local year, month = Time.parseDate(dateKey)
  return Time.dateKey(year :: number, month :: number, 1)
end

local function addMonths(dateKey: string, months: number): string
  local year, month = Time.parseDate(dateKey)
  local index = (year :: number) * 12 + (month :: number) - 1 + months
  return Time.dateKey(index // 12, index % 12 + 1, 1)
end

-- Days shown for a mode: one ISO week, or the whole weeks covering a month.
function History.range(state: HistoryState): (string, string)
  if state.mode == "week" then
    local from = Time.weekStart(state.anchor)
    return from, Time.addDays(from, 6)
  end
  local first = firstOfMonth(state.anchor)
  local last = Time.addDays(addMonths(first, 1), -1)
  return Time.weekStart(first), Time.addDays(Time.weekStart(last), 6)
end

-- Worked time of a day, with the running session for today.
local function workedOf(view: View, day: DaySummary): number
  if day.date == view.snap.today.date then
    return view.live.workedMs
  end
  return day.workedMs
end

-- "Thu 08 Oct · 7:12 / 7:00 · +0:12 · Armistice 1918"
local function tooltip(view: View, day: DaySummary): string
  local host, fmt = view.host, view.snap.display.durationFormat
  local worked = workedOf(view, day)
  local parts = { Widgets.date(host, day.date, "%a %d %b") }
  if day.targetMs > 0 then
    table.insert(parts, Format.duration(worked, fmt) .. " / " .. Format.duration(day.targetMs, fmt))
    table.insert(parts, Format.signed(worked - day.targetMs, fmt))
  else
    table.insert(parts, Format.duration(worked, fmt))
  end
  if day.holiday then
    table.insert(parts, day.holiday)
  end
  if day.dayOff then
    table.insert(parts, host.tr("panel.day.status.day_off"))
  end
  if day.missing then
    table.insert(parts, host.tr("panel.day.status.missing"))
  end
  if day.needsReview then
    table.insert(parts, host.tr("panel.day.status.needs_review"))
  end
  return table.concat(parts, " · ")
end

-- Glyph or dot telling a day's status at a glance: holiday, day off, missing, or above
-- or below the target. Never color alone (spec §7.7): each has its own shape.
local function marker(view: View, day: DaySummary): UiNode
  local worked = workedOf(view, day)
  if day.holiday then
    return ui.glyph({ name = "beach", size = MARKER_SIZE, color = "on_surface_variant" })
  elseif day.dayOff then
    return ui.glyph({ name = "calendar-off", size = MARKER_SIZE, color = "on_surface_variant" })
  elseif day.missing then
    return ui.row({ width = MARKER_SIZE, height = MARKER_SIZE, align = "center", justify = "center" }, {
      ui.box({ width = 6, height = 6, radius = 3, fill = "secondary" }),
    })
  elseif day.date < view.snap.today.date and (day.targetMs > 0 or worked > 0) then
    if worked - day.targetMs >= MINUTE_MS then
      return ui.glyph({ name = "caret-up", size = MARKER_SIZE, color = "tertiary" })
    elseif day.targetMs - worked >= MINUTE_MS then
      return ui.glyph({ name = "caret-down", size = MARKER_SIZE, color = "on_surface_variant" })
    end
  end
  return ui.box({ width = MARKER_SIZE, height = MARKER_SIZE, opacity = 0 })
end

local function header(view: View, state: HistoryState, title: string, step: (delta: number) -> (), current: boolean): UiNode
  local host = view.host
  local function modeButton(mode: "week" | "month"): UiNode
    return ui.button({
      text = host.tr("panel.history." .. mode),
      variant = state.mode == mode and "secondary" or "ghost",
      controlSize = "sm",
      onClick = function()
        state.mode = mode
        view.render()
      end,
    })
  end
  return ui.row({ align = "center", gap = 2 }, {
    ui.button({
      glyph = "chevron-left",
      variant = "ghost",
      controlSize = "sm",
      tooltip = host.tr("panel.history.previous"),
      onClick = function()
        step(-1)
      end,
    }),
    ui.label({ text = title, fontWeight = "medium", flexGrow = 1, textAlign = "center" }),
    ui.button({
      glyph = "chevron-right",
      variant = "ghost",
      controlSize = "sm",
      tooltip = host.tr("panel.history.next"),
      onClick = function()
        step(1)
      end,
    }),
    ui.button({
      glyph = "calendar-event",
      variant = "ghost",
      controlSize = "sm",
      enabled = not current,
      tooltip = host.tr("panel.history.today"),
      onClick = function()
        state.anchor = view.snap.today.date
        view.render()
      end,
    }),
    modeButton("week"),
    modeButton("month"),
  })
end

-- Week ---------------------------------------------------------------------------------

-- A day's bar, bottom-up: worked time in `primary` up to the target, then `tertiary`, with
-- the target as a 1 px `outline` tick. Without a target, all of it is overtime.
local function bar(worked: number, target: number, scale: number): UiNode
  local nodes = {}
  local function segment(ms: number, fill: string)
    local height = math.round(ms * scale)
    if height >= 1 then
      table.insert(nodes, ui.box({ width = BAR_WIDTH, height = height, radius = 3, fill = fill }))
    end
  end
  if target > 0 then
    segment(math.max(0, worked - target), "tertiary")
    table.insert(nodes, ui.box({ width = BAR_WIDTH + 8, height = 1, fill = "outline" }))
    local gap = math.round((target - math.min(worked, target)) * scale)
    if gap >= 1 then
      table.insert(nodes, ui.box({ width = BAR_WIDTH, height = gap, opacity = 0 }))
    end
    segment(math.min(worked, target), "primary")
  else
    segment(worked, "tertiary")
  end
  return ui.column({ height = BAR_HEIGHT + 1, justify = "end", align = "center", gap = 0 }, nodes)
end

local function weekView(view: View, state: HistoryState, byDate: { [string]: DaySummary }): { UiNode }
  local host, fmt = view.host, view.snap.display.durationFormat
  local from, to = History.range(state)
  local days, top = {}, HOUR_MS
  for offset = 0, 6 do
    local day = byDate[Time.addDays(from, offset)]
    if day then
      table.insert(days, day)
      top = math.max(top, workedOf(view, day), day.targetMs)
    end
  end
  local today = view.snap.today.date
  local current = from <= today and today <= to
  local title = Widgets.date(host, from, "%d %b") .. " – " .. Widgets.date(host, to, "%d %b")
  local children = {
    header(view, state, title, function(delta)
      state.anchor = Time.addDays(state.anchor, 7 * delta)
      view.render()
    end, current),
  }
  if #days < 7 then
    table.insert(children, ui.label({ text = host.tr("panel.history.loading"), color = "on_surface_variant", fontSize = 12 }))
    return children
  end

  local scale = BAR_HEIGHT / top
  local columns, worked, target = {}, 0, 0
  for _, day in days do
    local dayWorked = workedOf(view, day)
    worked += dayWorked
    target += day.targetMs
    table.insert(columns, ui.column({
      flexGrow = 1,
      align = "center",
      gap = 4,
      opacity = day.date > today and 0.5 or 1,
      tooltip = tooltip(view, day),
      onClick = function()
        view.openEditor(day.date)
      end,
    }, {
      bar(dayWorked, day.targetMs, scale),
      marker(view, day),
      ui.label({
        text = Widgets.date(host, day.date, "%a"),
        fontSize = 12,
        fontWeight = day.date == today and "bold" or nil,
        color = day.date == today and "primary" or "on_surface_variant",
      }),
      ui.label({ text = dayWorked > 0 and Format.duration(dayWorked, fmt) or "–", fontSize = 12 }),
    }))
  end
  table.insert(children, ui.row({ gap = 4 }, columns))
  local total = Format.duration(worked, fmt)
  if target > 0 then
    total ..= " / " .. Format.duration(target, fmt)
  end
  table.insert(children, ui.row({ align = "center" }, {
    ui.label({ text = host.tr("panel.history.week_total"), flexGrow = 1, color = "on_surface_variant", fontSize = 12 }),
    ui.label({ text = total, fontWeight = "bold" }),
  }))
  return children
end

-- Month --------------------------------------------------------------------------------

-- Cell fill: the share of the target worked, as a `primary` tint light enough for the
-- text on it; overtime-only days in `tertiary`.
local function tint(worked: number, target: number): string
  if worked <= 0 then
    return "on_surface/0.05"
  elseif target <= 0 then
    return "tertiary/0.25"
  end
  return string.format("primary/%.2f", 0.10 + 0.25 * math.min(1, worked / target))
end

local function monthView(view: View, state: HistoryState, byDate: { [string]: DaySummary }): { UiNode }
  local host, fmt = view.host, view.snap.display.durationFormat
  local first = firstOfMonth(state.anchor)
  local today = view.snap.today.date
  local children = {
    header(view, state, Widgets.date(host, first, "%B %Y"), function(delta)
      state.anchor = addMonths(first, delta)
      view.render()
    end, firstOfMonth(today) == first),
  }
  local from, to = History.range(state)
  if not byDate[from] or not byDate[to] then
    table.insert(children, ui.label({ text = host.tr("panel.history.loading"), color = "on_surface_variant", fontSize = 12 }))
    return children
  end

  local names = {}
  for offset = 0, 6 do
    table.insert(names, ui.label({
      text = Widgets.date(host, Time.addDays(from, offset), "%a"),
      flexGrow = 1,
      textAlign = "center",
      fontSize = 12,
      color = "on_surface_variant",
    }))
  end
  local rows = { ui.row({ gap = 4 }, names) }
  local month = string.sub(first, 1, 7)
  local week = {}
  local cursor = from
  while cursor <= to do
    local date = cursor -- one per cell: the click handler keeps its own
    local day = byDate[date]
    local worked = workedOf(view, day)
    local _, _, dayOfMonth = Time.parseDate(date)
    table.insert(week, ui.column({
      flexGrow = 1,
      height = CELL_HEIGHT,
      gap = 2,
      padding = 4,
      radius = 6,
      fill = tint(worked, day.targetMs),
      border = date == today and "primary" or nil,
      borderWidth = date == today and 1 or nil,
      opacity = string.sub(date, 1, 7) == month and 1 or 0.45,
      tooltip = tooltip(view, day),
      onClick = function()
        view.openEditor(date)
      end,
    }, {
      ui.row({ align = "center", justify = "space_between" }, {
        ui.label({ text = tostring(dayOfMonth), fontSize = 12, color = "on_surface" }),
        marker(view, day),
      }),
      -- Without spaces, "7h 12m" fits a cell.
      ui.label({ text = worked > 0 and (string.gsub(Format.duration(worked, fmt), "%s", "")) or "", fontSize = 12, fontWeight = "bold" }),
    }))
    if #week == 7 then
      table.insert(rows, ui.row({ gap = 4 }, week))
      week = {}
    end
    cursor = Time.addDays(cursor, 1)
  end
  table.insert(children, ui.column({ gap = 4 }, rows))
  return children
end

-- The tab's content. `history` is the latest `shift.history` value, nil before the first.
function History.render(view: View, state: HistoryState, history: HistoryInfo?): UiNode
  local byDate = {}
  if history then
    for _, day in history.days do
      byDate[day.date] = day
    end
  end
  local children = if state.mode == "week" then weekView(view, state, byDate) else monthView(view, state, byDate)
  return ui.column({ gap = 10 }, children)
end

return History
