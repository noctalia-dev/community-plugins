--!nonstrict
-- Shared schedule logic for the DeepSeek Peak Hours v5 port.
-- Single source of truth: schedule.json (provider profiles + bundled Chinese
-- holidays), read at runtime from the plugin directory. Mirrors the v4
-- semantics of deepseek-peak/peak.js.
--
-- Performance note: Noctalia enforces a CPU budget per Luau callback, so this
-- module avoids os.date/string allocation in hot paths and computes tier
-- transitions from known boundary times instead of scanning minutes.

local M = {}

local FALLBACK = {
  providers = {
    deepseek = {
      name = "DeepSeek",
      peakWindowsUtc = { { "01:00", "04:00" }, { "06:00", "10:00" } },
      weekendMode = "beijing-anchored",
      holidayOffPeak = true,
      sourceUrl = "https://api-docs.deepseek.com/quick_start/pricing/",
      fallbackUrls = {
        "https://api-docs.deepseek.com/quick_start/pricing/",
        "https://www.deepseek.com/en/pricing",
      },
    },
    ollama = {
      name = "Ollama",
      peakWindowsUtc = { { "12:00", "18:00" } },
      weekendMode = "utc",
      holidayOffPeak = false,
      sourceUrl = "https://ollama.com/pricing",
      fallbackUrls = { "https://ollama.com/pricing", "https://docs.ollama.com/cloud" },
    },
  },
  holidays = {},
}

local BEIJING_OFFSET = 8 * 3600
local DAY = 86400

local data = nil
local holidaySet = nil
local windowCache = {}

local function load()
  if data ~= nil then
    return data
  end
  local raw = noctalia.readFile("schedule.json")
  if raw then
    local parsed = noctalia.json.decode(raw)
    if type(parsed) == "table" and type(parsed.providers) == "table" then
      data = parsed
      return data
    end
  end
  data = FALLBACK
  return data
end

local function profile(provider)
  local profiles = load().providers
  return profiles[provider] or profiles.deepseek
end

local function toMinutes(hhmm)
  local h, m = string.match(hhmm, "^(%d%d):(%d%d)$")
  return tonumber(h) * 60 + tonumber(m)
end

-- Numeric windows per provider, computed once.
local function windows(provider)
  local cached = windowCache[provider]
  if cached then
    return cached
  end
  local out = {}
  for _, w in ipairs(profile(provider).peakWindowsUtc) do
    table.insert(out, { start = toMinutes(w[1]), finish = toMinutes(w[2]) })
  end
  windowCache[provider] = out
  return out
end

-- Bundled holidays keyed by Beijing day number (days since epoch), built once.
local function holidays()
  if holidaySet ~= nil then
    return holidaySet
  end
  holidaySet = {}
  local byYear = load().holidays or {}
  for _, days in pairs(byYear) do
    for _, d in ipairs(days) do
      local y, mo, da = string.match(d, "^(%d%d%d%d)-(%d%d)-(%d%d)$")
      if y then
        local ts = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(da),
                             hour = 0, min = 0, sec = 0, isdst = false })
        holidaySet[math.floor(ts / DAY)] = true
      end
    end
  end
  return holidaySet
end

-- Lua weekday convention: 1 = Sunday .. 7 = Saturday. 1970-01-01 was a
-- Thursday, so day 0 maps to 5.
local function weekday(dayNumber)
  return ((dayNumber + 4) % 7) + 1
end

function M.providerName(provider)
  return profile(provider).name
end

function M.sourceUrl(provider)
  return profile(provider).sourceUrl
end

function M.fallbackUrls(provider)
  return profile(provider).fallbackUrls or {}
end

function M.scheduleWindows(provider)
  local out = {}
  for _, w in ipairs(profile(provider).peakWindowsUtc) do
    table.insert(out, w[1] .. "-" .. w[2])
  end
  return out
end

function M.scheduleText(provider)
  return table.concat(M.scheduleWindows(provider), ", ") .. " UTC"
end

function M.isPeakAt(now, provider)
  local p = profile(provider)
  local utcDay = math.floor(now / DAY)
  local bjDay = math.floor((now + BEIJING_OFFSET) / DAY)
  local off
  if p.weekendMode == "utc" then
    local wd = weekday(utcDay)
    off = wd == 1 or wd == 7
  else
    local wd = weekday(bjDay)
    off = wd == 1 or wd == 7
  end
  if off then
    return false
  end
  if p.holidayOffPeak and holidays()[bjDay] then
    return false
  end
  local minutes = math.floor((now - utcDay * DAY) / 60)
  for _, w in ipairs(windows(provider)) do
    if minutes >= w.start and minutes < w.finish then
      return true
    end
  end
  return false
end

-- Candidate instants where the tier can change: UTC midnights (weekend
-- boundaries), Beijing midnights (weekend/holiday boundaries) and window
-- edges. Scanning these instead of minutes keeps callbacks inside budget.
local function candidates(now, provider)
  local utcDay = math.floor(now / DAY)
  local out = {}
  for d = utcDay - 9, utcDay + 9 do
    local utcMid = d * DAY
    table.insert(out, utcMid)
    table.insert(out, utcMid - BEIJING_OFFSET)
    for _, w in ipairs(windows(provider)) do
      table.insert(out, utcMid + w.start * 60)
      table.insert(out, utcMid + w.finish * 60)
    end
  end
  table.sort(out)
  return out
end

function M.secondsUntilNext(now, provider)
  local tier = M.isPeakAt(now, provider)
  for _, c in ipairs(candidates(now, provider)) do
    if c > now and M.isPeakAt(c, provider) ~= tier then
      return c - now
    end
  end
  return 0
end

function M.formatCountdown(s)
  local h = math.floor(s / 3600)
  local m = math.floor((s % 3600) / 60)
  if h > 0 then
    return h .. "h" .. m .. "m"
  end
  return m .. "m"
end

function M.formatHMS(s)
  s = math.max(0, math.floor(s))
  return string.format("%02d:%02d:%02d", math.floor(s / 3600), math.floor((s % 3600) / 60), s % 60)
end

-- Extract canonical "HH:MM-HH:MM" windows from a pricing page. Mirrors v4
-- windowsFromPage. The scan is bounded to a window around the marker so large
-- pages stay inside the script CPU budget.
function M.windowsFromPage(text)
  if type(text) ~= "string" then
    return nil
  end
  local at = string.find(text, "Peak hours are", 1, true)
  if at then
    local fragment = string.sub(text, at, at + 200)
    local found = {}
    for a, b in string.gmatch(fragment, "(%d%d:%d%d)%s*%-%s*(%d%d:%d%d)") do
      table.insert(found, a .. "-" .. b)
    end
    if #found > 0 then
      table.sort(found)
      return found
    end
  end
  local o = string.find(text, "outside", 1, true) or string.find(text, "Outside", 1, true)
  if o then
    local fragment = string.sub(text, math.max(1, o - 10), o + 120)
    local a, b = string.match(fragment, "(%d%d:%d%d)%s+and%s+(%d%d:%d%d)%s+UTC")
    if a and b then
      return { a .. "-" .. b }
    end
  end
  return nil
end

-- Order-independent window-set comparison. Both sides are canonical
-- "HH:MM-HH:MM" strings.
function M.sameWindows(left, right)
  local function key(list)
    local copy = {}
    for _, item in ipairs(list or {}) do
      table.insert(copy, item)
    end
    table.sort(copy)
    return table.concat(copy, ",")
  end
  return key(left) == key(right)
end

local function pad2(n)
  return string.format("%02d", n)
end

-- Canonical windows in a display zone: "utc" | "beijing" | "local". Mirrors
-- v4 fmtHM/windowLine. Returns nil on weekend days.
function M.windowLine(now, provider, tz)
  local p = profile(provider)
  local utcDay = math.floor(now / DAY)
  local bjDay = math.floor((now + BEIJING_OFFSET) / DAY)
  local off
  if p.weekendMode == "utc" then
    local wd = weekday(utcDay)
    off = wd == 1 or wd == 7
  else
    local wd = weekday(bjDay)
    off = wd == 1 or wd == 7
  end
  if off then
    return nil
  end
  local function hm(minutes)
    local h = math.floor(minutes / 60) % 24
    local m = minutes % 60
    if tz == "utc" then
      return pad2(h) .. ":" .. pad2(m)
    end
    if tz == "beijing" then
      return pad2((h + 8) % 24) .. ":" .. pad2(m)
    end
    local localTs = now - (now % DAY) + h * 3600 + m * 60
    local lt = os.date("*t", localTs)
    return pad2(lt.hour) .. ":" .. pad2(lt.min)
  end
  local parts = {}
  for _, w in ipairs(p.peakWindowsUtc) do
    table.insert(parts, hm(toMinutes(w[1])) .. "-" .. hm(toMinutes(w[2])))
  end
  return table.concat(parts, " · ")
end

-- Semantic relative "last checked" info. Keys live under "checked" in i18n.
function M.checkedInfo(nowMs, checkedMs)
  if checkedMs == nil or checkedMs <= 0 then
    return { key = "", n = 0, text = "" }
  end
  local diff = math.max(0, math.floor((nowMs - checkedMs) / 1000))
  if diff < 60 then
    return { key = "checked.just-now", n = 0, text = "" }
  end
  if diff < 3600 then
    return { key = "checked.minutes-ago", n = math.floor(diff / 60), text = "" }
  end
  if diff < 86400 then
    return { key = "checked.hours-ago", n = math.floor(diff / 3600), text = "" }
  end
  return { key = "checked.date", n = 0, text = os.date("%m-%d %H:%M", math.floor(checkedMs / 1000)) }
end

local function dateKeyToDay(key)
  local y, mo, d = string.match(key, "^(%d%d%d%d)-(%d%d)-(%d%d)$")
  if not y then
    return nil
  end
  return math.floor(os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d),
                              hour = 0, min = 0, sec = 0, isdst = false }) / DAY)
end

-- Current or next bundled holiday range when active or starting within a
-- week. nil for providers without holidayOffPeak.
function M.holidayRangeInfo(now, provider)
  local p = profile(provider)
  if not p.holidayOffPeak then
    return nil
  end
  local byYear = load().holidays or {}
  local all = {}
  for _, days in pairs(byYear) do
    for _, d in ipairs(days) do
      local day = dateKeyToDay(d)
      if day then
        table.insert(all, day)
      end
    end
  end
  if #all == 0 then
    return nil
  end
  table.sort(all)
  local bjDay = math.floor((now + BEIJING_OFFSET) / DAY)
  local idx = 1
  while idx <= #all and all[idx] < bjDay do
    idx = idx + 1
  end
  if idx > #all then
    return nil
  end
  local startIdx, endIdx = idx, idx
  if all[idx] == bjDay then
    while startIdx - 1 >= 1 and all[startIdx - 1] == all[startIdx] - 1 do
      startIdx = startIdx - 1
    end
    while endIdx + 1 <= #all and all[endIdx + 1] == all[endIdx] + 1 do
      endIdx = endIdx + 1
    end
    return { active = true,
             startMs = (all[startIdx] * DAY) - BEIJING_OFFSET,
             endMs = ((all[endIdx] + 1) * DAY) - BEIJING_OFFSET - 1,
             inDays = 0 }
  end
  while endIdx + 1 <= #all and all[endIdx + 1] == all[endIdx] + 1 do
    endIdx = endIdx + 1
  end
  local inDays = all[startIdx] - bjDay
  if inDays > 7 then
    return nil
  end
  return { active = false,
           startMs = (all[startIdx] * DAY) - BEIJING_OFFSET,
           endMs = ((all[endIdx] + 1) * DAY) - BEIJING_OFFSET - 1,
           inDays = inDays }
end

-- One candidate pass returning everything the UI needs, to keep per-tick
-- callbacks cheap: tier, seconds to the next flip, block bounds, progress.
function M.snapshot(now, provider)
  local tier = M.isPeakAt(now, provider)
  local cands = candidates(now, provider)
  local startMs = now - 10 * DAY
  for i = #cands, 1, -1 do
    local c = cands[i]
    if c <= now and M.isPeakAt(c - 1, provider) ~= tier and M.isPeakAt(c, provider) == tier then
      startMs = c
      break
    end
  end
  local forward = 0
  for _, c in ipairs(cands) do
    if c > now and M.isPeakAt(c, provider) ~= tier then
      forward = c - now
      break
    end
  end
  local endMs = forward > 0 and (now + forward) or (now + 10 * DAY)
  local total = endMs - startMs
  local ratio = 0
  if total > 0 then
    ratio = math.min(1, math.max(0, (now - startMs) / total))
  end
  return {
    isPeak = tier,
    secondsToNext = forward,
    progress = ratio,
    block = { provider = provider, isPeak = tier, startMs = startMs, endMs = endMs },
  }
end

-- Bounds of the current block plus elapsed fraction. The block start is the
-- latest candidate where the tier changed; the end comes from the next one.
function M.progress(now, provider)
  local snap = M.snapshot(now, provider)
  return snap.progress, snap.block
end

-- The countdown label semantics: while peak, count down to off-peak and
-- vice versa. Mirrors v4 (isPeak ? offPeakIn : peakIn).
function M.countdownLabelKey(isPeak)
  if isPeak then
    return "panel.off-peak-in"
  end
  return "panel.peak-in"
end

return M
