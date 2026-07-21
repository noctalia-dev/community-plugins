--!nonstrict

-- Service/UI state contract
-- -------------------------
-- `keymap.snapshot` is replaced atomically by the service:
-- {
--   status = "idle" | "loading" | "ready" | "error",
--   error = string,
--   compositor = "Hyprland",
--   source = string?,
--   updated_at = string?,
--   total = number,
--   warnings = { string },
--   categories = {
--     {
--       id = string,
--       name = string,
--       binds = {
--         {
--           id = string,
--           modifiers = { "SUPER", "CTRL", ... },
--           key = string,
--           description = string,
--           dispatcher = string?,
--           activation = "press" | "release",
--         },
--       },
--     },
--   },
-- }
-- The panel increments `keymap.refresh_request` to request a new
-- snapshot. It never mutates the service-owned snapshot.

local SNAPSHOT_KEY = "keymap.snapshot"
local REFRESH_KEY = "keymap.refresh_request"
local CREATE_REQUEST_KEY = "keymap.create_request"
local CREATE_RESULT_KEY = "keymap.create_result"
local UPDATE_REQUEST_KEY = "keymap.update_request"
local UPDATE_RESULT_KEY = "keymap.update_result"

local EMPTY_SNAPSHOT = {
  status = "idle",
  error = "",
  compositor = "",
  total = 0,
  categories = {},
  hidden = {},
}

local snapshot = EMPTY_SNAPSHOT
local searchQuery = ""
local searchRevision = 0
local viewMode = "keyboard"
local keyboardLayoutId = ""
local selectedKeyboardKey = nil
local activeModifiers = { SUPER = false, CTRL = false, SHIFT = false, ALT = false }
local creatorOpen = false
local creatorKeys = {}
local creatorKeysText = ""
local creatorActivation = "press"
local creatorCommand = ""
local creatorCommandKind = "shell"
local creatorLibraryEntryId = ""
local creatorDescription = ""
local creatorCategoryIndex = 0
local creatorNewCategory = ""
local creatorCategoryNamesFrozen = {}
local creatorContextCompositor = ""
local creatorContextSource = ""
local creatorRevision = 0
local creatorRequestId = ""
local creatorRequestCounter = 0
local creatorBusy = false
local creatorError = ""
local commandLibraryOpen = false
local commandLibraryQuery = ""
local commandLibrarySourceIndex = 0
local commandLibraryCategoryIndex = 0
local commandLibraryReadinessIndex = 0
local commandLibraryRevision = 0
local formMode = "create"
local editorMode = false
local editingBindId = ""
local editingCategory = ""
local editingCapabilities = {}
local editingAction = ""
local editingRequestId = ""
local editingOperation = "update"
local editingSnapshotBefore = nil
local deleteConfirmBindId = ""
local hiddenDeleteConfirmBindId = ""
local renamingCategoryId = ""
local renamingCategoryOriginal = ""
local renamingCategoryValue = ""
local renamingCategoryRevision = 0
local render
local selectKeyboardKey
local env = getfenv()
local dynamicCallbackNames = {}
local renderCallbackNames = nil

local COMMAND_LIBRARY = { entries = {} }
do
  local encoded = noctalia.readFile("command_library.json")
  if type(encoded) == "string" and type(noctalia.json) == "table"
    and type(noctalia.json.decode) == "function" then
    local ok, decoded = pcall(noctalia.json.decode, encoded)
    if ok and type(decoded) == "table" and decoded.schema == 1
      and type(decoded.entries) == "table" then
      COMMAND_LIBRARY = decoded
    end
  end
end

local function tr(key, args)
  return noctalia.tr(key, args)
end

local function cfg(key)
  return noctalia.getConfig(key)
end

local function asString(value, fallback)
  if type(value) == "string" and value ~= "" then
    return value
  end
  return fallback or ""
end

local function asArray(value)
  if type(value) == "table" then
    return value
  end
  return {}
end

local function registerDynamicCallback(name, callback)
  env[name] = callback
  if renderCallbackNames ~= nil then
    renderCallbackNames[name] = true
  end
  return name
end

local function finishDynamicCallbackRender()
  local previous = dynamicCallbackNames
  dynamicCallbackNames = renderCallbackNames or {}
  renderCallbackNames = nil
  for name, _ in pairs(previous) do
    if dynamicCallbackNames[name] ~= true then
      env[name] = nil
    end
  end
end

local function shellQuote(value)
  return "'" .. asString(value):gsub("'", "'\\''") .. "'"
end

local function sourceDirectory()
  local source = asString(snapshot.source)
  if source == "" then return "" end
  local expanded = noctalia.expandPath(source)
  local directory = expanded:match("^(.*)/[^/]*$")
  if directory == nil then return "." end
  if directory == "" then return "/" end
  return directory
end

local function normalized(value)
  return string.lower(noctalia.string.trim(asString(value)))
end

local MODIFIER_ORDER = { "SUPER", "CTRL", "SHIFT", "ALT" }
local MODIFIER_ALIASES = {
  super = "SUPER", meta = "SUPER", win = "SUPER", logo = "SUPER", mod = "SUPER", mod4 = "SUPER",
  ctrl = "CTRL", control = "CTRL",
  shift = "SHIFT",
  alt = "ALT", option = "ALT", mod1 = "ALT",
}

local KEY_ALIASES = {
  escape = "esc", esc = "esc",
  ["return"] = "enter", enter = "enter", kp_enter = "numenter", kpenter = "numenter",
  space = "space", spacebar = "space",
  print = "prtsc", printscreen = "prtsc", sys_req = "prtsc", prtsc = "prtsc",
  scroll_lock = "scrolllock", scrolllock = "scrolllock",
  pause = "pause", ["break"] = "pause",
  insert = "insert", ins = "insert", delete = "delete", del = "delete",
  home = "home", ["end"] = "end", prior = "pgup", page_up = "pgup", pageup = "pgup", pgup = "pgup",
  next = "pgdn", page_down = "pgdn", pagedown = "pgdn", pgdn = "pgdn",
  left = "left", arrowleft = "left", right = "right", arrowright = "right",
  up = "up", arrowup = "up", down = "down", arrowdown = "down",
  grave = "grave", asciitilde = "grave", minus = "minus", underscore = "minus",
  equal = "equal", plus = "equal",
  bracketleft = "bracketleft", braceleft = "bracketleft",
  bracketright = "bracketright", braceright = "bracketright",
  backslash = "backslash", bar = "backslash",
  semicolon = "semicolon", colon = "semicolon", apostrophe = "apostrophe", quotedbl = "apostrophe",
  comma = "comma", less = "comma", period = "period", greater = "period", slash = "slash", question = "slash",
  num_lock = "numlock", numlock = "numlock", kp_divide = "numdivide", kpdivide = "numdivide",
  kp_multiply = "nummultiply", kpmultiply = "nummultiply", kp_subtract = "numminus", kpsubtract = "numminus",
  kp_add = "numplus", kpadd = "numplus", kp_decimal = "numdecimal", kpdecimal = "numdecimal",
  num_plus = "numplus", ["num_+"] = "numplus", num_minus = "numminus", ["num_-"] = "numminus",
  num_multiply = "nummultiply", ["num_*"] = "nummultiply",
  num_divide = "numdivide", ["num_/"] = "numdivide",
  kp_insert = "num0", kpinsert = "num0", kp_end = "num1", kpend = "num1",
  kp_down = "num2", kpdown = "num2", kp_next = "num3", kpnext = "num3",
  kp_left = "num4", kpleft = "num4", kp_begin = "num5", kpbegin = "num5",
  kp_right = "num6", kpright = "num6", kp_home = "num7", kphome = "num7",
  kp_up = "num8", kpup = "num8", kp_prior = "num9", kpprior = "num9",
  kp_delete = "numdecimal", kpdelete = "numdecimal",
}

local SYMBOL_ALIASES = {
  ["~"] = "grave", ["!"] = "1", ["@"] = "2", ["#"] = "3",
  ["$"] = "4", ["%"] = "5", ["^"] = "6", ["&"] = "7", ["*"] = "8",
  ["("] = "9", [")"] = "0", ["-"] = "minus", ["_"] = "minus", ["="] = "equal", ["+"] = "equal",
  ["["] = "bracketleft", ["{"] = "bracketleft", ["]"] = "bracketright", ["}"] = "bracketright",
  ["\\"] = "backslash", ["|"] = "backslash", [";"] = "semicolon", [":"] = "semicolon",
  ["'"] = "apostrophe", ["\""] = "apostrophe", [","] = "comma", ["<"] = "comma",
  ["."] = "period", [">"] = "period", ["/"] = "slash", ["?"] = "slash",
}
SYMBOL_ALIASES[string.char(96)] = "grave"

local function canonicalModifier(value)
  return MODIFIER_ALIASES[normalized(value)] or string.upper(asString(value))
end

local function canonicalKey(value)
  local raw = normalized(value)
  if SYMBOL_ALIASES[raw] ~= nil then
    return SYMBOL_ALIASES[raw]
  end
  local key = raw:gsub("%s+", "_"):gsub("%-", "_")
  local rangeStart, rangeEnd = key:match("^(%d)_(%d)$")
  if rangeStart ~= nil then
    return rangeStart .. "-" .. rangeEnd
  end
  if KEY_ALIASES[key] ~= nil then
    return KEY_ALIASES[key]
  end
  local numpad = key:match("^kp_?(%d)$") or key:match("^num_?(%d)$")
  if numpad ~= nil then
    return "num" .. numpad
  end
  if key:match("^f%d%d?$") or key:match("^[a-z]$") or key:match("^%d$") then
    return key
  end
  return key
end

local function modifierSignature(modifiers)
  local enabled = {}
  local extras = {}
  for _, modifier in ipairs(asArray(modifiers)) do
    local canonical = canonicalModifier(modifier)
    if activeModifiers[canonical] ~= nil then
      enabled[canonical] = true
    else
      extras[#extras + 1] = canonical
    end
  end
  local ordered = {}
  for _, modifier in ipairs(MODIFIER_ORDER) do
    if enabled[modifier] then
      ordered[#ordered + 1] = modifier
    end
  end
  table.sort(extras)
  for _, modifier in ipairs(extras) do
    ordered[#ordered + 1] = modifier
  end
  return table.concat(ordered, "+")
end

local function activeModifierSignature()
  local ordered = {}
  for _, modifier in ipairs(MODIFIER_ORDER) do
    if activeModifiers[modifier] then
      ordered[#ordered + 1] = modifier
    end
  end
  return table.concat(ordered, "+")
end

local function expandedKeys(value)
  local canonical = canonicalKey(value)
  local first, last = canonical:match("^(%d)%-(%d)$")
  if first ~= nil and tonumber(first) <= tonumber(last) then
    local result = {}
    for number = tonumber(first), tonumber(last) do
      result[#result + 1] = tostring(number)
    end
    return result
  end
  return { canonical }
end

local function keyboardIndex()
  local exact = {}
  local any = {}
  for _, category in ipairs(asArray(snapshot.categories)) do
    for _, bind in ipairs(asArray(category.binds)) do
      local signature = modifierSignature(bind.modifiers)
      local indexedKeys = type(bind.keys) == "table" and bind.keys or expandedKeys(bind.key)
      for _, rawKey in ipairs(indexedKeys) do
        local key = canonicalKey(rawKey)
        local entry = {
          bind = bind,
          category = asString(category.name, tr("panel.uncategorized")),
        }
        local chord = signature .. "|" .. key
        exact[chord] = exact[chord] or {}
        exact[chord][#exact[chord] + 1] = entry
        any[key] = any[key] or {}
        any[key][#any[key] + 1] = entry
      end
    end
  end
  return { exact = exact, any = any }
end

local function keyCallback(id, code)
  local name = "onKeyboardKey_" .. id
  return registerDynamicCallback(name, function()
    selectKeyboardKey(code)
  end)
end

local function contains(haystack, needle)
  return string.find(normalized(haystack), needle, 1, true) ~= nil
end

local function bindMatches(bind, needle)
  if contains(bind.description, needle) or contains(bind.key, needle) or contains(bind.dispatcher, needle)
    or contains(bind.action, needle) or contains(bind.mode, needle) then
    return true
  end
  for _, modifier in ipairs(asArray(bind.modifiers)) do
    if contains(modifier, needle) then
      return true
    end
  end
  return false
end

local function filteredCategories()
  local result = {}
  local needle = normalized(searchQuery)

  for _, category in ipairs(asArray(snapshot.categories)) do
    local binds = asArray(category.binds)
    if needle == "" or contains(category.name, needle) then
      result[#result + 1] = {
        id = asString(category.id, asString(category.name)),
        name = asString(category.name, tr("panel.uncategorized")),
        binds = binds,
      }
    else
      local matching = {}
      for _, bind in ipairs(binds) do
        if bindMatches(bind, needle) then
          matching[#matching + 1] = bind
        end
      end
      if #matching > 0 then
        result[#result + 1] = {
          id = asString(category.id, asString(category.name)),
          name = asString(category.name, tr("panel.uncategorized")),
          binds = matching,
        }
      end
    end
  end

  return result
end

local function filteredHidden()
  local result = {}
  local needle = normalized(searchQuery)
  for _, bind in ipairs(asArray(snapshot.hidden)) do
    if needle == "" or bindMatches(bind, needle) or contains(bind.category, needle) then
      result[#result + 1] = bind
    end
  end
  return result
end

local function categoryWeight(category)
  return #asArray(category.binds) + 2
end

-- Split categories into contiguous, approximately equal columns. Contiguous
-- partitions preserve the reading order from the Lua configuration.
local function partitionCategories(categories, requestedColumns)
  if #categories == 0 then
    return {}
  end

  local columnCount = math.max(1, math.min(requestedColumns, #categories))
  local columns = {}
  local index = 1
  local remainingWeight = 0
  for _, category in ipairs(categories) do
    remainingWeight += categoryWeight(category)
  end

  for columnIndex = 1, columnCount do
    local remainingColumns = columnCount - columnIndex
    local target = remainingWeight / (remainingColumns + 1)
    local column = {}
    local weight = 0
    local lastAvailableIndex = #categories - remainingColumns

    while index <= lastAvailableIndex do
      local nextCategory = categories[index]
      local nextWeight = categoryWeight(nextCategory)
      if #column > 0 and math.abs(weight - target) <= math.abs(weight + nextWeight - target) then
        break
      end
      column[#column + 1] = nextCategory
      weight += nextWeight
      index += 1
    end

    columns[#columns + 1] = column
    remainingWeight -= weight
  end

  return columns
end

local function cardFill()
  local color = asString(cfg("card_color"), "surface_variant")
  local opacity = math.max(0, math.min(100, tonumber(cfg("card_opacity")) or 35)) / 100
  if string.sub(color, 1, 1) == "#" then
    local alpha = string.format("%02X", math.floor(opacity * 255 + 0.5))
    if #color == 7 then
      return color .. alpha
    elseif #color == 9 then
      return string.sub(color, 1, 7) .. alpha
    end
    return color
  end
  return color .. "/" .. string.format("%.2f", opacity)
end

local function modifierStyle(token)
  local name = normalized(token)
  if name == "super" or name == "meta" or name == "win" or name == "logo" then
    return cfg("super_color"), cfg("super_text_color")
  elseif name == "ctrl" or name == "control" then
    return cfg("ctrl_color"), cfg("ctrl_text_color")
  elseif name == "shift" then
    return cfg("shift_color"), cfg("shift_text_color")
  elseif name == "alt" or name == "mod1" or name == "option" then
    return cfg("alt_color"), cfg("alt_text_color")
  end
  return cfg("key_color"), cfg("key_text_color")
end

-- BEGIN KEYBOARD LAYOUT DATA
local KEYBOARD_100 = {
  -- Function row: 16 keys.
  {
    { id = "escape", label = "Esc", code = "Esc", units = 1 },
    { spacer = 1 },
    { id = "f1", label = "F1", code = "F1", units = 1 },
    { id = "f2", label = "F2", code = "F2", units = 1 },
    { id = "f3", label = "F3", code = "F3", units = 1 },
    { id = "f4", label = "F4", code = "F4", units = 1 },
    { spacer = 0.5 },
    { id = "f5", label = "F5", code = "F5", units = 1 },
    { id = "f6", label = "F6", code = "F6", units = 1 },
    { id = "f7", label = "F7", code = "F7", units = 1 },
    { id = "f8", label = "F8", code = "F8", units = 1 },
    { spacer = 0.5 },
    { id = "f9", label = "F9", code = "F9", units = 1 },
    { id = "f10", label = "F10", code = "F10", units = 1 },
    { id = "f11", label = "F11", code = "F11", units = 1 },
    { id = "f12", label = "F12", code = "F12", units = 1 },
    { spacer = 0.5 },
    { id = "print_screen", label = "Prt", code = "PrtSc", units = 1 },
    { id = "scroll_lock", label = "Scr", code = "Scroll Lock", units = 1 },
    { id = "pause", label = "Pau", code = "Pause", units = 1 },
    { spacer = 4.5 },
  },

  -- Number row: 21 keys.
  {
    { id = "grave", label = "`", code = "`", units = 1 },
    { id = "digit_1", label = "1", code = "1", units = 1 },
    { id = "digit_2", label = "2", code = "2", units = 1 },
    { id = "digit_3", label = "3", code = "3", units = 1 },
    { id = "digit_4", label = "4", code = "4", units = 1 },
    { id = "digit_5", label = "5", code = "5", units = 1 },
    { id = "digit_6", label = "6", code = "6", units = 1 },
    { id = "digit_7", label = "7", code = "7", units = 1 },
    { id = "digit_8", label = "8", code = "8", units = 1 },
    { id = "digit_9", label = "9", code = "9", units = 1 },
    { id = "digit_0", label = "0", code = "0", units = 1 },
    { id = "minus", label = "-", code = "-", units = 1 },
    { id = "equal", label = "=", code = "=", units = 1 },
    { id = "backspace", label = "Back", code = "Backspace", units = 2 },
    { spacer = 0.5 },
    { id = "insert", label = "Ins", code = "Insert", units = 1 },
    { id = "home", label = "Home", code = "Home", units = 1 },
    { id = "page_up", label = "PgU", code = "PgUp", units = 1 },
    { spacer = 0.5 },
    { id = "num_lock", label = "Num", code = "Num Lock", units = 1 },
    { id = "kp_divide", label = "/", code = "KP_Divide", units = 1 },
    { id = "kp_multiply", label = "*", code = "KP_Multiply", units = 1 },
    { id = "kp_subtract", label = "-", code = "KP_Subtract", units = 1 },
  },

  -- QWERTY row: 21 keys.
  {
    { id = "tab", label = "Tab", code = "Tab", units = 1.5 },
    { id = "key_q", label = "Q", code = "Q", units = 1 },
    { id = "key_w", label = "W", code = "W", units = 1 },
    { id = "key_e", label = "E", code = "E", units = 1 },
    { id = "key_r", label = "R", code = "R", units = 1 },
    { id = "key_t", label = "T", code = "T", units = 1 },
    { id = "key_y", label = "Y", code = "Y", units = 1 },
    { id = "key_u", label = "U", code = "U", units = 1 },
    { id = "key_i", label = "I", code = "I", units = 1 },
    { id = "key_o", label = "O", code = "O", units = 1 },
    { id = "key_p", label = "P", code = "P", units = 1 },
    { id = "bracket_left", label = "[", code = "[", units = 1 },
    { id = "bracket_right", label = "]", code = "]", units = 1 },
    { id = "backslash", label = "\\", code = "\\", units = 1.5 },
    { spacer = 0.5 },
    { id = "delete", label = "Del", code = "Delete", units = 1 },
    { id = "end", label = "End", code = "End", units = 1 },
    { id = "page_down", label = "PgD", code = "PgDn", units = 1 },
    { spacer = 0.5 },
    { id = "kp_7", label = "7", code = "KP_7", units = 1 },
    { id = "kp_8", label = "8", code = "KP_8", units = 1 },
    { id = "kp_9", label = "9", code = "KP_9", units = 1 },
    { id = "kp_add", label = "+", code = "KP_Add", units = 1 },
  },

  -- Home row: 16 keys. The final numpad spacer continues KP Add from above.
  {
    { id = "caps_lock", label = "Caps", code = "Caps Lock", units = 1.75, modifier = true },
    { id = "key_a", label = "A", code = "A", units = 1 },
    { id = "key_s", label = "S", code = "S", units = 1 },
    { id = "key_d", label = "D", code = "D", units = 1 },
    { id = "key_f", label = "F", code = "F", units = 1 },
    { id = "key_g", label = "G", code = "G", units = 1 },
    { id = "key_h", label = "H", code = "H", units = 1 },
    { id = "key_j", label = "J", code = "J", units = 1 },
    { id = "key_k", label = "K", code = "K", units = 1 },
    { id = "key_l", label = "L", code = "L", units = 1 },
    { id = "semicolon", label = ";", code = ";", units = 1 },
    { id = "apostrophe", label = "'", code = "'", units = 1 },
    { id = "enter", label = "Enter", code = "Enter", units = 2.25 },
    { spacer = 4 },
    { id = "kp_4", label = "4", code = "KP_4", units = 1 },
    { id = "kp_5", label = "5", code = "KP_5", units = 1 },
    { id = "kp_6", label = "6", code = "KP_6", units = 1 },
    { id = "kp_add_lower", label = "+", code = "KP_Add", units = 1 },
  },

  -- Shift row: 17 keys.
  {
    { id = "shift_left", label = "Shift", code = "Shift", units = 2.25, modifier = true },
    { id = "key_z", label = "Z", code = "Z", units = 1 },
    { id = "key_x", label = "X", code = "X", units = 1 },
    { id = "key_c", label = "C", code = "C", units = 1 },
    { id = "key_v", label = "V", code = "V", units = 1 },
    { id = "key_b", label = "B", code = "B", units = 1 },
    { id = "key_n", label = "N", code = "N", units = 1 },
    { id = "key_m", label = "M", code = "M", units = 1 },
    { id = "comma", label = ",", code = ",", units = 1 },
    { id = "period", label = ".", code = ".", units = 1 },
    { id = "slash", label = "/", code = "/", units = 1 },
    { id = "shift_right", label = "Shift", code = "Shift", units = 2.75, modifier = true },
    { spacer = 1.5 },
    { id = "arrow_up", label = "↑", code = "Up", units = 1 },
    { spacer = 1 },
    { spacer = 0.5 },
    { id = "kp_1", label = "1", code = "KP_1", units = 1 },
    { id = "kp_2", label = "2", code = "KP_2", units = 1 },
    { id = "kp_3", label = "3", code = "KP_3", units = 1 },
    { id = "kp_enter", label = "Ent", code = "KP_Enter", units = 1 },
  },

  -- Bottom row: 13 keys. The final numpad spacer continues KP Enter from above.
  {
    { id = "ctrl_left", label = "Ctrl", code = "Ctrl", units = 1.25, modifier = true },
    { id = "super_left", label = "Win", code = "Super", units = 1.25, modifier = true },
    { id = "alt_left", label = "Alt", code = "Alt", units = 1.25, modifier = true },
    { id = "space", label = "Space", code = "Space", units = 6.25 },
    { id = "alt_right", label = "Alt", code = "Alt", units = 1.25, modifier = true },
    { id = "super_right", label = "Win", code = "Super", units = 1.25, modifier = true },
    { id = "menu", label = "Menu", code = "Menu", units = 1.25 },
    { id = "ctrl_right", label = "Ctrl", code = "Ctrl", units = 1.25, modifier = true },
    { spacer = 0.5 },
    { id = "arrow_left", label = "←", code = "Left", units = 1 },
    { id = "arrow_down", label = "↓", code = "Down", units = 1 },
    { id = "arrow_right", label = "→", code = "Right", units = 1 },
    { spacer = 0.5 },
    { id = "kp_0", label = "0", code = "KP_0", units = 2 },
    { id = "kp_decimal", label = ".", code = "KP_Decimal", units = 1 },
    { id = "kp_enter_lower", label = "Ent", code = "KP_Enter", units = 1 },
  },
}

local function keyboardRowSlice(source, firstIndex, lastIndex)
  local row = {}
  for index = firstIndex, lastIndex do row[#row + 1] = source[index] end
  return row
end

local function keyboardAppend(row, spec)
  row[#row + 1] = spec
  return row
end

local function keyboardAppendSlice(row, source, firstIndex, lastIndex)
  for index = firstIndex, lastIndex do row[#row + 1] = source[index] end
  return row
end

local function keyboardSizedKey(spec, units)
  return {
    id = spec.id, label = spec.label, code = spec.code, units = units,
    modifier = spec.modifier, bindable = spec.bindable,
  }
end

-- 96% / 1800-compact: the navigation block is folded into the main cluster,
-- while the complete numpad remains directly beside it.
local KEYBOARD_96_FUNCTION = {
  KEYBOARD_100[1][1],
  KEYBOARD_100[1][3], KEYBOARD_100[1][4], KEYBOARD_100[1][5], KEYBOARD_100[1][6],
  KEYBOARD_100[1][8], KEYBOARD_100[1][9], KEYBOARD_100[1][10], KEYBOARD_100[1][11],
  KEYBOARD_100[1][13], KEYBOARD_100[1][14], KEYBOARD_100[1][15], KEYBOARD_100[1][16],
  KEYBOARD_100[3][16], KEYBOARD_100[2][17], KEYBOARD_100[3][17],
  KEYBOARD_100[2][18], KEYBOARD_100[3][18], KEYBOARD_100[1][18],
}
local KEYBOARD_96_SHIFT = keyboardRowSlice(KEYBOARD_100[5], 1, 11)
keyboardAppend(KEYBOARD_96_SHIFT, keyboardSizedKey(KEYBOARD_100[5][12], 1.75))
keyboardAppend(KEYBOARD_96_SHIFT, KEYBOARD_100[5][14])
keyboardAppendSlice(KEYBOARD_96_SHIFT, KEYBOARD_100[5], 17, 20)
local KEYBOARD_96_BOTTOM = {
  KEYBOARD_100[6][1], KEYBOARD_100[6][2], KEYBOARD_100[6][3], KEYBOARD_100[6][4],
  keyboardSizedKey(KEYBOARD_100[6][5], 1),
  keyboardSizedKey(KEYBOARD_100[6][6], 1),
  keyboardSizedKey(KEYBOARD_100[6][8], 1),
  KEYBOARD_100[6][10], KEYBOARD_100[6][11], KEYBOARD_100[6][12],
  keyboardSizedKey(KEYBOARD_100[6][14], 1), KEYBOARD_100[6][15], KEYBOARD_100[6][16],
}
local KEYBOARD_96 = {
  KEYBOARD_96_FUNCTION,
  keyboardAppendSlice(keyboardRowSlice(KEYBOARD_100[2], 1, 14), KEYBOARD_100[2], 20, 23),
  keyboardAppendSlice(keyboardRowSlice(KEYBOARD_100[3], 1, 14), KEYBOARD_100[3], 20, 23),
  keyboardAppendSlice(keyboardRowSlice(KEYBOARD_100[4], 1, 13), KEYBOARD_100[4], 15, 18),
  KEYBOARD_96_SHIFT,
  KEYBOARD_96_BOTTOM,
}

-- 80% / tenkeyless: full function and navigation clusters without a numpad.
local KEYBOARD_80 = {
  keyboardRowSlice(KEYBOARD_100[1], 1, 20),
  keyboardRowSlice(KEYBOARD_100[2], 1, 18),
  keyboardRowSlice(KEYBOARD_100[3], 1, 18),
  keyboardAppend(keyboardRowSlice(KEYBOARD_100[4], 1, 13), { spacer = 3.5 }),
  keyboardRowSlice(KEYBOARD_100[5], 1, 15),
  keyboardRowSlice(KEYBOARD_100[6], 1, 12),
}

local KEYBOARD_COMPACT_BOTTOM = {
  KEYBOARD_100[6][1],
  KEYBOARD_100[6][2],
  KEYBOARD_100[6][3],
  KEYBOARD_100[6][4],
  keyboardSizedKey(KEYBOARD_100[6][5], 1),
  keyboardSizedKey(KEYBOARD_100[6][6], 1),
  { id = "ctrl_right", label = "Ctrl", code = "Ctrl", units = 1, modifier = true },
  KEYBOARD_100[6][10],
  KEYBOARD_100[6][11],
  KEYBOARD_100[6][12],
}

local function compactKeyboardBody()
  local shiftRow = keyboardRowSlice(KEYBOARD_100[5], 1, 11)
  keyboardAppend(shiftRow, keyboardSizedKey(KEYBOARD_100[5][12], 1.75))
  keyboardAppend(shiftRow, KEYBOARD_100[5][14])
  keyboardAppend(shiftRow, KEYBOARD_100[3][17])
  return {
    keyboardAppend(keyboardRowSlice(KEYBOARD_100[2], 1, 14), KEYBOARD_100[2][17]),
    keyboardAppend(keyboardRowSlice(KEYBOARD_100[3], 1, 14), KEYBOARD_100[2][18]),
    keyboardAppend(keyboardRowSlice(KEYBOARD_100[4], 1, 13), KEYBOARD_100[3][18]),
    shiftRow,
    keyboardRowSlice(KEYBOARD_COMPACT_BOTTOM, 1, #KEYBOARD_COMPACT_BOTTOM),
  }
end

-- 75%: compact navigation and arrows plus a dedicated function row.
local KEYBOARD_75_FUNCTION = {
  KEYBOARD_100[1][1],
  KEYBOARD_100[1][3], KEYBOARD_100[1][4], KEYBOARD_100[1][5], KEYBOARD_100[1][6],
  KEYBOARD_100[1][8], KEYBOARD_100[1][9], KEYBOARD_100[1][10], KEYBOARD_100[1][11],
  KEYBOARD_100[1][13], KEYBOARD_100[1][14], KEYBOARD_100[1][15], KEYBOARD_100[1][16],
  KEYBOARD_100[1][18], KEYBOARD_100[1][20], KEYBOARD_100[3][16],
}
local KEYBOARD_75 = { KEYBOARD_75_FUNCTION }
for _, row in ipairs(compactKeyboardBody()) do KEYBOARD_75[#KEYBOARD_75 + 1] = row end

-- 65%: the same compact navigation column and arrows, without function keys.
local KEYBOARD_65_NUMBER = { KEYBOARD_100[1][1] }
keyboardAppendSlice(KEYBOARD_65_NUMBER, KEYBOARD_100[2], 2, 14)
keyboardAppend(KEYBOARD_65_NUMBER, KEYBOARD_100[2][17])
local KEYBOARD_65 = compactKeyboardBody()
KEYBOARD_65[1] = KEYBOARD_65_NUMBER
KEYBOARD_65[5] = {
  KEYBOARD_100[6][1], KEYBOARD_100[6][2], KEYBOARD_100[6][3], KEYBOARD_100[6][4],
  keyboardSizedKey(KEYBOARD_100[6][5], 1),
  { id = "fn", label = "Fn", units = 1, bindable = false },
  { id = "ctrl_right", label = "Ctrl", code = "Ctrl", units = 1, modifier = true },
  KEYBOARD_100[6][10], KEYBOARD_100[6][11], KEYBOARD_100[6][12],
}

-- 60%: the ANSI alphanumeric block only.
local KEYBOARD_60 = {
  keyboardRowSlice(KEYBOARD_100[2], 1, 14),
  keyboardRowSlice(KEYBOARD_100[3], 1, 14),
  keyboardRowSlice(KEYBOARD_100[4], 1, 13),
  keyboardRowSlice(KEYBOARD_100[5], 1, 12),
  keyboardRowSlice(KEYBOARD_100[6], 1, 8),
}

local KEYBOARD_LAYOUT_ORDER = { "100", "96", "80", "75", "65", "60" }
local KEYBOARD_LAYOUTS = {
  ["100"] = { id = "100", rows = KEYBOARD_100, rowUnits = 23, labelKey = "p100",
    features = { functionRow = true, numpad = true, navCluster = true, arrows = true } },
  ["96"] = { id = "96", rows = KEYBOARD_96, rowUnits = 19, labelKey = "p96",
    features = { functionRow = true, numpad = true, navCluster = false, arrows = true } },
  ["80"] = { id = "80", rows = KEYBOARD_80, rowUnits = 18.5, labelKey = "p80",
    features = { functionRow = true, numpad = false, navCluster = true, arrows = true } },
  ["75"] = { id = "75", rows = KEYBOARD_75, rowUnits = 16, labelKey = "p75",
    features = { functionRow = true, numpad = false, navCluster = false, arrows = true } },
  ["65"] = { id = "65", rows = KEYBOARD_65, rowUnits = 16, labelKey = "p65",
    features = { functionRow = false, numpad = false, navCluster = false, arrows = true } },
  ["60"] = { id = "60", rows = KEYBOARD_60, rowUnits = 15, labelKey = "p60",
    features = { functionRow = false, numpad = false, navCluster = false, arrows = false } },
}
-- END KEYBOARD LAYOUT DATA

-- One unit plus one gap is 48 px, divisible by four. Quarter-unit keys can
-- therefore be positioned without fractional rounding drift.
local KEYBOARD_UNIT = 44
local KEYBOARD_GAP = 4
local KEYBOARD_KEY_HEIGHT = 42
local KEYBOARD_CODE_SET = {}
local KEYBOARD_LABELS = {}
for _, layoutId in ipairs(KEYBOARD_LAYOUT_ORDER) do
  local layout = KEYBOARD_LAYOUTS[layoutId]
  layout.codeSet = {}
  for _, keyboardRow in ipairs(layout.rows) do
    for _, keySpec in ipairs(keyboardRow) do
      if keySpec.bindable ~= false and keySpec.code ~= nil then
        local code = canonicalKey(keySpec.code)
        KEYBOARD_CODE_SET[code] = true
        layout.codeSet[code] = true
        KEYBOARD_LABELS[code] = asString(keySpec.label, keySpec.code)
      end
    end
  end
end

local function activeKeyboardLayoutId()
  local layoutId = keyboardLayoutId ~= "" and keyboardLayoutId or asString(cfg("keyboard_layout"), "100")
  if KEYBOARD_LAYOUTS[layoutId] == nil then return "100" end
  return layoutId
end

local function activeKeyboardLayout()
  return KEYBOARD_LAYOUTS[activeKeyboardLayoutId()]
end

local function keyboardLayoutSelectedIndex()
  local activeId = activeKeyboardLayoutId()
  for index, layoutId in ipairs(KEYBOARD_LAYOUT_ORDER) do
    if layoutId == activeId then return index - 1 end
  end
  return 0
end

local function keyboardLayoutOptions()
  local options = {}
  for _, layoutId in ipairs(KEYBOARD_LAYOUT_ORDER) do
    options[#options + 1] = tr("panel.keyboard.layouts." .. KEYBOARD_LAYOUTS[layoutId].labelKey)
  end
  return options
end

-- Config files use XKB names, while the visual keyboard uses compact labels.
-- These names are accepted by Hyprland Lua, Niri KDL, and MangoWC.
local CONFIG_KEY_NAMES = {
  esc = "Escape", prtsc = "Print", scrolllock = "Scroll_Lock", pause = "Pause",
  grave = "grave", minus = "minus", equal = "equal", backspace = "BackSpace",
  tab = "Tab", bracketleft = "bracketleft", bracketright = "bracketright",
  backslash = "backslash", caps_lock = "Caps_Lock", semicolon = "semicolon",
  apostrophe = "apostrophe", enter = "Return", comma = "comma", period = "period",
  slash = "slash", space = "space", menu = "Menu",
  insert = "Insert", home = "Home", pgup = "Prior", delete = "Delete", ["end"] = "End",
  pgdn = "Next", left = "Left", right = "Right", up = "Up", down = "Down",
  numlock = "Num_Lock", numdivide = "KP_Divide", nummultiply = "KP_Multiply",
  numminus = "KP_Subtract", numplus = "KP_Add", numenter = "KP_Enter",
  numdecimal = "KP_Decimal",
  num0 = "KP_0", num1 = "KP_1", num2 = "KP_2", num3 = "KP_3", num4 = "KP_4",
  num5 = "KP_5", num6 = "KP_6", num7 = "KP_7", num8 = "KP_8", num9 = "KP_9",
}

local function creatorHasKey(code)
  for _, selectedCode in ipairs(creatorKeys) do
    if selectedCode == code then
      return true
    end
  end
  return false
end

local function configKeyName(code)
  local mapped = CONFIG_KEY_NAMES[code]
  if mapped ~= nil then
    return mapped
  end
  if code:match("^[a-z]$") then
    return string.upper(code)
  end
  if code:match("^f%d%d?$") then
    return string.upper(code)
  end
  return code
end

-- A multi-unit key replaces the gaps that would exist between unit-sized
-- keys. Using the same pitch for keys and spacers keeps every 23-unit row at
-- exactly the same physical width, regardless of its number of children.
local function keyboardUnitsWidth(units)
  local value = tonumber(units) or 1
  return math.max(1, math.floor(value * KEYBOARD_UNIT + (value - 1) * KEYBOARD_GAP + 0.5))
end

local function colorWithOpacity(value, fallback, opacity)
  local color = asString(value, fallback)
  if string.sub(color, 1, 1) == "#" then
    local alpha = string.format("%02X", math.floor(math.max(0, math.min(1, opacity)) * 255 + 0.5))
    if #color == 7 then
      return color .. alpha
    elseif #color == 9 then
      return string.sub(color, 1, 7) .. alpha
    end
    return color
  end
  return color .. "/" .. string.format("%.2f", opacity)
end

local function keyboardKeyNode(spec, index)
  if spec.spacer ~= nil then
    -- `ui.spacer` is flexible: inside a fixed-width row it absorbs remaining
    -- space and moves every key that follows it. Keyboard gaps must be rigid,
    -- otherwise the function/navigation blocks and the inverted-T arrows no
    -- longer share the same unit grid.
    return ui.spacer({ width = keyboardUnitsWidth(spec.spacer), flexGrow = 0 })
  end

  if spec.bindable == false or spec.code == nil then
    local width = keyboardUnitsWidth(spec.units or 1)
    return ui.row({
      key = "keyboard-" .. spec.id,
      width = width,
      height = KEYBOARD_KEY_HEIGHT,
      fill = colorWithOpacity(cfg("key_color"), "surface_variant", 0.28),
      border = "outline",
      borderWidth = 1,
      radius = 7,
      align = "center",
      justify = "center",
    }, {
      ui.label({
        text = asString(spec.label, ""), color = "on_surface_variant",
        fontSize = 8, textAlign = "center", maxLines = 1,
      }),
    })
  end

  local code = canonicalKey(spec.code)
  local signature = activeModifierSignature()
  local exactEntries = asArray(index.exact[signature .. "|" .. code])
  local anyEntries = asArray(index.any[code])
  local physicalModifier = MODIFIER_ALIASES[normalized(spec.code)]
  local modifierActive = physicalModifier ~= nil and activeModifiers[physicalModifier] == true
  local selected = creatorOpen and creatorHasKey(code) or selectedKeyboardKey == code

  local fill
  local border
  local borderWidth = 1
  if modifierActive then
    local modifierFill = modifierStyle(physicalModifier)
    fill = asString(modifierFill, "primary")
    border = asString(modifierFill, "primary")
    borderWidth = 2
  elseif selected then
    fill = colorWithOpacity("secondary", "secondary", 0.24)
    border = "secondary"
    borderWidth = 3
  elseif #exactEntries > 0 then
    fill = colorWithOpacity(cfg("category_color"), "primary", 0.30)
    border = asString(cfg("category_color"), "primary")
    borderWidth = 2
  elseif #anyEntries > 0 then
    fill = colorWithOpacity(cfg("category_color"), "primary", 0.10)
    border = asString(cfg("category_color"), "primary")
  else
    fill = colorWithOpacity(cfg("key_color"), "surface_variant", 0.42)
    border = "outline"
  end

  local displayText = asString(spec.label, "?")
  if #exactEntries > 0 then
    displayText = displayText .. "\n" .. tostring(#exactEntries)
  elseif #anyEntries > 0 then
    displayText = displayText .. "\n•"
  end

  local width = keyboardUnitsWidth(spec.units or 1)
  return ui.row({
    key = "keyboard-" .. spec.id,
    width = width,
    height = KEYBOARD_KEY_HEIGHT,
    fill = fill,
    border = border,
    borderWidth = borderWidth,
    radius = 7,
    paddingH = 4,
    paddingV = 3,
    align = "center",
    justify = "center",
  }, {
    ui.button({
      text = displayText,
      width = math.max(18, width - 6),
      height = KEYBOARD_KEY_HEIGHT - 6,
      fontSize = #asString(spec.label) > 4 and 7 or 8,
      variant = "ghost",
      selected = selected or modifierActive,
      contentAlign = "center",
      controlSize = "sm",
      tooltip = #exactEntries > 0 and tr("panel.keyboard.occupied") or (
        #anyEntries > 0 and tr("panel.keyboard.other_layer") or tr("panel.keyboard.free")
      ),
      onClick = keyCallback(spec.id, spec.code),
    }),
  })
end

local function keyboardLegendItem(fill, border, label)
  return ui.row({ gap = 5, align = "center" }, {
    ui.box({ width = 12, height = 12, radius = 3, fill = fill, border = border, borderWidth = 1 }),
    ui.label({ text = label, color = "on_surface_variant", fontSize = 10, maxLines = 1 }),
  })
end

local function keyboardLayerToolbar()
  local buttons = {
    ui.label({ text = tr("panel.keyboard.layer"), color = "on_surface_variant", fontSize = 11 }),
  }
  local callbacks = {
    SUPER = "onToggleSuper", CTRL = "onToggleCtrl", SHIFT = "onToggleShift", ALT = "onToggleAlt",
  }
  local labels = {
    SUPER = "Super", CTRL = "Ctrl", SHIFT = "Shift", ALT = "Alt",
  }
  for _, modifier in ipairs(MODIFIER_ORDER) do
    buttons[#buttons + 1] = ui.button({
      text = labels[modifier],
      selected = activeModifiers[modifier],
      variant = activeModifiers[modifier] and "primary" or "ghost",
      controlSize = "sm",
      onClick = callbacks[modifier],
    })
  end
  buttons[#buttons + 1] = ui.button({
    glyph = "restore",
    variant = "ghost",
    controlSize = "sm",
    tooltip = tr("panel.keyboard.clear_modifiers"),
    onClick = "onClearModifiers",
  })
  buttons[#buttons + 1] = ui.spacer({ flexGrow = 1 })
  buttons[#buttons + 1] = keyboardLegendItem(
    colorWithOpacity(cfg("key_color"), "surface_variant", 0.42), "outline", tr("panel.keyboard.free")
  )
  buttons[#buttons + 1] = keyboardLegendItem(
    colorWithOpacity(cfg("category_color"), "primary", 0.30),
    asString(cfg("category_color"), "primary"),
    tr("panel.keyboard.occupied")
  )
  buttons[#buttons + 1] = keyboardLegendItem(
    colorWithOpacity(cfg("category_color"), "primary", 0.10),
    asString(cfg("category_color"), "primary"),
    tr("panel.keyboard.other_layer")
  )
  return ui.row({ gap = 8, align = "center" }, buttons)
end

local function selectedKeyDetails(index)
  if selectedKeyboardKey == nil then
    return ui.row({
      minHeight = 62,
      paddingH = 12,
      paddingV = 9,
      radius = 10,
      fill = colorWithOpacity(cfg("card_color"), "surface_variant", 0.25),
      border = "outline",
      borderWidth = 1,
      align = "center",
      justify = "center",
    }, {
      ui.label({
        text = tr("panel.keyboard.select_hint"),
        color = "on_surface_variant",
        fontSize = 11,
        textAlign = "center",
        maxLines = 2,
      }),
    })
  end

  local signature = activeModifierSignature()
  local entries = asArray(index.exact[signature .. "|" .. selectedKeyboardKey])
  local chordParts = {}
  for _, modifier in ipairs(MODIFIER_ORDER) do
    if activeModifiers[modifier] then
      chordParts[#chordParts + 1] = modifier == "CTRL" and "Ctrl" or (
        modifier == "SUPER" and "Super" or (modifier == "SHIFT" and "Shift" or "Alt")
      )
    end
  end
  chordParts[#chordParts + 1] = KEYBOARD_LABELS[selectedKeyboardKey] or selectedKeyboardKey
  local chord = table.concat(chordParts, " + ")
  local children = {
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = chord, color = "on_surface", fontSize = 13, fontWeight = "bold", flexGrow = 1 }),
      ui.label({
        text = #entries > 0 and tr("panel.keyboard.occupied") or tr("panel.keyboard.free"),
        color = #entries > 0 and asString(cfg("category_color"), "primary") or "on_surface_variant",
        fontSize = 11,
        fontWeight = "bold",
      }),
    }),
  }
  if #entries == 0 then
    children[#children + 1] = ui.label({
      text = tr("panel.keyboard.free_hint"),
      color = "on_surface_variant",
      fontSize = 11,
      maxLines = 2,
    })
  else
    for entryIndex, entry in ipairs(entries) do
      if entryIndex > 5 then
        children[#children + 1] = ui.label({
          text = tr("panel.keyboard.more_actions", { count = #entries - 5 }),
          color = "on_surface_variant",
          fontSize = 10,
        })
        break
      end
      local bind = entry.bind
      local meta = entry.category
      local mode = asString(bind.mode)
      if mode ~= "" and normalized(mode) ~= "default" then
        meta = meta .. " · " .. mode
      end
      children[#children + 1] = ui.row({
        key = "keyboard-detail-" .. asString(bind.id, tostring(entryIndex)),
        gap = 8,
        paddingH = 8,
        paddingV = 4,
        radius = 7,
        fill = "surface/0.45",
        align = "center",
      }, {
        ui.label({
          text = asString(bind.description, tr("panel.no_description")),
          color = asString(cfg("description_color"), "on_surface"),
          fontSize = 11,
          flexGrow = 1,
          maxLines = 2,
        }),
        ui.label({ text = meta, color = "on_surface_variant", fontSize = 9, maxLines = 1 }),
      })
    end
  end
  return ui.column({
    paddingH = 12,
    paddingV = 9,
    gap = 5,
    radius = 10,
    fill = colorWithOpacity(cfg("card_color"), "surface_variant", 0.25),
    border = "outline",
    borderWidth = 1,
  }, children)
end

local function creatorCategoryNames()
  if creatorOpen and #creatorCategoryNamesFrozen > 0 then
    return creatorCategoryNamesFrozen
  end
  local names = {}
  local seen = {}
  for _, category in ipairs(asArray(snapshot.categories)) do
    local name = noctalia.string.trim(asString(category.name))
    if name ~= "" and not seen[name] then
      seen[name] = true
      names[#names + 1] = name
    end
  end
  return names
end

local function creatorCategory()
  local names = creatorCategoryNames()
  if creatorCategoryIndex >= #names then
    return noctalia.string.trim(creatorNewCategory)
  end
  return names[creatorCategoryIndex + 1] or ""
end

local function creatorChord()
  local parts = {}
  for _, modifier in ipairs(MODIFIER_ORDER) do
    if activeModifiers[modifier] then
      parts[#parts + 1] = modifier == "SUPER" and "Super" or (
        modifier == "CTRL" and "Ctrl" or (modifier == "SHIFT" and "Shift" or "Alt")
      )
    end
  end
  for _, code in ipairs(creatorKeys) do
    parts[#parts + 1] = KEYBOARD_LABELS[code] or configKeyName(code)
  end
  return table.concat(parts, " + ")
end

local function creatorKeysDisplay()
  local labels = {}
  for _, code in ipairs(creatorKeys) do
    labels[#labels + 1] = KEYBOARD_LABELS[code] or configKeyName(code)
  end
  return table.concat(labels, ", ")
end

local function creatorConflict(index)
  local signature = activeModifierSignature()
  for _, category in ipairs(asArray(snapshot.categories)) do
    for _, bind in ipairs(asArray(category.binds)) do
      if not (formMode == "edit" and asString(bind.id) == editingBindId)
        and modifierSignature(bind.modifiers) == signature
        and asString(bind.activation, "press") == creatorActivation then
        local rawKeys = type(bind.keys) == "table" and bind.keys or expandedKeys(bind.key)
        if #rawKeys == #creatorKeys then
          local matches = true
          for index, rawKey in ipairs(rawKeys) do
            if canonicalKey(rawKey) ~= creatorKeys[index] then matches = false break end
          end
          if matches then
            return { bind = bind, category = asString(category.name, tr("panel.uncategorized")) }
          end
        end
      end
    end
  end
  return nil
end

local function creatorErrorText()
  if creatorError == "" then
    return ""
  end
  local key = "panel.creator.errors." .. creatorError
  local translated = tr(key)
  return translated ~= key and translated or creatorError
end

local function creatorCanSave(index)
  local compositor = normalized(snapshot.compositor)
  if snapshot.status ~= "ready" or snapshot.compositor ~= creatorContextCompositor
    or snapshot.source ~= creatorContextSource or creatorBusy or #creatorKeys == 0
    or (editingCapabilities.command ~= false and noctalia.string.trim(creatorCommand) == "")
    or creatorCommand:find("{{", 1, true) ~= nil
    or noctalia.string.trim(creatorDescription) == "" or creatorCategory() == "" then
    return false
  end
  if compositor ~= "hyprland" and #creatorKeys ~= 1 then
    return false
  end
  if compositor == "niri" and creatorActivation == "release" then
    return false
  end
  return creatorConflict(index) == nil
end

local function commandLibraryCompositorSource()
  local compositor = normalized(snapshot.compositor)
  if compositor == "hyprland" or compositor == "niri" or compositor == "mangowc" then
    return compositor
  end
  return ""
end

local function commandLibrarySourceLabel(source)
  local key = "panel.command_library.sources." .. source
  local translated = tr(key)
  return translated ~= key and translated or source
end

local function commandLibraryCategoryLabel(category)
  local key = "panel.command_library.categories." .. category
  local translated = tr(key)
  return translated ~= key and translated or category
end

local function commandLibrarySourceIds()
  local result = { "", "noctalia" }
  local compositorSource = commandLibraryCompositorSource()
  if formMode ~= "edit" and compositorSource ~= "" then result[#result + 1] = compositorSource end
  return result
end

local function commandLibraryEntryAllowed(entry)
  if type(entry) ~= "table" then return false end
  if entry.source == "noctalia" then return entry.kind == "shell" end
  return formMode ~= "edit" and entry.kind == "native"
    and entry.source == commandLibraryCompositorSource()
end

local function commandLibraryCategoryIds()
  local sourceIds = commandLibrarySourceIds()
  local selectedSource = sourceIds[commandLibrarySourceIndex + 1] or ""
  local seen = {}
  for _, entry in ipairs(asArray(COMMAND_LIBRARY.entries)) do
    if commandLibraryEntryAllowed(entry) and type(entry.category) == "string"
      and (selectedSource == "" or entry.source == selectedSource) then
      seen[entry.category] = true
    end
  end
  local result = {}
  for category, _ in pairs(seen) do result[#result + 1] = category end
  table.sort(result, function(left, right)
    return commandLibraryCategoryLabel(left):lower() < commandLibraryCategoryLabel(right):lower()
  end)
  return result
end

local function commandLibraryFilteredEntries()
  local sourceIds = commandLibrarySourceIds()
  local selectedSource = sourceIds[commandLibrarySourceIndex + 1] or ""
  local categoryIds = commandLibraryCategoryIds()
  local selectedCategory = categoryIds[commandLibraryCategoryIndex] or ""
  local query = normalized(commandLibraryQuery)
  local result = {}
  for _, entry in ipairs(asArray(COMMAND_LIBRARY.entries)) do
    if commandLibraryEntryAllowed(entry)
      and (selectedSource == "" or entry.source == selectedSource)
      and (selectedCategory == "" or entry.category == selectedCategory) then
      local needsInput = asString(entry.template):find("{{", 1, true) ~= nil
      local readinessMatches = commandLibraryReadinessIndex == 0
        or (commandLibraryReadinessIndex == 1 and not needsInput)
        or (commandLibraryReadinessIndex == 2 and needsInput)
      local haystack = normalized(table.concat({
        asString(entry.id), asString(entry.template), asString(entry.usage),
        commandLibrarySourceLabel(asString(entry.source)),
        commandLibraryCategoryLabel(asString(entry.category)),
      }, " "))
      if readinessMatches and (query == "" or haystack:find(query, 1, true) ~= nil) then
        result[#result + 1] = entry
      end
    end
  end
  return result
end

local function commandLibraryNode()
  if not commandLibraryOpen then return ui.row({ visible = false }, {}) end
  local sourceIds = commandLibrarySourceIds()
  if commandLibrarySourceIndex >= #sourceIds then commandLibrarySourceIndex = 0 end
  local sourceOptions = { tr("panel.command_library.all_sources") }
  for index = 2, #sourceIds do
    sourceOptions[#sourceOptions + 1] = commandLibrarySourceLabel(sourceIds[index])
  end
  local categoryIds = commandLibraryCategoryIds()
  if commandLibraryCategoryIndex > #categoryIds then commandLibraryCategoryIndex = 0 end
  local categoryOptions = { tr("panel.command_library.all_categories") }
  for _, category in ipairs(categoryIds) do
    categoryOptions[#categoryOptions + 1] = commandLibraryCategoryLabel(category)
  end
  local matches = commandLibraryFilteredEntries()
  local resultNodes = {}
  local visibleCount = math.min(#matches, 6)
  for index = 1, visibleCount do
    local entry = matches[index]
    local callbackName = "onCommandLibraryUse:" .. asString(entry.id)
    registerDynamicCallback(callbackName, function()
      creatorCommand = asString(entry.template)
      creatorCommandKind = asString(entry.kind, "shell")
      creatorLibraryEntryId = asString(entry.id)
      commandLibraryOpen = false
      creatorError = ""
      creatorRevision += 1
      render()
    end)
    resultNodes[#resultNodes + 1] = ui.row({ gap = 6, align = "center" }, {
      ui.glyph({
        name = entry.kind == "native" and "binary-tree" or "terminal-2",
        size = 15, color = entry.kind == "native" and "primary" or "on_surface_variant",
      }),
      ui.column({ gap = 1, flexGrow = 1 }, {
        ui.label({ text = asString(entry.usage, asString(entry.id)), fontSize = 10, maxLines = 1 }),
        ui.label({
          text = commandLibrarySourceLabel(asString(entry.source)) .. " · "
            .. commandLibraryCategoryLabel(asString(entry.category)),
          color = "on_surface_variant", fontSize = 9, maxLines = 1,
        }),
      }),
      asString(entry.template):find("{{", 1, true) ~= nil and ui.label({
        text = tr("panel.command_library.requires_input"), color = "tertiary", fontSize = 9,
      }) or ui.label({ text = tr("panel.command_library.ready"), color = "secondary", fontSize = 9 }),
      ui.button({
        text = tr("panel.command_library.use"), variant = "ghost", controlSize = "sm",
        onClick = callbackName,
      }),
    })
  end
  if #resultNodes == 0 then
    resultNodes[1] = ui.label({
      text = tr("panel.command_library.no_results"), color = "on_surface_variant", fontSize = 10,
    })
  end
  return ui.column({
    gap = 6, paddingH = 8, paddingV = 8, radius = 8,
    fill = colorWithOpacity(cfg("card_color"), "surface", 0.35),
    border = "outline", borderWidth = 1,
  }, {
    ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "books", size = 16, color = "primary" }),
      ui.label({ text = tr("panel.command_library.title"), fontSize = 11, fontWeight = "bold", flexGrow = 1 }),
      ui.button({
        text = tr("panel.command_library.custom_command"), variant = "ghost", controlSize = "sm",
        onClick = "onCommandLibraryUseCustom",
      }),
    }),
    ui.input({
      key = "command-library-search-" .. tostring(commandLibraryRevision),
      value = commandLibraryQuery, placeholder = tr("panel.command_library.search_placeholder"),
      controlSize = "sm", onChange = "onCommandLibraryQueryChanged",
    }),
    ui.row({ gap = 6, align = "center" }, {
      ui.select({
        options = sourceOptions, selectedIndex = commandLibrarySourceIndex,
        flexGrow = 1, controlSize = "sm", onChange = "onCommandLibrarySourceChanged",
      }),
      ui.select({
        options = categoryOptions, selectedIndex = commandLibraryCategoryIndex,
        flexGrow = 1, controlSize = "sm", onChange = "onCommandLibraryCategoryChanged",
      }),
      ui.select({
        options = {
          tr("panel.command_library.all_readiness"), tr("panel.command_library.ready"),
          tr("panel.command_library.requires_input"),
        },
        selectedIndex = commandLibraryReadinessIndex, flexGrow = 1, controlSize = "sm",
        onChange = "onCommandLibraryReadinessChanged",
      }),
    }),
    ui.label({
      text = tr("panel.command_library.showing", { shown = visibleCount, total = #matches }),
      color = "on_surface_variant", fontSize = 9,
    }),
    ui.column({ gap = 3 }, resultNodes),
  })
end

local function creatorForm(index)
  local names = creatorCategoryNames()
  local options = {}
  for _, name in ipairs(names) do
    options[#options + 1] = name
  end
  options[#options + 1] = tr("panel.creator.new_category")
  if creatorCategoryIndex > #names then
    creatorCategoryIndex = #names
  end
  local isEditing = formMode == "edit"
  local showManualCombination = isEditing or viewMode == "list"
  local usesNewCategory = creatorCategoryIndex >= #names
  local compositor = normalized(snapshot.compositor)
  local releaseSupported = compositor ~= "niri" and (not isEditing or editingCapabilities.activation == true)
  local conflict = creatorConflict(index)
  local chord = creatorChord()
  local statusText = creatorErrorText()
  if conflict ~= nil and statusText == "" then
    statusText = tr("panel.creator.errors.conflict", {
      description = asString(conflict.bind.description, tr("panel.no_description")),
    })
  end

  local hintKey = isEditing and "panel.editor.hint" or (viewMode == "list" and "panel.creator.list_hint" or (
    compositor == "hyprland" and "panel.creator.hyprland_hint" or (
    compositor == "niri" and "panel.creator.niri_hint" or "panel.creator.mangowc_hint"
  )))

  local categoryControl = ui.select({
    key = "creator-category-" .. tostring(creatorRevision), options = options,
    selectedIndex = creatorCategoryIndex, width = 250, controlSize = "sm",
    onChange = "onCreatorCategoryChanged",
  })

  return ui.column({
    paddingH = 12,
    paddingV = 10,
    gap = 8,
    radius = 10,
    fill = colorWithOpacity(cfg("card_color"), "surface_variant", 0.25),
    border = "primary",
    borderWidth = 1,
  }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = isEditing and "pencil" or "pencil-plus", size = 18, color = "primary" }),
      ui.label({
        text = tr(isEditing and "panel.editor.title" or "panel.creator.title"),
        fontSize = 13, fontWeight = "bold", flexGrow = 1,
      }),
      ui.label({
        text = chord ~= "" and chord or tr("panel.creator.no_combination"),
        color = chord ~= "" and "primary" or "on_surface_variant",
        fontSize = 11,
        fontWeight = "bold",
        maxLines = 1,
      }),
    }),
    ui.label({ text = tr(hintKey), color = "on_surface_variant", fontSize = 10, maxLines = 2 }),
    showManualCombination and ui.row({ gap = 6, align = "center" }, {
      ui.label({ text = tr("panel.editor.combination"), color = "on_surface_variant", fontSize = 11 }),
      ui.button({
        text = "Super", selected = activeModifiers.SUPER,
        variant = activeModifiers.SUPER and "primary" or "ghost", controlSize = "sm",
        onClick = "onToggleSuper",
      }),
      ui.button({
        text = "Ctrl", selected = activeModifiers.CTRL,
        variant = activeModifiers.CTRL and "primary" or "ghost", controlSize = "sm",
        onClick = "onToggleCtrl",
      }),
      ui.button({
        text = "Shift", selected = activeModifiers.SHIFT,
        variant = activeModifiers.SHIFT and "primary" or "ghost", controlSize = "sm",
        onClick = "onToggleShift",
      }),
      ui.button({
        text = "Alt", selected = activeModifiers.ALT,
        variant = activeModifiers.ALT and "primary" or "ghost", controlSize = "sm",
        onClick = "onToggleAlt",
      }),
      ui.input({
        key = "editor-keys-" .. tostring(creatorRevision), value = creatorKeysText,
        placeholder = tr("panel.editor.keys_placeholder"), flexGrow = 1, controlSize = "sm",
        onChange = "onEditorKeysChanged",
      }),
    }) or ui.row({ visible = false }, {}),
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = tr("panel.creator.trigger"), color = "on_surface_variant", fontSize = 11 }),
      ui.button({
        text = tr("panel.creator.press"), selected = creatorActivation == "press",
        variant = creatorActivation == "press" and "primary" or "ghost", controlSize = "sm",
        onClick = "onCreatorPress",
      }),
      ui.button({
        text = tr("panel.creator.release"), selected = creatorActivation == "release",
        variant = creatorActivation == "release" and "primary" or "ghost", controlSize = "sm",
        enabled = releaseSupported, tooltip = releaseSupported and "" or tr("panel.creator.release_unavailable"),
        onClick = "onCreatorRelease",
      }),
      ui.spacer({ flexGrow = 1 }),
      ui.label({ text = tr("panel.creator.category"), color = "on_surface_variant", fontSize = 11 }),
      categoryControl,
      ui.input({
        key = "creator-new-category-" .. tostring(creatorRevision), value = creatorNewCategory,
        placeholder = tr("panel.creator.category_placeholder"), width = 220, controlSize = "sm",
        visible = usesNewCategory, onChange = "onCreatorNewCategoryChanged",
      }),
    }),
    ui.row({ gap = 8, align = "center" }, {
      ui.input({
        key = "creator-description-" .. tostring(creatorRevision), value = creatorDescription,
        placeholder = tr("panel.creator.description_placeholder"), flexGrow = 1, controlSize = "sm",
        onChange = "onCreatorDescriptionChanged",
      }),
      ui.input({
        key = "creator-command-" .. tostring(creatorRevision),
        value = isEditing and editingCapabilities.command ~= true and editingAction or creatorCommand,
        placeholder = isEditing and editingCapabilities.command ~= true
          and tr("panel.editor.action_placeholder") or tr("panel.creator.command_placeholder"),
        flexGrow = 2, controlSize = "sm",
        enabled = not isEditing or editingCapabilities.command == true,
        onChange = "onCreatorCommandChanged",
      }),
      ui.button({
        text = tr("panel.command_library.open"), glyph = "books",
        variant = commandLibraryOpen and "primary" or "ghost", controlSize = "sm",
        enabled = not isEditing or editingCapabilities.command == true,
        tooltip = tr("panel.command_library.open_hint"),
        onClick = "onCommandLibraryToggle",
      }),
    }),
    (not isEditing or editingCapabilities.command == true) and ui.row({ gap = 6, align = "center" }, {
      ui.label({
        text = tr(creatorCommandKind == "native"
          and "panel.command_library.native_action" or "panel.command_library.custom_command"),
        color = creatorCommandKind == "native" and "primary" or "on_surface_variant", fontSize = 9,
      }),
      creatorCommand:find("{{", 1, true) ~= nil and ui.label({
        text = tr("panel.command_library.placeholder_hint"), color = "tertiary", fontSize = 9,
        maxLines = 2, flexGrow = 1,
      }) or ui.spacer({ flexGrow = 1 }),
    }) or ui.row({ visible = false }, {}),
    commandLibraryNode(),
    ui.row({ gap = 8, align = "center" }, {
      ui.label({
        text = statusText,
        color = (conflict ~= nil or creatorError ~= "") and "error" or "on_surface_variant",
        fontSize = 10, maxLines = 2, flexGrow = 1,
      }),
      ui.button({ text = tr("panel.creator.cancel"), variant = "ghost", controlSize = "sm", onClick = "onCreatorCancel" }),
      ui.button({
        text = creatorBusy and tr("panel.creator.saving")
          or tr(isEditing and "panel.editor.save" or "panel.creator.save"),
        glyph = "device-floppy", variant = "primary", controlSize = "sm",
        enabled = creatorCanSave(index), onClick = "onCreatorSave",
      }),
    }),
  })
end

local function keyboardBody()
  local index = keyboardIndex()
  local layout = activeKeyboardLayout()
  local signature = activeModifierSignature()
  local occupied = 0
  for code, _ in pairs(layout.codeSet) do
    if #asArray(index.exact[signature .. "|" .. code]) > 0 then
      occupied = occupied + 1
    end
  end

  local unmapped = 0
  for key, entries in pairs(index.any) do
    if not layout.codeSet[key] then
      unmapped = unmapped + #entries
    end
  end

  local keyboardRows = {}
  for rowIndex, row in ipairs(layout.rows) do
    local keys = {}
    for _, spec in ipairs(row) do
      keys[#keys + 1] = keyboardKeyNode(spec, index)
    end
    keyboardRows[#keyboardRows + 1] = ui.row({
      key = "keyboard-row-" .. layout.id .. "-" .. tostring(rowIndex),
      width = keyboardUnitsWidth(layout.rowUnits),
      gap = KEYBOARD_GAP,
      align = "center",
      justify = "start",
    }, keys)
  end

  local layer = signature ~= "" and signature:gsub("%+", " + ") or tr("panel.keyboard.no_modifiers")
  local summary = tr("panel.keyboard.summary", { layer = layer, count = occupied })
  if unmapped > 0 then
    summary = summary .. " · " .. tr("panel.keyboard.outside", { count = unmapped })
  end

  return ui.scroll({ flexGrow = 1 }, {
    ui.column({ gap = 9, align = "stretch" }, {
      keyboardLayerToolbar(),
      ui.label({ text = summary, color = "on_surface_variant", fontSize = 10, textAlign = "center" }),
      ui.column({
        gap = KEYBOARD_GAP,
        padding = 10,
        radius = 13,
        fill = colorWithOpacity(cfg("card_color"), "surface_variant", 0.18),
        border = "outline",
        borderWidth = 1,
        align = "center",
      }, keyboardRows),
      creatorOpen and creatorForm(index) or selectedKeyDetails(index),
    }),
  })
end

selectKeyboardKey = function(code)
  local modifier = MODIFIER_ALIASES[normalized(code)]
  if modifier ~= nil and activeModifiers[modifier] ~= nil then
    activeModifiers[modifier] = not activeModifiers[modifier]
    selectedKeyboardKey = nil
  else
    local canonical = canonicalKey(code)
    selectedKeyboardKey = canonical
    if creatorOpen then
      if creatorHasKey(canonical) then
        local remaining = {}
        for _, selectedCode in ipairs(creatorKeys) do
          if selectedCode ~= canonical then
            remaining[#remaining + 1] = selectedCode
          end
        end
        creatorKeys = remaining
      elseif normalized(snapshot.compositor) == "hyprland" then
        if #creatorKeys < 4 then
          creatorKeys[#creatorKeys + 1] = canonical
        end
      else
        creatorKeys = { canonical }
      end
      creatorKeysText = creatorKeysDisplay()
      creatorError = ""
    end
  end
  render()
end


local function keyPill(token, isKey)
  local fill
  local textColor
  if isKey then
    fill = cfg("key_color")
    textColor = cfg("key_text_color")
  else
    fill, textColor = modifierStyle(token)
  end
  return ui.row({
    fill = asString(fill, "surface"),
    border = "outline",
    borderWidth = 1,
    radius = 7,
    paddingH = 7,
    paddingV = 2,
    align = "center",
    justify = "center",
  }, {
    ui.label({
      text = asString(token, "?"),
      color = asString(textColor, "on_surface"),
      fontSize = 11,
      fontWeight = "bold",
      maxLines = 1,
    }),
  })
end

local function keyWidth(columnCount)
  if columnCount <= 1 then
    return 330
  elseif columnCount == 2 then
    return 245
  elseif columnCount == 3 then
    return 210
  end
  return 180
end

local DND_BIND_TYPE = "keybind-category"

local function bindHasWritableProvenance(bind)
  return not asString(bind.id):match("^range:")
    and asString(bind.source) ~= "" and tonumber(bind.start_line) ~= nil
    and tonumber(bind.end_line) ~= nil and asString(bind.raw_snippet) ~= ""
    and asString(bind.fingerprint) ~= ""
end

local function bindEditable(bind)
  local capabilities = type(bind.capabilities) == "table" and bind.capabilities or {}
  return capabilities.combo == true and capabilities.description == true
    and bindHasWritableProvenance(bind)
end

local function bindCategoryMovable(bind)
  local capabilities = type(bind.capabilities) == "table" and bind.capabilities or {}
  local bindId = asString(bind.id)
  return capabilities.category == true and bindHasWritableProvenance(bind)
    and bindId ~= "" and #bindId <= 256
end

local function categoryCanAcceptDrop(categoryName)
  local name = noctalia.string.trim(asString(categoryName))
  return name ~= "" and #name <= 80 and not name:find("%c")
    and not name:find('"', 1, true)
    and not name:find("Keymap managed", 1, true)
end

local function categoryRenameable(category)
  local binds = asArray(type(category) == "table" and category.binds or nil)
  if asString(type(category) == "table" and category.id or "") == "" or #binds == 0 then return false end
  for _, bind in ipairs(binds) do
    local firstLine = tonumber(bind.start_line)
    local lastLine = tonumber(bind.end_line)
    if not bindCategoryMovable(bind) or bind.hidden == true
      or asString(bind.source):sub(1, 1) ~= "/"
      or firstLine == nil or lastLine == nil or firstLine % 1 ~= 0 or lastLine % 1 ~= 0
      or firstLine < 1 or lastLine < firstLine then return false end
  end
  return true
end

local function findSnapshotCategory(categoryId)
  for _, category in ipairs(asArray(snapshot.categories)) do
    if asString(category.id) == categoryId then return category end
  end
  return nil
end

local function categoryNameExists(name, excludedId)
  local wanted = normalized(name)
  if wanted == "" then return false end
  for _, category in ipairs(asArray(snapshot.categories)) do
    if asString(category.id) ~= excludedId and normalized(category.name) == wanted then return true end
  end
  return false
end

local function optimisticRenameCategory(categoryId, oldName, newName)
  local categories = {}
  local renamed = false
  for _, category in ipairs(asArray(snapshot.categories)) do
    local nextCategory = {}
    for key, value in pairs(category) do nextCategory[key] = value end
    if asString(category.id) == categoryId and asString(category.name) == oldName then
      nextCategory.name = newName
      local binds = {}
      for _, bind in ipairs(asArray(category.binds)) do
        local nextBind = {}
        for key, value in pairs(bind) do nextBind[key] = value end
        if nextBind.category ~= nil then nextBind.category = newName end
        binds[#binds + 1] = nextBind
      end
      nextCategory.binds = binds
      renamed = true
    end
    categories[#categories + 1] = nextCategory
  end
  if not renamed then return false end
  local nextSnapshot = {}
  for key, value in pairs(snapshot) do nextSnapshot[key] = value end
  nextSnapshot.categories = categories
  snapshot = nextSnapshot
  return true
end

local function findSnapshotBind(bindId)
  for _, category in ipairs(asArray(snapshot.categories)) do
    for _, bind in ipairs(asArray(category.binds)) do
      if asString(bind.id) == bindId then
        return bind, asString(category.name, tr("panel.uncategorized"))
      end
    end
  end
  return nil, ""
end

local function findHiddenBind(bindId)
  for _, bind in ipairs(asArray(snapshot.hidden)) do
    if bind.hidden == true and asString(bind.id) == bindId then return bind end
  end
  return nil
end

local function snapshotHasCategory(categoryName)
  for _, category in ipairs(asArray(snapshot.categories)) do
    if asString(category.name, tr("panel.uncategorized")) == categoryName then
      return true
    end
  end
  return false
end

local function optimisticPlaceBind(bindId, targetCategory, anchorId, placement)
  local moved = nil
  local categories = {}
  for _, category in ipairs(asArray(snapshot.categories)) do
    local nextCategory = {}
    for key, value in pairs(category) do nextCategory[key] = value end
    local binds = {}
    for _, bind in ipairs(asArray(category.binds)) do
      if asString(bind.id) == bindId then moved = bind else binds[#binds + 1] = bind end
    end
    nextCategory.binds = binds
    categories[#categories + 1] = nextCategory
  end
  if moved == nil then return false end

  local inserted = false
  for _, category in ipairs(categories) do
    if asString(category.name, tr("panel.uncategorized")) == targetCategory then
      local binds = category.binds
      if asString(anchorId) == "" then
        binds[#binds + 1] = moved
        inserted = true
      else
        for index, bind in ipairs(binds) do
          if asString(bind.id) == anchorId then
            table.insert(binds, placement == "after" and index + 1 or index, moved)
            inserted = true
            break
          end
        end
      end
      break
    end
  end
  if not inserted then return false end

  local nextSnapshot = {}
  for key, value in pairs(snapshot) do nextSnapshot[key] = value end
  nextSnapshot.categories = categories
  snapshot = nextSnapshot
  return true
end

-- Logical pixels: the declarative UI scales explicit dimensions with the
-- shell UI scale. Keep row actions no taller than the compact key pills so
-- enabling edit mode does not change the height of every keybind row.
local BIND_ROW_ACTION_SIZE = 18
local BIND_ROW_ACTION_GLYPH_SIZE = 12

local function beginBindOperation(bind, operation)
  if creatorBusy or not bindEditable(bind) then return end
  local bindId = asString(bind.id)
  if operation == "delete" and deleteConfirmBindId ~= bindId then
    deleteConfirmBindId = bindId
    render()
    return
  end
  deleteConfirmBindId = ""
  creatorRequestCounter += 1
  local requestId = tostring(os.time()) .. "-action-" .. tostring(creatorRequestCounter)
  formMode = "edit"
  editingOperation = operation
  editingBindId = bindId
  editingRequestId = requestId
  creatorContextCompositor = asString(snapshot.compositor)
  creatorContextSource = asString(snapshot.source)
  creatorBusy = true
  creatorError = ""
  creatorOpen = false
  noctalia.state.set(UPDATE_REQUEST_KEY, {
    request_id = requestId,
    target_id = bindId,
    operation = operation,
    compositor = creatorContextCompositor,
    source = creatorContextSource,
  })
  render()
end

local function beginHiddenOperation(bind, operation)
  if creatorBusy or type(bind) ~= "table" or bind.hidden ~= true
    or not bindHasWritableProvenance(bind) then return end
  local capabilities = type(bind.capabilities) == "table" and bind.capabilities or {}
  if operation == "restore" and capabilities.restore ~= true then return end
  if operation == "delete" and capabilities.delete ~= true then return end

  local bindId = asString(bind.id)
  if operation == "delete" and hiddenDeleteConfirmBindId ~= bindId then
    hiddenDeleteConfirmBindId = bindId
    render()
    return
  end
  hiddenDeleteConfirmBindId = ""
  creatorRequestCounter += 1
  local requestId = tostring(os.time()) .. "-hidden-" .. tostring(creatorRequestCounter)
  formMode = "edit"
  editingOperation = operation
  editingBindId = bindId
  editingRequestId = requestId
  creatorContextCompositor = asString(snapshot.compositor)
  creatorContextSource = asString(snapshot.source)
  creatorBusy = true
  creatorError = ""
  creatorOpen = false
  noctalia.state.set(UPDATE_REQUEST_KEY, {
    request_id = requestId,
    target_id = bindId,
    operation = operation,
    hidden = true,
    compositor = creatorContextCompositor,
    source = creatorContextSource,
  })
  render()
end

local function clearCategoryRename()
  renamingCategoryId = ""
  renamingCategoryOriginal = ""
  renamingCategoryValue = ""
  creatorError = ""
end

local function openCategoryRename(category)
  if creatorBusy or not editorMode or not categoryRenameable(category) then return end
  creatorOpen = false
  formMode = "edit"
  editingBindId = ""
  editingOperation = "update"
  deleteConfirmBindId = ""
  hiddenDeleteConfirmBindId = ""
  renamingCategoryId = asString(category.id)
  renamingCategoryOriginal = asString(category.name, tr("panel.uncategorized"))
  renamingCategoryValue = renamingCategoryOriginal
  renamingCategoryRevision += 1
  creatorError = ""
  render()
end

local function openBindEditor(bind, categoryName)
  if creatorBusy or not bindEditable(bind) then return end
  clearCategoryRename()
  formMode = "edit"
  editingOperation = "update"
  deleteConfirmBindId = ""
  editingBindId = asString(bind.id)
  editingCategory = categoryName
  editingCapabilities = type(bind.capabilities) == "table" and bind.capabilities or {}
  editingAction = asString(bind.action, asString(bind.dispatcher))
  creatorCategoryNamesFrozen = {}
  local categoryNames = creatorCategoryNames()
  creatorCategoryNamesFrozen = categoryNames
  creatorCategoryIndex = 0
  for index, name in ipairs(categoryNames) do
    if name == categoryName then creatorCategoryIndex = index - 1 break end
  end
  creatorNewCategory = ""
  creatorKeys = {}
  local rawKeys = type(bind.keys) == "table" and bind.keys or expandedKeys(bind.key)
  for _, rawKey in ipairs(rawKeys) do creatorKeys[#creatorKeys + 1] = canonicalKey(rawKey) end
  creatorKeysText = creatorKeysDisplay()
  for _, modifier in ipairs(MODIFIER_ORDER) do activeModifiers[modifier] = false end
  for _, rawModifier in ipairs(asArray(bind.modifiers)) do
    local modifier = canonicalModifier(rawModifier)
    if activeModifiers[modifier] ~= nil then activeModifiers[modifier] = true end
  end
  creatorActivation = asString(bind.activation, bind.release == true and "release" or "press")
  creatorCommand = asString(bind.command)
  creatorCommandKind = "shell"
  creatorLibraryEntryId = ""
  creatorDescription = asString(bind.description)
  creatorContextCompositor = asString(snapshot.compositor)
  creatorContextSource = asString(snapshot.source)
  creatorError = ""
  creatorBusy = false
  creatorOpen = true
  commandLibraryOpen = false
  commandLibraryQuery = ""
  commandLibrarySourceIndex = 0
  commandLibraryCategoryIndex = 0
  commandLibraryReadinessIndex = 0
  commandLibraryRevision += 1
  selectedKeyboardKey = creatorKeys[1]
  creatorRevision += 1
  viewMode = "list"
  render()
end

local function registerCategoryRenameCallback(categoryId)
  local name = "onCategoryRename:" .. categoryId
  return registerDynamicCallback(name, function()
    local category = findSnapshotCategory(categoryId)
    if category ~= nil then openCategoryRename(category) end
  end)
end

local function registerBindCallback(bindId, operation)
  local name = "onBindAction:" .. operation .. ":" .. bindId
  return registerDynamicCallback(name, function()
    local bind, categoryName = findSnapshotBind(bindId)
    if bind == nil then return end
    if operation == "edit" then
      openBindEditor(bind, categoryName)
    else
      beginBindOperation(bind, operation)
    end
  end)
end

local function registerHiddenCallback(bindId, operation)
  local name = "onHiddenBindAction:" .. operation .. ":" .. bindId
  return registerDynamicCallback(name, function()
    local bind = findHiddenBind(bindId)
    if bind ~= nil then beginHiddenOperation(bind, operation) end
  end)
end

local function editBindActions(bind, categoryName)
  if not editorMode then return {} end
  local actions = {}
  if bindCategoryMovable(bind) then
    actions[#actions + 1] = ui.dragSource({
      key = "drag-bind-" .. asString(bind.id),
      dragType = DND_BIND_TYPE,
      payload = asString(bind.id),
      previewAncestor = 1,
      liftFromLayout = true,
      enabled = not creatorBusy and not creatorOpen and renamingCategoryId == "",
      tooltip = tr("panel.editor.drag"),
      width = BIND_ROW_ACTION_SIZE,
      height = BIND_ROW_ACTION_SIZE,
      radius = 4,
      align = "center",
      justify = "center",
    }, {
      ui.glyph({
        name = "menu-2", size = BIND_ROW_ACTION_GLYPH_SIZE,
        color = "on_surface_variant",
      }),
    })
  end
  if not bindEditable(bind) then
    actions[#actions + 1] = ui.button({
      glyph = "lock", variant = "ghost",
      width = BIND_ROW_ACTION_SIZE, height = BIND_ROW_ACTION_SIZE,
      glyphSize = BIND_ROW_ACTION_GLYPH_SIZE, enabled = false,
      tooltip = tr("panel.editor.read_only"),
    })
    return actions
  end
  local bindId = asString(bind.id)
  local editCallback = registerBindCallback(bindId, "edit")
  local hideCallback = registerBindCallback(bindId, "hide")
  local deleteCallback = registerBindCallback(bindId, "delete")

  actions[#actions + 1] = ui.button({
    glyph = "pencil", variant = "ghost",
    width = BIND_ROW_ACTION_SIZE, height = BIND_ROW_ACTION_SIZE,
    glyphSize = BIND_ROW_ACTION_GLYPH_SIZE,
    tooltip = tr("panel.editor.edit"), onClick = editCallback,
  })
  actions[#actions + 1] = ui.button({
    glyph = "eye-off", variant = "ghost",
    width = BIND_ROW_ACTION_SIZE, height = BIND_ROW_ACTION_SIZE,
    glyphSize = BIND_ROW_ACTION_GLYPH_SIZE,
    tooltip = tr("panel.editor.hide"), onClick = hideCallback,
  })

  if deleteConfirmBindId == asString(bind.id) then
    local cancelCallback = "onCancelDeleteBind"
    actions[#actions + 1] = ui.button({
      glyph = "x", variant = "ghost",
      width = BIND_ROW_ACTION_SIZE, height = BIND_ROW_ACTION_SIZE,
      glyphSize = BIND_ROW_ACTION_GLYPH_SIZE,
      tooltip = tr("panel.editor.cancel_delete"), onClick = cancelCallback,
    })
    actions[#actions + 1] = ui.button({
      glyph = "trash", variant = "destructive",
      width = BIND_ROW_ACTION_SIZE, height = BIND_ROW_ACTION_SIZE,
      glyphSize = BIND_ROW_ACTION_GLYPH_SIZE,
      tooltip = tr("panel.editor.confirm_delete"), onClick = deleteCallback,
    })
  else
    actions[#actions + 1] = ui.button({
      glyph = "trash", variant = "ghost",
      width = BIND_ROW_ACTION_SIZE, height = BIND_ROW_ACTION_SIZE,
      glyphSize = BIND_ROW_ACTION_GLYPH_SIZE,
      tooltip = tr("panel.editor.delete"), onClick = deleteCallback,
    })
  end
  return actions
end

local function bindRow(bind, categoryName, columnCount, rowIndex)
  local width = keyWidth(columnCount)
  local keys = {}
  local tokens = {}
  local estimatedWidth = 0
  for _, modifier in ipairs(asArray(bind.modifiers)) do
    tokens[#tokens + 1] = asString(modifier, "?")
    estimatedWidth = estimatedWidth + #asString(modifier, "?") * 7 + 18
    keys[#keys + 1] = keyPill(modifier, false)
  end
  local mainKey = asString(bind.key, "?")
  tokens[#tokens + 1] = mainKey
  estimatedWidth = estimatedWidth + #mainKey * 7 + 18 + math.max(0, #tokens - 1) * 4
  keys[#keys + 1] = keyPill(mainKey, true)

  local keyArea
  if estimatedWidth > width then
    keyArea = ui.row({
      width = width,
      fill = asString(cfg("key_color"), "surface"),
      border = "outline",
      borderWidth = 1,
      radius = 7,
      paddingH = 6,
      paddingV = 2,
      align = "center",
      justify = "center",
    }, {
      ui.label({
        text = table.concat(tokens, " + "),
        color = asString(cfg("key_text_color"), "on_surface"),
        fontSize = 10,
        fontWeight = "bold",
        textAlign = "center",
        maxWidth = width - 12,
        maxLines = 2,
      }),
    })
  else
    keyArea = ui.row({ width = width, gap = 4, align = "center" }, keys)
  end

  local description = asString(bind.description, tr("panel.no_description"))
  local details = {}
  local mode = asString(bind.mode)
  if mode ~= "" and normalized(mode) ~= "default" then
    details[#details + 1] = ui.label({
      text = mode,
      color = "secondary",
      fontSize = 10,
      fontWeight = "bold",
      maxLines = 1,
    })
  end
  details[#details + 1] = ui.label({
    text = description,
    color = asString(cfg("description_color"), "on_surface"),
    fontSize = 12,
    maxLines = 2,
    flexGrow = 1,
  })

  local children = {
    keyArea,
    ui.row({ gap = 6, align = "center", flexGrow = 1 }, details),
  }
  for _, action in ipairs(editBindActions(bind, categoryName)) do
    children[#children + 1] = action
  end

  return ui.row({
    key = "bind-" .. asString(bind.id, tostring(rowIndex)),
    gap = 10,
    paddingH = 6,
    paddingV = 4,
    radius = 8,
    fill = "surface/0.42",
    align = "center",
  }, children)
end

local function reorderInsertionZone(bind, placement)
  if not editorMode or not bindCategoryMovable(bind) then return nil end
  return ui.dropZone({
    key = "reorder-" .. placement .. "-" .. asString(bind.id),
    accepts = { DND_BIND_TYPE },
    value = placement .. "|" .. asString(bind.id),
    onDrop = "onBindReordered",
    height = 3,
    radius = 8,
    expandOnDrag = true,
    hitSlop = 64,
    enabled = not creatorBusy and not creatorOpen and renamingCategoryId == "",
  }, {})
end

local function hiddenBindRow(bind, columnCount, rowIndex)
  local keys = {}
  for _, modifier in ipairs(asArray(bind.modifiers)) do keys[#keys + 1] = keyPill(modifier, false) end
  local rawKeys = type(bind.keys) == "table" and bind.keys or { asString(bind.key, "?") }
  for _, key in ipairs(rawKeys) do keys[#keys + 1] = keyPill(key, true) end

  local bindId = asString(bind.id)
  local restoreCallback = registerHiddenCallback(bindId, "restore")
  local deleteCallback = registerHiddenCallback(bindId, "delete")
  local actions = {
    ui.button({
      glyph = "restore", variant = "ghost",
      width = BIND_ROW_ACTION_SIZE, height = BIND_ROW_ACTION_SIZE,
      glyphSize = BIND_ROW_ACTION_GLYPH_SIZE,
      tooltip = tr("panel.editor.restore"), onClick = restoreCallback,
    }),
  }
  if hiddenDeleteConfirmBindId == bindId then
    actions[#actions + 1] = ui.button({
      glyph = "x", variant = "ghost",
      width = BIND_ROW_ACTION_SIZE, height = BIND_ROW_ACTION_SIZE,
      glyphSize = BIND_ROW_ACTION_GLYPH_SIZE,
      tooltip = tr("panel.editor.cancel_delete"), onClick = "onCancelDeleteHiddenBind",
    })
    actions[#actions + 1] = ui.button({
      glyph = "trash", variant = "destructive",
      width = BIND_ROW_ACTION_SIZE, height = BIND_ROW_ACTION_SIZE,
      glyphSize = BIND_ROW_ACTION_GLYPH_SIZE,
      tooltip = tr("panel.editor.confirm_delete_hidden"), onClick = deleteCallback,
    })
  else
    actions[#actions + 1] = ui.button({
      glyph = "trash", variant = "ghost",
      width = BIND_ROW_ACTION_SIZE, height = BIND_ROW_ACTION_SIZE,
      glyphSize = BIND_ROW_ACTION_GLYPH_SIZE,
      tooltip = tr("panel.editor.delete_hidden"), onClick = deleteCallback,
    })
  end

  local details = {
    ui.label({
      text = asString(bind.description, tr("panel.no_description")),
      color = asString(cfg("description_color"), "on_surface"),
      fontSize = 12, maxLines = 2, flexGrow = 1,
    }),
  }
  if asString(bind.category) ~= "" then
    details[#details + 1] = ui.label({
      text = asString(bind.category), color = "secondary", fontSize = 10,
      fontWeight = "bold", maxLines = 1,
    })
  end

  local children = {
    ui.row({ width = keyWidth(columnCount), gap = 4, align = "center" }, keys),
    ui.row({ gap = 6, align = "center", flexGrow = 1 }, details),
  }
  for _, action in ipairs(actions) do children[#children + 1] = action end
  return ui.row({
    key = "hidden-bind-" .. bindId .. "-" .. tostring(rowIndex),
    gap = 10, paddingH = 6, paddingV = 4, radius = 8,
    fill = "surface/0.42", align = "center",
  }, children)
end

local function hiddenSection(hidden, columnCount)
  if not editorMode or #hidden == 0 then return nil end
  local children = {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "eye-off", size = 16, color = "secondary" }),
      ui.label({
        text = tr("panel.editor.hidden_title"), color = "secondary",
        fontSize = 14, fontWeight = "bold", flexGrow = 1,
      }),
      ui.label({
        text = noctalia.trp("panel.editor.hidden_count", #hidden),
        color = "on_surface_variant", fontSize = 11,
      }),
    }),
    ui.label({
      text = tr("panel.editor.hidden_hint"), color = "on_surface_variant",
      fontSize = 11, maxLines = 2,
    }),
  }
  for index, bind in ipairs(hidden) do
    children[#children + 1] = hiddenBindRow(bind, columnCount, index)
  end
  return ui.column({
    key = "hidden-shortcuts", gap = 3, padding = 8, radius = 12,
    fill = cardFill(), border = "secondary", borderWidth = 1,
  }, children)
end

local function categoryCard(category, columnCount)
  local categoryName = asString(category.name, tr("panel.uncategorized"))
  local categoryId = asString(category.id, categoryName)
  local isRenaming = editorMode and renamingCategoryId == categoryId
  local canRename = categoryRenameable(category)
  local header
  if isRenaming then
    local nextName = noctalia.string.trim(renamingCategoryValue)
    local canSave = not creatorBusy and categoryCanAcceptDrop(nextName)
      and nextName ~= categoryName and not categoryNameExists(nextName, categoryId)
    header = ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "pencil", size = 15, color = "primary" }),
      ui.input({
        key = "category-name-" .. tostring(renamingCategoryRevision),
        value = renamingCategoryValue,
        placeholder = tr("panel.editor.category_name_placeholder"),
        flexGrow = 1,
        controlSize = "sm",
        enabled = not creatorBusy,
        focus = true,
        onChange = "onCategoryRenameChanged",
        onSubmit = "onCategoryRenameSave",
      }),
      ui.button({
        glyph = "x", variant = "ghost", controlSize = "sm",
        tooltip = tr("panel.editor.category_rename_cancel"),
        enabled = not creatorBusy, onClick = "onCategoryRenameCancel",
      }),
      ui.button({
        glyph = "device-floppy", variant = "primary", controlSize = "sm",
        tooltip = tr("panel.editor.category_rename_save"),
        enabled = canSave, onClick = "onCategoryRenameSave",
      }),
    })
  else
    local headerChildren = {
      ui.label({
        text = categoryName,
        color = asString(cfg("category_color"), "primary"),
        fontSize = 14,
        fontWeight = "bold",
        maxLines = 1,
        flexGrow = 1,
      }),
      ui.label({
        text = noctalia.trp("panel.category_count", #asArray(category.binds)),
        color = "on_surface_variant",
        fontSize = 11,
      }),
    }
    if editorMode then
      local renameProps = {
        glyph = "pencil", variant = "ghost",
        width = BIND_ROW_ACTION_SIZE, height = BIND_ROW_ACTION_SIZE,
        glyphSize = BIND_ROW_ACTION_GLYPH_SIZE,
        enabled = canRename and not creatorBusy and not creatorOpen and renamingCategoryId == "",
        tooltip = canRename and tr("panel.editor.category_rename")
          or tr("panel.editor.category_read_only"),
      }
      if canRename then renameProps.onClick = registerCategoryRenameCallback(categoryId) end
      headerChildren[#headerChildren + 1] = ui.button(renameProps)
    end
    header = ui.row({ gap = 8, align = "center" }, headerChildren)
  end
  local children = { header }
  if isRenaming and creatorError ~= "" then
    children[#children + 1] = ui.label({
      text = creatorErrorText(), color = "error", fontSize = 10, maxLines = 2,
    })
  end

  local categoryBinds = asArray(category.binds)
  for index, bind in ipairs(categoryBinds) do
    local insertion = reorderInsertionZone(bind, "before")
    if insertion ~= nil then children[#children + 1] = insertion end
    children[#children + 1] = bindRow(
      bind, categoryName, columnCount, index
    )
  end
  if #categoryBinds > 0 then
    local insertion = reorderInsertionZone(categoryBinds[#categoryBinds], "after")
    if insertion ~= nil then children[#children + 1] = insertion end
  end
  local props = {
    key = "category-" .. categoryId,
    gap = editorMode and 0 or 3,
    padding = 8,
    radius = 12,
    fill = cardFill(),
    border = "outline",
    borderWidth = 1,
  }
  if editorMode and categoryCanAcceptDrop(categoryName) then
    props.accepts = { DND_BIND_TYPE }
    props.value = categoryName
    props.onDrop = "onBindDropped"
    props.enabled = not creatorBusy and not creatorOpen and renamingCategoryId == ""
    return ui.dropZone(props, children)
  end
  return ui.column(props, children)
end

local function readyBody(categories, requestedColumns)
  local hidden = filteredHidden()
  if #categories == 0 and (not editorMode or #hidden == 0) then
    local searching = normalized(searchQuery) ~= ""
    local message = searching and tr("panel.no_results") or tr("panel.empty")
    local hint = searching and tr("panel.no_results_hint") or tr("panel.empty_hint")
    local children = {
      ui.glyph({ name = "keyboard-off", size = 44, color = "on_surface_variant" }),
      ui.label({ text = message, fontSize = 16, fontWeight = "bold", color = "on_surface" }),
      ui.label({ text = hint, color = "on_surface_variant", textAlign = "center", maxWidth = 560, maxLines = 3 }),
    }
    if not searching then
      children[#children + 1] = ui.button({
        text = tr("panel.open_settings_action"), glyph = "settings", variant = "ghost",
        onClick = "onOpenSettingsClicked",
      })
    end
    return ui.column({ flexGrow = 1, align = "center", justify = "center", gap = 10 }, children)
  end

  local columns = partitionCategories(categories, requestedColumns)
  local columnNodes = {}
  for columnIndex, column in ipairs(columns) do
    local cards = {}
    for _, category in ipairs(column) do
      cards[#cards + 1] = categoryCard(category, #columns)
    end
    columnNodes[#columnNodes + 1] = ui.column({
      key = "column-" .. tostring(columnIndex),
      gap = 12,
      flexGrow = 1,
      align = "stretch",
    }, cards)
  end

  local content = {}
  local hiddenNode = hiddenSection(hidden, math.max(1, #columns))
  if hiddenNode ~= nil then content[#content + 1] = hiddenNode end
  if #columnNodes > 0 then
    content[#content + 1] = ui.row({ gap = 12, align = "start" }, columnNodes)
  end
  return ui.scroll({ flexGrow = 1, gap = 0 }, {
    ui.column({ gap = 12, align = "stretch" }, content),
  })
end

local function statusBody(status, errorText)
  local isError = status == "error"
  local errorKey = "panel.errors." .. asString(errorText, "unknown")
  local translatedError = tr(errorKey)
  if translatedError == errorKey then
    translatedError = tr("panel.unknown_error")
  end
  return ui.column({ flexGrow = 1, align = "center", justify = "center", gap = 12 }, {
    ui.glyph({
      name = isError and "alert-circle" or "refresh",
      size = 44,
      color = isError and "error" or "primary",
    }),
    ui.label({
      text = isError and tr("panel.load_failed") or tr("panel.loading"),
      fontSize = 16,
      fontWeight = "bold",
      color = isError and "error" or "on_surface",
    }),
    ui.label({
      text = isError and translatedError or tr("panel.loading_hint"),
      color = "on_surface_variant",
      textAlign = "center",
      maxWidth = 680,
      maxLines = 4,
    }),
    ui.label({
      text = tr("panel.path_hint"),
      color = "on_surface_variant",
      textAlign = "center",
      maxWidth = 680,
      maxLines = 3,
      visible = isError,
    }),
    ui.button({
      text = tr("panel.retry"),
      glyph = "refresh",
      variant = "primary",
      visible = isError,
      onClick = "onRefreshClicked",
    }),
    ui.button({
      text = tr("panel.open_settings_action"),
      glyph = "settings",
      variant = "ghost",
      visible = isError,
      onClick = "onOpenSettingsClicked",
    }),
  })
end

local function countVisibleBinds(categories)
  local count = 0
  for _, category in ipairs(categories) do
    count += #asArray(category.binds)
  end
  return count
end

local function header()
  local compositor = asString(snapshot.compositor, tr("panel.detecting"))
  local total = tonumber(snapshot.total) or countVisibleBinds(asArray(snapshot.categories))
  local subtitle = compositor .. "  ·  " .. noctalia.trp("panel.bind_count", total)
  if asString(snapshot.updated_at) ~= "" then
    subtitle ..= "  ·  " .. tr("panel.updated", { time = snapshot.updated_at })
  end

  return ui.row({ gap = 10, align = "center" }, {
    ui.glyph({ name = "keyboard", size = 26, color = "primary" }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = tr("title"), fontSize = 18, fontWeight = "bold", color = "on_surface" }),
      ui.label({ text = subtitle, fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
    }),
    ui.button({
      glyph = "keyboard",
      variant = viewMode == "keyboard" and "primary" or "ghost",
      selected = viewMode == "keyboard",
      tooltip = tr("panel.keyboard.view"),
      onClick = "onShowKeyboard",
    }),
    ui.button({
      glyph = "list",
      variant = viewMode == "list" and "primary" or "ghost",
      selected = viewMode == "list",
      tooltip = tr("panel.list_view"),
      onClick = "onShowList",
    }),
    ui.label({
      text = tr("panel.keyboard.layout"),
      color = "on_surface_variant",
      fontSize = 10,
      visible = editorMode,
    }),
    ui.select({
      key = "keyboard-layout-selector",
      options = keyboardLayoutOptions(),
      selectedIndex = keyboardLayoutSelectedIndex(),
      width = 120,
      controlSize = "sm",
      visible = editorMode,
      enabled = not creatorBusy,
      onChange = "onKeyboardLayoutChanged",
    }),
    ui.spacer({ width = 8, flexGrow = 0 }),
    ui.button({
      text = tr("panel.creator.new_shortcut"),
      glyph = "pencil-plus",
      variant = creatorOpen and formMode == "create" and "primary" or "ghost",
      selected = creatorOpen and formMode == "create",
      enabled = snapshot.status == "ready",
      tooltip = tr("panel.creator.open"),
      onClick = "onCreatorToggle",
    }),
    ui.button({
      text = tr("panel.editor.open"),
      glyph = "edit",
      variant = editorMode and "primary" or "ghost",
      selected = editorMode,
      enabled = snapshot.status == "ready",
      tooltip = tr("panel.editor.open_hint"),
      onClick = "onEditorToggle",
    }),
    ui.button({
      glyph = "refresh",
      variant = "ghost",
      tooltip = tr("panel.refresh"),
      enabled = snapshot.status ~= "loading",
      onClick = "onRefreshClicked",
    }),
    ui.button({
      glyph = "folder-open",
      variant = "ghost",
      tooltip = tr("panel.open_config_folder"),
      enabled = sourceDirectory() ~= "" and not creatorBusy,
      onClick = "onOpenConfigFolderClicked",
    }),
    ui.button({
      glyph = "settings",
      variant = "ghost",
      tooltip = tr("panel.open_settings"),
      enabled = not creatorBusy,
      onClick = "onOpenSettingsClicked",
    }),
    ui.button({ glyph = "close", variant = "ghost", tooltip = tr("panel.close"), onClick = "onCloseClicked" }),
  })
end

local function searchBar(categories)
  local children = {
    ui.input({
      key = "search-" .. tostring(searchRevision),
      value = searchQuery,
      placeholder = tr("panel.search_placeholder"),
      focus = true,
      flexGrow = 1,
      onChange = "onSearchChanged",
      onSubmit = "onSearchChanged",
    }),
  }

  if searchQuery ~= "" then
    children[#children + 1] = ui.label({
      text = noctalia.trp("panel.search_results", countVisibleBinds(categories)),
      color = "on_surface_variant",
      fontSize = 11,
    })
    children[#children + 1] = ui.button({
      glyph = "x",
      variant = "ghost",
      tooltip = tr("panel.clear_search"),
      onClick = "onClearSearch",
    })
  end

  return ui.row({ gap = 8, align = "center" }, children)
end

local function warningsBanner()
  local warnings = asArray(snapshot.warnings)
  if #warnings == 0 then
    return nil
  end
  return ui.row({
    gap = 8,
    paddingH = 10,
    paddingV = 7,
    radius = 9,
    fill = "warning/0.12",
    border = "warning",
    borderWidth = 1,
    align = "center",
  }, {
    ui.glyph({ name = "alert-triangle", size = 17, color = "tertiary" }),
    ui.label({
      text = noctalia.trp("panel.warning_count", #warnings),
      color = "on_surface",
      fontSize = 11,
      maxLines = 2,
      flexGrow = 1,
    }),
  })
end

render = function()
  renderCallbackNames = {}
  local status = asString(snapshot.status, "idle")
  local categories = filteredCategories()
  local requestedColumns = math.max(1, math.min(4, math.floor(tonumber(cfg("columns")) or 3)))
  local body
  if status == "error" then
    body = statusBody(status, snapshot.error)
  elseif status == "loading" or status == "idle" then
    body = statusBody(status, "")
  elseif viewMode == "keyboard" then
    body = keyboardBody()
  else
    body = readyBody(categories, requestedColumns)
  end

  local children = {
    header(),
    ui.separator({ orientation = "horizontal", color = "outline", opacity = 0.65 }),
  }
  if viewMode == "list" then
    children[#children + 1] = searchBar(categories)
  end
  if viewMode == "list" and creatorOpen and status == "ready" then
    children[#children + 1] = creatorForm(keyboardIndex())
  end
  local warning = warningsBanner()
  if warning ~= nil and status == "ready" then
    children[#children + 1] = warning
  end
  children[#children + 1] = body
  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, children))
  finishDynamicCallbackRender()
end

local function requestRefresh()
  local current = tonumber(noctalia.state.get(REFRESH_KEY)) or 0
  noctalia.state.set(REFRESH_KEY, current + 1)
end

noctalia.state.watch(SNAPSHOT_KEY, function(value)
  if type(value) == "table" and value.status == "loading" and snapshot.status == "ready" then
    return
  end
  if type(value) == "table" then
    snapshot = value
  else
    snapshot = EMPTY_SNAPSHOT
  end
  render()
end)

noctalia.state.watch(CREATE_RESULT_KEY, function(result)
  if formMode ~= "create" or type(result) ~= "table"
    or tostring(result.request_id or "") ~= creatorRequestId or not creatorBusy then
    return
  end
  creatorBusy = false
  if result.ok == true then
    local chord = creatorChord()
    creatorOpen = false
    creatorKeys = {}
    selectedKeyboardKey = nil
    noctalia.notify(tr("title"), tr("panel.creator.saved", { chord = chord }))
  else
    creatorError = asString(result.error, "write_failed")
    noctalia.notifyError(tr("title"), creatorErrorText())
  end
  render()
end)

noctalia.state.watch(UPDATE_RESULT_KEY, function(result)
  if formMode ~= "edit" or type(result) ~= "table"
    or tostring(result.request_id or "") ~= editingRequestId or not creatorBusy then
    return
  end
  creatorBusy = false
  if result.ok == true then
    editingSnapshotBefore = nil
    creatorOpen = false
    editingBindId = ""
    selectedKeyboardKey = nil
    viewMode = "list"
    local resultKey = editingOperation == "hide" and "hidden"
      or (editingOperation == "restore" and "restored"
      or (editingOperation == "delete" and "deleted"
        or (editingOperation == "move" and "moved"
          or (editingOperation == "reorder" and "reordered"
            or (editingOperation == "rename_category" and "category_renamed" or "updated")))))
    noctalia.notify(tr("title"), tr("panel.editor." .. resultKey))
    if editingOperation == "rename_category" then clearCategoryRename() end
  else
    if editingSnapshotBefore ~= nil then snapshot = editingSnapshotBefore end
    editingSnapshotBefore = nil
    creatorError = asString(result.error, "write_failed")
    noctalia.notifyError(tr("title"), creatorErrorText())
  end
  editingOperation = "update"
  deleteConfirmBindId = ""
  hiddenDeleteConfirmBindId = ""
  render()
end)

function onOpen(_context)
  local configuredLayout = asString(cfg("keyboard_layout"), "100")
  keyboardLayoutId = KEYBOARD_LAYOUTS[configuredLayout] ~= nil and configuredLayout or "100"
  local current = noctalia.state.get(SNAPSHOT_KEY)
  snapshot = type(current) == "table" and current or EMPTY_SNAPSHOT
  searchQuery = ""
  searchRevision += 1
  if creatorBusy then
    creatorOpen = editingOperation == "update"
    viewMode = formMode == "edit" and "list" or "keyboard"
  else
    creatorOpen = false
    creatorError = ""
    editorMode = false
    formMode = "create"
    editingBindId = ""
    editingOperation = "update"
    deleteConfirmBindId = ""
    hiddenDeleteConfirmBindId = ""
    clearCategoryRename()
  end
  if snapshot.status == nil or snapshot.status == "idle" then
    requestRefresh()
  end
  render()
end

function onConfigChanged()
  render()
end

function update()
  render()
end

function onSearchChanged(value)
  searchQuery = asString(value)
  render()
end

function onClearSearch()
  searchQuery = ""
  searchRevision += 1
  render()
end

function onShowKeyboard()
  viewMode = "keyboard"
  render()
end

function onShowList()
  if creatorBusy then return end
  viewMode = "list"
  creatorOpen = false
  render()
end

function onKeyboardLayoutChanged(index, _label)
  if creatorBusy then return end
  local selectedIndex = math.floor(tonumber(index) or -1) + 1
  local layoutId = KEYBOARD_LAYOUT_ORDER[selectedIndex]
  if layoutId == nil or KEYBOARD_LAYOUTS[layoutId] == nil then return end
  keyboardLayoutId = layoutId
  render()
end

local function resetCreator()
  formMode = "create"
  editingBindId = ""
  editingCategory = ""
  editingCapabilities = {}
  editingAction = ""
  creatorKeys = viewMode == "keyboard" and selectedKeyboardKey ~= nil and { selectedKeyboardKey } or {}
  creatorKeysText = creatorKeysDisplay()
  creatorActivation = "press"
  creatorCommand = ""
  creatorCommandKind = "shell"
  creatorLibraryEntryId = ""
  creatorDescription = ""
  creatorCategoryIndex = 0
  creatorNewCategory = ""
  creatorCategoryNamesFrozen = creatorCategoryNames()
  creatorContextCompositor = asString(snapshot.compositor)
  creatorContextSource = asString(snapshot.source)
  creatorBusy = false
  creatorError = ""
  commandLibraryOpen = false
  commandLibraryQuery = ""
  commandLibrarySourceIndex = 0
  commandLibraryCategoryIndex = 0
  commandLibraryReadinessIndex = 0
  commandLibraryRevision += 1
  creatorRevision += 1
end

function onCreatorToggle()
  if creatorBusy then return end
  clearCategoryRename()
  if creatorOpen and formMode == "create" then
    creatorOpen = false
  else
    editorMode = false
    resetCreator()
    creatorOpen = true
  end
  render()
end

function onCreatorCancel()
  if creatorBusy then return end
  creatorOpen = false
  creatorBusy = false
  creatorError = ""
  commandLibraryOpen = false
  if formMode == "edit" then viewMode = "list" end
  render()
end

function onEditorToggle()
  if creatorBusy then return end
  if editorMode then
    editorMode = false
    creatorOpen = false
    formMode = "create"
    editingBindId = ""
    deleteConfirmBindId = ""
    hiddenDeleteConfirmBindId = ""
    clearCategoryRename()
  else
    editorMode = true
    creatorOpen = false
    formMode = "edit"
    editingBindId = ""
    deleteConfirmBindId = ""
    hiddenDeleteConfirmBindId = ""
    clearCategoryRename()
    viewMode = "list"
  end
  render()
end

function onCategoryRenameChanged(value)
  if creatorBusy or renamingCategoryId == "" then return end
  renamingCategoryValue = asString(value)
  creatorError = ""
  render()
end

function onCategoryRenameCancel()
  if creatorBusy then return end
  clearCategoryRename()
  render()
end

function onCategoryRenameSave()
  if creatorBusy or renamingCategoryId == "" or snapshot.status ~= "ready" then return end
  local category = findSnapshotCategory(renamingCategoryId)
  local nextName = noctalia.string.trim(renamingCategoryValue)
  if snapshot.compositor == "" or snapshot.source == "" then
    creatorError = "stale_context"
  elseif category == nil or asString(category.name) ~= renamingCategoryOriginal then
    creatorError = "category_changed"
  elseif not categoryRenameable(category) then
    creatorError = "category_not_editable"
  elseif nextName == "" then
    creatorError = "category_required"
  elseif not categoryCanAcceptDrop(nextName) then
    creatorError = "category_invalid"
  elseif categoryNameExists(nextName, renamingCategoryId) then
    creatorError = "category_exists"
  elseif nextName == renamingCategoryOriginal then
    clearCategoryRename()
  else
    creatorRequestCounter += 1
    local requestId = tostring(os.time()) .. "-rename-category-" .. tostring(creatorRequestCounter)
    formMode = "edit"
    editingOperation = "rename_category"
    editingBindId = ""
    editingRequestId = requestId
    creatorContextCompositor = asString(snapshot.compositor)
    creatorContextSource = asString(snapshot.source)
    creatorBusy = true
    creatorError = ""
    creatorOpen = false
    editingSnapshotBefore = snapshot
    if not optimisticRenameCategory(
      renamingCategoryId, renamingCategoryOriginal, nextName
    ) then
      editingSnapshotBefore = nil
      creatorBusy = false
      creatorError = "category_changed"
    else
      noctalia.state.set(UPDATE_REQUEST_KEY, {
        request_id = requestId,
        operation = "rename_category",
        compositor = creatorContextCompositor,
        source = creatorContextSource,
        category_id = renamingCategoryId,
        old_category = renamingCategoryOriginal,
        new_category = nextName,
      })
    end
  end
  render()
end

function onCreatorPress()
  creatorActivation = "press"
  creatorError = ""
  render()
end

function onCreatorRelease()
  if normalized(snapshot.compositor) ~= "niri" then
    creatorActivation = "release"
    creatorError = ""
    render()
  end
end

function onCreatorCategoryChanged(index, _text)
  creatorCategoryIndex = tonumber(index) or 0
  creatorError = ""
  render()
end

function onCreatorNewCategoryChanged(value)
  creatorNewCategory = asString(value)
  creatorError = ""
  render()
end

function onCreatorDescriptionChanged(value)
  creatorDescription = asString(value)
  creatorError = ""
  render()
end

function onCommandLibraryToggle()
  if formMode == "edit" and editingCapabilities.command ~= true then return end
  commandLibraryOpen = not commandLibraryOpen
  creatorError = ""
  render()
end

function onCommandLibraryQueryChanged(value)
  commandLibraryQuery = asString(value)
  render()
end

function onCommandLibrarySourceChanged(index, _text)
  commandLibrarySourceIndex = math.max(0, math.floor(tonumber(index) or 0))
  commandLibraryCategoryIndex = 0
  render()
end

function onCommandLibraryCategoryChanged(index, _text)
  commandLibraryCategoryIndex = math.max(0, math.floor(tonumber(index) or 0))
  render()
end

function onCommandLibraryReadinessChanged(index, _text)
  commandLibraryReadinessIndex = math.max(0, math.min(2, math.floor(tonumber(index) or 0)))
  render()
end

function onCommandLibraryUseCustom()
  if creatorCommandKind == "native" then
    creatorCommand = ""
    creatorRevision += 1
  end
  creatorCommandKind = "shell"
  creatorLibraryEntryId = ""
  commandLibraryOpen = false
  creatorError = ""
  render()
end

function onCreatorCommandChanged(value)
  creatorCommand = asString(value)
  creatorError = ""
  render()
end

function onEditorKeysChanged(value)
  creatorKeysText = asString(value)
  local keys = {}
  local seen = {}
  for part in (creatorKeysText .. ","):gmatch("(.-),") do
    local key = canonicalKey(noctalia.string.trim(part))
    if key ~= "" and not seen[key] then
      seen[key] = true
      keys[#keys + 1] = key
    end
  end
  creatorKeys = keys
  selectedKeyboardKey = keys[1]
  creatorError = ""
  render()
end

function onCreatorSave()
  if creatorBusy then
    return
  end
  local index = keyboardIndex()
  local compositor = normalized(snapshot.compositor)
  local category = creatorCategory()
  if snapshot.status ~= "ready" or snapshot.compositor ~= creatorContextCompositor
    or snapshot.source ~= creatorContextSource then
    creatorError = "stale_context"
  elseif #creatorKeys == 0 then
    creatorError = "combination_required"
  elseif (formMode ~= "edit" or editingCapabilities.command == true)
    and noctalia.string.trim(creatorCommand) == "" then
    creatorError = "command_required"
  elseif creatorCommand:find("{{", 1, true) ~= nil then
    creatorError = "library_arguments_required"
  elseif noctalia.string.trim(creatorDescription) == "" then
    creatorError = "description_required"
  elseif category == "" then
    creatorError = "category_required"
  elseif compositor ~= "hyprland" and #creatorKeys ~= 1 then
    creatorError = "single_key_only"
  elseif compositor == "niri" and creatorActivation == "release" then
    creatorError = "release_unsupported"
  elseif creatorConflict(index) ~= nil then
    creatorError = "conflict_blocked"
  else
    local keys = {}
    for _, code in ipairs(creatorKeys) do
      keys[#keys + 1] = configKeyName(code)
    end
    local modifiers = {}
    for _, modifier in ipairs(MODIFIER_ORDER) do
      if activeModifiers[modifier] then
        modifiers[#modifiers + 1] = modifier
      end
    end
    creatorRequestCounter += 1
    local requestId = tostring(os.time()) .. "-" .. tostring(creatorRequestCounter)
    creatorBusy = true
    creatorError = ""
    local request = {
      request_id = requestId,
      compositor = creatorContextCompositor,
      source = creatorContextSource,
      modifiers = modifiers,
      keys = keys,
      activation = creatorActivation,
      command = noctalia.string.trim(creatorCommand),
      command_kind = creatorCommandKind,
      library_entry_id = creatorLibraryEntryId,
      description = noctalia.string.trim(creatorDescription),
      category = category,
    }
    if formMode == "edit" then
      editingOperation = "update"
      editingRequestId = requestId
      request.target_id = editingBindId
      noctalia.state.set(UPDATE_REQUEST_KEY, request)
    else
      creatorRequestId = requestId
      noctalia.state.set(CREATE_REQUEST_KEY, request)
    end
  end
  render()
end

local function toggleModifier(modifier)
  activeModifiers[modifier] = not activeModifiers[modifier]
  selectedKeyboardKey = nil
  render()
end

function onToggleSuper() toggleModifier("SUPER") end
function onToggleCtrl() toggleModifier("CTRL") end
function onToggleShift() toggleModifier("SHIFT") end
function onToggleAlt() toggleModifier("ALT") end

function onClearModifiers()
  for _, modifier in ipairs(MODIFIER_ORDER) do
    activeModifiers[modifier] = false
  end
  selectedKeyboardKey = nil
  render()
end

function onCancelDeleteBind()
  deleteConfirmBindId = ""
  render()
end

function onCancelDeleteHiddenBind()
  hiddenDeleteConfirmBindId = ""
  render()
end

function onBindDropped(bindId, targetCategory)
  if not editorMode or creatorBusy or snapshot.status ~= "ready" then return end
  local targetName = noctalia.string.trim(asString(targetCategory))
  if not categoryCanAcceptDrop(targetName) or not snapshotHasCategory(targetName) then return end
  local bind, currentCategory = findSnapshotBind(asString(bindId))
  if bind == nil or not bindCategoryMovable(bind) or currentCategory == targetName then return end

  creatorRequestCounter += 1
  local requestId = tostring(os.time()) .. "-move-" .. tostring(creatorRequestCounter)
  formMode = "edit"
  editingOperation = "move"
  editingBindId = asString(bind.id)
  editingRequestId = requestId
  creatorContextCompositor = asString(snapshot.compositor)
  creatorContextSource = asString(snapshot.source)
  creatorBusy = true
  creatorError = ""
  creatorOpen = false
  deleteConfirmBindId = ""
  editingSnapshotBefore = snapshot
  if not optimisticPlaceBind(editingBindId, targetName, "", "after") then
    editingSnapshotBefore = nil
    creatorBusy = false
    return
  end
  noctalia.state.set(UPDATE_REQUEST_KEY, {
    request_id = requestId,
    target_id = editingBindId,
    operation = "move",
    category = targetName,
    compositor = creatorContextCompositor,
    source = creatorContextSource,
  })
  render()
end

function onBindReordered(bindId, targetValue)
  if not editorMode or creatorBusy or snapshot.status ~= "ready" then return end
  local placement, anchorId = asString(targetValue):match("^(%a+)|(.+)$")
  if (placement ~= "before" and placement ~= "after") or asString(anchorId) == "" then return end
  local bind, bindCategory = findSnapshotBind(asString(bindId))
  local anchor, anchorCategory = findSnapshotBind(asString(anchorId))
  if bind == nil or anchor == nil or asString(bind.id) == asString(anchor.id)
    or not bindCategoryMovable(bind) or not bindCategoryMovable(anchor) then return end
  if asString(bind.source) ~= asString(anchor.source) then
    if bindCategory ~= anchorCategory then onBindDropped(bindId, anchorCategory) end
    return
  end

  creatorRequestCounter += 1
  local requestId = tostring(os.time()) .. "-reorder-" .. tostring(creatorRequestCounter)
  formMode = "edit"
  editingOperation = "reorder"
  editingBindId = asString(bind.id)
  editingRequestId = requestId
  creatorContextCompositor = asString(snapshot.compositor)
  creatorContextSource = asString(snapshot.source)
  creatorBusy = true
  creatorError = ""
  creatorOpen = false
  deleteConfirmBindId = ""
  hiddenDeleteConfirmBindId = ""
  editingSnapshotBefore = snapshot
  if not optimisticPlaceBind(editingBindId, anchorCategory, asString(anchor.id), placement) then
    editingSnapshotBefore = nil
    creatorBusy = false
    return
  end
  noctalia.state.set(UPDATE_REQUEST_KEY, {
    request_id = requestId,
    target_id = editingBindId,
    anchor_id = asString(anchor.id),
    operation = "reorder",
    placement = placement,
    compositor = creatorContextCompositor,
    source = creatorContextSource,
  })
  render()
end

function onIpc(event, payload)
  if event == "view-keyboard" then
    onShowKeyboard()
  elseif event == "view-list" then
    onShowList()
  elseif event == "keyboard-layout" and KEYBOARD_LAYOUTS[asString(payload)] ~= nil then
    keyboardLayoutId = asString(payload)
    render()
  elseif event == "keyboard-key" and asString(payload) ~= "" then
    selectKeyboardKey(payload)
  elseif event == "clear-modifiers" then
    onClearModifiers()
  elseif event == "creator-open" and not creatorOpen then
    onCreatorToggle()
  elseif event == "creator-cancel" and creatorOpen then
    onCreatorCancel()
  elseif event == "editor-open" and not editorMode then
    onEditorToggle()
  elseif event == "editor-bind" and asString(payload) ~= "" then
    for _, category in ipairs(asArray(snapshot.categories)) do
      for _, bind in ipairs(asArray(category.binds)) do
        if asString(bind.id) == asString(payload) then
          editorMode = true
          openBindEditor(bind, asString(category.name, tr("panel.uncategorized")))
          return
        end
      end
    end
  end
end

function onRefreshClicked()
  requestRefresh()
end

function onOpenConfigFolderClicked()
  if creatorBusy then return end
  local directory = sourceDirectory()
  if directory == "" then
    noctalia.notifyError(tr("title"), tr("panel.config_folder_unavailable"))
    return
  end
  local info = noctalia.fileInfo(directory)
  if type(info) ~= "table" or info.isDir ~= true then
    noctalia.notifyError(tr("title"), tr("panel.config_folder_unavailable"))
    return
  end
  if not noctalia.commandExists("xdg-open") then
    noctalia.notifyError(tr("title"), tr("panel.xdg_open_unavailable"))
    return
  end
  local started = noctalia.runAsync("xdg-open " .. shellQuote(directory) .. " >/dev/null 2>&1", function(result)
    if result.timedOut == true or tonumber(result.exitCode) ~= 0 then
      noctalia.notifyError(tr("title"), tr("panel.config_folder_failed"))
    end
  end)
  if not started then
    noctalia.notifyError(tr("title"), tr("panel.config_folder_failed"))
  end
end

function onOpenSettingsClicked()
  if creatorBusy then return end
  local started = noctalia.runAsync("noctalia msg settings-open plugins")
  if not started then
    noctalia.notifyError(tr("title"), tr("panel.settings_failed"))
  end
end

function onCloseClicked()
  if creatorBusy then return end
  panel.close()
end
