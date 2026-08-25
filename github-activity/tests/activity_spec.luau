--!nonstrict

local Activity = require("../github-activity/lib/activity")
local fixtures = require("./fixtures")

local function equal(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
  end
end

local function normalize(fixture)
  return Activity.normalize(fixture, "2026-08-24")
end

local empty = normalize(fixtures.empty)
equal(empty.today, 0, "empty calendar today")
equal(empty.currentStreak, 0, "empty calendar current streak")
equal(empty.bestStreak, 0, "empty calendar best streak")

local fullYear = normalize(fixtures.fullYear)
equal(#fullYear.weeks, 53, "full year keeps all weeks")
equal(#Activity.flatten(fullYear.weeks), 371, "full year keeps partial calendar days")

local activeToday = normalize(fixtures.activeToday)
equal(activeToday.today, 7, "today count")
equal(activeToday.currentStreak, 4, "active current streak")
equal(activeToday.bestStreak, 4, "active best streak")
equal(activeToday.weeks[1].days[1].level, 2, "level normalization")

local yesterday = normalize(fixtures.emptyTodayKeepsYesterday)
equal(yesterday.today, 0, "empty today count")
equal(yesterday.currentStreak, 4, "yesterday streak is retained")
equal(yesterday.bestStreak, 4, "yesterday best streak")

local gaps = normalize(fixtures.gaps)
equal(gaps.currentStreak, 3, "current streak stops at gap")
equal(gaps.bestStreak, 3, "best streak honors gaps")
equal(Activity.color(0), "surface_variant", "zero activity color")
equal(Activity.color(4), "primary", "maximum activity color")

local malformed, err = normalize(fixtures.malformed)
equal(malformed, nil, "malformed response is rejected")
if err == nil then
  error("malformed response should include an error")
end

print("GitHub Activity tests passed")
