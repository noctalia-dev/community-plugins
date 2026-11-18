--!nonstrict
-- Polls OwnTone's JSON API and publishes a normalized status table via
-- noctalia.state, so the widget and panel entries never touch the network
-- themselves for reading state.

local STATUS_KEY = "owntone.status"

local function baseUrl()
  local host = noctalia.getConfig("host") or "127.0.0.1:3689"
  return "http://" .. host
end

local function httpJson(url, cb)
  local req = {
    url = url,
    headers = { "Accept: application/json" }
  }
  local user = noctalia.getConfig("username") or ""
  if user ~= "" then
    req.basic_username = user
    req.basic_password = noctalia.getConfig("password") or ""
  end
  noctalia.http(req, function(res)
    if res == nil or res.ok ~= true or res.body == nil or res.body == "" then
      cb(nil)
      return
    end
    local ok, decoded = pcall(noctalia.json.decode, res.body)
    cb(ok and decoded or nil)
  end)
end

local function publish(status)
  noctalia.state.set(STATUS_KEY, status)
end

local function poll()
  httpJson(baseUrl() .. "/api/player", function(player)
    if player == nil then
      publish({ reachable = false })
      return
    end

    httpJson(baseUrl() .. "/api/queue?id=now_playing", function(queue)
      local current_track = nil
      if queue ~= nil and queue.items ~= nil and type(queue.items) == "table" and queue.items[1] ~= nil then
        current_track = queue.items[1]
      end

      httpJson(baseUrl() .. "/api/outputs", function(outputsData)
        local outputs = {}
        if outputsData ~= nil and outputsData.outputs ~= nil and type(outputsData.outputs) == "table" then
          outputs = outputsData.outputs
        end

        publish({
          reachable = true,
          state = player.state,
          volume = player.volume,
          repeat_mode = player["repeat"] or "off",
          shuffle = player.shuffle == true,
          item_length_ms = player.item_length_ms or (current_track and current_track.length_ms) or 0,
          item_progress_ms = player.item_progress_ms or 0,
          title = (current_track ~= nil) and current_track.title or nil,
          artist = (current_track ~= nil) and current_track.artist or nil,
          album = (current_track ~= nil) and current_track.album or nil,
          artwork_url = (current_track ~= nil and current_track.artwork_url) or player.artwork_url or nil,
          outputs = outputs,
        })
      end)
    end)
  end)
end

local seconds = tonumber(noctalia.getConfig("poll_seconds")) or 3
noctalia.setUpdateInterval(seconds * 1000)

function update()
  poll()
end

-- Allow panel or widget to trigger immediate re-poll after user interaction
noctalia.state.watch("owntone.refresh", function()
  poll()
end)

-- Poll once immediately at load instead of waiting a full interval.
poll()
