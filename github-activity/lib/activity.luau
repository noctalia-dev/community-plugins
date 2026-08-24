--!nonstrict

local Activity = {}

local levelByName = {
  NONE = 0,
  FIRST_QUARTILE = 1,
  SECOND_QUARTILE = 2,
  THIRD_QUARTILE = 3,
  FOURTH_QUARTILE = 4,
}

local colorByLevel = {
  "surface_variant",
  "primary/0.25",
  "primary/0.45",
  "primary/0.70",
  "primary",
}

function Activity.level(value)
  if type(value) == "number" then
    return math.clamp(math.floor(value), 0, 4)
  end

  return levelByName[value] or 0
end

function Activity.color(level)
  return colorByLevel[Activity.level(level) + 1]
end

function Activity.symbol(level)
  local symbols = { "·", "░", "▒", "▓", "█" }
  return symbols[Activity.level(level) + 1]
end

function Activity.levelForSymbol(symbol)
  local levels = {
    ["·"] = 0,
    ["░"] = 1,
    ["▒"] = 2,
    ["▓"] = 3,
    ["█"] = 4,
  }

  return levels[symbol] or 0
end

function Activity.rowLevels(row)
  local levels = {}
  local byCodepoint = {
    [0x00B7] = 0,
    [0x2591] = 1,
    [0x2592] = 2,
    [0x2593] = 3,
    [0x2588] = 4,
  }
  for _, codepoint in utf8.codes(row or "") do
    table.insert(levels, byCodepoint[codepoint] or 0)
  end
  return levels
end

function Activity.heatmapSvg(rows, dark)
  local colors = dark
    and { "#252a33", "#283f68", "#355b94", "#4b7dc5", "#72a7ec" }
    or { "#e2e7ef", "#bdd4ed", "#82b4e2", "#468dcc", "#1769aa" }
  local fragments = {
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 595 142" shape-rendering="geometricPrecision">',
  }

  local levelRows = {}
  local columnCount = 0
  for day = 1, 7 do
    local levels = Activity.rowLevels((rows or {})[day])
    levelRows[day] = levels
    columnCount = math.max(columnCount, #levels)
  end

  local date = os.date("*t")
  local monthNames = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
  local firstMonth = date.month - 11
  local textColor = dark and "#c6cbd4" or "#414750"
  for offset = 0, 11 do
    local month = ((firstMonth + offset - 1) % 12) + 1
    local week = math.floor(offset * math.max(1, columnCount - 1) / 11)
    table.insert(fragments,
      '<text x="' .. tostring(45 + week * 10) .. '" y="13" fill="' .. textColor
        .. '" font-family="sans-serif" font-size="10">' .. monthNames[month] .. "</text>")
  end

  for _, label in ipairs({ { "Mon", 1 }, { "Wed", 3 }, { "Fri", 5 } }) do
    table.insert(fragments,
      '<text x="34" y="' .. tostring(34 + label[2] * 13) .. '" text-anchor="end" fill="' .. textColor
        .. '" font-family="sans-serif" font-size="10">' .. label[1] .. "</text>")
  end

  local paths = { {}, {}, {}, {}, {} }
  for day = 1, 7 do
    for week, level in ipairs(levelRows[day]) do
      table.insert(paths[level + 1], "M" .. tostring(45 + (week - 1) * 10)
        .. " " .. tostring(24 + (day - 1) * 13) .. "h8v8h-8z")
    end
  end

  for level = 1, 5 do
    table.insert(fragments, '<path fill="' .. colors[level] .. '" d="' .. table.concat(paths[level]) .. '"/>')
  end

  table.insert(fragments, "</svg>")
  return table.concat(fragments)
end

function Activity.flatten(weeks)
  local days = {}

  for _, week in ipairs(weeks or {}) do
    for _, day in ipairs(week.days or {}) do
      table.insert(days, day)
    end
  end

  return days
end

function Activity.streaks(days, todayDate)
  local best = 0
  local running = 0

  for _, day in ipairs(days or {}) do
    if (day.count or 0) > 0 then
      running = running + 1
      best = math.max(best, running)
    else
      running = 0
    end
  end

  local endIndex = nil
  for index = #days, 1, -1 do
    if days[index].date <= todayDate then
      endIndex = index
      break
    end
  end

  if endIndex == nil then
    return 0, best
  end

  -- A day that has not happened yet is irrelevant. If today is empty, retain
  -- yesterday's active streak rather than resetting it early in the morning.
  if days[endIndex].date == todayDate and (days[endIndex].count or 0) == 0 then
    endIndex = endIndex - 1
  end

  local current = 0
  for index = endIndex, 1, -1 do
    if (days[index].count or 0) == 0 then
      break
    end
    current = current + 1
  end

  return current, best
end

function Activity.countStreaks(counts, todayIndex)
  local best = 0
  local running = 0
  for _, count in ipairs(counts or {}) do
    if count > 0 then
      running = running + 1
      best = math.max(best, running)
    else
      running = 0
    end
  end

  if todayIndex == nil then
    return 0, best
  end

  local endIndex = todayIndex
  if (counts[endIndex] or 0) == 0 then
    endIndex = endIndex - 1
  end

  local current = 0
  for index = endIndex, 1, -1 do
    if (counts[index] or 0) == 0 then
      break
    end
    current = current + 1
  end

  return current, best
end

function Activity.normalize(payload, todayDate)
  local viewer = payload
    and payload.data
    and payload.data.viewer
  local calendar = viewer
    and viewer.contributionsCollection
    and viewer.contributionsCollection.contributionCalendar

  if type(viewer) ~= "table" or type(calendar) ~= "table" then
    return nil, "missing contribution calendar"
  end

  if type(viewer.login) ~= "string"
    or type(calendar.weeks) ~= "table"
    or type(calendar.totalContributions) ~= "number" then
    return nil, "invalid contribution calendar"
  end

  local weeks = {}
  for _, sourceWeek in ipairs(calendar.weeks) do
    if type(sourceWeek.contributionDays) ~= "table" then
      return nil, "invalid contribution week"
    end

    local week = { days = {} }
    for _, sourceDay in ipairs(sourceWeek.contributionDays) do
      if type(sourceDay.date) ~= "string" or type(sourceDay.contributionCount) ~= "number" then
        return nil, "invalid contribution day"
      end

      table.insert(week.days, {
        date = sourceDay.date,
        count = math.max(0, math.floor(sourceDay.contributionCount)),
        level = Activity.level(sourceDay.contributionLevel),
      })
    end
    table.insert(weeks, week)
  end

  local days = Activity.flatten(weeks)
  local today = 0
  for _, day in ipairs(days) do
    if day.date == todayDate then
      today = day.count
      break
    end
  end

  local currentStreak, bestStreak = Activity.streaks(days, todayDate)
  return {
    login = viewer.login,
    total = math.max(0, math.floor(calendar.totalContributions)),
    weeks = weeks,
    today = today,
    currentStreak = currentStreak,
    bestStreak = bestStreak,
    fetchedAt = os.time(),
  }
end

function Activity.normalizeText(output, todayDate)
  local header, body = string.match(output or "", "^([^\n]+)\n(.*)$")
  if header == nil or body == nil then
    return nil, "missing contribution header"
  end

  local login, totalText = string.match(header, "^([^\t]+)\t(%d+)$")
  if login == nil or totalText == nil then
    return nil, "invalid contribution header"
  end

  local rows = { "", "", "", "", "", "", "" }
  local counts = {}
  local todayIndex = nil
  local today = 0
  local weekDay = 0
  local dayCount = 0

  for line in string.gmatch(body, "[^\n]+") do
    if line == "WEEK" then
      weekDay = 0
    else
      local date, countText, level = string.match(line, "^([^\t]+)\t(%d+)\t([^\t]+)$")
      if date == nil then
        return nil, "invalid contribution day"
      end

      local count = tonumber(countText)
      if count == nil then
        return nil, "invalid contribution count"
      end

      weekDay = weekDay + 1
      dayCount = dayCount + 1
      rows[weekDay] = rows[weekDay] .. Activity.symbol(level)
      counts[dayCount] = count
      if date == todayDate then
        todayIndex = dayCount
        today = count
      end
    end
  end

  if dayCount == 0 then
    return nil, "empty contribution calendar"
  end

  local currentStreak, bestStreak = Activity.countStreaks(counts, todayIndex)
  return {
    login = login,
    total = tonumber(totalText),
    rows = rows,
    details = data.details or {},
    today = today,
    todayDate = todayDate,
    currentStreak = currentStreak,
    bestStreak = bestStreak,
    fetchedAt = os.time(),
  }
end

-- Convert caches written by the first MVP build (which stored all 371 days)
-- into the compact representation used by the CPU-safe panel.
function Activity.compact(data, todayDate)
  if type(data) ~= "table" then
    return nil
  end

  if type(data.rows) == "table" then
    return data
  end

  if type(data.weeks) ~= "table"
    or type(data.login) ~= "string"
    or type(data.total) ~= "number" then
    return nil
  end

  local rows = { "", "", "", "", "", "", "" }
  for _, week in ipairs(data.weeks) do
    if type(week) ~= "table" or type(week.days) ~= "table" then
      return nil
    end

    for index = 1, 7 do
      local day = week.days[index]
      if day ~= nil then
        rows[index] = rows[index] .. Activity.symbol(day.level)
      end
    end
  end

  return {
    login = data.login,
    total = data.total,
    rows = rows,
    today = data.today or 0,
    todayDate = data.todayDate or todayDate or os.date("%Y-%m-%d"),
    currentStreak = data.currentStreak or 0,
    bestStreak = data.bestStreak or 0,
    fetchedAt = data.fetchedAt or os.time(),
  }
end

function Activity.isValidCache(data)
  return type(data) == "table"
    and type(data.login) == "string"
    and type(data.total) == "number"
    and type(data.rows) == "table"
    and (data.details == nil or type(data.details) == "table")
    and type(data.today) == "number"
    and type(data.todayDate) == "string"
    and type(data.currentStreak) == "number"
    and type(data.bestStreak) == "number"
    and type(data.fetchedAt) == "number"
end

return Activity
