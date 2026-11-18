--!nonstrict
-- Solar Hijri (Jalali) <-> Julian Day Number <-> Gregorian.
--
-- Uses Borkowski's breakpoint method, the same algorithm behind jalaali-js and
-- moment-jalaali. Exact against Iran's official calendar for Jalali years
-- 1178-1633 (about 1799-2256 CE).
--
-- Every conversion pivots on JDN; Jalali <-> Gregorian is never written
-- directly. Weekdays are 0 = Saturday .. 6 = Friday, matching the Iranian week.

local M = {}

-- Integer division truncating toward zero. NOT math.floor: for negative
-- operands the reference algorithm truncates, and flooring shifts dates by a
-- day. (gm - 8) / 6 with gm = 1 is the case that catches it.
local function idiv(a: number, b: number): number
  local q = a / b
  if q >= 0 then
    return math.floor(q)
  end
  return -math.floor(-q)
end

local function imod(a: number, b: number): number
  return a - idiv(a, b) * b
end

M.idiv = idiv
M.imod = imod

function M.gregorianToJDN(gy: number, gm: number, gd: number): number
  local d = idiv((gy + idiv(gm - 8, 6) + 100100) * 1461, 4)
    + idiv(153 * imod(gm + 9, 12) + 2, 5)
    + gd
    - 34840408
  d = d - idiv(idiv(gy + 100100 + idiv(gm - 8, 6), 100) * 3, 4) + 752
  return d
end

function M.gregorianFromJDN(jdn: number): (number, number, number)
  local j = 4 * jdn + 139361631
  j = j + idiv(idiv(4 * jdn + 183187720, 146097) * 3, 4) * 4 - 3908
  local i = idiv(imod(j, 1461), 4) * 5 + 308
  local gd = idiv(imod(i, 153), 5) + 1
  local gm = imod(idiv(i, 153), 12) + 1
  local gy = idiv(j, 1461) - 100100 + idiv(8 - gm, 6)
  return gy, gm, gd
end

-- JDN 2451545 is 2000-01-01, a Saturday, and 2451545 % 7 == 5.
-- Shifting by +2 maps Saturday to 0.
function M.dayOfWeek(jdn: number): number
  return (jdn + 2) % 7
end

-- Breakpoints of the 2820-year Borkowski cycle. Valid for Jalali years
-- 1178-1633; outside that range the calendar is not defined by this method.
local BREAKS = { -61, 9, 38, 199, 426, 686, 756, 818, 1111, 1181, 1210, 1635, 2060 }

-- Returns the Gregorian year containing Nowruz of jy, the March day Nowruz
-- falls on, and the leap indicator (0 means jy is a leap year).
local function jalCal(jy: number): (number, number, number)
  local gy = jy + 621
  local leapJ = -14
  local jp = BREAKS[1]

  if jy < jp or jy >= BREAKS[#BREAKS] then
    error(`jalali year out of range: {jy}`)
  end

  local jump = 0
  for i = 2, #BREAKS do
    local jm = BREAKS[i]
    jump = jm - jp
    if jy < jm then
      break
    end
    leapJ = leapJ + idiv(jump, 33) * 8 + idiv(imod(jump, 33), 4)
    jp = jm
  end

  local n = jy - jp
  leapJ = leapJ + idiv(n, 33) * 8 + idiv(imod(n, 33) + 3, 4)
  if imod(jump, 33) == 4 and jump - n == 4 then
    leapJ += 1
  end

  local leapG = idiv(gy, 4) - idiv((idiv(gy, 100) + 1) * 3, 4) - 150
  local march = 20 + leapJ - leapG

  local nn = n
  if jump - n < 6 then
    nn = n - jump + idiv(jump + 4, 33) * 33
  end
  local leap = imod(imod(nn + 1, 33) - 1, 4)
  if leap == -1 then
    leap = 4
  end

  return gy, march, leap
end

function M.isLeapYear(jy: number): boolean
  local _, _, leap = jalCal(jy)
  return leap == 0
end

function M.toJDN(jy: number, jm: number, jd: number): number
  local gy, march = jalCal(jy)
  return M.gregorianToJDN(gy, 3, march) + (jm - 1) * 31 - idiv(jm, 7) * (jm - 7) + jd - 1
end

function M.fromJDN(jdn: number): (number, number, number)
  local gy = M.gregorianFromJDN(jdn)
  local jy = gy - 621
  local _, march, leap = jalCal(jy)
  local nowruz = M.gregorianToJDN(gy, 3, march)

  local k = jdn - nowruz
  if k >= 0 then
    if k <= 185 then
      -- First six months, all 31 days.
      return jy, 1 + idiv(k, 31), imod(k, 31) + 1
    end
    k -= 186
  else
    -- Before Nowruz, so we are still in the previous Jalali year. `leap` here
    -- is the indicator of the year we compared against, not of jy - 1. That
    -- is deliberate and matches the reference implementation.
    jy -= 1
    k += 179
    if leap == 1 then
      k += 1
    end
  end

  return jy, 7 + idiv(k, 30), imod(k, 30) + 1
end

function M.monthLength(jy: number, jm: number): number
  if jm <= 6 then
    return 31
  elseif jm <= 11 then
    return 30
  elseif M.isLeapYear(jy) then
    return 30
  end
  return 29
end

return M
