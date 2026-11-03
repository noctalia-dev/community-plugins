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

local util = require("./util.luau")

local M = {}

local function emptyStore()
  return { commands = {}, layouts = {}, thumbs = {}, removed = {} }
end

function M.path()
  local dir = noctalia.pluginDataDir()
  if dir == nil then
    return nil
  end
  return dir .. "/store.json"
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

  return store
end

function M.save(store)
  local path = M.path()
  if path == nil then
    return false, "sin directorio de datos"
  end

  local ok, encoded = pcall(noctalia.json.encode, store, true)
  if not ok or encoded == nil then
    return false, "no se pudo serializar"
  end

  local wrote = noctalia.writeFile(path, encoded)
  if wrote ~= true then
    return false, "no se pudo escribir " .. path
  end
  return true
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

return M
