--!nonstrict
-- Almacén propio del plugin.
--
-- La lista de widgets (nombre, comando, layout y miniatura) vive en
-- `store.json`, dentro del directorio de datos del plugin. Al cargar se
-- fusionan los defaults integrados y los borrados se recuerdan en `removed`:
--
--   defaults  ⊕  store  −  removed
--
-- Así se puede añadir un widget sin perder los que ya estaban y también borrar
-- los que vienen por defecto. Ajustes de Noctalia no participa.
--
-- El mismo fichero guarda la memoria del cerebro: el interruptor (`brain`) y
-- las geometrías recordadas por clase de ventana (`brainGeometry`). Como se
-- escriben desde sitios distintos (la lista de widgets, el interruptor, la
-- geometría al salir de editar), cada escritura lee el disco y pisa solo sus
-- claves: nadie pierde lo que otro guardó.

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

-- Escritura atómica: ningún lector puede ver el fichero a medias.
local function writeStore(store)
  local path = M.path()
  if path == nil then return false, "sin directorio de datos" end
  local ok, encoded = pcall(noctalia.json.encode, store, true)
  if not ok or type(encoded) ~= "string" then return false, "no se pudo codificar el store" end
  local tmp = path .. ".tmp"
  local wrote = noctalia.writeFile(tmp, encoded)
  if wrote ~= true then return false, "no se pudo escribir " .. tmp end
  if noctalia.renameFile ~= nil then
    local renamed = noctalia.renameFile(tmp, path)
    if renamed ~= true then return false, "no se pudo renombrar " .. path end
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
    noctalia.log("terminal-widgets: store.json ilegible, se empieza de cero")
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

-- Fusiona las tres capas y aplica los borrados.
-- Los valores vacíos de los defaults y de Ajustes se ignoran, pero los del
-- store se respetan: un comando vacío es una decisión explícita del usuario
-- (un widget sin comando sigue apareciendo en la lista).
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

-- Marca un widget como borrado (tombstone) y lo quita del store.
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

-- Añade o actualiza un widget.
-- `nil` no toca lo que hubiera; `""` en `layout` o `thumb` borra el valor
-- (para volver al layout por defecto o quitar la miniatura personalizada).
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

-- Las cuatro claves de la lista de widgets. La memoria del cerebro no está:
-- se escribe desde sus propias funciones para no pisarla por accidente.
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
