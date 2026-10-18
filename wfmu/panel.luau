--!nonstrict
-- WFMU browse panel: play live streams and each show's most recent archive.

local data_dir = noctalia.pluginDataDir()
local pid_file = data_dir .. "/mpv.pid"
local ipc_sock = data_dir .. "/mpv.sock"

local function configure(key, fallback)
  local value = noctalia.getConfig(key)
  if value == nil or value == "" then
    return fallback
  end
  return value
end

-- Single-quote a value for the shell, so a crafted URL or path containing $, `
-- or " can never be expanded into a second command.
local function shq(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local tsv_path = configure("tsv_path", data_dir .. "/latest-archives.tsv")

-- The live streams are static, so seed the view with them: the panel shows
-- something the moment it opens, while the service is still downloading the
-- archive list. Keep in sync with LIVE_STREAMS in scripts/wfmu_archives.py.
local LIVE_SEED = table.concat({
  "WFMU 91.1 East Orange, NJ\thttp://stream2.wfmu.org/freeform-128k",
  "WFMU Give the Drummer Radio\thttp://stream0.wfmu.org/drummer",
  "WFMU Rock'n'Soul Radio\thttps://wfmu.org/wfmu_rock.pls",
  "WFMU Sheena's Jungle Room\thttps://wfmu.org/wfmu_sheena.pls",
}, "\n") .. "\n"

local items = {}
local query = ""
local refreshing = noctalia.state.get("refreshing") == true
local open = false
local render
local favorites_path = data_dir .. "/favorites.json"
local favorites = {}

local function showKey(name)
  local k = noctalia.string.trim((name or ""):gsub("%s*%b()%s*$", ""))
  return string.lower(k)
end

local function loadFavorites()
  local raw = noctalia.readFile(favorites_path)
  if raw then
    local data = noctalia.json.decode(raw)
    if type(data) == "table" then
      favorites = data
    end
  end
end

local function saveFavorites()
  noctalia.writeFile(favorites_path, noctalia.json.encode(favorites, true))
end

local function migrateLegacyFavorites()
  local legacy = {}
  for k, v in pairs(favorites) do
    if v == true then
      legacy[#legacy + 1] = k
    end
  end
  if #legacy == 0 then
    return
  end
  for _, url in ipairs(legacy) do
    local name
    for _, it in ipairs(items) do
      if it.url == url then
        name = it.name
        break
      end
    end
    if name then
      local key = showKey(name)
      favorites[key] = favorites[key] or { url = url, name = name }
    end
    favorites[url] = nil
  end
  saveFavorites()
end

local function toggleFavorite(it)
  local key = showKey(it.name)
  if favorites[key] then
    favorites[key] = nil
  else
    favorites[key] = { url = it.url, name = it.name }
  end
  saveFavorites()
  render()
end

loadFavorites()

local function stopPlayback()
  if pid_file ~= "" then
    noctalia.runAsync(string.format(
      "if [ -f %s ]; then kill $(cat %s) 2>/dev/null; rm -f %s; fi; rm -f %s",
      shq(pid_file), shq(pid_file), shq(pid_file), shq(ipc_sock)))
  end
  noctalia.state.set("now", nil)
  noctalia.state.set("paused", false)
end

local function isArchiveUrl(url)
  return string.find(url, "mp3archives.wfmu.org", 1, true) ~= nil
    or string.find(url, "/archive/", 1, true) ~= nil
    or string.sub(url, -4) == ".mp3"
    or string.sub(url, -4) == ".mp4"
end

-- Archives are the seekable streams; live radio is not.
local isSeekable = isArchiveUrl

local function parseList(contents)
  local out = {}
  for line in contents:gmatch("[^\r\n]+") do
    local tab = string.find(line, "\t", 1, true)
    if tab then
      local name = noctalia.string.trim(line:sub(1, tab - 1))
      local url = noctalia.string.trim(line:sub(tab + 1))
      if url ~= "" then
        out[#out + 1] = {
          name = name,
          nameLower = string.lower(name),
          url = url,
          isArchive = isArchiveUrl(url),
        }
      end
    end
  end
  return out
end

-- Show the live streams straight away; the downloaded list replaces these.
items = parseList(LIVE_SEED)

local function startPlayback(name, url)
  noctalia.state.set("last_name", name)
  noctalia.state.set("last_url", url)
  noctalia.state.set("seekable", isSeekable(url))
  local ok = noctalia.runAsync(string.format(
    "if [ -f %s ]; then kill $(cat %s) 2>/dev/null; fi; rm -f %s %s; mpv --no-video --input-ipc-server=%s %s >/dev/null 2>&1 & echo $! > %s",
    shq(pid_file), shq(pid_file), shq(pid_file), shq(ipc_sock), shq(ipc_sock), shq(url), shq(pid_file)))
  if not ok then
    noctalia.notifyError("WFMU", "could not start mpv")
    return false
  end
  noctalia.state.set("now", name)
  noctalia.state.set("paused", false)
  return true
end

local function play(name, url)
  startPlayback(name, url)
end

local function playRandom()
  local query_l = string.lower(query)
  local candidates = {}
  for _, it in ipairs(items) do
    if query_l == "" or string.find(it.nameLower, query_l, 1, true) then
      candidates[#candidates + 1] = it
    end
  end
  if #candidates == 0 then
    noctalia.notify("WFMU", "no streams to pick from")
    return
  end
  local pick = candidates[math.random(1, #candidates)]
  if startPlayback(pick.name, pick.url) then
    render()
  end
end

local function seekBy(delta)
  noctalia.runAsync(string.format(
    "python3 -c 'import socket,sys,json;s=socket.socket(socket.AF_UNIX);s.connect(sys.argv[1]);s.send((json.dumps({\"command\":[\"seek\",sys.argv[2]]})+\"\\n\").encode())' %s %d",
    shq(ipc_sock), delta))
end

local function setPaused(paused)
  noctalia.runAsync(string.format(
    "python3 -c 'import socket,sys,json;s=socket.socket(socket.AF_UNIX);s.connect(sys.argv[1]);s.send((json.dumps({\"command\":[\"set_property\",\"pause\",sys.argv[2]]})+\"\\n\").encode())' %s %s",
    shq(ipc_sock), paused and "yes" or "no"))
end

local function togglePause()
  local paused = noctalia.state.get("paused") == true
  local next = not paused
  setPaused(next)
  noctalia.state.set("paused", next)
  render()
end

render = function()
  local query_l = string.lower(query)
  local live = {}
  local faved = {}
  local rest = {}
  local viewCount = 0
  local favDirty = false
  for _, it in ipairs(items) do
    if query_l == "" or string.find(it.nameLower, query_l, 1, true) then
      viewCount = viewCount + 1
      local key = showKey(it.name)
      if not it.isArchive then
        live[#live + 1] = it
      elseif favorites[key] then
        faved[#faved + 1] = it
        if favorites[key].url ~= it.url then
          favorites[key] = { url = it.url, name = it.name }
          favDirty = true
        end
      else
        rest[#rest + 1] = it
      end
    end
  end
  if favDirty then
    saveFavorites()
  end

  local rows = {}
  local sections = {
    { items = live, label = "Live" },
    { items = faved, label = "Favourites" },
    { items = rest, label = "Archives" },
  }
  for _, section in ipairs(sections) do
    if #section.items > 0 then
      rows[#rows + 1] = ui.column({ key = "section-" .. section.label, paddingV = 4 }, {
        ui.label({ text = section.label, fontSize = 12, fontWeight = "bold", color = "secondary" }),
      })
    end
    for _, it in ipairs(section.items) do
      local row = {
        ui.button({ key = it.url .. "-play", text = it.name, variant = "ghost", contentAlign = "start", controlSize = "sm", flexGrow = 1, onClick = function()
          play(it.name, it.url)
        end }),
      }
      if it.isArchive and favorites[showKey(it.name)] then
        row[#row + 1] = ui.button({ key = it.url .. "-fav", glyph = "star", tooltip = "Remove from favourites", selected = true, variant = "ghost", controlSize = "sm", onClick = function()
          toggleFavorite(it)
        end })
      end
      table.insert(rows, ui.row({ key = it.url .. "-row", gap = 4, align = "center" }, row))
    end
  end

  local now = noctalia.state.get("now")
  local nowUrl = now and now ~= "" and noctalia.state.get("last_url") or ""
  local headerRow = {
    ui.image({ path = "wfmu.png", width = 24, height = 24, radius = 6 }),
    ui.label({ text = "WFMU", fontSize = 16, fontWeight = "bold", color = "primary", flexGrow = 1 }),
    ui.label({ text = tostring(viewCount) .. " stream" .. (viewCount == 1 and "" or "s"), fontSize = 12 }),
    ui.button({ glyph = "shuffle", variant = "ghost", controlSize = "sm", tooltip = "Play random stream", onClick = "onPlayRandom" }),
  }
  if now and now ~= "" and nowUrl ~= "" and isArchiveUrl(nowUrl) then
    local nowKey = showKey(now)
    headerRow[#headerRow + 1] = ui.button({ key = "fav-now", glyph = "star", tooltip = favorites[nowKey] and "Remove from favourites" or "Add to favourites", selected = favorites[nowKey] ~= nil, variant = "ghost", controlSize = "sm", onClick = function()
      toggleFavorite({ name = now, url = nowUrl })
    end })
  end
  headerRow[#headerRow + 1] = ui.button({ glyph = "refresh", variant = "ghost", controlSize = "sm", tooltip = "Refresh stream list", onClick = "onRefresh" })
  headerRow[#headerRow + 1] = ui.button({ glyph = "close", variant = "ghost", onClick = "onCloseClicked" })

  local children = {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, headerRow),
  }

  if now and now ~= "" then
    local paused = noctalia.state.get("paused") == true
    local row = {
      ui.label({ text = now, flexGrow = 1, maxLines = 1, fontWeight = "bold" }),
      ui.button({ glyph = paused and "player-play" or "player-pause", tooltip = paused and "Resume" or "Pause", variant = "secondary", controlSize = "sm", onClick = "onTogglePause" }),
    }
    if noctalia.state.get("seekable") then
      row[#row + 1] = ui.button({ glyph = "chevron-left", tooltip = "Back 1 min", variant = "secondary", controlSize = "sm", onClick = function()
        seekBy(-60)
      end })
      row[#row + 1] = ui.button({ glyph = "chevron-right", tooltip = "Skip 1 min", variant = "secondary", controlSize = "sm", onClick = function()
        seekBy(60)
      end })
      row[#row + 1] = ui.button({ glyph = "chevrons-right", tooltip = "Skip 3 min", variant = "secondary", controlSize = "sm", onClick = function()
        seekBy(180)
      end })
    end
    row[#row + 1] = ui.button({ glyph = "player-stop", tooltip = "Stop", variant = "destructive", controlSize = "sm", onClick = "onStop" })
    children[#children + 1] = ui.row({ align = "center", gap = 8, padding = 8, fill = "surface_variant/0.5", radius = 8 }, row)
    local np = noctalia.state.get("now_playing")
    if np and np ~= "" then
      children[#children + 1] = ui.label({ text = np, fontSize = 12, maxLines = 1, color = "secondary" })
    end
  end

  children[#children + 1] = ui.input({ key = "search", placeholder = "Filter streams…", onChange = "onSearch", controlSize = "sm", focus = true })

  if refreshing then
    children[#children + 1] = ui.label({ text = "Downloading stream list…", fontSize = 12, color = "secondary" })
  elseif #items == 0 then
    children[#children + 1] = ui.label({ text = "No streams yet — the list downloads automatically, or press refresh.", fontSize = 12, color = "secondary" })
  elseif viewCount == 0 then
    children[#children + 1] = ui.label({ text = "No streams match your filter.", fontSize = 12, color = "secondary" })
  end

  children[#children + 1] = ui.scroll({ flexGrow = 1, gap = 2 }, rows)

  panel.render(ui.column({ padding = 12, gap = 8, flexGrow = 1 }, children))
end

noctalia.state.watch("now", function()
  if open then
    render()
  end
end)

noctalia.state.watch("paused", function()
  if open then
    render()
  end
end)

noctalia.state.watch("now_playing", function()
  if open then
    render()
  end
end)

local function loadList()
  noctalia.readFileAsync(tsv_path, function(contents)
    if contents == nil then
      -- No list yet: show the live streams while the service downloads it.
      items = parseList(LIVE_SEED)
      if not refreshing then
        noctalia.state.set("refresh_requested", true)
      end
      if open then
        render()
      end
      return
    end
    items = parseList(contents)
    migrateLegacyFavorites()
    if open then
      render()
    end
  end)
end

local function refresh()
  noctalia.state.set("refresh_requested", true)
end

noctalia.state.watch("refreshing", function(value)
  refreshing = value == true
  if open then
    render()
  end
end)

noctalia.state.watch("refresh_seq", function()
  if open then
    loadList()
  end
end)

function onSearch(value)
  if value == query then
    return
  end
  query = value
  render()
end

function onStop()
  stopPlayback()
  render()
end

function onTogglePause()
  togglePause()
end

function onRefresh()
  refresh()
end

function onPlayRandom()
  playRandom()
end

function onCloseClicked()
  panel.close()
end

function onIpc(event, _payload)
  if event == "stop" then
    onStop()
  elseif event == "refresh" then
    onRefresh()
  elseif event == "play" then
    local name = noctalia.state.get("last_name")
    local url
    if _payload and _payload ~= "" then
      url = _payload
    else
      url = noctalia.state.get("last_url")
    end
    if url and url ~= "" then
      play(name or "WFMU", url)
    end
  end
end

function onOpen(_context)
  open = true
  query = ""
  loadList()
  render()
end

function onClose()
  open = false
end

function onExit()
  stopPlayback()
end