--!nonstrict
-- Day editor (spec §6.8.2): a day's target, worked time and statuses, the review actions
-- of a missing day, the day-off toggle, and its sessions as start/end inputs. Save sends
-- the whole day at once (`day.save`); Cancel drops the draft.
--
-- Pending absences only exist today; their buttons apply at once, like the attention
-- cards, and the sessions stay locked until they are resolved.

local Format = require("../format.luau")
local Model = require("../model.luau")
local Time = require("../time.luau")
local Types = require("../types.luau")
local Widgets = require("./widgets.luau")

type View = Widgets.View
type DaySummary = Types.DaySummary

-- One session row. A text the user did not change keeps its exact epoch, seconds
-- included, so saving an untouched session leaves it as it was.
type Row = { id: number, start: string, ["end"]: string, startS: number?, endS: number?, startText: string?, endText: string? }

type Draft = {
  rows: { Row },
  openStart: string?, -- start of the running session, when it belongs to this day
  openStartS: number?,
  openText: string?,
  dayOff: boolean,
  dirty: boolean,
  basis: string, -- the data the draft was built from
}

export type EditorState = {
  date: string,
  draft: Draft?,
  confirm: boolean, -- marking a day with sessions as a day off asks first
  nextRow: number,
}

local Editor = {}

local INPUT_WIDTH = 88
local ROW_HEIGHT = 32

function Editor.new(date: string): EditorState
  return { date = date, draft = nil, confirm = false, nextRow = 1 }
end

local function clock(view: View, epochS: number): string
  return Format.clock(view.host, epochS)
end

-- Start of the running session when it counts toward `date`.
local function openStartOf(view: View, date: string): number?
  local today = view.snap.today
  return today.date == date and today.openStartMs and today.openStartMs // 1000 or nil
end

local function basisOf(view: View, day: DaySummary): string
  local parts = { tostring(day.dayOff), tostring(openStartOf(view, day.date)) }
  for _, session in day.sessions do
    table.insert(parts, session.startS .. "-" .. session.endS)
  end
  return table.concat(parts, "|")
end

local function newRow(state: EditorState): Row
  local row = { id = state.nextRow, start = "", ["end"] = "" }
  state.nextRow += 1
  return row
end

local function buildDraft(view: View, state: EditorState, day: DaySummary): Draft
  local rows = {}
  for _, session in day.sessions do
    local row = newRow(state)
    row.start, row.startS = clock(view, session.startS), session.startS
    row["end"], row.endS = clock(view, session.endS), session.endS
    row.startText, row.endText = row.start, row["end"]
    table.insert(rows, row)
  end
  local draft = { rows = rows, dayOff = day.dayOff, dirty = false, basis = basisOf(view, day) }
  local openStartS = openStartOf(view, day.date)
  if openStartS then
    draft.openStart, draft.openStartS, draft.openText = clock(view, openStartS), openStartS, clock(view, openStartS)
  end
  return draft
end

-- Epoch of a typed time inside the edited workday; the original epoch when unchanged.
local function epochOf(view: View, date: string, text: string, original: string?, originalS: number?): number?
  if original and text == original then
    return originalS
  end
  local minutes = Time.parseClock(text)
  return minutes and Time.workdayClockS(date, minutes, view.snap.contract.dayStartHour)
end

-- The draft as `day.save` sessions, or nil and the error to show.
local function parse(view: View, state: EditorState): (any?, string?)
  local draft = state.draft :: Draft
  local date = state.date
  local sessions = {}
  for _, row in draft.rows do
    local startS = epochOf(view, date, row.start, row.startText, row.startS)
    local endS = epochOf(view, date, row["end"], row.endText, row.endS)
    if not startS or not endS then
      return nil, "parse"
    end
    table.insert(sessions, { startS = startS, endS = endS })
  end
  local openStartS
  if draft.openStart then
    openStartS = epochOf(view, date, draft.openStart, draft.openText, draft.openStartS)
    if not openStartS then
      return nil, "parse"
    end
  end
  local _, reason = Model.validateDay({ date = date, sessions = sessions, openStartS = openStartS }, view.snap.contract.dayStartHour, view.nowS)
  if reason then
    return nil, reason
  end
  return { sessions = sessions, openStartS = openStartS }
end

local function close(view: View, state: EditorState)
  state.draft = nil
  view.closeEditor()
end

local function statusChips(view: View, day: DaySummary, pending: boolean): UiNode
  local host = view.host
  local chips = {}
  if day.holiday then
    table.insert(chips, Widgets.chip(day.holiday, "beach"))
  end
  if day.dayOff then
    table.insert(chips, Widgets.chip(host.tr("panel.day.status.day_off"), "calendar-off"))
  end
  if day.missing then
    table.insert(chips, Widgets.chip(host.tr("panel.day.status.missing"), "help-circle", "secondary"))
  end
  if day.needsReview then
    table.insert(chips, Widgets.chip(host.tr("panel.day.status.needs_review"), "alert-circle", "secondary"))
  end
  if pending then
    table.insert(chips, Widgets.chip(host.tr("panel.day.status.pending"), "clock-exclamation", "secondary"))
  end
  return ui.row({ gap = 6 }, chips)
end

local function sessionRow(view: View, state: EditorState, row: Row, enabled: boolean): UiNode
  local host, draft = view.host, state.draft :: Draft
  local startS = epochOf(view, state.date, row.start, row.startText, row.startS)
  local endS = epochOf(view, state.date, row["end"], row.endText, row.endS)
  local duration = (startS and endS and endS > startS) and Format.duration((endS - startS) * 1000, view.snap.display.durationFormat) or ""
  local function input(field: "start" | "end"): UiNode
    return ui.input({
      key = string.format("%s:%s:%d", field, state.date, row.id),
      value = row[field],
      placeholder = field == "start" and "09:00" or "17:00",
      width = INPUT_WIDTH,
      controlSize = "sm",
      enabled = enabled,
      onChange = function(value)
        row[field] = value
        draft.dirty = true
        view.render()
      end,
    })
  end
  return ui.row({ key = "row:" .. row.id, align = "center", gap = 6, height = ROW_HEIGHT }, {
    input("start"),
    ui.label({ text = "–", color = "on_surface_variant" }),
    input("end"),
    ui.label({ text = duration, flexGrow = 1, textAlign = "end", fontWeight = "bold" }),
    ui.button({
      glyph = "trash",
      variant = "ghost",
      controlSize = "sm",
      enabled = enabled,
      tooltip = host.tr("panel.day.delete_session"),
      onClick = function()
        local index = table.find(draft.rows, row)
        if index then
          table.remove(draft.rows, index)
          draft.dirty = true
          view.render()
        end
      end,
    }),
  })
end

local function openRow(view: View, state: EditorState, enabled: boolean): UiNode
  local host, draft = view.host, state.draft :: Draft
  local startS = epochOf(view, state.date, draft.openStart :: string, draft.openText, draft.openStartS)
  local duration = startS and startS < view.nowS and Format.duration((view.nowS - startS) * 1000, view.snap.display.durationFormat) or ""
  return ui.row({ key = "row:open", align = "center", gap = 6, height = ROW_HEIGHT }, {
    ui.input({
      key = "open:" .. state.date,
      value = draft.openStart,
      width = INPUT_WIDTH,
      controlSize = "sm",
      enabled = enabled,
      onChange = function(value)
        draft.openStart = value
        draft.dirty = true
        view.render()
      end,
    }),
    ui.label({ text = "–", color = "on_surface_variant" }),
    ui.label({ text = host.tr("panel.today.now"), width = INPUT_WIDTH, color = "primary" }),
    ui.label({ text = duration, flexGrow = 1, textAlign = "end", fontWeight = "bold" }),
    -- Keeps the columns aligned with the rows that have a delete button.
    ui.box({ width = 32, height = 1, opacity = 0 }),
  })
end

-- Review actions of a missing day (spec §6.6).
local function missingActions(view: View, state: EditorState): UiNode
  local host = view.host
  return ui.column({ gap = 8, padding = 12, radius = 12, fill = "surface_variant" }, {
    ui.label({ text = host.tr("panel.day.missing_hint"), fontSize = 13, maxLines = 2 }),
    ui.row({ gap = 6, justify = "end" }, {
      Widgets.smallButton(host.tr("panel.day.not_worked"), "ghost", function()
        view.send({ type = "day.flag", date = state.date, flag = "missingConfirmed", value = true })
        close(view, state)
      end),
      Widgets.smallButton(host.tr("panel.day.mark_day_off"), "outline", function()
        view.send({ type = "day.flag", date = state.date, flag = "dayOff", value = true })
        close(view, state)
      end),
      Widgets.smallButton(host.tr("panel.day.add_session"), "primary", function()
        local draft = state.draft :: Draft
        table.insert(draft.rows, newRow(state))
        draft.dirty = true
        view.render()
      end),
    }),
  })
end

local function pendingList(view: View): UiNode
  local host = view.host
  local rows = { ui.label({ text = host.tr("panel.day.pending_hint"), fontSize = 12, color = "on_surface_variant", maxLines = 2 }) }
  for _, absence in view.snap.pending do
    table.insert(rows, ui.row({ align = "center", gap = 6 }, {
      ui.label({
        text = host.tr("panel.today.range", { from = clock(view, absence.startS), to = clock(view, absence.endS) })
          .. " · "
          .. host.tr("panel.attention.signal." .. absence.signal),
        flexGrow = 1,
        fontSize = 13,
      }),
      Widgets.smallButton(host.tr("panel.attention.remove"), "ghost", function()
        view.send({ type = "absence.resolve", id = absence.id, keep = false })
      end),
      Widgets.smallButton(host.tr("panel.attention.keep"), "outline", function()
        view.send({ type = "absence.resolve", id = absence.id, keep = true })
      end),
    }))
  end
  return ui.column({ gap = 6, padding = 12, radius = 12, fill = "surface_variant" }, rows)
end

-- The editor, replacing the panel body. `day` is the edited day from `shift.history`,
-- nil while it loads.
function Editor.render(view: View, state: EditorState, day: DaySummary?): { UiNode }
  local host, fmt = view.host, view.snap.display.durationFormat
  local today = view.snap.today.date
  local back = Widgets.pageHeader(host, Widgets.date(host, state.date, "%A %d %B %Y"), function()
    close(view, state)
  end)
  if not day then
    return { back, ui.label({ text = host.tr("panel.history.loading"), color = "on_surface_variant", fontSize = 12 }) }
  end

  -- The draft follows the data until the user changes something.
  local basis = basisOf(view, day)
  if not state.draft or (not state.draft.dirty and state.draft.basis ~= basis) then
    state.draft = buildDraft(view, state, day)
    state.confirm = false
  end
  local draft = state.draft :: Draft
  local future = state.date > today
  local pending = state.date == today and #view.snap.pending > 0
  local editable = not future and not pending

  local worked = day.workedMs
  if state.date == today then
    worked = view.live.workedMs
  end
  local summary = { host.tr("panel.day.target", { target = Format.duration(day.targetMs, fmt) }) }
  if not future then
    table.insert(summary, host.tr("panel.day.worked", { worked = Format.duration(worked, fmt) }))
    table.insert(summary, Format.signed(worked - day.targetMs, fmt))
  end
  local children = {
    back,
    ui.label({ text = table.concat(summary, " · "), color = "on_surface_variant", fontSize = 13 }),
    statusChips(view, day, pending),
  }
  if day.missing and #draft.rows == 0 then
    table.insert(children, missingActions(view, state))
  end
  if pending then
    table.insert(children, pendingList(view))
  end
  if view.trackingStart and state.date < view.trackingStart then
    table.insert(children, ui.label({ text = host.tr("panel.day.before_tracking"), fontSize = 12, color = "on_surface_variant", maxLines = 2 }))
  end

  table.insert(children, ui.row({ align = "center", height = ROW_HEIGHT }, {
    ui.label({ text = host.tr("panel.day.day_off"), flexGrow = 1 }),
    ui.toggle({
      checked = draft.dayOff,
      onChange = function(value)
        draft.dayOff = value == "true"
        draft.dirty = true
        state.confirm = false
        view.render()
      end,
    }),
  }))

  local parsed, problem
  if not future then
    table.insert(children, Widgets.sectionTitle(host.tr("panel.day.sessions")))
    local rows = {}
    if draft.openStart then
      table.insert(rows, openRow(view, state, editable))
    end
    for _, row in draft.rows do
      table.insert(rows, sessionRow(view, state, row, editable))
    end
    if #rows == 0 then
      table.insert(rows, ui.label({ text = host.tr("panel.day.no_sessions"), color = "on_surface_variant", fontSize = 12 }))
    end
    table.insert(children, ui.column({ gap = 6 }, rows))
    table.insert(children, ui.row({}, {
      Widgets.smallButton(host.tr("panel.day.add_session"), "ghost", function()
        table.insert(draft.rows, newRow(state))
        draft.dirty = true
        view.render()
      end, editable),
    }))
    parsed, problem = parse(view, state)
  else
    parsed = { sessions = {} }
  end

  -- Always present, so typing never changes the tree's structure (spec §7.4 render key).
  local message, messageColor = "", "error"
  if problem then
    message = host.tr("panel.day.errors." .. problem)
  elseif state.confirm then
    message, messageColor = host.tr("panel.day.confirm_day_off"), "secondary"
  end
  table.insert(children, ui.label({ text = message, color = messageColor, fontSize = 12, maxLines = 2 }))

  local hasSessions = #draft.rows > 0 or draft.openStart ~= nil
  local canSave = parsed ~= nil and (editable or future) and (draft.dirty or day.needsReview)
  table.insert(children, ui.row({ gap = 8, justify = "end" }, {
    Widgets.smallButton(host.tr("panel.day.cancel"), "ghost", function()
      close(view, state)
    end),
    Widgets.smallButton(host.tr(state.confirm and "panel.day.confirm" or "panel.day.save"), "primary", function()
      if not parsed then
        return
      end
      if draft.dayOff and not day.dayOff and hasSessions and not state.confirm then
        state.confirm = true
        view.render()
        return
      end
      if future then
        view.send({ type = "day.flag", date = state.date, flag = "dayOff", value = draft.dayOff })
      else
        view.send({
          type = "day.save",
          date = state.date,
          sessions = parsed.sessions,
          openStartS = parsed.openStartS,
          dayOff = draft.dayOff,
        })
      end
      close(view, state)
    end, canSave),
  }))
  return children
end

return Editor
