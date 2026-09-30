--!nonstrict
-- Occasion lookup.
--
-- Occasions are stored by rule, not resolved per Jalali year: a date is
-- converted into all three calendars and each table is consulted. That keeps
-- the bundled data small and keeps it correct for any year, including ones
-- past whatever range happened to be generated.
--
-- A malformed or missing data file must not take down three entry VMs, so the
-- module degrades to "no occasions" rather than erroring.

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

local M = {}

local EMPTY = table.freeze({})

local ok, data = pcall(function()
  return req("./occasions")
end)

if not ok or type(data) ~= "table" or type(data.solar) ~= "table" then
  data = {
    version = 0,
    solar = {},
    lunar = {},
    lunarEndOfMonth = {},
    gregorian = {},
  }
end

function M.isAvailable(): boolean
  return (data.version or 0) > 0
end

-- Entries are stored as compact arrays: { title, isOfficialHoliday, category }.
--
-- Category filtering applies to occasions, not to public holidays: an Iranian
-- day off is always shown, by name, whatever is switched on, because the
-- calendar should always say which days are days off.
--
-- Categories whose holiday flag is an Iranian public holiday. An Afghan public
-- holiday is not an Iranian day off, so it only counts when the user has opted
-- into Afghan events.
local IRANIAN = { national = true, religious = true }

local function append(out, bucket, enabled, state)
  if bucket == nil then
    return
  end
  for _, entry in bucket do
    local category = entry[3]
    local isHoliday = entry[2] == true
    -- An Iranian day off is always named. Anything else obeys the filters,
    -- including Afghan holidays: those are days off in Afghanistan, not here.
    local alwaysShow = isHoliday and IRANIAN[category]
    if alwaysShow or enabled == nil or enabled[category] then
      table.insert(out, { title = entry[1], holiday = isHoliday, category = category })
      if isHoliday then
        state.holiday = true
      end
    end
  end
end

local function lookup2(tbl, a: number, b: number)
  local row = tbl and tbl[a]
  return row and row[b]
end

-- Pure table lookups against a date already converted into all three
-- calendars. The grid converts once per cell and calls this, rather than
-- having every lookup redo the conversions -- which is what pushed the panel
-- past the host's per-callback CPU budget.
--
-- ctx = { jm, jd, hm, hd, hijriMonthLength, gm, gd }
-- enabled maps category name -> true; nil means every category.
--
-- Returns the visible occasions and whether the day is an official holiday.
function M.forContext(ctx, enabled): ({ any }, boolean)
  local result = {}
  local state = { holiday = false }

  append(result, lookup2(data.solar, ctx.jm, ctx.jd), enabled, state)
  append(result, lookup2(data.lunar, ctx.hm, ctx.hd), enabled, state)

  -- "End of month" occasions land on the last day, whether the month ran 29
  -- or 30 days, so they cannot be stored under a fixed day number.
  if ctx.hd == ctx.hijriMonthLength then
    append(result, data.lunarEndOfMonth and data.lunarEndOfMonth[ctx.hm], enabled, state)
  end

  append(result, lookup2(data.gregorian, ctx.gm, ctx.gd), enabled, state)

  local occasions = if #result == 0 then EMPTY else result
  return occasions, state.holiday
end

-- Convenience wrapper that does the conversions itself. Returns the visible
-- occasions and whether the day is an official Iranian holiday.
function M.forDay(jy: number, jm: number, jd: number, enabled): ({ any }, boolean)
  local jdn = jalali.toJDN(jy, jm, jd)
  local hijriInfo = hijri.lookup(jdn)
  local _, gm, gd = jalali.gregorianFromJDN(jdn)
  return M.forContext({
    jm = jm,
    jd = jd,
    hm = hijriInfo.month,
    hd = hijriInfo.day,
    hijriMonthLength = hijriInfo.monthLength,
    gm = gm,
    gd = gd,
  }, enabled)
end

-- Whether the day is an official Iranian holiday.
function M.isHoliday(jy: number, jm: number, jd: number, enabled): boolean
  local _, holiday = M.forDay(jy, jm, jd, enabled)
  return holiday
end

function M.forMonth(jy: number, jm: number, enabled): { [number]: { any } }
  local result = {}
  for jd = 1, jalali.monthLength(jy, jm) do
    local occasions = M.forDay(jy, jm, jd, enabled)
    if #occasions > 0 then
      result[jd] = occasions
    end
  end
  return result
end

return M
