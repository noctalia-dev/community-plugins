--!nonstrict
local h = require("./harness")
local calendar = require("../calendar")
local jalali = require("../jalali")

local function baseOpts(overrides)
  local o = {
    lang = "persian",
    digits = "persian",
    weekStart = "saturday",
    showHijri = true,
    showGregorian = true,
    showHolidays = true,
    todayJDN = jalali.toJDN(1405, 6, 31),
  }
  for k, v in overrides or {} do
    o[k] = v
  end
  return o
end

local function eachCell(model, fn)
  for _, week in model.weeks do
    for i = 1, 7 do
      if week[i] ~= nil then
        fn(week[i], i)
      end
    end
  end
end

local function countCells(model)
  local n = 0
  eachCell(model, function()
    n += 1
  end)
  return n
end

local function findDay(model, jd)
  local found, col
  eachCell(model, function(cell, i)
    if cell.jd == jd then
      found, col = cell, i
    end
  end)
  return found, col
end

return function()
  h.describe("month shape", function()
    local model = calendar.buildMonth(1405, 6, baseOpts())
    h.eq(#model.weeks, 6, "always six week rows")
    h.eq(#model.weekdayHeaders, 7, "seven weekday headers")
    h.eq(countCells(model), 31, "shahrivar has 31 cells")
    h.eq(model.title, "شهریور ۱۴۰۵", "persian title")
    h.eq(calendar.buildMonth(1405, 6, baseOpts({ lang = "latin", digits = "latin" })).title,
      "Shahrivar 1405", "latin title")
  end)

  h.describe("esfand length follows leap year", function()
    h.eq(countCells(calendar.buildMonth(1403, 12, baseOpts())), 30, "leap esfand has 30")
    h.eq(countCells(calendar.buildMonth(1405, 12, baseOpts())), 29, "common esfand has 29")
  end)

  h.describe("days are contiguous and correctly dated", function()
    local model = calendar.buildMonth(1405, 7, baseOpts())
    local expected = jalali.toJDN(1405, 7, 1)
    for jd = 1, 30 do
      local cell = findDay(model, jd)
      h.eq(cell and cell.jdn, expected, `day {jd} has the right jdn`)
      expected += 1
    end
  end)

  h.describe("today marking", function()
    local model = calendar.buildMonth(1405, 6, baseOpts())
    local todays = 0
    eachCell(model, function(cell)
      if cell.isToday then
        todays += 1
        h.eq(cell.jd, 31, "today is the 31st")
      end
    end)
    h.eq(todays, 1, "exactly one cell is today")

    local other = calendar.buildMonth(1405, 5, baseOpts())
    local otherTodays = 0
    eachCell(other, function(cell)
      if cell.isToday then
        otherTodays += 1
      end
    end)
    h.eq(otherTodays, 0, "no today marker in another month")
  end)

  h.describe("rtl ordering", function()
    -- In Persian the grid runs right to left, so day 1 sits at a higher
    -- column index than day 2 when they share a row.
    local model = calendar.buildMonth(1405, 1, baseOpts())
    local _, col1 = findDay(model, 1)
    local _, col2 = findDay(model, 2)
    h.ok(col1 ~= nil, "day 1 is placed")
    h.ok(col1 > col2, "persian grid runs right to left")
  end)

  h.describe("ltr ordering", function()
    local model = calendar.buildMonth(1405, 1, baseOpts({ lang = "latin" }))
    local _, col1 = findDay(model, 1)
    local _, col2 = findDay(model, 2)
    h.ok(col1 < col2, "latin grid runs left to right")
  end)

  h.describe("week start shifts the leading offset", function()
    -- 1 Farvardin 1405 is 2026-03-21, a Saturday, so it is the first column
    -- under a Saturday week start.
    h.eq(jalali.dayOfWeek(jalali.toJDN(1405, 1, 1)), 0, "nowruz 1405 is a saturday")

    local sat = calendar.buildMonth(1405, 1, baseOpts({ lang = "latin" }))
    local _, colSat = findDay(sat, 1)
    h.eq(colSat, 1, "saturday start puts it in column 1")

    local sun = calendar.buildMonth(1405, 1, baseOpts({ lang = "latin", weekStart = "sunday" }))
    local _, colSun = findDay(sun, 1)
    h.eq(colSun, 7, "sunday start pushes saturday to the last column")
  end)

  h.describe("cell contents", function()
    local model = calendar.buildMonth(1405, 1, baseOpts())
    local nowruz = findDay(model, 1)
    h.ok(nowruz ~= nil, "found nowruz cell")
    h.eq(nowruz.isHoliday, true, "nowruz is a holiday")
    h.eq(nowruz.label, "۱", "day label uses persian digits")
    h.eq(nowruz.greg.y, 2026, "gregorian year")
    h.eq(nowruz.greg.m, 3, "gregorian month")
    h.eq(nowruz.greg.d, 21, "gregorian day")
    h.eq(nowruz.gregLabel, "21", "gregorian label stays in latin digits")
    h.ok(#nowruz.occasions >= 1, "nowruz carries its occasions")
  end)

  h.describe("settings switch off secondary numbers", function()
    local model = calendar.buildMonth(1405, 1, baseOpts({ showHijri = false, showGregorian = false }))
    local cell = findDay(model, 1)
    h.eq(cell.gregLabel, "", "gregorian label suppressed")
    h.eq(cell.hijriLabel, "", "hijri label suppressed")

    local noHolidays = calendar.buildMonth(1405, 1, baseOpts({ showHolidays = false }))
    local plain = findDay(noHolidays, 1)
    h.eq(plain.isHoliday, false, "holiday flag suppressed")
    h.eq(#plain.occasions, 0, "occasions suppressed")
  end)

  h.describe("fridays", function()
    local model = calendar.buildMonth(1405, 6, baseOpts())
    local fridays = 0
    eachCell(model, function(cell)
      if cell.isFriday then
        fridays += 1
        h.eq(jalali.dayOfWeek(cell.jdn), 6, "friday cell really is a friday")
      end
    end)
    h.ok(fridays >= 4 and fridays <= 5, `a month has 4 or 5 fridays, got {fridays}`)
  end)

  h.describe("month stepping", function()
    local y, m = calendar.step(1405, 12, 1)
    h.eq(y, 1406, "esfand rolls the year forward")
    h.eq(m, 1, "and wraps to farvardin")

    local py, pm = calendar.step(1405, 1, -1)
    h.eq(py, 1404, "farvardin rolls the year back")
    h.eq(pm, 12, "and wraps to esfand")

    local sy, sm = calendar.step(1405, 6, 1)
    h.eq(sy, 1405, "mid-year keeps the year")
    h.eq(sm, 7, "and advances the month")

    local ay, am = calendar.step(1405, 6, 12)
    h.eq(ay, 1406, "stepping a full year")
    h.eq(am, 6, "lands on the same month")
  end)

  h.describe("today from a gregorian date", function()
    local today = calendar.today(2026, 9, 22)
    h.eq(today.jy, 1405, "year")
    h.eq(today.jm, 6, "month")
    h.eq(today.jd, 31, "day")
    h.eq(today.jdn, jalali.gregorianToJDN(2026, 9, 22), "jdn")
  end)
end
