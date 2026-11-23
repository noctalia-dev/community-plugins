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

-- ── text measurement (shared with panel.luau / desktop.luau / widget.luau) ──
local function toChars(text)
  local chars = {}
  local i = 1
  while i <= #text do
    local byte = text:byte(i)
    local len = 1
    if byte >= 0xF0 then len = 4
    elseif byte >= 0xE0 then len = 3
    elseif byte >= 0xC0 then len = 2 end
    chars[#chars + 1] = text:sub(i, i + len - 1)
    i = i + len
  end
  return chars
end

local function charAdv(c)
  local o = string.byte(c) or 32
  if o >= 0x80 then
    if #c >= 3 then return 1.0 end                     -- CJK / emoji: full width
    return 0.58                                          -- other non-ASCII (Cyrillic etc)
  end
  if c == " " then return 0.28 end
  if c == "i" or c == "l" or c == "I" then return 0.27 end
  if c == "m" then return 0.92 end
  if c == "w" or c == "M" or c == "W" then return 0.80 end
  if c == "." or c == "," or c == ":" or c == ";" or c == "'" or c == "!"
     or c == "|" or c == "`" then return 0.28 end
  if c == "(" or c == ")" or c == "[" or c == "]" or c == "{" or c == "}" then return 0.35 end
  if c == "j" or c == "t" or c == "f" or c == "r" then return 0.39 end
  if string.find("ABCDGHNOQRUVXY", c, 1, true) then return 0.64 end
  return 0.56
end

local function unitEm(text)
  local u = 0
  for _, ch in ipairs(toChars(text)) do u = u + charAdv(ch) end
  return u
end

lib.toChars = toChars
lib.charAdv = charAdv
lib.unitEm = unitEm

-- Hard-cut to a whole glyph boundary, appending an ellipsis when truncated.
function lib.truncEm(text, capEm)
  local out, used = {}, 0
  for _, ch in ipairs(toChars(text)) do
    local a = charAdv(ch)
    if used + a > capEm then
      return table.concat(out) .. "…"
    end
    out[#out + 1] = ch
    used = used + a
  end
  return table.concat(out)
end

-- ── LRC parsing ─────────────────────────────────────────────────────────────

function lib.fractionalSeconds(frac)
  if not frac or frac == "" then return 0.0 end
  local v = tonumber(frac) or 0
  -- Scale by the ACTUAL digit count: "[00:01.0025]" is 25 ms, not 2.5 ms
  -- (the old /1000 cap silently misread 4+ digit fractions).
  return v / (10 ^ #frac)
end

function lib.isMetadataLine(line)
  local l = (line or ""):lower()
  local basic = l:match("^%[ar%s*:") ~= nil or l:match("^%[ti%s*:") ~= nil
    or l:match("^%[al%s*:") ~= nil or l:match("^%[by%s*:") ~= nil
    or l:match("^%[re%s*:") ~= nil or l:match("^%[ve%s*:") ~= nil
    or l:match("^%[offset%s*:") ~= nil or l:match("^%[length%s*:") ~= nil
  if basic then return true end
  return lib.isNetEaseMetaLine(line)
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

  -- stable sort: synced lines first (by time), unsynced after, preserving order.
  -- The order map is built ONCE: a tie-break lookup in it is O(1). The previous
  -- comparator re-scanned the whole list on every tie (O(n^2) on lines sharing
  -- a timestamp) and burned the host's 25 ms callback budget — the service
  -- callback died mid-parse and the panel stuck on "Loading lyrics..."
  -- (community-plugins issue #1494).
  local ord = {}
  for i, v in ipairs(result) do ord[v] = i end
  table.sort(result, function(a, b)
    local at, bt = a.time >= 0, b.time >= 0
    if at ~= bt then return at end
    -- Equal timestamps (including \"no timestamp\" / unsynced lines) tie-break
    -- on the original file order, so plain lyrics never get reshuffled.
    if at and bt then
      if a.time ~= b.time then return a.time < b.time end
      return ord[a] < ord[b] -- stability
    end
    -- at != bt: synced lines always sort before unsynced ones.
    if at ~= bt then return at end
    return ord[a] < ord[b] -- unsynced / equal plain lines keep file order
  end)
  return result
end

-- ── NetEase placeholder detection ──────────────────────────────────────────

local PLACEHOLDER_MAX_BYTES = 4096
lib.PLACEHOLDER_MAX_BYTES = PLACEHOLDER_MAX_BYTES

local NETEASE_PLACEHOLDERS = { "纯音乐请欣赏", "纯音乐版", "暂无歌词",
  "此歌曲为没有填词的纯音乐", "此歌曲为纯音乐请欣赏", "纯音乐" }
lib.NETEASE_PLACEHOLDERS = NETEASE_PLACEHOLDERS

function lib.isPlaceholderLyrics(raw)
  raw = raw or ""
  -- Плейсхолдеры — короткие фразы/несколько credit-строк; настоящий LRC на порядок больше.
  -- Полнострочные gsub выполняются в C и убивали 25-мс бюджет колбэка (log lyrics_lib.luau:208/209).
  if #raw > PLACEHOLDER_MAX_BYTES then return false end
  -- A payload made ENTIRELY of metadata/credit rows (raw word-timing JSON,
  -- 作曲-style credit tags) is not lyrics: drop it and keep the lookup chain
  -- hunting. Mixed payloads fall through and are filtered per line in parseLrc.
  local nonEmpty, allMeta = 0, true
  for line in raw:gmatch("[^\n]+") do
    if line:match("%S") then
      nonEmpty = nonEmpty + 1
      if not lib.isNetEaseMetaLine(line) then allMeta = false break end
    end
  end
  if nonEmpty > 0 and allMeta then return true end
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

function lib.isNetEaseMetaLine(line)
  local text = trim(line or "")
  if text == "" then return false end
  if text:match("^%s*{") then return true end
  local body = text:gsub("^%[%d+:%d+%.?%d*%]%s*", "")
  for _, pp in ipairs(NETEASE_META) do
    if body:match(pp) then return true end
  end
  -- Credit tags like "[4F5C][66F2]: ..." (作曲:) come as bracketed CJK code
  -- points. Match the OBSERVED shapes (two tags in a row, or one tag followed
  -- by a colon) - a lone "[Beef]" in a lyric must NOT be eaten.
  if body:match("^%[%x%x%x%x%]%[%x%x%x%x%]") then return true end
  if body:match("^%[%x%x%x%x%]:") then return true end
  return false
end

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
      if not isMeta and lib.isNetEaseMetaLine(text) then isMeta = true end
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
  local out = trim((s or ""):gsub('[%c/\\]', "_"))
  -- Bound the filename piece: a 300-character title broke cache writes on
  -- long-path filesystems. Cut at 80 bytes and drop a trailing partial
  -- UTF-8 sequence so the name stays valid.
  if #out > 80 then
    out = out:sub(1, 80)
    while #out > 0 and out:byte(#out) >= 0x80 do
      out = out:sub(1, #out - 1)
    end
  end
  return out
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
  return wa == ga or ga:find(wa, 1, true) ~= nil or wa:find(ga, 1, true) ~= nil
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
-- Decode a file:// URI into a local path; non-file schemes (and garbage) are
-- ignored. Percent-escapes (%XX) are decoded.
function lib.fileUriToPath(uri)
  if type(uri) ~= "string" or uri == "" then return nil end
  local low = uri:lower()
  if low:sub(1, 7) ~= "file://" then return nil end
  -- keep the original casing of the path; only the scheme is case-insensitive
  local path = uri:sub(8)
  -- a third slash (file:///) is part of the empty authority; collapse it
  if path:sub(1, 1) == "/" then
    -- already an absolute path, nothing to do
  else
    path = "/" .. path
  end
  path = path:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
  if path == "" or path == "/" then return nil end
  return path
end

-- Candidate sidecar .lrc path next to an audio file given by a file:// URI.
-- Returns "<dir>/<basename>.lrc" with the audio extension stripped, or nil
-- for non-file URIs. Read-only: callers must never write to this location.
function lib.sidecarLyricPath(uri)
  local path = lib.fileUriToPath(uri)
  if not path then return nil end
  local dir = path:match("^(.*)/[^/]+$")
  local base = path:match("([^/]+)$")
  if not base then return nil end
  -- strip the audio extension
  base = base:gsub("%.[^%.]+$", "")
  if base == "" then return nil end
  if dir and dir ~= "" then
    return dir .. "/" .. base .. ".lrc"
  end
  return base .. ".lrc"
end

-- aliases (various names callers/tests may use)
-- aliases removed


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

-- Fallback: some players (yt-music via mpv --force-media-title="Title - Artist") leave
-- xesam:artist empty and embed the artist at the end of xesam:title. Split only
-- when artist is empty/whitespace, on the LAST " - ". Empty parts => no split.
function lib.splitTitleArtist(title, artist)
    title = title or ""
    artist = artist or ""
    if trim(artist) ~= "" then
        return title, artist
    end
    local lastPos = nil
    local start = 1
    while true do
        local i = title:find(" - ", start, true)
        if not i then break end
        lastPos = i
        start = i + 3
    end
    if lastPos then
        local t = title:sub(1, lastPos - 1)
        local a = title:sub(lastPos + 3)
        if trim(t) ~= "" and trim(a) ~= "" then
            return trim(t), trim(a)
        end
    end
    return title, artist
end

-- split aliases removed

-- Плавная проекция позиции: последнее известное положение + wall clock.
-- nowMs / sampleMs в миллисекундах, lastPosSec — секунды; playing — bool;
-- lengthSec — опциональный верхний предел (cap).
function lib.projectPosition(lastPosSec, sampleMs, nowMsV, playing, lengthSec)
  lastPosSec = tonumber(lastPosSec) or 0
  sampleMs = tonumber(sampleMs) or nowMsV or 0
  nowMsV = tonumber(nowMsV) or sampleMs
  local len = tonumber(lengthSec) or 0
  local pos = lastPosSec
  if playing then
    local delta = (nowMsV - sampleMs) / 1000.0
    if delta < 0 then delta = 0 end
    pos = lastPosSec + delta
  end
  -- The display must NEVER exceed the duration (the 3:18 / 3:16 class) -
  -- clamped on every path, including a stale base while paused.
  if len > 0 and pos > len then pos = len end
  return pos
end

-- Унифицированный интерполятор позиции для всех entry (panel/panel-mini/desktop).
-- Принимает либо таблицу состояния s, либо позиционные аргументы
-- (lastPosSec, sampleMs, nowMs, playing, lengthSec) как projectPosition.
function lib.interpPos(...)
  local args = {...}
  if type(args[1]) == "table" then
    local s = args[1]
    local nowOverride = args[2]
    local nowMsV = nowOverride
    if type(nowMsV) ~= "number" then
      nowMsV = 0
      pcall(function() nowMsV = noctalia.nowMs() end)
      if type(nowMsV) ~= "number" or nowMsV <= 0 then nowMsV = os.time() * 1000 end
    end
    local sampleMs = s.sampleMs or s.posAtMs or s.lastSnapMs or 0
    if not sampleMs or sampleMs == 0 then sampleMs = nowMsV end
    return lib.projectPosition(s.posSec or s.position or s.pos or 0, sampleMs, nowMsV, s.playing, s.lengthSec or s.length or s.duration or s.durationSec)
  end
  return lib.projectPosition(args[1], args[2], args[3], args[4], args[5])
end

-- Разбор ответа noctalia.mediaPlayer() (plugin_api 51): tolerant, не ломается
-- на отличиях схемы. Возвращает нормализованную таблицу или nil.
function lib.parseMediaPlayerResponse(resp)
  if type(resp) ~= "table" then return nil end
  --(resp may be wrapped as { data = {...} } or bare)
  local f = resp
  if type(resp.data) == "table" and type(resp.data.title) ~= nil then f = resp.data end
  local function g(key, ...)
    -- try a list of candidate keys
    for _, k in ipairs({...}) do
      local v = f[k]
      if v ~= nil then return v end
    end
    return f[key]
  end
  local title = g("title", "Title") or ""
  local artist = g("artist", "Artist", "artists") or ""
  -- artist may be a list
  if type(artist) == "table" then
    local parts = {}
    for _, a in ipairs(artist) do
      if type(a) == "string" then parts[#parts+1] = a
      elseif type(a) == "table" then parts[#parts+1] = a.name or a.text or "" end
    end
    artist = table.concat(parts, ", ")
  end
  local album = g("album", "Album") or ""
  -- Units differ across shell versions: lengthSec/durationSec (seconds),
  -- lengthMs/durationMs (milliseconds), lengthUs/length_us/mpris:length
  -- (microseconds), or a bare length/duration in ANY of them. Normalize per
  -- known key first; only the bare fallback uses a magnitude heuristic.
  -- (A parsed length of 0 showed live as "1:25 / 0:00" on the sync path.)
  local lengthSec = tonumber(g("lengthSec", "durationSec")) or 0
  if lengthSec == 0 then
    lengthSec = (tonumber(g("lengthMs", "durationMs")) or 0) / 1000
  end
  if lengthSec == 0 then
    lengthSec = (tonumber(g("lengthUs", "length_us")) or 0) / 1e6
  end
  if lengthSec == 0 then
    local raw = tonumber(g("length", "Length", "duration", "durationSec"))
    if raw then
      if raw > 1e6 then raw = raw / 1e6
      elseif raw > 1e4 then raw = raw / 1000 end
      lengthSec = raw
    end
  end
  local posSec = tonumber(g("posSec", "positionSec")) or 0
  if posSec == 0 then posSec = (tonumber(g("positionMs", "posMs")) or 0) / 1000 end
  if posSec == 0 then posSec = (tonumber(g("positionUs", "position_us")) or 0) / 1e6 end
  if posSec == 0 then
    local raw = tonumber(g("position", "Position"))
    if raw then
      if raw > 1e6 then raw = raw / 1e6
      elseif raw > 1e4 then raw = raw / 1000 end
      posSec = raw
    end
  end
  local status = g("playback_status", "playbackStatus", "status", "Status") or ""
  local playing = (tostring(status):lower() == "playing") or (g("playing", "isPlaying") == true)
  local busName = g("bus_name", "busName", "playerBusName") or ""
  local ident = g("identity", "playerName", "name") or ""
  local canSeek = (g("canSeek", "can_seek") == nil) and true or (g("canSeek", "can_seek") == true)
  -- Transport caps are OPTIONAL in MPRIS and several hosts omit them. Unknown
  -- means ENABLED (optimistic): Next/Previous are near-universal and the
  -- command path refreshes the caps after the call. Treating "unknown" as "no"
  -- silently disabled both buttons on every sync-path player (owner report).
  local canGoNext = (g("canGoNext", "can_go_next") == nil) and true or (g("canGoNext", "can_go_next") == true)
  local canGoPrev = (g("canGoPrev", "can_go_previous") == nil) and true or (g("canGoPrev", "can_go_previous") == true)
  local artUrl = g("artUrl", "art_url", "art", "mpris:artUrl", "artUrlMs") or ""
  return {
    title = tostring(title),
    artist = tostring(artist),
    album = tostring(album),
    artUrl = tostring(artUrl),
    lengthSec = lengthSec,
    posSec = posSec,
    playing = playing,
    status = tostring(status),
    busName = tostring(busName),
    identity = tostring(ident),
    canSeek = canSeek,
    canGoNext = canGoNext,
    canGoPrev = canGoPrev,
  }
end

-- Index of the active lyric line for a given playback position: the last
-- line whose timestamp <= pos. Returns -1 when no line has started yet
-- (intro / before first timestamp). Plain/unsynced lines (time < 0) never
-- become active here: callers treat -1 as "highlight nothing".
function lib.activeIndex(lines, pos)
  local active = -1
  lines = lines or {}
  for i = 1, #lines do
    local t = lines[i] and lines[i].time
    if type(t) == "number" and t >= 0 then
      if t <= pos then
        active = i
      else
        break
      end
    end
  end
  return active
end

-- Should the lyrics area show loaded lyrics for this status? Single source of
-- truth for the "ready or choose-with-lyrics" rule every surface re-implemented
-- (the audits counted three different spellings).
function lib.isLyricsShown(status)
  return status == "ready" or status == "choose"
end

-- Do two track *claims* refer to the same real track despite MPRIS
-- metadata drift (title "Big Dawgs" -> "Big Dawgs (feat. Kalmi)", length 0 -> 190s)?
-- Returns true only for the drift we want to collapse, NOT for distinct
-- remixes: artist change or a non-prefix title change is a different track,
-- and a suffix added after a known (non-zero) duration is also a different
-- track.
function lib.sameClaim(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  local function field(t, k)
    local v = t[k]
    if v == nil then return "" end
    return tostring(v)
  end
  local function dur(t)
    local d = t.durationSec or t.lengthSec
    if d == nil and t.lengthUs ~= nil then d = (tonumber(t.lengthUs) or 0) / 1000000 end
    local n = tonumber(d)
    if not n or n < 0 then return 0 end
    return n
  end
  local function norm(s) return trim(tostring(s or ""):lower()) end
  local ta, tb = norm(field(a, "title")), norm(field(b, "title"))
  local aa, ab = norm(field(a, "artist")), norm(field(b, "artist"))
  if aa ~= "" and ab ~= "" and aa ~= ab then return false end
  if ta == "" or tb == "" then return false end
  if ta == tb then return true end
  local prefix = (tb:sub(1, #ta) == ta) or (ta:sub(1, #tb) == tb)
  if not prefix then return false end
  local da, db = dur(a), dur(b)
  -- at least one side must have unknown (zero) duration to collapse drift
  if da ~= 0 and db ~= 0 then return false end
  return true
end

-- (lib.normalizePlayer deleted: dead since the service reads the host
--  response through parseMediaPlayerResponse + the variant shim; both
--  re-audits flagged the ~80-line duplicate.)

function lib.trackKey(ident, title, artist, lengthUs)
  return tostring(ident or "") .. "|" .. tostring(title or "") .. "|"
    .. tostring(artist or "") .. "|"
    .. tostring(math.floor((tonumber(lengthUs) or 0) + 0.5))
end

-- Combine the global offset setting with a per-track override. An empty/nil
-- override means "global only"; a numeric override adds to the global value.
function lib.effectiveOffsetMs(globalMs, overrideMs)
  local g = tonumber(globalMs) or 0
  if type(overrideMs) == "number" then return g + overrideMs end
  return g
end

-- Mutate a per-track offsets map (pure; the service owns the IO): a numeric
-- value sets/replaces the override, nil removes it. Bad values coerce to 0.
function lib.updateOffsetMap(t, key, value)
  if type(t) ~= "table" or not key or key == "" then return t end
  if value == nil then t[key] = nil else t[key] = tonumber(value) or 0 end
  return t
end

return lib
