--!nonstrict
-- Keyboard on-screen keyboard: a compact key grid in Noctalia's theme, at one of nine places
-- on the screen. The layer never takes the keyboard focus, so each key goes to the window
-- you type in, typed there with wtype. The keys follow the active language: Turkish for TR,
-- English otherwise. Shift, Ctrl and Alt hold for the next key. Renders "keyboard.model".
--
-- The grip shows a 3 × 3 grid of places in place of the keys; a click on one puts the
-- keyboard there. A layer gets no pointer position, so it cannot be dragged.

local model = nil
local shift, ctrl, alt = false, false, false

local function send(command)
  command.n = noctalia.nowMs()
  noctalia.state.set("keyboard.command", command)
end

-- Each key as { normal, shifted }.
local SETS = {
  EN = {
    { { "1", "!" }, { "2", "@" }, { "3", "#" }, { "4", "$" }, { "5", "%" }, { "6", "^" },
      { "7", "&" }, { "8", "*" }, { "9", "(" }, { "0", ")" }, { "-", "_" }, { "=", "+" } },
    { { "q", "Q" }, { "w", "W" }, { "e", "E" }, { "r", "R" }, { "t", "T" }, { "y", "Y" },
      { "u", "U" }, { "i", "I" }, { "o", "O" }, { "p", "P" }, { "[", "{" }, { "]", "}" } },
    { { "a", "A" }, { "s", "S" }, { "d", "D" }, { "f", "F" }, { "g", "G" }, { "h", "H" },
      { "j", "J" }, { "k", "K" }, { "l", "L" }, { ";", ":" }, { "'", "\"" }, { "\\", "|" } },
    { { "z", "Z" }, { "x", "X" }, { "c", "C" }, { "v", "V" }, { "b", "B" }, { "n", "N" },
      { "m", "M" }, { ",", "<" }, { ".", ">" }, { "/", "?" } },
  },
  TR = {
    { { "1", "!" }, { "2", "'" }, { "3", "^" }, { "4", "+" }, { "5", "%" }, { "6", "&" },
      { "7", "/" }, { "8", "(" }, { "9", ")" }, { "0", "=" }, { "*", "?" }, { "-", "_" } },
    { { "q", "Q" }, { "w", "W" }, { "e", "E" }, { "r", "R" }, { "t", "T" }, { "y", "Y" },
      { "u", "U" }, { "ı", "I" }, { "o", "O" }, { "p", "P" }, { "ğ", "Ğ" }, { "ü", "Ü" } },
    { { "a", "A" }, { "s", "S" }, { "d", "D" }, { "f", "F" }, { "g", "G" }, { "h", "H" },
      { "j", "J" }, { "k", "K" }, { "l", "L" }, { "ş", "Ş" }, { "i", "İ" }, { ",", ";" } },
    { { "z", "Z" }, { "x", "X" }, { "c", "C" }, { "v", "V" }, { "b", "B" }, { "n", "N" },
      { "m", "M" }, { "ö", "Ö" }, { "ç", "Ç" }, { ".", ":" } },
  },
}

-- The nine places, row by row, with the glyph of each.
local SPOTS = {
  { { "top_left", "arrow-up-left" }, { "top", "arrow-up" }, { "top_right", "arrow-up-right" } },
  { { "left", "arrow-left" }, { "center", "point" }, { "right", "arrow-right" } },
  { { "bottom_left", "arrow-down-left" }, { "bottom", "arrow-down" }, { "bottom_right", "arrow-down-right" } },
}

local PADDING, GAP, GRIP = 8, 5, 20

local render

local function keyHeight()
  local height = model and model.oskSize and model.oskSize.height or 220
  return math.max(20, math.floor((height - 2 * PADDING - GRIP - 5 * GAP) / 5))
end

-- Types text, or presses a key by its name with -k, holding Ctrl and Alt when they are on.
local function press(text, keyName)
  local argv = { "wtype" }
  if ctrl then
    table.insert(argv, "-M")
    table.insert(argv, "ctrl")
  end
  if alt then
    table.insert(argv, "-M")
    table.insert(argv, "alt")
  end
  if keyName then
    table.insert(argv, "-k")
    table.insert(argv, keyName)
  else
    table.insert(argv, "--")
    table.insert(argv, text)
  end
  noctalia.runAsync(argv)
  shift, ctrl, alt = false, false, false
  render()
end

local function key(label, onClick, options)
  options = options or {}
  return ui.button({
    text = label,
    glyph = options.glyph,
    variant = options.on and "primary" or "default",
    flexGrow = options.grow or 1,
    height = options.height or keyHeight(),
    onClick = onClick,
  })
end

local function toggle(label, value, flip)
  return key(label, function()
    flip()
    render()
  end, { on = value, grow = 1.5 })
end

local function activeSet()
  for _, entry in ipairs(model and model.entries or {}) do
    if entry.key == model.current and SETS[entry.short] then
      return SETS[entry.short]
    end
  end
  return SETS.EN
end

-- The top row: the grip shows or hides the places, ✕ hides the keyboard. They are buttons,
-- as a layer's rows take no clicks.
local function gripRow(picking)
  return ui.row({ gap = GAP, align = "center", height = GRIP }, {
    ui.button({
      glyph = picking and "keyboard" or "grip-horizontal",
      variant = "ghost",
      controlSize = "sm",
      flexGrow = 1,
      height = GRIP,
      onClick = function() send({ action = "osk_move" }) end,
    }),
    ui.button({
      glyph = "x",
      variant = "ghost",
      controlSize = "sm",
      width = 28,
      height = GRIP,
      onClick = function() send({ action = "osk", open = false }) end,
    }),
  })
end

local function keys()
  local rows = {}
  for index, keysOfRow in ipairs(activeSet()) do
    local row = {}
    if index == 2 then
      table.insert(row, key("Tab", function() press(nil, "Tab") end, { grow = 1.5 }))
    elseif index == 4 then
      table.insert(row, toggle("Shift", shift, function() shift = not shift end))
    end
    for _, pair in ipairs(keysOfRow) do
      local text = shift and pair[2] or pair[1]
      table.insert(row, key(text, function() press(text) end))
    end
    if index == 1 then
      table.insert(row, key("", function() press(nil, "BackSpace") end, { glyph = "backspace", grow = 1.5 }))
    elseif index == 3 then
      table.insert(row, key("", function() press(nil, "Return") end, { glyph = "corner-down-left", grow = 1.5 }))
    end
    table.insert(rows, ui.row({ gap = GAP }, row))
  end
  table.insert(rows, ui.row({ gap = GAP }, {
    toggle("Ctrl", ctrl, function() ctrl = not ctrl end),
    toggle("Alt", alt, function() alt = not alt end),
    key("", function() press(nil, "space") end, { glyph = "space", grow = 6 }),
    key("", function() press(nil, "Left") end, { glyph = "arrow-left" }),
    key("", function() press(nil, "Right") end, { glyph = "arrow-right" }),
  }))
  return rows
end

-- The nine places, the current one marked.
local function spots()
  local current = model and model.oskSpot or "bottom"
  -- The three rows of places take the height of the five rows of keys.
  local height = math.floor((5 * keyHeight() + 2 * GAP) / 3)
  local rows = {}
  for _, line in ipairs(SPOTS) do
    local row = {}
    for _, spot in ipairs(line) do
      table.insert(row, key("", function() send({ action = "osk_place", spot = spot[1] }) end,
        { glyph = spot[2], on = spot[1] == current, height = height }))
    end
    table.insert(rows, ui.row({ gap = GAP }, row))
  end
  return rows
end

render = function()
  local picking = model ~= nil and model.oskPicking == true
  local rows = { gripRow(picking) }
  for _, row in ipairs(picking and spots() or keys()) do
    table.insert(rows, row)
  end
  layer.render(ui.column({
    -- A new key for each view, so no button of one is reused in the other.
    key = picking and "spots" or "keys",
    gap = GAP,
    padding = PADDING,
    fill = "surface_container/0.96",
    border = "outline_variant",
    borderWidth = 1,
    radius = 12,
    flexGrow = 1,
  }, rows))
end

-- What the keyboard shows of the model. The service publishes every second; the keyboard
-- draws again only when this changes, so it does not flicker.
local function shown(value)
  if value == nil then
    return ""
  end
  local size = value.oskSize or {}
  local current = nil
  for _, entry in ipairs(value.entries or {}) do
    if entry.key == value.current then
      current = entry.short
    end
  end
  return table.concat({
    tostring(current), tostring(value.oskPicking), tostring(value.oskSpot), tostring(size.height),
  }, " ")
end

local lastShown = nil
noctalia.state.watch("keyboard.model", function(value)
  model = value
  local now = shown(value)
  if now ~= lastShown then
    lastShown = now
    render()
  end
end)
model = noctalia.state.get("keyboard.model")
render()
