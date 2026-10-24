--!nonstrict
-- Public holidays (spec §6.7), the plugin's only network access: one Nager.Date request
-- per country and year, cached in holidays/<CC>-<YYYY>.json. The cache holds the raw
-- answer, so a region change only filters it again.
--
-- Every year from tracking start to next year is needed: past years are fetched once,
-- the current and next ones are refreshed at most once a week. A failed request is
-- retried an hour later; meanwhile, and in offline mode (the host's `http` honors it),
-- the cache is used. Failures never block tracking.

local Time = require("./time.luau")
local Types = require("./types.luau")

type Host = Types.Host

export type Config = {
  enabled: boolean,
  country: string, -- ISO 3166-1 alpha-2; empty: from the locale
  region: string, -- ISO 3166-2 subdivision, optional
  fromYear: number, -- first year needed (tracking start)
}

export type Monitor = {
  configure: (config: Config) -> (),
  holiday: (dateKey: string) -> string?,
  -- Every known holiday, by date (not to be modified).
  dates: () -> { [string]: string },
  health: () -> Types.BackendHealth,
  -- The one-time hint to show: holidays are unavailable and nothing is cached.
  hint: () -> string?,
  tick: () -> (),
  refresh: () -> (),
}

local Holidays = {}

local URL = "https://date.nager.at/api/v3/PublicHolidays/%d/%s"
local DAY_S = 24 * 60 * 60
local REFRESH_S = 7 * DAY_S
local RETRY_S = 60 * 60
-- Years before tracking start are never needed; a very old tracking start is capped.
local MAX_YEARS = 10

-- Country of the user's locale: `fr_FR.UTF-8` → "FR".
function Holidays.countryFromLocale(getenv: (name: string) -> string?): string?
  for _, name in { "LC_ALL", "LC_TIME", "LANG" } do
    local value = getenv(name)
    if value and value ~= "" then
      local country = string.match(value, "^%a%a%a?_(%a%a)")
      return country and string.upper(country) or nil
    end
  end
  return nil
end

-- The holidays of one cached answer that apply to `region`, by date.
function Holidays.filter(entries: { any }, region: string): { [string]: string }
  local byDate = {}
  for _, entry in entries do
    if type(entry) == "table" and Time.isDate(entry.date) then
      local applies = entry.global == true
      if not applies and region ~= "" and type(entry.counties) == "table" then
        applies = table.find(entry.counties, region) ~= nil
      end
      if applies and not byDate[entry.date] then
        byDate[entry.date] = type(entry.localName) == "string" and entry.localName or tostring(entry.name)
      end
    end
  end
  return byDate
end

function Holidays.start(host: Host, onChange: () -> ()): Monitor
  local dir = host.pluginDataDir()
  local config: Config = { enabled = false, country = "", region = "", fromYear = 0 }
  local country: string? = nil
  local byDate: { [string]: string } = {}
  local fetched: { [number]: number } = {} -- year → fetchedS of its cache file
  local retryAt: { [number]: number } = {}
  local failed = false
  local inFlight = false

  local function nowS(): number
    return host.nowMs() // 1000
  end

  local function currentYear(): number
    return (os.date("*t", nowS()) :: any).year
  end

  local function fileOf(year: number): string?
    if not dir or not country then
      return nil
    end
    return string.format("%s/holidays/%s-%d.json", dir, country, year)
  end

  local function years(): (number, number)
    local last = currentYear() + 1
    return math.max(config.fromYear, last - MAX_YEARS), last
  end

  -- Reads every needed year from the cache.
  local function load()
    byDate, fetched = {}, {}
    if not config.enabled or not country then
      return
    end
    local first, last = years()
    for year = first, last do
      local path = fileOf(year)
      local text = path and host.fileExists(path) and host.readFile(path)
      local doc = text and host.json.decode(text)
      if type(doc) == "table" and type(doc.holidays) == "table" and type(doc.fetchedS) == "number" then
        fetched[year] = doc.fetchedS
        for date, name in Holidays.filter(doc.holidays, config.region) do
          byDate[date] = name
        end
      end
    end
  end

  local function save(year: number, entries: { any }): boolean
    local path = fileOf(year)
    if not path then
      return false
    end
    local text = host.json.encode({ schema = 1, country = country, year = year, fetchedS = nowS(), holidays = entries }, true)
    host.mkdirAll((dir :: string) .. "/holidays")
    return text ~= nil and host.writeFile(path .. ".tmp", text) and host.renameFile(path .. ".tmp", path)
  end

  -- The next year to fetch: a missing one, or a stale current or next year.
  local function due(): number?
    local now, first, last = nowS(), years()
    local thisYear = currentYear()
    for year = first, last do
      local at = fetched[year]
      local stale = at == nil or (year >= thisYear and now - at >= REFRESH_S)
      if stale and now >= (retryAt[year] or 0) then
        return year
      end
    end
    return nil
  end

  -- The health changed: the service publishes it.
  local function fail(year: number)
    retryAt[year] = nowS() + RETRY_S
    failed = true
    onChange()
  end

  local function fetch(year: number)
    local requested = country
    inFlight = true
    local started = host.http({ url = string.format(URL, year, requested :: string) }, function(response)
      inFlight = false
      if requested ~= country then
        return -- the country changed meanwhile
      end
      local entries
      if response.ok and response.status == 200 then
        entries = host.json.decode(response.body)
      elseif response.ok and response.status == 204 then
        entries = {} -- no public holidays that year
      end
      if type(entries) ~= "table" or not save(year, entries) then
        host.log(string.format("holidays: %s %d failed (status %d)", tostring(requested), year, response.status))
        fail(year)
        return
      end
      failed = false
      load()
      onChange()
    end)
    if not started then
      inFlight = false
      fail(year)
    end
  end

  local monitor = {}

  function monitor.configure(next: Config)
    local changed = next.enabled ~= config.enabled
      or next.country ~= config.country
      or next.region ~= config.region
      or next.fromYear ~= config.fromYear
    if not changed then
      return
    end
    config = next
    local code = next.country ~= "" and string.upper(next.country) or Holidays.countryFromLocale(host.getenv)
    -- Interpolated into the request URL: only two letters.
    country = code and string.match(code, "^%u%u$") or nil
    retryAt, failed = {}, false
    load()
    onChange()
  end

  function monitor.holiday(dateKey: string): string?
    return byDate[dateKey]
  end

  function monitor.dates(): { [string]: string }
    return byDate
  end

  function monitor.health(): Types.BackendHealth
    if not config.enabled then
      return "off"
    elseif not country then
      return "unavailable"
    end
    return if failed then "error" else "ok"
  end

  function monitor.hint(): string?
    local health = monitor.health()
    if (health == "error" or health == "unavailable") and next(fetched) == nil then
      return "holidays"
    end
    return nil
  end

  function monitor.tick()
    if config.enabled and country and not inFlight then
      local year = due()
      if year then
        fetch(year)
      end
    end
  end

  -- Forces a refetch of the current and next years (IPC holidays-refresh).
  function monitor.refresh()
    local thisYear = currentYear()
    for year in fetched do
      if year >= thisYear then
        fetched[year] = 0
      end
    end
    retryAt = {}
    monitor.tick()
  end

  return monitor
end

return Holidays
