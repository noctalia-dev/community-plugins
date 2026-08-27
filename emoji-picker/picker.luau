--!nonstrict
-- Emoji & symbol picker panel — Raycast-inspired browser for Noctalia.
--
-- One script serves the three [[panel]] entries in plugin.toml (wide /
-- desktop / compact): the surface size is manifest-owned, the grid tier
-- (columns / cell / glyph size) is derived here from the FOCUSED output's
-- logical width. Dataset: assets/emoji.json (committed data generated
-- from pinned Unicode CLDR + UnicodeData sources — see tools/ and
-- README.md). Usage state lives in pluginDataDir()/usage.json.
--
-- The dataset has two entry types sharing this whole UI — search, grid,
-- keyboard, recents, copy/paste — keyed apart by the s field:
--   * emoji  (s absent): CLDR names + keywords
--   * symbol (s == 1):   plain Unicode characters (€ ± → … π) with
--     name-class aliases (a) — "arrow right", "plusminus", "gbp" — so a
--     query that names a symbol ranks the symbol itself at the top
--     instead of a pile of semantically related emoji. See wordTier.
--
-- Keyboard model (see plugin.toml capture_keys):
--   * typing goes to the focused search input (the host routes plain
--     printable keys there before consulting capture keys),
--   * arrows + Enter are captured and handled by onKey below,
--   * Escape is reserved by the host and simply closes the panel.

-- ── Categories (order = browse order; glyphs validated against the
-- shell's bundled tabler.json) ─────────────────────────────────────────
local CATEGORIES = {
  { id = "smileys",  label = "Smileys & People", glyph = "mood-smile" },
  { id = "animals",  label = "Animals & Nature", glyph = "paw" },
  { id = "food",     label = "Food & Drink",     glyph = "apple" },
  { id = "activity", label = "Activities",       glyph = "ball-football" },
  { id = "travel",   label = "Travel & Places",  glyph = "map" },
  { id = "objects",  label = "Objects",          glyph = "device-floppy" },
  { id = "symbols",  label = "Symbols",          glyph = "at" },
  { id = "chars",    label = "Characters",       glyph = "math-symbols" },
  { id = "flags",    label = "Flags",            glyph = "flag" },
}

-- Layout tiers, selected by the focused output's logical width. The
-- thresholds pair with the [[panel]] entries in plugin.toml: bind the
-- entry whose size suits the output you open it on. cols fills the
-- manifest panel width at `cell` px + 6px gaps + 16px padding + ~10px
-- scrollbar slack.
local TIERS = {
  { min = 2560, cols = 9, cell = 72, glyph = 34 }, -- 3440×1440 ultrawide
  { min = 1600, cols = 8, cell = 66, glyph = 30 }, -- 1920×1080 class
  { min = 0,    cols = 6, cell = 58, glyph = 26 }, -- laptop panels
}

local GAP = 6
local MAX_SEARCH_RESULTS = 300
local RECENCY_HALF_LIFE_DAYS = 14.0

-- ── State ──────────────────────────────────────────────────────────────
local data = nil -- dataset array, lazily loaded atomically on first open
local byCat = nil -- { [catId] = {entry, …} } browse list (no skin-tone variants)
local emojiIndex = nil -- { [emoji] = entry }
local usage = nil -- { [emoji] = { c = count, t = last_used_epoch_s } }
local usagePath = nil

local tier = TIERS[1]
local cat = "smileys" -- browse category; "all" renders every section (slower)
local query = ""
local inputKey = 0 -- bump to recreate the input (clears its host-owned buffer)
local items = {} -- flat item list for the current view (entry tables)
local rows = {} -- { { base = first item index, len = n }, … }
local rowOfItem = {} -- item index -> row index
local sel = 0 -- focused item index into `items` (0 = none)

-- Incremental rendering: building all of "items" as UI nodes on the first
-- open (up to ~560 tiles for one category) is the dominant cost of open
-- latency, so the grid renders only the first `renderLimit` ROWS and grows
-- as the user scrolls near the bottom (onScroll below) or arrows past the
-- rendered edge (ensureRowRendered). `rows`/`rowOfItem` above stay full —
-- keyboard math always sees the true layout — only the UI TREE is capped.
local INITIAL_RENDER_ROWS = 8
local RENDER_ROWS_STEP = 10
local renderLimit = INITIAL_RENDER_ROWS

-- ── Data & frecency ────────────────────────────────────────────────────
local function nowSec()
  return noctalia.nowMs() / 1000.0
end

local function loadUsage()
  usage = {}
  if usagePath == nil then
    local dir = noctalia.pluginDataDir()
    if dir == "" then
      return
    end
    usagePath = dir .. "/usage.json"
  end
  local content = noctalia.readFile(usagePath)
  if type(content) == "string" then
    local ok, parsed = pcall(noctalia.json.decode, content)
    if ok and type(parsed) == "table" then
      for emoji, u in pairs(parsed) do
        if type(u) == "table" and type(u.c) == "number" and type(u.t) == "number" then
          usage[emoji] = { c = u.c, t = u.t }
        end
      end
    end
  end
end

local function saveUsage()
  if usagePath ~= nil then
    local dir = usagePath:match("^(.*)/")
    if dir ~= nil then
      noctalia.mkdirAll(dir)
    end
    pcall(function()
      noctalia.writeFile(usagePath, noctalia.json.encode(usage))
    end)
  end
end

-- Frequency with a recency decay: each pick counts, but a pick from last
-- month is worth far less than one from today.
local function frecencyScore(count, lastUsed, now)
  if count <= 0 then
    return 0.0
  end
  local ageDays = math.max(0.0, now - lastUsed) / 86400.0
  return count * (0.5 ^ (ageDays / RECENCY_HALF_LIFE_DAYS))
end

local function frecency(emoji, now)
  local u = usage[emoji]
  if u == nil then
    return 0.0
  end
  return frecencyScore(u.c, u.t, now)
end

local function ensureData()
  if data ~= nil then
    return
  end
  local content = noctalia.readFile("assets/emoji.json")
  if type(content) ~= "string" then
    data = {}
    byCat = {}
    emojiIndex = {}
    return
  end
  local ok, parsed = pcall(noctalia.json.decode, content)
  local nextData = (ok and type(parsed) == "table") and parsed or {}
  local nextByCat = {}
  local nextEmojiIndex = {}
  -- l/z and k/a arrive pre-normalised and pre-indexed by the generator.
  -- Keep this loop allocation-light: it runs in the first onOpen callback,
  -- which has a hard CPU budget. Build into locals and publish all three
  -- structures only after the loop completes; a timeout/error can therefore
  -- never expose a half-indexed dataset to onChange (the former find(nil)
  -- follow-on failure that made Noctalia disable the panel).
  for _, e in ipairs(nextData) do
    nextEmojiIndex[e.e] = e
    -- Skin-tone variants stay searchable but never clutter the browse grid.
    if string.find(e.n, "skin tone", 1, true) == nil then
      local list = nextByCat[e.c]
      if list == nil then
        list = {}
        nextByCat[e.c] = list
      end
      table.insert(list, e)
    end
  end
  data = nextData
  byCat = nextByCat
  emojiIndex = nextEmojiIndex
end

local function recents(now, n)
  local scored = {}
  for emoji, u in pairs(usage) do
    if emojiIndex[emoji] ~= nil and u.c > 0 then
      table.insert(scored, { emoji = emoji, score = frecencyScore(u.c, u.t, now) })
    end
  end
  table.sort(scored, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    return a.emoji < b.emoji
  end)
  local out = {}
  for i = 1, math.min(n, #scored) do
    table.insert(out, emojiIndex[scored[i].emoji])
  end
  return out
end

-- ── Search (relevance dominates; frecency is a small tie-breaker) ──────
-- Per word, the BEST of the entry's match classes:
--   character: the query word IS the entry itself (typing/pasting "€")
--     1100 — beats every name match.
--   name: exact full name 1000 / word-boundary match 700 (w occurs in the
--     name starting at position 1 or right after a space — "hearts" and
--     "heart-eyes" both count as a "heart" word-boundary match, "sweetheart"
--     does not) / substring anywhere else, no boundary, e.g. "art" inside
--     "heart" 250.
--   keyword: exact 450 / prefix 150 / substring 80.
-- Symbol entries (s == 1 — € ± → π, the "chars" category) score their
-- curated aliases (a) like names — they ARE the names people type — and
-- sit slightly above the emoji name classes: alias/name exact 1000,
-- alias/name word-boundary 900, name substring 500. So a query that
-- clearly names a symbol ranks the symbol itself first ("euro" → €
-- before 💶, "arrow right" → → before ➡️) while emoji keep ranking
-- naturally for emoji-oriented queries ("star" still puts ⭐ first — no
-- symbol is named exactly "star").
-- All query words must match (AND); the entry's tier is its WEAKEST word.
-- A word-boundary name match always outranks a keyword-only match: the
-- short name is an entry's primary identity, keywords are secondary
-- aliases. Ranking "smiling face with hearts" (a name SUBSTRING match on
-- "heart") above "red heart" (a name word-boundary match) is exactly the
-- bug this replaced.
--
-- Entries tied on tier: a symbol beats an emoji (the query named a
-- character), then SPECIFICITY, not dataset order: fewer name words,
-- then a shorter name, wins — "red heart" (2 words, 9 chars) reads ahead
-- of "smiling face with hearts" (4 words) and every other equally
-- matching colour/decorated heart, because a short, focused name is more
-- centrally "about" the matched word than a longer compound one.
-- Frecency (capped) breaks any tie still remaining, then dataset order.
--
-- Plain substring scans throughout, no per-entry token arrays: this runs
-- over the full ~4000-entry dataset on every keystroke inside the host's
-- 25ms script-callback CPU budget, and allocating a tokens table per
-- entry (in ensureData, unconditionally, for entries most searches never
-- touch) blew that budget on open — confirmed live (onOpen errored
-- "exceeded its CPU budget" with a naive tokens-array version of this
-- search). nameWordCount below still allocates nothing; it is only ever
-- called for entries that already matched, a small fraction of the
-- dataset. Symbol alias scans add the same cost class as the keyword
-- loop over a similar-length array.
local function isWordBoundaryMatch(n, w)
  local from = 1
  while true do
    local s = string.find(n, w, from, true)
    if s == nil then
      return false
    end
    if s == 1 or string.sub(n, s - 1, s - 1) == " " then
      return true
    end
    from = s + 1
  end
end

local function nameWordCount(n)
  local count = 0
  for _ in string.gmatch(n, "%S+") do
    count += 1
  end
  return count
end

local function wordTier(entry, w)
  -- Typing or pasting the literal character finds it directly.
  if entry.e == w then
    return 1100
  end
  -- One find over the entry's pre-built search blob replaces ~20 finds
  -- over name/keywords/aliases for every entry that cannot match at all
  -- — the difference between fitting the host's per-keystroke CPU
  -- budget and not on broad prefixes (confirmed live).
  if string.find(entry.z, w, 1, true) == nil then
    return 0
  end
  local single = #w == 1
  local symbol = entry.s == 1
  local n = entry.l
  local best = 0
  -- Symbol aliases first: name-class, so a symbol whose alias IS the
  -- query ("euro", "arrow right", "plusminus") matches at full strength
  -- instead of sinking into the weaker emoji-keyword class.
  if symbol and entry.a ~= nil then
    for _, x in ipairs(entry.a) do
      if x == w then
        best = 1000
        break
      end
    end
  end
  if best < 1000 and n == w then
    best = 1000
  end
  if best < 900 and isWordBoundaryMatch(n, w) then
    best = if symbol then 900 else 700
  end
  if best < 900 and symbol and entry.a ~= nil then
    for _, x in ipairs(entry.a) do
      if isWordBoundaryMatch(x, w) then
        best = 900
        break
      end
    end
  end
  if best < 450 then
    for _, k in ipairs(entry.k) do
      local t = 0
      if k == w then
        t = 450
      elseif single then
        -- Single-character words are the every-keystroke typing state:
        -- keyword EXACT matches only (🅰 for "a"). The prefix/substring
        -- find scans over every keyword were the dominant cost of broad
        -- prefixes and only ever produced deep-tail tiers.
        t = 0
      elseif #k >= #w and string.sub(k, 1, #w) == w then
        t = 150
      elseif string.find(k, w, 1, true) then
        t = 80
      end
      if t > best then
        best = t
      end
    end
  end
  if string.find(n, w, 1, true) then
    best = math.max(best, if symbol then 500 else 250)
  end
  return best
end

local function search(now)
  local words = {}
  for w in string.gmatch(string.lower(query), "%S+") do
    table.insert(words, w)
  end
  local scored = {}
  -- Broad queries (a single "e") match thousands of entries, and sorting
  -- them all once blew the host's per-callback CPU budget on the first
  -- keystroke (confirmed live). Only the top MAX_SEARCH_RESULTS are ever
  -- shown, so once the kept set is full, entries at or below its weakest
  -- tier are skipped WITHOUT building a scored row (frecency, word count,
  -- insert). Strictly-better tiers still enter, so the bounded set stays
  -- a superset of the true top slice; only equal-tier ordering beyond the
  -- cap can differ from an exact full sort — invisible results nobody
  -- scrolls to.
  local minKeptTier = 1200
  for idx, e in ipairs(data) do
    local tierScore = 1000
    for _, w in ipairs(words) do
      local t = wordTier(e, w)
      if t == 0 then
        tierScore = 0
        break
      end
      if t < tierScore then
        tierScore = t
      end
    end
    if tierScore > 0 and (#scored < MAX_SEARCH_RESULTS or tierScore > minKeptTier) then
      local f = frecency(e.e, now)
      if f > 25 then
        f = 25 -- cap the tie-breaker: usage never outranks relevance
      end
      table.insert(
        scored,
        { e = e, tier = tierScore, s = e.s == 1, nwords = nameWordCount(e.l), nlen = #e.l, f = f, i = idx }
      )
      if tierScore < minKeptTier then
        minKeptTier = tierScore
      end
    end
  end
  table.sort(scored, function(a, b)
    if a.tier ~= b.tier then
      return a.tier > b.tier
    end
    -- Equal relevance: the query named a character, so the symbol beats
    -- an equally-scoring emoji ("copyright" → © before the ©️ emoji).
    if a.s ~= b.s then
      return a.s
    end
    if a.nwords ~= b.nwords then
      return a.nwords < b.nwords
    end
    if a.nlen ~= b.nlen then
      return a.nlen < b.nlen
    end
    if a.f ~= b.f then
      return a.f > b.f
    end
    return a.i < b.i
  end)
  local out = {}
  for i = 1, math.min(MAX_SEARCH_RESULTS, #scored) do
    table.insert(out, scored[i].e)
  end
  return out
end

-- ── View model ─────────────────────────────────────────────────────────
local function searchActive()
  -- A query of only whitespace behaves as "no query" (browse view).
  return string.find(query, "%S") ~= nil
end

local function buildView()
  ensureData()
  items = {}
  rows = {}
  rowOfItem = {}

  local function addSection(entries)
    for base = 1, #entries, tier.cols do
      local len = math.min(tier.cols, #entries - base + 1)
      local rowIndex = #rows + 1
      rows[rowIndex] = { base = #items + 1, len = len }
      for i = base, base + len - 1 do
        rowOfItem[#items + 1] = rowIndex
        table.insert(items, entries[i])
      end
    end
  end

  if searchActive() then
    addSection(search(nowSec()))
  else
    local recent = recents(nowSec(), tier.cols * 2)
    if #recent > 0 then
      addSection(recent)
    end
    if cat == "all" then
      for _, c in ipairs(CATEGORIES) do
        addSection(byCat[c.id] or {})
      end
    else
      addSection(byCat[cat] or {})
    end
  end

  if sel < 1 or sel > #items then
    sel = if #items > 0 then 1 else 0
  end
  renderLimit = math.min(#rows, INITIAL_RENDER_ROWS)
end

-- Grows the render budget so the row a keyboard move lands on is always
-- built (arrows can otherwise select a not-yet-rendered — but real —
-- item; there is no scroll-into-view API for plugin panels, so this at
-- least guarantees the tile exists once the user scrolls to it).
local function ensureRowRendered(rowIndex)
  if rowIndex > renderLimit then
    renderLimit = math.min(#rows, rowIndex)
  end
end

local function moveSelection(dr, dc)
  if #items == 0 then
    return
  end
  if dr == 0 then
    sel = math.min(#items, math.max(1, sel + dc))
  else
    local row = rowOfItem[sel] or 1
    local col = sel - rows[row].base + 1
    local target = math.min(#rows, math.max(1, row + dr))
    col = math.min(col, rows[target].len)
    sel = rows[target].base + col - 1
  end
  ensureRowRendered(rowOfItem[sel] or 1)
end

-- ── Actions ────────────────────────────────────────────────────────────
local function shellQuote(s)
  return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

-- Optional paste step after the clipboard copy. The shell cannot inject
-- keystrokes into an arbitrary window portably (every compositor handles
-- focus security differently, and virtual-keyboard injection needs tools
-- most setups don't run), so instead of shipping compositor-specific
-- machinery the panel runs whatever command the USER configured in the
-- `paste_command` setting: {emoji} is replaced with the shell-quoted
-- character. Empty (the default) means copy to the clipboard only.
-- Examples users can configure themselves:
--   ydotool key -d 20 29:1 47:1 47:0 29:0   (press Ctrl+V after the copy)
--   wtype {emoji}                            (type the character literally)
local function pasteWithConfiguredCommand(emoji)
  local cmd = noctalia.getConfig("paste_command")
  if type(cmd) ~= "string" or cmd == "" then
    return
  end
  local quoted = shellQuote(emoji)
  -- Function replacement: the quoted emoji must not be interpreted as a
  -- gsub pattern replacement (e.g. a literal % or trailing digit).
  noctalia.runAsync((string.gsub(cmd, "{emoji}", function()
    return quoted
  end)))
end

local function commit(entry)
  if entry == nil then
    return
  end
  local now = nowSec()
  local u = usage[entry.e]
  if u == nil then
    u = { c = 0, t = now }
    usage[entry.e] = u
  end
  u.c += 1
  u.t = now
  saveUsage()
  -- (text, mime) — the binding requires both; plain UTF-8 text.
  noctalia.copyToClipboard(entry.e, "text/plain;charset=utf-8")
  pasteWithConfiguredCommand(entry.e)
  panel.close()
end

-- ── Rendering ──────────────────────────────────────────────────────────
local render -- forward declaration (closures below call it)

local function tile(entry, idx)
  return ui.button({
    key = "t" .. tostring(idx),
    text = entry.e,
    fontSize = tier.glyph,
    width = tier.cell,
    height = tier.cell,
    contentAlign = "center",
    tooltip = entry.n,
    onClick = function()
      commit(entry)
    end,
    onHover = function()
      if sel ~= idx then
        sel = idx
        render()
      end
    end,
  })
end

-- `entries` must be the same slice of `items` that buildView laid out,
-- starting at flat item index `startIndex` (keeps tiles' idx in sync with
-- the keyboard model). `budget` caps how many ROWS this call may add —
-- shared across every sectionBlock call in one gridArea() build, so the
-- cap applies to the whole view, not per-section (see renderLimit above).
local function sectionBlock(label, entries, startIndex, budget)
  local children = {}
  if label ~= nil then
    table.insert(children, ui.label({
      key = "h" .. label,
      text = label,
      fontSize = 11,
      fontWeight = "semibold",
      color = "on_surface_variant",
    }))
  end
  if #entries == 0 then
    return children
  end
  for base = 1, #entries, tier.cols do
    if budget.remaining <= 0 then
      break
    end
    local rowChildren = {}
    for i = base, math.min(base + tier.cols - 1, #entries) do
      table.insert(rowChildren, tile(entries[i], startIndex + i - 1))
    end
    table.insert(children, ui.row({
      key = "r" .. tostring(startIndex) .. "-" .. tostring(base),
      gap = GAP,
      align = "center",
    }, rowChildren))
    budget.remaining -= 1
  end
  return children
end

local function categoryStrip()
  local buttons = {}
  local function catButton(id, glyph, label)
    table.insert(buttons, ui.button({
      key = "cat-" .. id,
      glyph = glyph,
      glyphSize = 18,
      variant = if cat == id then "secondary" else "ghost",
      width = 34,
      height = 30,
      tooltip = label,
      onClick = function()
        cat = id
        query = ""
        inputKey += 1 -- recreate the input: clears its host-owned buffer
        sel = 1
        buildView()
        render()
      end,
    }))
  end
  catButton("all", "layout-grid", "All")
  for _, c in ipairs(CATEGORIES) do
    catButton(c.id, c.glyph, c.label)
  end
  return ui.row({ key = "cats", gap = 2, align = "center" }, buttons)
end

local function gridArea()
  if #items == 0 then
    local message = if searchActive() then "No results found" else "No results"
    return ui.column({
      key = "empty",
      align = "center",
      justify = "center",
      flexGrow = 1,
      gap = 8,
    }, {
      ui.glyph({ name = "search", size = 28, color = "on_surface_variant" }),
      ui.label({ text = message, color = "on_surface_variant" }),
    })
  end

  local children = {}
  local budget = { remaining = renderLimit }
  if searchActive() then
    -- Search view: one borderless grid of results.
    local section = {}
    for i = 1, #items do
      table.insert(section, items[i])
    end
    for _, b in ipairs(sectionBlock(nil, section, 1, budget)) do
      table.insert(children, b)
    end
  else
    -- Browse view: Frequently Used + category sections.
    local startIndex = 1
    local recent = recents(nowSec(), tier.cols * 2)
    if #recent > 0 then
      for _, b in ipairs(sectionBlock("Frequently Used", recent, startIndex, budget)) do
        table.insert(children, b)
      end
      startIndex += #recent
    end
    local sections = {}
    if cat == "all" then
      for _, c in ipairs(CATEGORIES) do
        table.insert(sections, { label = c.label, entries = byCat[c.id] or {} })
      end
    else
      for _, c in ipairs(CATEGORIES) do
        if c.id == cat then
          table.insert(sections, { label = c.label, entries = byCat[c.id] or {} })
        end
      end
    end
    for _, s in ipairs(sections) do
      for _, b in ipairs(sectionBlock(s.label, s.entries, startIndex, budget)) do
        table.insert(children, b)
      end
      startIndex += #s.entries
    end
  end

  return ui.scroll({
    key = "grid",
    flexGrow = 1,
    gap = GAP,
    align = "start",
    paddingH = 2,
    -- Grow the render budget as the user scrolls near the bottom — the
    -- first paint only builds INITIAL_RENDER_ROWS, so opening a large
    -- category (500+ emoji) stays fast; scrolling fills in the rest.
    onScroll = function(offset, maxOffset)
      local off = tonumber(offset) or 0
      local mx = tonumber(maxOffset) or 0
      if renderLimit < #rows and mx - off < 400 then
        renderLimit = math.min(#rows, renderLimit + RENDER_ROWS_STEP)
        render()
      end
    end,
  }, children)
end

local function footer()
  local entry = items[sel]
  local emoji = if entry ~= nil then entry.e else ""
  local name = if entry ~= nil
    then entry.n
    elseif searchActive() then "No results found" else "Type to search"
  return ui.column({ key = "footer", gap = 8 }, {
    ui.separator({ key = "foot-sep" }),
    ui.row({ key = "foot-row", align = "center", gap = 10 }, {
      ui.label({ key = "foot-emoji", text = emoji, fontSize = 16, width = 24 }),
      ui.label({
        key = "foot-name",
        text = name,
        fontSize = 12,
        color = "on_surface_variant",
        flexGrow = 1,
        maxLines = 1,
      }),
      ui.label({
        key = "foot-hint",
        text = "Enter  Select      Esc  Close",
        fontSize = 11,
        color = "on_surface_variant",
      }),
    }),
  })
end

render = function()
  panel.render(ui.column({
    key = "root",
    flexGrow = 1,
    align = "stretch",
    gap = 10,
    padding = 16,
    fill = "surface",
    radius = 16,
  }, {
    -- NB: no flexGrow here — this input sits directly in a column, where
    -- flexGrow would stretch it VERTICALLY into a giant field. Width comes
    -- from the column's cross-axis stretch.
    ui.input({
      key = "q-" .. tostring(inputKey),
      value = query,
      placeholder = "Search Emoji & Symbols…",
      fontSize = 15,
      focus = true,
      controlSize = "lg",
      onChange = function(value)
        query = if type(value) == "string" then value else ""
        sel = 1
        buildView()
        render()
      end,
    }),
    gridArea(),
    footer(),
  }))
end

-- ── Lifecycle ──────────────────────────────────────────────────────────
local function pickTier()
  local width = 0
  for _, out in ipairs(noctalia.outputs()) do
    if out.focused then
      width = tonumber(out.width) or 0
      break
    end
  end
  for _, t in ipairs(TIERS) do
    if width >= t.min then
      tier = t
      return
    end
  end
  tier = TIERS[#TIERS]
end

function onOpen(_context)
  ensureData()
  loadUsage()
  pickTier()
  query = ""
  cat = "smileys"
  inputKey += 1 -- fresh input: empty buffer, immediate focus
  sel = 1
  buildView()
  render()
end

function onKey(chord, pressed)
  if not pressed then
    return
  end
  if chord == "left" then
    moveSelection(0, -1)
  elseif chord == "right" then
    moveSelection(0, 1)
  elseif chord == "up" then
    moveSelection(-1, 0)
  elseif chord == "down" then
    moveSelection(1, 0)
  elseif chord == "enter" then
    commit(items[sel])
    return
  end
  render()
end
