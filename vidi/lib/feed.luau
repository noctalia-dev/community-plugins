local Feed = {}

local CACHE_PATH = "~/.cache/vidi/feed_cache.json"
local THUMB_DIR = "~/.cache/vidi/preview_images"
local STATE_KEY = "feed_cache"
local PENDING_KEY = "feed_refresh_pending"

local JQ_FILTER = [[
  {cached_at: .cached_at,
   videos: ([.videos[] | {id, title, url, channel, duration_string, view_count, timestamp, is_short}]
            | sort_by(-(.timestamp // 0))[:120])}
]]

local function toBool(value)
  return value == true or value == "True" or value == "true"
end

local function trim1(value)
  local text = string.format("%.1f", value)
  return (text:gsub("%.0$", ""))
end

local function fingerprintOf(stat)
  if stat == nil then
    return "missing"
  end
  return string.format("%.0f:%.0f", stat.mtime or 0, stat.size or 0)
end

local function normalize(data, now)
  local videos = {}
  for _, entry in ipairs(data.videos or {}) do
    table.insert(videos, {
      id = tostring(entry.id or ""),
      title = tostring(entry.title or ""),
      url = tostring(entry.url or ""),
      channel = tostring(entry.channel or ""),
      duration = tostring(entry.duration_string or ""),
      views = tonumber(entry.view_count),
      timestamp = tonumber(entry.timestamp),
      isShort = toBool(entry.is_short),
    })
  end

  local cachedAt = tonumber(data.cached_at) or 0
  local ageSeconds = nil
  if cachedAt > 0 then
    ageSeconds = math.max(0, now - cachedAt)
  end

  return { cachedAt = cachedAt, ageSeconds = ageSeconds, videos = videos }
end

function Feed.load()
  local path = noctalia.expandPath(CACHE_PATH)
  local fingerprint = fingerprintOf(noctalia.fileInfo(path))
  local cached = noctalia.state.get(STATE_KEY)

  if cached ~= nil and cached.fingerprint == fingerprint then
    if noctalia.state.get(PENDING_KEY) == true then
      noctalia.state.set(PENDING_KEY, false)
    end
    return cached.feed
  end

  if noctalia.state.get(PENDING_KEY) ~= true then
    noctalia.state.set(PENDING_KEY, true)
    noctalia.runAsync({ "jq", "-c", JQ_FILTER, path }, function(result)
      noctalia.state.set(PENDING_KEY, false)
      if result == nil or result.exitCode ~= 0 or type(result.stdout) ~= "string" or result.stdout == "" then
        noctalia.log("vidi: failed to compact feed cache (jq exit "
          .. tostring(result ~= nil and result.exitCode or "nil") .. ")")
        return
      end
      local data = noctalia.json.decode(result.stdout)
      if type(data) ~= "table" then
        return
      end
      local feed = normalize(data, math.floor(noctalia.nowMs() / 1000))
      noctalia.state.set(STATE_KEY, {
        fingerprint = fingerprintOf(noctalia.fileInfo(path)),
        feed = feed,
      })
      noctalia.log("feed cache refreshed (" .. #feed.videos .. " videos)")
    end)
  end

  return cached ~= nil and cached.feed or nil
end

function Feed.filter(feed, includeShorts, maxItems)
  local out = {}
  for _, video in ipairs(feed.videos) do
    if not video.isShort or includeShorts then
      table.insert(out, video)
      if maxItems ~= nil and #out >= maxItems then
        break
      end
    end
  end
  return out
end

function Feed.unseenCount(feed, includeShorts, seenTs)
  local count = 0
  for _, video in ipairs(feed.videos) do
    if (not video.isShort or includeShorts) and video.timestamp ~= nil and video.timestamp > seenTs then
      count += 1
    end
  end
  return count
end

function Feed.newestTimestamp(feed, includeShorts, floor)
  local newest = floor or 0
  for _, video in ipairs(feed.videos) do
    if (not video.isShort or includeShorts) and video.timestamp ~= nil then
      newest = math.max(newest, video.timestamp)
    end
  end
  return newest
end

function Feed.seenPath()
  return noctalia.pluginDataDir() .. "/seen.json"
end

function Feed.loadSeen()
  local raw = noctalia.readFile(Feed.seenPath())
  if raw == nil then
    return 0
  end
  local data = noctalia.json.decode(raw)
  if type(data) ~= "table" then
    return 0
  end
  return tonumber(data.ts) or 0
end

function Feed.markSeen(ts)
  noctalia.mkdirAll(noctalia.pluginDataDir())
  noctalia.writeFile(Feed.seenPath(), noctalia.json.encode({ ts = ts }))
  noctalia.state.set("seen_ts", ts)
end

function Feed.thumbPath(videoId)
  return noctalia.expandPath(THUMB_DIR .. "/" .. videoId .. ".png")
end

function Feed.shellQuote(s)
  return "'" .. string.gsub(tostring(s), "'", "'\\''") .. "'"
end

function Feed.vidiCommand()
  if noctalia.commandExists("vidi") then
    return "vidi"
  end
  local candidates = { "~/.local/bin/vidi", "/usr/local/bin/vidi", "/usr/bin/vidi" }
  for _, candidate in ipairs(candidates) do
    local path = noctalia.expandPath(candidate)
    if noctalia.fileExists(path) then
      return path
    end
  end
  return nil
end

function Feed.relAge(seconds)
  if seconds == nil then
    return ""
  end
  if seconds < 60 then
    return "now"
  elseif seconds < 3600 then
    return trim1(seconds / 60) .. "m"
  elseif seconds < 86400 then
    return trim1(seconds / 3600) .. "h"
  elseif seconds < 2592000 then
    return trim1(seconds / 86400) .. "d"
  elseif seconds < 31536000 then
    return trim1(seconds / 2592000) .. "mo"
  end
  return trim1(seconds / 31536000) .. "y"
end

function Feed.compactCount(n)
  if n == nil then
    return ""
  end
  if n >= 1000000 then
    return trim1(n / 1000000) .. "M"
  elseif n >= 1000 then
    return trim1(n / 1000) .. "K"
  end
  return tostring(math.floor(n))
end

function Feed.shortTitle(text, limit)
  if #text <= limit then
    return text
  end
  return (text:sub(1, limit - 1):gsub("%s+$", "")) .. "…"
end

return Feed
