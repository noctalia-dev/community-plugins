--!nonstrict
-- The automation reducer (spec §9.2): every user command, IPC call, signal and tick
-- becomes an event for one pure function
--
--   reduce(state, event, ctx) -> state', effects, result
--
-- `state` mirrors state.json and is never mutated. `effects` are applied by the service
-- in order (ledger writes before the state, persistence before publishing, spec §10.3):
--
--   { type = "ledger.addSession", date, session }      { type = "ledger.removeSession", date, id }
--   { type = "ledger.setFlag", date, flag, value }     { type = "ledger.setDay", date, day }
--   { type = "balance.save", balance }                 { type = "state.save" }   { type = "publish" }
--   { type = "notify", kind, ms? }                     a new suggestion ("checkin", "checkout") or
--                                                      absence to review ("absence", its length)
--
-- `result` is `{ ok = true, changed = bool }` or `{ ok = false, error = code }`. Commands
-- are idempotent: a check-in while working is accepted and changes nothing, so a command
-- delivered twice is harmless (spec §9.3). When nothing changes, the input state itself
-- is returned.
--
--   ctx = { nowS, settings, window = { at(t), nextEdge(t) }, dayOf(date), balance }
--
-- `dayOf` reads recorded days, to cut a removed absence out of a closed session and for
-- the edits of past days; `balance` is balance.json, for the edits of the Balance tab.
--
-- Events (the fields besides `type`):
--   checkin, checkout, toggle  { origin? }        manual tracking (§6.2), origin "manual" by default
--   undo                       { id? }            §6.8.4
--   absence.resolve            { id, keep }       a pending absence counted as work or cut out (§6.3.5)
--   suggestion.dismiss         { kind }           "Not now" (§6.3.4)
--   hint.dismiss               { id }             a one-time hint
--   onboarding.dismiss                            the first-run card (§6.10)
--   day.save                   { date, sessions, openStartS?, dayOff? }   the day editor (§6.8.2)
--   day.flag                   { date, flag, value }   dayOff or missingConfirmed (§6.6)
--   adjust.add                 { id, date, minutes, note }   a balance adjustment (§6.6)
--   adjust.remove              { id }
--   balance.meta               { trackingStart?, initialBalanceMin? }
--   signal                     { signal, atS?, startS?, endS? }   idle, active, lock, unlock, sleep,
--                                                 resume, or gap with its interval (§6.3.2)
--   start                      { startS? }        service start; startS = stale heartbeat (E1)
--   tick                                          every few seconds: window edges, thresholds
--   config                     { restarted? }     settings changed; restarted: signal sources too
--   calendar                                      holidays changed
--
-- Before any event, a workday that has ended is rolled over (§6.4).

local Model = require("./model.luau")
local Time = require("./time.luau")
local Types = require("./types.luau")

type Adjustment = Types.Adjustment
type AwaySignal = Types.AwaySignal
type Balance = Types.Balance
type Cut = Types.Cut
type Day = Types.Day
type Effect = Types.Effect
type Event = Types.Event
type PendingAbsence = Types.PendingAbsence
type ReduceContext = Types.ReduceContext
type Result = Types.Result
type Session = Types.Session
type State = Types.State
type UndoEntry = Types.UndoEntry
type WindowProbe = Types.WindowProbe

-- One reduction in progress. `state` is a shallow copy: nested tables are shared with
-- the input and are replaced, never modified. `dirty` changes are saved and published;
-- `touched` ones (the last activity on ticks) stay in memory until the next heartbeat.
-- `days` holds the sessions of the recorded days read so far, with this step's session
-- effects applied.
type Step = {
  state: State,
  balance: Types.Balance?,
  effects: { Effect },
  dirty: boolean,
  touched: boolean,
  now: number,
  settings: Types.Settings,
  window: WindowProbe,
  dayOf: (dateKey: string) -> Types.Day?,
  days: { [string]: { Session } },
}

type Handler = (s: Step, event: Event) -> Result?

local Automation = {}

local DAY_S = 24 * 60 * 60
local UNCHANGED: Result = { ok = true, changed = false }

local NO_WINDOW: WindowProbe = {
  at = function(_t)
    return false
  end,
  nextEdge = function(_t)
    return nil
  end,
}

-- Helpers ------------------------------------------------------------------------

local function emit(s: Step, effect: Effect)
  table.insert(s.effects, effect)
  s.dirty = true
end

-- Sets a suggestion, with its one notification (spec §6.9): a suggestion lasts until the
-- window segment ends, so each segment notifies once.
local function suggest(s: Step, kind: "checkin" | "checkout", atS: number)
  s.state.suggestion = { kind = kind, untilS = s.window.nextEdge(atS) }
  s.dirty = true
  if s.settings.notify.suggestions then
    emit(s, { type = "notify", kind = kind })
  end
end

local function isAway(presence: Types.Presence?): boolean
  return presence ~= nil and (presence.idle == true or presence.locked == true or presence.asleep == true)
end

local function workdayOf(s: Step, epochS: number): string
  return Time.workdayOf(epochS, s.settings.dayStartHour)
end

-- End of the window segment containing `atS`, or of a day when no edge is in sight.
local function segmentEnd(s: Step, atS: number): number
  return s.window.nextEdge(atS) or atS + DAY_S
end

local function setOverride(s: Step, key: string, value: any)
  local overrides = table.clone(s.state.overrides or {})
  overrides[key] = value
  s.state.overrides = overrides
  s.dirty = true
end

-- Keeps at most UNDO_DEPTH entries.
local function pushUndo(s: Step, entry: UndoEntry)
  local stack = table.clone(s.state.undo or {})
  table.insert(stack, entry)
  while #stack > Model.UNDO_DEPTH do
    table.remove(stack, 1)
  end
  s.state.undo = stack
  s.dirty = true
end

local function insertPending(s: Step, absence: PendingAbsence)
  local pending = table.clone(s.state.pending or {})
  local index = #pending + 1
  for i, other in pending do
    if absence.startS < other.startS then
      index = i
      break
    end
  end
  table.insert(pending, index, absence)
  s.state.pending = pending
  s.dirty = true
end

-- Sessions -------------------------------------------------------------------------

-- Sessions of a recorded day as this step leaves them.
local function sessionsOf(s: Step, date: string): { Session }
  local list = s.days[date]
  if not list then
    local day = s.dayOf(date)
    list = table.clone(day and day.sessions or {})
    s.days[date] = list
  end
  return list
end

local function addSession(s: Step, date: string, session: Session)
  table.insert(sessionsOf(s, date), session)
  emit(s, { type = "ledger.addSession", date = date, session = session })
end

local function removeSession(s: Step, date: string, id: string)
  local list = sessionsOf(s, date)
  for index, session in list do
    if session.id == id then
      table.remove(list, index)
      break
    end
  end
  emit(s, { type = "ledger.removeSession", date = date, id = id })
end

local function openSession(s: Step, atS: number, origin: Types.Origin)
  local st = s.state
  local open = { id = Model.sessionId(atS), startS = atS, origin = origin }
  st.open = open
  st.absence = nil
  st.suggestion = nil
  st.firstRunDismissed = true
  st.lastActivityS = math.max(st.lastActivityS or atS, atS)
  -- A manual session started outside the window is left alone by window edges (§6.3.4).
  setOverride(s, "manualSession", (origin == "manual" and not s.window.at(atS)) or nil)
  pushUndo(s, { id = "checkin:" .. open.id, action = "checkin", atS = s.now, session = open })
end

-- Closes the open session at `endS`. Pending absences past the end are trimmed: that
-- time is no longer part of the session.
local function closeSession(s: Step, endS: number, undoable: boolean)
  local st = s.state
  local open = assert(st.open, "no open session")
  endS = math.max(endS, open.startS)
  local session = { id = open.id, startS = open.startS, endS = endS, origin = open.origin }
  local date = workdayOf(s, open.startS)
  local recorded = endS > open.startS
  if recorded then
    addSession(s, date, session)
  end

  if st.pending then
    local pending = {}
    for _, absence in st.pending do
      if absence.startS < endS then
        if absence.endS > endS then
          absence = table.clone(absence)
          absence.endS = endS
        end
        table.insert(pending, absence)
      end
    end
    st.pending = if #pending > 0 then pending else nil
  end

  st.open = nil
  st.absence = nil
  st.suggestion = nil
  setOverride(s, "manualSession", nil)
  if undoable then
    pushUndo(s, {
      id = "checkout:" .. open.id,
      action = "checkout",
      atS = s.now,
      session = session,
      date = date,
      recorded = recorded,
    })
  end
  s.dirty = true
end

-- Absences (spec §6.3.5) ---------------------------------------------------------------

-- Opens or extends the absence of the open session. The user was last active at `startS`.
local function startAbsence(s: Step, signal: AwaySignal, startS: number)
  local st = s.state
  if st.lastActivityS and st.lastActivityS > startS then
    st.lastActivityS = startS
    s.touched = true
  end
  local open = st.open
  if not open then
    return
  end
  startS = math.max(startS, open.startS)
  local absence = st.absence
  local signals = table.clone(absence and absence.signals or {})
  if not table.find(signals, signal) then
    table.insert(signals, signal)
  end
  st.absence = { startS = absence and math.min(absence.startS, startS) or startS, signals = signals }
  s.dirty = true
end

-- Cuts [startS, endS] out of the session holding it (spec §6.3.5): the session ends at
-- the absence start and goes on as a new session from its end. Returns how to undo it,
-- or nil when no session holds that time any more (it was undone or edited).
local function cutSession(s: Step, date: string, startS: number, endS: number): Cut?
  local st = s.state
  local open = st.open
  if open and startS >= open.startS then
    local openDate = workdayOf(s, open.startS)
    local pieces = {}
    if startS > open.startS then
      addSession(s, openDate, { id = open.id, startS = open.startS, endS = startS, origin = open.origin })
      table.insert(pieces, { date = openDate, id = open.id })
    end
    st.open = { id = Model.sessionId(endS), startS = endS, origin = open.origin }
    s.dirty = true
    return { session = open, date = openDate, pieces = pieces, openId = st.open.id }
  end
  for _, session in sessionsOf(s, date) do
    if session.startS < endS and startS < session.endS then
      local cutStart, cutEnd = math.max(startS, session.startS), math.min(endS, session.endS)
      local pieces = {}
      removeSession(s, date, session.id)
      if cutStart > session.startS then
        addSession(s, date, { id = session.id, startS = session.startS, endS = cutStart, origin = session.origin })
        table.insert(pieces, { date = date, id = session.id })
      end
      if session.endS > cutEnd then
        local id, pieceDate = Model.sessionId(cutEnd), workdayOf(s, cutEnd)
        addSession(s, pieceDate, { id = id, startS = cutEnd, endS = session.endS, origin = session.origin })
        table.insert(pieces, { date = pieceDate, id = id })
      end
      return { session = session, date = date, pieces = pieces }
    end
  end
  return nil
end

-- Reverts a cut. Fails when the session that went on is no longer the open one.
local function uncut(s: Step, cut: Cut): boolean
  local st = s.state
  if cut.openId and not (st.open and st.open.id == cut.openId) then
    return false
  end
  for _, piece in cut.pieces do
    removeSession(s, piece.date, piece.id)
  end
  if cut.openId then
    local session = cut.session
    st.open = { id = session.id, startS = session.startS, origin = session.origin }
  else
    addSession(s, cut.date, cut.session :: Session)
  end
  s.dirty = true
  return true
end

-- Ends the absence in progress at `endS` and applies its action.
local function finishAbsence(s: Step, endS: number)
  local st = s.state
  local absence = st.absence
  local open = st.open
  st.absence = nil
  s.dirty = true
  if not absence or not open then
    return
  end
  local settings = s.settings
  local action = Model.absenceAction(settings, absence.signals)
  if action == "ignore" or endS - absence.startS < settings.minAbsenceMin * 60 then
    return -- micro-breaks are work
  end
  local id = Model.absenceId(absence.startS)
  local date = workdayOf(s, open.startS)
  if action == "ask" then
    insertPending(s, { id = id, date = date, startS = absence.startS, endS = endS, signals = absence.signals })
    if settings.notify.pendingAbsence then
      emit(s, { type = "notify", kind = "absence", ms = (endS - absence.startS) * 1000 })
    end
  elseif action == "deduct" then
    -- Undone back to pending, like a decision of the user (§6.8.4).
    local pending = { id = id, date = date, startS = absence.startS, endS = endS, signals = absence.signals }
    local cut = cutSession(s, date, absence.startS, endS)
    pushUndo(s, { id = "resolve:" .. id, action = "resolve", atS = s.now, absence = pending, cut = cut })
  else -- checkout: normally done by the tick as soon as the threshold is crossed
    closeSession(s, absence.startS, true)
  end
end

-- Check-out at `endS` after ending an absence in progress (manual or window check-out).
local function checkOut(s: Step, endS: number)
  if s.state.absence then
    finishAbsence(s, endS)
  end
  if s.state.open then
    closeSession(s, endS, true)
  end
end

-- Automatic check-in (spec §6.3.4) ------------------------------------------------------

-- Checks in or suggests it when the user is active at `atS` inside the window.
local function offerCheckin(s: Step, atS: number)
  local st, mode = s.state, s.settings.autoCheckin
  if st.open or mode == "off" or not s.window.at(atS) then
    return
  end
  local suppressed = st.overrides and st.overrides.suppressCheckinUntilS
  if suppressed and atS < suppressed then
    return
  end
  if mode == "auto" then
    openSession(s, atS, "auto")
  elseif not (st.suggestion and st.suggestion.kind == "checkin") then
    suggest(s, "checkin", atS)
  end
end

-- The user is known to be active at `atS`: ends their absence and may check them in.
local function activity(s: Step, atS: number)
  local st = s.state
  if not st.lastActivityS or atS > st.lastActivityS then
    st.lastActivityS = atS
    s.touched = true
  end
  if st.absence then
    finishAbsence(s, atS)
  end
  offerCheckin(s, atS)
end

local function windowOpened(s: Step, edgeS: number)
  local st = s.state
  if st.suggestion and st.suggestion.kind == "checkout" then
    st.suggestion = nil
    s.dirty = true
  end
  if not isAway(st.presence) then
    offerCheckin(s, edgeS)
  end
end

local function windowClosed(s: Step, edgeS: number)
  local st, mode = s.state, s.settings.autoCheckout
  if st.suggestion and st.suggestion.kind == "checkin" then
    st.suggestion = nil
    s.dirty = true
  end
  if not st.open or mode == "off" or (st.overrides and st.overrides.manualSession) then
    return
  end
  if mode == "auto" then
    checkOut(s, edgeS)
  else
    suggest(s, "checkout", edgeS)
  end
end

-- Rollover (spec §6.4) -------------------------------------------------------------------

-- Closes the workday the service last saw when another one has started: the open
-- session ends at the last known activity (the day is flagged for review, D21) and
-- pending absences take `unresolved_absence`.
local function rollover(s: Step)
  local st = s.state
  local today = workdayOf(s, s.now)
  local last = st.workday
  local open = st.open
  if last == nil then
    -- First run, or state written before rollovers existed.
    last = open and workdayOf(s, open.startS) or today
  end
  if last >= today then
    if st.workday ~= today and last == today then
      st.workday = today
      s.touched = true
    end
    return -- same day, or the clock went backwards (E7): keep the later day
  end

  if open then
    local openDay = workdayOf(s, open.startS)
    local dayEnd = Time.workdayStartS(Time.addDays(openDay, 1), s.settings.dayStartHour)
    local closeAt = math.clamp(st.lastActivityS or dayEnd, open.startS, dayEnd)
    if st.absence then
      closeAt = math.min(closeAt, st.absence.startS)
    end
    closeSession(s, closeAt, false)
    emit(s, { type = "ledger.setFlag", date = openDay, flag = "needsReview", value = true })
  end

  -- Kept absences are already work; removed ones are cut out of their closed sessions.
  if s.settings.unresolvedAbsence == "remove" then
    for _, absence in st.pending or {} do
      cutSession(s, absence.date, absence.startS, absence.endS)
    end
  end

  st.pending = nil
  st.absence = nil
  st.suggestion = nil
  st.window = nil
  st.overrides = nil
  st.undo = nil -- a new day starts with nothing to undo
  st.workday = today
  s.dirty = true
end

-- Edits (spec §6.8) -----------------------------------------------------------------------

local EDIT_FLAGS = { dayOff = true, missingConfirmed = true }
local MAX_ADJUSTMENT_MIN = 1000 * 60
local MAX_NOTE = 200

local hasFlag = Model.hasFlag

-- A recorded day as this step leaves it (an empty one when nothing was recorded).
local function recordOf(s: Step, date: string): Day
  local day = s.dayOf(date)
  return {
    sessions = table.clone(sessionsOf(s, date)),
    flags = table.clone(day and day.flags or {}),
    note = day and day.note or "",
  }
end

local function sameDay(a: Day, b: Day): boolean
  if #a.sessions ~= #b.sessions or a.note ~= b.note then
    return false
  end
  for i, session in a.sessions do
    local other = b.sessions[i]
    if session.id ~= other.id or session.startS ~= other.startS or session.endS ~= other.endS or session.origin ~= other.origin then
      return false
    end
  end
  for name in EDIT_FLAGS do
    if hasFlag(a, name) ~= hasFlag(b, name) then
      return false
    end
  end
  return hasFlag(a, "needsReview") == hasFlag(b, "needsReview")
end

-- A day off set or cleared today or ahead: the window is evaluated afresh by the next
-- tick, not as an edge. Its next edge, computed ahead, may have skipped that day.
local function dayOffChanged(s: Step, date: string)
  if date >= workdayOf(s, s.now) then
    s.state.window = nil
  end
end

local function setDay(s: Step, date: string, day: Day)
  if hasFlag(recordOf(s, date), "dayOff") ~= hasFlag(day, "dayOff") then
    dayOffChanged(s, date)
  end
  s.days[date] = table.clone(day.sessions)
  emit(s, { type = "ledger.setDay", date = date, day = day })
end

local function setFlag(s: Step, date: string, name: string, value: boolean)
  emit(s, { type = "ledger.setFlag", date = date, flag = name, value = value })
  if name == "dayOff" then
    dayOffChanged(s, date)
  end
end

local function saveBalance(s: Step, balance: Balance)
  s.balance = balance
  emit(s, { type = "balance.save", balance = balance })
end

local function findAdjustment(balance: Balance, id: string): number?
  for index, adjustment in balance.adjustments do
    if adjustment.id == id then
      return index
    end
  end
  return nil
end

-- Adds or removes an adjustment; false when it is already in that state.
local function setAdjustment(s: Step, adjustment: Adjustment, present: boolean): boolean
  local balance = s.balance :: Balance
  local index = findAdjustment(balance, adjustment.id)
  if (index ~= nil) == present then
    return false
  end
  local next = table.clone(balance)
  next.adjustments = table.clone(balance.adjustments)
  if present then
    table.insert(next.adjustments, adjustment)
  else
    table.remove(next.adjustments, index :: number)
  end
  saveBalance(s, next)
  return true
end

local function metaOf(balance: Balance): Types.BalanceMeta
  return { trackingStart = balance.trackingStart, initialBalanceMin = balance.initialBalanceMin }
end

local function setMeta(s: Step, meta: Types.BalanceMeta)
  local next = table.clone(s.balance :: Balance)
  next.trackingStart = meta.trackingStart
  next.initialBalanceMin = meta.initialBalanceMin
  saveBalance(s, next)
end

-- Reverts an edit, a flag, an adjustment or a balance change; false when what it changed
-- was changed again since.
local function undoEdit(s: Step, top: UndoEntry): boolean
  local st = s.state
  if top.action == "edit" then
    if not sameDay(recordOf(s, top.date), top.after) or st.open ~= top.openAfter then
      return false
    end
    setDay(s, top.date, top.before or Model.newDay())
    st.open = top.openBefore
  elseif top.action == "flag" then
    if hasFlag(s.dayOf(top.date), top.flag) == top.before then
      return false
    end
    setFlag(s, top.date, top.flag, top.before)
  elseif top.action == "adjust" then
    if not s.balance or not setAdjustment(s, top.adjustment, not top.added) then
      return false
    end
  elseif top.action == "meta" then
    local balance = s.balance
    if not balance or balance.trackingStart ~= top.after.trackingStart or balance.initialBalanceMin ~= top.after.initialBalanceMin then
      return false
    end
    setMeta(s, top.before)
  end
  return true
end

-- Handlers ---------------------------------------------------------------------------

local handlers: { [string]: Handler } = {}

function handlers.checkin(s, event)
  if s.state.open then
    return UNCHANGED
  end
  openSession(s, s.now, event.origin or "manual")
  return nil
end

function handlers.checkout(s, event)
  local st = s.state
  if not st.open then
    return UNCHANGED
  end
  checkOut(s, s.now)
  -- A manual check-out inside a segment holds automatic check-in until it ends (E8).
  if (event.origin or "manual") == "manual" and s.window.at(s.now) then
    setOverride(s, "suppressCheckinUntilS", segmentEnd(s, s.now))
  end
  return nil
end

function handlers.toggle(s, event)
  if s.state.open then
    return handlers.checkout(s, event)
  end
  return handlers.checkin(s, event)
end

-- Reverts the most recent action if it is younger than the undo window. `event.id`
-- (sent by the UIs) must name that action: an undo delivered twice then finds another
-- entry on top, or none, and does nothing. IPC sends no id and undoes the top entry.
function handlers.undo(s, event)
  local st = s.state
  local top = Model.undoable(st, s.now)
  if not top then
    return event.id and UNCHANGED or { ok = false, error = "nothing_to_undo" }
  end
  if event.id and event.id ~= top.id then
    return UNCHANGED
  end

  if top.action == "checkin" then
    -- The stack is in action order, so the session it opened is still the open one.
    if not (st.open and st.open.id == top.session.id) then
      return { ok = false, error = "undo_conflict" }
    end
    st.open = nil
    st.absence = nil
    setOverride(s, "manualSession", nil)
  elseif top.action == "checkout" then
    if st.open then
      return { ok = false, error = "undo_conflict" }
    end
    if top.recorded then
      removeSession(s, top.date, top.session.id)
    end
    st.open = { id = top.session.id, startS = top.session.startS, origin = top.session.origin }
  elseif top.action == "resolve" then
    if top.cut and not uncut(s, top.cut) then
      return { ok = false, error = "undo_conflict" }
    end
    insertPending(s, top.absence)
  elseif not undoEdit(s, top) then
    return { ok = false, error = "undo_conflict" }
  end
  local stack = table.clone(st.undo :: { UndoEntry })
  table.remove(stack)
  st.undo = stack
  s.dirty = true
  return nil
end

handlers["absence.resolve"] = function(s, event)
  local st = s.state
  for index, pending in st.pending or {} do
    if pending.id == event.id then
      local list = table.clone(st.pending :: { PendingAbsence })
      table.remove(list, index)
      st.pending = if #list > 0 then list else nil
      -- Kept time is already part of its session.
      local cut = if event.keep == true then nil else cutSession(s, pending.date, pending.startS, pending.endS)
      pushUndo(s, { id = "resolve:" .. pending.id, action = "resolve", atS = s.now, absence = pending, cut = cut })
      return nil
    end
  end
  return UNCHANGED -- already resolved
end

-- "Not now": a check-in suggestion stays away until the segment ends.
handlers["suggestion.dismiss"] = function(s, event)
  local suggestion = s.state.suggestion
  if not suggestion or (event.kind and event.kind ~= suggestion.kind) then
    return UNCHANGED
  end
  if suggestion.kind == "checkin" then
    setOverride(s, "suppressCheckinUntilS", suggestion.untilS or s.now + DAY_S)
  end
  s.state.suggestion = nil
  s.dirty = true
  return nil
end

handlers["hint.dismiss"] = function(s, event)
  local hints = s.state.hints or {}
  if type(event.id) ~= "string" or hints[event.id] then
    return UNCHANGED
  end
  hints = table.clone(hints)
  hints[event.id] = true
  s.state.hints = hints
  s.dirty = true
  return nil
end

handlers["onboarding.dismiss"] = function(s, _event)
  if s.state.firstRunDismissed then
    return UNCHANGED
  end
  s.state.firstRunDismissed = true
  s.dirty = true
  return nil
end

local function invalid(code: string): Result
  return { ok = false, error = code }
end

-- The day editor saves a whole day: its sessions, the start of the running session when
-- it belongs to that day, and the day-off marker. Saving reviews the day (needsReview).
-- A day with pending absences is locked until they are resolved.
handlers["day.save"] = function(s, event)
  local st, date = s.state, event.date
  if not Time.isDate(date) or type(event.sessions) ~= "table" then
    return invalid("invalid_day")
  end
  for _, absence in st.pending or {} do
    if absence.date == date then
      return invalid("pending")
    end
  end
  local open = st.open
  local openHere = open ~= nil and workdayOf(s, open.startS) == date
  local draft: Model.DayDraft = { date = date :: string, sessions = {} }
  if openHere then
    draft.openStartS = if type(event.openStartS) == "number" then math.floor(event.openStartS) else (open :: any).startS
  end
  for _, session in event.sessions :: { any } do
    if type(session) ~= "table" or type(session.startS) ~= "number" or type(session.endS) ~= "number" then
      return invalid("invalid_day")
    end
    table.insert(draft.sessions, { startS = math.floor(session.startS), endS = math.floor(session.endS) })
  end
  local _, reason = Model.validateDay(draft, s.settings.dayStartHour, s.now)
  if reason then
    return invalid("invalid_" .. reason)
  end

  local before = recordOf(s, date :: string)
  -- Unchanged sessions keep their origin; edited ones become manual.
  local origins = {}
  for _, session in before.sessions do
    origins[session.startS .. "-" .. session.endS] = session.origin
  end
  table.sort(draft.sessions, function(a, b)
    return a.startS < b.startS
  end)
  local after: Day = { sessions = {}, flags = table.clone(before.flags), note = before.note }
  for _, session in draft.sessions do
    table.insert(after.sessions, {
      id = Model.sessionId(session.startS),
      startS = session.startS,
      endS = session.endS,
      origin = origins[session.startS .. "-" .. session.endS] or "manual",
    })
  end
  local flags: { [string]: boolean? } = after.flags
  flags.needsReview = nil
  if type(event.dayOff) == "boolean" then
    flags.dayOff = event.dayOff or nil
  end
  local openAfter = open
  if openHere and draft.openStartS ~= (open :: any).startS then
    local startS = draft.openStartS :: number
    openAfter = { id = Model.sessionId(startS), startS = startS, origin = (open :: any).origin }
  end
  if sameDay(before, after) and openAfter == open then
    return UNCHANGED
  end
  setDay(s, date :: string, after)
  st.open = openAfter
  pushUndo(s, {
    id = string.format("edit:%s:%d", date, s.now),
    action = "edit",
    atS = s.now,
    date = date :: string,
    before = before,
    after = after,
    openBefore = open,
    openAfter = openAfter,
  })
  return nil
end

-- Marks a day off (target 0), or a missing day as not worked (spec §6.6, §6.6.1).
handlers["day.flag"] = function(s, event)
  local date, name, value = event.date, event.flag, event.value
  if not Time.isDate(date) or not EDIT_FLAGS[name] or type(value) ~= "boolean" then
    return invalid("invalid_flag")
  end
  local before = hasFlag(s.dayOf(date :: string), name :: string)
  if before == value then
    return UNCHANGED
  end
  setFlag(s, date :: string, name :: string, value :: boolean)
  pushUndo(s, {
    id = string.format("flag:%s:%s:%s", date, name, tostring(value)),
    action = "flag",
    atS = s.now,
    date = date :: string,
    flag = name :: string,
    before = before,
  })
  return nil
end

local function trimNote(note: any): string
  if type(note) ~= "string" then
    return ""
  end
  return string.sub(string.match(note, "^%s*(.-)%s*$") :: string, 1, MAX_NOTE)
end

-- Adjustments carry an id chosen by the sender, so adding one twice changes nothing.
handlers["adjust.add"] = function(s, event)
  local minutes = event.minutes
  if
    not s.balance
    or type(event.id) ~= "string"
    or #event.id == 0
    or #event.id > 64
    or not Time.isDate(event.date)
    or type(minutes) ~= "number"
    or minutes ~= math.floor(minutes)
    or minutes == 0
    or math.abs(minutes) > MAX_ADJUSTMENT_MIN
  then
    return invalid("invalid_adjustment")
  end
  local adjustment = { id = event.id :: string, date = event.date :: string, minutes = minutes :: number, note = trimNote(event.note) }
  if findAdjustment(s.balance :: Balance, adjustment.id) then
    return UNCHANGED
  end
  setAdjustment(s, adjustment, true)
  pushUndo(s, { id = "adjust.add:" .. adjustment.id, action = "adjust", atS = s.now, adjustment = adjustment, added = true })
  return nil
end

handlers["adjust.remove"] = function(s, event)
  local balance = s.balance
  local index = balance and type(event.id) == "string" and findAdjustment(balance, event.id)
  if not index then
    return UNCHANGED
  end
  local adjustment = (balance :: Balance).adjustments[index]
  setAdjustment(s, adjustment, false)
  pushUndo(s, { id = "adjust.remove:" .. adjustment.id, action = "adjust", atS = s.now, adjustment = adjustment, added = false })
  return nil
end

-- Tracking start and initial balance, edited in the Balance tab.
handlers["balance.meta"] = function(s, event)
  local balance = s.balance
  if not balance then
    return invalid("invalid_meta")
  end
  local before = metaOf(balance)
  local after = table.clone(before)
  if event.trackingStart ~= nil then
    if not Time.isDate(event.trackingStart) then
      return invalid("invalid_meta")
    end
    after.trackingStart = event.trackingStart :: string
  end
  local initial = event.initialBalanceMin
  if initial ~= nil then
    if type(initial) ~= "number" or initial ~= math.floor(initial) or math.abs(initial) > MAX_ADJUSTMENT_MIN then
      return invalid("invalid_meta")
    end
    after.initialBalanceMin = initial
  end
  if after.trackingStart == before.trackingStart and after.initialBalanceMin == before.initialBalanceMin then
    return UNCHANGED
  end
  setMeta(s, after)
  pushUndo(s, { id = string.format("meta:%d", s.now), action = "meta", atS = s.now, before = before, after = after })
  return nil
end

local AWAY_SIGNALS = { idle = "idle", lock = "locked", sleep = "asleep" }
local RETURN_SIGNALS = { active = "idle", unlock = "locked", resume = "asleep" }

function handlers.signal(s, event)
  local st, signal = s.state, event.signal
  local atS = math.min(event.atS or s.now, s.now)
  local presence = table.clone(st.presence or {})
  if signal == "gap" then
    if type(event.startS) ~= "number" or type(event.endS) ~= "number" or event.endS <= event.startS then
      return { ok = false, error = "invalid_signal" }
    end
    startAbsence(s, "gap", event.startS)
    atS = math.min(event.endS, s.now)
  elseif AWAY_SIGNALS[signal] then
    presence[AWAY_SIGNALS[signal]] = true
    -- swayidle reports idle after the timeout: the user left that long ago.
    local startS = signal == "idle" and atS - s.settings.idleTimeoutMin * 60 or atS
    startAbsence(s, signal :: AwaySignal, startS)
  elseif RETURN_SIGNALS[signal] then
    presence[RETURN_SIGNALS[signal]] = false
    if signal == "unlock" then
      presence.idle = false -- unlocking takes input
    end
  else
    return { ok = false, error = "invalid_signal" }
  end
  st.presence = presence
  s.dirty = true
  -- Activity ends an absence only once nothing reports the user away: `active` on the
  -- lock screen is not activity, only `unlock` is (spike S1).
  if not AWAY_SIGNALS[signal] and not isAway(presence) then
    activity(s, atS)
  end
  return nil
end

-- Service start: the signals start over, and the start itself is activity. A stale
-- heartbeat means the service was not running while a session was open (E1). The window
-- state is kept, so an edge passed while stopped is applied by the next tick.
function handlers.start(s, event)
  local st = s.state
  st.presence = {}
  s.dirty = true
  if type(event.startS) == "number" and event.startS < s.now then
    startAbsence(s, "gap", event.startS)
  end
  activity(s, s.now)
  return nil
end

function handlers.tick(s, _event)
  local st, now, settings = s.state, s.now, s.settings
  if st.open and not isAway(st.presence) then
    st.lastActivityS = now
    s.touched = true
  end

  local absence = st.absence
  if
    st.open
    and absence
    and Model.absenceAction(settings, absence.signals) == "checkout"
    and now - absence.startS >= settings.minAbsenceMin * 60
  then
    closeSession(s, absence.startS, true)
  end

  local suggestion = st.suggestion
  if suggestion and suggestion.untilS and now >= suggestion.untilS then
    st.suggestion = nil
    s.dirty = true
  end

  -- Window edges are computed ahead (`untilS`), so most ticks stop here (spec §9.4).
  local window = st.window
  if not window or now >= (window.untilS or math.huge) then
    local inside = s.window.at(now)
    st.window = { open = inside, untilS = s.window.nextEdge(now) or now + DAY_S }
    s.touched = true
    if window and inside ~= window.open then
      local edgeS = math.min(window.untilS or now, now)
      if inside then
        windowOpened(s, edgeS)
      else
        windowClosed(s, edgeS)
      end
    end
  end
  return nil
end

-- Holidays or days off changed: the window is evaluated afresh by the next tick, without
-- treating the change as an edge.
function handlers.calendar(s, _event)
  s.state.window = nil
  s.touched = true
  return nil
end

-- New settings: the window is evaluated afresh, without treating the change as an edge,
-- and suggestions made under the old settings are dropped. When the signal sources were
-- restarted, what they said is forgotten; the user is changing settings, so active.
function handlers.config(s, event)
  s.state.window = nil
  s.state.suggestion = nil
  s.dirty = true
  if event.restarted then
    s.state.presence = {}
    activity(s, s.now)
  end
  return nil
end

function Automation.reduce(state: State, event: Event, ctx: ReduceContext): (State, { Effect }, Result)
  local handler = handlers[event.type]
  if not handler then
    return state, {}, { ok = false, error = "unknown_command" }
  end
  local s: Step = {
    state = table.clone(state),
    effects = {},
    dirty = false,
    touched = false,
    now = ctx.nowS,
    settings = ctx.settings,
    window = ctx.window or NO_WINDOW,
    dayOf = ctx.dayOf or function(_dateKey)
      return nil
    end,
    days = {},
    balance = ctx.balance,
  }
  rollover(s)
  local result = handler(s, event)
  if not s.dirty and not s.touched then
    return state, {}, result or UNCHANGED
  end
  if s.dirty then
    table.insert(s.effects, { type = "state.save" })
    table.insert(s.effects, { type = "publish" })
  end
  return s.state, s.effects, result or { ok = true, changed = s.dirty }
end

return Automation
