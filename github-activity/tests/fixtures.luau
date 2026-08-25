--!nonstrict

local function day(date, count, level)
  return {
    date = date,
    contributionCount = count,
    contributionLevel = level or (count > 0 and "FIRST_QUARTILE" or "NONE"),
  }
end

local function payload(days)
  local total = 0
  for _, item in ipairs(days) do
    total = total + item.contributionCount
  end

  return {
    data = {
      viewer = {
        login = "AlexMnrs",
        contributionsCollection = {
          contributionCalendar = {
            totalContributions = total,
            weeks = { { contributionDays = days } },
          },
        },
      },
    },
  }
end

local function fullYear()
  local weeks = {}
  local start = os.time({ year = 2025, month = 8, day = 24, hour = 12 })
  local total = 0

  for weekIndex = 0, 52 do
    local contributionDays = {}
    for dayIndex = 0, 6 do
      local count = ((weekIndex + dayIndex) % 5 == 0) and 2 or 0
      total = total + count
      table.insert(contributionDays, day(
        os.date("%Y-%m-%d", start + (weekIndex * 7 + dayIndex) * 86400),
        count
      ))
    end
    table.insert(weeks, { contributionDays = contributionDays })
  end

  return {
    data = {
      viewer = {
        login = "AlexMnrs",
        contributionsCollection = {
          contributionCalendar = {
            totalContributions = total,
            weeks = weeks,
          },
        },
      },
    },
  }
end

return {
  empty = payload({
    day("2026-08-22", 0),
    day("2026-08-23", 0),
    day("2026-08-24", 0),
  }),
  fullYear = fullYear(),
  activeToday = payload({
    day("2026-08-21", 2, "SECOND_QUARTILE"),
    day("2026-08-22", 1),
    day("2026-08-23", 4, "THIRD_QUARTILE"),
    day("2026-08-24", 7, "FOURTH_QUARTILE"),
  }),
  emptyTodayKeepsYesterday = payload({
    day("2026-08-20", 2),
    day("2026-08-21", 1),
    day("2026-08-22", 3),
    day("2026-08-23", 1),
    day("2026-08-24", 0),
  }),
  gaps = payload({
    day("2026-08-18", 1),
    day("2026-08-19", 1),
    day("2026-08-20", 0),
    day("2026-08-21", 1),
    day("2026-08-22", 1),
    day("2026-08-23", 1),
    day("2026-08-24", 0),
  }),
  malformed = { data = { viewer = { login = "AlexMnrs" } } },
}
