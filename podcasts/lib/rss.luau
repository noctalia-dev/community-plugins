--!nonstrict
-- Shared podcast helpers: RSS parsing, text cleanup, subscriptions file.
-- Required by panel.luau and finder.luau (plugin_api 22 relative modules).

local M = {}

local function stripCdata(s)
  local inner = string.match(s or "", "^%s*<!%[CDATA%[(.-)%]%]>%s*$")
  if inner ~= nil then
    return inner
  end
  return s or ""
end

local function unescape(s)
  s = s or ""
  s = string.gsub(s, "&#(%d+);", function(n)
    local ok, ch = pcall(utf8.char, tonumber(n) or 0)
    if ok then
      return ch
    end
    return ""
  end)
  s = string.gsub(s, "&#x(%x+);", function(n)
    local ok, ch = pcall(utf8.char, tonumber(n, 16) or 0)
    if ok then
      return ch
    end
    return ""
  end)
  s = string.gsub(s, "&lt;", "<")
  s = string.gsub(s, "&gt;", ">")
  s = string.gsub(s, "&quot;", '"')
  s = string.gsub(s, "&apos;", "'")
  s = string.gsub(s, "&#39;", "'")
  s = string.gsub(s, "&amp;", "&")
  return s
end

function M.cleanText(s)
  s = stripCdata(s)
  s = unescape(s)
  s = string.gsub(s, "%s+", " ")
  return noctalia.string.trim(s)
end

function M.stripTags(s)
  s = stripCdata(s or "")
  s = string.gsub(s, "<[^>]+>", " ")
  return M.cleanText(s)
end

-- "00:37:18" / "37:18" / "3720" -> seconds.
function M.parseDuration(raw)
  raw = noctalia.string.trim(tostring(raw or ""))
  if raw == "" then
    return 0
  end
  if string.match(raw, "^%d+$") then
    return tonumber(raw) or 0
  end
  local h, m, s = string.match(raw, "^(%d+):(%d+):(%d+)$")
  if h then
    return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s)
  end
  local mm, ss = string.match(raw, "^(%d+):(%d+)$")
  if mm then
    return tonumber(mm) * 60 + tonumber(ss)
  end
  return 0
end

-- 3720 -> "1:02:00", 754 -> "12:34", for player positions.
function M.clock(secs)
  secs = math.max(0, math.floor(tonumber(secs) or 0))
  local h = math.floor(secs / 3600)
  local m = math.floor((secs % 3600) / 60)
  local s = secs % 60
  if h > 0 then
    return string.format("%d:%02d:%02d", h, m, s)
  end
  return string.format("%d:%02d", m, s)
end

-- 3720 -> "1h 2m", 754 -> "12m", 45 -> "45s".
function M.fmtDuration(secs)
  secs = math.floor(tonumber(secs) or 0)
  if secs <= 0 then
    return ""
  end
  local h = math.floor(secs / 3600)
  local m = math.floor((secs % 3600) / 60)
  if h > 0 then
    return string.format("%dh %dm", h, m)
  end
  if m > 0 then
    return string.format("%dm", m)
  end
  return string.format("%ds", secs)
end

-- "Tue, 15 Sep 2026 08:00:00 +0000" -> "15 Sep 2026".
function M.shortDate(raw)
  local d = string.match(tostring(raw or ""), "%a+, (%d+ %a+ %d+)")
  if d then
    return d
  end
  return ""
end

-- Plain-text tag extraction: zero pattern backtracking, safe on big inputs.
-- Returns cleaned text, or raw substring when raw=true.
local function tagText(block, name, fallback, raw)
  local s, e = string.find(block, "<" .. name .. ">", 1, true)
  if not s then
    return fallback or ""
  end
  local se = string.find(block, "</" .. name .. ">", e + 1, true)
  if not se then
    return fallback or ""
  end
  local inner = string.sub(block, e + 1, se - 1)
  if raw then
    return inner
  end
  return M.cleanText(inner)
end

-- Parse at most `maxItems` episodes from an RSS string.
-- Episode: { title, url, secs, dur, date, desc }.
function M.parseFeed(xml, maxItems)
  local eps = {}
  if type(xml) ~= "string" or xml == "" then
    return eps, ""
  end
  -- Feeds can be megabytes (hundreds of old episodes). We only ever show
  -- the newest handful, so parse a head prefix; item scan below stops at
  -- the first incomplete tail automatically.
  if #xml > 400000 then
    xml = string.sub(xml, 1, 400000)
  end
  maxItems = math.min(math.floor(tonumber(maxItems) or 10), 50)
  local channelTitle = ""
  local cs = string.find(xml, "<channel>", 1, true)
  if cs then
    channelTitle = tagText(string.sub(xml, cs, cs + 3000), "title", "")
  end
  local pos = 1
  while #eps < maxItems do
    local s, e = string.find(xml, "<item>", pos, true)
    if not s then
      break
    end
    local se, ee = string.find(xml, "</item>", e + 1, true)
    if not se then
      break
    end
    local block = string.sub(xml, e + 1, se - 1)
    pos = ee + 1
    -- Enclosure URL: bound the attribute scan to the tag itself.
    local url = nil
    local es = string.find(block, "<enclosure", 1, true)
    if es then
      local tagEnd = string.find(block, ">", es, true)
      if tagEnd and tagEnd - es < 2000 then
        url = string.match(string.sub(block, es, tagEnd), 'url="([^"]+)"')
      end
    end
    if url and url ~= "" then
      local durRaw = tagText(block, "itunes:duration", "")
      if durRaw == "" then
        durRaw = tagText(block, "duration", "")
      end
      local secs = M.parseDuration(durRaw)
      local descRaw = tagText(block, "description", "", true)
      if #descRaw > 4000 then
        descRaw = string.sub(descRaw, 1, 4000)
      end
      local desc = M.stripTags(descRaw)
      if #desc > 140 then
        desc = string.sub(desc, 1, 140) .. "..."
      end
      local title = tagText(block, "title", "")
      if title == "" then
        title = "Untitled episode"
      end
      table.insert(eps, {
        title = title,
        url = unescape(url),
        secs = secs,
        dur = M.fmtDuration(secs),
        date = M.shortDate(tagText(block, "pubDate", "")),
        desc = desc,
      })
    end
  end
  return eps, channelTitle
end

function M.subsPath()
  return noctalia.pluginDataDir() .. "/subscriptions.json"
end

function M.loadSubs()
  local raw = noctalia.readFile(M.subsPath())
  if not raw then
    return {}
  end
  local data = noctalia.json.decode(raw)
  if type(data) == "table" then
    return data
  end
  return {}
end

function M.saveSubs(subs)
  noctalia.writeFile(M.subsPath(), noctalia.json.encode(subs) or "[]")
  noctalia.state.set("pod_subs", subs)
end

-- Effective subscriptions: settings feeds (plain URLs) plus panel-added ones.
-- Entry: { title, feed, art } where art is an artwork URL or "".
function M.allSubs()
  local out = {}
  local seen = {}
  local cfg = noctalia.getConfig("podcast_feeds")
  if type(cfg) == "table" then
    for _, u in ipairs(cfg) do
      if type(u) == "string" and u ~= "" and not seen[u] then
        seen[u] = true
        table.insert(out, { title = u, feed = u, art = "" })
      end
    end
  end
  for _, s in ipairs(M.loadSubs()) do
    if type(s) == "table" and s.feed and s.feed ~= "" and not seen[s.feed] then
      seen[s.feed] = true
      table.insert(out, { title = s.title or s.feed, feed = s.feed, art = s.art or "" })
    end
  end
  return out
end

function M.artPath(key)
  local safe = string.gsub(tostring(key or ""), "[^%w]", "")
  if #safe > 40 then
    safe = string.sub(safe, 1, 40)
  end
  if safe == "" then
    safe = "feed"
  end
  return noctalia.pluginDataDir() .. "/art/" .. safe .. ".jpg"
end

return M
