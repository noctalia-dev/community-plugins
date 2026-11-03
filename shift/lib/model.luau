--!nonstrict
-- Domain model: settings, daily targets, sessions and the snapshot published to the UIs
-- (spec §6.5, §6.6, §9.3). Pure: no host access, data comes in as arguments.

local Time = require("./time.luau")
local Types = require("./types.luau")

type AbsenceAction = Types.AbsenceAction
type AwaySignal = Types.AwaySignal
type Balance = Types.Balance
type BalanceSummary = Types.BalanceSummary
type Book = Types.Book
type Contract = Types.Contract
type Day = Types.Day
type DaySummary = Types.DaySummary
type Live = Types.Live
type Status = Types.Status
type Session = Types.Session
type Settled = Types.Settled
type Settings = Types.Settings
type Snapshot = Types.Snapshot
type State = Types.State
type UndoEntry = Types.UndoEntry

local Model = {}

local HOUR_MS = 60 * 60 * 1000
local MINUTE_MS = 60 * 1000

-- Snapshot schema version (spec §9.3); fields are only ever added within a version.
Model.SNAPSHOT_VERSION = 1

-- Undo (spec §6.8.4): an action can be undone for 10 minutes, from any surface, and
-- consecutive undos chain while the entries are recent. The stack keeps 20 entries.
Model.UNDO_WINDOW_S = 10 * 60
Model.UNDO_DEPTH = 20

-- Settings -------------------------------------------------------------------

local DAY_SETTINGS = { "workday_mon", "workday_tue", "workday_wed", "workday_thu", "workday_fri", "workday_sat", "workday_sun" }

local WORK_WEEKS = {
  mon_fri = { true, true, true, true, true, false, false },
  mon_sat = { true, true, true, true, true, true, false },
}

local DURATION_FORMATS = { colon = true, units = true, decimal = true }

-- Automation presets (spec §6.3.1); `custom` reads the individual settings.
local PRESETS = {
  manual = { autoCheckin = "off", autoCheckout = "off", idle = "ignore", lock = "ignore", sleep = "ignore" },
  assisted = { autoCheckin = "suggest", autoCheckout = "suggest", idle = "ask", lock = "ask", sleep = "ask" },
  automatic = { autoCheckin = "auto", autoCheckout = "auto", idle = "ask", lock = "ask", sleep = "ask" },
}
local AUTO_MODES = { off = true, suggest = true, auto = true }
local ACTIONS = { ignore = true, ask = true, deduct = true, checkout = true }
local IDLE_BACKENDS = { auto = true, swayidle = true, external = true, off = true }

local function number(value: any, default: number, min: number, max: number): number
  if type(value) ~= "number" or value ~= value then
    return default
  end
  return math.clamp(value, min, max)
end

-- The value when it is one of `allowed`, else `default`.
local function choice(value: any, allowed: { [string]: boolean }, default: string): any
  return allowed[value] and value or default
end

local function code(value: any): string
  if type(value) ~= "string" then
    return ""
  end
  return string.upper((string.gsub(value, "%s+", "")))
end

local function strings(value: any): { string }
  local list = {}
  if type(value) == "table" then
    for _, item in value do
      if type(item) == "string" then
        table.insert(list, item)
      end
    end
  end
  return list
end

-- Reads the settings used by the core from `getConfig`, falling back to the manifest
-- defaults (spec §8) for missing or invalid values.
function Model.readSettings(getConfig: (key: string) -> any): Settings
  local workWeek = getConfig("work_week")
  local workdays = WORK_WEEKS[workWeek]
  if workWeek == "custom" then
    workdays = {}
    for i, key in DAY_SETTINGS do
      local value = getConfig(key)
      if type(value) == "boolean" then
        workdays[i] = value
      else
        workdays[i] = WORK_WEEKS.mon_fri[i]
      end
    end
  end
  local preset = choice(getConfig("automation"), { manual = true, assisted = true, automatic = true, custom = true }, "assisted")
  local behavior = PRESETS[preset]
  if not behavior then
    local default = PRESETS.assisted
    behavior = {
      autoCheckin = choice(getConfig("auto_checkin"), AUTO_MODES, default.autoCheckin),
      autoCheckout = choice(getConfig("auto_checkout"), AUTO_MODES, default.autoCheckout),
      idle = choice(getConfig("idle_action"), ACTIONS, default.idle),
      lock = choice(getConfig("lock_action"), ACTIONS, default.lock),
      sleep = choice(getConfig("sleep_action"), ACTIONS, default.sleep),
    }
  end
  local startText, endText = getConfig("window_start"), getConfig("window_end")
  return {
    weeklyHours = number(getConfig("weekly_hours"), 35, 0, 100),
    workdays = workdays or WORK_WEEKS.mon_fri,
    dayStartHour = math.floor(number(getConfig("day_start_hour"), 4, 0, 12)),
    durationFormat = choice(getConfig("duration_format"), DURATION_FORMATS, "colon"),
    preset = preset,
    autoCheckin = behavior.autoCheckin,
    autoCheckout = behavior.autoCheckout,
    actions = { idle = behavior.idle, lock = behavior.lock, sleep = behavior.sleep },
    idleTimeoutMin = math.floor(number(getConfig("idle_timeout_min"), 5, 1, 120)),
    minAbsenceMin = math.floor(number(getConfig("min_absence_min"), 15, 1, 240)),
    unresolvedAbsence = choice(getConfig("unresolved_absence"), { keep = true, remove = true }, "keep"),
    idleBackend = choice(getConfig("idle_backend"), IDLE_BACKENDS, "auto"),
    window = {
      start = type(startText) == "string" and startText or "08:00",
      ["end"] = type(endText) == "string" and endText or "19:00",
      excludeHolidays = getConfig("window_exclude_holidays") ~= false,
      extraRules = strings(getConfig("extra_rules")),
    },
    holidays = {
      enabled = getConfig("holidays_enabled") ~= false,
      country = code(getConfig("holiday_country")),
      region = code(getConfig("holiday_region")),
    },
    notify = {
      targetReached = getConfig("notify_target_reached") ~= false,
      pendingAbsence = getConfig("notify_pending_absence") ~= false,
      suggestions = getConfig("notify_suggestions") ~= false,
    },
  }
end

-- Whether automation needs signals at all: the manual preset ignores them.
function Model.usesSignals(settings: Settings): boolean
  local actions = settings.actions
  return settings.autoCheckin ~= "off"
    or settings.autoCheckout ~= "off"
    or actions.idle ~= "ignore"
    or actions.lock ~= "ignore"
    or actions.sleep ~= "ignore"
end

-- Targets --------------------------------------------------------------------

-- Weekly hours split evenly over the contract workdays, rounded to the minute (D4).
function Model.dailyTargetMs(settings: Settings): number
  local count = 0
  for _, isWorkday in settings.workdays do
    if isWorkday then
      count += 1
    end
  end
  if count == 0 then
    return 0
  end
  return math.round(settings.weeklyHours * HOUR_MS / count / MINUTE_MS) * MINUTE_MS
end

-- Contract (D22): changes apply from the day they are made, never to past days.
function Model.contract(settings: Settings, from: string): Contract
  local daily = Model.dailyTargetMs(settings) // MINUTE_MS
  local targets = {}
  for day = 1, 7 do
    targets[day] = settings.workdays[day] and daily or 0
  end
  return { from = from, weeklyHours = settings.weeklyHours, targets = targets }
end

local function sameContract(a: Contract, b: Contract): boolean
  if a.weeklyHours ~= b.weeklyHours then
    return false
  end
  for day = 1, 7 do
    if a.targets[day] ~= b.targets[day] then
      return false
    end
  end
  return true
end

-- The contract history with the current settings applied from `today`, or nil when it
-- already ends with them. A change made the same day as the previous one replaces it.
function Model.syncContract(history: { Contract }?, settings: Settings, today: string): { Contract }?
  local list = table.clone(history or {})
  local current = Model.contract(settings, today)
  local last = list[#list]
  if last and sameContract(last, current) then
    return nil
  end
  if last and last.from >= today then
    list[#list] = nil
    local previous = list[#list]
    if not previous then
      current.from = last.from -- the first contract keeps applying from tracking start
    elseif sameContract(previous, current) then
      return list -- back to what applied before today
    end
  end
  table.insert(list, current)
  return list
end

-- The contract in force on a date; the oldest one for earlier dates.
function Model.contractOn(history: { Contract }?, dateKey: string): Contract?
  local found = history and history[1]
  for _, entry in history or ({} :: { Contract }) do
    if entry.from <= dateKey then
      found = entry
    end
  end
  return found
end

-- Whether a recorded day has a flag (`dayOff`, `missingConfirmed`, `needsReview`).
function Model.hasFlag(day: Day?, name: string): boolean
  return day ~= nil and day.flags ~= nil and day.flags[name] == true
end
local flag = Model.hasFlag

-- Target of a workday (spec §6.6): none before tracking start, outside the contract
-- workdays, on public holidays and on days off.
function Model.targetMs(dateKey: string, book: Book): number
  local balance = book.balance
  if dateKey < balance.trackingStart then
    return 0
  end
  local contract = Model.contractOn(balance.contractHistory, dateKey)
  local minutes = contract and contract.targets[Time.weekday(dateKey)] or 0
  if minutes == 0 or book.holiday(dateKey) or flag(book.dayOf(dateKey), "dayOff") then
    return 0
  end
  return minutes * MINUTE_MS
end

-- Whether a date is a workday of the contract in force then.
function Model.isContractDay(dateKey: string, balance: Balance): boolean
  local contract = Model.contractOn(balance.contractHistory, dateKey)
  return contract ~= nil and contract.targets[Time.weekday(dateKey)] > 0
end

-- History and balance -------------------------------------------------------------

-- A day as the history and the day editor show it. A missing day is a past day with a
-- target and no session that the user has not reviewed (D23).
function Model.daySummary(dateKey: string, book: Book, today: string): DaySummary
  local day = book.dayOf(dateKey)
  local target = Model.targetMs(dateKey, book)
  local sessions = day and day.sessions or {}
  local confirmed = flag(day, "missingConfirmed")
  return {
    date = dateKey,
    workedMs = Model.closedWorkedMs(day),
    targetMs = target,
    holiday = book.holiday(dateKey),
    dayOff = flag(day, "dayOff"),
    missing = dateKey < today and target > 0 and #sessions == 0 and not confirmed,
    missingConfirmed = confirmed,
    needsReview = flag(day, "needsReview"),
    sessions = sessions,
  }
end

-- Worked minus target over the days in [from, to), all before today, leaving out the
-- unreviewed missing days (spec §6.6).
function Model.settle(book: Book, from: string, to: string): Settled
  local delta, toReview, needsReview = 0, {}, {}
  local date = from
  while date < to do
    local summary = Model.daySummary(date, book, to)
    if summary.missing then
      table.insert(toReview, date)
    else
      delta += summary.workedMs - summary.targetMs
    end
    if summary.needsReview then
      table.insert(needsReview, date)
    end
    date = Time.addDays(date, 1)
  end
  return { deltaMs = delta, toReview = toReview, needsReview = needsReview }
end

-- The settled balance from the settled days: plus the initial balance and every
-- adjustment.
function Model.balanceOf(balance: Balance, settled: Settled): BalanceSummary
  local adjustments = 0
  for _, adjustment in balance.adjustments do
    adjustments += adjustment.minutes * MINUTE_MS
  end
  local initial = balance.initialBalanceMin * MINUTE_MS
  return {
    settledMs = initial + settled.deltaMs + adjustments,
    initialMs = initial,
    deltaMs = settled.deltaMs,
    adjustmentsMs = adjustments,
    toReview = settled.toReview,
    needsReview = settled.needsReview,
  }
end

-- The settled balance on `today` (spec §6.6): every day from tracking start to yesterday.
-- The service keeps it by month instead (lib/totals.luau).
function Model.balance(book: Book, today: string): BalanceSummary
  return Model.balanceOf(book.balance, Model.settle(book, book.balance.trackingStart, today))
end

-- Day editor (spec §6.8.2, §6.8.3) --------------------------------------------------

export type DayDraft = {
  date: string,
  sessions: { { startS: number, endS: number } },
  openStartS: number?, -- the running session's start, when it belongs to this day
}

-- Checks the sessions of an edited day. Returns nil when valid, else the index of the
-- first faulty session (0 for the running one) and a reason: "order" (end ≤ start),
-- "bounds" (outside the workday), "future" (after now), or "overlap".
function Model.validateDay(draft: DayDraft, dayStartHour: number, nowS: number): (number?, string?)
  local fromS = Time.workdayStartS(draft.date, dayStartHour)
  local toS = Time.workdayStartS(Time.addDays(draft.date, 1), dayStartHour)
  local ranges = {}
  for index, session in draft.sessions do
    if session.endS <= session.startS then
      return index, "order"
    elseif session.startS < fromS or session.endS > toS then
      return index, "bounds"
    elseif session.endS > nowS then
      return index, "future"
    end
    table.insert(ranges, { index = index, startS = session.startS, endS = session.endS })
  end
  local open = draft.openStartS
  if open then
    if open < fromS or open >= toS then
      return 0, "bounds"
    elseif open > nowS then
      return 0, "future"
    end
    table.insert(ranges, { index = 0, startS = open, endS = math.huge })
  end
  table.sort(ranges, function(a, b)
    return a.startS < b.startS
  end)
  for i = 2, #ranges do
    if ranges[i].startS < ranges[i - 1].endS then
      return math.max(ranges[i].index, ranges[i - 1].index), "overlap"
    end
  end
  return nil
end

-- Sessions -------------------------------------------------------------------

function Model.newDay(): Day
  return { sessions = {}, flags = {}, note = "" }
end

local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"

local function base36(n: number): string
  local out = ""
  repeat
    local digit = n % 36
    out = string.sub(DIGITS, digit + 1, digit + 1) .. out
    n //= 36
  until n == 0
  return out
end

-- Session ids derive from the start time: sessions never overlap, so starts are unique,
-- and the id of an open session tells whether it already reached the ledger.
function Model.sessionId(startS: number): string
  return "s_" .. base36(startS)
end

-- Inserts a closed session into a day, keeping sessions sorted (spec §6.1 invariants).
-- Returns false and "overlap" when it would overlap an existing session.
function Model.addSession(day: Day, session: Session): (boolean, string?)
  local index = #day.sessions + 1
  for i, other in day.sessions do
    if session.startS < other.endS and other.startS < session.endS then
      return false, "overlap"
    end
    if session.startS < other.startS and index > i then
      index = i
    end
  end
  table.insert(day.sessions, index, session)
  return true
end

-- Removes a session by id; returns whether it was there.
function Model.removeSession(day: Day, id: string): boolean
  for i, session in day.sessions do
    if session.id == id then
      table.remove(day.sessions, i)
      return true
    end
  end
  return false
end

function Model.hasSession(day: Day, id: string): boolean
  for _, session in day.sessions do
    if session.id == id then
      return true
    end
  end
  return false
end

-- Worked time of the recorded sessions of a day (spec §6.5). Removed absences are not
-- part of any session.
function Model.closedWorkedMs(day: Day?): number
  local total = 0
  if day then
    for _, session in day.sessions do
      total += (session.endS - session.startS) * 1000
    end
  end
  return total
end

-- Absences ---------------------------------------------------------------------

-- Precedence of the signals of a merged absence (spec §6.3.5): sleep/gap > lock > idle.
local SIGNAL_RANK = { idle = 1, lock = 2, sleep = 3, gap = 3 }

function Model.strongestSignal(signals: { AwaySignal }): AwaySignal
  local best: AwaySignal = signals[1]
  for _, signal in signals do
    if SIGNAL_RANK[signal] > SIGNAL_RANK[best] then
      best = signal
    end
  end
  return best
end

-- The action configured for the strongest signal; offline gaps follow `sleep`.
function Model.absenceAction(settings: Settings, signals: { AwaySignal }): AbsenceAction
  local signal = Model.strongestSignal(signals)
  if signal == "gap" then
    signal = "sleep"
  end
  return settings.actions[signal]
end

function Model.absenceId(startS: number): string
  return "a_" .. base36(startS)
end

-- Tracking status (spec §6.1): away while an absence that is not ignored is in progress.
function Model.status(state: State, settings: Settings): Status
  if not state.open then
    return "off"
  end
  local absence = state.absence
  if absence and Model.absenceAction(settings, absence.signals) ~= "ignore" then
    return "away"
  end
  return "working"
end

-- Undo -----------------------------------------------------------------------

-- The action an undo would revert now: the top of the stack, if inside the window.
function Model.undoable(state: State, nowS: number): UndoEntry?
  local stack = state.undo
  local top = stack and stack[#stack]
  if top and nowS - top.atS < Model.UNDO_WINDOW_S then
    return top
  end
  return nil
end

-- What an undo would revert, for the UIs' labels: the action, refined for flags and
-- adjustments ("day_off", "adjust_remove"…).
local function undoKind(entry: UndoEntry): string
  if entry.action == "flag" then
    local name = entry.flag == "dayOff" and "day_off" or "not_worked"
    return entry.before and name .. "_cleared" or name
  elseif entry.action == "adjust" then
    return entry.added and "adjust_add" or "adjust_remove"
  end
  return entry.action
end

-- Snapshot -------------------------------------------------------------------

-- Builds the `shift.snapshot` value (spec §9.3). Counters cover closed sessions only:
-- the UIs add the running part of the open session themselves (`openStartMs`), so the
-- service does not publish every second. The open session counts toward the workday
-- it started on (E3).
export type SnapshotContext = {
  state: State,
  nowS: number,
  settings: Settings,
  book: Book,
  balance: BalanceSummary?, -- the service's, nil while it computes it
  automation: Types.SnapshotAutomation,
}

function Model.snapshot(ctx: SnapshotContext): Snapshot
  local settings, book, open = ctx.settings, ctx.book, ctx.state.open
  local today = Time.workdayOf(ctx.nowS, settings.dayStartHour)
  local todayRecord = book.dayOf(today)

  local status = Model.status(ctx.state, settings)
  local since
  if status == "away" then
    since = (ctx.state.absence :: any).startS
  elseif open then
    since = open.startS
  elseif todayRecord and #todayRecord.sessions > 0 then
    since = todayRecord.sessions[#todayRecord.sessions].endS
  end

  -- The open session counts toward the workday it started on; the rollover closes it
  -- when that workday ends, so this only fails between a day change and the next tick.
  local openToday = open and Time.workdayOf(open.startS, settings.dayStartHour) == today
  local openStartS = openToday and open.startS or nil

  local weekStart = Time.weekStart(today)
  local weekWorked, weekTarget = 0, 0
  for offset = 0, 6 do
    local key = Time.addDays(weekStart, offset)
    weekWorked += Model.closedWorkedMs(book.dayOf(key))
    weekTarget += Model.targetMs(key, book)
  end

  local sessions = {}
  for _, session in todayRecord and todayRecord.sessions or {} do
    table.insert(sessions, { startS = session.startS, endS = session.endS })
  end

  local absences, pending = {}, {}
  for _, absence in ctx.state.pending or ({} :: { Types.PendingAbsence }) do
    table.insert(pending, {
      id = absence.id,
      startS = absence.startS,
      endS = absence.endS,
      signal = Model.strongestSignal(absence.signals),
    })
    if absence.date == today then
      table.insert(absences, { startS = absence.startS, endS = absence.endS })
    end
  end

  local undo = Model.undoable(ctx.state, ctx.nowS)
  local suggestion = ctx.state.suggestion

  return {
    v = Model.SNAPSHOT_VERSION,
    status = status,
    since = since,
    today = {
      date = today,
      workedClosedMs = Model.closedWorkedMs(todayRecord),
      openStartMs = openStartS and openStartS * 1000 or nil,
      targetMs = Model.targetMs(today, book),
      isWorkday = Model.isContractDay(today, book.balance),
      holiday = book.holiday(today),
      dayOff = flag(todayRecord, "dayOff"),
      sessions = sessions,
      absences = absences,
    },
    week = { workedMs = weekWorked, targetMs = weekTarget },
    balance = ctx.balance and { settledMs = ctx.balance.settledMs, toReview = ctx.balance.toReview },
    pending = pending,
    suggestion = suggestion and suggestion.kind or nil,
    undo = undo and { id = undo.id, action = undo.action, kind = undoKind(undo), atS = undo.atS, date = (undo :: any).date } or nil,
    automation = ctx.automation,
    contract = {
      weeklyHours = settings.weeklyHours,
      workdays = settings.workdays,
      dailyTargetMs = Model.dailyTargetMs(settings),
      dayStartHour = settings.dayStartHour,
    },
    flags = { firstRun = not ctx.state.firstRunDismissed, needsReview = ctx.balance and ctx.balance.needsReview or {} },
    display = { durationFormat = settings.durationFormat },
  }
end

-- Live counters derived from a snapshot at `nowMs` (spec §6.5), computed by the UIs
-- every second. `remainingMs` is counted from the worked time truncated to the minute,
-- so the displayed worked and remaining times always add up to the target.
function Model.live(snapshot: Snapshot, nowMs: number): Live
  local today = snapshot.today
  local running = today.openStartMs and math.max(0, nowMs - today.openStartMs) or 0
  local worked = today.workedClosedMs + running
  local target = today.targetMs
  local remaining = math.max(0, target - worked // MINUTE_MS * MINUTE_MS)
  local eta
  if snapshot.status == "working" and today.openStartMs and worked < target then
    eta = (nowMs + target - worked) // 1000
  end
  return {
    workedMs = worked,
    targetMs = target,
    remainingMs = remaining,
    overtimeMs = math.max(0, worked - target),
    etaS = eta,
    weekWorkedMs = snapshot.week.workedMs + running,
    weekTargetMs = snapshot.week.targetMs,
  }
end

return Model
