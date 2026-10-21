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

local function entryByName(name)
  for _, e in ipairs(DATASET) do
    if e.n == name then
      return e
    end
  end
  return nil
end

-- ── Host API stubs ─────────────────────────────────────────────────────
local copied = {}
local closedPanel = 0
local renderedTree = nil -- last tree handed to panel.render (ui nodes below)
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
    return function(opts, children)
      return { kind = k, opts = opts, children = children }
    end
  end,
})
panel = {
  -- Flag/field-driven like the fs stubs above: every picker chunk must
  -- see the SAME panel.render closure (chunk-time global snapshots).
  render = function(tree)
    renderedTree = tree
  end,
  close = function()
    closedPanel += 1
  end,
}

-- ── Load picker.luau with an export tail (runs in the same chunk scope,
-- so the module's locals are reachable). Note picker.luau loads the
-- dataset at chunk time now, so simply CONSTRUCTING the chunk performs
-- the full read → decode → index pass under the stubbed host. ──────────
-- The core now exports M.onOpen/M.onKey (the entry shims define the real
-- globals); the aliases below let the harness drive them by their old
-- global names.
local CHUNK_TAIL = "\n\nonOpen = M.onOpen\nonKey = M.onKey\nreturn {\n"
  .. "  ensureData = ensureData,\n"
  .. "  loadUsage = loadUsage,\n"
  .. "  search = search,\n"
  .. "  buildView = buildView,\n"
  .. "  render = render,\n"
  .. "  recents = recents,\n"
  .. "  commit = commit,\n"
  .. "  moveSelection = moveSelection,\n"
  .. "  setQuery = function(q) query = q end,\n"
  .. "  getSel = function() return sel end,\n"
  .. "  getItem = function(i) return items[i] end,\n"
  .. "  setCat = function(c) cat = c end,\n"
  .. "  getCat = function() return cat end,\n"
  .. "  dataLoaded = function() return data ~= nil end,\n"
  .. "  getLoadError = function() return loadError end,\n"
  .. "  firstEntry = function() return data ~= nil and data[1] or nil end,\n"
  .. "  categoryIds = function()\n"
  .. "    local ids = {}\n"
  .. "    for _, c in ipairs(CATEGORIES) do table.insert(ids, c.id) end\n"
  .. "    return ids\n"
  .. "  end,\n"
  .. "  categoryHas = function(id) return byCat[id] ~= nil and #byCat[id] > 0 end,\n"
  .. "  fitGrid = fitGrid,\n"
  .. "  tierForWidth = tierForWidth,\n"
  .. "  gridInfo = function() return gridCols, gridCell end,\n"
  .. "  TIERS = TIERS,\n"
  .. "  GAP = GAP,\n"
  .. "  TILE_CHROME = TILE_CHROME,\n"
  .. "  SCROLLBAR_GUTTER = SCROLLBAR_GUTTER,\n"
  .. "  ROOT_PADDING = ROOT_PADDING,\n"
  .. "  HOST_PADDING = HOST_PADDING,\n"
  .. "  gridRowWidth = function() return gridRowWidth end,\n"
  .. "  PANEL_WIDTHS = { PANEL_WIDTH_BY_ID.wide, PANEL_WIDTH_BY_ID.desktop, PANEL_WIDTH_BY_ID.compact },\n"
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

-- ── Emoji 18.0 additions: presence + the tone-variant dataset contract ──
for _, name in ipairs({ "cracking face", "orca", "trombone", "lighthouse", "ballet dancer", "leftwards thumb sign" }) do
  check(entryByName(name) ~= nil, "dataset contains new emoji " .. name)
end

do
  -- Tone variants ship as their own rows whose names carry the "skin
  -- tone" marker picker.luau's browse filter keys on (searchable rows,
  -- never browse-grid clutter) — assert the dataset contract only here.
  local allPresent = true
  for _, tone in ipairs({ "light", "medium-light", "medium", "medium-dark", "dark" }) do
    local row = entryByName("leftwards thumb sign: " .. tone .. " skin tone")
    if row == nil or string.find(row.n, "skin tone", 1, true) == nil then
      allPresent = false
    end
  end
  check(allPresent, "leftwards thumb sign ships all five tone rows carrying the 'skin tone' marker")
  local base = entryByName("leftwards thumb sign")
  check(base ~= nil and string.find(base.n, "skin tone", 1, true) == nil, "base rows carry no tone marker")
  check(entryByName("ballet dancer: dark skin tone") ~= nil, "ballet dancer ships tone rows")
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
  -- Curated symbol waves from the Emoji 18.0 dataset refresh.
  { "maps to", "↦" }, { "mapsto", "↦" }, { "maps from", "↤" },
  { "long right arrow", "⟶" }, { "onto", "↠" }, { "equilibrium", "⇌" },
  { "caps lock", "⇪" }, { "return arrow", "↵" },
  { "line", "─" }, { "pipe", "│" }, { "corner", "┌" },
  { "full block", "█" }, { "block", "█" }, { "shade", "▓" },
  { "greek cross", "✚" }, { "heavy asterisk", "✱" }, { "care of", "℅" },
  { "integers", "ℤ" }, { "natural numbers", "ℕ" }, { "aleph", "ℵ" },
  { "rx", "℞" }, { "liter", "ℓ" }, { "estimated", "℮" }, { "telephone", "℡" },
}

-- Broad queries keep surfacing the expected glyphs in the top results
-- after the curated waves: the new arrow/box symbols must find
-- themselves without crowding out the classics.
do
  local res = searchFor("arrow")
  check(firstChar(res) == "↑", "arrow: up arrow stays first")
  local right = indexOf(res, "→")
  check(right ~= nil and right <= 5, "arrow: → in top 5")
  local ret = indexOf(res, "↵")
  check(ret ~= nil and ret <= 5, "arrow: new ↵ in top 5")

  res = searchFor("box")
  local boxCross = indexOf(res, "┼")
  check(boxCross ~= nil and boxCross <= 5, "box: new ┼ in top 5")
  local ballot = indexOf(res, "☐")
  check(ballot ~= nil and ballot <= 8, "box: ☐ in top results")

  check(firstChar(searchFor("degree")) == "°", "degree: ° stays first")
  res = searchFor("check")
  check(firstChar(res) == "✓", "check: ✓ stays first")
  local heavy = indexOf(res, "✔")
  check(heavy ~= nil and heavy <= 5, "check: ✔ in top 5")
end
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

-- ── Tabs: the category strip is browse-only chrome ─────────────────────
-- The strip is a row of toggle buttons (All + the nine categories) mounted
-- above the grid while no query is active. Clicking a tab switches `cat`
-- and rebuilds the view: fresh grid scroll container (the tab opens at its
-- top), selection reset, Frequently Used re-pinned above the new section.
local function keyOf(node)
  return node.opts ~= nil and node.opts.key or nil
end

local function walkTree(node, fn)
  if node == nil then
    return
  end
  fn(node)
  for _, child in ipairs(node.children or {}) do
    walkTree(child, fn)
  end
end

local function findNodes(pred)
  local out = {}
  walkTree(renderedTree, function(n)
    if pred(n) then
      table.insert(out, n)
    end
  end)
  return out
end

local function tabButtons()
  return findNodes(function(n)
    return n.kind == "button" and type(keyOf(n)) == "string" and string.sub(keyOf(n), 1, 4) == "cat-"
  end)
end

-- Grid tiles are keyed clickable columns holding one glyph label; the
-- selection highlight is the tile's own fill/border and its label colour.
local function tileNodes()
  return findNodes(function(n)
    return n.kind == "column" and type(keyOf(n)) == "string" and string.find(keyOf(n), "^t%d+$") ~= nil
  end)
end

local function tileGlyph(tileNode)
  local label = tileNode.children ~= nil and tileNode.children[1] or nil
  return label ~= nil and label.kind == "label" and label.opts.text or nil
end

local function labelShown(text)
  return #findNodes(function(n)
    return n.kind == "label" and n.opts.text == text
  end) > 0
end

do
  picker.setCat("smileys")
  picker.setQuery("")
  picker.buildView()
  picker.render()

  -- Default view: Frequently Used pinned above the smileys section.
  check(labelShown("Frequently Used"), "default view pins a Frequently Used section")
  check(labelShown("Smileys & People"), "default view shows the smileys section")

  -- The strip is mounted in browse view: All + every category id.
  check(#findNodes(function(n) return keyOf(n) == "cats" end) == 1, "browse view mounts the category strip")
  -- The strip centers by stretching across the content box and justifying
  -- its buttons — no explicit width, so it shares the input's exact span
  -- (review feedback: tabs must sit at the panel's center).
  local catsRow = findNodes(function(n) return keyOf(n) == "cats" end)[1]
  check(catsRow.opts.width == nil and catsRow.opts.justify == "center",
    "category strip spans the content box and centers its tabs")
  local tabs = tabButtons()
  check(#tabs == 10, "strip renders 10 tabs (All + 9 categories), got " .. tostring(#tabs))
  local byKey = {}
  for _, b in ipairs(tabs) do
    byKey[string.sub(keyOf(b), 5)] = b
  end
  local coversAll = byKey["all"] ~= nil
  for _, id in ipairs(picker.categoryIds()) do
    if byKey[id] == nil then
      coversAll = false
    end
  end
  check(coversAll, "strip covers All plus every category id")
  check(
    byKey["smileys"] ~= nil and byKey["smileys"].opts.variant == "secondary",
    "smileys tab is the selected variant by default"
  )
  check(byKey["all"] ~= nil and byKey["all"].opts.variant == "ghost", "unselected tabs use the ghost variant")

  -- Clicking a tab switches cat and rebuilds the grid content.
  local scrollBefore = findNodes(function(n) return n.kind == "scroll" end)[1]
  local flagsTab = byKey["flags"]
  check(flagsTab ~= nil, "strip exposes the flags tab")
  if flagsTab ~= nil then
    flagsTab.opts.onClick()
  end
  check(picker.getCat() == "flags", "clicking the flags tab switches cat to flags")
  check(picker.getSel() == 1, "tab click resets the keyboard selection")
  check(labelShown("Flags"), "flags tab renders the Flags section")
  -- Flag glyphs = pairs of regional indicators (U+1F1E6..U+1F1FF), which
  -- share their first three UTF-8 bytes.
  local RI_PREFIX = string.sub("\u{1F1E6}", 1, 3)
  local flagTiles = 0
  for _, b in ipairs(tileNodes()) do
    local glyph = tileGlyph(b)
    if type(glyph) == "string" and string.sub(glyph, 1, 3) == RI_PREFIX then
      flagTiles += 1
    end
  end
  check(flagTiles > 0, "flags tab grid shows flag glyphs")
  local scrollAfter = findNodes(function(n) return n.kind == "scroll" end)[1]
  check(
    scrollBefore ~= nil and scrollAfter ~= nil and keyOf(scrollBefore) ~= keyOf(scrollAfter),
    "tab switch rebuilds the grid scroll container"
  )
  check(#tabButtons() == 10, "strip stays mounted after the switch")
  local afterKeys = {}
  for _, b in ipairs(tabButtons()) do
    afterKeys[string.sub(keyOf(b), 5)] = b
  end
  check(
    afterKeys["flags"] ~= nil
      and afterKeys["flags"].opts.variant == "secondary"
      and afterKeys["smileys"] ~= nil
      and afterKeys["smileys"].opts.variant == "ghost",
    "selected tab follows the click"
  )

  -- Search spans all categories: the strip disappears while a query is
  -- active and comes back when the query clears.
  picker.setQuery("arrow")
  picker.buildView()
  picker.render()
  check(#findNodes(function(n) return keyOf(n) == "cats" end) == 0, "category strip hides while a query is active")
  check(#tabButtons() == 0, "no tab buttons while a query is active")
  picker.setQuery("")
  picker.buildView()
  picker.render()
  check(#tabButtons() == 10, "strip returns when the query clears")
end

-- The root column is layout-only: the host-owned surface paints the card
-- chrome, so a root fill/radius would double-paint (the panel-ring fix).
do
  check(renderedTree ~= nil and keyOf(renderedTree) == "root", "render mounts the root column")
  check(
    renderedTree ~= nil and renderedTree.opts.fill == nil and renderedTree.opts.radius == nil,
    "root column carries no fill/radius (host-owned chrome)"
  )
end

-- ── Selection: one visible highlight, owned by the keyboard model ──────
-- A tile paints its own fill/border/label colour from `sel`, so exactly
-- one tile is highlighted at any time — the one the footer names and
-- Enter commits — whether `sel` moved by search, arrows or pointer hover.
-- Hover callbacks arrive as the strings "true"/"false" (the panel host
-- sends both on enter/leave); a leave must never move the selection.
do
  local function highlighted(tileNode)
    return tileNode.opts.fill == "primary"
  end
  local function footerLabel(key)
    return findNodes(function(n) return n.kind == "label" and keyOf(n) == key end)[1]
  end
  local function tileByIndex(i)
    return findNodes(function(n) return keyOf(n) == "t" .. tostring(i) end)[1]
  end
  -- Exactly one tile is highlighted and it is tile `expected`; its fill,
  -- border and glyph colour agree; every other tile is fully unhighlighted;
  -- the footer shows the selected entry.
  local function expectSelected(expected, what)
    local lit = {}
    local consistent = true
    for _, t in ipairs(tileNodes()) do
      local label = t.children[1]
      local on = highlighted(t)
      if on then
        table.insert(lit, t)
      end
      if (t.opts.border == "primary") ~= on or (label.opts.color == "on_primary") ~= on then
        consistent = false
      end
      if not on and (t.opts.fill ~= "surface_variant" or label.opts.color ~= "on_surface") then
        consistent = false
      end
    end
    check(picker.getSel() == expected, what .. ": keyboard selection is " .. tostring(expected))
    check(#lit == 1, what .. ": exactly one tile is highlighted (got " .. tostring(#lit) .. ")")
    check(
      lit[1] ~= nil and keyOf(lit[1]) == "t" .. tostring(expected),
      what .. ": the highlighted tile is tile " .. tostring(expected)
    )
    check(consistent, what .. ": fill, border and glyph colour agree on every tile")
    local entry = picker.getItem(expected)
    local emojiLabel, nameLabel = footerLabel("foot-emoji"), footerLabel("foot-name")
    check(
      entry ~= nil and lit[1] ~= nil and tileGlyph(lit[1]) == entry.e,
      what .. ": the highlighted tile shows the selected entry"
    )
    check(
      entry ~= nil and emojiLabel ~= nil and nameLabel ~= nil
        and emojiLabel.opts.text == entry.e and nameLabel.opts.text == entry.n,
      what .. ": the footer names the highlighted tile"
    )
  end

  -- Drive the rendered controls, as the host does: typing calls the input's
  -- onChange (which resets the selection to the first result), and a tab
  -- click calls that tab button's onClick. Both re-render before returning.
  local function typeQuery(text)
    local input = findNodes(function(n)
      return n.kind == "input" and type(keyOf(n)) == "string" and string.sub(keyOf(n), 1, 2) == "q-"
    end)[1]
    check(input ~= nil, "the search input is rendered")
    if input ~= nil then
      input.opts.onChange(text)
    end
  end
  local function pickTab(id)
    local tab = findNodes(function(n) return n.kind == "button" and keyOf(n) == "cat-" .. id end)[1]
    check(tab ~= nil, "the " .. id .. " tab is rendered")
    if tab ~= nil then
      tab.opts.onClick()
    end
  end

  local savedCat = picker.getCat()

  -- Search: typing selects the first result straight away.
  pickTab("smileys")
  typeQuery("euro")
  check(#tileNodes() >= 2, "euro search renders at least two tiles")
  expectSelected(1, "after search")

  onKey("right", true)
  expectSelected(2, "after right arrow")
  onKey("left", true)
  expectSelected(1, "after left arrow")

  -- Pointer enter: the hovered tile becomes the one selection, footer too.
  tileByIndex(2).opts.onHover("true", "t2")
  expectSelected(2, "after hovering tile 2")

  -- Keyboard while the pointer still rests on tile 2: tile 2 must not stay
  -- highlighted beside the keyboard's tile (the old stuck-hover state).
  onKey("left", true)
  expectSelected(1, "keyboard move while the pointer rests on tile 2")

  -- The pointer then leaves tile 2: the "false" string is truthy in Luau
  -- but must be ignored, so the keyboard selection survives.
  tileByIndex(2).opts.onHover("false", "t2")
  expectSelected(1, "pointer leaving tile 2 after a keyboard move")

  -- Sweeping A -> B delivers A's leave before B's enter.
  tileByIndex(1).opts.onHover("true", "t1")
  tileByIndex(1).opts.onHover("false", "t1")
  tileByIndex(2).opts.onHover("true", "t2")
  expectSelected(2, "pointer sweep from tile 1 to tile 2")

  -- Enter commits the selected entry and closes, as before.
  local copiedBefore, closedBefore = #copied, closedPanel
  local selectedEntry = picker.getItem(2)
  onKey("enter", true)
  check(
    #copied == copiedBefore + 1 and selectedEntry ~= nil and copied[#copied].text == selectedEntry.e,
    "enter copies the hovered-and-selected glyph"
  )
  check(closedPanel == closedBefore + 1, "enter closes the panel after a hover selection")

  -- Mouse click commits the clicked tile's own glyph (not `sel`) and closes.
  typeQuery("")
  typeQuery("euro")
  expectSelected(1, "after re-search")
  copiedBefore, closedBefore = #copied, closedPanel
  local clicked = tileByIndex(2)
  local clickedEntry = picker.getItem(2)
  clicked.opts.onClick()
  check(
    #copied == copiedBefore + 1 and clickedEntry ~= nil and copied[#copied].text == clickedEntry.e,
    "clicking a tile copies that tile's glyph"
  )
  check(closedPanel == closedBefore + 1, "clicking a tile closes the panel")

  -- Browse view: the highlight is still the keyboard model's, and vertical
  -- navigation moves it with the footer.
  typeQuery("")
  pickTab("smileys")
  expectSelected(picker.getSel(), "browse view rebuild")
  local before = picker.getSel()
  onKey("down", true)
  check(picker.getSel() ~= before, "down arrow moves the browse selection")
  expectSelected(picker.getSel(), "after down arrow")
  tileByIndex(1).opts.onHover("true", "t1")
  expectSelected(1, "hovering tile 1 in the browse grid")

  -- Leave no state behind for later tests: original category, no query.
  typeQuery("")
  pickTab(savedCat)
  check(picker.getSel() == 1, "selection block leaves keyboard focus at 1")
end

-- ── Grid fit: a rendered row never runs under the overlay scrollbar ────
-- The ui.scroll scrollbar is an overlay (reserves no width), so the row
-- budget must cover the RENDERED tile width and reserve SCROLLBAR_GUTTER.
-- fitGrid guarantees that for every manifest panel width and every tier;
-- the rendered tree must then spend exactly what fitGrid derived.
do
  check(picker.SCROLLBAR_GUTTER > 0, "scrollbar gutter is reserved (overlay scrollbar needs it)")

  for _, w in ipairs(picker.PANEL_WIDTHS) do
    local available = w - 2 * (picker.HOST_PADDING + picker.ROOT_PADDING)
    for ti, t in ipairs(picker.TIERS) do
      local cols, cell = picker.fitGrid(available, picker.GAP, t.cols, t.cell)
      local rowW = cols * cell + (cols - 1) * picker.GAP
      check(
        picker.SCROLLBAR_GUTTER > 0
          and cols >= 1
          and cell > picker.TILE_CHROME
          and rowW + picker.SCROLLBAR_GUTTER <= available,
        ("fit invariant: tier %d on %dpx panel reserves the gutter (row %dpx + gutter %d <= %d)")
          :format(ti, w, rowW, picker.SCROLLBAR_GUTTER, available)
      )
    end
  end

  -- Entry width picks the tier: the entry shim is the size signal.
  check(
    picker.tierForWidth(780).cols == 9,
    "wide entry (780) gets 9 columns"
  )
  check(
    picker.tierForWidth(640).cols == 8,
    "desktop entry (640) gets 8 columns"
  )
  check(
    picker.tierForWidth(480).cols == 6,
    "compact entry (480) gets 6 columns"
  )
  check(
    picker.tierForWidth(123) == picker.TIERS[#picker.TIERS],
    "unknown entry width falls back to the smallest tier"
  )

  picker.setCat("smileys")
  picker.setQuery("")
  picker.buildView()
  picker.render()
  local cols, cell = picker.gridInfo()
  local avail = picker.PANEL_WIDTHS[3] - 2 * (picker.HOST_PADDING + picker.ROOT_PADDING)
  check(
    cols == picker.fitGrid(avail, picker.GAP, picker.TIERS[1].cols, picker.TIERS[1].cell),
    "load-time grid derives cols from the narrowest manifest panel"
  )
  -- Rendered rows must spend exactly the fit budget: tile nodes declare
  -- the content box, so rendered tile = w + TILE_CHROME = gridCell, and
  -- n tiles + gaps + gutter must fit the panel minus the root padding.
  local rows = findNodes(function(n)
    return n.kind == "row" and type(keyOf(n)) == "string" and string.find(keyOf(n), "^r%d+%-%d+$") ~= nil
  end)
  check(#rows > 0, "grid renders tile rows")
  local budgetOk = true
  local chromeOk = true
  local centeredOk = true
  for _, r in ipairs(rows) do
    local n = #(r.children or {})
    if r.opts.width ~= picker.gridRowWidth() or r.opts.justify ~= "center" then
      centeredOk = false
    end
    if n > 0 then
      local w0 = r.children[1].opts.width
      if n * (w0 + picker.TILE_CHROME) + (n - 1) * picker.GAP + picker.SCROLLBAR_GUTTER > avail then
        budgetOk = false
      end
      for _, tileNode in ipairs(r.children) do
        if tileNode.opts.width + picker.TILE_CHROME ~= cell then
          chromeOk = false
        end
      end
    end
  end
  check(budgetOk, "rendered row budget (tiles + gaps + gutter) fits the panel minus both paddings")
  check(chromeOk, "tile content width + TILE_CHROME equals the derived grid cell")
  check(centeredOk, "tile rows span the row area (width) and center their tiles (justify)")
  local scrolls = findNodes(function(n) return n.kind == "scroll" end)
  check(
    #scrolls == 1 and scrolls[1].opts.align == "center",
    "grid scroll centers its children (row boxes) horizontally"
  )
  local labelsOk = true
  local labelNodes = findNodes(function(n)
    return n.kind == "label" and type(keyOf(n)) == "string" and string.sub(keyOf(n), 1, 1) == "h"
  end)
  check(#labelNodes > 0, "section labels render in browse view")
  for _, n in ipairs(labelNodes) do
    if n.opts.width ~= picker.gridRowWidth() or n.opts.textAlign ~= "left" then
      labelsOk = false
    end
  end
  check(labelsOk, "section labels share the row box and stay left-aligned")
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
