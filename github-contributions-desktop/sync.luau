--!nonstrict
-- GitHub Contributions sync service: fetches the authenticated account's
-- contribution calendar via GitHub CLI (`gh api graphql`) and publishes the
-- normalized calendar on noctalia.state for the desktop widget.
--
-- Based on alexmnrs/github-activity (MIT), which this plugin is derived from.
-- The service owns all fetching and caching; the desktop widget is a thin
-- noctalia.state client and never spawns a process or touches the network.

local Activity = require("./lib/activity.luau")
local Settings = require("./lib/settings.luau")

local function buildQuery(year)
  if year == "last12" then
    return [[
query {
  viewer {
    login
    contributionsCollection {
      contributionCalendar {
        totalContributions
        weeks {
          contributionDays {
            date
            contributionCount
            contributionLevel
          }
        }
      }
    }
  }
}
]]
  end

  -- A calendar year is fetched with an explicit from/to range.
  return string.format([[
query {
  viewer {
    login
    contributionsCollection(from: "%s-01-01T00:00:00Z", to: "%s-12-31T23:59:59Z") {
      contributionCalendar {
        totalContributions
        weeks {
          contributionDays {
            date
            contributionCount
            contributionLevel
          }
        }
      }
    }
  }
}
]], year, year)
end

local JQ_QUERY = [=[
def sym:
  if . == "NONE" then "·"
  elif . == "FIRST_QUARTILE" then "░"
  elif . == "SECOND_QUARTILE" then "▒"
  elif . == "THIRD_QUARTILE" then "▓"
  else "█"
  end;
def maxrun:
  reduce .[] as $value
    ({ current: 0, maximum: 0 };
      if $value > 0
      then .current += 1 | .maximum = ([.maximum, .current] | max)
      else .current = 0
      end
    ) | .maximum;
def suffixrun:
  reduce .[] as $value
    ({ running: 0, stopped: false };
      if .stopped
      then .
      elif $value > 0
      then .running += 1
      else .stopped = true
      end
    ) | .running;

(.data.viewer.contributionsCollection.contributionCalendar) as $calendar
| $calendar.weeks as $weeks
| [$weeks[] | .contributionDays[]] as $days
| (now | strftime("%Y-%m-%d")) as $today
| ([$days[] | .date] | index($today)) as $todayIndex
| (if $todayIndex == null
   then null
   elif $days[$todayIndex].contributionCount == 0
   then $todayIndex - 1
   else $todayIndex
   end) as $streakEnd
| (if $streakEnd == null or $streakEnd < 0
   then 0
   else [range(0; $streakEnd + 1) as $offset
         | $days[$streakEnd - $offset].contributionCount] | suffixrun
   end) as $currentStreak
| ([$days[] | .contributionCount] | maxrun) as $bestStreak
| ([range(0; 7) as $day
    | [$weeks[]
       | ((.contributionDays | .[$day] | .contributionLevel // "NONE") | sym)]
    | join("")]) as $rows
| ([range(0; 7) as $day
    | [$weeks[]
       | (.contributionDays | .[$day] // null)
       | if . == null then "" else "\(.date)|\(.contributionCount)" end]
    | join("\t")]) as $details
| {
    login: .data.viewer.login,
    total: $calendar.totalContributions,
    rows: $rows,
    details: $details,
    today: (if $todayIndex == null then 0 else $days[$todayIndex].contributionCount end),
    todayDate: $today,
    currentStreak: $currentStreak,
    bestStreak: $bestStreak,
    fetchedAt: now
  }
]=]

local cachePath = nil
local inFlight = false

local function todayDate()
  return os.date("%Y-%m-%d")
end

local function publish(status, detail)
  noctalia.state.set("status", status)
  noctalia.state.set("error", detail or "")
end

local function initialiseCache()
  local dataDir, error = noctalia.pluginDataDir()
  if dataDir == nil then
    noctalia.log("GitHub Contributions could not create its data directory: " .. tostring(error))
    return
  end

  cachePath = dataDir .. "/activity.json"
  local contents, readError = noctalia.readFile(cachePath)
  if contents == nil then
    if readError ~= nil then
      noctalia.log("GitHub Contributions cache is unavailable: " .. tostring(readError))
    end
    return
  end

  local cached, decodeError = noctalia.json.decode(contents)
  cached = Activity.compact(cached, todayDate())
  if cached == nil or not Activity.isValidCache(cached) then
    noctalia.log("GitHub Contributions ignored an invalid cache: " .. tostring(decodeError or "unexpected data"))
    return
  end

  -- The cache is year-aware: only reuse it when it covers the year the
  -- user currently selected (caches written before the year setting existed
  -- count as "last12").
  local selectedYear = Settings.selectedYear(noctalia.getConfig("year"))
  if (cached.year or "last12") ~= selectedYear then
    noctalia.log("GitHub Contributions ignored a cache from a different year.")
    return
  end

  noctalia.state.set("data", cached)
  noctalia.state.set("year", selectedYear)
  noctalia.state.set("stale", true)
  publish("stale")
end

local function persist(data)
  if cachePath == nil then
    return
  end

  local encoded, encodeError = noctalia.json.encode(data)
  if encoded == nil then
    noctalia.log("GitHub Contributions could not encode its cache: " .. tostring(encodeError))
    return
  end

  local ok, writeError = noctalia.writeFile(cachePath, encoded)
  if not ok then
    noctalia.log("GitHub Contributions could not write its cache: " .. tostring(writeError))
  end
end

local function failure(status, detail)
  inFlight = false
  noctalia.state.set("stale", noctalia.state.get("data") ~= nil)
  publish(status, detail)
end

local function refresh()
  if inFlight then
    return
  end

  if not noctalia.commandExists("gh") then
    failure("missing_gh", "GitHub CLI (gh) is not installed.")
    return
  end

  inFlight = true
  publish("loading")
  local year = Settings.selectedYear(noctalia.getConfig("year"))
  noctalia.state.set("year", year)
  noctalia.runAsync({ "gh", "api", "graphql", "--jq", JQ_QUERY, "-f", "query=" .. buildQuery(year) }, function(result)
    if result.exitCode ~= 0 then
      local message = string.lower(result.stderr or "")
      if string.find(message, "auth", 1, true) or string.find(message, "token", 1, true) then
        failure("auth_error", "Run gh auth login -h github.com to authenticate GitHub CLI.")
      else
        failure("request_error", "GitHub CLI could not fetch contribution data.")
      end
      return
    end

    local data, decodeError = noctalia.json.decode(result.stdout or "")
    if data == nil or not Activity.isValidCache(data) then
      failure("invalid_response", "GitHub returned an unexpected contribution calendar: " .. tostring(decodeError or "invalid normalized data"))
      return
    end

    inFlight = false
    data.year = year
    persist(data)
    noctalia.state.set("data", data)
    noctalia.state.set("stale", false)
    publish("ready")
  end)
end

local function configureRefreshInterval()
  noctalia.setUpdateInterval(Settings.refreshIntervalMs(noctalia.getConfig("refresh_interval_minutes")))
end

configureRefreshInterval()
initialiseCache()
refresh()

noctalia.state.watch("refresh_request", function(_value)
  refresh()
end)

function update()
  refresh()
end

function onEnable()
  refresh()
end

function onConfigChanged()
  configureRefreshInterval()
  refresh()
end

function onIpc(event, _payload)
  if event == "refresh" then
    refresh()
  end
end
