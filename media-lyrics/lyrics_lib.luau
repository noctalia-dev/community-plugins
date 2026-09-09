--!nonstrict
-- lyrics_lib: pure, host-independent lyric logic extracted from service.luau
-- so it can be unit-tested without a Noctalia host (Lua 5.5 / luac -p) and
-- kept free of noctalia.* dependencies. service.luau requires this module.
--
-- Kept behaviour-identical to the original inline helpers: LRC/plain-text
-- parsing, placeholder detection, NetEase metadata stripping, ranking, and
-- UTF-8-safe sanitizers. No `noctalia` global here.

local lib = {}

local function trim(s)
  if type(s) ~= "string" then return "" end
  return s:gsub("^%s+", ""):gsub("%s+$", "")
end
lib.trim = trim

-- ── LRC parsing ─────────────────────────────────────────────────────────────

function lib.fractionalSeconds(frac)
  if not frac or frac == "" then return 0.0 end
  local v = tonumber(frac) or 0
  local n = #frac
  if n == 1 then return v / 10.0 end
  if n == 2 then return v / 100.0 end
  return v / 1000.0
end

function lib.isMetadataLine(line)
  local l = line:lower()
  return l:match("^%[ar%s*:") ~= nil or l:match("^%[ti%s*:") ~= nil
    or l:match("^%[al%s*:") ~= nil or l:match("^%[by%s*:") ~= nil
    or l:match("^%[re%s*:") ~= nil or l:match("^%[ve%s*:") ~= nil
    or l:match("^%[offset%s*:") ~= nil
end

function lib.looksLikeMalformedTimestamp(line)
  return line:match("^%[%d+%s*:[^%]]+%]") ~= nil
end

-- Parse an LRC (or plain-text) lyric into a sorted list of { time = sec, text }.
-- time < 0 marks unsynced lines. Mirrors Lyrics::parseLrc from Clavis.
function lib.parseLrc(text, offsetMs)
  local result = {}
  if trim(text) == "" then return result end

  local fileOffsetMs = 0
  local off = text:match("%[offset%s*:%s*(-?%d+%.?%d*)%]")
  if off then fileOffsetMs = tonumber(off) or 0 end
  local extraOffset = (fileOffsetMs + (offsetMs or 0)) / 1000.0

  for line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    local timestamps = {}
    local rest = line
    -- consume every leading [mm:ss(.ttt)] timestamp tag (also accepts : or - ms separators)
    while true do
      local min, sec, epos
      local sep, frac
      -- with fractional part
      min, sec, sep, frac, epos = rest:match("^%s*%[(%d+):(%d%d?)([%.:%-])(%d+)%]()")
      if not min then
        -- plain [mm:ss]
        min, sec, epos = rest:match("^%s*%[(%d+):(%d%d?)%]()")
        sep, frac = nil, nil
      end
      if not min then break end
      local ts = tonumber(min) * 60 + tonumber(sec) + lib.fractionalSeconds(frac)
      timestamps[#timestamps + 1] = ts + extraOffset
      rest = rest:sub(epos)
    end

    local lyricText = trim(rest)
    if #timestamps > 0 then
      if lyricText ~= "" then
        for _, t in ipairs(timestamps) do
          result[#result + 1] = { time = t, text = lyricText }
        end
      end
    else
      local trimmedLine = trim(line)
      if not (lyricText == "" or lib.isMetadataLine(trimmedLine) or lib.looksLikeMalformedTimestamp(trimmedLine)) then
        result[#result + 1] = { time = -1.0, text = lyricText }
      end
    end
  end

  -- stable sort: synced lines first (by time), unsynced after, preserving order
  local function keyed(t)
    for i, v in ipairs(result) do
      if v == t then return i end
    end
    return 0
  end
  table.sort(result, function(a, b)
    local at, bt = a.time >= 0, b.time >= 0
    if at ~= bt then return at end
    if at and bt then
      if a.time ~= b.time then return a.time < b.time end
      return keyed(a) < keyed(b) -- stability
    end
    return false
  end)
  return result
end

-- ── NetEase placeholder detection ──────────────────────────────────────────

local NETEASE_PLACEHOLDERS = { "纯音乐请欣赏", "纯音乐版", "暂无歌词",
  "此歌曲为没有填词的纯音乐", "此歌曲为纯音乐请欣赏", "纯音乐" }
lib.NETEASE_PLACEHOLDERS = NETEASE_PLACEHOLDERS

function lib.isPlaceholderLyrics(raw)
  -- Byte-safe sanitize: multibyte chars must NOT live inside a Lua character
  -- class together with ASCII punctuation — it corrupts UTF-8 bytes. Strip
  -- timestamps + ASCII punctuation first, then full-width chars literally.
  local cleaned = (raw or ""):gsub("%[%d+:%d+%.?%d*%]", "")
  cleaned = cleaned:gsub("[%s,.!?]", "")
  cleaned = cleaned:gsub("，", ""):gsub("。", ""):gsub("．", "")
  cleaned = cleaned:gsub("！", ""):gsub("？", "")
  if cleaned == "" then return false end
  for _, p in ipairs(NETEASE_PLACEHOLDERS) do
    if cleaned == p then return true end
  end
  -- variant lines appended after the phrase (e.g. "...请欣赏，谢谢");
  -- compare CHARACTER length (utf8), not bytes
  local clen = utf8.len(cleaned) or #cleaned
  return clen <= 16 and cleaned:find("纯音乐", 1, true) ~= nil
end

-- ── NetEase metadata strip ─────────────────────────────────────────────────

local NETEASE_META = {
  "^%s*作词%s*[:：]", "^%s*作曲%s*[:：]", "^%s*编曲%s*[:：]",
  "^%s*制作人%s*[:：]", "^%s*混音%s*[:：]", "^%s*母带%s*[:：]",
  "^%s*录音%s*[:：]", "^%s*监制%s*[:：]", "^%s*和声%s*[:：]",
  "^%s*出品%s*[:：]", "^%s*发行%s*[:：]", "^%s*企划%s*[:：]",
  "^%s*统筹%s*[:：]", "^%s*OP%s*[:：]", "^%s*SP%s*[:：]",
  "^%s*Artist%s*[:：]", "^%s*Album%s*[:：]", "^%s*Producer%s*[:：]",
  "^%s*Composer%s*[:：]", "^%s*Lyricist%s*[:：]",
}
lib.NETEASE_META = NETEASE_META

function lib.stripNetEaseMeta(raw)
  local out = {}
  for line in (raw .. "\n"):gmatch("(.-)\n") do
    local text = trim(line)
    if text ~= "" then
      local body = text:gsub("^%[%d+:%d+%.?%d*%]%s*", "")
      local isMeta = false
      for _, p in ipairs(NETEASE_META) do
        if body:match(p) then isMeta = true break end
      end
      if not isMeta then out[#out + 1] = text end
    end
  end
  return table.concat(out, "\n")
end

-- ── NetEase song ranking ──────────────────────────────────────────────────

local function ciEq(a, b)
  return trim(a or ""):lower() == trim(b or ""):lower()
end
lib.ciEq = ciEq

local function ciHas(hay, needle)
  return trim(hay or ""):lower():find(trim(needle or ""):lower(), 1, true) ~= nil
end
lib.ciHas = ciHas

-- Rank cloudsearch hits: exact/contains matches on title (3/1) and artist
-- (2/1), plus a duration bonus (2/1) when cloudsearch `dt` (ms) matches the
-- playing track's length. Returns score>0 candidates sorted desc {id, score}.
function lib.rankNetEaseSongs(songs, artist, title, durSec)
  local ranked = {}
  for _, s in ipairs(songs) do
    local sname = trim(s.name or "")
    local artists = ""
    local arr = type(s.ar) == "table" and s.ar or type(s.artists) == "table" and s.artists or nil
    if arr then
      local names = {}
      for _, a in ipairs(arr) do names[#names + 1] = a.name or "" end
      artists = table.concat(names, ", ")
    end
    local artistKnown = trim(artist or "") ~= ""
    local titleOk = ciEq(sname, title) or ciHas(sname, title)
    local artistOk = (not artistKnown) or ciEq(artists, artist) or ciHas(artists, artist)
    if titleOk and artistOk then
      local score = 0
      if ciEq(sname, title) then score = score + 3 end
      if ciHas(sname, title) then score = score + 1 end
      if ciEq(artists, artist) then score = score + 2 end
      if ciHas(artists, artist) then score = score + 1 end
      if type(s.dt) == "number" and durSec and durSec > 0 then
        local d = math.abs(s.dt / 1000 - durSec)
        if d < 2 then score = score + 2
        elseif d < 6 then score = score + 1 end
      end
      if score > 0 and type(s.id) == "number" then
        ranked[#ranked + 1] = { id = s.id, score = score }
      end
    end
  end
  table.sort(ranked, function(a, b) return a.score > b.score end)
  return ranked
end

-- True when the text carries [mm:ss.xx] timestamps (karaoke-capable).
function lib.lrcIsSynced(text)
  return text:match("%[%d+:%d+%.?%d*%]") ~= nil
end

-- ── sanitizers ─────────────────────────────────────────────────────────────

function lib.sanitizePart(s)
  return trim((s or ""):gsub('[%c/\\]', "_"))
end

-- UTF-8 aware glyph count (never splits a sequence).
function lib.charCount(s)
  local i, n = 1, 0
  while i <= #s do
    local b = s:byte(i)
    if b >= 0xF0 then i = i + 4
    elseif b >= 0xE0 then i = i + 3
    elseif b >= 0xC0 then i = i + 2
    else i = i + 1 end
    n = n + 1
  end
  return n
end

return lib
