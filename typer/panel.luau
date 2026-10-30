--!nonstrict
-- Typer panel - monkeytype-style typing practice.
--
-- A floating panel with exclusive keyboard focus. The user picks language
-- (English/Español), mode (time/words) and length, then starts typing: the
-- first keystroke starts the clock. Words are shown as flowing multi-line
-- text (three visible lines that shift up as the user advances), with a
-- blinking caret, per-char coloring (typed/incorrect/untyped), live WPM and
-- accuracy. Space submits a word (typed words advance automatically). Results
-- (WPM, accuracy) are shown on finish and the best WPM per day/language is
-- persisted to the plugin data dir and published to the bar widget over
-- noctalia.state.
--
-- ui.* has no transitions, so line shifts are instant (no smooth scroll).

-- ---------------------------------------------------------------------------
-- Wordlists
-- ---------------------------------------------------------------------------

local WORDS = { en = {}, es = {} }

local function loadWords(lang, file)
  local raw = noctalia.readFile(file)
  if raw == nil then
    noctalia.log("typer: cannot read " .. file)
    return
  end
  for w in raw:gmatch("%S+") do
    w = noctalia.string.trim(w)
    if w ~= "" then
      table.insert(WORDS[lang], w:lower())
    end
  end
end

loadWords("en", "words/en.txt")
loadWords("es", "words/es.txt")

local LANG_LABELS = { "English", "Español" }
local MODE_LABELS = { "Time", "Words" }
local TIME_OPTIONS = { 15, 30, 60 }
local WORD_OPTIONS = { 15, 25, 50 }

pcall(math.randomseed, os.time())

-- ---------------------------------------------------------------------------
-- Persistent stats
-- ---------------------------------------------------------------------------

local LANG_KEYS = { "en", "es" }

local langIndex = 1
local modeIndex = 1 -- 1 = time, 2 = words
local lengthIndex = 2

local function langKey()
  return LANG_KEYS[langIndex] or "en"
end

local statsPath = nil
local stats = { days = {}, last = {} }

local function loadStats()
  local dir = noctalia.pluginDataDir()
  if dir == nil then return end
  statsPath = dir .. "/stats.json"
  local raw = noctalia.readFile(statsPath)
  if raw == nil then return end
  local decoded = noctalia.json.decode(raw)
  if type(decoded) == "table" then
    stats = decoded
    if type(stats.days) ~= "table" then stats.days = {} end
    if type(stats.last) ~= "table" then stats.last = {} end
  end
end

loadStats()

local function todayKey()
  return os.date("%Y-%m-%d")
end

local function bestToday()
  local day = stats.days[todayKey()]
  if type(day) ~= "table" or type(day.best) ~= "table" then return 0 end
  local best = 0
  for _, v in pairs(day.best) do
    if type(v) == "number" and v > best then best = v end
  end
  return best
end

local function saveResult(wpm, accuracy)
  local key = todayKey()
  local day = stats.days[key]
  if type(day) ~= "table" then
    day = { tests = 0, best = {} }
    stats.days[key] = day
  end
  day.tests = (day.tests or 0) + 1
  if wpm > (day.best[langKey()] or 0) then
    day.best[langKey()] = wpm
  end
  stats.last[langKey()] = wpm

  if statsPath ~= nil then
    noctalia.writeFile(statsPath, noctalia.json.encode(stats, true))
  end

  -- Publish today's best for the bar widget.
  noctalia.state.set("typer.todayBest", bestToday())
end

-- ---------------------------------------------------------------------------
-- Session state (langIndex/modeIndex/lengthIndex are declared above, next to
-- langKey(), so both the stats saver and the callbacks share one set)
-- ---------------------------------------------------------------------------

local state = "ready" -- ready | typing | done
local queue = {}
local qIndex = 1
local typed = "" -- current input content (without a trailing space)
local inputKey = 0

local correctWords = 0
local attemptedWords = 0
local correctChars = 0
local startMs = nil
local elapsedMs = 0

local lastWpm = 0
local lastAcc = 100

-- Monkeytype-style text window.
local fontSize = 24
local maxCharsPerLine = 32 -- estimated wrap width (panel is 540px wide)
local lineStart = 1 -- first word index of the visible window
local blinkPhase = 0 -- caret blink phase, toggled by frame ticks

local function randomWord()
  local list = WORDS[langKey()]
  if list == nil or #list == 0 then return "words" end
  return list[math.random(#list)]
end

local function buildQueue()
  queue = {}
  local count
  if modeIndex == 2 then
    count = WORD_OPTIONS[lengthIndex] or 25
  else
    count = (TIME_OPTIONS[lengthIndex] or 30) * 4 -- enough words for the run
  end
  for _ = 1, count do
    table.insert(queue, randomWord())
  end
  qIndex = 1
  lineStart = 1
end

-- Greedy line wrap over the queue, estimated by character count.
local function computeLineRanges(fromIdx)
  local ranges = {}
  local idx = fromIdx
  for l = 1, 3 do
    local first = idx
    local used = 0
    while idx <= #queue do
      local need = #queue[idx] + ((idx > first) and 1 or 0) -- +1 for the space
      if used + need > maxCharsPerLine and idx > first then break end
      used = used + need
      idx = idx + 1
    end
    ranges[l] = { first = first, stop = idx - 1 }
  end
  return ranges
end

local function resetSession()
  state = "ready"
  buildQueue()
  typed = ""
  inputKey = inputKey + 1
  correctWords = 0
  attemptedWords = 0
  correctChars = 0
  startMs = nil
  elapsedMs = 0
  panel.setWantsSecondTicks(false)
  panel.setNeedsFrameTick(true) -- caret blink
end

-- ---------------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------------

local function caretNode()
  return ui.box({
    key = "caret",
    width = 2,
    height = fontSize + 4,
    radius = 1,
    fill = (blinkPhase == 0) and "primary" or "on_surface_variant/0.25",
  })
end

-- Chars of one word. For the current word: per-char colors plus a caret
-- inserted at the typing position (extra typed chars render in red).
local function wordNodes(word, wordIdx)
  local isCurrent = (wordIdx == qIndex)
  if not isCurrent then
    return { ui.label({ key = "word-" .. wordIdx, text = word, fontSize = fontSize, color = "on_surface_variant" }) }
  end

  local len = math.max(#word, #typed)
  local labels = {}
  for i = 1, len + 1 do
    if i == #typed + 1 then
      table.insert(labels, caretNode())
    end
    if i <= len then
      local color
      local ch
      if i <= #word then
        ch = word:sub(i, i)
        if i <= #typed then
          color = (typed:sub(i, i) == ch) and "primary" or "error"
        else
          color = "on_surface_variant"
        end
      else
        ch = typed:sub(i, i) -- extra char beyond the target: wrong by definition
        color = "error"
      end
      table.insert(labels, ui.label({ key = "ch-" .. i, text = ch, fontSize = fontSize, color = color }))
    end
  end
  return labels
end

local function wordsSection()
  local ranges = computeLineRanges(lineStart)
  local lineRows = {}
  for l = 1, 3 do
    local r = ranges[l]
    local items = {}
    for w = r.first, r.stop do
      table.insert(items, ui.row({ key = "word-" .. w, gap = 1, align = "center" }, wordNodes(queue[w], w)))
    end
    table.insert(lineRows, ui.row({
      key = "line-" .. l,
      gap = 10,
      align = "center",
      height = fontSize + 12, -- steady line height, no layout jumps
    }, items))
  end
  return ui.column({ key = "words", gap = 6, align = "center", padding = 12 }, lineRows)
end

local function render()
  local rows = {}

  -- Header: title + close.
  table.insert(rows, ui.row({ gap = 8, align = "center", justify = "space_between" }, {
    ui.label({ text = "Typer", fontSize = 16, fontWeight = "bold", color = "primary" }),
    ui.button({ glyph = "close", variant = "ghost", onClick = "onCloseClicked" }),
  }))

  if state == "done" then
    -- Results screen.
    local minutes = math.max(elapsedMs, 1) / 60000
    table.insert(rows, ui.column({ gap = 6, align = "center", padding = 24 }, {
      ui.label({ text = tostring(lastWpm) .. " wpm", fontSize = 48, fontWeight = "bold", color = "primary" }),
      ui.row({ gap = 18, align = "center" }, {
        ui.label({ text = "accuracy " .. tostring(lastAcc) .. "%", fontSize = 14, color = "on_surface_variant" }),
        ui.label({ text = math.floor(minutes * 60 + 0.5) .. "s", fontSize = 14, color = "on_surface_variant" }),
        ui.label({ text = "best today " .. tostring(bestToday()) .. " wpm", fontSize = 14, color = "on_surface_variant" }),
      }),
      ui.row({ gap = 8, align = "center" }, {
        ui.button({ text = "Restart (Enter)", variant = "primary", onClick = "onRestart" }),
      }),
    }))
  -- Focused, invisible input so plain Enter restarts.
    inputKey = inputKey + 1
    table.insert(rows, ui.input({
      key = "restart-" .. inputKey,
      focus = true,
      frameVisible = false,
      opacity = 0,
      height = 1,
      fontSize = 8,
      onSubmit = "onRestart",
    }))
    panel.render(ui.column({ flexGrow = 1, gap = 12 }, rows))
    return
  end

  -- Settings row (only before the run starts).
  if state == "ready" then
    local lengthLabels = {}
    if modeIndex == 1 then
      for _, v in ipairs(TIME_OPTIONS) do table.insert(lengthLabels, v .. "s") end
    else
      for _, v in ipairs(WORD_OPTIONS) do table.insert(lengthLabels, tostring(v)) end
    end
    table.insert(rows, ui.row({ gap = 8, align = "center" }, {
      ui.select({
        options = LANG_LABELS,
        selectedIndex = langIndex - 1,
        controlSize = "sm",
        onChange = "onLangChanged",
      }),
      ui.select({
        options = MODE_LABELS,
        selectedIndex = modeIndex - 1,
        controlSize = "sm",
        onChange = "onModeChanged",
      }),
      ui.select({
        options = lengthLabels,
        selectedIndex = lengthIndex - 1,
        controlSize = "sm",
        onChange = "onLengthChanged",
      }),
    }))
  end

  -- Live stats row (only while typing) - small, top-left, monkeytype-style.
  if state == "typing" then
    local minutes = math.max(elapsedMs, 1) / 60000
    local wpmLive = math.floor((correctChars / 5) / minutes + 0.5)
    local leftLabel
    if modeIndex == 1 then
      local remaining = math.max(0, (TIME_OPTIONS[lengthIndex] or 30) * 1000 - elapsedMs)
      leftLabel = math.ceil(remaining / 1000) .. "s"
    else
      leftLabel = (qIndex - 1) .. "/" .. (WORD_OPTIONS[lengthIndex] or 25)
    end
    table.insert(rows, ui.row({ gap = 14, align = "center" }, {
      ui.label({ text = leftLabel, fontSize = 18, fontWeight = "bold", color = "primary" }),
      ui.label({ text = wpmLive .. " wpm", fontSize = 14, color = "on_surface_variant" }),
      ui.label({
        text = (attemptedWords > 0 and math.floor(correctWords / attemptedWords * 100 + 0.5) or 100) .. "%",
        fontSize = 14,
        color = "on_surface_variant",
      }),
    }))
  end

  -- Flowing words, three lines, caret blinking, right under the settings.
  table.insert(rows, wordsSection())

  if state == "ready" then
    table.insert(rows, ui.row({ justify = "center" }, {
      ui.label({
        text = "Start typing to begin - space advances, Esc closes",
        fontSize = 12,
        color = "on_surface_variant",
      }),
    }))
  end

  -- The keystroke sink: fully invisible (zero opacity, 1px tall) but focused,
  -- so every printable key lands here while the panel is open. The hint label
  -- stays the only visible affordance at the bottom, and the word-window caret
  -- is the only cursor on screen.
  table.insert(rows, ui.input({
    key = "typer-" .. inputKey,
    value = "",
    focus = true,
    frameVisible = false,
    opacity = 0,
    height = 1,
    fontSize = 8,
    onChange = "onInputChange",
    onSubmit = "onSubmit",
  }))

  panel.render(ui.column({ flexGrow = 1, gap = 10 }, rows))
end

-- ---------------------------------------------------------------------------
-- Game flow
-- ---------------------------------------------------------------------------

local function finish()
  state = "done"
  panel.setWantsSecondTicks(false)
  panel.setNeedsFrameTick(false)
  elapsedMs = noctalia.nowMs() - (startMs or noctalia.nowMs())
  local minutes = math.max(elapsedMs, 1) / 60000
  lastWpm = math.floor((correctChars / 5) / minutes + 0.5)
  lastAcc = attemptedWords > 0 and math.floor(correctWords / attemptedWords * 100 + 0.5) or 100
  saveResult(lastWpm, lastAcc)
  render()
end

local function advance()
  qIndex = qIndex + 1
  typed = ""
  -- Fresh input for the next word: a new key creates a new control, which
  -- grabs focus and starts empty. Never bump while typing mid-word - that
  -- would destroy the input the user is typing into.
  inputKey = inputKey + 1
  -- Shift the text window up when the caret moves past the first visible line.
  if qIndex > #queue then
    for _ = 1, 20 do table.insert(queue, randomWord()) end
  end
  local ranges = computeLineRanges(lineStart)
  if qIndex > ranges[1].stop then
    lineStart = ranges[2].first
  end
  if modeIndex == 2 and (qIndex - 1) >= (WORD_OPTIONS[lengthIndex] or 25) then
    finish()
  else
    render()
  end
end

local function startClock()
  state = "typing"
  startMs = noctalia.nowMs()
  elapsedMs = 0
  panel.setWantsSecondTicks(true)
end

function onInputChange(text)
  if state == "done" then return end
  if text == nil or text == "" then
    typed = ""
    render()
    return
  end

  if state == "ready" then
    startClock()
  end

  -- Space: submit the word before the space.
  if text:sub(-1) == " " then
    local word = text:sub(1, -2)
    if word ~= "" then
      local target = queue[qIndex] or randomWord()
      attemptedWords = attemptedWords + 1
      if word == target then
        correctWords = correctWords + 1
        correctChars = correctChars + #target + 1 -- the word plus its space
      end
      advance()
    else
      -- Double space: just clear the field, no penalty.
      typed = ""
      inputKey = inputKey + 1
      render()
    end
    return
  end

  typed = text

  -- Monkeytype-style: no auto-advance on exact match. Space submits the word
  -- (see above); letters only re-render the per-char coloring.
  render()
end

-- Second ticks: countdown in time mode.
function update()
  if state ~= "typing" or modeIndex ~= 1 then return end
  elapsedMs = noctalia.nowMs() - (startMs or noctalia.nowMs())
  if elapsedMs >= (TIME_OPTIONS[lengthIndex] or 30) * 1000 then
    finish()
  else
    render()
  end
end

-- Frame ticks: caret blink (re-render only when the phase flips, twice a second).
function onFrameTick(_deltaMs)
  if state == "done" then return end
  local phase = math.floor(noctalia.nowMs() / 500) % 2
  if phase ~= blinkPhase then
    blinkPhase = phase
    render()
  end
end

-- ---------------------------------------------------------------------------
-- UI callbacks
-- ---------------------------------------------------------------------------

function onLangChanged(index, _text)
  langIndex = tonumber(index) or 1
  resetSession()
  render()
end

function onModeChanged(index, _text)
  modeIndex = tonumber(index) or 1
  lengthIndex = 2
  resetSession()
  render()
end

function onLengthChanged(index, _text)
  lengthIndex = tonumber(index) or 1
  resetSession()
  render()
end

function onRestart()
  resetSession()
  render()
end

function onSubmit()
  -- Enter mid-test does nothing; on the results screen the focused input
  -- handles restart.
end

function onCloseClicked()
  panel.close()
end

function onOpen(_context)
  -- Seeded session defaults from the plugin settings; the panel selects
  -- override them per session.
  if noctalia.getConfig("language") == "es" then langIndex = 2 end
  if noctalia.getConfig("mode") == "words" then modeIndex = 2 end
  resetSession()
  render()
end
