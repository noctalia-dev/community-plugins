--!nonstrict
local h = require("./harness")
local hijri = require("../hijri")
local jalali = require("../jalali")

return function()
  h.describe("exact month starts from bundled data", function()
    -- 1447/1 begins 2025-06-27, straight from roozbehp/qamari.
    local start1447 = jalali.gregorianToJDN(2025, 6, 27)
    local y, m, d = hijri.fromJDN(start1447)
    h.eq(y, 1447, "year at a month start")
    h.eq(m, 1, "month at a month start")
    h.eq(d, 1, "day at a month start")

    local y2, m2, d2 = hijri.fromJDN(start1447 + 5)
    h.eq(y2, 1447, "mid-month year")
    h.eq(m2, 1, "mid-month month")
    h.eq(d2, 6, "mid-month day")

    -- The last day before the next month starts.
    local start1447m2 = jalali.gregorianToJDN(2025, 7, 26)
    local _y3, m3, d3 = hijri.fromJDN(start1447m2 - 1)
    h.eq(m3, 1, "day before month 2 is still month 1")
    h.eq(d3, 29, "muharram 1447 ran 29 days")

    local _y4, m4, d4 = hijri.fromJDN(start1447m2)
    h.eq(m4, 2, "month 2 starts on its listed date")
    h.eq(d4, 1, "and on day 1")
  end)

  h.describe("exactness horizon", function()
    -- Iran publishes about a year ahead; the bundled table stops at
    -- 1447/10 = 2026-03-21.
    local horizon = jalali.gregorianToJDN(2026, 3, 21)
    h.eq(hijri.isExact(horizon), true, "the last listed month start is exact")
    h.eq(hijri.isExact(horizon - 300), true, "well inside the table is exact")
    h.eq(hijri.isExact(horizon + 400), false, "past the table is approximate")
    h.eq(hijri.exactMaxJDN(), horizon, "horizon is reported")
  end)

  h.describe("continuity across the horizon", function()
    -- Prediction must continue the real sequence, not restart from an epoch.
    local horizon = jalali.gregorianToJDN(2026, 3, 21)
    local prev = { hijri.fromJDN(horizon) }
    for offset = 1, 800 do
      local y, m, d = hijri.fromJDN(horizon + offset)
      local py, pm, pd = prev[1], prev[2], prev[3]
      local contiguous = (y == py and m == pm and d == pd + 1)
        or (y == py and m == pm + 1 and d == 1)
        or (y == py + 1 and m == 1 and pm == 12 and d == 1)
      if not contiguous then
        h.ok(false, `discontinuity at +{offset}: {py}/{pm}/{pd} -> {y}/{m}/{d}`)
        break
      end
      prev = { y, m, d }
    end
    h.ok(true, "sequence stays contiguous past the horizon")
  end)

  h.describe("components stay in range over 20 years", function()
    local start = jalali.gregorianToJDN(2020, 1, 1)
    local finish = jalali.gregorianToJDN(2040, 1, 1)
    local bad = 0
    for jdn = start, finish do
      local y, m, d = hijri.fromJDN(jdn)
      if m < 1 or m > 12 or d < 1 or d > 30 or y < 1400 then
        bad += 1
      end
    end
    h.eq(bad, 0, "no out-of-range hijri components")
  end)

  h.describe("exactness survives backward extension", function()
    -- Regression for a review note on community-plugins#819. The lower bound
    -- of the observed table used to be read live from starts[1], which
    -- extendBefore() mutates. Converting any date before the table (here
    -- 1970, which extrapolates back to 1389 AH) moved that bound, and every
    -- extrapolated date after it reported itself as observed.
    local before = jalali.gregorianToJDN(1970, 1, 1)
    h.eq(hijri.isExact(before), false, "1970 is outside the observed table")

    local y = hijri.fromJDN(before) -- forces a backward extension
    h.ok(y < 1400, `1970 extrapolates before the table, got {y}`)

    h.eq(hijri.isExact(before), false, "still not exact after extending backwards")
    h.eq(hijri.lookup(before).exact, false, "lookup agrees after extending backwards")

    -- The observed range itself must be unaffected.
    local observed = jalali.gregorianToJDN(2025, 6, 27) -- 1447/1/1
    h.eq(hijri.isExact(observed), true, "observed dates stay exact")
    h.eq(hijri.lookup(observed).exact, true, "and lookup agrees")
  end)

  h.describe("month length", function()
    h.eq(hijri.monthLength(1447, 1), 29, "muharram 1447 ran 29 days")
    local len = hijri.monthLength(1447, 2)
    h.ok(len == 29 or len == 30, "a hijri month is 29 or 30 days")
  end)
end
