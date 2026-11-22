--!nonstrict
-- CCF Deadlines service - the only entry that touches the network or disk.
--
-- Fetches ccfddl's aggregated allconf.json, caches it in the plugin data dir,
-- converts every deadline to a UTC epoch, filters by the plugin settings, and
-- publishes the sorted list on "ccfddl.state". Widgets, the panel and the
-- launcher are pure renderers over that state and send actions back on
-- "ccfddl.request" (refresh, star, unstar).

local Common = require("./lib/common.luau")

-- Local-only tick: drops passed deadlines and checks reminders. No network.
local TICK_MS = 10 * 60 * 1000
-- Failed downloads retry after 15 min, doubling up to the refresh interval.
local RETRY_BASE_S = 15 * 60
local CACHE_FILE = "allconf.json"
local ACC_FILE = "allacc.json"
-- Bump when TRIM_FILTER or ACC_FILTER changes: forces one full re-download.
local FILTER_VERSION = 2
local META_FILE = "meta.json"
local FAVORITES_FILE = "favorites.json"
local NOTIFIED_FILE = "notified.json"
local MAX_NOTIFY_PER_PASS = 5

local conferences = nil -- decoded allconf.json
local acceptRates = nil -- lowercased title -> { "22.5%(68/302 26')", ... }, newest first
local accPending = false -- decode allacc.json on the next tick (one decode per callback)
local publishPending = false -- rebuild the list on the next tick, not in the decode callback
local fetchedAt = 0 -- epoch seconds of the last successful download
local fetching = false
local failures = 0
local retryAt = 0 -- epoch seconds before which a failed download is not retried
local lastError = nil
local favorites = {} -- lowercased title -> true
local notified = nil -- notification key -> due epoch
local lastNonce = nil

-- ---------------------------------------------------------------- files

local function dataPath(name)
  local dir, err = noctalia.pluginDataDir()
  if dir == nil then
    noctalia.log("ccf-deadlines: no plugin data dir: " .. tostring(err))
    return nil
  end
  noctalia.mkdirAll(dir)
  return dir .. "/" .. name
end

local function readJson(name)
  local path = dataPath(name)
  if path == nil or not noctalia.fileExists(path) then
    return nil
  end
  local text = noctalia.readFile(path)
  if type(text) ~= "string" or text == "" then
    return nil
  end
  local ok, value = pcall(noctalia.json.decode, text)
  return ok and value or nil
end

local function writeText(name, text)
  local path = dataPath(name)
  if path ~= nil then
    local ok, err = noctalia.writeFile(path, text)
    if not ok then
      noctalia.log(`ccf-deadlines: cannot write {path}: {err}`)
    end
  end
end

local function writeJson(name, value)
  writeText(name, noctalia.json.encode(value))
end

local function loadFavorites()
  favorites = {}
  local list = readJson(FAVORITES_FILE)
  if type(list) == "table" then
    for _, title in ipairs(list) do
      favorites[string.lower(tostring(title))] = true
    end
  end
end

local function saveFavorites()
  local list = {}
  for title in pairs(favorites) do
    table.insert(list, title)
  end
  table.sort(list)
  writeJson(FAVORITES_FILE, list)
end

local function loadNotified()
  if notified == nil then
    local value = readJson(NOTIFIED_FILE)
    notified = type(value) == "table" and value or {}
  end
end

-- ---------------------------------------------------------------- time

-- Days since 1970-01-01 for a proleptic Gregorian date (Hinnant's algorithm).
local function daysFromCivil(y, m, d)
  if m <= 2 then
    y -= 1
  end
  local era = (if y >= 0 then y else y - 399) // 400
  local yoe = y - era * 400
  local mp = (m + 9) % 12
  local doy = (153 * mp + 2) // 5 + d - 1
  local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
  return era * 146097 + doe - 719468
end

-- Day of month of the n-th Sunday of a month.
local function nthSunday(y, m, n)
  local weekday = (daysFromCivil(y, m, 1) + 4) % 7 -- 0 = Sunday
  return 1 + (7 - weekday) % 7 + (n - 1) * 7
end

-- US Pacific: PDT from the 2nd Sunday of March to the 1st Sunday of November.
local function pacificOffset(y, m, d)
  if m > 3 and m < 11 then
    return -7
  elseif m == 3 then
    return if d >= nthSunday(y, 3, 2) then -7 else -8
  elseif m == 11 then
    return if d < nthSunday(y, 11, 1) then -7 else -8
  end
  return -8
end

-- Hours east of UTC for ccfddl's timezone strings: AoE, UTC, UTC+8, UTC-7, PT.
local function tzOffsetHours(tz, y, m, d)
  -- Plain Lua trim: this runs for every date, and host calls are slow.
  tz = tostring(tz or "AoE"):match("^%s*(.-)%s*$")
  if tz == "AoE" or tz == "" then
    return -12
  end
  if tz == "PT" or tz == "PST" or tz == "PDT" then
    return pacificOffset(y, m, d)
  end
  if tz == "UTC" or tz == "GMT" then
    return 0
  end
  local sign, hours, minutes = tz:match("^UTC%s*([%+%-])%s*(%d+):?(%d*)$")
  if sign ~= nil then
    local value = tonumber(hours) + (tonumber(minutes) or 0) / 60
    return if sign == "-" then -value else value
  end
  return -12 -- unknown: be conservative, assume the latest possible moment
end

-- "2026-05-15 23:59:59" in the conference timezone -> UTC epoch seconds.
local function parseEpoch(text, tz)
  if type(text) ~= "string" then
    return nil
  end
  local y, mo, d, h, mi, s = text:match("^(%d+)%-(%d+)%-(%d+)%s+(%d+):(%d+):?(%d*)")
  if y == nil then
    y, mo, d = text:match("^(%d+)%-(%d+)%-(%d+)$")
    h, mi, s = "23", "59", "59"
  end
  if y == nil then
    return nil -- "TBD" and friends
  end
  y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
  local local_ = daysFromCivil(y, mo, d) * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + (tonumber(s) or 0)
  return math.floor(local_ - tzOffsetHours(tz, y, mo, d) * 3600)
end

local toEpoch = parseEpoch

-- ---------------------------------------------------------------- filtering

local RANK_LEVEL = { A = 1, B = 2, C = 3 }

local function rankAllowed(rank, minRank)
  if minRank == "all" then
    return true
  end
  local level = RANK_LEVEL[rank]
  local limit = RANK_LEVEL[minRank] or 3
  return level ~= nil and level <= limit
end

local function lowerSet(key)
  local set, any = {}, false
  local value = noctalia.getConfig(key)
  if type(value) == "table" then
    for _, item in ipairs(value) do
      local name = noctalia.string.trim(tostring(item))
      if name ~= "" then
        set[string.lower(name)] = true
        any = true
      end
    end
  end
  return set, any
end

-- Date conversion is the expensive part, and a script callback has a small
-- CPU budget. So every time data is loaded, `rounds` (one record per
-- submission round, dates already converted) is built a few conferences per
-- tick. buildItems then only filters and sorts it.
local PREPARE_PER_TICK = 20
local rounds = nil -- prepared records, nil while (re)preparing
local preparing = nil -- { index = next conference, rounds = partial list }

local function startPrepare()
  rounds = nil
  if type(conferences) == "table" then
    preparing = { index = 1, rounds = {} }
    noctalia.setUpdateInterval(250)
  else
    preparing = nil
  end
end

-- Returns true once every conference has been prepared.
local function prepareStep()
  if preparing == nil then
    return true
  end
  local list = conferences
  local stop = math.min(preparing.index + PREPARE_PER_TICK - 1, #list)
  for i = preparing.index, stop do
    local conf = list[i]
    local title = tostring(conf.title or "?")
    local lower = string.lower(title)
    local rank = type(conf.rank) == "table" and conf.rank or {}
    for _, edition in ipairs(type(conf.confs) == "table" and conf.confs or {}) do
      local tz = edition.timezone
      local opening = toEpoch(edition.opening, tz)
      for index, round in ipairs(type(edition.timeline) == "table" and edition.timeline or {}) do
        local abstract = toEpoch(round.abstract_deadline, tz)
        local paper = toEpoch(round.deadline, tz)
        if abstract ~= nil and abstract == paper then
          abstract = nil
        end
        local milestones = {}
        local function add(k, t)
          if t ~= nil then
            table.insert(milestones, { kind = k, due = t })
          end
        end
        add("abstract", abstract)
        add("paper", paper)
        add("rebuttal", toEpoch(round.rebuttal_deadline, tz))
        add("decision", toEpoch(round.decision_deadline, tz))
        add("opening", opening)
        table.sort(milestones, function(x, y)
          return x.due < y.due
        end)
        table.insert(preparing.rounds, {
          id = `{edition.id or lower}:{index}`,
          lower = lower,
          title = title,
          description = tostring(conf.description or ""),
          sub = tostring(conf.sub or ""),
          ccf = tostring(rank.ccf or "N"),
          core = rank.core ~= nil and tostring(rank.core) or nil,
          thcpl = rank.thcpl ~= nil and tostring(rank.thcpl) or nil,
          year = edition.year,
          link = edition.link,
          place = edition.place,
          date = edition.date,
          comment = round.comment,
          tz = tostring(tz or "AoE"),
          abstractDue = abstract,
          paperDue = paper,
          milestones = milestones,
        })
      end
    end
  end
  preparing.index = stop + 1
  if preparing.index > #list then
    rounds = preparing.rounds
    preparing = nil
    return true
  end
  return false
end

-- One item per submission round. `due` is the round's next submission
-- deadline (the abstract while it is ahead, then the paper); `milestones` is
-- the full timeline for the panel's detail view.
local function buildItems()
  if rounds == nil then
    return {}
  end
  local now = Common.nowSec()
  local horizon = now + (tonumber(noctalia.getConfig("horizon_days")) or 180) * 86400
  local minRank = noctalia.getConfig("min_rank") or "C"
  local includeAbstract = noctalia.getConfig("include_abstract") ~= false
  local categories, filterCategories = lowerSet("categories")
  local always = lowerSet("always_show")

  local items = {}
  for _, r in ipairs(rounds) do
    local starred = favorites[r.lower] == true
    local visible = starred or always[r.lower] == true
      or (rankAllowed(r.ccf, minRank) and (not filterCategories or categories[string.lower(r.sub)] == true))
    if visible then
      local abstract, paper = r.abstractDue, r.paperDue
      local due, kind = nil, nil
      if includeAbstract and abstract ~= nil and abstract > now then
        due, kind = abstract, "abstract"
      elseif paper ~= nil and paper > now then
        due, kind = paper, "paper"
      elseif paper == nil and abstract ~= nil and abstract > now then
        due, kind = abstract, "abstract"
      end
      if due ~= nil and due <= horizon then
        table.insert(items, {
          id = r.id,
          title = r.title,
          description = r.description,
          sub = r.sub,
          ccf = r.ccf,
          core = r.core,
          thcpl = r.thcpl,
          year = r.year,
          link = r.link,
          place = r.place,
          date = r.date,
          comment = r.comment,
          tz = r.tz,
          kind = kind,
          due = due,
          abstractDue = abstract,
          paperDue = paper,
          milestones = r.milestones,
          acc = type(acceptRates) == "table" and acceptRates[r.lower] or nil,
          starred = starred,
        })
      end
    end
  end
  table.sort(items, function(a, b)
    if a.due ~= b.due then
      return a.due < b.due
    end
    return a.id < b.id
  end)
  return items
end

-- ---------------------------------------------------------------- notify

local function notifyDue(items)
  local days = tonumber(noctalia.getConfig("notify_days")) or 0
  if days <= 0 then
    return
  end
  loadNotified()
  local now = Common.nowSec()
  local all = noctalia.getConfig("notify_all") == true
  local includeAbstract = noctalia.getConfig("include_abstract") ~= false
  local sent, dirty = 0, false

  for _, item in ipairs(items) do
    if all or item.starred then
      local targets = { { kind = "paper", due = item.paperDue } }
      if includeAbstract then
        table.insert(targets, { kind = "abstract", due = item.abstractDue })
      end
      for _, target in ipairs(targets) do
        local remaining = if target.due ~= nil then target.due - now else -1
        -- One reminder when entering the window, another in the last 24 hours.
        local stage = nil
        if remaining > 0 and remaining <= 86400 then
          stage = "1d"
        elseif remaining > 0 and remaining <= days * 86400 then
          stage = "window"
        end
        if stage ~= nil then
          local key = `{item.id}:{target.kind}:{stage}`
          -- Only reminders actually sent are recorded; the rest go out on a later pass.
          if notified[key] == nil and sent < MAX_NOTIFY_PER_PASS then
            notified[key] = target.due
            dirty = true
            sent += 1
            noctalia.notify(
              noctalia.tr("notify.title", { name = Common.itemTitle(item) }),
              noctalia.tr("notify.body", {
                kind = noctalia.tr(`milestone.{target.kind}`),
                left = Common.countdown(remaining),
                time = noctalia.formatTime("%a %Y-%m-%d %H:%M", target.due),
              })
            )
          end
        end
      end
    end
  end

  -- Forget reminders for deadlines that have passed.
  for key, due in pairs(notified) do
    if type(due) ~= "number" or due < now then
      notified[key] = nil
      dirty = true
    end
  end
  if dirty then
    writeJson(NOTIFIED_FILE, notified)
  end
end

-- ---------------------------------------------------------------- publish

local function publish()
  local items = buildItems()
  local starred = {}
  for title in pairs(favorites) do
    table.insert(starred, title)
  end
  noctalia.state.set("ccfddl.state", {
    phase = if conferences == nil and not fetching and lastError ~= nil then "error"
      elseif rounds == nil then "loading"
      else "ready",
    fetching = fetching,
    error = lastError,
    fetchedAt = fetchedAt,
    conferenceCount = type(conferences) == "table" and #conferences or 0,
    items = items,
    favorites = starred,
  })
  notifyDue(items)
end

local function parseBody(body)
  local ok, decoded = pcall(noctalia.json.decode, body)
  if ok and type(decoded) == "table" and #decoded > 0 then
    return decoded
  end
  if not ok then
    noctalia.log("ccf-deadlines: decode failed: " .. tostring(decoded))
  end
  return nil
end

-- allconf.json is ~800 KB, which a script callback cannot decode within its
-- CPU budget. curl + jq trim it to editions with a deadline from two days ago
-- onward (~50 KB) before the service ever sees it.
local TRIM_FILTER = [[
def live: ((. // "") | type == "string" and . >= $cut and . < "A");
[ .[]
  | .confs = [ (.confs // [])[]
      | .timeline = [ (.timeline // [])[] | select((.deadline | live) or (.abstract_deadline | live)) ]
      | select(.timeline | length > 0)
      | {year, id, link, timeline, timezone, date, place, opening} ]
  | select(.confs | length > 0)
  | {title, description, sub, rank, confs} ]
]]

-- allacc.json (~225 KB) -> { "mobisys": ["22.5%(68/302 26')", "18.0%(42/233 25')"] }
local ACC_FILTER = [[
map(select((.accept_rates // []) | length > 0)
    | { key: (.title | ascii_downcase),
        value: [ .accept_rates | sort_by(.year) | .[-2:] | reverse | .[] | .str ] })
| from_entries
]]

-- Smallest transfer the server allows:
--  * If-Modified-Since with the server's Last-Modified from the last download:
--    304 and no body when unchanged. (ETags differ between the site's mirrors,
--    so they miss; the dates differ by a second at most, so at worst one extra
--    download.)
--  * a single encoding, the best this curl decodes: zstd (~114 KB), else br
--    (~117 KB), else gzip (~124 KB), instead of ~800 KB. Only one is offered
--    because Cloudflare picks gzip whenever gzip is in the list.
-- then jq trims it to current editions (~50 KB) for the script to decode.
-- Prints "updated <bytes>" or "unchanged 0".
local FETCH_SCRIPT = [[
cut=$1 fv=$8
case "$(curl -V | grep -i '^features:')" in
  *zstd*) enc=zstd ;;
  *brotli*) enc=br ;;
  *) enc=gzip ;;
esac
# get NAME URL FILTER OUT -> prints "NAME updated|unchanged BYTES"
get() {
  local name=$1 url=$2 filter=$3 out=$4
  local stamp="$out.v$fv.stamp" dl="$out.download" res code size status cond=()
  [ -s "$out" ] || rm -f "$stamp"
  # The stamp holds the URL it was made for: a different source is fetched in full.
  [ -e "$stamp" ] && [ "$(< "$stamp")" = "$url" ] && cond=(-z "$stamp")
  [ -n "$url" ] || return 2
  res=$(curl -sS --fail --max-time 60 --max-filesize 20000000 --proto =https -R "${cond[@]}" \
    -H "Accept-Encoding: $enc" --compressed \
    -o "$dl" -w '%{http_code} %{size_download}' "$url") || { rm -f "$dl"; return 1; }
  read -r code size <<< "$res"
  if [ "$code" = 304 ] || [ ! -e "$dl" ]; then
    rm -f "$dl"
    echo "$name unchanged 0"
    return 0
  fi
  jq -c --arg cut "$cut" "$filter" "$dl" > "$out.tmp" && mv -f "$out.tmp" "$out" && printf '%s' "$url" > "$stamp" && touch -r "$dl" "$stamp"
  status=$?
  rm -f "$dl" "$out.tmp"
  [ $status = 0 ] && echo "$name updated $size"
  return $status
}
get conf "$2" "$3" "$4" || exit 1
# Acceptance rates are optional: a failure here keeps the old file.
if [ -n "$5" ]; then get acc "$5" "$6" "$7" || echo "acc failed 0"; else echo "acc skipped 0"; fi
exit 0
]]

local FETCH_TIMEOUT_MS = 90 * 1000

local function loadAccFile()
  local value = readJson(ACC_FILE)
  if type(value) == "table" then
    acceptRates = value
  end
end

local function loadCacheFile()
  local path = dataPath(CACHE_FILE)
  if path == nil or not noctalia.fileExists(path) then
    return nil
  end
  local text = noctalia.readFile(path)
  return type(text) == "string" and parseBody(text) or nil
end

local function refreshSeconds()
  return (tonumber(noctalia.getConfig("refresh_days")) or 7) * 86400
end

local function noteFailure(detail)
  failures += 1
  retryAt = Common.nowSec() + math.min(RETRY_BASE_S * 2 ^ (failures - 1), refreshSeconds())
  lastError = noctalia.tr("error.fetch", { detail = detail })
  noctalia.log(`ccf-deadlines: fetch failed ({failures}): {detail}`)
end

local function fetch()
  if fetching then
    return
  end
  local path = dataPath(CACHE_FILE)
  if path == nil then
    lastError = noctalia.tr("error.fetch", { detail = "no data dir" })
    publish()
    return
  end
  if not noctalia.commandExists("curl") or not noctalia.commandExists("jq") then
    lastError = noctalia.tr("error.missing_tools")
    publish()
    return
  end
  local url = noctalia.string.trim(tostring(noctalia.getConfig("data_url") or ""))
  if url == "" then
    url = "https://ccfddl.com/conference/allconf.json"
  end
  -- Only https: keeps curl off file:// and plain-http sources (curl enforces it too).
  if not url:match("^https://[^%s%c]+$") then
    lastError = noctalia.tr("error.bad_url")
    publish()
    return
  end
  local cut = noctalia.formatTime("%Y-%m-%d", Common.nowSec() - 2 * 86400)
  -- Acceptance rates sit next to allconf.json; any other data URL skips them.
  local accUrl = if url:match("/allconf%.json$") then url:gsub("allconf%.json$", "allacc.json") else ""
  local accPath = dataPath(ACC_FILE)

  fetching = true
  publish()
  local started = noctalia.runAsync({ "bash", "-c", FETCH_SCRIPT, "ccf-deadlines", cut, url, TRIM_FILTER, path, accUrl, ACC_FILTER, accPath, tostring(FILTER_VERSION) }, function(result)
    fetching = false
    if result.timedOut or result.exitCode ~= 0 then
      local detail = noctalia.string.trim(result.stderr or "")
      if detail == "" then
        detail = if result.timedOut then "timeout" else `exit {result.exitCode}`
      end
      noteFailure(detail)
    else
      local out = result.stdout or ""
      local kind, bytes = out:match("conf%s+(%a+)%s+(%d+)")
      local accKind, accBytes = out:match("acc%s+(%a+)%s+(%d+)")
      if accKind == "updated" or (accKind == "unchanged" and acceptRates == nil) then
        accPending = true
        noctalia.setUpdateInterval(1000)
      end
      local decoded = if kind == "unchanged" and conferences ~= nil then conferences else loadCacheFile()
      if decoded == nil then
        noteFailure(noctalia.tr("error.parse"))
      else
        local changed = decoded ~= conferences
        conferences = decoded
        if changed then
          startPrepare()
        end
        fetchedAt = Common.nowSec()
        lastError = nil
        failures = 0
        retryAt = 0
        writeJson(META_FILE, { fetchedAt = fetchedAt, url = url, filterVersion = FILTER_VERSION })
        noctalia.log(`ccf-deadlines: deadlines {kind or "?"} ({bytes or "?"} bytes), acceptance rates {accKind or "?"} ({accBytes or "?"} bytes)`)
      end
    end
    -- Decoding and rebuilding in one callback can exceed the CPU budget.
    publishPending = true
    noctalia.setUpdateInterval(1000)
  end, FETCH_TIMEOUT_MS)
  if started == false then
    fetching = false
    noteFailure("could not start curl")
    publish()
  end
end

local function refreshIfStale()
  local now = Common.nowSec()
  if now < retryAt then
    return
  end
  if conferences == nil or now - fetchedAt >= refreshSeconds() then
    fetch()
  end
end

local function loadCache()
  conferences = loadCacheFile()
  local meta = readJson(META_FILE)
  if conferences ~= nil and type(meta) == "table" and meta.filterVersion == FILTER_VERSION then
    fetchedAt = tonumber(meta.fetchedAt) or 0
  end
end

-- ---------------------------------------------------------------- requests

noctalia.state.watch(Common.REQUEST_KEY, function(value)
  if type(value) ~= "table" or value.nonce == lastNonce then
    return
  end
  lastNonce = value.nonce
  local action = value.action
  if action == "refresh" then
    retryAt = 0 -- a manual refresh skips the backoff
    fetch()
  elseif action == "star" or action == "unstar" or action == "toggle_star" then
    local title = type(value.title) == "string" and string.lower(value.title) or nil
    if title == nil or title == "" then
      return
    end
    local on = if action == "toggle_star" then favorites[title] ~= true else action == "star"
    favorites[title] = if on then true else nil
    saveFavorites()
    publish()
  elseif action == "ping" then
    publish()
  end
end)

function update()
  -- At most one heavy step per tick: acceptance rates, preparing the data a
  -- few conferences at a time, then the list rebuild.
  if accPending then
    accPending = false
    loadAccFile()
    publishPending = true
    return
  end
  if preparing ~= nil then
    if prepareStep() then
      publishPending = true
    end
    return
  end
  if publishPending then
    publishPending = false
    noctalia.setUpdateInterval(TICK_MS)
    publish()
    return
  end
  refreshIfStale()
  publish()
end

-- `noctalia msg plugin samxu29/ccf-deadlines:service <target> refresh`
function onIpc(event, _payload)
  if event == "refresh" then
    retryAt = 0
    fetch()
  end
end

function onConfigChanged()
  publish()
end

loadFavorites()
loadCache()
startPrepare()
-- Decode acceptance rates on the first tick, not in the same callback.
accPending = true
lastNonce = (noctalia.state.get(Common.REQUEST_KEY) or {}).nonce
-- The cache was just decoded; the first list rebuild happens on the next tick.
refreshIfStale()
noctalia.setUpdateInterval(250)
