--!nonstrict
-- Overview service: reads Hyprland's monitors, workspaces and windows when the panel opens,
-- takes a small picture of each window with grim, and runs what the panel asks: focus a
-- window, switch workspace, move a window.
--
-- Hyprland takes dispatchers in Lua when its config is Lua, and in the older form
-- otherwise; dispatch() tries Lua first.
--
-- Publishes "overview.model" and takes commands on "overview.command".

local function onHyprland()
  return noctalia.getenv("HYPRLAND_INSTANCE_SIGNATURE") ~= nil and noctalia.commandExists("hyprctl")
end

local function decode(result)
  if result.exitCode ~= 0 then
    return nil
  end
  local value = noctalia.json.decode(result.stdout or "")
  return type(value) == "table" and value or nil
end

local function idOf(value)
  return type(value) == "table" and value.id or value
end

local function isNumber(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- A pair of numbers, such as a window's "at" and "size".
local function isPair(value)
  return type(value) == "table" and isNumber(value[1]) and isNumber(value[2])
end

-- Builds the model from the three hyprctl answers. Window positions are kept relative to
-- their monitor, in logical pixels. An entry without the fields it needs is left out, so one
-- odd monitor, workspace or window cannot stop the whole overview.
local function build(monitorList, workspaceList, clientList)
  local monitors, monitorById, monitorByName = {}, {}, {}
  for _, m in ipairs(monitorList) do
    if type(m) ~= "table" or type(m.name) ~= "string" or not isNumber(m.width) or not isNumber(m.height)
      or m.width <= 0 or m.height <= 0 or not isNumber(m.x) or not isNumber(m.y) then
      continue
    end
    local scale = isNumber(m.scale) and m.scale > 0 and m.scale or 1
    local width, height = m.width / scale, m.height / scale
    if m.transform == 1 or m.transform == 3 or m.transform == 5 or m.transform == 7 then
      width, height = height, width
    end
    local monitor = {
      id = m.id,
      name = m.name,
      x = m.x,
      y = m.y,
      width = width,
      height = height,
      active = idOf(m.activeWorkspace),
      focused = m.focused == true,
    }
    table.insert(monitors, monitor)
    monitorById[m.id] = monitor
    monitorByName[m.name] = monitor
  end

  local workspaces, workspaceById = {}, {}
  for _, w in ipairs(workspaceList) do
    -- Special workspaces have negative ids and live outside the usual flow.
    if type(w) == "table" and isNumber(w.id) and w.id > 0 then
      local monitor = monitorByName[w.monitor] or monitorById[w.monitorID]
      local workspace = { id = w.id, name = w.name, monitor = monitor and monitor.name or "", windows = {} }
      table.insert(workspaces, workspace)
      workspaceById[w.id] = workspace
    end
  end
  table.sort(workspaces, function(a, b) return a.id < b.id end)

  for _, c in ipairs(clientList) do
    local workspace = type(c) == "table" and workspaceById[idOf(c.workspace)]
    local monitor = workspace and monitorByName[workspace.monitor]
    if workspace and monitor and c.mapped ~= false and c.hidden ~= true and isPair(c.at) and isPair(c.size)
      and type(c.address) == "string" then
      table.insert(workspace.windows, {
        address = c.address,
        class = type(c.class) == "string" and c.class or "",
        title = type(c.title) == "string" and c.title or "",
        x = c.at[1] - monitor.x,
        y = c.at[2] - monitor.y,
        width = c.size[1],
        height = c.size[2],
        floating = c.floating == true,
        focused = c.focusHistoryID == 0,
        stableId = type(c.stableId) == "string" and c.stableId or nil,
      })
    end
  end

  return { hyprland = true, monitors = monitors, workspaces = workspaces }
end

local reading = false
local watching = false -- the panel is open
local lastPublished = nil

-- Pictures are taken at this share of the window's size: enough for a card.
local PREVIEW_SCALE = "0.25"
local previewDir = (noctalia.pluginDataDir() or "") .. "/previews"

local pictures = {} -- the last good picture of each window, by toplevel id
local icons = {} -- app icon path by window class, or false when there is none
local iconsWanted = {} -- classes still to look up
-- Looking up an icon takes a few milliseconds, and a callback has 25: each update starts
-- lookups only while it has used less than this.
local ICON_MS = 6
local capturing = false
local cleared = false -- the pictures of an earlier run are gone
local capturedFor = nil -- the windows and places the last pictures were taken for
local generation = 0

-- Gives each window its picture, and its app icon for while it has none.
local function applyPictures(model)
  for _, workspace in ipairs(model.workspaces) do
    for _, window in ipairs(workspace.windows) do
      window.preview = window.stableId and pictures[window.stableId] or nil
      if window.class ~= "" then
        if icons[window.class] == nil then
          iconsWanted[window.class] = true
        end
        window.icon = icons[window.class] or nil
      end
    end
  end
end

-- Looks up the icons of new window classes, a few at a time; the next read publishes them.
local function lookUpIcons()
  local started = os.clock()
  for class in pairs(iconsWanted) do
    if (os.clock() - started) * 1000 >= ICON_MS then
      break
    end
    iconsWanted[class] = nil
    icons[class] = noctalia.appIconPath(class, 32) or false
  end
end

-- What the pictures depend on: which windows there are, where, and on which workspace.
local function layoutKey(model)
  local parts = {}
  for _, workspace in ipairs(model.workspaces) do
    for _, window in ipairs(workspace.windows) do
      table.insert(parts, `{window.address}@{workspace.id}:{window.x},{window.y},{window.width},{window.height}`)
    end
  end
  return table.concat(parts, ";")
end

-- Takes a picture of every window, even on hidden workspaces, with grim and the window's
-- toplevel id. The old pictures stay on screen until the new ones are all there; each round
-- has new file names, so the panel never shows a cached picture.
local function capture(model)
  -- With previews off, the pictures taken so far go too, and windows show their icon.
  if noctalia.getConfig("previews") == false then
    for _, path in pairs(pictures) do
      noctalia.removeFile(path)
    end
    pictures = {}
    capturedFor = nil
    return
  end
  local key = layoutKey(model)
  if not cleared or capturing or key == capturedFor or not noctalia.commandExists("grim") then
    return
  end
  capturing = true
  generation += 1
  noctalia.mkdirAll(previewDir)
  local shots = {}
  for _, workspace in ipairs(model.workspaces) do
    for _, window in ipairs(workspace.windows) do
      if window.stableId then
        table.insert(shots, { id = window.stableId, path = `{previewDir}/{window.stableId}-{generation}.png` })
      end
    end
  end
  -- One grim at a time, so a screen full of windows does not start dozens at once.
  local taken = {}
  local function done()
    capturing = false
    capturedFor = key
    for _, path in pairs(pictures) do
      noctalia.removeFile(path)
    end
    pictures = taken
    applyPictures(model)
    lastPublished = noctalia.json.encode(model)
    noctalia.state.set("overview.model", model)
  end
  local function take(index)
    local shot = shots[index]
    if shot == nil then
      done()
      return
    end
    noctalia.runAsync({ "grim", "-T", shot.id, "-s", PREVIEW_SCALE, shot.path }, function(result)
      if result.exitCode == 0 then
        taken[shot.id] = shot.path
      end
      take(index + 1)
    end, 10000)
  end
  take(1)
end

-- Shows why the overview cannot be read, in the panel and once in Noctalia's log, instead of
-- loading forever.
local lastError = nil
local function fail(message)
  if message ~= lastError then
    lastError = message
    noctalia.log("overview could not read Hyprland: " .. message)
  end
  lastPublished = nil
  noctalia.state.set("overview.model", { hyprland = true, error = message })
end

local function refresh()
  if not onHyprland() then
    noctalia.state.set("overview.model", { hyprland = false })
    return
  end
  if reading then
    return
  end
  reading = true
  noctalia.runAsync({ "hyprctl", "-j", "monitors" }, function(monitors)
    noctalia.runAsync({ "hyprctl", "-j", "workspaces" }, function(workspaces)
      noctalia.runAsync({ "hyprctl", "-j", "clients" }, function(clients)
        reading = false
        local m, w, c = decode(monitors), decode(workspaces), decode(clients)
        if not (m and w and c) then
          fail("hyprctl did not answer with JSON")
          return
        end
        local ok, model = pcall(build, m, w, c)
        if not ok then
          fail(tostring(model))
          return
        end
        lastError = nil
        applyPictures(model)
        -- Rendered again only when something changed.
        local text = noctalia.json.encode(model)
        if text ~= lastPublished then
          lastPublished = text
          noctalia.state.set("overview.model", model)
        end
        capture(model)
      end)
    end)
  end)
end

-- lua is a dispatcher call such as `hl.dsp.focus({ workspace = "2" })`; legacy is the same
-- in the older form, as hyprctl arguments.
local function dispatch(lua, legacy, onDone)
  noctalia.runAsync({ "hyprctl", "dispatch", lua }, function(result)
    if noctalia.string.trim(result.stdout or "") == "ok" then
      if onDone then onDone() end
      return
    end
    local argv = { "hyprctl", "dispatch" }
    table.move(legacy, 1, #legacy, #argv + 1, argv)
    noctalia.runAsync(argv, function()
      if onDone then onDone() end
    end)
  end)
end

-- %q makes a quoted Lua string, so names and addresses cannot break out of it.
local function quoted(value)
  return string.format("%q", tostring(value))
end

noctalia.state.watch("overview.command", function(command)
  if type(command) ~= "table" or not onHyprland() then
    return
  end
  local action = command.action
  if action == "open" then
    watching = true
    -- Windows may show something new, so their pictures are taken again.
    capturedFor = nil
    refresh()
  elseif action == "close" then
    watching = false
  elseif action == "focus" and type(command.address) == "string" then
    local window = "address:" .. command.address
    dispatch(`hl.dsp.focus(\{ window = {quoted(window)} \})`, { "focuswindow", window })
  elseif action == "switch" and command.workspace then
    local workspace = tostring(command.workspace)
    dispatch(`hl.dsp.focus(\{ workspace = {quoted(workspace)} \})`, { "workspace", workspace })
  elseif action == "move" and type(command.address) == "string" and command.workspace then
    local window = "address:" .. command.address
    local workspace = tostring(command.workspace)
    dispatch(
      `hl.dsp.window.move(\{ workspace = {quoted(workspace)}, follow = false, window = {quoted(window)} \})`,
      { "movetoworkspacesilent", `{workspace},{window}` },
      refresh
    )
  end
end)

-- The key binding from the "keybind" setting, such as "SUPER + Tab". It is added to Hyprland
-- while Noctalia runs, never written to its config. A key that is already bound is left
-- alone, and Hyprland drops added bindings when it reloads, so update() checks it again.

local TOGGLE = "noctalia msg panel-toggle omerfuyar/overview:center"
local MODIFIERS = { SHIFT = 1, CAPS = 2, CTRL = 4, CONTROL = 4, ALT = 8, MOD2 = 16, MOD3 = 32, SUPER = 64, MOD5 = 128 }

local bound = nil -- the key this plugin bound, as written in the setting
local warned = nil

-- "SUPER + SHIFT + Tab" -> modmask 65, key "Tab", and the older form "SUPER SHIFT,Tab".
local function parseKey(text)
  local parts = {}
  for part in text:gmatch("[^+]+") do
    table.insert(parts, noctalia.string.trim(part))
  end
  local key = table.remove(parts)
  if key == nil or key == "" then
    return nil
  end
  local mask = 0
  for _, modifier in ipairs(parts) do
    local value = MODIFIERS[modifier:upper()]
    if value == nil then
      return nil
    end
    mask += value
  end
  return mask, key, table.concat(parts, " ") .. "," .. key
end

local function unbind(key)
  local _, _, legacy = parseKey(key)
  noctalia.runAsync({ "hyprctl", "eval", `hl.unbind({quoted(key)})` }, function(result)
    if noctalia.string.trim(result.stdout or "") ~= "ok" then
      noctalia.runAsync({ "hyprctl", "keyword", "unbind", legacy or key })
    end
  end)
end

local function checkBinding()
  local wanted = noctalia.string.trim(noctalia.getConfig("keybind") or "")
  if not onHyprland() then
    return
  end
  if bound and bound ~= wanted then
    unbind(bound)
    bound = nil
  end
  if wanted == "" then
    return
  end
  local mask, key, legacy = parseKey(wanted)
  if mask == nil then
    if warned ~= wanted then
      warned = wanted
      noctalia.notifyError(noctalia.tr("keybind.invalid_title"), noctalia.tr("keybind.invalid", { key = wanted }))
    end
    return
  end
  noctalia.runAsync({ "hyprctl", "-j", "binds" }, function(result)
    local binds = decode(result) or {}
    for _, bind in ipairs(binds) do
      if bind.modmask == mask and tostring(bind.key):lower() == key:lower() then
        if bound ~= wanted and warned ~= wanted then
          warned = wanted
          noctalia.notifyError(noctalia.tr("keybind.taken_title"), noctalia.tr("keybind.taken", { key = wanted }))
        end
        return
      end
    end
    -- Not bound: either never added, or dropped by a Hyprland reload.
    bound = wanted
    local command = `hl.bind({quoted(wanted)}, hl.dsp.exec_cmd({quoted(TOGGLE)}))`
    noctalia.runAsync({ "hyprctl", "eval", command }, function(lua)
      if noctalia.string.trim(lua.stdout or "") ~= "ok" then
        noctalia.runAsync({ "hyprctl", "keyword", "bind", `{legacy},exec,{TOGGLE}` })
      end
    end)
  end)
end

local lastBindingMs = 0

-- Pictures left by an earlier run are not known to this one, so they go before any is taken.
local function clearOldPictures()
  for _, name in ipairs(noctalia.listDir(previewDir) or {}) do
    if name:match("%.png$") then
      noctalia.removeFile(previewDir .. "/" .. name)
    end
  end
  cleared = true
end

function update()
  if not cleared then
    clearOldPictures()
  end
  -- While the panel is open, workspaces and windows are read again, so it follows changes.
  if watching then
    lookUpIcons()
    refresh()
  end
  if noctalia.nowMs() - lastBindingMs >= 5000 then
    lastBindingMs = noctalia.nowMs()
    checkBinding()
  end
end

function onConfigChanged()
  checkBinding()
end

function onExit()
  if bound then
    unbind(bound)
  end
end

noctalia.setUpdateInterval(1500)
-- The model of an earlier run names pictures that are about to go.
noctalia.state.set("overview.model", nil)
