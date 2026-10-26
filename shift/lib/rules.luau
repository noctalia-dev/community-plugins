--!nonstrict
-- Automation window (spec §6.3.3): when automation may act on its own.
--
-- The window comes from two layers (D29): the base window of the typed settings, which
-- stands for the rules `+ <contract workdays> <start>-<end>` and `- holidays`, and the
-- `extra_rules` lines of the DSL below. An instant is inside the window when an include
-- rule matches it and no exclude rule does; days off are always outside.
--
--   rule       = sign selector [timerange]       e.g. "- * 12:00-13:30"
--   sign       = "+" | "-"
--   selector   = "*" | "holidays" | days | date | date ".." date
--   days       = day[-day] {"," day[-day]}       ranges may wrap: fri-mon
--   timerange  = HH:MM "-" HH:MM                 end > start, "24:00" allowed as end
--
-- Rules are case-insensitive and match local calendar dates and wall-clock times. Invalid
-- lines are skipped and reported (`errors`), never fatal. Pure: the calendar (holidays,
-- days off) comes in as an argument.

local Time = require("./time.luau")
local Types = require("./types.luau")

type Calendar = Types.Calendar
type RuleError = Types.RuleError

export type Rule = {
  include: boolean,
  kind: "all" | "holidays" | "days" | "dates",
  days: { boolean }?, -- ISO weekday 1 = Monday … 7 = Sunday
  from: string?, -- inclusive date range for "dates"
  to: string?,
  startMin: number, -- [startMin, endMin) in minutes of the day
  endMin: number,
}

export type Compiled = { rules: { Rule }, errors: { RuleError } }

export type WindowSettings = {
  workdays: { boolean },
  start: string,
  ["end"]: string,
  excludeHolidays: boolean,
  extraRules: { string },
}

local Rules = {}

local DAY_MIN = 24 * 60
local DAYS = { mon = 1, tue = 2, wed = 3, thu = 4, fri = 5, sat = 6, sun = 7 }

-- Calendar used when holidays and days off are unknown.
Rules.NO_CALENDAR = {
  isHoliday = function(_dateKey: string): boolean
    return false
  end,
  isDayOff = function(_dateKey: string): boolean
    return false
  end,
} :: Calendar

-- Parsing ----------------------------------------------------------------------

-- Minutes since midnight of "HH:MM" (or "H:MM"); "24:00" only when `isEnd`.
function Rules.parseClock(text: string, isEnd: boolean?): number?
  local hours, minutes = string.match(text, "^(%d%d?):(%d%d)$")
  if not hours then
    return nil
  end
  local h, m = tonumber(hours) :: number, tonumber(minutes) :: number
  if m > 59 or h > 24 or (h == 24 and (m > 0 or not isEnd)) then
    return nil
  end
  return h * 60 + m
end

-- A real calendar date: Time.addDays normalises "2026-02-30" into March.
local function validDate(key: string): boolean
  return Time.parseDate(key) ~= nil and Time.addDays(key, 0) == key
end

local function parseDays(text: string): { boolean }?
  local days = { false, false, false, false, false, false, false }
  for part in string.gmatch(text, "[^,]+") do
    local first, last = string.match(part, "^(%a+)%-(%a+)$")
    first = first or part
    local from, to = DAYS[first], DAYS[last or first]
    if not from or not to then
      return nil
    end
    local day = from
    days[day] = true
    while day ~= to do
      day = day % 7 + 1
      days[day] = true
    end
  end
  return days
end

-- Fills `rule` from a selector; returns an error reason when it is invalid.
local function parseSelector(rule: Rule, text: string): string?
  if text == "*" then
    rule.kind = "all"
  elseif text == "holidays" then
    rule.kind = "holidays"
  elseif string.match(text, "^%d") then
    local from, to = string.match(text, "^([%d%-]+)%.%.([%d%-]+)$")
    from = from or text
    to = to or text
    if not validDate(from) or not validDate(to) then
      return "date"
    end
    if to < from then
      return "range"
    end
    rule.kind, rule.from, rule.to = "dates", from, to
  else
    local days = parseDays(text)
    if not days then
      return "selector"
    end
    rule.kind, rule.days = "days", days
  end
  return nil
end

-- Parses one DSL line; returns the rule, or nil and an error reason.
function Rules.parse(line: string): (Rule?, string?)
  local text = string.lower(string.match(line, "^%s*(.-)%s*$") :: string)
  text = string.gsub(text, "^\u{2212}", "-") -- a typographic minus works too
  text = string.gsub(text, "%s*,%s*", ",")
  local sign, rest = string.match(text, "^([%+%-])%s*(.*)$")
  if not sign then
    return nil, "syntax"
  end
  local selector, range, extra = string.match(rest, "^(%S+)%s*(%S*)%s*(.*)$")
  if not selector or extra ~= "" then
    return nil, "syntax"
  end
  local rule: Rule = { include = sign == "+", kind = "all", startMin = 0, endMin = DAY_MIN }
  local err = parseSelector(rule, selector)
  if err then
    return nil, err
  end
  if range ~= "" then
    local first, second = string.match(range, "^([%d:]+)%-([%d:]+)$")
    local startMin = first and Rules.parseClock(first)
    local endMin = second and Rules.parseClock(second, true)
    if not startMin or not endMin then
      return nil, "time"
    end
    if endMin <= startMin then
      return nil, "order"
    end
    rule.startMin, rule.endMin = startMin, endMin
  end
  return rule
end

-- Builds the effective rule list from the settings (spec §6.3.3, D29).
function Rules.compile(settings: WindowSettings): Compiled
  local rules: { Rule } = {}
  local errors: { RuleError } = {}

  local startMin = Rules.parseClock(settings.start)
  local endMin = Rules.parseClock(settings["end"], true)
  if not startMin then
    table.insert(errors, { setting = "window_start", text = settings.start, reason = "time" })
  end
  if not endMin then
    table.insert(errors, { setting = "window_end", text = settings["end"], reason = "time" })
  end
  if startMin and endMin then
    if endMin > startMin then
      table.insert(rules, { include = true, kind = "days", days = settings.workdays, startMin = startMin, endMin = endMin })
    elseif endMin < startMin then
      table.insert(errors, { setting = "window_end", text = settings["end"], reason = "order" })
    end
    -- Equal times: no base window, on purpose (automation only through extra rules).
  end
  if settings.excludeHolidays then
    table.insert(rules, { include = false, kind = "holidays", startMin = 0, endMin = DAY_MIN })
  end

  for index, line in settings.extraRules do
    local rule, reason = Rules.parse(line)
    if rule then
      table.insert(rules, rule)
    else
      table.insert(errors, { setting = "extra_rules", index = index, text = line, reason = reason :: string })
    end
  end
  return { rules = rules, errors = errors }
end

-- Evaluation ---------------------------------------------------------------------

-- Rules that apply on a date, with its day off, weekday and holiday looked up once; nil on
-- a day off.
local function rulesOn(compiled: Compiled, key: string, calendar: Calendar): { Rule }?
  if calendar.isDayOff(key) then
    return nil
  end
  local weekday = Time.weekday(key)
  local holiday: boolean? = nil
  local applying = {}
  for _, rule in compiled.rules do
    local applies
    if rule.kind == "all" then
      applies = true
    elseif rule.kind == "days" then
      applies = (rule.days :: { boolean })[weekday] == true
    elseif rule.kind == "dates" then
      applies = key >= (rule.from :: string) and key <= (rule.to :: string)
    else
      if holiday == nil then
        holiday = calendar.isHoliday(key)
      end
      applies = holiday
    end
    if applies then
      table.insert(applying, rule)
    end
  end
  return applying
end

local function insideOn(applying: { Rule }?, minute: number): boolean
  if not applying then
    return false
  end
  local included = false
  for _, rule in applying do
    if minute >= rule.startMin and minute < rule.endMin then
      if not rule.include then
        return false
      end
      included = true
    end
  end
  return included
end

-- Whether a local calendar date and minute of the day is inside the window.
function Rules.inside(compiled: Compiled, key: string, minute: number, calendar: Calendar): boolean
  return insideOn(rulesOn(compiled, key, calendar), minute)
end

function Rules.at(compiled: Compiled, epochS: number, calendar: Calendar): boolean
  local t = os.date("*t", epochS)
  return Rules.inside(compiled, Time.dateKey(t.year, t.month, t.day), t.hour * 60 + t.min, calendar)
end

-- The window can only change at midnight or at a rule boundary.
local function boundaries(compiled: Compiled): { number }
  local set, list = { [0] = true }, { 0 }
  for _, rule in compiled.rules do
    for _, minute in { rule.startMin, rule.endMin } do
      if minute < DAY_MIN and not set[minute] then
        set[minute] = true
        table.insert(list, minute)
      end
    end
  end
  table.sort(list)
  return list
end

-- First instant after `epochS` where the window changes value, looking up to 8 days
-- ahead; nil when it stays the same all that time.
function Rules.nextEdge(compiled: Compiled, epochS: number, calendar: Calendar): number?
  local current = Rules.at(compiled, epochS, calendar)
  local t = os.date("*t", epochS)
  local today = Time.dateKey(t.year, t.month, t.day)
  local minutes = boundaries(compiled)
  for offset = 0, 8 do
    local key = Time.addDays(today, offset)
    local year, month, day = Time.parseDate(key)
    for _, minute in minutes do
      local candidate = Time.localToEpoch(year :: number, month :: number, day :: number, minute // 60, minute % 60)
      if candidate > epochS and Rules.at(compiled, candidate, calendar) ~= current then
        return candidate
      end
    end
  end
  return nil
end

-- 7 × 24 preview of a week (spec §7.4.6): one string per day from Monday, one digit per
-- hour giving how many of its quarters are inside the window (0–4).
function Rules.preview(compiled: Compiled, weekStart: string, calendar: Calendar): { string }
  local days = {}
  for offset = 0, 6 do
    local applying = rulesOn(compiled, Time.addDays(weekStart, offset), calendar)
    local digits = table.create(24)
    for hour = 0, 23 do
      local count = 0
      for quarter = 0, 3 do
        if insideOn(applying, hour * 60 + quarter * 15) then
          count += 1
        end
      end
      digits[hour + 1] = tostring(count)
    end
    table.insert(days, table.concat(digits))
  end
  return days
end

return Rules
