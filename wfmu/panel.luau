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

-- The Archives and Favorites sections can be listed A-Z (the default, and how
-- the fetcher writes the list) or newest-first.
local sort_path = data_dir .. "/sort.txt"
local sortMode = "name"

-- Wording for the archive-sort tooltip: the current mode, then the count of
-- streams it is sorting.
local SORT_OPTIONS = { "A-Z", "Latest" }

local function showKey(name)
  local k = noctalia.string.trim((name or ""):gsub("%s*%b()%s*$", ""))
  return string.lower(k)
end

-- WFMU's own stream titles read "<Show> from <date>" ("Flot's Spot from
-- 10/16/2026"); shave the date off so the now-playing line reads as a track
-- name. Keep in sync with stripDate() in widget.luau.
local function stripDate(text)
  local t = text or ""
  t = t:gsub("%s*%b()%s*$", " ")
  t = t:gsub("%s*[Ff]rom%s+[^%d]*%d[%d%p%s:-]*$", " ")
  do
    local lower = string.lower(t)
    for _, m in ipairs({ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" }) do
      local match = lower:match("%s+" .. m .. "[a-z]*%s+%d%d?,?%s*%d%d%d%d%s*$")
      if match then
        -- The match is a plain-ASCII date suffix, so its byte length is the same
        -- in the original; cut it off instead of replacing the value with its
        -- lowercased form, which would lowercase the show name as well.
        t = t:sub(1, #t - #match)
        break
      end
    end
  end
  t = t:gsub("%s*[%-–—:]?%s*%d%d%d%d%-%d%d%-%d%d%s*$", " ")
  t = t:gsub("%s*[%-–—:]?%s*%d?%d/%d?%d/%d%d%d%d%s*$", " ")
  t = t:gsub("%s+", " ")
  return noctalia.string.trim(t)
end

local function loadFavorites()
  local raw = noctalia.readFile(favorites_path)
  if raw then
    local ok, data = pcall(noctalia.json.decode, raw)
    if ok and type(data) == "table" then
      favorites = data
    end
  end
end

local function saveFavorites()
  noctalia.writeFile(favorites_path, noctalia.json.encode(favorites, true))
end

local function loadSortMode()
  local raw = noctalia.readFile(sort_path)
  if raw and noctalia.string.trim(raw) == "date" then
    sortMode = "date"
  end
end

local function setSortMode(mode)
  if mode ~= "date" then
    mode = "name"
  end
  if mode == sortMode then
    return
  end
  sortMode = mode
  noctalia.writeFile(sort_path, mode .. "\n")
  render()
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
loadSortMode()

local function stopPlayback()
  if pid_file ~= "" then
    noctalia.runAsync(string.format(
      "if [ -f %s ]; then kill $(cat %s) 2>/dev/null; rm -f %s; fi; rm -f %s",
      shq(pid_file), shq(pid_file), shq(pid_file), shq(ipc_sock)))
  end
  noctalia.state.set("now", nil)
  noctalia.state.set("now_playing", nil)
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
      -- The fetcher writes "<label>\t<url>" and appends an ordering stamp as a
      -- third column for archives. Older lists, and the live seed, only have two.
      local url, aired = string.match(line:sub(tab + 1), "^([^\t]*)\t?(.*)$")
      url = noctalia.string.trim(url or "")
      if url ~= "" then
        out[#out + 1] = {
          name = name,
          nameLower = string.lower(name),
          url = url,
          aired = noctalia.string.trim(aired or ""),
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
  math.randomseed(os.time())
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

  -- Both the Favorites and Archives sections follow the sort picked in the
  -- heading row. Name order is applied explicitly rather than relying on the
  -- order the fetcher happened to write the list in.
  local function byName(a, b)
    return a.nameLower < b.nameLower
  end
  -- "Newest first" sorts on the ordering stamp the fetcher appends to archive
  -- lines: the day the feed says the show aired, a space, then the instant its
  -- archive was published ("2026-10-16 2026-10-17T04:14:53Z"). The day half
  -- keeps a show inside the day it aired; the publish half puts same-day shows
  -- in the order they went out and keeps a late-night show (published just
  -- after midnight) at the end of its day rather than the start. It is a
  -- plain string compare. Lines with no stamp (live streams, a list fetched by
  -- an older version) sort last.
  local function byDate(a, b)
    if a.aired ~= b.aired then
      return a.aired > b.aired
    end
    return a.nameLower < b.nameLower
  end
  local order = sortMode == "date" and byDate or byName
  table.sort(faved, order)
  table.sort(rest, order)

  local rows = {}
  local sections = {
    { items = live, label = "Live" },
    { items = faved, label = "Favorites" },
    { items = rest, label = "Archives" },
  }
  for _, section in ipairs(sections) do
    if #section.items > 0 then
      local heading = {
        ui.label({ text = section.label, flexGrow = 1, fontSize = 12, fontWeight = "bold", color = "secondary" }),
      }
      rows[#rows + 1] = ui.row({ key = "section-" .. section.label, align = "center", gap = 8, paddingV = 4 }, heading)
    end
    for _, it in ipairs(section.items) do
      local row = {
        ui.button({ key = it.url .. "-play", text = it.name, variant = "ghost", contentAlign = "start", controlSize = "sm", flexGrow = 1, onClick = function()
          play(it.name, it.url)
        end }),
      }
      table.insert(rows, ui.row({ key = it.url .. "-row", gap = 4, align = "center" }, row))
    end
  end

  local now = noctalia.state.get("now")
  local nowUrl = now and now ~= "" and noctalia.state.get("last_url") or ""
  local headerRow = {
    ui.image({ path = "wfmu.png", width = 24, height = 24, radius = 6, tooltip = "Open wfmu.org", onClick = "onOpenSite" }),
    ui.label({ text = "WFMU", fontSize = 16, fontWeight = "bold", color = "primary", flexGrow = 1 }),
  }
  -- Favorite star for the playing archive, leftmost of the icon cluster.
  if now and now ~= "" and nowUrl ~= "" and isArchiveUrl(nowUrl) then
    local nowKey = showKey(now)
    headerRow[#headerRow + 1] = ui.button({ key = "fav-now", glyph = "star", tooltip = favorites[nowKey] and "Remove from favorites" or "Add to favorites", selected = favorites[nowKey] ~= nil, variant = "ghost", controlSize = "sm", onClick = function()
      toggleFavorite({ name = now, url = nowUrl })
    end })
  end
  -- Archive sort toggle: a clock while the list runs newest first, an A-Z
  -- while it is alphabetical. Buttons are plain callbacks - a ui.select here
  -- re-fired onChange on every render until the shell disabled the panel. The
  -- stream count lives in its tooltip rather than as its own label.
  headerRow[#headerRow + 1] = ui.button({
    key = "archives-sort",
    glyph = sortMode == "date" and "clock" or "sort-a-z",
    variant = "ghost",
    controlSize = "sm",
    tooltip = (sortMode == "date" and SORT_OPTIONS[2] or SORT_OPTIONS[1])
      .. " - " .. tostring(viewCount) .. " stream" .. (viewCount == 1 and "" or "s"),
    onClick = function()
      setSortMode(sortMode == "date" and "name" or "date")
    end,
  })
  headerRow[#headerRow + 1] = ui.button({ glyph = "shuffle", variant = "ghost", controlSize = "sm", tooltip = "Play random stream", onClick = "onPlayRandom" })
  headerRow[#headerRow + 1] = ui.button({ glyph = "refresh", variant = "ghost", controlSize = "sm", tooltip = "Refresh stream list", onClick = "onRefresh" })
  headerRow[#headerRow + 1] = ui.button({ glyph = "close", variant = "ghost", onClick = "onCloseClicked" })

  local children = {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, headerRow),
  }

  if now and now ~= "" then
    local paused = noctalia.state.get("paused") == true
    local row = {
      ui.label({ text = now, flexGrow = 1, maxLines = 1, fontWeight = "bold" }),
      ui.button({ glyph = paused and "player-play" or "player-pause", tooltip = paused and "Resume" or "Pause", variant = "ghost", controlSize = "sm", onClick = "onTogglePause" }),
    }
    if noctalia.state.get("seekable") then
      row[#row + 1] = ui.button({ glyph = "chevron-left", tooltip = "1 min (left-click)\n3 min (right-click)", variant = "ghost", controlSize = "sm", onClick = function()
        seekBy(-60)
      end, onRightClick = function()
        seekBy(-180)
      end })
      row[#row + 1] = ui.button({ glyph = "chevron-right", tooltip = "1 min (left-click)\n3 min (right-click)", variant = "ghost", controlSize = "sm", onClick = function()
        seekBy(60)
      end, onRightClick = function()
        seekBy(180)
      end })
    end
    row[#row + 1] = ui.button({ glyph = "player-stop", tooltip = "Stop", variant = "ghost", controlSize = "sm", onClick = "onStop" })
    children[#children + 1] = ui.row({ align = "center", gap = 8, padding = 8, radius = 8 }, row)
    -- mpv reports the stream name again when it has no song metadata (common on
    -- the live streams); show that line once rather than twice.
    local np = stripDate(noctalia.state.get("now_playing"))
    if np ~= "" and string.lower(np) ~= string.lower(stripDate(now)) then
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

-- Clicking the WFMU logo in the header opens the station's website.
function onOpenSite()
  noctalia.runAsync({ "xdg-open", "https://wfmu.org/" })
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