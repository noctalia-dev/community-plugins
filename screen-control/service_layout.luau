--!nonstrict
-- Screen Control layout service: reads the screens, keeps a layout for each set of connected
-- screens in its data file, and applies it while Noctalia runs: on start, when screens
-- change, and when something else, such as a Hyprland reload, changes them back
-- (DESIGN.md, section 10.9). A change that can leave a screen dark waits to be kept.
-- Publishes "screen-control.layout" and takes actions on "screen-control.layout-command".

local Hyprland = require("./lib/hyprland.luau")
local Layout = require("./lib/layout.luau")

local POLL_MS = 3000
local SETTLE_MS = 1500

local data = { profiles = {}, ruled = {} } -- ruled: workspace id -> its rule before this plugin moved it, or false
local dataPath = nil
local live = nil -- the screens as Hyprland reports them
local key = nil -- the set of connected screens
local layout = nil -- the screens as they should be
local pending = nil -- { untilMs, previous } while "Keep this layout?" waits
local original = nil -- the layout before the first change of a set without a profile
local applying = false
local settleAtMs = nil
local seen = nil -- the screens' signature after the last apply or read
local lastPollMs = 0
local errorText = nil
local errors = {} -- screen id -> problem with what was typed
local lastCommand = nil

local function fieldsOf(screens)
  local fields = {}
  for _, screen in ipairs(screens) do
    local item = {}
    for _, name in ipairs(Layout.FIELDS) do
      item[name] = screen[name]
    end
    fields[screen.id] = item
  end
  return fields
end

-- The live screens with what <fields> remembers of each.
local function merged(fields)
  local screens = Layout.copy(live)
  for _, screen in ipairs(screens) do
    for name, value in pairs(fields and fields[screen.id] or {}) do
      screen[name] = value
    end
  end
  return screens
end

local function save()
  if not dataPath then
    return
  end
  local text = noctalia.json.encode(data, true)
  local temp = dataPath .. ".tmp"
  if text and noctalia.writeFile(temp, text) then
    noctalia.renameFile(temp, dataPath)
  end
end

local function load()
  local dir = noctalia.pluginDataDir()
  if not dir then
    return
  end
  dataPath = dir .. "/layouts.json"
  local text = noctalia.readFile(dataPath)
  local decoded = text and noctalia.json.decode(text)
  if type(decoded) == "table" then
    data.profiles = type(decoded.profiles) == "table" and decoded.profiles or {}
    -- An empty object reads back as a list.
    data.ruled = type(decoded.ruled) == "table" and #decoded.ruled == 0 and decoded.ruled or {}
  end
end

local function keepSeconds()
  return math.max(5, tonumber(noctalia.getConfig("keep_seconds")) or 15)
end

local function publish()
  noctalia.state.set("screen-control.layout", {
    ready = layout ~= nil,
    screens = layout or {},
    remembered = key ~= nil and data.profiles[key] ~= nil,
    pending = pending and math.max(0, math.ceil((pending.untilMs - noctalia.nowMs()) / 1000)) or nil,
    error = errorText,
    errors = errors,
  })
end

local function apply(screens)
  applying = true
  Hyprland.apply(screens, data.ruled, function(ok, message, ruled)
    applying = false
    errorText = not ok and (message and message ~= "" and message or noctalia.tr("layout.apply_failed")) or nil
    if ok then
      data.ruled = ruled
      save()
    end
    settleAtMs = noctalia.nowMs() + SETTLE_MS
    publish()
  end)
end

local function saveProfile()
  local profile = data.profiles[key] or {}
  profile.original = profile.original or original
  profile.screens = fieldsOf(layout)
  data.profiles[key] = profile
  original = nil
  save()
end

local function onRead(screens, settling)
  live = screens
  local newKey = Layout.key(screens)
  if newKey ~= key then
    key = newKey
    pending, original = nil, nil
    local profile = data.profiles[key]
    layout = merged(profile and profile.screens)
    seen = nil
    if profile then
      apply(layout)
    else
      seen = Layout.signature(live)
    end
    publish()
    return
  end
  local signature = Layout.signature(live)
  local profile = data.profiles[key]
  if settling or seen == nil then
    seen = signature
    if not pending then
      layout = merged(profile and profile.screens)
    end
  elseif signature ~= seen then
    if profile and not pending then
      -- Something else, such as a reload of Hyprland's config, changed the screens.
      layout = merged(profile.screens)
      apply(layout)
    elseif not pending then
      layout = merged(nil)
      seen = signature
    end
  end
  publish()
end

local function refresh(settling)
  Hyprland.read(function(screens, message)
    if not screens then
      errorText = message
      publish()
      return
    end
    if not applying then
      onRead(screens, settling)
    end
  end)
end

-- Applies <screens> in place of the layout. A change that can leave a screen dark waits to
-- be kept; any other is remembered at once, unless one is already waiting.
local function change(screens, risky)
  if not data.profiles[key] and not original then
    original = fieldsOf(layout)
  end
  if risky then
    pending = pending or { previous = Layout.copy(layout) }
    pending.untilMs = noctalia.nowMs() + keepSeconds() * 1000
  end
  layout = screens
  if not pending then
    saveProfile()
  end
  apply(layout)
  publish()
end

local function keep()
  if pending then
    pending = nil
    saveProfile()
    publish()
  end
end

local function undo()
  if pending then
    layout = pending.previous
    pending = nil
    apply(layout)
    publish()
  end
end

local function reset()
  local profile = data.profiles[key]
  pending = nil
  if profile then
    data.profiles[key] = nil
    save()
    if profile.original then
      layout = merged(profile.original)
      apply(layout)
    end
  end
  original = nil
  publish()
end

local function set(command)
  local screens = Layout.copy(layout)
  local screen = Layout.find(screens, command.id)
  if not screen then
    return
  end
  local field, value = command.field, command.value
  errors[command.id] = nil
  if field == "workspaces" then
    value = noctalia.string.trim(tostring(value))
    if not Hyprland.workspaceIds(value) then
      errors[command.id] = noctalia.tr("layout.workspaces_invalid")
      publish()
      return
    end
  elseif field == "enabled" and value == false and Layout.enabledCount(screens) <= 1 then
    return
  end
  screen[field] = value
  if field == "enabled" and value == false then
    -- Screens that mirrored this one show their own picture again.
    for _, other in ipairs(screens) do
      if other.mirror == screen.id then
        other.mirror = ""
      end
    end
  end
  change(screens, Layout.risky(field))
end

noctalia.state.watch("screen-control.layout-command", function(command)
  if type(command) ~= "table" or command.n == lastCommand or layout == nil then
    return
  end
  lastCommand = command.n
  if command.action == "set" then
    set(command)
  elseif command.action == "move" then
    local screens = Layout.copy(layout)
    if Layout.place(screens, command.id, command.target, command.edge, command.align) then
      change(screens, false)
    end
  elseif command.action == "keep" then
    keep()
  elseif command.action == "undo" then
    undo()
  elseif command.action == "reset" then
    reset()
  end
end)

load()
refresh(false)

function update()
  noctalia.setUpdateInterval(1000)
  local now = noctalia.nowMs()
  if pending then
    if now >= pending.untilMs then
      undo()
    else
      publish()
    end
  end
  if settleAtMs and now >= settleAtMs and not applying then
    settleAtMs = nil
    refresh(true)
  elseif not applying and now - lastPollMs >= POLL_MS then
    lastPollMs = now
    refresh(false)
  end
end

function onOutputsChanged()
  if not applying then
    refresh(false)
  end
end

-- Turned off or removed, the plugin puts the screens back as they were before its first
-- change, and takes out its workspace rules, so Hyprland's own settings apply again.
function onExit(_, reason)
  if reason ~= "disable" and reason ~= "uninstall" or not live then
    return
  end
  local profile = key and data.profiles[key]
  Hyprland.applyNow(merged(profile and profile.original or fieldsOf(live)), data.ruled)
end

-- noctalia msg plugin omerfuyar/screen-control:layout all apply|keep|undo
function onIpc(event)
  if event == "apply" and layout then
    apply(layout)
  elseif event == "keep" then
    keep()
  elseif event == "undo" then
    undo()
  end
end
