--!nonstrict
-- The model: what NaN's API returns in, what the bar widget and the panel paint out.
--
-- Pure by construction. It calls nothing on `noctalia.*` and reads no clock of its
-- own: every derivation that depends on time takes it as an argument, in whole
-- seconds since the epoch. That is what lets `tests/shared_test.lua` run this file
-- under a fixed clock with plain Lua, and it is also why a countdown can be
-- recomputed from data already held without touching the network.
--
-- The NaN API has no published contract — the shapes below were read off the
-- panel bundle, and can change without notice — so every reader here is tolerant:
-- numbers may arrive as strings, timestamps as ISO strings, dates or epoch
-- numbers, and anything unreadable degrades to a zero value rather than throwing
-- away the whole response.

local M = {}

-- ── Levels ──────────────────────────────────────────────────────────────────

local RANK = { ok = 0, warn = 1, crit = 2 }

-- Share of the period that has to have elapsed before a burn rate means
-- anything: in the first hours of a period the average is noise.
local MIN_ELAPSED_FRAC = 0.05

-- Share of the period that has to be spent without quota for that to count as
-- critical. Running out just before the reset only warrants a warning.
local LOCKOUT_CRIT_FRAC = 0.10

function M.rank(level)
  return RANK[level] or 0
end

-- The more alarming of two levels.
function M.maxLevel(a, b)
  if (RANK[a] or 0) >= (RANK[b] or 0) then
    return a
  end
  return b
end

-- How full a window is right now.
function M.utilLevel(util)
  if util >= 90 then
    return "crit"
  end
  if util >= 75 then
    return "warn"
  end
  return "ok"
end

-- ── Reading values the API is careless about ────────────────────────────────

-- A number that may arrive as a string ("8000000"), or as junk, which becomes 0.
local function num(value)
  if type(value) == "number" then
    return value
  end
  if type(value) == "string" then
    return tonumber(value) or 0
  end
  return 0
end

-- A string that may arrive as a number, trimmed; "" when absent.
local function str(value)
  if type(value) == "string" then
    return value
  end
  if type(value) == "number" then
    return tostring(value)
  end
  return ""
end

-- Local-minus-UTC in seconds at a given instant. Recomputed per instant so a
-- value that straddles a DST change is out by at most the one hour it crosses.
--
-- isdst must be cleared: os.date("!*t") sets it to false, and os.time honours it,
-- which would read a UTC breakdown back as standard time all summer.
local function utcOffset(at)
  local fields = os.date("!*t", at)
  fields.isdst = nil
  return os.time(fields) - at
end

-- A timestamp: ISO ("2026-10-01T00:00:00Z"), with an explicit offset, a bare date
-- ("2026-09-01"), epoch seconds, or a number-as-string. nil when unreadable.
local function unix(value)
  if type(value) == "number" then
    return value
  end
  local raw = str(value)
  if raw == "" then
    return nil
  end
  local plain = tonumber(raw)
  if plain then
    return plain
  end
  local year, month, day, hour, min, sec = raw:match("^(%d%d%d%d)-(%d%d)-(%d%d)[Tt ]?(%d*):?(%d*):?(%d*)")
  if not year then
    return nil
  end
  local fields = os.time({
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = tonumber(hour) or 0,
    min = tonumber(min) or 0,
    sec = tonumber(sec) or 0,
  })
  if not fields then
    return nil
  end
  -- os.time read those fields as local wall time; they are UTC unless the string
  -- says otherwise.
  if hour == "" then
    -- A bare date: a calendar day, so read it as local midnight rather than
    -- shifting it into the previous day for anyone west of UTC.
    return fields
  end
  local at = fields - utcOffset(fields)
  local sign, offh, offm = raw:match("([%+%-])(%d%d):(%d%d)%s*$")
  if sign then
    local shift = (tonumber(offh) * 60 + tonumber(offm)) * 60
    at = at - (sign == "+" and shift or -shift)
  end
  return at
end

-- ── Formatting ──────────────────────────────────────────────────────────────

-- 3.00 → 3, 1.50 → 1.5
local function trimZeros(text)
  if not text:find(".", 1, true) then
    return text
  end
  text = text:gsub("0+$", "")
  return (text:gsub("%.$", ""))
end

-- A token count in compact form: 3B, 1.5B, 79.9M, 398K, 42.
function M.fmtTokens(n)
  local v = math.max(0, num(n))
  if v >= 1e9 then
    return trimZeros(string.format("%.2f", v / 1e9)) .. "B"
  elseif v >= 1e6 then
    return trimZeros(string.format("%.1f", v / 1e6)) .. "M"
  elseif v >= 1e3 then
    return string.format("%.0f", math.floor(v / 1e3 + 0.5)) .. "K"
  end
  return string.format("%.0f", math.floor(v + 0.5))
end

-- A percentage: whole numbers for the bar, and one decimal below 10% when fine is
-- set, where a plain "0%" says nothing for weeks.
function M.fmtPct(util, fine)
  local v = math.max(0, num(util))
  if fine and v < 10 then
    return string.format("%.1f%%", v)
  end
  return string.format("%.0f%%", math.floor(v + 0.5))
end

-- A model id abbreviated for the bar: deepseek-v4-flash → ds4f, glm5.3-flash → glm5.3f.
function M.shortModel(id)
  local out = str(id):gsub("deepseek%-v4%-flash", "ds4f")
  return (out:gsub("%-flash", "f"))
end

-- A duration with at most two units. compact is the bar form (20d, 4h21m, 45m);
-- the long form is 20d 4h, 4h 21m, 45 min.
function M.humanDuration(seconds, compact)
  local secs = math.floor(math.max(0, num(seconds)))
  if secs < 60 then
    return compact and (secs .. "s") or (secs .. " s")
  end
  local mins = math.floor(secs / 60 + 0.5)
  if mins < 60 then
    return compact and (mins .. "m") or (mins .. " min")
  end
  local hrs = math.floor(mins / 60)
  if hrs < 24 then
    if compact then
      return hrs .. "h" .. (mins % 60) .. "m"
    end
    return hrs .. "h " .. (mins % 60) .. "m"
  end
  local days = math.floor(hrs / 24)
  if compact then
    return days .. "d"
  end
  return days .. "d " .. (hrs % 24) .. "h"
end

-- Time of day, in the shell's own timezone.
function M.clockTime(at)
  if not at then
    return ""
  end
  return os.date("%H:%M", at)
end

-- Day and month, the Go layout "2 Jan" with its unpadded day.
function M.shortDate(at)
  if not at then
    return ""
  end
  local day = os.date("%d", at):gsub("^0", "")
  return day .. " " .. os.date("%b", at)
end

-- ── Windows ─────────────────────────────────────────────────────────────────

-- One model in one period, normalised.
--
-- cap is always > 0: entries without a usable cap are dropped. utilization is
-- deliberately not clamped to 100 — if NaN lets usage overshoot, that should be
-- visible.
function M.windows(raw)
  local models = raw and raw.models
  if type(models) ~= "table" then
    return {}
  end
  local startsAt = unix(raw.periodStart)
  local out = {}
  for _, entry in ipairs(models) do
    if type(entry) == "table" then
      local model = str(entry.model)
      local cap = num(entry.cap)
      if model ~= "" and cap > 0 then
        local used = math.max(0, num(entry.tokensUsed))
        local remaining = cap - used
        if entry.remaining ~= nil then
          remaining = num(entry.remaining)
        end
        out[#out + 1] = {
          key = model,
          model = model,
          label = model,
          used = used,
          cap = cap,
          remaining = remaining,
          utilization = used / cap * 100,
          startsAt = startsAt,
          resetsAt = unix(entry.periodEnd),
          windowHours = num(entry.windowHours),
          windowCap = num(entry.fullWindowTokens),
          updatedAt = unix(entry.updatedAt),
        }
      end
    end
  end
  -- Busiest first, then by name, so the list is stable between refreshes.
  table.sort(out, function(a, b)
    if a.utilization ~= b.utilization then
      return a.utilization > b.utilization
    end
    return a.model < b.model
  end)
  return out
end

-- The timing of a period, and only when there is something to extrapolate from:
-- both ends known, period not over, and not freshly started.
local function span(w, now)
  if not w.startsAt or not w.resetsAt then
    return nil
  end
  if w.resetsAt <= w.startsAt then
    return nil
  end
  local total = w.resetsAt - w.startsAt
  local elapsed = now - w.startsAt
  local remaining = w.resetsAt - now
  if remaining <= 0 or elapsed <= 0 or elapsed < total * MIN_ELAPSED_FRAC then
    return nil
  end
  return { total = total, elapsed = elapsed, remaining = remaining }
end

-- The usage the period would end at if the average rate held until the reset.
-- Never below the usage already seen.
function M.projectedUtil(w, now)
  local s = span(w, now)
  if not s then
    return w.utilization
  end
  return math.max(w.utilization, w.utilization * s.total / s.elapsed)
end

-- How long until the quota runs out at the average rate, and only when that
-- happens before the reset.
function M.exhaustAfter(w, now)
  local s = span(w, now)
  if not s or w.utilization <= 0 then
    return nil
  end
  if w.utilization >= 100 then
    return 0
  end
  local toExhaust = s.elapsed * (100 - w.utilization) / w.utilization
  if toExhaust < s.remaining then
    return toExhaust
  end
  return nil
end

-- How long the account would sit without quota before the reset at the current
-- rate, when the rate does exhaust it.
function M.lockout(w, now)
  local after = M.exhaustAfter(w, now)
  if not after then
    return nil
  end
  return math.max(0, (w.resetsAt - now) - after)
end

-- Level by the consequence of the burn rate, not by the percentage alone.
function M.windowLevel(w, now)
  local level = M.utilLevel(w.utilization)
  local s = span(w, now)
  local lock = M.lockout(w, now)
  if lock and s then
    if lock >= s.total * LOCKOUT_CRIT_FRAC then
      return M.maxLevel(level, "crit")
    end
    return M.maxLevel(level, "warn")
  end
  if M.projectedUtil(w, now) >= 75 then
    return M.maxLevel(level, "warn")
  end
  return level
end

-- The footer line of a window, tied to the same thresholds as windowLevel.
-- Empty when there is nothing worth saying.
function M.projectionNote(w, now)
  local s = span(w, now)
  if not s then
    return ""
  end
  local lock = M.lockout(w, now)
  if lock then
    if lock >= s.total * LOCKOUT_CRIT_FRAC then
      return "at this rate it runs out in ~" .. M.humanDuration(M.exhaustAfter(w, now), false)
    end
    return "at this rate it runs out just before the reset"
  end
  local projected = M.projectedUtil(w, now)
  if projected >= 75 and math.floor(projected + 0.5) > math.floor(w.utilization + 0.5) then
    return "on track for ~" .. M.fmtPct(projected, false) .. " at reset"
  end
  return ""
end

-- The detail line under a window's bar: tokens used against the cap, time to
-- reset, the rolling window when there is one, and the projection note.
function M.caption(w, now)
  local parts = { M.fmtTokens(w.used) .. " / " .. M.fmtTokens(w.cap) }
  if w.resetsAt then
    parts[#parts + 1] = "resets in " .. M.humanDuration(w.resetsAt - now, false)
  end
  if w.windowHours > 0 then
    parts[#parts + 1] = "window " .. M.fmtTokens(w.windowHours) .. " h: " .. M.fmtTokens(w.windowCap)
  end
  local note = M.projectionNote(w, now)
  if note ~= "" then
    parts[#parts + 1] = note
  end
  return table.concat(parts, " · ")
end

-- The period shared by the listed windows.
function M.periodLine(ref, now)
  if not ref or not ref.startsAt or not ref.resetsAt then
    return ""
  end
  return "Period from " .. M.shortDate(ref.startsAt) .. " · resets in " .. M.humanDuration(ref.resetsAt - now, false)
end

-- What a list shows: with hideUnused, windows with no usage are dropped, except
-- the pinned one, which stays so it can be inspected.
function M.visibleWindows(windows, hideUnused, pinned)
  if not hideUnused then
    return windows
  end
  local out = {}
  for _, w in ipairs(windows) do
    if w.used > 0 or (pinned ~= "" and w.model == pinned) then
      out[#out + 1] = w
    end
  end
  return out
end

-- Which window the bar indicator reflects. mode: "worst", "max" or "fixed".
function M.selectPanelWindow(windows, mode, modelID, now)
  if #windows == 0 then
    return nil
  end
  if mode == "fixed" then
    for _, w in ipairs(windows) do
      if w.model == modelID then
        return w
      end
    end
  end
  -- Only consider windows actually in use; if none are, fall back to all of
  -- them so the bar still says something.
  local candidates = {}
  for _, w in ipairs(windows) do
    if w.used > 0 then
      candidates[#candidates + 1] = w
    end
  end
  if #candidates == 0 then
    candidates = windows
  end
  local best = candidates[1]
  for _, w in ipairs(candidates) do
    if M.better(w, best, mode, now) then
      best = w
    end
  end
  return best
end

-- Worst ranks by alarm level and then by usage; max goes by usage alone.
function M.better(a, b, mode, now)
  if mode == "max" then
    return a.utilization > b.utilization
  end
  return M.rank(M.windowLevel(a, now)) * 1000 + a.utilization
    > M.rank(M.windowLevel(b, now)) * 1000 + b.utilization
end

-- ── Account and aggregates ──────────────────────────────────────────────────

-- The "handle · region" line under the title.
function M.accountSummary(me)
  local name = str(me and me.handle)
  if name == "" then
    name = str(me and me.username)
  end
  local parts = {}
  if name ~= "" then
    parts[#parts + 1] = name
  end
  if me and str(me.region) ~= "" then
    parts[#parts + 1] = str(me.region)
  end
  return table.concat(parts, " · ")
end

local function bucket(raw, key)
  local value = raw and raw[key]
  if type(value) == "table" then
    return num(value.totalTokens)
  end
  if value ~= nil then
    return num(value)
  end
  return nil
end

-- "24 h: 5M · month: 40M · 30 d: 44M"
function M.metricsSummary(metrics)
  local parts = {}
  local labels = { { "last24h", "24 h" }, { "monthToDate", "month" }, { "last30d", "30 d" } }
  for _, entry in ipairs(labels) do
    local tokens = bucket(metrics, entry[1])
    if tokens then
      parts[#parts + 1] = entry[2] .. ": " .. M.fmtTokens(tokens)
    end
  end
  return table.concat(parts, " · ")
end

-- The same aggregates as data, so a UI can draw bars instead of printing a line.
function M.usageBuckets(metrics)
  local out = {}
  local labels = { { "last24h", "24 h" }, { "monthToDate", "month" }, { "last30d", "30 d" } }
  for _, entry in ipairs(labels) do
    local tokens = bucket(metrics, entry[1])
    if tokens then
      out[#out + 1] = { label = entry[2], text = M.fmtTokens(tokens), tokens = tokens }
    end
  end
  if #out == 0 then
    return nil
  end
  return out
end

-- ── The document the surfaces paint ─────────────────────────────────────────

-- Which pieces the indicator is made of, composed the way the tool composes it.
function M.barText(panel, cfg)
  if not panel then
    return "—"
  end
  local parts = {}
  if cfg.showPercentage then
    parts[#parts + 1] = panel.percentText
  end
  if cfg.showReset and panel.resetsIn ~= "" then
    parts[#parts + 1] = panel.resetsIn
  end
  if cfg.showModel and panel.short ~= "" then
    parts[#parts + 1] = panel.short
  end
  if #parts == 0 then
    -- Everything is off: the model is the only useful leftover.
    return panel.short
  end
  -- No spaces around the separator: in a bar, a full space either side of a middot
  -- reads as three separate things rather than one figure. (A thin space would be
  -- the typographic answer, but the theme's bar font may not have U+2009, and a
  -- missing glyph is worse than a tight separator.)
  return table.concat(parts, "·")
end

local function toWindow(w, now)
  local resetsIn = ""
  if w.resetsAt then
    resetsIn = M.humanDuration(w.resetsAt - now, true)
  end
  return {
    key = w.key,
    model = w.model,
    short = M.shortModel(w.model),
    used = w.used,
    cap = w.cap,
    remaining = w.remaining,
    percent = w.utilization,
    percentText = M.fmtPct(w.utilization, true),
    usedText = M.fmtTokens(w.used),
    capText = M.fmtTokens(w.cap),
    level = M.windowLevel(w, now),
    resetsIn = resetsIn,
    caption = M.caption(w, now),
    note = M.projectionNote(w, now),
  }
end

local function toPanel(w, now, cfg)
  if not w then
    return nil
  end
  local panel = {
    model = w.model,
    short = M.shortModel(w.model),
    percent = w.utilization,
    percentText = M.fmtPct(w.utilization, false),
    level = M.windowLevel(w, now),
    resetsIn = "",
  }
  if w.resetsAt then
    panel.resetsIn = M.humanDuration(w.resetsAt - now, true)
  end
  panel.text = M.barText(panel, cfg)
  return panel
end

-- Assembles the record the widget and the panel paint.
--
-- `state` is what the service holds: the last responses it read, when, and any
-- error. `now` is the clock, so every countdown is recomputed from the same data
-- on each repaint rather than only on each poll.
function M.build(state, cfg, now)
  state = state or {}
  cfg = cfg or {}
  local record = {
    version = 1,
    ok = false,
    stale = false,
    error = state.error or "",
    fetchedAt = state.fetchedAt,
    ageSeconds = state.fetchedAt and math.max(0, now - state.fetchedAt) or 0,
    updated = "",
    account = { handle = "", region = "", tier = "", summary = "" },
    period = "",
    panel = nil,
    windows = {},
    totalWindows = 0,
    gauge = cfg.gauge or "bar",
    metrics = "",
    usage = nil,
    pollSeconds = cfg.pollSeconds or 300,
  }

  local me = state.me
  if type(me) == "table" then
    local name = str(me.handle ~= "" and me.handle or me.username)
    record.account = {
      handle = name,
      region = str(me.region),
      tier = str(me.tier):upper():gsub("^%s*(.-)%s*$", "%1"),
      summary = M.accountSummary(me),
    }
  end

  if cfg.showMetrics then
    record.metrics = M.metricsSummary(state.metrics)
    record.usage = M.usageBuckets(state.metrics)
  end

  local windows = M.windows(state.quota)
  record.totalWindows = #windows

  local pinned = ""
  if cfg.panelModel == "fixed" then
    pinned = cfg.panelModelId or ""
  end
  for _, w in ipairs(M.visibleWindows(windows, cfg.hideUnused, pinned)) do
    record.windows[#record.windows + 1] = toWindow(w, now)
  end
  if windows[1] then
    record.period = M.periodLine(windows[1], now)
  end
  record.panel = toPanel(M.selectPanelWindow(windows, cfg.panelModel, cfg.panelModelId, now), now, cfg)

  record.ok = #windows > 0
  record.stale = record.error ~= "" and record.ok
  if state.fetchedAt then
    record.updated = "Updated at " .. M.clockTime(state.fetchedAt)
    if record.error ~= "" then
      record.updated = record.updated .. " · with errors"
    end
  elseif record.error ~= "" then
    record.updated = "No data"
  end
  return record
end

return M
