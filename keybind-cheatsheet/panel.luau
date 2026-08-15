--!nonstrict
-- Snapshot-driven keybind viewer for Mango, Hyprland, and Niri.
--
-- Parsing, durable cache ownership, and refreshes live in service.luau. This
-- panel only reads the shared snapshot and renders it.

local noctalia = noctalia
local ui = ui
local panel = panel
if noctalia == nil then
  local host = require("./tests/host_mock")
  noctalia = host.noctalia
  ui = host.ui
  panel = host.panel
end

local PANEL_ID = "kenn/keybind-cheatsheet:cheatsheet"
local SNAPSHOT_KEY = "keybind-cheatsheet.snapshot"
local REFRESH_REQUEST_KEY = "keybind-cheatsheet.refresh-request"
local SELF_TEST_REQUEST_KEY = "keybind-cheatsheet.self-test-request"
local PREFERENCES_FILE = "preferences.json"

local bindings = {}
local parseWarnings = {}
local currentCompositor = ""
local loading = false
local panelOpen = false
local panelError = nil
local refreshError = nil
local snapshot = nil
local query = ""
local searchRevision = 0
local view = "bindings"
local editingId = nil
local editDraft = ""
local preferences = { version = 1, hidden = {}, descriptions = {}, colors = {} }
local refreshing = false

local render
local refresh

local env = getfenv()
local dynamicCallbacks = {}
local callbackIndex = 0

local function tr(key, values)
  return noctalia.tr(key, values)
end

local function trim(value)
  local result = (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
  return result
end

local function lower(value)
  return string.lower(value or "")
end

local function startsWith(value, prefix)
  return value:sub(1, #prefix) == prefix
end

local function resetCallbacks()
  for _, name in ipairs(dynamicCallbacks) do
    env[name] = nil
  end
  dynamicCallbacks = {}
  callbackIndex = 0
end

local function callback(prefix, fn)
  callbackIndex += 1
  local name = "keybindCheatsheet_" .. prefix .. "_" .. callbackIndex
  env[name] = fn
  table.insert(dynamicCallbacks, name)
  return name
end

local KEY_LABELS = {
  XF86AudioRaiseVolume = "Vol Up",
  XF86AudioLowerVolume = "Vol Down",
  XF86AudioMute = "Mute",
  XF86AudioMicMute = "Mic Mute",
  XF86MonBrightnessUp = "Bright Up",
  XF86MonBrightnessDown = "Bright Down",
  XF86AudioPlay = "Play/Pause",
  XF86AudioPause = "Pause",
  XF86AudioNext = "Next",
  XF86AudioPrev = "Previous",
  Print = "PrtSc",
  Prior = "PgUp",
  Next = "PgDn",
  Return = "Enter",
  Escape = "Esc",
  space = "Space",
  btn_left = "Mouse Left",
  btn_right = "Mouse Right",
  btn_middle = "Mouse Middle",
  btn_side = "Mouse Side",
  btn_extra = "Mouse Extra",
}

local function formatKey(key)
  return KEY_LABELS[key] or key:gsub("^mouse:", "Mouse ")
end

local function niriCategoryFor(action)
  local value = lower(action)
  if startsWith(value, "spawn") then return "Applications" end
  if startsWith(value, "focus-column-") then return "Column Navigation" end
  if startsWith(value, "focus-window-") then return "Window Focus" end
  if startsWith(value, "focus-workspace-") then return "Workspace Navigation" end
  if startsWith(value, "move-column-") then return "Move Columns" end
  if startsWith(value, "move-window-") then return "Move Windows" end
  if startsWith(value, "screenshot") then return "Screenshots" end
  if startsWith(value, "close-window") or startsWith(value, "fullscreen-window") then return "Window Management" end
  if startsWith(value, "power-off-monitors") then return "Power" end
  if startsWith(value, "quit") then return "System" end
  return "Other"
end


local function preferencesPath()
  local directory, err = noctalia.pluginDataDir()
  if directory == nil then
    noctalia.log("Could not resolve plugin data directory: " .. (err or "unknown error"))
    return nil
  end
  return directory .. "/" .. PREFERENCES_FILE
end

local function normalizePreferences(decoded)
  local result = { version = 1, hidden = {}, descriptions = {}, colors = {} }
  if type(decoded) ~= "table" then
    return result
  end
  for id, hidden in pairs(type(decoded.hidden) == "table" and decoded.hidden or {}) do
    if type(id) == "string" and hidden == true then
      result.hidden[id] = true
    end
  end
  for id, description in pairs(type(decoded.descriptions) == "table" and decoded.descriptions or {}) do
    if type(id) == "string" and type(description) == "string" and trim(description) ~= "" then
      result.descriptions[id] = trim(description)
    end
  end
  for bucket, colors in pairs(type(decoded.colors) == "table" and decoded.colors or {}) do
    if type(bucket) == "string" and type(colors) == "table" then
      result.colors[bucket] = {}
      if type(colors.background) == "string" then result.colors[bucket].background = colors.background end
      if type(colors.text) == "string" then result.colors[bucket].text = colors.text end
    end
  end
  return result
end

local function loadPreferences()
  local path = preferencesPath()
  if path == nil then
    preferences = normalizePreferences(nil)
    return
  end
  local raw = noctalia.readFile(path)
  if raw == nil or raw == "" then
    preferences = normalizePreferences(nil)
    return
  end
  local decoded = noctalia.json.decode(raw)
  preferences = normalizePreferences(decoded)
end

local function savePreferences()
  local path = preferencesPath()
  if path == nil then return end
  local encoded = noctalia.json.encode(preferences, true)
  if encoded == nil then return end
  local ok, err = noctalia.writeFile(path, encoded)
  if not ok then
    noctalia.notifyError(tr("title"), err or "Could not save preferences")
  end
end

local function applySnapshot(value)
  snapshot = type(value) == "table" and value or nil
  if snapshot == nil then
    bindings = {}
    parseWarnings = {}
    currentCompositor = ""
    loading = true
    refreshing = false
    panelError = nil
    refreshError = nil
    return
  end

  bindings = type(snapshot.bindings) == "table" and snapshot.bindings or {}
  parseWarnings = type(snapshot.warnings) == "table" and snapshot.warnings or {}
  currentCompositor = type(snapshot.compositor) == "string" and snapshot.compositor or ""
  refreshing = snapshot.refreshing == true
  loading = (snapshot.status == "loading" or snapshot.status == "idle") and #bindings == 0
  panelError = snapshot.status == "error" and (snapshot.error or tr("missing_config")) or nil
  refreshError = snapshot.status == "ready" and type(snapshot.error) == "string"
    and snapshot.error ~= "" and snapshot.error or nil
end

refresh = function()
  local current = tonumber(noctalia.state.get(REFRESH_REQUEST_KEY)) or 0
  refreshing = true
  noctalia.state.set(REFRESH_REQUEST_KEY, current + 1)
  render()
end


local COLOR_BUCKETS = {
  { id = "super", label = "Super", background = "primary", text = "on_primary", picker = "#6750A4" },
  { id = "ctrl", label = "Ctrl", background = "secondary", text = "on_secondary", picker = "#625B71" },
  { id = "shift", label = "Shift", background = "tertiary", text = "on_tertiary", picker = "#7D5260" },
  { id = "alt", label = "Alt", background = "error", text = "on_error", picker = "#B3261E" },
  { id = "xf86", label = "Media", background = "secondary/0.25", text = "secondary", picker = "#E8DEF8" },
  { id = "number", label = "Numbers", background = "tertiary/0.25", text = "tertiary", picker = "#FFD8E4" },
  { id = "mouse", label = "Mouse", background = "error/0.2", text = "error", picker = "#F9DEDC" },
  { id = "print", label = "Print", background = "primary/0.25", text = "primary", picker = "#EADDFF" },
  { id = "default", label = "Other keys", background = "surface_variant", text = "on_surface_variant", picker = "#E7E0EC" },
  { id = "description", label = "Descriptions", background = "surface", text = "on_surface", picker = "#1D1B20" },
}

local COLOR_BY_ID = {}
for _, bucket in ipairs(COLOR_BUCKETS) do COLOR_BY_ID[bucket.id] = bucket end

local function colorValue(bucketId, property)
  local custom = preferences.colors[bucketId]
  if custom ~= nil and custom[property] ~= nil then
    return custom[property]
  end
  local bucket = COLOR_BY_ID[bucketId] or COLOR_BY_ID.default
  return bucket[property]
end

local function bucketForKey(key)
  local value = lower(key)
  if startsWith(value, "xf86") then return "xf86" end
  if value:match("^%d$") then return "number" end
  if startsWith(value, "mouse") or startsWith(value, "btn_") or value:find("wheel", 1, true) ~= nil then return "mouse" end
  if value == "print" or value == "prior" or value == "next" then return "print" end
  return "default"
end

local function bucketForModifier(modifier)
  local value = lower(modifier)
  if value == "super" or value == "mod4" or value == "logo" then return "super" end
  if value == "ctrl" or value == "control" then return "ctrl" end
  if value == "shift" then return "shift" end
  if value == "alt" or value == "mod1" then return "alt" end
  return "default"
end

local function isHexColor(value)
  if type(value) ~= "string" then return false end
  return value:match("^#%x%x%x%x%x%x$") ~= nil or value:match("^#%x%x%x%x%x%x%x%x$") ~= nil
end

local function setColor(bucketId, property, value)
  preferences.colors[bucketId] = preferences.colors[bucketId] or {}
  preferences.colors[bucketId][property] = value
  savePreferences()
  render()
end

local function chooseColor(bucketId, property)
  local bucket = COLOR_BY_ID[bucketId] or COLOR_BY_ID.default
  local current = colorValue(bucketId, property)
  local initial = isHexColor(current) and current:sub(1, 7) or bucket.picker
  noctalia.openColorPicker(initial, function(color)
    if color ~= nil then
      setColor(bucketId, property, color)
    end
  end)
end

local function pasteColor(bucketId, property)
  local value = trim(noctalia.clipboardText() or "")
  if isHexColor(value) then
    setColor(bucketId, property, string.upper(value))
  else
    noctalia.notifyError(tr("title"), "Clipboard does not contain a #RRGGBB color")
  end
end

local function bindingContentOpacity(hidden)
  return hidden and 0.45 or 1
end

local function keyPill(text, bucketId, key)
  return ui.column({
    key = key,
    fill = colorValue(bucketId, "background"),
    radius = 4,
    paddingH = 7,
    paddingV = 3,
    align = "center",
  }, {
    ui.label({ text = text, color = colorValue(bucketId, "text"), fontSize = 12, fontWeight = "bold", maxLines = 1 }),
  })
end

local function authoredDescription(binding)
  return preferences.descriptions[binding.id] or binding.description or ""
end

local function titleCase(value)
  value = trim(value):gsub("[_%-]+", " ")
  return (value:gsub("(%a)([%w']*)", function(first, rest)
    return string.upper(first) .. lower(rest)
  end))
end

local function friendlySpawn(commandLine)
  local value = lower(trim(commandLine))
  if value:find("noctalia msg panel-toggle launcher", 1, true) ~= nil then return "Application Launcher" end
  if value:find("noctalia msg panel-toggle session", 1, true) ~= nil then return "Power Menu" end
  if value:find("noctalia msg session lock", 1, true) ~= nil then return "Lock Screen" end
  if value:find("playerctl play-pause", 1, true) ~= nil then return "Play / Pause" end
  if value:find("playerctl next", 1, true) ~= nil then return "Next Track" end
  if value:find("playerctl previous", 1, true) ~= nil then return "Previous Track" end
  if value:find("playerctl stop", 1, true) ~= nil then return "Stop Playback" end
  if value:find("wpctl set-volume", 1, true) ~= nil then
    return value:find("+", 1, true) ~= nil and "Volume Up" or "Volume Down"
  end
  if value:find("wpctl set-mute", 1, true) ~= nil then
    return value:find("source", 1, true) ~= nil and "Toggle Microphone Mute" or "Toggle Mute"
  end
  if value:find("brightnessctl", 1, true) ~= nil then
    return value:find("+", 1, true) ~= nil and "Brightness Up" or "Brightness Down"
  end

  local program = trim(commandLine):match("^([^%s]+)") or "Application"
  program = program:match("([^/]+)$") or program
  local programs = {
    alacritty = "Terminal",
    chromium = "Browser",
    dolphin = "File Manager",
    firefox = "Browser",
    foot = "Terminal",
    kitty = "Terminal",
    nautilus = "File Manager",
    thunar = "File Manager",
  }
  return programs[lower(program)] or ("Launch " .. titleCase(program))
end

local ACTION_LABELS = {
  close_window = "Close Window",
  killactive = "Close Window",
  killclient = "Close Window",
  minimized = "Minimize Window",
  quit = "Exit Compositor",
  reload_config = "Reload Configuration",
  restore_minimized = "Restore Minimized Window",
  switch_proportion_preset = "Cycle Width Preset",
  toggle_named_scratchpad = "Toggle Scratchpad",
  togglefakefullscreen = "Toggle Fake Fullscreen",
  togglefloating = "Toggle Floating",
  togglefullscreen = "Toggle Fullscreen",
  togglegaps = "Toggle Gaps",
  toggleglobal = "Toggle Global Window",
  togglemaximizescreen = "Toggle Maximize",
  toggleoverlay = "Toggle Overlay",
  toggleoverview = "Workspace Overview",
}

local function friendlyAction(binding)
  local action = trim(binding.action)
  local command, arguments = action:match("^(%S+)%s*(.*)$")
  command = lower(command or ""):gsub("%-", "_")
  arguments = trim(arguments or "")
  if command == "spawn" or command == "spawn_shell" or command == "exec" then
    return friendlySpawn(arguments)
  end
  if ACTION_LABELS[command] ~= nil then return ACTION_LABELS[command] end

  local argument = arguments:match("^([^,%s]+)") or ""
  local direction = argument ~= "" and titleCase(argument) or ""
  if command == "focusdir" or command == "movefocus" then return "Focus " .. direction end
  if command == "exchange_client" or command == "movewindow" then return "Move Window " .. direction end
  if command == "focusmon" then return "Focus Monitor " .. direction end
  if command == "tagmon" then return "Move to Monitor " .. direction end
  if command == "scroller_stack" then return "Move Within Stack " .. direction end
  if command == "view" or command == "workspace" then return "Workspace " .. argument end
  if command == "tag" or command == "movetoworkspace" then return "Send to Workspace " .. argument end
  if command == "viewtoleft" or command == "viewtoleft_have_client" then return "Previous Workspace" end
  if command == "viewtoright" or command == "viewtoright_have_client" then return "Next Workspace" end
  if command == "setlayout" then return titleCase(argument) .. " Layout" end
  if command == "set_proportion" then return "Set Window Proportion " .. argument end
  if command == "setmfact" then return "Set Layout Size " .. argument end
  if command == "moveresize" then
    return arguments:find("curresize", 1, true) ~= nil and "Resize Window with Mouse" or "Move Window with Mouse"
  end
  return titleCase(action)
end

local function effectiveDescription(binding)
  local description = authoredDescription(binding)
  return description ~= "" and description or friendlyAction(binding)
end

local function effectiveCategory(binding)
  if binding.baseCategory ~= nil and binding.baseCategory ~= "" then
    return binding.baseCategory
  end
  if authoredDescription(binding) == "" and binding.compositor ~= "niri" then
    return tr("without_description")
  end
  return binding.compositor == "niri" and niriCategoryFor(binding.action) or tr("other")
end

local function bindingMatches(binding)
  local needle = lower(trim(query))
  if needle == "" then return true end
  local haystack = lower(table.concat({
    table.concat(binding.modifiers, " "),
    binding.key,
    formatKey(binding.key),
    effectiveDescription(binding),
    binding.action,
    effectiveCategory(binding),
  }, " "))
  return haystack:find(needle, 1, true) ~= nil
end

local CATEGORY_PRIORITIES = {
  { "applications", 10 },
  { "system", 20 },
  { "window management", 30 },
  { "focus", 40 },
  { "navigation", 40 },
  { "moving windows", 45 },
  { "workspace", 50 },
  { "tags", 50 },
  { "monitor", 50 },
  { "media", 60 },
  { "brightness", 60 },
  { "layout", 70 },
  { "mouse", 80 },
  { "touchpad", 90 },
  { "gesture", 90 },
  { "integration", 100 },
  { lower(tr("without_description")), 900 },
  { lower(tr("other")), 950 },
}

local function categoryPriority(name)
  local value = lower(name)
  for _, entry in ipairs(CATEGORY_PRIORITIES) do
    if value:find(entry[1], 1, true) ~= nil then return entry[2] end
  end
  return 500
end

local function bindingAvailableInView(hidden, undescribed, managing, showUndescribed)
  if managing then return true end
  return not hidden and (showUndescribed or not undescribed)
end

local function hiddenBindingCount(bindingList, hiddenPreferences)
  local currentIds = {}
  for _, binding in ipairs(bindingList or {}) do
    currentIds[binding.id] = true
  end
  local count = 0
  for id in pairs(currentIds) do
    if hiddenPreferences[id] == true then count += 1 end
  end
  return count
end

local function restoreHiddenBindings(bindingList, hiddenPreferences)
  for _, binding in ipairs(bindingList or {}) do
    hiddenPreferences[binding.id] = nil
  end
end

local function visibleGroups()
  local showUndescribed = noctalia.getConfig("show_undescribed") ~= false
  local managing = view == "edit"
  local groups = {}
  local byName = {}
  for index, binding in ipairs(bindings) do
    local hidden = preferences.hidden[binding.id] == true
    local undescribed = authoredDescription(binding) == "" and binding.compositor ~= "niri"
    if bindingAvailableInView(hidden, undescribed, managing, showUndescribed) and bindingMatches(binding) then
      local category = effectiveCategory(binding)
      local group = byName[category]
      if group == nil then
        group = { name = category, bindings = {}, sourceOrder = #groups + 1, order = 0, weight = 1 }
        byName[category] = group
        table.insert(groups, group)
      end
      binding.displayIndex = index
      table.insert(group.bindings, binding)
      group.weight += 1
    end
  end
  table.sort(groups, function(a, b)
    local left = categoryPriority(a.name)
    local right = categoryPriority(b.name)
    if left ~= right then return left < right end
    return a.sourceOrder < b.sourceOrder
  end)
  for index, group in ipairs(groups) do group.order = index end
  return groups
end

local function columnCount()
  local configured = math.clamp(tonumber(noctalia.getConfig("columns")) or 3, 1, 4)
  local outputWidth = 1920
  local focused = noctalia.focusedOutputName()
  for _, output in ipairs(noctalia.outputs()) do
    if output.name == focused or output.focused then
      outputWidth = output.width / math.max(output.scale or 1, 1)
      break
    end
  end
  local responsive = outputWidth < 760 and 1 or (outputWidth < 1100 and 2 or (outputWidth < 1500 and 3 or 4))
  return math.min(configured, responsive)
end

local function balancedColumns(groups, count)
  local columns = {}
  for index = 1, count do columns[index] = { groups = {}, weight = 0 } end
  for _, group in ipairs(groups) do
    local target = 1
    for index = 2, count do
      if columns[index].weight < columns[target].weight then target = index end
    end
    table.insert(columns[target].groups, group)
    columns[target].weight += group.weight
  end
  for _, column in ipairs(columns) do
    table.sort(column.groups, function(a, b) return a.order < b.order end)
  end
  return columns
end

local function saveCustomDescription(binding, value)
  value = trim(value)
  if value == "" or value == binding.description then
    preferences.descriptions[binding.id] = nil
  else
    preferences.descriptions[binding.id] = value
  end
  editingId = nil
  editDraft = ""
  savePreferences()
  render()
end

local function bindingRow(binding, occurrence)
  local hidden = preferences.hidden[binding.id] == true
  local contentOpacity = bindingContentOpacity(hidden)
  local pills = {}
  for index, modifier in ipairs(binding.modifiers) do
    table.insert(pills, keyPill(modifier == "SUPER" and "Super" or modifier:sub(1, 1) .. lower(modifier:sub(2)), bucketForModifier(modifier), "mod-" .. index))
  end
  table.insert(pills, keyPill(formatKey(binding.key), bucketForKey(binding.key), "key"))

  local description = effectiveDescription(binding)
  local identity = binding.id .. "#" .. occurrence
  if view == "edit" and editingId == identity then
    local visibilityChanged = callback("visibility", function()
      if hidden then
        preferences.hidden[binding.id] = nil
      else
        preferences.hidden[binding.id] = true
      end
      savePreferences()
      render()
    end)
    local inputChanged = callback("editChange", function(value) editDraft = value end)
    local submit = callback("editSubmit", function(value) saveCustomDescription(binding, value) end)
    local save = callback("editSave", function() saveCustomDescription(binding, editDraft) end)
    local cancel = callback("editCancel", function()
      editingId = nil
      editDraft = ""
      render()
    end)
    return ui.row({ key = "edit-" .. identity, gap = 6, align = "center", paddingV = 0 }, {
      ui.row({ minWidth = 188, gap = 3, align = "center", opacity = contentOpacity }, pills),
      ui.input({ key = "description-" .. identity, value = editDraft, placeholder = tr("edit_description"), focus = true, controlSize = "sm", flexGrow = 1, onChange = inputChanged, onSubmit = submit }),
      ui.button({ glyph = "check", width = 22, height = 22, glyphSize = 12, variant = "ghost", controlSize = "sm", tooltip = tr("save"), onClick = save }),
      ui.button({ glyph = "close", width = 22, height = 22, glyphSize = 12, variant = "ghost", controlSize = "sm", tooltip = tr("cancel"), onClick = cancel }),
      ui.button({ glyph = hidden and "eye-off" or "eye", width = 22, height = 22, glyphSize = 13, variant = "ghost", controlSize = "sm", selected = hidden, tooltip = hidden and tr("show_binding") or tr("hide_binding"), onClick = visibilityChanged }),
    })
  end

  local labels = {
    ui.label({
      text = description,
      color = colorValue("description", "text"),
      fontWeight = "bold",
      fontSize = 13,
      maxLines = 1,
    }),
  }
  if noctalia.getConfig("show_actions") ~= false and description ~= "" and binding.action ~= "" then
    table.insert(labels, ui.label({ text = binding.action, color = "on_surface_variant", fontSize = 11, maxLines = 1 }))
  end
  local row = {
    ui.row({ minWidth = 188, gap = 3, align = "center", opacity = contentOpacity }, pills),
    ui.column({ flexGrow = 1, gap = 0, opacity = contentOpacity }, labels),
  }
  if view == "edit" then
    local edit = callback("edit", function()
      editingId = identity
      editDraft = description
      render()
    end)
    local visibilityChanged = callback("visibility", function()
      if hidden then
        preferences.hidden[binding.id] = nil
      else
        preferences.hidden[binding.id] = true
      end
      savePreferences()
      render()
    end)
    table.insert(row, ui.button({ glyph = "pencil", width = 22, height = 22, glyphSize = 12, variant = "ghost", controlSize = "sm", tooltip = tr("edit_description"), onClick = edit }))
    table.insert(row, ui.button({ glyph = hidden and "eye-off" or "eye", width = 22, height = 22, glyphSize = 13, variant = "ghost", controlSize = "sm", selected = hidden, tooltip = hidden and tr("show_binding") or tr("hide_binding"), onClick = visibilityChanged }))
  end
  return ui.row({ key = identity, gap = 6, align = "center", paddingV = 0 }, row)
end

local function categoryNode(group)
  local children = {
    ui.label({ text = string.upper(group.name), color = "primary", fontSize = 14, fontWeight = "bold" }),
    ui.separator({ color = "outline", thickness = 1, spacing = 1 }),
  }
  local occurrences = {}
  for _, binding in ipairs(group.bindings) do
    occurrences[binding.id] = (occurrences[binding.id] or 0) + 1
    table.insert(children, bindingRow(binding, occurrences[binding.id]))
  end
  return ui.column({ key = "category-" .. group.name, gap = 1, paddingV = 3, align = "stretch" }, children)
end

local function bindingsBody()
  local groups = visibleGroups()
  if #groups == 0 then
    return ui.column({ flexGrow = 1, align = "center", justify = "center" }, {
      ui.glyph({ name = "search-off", size = 32, color = "on_surface_variant" }),
      ui.label({ text = tr("no_results"), color = "on_surface_variant" }),
    })
  end
  local columns = balancedColumns(groups, columnCount())
  local columnNodes = {}
  for index, column in ipairs(columns) do
    local categoryNodes = {}
    for _, group in ipairs(column.groups) do table.insert(categoryNodes, categoryNode(group)) end
    table.insert(columnNodes, ui.column({ key = "column-" .. index, flexGrow = 1, gap = 8, align = "stretch" }, categoryNodes))
  end
  return ui.scroll({ flexGrow = 1, gap = 0 }, {
    ui.row({ key = "binding-columns", gap = 22, align = "stretch" }, columnNodes),
  })
end

local function hiddenCount()
  return hiddenBindingCount(bindings, preferences.hidden)
end

local function colorControl(bucket, property)
  local choose = callback("chooseColor", function() chooseColor(bucket.id, property) end)
  local paste = callback("pasteColor", function() pasteColor(bucket.id, property) end)
  local reset = callback("resetColor", function()
    if preferences.colors[bucket.id] ~= nil then
      preferences.colors[bucket.id][property] = nil
      if next(preferences.colors[bucket.id]) == nil then preferences.colors[bucket.id] = nil end
      savePreferences()
      render()
    end
  end)
  return ui.row({ gap = 5, align = "center", flexGrow = 1 }, {
    ui.box({ width = 24, height = 24, radius = 5, fill = colorValue(bucket.id, property), border = "outline", borderWidth = 1 }),
    ui.button({ text = property == "background" and tr("background") or tr("text"), variant = "ghost", controlSize = "sm", flexGrow = 1, onClick = choose }),
    ui.button({ glyph = "clipboard", variant = "ghost", controlSize = "sm", tooltip = tr("paste"), onClick = paste }),
    ui.button({ glyph = "restore", variant = "ghost", controlSize = "sm", tooltip = tr("reset"), onClick = reset }),
  })
end

local function appearanceBody()
  local rows = {
    ui.label({ text = tr("customize_colors"), color = "on_surface_variant" }),
  }
  for _, bucket in ipairs(COLOR_BUCKETS) do
    table.insert(rows, ui.column({ key = "color-" .. bucket.id, gap = 5, paddingV = 4 }, {
      ui.label({ text = bucket.label, fontWeight = "medium" }),
      ui.row({ gap = 12, align = "center" }, {
        colorControl(bucket, "background"),
        colorControl(bucket, "text"),
      }),
    }))
  end
  local resetAll = callback("resetAllColors", function()
    preferences.colors = {}
    savePreferences()
    render()
  end)
  table.insert(rows, ui.separator({ spacing = 6 }))
  table.insert(rows, ui.row({ gap = 8, align = "center" }, {
    ui.button({ glyph = "restore", text = tr("reset_colors"), onClick = resetAll }),
  }))
  return ui.scroll({ flexGrow = 1, gap = 4 }, rows)
end

local function renderHeader()
  local refreshClick = callback("refresh", function() refresh() end)
  local editMode = callback("editMode", function()
    view = view == "edit" and "bindings" or "edit"
    editingId = nil
    editDraft = ""
    render()
  end)
  local appearance = callback("appearance", function()
    view = view == "appearance" and "bindings" or "appearance"
    editingId = nil
    editDraft = ""
    render()
  end)
  local title = tr("title")
  if currentCompositor ~= "" then
    title = (currentCompositor == "mango" and "Mango" or (currentCompositor == "niri" and "Niri" or "Hyprland")) .. " Keymap"
  end
  local children = {
    ui.row({ minWidth = 230, gap = 7, align = "center", flexGrow = 1 }, {
      ui.glyph({ name = "keyboard", size = 16, color = "primary" }),
      ui.label({ text = title, fontSize = 15, fontWeight = "bold", color = "on_surface" }),
    }),
  }
  if (view == "bindings" or view == "edit") and not loading and panelError == nil then
    local searchChanged = callback("search", function(value)
      query = value
      editingId = nil
      render()
    end)
    local clearSearch = callback("clearSearch", function()
      query = ""
      searchRevision += 1
      render()
    end)
    table.insert(children, ui.input({ key = "search-" .. searchRevision, value = query, placeholder = tr("search_placeholder"), controlSize = "sm", width = 300, onChange = searchChanged }))
    table.insert(children, ui.button({ glyph = "x", width = 26, variant = "ghost", controlSize = "sm", enabled = query ~= "", tooltip = tr("clear"), onClick = clearSearch }))
  end
  if not loading or #bindings > 0 then
    table.insert(children, ui.label({ text = tr("binding_count", { count = #bindings }), color = "on_surface_variant", fontSize = 12 }))
  end
  if view == "edit" then
    local count = hiddenCount()
    local restoreHidden = callback("restoreHidden", function()
      restoreHiddenBindings(bindings, preferences.hidden)
      savePreferences()
      render()
    end)
    table.insert(children, ui.label({ text = tr("hidden_count", { count = count }), color = "on_surface_variant", fontSize = 12 }))
    table.insert(children, ui.button({ glyph = "eye", variant = "ghost", controlSize = "sm", enabled = count > 0, tooltip = tr("restore_hidden"), onClick = restoreHidden }))
  end
  table.insert(children, ui.button({ glyph = "refresh", variant = "ghost", tooltip = tr("refresh"), enabled = not refreshing, onClick = refreshClick }))
  table.insert(children, ui.button({ glyph = view == "edit" and "check" or "pencil", variant = "ghost", tooltip = view == "edit" and tr("finish_editing") or tr("edit_bindings"), selected = view == "edit", onClick = editMode }))
  table.insert(children, ui.button({ glyph = view == "appearance" and "check" or "palette", variant = "ghost", tooltip = view == "appearance" and tr("back") or tr("appearance"), selected = view == "appearance", onClick = appearance }))
  return ui.row({ align = "center", justify = "space_between", gap = 7 }, children)
end

render = function()
  if not panelOpen then return end
  resetCallbacks()
  local contentState = "bindings"
  if view == "appearance" then
    contentState = "appearance"
  elseif loading then
    contentState = "loading"
  elseif panelError ~= nil then
    contentState = "error"
  elseif view == "edit" then
    contentState = "edit"
  end
  local children = { renderHeader() }
  if view == "appearance" then
    table.insert(children, appearanceBody())
  elseif loading then
    table.insert(children, ui.column({ flexGrow = 1, align = "center", justify = "center", gap = 10 }, {
      ui.glyph({ name = "loader", size = 32, color = "primary" }),
      ui.label({ text = tr("loading"), color = "on_surface_variant" }),
    }))
  elseif panelError ~= nil then
    table.insert(children, ui.column({ flexGrow = 1, align = "center", justify = "center", gap = 10 }, {
      ui.glyph({ name = "alert-triangle", size = 32, color = "error" }),
      ui.label({ text = panelError, color = "error", textAlign = "center", maxWidth = 640 }),
    }))
  else
    if refreshError ~= nil then
      table.insert(children, ui.label({ text = refreshError, color = "error", fontSize = 11, maxLines = 2 }))
    end
    if #parseWarnings > 0 then
      table.insert(children, ui.label({ text = tr("source_warning") .. " " .. table.concat(parseWarnings, " | "), color = "error", fontSize = 11, maxLines = 2 }))
    end
    table.insert(children, bindingsBody())
  end
  panel.render(ui.column({ key = "keybind-cheatsheet-" .. contentState, flexGrow = 1, gap = 8, align = "stretch" }, children))
end

noctalia.state.watch(SNAPSHOT_KEY, function(value)
  applySnapshot(value)
  if panelOpen then render() end
end)

local function releasePanelState(clearModel)
  panelOpen = false
  view = "bindings"
  query = ""
  editingId = nil
  editDraft = ""
  resetCallbacks()
  if clearModel then
    bindings = {}
    parseWarnings = {}
    currentCompositor = ""
    loading = false
    refreshing = false
    panelError = nil
    refreshError = nil
    snapshot = nil
  end
end

function onOpen(_context)
  panelOpen = true
  view = "bindings"
  query = ""
  searchRevision += 1
  editingId = nil
  editDraft = ""
  loadPreferences()
  applySnapshot(noctalia.state.get(SNAPSHOT_KEY))
  render()
end

function onClose()
  releasePanelState(false)
end

function onExit(_signal)
  releasePanelState(true)
end

function onConfigChanged()
  if panelOpen then render() end
end

function onIpc(event, _payload)
  if event == "toggle" then
    if panelOpen then panel.close() else noctalia.togglePanel(PANEL_ID) end
  elseif event == "refresh" then
    refresh()
  elseif event == "self-test" then
    local current = tonumber(noctalia.state.get(SELF_TEST_REQUEST_KEY)) or 0
    noctalia.state.set(SELF_TEST_REQUEST_KEY, current + 1)
  end
end

local function lifecycleState()
  return {
    panelOpen = panelOpen,
    loading = loading,
    refreshing = refreshing,
    bindingCount = #bindings,
    snapshotLoaded = snapshot ~= nil,
    callbackCount = #dynamicCallbacks,
    editDraft = editDraft,
  }
end

return {
  bindingAvailableInView = bindingAvailableInView,
  bindingContentOpacity = bindingContentOpacity,
  hiddenBindingCount = hiddenBindingCount,
  restoreHiddenBindings = restoreHiddenBindings,
  categoryPriority = categoryPriority,
  friendlyAction = friendlyAction,
  applySnapshot = applySnapshot,
  onOpen = onOpen,
  onClose = onClose,
  onExit = onExit,
  onIpc = onIpc,
  lifecycleState = lifecycleState,
}
