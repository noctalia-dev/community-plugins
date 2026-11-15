-- Regression tests for panel.luau, runnable with Lua 5.4.
--
-- The panel is pure Lua/Luau: it only talks to the shell through the
-- `noctalia`, `panel` and `ui` globals. Those globals are simulated here so
-- the entry point can be loaded and driven the way Noctalia would: open it,
-- press it, change a setting. Then the rendered tree is inspected.
--
-- The settings the panel changes accumulate in `overrides` (the layer the
-- panel writes and the script reads), so the checks look at what was really
-- stored and not just at what is visible on screen.
--
-- Usage: lua5.4 bin/test-panel.lua panel.luau

local panelPath = arg[1] or "panel.luau"
local pluginDir = panelPath:match("^(.*)/[^/]+$") or "."

local checks = 0
local failures = 0

local function check(condition, message)
  checks = checks + 1
  if not condition then
    failures = failures + 1
    io.stderr:write("FAIL: " .. message .. "\n")
  end
end

local function eq(current, expected, message)
  check(
    current == expected,
    string.format("%s (got %s, expected %s)", message, tostring(current), tostring(expected))
  )
end

-- Shell simulation ------------------------------------------------------

-- Initial configuration (what is in the settings.toml).
local config = {
  font_family = "Departure Mono",
  font_size = 22,
  direction = "down",
  marker = false,
  karaoke = true,
  footer = false,
  hints = false,
  header = false,
  spacing = 2,
  ghost = true,
  offset_ms = 0,
  width = 1200,
  height = 820,
  anchor = "center",
  custom_x = 100,
  custom_y = 100,
  accent = "primary",
  custom_color = "#e46767",
  active_scale = 1.35,
  visible_above = 6,
  visible_below = 6,
}

-- Overrides layer: what the panel has written.
local overrides = {}
-- Reads of the overrides file (to check the cache).
local reads = 0
-- Processes the panel has spawned.
local commands = {}
local tree = nil
local closed = false
local notified = {}
local logs = {}
-- The panel redraws on every change; some callbacks arrive late.
local renders = 0
-- Simulated failures: the overrides dump and playerctl.
local failMerge = false
local deferPlayerctl = false
local deferredPlayerctl = nil

local function parseValue(value, kind)
  if kind == "bool" then
    return value == "true" or value == "1"
  elseif kind == "int" then
    return math.floor(tonumber(value) or 0)
  elseif kind == "float" then
    return tonumber(value) or 0
  end
  return value
end

-- Serializes a flat table (text keys, scalars) as JSON.
local function encodeTable(table_map)
  local parts = {}
  local keys = {}
  for key in pairs(table_map) do
    table.insert(keys, key)
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local value = table_map[key]
    local text_value
    if type(value) == "string" then
      text_value = string.format('%q', value)
    else
      text_value = tostring(value)
    end
    table.insert(parts, string.format('%q: %s', key, text_value))
  end
  return "{" .. table.concat(parts, ", ") .. "}"
end

-- What `set-setting.py read` returns: the configuration saved in the
-- settings.toml. The panel asks for it because the manifest no longer declares
-- those settings, so the double has to answer it for the render to see the
-- real values and not the defaults.
local function encodeConfig()
  return encodeTable(config)
end

local function encodeOverrides()
  return encodeTable(overrides)
end

-- Minimal decoder: the helper only returns flat objects with scalars
-- ({"key": value, ...}). Before, the double always returned the overrides
-- no matter what, so reading the stored values could not be tested:
-- the two answers were confused.
--
-- Beware of Lua patterns: they have no alternation, so the value is
-- captured loosely (up to the comma or the closing brace) and converted later.
local function jsonDecode(text)
  local table_map = {}
  if type(text) ~= "string" then
    return table_map
  end
  for setting_key, setting_value in text:gmatch('"([%w_]+)"%s*:%s*([^,}]+)') do
    setting_value = setting_value:match("^%s*(.-)%s*$")
    if setting_value == "true" then
      table_map[setting_key] = true
    elseif setting_value == "false" then
      table_map[setting_key] = false
    elseif setting_value:sub(1, 1) == '"' then
      table_map[setting_key] = setting_value:sub(2, -2)
    else
      table_map[setting_key] = tonumber(setting_value)
    end
  end
  return table_map
end

local function node(kind)
  return function(props, children)
    return { kind = kind, props = props or {}, children = children or {} }
  end
end

ui = {
  column = node("column"),
  row = node("row"),
  scroll = node("scroll"),
  label = node("label"),
  separator = node("separator"),
  spacer = node("spacer"),
  button = node("button"),
  glyph = node("glyph"),
  toggle = node("toggle"),
  select = node("select"),
  input = node("input"),
  slider = node("slider"),
}

panel = {
  close = function()
    closed = true
  end,
  render = function(nextTree)
    renders = renders + 1
    tree = nextTree
  end,
  setNeedsFrameTick = function() end,
}

noctalia = {
  tr = function(key)
    return key
  end,
  getenv = function()
    return "/home/tester"
  end,
  getConfig = function(key)
    return config[key]
  end,
  getSetting = function()
    return nil
  end,
  pluginDataDir = function()
    return "/tmp/lyrics-carousel-selftest/data"
  end,
  pluginDir = function()
    return "/tmp/lyrics-carousel-selftest/plugin"
  end,
  readFile = function()
    reads = reads + 1
    return encodeOverrides()
  end,
  writeFile = function()
    return true
  end,
  fileExists = function()
    return false
  end,
  mkdirAll = function()
    return true
  end,
  json = {
    encode = function()
      return encodeOverrides()
    end,
    decode = jsonDecode,
  },
  outputs = function()
    return { { name = "DP-1", width = 1920, height = 1080, focused = true } }
  end,
  openSettings = function() end,
  notify = function(title, body)
    table.insert(notified, { title = title, body = body })
  end,
  notifyError = function(title, body)
    table.insert(notified, { title = title, body = body })
  end,
  log = function(message)
    table.insert(logs, tostring(message))
  end,
  runAsync = function(argv, callback)
    local exitCode = 0
    local output = ""
    if type(argv) == "table" then
      table.insert(commands, argv)
      -- A slow playerctl: the callback arrives after the panel has closed.
      if argv[1] == "playerctl" and deferPlayerctl and callback ~= nil then
        deferredPlayerctl = callback
        return true
      end
      -- The settings helper is the only writer: it is logged.
      if argv[1] == "python3" and argv[2] and argv[2]:match("set%-setting%.py$") then
        local render_mode = argv[3]
        if render_mode == "override" then
          if argv[4] == "explode" then
            exitCode = 1
          else
            overrides[argv[4]] = parseValue(argv[5], argv[6])
          end
        elseif render_mode == "merge" and failMerge then
          exitCode = 1
        elseif render_mode == "read" then
          -- The panel asks for the real values from the settings.toml: the
          -- double answers with the configuration assembled for the test.
          output = encodeConfig()
        end
      end
    end
    if callback then
      callback({
        exitCode = exitCode,
        stdout = output,
        stderr = exitCode == 0 and "" or "boom",
      })
    end
    return true
  end,
}

-- The overrides layer expires after 2 s (os.time). The whole test runs
-- within the same second: whoever needs a fresh read asks for it with
-- settingsModule.refresh() beforehand (the widget, below).

-- Relative `require`: Noctalia resolves it from the entry point directory.
local settingsModule = nil
require = function(name)
  local relative = name:gsub("^%./", ""):gsub("%.luau$", "")
  local module = dofile(pluginDir .. "/" .. relative .. ".luau")
  if relative:match("settings") then
    settingsModule = module
  end
  return module
end

dofile(panelPath)

-- Helpers over the tree -----------------------------------------------------

local function collect(current, kind, result)
  result = result or {}
  if type(current) ~= "table" then
    return result
  end
  if current.kind == kind then
    table.insert(result, current)
  end
  for _, child in ipairs(current.children or {}) do
    collect(child, kind, result)
  end
  return result
end

local function findByKey(kind, key)
  for _, node in ipairs(collect(tree, kind)) do
    if node.props.key == key then
      return node
    end
  end
  return nil
end

-- The toggle whose label text is `label`.
local function toggleFor(label)
  for _, row in ipairs(collect(tree, "row")) do
    for _, child in ipairs(row.children or {}) do
      if child.kind == "label" and child.props.text == label then
        for _, sibling in ipairs(row.children or {}) do
          if sibling.kind == "toggle" then
            return sibling
          end
        end
      end
    end
  end
  return nil
end

-- The number shown next to a size button.
local function stepperValue(buttonKey)
  for _, row in ipairs(collect(tree, "row")) do
    local hasButton = false
    for _, child in ipairs(row.children or {}) do
      if child.kind == "button" and child.props.key == buttonKey then
        hasButton = true
      end
    end
    if hasButton then
      for _, child in ipairs(row.children or {}) do
        if child.kind == "label" then
          return tonumber(child.props.text)
        end
      end
    end
  end
  return nil
end

-- Looks for a fragment in any argument of the spawned processes.
local function commandContains(fragmento)
  for _, argv in ipairs(commands) do
    for _, value in ipairs(argv) do
      if type(value) == "string" and value:find(fragmento, 1, true) then
        return true
      end
    end
  end
  return false
end

-- Delivers the playerctl callback that was left pending.
local function triggerDeferredPlayerctl()
  local callback = deferredPlayerctl
  deferredPlayerctl = nil
  if callback ~= nil then
    callback({ exitCode = 0, stdout = "", stderr = "" })
  end
end

onOpen()

-- 1. Toggles turn on and off -----------------------------

local TOGGLES = {
  "karaoke",
  "marker",
  "header",
  "footer",
  "hints",
  "ghost",
}

for _, name in ipairs(TOGGLES) do
  local toggle = toggleFor(name)
  check(toggle ~= nil, "the panel has a switch for " .. name)
  if toggle ~= nil then
    -- Noctalia delivers the value as a string: "true" / "false".
    toggle.props.onChange("true")
    eq(toggleFor(name).props.checked, true, "the switch " .. name .. " turns on")
    eq(overrides[name], true, "the switch " .. name .. " stores the value")
    toggleFor(name).props.onChange("false")
    eq(toggleFor(name).props.checked, false, "the switch " .. name .. " turns off")
    eq(overrides[name], false, "the switch " .. name .. " stores the off state")
  end
end

-- 1b. Text mode and the optional visualizer no longer exist -----------------
--
-- The window is image only and the visualizer is always the background: these
-- controls must not come back to the panel even if old keys remain in the
-- settings.toml.

check(findByKey("toggle", "toggle-equalizer") == nil, "there is no visualizer switch")
check(findByKey("button", "mode-text") == nil, "there is no text mode button")
check(findByKey("button", "mode-image") == nil, "there is no image mode button")
check(findByKey("slider", "animation_ms") == nil, "there is no animation_ms control")

-- 2. The 9 positions are buttons in a 3x3 grid ------------------------

local ANCHOR_GRID = {
  "top-left", "top-center", "top-right",
  "left-center", "center", "right-center",
  "bottom-left", "bottom-center", "bottom-right",
}

local function anchorButton(name)
  return findByKey("button", "anchor-" .. name)
end

local anchorButtons = 0
for _, name in ipairs(ANCHOR_GRID) do
  local button = anchorButton(name)
  check(button ~= nil, "the panel has the position button " .. name)
  if button ~= nil then
    anchorButtons = anchorButtons + 1
  end
end
eq(anchorButtons, 9, "the panel has the 9 position buttons")
check(
  findByKey("select", "anchor-select") == nil,
  "the position is no longer chosen with a dropdown"
)

-- Each row of the grid has three buttons: if a row had four,
-- the grid would no longer represent the screen.
for _, row in ipairs(collect(tree, "row")) do
  local inRow = 0
  for _, child in ipairs(row.children or {}) do
    local key = child.props and child.props.key
    if child.kind == "button" and key and key:match("^anchor%-") and key ~= "anchor-custom" then
      inRow = inRow + 1
    end
  end
  if inRow > 0 then
    eq(inRow, 3, "each row of positions has three buttons")
  end
end

eq(anchorButton("center").props.variant, "secondary", "the center button marks the current position")
anchorButton("top-left").props.onClick()
eq(overrides.anchor, "top-left", "clicking top-left stores that position")
eq(anchorButton("top-left").props.variant, "secondary", "top-left is marked")
eq(anchorButton("center").props.variant, "ghost", "center is no longer marked")

check(findByKey("button", "anchor-custom") ~= nil, "the panel has the custom position")
findByKey("button", "anchor-custom").props.onClick()
eq(overrides.anchor, "custom", "the custom button stores custom")

-- 2-bis. Resizing is requested without keeping the aspect ratio ----------------
--
-- Hyprland 0.57 keeps the aspect ratio in the resize dispatcher unless told
-- otherwise: the size change is silently discarded and the
-- window keeps the tiny size it had.

commands = {}
anchorButton("center").props.onClick()
local resizeExpr = nil
for _, argv in ipairs(commands) do
  local last = argv[#argv]
  if type(last) == "string" and last:find("window%.resize") then
    resizeExpr = last
  end
end
check(resizeExpr ~= nil, "the panel asks to resize the window")
check(
  resizeExpr ~= nil and resizeExpr:find("keep_aspect_ratio = false") ~= nil,
  "the resize does not keep the aspect ratio",
  tostring(resizeExpr)
)

-- 3. A hand-written value is normalized -----------------------------------

config.anchor = "centro"
overrides.anchor = nil
onConfigChanged()
eq(anchorButton("center").props.variant, "secondary", "a Spanish anchor is marked as center")
config.anchor = "center"
onConfigChanged()

-- 4. Hovering the size buttons changes nothing ----------------

config.width = 1200
overrides.width = nil
onConfigChanged()
local minus = findByKey("button", "width-dec")
check(minus ~= nil, "the panel has a button to subtract width")
if minus ~= nil then
  -- Hovering must not change the width. The panel uses no hover
  -- handlers anywhere, so the button must not have one:
  -- if it ever did, it would have to be harmless (and the
  -- assertion below checks that).
  check(
    minus.props.onHover == nil,
    "the width button does not define a hover handler"
  )
  if minus.props.onHover ~= nil then
    minus.props.onHover("true")
    minus.props.onHover("false")
  end
  eq(overrides.width, nil, "hover does not change the width")
  eq(stepperValue("width-dec"), 1200, "hover does not change the visible width")
  minus.props.onClick()
  eq(overrides.width, 1100, "a click subtracts 100 from the width")
  eq(stepperValue("width-dec"), 1100, "the new width is shown")
  local plus = findByKey("button", "width-inc")
  plus.props.onClick()
  eq(overrides.width, 1200, "a click adds 100 to the width")
end

-- 5. The X/Y fields only appear with the custom position --------------

config.anchor = "center"
overrides.anchor = nil
onConfigChanged()
check(findByKey("input", "custom_x") == nil, "without a custom position there is no X field")
check(findByKey("input", "custom_y") == nil, "without a custom position there is no Y field")

config.anchor = "custom"
onConfigChanged()
local inputX = findByKey("input", "custom_x")
local inputY = findByKey("input", "custom_y")
check(inputX ~= nil, "with a custom position there is an X field")
check(inputY ~= nil, "with a custom position there is a Y field")
if inputX ~= nil then
  inputX.props.onChange("250")
  eq(overrides.custom_x, 250, "the X field stores the coordinate")
  -- A value that is not a number changes nothing.
  inputX.props.onChange("abc")
  eq(overrides.custom_x, 250, "the X field ignores what is not a number")
end
config.anchor = "center"
overrides.anchor = nil
onConfigChanged()

-- 6. Text fields have a stable key --------------------------------

for _, node in ipairs(collect(tree, "input")) do
  check(type(node.props.key) == "string", "every text field has a stable key")
end

-- 7. An IPC without a type token infers the type from the key ---------------------

overrides.karaoke = nil
onIpc("set", "karaoke true")
eq(overrides.karaoke, true, "an IPC without a type stores a boolean")
eq(toggleFor("karaoke").props.checked, true, "the switch reflects the IPC")

overrides.marker = nil
onIpc("set", "marker true bool")
eq(overrides.marker, true, "an IPC with a type stores a boolean")

overrides.visible_above = nil
onIpc("set", "visible_above 4")
eq(overrides.visible_above, 4, "an IPC without a type stores a number")

-- 8. The "toggle" IPC flips a toggle ---------------------------------

overrides.footer = nil
onIpc("toggle", "footer")
eq(overrides.footer, true, "toggle turns on a switch that is off")
onIpc("toggle", "footer")
eq(overrides.footer, false, "toggle turns off a switch that is on")

-- 9. The write reports whether it succeeded ------------------------------------

local outcome = nil
settingsModule.write("marker", true, function(ok)
  outcome = ok
end)
eq(outcome, true, "a successful write reports the result")

outcome = nil
settingsModule.write("explode", true, function(ok)
  outcome = ok
end)
eq(outcome, false, "a write that fails reports the failure")

-- 10. A value that looks like a type is not consumed as a token -------------------

overrides.font_family = nil
onIpc("set", "font_family string")
eq(overrides.font_family, "string", "a value with a type name is stored intact")

-- 11. Overrides are cached -----------------------------------------------

settingsModule.refresh()
reads = 0
settingsModule.value("karaoke")
local read_count = reads
check(read_count > 0, "the first read reads the overrides file")
settingsModule.value("marker")
settingsModule.value("footer")
settingsModule.value("width")
eq(reads, read_count, "the following reads use the cache")

-- 12. Language and cache clearing are no longer in the panel -----------------
--
-- The window language is detected automatically (--lang or the system one) and
-- the cache is refreshed with "r" in the window: they are not settings that
-- should take space in the panel.

check(findByKey("button", "lang-auto") == nil, "there is no automatic language button")
check(findByKey("button", "lang-en") == nil, "there is no English language button")
check(findByKey("button", "lang-es") == nil, "there is no Spanish language button")
check(findByKey("button", "clear-cache") == nil, "there is no button to clear the cache")
for _, item in ipairs(collect(tree, "label")) do
  check(
    item.props == nil or item.props.text ~= "clear_cache_hint",
    "the cache-clearing explanation is gone"
  )
end

-- 14. A toggle reads correctly a value that arrives as a string ---------------------
--
-- Noctalia delivers a toggle value as the string "true". If the
-- panel read it with `== true`, the toggle would be drawn off even though
-- the setting was on.

config.karaoke = "true"
overrides.karaoke = nil
onConfigChanged()
eq(toggleFor("karaoke").props.checked, true, "a \"true\" in the config turns on the switch")

config.karaoke = "false"
overrides.karaoke = nil
onConfigChanged()
eq(toggleFor("karaoke").props.checked, false, "a \"false\" in the config turns off the switch")

config.karaoke = true
overrides.karaoke = nil
onConfigChanged()
eq(toggleFor("karaoke").props.checked, true, "a true boolean turns on the switch")

-- 15. The "toggle" IPC flips a value that arrives as a string --------------------
--
-- The widget uses settings.apply to flip. If the stored value arrives as
-- the string "true", flipping it has to turn the toggle off, not leave it
-- as it was.

overrides.footer = nil
config.footer = "true"
settingsModule.refresh()
local alternating = settingsModule.apply("footer", nil)
eq(alternating, false, "alternating a \"true\" turns it off")
eq(overrides.footer, false, "alternating a \"true\" stores the off state")

overrides.footer = nil
config.footer = "false"
settingsModule.refresh()
alternating = settingsModule.apply("footer", nil)
eq(alternating, true, "alternating a \"false\" turns it on")

-- The panel and the widget have to understand the same values: if the panel
-- accepts "1" and the widget does not, the "toggle" IPC would do nothing.
overrides.footer = nil
config.footer = "1"
settingsModule.refresh()
alternating = settingsModule.apply("footer", nil)
eq(alternating, false, "alternating a \"1\" turns it off")
eq(overrides.footer, false, "alternating a \"1\" stores the off state")

-- A setting that is not a toggle is not flipped: it makes no sense to write
-- a boolean where a number belongs.
overrides.width = nil
config.width = 1200
settingsModule.refresh()
eq(settingsModule.apply("width", nil), nil, "a number is not flipped")
eq(overrides.width, nil, "alternating a number writes nothing")

config.footer = false
overrides.footer = nil
settingsModule.refresh()

-- 16. The five missing settings are in the panel ----------------------
--
-- The panel has to be a mirror of the manifest: if a setting can only be
-- changed from the Noctalia settings page, the user thinks the
-- panel is complete when it is not.

overrides = {}
config.anchor = "center"
onConfigChanged()

local function sliderFor(key)
  return findByKey("slider", key)
end

check(sliderFor("spacing") ~= nil, "the panel has the spacing control")
check(sliderFor("animation_ms") == nil, "the animation_ms control no longer exists")
check(sliderFor("offset_ms") ~= nil, "the panel has the offset_ms control")
-- The bar icon is not in the panel: it belongs to the bar widget
-- and is changed in Settings -> Plugins -> Lyrics Carousel. The panel only
-- offers what affects the lyrics window.
check(findByKey("input", "glyph") == nil, "the panel does not have the glyph field")

-- The custom color only makes sense with the "custom" accent: if it is
-- always offered, the user types a hex the script ignores.
config.accent = "primary"
overrides.accent = nil
onConfigChanged()
check(
  findByKey("input", "custom_color") == nil,
  "with a palette accent no custom colour is requested"
)

if sliderFor("spacing") ~= nil then
  sliderFor("spacing").props.onChange("4")
  eq(overrides.spacing, 4, "the spacing control stores an integer")
  sliderFor("spacing").props.onChange("2.9")
  eq(overrides.spacing, 2, "the spacing control truncates to an integer")
end

if sliderFor("offset_ms") ~= nil then
  sliderFor("offset_ms").props.onChange("-250")
  eq(overrides.offset_ms, -250, "the offset control stores a negative")
end

-- An out-of-range value (hand-written in the settings.toml, for
-- example) has to be clamped in the slider: if the panel
-- shows 500 and the script uses 96, the two do not tell the same story.
config.font_size = 500
overrides.font_size = nil
settingsModule.refresh()
onConfigChanged()
if sliderFor("font_size") ~= nil then
  eq(sliderFor("font_size").props.value, 96, "the slider shows the clamped value")
end
config.font_size = 22
overrides.font_size = nil
settingsModule.refresh()
onConfigChanged()

local accentCustom = findByKey("button", "accent-custom")
check(accentCustom ~= nil, "the panel has the custom accent")
if accentCustom ~= nil then
  accentCustom.props.onClick()
  eq(overrides.accent, "custom", "choosing the custom accent stores it")
  local colorInput = findByKey("input", "custom_color")
  check(colorInput ~= nil, "with the custom accent the colour field appears")
  if colorInput ~= nil then
    colorInput.props.onChange("#12ab34")
    eq(overrides.custom_color, "#12ab34", "a valid hex is stored")
    colorInput.props.onChange("rojo")
    eq(overrides.custom_color, "#12ab34", "an invalid colour is not stored")
    colorInput.props.onChange("#12AB3")
    eq(overrides.custom_color, "#12ab34", "a short hex is not stored")
  end
  findByKey("button", "accent-primary").props.onClick()
  check(
    findByKey("input", "custom_color") == nil,
    "returning to a palette accent hides the custom colour"
  )
end
config.accent = "primary"
overrides.accent = nil
onConfigChanged()

-- 17. Numeric controls respect the panel range --------------------
--
-- An out-of-range value leaves the window off-screen or the font
-- empty. The panel limits have to be the same as the ones in the
-- manifest and in the script.

check(sliderFor("font_size") ~= nil, "font_size is adjusted with a slider")
if sliderFor("font_size") ~= nil then
  eq(sliderFor("font_size").props.min, 6, "font_size starts at 6")
  eq(sliderFor("font_size").props.max, 96, "font_size ends at 96")
end
check(sliderFor("visible_above") ~= nil, "visible_above is adjusted with a slider")
if sliderFor("visible_above") ~= nil then
  eq(sliderFor("visible_above").props.max, 20, "visible_above ends at 20")
end
check(sliderFor("active_scale") ~= nil, "active_scale is adjusted with a slider")
if sliderFor("active_scale") ~= nil then
  eq(sliderFor("active_scale").props.min, 1.0, "active_scale starts at 1.0")
  eq(sliderFor("active_scale").props.max, 2.5, "active_scale ends at 2.5")
end

config.anchor = "custom"
overrides.anchor = nil
overrides.custom_x = nil
onConfigChanged()
local inputX2 = findByKey("input", "custom_x")
check(inputX2 ~= nil, "with a custom position there is an X field for the limit")
if inputX2 ~= nil then
  inputX2.props.onChange("-500")
  check(overrides.custom_x ~= -500, "X does not accept negatives")
  eq(overrides.custom_x, 0, "X clamps the negative to the minimum")
  inputX2.props.onChange("999999")
  check(
    overrides.custom_x == nil or overrides.custom_x <= 10000,
    "X does not exceed the maximum"
  )
  eq(overrides.custom_x, 10000, "X clamps to the maximum")
end
config.anchor = "center"
overrides.anchor = nil
onConfigChanged()

overrides.width = nil
onIpc("set", "width 99999 int")
check(overrides.width == nil or overrides.width <= 3840, "the IPC clamps the width to the maximum")
eq(overrides.width, 3840, "the IPC clamps the width to 3840")

overrides.font_size = nil
onIpc("set", "font_size 999 int")
eq(overrides.font_size, 96, "the IPC clamps the font size to 96")

overrides.active_scale = nil
onIpc("set", "active_scale 9.5 float")
eq(overrides.active_scale, 2.5, "the IPC clamps the active scale to 2.5")

-- 18. The window cannot be bigger than the screen -------------------------
--
-- Hyprland accepts a size bigger than the monitor, but the window ends up
-- cut off and the user cannot move it. The panel clamps before launching.

config.width = 3840
config.height = 2160
overrides.width = nil
overrides.height = nil
onConfigChanged()
commands = {}
local launchButton = findByKey("button", "launch")
check(launchButton ~= nil, "the panel has the launch button")
if launchButton ~= nil then
  launchButton.props.onClick()
  check(
    commandContains("size = { 1920, 1080 }"),
    "the size is clipped to the screen"
  )
end

-- 19. Changing the size over IPC moves the window ----------------------------
--
-- If the IPC only stores the setting, the open window keeps the old size
-- until it is launched again.

config.width = 1200
config.height = 820
overrides.width = nil
overrides.height = nil
onConfigChanged()
commands = {}
onIpc("set", "width 1600 int")
check(commandContains("hl.dsp.window"), "the size IPC applies the geometry")

-- 20. A dump failure warns the user ---------------------------------
--
-- If the helper cannot write the settings.toml, the user has to
-- find out: the change stays only in the overrides layer.

failMerge = true
notified = {}
onClose()
check(#notified > 0, "if the dump fails, the panel warns")

-- 21. A callback after closing does not redraw ---------------------------
--
-- playerctl can take longer than the panel. When its callback arrives, the panel
-- is already closed and drawing over the dead tree errors in Noctalia.

deferPlayerctl = true
onOpen()
local rendersBefore = renders
onClose()
triggerDeferredPlayerctl()
eq(renders, rendersBefore, "a closed panel does not redraw")

-- 22. The widget reads the overrides layer ---------------------------------
--
-- The panel writes the glyph into the overrides and dumps them on close; if
-- the widget only looked at the configuration, the bar icon would not change
-- until then (and the panel says it applies right away).

local glyphUsed = nil
barWidget = {
  setGlyph = function(name) glyphUsed = name end,
  setTooltip = function(text) end,
}
config.glyph = "music"
overrides = {}
settingsModule.refresh()
-- The widget defines onConfigChanged and onIpc as globals (that is how
-- Noctalia calls them): loading it with dofile overwrites the panel ones. They
-- are saved and restored, otherwise the rest of the suite would test against
-- the widget instead of against the panel.
local panelOnConfigChanged = onConfigChanged
local panelOnIpc = onIpc
dofile(pluginDir .. "/widget.luau")
local widgetOnIpc = onIpc
onConfigChanged = panelOnConfigChanged
onIpc = panelOnIpc
eq(glyphUsed, "music", "the widget uses the glyph from the configuration")

-- The widget IPC validates the same as the panel: a glyph with
-- uppercase letters or a color that is not a hex would leave the bar or the window
-- without an icon or without a color. The patterns live in lib/settings.luau so
-- that the two entry points do not drift apart.
overrides.glyph = nil
overrides.custom_color = nil
widgetOnIpc("set", "glyph Music!")
eq(overrides.glyph, nil, "the widget IPC does not store an invalid glyph")
widgetOnIpc("set", "glyph music_note")
eq(overrides.glyph, nil, "the widget IPC does not store a glyph with an underscore")
widgetOnIpc("set", "glyph headphones")
eq(overrides.glyph, "headphones", "the widget IPC stores a valid glyph")
widgetOnIpc("set", "custom_color rojo")
eq(overrides.custom_color, nil, "the widget IPC does not store an invalid colour")
widgetOnIpc("set", "custom_color #12ab34")
eq(overrides.custom_color, "#12ab34", "the widget IPC stores a valid colour")
overrides.font_family = nil
widgetOnIpc("set", "font_family=")
eq(overrides.font_family, nil, "the widget IPC does not store an empty family")
check(
  #logs > 0 and logs[#logs]:match("font_family") ~= nil,
  "a value rejected by IPC leaves a warning in the log"
)

overrides.glyph = "volume"
settingsModule.refresh()
update()
eq(glyphUsed, "volume", "the widget uses the glyph from the overrides")

-- 23. All visible text goes through the translations ----------------------
--
-- A placeholder is visible text: if it is hardcoded, the panel shows
-- "music" or "#rrggbb" in any language and the store reviewer flags it
-- as untranslated text. The tr mock returns the key, so
-- the check is that the placeholder is a key and not a literal.

-- The panel was closed in section 21: without opening it again, the changes
-- do not redraw and the checks would look at a stale tree.
onOpen()
-- The glyph field left the panel: its translation is no longer used here.
check(findByKey("input", "glyph") == nil, "the panel still has no glyph field")

config.accent = "custom"
overrides.accent = nil
onConfigChanged()
local colorInput = findByKey("input", "custom_color")
check(colorInput ~= nil, "with a custom accent there is the colour field")
if colorInput ~= nil then
  eq(colorInput.props.placeholder, "color_placeholder", "the colour placeholder goes through the translation")
end
config.accent = "primary"
overrides.accent = nil
onConfigChanged()

-- 24. The font is a single selector with an option to type it --------------
--
-- There used to be two lists of chips and an always visible field: the user
-- did not know which one won. Now there is a dropdown with all the fonts and
-- an "Other" option that reveals the text field.

config.font_family = "Departure Mono"
overrides.font_family = nil
settingsModule.refresh()
onConfigChanged()
local fontSelect = findByKey("select", "font-select")
check(fontSelect ~= nil, "the panel has a single font selector")
check(
  findByKey("input", "font_family") == nil,
  "with a font from the list the text field is not shown"
)
if fontSelect ~= nil then
  local options = fontSelect.props.options
  check(#options >= 8, "the selector includes the available fonts")
  eq(fontSelect.props.selectedIndex, 0, "the selector marks the current font")

  local imageIndex = nil
  for i, label in ipairs(options) do
    if label:find("Ndot 55", 1, true) then
      imageIndex = i - 1
    end
  end
  check(imageIndex ~= nil, "the selector includes the image mode fonts")
  if imageIndex ~= nil then
    fontSelect.props.onChange(tostring(imageIndex))
    eq(overrides.font_family, "Ndot 55", "choosing a font from the list stores it")
    check(
      findByKey("input", "font_family") == nil,
      "choosing a font from the list hides the text field"
    )
  end

  fontSelect = findByKey("select", "font-select")
  fontSelect.props.onChange(tostring(#options - 1))
  local familyInput = findByKey("input", "font_family")
  check(familyInput ~= nil, "choosing Other font shows the text field")
  if familyInput ~= nil then
    familyInput.props.onChange("Iosevka")
    eq(overrides.font_family, "Iosevka", "the font_family field stores the typed family")
    familyInput.props.onChange("")
    eq(overrides.font_family, "Iosevka", "the font_family field does not store an empty family")
    familyInput.props.onChange("Iosevka\nMono")
    eq(overrides.font_family, "Iosevka", "the font_family field does not store line breaks")
  end

  fontSelect = findByKey("select", "font-select")
  if fontSelect ~= nil then
    fontSelect.props.onChange("0")
    eq(overrides.font_family, "Departure Mono", "going back to a font from the list stores it")
    check(
      findByKey("input", "font_family") == nil,
      "returning to a font from the list hides the text field"
    )
  end
end

-- A font that is not in the list (written in the settings.toml) has
-- to be editable without having to pick "Other" by hand.
config.font_family = "Iosevka"
overrides.font_family = nil
settingsModule.refresh()
onConfigChanged()
check(
  findByKey("input", "font_family") ~= nil,
  "a font outside the list opens the text field"
)
config.font_family = "Departure Mono"
overrides.font_family = nil
settingsModule.refresh()
onConfigChanged()

-- 25. The panel offers the ranges that the script later applies ---------------
--
-- The ranges live in lib/settings.luau: the manifest no longer declares them
-- (only the bar icon is left). This test reads them from there and compares them
-- with the controls the panel actually draws (not with the source code):
-- if a slider goes out of range, the user can pick a value that the
-- window later discards.

local function panelLimits(path)
  local limits = {}
  local file = io.open(path, "r")
  if file == nil then
    return nil
  end
  local inside = false
  for file_line in file:lines() do
    if file_line:match("^local LIMITS") then
      inside = true
    elseif inside and file_line:match("^}") then
      inside = false
    elseif inside then
      local setting_key, mn, mx = file_line:match(
        "^%s*(%w+)%s*=%s*{%s*(%-?%d+%.?%d*)%s*,%s*(%-?%d+%.?%d*)%s*}"
      )
      if setting_key then
        limits[setting_key] = { min = tonumber(mn), max = tonumber(mx) }
      end
    end
  end
  file:close()
  return limits
end

-- With the custom position the X and Y fields are visible too. The panel
-- is opened again because in section 21 it was closed (and a closed panel
-- does not redraw). The position is changed through its button (the real
-- user path) so that the panel internal table stays consistent.
onOpen()
local anchorCustom = findByKey("button", "anchor-custom")
check(anchorCustom ~= nil, "the panel has the custom position button")
if anchorCustom ~= nil then
  anchorCustom.props.onClick()
end
eq(overrides.anchor, "custom", "the custom position is chosen")
settingsModule.refresh()
onConfigChanged()

local limits = panelLimits(pluginDir .. "/lib/settings.luau")
check(limits ~= nil and next(limits) ~= nil, "the library declares limits")
if limits ~= nil then
  for setting_key, limit in pairs(limits) do
    local control = findByKey("slider", setting_key)
    if control ~= nil then
      eq(
        control.props.min,
        limit.min,
        "the slider for " .. setting_key .. " starts at the panel minimum"
      )
      eq(
        control.props.max,
        limit.max,
        "the slider for " .. setting_key .. " ends at the panel maximum"
      )
      check(
        control.props.step ~= nil and control.props.step > 0,
        "the slider for " .. setting_key .. " has a step"
      )
    elseif findByKey("input", setting_key) ~= nil then
      -- Text fields (the coordinates) carry no visible range: the
      -- library does the clamping when writing.
    elseif findByKey("button", setting_key .. "-dec") ~= nil then
      -- The +/- counters carry no range in their props: the check is that
      -- they do not go below the minimum declared by the library.
      config[setting_key] = limit.min
      overrides[setting_key] = nil
      settingsModule.refresh()
      onConfigChanged()
      local button_node = findByKey("button", setting_key .. "-dec")
      if button_node ~= nil then
        button_node.props.onClick()
      end
      check(
        overrides[setting_key] == nil or overrides[setting_key] >= limit.min,
        "the counter for " .. setting_key .. " does not go below the panel minimum"
      )
    else
      check(false, "the panel has no control for " .. setting_key)
    end
  end
end

-- 26. The panel sees the stored values even if getConfig does not give them ----------
--
-- The manifest only declares the bar icon. `noctalia.getConfig`
-- only returns the keys it knows, so for the rest the panel
-- reads them from the settings.toml with the helper (`set-setting.py read`). Without that
-- read, the panel would show the default values instead of the user's:
-- the user would move a slider that was already where they left it.

-- getConfig stops answering the keys the manifest no longer declares.
local realGetConfig = noctalia.getConfig
noctalia.getConfig = function(key)
  if key == "glyph" then
    return config[key]
  end
  return nil
end
local written = nil
local readSaved = function()
  settingsModule.refresh()
  onConfigChanged()
  written = encodeConfig()
end
readSaved()
overrides.font_size = nil
eq(
  sliderFor("font_size") and sliderFor("font_size").props.value,
  config.font_size,
  "the slider shows the stored value, not the default"
)
-- And a value that only exists in the settings.toml (never in the manifest)
-- has to reach the panel too. The override is cleared first: it wins
-- over what is stored, so if we left it there the panel would show that one.
overrides.font_size = nil
config.font_size = 20
readSaved()
eq(
  sliderFor("font_size") and sliderFor("font_size").props.value,
  20,
  "when the stored value changes the panel reflects it"
)
noctalia.getConfig = realGetConfig

-- Result ------------------------------------------------------------------

if failures > 0 then
  io.stderr:write(string.format("%d of %d checks failed\n", failures, checks))
  os.exit(1)
end
print(string.format("%d checks passed", checks))
