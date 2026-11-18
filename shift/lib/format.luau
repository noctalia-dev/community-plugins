--!nonstrict
-- Display formatting of durations and clock times (spec §7.2). Durations are shown in
-- whole minutes, truncated toward zero, so a counter never shows time not yet worked.

local Types = require("./types.luau")

local Format = {}

local STYLES = { colon = true, units = true, decimal = true }

-- `style` is the `duration_format` setting: "colon" (7:30), "units" (7h 30m) or
-- "decimal" (7.50 h). Unknown styles fall back to "colon".
function Format.duration(ms: number, style: string?): string
  style = STYLES[style] and style or "colon"
  local minutes = math.abs(ms) // 60000
  local sign = (ms < 0 and minutes > 0) and "-" or ""
  local hours, rest = minutes // 60, minutes % 60
  if style == "units" then
    if hours == 0 then
      return string.format("%s%dm", sign, rest)
    elseif rest == 0 then
      return string.format("%s%dh", sign, hours)
    end
    return string.format("%s%dh %02dm", sign, hours, rest)
  elseif style == "decimal" then
    return string.format("%s%.2f h", sign, minutes / 60)
  end
  return string.format("%s%d:%02d", sign, hours, rest)
end

-- Splits a formatted duration into its numbers and the unit after each, so a large
-- counter can draw units smaller: "7h 30m" -> { "7", "h" }, { "30", "m" }; "7:30" ->
-- { "7:30", "" }; "7.50 h" -> { "7.50", "h" }.
function Format.parts(text: string): { { number: string, unit: string } }
  local parts = {}
  for number, unit in string.gmatch(text, "([^%a%s]+)%s*(%a*)") do
    table.insert(parts, { number = number, unit = unit })
  end
  return parts
end

-- Short form for narrow places such as a vertical bar: "5h", or "42m" under an hour.
function Format.compact(ms: number): string
  local minutes = math.max(0, ms) // 60000
  if minutes < 60 then
    return string.format("%dm", minutes)
  end
  return string.format("%dh", minutes // 60)
end

-- Signed duration for deltas: "+0:23", "-1:18", "0:00".
function Format.signed(ms: number, style: string?): string
  local text = Format.duration(ms, style)
  if ms >= 60000 then
    return "+" .. text
  end
  return text
end

-- Compact list of workdays: runs of three days or more collapse into ranges
-- ("Mon–Fri", "Mon, Wed, Fri", "Mon–Thu, Sat"). `names` holds the 7 short day names,
-- Monday first.
function Format.workdays(workdays: { boolean }, names: { string }): string
  local parts = {}
  local day = 1
  while day <= 7 do
    if workdays[day] then
      local last = day
      while last < 7 and workdays[last + 1] do
        last += 1
      end
      if last - day >= 2 then
        table.insert(parts, names[day] .. "–" .. names[last])
      else
        for d = day, last do
          table.insert(parts, names[d])
        end
      end
      day = last + 1
    else
      day += 1
    end
  end
  return table.concat(parts, ", ")
end

-- "42 min" under an hour, else a duration in the user's format: how long an absence
-- lasted.
function Format.short(host: Types.Host, ms: number, style: string?): string
  local minutes = ms // 60000
  if minutes < 60 then
    return host.trp("format.minutes", minutes)
  end
  return Format.duration(ms, style)
end

-- Clock time in the user's 12/24 h preference (`[shell].time_format`).
function Format.clock(host: Types.Host, epochS: number): string
  return host.formatTime(host.timeFormat(), epochS)
end

return Format
