--!nonstrict
-- The poller: the one part of this plugin that talks to NaN.
--
-- It holds the API key, fetches the three responses the model reads, and publishes
-- what came back on the plugin's shared state under "data". The bar widget and the
-- panel are subscribers: each builds the record from that data with its own clock,
-- so the bar's countdowns move between polls — the panel rebuilds on each poll and
-- on opening, since it is usually open for a moment — and neither of them spawns a
-- process or touches the network.
--
-- Nothing here judges anything. Levels, projections and text live in shared.luau,
-- which the surfaces run too; this file only says what came back and what did not.

-- The NaN cloud API. It has no published contract — the shapes the model reads were
-- taken from the panel bundle — so a failure here is reported, not interpreted.
local API = "https://cloud-api.nan.builders"

-- The three responses. The quota is the one that matters; the account decorates it
-- and the aggregates are opt-out, because they cost a request of their own.
local ENDPOINTS = {
  { path = "/api/usage/quota", slot = "quota" },
  { path = "/api/auth/me", slot = "me" },
  { path = "/api/metrics/usage", slot = "metrics", setting = "show_metrics" },
}

-- Where the data is published, and the key a surface uses to ask for a refresh.
-- One VM cannot call into another, so the channel is how the panel's header asks
-- the poller to go now.
local DATA_KEY = "data"
local REFRESH_KEY = "refresh"

-- The file the `nan` CLI uses, so one key serves both. The read below resolves `~`
-- itself.
local DEFAULT_KEY_PATH = "~/.config/nan/api-key"

local data = {
  quota = nil,
  me = nil,
  metrics = nil,
  fetchedAt = nil,
  error = "",
}
local pending = 0
local lastPoll = 0

local function publish()
  -- A copy, not the same table every time: a host that compares by identity would
  -- otherwise see no change and never notify the surfaces.
  local snapshot = {
    quota = data.quota,
    me = data.me,
    metrics = data.metrics,
    fetchedAt = data.fetchedAt,
    error = data.error,
  }
  noctalia.state.set(DATA_KEY, snapshot)
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
  local seconds = tonumber(noctalia.getConfig("interval")) or 60
  if seconds < 15 then
    seconds = 15
  elseif seconds > 1800 then
    seconds = 1800
  end
  return seconds * 1000
end

-- One response settled. The quota decides whether the poll worked; the last good
-- numbers are never thrown away, because an error next to them is what lets a
-- surface say "showing the last data" instead of going blank.
local function settle(slot, value, reason)
  pending = pending - 1
  if slot == "quota" then
    if value ~= nil then
      data.quota = value
      data.error = ""
      data.fetchedAt = os.time()
    elseif reason ~= nil then
      data.error = reason
    end
  elseif value ~= nil then
    data[slot] = value
  end
  if pending <= 0 then
    pending = 0
    publish()
  end
end

local function get(endpoint, key)
  local started = noctalia.http({
    url = API .. endpoint.path,
    headers = {
      "Authorization: Bearer " .. key,
      "Accept: application/json",
      "User-Agent: noctalia-nan-usage",
    },
  }, function(response)
    local value, reason = nil, nil
    if not response.ok then
      reason = "Could not reach " .. API
    elseif response.status == 401 or response.status == 403 then
      reason = "NaN rejected the API key in " .. keyPath()
    elseif response.status < 200 or response.status > 299 then
      reason = "NaN answered " .. tostring(response.status) .. " for " .. endpoint.path
    else
      local decoded, err = noctalia.json.decode(response.body or "")
      if decoded == nil then
        reason = "Unreadable answer from " .. endpoint.path .. " (" .. tostring(err) .. ")"
      else
        value = decoded
      end
    end
    settle(endpoint.slot, value, reason)
  end)
  if started == false then
    settle(endpoint.slot, nil, "Could not start a request to " .. API)
  end
end

-- force skips the rate limit, and is what a surface's refresh button uses.
local function poll(force)
  if pending > 0 then
    return
  end
  if not force and lastPoll > 0 and os.time() - lastPoll < intervalMs() / 2000 then
    -- The first tick after load can arrive almost immediately, and the host calls
    -- update() again on a settings change. Half an interval is the floor between
    -- two polls; a surface's refresh bypasses it.
    return
  end
  local key, reason = readKey()
  if key == nil then
    reason = reason or ("Could not read a key from " .. keyPath())
    data.error = reason
    publish()
    noctalia.log("NaN Usage: " .. reason)
    return
  end
  lastPoll = os.time()
  local wanted = {}
  for _, endpoint in ipairs(ENDPOINTS) do
    if endpoint.setting == nil or noctalia.getConfig(endpoint.setting) ~= false then
      wanted[#wanted + 1] = endpoint
    end
  end
  pending = #wanted
  for _, endpoint in ipairs(wanted) do
    get(endpoint, key)
  end
end

noctalia.state.watch(REFRESH_KEY, function()
  poll(true)
end)

-- The service's tick is the poll: one pass over the three endpoints per interval.
function update()
  noctalia.setUpdateInterval(intervalMs())
  poll(false)
end

-- Say something before the first response lands, so a surface that opens early
-- finds a record rather than nothing.
publish()
poll(true)
