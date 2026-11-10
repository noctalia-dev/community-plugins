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
  -- SUBTRACT the user setting: its documented contract is "positive values show
  -- lines earlier, negative later", i.e. positive must move every timestamp DOWN
  -- (the lines fire sooner). Adding it did the opposite - a positive value pushed
  -- the text later than the recording, so the visible setting disagreed with its
  -- own description. The embedded [offset:] tag keeps its historical handling.
  local extraOffset = (fileOffsetMs - (offsetMs or 0)) / 1000.0

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
    local wordTimes = nil
    if lyricText ~= "" then
      local clean, times = lib.stripWordTimes(lyricText)
      lyricText = trim(clean)
      if #times > 0 then
        wordTimes = {}
        for _, wt in ipairs(times) do wordTimes[#wordTimes + 1] = wt + extraOffset end
      end
    end
    if #timestamps > 0 then
      if lyricText ~= "" then
        for _, t in ipairs(timestamps) do
          result[#result + 1] = { time = t, text = lyricText, words = wordTimes }
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

-- ── word timing (enhanced LRC) ─────────────────────────────────────────────
-- Enhanced LRC marks the start of each word with <mm:ss.xx> INSIDE the line:
--   [00:12.00] <00:12.00>hello <00:12.45>world
-- The markers are not lyrics: strip them out of the text and keep their times,
-- so the renderer can sweep the highlight word by word. Lines without markers
-- come back with an empty times list and sweep evenly instead.
function lib.stripWordTimes(text)
  local clean, times = {}, {}
  local pos = 1
  while true do
    local fs, fe, min, sec, frac = string.find(text, "<(%d+):(%d%d?)%.?(%d*)>", pos)
    if not fs then
      clean[#clean + 1] = string.sub(text, pos)
      break
    end
    clean[#clean + 1] = string.sub(text, pos, fs - 1)
    times[#times + 1] = tonumber(min) * 60 + tonumber(sec) + lib.fractionalSeconds(frac)
    pos = fe + 1
  end
  return table.concat(clean), times
end

-- How far the highlight has swept, as a float index over words: 0 = nothing
-- filled, 1 = the first word is done, 2.5 = two words done and half of the
-- third. `wordCount` is the number of words the ROW shows (a wrapped line has
-- fewer than the whole lyric), so the answer is relative to the row.
-- Without word times the fill sweeps evenly across the line's span.
--
-- Timing follows the official lyrics widget: every word fills over its own slot
-- and the line finishes a little early. The old code stretched the LAST word to
-- the next line's timestamp (and the even sweep to the line end), so the
-- highlight crawled through every trailing gap — the animation read as slower
-- than the singing.
function lib.fillProgress(words, nowSec, lineStartSec, lineEndSec, wordCount)
  local count = wordCount or (words and #words) or 1
  if count <= 0 then return 0 end
  if words and #words > 0 then
    local n = #words
    if nowSec <= words[1] then return 0 end
    -- Markers can be sparser than the visible words: sweep the word index space
    -- evenly across the markers instead of capping at n (which froze the fill
    -- and then jumped it to the end of the line).
    local scale = count / n
    for i = 1, n do
      local a = words[i]
      local b
      if i < n then
        b = words[i + 1]
      else
        -- The last word keeps its own duration (the average slot), never the
        -- wait for the next line.
        local avg = (n > 1) and ((words[n] - words[1]) / (n - 1)) or 0.35
        b = a + math.max(0.15, avg)
        if lineEndSec and lineEndSec > a then b = math.min(b, lineEndSec) end
      end
      if nowSec < b then
        local span = math.max(b - a, 0.001)
        return math.min(count, ((i - 1) + (nowSec - a) / span) * scale)
      end
    end
    return count
  end
  local span = math.max((lineEndSec or (lineStartSec + 3)) - lineStartSec, 0.001)
  -- Finish a little early (like the official widget) so the full line is seen
  -- before the next one replaces it, instead of crawling through the gap.
  local sweepSpan = math.max(span - math.min(span * 0.3, 0.6), 0.001)
  local f = math.max(0, math.min(1, (nowSec - lineStartSec) / sweepSpan))
  return f * count
end

-- ── word-timed sources ──────────────────────────────────────────────────────
-- The word-timed providers speak their own formats; both convert to enhanced
-- LRC (<mm:ss.xx>word markers), so parseLrc above stays the single reader.

local function lrcTime(ms, open, close)
  ms = math.max(0, math.floor(tonumber(ms) or 0))
  local total = math.floor(ms / 1000)
  return string.format("%s%d:%02d.%02d%s", open, math.floor(total / 60),
    total % 60, math.floor(ms / 10) % 100, close)
end

-- Word rows in milliseconds (lrcmux shape: text/start/words[{text,start}]) to
-- enhanced LRC. Rows without words come out as plain line-timed LRC.
function lib.wordRowsToLrc(rows)
  local out = {}
  for _, row in ipairs(rows or {}) do
    local words = row.words
    if type(words) == "table" and #words > 0 then
      local parts = {}
      for _, w in ipairs(words) do
        local t = trim(w.text or "")
        if t ~= "" then
          parts[#parts + 1] = lrcTime(w.start or 0, "<", ">") .. t
        end
      end
      if #parts > 0 then
        out[#out + 1] = lrcTime(row.start or 0, "[", "]") .. table.concat(parts, " ")
      end
    elseif trim(row.text or "") ~= "" then
      out[#out + 1] = lrcTime(row.start or 0, "[", "]") .. trim(row.text)
    end
  end
  return table.concat(out, "\n")
end

-- NetEase yrc to enhanced LRC. Rows look like
--   [26630,5490](26630,300,0)Like (26930,240,0)when ...
-- (line start+duration in ms, then per-word start+duration+flag and text).
-- Credit rows arrive as JSON and are skipped.
function lib.yrcToLrc(yrc)
  local out = {}
  for line in tostring(yrc or ""):gmatch("[^\r\n]+") do
    local ls, text = line:match("^%[(%d+),%d+%](.*)$")
    local lineMs = ls and tonumber(ls) or nil
    if lineMs and text then
      local parts, pos = {}, 1
      while true do
        local s, _, wstart, after = string.find(text, "%((%d+),%d+,%d+%)()", pos)
        if not s then break end
        local ne = string.find(text, "%(%d+,%d+,%d+%)", after)
        local chunk = string.sub(text, after, (ne or (#text + 1)) - 1)
        if trim(chunk) ~= "" then
          parts[#parts + 1] = lrcTime(tonumber(wstart) or 0, "<", ">") .. trim(chunk)
        end
        pos = ne or (#text + 1)
      end
      if #parts > 0 then
        out[#out + 1] = lrcTime(lineMs, "[", "]") .. table.concat(parts, " ")
      end
    end
  end
  return table.concat(out, "\n")
end

-- Conservative accept for third-party matches: the normalized title must be
-- equal, the duration within 5 s, and the artist matching or contained. A remix
-- with a different parenthetical suffix is a different recording and is
-- refused — its timings would desync every line.
function lib.trackMatches(want, got)
  if type(want) ~= "table" or type(got) ~= "table" then return false end
  local function norm(s)
    return (trim(tostring(s or ""):lower()):gsub("%s+", " "))
  end
  local wt, gt = norm(want.title), norm(got.title)
  if wt == "" or wt ~= gt then return false end
  local wd, gd = tonumber(want.durationSec) or 0, tonumber(got.duration) or 0
  if wd > 0 and gd > 0 and math.abs(wd - gd) > 5 then return false end
  local wa, ga = norm(want.artist), norm(got.artist)
  if wa == "" or ga == "" then return true end
  return wa == ga or ga:find(wa, 1, true) ~= nil or wa: find(ga, 1, true) ~= nil
end

-- Do two lyric bodies say the same words? The comparison is a word bag —
-- markers, punctuation and line breaks ignored: providers cut lines
-- differently ("one long line" vs "two short ones" is the same song), while a
-- translation or another song shares almost no words.
function lib.textLooksSame(a, b)
  local function bagOf(s)
    local bag, total = {}, 0
    -- line stamps and word markers are not words; JSON credit rows are not lines
    s = tostring(s or ""):gsub("<%d+:%d%d?%.?%d*>", "")
      :gsub("%[%d+:%d%d?%.?%d*%]", ""):lower()
    for raw in (s .. "\n"):gmatch("([^\r\n]*)\r?\n") do
      if not raw:match("^%s*{") then
        for w in raw:gmatch("[%w\128-\255]+") do
          bag[w] = (bag[w] or 0) + 1
          total = total + 1
        end
      end
    end
    return bag, total
  end
  local ba, ta = bagOf(a)
  local bb, tb = bagOf(b)
  if ta == 0 or tb == 0 then return false end
  local common = 0
  for w, n in pairs(ba) do
    local m = bb[w]
    if m then common = common + math.min(n, m) end
  end
  return common / math.max(ta, tb) >= 0.8
end

-- ── cache locations ───────────────────────────────────────────────────────
-- The cache lives in a `lyrics/` subfolder of the plugin data dir. The host
-- does not create parent folders on write, so every writer must ask for the
-- directory explicitly before writing a file into it.
function lib.cachePaths(dataDir, artist, title)
  if not dataDir or dataDir == "" then return nil end
  local dir = dataDir .. "/lyrics"
  return {
    dir = dir,
    file = dir .. "/" .. lib.sanitizePart(artist) .. "__" .. lib.sanitizePart(title) .. ".lrc",
  }
end

-- ── source order ──────────────────────────────────────────────────────────
-- Online providers in the order the user wants them tried. Unknown or repeated
-- ids are dropped; ids the user left out keep their default place at the end,
-- so a partial list never loses a provider.
lib.SOURCE_ORDER_DEFAULT = { "lrcmux", "lrclib", "netease" }

function lib.sourceOrder(cfg)
  local known = {}
  for _, id in ipairs(lib.SOURCE_ORDER_DEFAULT) do known[id] = true end
  local out, seen = {}, {}
  for raw in tostring(cfg or ""):gmatch("[^,%s]+") do
    local id = raw:lower()   -- Lua 5.4 forbids assigning to a for-loop variable
    if known[id] and not seen[id] then
      out[#out + 1] = id
      seen[id] = true
    end
  end
  for _, id in ipairs(lib.SOURCE_ORDER_DEFAULT) do
    if not seen[id] then out[#out + 1] = id end
  end
  return out
end

return lib
