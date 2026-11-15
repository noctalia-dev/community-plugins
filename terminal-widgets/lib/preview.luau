-- Capturas de miniaturas para el panel de Terminal Widgets.
--
-- Gestiona capturas de ventanas, cache de miniaturas, animación GIF casera,
-- limpieza de archivos antiguos y captura "solo ventana" via grim -g.

local util = require("./util.luau")

local M = {}

local CAPTURE_WIDTH = 320
local CAPTURE_HEIGHT = 190
-- Cambiar la versión invalida las capturas antiguas (por ejemplo, las que
-- incluían el panel u otras ventanas por encima).
local CAPTURE_VERSION = "v2"

local batchCounter = 0

-- Directorio de cache para miniaturas.
local cachedDir = nil
function M.cacheDir()
  if cachedDir ~= nil then
    if cachedDir == false then
      return nil
    end
    return cachedDir
  end

  local base = noctalia.pluginDataDir()
  if base == nil then
    cachedDir = false
    return nil
  end

  local path = base .. "/thumbs"
  -- Se crea una sola vez por runtime (mkdirAll es idempotente); así las
  -- capturas funcionan también en una instalación nueva.
  local called, created = pcall(noctalia.mkdirAll, path)
  if not called or created == false then
    noctalia.log("terminal-widgets: no se pudo crear " .. path)
    cachedDir = false
    return nil
  end
  cachedDir = path
  return path
end

-- Verifica si las herramientas necesarias (grim, python3) están disponibles.
function M.toolsAvailable()
  local ok1 = pcall(function() return noctalia.commandExists("grim") end)
  local ok2 = pcall(function() return noctalia.commandExists("python3") end)
  if not (ok1 and ok2) then
    return false
  end
  local script = util.pluginPath("bin/snapshot.py")
  return script ~= nil and noctalia.fileExists(script)
end

-- Genera un hash simple para usar en nombres de archivo.
local function hashText(text)
  local hash = 0
  for i = 1, #text do
    hash = (hash * 31 + text:byte(i)) % 0x1000000
  end
  return string.format("%06x", hash)
end

-- Firma de geometría de una ventana (para detectar cambios).
function M.signature(window, seq)
  -- Soporta tanto formato nuevo (entry con x,y,w,h) como antiguo (window object)
  local x = window.x or 0
  local y = window.y or 0
  local w = window.w or 0
  local h = window.h or 0
  local base = string.format("%d,%d,%d,%d", x, y, w, h)
  if seq ~= nil then
    return base .. "@" .. tostring(seq)
  end
  return base
end

function M.thumbPath(name, signature)
  local dir = M.cacheDir()
  if dir == nil then
    return nil
  end
  return string.format("%s/%s-%s-%s.png", dir, util.slug(name), CAPTURE_VERSION, hashText(signature))
end

-- Ruta de la miniatura "actual" (sin seq) para el preview principal
function M.currentThumbPath(name)
  local dir = M.cacheDir()
  if dir == nil then
    return nil
  end
  local base = string.format("%s/%s-%s-current.png", dir, util.slug(name), CAPTURE_VERSION)
  return base
end

function M.cached(name, signature)
  local path = M.thumbPath(name, signature)
  if path == nil then
    return nil
  end
  if noctalia.fileExists(path) then
    return path
  end
  -- Fallback a la miniatura actual
  local currentPath = M.currentThumbPath(name)
  if currentPath and noctalia.fileExists(currentPath) then
    return currentPath
  end
  return nil
end

function M.current(name)
  local path = M.currentThumbPath(name)
  if path and noctalia.fileExists(path) then
    return path
  end
  return nil
end

-- Rutas de las miniaturas que las tarjetas están usando ahora mismo.
-- `windows` acepta una lista o un mapa de ventanas abiertas (con `name`, `x`,
-- `y`, `w` y `h`).
function M.currentPaths(windows)
  local paths = {}
  for _, window in pairs(windows or {}) do
    if type(window) == "table" and window.name ~= nil then
      local path = M.thumbPath(window.name, M.signature(window))
      if path ~= nil then
        paths[path] = true
      end
      -- También incluir la miniatura actual
      local currentPath = M.currentThumbPath(window.name)
      if currentPath ~= nil then
        paths[currentPath] = true
      end
    end
  end
  return paths
end

-- Cache simple para frames (evita listDir/fileInfo frecuentes)
local framesCache = {}
local framesCacheTime = 0
local FRAMES_CACHE_TTL = 1000  -- 1 segundo

-- Devuelve las miniaturas recientes de un widget (más nuevas primeras), para
-- poder animarlas como un GIF casero cuando el widget está cerrado.
function M.frames(name, limit)
  local now = noctalia.nowMs()
  local cacheKey = name .. ":" .. (limit or 8)
  
  -- Verificar cache
  if framesCache[cacheKey] and (now - framesCacheTime) < FRAMES_CACHE_TTL then
    return framesCache[cacheKey]
  end
  
  local dir = M.cacheDir()
  if dir == nil then
    return {}
  end
  local files = noctalia.listDir(dir)
  if files == nil then
    return {}
  end
  limit = tonumber(limit) or 8
  local slug = util.slug(name)
  local prefix = slug .. "-"
  local suffix = ".png"
  local matches = {}
  local checked = 0
  local maxChecks = 24  -- acotado para no exceder el CPU budget
  for _, file in ipairs(files) do
    if checked >= maxChecks then
      break
    end
    if file:sub(1, #prefix) == prefix and file:sub(-4) == suffix then
      local path = dir .. "/" .. file
      local info = noctalia.fileInfo(path)
      local mtime = type(info) == "table" and tonumber(info.mtime) or 0
      table.insert(matches, { path = path, mtime = mtime })
      checked = checked + 1
    end
  end
  table.sort(matches, function(a, b)
    return a.mtime > b.mtime
  end)
  local out = {}
  for index = 1, math.min(limit, #matches) do
    table.insert(out, matches[index].path)
  end
  
  -- Guardar en cache
  framesCache[cacheKey] = out
  framesCacheTime = now
  return out
end

-- Captura las ventanas indicadas. `entries` = { {name, address, width, height} }
function M.capture(entries, callback)
  if #entries == 0 then
    if callback ~= nil then
      callback()
    end
    return
  end

  local dir = M.cacheDir()
  local script = util.pluginPath("bin/snapshot.py")
  if dir == nil or script == nil then
    if callback ~= nil then
      callback()
    end
    return
  end

  local items = {}
  for _, entry in ipairs(entries) do
    -- Thumbnail con seq (para frames/animación)
    local signature = M.signature(entry, entry.seq)
    local path = M.thumbPath(entry.name, signature)
    -- Thumbnail actual (sin seq, para preview principal)
    local currentPath = M.currentThumbPath(entry.name)
    
    if path ~= nil and not noctalia.fileExists(path) then
      table.insert(items, {
        name = entry.name,
        address = entry.address,
        stable_id = entry.stable_id,
        x = entry.x,
        y = entry.y,
        w = entry.w,
        h = entry.h,
        output = entry.output,
        width = CAPTURE_WIDTH,
        height = CAPTURE_HEIGHT,
        out = path,
        current_out = currentPath,
      })
    end
  end

  if #items == 0 then
    if callback ~= nil then
      callback()
    end
    return
  end

  local ok, encoded = pcall(noctalia.json.encode, items)
  if not ok or encoded == nil then
    if callback ~= nil then
      callback()
    end
    return
  end

  batchCounter = batchCounter + 1
  local batchPath = string.format("%s/batch-%d-%d.json", dir, os.time(), batchCounter)
  if not noctalia.writeFile(batchPath, encoded) then
    if callback ~= nil then
      callback()
    end
    return
  end

  local started = noctalia.runAsync({
    "python3",
    script,
    batchPath,
  }, function(result)
    pcall(noctalia.removeFile, batchPath)
    if result.exitCode ~= 0 then
      local detail = util.trim(result.stderr or "")
      noctalia.log("terminal-widgets: captura: " .. detail)
    end
    if callback ~= nil then
      callback()
    end
  end)
  if not started then
    pcall(noctalia.removeFile, batchPath)
    if callback ~= nil then
      callback()
    end
  end
end

-- Borra las miniaturas que ya no usa ninguna tarjeta y los archivos de lote
-- que se hayan quedado por el camino.
--
-- Se borra por *uso* y no por widget, y solo si además son antiguas: el host
-- puede volver a aplicar un árbol guardado (por ejemplo, al reabrir el panel)
-- y pedir una imagen que se borró hace un momento. Con la antigüedad mínima
-- ese fichero sigue ahí durante un rato y el aviso "image failed to load" no
-- aparece; los ficheros viejos se van yendo solos.
--
-- `currentPaths` = rutas que usan las tarjetas ahora mismo.
-- `maxAgeSeconds` = antigüedad a partir de la cual un fichero no usado se
-- considera caducable.
function M.pruneUnused(currentPaths, maxAgeSeconds)
  local dir = M.cacheDir()
  if dir == nil then
    return
  end
  local files = noctalia.listDir(dir)
  if files == nil then
    return
  end

  maxAgeSeconds = tonumber(maxAgeSeconds) or 1800
  local now = os.time()
  local checked = 0
  local maxChecks = 10

  for _, file in ipairs(files) do
    if checked >= maxChecks then
      break
    end
    checked = checked + 1
    if file:sub(1, 6) == "batch-" or file == "batch.json" then
      pcall(noctalia.removeFile, dir .. "/" .. file)
    elseif file:sub(-4) == ".png" and not currentPaths[dir .. "/" .. file] then
      local path = dir .. "/" .. file
      local info = noctalia.fileInfo(path)
      local mtime = type(info) == "table" and tonumber(info.mtime) or nil
      if mtime == nil or (now - mtime) >= maxAgeSeconds then
        pcall(noctalia.removeFile, path)
      end
    end
  end
end

-- Última miniatura disponible para un widget (la más reciente).
function M.latest(name)
  local frames = M.frames(name, 1)
  if #frames > 0 then
    return frames[1]
  end
  return nil
end

return M