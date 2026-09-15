--!nonstrict
-- Browser panel: a little radio receiver. Search radio-browser.info, keep
-- favorites, control playback. Playback itself is owned by the [[service]]
-- (player.luau): this panel only publishes requests to shared state and
-- mirrors status/favorites back.

local API_MIRRORS = { "https://de1.api.radio-browser.info", "https://de2.api.radio-browser.info" }
local UA = "noctalia-radio/0.1.0"

local query = ""
local results = {}
local favorites = noctalia.state.get("radio_favorites") or {}
local status = noctalia.state.get("radio_status") or { playing = false, name = "", url = "", uuid = "", volume = 70 }
local loading = false
local errorMsg = ""
local open = false

local function favPath()
  return noctalia.pluginDataDir() .. "/favorites.json"
end

local function saveFavorites()
  noctalia.state.set("radio_favorites", favorites)
  noctalia.writeFile(favPath(), noctalia.json.encode(favorites) or "[]")
end

local function loadFavorites()
  local raw = noctalia.readFile(favPath())
  if raw then
    local data = noctalia.json.decode(raw)
    if type(data) == "table" then
      favorites = data
      noctalia.state.set("radio_favorites", favorites)
    end
  end
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

local function isFav(uuid)
  for _, f in favorites do
    if f.uuid == uuid then
      return true
    end
  end
  return false
end

local function isPlaying(st)
  if not status.playing then
    return false
  end
  if status.uuid and status.uuid ~= "" and st.uuid and st.uuid ~= "" then
    return status.uuid == st.uuid
  end
  return status.url ~= "" and status.url == st.url
end

local function toStation(s)
  return {
    uuid = s.stationuuid or "",
    name = s.name or "Unknown",
    url = s.url_resolved or s.url or "",
    country = s.country or "",
    codec = s.codec or "",
    bitrate = tonumber(s.bitrate) or 0,
  }
end

local function specLine(st)
  local parts = {}
  if st.country and st.country ~= "" then
    table.insert(parts, st.country)
  end
  if st.bitrate and st.bitrate > 0 then
    table.insert(parts, tostring(st.bitrate) .. "k")
  end
  if st.codec and st.codec ~= "" then
    table.insert(parts, st.codec)
  end
  return table.concat(parts, "  •  ")
end

-- GET with mirror fallback: de1 is sometimes down, de2 usually answers.
local function apiGet(path, cb, attempt)
  attempt = attempt or 1
  local base = API_MIRRORS[attempt]
  if not base then
    cb(nil)
    return
  end
  noctalia.http({ url = base .. path, headers = { "User-Agent: " .. UA } }, function(res)
    if res.ok then
      cb(res)
    else
      apiGet(path, cb, attempt + 1)
    end
  end)
end

local function fetchStations(path)
  loading = true
  errorMsg = ""
  render()
  apiGet(path, function(res)
    loading = false
    if res == nil then
      errorMsg = "Network error talking to radio-browser.info"
      render()
      return
    end
    local data = noctalia.json.decode(res.body)
    if type(data) ~= "table" then
      errorMsg = "Unexpected response from radio-browser.info"
      render()
      return
    end
    local limit = math.clamp(math.floor(tonumber(noctalia.getConfig("search_limit")) or 20), 5, 50)
    local out = {}
    for _, s in data do
      if type(s) == "table" and (s.url_resolved or s.url) then
        table.insert(out, toStation(s))
        if #out >= limit then
          break
        end
      end
    end
    results = out
    if #results == 0 then
      errorMsg = "No stations found"
    end
    render()
  end)
end

local function searchUrl(q)
  q = tostring(q or "")
  local rawLimit = noctalia.getConfig("search_limit")
  local rawCountry = noctalia.getConfig("country")
  local limit = math.clamp(math.floor(tonumber(rawLimit) or 20), 5, 50)
  local country = noctalia.string.trim(tostring(rawCountry or ""))
  local url = "/json/stations/search?name=" .. noctalia.string.urlEncode(q)
    .. "&limit=" .. tostring(limit) .. "&hidebroken=true&order=votes&reverse=true"
  if country ~= "" then
    url = url .. "&country=" .. noctalia.string.urlEncode(country)
  end
  return url
end

local function topUrl()
  local rawLimit = noctalia.getConfig("search_limit")
  local rawCountry = noctalia.getConfig("country")
  local limit = math.clamp(math.floor(tonumber(rawLimit) or 20), 5, 50)
  local country = noctalia.string.trim(tostring(rawCountry or ""))
  if country ~= "" then
    return "/json/stations/bycountry/" .. noctalia.string.urlEncode(country)
      .. "?limit=" .. tostring(limit) .. "&hidebroken=true&order=votes&reverse=true"
  end
  return "/json/stations/topvote/" .. tostring(limit) .. "?hidebroken=true"
end

-- Decorative tuner bars: dance while playing, rest flat while stopped.
local function eqValues()
  local bars = {}
  local t = os.time()
  for i = 1, 28 do
    if status.playing then
      local v = 0.3 + 0.28 * math.sin(t * 2.1 + i * 0.7) + 0.18 * math.sin(t * 3.7 + i * 1.9)
      bars[i] = math.max(0.08, math.min(1, v))
    else
      bars[i] = 0.07
    end
  end
  return bars
end

local function stationRow(st)
  local playing = isPlaying(st)
  return ui.row({ key = "st-" .. st.uuid, gap = 10, align = "center" }, {
    ui.button({
      glyph = playing and "player-stop-filled" or "player-play-filled",
      variant = playing and "primary" or "ghost",
      controlSize = "sm",
      tooltip = playing and "Stop" or "Play " .. st.name,
      onClick = function()
        if playing then
          request("stop")
        else
          request("play", { uuid = st.uuid, name = st.name, url = st.url })
        end
      end,
    }),
    ui.column({ flexGrow = 1, gap = 1 }, {
      ui.label({ text = st.name, maxLines = 1, fontWeight = playing and "semibold" or "normal", color = playing and "primary" or "on_surface" }),
      ui.label({ text = specLine(st), fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
    }),
    ui.button({
      glyph = isFav(st.uuid) and "star-filled" or "star",
      variant = "ghost",
      controlSize = "sm",
      tooltip = isFav(st.uuid) and "Remove favorite" or "Save favorite",
      onClick = function()
        toggleFav(st)
      end,
    }),
  })
end

function toggleFav(st)
  for i, f in favorites do
    if f.uuid == st.uuid then
      table.remove(favorites, i)
      saveFavorites()
      render()
      return
    end
  end
  table.insert(favorites, {
    uuid = st.uuid,
    name = st.name,
    url = st.url,
    country = st.country,
    codec = st.codec,
    bitrate = st.bitrate,
  })
  saveFavorites()
  render()
end

function onSearchInput(value)
  query = value
end

function onSearchSubmit(value)
  query = noctalia.string.trim(value or "")
  if query == "" then
    fetchStations(topUrl())
  else
    fetchStations(searchUrl(query))
  end
end

function onSearchClicked()
  onSearchSubmit(query)
end

function onVolume(value)
  local v = math.clamp(math.floor(tonumber(value) or 70), 0, 100)
  status.volume = v
  request("volume", { volume = v })
  render()
end

function onTogglePlaying()
  if status.playing then
    request("stop")
  elseif status.url ~= "" then
    request("play", { name = status.name, url = status.url, uuid = status.uuid })
  end
end

function onCloseClicked()
  panel.close()
end

-- Panel must be open to receive this (use panel-toggle first).
function onIpc(event, payload)
  if event == "search" then
    onSearchSubmit(tostring(payload or ""))
  end
end

function render()
  if not open then
    return
  end
  local nowName = status.name ~= "" and status.name or "Nothing playing"
  local nowSpec = specLine({ country = "", codec = "", bitrate = 0 })
  if status.playing then
    nowSpec = "ON AIR"
  elseif status.name ~= "" then
    nowSpec = "STOPPED"
  else
    nowSpec = "PICK A STATION BELOW"
  end

  local body = {
    -- Receiver face: tuner display + transport + volume.
    ui.column({ gap = 10, fill = "surface_variant/0.55", radius = 18, padding = 16 }, {
      ui.row({ gap = 8, align = "center" }, {
        ui.glyph({ name = status.playing and "radio" or "radio-off", size = 20, color = "primary" }),
        ui.column({ flexGrow = 1, gap = 1 }, {
          ui.label({ text = nowName, fontSize = 15, fontWeight = "bold", maxLines = 1 }),
          ui.label({ text = nowSpec, fontSize = 11, fontWeight = "medium", color = status.playing and "primary" or "on_surface_variant", maxLines = 1 }),
        }),
        ui.button({
          glyph = status.playing and "player-stop-filled" or "player-play-filled",
          glyphSize = 22,
          variant = "primary",
          controlSize = "lg",
          enabled = status.url ~= "" or status.playing,
          tooltip = status.playing and "Stop" or "Play",
          onClick = "onTogglePlaying",
        }),
      }),
      ui.graph({ values = eqValues(), color = "primary", fillOpacity = 0.35, height = 42 }),
      ui.row({ gap = 10, align = "center" }, {
        ui.glyph({ name = "volume-2", size = 15, color = "on_surface_variant" }),
        ui.slider({ min = 0, max = 100, step = 1, value = tonumber(status.volume) or 70, flexGrow = 1, controlSize = "sm", onChange = "onVolume" }),
        ui.label({ text = tostring(tonumber(status.volume) or 70) .. "%", fontSize = 12, color = "on_surface_variant", width = 40, textAlign = "end" }),
      }),
    }),
    -- Dial: search.
    ui.row({ gap = 8, align = "center" }, {
      ui.input({ key = "search", placeholder = "Tune in... search stations", flexGrow = 1, onChange = "onSearchInput", onSubmit = "onSearchSubmit" }),
      ui.button({ glyph = "search", variant = "secondary", controlSize = "sm", tooltip = "Search", onClick = "onSearchClicked" }),
    }),
  }

  if #favorites > 0 then
    table.insert(body, ui.label({ text = "PRESETS", fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }))
    local n = 0
    for _, f in favorites do
      n = n + 1
      if n > 6 then
        break
      end
      table.insert(body, stationRow({
        uuid = f.uuid or "",
        name = f.name or "Unknown",
        url = f.url or "",
        country = f.country or "",
        codec = f.codec or "",
        bitrate = tonumber(f.bitrate) or 0,
      }))
    end
    table.insert(body, ui.separator({ spacing = 4 }))
  end

  table.insert(body, ui.label({ text = "STATIONS", fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }))
  if loading then
    table.insert(body, ui.label({ text = "Tuning...", color = "on_surface_variant" }))
  elseif errorMsg ~= "" and #results == 0 then
    table.insert(body, ui.label({ text = errorMsg, color = "on_surface_variant" }))
  else
    for _, st in results do
      table.insert(body, stationRow(st))
    end
  end

  panel.render(ui.column({ flexGrow = 1, gap = 14 }, {
    ui.row({ align = "center", gap = 8 }, {
      ui.label({ text = "Radio", fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
      ui.button({ glyph = "close", variant = "ghost", controlSize = "sm", onClick = "onCloseClicked" }),
    }),
    ui.scroll({ flexGrow = 1, gap = 12 }, body),
  }))
end

noctalia.state.watch("radio_status", function(value)
  if type(value) == "table" then
    status = value
    render()
  end
end)

noctalia.state.watch("radio_favorites", function(value)
  if type(value) == "table" then
    favorites = value
    render()
  end
end)

function update()
  -- Second ticks drive the tuner animation while the panel is open.
  render()
end

function onOpen(_context)
  open = true
  panel.setWantsSecondTicks(true)
  loadFavorites()
  if query == "" and #results == 0 then
    fetchStations(topUrl())
  else
    render()
  end
end

function onClose()
  open = false
end
