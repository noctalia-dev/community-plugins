--!nonstrict
-- Shift core service: the single source of truth (spec §9.1). It owns the tracking
-- state, persists it, and publishes `shift.snapshot` for the UI entries, which send
-- their actions back as commands (lib/commands.luau). Every action, signal and tick
-- becomes an event for the reducer in lib/automation.luau; this file only wires the
-- host to it.

local Automation = require("./lib/automation.luau")
local Commands = require("./lib/commands.luau")
local Format = require("./lib/format.luau")
local Holidays = require("./lib/holidays.luau")
local Host = require("./lib/host.luau")
local Idle = require("./lib/signals/idle.luau")
local Logind = require("./lib/signals/logind.luau")
local Model = require("./lib/model.luau")
local Ring = require("./lib/ring.luau")
local Rules = require("./lib/rules.luau")
local Store = require("./lib/store.luau")
local Time = require("./lib/time.luau")
local Totals = require("./lib/totals.luau")
local Types = require("./lib/types.luau")

local SNAPSHOT_KEY = "shift.snapshot"
local BALANCE_KEY = "shift.balance"
local HISTORY_KEY = "shift.history"
-- Longest range a history request may cover: a month view with its leading and
-- trailing days.
local MAX_HISTORY_DAYS = 42
local TICK_MS = 5000
local HEARTBEAT_S = 60
-- A tick later than this means the clock jumped or the system slept (spec §6.3.2).
local GAP_S = 3 * TICK_MS // 1000 + 30
-- At startup, an older heartbeat means the service was not running (E1).
local STALE_HEARTBEAT_S = 2 * 60
-- A backward clock jump larger than this is logged (E7).
local BACKWARD_SLACK_S = 30
-- Wall time the settled balance may take per call, at load and afterwards (the CPU budget
-- is 100 ms and 25 ms). With a long history, the ticks come every CATCH_UP_MS until it is
-- computed (lib/totals.luau).
local LOAD_SLICE_MS = 40
local SLICE_MS = 8
local CATCH_UP_MS = 100

local host = Host.new()
local store = Store.new(host)
local settings = Model.readSettings(host.getConfig)
local state: Types.State = store:loadState()
local lastSaveS = 0
local backupDay: string? = nil
local lastPublishMinute: number? = nil
-- Daily target notification (spec §6.9): whether today's worked time was under the target
-- at the last publish (nil before the first one), and the workday already notified.
local belowTarget: boolean? = nil
local targetNotified: string? = nil

local function nowS(): number
  return host.nowMs() // 1000
end

local lastTickS = nowS()

local function today(): string
  return Time.workdayOf(nowS(), settings.dayStartHour)
end

-- On first run, tracking starts today (spec §6.10).
local loadedBalance = store:loadBalance()
local balance: Types.Balance = loadedBalance
  or { schema = Store.SCHEMA, trackingStart = today(), initialBalanceMin = 0, adjustments = {} }
if not loadedBalance then
  store:saveBalance(balance)
end

-- Recorded day, nil when nothing was recorded.
local function dayOf(dateKey: string): Types.Day?
  return store:day(dateKey)
end

local holidays: Holidays.Monitor? = nil

local function holidayOf(dateKey: string): string?
  return holidays and holidays.holiday(dateKey)
end

-- What targets and the balance read; `balance` is replaced on every change.
local book: Types.Book = { balance = balance, dayOf = dayOf, holiday = holidayOf }
local totals = Totals.new(book, os.clock)

-- Automation window ---------------------------------------------------------------

local calendar: Types.Calendar = {
  isHoliday = function(dateKey)
    return holidayOf(dateKey) ~= nil
  end,
  isDayOff = function(dateKey)
    return Model.hasFlag(dayOf(dateKey), "dayOff")
  end,
}
local rules: Rules.Compiled
local preview: { week: string, days: { string } }? = nil

local function compileRules()
  local window = settings.window
  rules = Rules.compile({
    workdays = settings.workdays,
    start = window.start,
    ["end"] = window["end"],
    excludeHolidays = window.excludeHolidays,
    extraRules = window.extraRules,
  })
  preview = nil
end

compileRules()

local windowProbe: Types.WindowProbe = {
  at = function(t)
    return Rules.at(rules, t, calendar)
  end,
  nextEdge = function(t)
    return Rules.nextEdge(rules, t, calendar)
  end,
}

-- Persistence and snapshot ------------------------------------------------------------

local function saveState()
  state.heartbeatS = nowS()
  lastSaveS = state.heartbeatS
  store:saveState(state)
end

local idle: Idle.IdleMonitor? = nil
local logind: Logind.LogindMonitor? = nil

local function automationInfo(now: number): Types.SnapshotAutomation
  local t = os.date("*t", now)
  local week = Time.weekStart(Time.dateKey(t.year, t.month, t.day))
  if not preview or preview.week ~= week then
    preview = { week = week, days = Rules.preview(rules, week, calendar) }
  end
  local hints = {}
  for _, hint in { idle and idle.hint(), holidays and holidays.hint() } do
    if not (state.hints and state.hints[hint]) then
      table.insert(hints, hint)
    end
  end
  return {
    preset = settings.preset,
    idleMin = settings.idleTimeoutMin,
    window = { start = settings.window.start, ["end"] = settings.window["end"], extraRules = #settings.window.extraRules },
    backends = {
      idle = idle and idle.health() or "off",
      logind = logind and logind.health() or "off",
      holidays = holidays and holidays.health() or "off",
    },
    ruleErrors = rules.errors,
    preview = (preview :: any).days,
    hints = hints,
  }
end

-- History and balance ----------------------------------------------------------------

-- The settled balance only changes with the data or the day: it is computed again after
-- a change (`invalidate`), and the balance and history keys are published with it.
local summary: Types.BalanceSummary? = nil
local summaryDay: string? = nil
local historyRange: { from: string, to: string }? = nil
local sliceMs = LOAD_SLICE_MS
local catchingUp = false -- the settled balance is still being computed

-- `calendar` when days off or holidays may have changed: the window preview shows them.
local function invalidate(calendar: boolean?)
  summary = nil
  if calendar then
    preview = nil
  end
end

local function publishHistory()
  local range = historyRange
  if not range then
    return
  end
  local current, day, days = today(), range.from, {}
  while day <= range.to do
    table.insert(days, Model.daySummary(day, book, current))
    day = Time.addDays(day, 1)
  end
  local info: Types.HistoryInfo = { from = range.from, to = range.to, days = days }
  host.state.set(HISTORY_KEY, info)
end

local function balanceSummary(): Types.BalanceSummary?
  local day = today()
  if summary and summaryDay == day then
    return summary
  end
  local computed = totals.summary(day, sliceMs)
  if catchingUp ~= (computed == nil) then
    catchingUp = computed == nil
    host.setUpdateInterval(if catchingUp then CATCH_UP_MS else TICK_MS)
  end
  if not computed then
    return nil
  end
  summary, summaryDay = computed, day
  local info: Types.BalanceInfo = {
    trackingStart = balance.trackingStart,
    initialBalanceMin = balance.initialBalanceMin,
    adjustments = balance.adjustments,
    initialMs = computed.initialMs,
    deltaMs = computed.deltaMs,
    adjustmentsMs = computed.adjustmentsMs,
    settledMs = computed.settledMs,
    toReview = computed.toReview,
  }
  host.state.set(BALANCE_KEY, info)
  publishHistory()
  return computed
end

-- Notifies once per workday when the worked time crosses the target during a session. A
-- target already reached when the service starts, or reached by editing the day while
-- checked out, is not a crossing.
local function checkTarget(snap: Types.Snapshot, now: number)
  local live = Model.live(snap, now * 1000)
  local below = live.targetMs <= 0 or live.workedMs < live.targetMs
  local crossed = belowTarget == true and not below
  belowTarget = below
  if not crossed or snap.status == "off" or targetNotified == snap.today.date then
    return
  end
  targetNotified = snap.today.date
  if not settings.notify.targetReached then
    return
  end
  local fmt = settings.durationFormat
  local worked = Format.duration(live.workedMs, fmt)
  local body = host.tr("notifications.target.body", { worked = worked })
  if snap.balance then
    local balanceMs = snap.balance.settledMs + live.workedMs - live.targetMs
    body = host.tr("notifications.target.body_balance", { worked = worked, balance = Format.signed(balanceMs, fmt) })
  end
  host.notify(host.tr("notifications.target.title"), body)
end

local function publish()
  local now = nowS()
  lastPublishMinute = now // 60
  local snap = Model.snapshot({
    state = state,
    nowS = now,
    settings = settings,
    book = book,
    balance = balanceSummary(),
    automation = automationInfo(now),
  })
  host.state.set(SNAPSHOT_KEY, snap)
  checkTarget(snap, now)
end

local function setBalance(next: Types.Balance)
  balance = next
  book.balance = next
  store:saveBalance(next)
  invalidate()
end

-- The contract in the settings applies from today on (D22).
local function syncContract()
  local history = Model.syncContract(balance.contractHistory, settings, today())
  if history then
    local next = table.clone(balance)
    next.contractHistory = history
    setBalance(next)
  end
end

local function configureHolidays()
  if holidays then
    holidays.configure({
      enabled = settings.holidays.enabled,
      country = settings.holidays.country,
      region = settings.holidays.region,
      fromYear = Time.year(balance.trackingStart),
    })
  end
end

-- Effects ------------------------------------------------------------------------------

local function addSession(date: string, session: Types.Session)
  local day = store:day(date, Model.newDay)
  local ok = Model.addSession(day, session)
  if ok then
    store:saveLedger(Time.year(date))
    return
  end
  -- Only reachable if the system clock went backwards during the session (E7).
  host.log(string.format("session %s on %s overlaps a recorded session, not saved", session.id, date))
  host.notifyError(host.tr("errors.overlap.title"), host.tr("errors.overlap.body"))
end

-- Applies `change` to the record of `date` and saves its ledger.
local function editDay(date: string, change: (day: Types.Day) -> ())
  local day = store:day(date, Model.newDay)
  change(day)
  store:saveLedger(Time.year(date))
end

local function apply(effects: { Types.Effect })
  for _, effect in effects do
    if string.sub(effect.type, 1, 7) == "ledger." then
      totals.changed(effect.date)
      invalidate(effect.type == "ledger.setFlag" or effect.type == "ledger.setDay")
    end
    if effect.type == "ledger.addSession" then
      addSession(effect.date, effect.session)
    elseif effect.type == "ledger.removeSession" then
      editDay(effect.date, function(day)
        Model.removeSession(day, effect.id)
      end)
    elseif effect.type == "ledger.setFlag" then
      editDay(effect.date, function(day)
        day.flags = day.flags or {}
        day.flags[effect.flag] = effect.value
      end)
    elseif effect.type == "ledger.setDay" then
      store:setDay(effect.date, effect.day)
      store:saveLedger(Time.year(effect.date))
    elseif effect.type == "balance.save" then
      local trackingStart = balance.trackingStart
      setBalance(effect.balance)
      if effect.balance.trackingStart ~= trackingStart then
        configureHolidays()
      end
    elseif effect.type == "state.save" then
      saveState()
    elseif effect.type == "publish" then
      publish()
    elseif effect.type == "notify" then
      local key = "notifications." .. effect.kind
      local duration = effect.ms and Format.short(host, effect.ms, settings.durationFormat)
      host.notify(host.tr(key .. ".title"), host.tr(key .. ".body", { duration = duration }))
    end
  end
end

local function dispatch(event: Types.Event): Types.Result
  local nextState, effects, result =
    Automation.reduce(state, event, { nowS = nowS(), settings = settings, window = windowProbe, dayOf = dayOf, balance = balance })
  state = nextState
  apply(effects)
  return result
end

-- Signals (spec §6.3.2) ---------------------------------------------------------------

local function onSignal(signal: string, atS: number)
  if signal == "resume" then
    lastTickS = nowS() -- the sleep is already an absence: no clock gap on top
  end
  local result = dispatch({ type = "signal", signal = signal, atS = atS })
  if not result.ok then
    host.log(string.format("signal %s: %s", signal, tostring(result.error)))
  end
end

local function startIdle()
  idle = Idle.start(host, {
    backend = settings.idleBackend,
    timeoutS = settings.idleTimeoutMin * 60,
    onSignal = onSignal,
  })
end

-- The manual preset ignores every signal: nothing is spawned then.
local function startSignals()
  if Model.usesSignals(settings) then
    startIdle()
    logind = Logind.start(host, onSignal)
  end
end

local function stopSignals()
  if idle then
    idle.stop()
    idle = nil
  end
  if logind then
    logind.stop()
    logind = nil
  end
end

-- Startup ------------------------------------------------------------------------------

syncContract()

-- Holidays change targets and the window: both are evaluated afresh, by the next tick,
-- since a configuration change can happen while effects are being applied.
local calendarChanged = false
local holidayDates: { [string]: string } = {}
holidays = Holidays.start(host, function()
  local dates = holidays and holidays.dates() or {}
  for date, name in dates do
    if holidayDates[date] ~= name then
      totals.changed(date)
    end
  end
  for date in holidayDates do
    if dates[date] == nil then
      totals.changed(date)
    end
  end
  holidayDates = table.clone(dates)
  invalidate(true)
  calendarChanged = true
end)
configureHolidays()

-- A check-out writes the ledger before the state: if Noctalia stopped in between, the
-- open session is already recorded and must not stay open.
if state.open then
  local day = store:day(Time.workdayOf(state.open.startS, settings.dayStartHour))
  if day and Model.hasSession(day, state.open.id) then
    state.open = nil
  end
end

-- Rings cached for an older palette or older drawing code are never shown again.
Ring.prune(host)

do
  local heartbeat = state.heartbeatS
  local stale = state.open and heartbeat and nowS() - heartbeat > STALE_HEARTBEAT_S
  dispatch({ type = "start", startS = stale and heartbeat or nil })
end
calendarChanged = false -- the start evaluates the window anyway
startSignals()

-- Commands come from other entries' state writes: only the UI actions and their known
-- fields are forwarded (signals, ticks and the like are the service's own events).
local UI_COMMANDS = {
  checkin = true,
  checkout = true,
  undo = true,
  ["absence.resolve"] = true,
  ["suggestion.dismiss"] = true,
  ["hint.dismiss"] = true,
  ["onboarding.dismiss"] = true,
  ["day.save"] = true,
  ["day.flag"] = true,
  ["adjust.add"] = true,
  ["adjust.remove"] = true,
  ["balance.meta"] = true,
}
local COMMAND_FIELDS = {
  id = "string",
  keep = "boolean",
  kind = "string",
  date = "string",
  sessions = "table",
  openStartS = "number",
  dayOff = "boolean",
  flag = "string",
  value = "boolean",
  minutes = "number",
  note = "string",
  trackingStart = "string",
  initialBalanceMin = "number",
}

-- The panel asks for the days it shows; they are published on `shift.history`, and again
-- whenever the data changes.
local function requestHistory(cmd): Types.Result
  local from, to = cmd.from, cmd.to
  if not Time.isDate(from) or not Time.isDate(to) or to < from or Time.daysBetween(from, to) >= MAX_HISTORY_DAYS then
    return { ok = false, error = "invalid_range" }
  end
  historyRange = { from = from, to = to }
  publishHistory()
  return { ok = true, changed = false }
end

Commands.receiver(host, function(cmd)
  if cmd.type == "history.get" then
    return requestHistory(cmd)
  end
  if not UI_COMMANDS[cmd.type] then
    return { ok = false, error = "unknown_command" }
  end
  local event: Types.Event = { type = cmd.type }
  for field, kind in COMMAND_FIELDS do
    if type(cmd[field]) == kind then
      (event :: any)[field] = cmd[field]
    end
  end
  return dispatch(event)
end)

sliceMs = SLICE_MS
host.setUpdateInterval(if catchingUp then CATCH_UP_MS else TICK_MS)

-- Host callbacks ---------------------------------------------------------------------

function update()
  local now = nowS()
  if now < lastTickS - BACKWARD_SLACK_S then
    -- The clock went backwards (E7): no absence, the open session is kept.
    host.log(string.format("system clock went back by %d s", lastTickS - now))
  elseif state.open and now - lastTickS > GAP_S then
    dispatch({ type = "signal", signal = "gap", startS = lastTickS, endS = now })
  end
  lastTickS = now

  if idle then
    idle.tick()
  end
  if logind then
    logind.tick()
  end
  if holidays then
    holidays.tick()
  end
  if calendarChanged then
    calendarChanged = false
    dispatch({ type = "calendar" })
    publish()
  end
  dispatch({ type = "tick" })

  if now - lastSaveS >= HEARTBEAT_S then
    saveState()
  end
  -- The first tick of each workday backs the data up (spec §10.1), after the rollover
  -- has closed the previous one.
  local workday = today()
  if backupDay ~= workday then
    backupDay = workday
    saveState()
    store:backup(workday)
  end
  -- Once a minute, so counters roll over to a new workday and week; on every tick while the
  -- settled balance is being computed.
  if catchingUp or now // 60 ~= lastPublishMinute then
    publish()
  end
end

function onConfigChanged()
  local old = settings
  settings = Model.readSettings(host.getConfig)
  compileRules()
  syncContract()
  configureHolidays()
  invalidate()
  -- Restart only what the change concerns (spec §8).
  local restarted = false
  if Model.usesSignals(settings) ~= Model.usesSignals(old) then
    stopSignals()
    startSignals()
    restarted = true
  elseif idle and (settings.idleBackend ~= old.idleBackend or settings.idleTimeoutMin ~= old.idleTimeoutMin) then
    idle.stop()
    startIdle()
    restarted = true
  end
  dispatch({ type = "config", restarted = restarted })
  publish()
end

local IPC_EVENTS = { checkin = true, checkout = true, toggle = true, undo = true }
local IPC_SIGNALS = { idle = true, active = true, lock = true, unlock = true, sleep = true, resume = true }

-- `adjust <±duration> [note…]`, dated today.
local function ipcAdjust(arg: string): Types.Result
  local amount, note = string.match(arg, "^(%S+)%s*(.*)$")
  local minutes = amount and Time.parseDuration(amount)
  if not minutes or minutes == 0 then
    return { ok = false, error = "invalid_adjustment" }
  end
  local id = string.format("j_%x%04x", host.nowMs(), math.random(0, 0xffff)) -- as the panel
  return dispatch({ type = "adjust.add", id = id, date = today(), minutes = minutes, note = note })
end

-- `dayoff [YYYY-MM-DD]` toggles the marker, today by default.
local function ipcDayOff(arg: string): Types.Result
  local date = arg ~= "" and arg or today()
  if not Time.isDate(date) then
    return { ok = false, error = "invalid_flag" }
  end
  return dispatch({ type = "day.flag", date = date, flag = "dayOff", value = not calendar.isDayOff(date) })
end

local function trim(payload: any): string
  return type(payload) == "string" and (string.match(payload, "^%s*(.-)%s*$") :: string) or ""
end

function onIpc(event, payload)
  local arg = trim(payload)
  local result: Types.Result
  if IPC_EVENTS[event] then
    result = dispatch({ type = event })
  elseif event == "resolve" and (arg == "keep" or arg == "remove") then
    local oldest = state.pending and state.pending[1]
    if not oldest then
      result = { ok = false, error = "nothing_pending" }
    else
      result = dispatch({ type = "absence.resolve", id = oldest.id, keep = arg == "keep" })
    end
  elseif event == "adjust" then
    result = ipcAdjust(arg)
  elseif event == "dayoff" then
    result = ipcDayOff(arg)
  elseif event == "holidays-refresh" then
    if holidays then
      holidays.refresh()
    end
    return
  elseif event == "signal" and IPC_SIGNALS[arg] then
    -- External integrations (idle_backend = external, spec §11).
    onSignal(arg, nowS())
    return
  else
    host.log(string.format("unknown IPC event: %s %s", tostring(event), arg))
    return
  end
  if not result.ok then
    host.log(string.format("IPC %s: %s", event, tostring(result.error)))
  end
end

-- Persist on reload, disable and shutdown; an open session stays open (E20, E21).
function onExit(_signal, _reason)
  saveState()
end
