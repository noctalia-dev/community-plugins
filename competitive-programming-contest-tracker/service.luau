--!nonstrict
local cache = require("./lib/cache.luau")
local filtersLib = require("./lib/filters.luau")
local format = require("./lib/format.luau")
local lists = require("./lib/lists.luau")
local reminders = require("./lib/reminders.luau")
local settings = require("./lib/settings.luau")
local state = require("./lib/state.luau")
local types = require("./lib/types.luau")

local SOURCES: { types.Source } = {
  require("./sources/codeforces.luau"),
  require("./sources/codechef.luau"),
  require("./sources/leetcode.luau"),
  require("./sources/atcoder.luau"),
}

local TICK_MS = 30 * 1000
local RETRY_S = 5 * 60

local upBySource, pastBySource = cache.load()
local filters: types.Filters = filtersLib.load()

local upcoming: { types.Contest } = {}
local pending = 0
local failures = 0
local lastAttempt = 0
local wait = 0

local function publish()
  local now = os.time()
  local up, past = lists.build(upBySource, pastBySource, filters, now)
  upcoming = up
  noctalia.state.set(state.CONTESTS, up)
  noctalia.state.set(state.PAST, past)
  noctalia.state.set(state.UPDATED, now)
end

local function finishOne(id: string, up: { types.Contest }?, past: { types.Contest }?)
  if up then
    upBySource[id] = up
    pastBySource[id] = past or {}
  else
    failures += 1
    noctalia.log(`{id}: fetch failed`)
  end
  pending -= 1
  if pending == 0 then
    publish()
    cache.save(upBySource, pastBySource)
    wait = failures > 0 and RETRY_S or settings.refreshSeconds()
  end
end

local function refresh()
  if pending > 0 then
    return
  end
  lastAttempt = os.time()
  failures = 0
  pending = #SOURCES
  local opts: types.FetchOpts = { pastWindowSeconds = settings.pastWindowSeconds() }

  for _, source in ipairs(SOURCES) do
    local reported = false
    local function done(up: { types.Contest }?, past: { types.Contest }?)
      if not reported then
        reported = true
        finishOne(source.id, up, past)
      end
    end
    local ok, err = (pcall :: any)(source.fetch, done, opts)
    if not ok then
      noctalia.log(`{source.id}: {err}`)
      done(nil)
    end
  end
end

local function maybeRefresh()
  if pending == 0 and os.time() - lastAttempt >= wait then
    refresh()
  end
end

local function refreshNow()
  lastAttempt = 0
  wait = 0
  maybeRefresh()
end

reminders.load()
publish()
maybeRefresh()

noctalia.setUpdateInterval(TICK_MS)
function update()
  maybeRefresh()
  reminders.check(upcoming, filters.favorites)
end

noctalia.state.watch(state.FILTERS, function(value: any)
  if type(value) == "table" and type(value.favorites) == "table" and type(value.saved) == "table" then
    filters = value
    publish()
    reminders.check(upcoming, filters.favorites)
  end
end)

noctalia.state.watch(state.REFRESH, refreshNow)

function onConfigChanged()
  wait = math.min(wait, settings.refreshSeconds())
  publish()
end

function onIpc(event: string, _payload: string?)
  if event == "refresh" then
    refreshNow()
  elseif event == "test-reminder" then
    local c = upcoming[1]
    if c then
      reminders.notify(c, noctalia.tr("reminders.test", { time = format.fmtDur(c.start - os.time()) }))
    end
  end
end
