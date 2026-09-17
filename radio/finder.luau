--!nonstrict
-- Launcher provider: /radio <text> searches favorites + radio-browser.info.
-- Activating a result plays it through the player service.

local API_MIRRORS = { "https://de1.api.radio-browser.info", "https://de2.api.radio-browser.info" }
local UA = "noctalia-radio/0.1.0"

-- uuid -> station details for onActivate (launcher runtime persists).
local known = {}

local function favPath()
  return noctalia.pluginDataDir() .. "/favorites.json"
end

local function loadFavorites()
  local raw = noctalia.readFile(favPath())
  if not raw then
    return {}
  end
  local data = noctalia.json.decode(raw)
  if type(data) == "table" then
    return data
  end
  return {}
end

local function request(action, extra)
  local prev = noctalia.state.get("radio_request")
  local seq = 0
  if type(prev) == "table" and tonumber(prev.seq) then
    seq = tonumber(prev.seq)
  end
  local req = { seq = seq + 1, action = action }
  if type(extra) == "table" then
    for k, v in extra do
      req[k] = v
    end
  end
  noctalia.state.set("radio_request", req)
end

local function playRow(st, score)
  known[st.uuid] = st
  local sub = st.country or ""
  if tonumber(st.bitrate) and tonumber(st.bitrate) > 0 then
    sub = sub .. (sub ~= "" and " - " or "") .. tostring(st.bitrate) .. "k"
  end
  return {
    id = "play:" .. st.uuid,
    title = st.name,
    subtitle = sub ~= "" and sub or "Radio station - Enter to play",
    glyph = "player-play",
    score = score,
  }
end

local function searchPath(q, limit)
  return "/json/stations/search?name=" .. noctalia.string.urlEncode(q)
    .. "&limit=" .. tostring(limit) .. "&hidebroken=true&order=votes&reverse=true"
end

local function apiSearch(path, cb, attempt)
  attempt = attempt or 1
  local base = API_MIRRORS[attempt]
  if not base then
    return
  end
  noctalia.http({ url = base .. path, headers = { "User-Agent: " .. UA } }, function(res)
    if not res.ok then
      apiSearch(path, cb, attempt + 1)
      return
    end
    cb(res)
  end)
end

function onQuery(text)
  local q = noctalia.string.trim(text or "")
  local limit = math.clamp(math.floor(tonumber(noctalia.getConfig("search_limit")) or 20), 5, 50)
  local favs = loadFavorites()
  local rows = {}

  if q == "" then
    for _, f in favs do
      if type(f) == "table" and f.uuid and f.url then
        table.insert(rows, playRow({
          uuid = f.uuid,
          name = f.name or "Unknown",
          url = f.url,
          country = f.country or "",
          bitrate = tonumber(f.bitrate) or 0,
        }, 100))
      end
    end
    if #rows == 0 then
      rows[1] = { id = "", title = "Type a station name to search", subtitle = "Favorites will appear here", glyph = "radio" }
    else
      table.insert(rows, { id = "", title = "Type to search all of radio-browser.info", glyph = "search" })
    end
    launcher.setResults(text, rows)
    return
  end

  -- Synchronous pass: matching favorites first, placeholder for network.
  for _, f in favs do
    if type(f) == "table" and f.name and f.uuid and f.url then
      local score = noctalia.fuzzyScore(q, f.name)
      if score ~= nil then
        table.insert(rows, playRow({
          uuid = f.uuid,
          name = f.name,
          url = f.url,
          country = f.country or "",
          bitrate = tonumber(f.bitrate) or 0,
        }, 100 + (score or 0)))
      end
    end
  end
  table.insert(rows, { id = "", title = "Searching radio-browser.info for '" .. q .. "'...", glyph = "loader" })
  launcher.setResults(text, rows)

  apiSearch(searchPath(q, limit), function(res)
    local data = noctalia.json.decode(res.body)
    if type(data) ~= "table" then
      return
    end
    local fresh = {}
    for _, f in loadFavorites() do
      if type(f) == "table" and f.name and f.uuid and f.url then
        local score = noctalia.fuzzyScore(q, f.name)
        if score ~= nil then
          table.insert(fresh, playRow({
            uuid = f.uuid,
            name = f.name,
            url = f.url,
            country = f.country or "",
            bitrate = tonumber(f.bitrate) or 0,
          }, 100 + (score or 0)))
        end
      end
    end
    local n = 0
    for _, s in data do
      if type(s) == "table" and (s.url_resolved or s.url) and s.stationuuid then
        n = n + 1
        table.insert(fresh, playRow({
          uuid = s.stationuuid,
          name = s.name or "Unknown",
          url = s.url_resolved or s.url,
          country = s.country or "",
          bitrate = tonumber(s.bitrate) or 0,
        }, 50 - n))
      end
      if n >= limit then
        break
      end
    end
    if #fresh == 0 then
      fresh[1] = { id = "", title = "No stations found for '" .. q .. "'", glyph = "mood-empty" }
    end
    launcher.setResults(text, fresh)
  end)
end

function onActivate(id)
  if id == "" or id == nil then
    return
  end
  local uuid = string.match(id, "^play:(.+)$")
  if uuid and known[uuid] then
    local st = known[uuid]
    request("play", { uuid = st.uuid, name = st.name, url = st.url })
    noctalia.notify("Radio", "Playing " .. st.name)
  end
end
