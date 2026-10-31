--!nonstrict
-- Text helpers shared by the bar and the panels.

local M = {}

-- 83000 -> "1:23", 3723000 -> "1:02:03"
function M.duration(ms)
  if type(ms) ~= "number" then
    return "–:––"
  end
  local s = math.max(0, math.floor(ms / 1000))
  local h, m = s // 3600, (s // 60) % 60
  if h > 0 then
    return string.format("%d:%02d:%02d", h, m, s % 60)
  end
  return string.format("%d:%02d", m, s % 60)
end

-- "40 s" / "10 min" / "1 h" for a wait, rounded up.
function M.wait(ms)
  local s = math.max(1, math.ceil((ms or 0) / 1000))
  if s < 60 then
    return `{s} s`
  end
  local m = math.ceil(s / 60)
  if m < 60 then
    return `{m} min`
  end
  return `{math.ceil(m / 60)} h`
end

function M.artists(item)
  if type(item) ~= "table" then
    return ""
  end
  if item.type == "episode" then
    return (item.podcast and item.podcast.title) or item.author or ""
  end
  local names = {}
  for _, a in ipairs(item.artists or {}) do
    table.insert(names, a.name)
  end
  return table.concat(names, ", ")
end

function M.album(item)
  if type(item) ~= "table" then
    return ""
  end
  if item.type == "episode" then
    return item.author or ""
  end
  return (item.album and item.album.title) or ""
end

-- A second line for any Item: who made it and what it is.
function M.subtitle(item)
  if type(item) ~= "table" then
    return ""
  end
  local t = item.type
  -- Variadic, so a nil in the middle (no author, no year) does not cut the list short.
  local function join(...)
    local parts = table.pack(...)
    local out = {}
    for i = 1, parts.n do
      if parts[i] and parts[i] ~= "" then
        table.insert(out, parts[i])
      end
    end
    return table.concat(out, " · ")
  end
  if t == "track" then
    return M.artists(item)
  elseif t == "episode" then
    return join(item.podcast and item.podcast.title, item.publishedText)
  elseif t == "album" then
    local kind = item.albumType == "single" and noctalia.tr("lib.kind.single")
      or item.albumType == "ep" and "EP"
      or noctalia.tr("lib.kind.album")
    return join(kind, M.artists(item), item.year and tostring(item.year))
  elseif t == "playlist" then
    return join(item.author, item.trackCount and noctalia.trp("lib.songs", item.trackCount))
  elseif t == "artist" then
    return item.subscribersText or noctalia.tr("lib.kind.artist")
  elseif t == "podcast" then
    return join(noctalia.tr("lib.kind.podcast"), item.author)
  end
  return ""
end

-- The display name of any Item (artists have `name`, everything else `title`).
function M.name(item)
  return type(item) == "table" and (item.title or item.name) or ""
end

return M
