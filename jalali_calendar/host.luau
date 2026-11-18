--!nonstrict
-- The bits of host interaction all three entries need.
--
-- Entries run in separate VMs and share no memory, so each one reads its own
-- settings and resolves its own "today". This module keeps that from being
-- written three times, which is where drift between the bar and the panel
-- would otherwise creep in.

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

local calendar = req("./calendar")
local jalali = req("./jalali")

local M = {}

M.PANEL_ID = "borderliner/jalali_calendar:calendar"

-- JDN of the Unix epoch, for the fallback clock path.
local UNIX_EPOCH_JDN = 2440588

-- Vazirmatn is bundled (SIL OFL 1.1) rather than assumed present: the host's
-- default bar font often has no Persian glyphs, and a published plugin cannot
-- rely on the user having installed one.
--
-- Returns the registered family name, or nil when the font could not be
-- loaded, in which case callers simply leave fontFamily unset and inherit the
-- host default. A missing font must never stop the calendar rendering.
local fontFamily = nil
local fontLoaded = false

function M.font(): string?
  if fontLoaded then
    return fontFamily
  end
  fontLoaded = true
  -- Bold is registered too so fontWeight = "bold" has a real face to use
  -- instead of being synthesised.
  local family = noctalia.loadFont("fonts/Vazirmatn-Regular.ttf")
  noctalia.loadFont("fonts/Vazirmatn-Bold.ttf")
  fontFamily = family
  return fontFamily
end

-- Normalises the raw manifest settings into the option table the pure modules
-- expect.
--
-- Each entry script makes its own noctalia.getConfig calls and passes the
-- values in, rather than this module reading them: `noctalia plugins lint`
-- scans entry files for getConfig("key") and does not follow require, so
-- reading settings in here would make every one of them look unread. The
-- defaulting logic still lives in one place.
function M.normalize(raw)
  return {
    lang = raw.language or "persian",
    digits = raw.digits or "persian",
    weekStart = raw.week_start or "saturday",
    -- getConfig yields nil for an unset boolean, and these all default true.
    showHijri = raw.show_hijri ~= false,
    showGregorian = raw.show_gregorian ~= false,
    showHolidays = raw.show_holidays ~= false,
    -- Clamped rather than trusted: the manifest constrains it, but a
    -- hand-edited config should not be able to produce a zero or negative
    -- font size.
    scale = math.max(0.7, math.min(2.0, tonumber(raw.scale) or 1.0)),
    -- Which groups of occasion to show. Public holidays are not filtered by
    -- these: an Iranian day off is always shown.
    categories = {
      national = raw.events_national ~= false,
      religious = raw.events_religious == true,
      ancient = raw.events_ancient ~= false,
      afghan = raw.events_afghan == true,
    },
    todayJDN = 0,
  }
end

-- Parses "YYYY-MM-DD". Returns nil rather than erroring when the host hands
-- back something unexpected, so the caller can fall back.
local function parseDate(text): (number?, number?, number?)
  if type(text) ~= "string" then
    return nil
  end
  local y, m, d = text:match("^(%d+)-(%d+)-(%d+)$")
  if y == nil then
    return nil
  end
  return tonumber(y), tonumber(m), tonumber(d)
end

-- Today in the user's local timezone.
--
-- Asks the host to format the date rather than using os.date: the host knows
-- the user's timezone, and this does not depend on what the sandboxed VM
-- happens to expose. Falls back to a UTC date derived from os.time() so a
-- surprising host response degrades to a slightly-off date instead of a dead
-- entry.
function M.today()
  local gy, gm, gd = parseDate(noctalia.formatTime("%Y-%m-%d"))
  if gy == nil then
    local days = math.floor(os.time() / 86400)
    gy, gm, gd = jalali.gregorianFromJDN(UNIX_EPOCH_JDN + days)
  end
  return calendar.today(gy, gm, gd)
end

-- The occasion titles for a cell, in the configured language. Titles are
-- Persian in the source data; Latin mode still shows them, because there is no
-- translation of them to show instead.
function M.occasionTitles(cell): { string }
  local out = {}
  for _, occasion in cell.occasions do
    table.insert(out, occasion.title)
  end
  return out
end

return M
