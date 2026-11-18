--!nonstrict
-- Builds the month model the UI renders.
--
-- This module owns every presentation decision that can be reasoned about
-- without a shell: cell contents, holiday flags, and crucially the RTL
-- ordering. The panel renders rows left to right unconditionally and gets a
-- correct Persian grid because the cells arrive pre-ordered. That keeps the
-- one genuinely fiddly piece of layout logic pure and testable.

-- Noctalia's require needs the ".luau" extension; the standalone luau CLI the
-- tests run under rejects it. Trying both lets one source file load in each,
-- which is what keeps the pure core testable outside the shell.
local function req(path: string)
  local ok, module = pcall(require, path .. ".luau")
  if ok then
    return module
  end
  return require(path)
end

local jalali = req("./jalali")
local hijri = req("./hijri")
local holidays = req("./holidays")
local fmt = req("./fmt")

local M = {}

-- Offset from Saturday (dayOfWeek 0) for each supported week start.
local WEEK_START_OFFSET = {
  saturday = 0,
  sunday = 1,
  monday = 2,
}

local EMPTY = table.freeze({})

function M.today(gy: number, gm: number, gd: number)
  local jdn = jalali.gregorianToJDN(gy, gm, gd)
  local jy, jm, jd = jalali.fromJDN(jdn)
  return { jy = jy, jm = jm, jd = jd, jdn = jdn }
end

function M.step(jy: number, jm: number, delta: number): (number, number)
  local index = (jy * 12) + (jm - 1) + delta
  return math.floor(index / 12), (index % 12) + 1
end

local function buildCell(jy: number, jm: number, jd: number, opts): any
  local jdn = jalali.toJDN(jy, jm, jd)
  local gy, gm, gd = jalali.gregorianFromJDN(jdn)
  -- One pass for date, exactness and month length; the grid builds 31 of these
  -- inside a single CPU budget.
  local h = hijri.lookup(jdn)

  local occasions, isHoliday = EMPTY, false
  if opts.showHolidays then
    occasions, isHoliday = holidays.forContext({
      jm = jm,
      jd = jd,
      hm = h.month,
      hd = h.day,
      hijriMonthLength = h.monthLength,
      gm = gm,
      gd = gd,
    }, opts.categories)
  end

  return {
    jd = jd,
    jdn = jdn,
    label = fmt.digits(jd, opts.digits),
    greg = { y = gy, m = gm, d = gd },
    -- Gregorian stays in Latin digits even in Persian mode: it is the
    -- cross-reference number, and rendering it in Persian digits beside the
    -- Jalali one makes the two indistinguishable at a glance.
    gregLabel = if opts.showGregorian then tostring(gd) else "",
    hijri = { y = h.year, m = h.month, d = h.day },
    hijriLabel = if opts.showHijri then fmt.digits(h.day, opts.digits) else "",
    isToday = jdn == opts.todayJDN,
    isFriday = jalali.dayOfWeek(jdn) == 6,
    isHoliday = isHoliday,
    occasions = occasions,
  }
end

function M.buildMonth(jy: number, jm: number, opts): any
  local rtl = opts.lang == "persian"
  local startOffset = WEEK_START_OFFSET[opts.weekStart] or 0
  local length = jalali.monthLength(jy, jm)

  -- Which column the 1st lands in, relative to the configured week start.
  local firstDow = jalali.dayOfWeek(jalali.toJDN(jy, jm, 1))
  local leading = (firstDow - startOffset + 7) % 7

  local weeks = {}
  for row = 1, 6 do
    weeks[row] = {}
  end

  for jd = 1, length do
    local slot = leading + jd - 1
    local row = math.floor(slot / 7) + 1
    local col = (slot % 7) + 1
    if rtl then
      col = 8 - col
    end
    if weeks[row] then
      weeks[row][col] = buildCell(jy, jm, jd, opts)
    end
  end

  -- Weekday headers, ordered to match the cells beneath them.
  local headers = {}
  for col = 1, 7 do
    local dow = (startOffset + col - 1) % 7
    local target = if rtl then 8 - col else col
    headers[target] = fmt.weekdayName(dow, opts.lang, true)
  end

  return {
    jy = jy,
    jm = jm,
    title = `{fmt.monthName(jm, opts.lang)} {fmt.digits(jy, opts.digits)}`,
    weekdayHeaders = headers,
    weeks = weeks,
  }
end

return M
