--!nonstrict
-- Launcher provider: /podcast <text> searches subscriptions and iTunes.
-- Activating a podcast drills in (query set, stays open); episodes listed
-- inside play on activate.

local rss = require("./lib/rss.luau")
local pi = require("./lib/pi.luau")

local ITUNES = "https://itunes.apple.com/search?media=podcast&entity=podcast"

local knownEps = {}
local knownSubs = {}
local epCache = {}

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

local function epLimit()
  return math.clamp(math.floor(tonumber(noctalia.getConfig("search_limit")) or 10), 3, 30)
end

local function subForTitle(title)
  for _, s in ipairs(rss.allSubs()) do
    if s.title == title then
      return s
    end
  end
  return nil
end

local function epRow(podcast, ep, score)
  local id = "ep:" .. tostring(#knownEps + 1)
  knownEps[id] = { podcast = podcast, ep = ep }
  local sub = ep.date
  if ep.dur ~= "" then
    sub = (sub ~= "" and (sub .. " - ") or "") .. ep.dur
  end
  return {
    id = id,
    title = ep.title,
    subtitle = (sub ~= "" and (sub .. " - ") or "") .. "Enter to play",
    glyph = "player-play",
    score = score,
  }
end

local function fetchRss(sub, filter, text)
  noctalia.http({ url = sub.feed }, function(res)
    if not res.ok then
      return
    end
    local eps = rss.parseFeed(res.body, epLimit())
    epCache[sub.feed] = eps
    local rows = {}
    for _, ep in ipairs(eps) do
      if filter == "" or noctalia.fuzzyScore(filter, ep.title) ~= nil then
        table.insert(rows, epRow(sub.title, ep, 50))
      end
    end
    if #rows == 0 then
      rows[1] = { id = "", title = "No episodes match", glyph = "mood-empty" }
    end
    launcher.setResults(text, rows)
  end)
end

function onQuery(text)
  local q = noctalia.string.trim(tostring(text or ""))
  local limit = epLimit()
  -- Drill-in: "Exact Podcast Title <filter>" lists that podcast's episodes.
  for _, s in ipairs(rss.allSubs()) do
    local head = s.title .. " "
    if string.sub(q, 1, #head) == head then
      local filter = noctalia.string.trim(string.sub(q, #head + 1))
      local cached = epCache[s.feed]
      if cached then
        local rows = {}
        for _, ep in ipairs(cached) do
          if filter == "" or noctalia.fuzzyScore(filter, ep.title) ~= nil then
            table.insert(rows, epRow(s.title, ep, 50))
          end
        end
        if #rows == 0 then
          rows[1] = { id = "", title = "No episodes match", glyph = "mood-empty" }
        end
        launcher.setResults(text, rows)
      else
        launcher.setResults(text, { { id = "", title = "Fetching " .. s.title .. "...", glyph = "loader" } })
        fetchRss(s, filter, text)
      end
      return
    end
  end

  -- Top level: subscribed podcasts (drill-in) + iTunes search.
  local rows = {}
  for i, s in ipairs(rss.allSubs()) do
    if q == "" or noctalia.fuzzyScore(q, s.title) ~= nil then
      local id = "sub:" .. tostring(i)
      knownSubs[id] = s
      table.insert(rows, {
        id = id,
        title = s.title,
        subtitle = "Open episodes - Enter to browse",
        glyph = "rss",
        score = 100,
      })
    end
  end
  if q == "" then
    if #rows == 0 then
      rows[1] = { id = "", title = "Type to search iTunes podcasts", subtitle = "Added feeds appear here", glyph = "rss" }
    end
    launcher.setResults(text, rows)
    return
  end
  table.insert(rows, { id = "", title = "Searching for '" .. q .. "'...", glyph = "loader" })
  launcher.setResults(text, rows)

  -- Async: iTunes plus Podcast Index (when configured), merged by feed.
  local seen = {}
  local combined = {}
  local pending = 1
  local myq = q
  local mytext = text
  if pi.configured() then
    pending = 2
  end
  local function collect(list, baseScore)
    if not list then
      return
    end
    for _, r in ipairs(list) do
      if not seen[r.feed] then
        seen[r.feed] = true
        table.insert(combined, r)
        r.score = baseScore - #combined
      end
    end
  end
  local function publish()
    pending = pending - 1
    if pending > 0 then
      return
    end
    local fresh = {}
    for _, s in ipairs(rss.allSubs()) do
      if noctalia.fuzzyScore(myq, s.title) ~= nil then
        local id = "sub:" .. s.feed
        knownSubs[id] = s
        table.insert(fresh, {
          id = id,
          title = s.title,
          subtitle = "Open episodes - Enter to browse",
          glyph = "rss",
          score = 100,
        })
      end
    end
    local n = 0
    for _, r in ipairs(combined) do
      n = n + 1
      local id = "add:" .. tostring(n)
      knownSubs[id] = {
        title = r.title,
        feed = r.feed,
        art = r.art or "",
      }
      table.insert(fresh, {
        id = id,
        title = r.title,
        subtitle = (r.artist or "") .. " - Enter to subscribe",
        glyph = "plus",
        score = r.score or 0,
      })
      if n >= limit then
        break
      end
    end
    if #fresh == 0 then
      fresh[1] = { id = "", title = "No podcasts found for '" .. myq .. "'", glyph = "mood-empty" }
    end
    launcher.setResults(mytext, fresh)
  end
  noctalia.http({
    url = ITUNES .. "&term=" .. noctalia.string.urlEncode(q) .. "&limit=" .. tostring(limit),
  }, function(res)
    if res.ok then
      local data = noctalia.json.decode(res.body)
      if type(data) == "table" and type(data.results) == "table" then
        local out = {}
        for _, r in ipairs(data.results) do
          if type(r) == "table" and r.feedUrl and r.feedUrl ~= "" then
            table.insert(out, {
              title = r.collectionName or "Unknown podcast",
              artist = r.artistName or "",
              feed = r.feedUrl,
              art = r.artworkUrl100 or "",
            })
          end
        end
        collect(out, 50)
      end
    end
    publish()
  end)
  if pi.configured() then
    pi.search(q, limit, function(list)
      collect(list, 40)
      publish()
    end)
  end
end

function onActivate(id)
  if id == "" or id == nil then
    return
  end
  if knownEps[id] then
    local e = knownEps[id]
    request("play", { podcast = e.podcast, episode = e.ep.title, url = e.ep.url })
    noctalia.notify("Podcasts", "Playing " .. e.ep.title)
    return
  end
  local sub = knownSubs[id]
  if sub then
    if string.sub(id, 1, 4) == "add:" then
      local current = rss.loadSubs()
      table.insert(current, { title = sub.title, feed = sub.feed, art = sub.art or "" })
      rss.saveSubs(current)
      noctalia.notify("Podcasts", "Subscribed to " .. sub.title)
      launcher.setQuery(sub.title .. " ")
    else
      launcher.setQuery(sub.title .. " ")
    end
  end
end
