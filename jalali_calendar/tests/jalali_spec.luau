--!nonstrict
local h = require("./harness")
local jalali = require("../jalali")

return function()
  h.describe("gregorian <-> jdn", function()
    h.eq(jalali.gregorianToJDN(2000, 1, 1), 2451545, "epoch reference date")
    h.eq(jalali.gregorianToJDN(2026, 9, 22), 2461306, "today")

    local gy, gm, gd = jalali.gregorianFromJDN(2451545)
    h.eq(gy, 2000, "round-trip year")
    h.eq(gm, 1, "round-trip month")
    h.eq(gd, 1, "round-trip day")

    -- January is where truncation-vs-floor bugs show up: (gm - 8) / 6 is
    -- negative and non-integral, so flooring instead of truncating shifts the
    -- result by a day.
    local jy2, jm2, jd2 = jalali.gregorianFromJDN(jalali.gregorianToJDN(2024, 1, 31))
    h.eq(jy2, 2024, "january round-trip year")
    h.eq(jm2, 1, "january round-trip month")
    h.eq(jd2, 31, "january round-trip day")

    local ly, lm, ld = jalali.gregorianFromJDN(jalali.gregorianToJDN(2024, 2, 29))
    h.eq(ly, 2024, "leap day year")
    h.eq(lm, 2, "leap day month")
    h.eq(ld, 29, "leap day day")
  end)

  h.describe("day of week", function()
    h.eq(jalali.dayOfWeek(2451545), 0, "2000-01-01 is a Saturday")
    h.eq(jalali.dayOfWeek(2451546), 1, "next day is Sunday")
    h.eq(jalali.dayOfWeek(2451544), 6, "previous day is Friday")
  end)

  h.describe("jalali <-> jdn", function()
    h.eq(jalali.toJDN(1400, 1, 1), jalali.gregorianToJDN(2021, 3, 21), "nowruz 1400")
    h.eq(jalali.toJDN(1403, 1, 1), jalali.gregorianToJDN(2024, 3, 20), "nowruz 1403")
    h.eq(jalali.toJDN(1404, 1, 1), jalali.gregorianToJDN(2025, 3, 21), "nowruz 1404")
    h.eq(jalali.toJDN(1405, 1, 1), jalali.gregorianToJDN(2026, 3, 21), "nowruz 1405")
    h.eq(
      jalali.toJDN(1403, 12, 30),
      jalali.gregorianToJDN(2025, 3, 20),
      "last day of leap year 1403"
    )

    local jy, jm, jd = jalali.fromJDN(jalali.gregorianToJDN(2026, 9, 22))
    h.eq(jy, 1405, "today year")
    h.eq(jm, 6, "today month is shahrivar")
    h.eq(jd, 31, "today day")

    local ny, nm, nd = jalali.fromJDN(jalali.gregorianToJDN(2026, 9, 23))
    h.eq(ny, 1405, "tomorrow year")
    h.eq(nm, 7, "tomorrow month is mehr")
    h.eq(nd, 1, "tomorrow day")
  end)

  h.describe("leap years", function()
    h.eq(jalali.isLeapYear(1403), true, "1403 is leap")
    h.eq(jalali.isLeapYear(1404), false, "1404 is not leap")
    h.eq(jalali.isLeapYear(1405), false, "1405 is not leap")
  end)

  h.describe("month lengths", function()
    h.eq(jalali.monthLength(1405, 1), 31, "farvardin has 31 days")
    h.eq(jalali.monthLength(1405, 6), 31, "shahrivar has 31 days")
    h.eq(jalali.monthLength(1405, 7), 30, "mehr has 30 days")
    h.eq(jalali.monthLength(1405, 11), 30, "bahman has 30 days")
    h.eq(jalali.monthLength(1405, 12), 29, "esfand has 29 days in a common year")
    h.eq(jalali.monthLength(1403, 12), 30, "esfand has 30 days in a leap year")
  end)

  h.describe("round-trip over 200 years", function()
    -- Every JDN from Nowruz 1300 to Nowruz 1500 must survive
    -- jalali -> jdn -> jalali unchanged. This is the test that catches
    -- off-by-one errors the golden dates miss.
    local start = jalali.toJDN(1300, 1, 1)
    local finish = jalali.toJDN(1500, 1, 1)
    local broken = 0
    for jdn = start, finish do
      local y, m, d = jalali.fromJDN(jdn)
      if jalali.toJDN(y, m, d) ~= jdn then
        broken += 1
      end
    end
    h.eq(broken, 0, "no round-trip failures")
  end)

  h.describe("year length follows leap rule", function()
    for jy = 1390, 1420 do
      local days = jalali.toJDN(jy + 1, 1, 1) - jalali.toJDN(jy, 1, 1)
      local expected = if jalali.isLeapYear(jy) then 366 else 365
      h.eq(days, expected, `year {jy} has the right number of days`)
    end
  end)
end
