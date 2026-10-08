-- Search/ranking/interaction tests for the emoji & symbol picker panel.
--
-- This file is the tail of a script assembled by build_test.py, which
-- prepends the REAL generated dataset as `local DATASET` and the verbatim
-- picker.luau source as `local PICKER_SRC`. It runs under the stock luau
-- CLI with the noctalia/ui/panel host APIs stubbed — picker.luau itself
-- is loaded unmodified except for an appended export tail (same-chunk
-- scope), so these tests exercise exactly the shipped search, keyboard
-- model and commit path.

local failures = 0
local passed = 0
local function check(cond, msg)
  if cond then
    passed += 1
  else
    failures += 1
    print("FAIL: " .. msg)
  end
end

local function firstChar(results)
  return results[1] ~= nil and results[1].e or nil
end

local function indexOf(results, char)
  for i, r in ipairs(results) do
    if r.e == char then
      return i
    end
  end
  return nil
end

-- ── Host API stubs ─────────────────────────────────────────────────────
local copied = {}
local closedPanel = 0
-- Failure-injection flags read by the stubs at CALL time (see readFile).
local fs = { fail = false, badJson = false, raiseDecode = false }
noctalia = {
  nowMs = function()
    return 1700000000000
  end,
  pluginDataDir = function()
    return "" -- usage file disabled; in-memory usage still works
  end,
  readFile = function(p)
    -- Behaviour is flag-driven, not stub-swapped: the stock luau CLI
    -- sandbox snapshots a loadstring chunk's view of global-table fields
    -- at chunk creation, so tests flip `fs.fail` instead of reassigning
    -- this stub and every chunk (existing or future) sees the change.
    if fs.fail then
      return nil, "cannot open file"
    end
    if p == "assets/emoji.json" then
      return "DATASET"
    end
    return nil
  end,
  writeFile = function() end,
  log = function() end,
  json = {
    decode = function(s)
      if s == "DATASET" then
        if fs.badJson then
          return nil, "bad json"
        end
        if fs.raiseDecode then
          -- Mirror the host's CPU-budget interrupt: it raises a Luau
          -- error from inside the binding at the next VM instruction,
          -- which used to land inside a pcall and publish an EMPTY
          -- dataset as if it were valid (#700).
          error("script callback 'chunk' exceeded its CPU budget", 0)
        end
        return DATASET
      end
      return nil
    end,
    encode = function()
      return "{}"
    end,
  },
  getConfig = function() return nil end,
  runAsync = function() end,
  copyToClipboard = function(text, mime)
    table.insert(copied, { text = text, mime = mime })
  end,
}
ui = setmetatable({}, {
  __index = function(_, k)
    return function(opts)
      return { kind = k, opts = opts }
    end
  end,
})
panel = {
  render = function() end,
  close = function()
    closedPanel += 1
  end,
}

-- ── Load picker.luau with an export tail (runs in the same chunk scope,
-- so the module's locals are reachable). Note picker.luau loads the
-- dataset at chunk time now, so simply CONSTRUCTING the chunk performs
-- the full read → decode → index pass under the stubbed host. ──────────
local CHUNK_TAIL = "\n\nreturn {\n"
  .. "  ensureData = ensureData,\n"
  .. "  loadUsage = loadUsage,\n"
  .. "  search = search,\n"
  .. "  buildView = buildView,\n"
  .. "  recents = recents,\n"
  .. "  commit = commit,\n"
  .. "  moveSelection = moveSelection,\n"
  .. "  setQuery = function(q) query = q end,\n"
  .. "  getSel = function() return sel end,\n"
  .. "  setCat = function(c) cat = c end,\n"
  .. "  dataLoaded = function() return data ~= nil end,\n"
  .. "  getLoadError = function() return loadError end,\n"
  .. "  firstEntry = function() return data ~= nil and data[1] or nil end,\n"
  .. "  categoryIds = function()\n"
  .. "    local ids = {}\n"
  .. "    for _, c in ipairs(CATEGORIES) do table.insert(ids, c.id) end\n"
  .. "    return ids\n"
  .. "  end,\n"
  .. "  categoryHas = function(id) return byCat[id] ~= nil and #byCat[id] > 0 end,\n"
  .. "}\n"

local function freshPicker()
  return assert(loadstring(PICKER_SRC .. CHUNK_TAIL))()
end

-- The shipped dataset must not carry the z blob (it is derived while
-- indexing). Checked BEFORE any picker chunk loads: indexing mutates the
-- shared DATASET tables in place by setting e.z on them.
do
  local shipped = 0
  for _, e in ipairs(DATASET) do
    if e.z ~= nil then
      shipped += 1
    end
  end
  check(shipped == 0, "shipped dataset carries no z blobs")
end

local picker = freshPicker()
picker.loadUsage()
picker.ensureData() -- a no-op when the chunk-time load already succeeded

local function searchFor(q)
  picker.setQuery(q)
  return picker.search(0)
end

-- ── Symbol queries: the named character ranks first ────────────────────
local cases = {
  { "euro", "€" }, { "dollar", "$" }, { "pound", "£" }, { "yen", "¥" },
  { "rupee", "₹" }, { "ruble", "₽" }, { "bitcoin", "₿" },
  { "copyright", "©" }, { "registered", "®" }, { "trademark", "™" }, { "tm", "™" },
  { "degree", "°" }, { "degrees", "°" },
  { "plus minus", "±" }, { "plus-minus", "±" }, { "plusminus", "±" },
  { "multiply", "×" }, { "times", "×" }, { "divide", "÷" },
  { "approximately", "≈" }, { "approx", "≈" },
  { "not equal", "≠" }, { "neq", "≠" },
  { "less than or equal", "≤" }, { "greater equal", "≥" },
  { "infinity", "∞" }, { "square root", "√" }, { "sum", "∑" }, { "integral", "∫" },
  { "pi", "π" }, { "alpha", "α" }, { "theta", "θ" }, { "lambda", "λ" },
  { "arrow right", "→" }, { "right arrow", "→" }, { "rightarrow", "→" }, { "right", "→" },
  { "arrow left", "←" }, { "arrow up", "↑" }, { "arrow down", "↓" },
  { "bullet", "•" }, { "ellipsis", "…" }, { "em dash", "—" }, { "en dash", "–" },
  { "section", "§" }, { "paragraph", "¶" },
  { "check", "✓" }, { "tick", "✓" }, { "cross", "✕" },
  { "nbsp", "\u{00A0}" }, { "command", "⌘" }, { "option", "⌥" },
  { "half", "½" }, { "squared", "²" }, { "celsius", "℃" },
}
for _, case in ipairs(cases) do
  local q, expected = case[1], case[2]
  check(firstChar(searchFor(q)) == expected, ("query %q -> %s (got %s)"):format(q, expected, tostring(firstChar(searchFor(q)))))
end

-- Ranking: € above euro-related emoji (💶 banknote, 🇪🇺 flag).
do
  local res = searchFor("euro")
  check(res[1].e == "€" and res[1].s == 1, "euro: € is first and is a symbol")
  local banknote, flag = indexOf(res, "💶"), indexOf(res, "🇪🇺")
  check(banknote ~= nil and banknote > 1, "euro: 💶 ranks below €")
  check(flag ~= nil and flag > 1, "euro: 🇪🇺 ranks below €")
end

-- The symbol is first even when an emoji has the identical name
-- ("copyright" also names the ©️ emoji).
do
  local res = searchFor("copyright")
  check(res[1].e == "©" and res[1].s == 1, "copyright: symbol © first")
  check(indexOf(res, "©️") ~= nil and indexOf(res, "©️") > 1, "copyright: ©️ emoji follows the symbol")
end

-- Literal character queries find themselves.
check(firstChar(searchFor("€")) == "€", "€ finds €")
check(firstChar(searchFor("→")) == "→", "→ finds →")
check(firstChar(searchFor("™")) == "™", "™ finds ™")

-- Normalisation: case-insensitive queries.
check(firstChar(searchFor("PLUS MINUS")) == "±", "PLUS MINUS -> ±")
check(firstChar(searchFor("Copyright")) == "©", "Copyright -> ©")
do
  -- Keyword-only emoji matches still work and rank naturally.
  local res = searchFor("ski")
  check(res[1] ~= nil and res[1].s ~= 1, "ski: emoji result first")
end
check(firstChar(searchFor("star")) == "⭐", "star -> ⭐ (not ★)")
check(firstChar(searchFor("flag france")) == "🇫🇷", "flag france -> 🇫🇷")
do
  local res = searchFor("heart")
  local pos = indexOf(res, "❤️")
  check(pos ~= nil and pos <= 3, "heart: ❤️ in top 3 (got " .. tostring(pos) .. ")")
end
-- Collision sanity: heart/star/check orderings stay useful.
do
  local res = searchFor("heart")
  check(indexOf(res, "♥") ~= nil and indexOf(res, "♥") <= 4, "heart: ♥ near top")
end
do
  local res = searchFor("triangle")
  check(indexOf(res, "▲") ~= nil and indexOf(res, "▲") <= 3, "triangle: ▲ near top")
end

-- ── Interaction: symbols ride the same selection/commit path ───────────
picker.setQuery("euro")
picker.buildView()
check(picker.getSel() == 1, "keyboard focus starts at 1")
onKey("right", true)
check(picker.getSel() == 2, "right arrow moves focus to 2")
onKey("left", true)
check(picker.getSel() == 1, "left arrow moves focus back to 1")
onKey("enter", true)
check(#copied > 0 and copied[#copied].text == "€", "enter copies focused symbol €")
check(copied[#copied].mime == "text/plain;charset=utf-8", "copy uses utf-8 text mime")
check(closedPanel == 1, "enter closes the panel")
do
  local recent = picker.recents(0, 10)
  check(recent[1] ~= nil and recent[1].e == "€", "picked symbol becomes most recent")
end

-- Browse: the Characters category is populated and rendered by buildView.
do
  local ids = picker.categoryIds()
  local hasChars = false
  for _, id in ipairs(ids) do
    if id == "chars" then
      hasChars = true
    end
  end
  check(hasChars, "Characters category exists")
  check(picker.categoryHas("chars"), "Characters category is populated")
  picker.setCat("chars")
  picker.setQuery("")
  picker.buildView()
  check(closedPanel == 1, "browse buildView keeps panel state intact")
end

-- ── Contract: search fields arrive pre-lowered/pre-indexed from the
-- generator, the z search blob is DERIVED (name + keywords + aliases —
-- the shipped dataset no longer carries it), and a COLD chunk-time load
-- stays well inside the host's 100ms script-load budget (callback
-- budget is 25ms; a decode that crosses it mid-pcall is exactly what
-- used to publish a permanently empty dataset, #700). ────────────────
do
  local notLowered = 0
  for _, e in ipairs(DATASET) do
    -- Luau's string.lower is ASCII-only while the Python generator uses
    -- Unicode-aware lower-casing, so validate the generated index contract
    -- structurally here; exact casing is covered in the Python tests.
    if type(e.l) ~= "string" then
      notLowered += 1
    end
    for _, k in ipairs(e.k) do
      if k ~= string.lower(k) then
        notLowered += 1
      end
    end
    if e.a ~= nil then
      for _, x in ipairs(e.a) do
        if x ~= string.lower(x) then
          notLowered += 1
        end
      end
    end
  end
  check(notLowered == 0, "dataset search fields are pre-normalised, z derived")

  local first = picker.firstEntry()
  check(first ~= nil and type(first.z) == "string", "indexed entries carry a derived z blob")
  if first ~= nil then
    check(string.find(first.z, first.l, 1, true) == 1, "z starts with the lowered name")
    local missingKeyword = false
    for _, k in ipairs(first.k) do
      if string.find(first.z, k, 1, true) == nil then
        missingKeyword = true
      end
    end
    check(not missingKeyword, "z contains every keyword")
  end

  local t0 = os.clock()
  local fresh = freshPicker()
  local loadMs = (os.clock() - t0) * 1000
  check(fresh.dataLoaded(), "cold chunk-time load succeeds")
  print(("cold chunk load (decode stubbed, index+derive) over %d entries: %.2f ms"):format(#DATASET, loadMs))
  check(loadMs < 15, "cold chunk load indexing stays under 15ms")
end

-- ── Load failures are never cached and are always observable (#700):
-- an unreadable dataset must leave the picker unloaded (never "loaded
-- but empty"), report why, keep search/buildView safe, and a later
-- attempt must be able to succeed. ─────────────────────────────────────
do
  fs.fail = true
  local broken = freshPicker()
  check(not broken.dataLoaded(), "read failure leaves dataset unloaded")
  check(broken.getLoadError() == "cannot open file", "read failure records the reason")
  broken.loadUsage()
  fs.fail = false
  fs.badJson = true
  local malformed = freshPicker()
  check(not malformed.dataLoaded(), "decode failure leaves dataset unloaded")
  check(malformed.getLoadError() == "bad json", "decode failure records the decoder's reason")
  fs.badJson = false

  -- #700 regression: a budget interrupt raised from inside the decode
  -- binding must not publish an empty dataset (the old code swallowed
  -- exactly this error and then cached "loaded-but-empty" forever).
  fs.raiseDecode = true
  local throttled = freshPicker()
  check(not throttled.dataLoaded(), "budget-interrupted decode publishes no dataset")
  check(
    string.find(throttled.getLoadError() or "", "CPU budget", 1, true) ~= nil,
    "budget interruption records the host's reason"
  )
  fs.raiseDecode = false
  throttled.ensureData()
  check(throttled.dataLoaded(), "budget-interrupted runtime recovers on retry")
  fs.badJson = true
  local malformed = freshPicker()
  check(not malformed.dataLoaded(), "decode failure leaves dataset unloaded")
  check(malformed.getLoadError() == "bad json", "decode failure records the decoder's reason")
  fs.badJson = false

  -- The retry path: the same runtime recovers once the file reads again.
  broken.ensureData()
  check(broken.dataLoaded(), "ensureData retries after a failed load and recovers")
  check(broken.getLoadError() == nil, "a recovered load clears the error")
end

-- Initialization is transactional. A failure halfway through indexing must
-- not publish partial state: that exact leak previously turned one onOpen
-- timeout into find(nil) on onChange and triggered Noctalia's auto-disable.
-- The dataset is corrupted BEFORE the chunk is built, so the chunk-time
-- load itself hits it; ensureData must swallow it (a chunk-level raise
-- would kill the whole script) yet leave every structure unpublished.
do
  local saved = DATASET[50].e
  DATASET[50].e = nil
  local fresh = assert(
    loadstring(PICKER_SRC .. "\n\nreturn { ensureData = ensureData, dataReady = function() return data ~= nil or byCat ~= nil or emojiIndex ~= nil end, getLoadError = function() return loadError end }\n")
  )()
  check(not fresh.dataReady(), "mid-initialization failure publishes no partial state")
  check(type(fresh.getLoadError()) == "string", "mid-initialization failure records a reason")
  DATASET[50].e = saved
  fresh.ensureData() -- intact dataset now: the retry completes
  check(fresh.dataReady(), "retry after mid-initialization failure recovers")
end

-- ── Performance smoke: a full search over the dataset stays well inside
-- the host's 25ms per-keystroke budget. ────────────────────────────────
do
  picker.setQuery("arrow")
  local t0 = os.clock()
  local iterations = 200
  for _ = 1, iterations do
    picker.search(0)
  end
  local avgMs = (os.clock() - t0) * 1000 / iterations
  print(("search avg over %d iterations: %.2f ms (budget 25ms)"):format(iterations, avgMs))
  check(avgMs < 20, "search stays under 20ms average")
end

print(("%d passed, %d failed"):format(passed, failures))
if failures > 0 then
  error("search tests failed")
end
