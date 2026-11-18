--!nonstrict
-- Plugin's own store.
--
-- The widget list (name, command, layout and thumbnail) lives in
-- `store.json`, inside the plugin data directory. On load, built-in defaults
-- are merged and deletions are remembered in `removed`:
--
--   defaults  ⊕  store  −  removed
--
-- This way a widget can be added without losing the existing ones, and the
-- built-in ones can also be deleted. Noctalia settings are not involved.
--
-- The same file stores the brain memory: the toggle (`brain`) and the
-- geometries remembered per window class (`brainGeometry`). Since they are
-- written from different places (the widget list, the toggle, the geometry
-- when leaving edit mode), every write reads the disk and overwrites only its
-- own keys: nobody loses what another one saved.

local util = require("./util.luau")

local M = {}

local function emptyStore()
  return {
    commands = {},
    layouts = {},
    thumbs = {},
    removed = {},
    brain = false,
    brainGeometry = {},
  }
end

function M.path()
  local dir = noctalia.pluginDataDir()
  if dir == nil then
    return nil
  end
  return dir .. "/store.json"
end

-- Atomic write: no reader can see a half-written file.
local function writeStore(store)
  local path = M.path()
  if path == nil then return false, "no data directory" end
  local ok, encoded = pcall(noctalia.json.encode, store, true)
  if not ok or type(encoded) ~= "string" then return false, "could not encode the store" end
  local tmp = path .. ".tmp"
  local wrote = noctalia.writeFile(tmp, encoded)
  if wrote ~= true then return false, "could not write " .. tmp end
  if noctalia.renameFile ~= nil then
    local renamed = noctalia.renameFile(tmp, path)
    if renamed ~= true then return false, "could not rename " .. path end
  end
  return true
end

function M.load()
  local store = emptyStore()
  local path = M.path()
  if path == nil then
    return store
  end

  local raw = noctalia.readFile(path)
  if raw == nil or raw == "" then
    return store
  end

  local ok, decoded = pcall(noctalia.json.decode, raw)
  if not ok or type(decoded) ~= "table" then
    noctalia.log("terminal-widgets: store.json unreadable, starting from scratch")
    return store
  end

  if type(decoded.commands) == "table" then
    for key, value in pairs(decoded.commands) do
      if type(value) == "string" then
        store.commands[key] = value
      end
    end
  end
  if type(decoded.layouts) == "table" then
    for key, value in pairs(decoded.layouts) do
      if type(value) == "string" then
        store.layouts[key] = value
      end
    end
  end
  if type(decoded.removed) == "table" then
    for _, value in ipairs(decoded.removed) do
      if type(value) == "string" then
        table.insert(store.removed, value)
      end
    end
  end
  if type(decoded.thumbs) == "table" then
    for key, value in pairs(decoded.thumbs) do
      if type(value) == "string" then
        store.thumbs[key] = value
      end
    end
  end
  store.brain = decoded.brain == true
  if type(decoded.brainGeometry) == "table" then
    for key, value in pairs(decoded.brainGeometry) do
      if type(value) == "string" then
        store.brainGeometry[key] = value
      end
    end
  end

  return store
end

function M.save(store)
  return writeStore(store)
end

-- Merge the three layers and apply deletions.
-- Empty values from defaults and Settings are ignored, but store values are
-- respected: an empty command is an explicit user decision (a widget without a
-- command still appears in the list).
function M.merge(base, configMap, storeMap, removed, baseThumbs, configThumbs, storeThumbs)
  local out = {}

  for key, value in pairs(base or {}) do
    if type(value) == "string" and value ~= "" then
      out[key] = value
    end
  end
  for key, value in pairs(configMap or {}) do
    if type(value) == "string" and value ~= "" then
      out[key] = value
    end
  end
  for key, value in pairs(storeMap or {}) do
    if type(value) == "string" then
      out[key] = value
    end
  end
  for _, key in ipairs(removed or {}) do
    out[key] = nil
  end

  -- Thumbs merge (same logic)
  local thumbsOut = {}
  for key, value in pairs(baseThumbs or {}) do
    if type(value) == "string" and value ~= "" then
      thumbsOut[key] = value
    end
  end
  for key, value in pairs(configThumbs or {}) do
    if type(value) == "string" and value ~= "" then
      thumbsOut[key] = value
    end
  end
  for key, value in pairs(storeThumbs or {}) do
    if type(value) == "string" then
      thumbsOut[key] = value
    end
  end
  for _, key in ipairs(removed or {}) do
    thumbsOut[key] = nil
  end

  return out, thumbsOut
end

-- Mark a widget as deleted (tombstone) and remove it from the store.
function M.remove(store, name)
  if not util.contains(store.removed, name) then
    table.insert(store.removed, name)
  end
  store.commands[name] = nil
  store.layouts[name] = nil
  if store.thumbs then
    store.thumbs[name] = nil
  end
end

-- Add or update a widget.
-- `nil` leaves the existing value alone; `""` in `layout` or `thumb` clears
-- the value (to return to the default layout or remove the custom thumbnail).
function M.upsert(store, name, command, layout, thumb)
  local index = nil
  for position, value in ipairs(store.removed) do
    if value == name then
      index = position
      break
    end
  end
  if index ~= nil then
    table.remove(store.removed, index)
  end

  if command ~= nil then
    store.commands[name] = command
  end
  if layout ~= nil then
    if layout == "" then
      store.layouts[name] = nil
    else
      store.layouts[name] = layout
    end
  end
  if thumb ~= nil then
    if thumb == "" then
      store.thumbs[name] = nil
    else
      store.thumbs[name] = thumb
    end
  end
end

-- The four widget-list keys. Brain memory is not here: it is written from
-- its own functions so it is not overwritten by accident.
local WIDGET_KEYS = { "commands", "layouts", "thumbs", "removed" }

function M.saveWidgets(store)
  local disk = M.load()
  for _, key in ipairs(WIDGET_KEYS) do
    disk[key] = (store and store[key]) or {}
  end
  return writeStore(disk)
end

function M.loadBrain()
  local disk = M.load()
  return { brain = disk.brain == true, brainGeometry = disk.brainGeometry or {} }
end

function M.saveBrainToggle(brain)
  local disk = M.load()
  disk.brain = brain == true
  return writeStore(disk)
end

function M.saveBrainGeometry(changes, removals)
  local disk = M.load()
  local map = disk.brainGeometry or {}
  for class, value in pairs(changes or {}) do
    if type(value) == "string" then map[class] = value end
  end
  for _, class in ipairs(removals or {}) do map[class] = nil end
  disk.brainGeometry = map
  return writeStore(disk)
end

function M.saveBrainForget(class)
  return M.saveBrainGeometry({}, { class })
end

return M
