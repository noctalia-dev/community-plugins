-- service.luau
-- Headless service: fetches each configured feed, extracts items (RSS <item>
-- or Atom <entry>), compares against what's already been seen, notifies on
-- new items, and publishes the unread count in noctalia.state for the widget.

local seen = {}          -- { [feedUrl] = { ids = { [itemId]=true, ... }, order = { id1, id2, ... } } }
local unread = 0
local recentItems = {}   -- list of the most recent items, newest first
local faviconCache = {}  -- { [domain] = localFilePath } - avoids re-downloading the same site's favicon
local dataPath = nil

local MAX_RECENT_ITEMS  = 50
local MAX_SEEN_PER_FEED = 300 -- cap on "already seen" ids kept per feed (prevents unbounded growth)

-- Limits to keep parsing fast enough for the (very tight) CPU budget of the
-- async callback.
local MAX_BODY_BYTES  = 8000   -- only look at the first ~8KB of the feed body
local MAX_ITEM_BYTES  = 700    -- trim each <item>/<entry> block before extracting tags (raised to fit enclosure/media:thumbnail)
local MAX_ITEMS       = 8      -- stop processing items after this many

local function isUtf8Continuation(b)
  return b ~= nil and b >= 0x80 and b < 0xC0
end

-- Cuts the string to at most n bytes, but never in the middle of a multibyte
-- UTF-8 character (accents, curly quotes, emoji, etc.) - cutting there
-- produces invalid bytes that the text renderer (Pango) rejects, leaving
-- labels (and by extension the whole panel) blank.
local function truncate(s, n)
  if not s or #s <= n then
    return s
  end
  local cut = n
  -- back off while the byte at this position is a continuation byte (0x80-0xBF)
  while cut > 0 and isUtf8Continuation(s:byte(cut)) do
    cut = cut - 1
  end
  -- if the remaining byte is the start of a multibyte sequence, only keep it
  -- if the whole sequence fits within the limit n; otherwise drop it too
  local b = cut > 0 and s:byte(cut) or nil
  if b and b >= 0xC0 then
    local seqLen = (b >= 0xF0 and 4) or (b >= 0xE0 and 3) or 2
    if cut + seqLen - 1 > n then
      cut = cut - 1
    end
  end
  return s:sub(1, cut)
end

-- Same "don't cut mid-UTF-8" logic, but working only with individual
-- indices/bytes (without materializing giant substrings) - used to bound the
-- size of an <item> block without copying the whole content before cutting.
local function safeCutEnd(xml, endPos, minPos)
  local pos = endPos
  while pos > minPos do
    local b = xml:byte(pos)
    if not b then
      break
    end
    if b < 0x80 then
      break -- ascii, safe
    elseif b >= 0xC0 then
      local seqLen = (b >= 0xF0 and 4) or (b >= 0xE0 and 3) or 2
      if pos + seqLen - 1 <= endPos then
        break -- the whole sequence fits up to endPos, safe
      end
      pos = pos - 1 -- doesn't fit whole, drop the lead byte too
    else
      pos = pos - 1 -- continuation byte, still mid-sequence
    end
  end
  return pos
end

-- Checks whether an item has already been seen and, if not, marks it as
-- seen - with a per-feed size cap (drops the oldest once over the limit), so
-- the "seen" structure never grows without bound (and blows up encode/save).
local function markSeen(url, id)
  local bucket = seen[url]
  if not bucket or not bucket.ids then
    bucket = { ids = {}, order = {} }
    seen[url] = bucket
  end
  if bucket.ids[id] then
    return false -- already seen
  end
  bucket.ids[id] = true
  table.insert(bucket.order, id)
  while #bucket.order > MAX_SEEN_PER_FEED do
    local oldest = table.remove(bucket.order, 1)
    bucket.ids[oldest] = nil
  end
  return true -- was new
end

local function isFirstRunForFeed(url)
  local bucket = seen[url]
  return not bucket or not bucket.order or #bucket.order == 0
end

-- Converts a Unicode codepoint to the equivalent UTF-8 byte sequence.
local function codepointToUtf8(cp)
  if not cp or cp < 0 then
    return ""
  elseif cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + (cp % 0x40))
  elseif cp < 0x10000 then
    return string.char(
      0xE0 + math.floor(cp / 0x1000),
      0x80 + (math.floor(cp / 0x40) % 0x40),
      0x80 + (cp % 0x40)
    )
  else
    return string.char(
      0xF0 + math.floor(cp / 0x40000),
      0x80 + (math.floor(cp / 0x1000) % 0x40),
      0x80 + (math.floor(cp / 0x40) % 0x40),
      0x80 + (cp % 0x40)
    )
  end
end

-- CP-1252 diverges from Latin-1 exactly in the 0x80-0x9F byte range: in
-- Latin-1 those are useless control codes, but in CP-1252 (the de-facto more
-- common charset in mislabeled feeds) they're curly quotes, dashes, ellipsis, etc.
local CP1252_HIGH = {
  [0x80] = 0x20AC, [0x82] = 0x201A, [0x83] = 0x0192, [0x84] = 0x201E,
  [0x85] = 0x2026, [0x86] = 0x2020, [0x87] = 0x2021, [0x88] = 0x02C6,
  [0x89] = 0x2030, [0x8A] = 0x0160, [0x8B] = 0x2039, [0x8C] = 0x0152,
  [0x8E] = 0x017D, [0x91] = 0x2018, [0x92] = 0x2019, [0x93] = 0x201C,
  [0x94] = 0x201D, [0x95] = 0x2022, [0x96] = 0x2013, [0x97] = 0x2014,
  [0x98] = 0x02DC, [0x99] = 0x2122, [0x9A] = 0x0161, [0x9B] = 0x203A,
  [0x9C] = 0x0153, [0x9E] = 0x017E, [0x9F] = 0x0178,
}

-- Converts a single Latin-1/CP-1252 byte (0x80-0xFF) to the equivalent UTF-8
-- sequence - used as a fallback when a byte doesn't form valid UTF-8.
local function latin1ByteToUtf8(b)
  local cp = CP1252_HIGH[b] or b -- 0xA0-0xFF: Latin-1 and CP-1252 match
  return codepointToUtf8(cp)
end

-- Fixes/normalizes text to valid UTF-8. When a byte doesn't form a valid
-- UTF-8 sequence, assumes Latin-1/CP-1252 (a wrong-charset case common in
-- older feeds, like Brazilian news sites) and CONVERTS instead of dropping -
-- so the accent shows up correctly instead of vanishing.
local function sanitizeUtf8(s)
  if not s then
    return s
  end
  local out = {}
  local i = 1
  local len = #s
  while i <= len do
    local b = s:byte(i)
    if b < 0x80 then
      out[#out + 1] = string.char(b)
      i = i + 1
    else
      local seqLen
      if b >= 0xF0 and b <= 0xF4 then
        seqLen = 4
      elseif b >= 0xE0 then
        seqLen = 3
      elseif b >= 0xC2 then
        seqLen = 2
      else
        seqLen = 0 -- invalid lead byte (0x80-0xC1)
      end

      local valid = seqLen > 0 and (i + seqLen - 1) <= len
      if valid then
        for k = 1, seqLen - 1 do
          local cb = s:byte(i + k)
          if not cb or cb < 0x80 or cb >= 0xC0 then
            valid = false
            break
          end
        end
      end

      if valid then
        out[#out + 1] = s:sub(i, i + seqLen - 1)
        i = i + seqLen
      else
        out[#out + 1] = latin1ByteToUtf8(b) -- convert instead of dropping
        i = i + 1
      end
    end
  end
  return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- Persistence (survives plugin/shell restarts)
-- ---------------------------------------------------------------------------

local function loadState()
  local dir = noctalia.pluginDataDir()
  if not dir then
    return
  end
  dataPath = dir .. "/state.json"

  local raw = noctalia.readFile(dataPath)
  if raw then
    local ok, decoded = pcall(noctalia.json.decode, raw)
    if ok and type(decoded) == "table" then
      seen        = decoded.seen or {}
      recentItems = decoded.recentItems or {}
      unread      = decoded.unread or 0
      faviconCache = decoded.faviconCache or {}

      -- migrate the old format ({ [id]=true, ... } directly) to the new one
      -- ({ ids=..., order=... }), if needed
      for url, bucket in pairs(seen) do
        if type(bucket) == "table" and not bucket.ids then
          local migrated = { ids = {}, order = {} }
          for id, v in pairs(bucket) do
            if v == true then
              migrated.ids[id] = true
              table.insert(migrated.order, id)
            end
          end
          seen[url] = migrated
        end
      end

      -- sanitize already-persisted items (may have been saved with broken
      -- UTF-8 by earlier versions of this plugin, before this fix)
      for _, item in ipairs(recentItems) do
        if item.title then
          item.title = sanitizeUtf8(item.title)
        end
        if item.feedTitle then
          item.feedTitle = sanitizeUtf8(item.feedTitle)
        end
      end
    end
  end
end

-- Never let an encode/write failure take down the entry (this already
-- caused the service to be disabled after several consecutive update() errors).
local function saveState()
  if not dataPath then
    return
  end
  local ok, encoded = pcall(noctalia.json.encode, {
    seen         = seen,
    recentItems  = recentItems,
    unread       = unread,
    faviconCache = faviconCache,
  })
  if ok and type(encoded) == "string" then
    pcall(noctalia.writeFile, dataPath, encoded)
  end
end

-- Same idea for publishing to noctalia.state: never propagate an error upward.
local function publishItems()
  local ok, encoded = pcall(noctalia.json.encode, recentItems)
  if ok and type(encoded) == "string" then
    noctalia.state.set("items", encoded)
  end
end

-- ---------------------------------------------------------------------------
-- Thumbnail download: ui.image only accepts a LOCAL file 'path', not a
-- remote URL (confirmed in the official Wallhaven plugin). So we download
-- the image into the plugin's cache and only then fill item.image with the
-- local path. Queue with a concurrency cap, same pattern as Wallhaven, to
-- avoid exceeding the host's simultaneous async operation limit.
-- ---------------------------------------------------------------------------

local THUMB_DIR = nil
local thumbQueue = {}
local thumbActive = 0
local MAX_THUMB_CONCURRENT = 2

local function shellQuote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function sanitizeFilename(s)
  return (tostring(s):gsub("[^%w%-]", "_")):sub(1, 80)
end

local function ensureThumbDir()
  local dir = noctalia.pluginDataDir()
  if not dir then
    return
  end
  THUMB_DIR = dir .. "/thumbs"
  noctalia.runAsync("mkdir -p " .. shellQuote(THUMB_DIR))
end

local pumpThumbQueue

pumpThumbQueue = function()
  while thumbActive < MAX_THUMB_CONCURRENT and #thumbQueue > 0 do
    local job = table.remove(thumbQueue, 1)
    thumbActive = thumbActive + 1
    noctalia.download(job.url, job.dest, function(ok)
      thumbActive = thumbActive - 1
      if ok then
        if job.domain then
          faviconCache[job.domain] = job.dest -- cache so other items from the same site reuse it
        end
        for _, item in ipairs(recentItems) do
          if item.id == job.id then
            item.image = job.dest
            break
          end
        end
        publishItems()
        saveState()
      else
        noctalia.log("rss-notifier: thumbnail download failed for " .. job.url)
        if job.domain then
          faviconCache[job.domain] = false -- remember the failure so we stop retrying this domain
          saveState()
        end
      end
      pumpThumbQueue()
    end)
  end
end

-- Downloads a feed item's own cover image (enclosure/media). One file per
-- item, since these URLs are essentially unique per item.
local function queueThumbDownload(id, url)
  if not THUMB_DIR or not url or url == "" then
    return
  end
  local dest = THUMB_DIR .. "/" .. sanitizeFilename(id) .. ".img"
  table.insert(thumbQueue, { id = id, url = url, dest = dest })
  pumpThumbQueue()
end

-- Resolves a site favicon for an item, reusing the cache when another item
-- from the same domain already downloaded it (favicons are per-SITE, not
-- per-item, so there's no reason to fetch the same one over and over).
-- faviconCache[domain] can be: nil (never tried), false (tried and failed -
-- don't retry), or a string (local path, ready to use).
local function queueFaviconDownload(id, domain, faviconUrl)
  if not THUMB_DIR or not domain then
    return
  end
  local cached = faviconCache[domain]
  if cached == false then
    return -- already know this domain has no favicon, don't hammer it again
  end
  if cached then
    for _, item in ipairs(recentItems) do
      if item.id == id then
        item.image = cached
        break
      end
    end
    publishItems()
    return
  end
  local dest = THUMB_DIR .. "/favicon-" .. sanitizeFilename(domain) .. ".img"
  table.insert(thumbQueue, { id = id, url = faviconUrl, dest = dest, domain = domain })
  pumpThumbQueue()
end

-- ---------------------------------------------------------------------------
-- Minimal RSS 2.0 / Atom 1.0 parsing using ONLY literal search (string.find
-- with plain=true) - avoids Lua's pattern engine (".-", "[^>]", etc.), which
-- turned out to be too expensive for this environment's CPU budget.
-- ---------------------------------------------------------------------------

-- (codepointToUtf8 was already defined above, near sanitizeUtf8 - reused here)

-- Most common named accent entities in Portuguese (not strict XML, but some
-- malformed feeds use them anyway).
local NAMED_ENTITIES = {
  aacute = 0xE1, eacute = 0xE9, iacute = 0xED, oacute = 0xF3, uacute = 0xFA,
  Aacute = 0xC1, Eacute = 0xC9, Iacute = 0xCD, Oacute = 0xD3, Uacute = 0xDA,
  atilde = 0xE3, otilde = 0xF5, Atilde = 0xC3, Otilde = 0xD5,
  acirc = 0xE2, ecirc = 0xEA, ocirc = 0xF4, Acirc = 0xC2, Ecirc = 0xCA, Ocirc = 0xD4,
  ccedil = 0xE7, Ccedil = 0xC7,
  agrave = 0xE0, egrave = 0xE8, Agrave = 0xC0, Egrave = 0xC8,
  uuml = 0xFC, Uuml = 0xDC, nbsp = 0x20, ndash = 0x2013, mdash = 0x2014,
  lsquo = 0x2018, rsquo = 0x2019, ldquo = 0x201C, rdquo = 0x201D,
  apos = 0x0027, hellip = 0x2026, bull = 0x2022,
}

local function decodeEntities(s)
  if not s then
    return s
  end
  s = s:gsub("&lt;", "<")
  s = s:gsub("&gt;", ">")
  s = s:gsub("&quot;", '"')
  s = s:gsub("&#39;", "'")
  -- decimal numeric refs: &#244;
  s = s:gsub("&#(%d+);", function(digits)
    return codepointToUtf8(tonumber(digits))
  end)
  -- hex numeric refs: &#xF4; or &#Xf4;
  s = s:gsub("&#[xX](%x+);", function(hex)
    return codepointToUtf8(tonumber(hex, 16))
  end)
  -- common named accent entities (non-strict-XML feeds)
  s = s:gsub("&(%a+);", function(name)
    local cp = NAMED_ENTITIES[name]
    return cp and codepointToUtf8(cp) or ("&" .. name .. ";")
  end)
  s = s:gsub("&amp;", "&") -- last, otherwise "&amp;lt;" would wrongly become "<"
  return sanitizeUtf8(noctalia.string.trim(s))
end

local function stripCdata(s)
  if s:sub(1, 9) == "<![CDATA[" then
    local endPos = s:find("]]>", 10, true)
    if endPos then
      return s:sub(10, endPos - 1)
    end
  end
  return s
end

-- Extracts the content of <tag>...</tag> using only literal find().
local function findTagContent(s, tag)
  local openStart = s:find("<" .. tag, 1, true)
  if not openStart then
    return nil
  end
  local openEnd = s:find(">", openStart, true)
  if not openEnd then
    return nil
  end
  local closeStart = s:find("</" .. tag .. ">", openEnd, true)
  if not closeStart then
    return nil
  end
  return decodeEntities(stripCdata(s:sub(openEnd + 1, closeStart - 1)))
end

-- Extracts an attribute value from inside the FIRST occurrence of <tag ...>.
local function findAttr(s, tag, attr)
  local openStart = s:find("<" .. tag, 1, true)
  if not openStart then
    return nil
  end
  local openEnd = s:find(">", openStart, true)
  if not openEnd then
    return nil
  end
  local tagSrc = s:sub(openStart, openEnd)
  local attrStart = tagSrc:find(attr .. '="', 1, true)
  if not attrStart then
    return nil
  end
  local valueStart = attrStart + #attr + 2
  local valueEnd = tagSrc:find('"', valueStart, true)
  if not valueEnd then
    return nil
  end
  return tagSrc:sub(valueStart, valueEnd - 1)
end

local function extractLink(block)
  local rssLink = findTagContent(block, "link") -- RSS: <link>URL</link>
  if rssLink and rssLink ~= "" then
    return rssLink
  end
  return findAttr(block, "link", "href") -- Atom: <link href="URL"/>
end

local function extractId(block)
  return findTagContent(block, "guid") or findTagContent(block, "id") or extractLink(block)
end

-- Tries to find a cover image for the item: <enclosure type="image/...">,
-- <media:thumbnail>, or <media:content medium="image">, in that order.
local function extractImage(block)
  local encUrl = findAttr(block, "enclosure", "url")
  if encUrl then
    local encType = findAttr(block, "enclosure", "type")
    if not encType or encType:find("image", 1, true) then
      return encUrl
    end
  end

  local thumbUrl = findAttr(block, "media:thumbnail", "url")
  if thumbUrl then
    return thumbUrl
  end

  local mediaUrl = findAttr(block, "media:content", "url")
  if mediaUrl then
    local medium = findAttr(block, "media:content", "medium")
    local mtype = findAttr(block, "media:content", "type")
    if (not medium and not mtype) or (medium == "image") or (mtype and mtype:find("image", 1, true)) then
      return mediaUrl
    end
  end

  return nil
end

-- Extracts the host from a URL (e.g. "https://example.com/path" -> "example.com"),
-- using only literal find()/sub() - no pattern engine.
local function extractDomain(url)
  if not url or url == "" then
    return nil
  end
  local schemeEnd = url:find("://", 1, true)
  local start = schemeEnd and (schemeEnd + 3) or 1
  local slashPos = url:find("/", start, true)
  local domain = slashPos and url:sub(start, slashPos - 1) or url:sub(start)

  local atPos = domain:find("@", 1, true)
  if atPos then
    domain = domain:sub(atPos + 1) -- strip a possible "user:pass@" prefix
  end
  local colonPos = domain:find(":", 1, true)
  if colonPos then
    domain = domain:sub(1, colonPos - 1) -- strip a possible ":port" suffix
  end

  if domain == "" then
    return nil
  end
  return domain
end

-- Fallback favicon URL for a site, used when the feed item has no image of
-- its own. Uses Google's favicon service instead of guessing /favicon.ico
-- paths or downloading+parsing the site's HTML, which would be much heavier.
local function faviconUrlFor(domain)
  return "https://www.google.com/s2/favicons?sz=64&domain=" .. domain
end


-- Finds the NEXT <tag ...>...</tag> block starting at fromPos, using only
-- literal find(). Returns the (already trimmed) block content and the
-- position to resume at on the next call - lets us process one item at a
-- time, across separate ticks, instead of everything at once inside the
-- http callback.
local function findNextBlock(xml, tag, fromPos, maxItemBytes)
  local openStart = xml:find("<" .. tag, fromPos, true)
  if not openStart then
    return nil, fromPos
  end
  local openEnd = xml:find(">", openStart, true)
  if not openEnd then
    return nil, fromPos
  end
  local closeTag = "</" .. tag .. ">"
  local closeStart = xml:find(closeTag, openEnd, true)
  if not closeStart then
    return nil, fromPos
  end
  local contentEnd = math.min(closeStart - 1, openEnd + maxItemBytes)
  if contentEnd < closeStart - 1 then
    -- only need to fix the UTF-8 boundary when the cut was actually caused
    -- by the byte limit (not by the closing tag, which is already a safe boundary)
    contentEnd = safeCutEnd(xml, contentEnd, openEnd)
  end
  local block = xml:sub(openEnd + 1, contentEnd)
  return block, closeStart + #closeTag
end

-- ---------------------------------------------------------------------------
-- Incremental processing queue: the http callback only stores the (already
-- trimmed) body in the queue; the actual parsing happens gradually, one item
-- per update() tick, because the async callback's CPU budget is too small
-- to process a whole feed at once.
-- ---------------------------------------------------------------------------

local queue = {} -- list of { url=, body=, pos=, tag=, feedTitle=, items=, notifyBudget= }

local function enqueueFeed(url, body, notifyBudget)
  table.insert(queue, {
    url          = url,
    body         = truncate(body, MAX_BODY_BYTES),
    pos          = 1,
    tag          = "item",
    triedEntry   = false,
    feedTitle    = nil,
    items        = {},
    notifyBudget = notifyBudget,
  })
end

-- Finalizes a feed from the queue: compares against what's already been
-- seen, notifies on new items, and publishes state. This is an isolated
-- step (not mixed with item extraction) to keep each callback small.
local function finalizeFeed(f)
  local url = f.url
  local firstRun = isFirstRunForFeed(url)
  local notifyEnabled = noctalia.getConfig("notify_new")
  local newCount = 0

  for _, item in ipairs(f.items) do
    local id = item.id or item.link or item.title
    if id and markSeen(url, id) then
      newCount = newCount + 1

      if not firstRun then
        table.insert(recentItems, 1, {
          id        = id,
          title     = item.title,
          link      = item.link,
          feedTitle = f.feedTitle,
          image     = nil, -- filled in later with the LOCAL path, once the download finishes
        })
        if item.image and item.image ~= "" then
          queueThumbDownload(id, item.image)
        else
          -- prefer the FEED's own domain: item links often go through
          -- redirect/tracking subdomains (e.g. redir.example.com) that have
          -- no favicon of their own, while the feed's domain is reliably the
          -- real site
          local domain = extractDomain(url) or extractDomain(item.link)
          if domain then
            queueFaviconDownload(id, domain, faviconUrlFor(domain))
          end
        end
        if notifyEnabled and f.notifyBudget.count < f.notifyBudget.max then
          f.notifyBudget.count = f.notifyBudget.count + 1
          noctalia.notify(item.title, f.feedTitle)
        end
      end
    end
  end

  while #recentItems > MAX_RECENT_ITEMS do
    table.remove(recentItems)
  end

  if not firstRun and newCount > 0 then
    unread = unread + newCount
    noctalia.state.set("unread", unread)
    publishItems()
  end

  saveState()
end

-- Processes ONE small step of the queue: extracts at most one item from the
-- feed at the front of the queue. Called once per update() tick.
local function processQueueStep()
  local f = queue[1]
  if not f then
    return
  end

  if not f.feedTitle then
    f.feedTitle = findTagContent(truncate(f.body, 300), "title") or f.url
    return -- one step per tick: just the title this time
  end

  if #f.items >= MAX_ITEMS then
    table.remove(queue, 1)
    finalizeFeed(f)
    return
  end

  local block, nextPos = findNextBlock(f.body, f.tag, f.pos, MAX_ITEM_BYTES)

  if not block then
    if f.tag == "item" and not f.triedEntry then
      -- no RSS found: try Atom (<entry>) from the start
      f.tag = "entry"
      f.pos = 1
      f.triedEntry = true
      return
    end
    -- ran out of items (or found none) - finalize
    table.remove(queue, 1)
    finalizeFeed(f)
    return
  end

  f.pos = nextPos
  table.insert(f.items, {
    title = findTagContent(block, "title") or "(sem titulo)",
    link  = extractLink(block),
    id    = extractId(block),
    image = extractImage(block),
  })
end

-- ---------------------------------------------------------------------------
-- Fetch cycle
-- ---------------------------------------------------------------------------

local function checkFeed(url, notifyBudget)
  -- the http callback does the BARE MINIMUM: just stores the body in the
  -- queue. All the real parsing happens later, gradually, in processQueueStep().
  noctalia.http({ url = url, headers = { "Accept: application/rss+xml, application/atom+xml, application/xml, text/xml" } }, function(res)
    if not res.ok or not res.body or res.body == "" then
      return
    end
    enqueueFeed(url, res.body, notifyBudget)
  end)
end

local function fetchAll()
  local urls = noctalia.getConfig("feed_urls") or {}
  local notifyBudget = { count = 0, max = noctalia.getConfig("max_notifications_per_cycle") or 5 }

  for _, url in ipairs(urls) do
    if url and noctalia.string.trim(url) ~= "" then
      checkFeed(url, notifyBudget)
    end
  end
end

local REFRESH_TICK_MS = 1000 -- update() runs every second: drains the queue gradually
local ticksUntilFetch = 1

local function applyInterval()
  local minutes = noctalia.getConfig("refresh_minutes") or 30
  if minutes < 1 then
    minutes = 1
  end
  noctalia.setUpdateInterval(REFRESH_TICK_MS)
  ticksUntilFetch = math.floor((minutes * 60000) / REFRESH_TICK_MS)
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

loadState()
ensureThumbDir()
applyInterval()
noctalia.state.set("unread", unread)
publishItems()
fetchAll() -- first read: just marks items as "seen", without notifying (firstRun)

function update()
  processQueueStep() -- always drains a little bit of the queue, if there's anything

  ticksUntilFetch = ticksUntilFetch - 1
  if ticksUntilFetch <= 0 then
    fetchAll()
    local minutes = noctalia.getConfig("refresh_minutes") or 30
    if minutes < 1 then
      minutes = 1
    end
    ticksUntilFetch = math.floor((minutes * 60000) / REFRESH_TICK_MS)
  end
end

function onConfigChanged()
  applyInterval()
  fetchAll()
end

function onIpc(_event, payload)
  if _event == "refresh" then
    fetchAll()
  elseif _event == "mark-read" then
    unread = 0
    noctalia.state.set("unread", 0)
  elseif _event == "dismiss" and payload then
    for i, item in ipairs(recentItems) do
      if item.id == payload then
        table.remove(recentItems, i)
        break
      end
    end
    publishItems()
    saveState()
  elseif _event == "clear-all" then
    recentItems = {}
    publishItems()
    saveState()
  end
end
