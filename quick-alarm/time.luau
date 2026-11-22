--!nonstrict
-- Quick Alarm - Time parser & formatter (1:1 port of Cinnamon quick-alarm@andreas-glaser)

local Time = {}

local function trim(s)
  if type(s) ~= "string" then return "" end
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function splitWords(s)
  local out = {}
  for w in s:gmatch("%S+") do
    table.insert(out, w)
  end
  return out
end

function Time.formatTime(timestamp, showSeconds)
  if showSeconds then
    return tostring(os.date("%H:%M:%S", timestamp))
  end
  return tostring(os.date("%H:%M", timestamp))
end

function Time.formatCountdown(targetTimestamp, nowTimestamp)
  local diffSec = math.ceil(targetTimestamp - nowTimestamp)
  if diffSec <= 0 then return "" end

  local h = math.floor(diffSec / 3600)
  local m = math.floor((diffSec % 3600) / 60)
  local s = diffSec % 60

  if h > 0 then
    return m > 0 and string.format("%dh %dm", h, m) or string.format("%dh", h)
  end
  if m >= 2 then
    return string.format("%dm", m)
  end
  if m == 1 then
    return s > 0 and string.format("1m %ds", s) or "1m"
  end
  return string.format("%ds", s)
end

function Time.formatTimeAgo(dueTimestamp, nowTimestamp)
  local diffSec = math.max(0, math.floor(nowTimestamp - dueTimestamp))
  local diffMin = math.floor(diffSec / 60)
  local diffHr = math.floor(diffMin / 60)

  if diffSec < 5 then return "just now" end
  if diffSec < 60 then return string.format("%d seconds ago", diffSec) end
  if diffMin == 1 then return "1 minute ago" end
  if diffMin < 60 then return string.format("%d minutes ago", diffMin) end
  if diffHr == 1 then return "1 hour ago" end
  return string.format("%d hours ago", diffHr)
end

local function splitLabel(raw)
  local s = trim(raw)
  local seps = { " %- ", " – ", " — " }
  for _, sep in ipairs(seps) do
    local a, b = s:match("^(.-)" .. sep .. "(.+)$")
    if a and b then
      return { spec = trim(a), label = trim(b) }
    end
  end
  return { spec = s, label = "" }
end

local function stripLeadingWord(s, words)
  local lower = s:lower()
  for _, w in ipairs(words) do
    local pos = lower:match("^" .. w .. "%s+()")
    if pos then
      return trim(s:sub(pos))
    end
  end
  return s
end

local function lightNormalizeSpec(raw)
  local s = raw:gsub("^[%s,;:.!?]+", "")
  s = trim(s)
  s = stripLeadingWord(s, { "set", "add", "new", "adicionar", "criar", "novo" })
  s = stripLeadingWord(s, { "at", "for", "as", "às", "para" })
  return trim(s)
end

local function normalizeSpec(raw)
  local s = lightNormalizeSpec(raw)
  s = stripLeadingWord(s, { "an", "a", "um", "uma" })
  s = stripLeadingWord(s, { "alarm", "reminder", "timer", "alarme", "lembrete" })
  s = stripLeadingWord(s, { "at", "for", "as", "às", "para" })
  return trim(s)
end

local function parseAbsoluteTime(part)
  local s = trim(part):lower()
  if s == "" then return nil end

  local hStr, mStr, ampm

  -- 1. "11:30am", "11:30 pm", "11.30pm"
  hStr, mStr, ampm = s:match("^(%d%d?)[:%.](%d%d)%s*([ap]m)$")
  -- 2. "11:30", "11.30"
  if not hStr then
    hStr, mStr = s:match("^(%d%d?)[:%.](%d%d)$")
  end
  -- 3. "11am", "11 pm"
  if not hStr then
    hStr, ampm = s:match("^(%d%d?)%s*([ap]m)$")
    if hStr then mStr = "00" end
  end
  -- 4. "11" (bare hour)
  if not hStr then
    hStr = s:match("^(%d%d?)$")
    if hStr then mStr = "00" end
  end

  if not hStr then return nil end

  local hour = tonumber(hStr)
  local minute = tonumber(mStr)
  if not hour or not minute then return nil end
  if minute < 0 or minute > 59 then return nil end

  if ampm then
    if hour < 1 or hour > 12 then return nil end
    if ampm == "am" then
      hour = hour % 12
    elseif ampm == "pm" then
      hour = (hour % 12) + 12
    end
  else
    if hour < 0 or hour > 23 then return nil end
  end

  return { hour = hour, minute = minute }
end

local UNITS = {
  { "hours", "h" }, { "hour", "h" }, { "hrs", "h" }, { "hr", "h" }, { "horas", "h" }, { "hora", "h" }, { "h", "h" },
  { "minutes", "m" }, { "minute", "m" }, { "mins", "m" }, { "min", "m" }, { "minutos", "m" }, { "minuto", "m" }, { "m", "m" },
  { "seconds", "s" }, { "second", "s" }, { "secs", "s" }, { "sec", "s" }, { "segundos", "s" }, { "segundo", "s" }, { "s", "s" },
}

local function matchLeadingDurationToken(s)
  local lower = s:lower()
  local numStr, afterNum = lower:match("^(%d+)%s*()")
  if not numStr then return nil end
  local restAfterNum = lower:sub(afterNum)

  for _, u in ipairs(UNITS) do
    local word = u[1]
    local kind = u[2]
    local afterUnit = restAfterNum:match("^" .. word .. "()")
    if afterUnit then
      local nextChar = restAfterNum:sub(afterUnit, afterUnit)
      if nextChar == "" or nextChar:match("%s") then
        local afterSpaces = restAfterNum:match("^" .. word .. "%s*()")
        local consumed = (afterNum - 1) + (afterSpaces - 1)
        return tonumber(numStr), kind, consumed
      end
    end
  end
  return nil
end

local function parseRelative(spec)
  local orig = trim(spec)
  local restOrig = stripLeadingWord(orig, { "in", "after", "em", "daqui a", "daqui" })

  local totalSecs = 0
  local matchedAny = false

  while #restOrig > 0 do
    local val, kind, consumed = matchLeadingDurationToken(restOrig)
    if not val or not kind or not consumed then
      break
    end
    if val < 0 then return nil end
    matchedAny = true
    if kind == "h" then
      totalSecs = totalSecs + val * 3600
    elseif kind == "m" then
      totalSecs = totalSecs + val * 60
    else
      totalSecs = totalSecs + val
    end
    restOrig = restOrig:sub(consumed + 1)
  end

  if not matchedAny or totalSecs <= 0 then
    return nil
  end

  return {
    delaySecs = totalSecs,
    label = trim(restOrig),
    showSeconds = true,
  }
end

local function tryRelativeWithLabelFirst(s)
  local r = parseRelative(s)
  if r then return r end

  local words = splitWords(s)
  for i = 2, #words do
    local candidate = table.concat(words, " ", i, #words)
    local tryRel = parseRelative(candidate)
    if tryRel then
      local prefix = table.concat(words, " ", 1, i - 1)
      local combined = prefix
      if tryRel.label ~= "" then
        combined = combined .. " " .. tryRel.label
      end
      return {
        delaySecs = tryRel.delaySecs,
        label = trim(combined),
        showSeconds = tryRel.showSeconds,
      }
    end
  end
  return nil
end

local function looksTimeToken(tok)
  if tok:match("^%d%d?[:%.]%d%d$") then return true end
  if tok:match("^%d%d?$") then return true end
  return false
end

local function looksAmPm(tok)
  local l = tok:lower()
  return l == "am" or l == "pm"
end

local function errorWithExamples(prefix)
  return table.concat({
    prefix,
    "Try: in 10m coffee • 11:45 - lunch • 5s • 11am daily",
  }, "\n")
end

function Time.parseAlarmSpec(input, nowTimestamp)
  local now = nowTimestamp or os.time()
  local raw = trim(tostring(input or ""))
  if raw == "" then
    return { ok = false, error = errorWithExamples("Enter a time or countdown.") }
  end

  local split = splitLabel(raw)
  local spec = normalizeSpec(split.spec)
  if spec == "" then
    return { ok = false, error = errorWithExamples("Enter a time or countdown.") }
  end

  -- Day hints: "today 11am", "tomorrow 11:30"
  local dayHint = nil
  local dayWord, dayRest = spec:match("^(%S+)%s+(.+)$")
  if dayWord then
    local dw = dayWord:lower()
    if dw == "today" or dw == "hoje" then
      dayHint = "today"
      spec = normalizeSpec(dayRest)
    elseif dw == "tomorrow" or dw == "tmr" or dw == "amanha" or dw == "amanhã" then
      dayHint = "tomorrow"
      spec = normalizeSpec(dayRest)
    end
  end

  local lightSpec = dayHint and spec or lightNormalizeSpec(split.spec)
  local rel = tryRelativeWithLabelFirst(lightSpec)
  if not rel and lightSpec ~= spec then
    rel = tryRelativeWithLabelFirst(spec)
  end
  if rel then
    local finalLabel = split.label ~= "" and split.label or rel.label
    return {
      ok = true,
      target = now + rel.delaySecs,
      label = trim(finalLabel),
      showSeconds = rel.showSeconds,
    }
  end

  local rawParts = splitWords(spec)
  local parts = {}
  local i = 1
  while i <= #rawParts do
    local tok = rawParts[i]
    local lowerTok = tok:lower()
    if lowerTok == "at" or lowerTok == "as" or lowerTok == "às" then
      i = i + 1
    elseif looksTimeToken(tok) and (i + 1 <= #rawParts) and looksAmPm(rawParts[i + 1]) then
      table.insert(parts, tok .. rawParts[i + 1])
      i = i + 2
    else
      table.insert(parts, tok)
      i = i + 1
    end
  end

  if #parts == 0 then
    return { ok = false, error = errorWithExamples("Could not parse time.") }
  end

  local timePart = parts[1]
  local tailRest = #parts >= 2 and table.concat(parts, " ", 2, #parts) or ""
  local label = split.label ~= "" and split.label or trim(tailRest)
  local abs = parseAbsoluteTime(timePart)

  if not abs and #parts >= 2 then
    local tail = parts[#parts]
    local tailAbs = parseAbsoluteTime(tail)
    if tailAbs then
      abs = tailAbs
      local headRest = table.concat(parts, " ", 1, #parts - 1)
      label = split.label ~= "" and split.label or trim(headRest)
    end
  end

  if not abs then
    return { ok = false, error = errorWithExamples("Could not parse time.") }
  end

  -- Note: In Luau, os.date("*t", now) uses localtime_r (local timezone),
  -- but os.time(table) uses os_timegm (UTC!). Therefore we compute the local
  -- timestamp directly relative to today's local midnight:
  local dt = os.date("*t", now)
  local secondsSinceLocalMidnight = (dt.hour * 3600) + (dt.min * 60) + dt.sec
  local startOfLocalToday = now - secondsSinceLocalMidnight
  local targetTime = startOfLocalToday + (abs.hour * 3600) + (abs.minute * 60)

  if dayHint == "tomorrow" then
    targetTime = targetTime + 86400
  elseif dayHint == "today" then
    if targetTime <= now then
      return { ok = false, error = errorWithExamples("That time has already passed today.") }
    end
  else
    if targetTime <= now then
      targetTime = targetTime + 86400
    end
  end

  return {
    ok = true,
    target = targetTime,
    label = trim(label),
    showSeconds = false,
  }
end

return Time
