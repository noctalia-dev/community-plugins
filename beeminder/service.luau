--!nonstrict
local API = "https://www.beeminder.com/api/v1/users/me"

local inFlight = false
local refreshQueued = false
-- The username never changes for a given token, so it is fetched once per token.
local usernameFor = { token = nil, username = nil }
local fetch

local function token()
  return noctalia.string.trim(noctalia.getConfig("auth_token") or "")
end

local function intervalMs()
  return math.max(1, tonumber(noctalia.getConfig("refresh_minutes")) or 5) * 60 * 1000
end

local function publish(report)
  noctalia.state.set("report", report)
end

local function finish()
  inFlight = false
  if refreshQueued then
    refreshQueued = false
    fetch()
  end
end

-- Goals from the last good fetch stay visible in the panel while the error is shown.
local function fail(status, detail)
  local previous = noctalia.state.get("report")
  publish({
    status = status,
    detail = detail,
    username = usernameFor.username,
    goals = previous and previous.goals or nil,
    fetchedAt = previous and previous.fetchedAt or nil,
  })
  finish()
end

local function summarize(goal)
  return {
    slug = goal.slug,
    title = (goal.title ~= nil and goal.title ~= "") and goal.title or goal.slug,
    limsum = goal.limsum or "",
    safebuf = tonumber(goal.safebuf) or 0,
    losedate = tonumber(goal.losedate) or 0,
    pledge = tonumber(goal.pledge) or 0,
    colorkey = goal.colorkey or "gray",
    urgencykey = goal.urgencykey or "",
    frozen = goal.frozen == true,
    won = goal.won == true,
  }
end

local function get(path, authToken, onBody)
  local url = `{API}{path}?auth_token={noctalia.string.urlEncode(authToken)}`
  local started = noctalia.http({ url = url }, function(res)
    -- The token changed while this request was in flight, so its result belongs to another account.
    if authToken ~= token() then
      finish()
    elseif not res.ok then
      fail("error", noctalia.tr("error.network"))
    elseif res.status == 401 then
      fail("unauthorized")
    elseif res.status ~= 200 then
      fail("error", noctalia.tr("error.http_status", { status = res.status }))
    else
      local body, err = noctalia.json.decode(res.body)
      if type(body) ~= "table" then
        fail("error", noctalia.tr("error.bad_json", { error = err or "" }))
      else
        local ok, bodyErr = pcall(onBody, body)
        if not ok then
          fail("error", noctalia.tr("error.bad_json", { error = tostring(bodyErr) }))
        end
      end
    end
  end)
  if not started then
    fail("error", noctalia.tr("error.not_started"))
  end
end

local function loadGoals(authToken)
  get("/goals.json", authToken, function(goals)
    local summaries = {}
    for _, goal in ipairs(goals) do
      table.insert(summaries, summarize(goal))
    end
    table.sort(summaries, function(a, b)
      return a.urgencykey < b.urgencykey
    end)
    publish({ status = "ok", username = usernameFor.username, goals = summaries, fetchedAt = os.time() })
    finish()
  end)
end

fetch = function()
  local authToken = token()
  if authToken == "" then
    usernameFor = { token = nil, username = nil }
    publish({ status = "no_token" })
    return
  end
  if inFlight then
    refreshQueued = true
    return
  end
  inFlight = true

  if usernameFor.token == authToken then
    loadGoals(authToken)
  else
    get(".json", authToken, function(user)
      usernameFor = { token = authToken, username = user.username }
      loadGoals(authToken)
    end)
  end
end

noctalia.state.watch("refresh_request", function(_)
  fetch()
end)

noctalia.setUpdateInterval(intervalMs())
fetch()

function update()
  fetch()
end

function onConfigChanged()
  noctalia.setUpdateInterval(intervalMs())
  fetch()
end
