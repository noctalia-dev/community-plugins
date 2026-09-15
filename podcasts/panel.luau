--!nonstrict
-- Browser panel: subscriptions, episode lists, iTunes discovery.
-- Playback is owned by the [[service]] (player.luau): this panel publishes
-- requests to shared state and mirrors status back.

local rss = require("./lib/rss.luau")
local pi = require("./lib/pi.luau")

local ITUNES = "https://itunes.apple.com/search?media=podcast&entity=podcast"

local query = ""
local selectedFeed = ""
local episodes = {}
local epCache = {}
local subs = {}
local discover = {}
local artFiles = {}
local status = noctalia.state.get("pod_status") or { playing = false, podcast = "", episode = "", url = "", volume = 70, pos = 0, dur = 0 }
local loading = false
local errorMsg = ""
local open = false

local function epLimit()
  return math.clamp(math.floor(tonumber(noctalia.getConfig("search_limit")) or 10), 3, 30)
end

local function request(action, extra)
  local prev = noctalia.state.get("pod_request")
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
  noctalia.state.set("pod_request", req)
end

local function refreshSubs()
  subs = rss.allSubs()
  noctalia.state.set("pod_subs", subs)
end

local function subTitle(feed)
  for _, s in ipairs(subs) do
    if s.feed == feed then
      return s.title or feed
    end
  end
  return feed
end

local function ensureArt(sub)
  if not sub or not sub.art or sub.art == "" then
    return nil
  end
  local dest = rss.artPath(sub.feed)
  if not noctalia.fileExists(dest) then
    noctalia.mkdirAll(noctalia.pluginDataDir() .. "/art")
    noctalia.download(sub.art, dest, function(_)
      render()
    end)
    return nil
  end
  return dest
end

local function fetchEpisodes(feed)
  loading = true
  errorMsg = ""
  render()
  noctalia.http({ url = feed }, function(res)
    loading = false
    if not res.ok then
      errorMsg = "Could not fetch feed"
      render()
      return
    end
    local eps, channelTitle = rss.parseFeed(res.body, epLimit())
    if channelTitle ~= "" then
      for _, s in ipairs(subs) do
        if s.feed == feed and (s.title == feed or s.title == "") then
          s.title = channelTitle
        end
      end
    end
    epCache[feed] = eps
    if selectedFeed == feed then
      episodes = eps
      if #episodes == 0 then
        errorMsg = "No playable episodes in this feed"
      end
    end
    render()
  end)
end

local function selectFeed(feed)
  selectedFeed = feed
  local cached = epCache[feed]
  if cached then
    episodes = cached
    render()
  else
    fetchEpisodes(feed)
  end
end

-- Discover across iTunes plus Podcast Index (when its key is set).
-- Both run in parallel; results merge deduped by feed URL as each lands.
local function searchDiscover(q)
  loading = true
  errorMsg = ""
  discover = {}
  render()
  local limit = epLimit()
  local myq = q
  local merged = {}
  local pending = 1
  local piOn = pi.configured()
  if piOn then
    pending = 2
  end
  local function done()
    pending = pending - 1
    if pending > 0 then
      return
    end
    if query ~= myq then
      return
    end
    discover = {}
    for _, e in pairs(merged) do
      table.insert(discover, e)
    end
    table.sort(discover, function(a, b)
      return (a.score or 0) > (b.score or 0)
    end)
    loading = false
    if #discover == 0 then
      errorMsg = "No podcasts found"
    end
    render()
  end
  noctalia.http({
    url = ITUNES .. "&term=" .. noctalia.string.urlEncode(q) .. "&limit=" .. tostring(limit),
  }, function(res)
    if query ~= myq then
      return
    end
    if res.ok then
      local data = noctalia.json.decode(res.body)
      if type(data) == "table" and type(data.results) == "table" then
        for _, r in ipairs(data.results) do
          if type(r) == "table" and r.feedUrl and r.feedUrl ~= "" and not merged[r.feedUrl] then
            merged[r.feedUrl] = {
              title = r.collectionName or "Unknown podcast",
              artist = r.artistName or "",
              feed = r.feedUrl,
              art = r.artworkUrl100 or r.artworkUrl60 or "",
              count = tonumber(r.trackCount) or 0,
              score = 50,
            }
          end
        end
      end
    end
    done()
  end)
  if piOn then
    pi.search(q, limit, function(list)
      if query ~= myq then
        return
      end
      if list then
        for _, e in ipairs(list) do
          if not merged[e.feed] then
            e.score = 40
            merged[e.feed] = e
          end
        end
      end
      done()
    end)
  end
end

local function searchItunes(q)
  searchDiscover(q)
end

local function isSubbed(feed)
  for _, s in ipairs(rss.loadSubs()) do
    if s.feed == feed then
      return true
    end
  end
  local cfg = noctalia.getConfig("podcast_feeds")
  if type(cfg) == "table" then
    for _, u in ipairs(cfg) do
      if u == feed then
        return true
      end
    end
  end
  return false
end

function toggleSub(title, feed, art)
  local current = rss.loadSubs()
  for i, s in ipairs(current) do
    if s.feed == feed then
      table.remove(current, i)
      rss.saveSubs(current)
      refreshSubs()
      render()
      return
    end
  end
  table.insert(current, { title = title, feed = feed, art = art or "" })
  rss.saveSubs(current)
  refreshSubs()
  local sub = { title = title, feed = feed, art = art or "" }
  ensureArt(sub)
  selectFeed(feed)
  render()
end

function addFeedUrl(url)
  url = noctalia.string.trim(tostring(url or ""))
  if url == "" then
    return
  end
  if not string.match(url, "^https?://") then
    url = "https://" .. url
  end
  if isSubbed(url) then
    selectFeed(url)
    return
  end
  local current = rss.loadSubs()
  table.insert(current, { title = url, feed = url, art = "" })
  rss.saveSubs(current)
  refreshSubs()
  selectFeed(url)
end

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

local function epRow(podcast, ep)
  local playing = status.playing and status.url ~= "" and status.url == ep.url
  local sub = ep.date
  if ep.dur ~= "" then
    sub = (sub ~= "" and (sub .. "  •  ") or "") .. ep.dur
  end
  return ui.row({ key = "ep-" .. ep.url, gap = 10, align = "center" }, {
    ui.button({
      glyph = playing and "player-stop-filled" or "player-play-filled",
      variant = playing and "primary" or "ghost",
      controlSize = "sm",
      tooltip = playing and "Stop" or "Play",
      onClick = function()
        if playing then
          request("stop")
        else
          request("play", { podcast = podcast, episode = ep.title, url = ep.url })
        end
      end,
    }),
    ui.column({ flexGrow = 1, gap = 1 }, {
      ui.label({ text = ep.title, maxLines = 1, fontWeight = playing and "semibold" or "normal", color = playing and "primary" or "on_surface" }),
      ui.label({ text = sub, fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
    }),
  })
end

local function subRow(sub)
  local selected = selectedFeed == sub.feed
  return ui.row({ key = "sub-" .. sub.feed, gap = 10, align = "center" }, {
    ui.button({
      glyph = selected and "eye" or "rss",
      variant = selected and "primary" or "ghost",
      controlSize = "sm",
      tooltip = sub.title,
      onClick = function()
        selectFeed(sub.feed)
      end,
    }),
    ui.column({ flexGrow = 1, gap = 0 }, {
      ui.label({
        text = sub.title,
        maxLines = 1,
        fontWeight = selected and "semibold" or "normal",
        color = selected and "primary" or "on_surface",
      }),
    }),
    ui.button({
      glyph = "x",
      variant = "ghost",
      controlSize = "sm",
      tooltip = "Remove",
      onClick = function()
        removeSub(sub.feed)
      end,
    }),
  })
end

function removeSub(feed)
  local current = rss.loadSubs()
  local kept = {}
  local removed = false
  for _, s in ipairs(current) do
    if s.feed == feed then
      removed = true
    else
      table.insert(kept, s)
    end
  end
  if removed then
    rss.saveSubs(kept)
  end
  refreshSubs()
  if selectedFeed == feed then
    selectedFeed = ""
    episodes = {}
  end
  render()
end

local function discoverRow(d)
  local sub = d.artist
  if d.count > 0 then
    sub = (sub ~= "" and (sub .. "  •  ") or "") .. tostring(d.count) .. " episodes"
  end
  return ui.row({ key = "disc-" .. d.feed, gap = 10, align = "center" }, {
    ui.column({ flexGrow = 1, gap = 1 }, {
      ui.label({ text = d.title, maxLines = 1 }),
      ui.label({ text = sub, fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
    }),
    ui.button({
      text = isSubbed(d.feed) and "Added" or "Add",
      variant = isSubbed(d.feed) and "ghost" or "secondary",
      controlSize = "sm",
      enabled = not isSubbed(d.feed),
      onClick = function()
        toggleSub(d.title, d.feed, d.art)
      end,
    }),
  })
end

function onSearchInput(value)
  query = tostring(value or "")
end

function onSearchSubmit(value)
  query = noctalia.string.trim(tostring(value or ""))
  if query == "" then
    return
  end
  if string.match(query, "^https?://") or string.match(query, "^[%w%.%-]+%.[%a]+/") then
    addFeedUrl(query)
  else
    searchItunes(query)
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

function onSeek(value)
  local v = math.max(0, math.floor(tonumber(value) or 0))
  status.pos = v
  request("seek", { pos = v })
  render()
end

function onTogglePlaying()
  if status.playing and not status.paused then
    request("pause")
  elseif status.playing and status.paused then
    request("resume")
  elseif status.url ~= "" then
    request("play", { podcast = status.podcast, episode = status.episode, url = status.url })
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
  local nowName = status.episode ~= "" and status.episode or "Nothing playing"
  local nowSpec = "PICK AN EPISODE BELOW"
  if status.playing and status.paused then
    nowSpec = "PAUSED" .. (status.podcast ~= "" and ("  •  " .. status.podcast) or "")
  elseif status.playing then
    nowSpec = "ON AIR" .. (status.podcast ~= "" and ("  •  " .. status.podcast) or "")
  elseif status.episode ~= "" then
    nowSpec = "STOPPED"
  end

  local artNode = ui.glyph({ name = "rss", size = 20, color = "primary" })
  for _, s in ipairs(subs) do
    if status.playing and s.title == status.podcast and s.art ~= "" then
      local p = rss.artPath(s.feed)
      if noctalia.fileExists(p) then
        artNode = ui.image({ path = p, width = 40, height = 40, radius = 8, fit = "cover" })
      end
      break
    end
  end

  local body = {
    ui.column({ gap = 10, fill = "surface_variant/0.55", radius = 18, padding = 16 }, {
      ui.row({ gap = 10, align = "center" }, {
        artNode,
        ui.column({ flexGrow = 1, gap = 1 }, {
          ui.label({ text = nowName, fontSize = 15, fontWeight = "bold", maxLines = 1 }),
          ui.label({ text = nowSpec, fontSize = 11, fontWeight = "medium", color = status.playing and "primary" or "on_surface_variant", maxLines = 1 }),
        }),
        ui.button({
          glyph = (status.playing and not status.paused) and "player-stop-filled" or "player-play-filled",
          glyphSize = 22,
          variant = "primary",
          controlSize = "lg",
          enabled = status.url ~= "",
          tooltip = (status.playing and not status.paused) and "Pause" or "Play",
          onClick = "onTogglePlaying",
        }),
      }),
      ui.graph({ values = eqValues(), color = "primary", fillOpacity = 0.35, height = 42 }),
      ui.row({ gap = 8, align = "center" }, {
        ui.label({ text = rss.clock(status.pos), fontSize = 11, color = "on_surface_variant", width = 46 }),
        ui.slider({
          min = 0,
          max = (tonumber(status.dur) or 0) > 0 and math.floor(tonumber(status.dur)) or 1,
          step = 1,
          value = math.clamp(math.floor(tonumber(status.pos) or 0), 0, (tonumber(status.dur) or 0) > 0 and math.floor(tonumber(status.dur)) or 1),
          flexGrow = 1,
          controlSize = "sm",
          enabled = (tonumber(status.dur) or 0) > 0 and status.url ~= "",
          onChange = "onSeek",
        }),
        ui.label({ text = rss.clock(status.dur), fontSize = 11, color = "on_surface_variant", width = 46, textAlign = "end" }),
      }),
      ui.row({ gap = 10, align = "center" }, {
        ui.glyph({ name = "volume-2", size = 15, color = "on_surface_variant" }),
        ui.slider({ min = 0, max = 100, step = 1, value = tonumber(status.volume) or 70, flexGrow = 1, controlSize = "sm", onChange = "onVolume" }),
        ui.label({ text = tostring(tonumber(status.volume) or 70) .. "%", fontSize = 12, color = "on_surface_variant", width = 40, textAlign = "end" }),
      }),
    }),
    ui.row({ gap = 8, align = "center" }, {
      ui.input({ key = "search", placeholder = "Search podcasts or paste feed URL...", flexGrow = 1, onChange = "onSearchInput", onSubmit = "onSearchSubmit" }),
      ui.button({ glyph = "search", variant = "secondary", controlSize = "sm", tooltip = "Search", onClick = "onSearchClicked" }),
    }),
  }

  if not pi.configured() then
    table.insert(body, ui.label({ text = "Tip: a Podcast Index key in plugin settings widens search.", fontSize = 11, color = "on_surface_variant" }))
  end

  if #discover > 0 then
    table.insert(body, ui.label({ text = "DISCOVER", fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }))
    for _, d in ipairs(discover) do
      table.insert(body, discoverRow(d))
    end
    table.insert(body, ui.separator({ spacing = 4 }))
  end

  if #subs > 0 then
    table.insert(body, ui.label({ text = "SUBSCRIPTIONS", fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }))
    for _, s in ipairs(subs) do
      table.insert(body, subRow(s))
    end
    table.insert(body, ui.separator({ spacing = 4 }))
  elseif #discover == 0 and not loading then
    table.insert(body, ui.label({ text = "No subscriptions yet - search above or paste a feed URL.", color = "on_surface_variant" }))
  end

  if selectedFeed ~= "" then
    table.insert(body, ui.label({ text = "EPISODES  •  " .. string.upper(string.sub(subTitle(selectedFeed), 1, 24)), fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }))
    if loading then
      table.insert(body, ui.label({ text = "Fetching episodes...", color = "on_surface_variant" }))
    elseif errorMsg ~= "" and #episodes == 0 then
      table.insert(body, ui.label({ text = errorMsg, color = "on_surface_variant" }))
    else
      for _, ep in ipairs(episodes) do
        table.insert(body, epRow(subTitle(selectedFeed), ep))
      end
    end
  end

  if loading and selectedFeed == "" and #discover == 0 then
    table.insert(body, ui.label({ text = "Searching...", color = "on_surface_variant" }))
  elseif errorMsg ~= "" and selectedFeed == "" and #discover == 0 then
    table.insert(body, ui.label({ text = errorMsg, color = "on_surface_variant" }))
  end

  panel.render(ui.column({ flexGrow = 1, gap = 14 }, {
    ui.row({ align = "center", gap = 8 }, {
      ui.label({ text = "Podcasts", fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
      ui.button({ glyph = "close", variant = "ghost", controlSize = "sm", onClick = "onCloseClicked" }),
    }),
    ui.scroll({ flexGrow = 1, gap = 12 }, body),
  }))
end

noctalia.state.watch("pod_status", function(value)
  if type(value) == "table" then
    status = value
    render()
  end
end)

noctalia.state.watch("pod_subs", function(value)
  if type(value) == "table" then
    refreshSubs()
    render()
  end
end)

function update()
  render()
end

function onOpen(_context)
  open = true
  panel.setWantsSecondTicks(true)
  refreshSubs()
  if selectedFeed == "" and #subs > 0 then
    selectFeed(subs[1].feed)
  else
    render()
  end
end

function onClose()
  open = false
end
