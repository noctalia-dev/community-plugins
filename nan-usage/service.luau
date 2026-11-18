--!nonstrict
-- The poller: the one part of this plugin that talks to NaN.
--
-- It holds the API key, asks /v1/usage for the billing period, and publishes the
-- answer on the plugin's shared state under "data". The bar widget and the panel
-- are subscribers: each builds the record from that data with its own clock, so the
-- bar's countdowns move between polls — the panel rebuilds on each poll and on
-- opening, since it is usually open for a moment — and neither of them spawns a
-- process or touches the network.
--
-- Nothing here judges anything. Levels, the pace and every text live in
-- shared.luau, which the surfaces run too; this file only says what came back and
-- what did not.

local shared = require("./shared.luau")

-- The one endpoint: NaN's documented usage report, which an API key may read. It
-- carries the period's credits, and the tokens and credits per model per day.
local API = "https://api.nan.builders/v1/usage"

-- Rows per page. A billing period is about 31 days of a handful of models, so one
-- page covers it; the cursor is followed anyway, up to a bound.
local PAGE_LIMIT = 500
local MAX_PAGES = 5

-- How long to stay quiet after NaN says 429. The host does not hand over response
-- headers, so Retry-After cannot be read; the usage report allows 30 requests a
-- minute, and a minute clears that.
local BACKOFF_SECONDS = 60

-- Where the data is published, and the key a surface uses to ask for a refresh.
-- One VM cannot call into another, so the channel is how the panel's header asks
-- the poller to go now.
local DATA_KEY = "data"
local REFRESH_KEY = "refresh"

-- The file the `nan` CLI uses, so one key serves both. The read below resolves `~`
-- itself.
local DEFAULT_KEY_PATH = "~/.config/nan/api-key"

local data = {
  usage = nil,
  fetchedAt = nil,
  error = "",
}
local busy = false
local lastPoll = 0
local quietUntil = 0

local function publish()
  -- A copy, not the same table every time: a host that compares by identity would
  -- otherwise see no change and never notify the surfaces.
  noctalia.state.set(DATA_KEY, {
    usage = data.usage,
    fetchedAt = data.fetchedAt,
    error = data.error,
  })
end

local function keyPath()
  local configured = noctalia.getConfig("api_key")
  if type(configured) == "string" and configured ~= "" then
    return configured
  end
  return DEFAULT_KEY_PATH
end

-- The key, or a sentence saying which of the ways it can be missing happened.
local function readKey()
  -- The configured path is what the messages name, since that is what the setting
  -- shows and what someone would go and look at; the expanded one is only for the
  -- file calls.
  local configured = keyPath()
  local path = noctalia.expandPath(configured)
  if not noctalia.fileExists(path) then
    return nil, "No API key at " .. configured
  end
  local contents, err = noctalia.readFile(path)
  if contents == nil then
    return nil, "Could not read " .. configured .. " (" .. tostring(err) .. ")"
  end
  -- Only the first line: a key is one token, and a stray second line (a comment
  -- someone added) would otherwise end up inside the Authorization header.
  local key = tostring(contents):match("^[^\r\n]*") or ""
  key = key:match("^%s*(.-)%s*$") or ""
  if key == "" then
    return nil, "The key file at " .. configured .. " is empty"
  end
  return key
end

-- The tick rate is the poll interval: there is nothing to do in between.
local function intervalMs()
  local seconds = tonumber(noctalia.getConfig("interval")) or 300
  if seconds < 15 then
    seconds = 15
  elseif seconds > 1800 then
    seconds = 1800
  end
  return seconds * 1000
end

-- The poll is over. A good answer replaces the data; a failed one keeps the last
-- good numbers, because an error next to them is what lets a surface say "showing
-- the last data" instead of going blank.
local function finish(usage, reason)
  busy = false
  if usage ~= nil then
    data.usage = usage
    data.error = ""
    data.fetchedAt = os.time()
  else
    data.error = reason
    noctalia.log("NaN Usage: " .. reason)
  end
  publish()
end

local function url(from, cursor)
  local query = API .. "?start_date=" .. from .. "&limit=" .. PAGE_LIMIT
  if cursor ~= nil then
    -- An opaque token; percent-encode anything that is not plainly safe in a query.
    query = query .. "&cursor=" .. cursor:gsub("[^%w%-%._~]", function(c)
      return string.format("%%%02X", string.byte(c))
    end)
  end
  return query
end

-- One page. The first one carries the totals and the credits; any later page only
-- adds rows, which are appended to the first.
local function fetch(key, from, cursor, first, page)
  local started = noctalia.http({
    url = url(from, cursor),
    headers = {
      "Authorization: Bearer " .. key,
      "Accept: application/json",
      "User-Agent: noctalia-nan-usage",
    },
  }, function(response)
    if not response.ok then
      finish(nil, "Could not reach " .. API)
      return
    end
    if response.status == 401 or response.status == 403 then
      finish(nil, "NaN rejected the API key in " .. keyPath())
      return
    end
    if response.status == 429 then
      quietUntil = os.time() + BACKOFF_SECONDS
      finish(nil, "NaN asked to slow down; trying again in a minute")
      return
    end
    if response.status < 200 or response.status > 299 then
      finish(nil, "NaN answered " .. tostring(response.status) .. " for /v1/usage")
      return
    end
    local decoded, err = noctalia.json.decode(response.body or "")
    if type(decoded) ~= "table" then
      finish(nil, "Unreadable answer from /v1/usage (" .. tostring(err) .. ")")
      return
    end
    local whole = first or decoded
    if first ~= nil and type(decoded.data) == "table" and type(whole.data) == "table" then
      for _, row in ipairs(decoded.data) do
        table.insert(whole.data, row)
      end
    end
    local nextCursor = decoded.next_cursor
    if decoded.has_more == true and type(nextCursor) == "string" and nextCursor ~= "" and page < MAX_PAGES then
      fetch(key, from, nextCursor, whole, page + 1)
      return
    end
    finish(whole, nil)
  end)
  if started == false then
    finish(nil, "Could not start a request to " .. API)
  end
end

-- force skips the rate limit, and is what a surface's refresh button uses.
local function poll(force)
  if busy then
    return
  end
  local now = os.time()
  if now < quietUntil then
    return
  end
  if not force and lastPoll > 0 and now - lastPoll < intervalMs() / 2000 then
    -- The first tick after load can arrive almost immediately, and the host calls
    -- update() again on a settings change. Half an interval is the floor between
    -- two polls; a surface's refresh bypasses it.
    return
  end
  local key, reason = readKey()
  if key == nil then
    data.error = reason or ("Could not read a key from " .. keyPath())
    publish()
    noctalia.log("NaN Usage: " .. data.error)
    return
  end
  lastPoll = now
  busy = true
  -- The billing period's first day, once an answer has said what it is.
  local credits = data.usage and data.usage.credits
  local periodStart = type(credits) == "table" and credits.period_start or nil
  fetch(key, shared.windowStart(periodStart, now), nil, nil, 1)
end

noctalia.state.watch(REFRESH_KEY, function()
  poll(true)
end)

-- The service's tick is the poll: one request per interval.
function update()
  noctalia.setUpdateInterval(intervalMs())
  poll(false)
end

-- Say something before the first response lands, so a surface that opens early
-- finds a record rather than nothing.
publish()
poll(true)
