--!nonstrict
-- Stub-based smoke test for typer panel.luau (runs under plain Lua/LuaJIT).
-- Stubs noctalia.* / ui.* / panel.* globals, loads the panel entry, and drives
-- a full session. All assertions go through the plugin's public surface:
-- rendered ui.* trees, noctalia.state.set calls, and writeFile calls.

local results = {}
local function check(name, cond)
  table.insert(results, { name = name, ok = cond })
  if not cond then print("FAIL: " .. name) end
end

-- ---------------------------------------------------------------------------
-- Stubs
-- ---------------------------------------------------------------------------

local trees = {} -- every rendered tree, in order
local secondTicks = nil
local frameTicks = nil
local stateSet = {} -- { [key] = last value }
local writtenFiles = {}

panel = {
  render = function(tree) table.insert(trees, tree) end,
  close = function() end,
  setWantsSecondTicks = function(v) secondTicks = v end,
  setNeedsFrameTick = function(v) frameTicks = v end,
}

local fakeNow = 1000
local WORDLISTS = {
  ["words/en.txt"] = "the and cat dog run sun good code type fast\n",
  ["words/es.txt"] = "de la casa perro gato sol noche mesa libro\n",
}
noctalia = {
  readFile = function(p) return WORDLISTS[p] end,
  writeFile = function(p, c) table.insert(writtenFiles, { path = p, content = c }) return true end,
  pluginDataDir = function() return "/tmp/typer-data" end,
  log = function(m) print("log: " .. tostring(m)) end,
  nowMs = function() return fakeNow end,
  getConfig = function() return nil end,
  string = { trim = function(s) return s:match("^%s*(.-)%s*$") end },
  json = {},
  state = { set = function(k, v) stateSet[k] = v end },
  togglePanel = function() end,
}
noctalia.json.encode = function() return "{}" end
noctalia.json.decode = function() return nil end

-- Deterministic RNG: always the first word of the list.
math.random = function(n)
  if n then return 1 end
  return 0
end

local function mk(name)
  return function(props, children)
    return { kind = name, props = props, children = children }
  end
end
ui = {}
for _, name in ipairs({ "column", "row", "scroll", "label", "glyph", "input",
  "button", "select", "toggle", "slider", "box", "separator", "spacer",
  "progress", "markdown", "image" }) do
  ui[name] = mk(name)
end

-- ---------------------------------------------------------------------------
-- Tree inspection helpers
-- ---------------------------------------------------------------------------

local function walk(node, fn)
  if type(node) ~= "table" then return end
  fn(node)
  if type(node.children) == "table" then
    for _, c in ipairs(node.children) do walk(c, fn) end
  end
end

local function labelTexts(tree)
  local out = {}
  walk(tree, function(n)
    if n.kind == "label" and type(n.props.text) == "string" then
      table.insert(out, n.props.text)
    end
  end)
  return out
end

local function hasLabel(tree, text)
  for _, t in ipairs(labelTexts(tree)) do
    if t == text then return true end
  end
  return false
end

local function countKind(tree, kind)
  local n = 0
  walk(tree, function(node)
    if node.kind == kind then n = n + 1 end
  end)
  return n
end

local function lastTree() return trees[#trees] end

-- ---------------------------------------------------------------------------
-- Load the plugin entry
-- ---------------------------------------------------------------------------

local chunk = assert(loadfile("panel.luau"))
chunk()

onOpen()
check("onOpen renders", #trees == 1)
check("ready state shows settings (3 selects)", countKind(lastTree(), "select") == 3)
check("ready state shows hint", hasLabel(lastTree(), "Start typing to begin - space advances, Esc closes"))
check("caret visible in ready state", countKind(lastTree(), "box") >= 1)
check("future words shown as flowing text", hasLabel(lastTree(), "the"))
check("no second ticks while ready", secondTicks == false)

-- ---------------------------------------------------------------------------
-- Words mode: 25 words, all "the" (deterministic RNG)
-- ---------------------------------------------------------------------------

onLangChanged("1") -- English
onModeChanged("2") -- Words
onLengthChanged("2") -- 25 words
trees = {}

local function inputKeys(tree)
  local out = {}
  walk(tree, function(n)
    if n.kind == "input" and type(n.props.key) == "string" then table.insert(out, n.props.key) end
  end)
  return out
end

-- Regression (user-reported): the input must keep one stable key while typing
-- a word - a new key per render recreates the control and kills focus, so the
-- second letter never arrives. It must change only when a word is submitted.
-- Monkeytype-style: an exact word does NOT auto-advance; space submits.
onInputChange("t")
local keyAfterFirstLetter = inputKeys(lastTree())[1]
check("caret visible while typing", countKind(lastTree(), "box") >= 1)
onInputChange("th")
check("input key stable while typing one word", inputKeys(lastTree())[1] == keyAfterFirstLetter)
onInputChange("the")
check("exact word does not auto-advance", hasLabel(lastTree(), "0/25"))
onInputChange("the ")
check("space submits the word", hasLabel(lastTree(), "1/25"))
check("input key changes when a word is submitted", inputKeys(lastTree())[1] ~= keyAfterFirstLetter)
for i = 2, 24 do
  onInputChange("the ")
  check("advanced to word " .. i, hasLabel(lastTree(), i .. "/25"))
end

-- Word 25 is wrong (typed then space): session must finish with a penalty.
fakeNow = 61000 -- one minute of typing
onInputChange("thex ")
check("finished after 25th word", hasLabel(lastTree(), "19 wpm"))
check("accuracy 96% after one wrong", hasLabel(lastTree(), "accuracy 96%"))
check("best today published to state", stateSet["typer.todayBest"] == 19)
check("stats persisted", #writtenFiles == 1 and writtenFiles[1].path:match("stats.json$") ~= nil)
check("second ticks off when done", secondTicks == false)
check("results show a 60s duration", hasLabel(lastTree(), "60s"))

-- ---------------------------------------------------------------------------
-- Restart + time mode
-- ---------------------------------------------------------------------------

onRestart()
check("restart returns to settings view", countKind(lastTree(), "select") == 3)

onModeChanged("1") -- Time
onLengthChanged("1") -- 15s
trees = {}

fakeNow = 62000
onInputChange("t")
check("typing started on keystroke", secondTicks == true)
check("time mode shows remaining seconds", hasLabel(lastTree(), "15s"))

fakeNow = 62000 + 16000 -- past the 15s duration
update()
check("time mode finishes on tick", hasLabel(lastTree(), "0 wpm"))
check("second ticks off after time finish", secondTicks == false)

-- ---------------------------------------------------------------------------
-- Rules: double space, backspace, language switch
-- ---------------------------------------------------------------------------

onModeChanged("2")
onLengthChanged("2")
trees = {}

fakeNow = 1000
onInputChange("t") -- start
onInputChange(" ") -- double-space guard: empty word, no penalty/advance
check("double space does not advance", hasLabel(lastTree(), "0/25"))

onInputChange("ca")
onInputChange("") -- backspace everything
check("backspace to empty does not advance", hasLabel(lastTree(), "0/25"))

onInputChange("the ")
check("space advances in es", hasLabel(lastTree(), "1/25"))

onLangChanged("2") -- Español: first word is now "de"
trees = {}
onRestart()
onInputChange("de ")
check("es wordlist active after language change", hasLabel(lastTree(), "1/25"))

local failed = 0
for _, r in ipairs(results) do
  if not r.ok then failed = failed + 1 end
end
print(string.format("%d/%d checks passed", #results - failed, #results))
if failed > 0 then os.exit(1) end
