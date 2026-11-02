--!nonstrict
-- Panel de lanzamiento: una tarjeta por widget de terminal.
--
-- Cada tarjeta abre (o enfoca) su terminal flotante. La cabecera trae las
-- acciones: abrir todo, rotar las ventanas, cerrarlas todas y editar la
-- lista de widgets.
--
-- La posición y el tamaño de cada ventana salen de `layouts`; el botón de
-- "abrir todo" además rota las ventanas ya abiertas entre sí.

local util = require("./lib/util.luau")
local defaults = require("./lib/defaults.luau")
local layoutLib = require("./lib/layout.luau")
local storeLib = require("./lib/store.luau")
local win = require("./lib/windows.luau")
local preview = require("./lib/preview.luau")
local gifLib = require("./lib/gif.luau")

-- Semilla aleatoria inicializada una vez al cargar el plugin.
math.randomseed(noctalia.nowMs() + (os.time() or 0) * 1000)

local DEBOUNCE_MS = 700
-- Ancho útil real del área de scroll (sin el canal de la barra lateral). El
-- panel mide 520 px lógicos; tras descontar el padding y el hueco que reserva
-- el scroll quedan ~465 px. Usar este valor evita que una sola columna se
-- desborde un poco del panel.
local SCROLL_CONTENT_WIDTH = 465
local PANEL_PADDING = 8
local CARD_GAP = 6
local CARD_PADDING = 5
-- Ratio de la miniatura respecto al ancho de la tarjeta. Valor menor =
-- tarjetas más horizontales (más rectangulares).
local PREVIEW_RATIO = 0.5
local MAX_PREVIEW_HEIGHT = 120
-- Margen de tolerancia: dos ventanas que se tocan (1-2 px) no cuentan como
-- solapadas, así una posición configurada no se mueve por un roce.
local OVERLAP_TOLERANCE = 4

-- Generador de números aleatorios simple que no depende de math.random
-- (que puede no comportarse de forma determinista en el entorno Luau de
-- Noctalia). Usa ahoraMs + un contador para que cada llamada dé un valor
-- distinto.
local _randCounter = 0
local function randomRange(minVal, maxVal)
  local range = maxVal - minVal + 1
  if range <= 0 then
    return minVal
  end
  _randCounter = _randCounter + 1
  local seed = (noctalia.nowMs() or 0) + _randCounter * 7919
  seed = (seed * 1103515245 + 12345) % 2147483648
  return minVal + (seed % range)
end

local cfg = {
  terminal = "kitty",
  width = 900,
  height = 830,
  x = 120,
  y = 140,
  margin = 16,
  output = "",
  closeOnLaunch = false,
  reuseExisting = true,
  rotation = "clockwise",
  rotationSizes = true,
  columns = 2,
  cardPreview = "auto",
  previewInterval = 3000,
  fallbackMode = "random",
  fallbackRandomResize = false,
}

local state = {
  commands = {},
  layouts = {},
  store = nil,
  windows = {},
  thumbUsed = {},
  clients = {},
  classNames = {},
  frames = {},
  gifAnim = {},
  captureAnim = {},
  -- Último tamaño real de cada ventana (para conservarlo cuando "Cambiar
  -- tamaño también" está desactivado).
  lastSize = {},
  -- Rutas de las capturas recientes de cada widget (animación tipo GIF).
  recentFrames = {},
  capturing = false,
  lastCapture = 0,
  tick = 0,
  editing = false,
  editTarget = nil,
  editSession = 0,
  form = { name = "", command = "", layout = "", thumb = "" },
  lastLaunch = {},
  launching = {},
  rotating = false,
  open = false,
}

-- Las funciones se referencian entre sí (una tarjeta llama a render() y
-- render() dibuja las tarjetas), así que se declaran antes de definirlas.
local render
local card
local header
local editorCard
local launch
local startEditing
local deleteWidget
local syncFrameTicks
local saveForm
local refreshWindows
local captureThumbs
local openAll
local rotateWindows
local closeAllWindows

local function tr(key, args)
  return noctalia.tr(key, args)
end

local function append(list, node)
  if node ~= nil then
    table.insert(list, node)
  end
  return list
end

-- ---------------------------------------------------------------- ajustes --

local function loadConfig()
  -- (Re)inicializar el generador aleatorio para que cada sesión del panel
  -- produzca posiciones distintas en modo fallbackMode = "random".
  math.randomseed(noctalia.nowMs() + (os.time() or 0) * 1000)
  cfg.terminal = tostring(noctalia.getConfig("terminal") or "kitty")
  cfg.width = tonumber(noctalia.getConfig("width")) or 900
  cfg.height = tonumber(noctalia.getConfig("height")) or 520
  cfg.x = tonumber(noctalia.getConfig("x")) or 120
  cfg.y = tonumber(noctalia.getConfig("y")) or 140
  cfg.margin = tonumber(noctalia.getConfig("margin")) or 16

  local output = util.trim(noctalia.getConfig("output") or "")
  if output:lower() == "focused" then
    output = ""
  end
  cfg.output = output

  cfg.closeOnLaunch = noctalia.getConfig("close_on_launch") == true
  cfg.reuseExisting = noctalia.getConfig("reuse_existing") ~= false
  cfg.rotation = tostring(noctalia.getConfig("rotation") or "clockwise")
  cfg.rotationSizes = noctalia.getConfig("rotation_sizes") == true
  cfg.columns = math.floor(util.clamp(tonumber(noctalia.getConfig("columns")) or 2, 1, 3))
  cfg.cardPreview = tostring(noctalia.getConfig("card_preview") or "auto")
  -- preview_interval se guarda en milisegundos (el manifiesto lo declara así).
  cfg.previewInterval = math.floor(util.clamp(tonumber(noctalia.getConfig("preview_interval")) or 3000, 500, 60000))
  cfg.fallbackMode = tostring(noctalia.getConfig("fallback_mode") or "random")
  cfg.fallbackRandomResize = noctalia.getConfig("fallback_random_resize") == true
end

local function widgetNames()
  return util.sortedKeys(state.commands)
end

-- Fusiona defaults + Ajustes + store propio y aplica los borrados.
local function loadWidgets()
  local base = defaults.load()
  state.store = state.store or storeLib.load()

  -- Combinar defaults + store (sin config de Ajustes)
  local combinedRemoved = {}
  local seen = {}
  for _, name in ipairs(state.store.removed or {}) do
    if not seen[name] then
      table.insert(combinedRemoved, name)
      seen[name] = true
    end
  end

  state.commands, state.thumbs = storeLib.merge(
    base.commands,
    nil,  -- sin config de Ajustes
    state.store.commands,
    combinedRemoved,
    base.thumbs or {},
    nil,  -- sin config thumbs
    state.store.thumbs
  )
  state.layouts = storeLib.merge(
    base.layouts,
    nil,  -- sin config
    state.store.layouts,
    combinedRemoved
  )

  -- Una miniatura personalizada solo cuenta si el archivo existe. Así una
  -- ruta vieja o inventada no aparece en el editor ni se muestra por defecto.
  local validThumbs = {}
  for name, path in pairs(state.thumbs or {}) do
    if type(path) == "string" and util.trim(path) ~= "" then
      local info = noctalia.fileInfo(path)
      if type(info) == "table" and tonumber(info.size or 0) > 0 then
        validThumbs[name] = path
      end
    end
  end
  state.thumbs = validThumbs

  noctalia.log("terminal-widgets: widgets -> " .. table.concat(widgetNames(), ", "))
end

local function classMap()
  local map = {}
  for _, name in ipairs(widgetNames()) do
    local class = util.classFor(name)
    if map[class] ~= nil then
      -- Dos nombres que seormalizan igual comparten clase: sus ventanas se
      -- confundirían. Se avisa en el log, pero se sigue funcionando.
      noctalia.log(
        string.format(
          "terminal-widgets: '%s' y '%s' comparten la clase %s",
          map[class],
          name,
          class
        )
      )
    end
    map[class] = name
  end
  return map
end

-- --------------------------------------------------------------- geometría --

local function outputGeometry()
  local outputs = noctalia.outputs() or {}
  local wanted = cfg.output
  local chosen = nil
  local focused = nil

  for _, output in ipairs(outputs) do
    if output.focused then
      focused = output
    end
    if wanted ~= "" and output.name == wanted then
      chosen = output
    end
  end

  chosen = chosen or focused or outputs[1]
  if chosen ~= nil then
    local width = tonumber(chosen.width) or 0
    local height = tonumber(chosen.height) or 0
    if width >= 320 and height >= 240 then
      return math.floor(width), math.floor(height), chosen.name or ""
    end
  end

  return 1920, 1080, ""
end

local function resolveGeometry(name)
  local spec = layoutLib.parseLayout(state.layouts[name])
  local width = cfg.width
  local height = cfg.height
  local custom = false
  local dx = 0
  local dy = 0
  local anchor = nil
  local auto = false

  if spec ~= nil and spec.valid then
    width = spec.width or width
    height = spec.height or height
    custom = spec.custom == true
    dx = spec.dx or 0
    dy = spec.dy or 0
    anchor = spec.anchor
    auto = spec.auto == true
  else
    -- Sin layout explícito: el widget entra en modo automático, por lo que
    -- el fallbackMode "random" puede colocarlo en una posición libre.
    auto = true
  end

  local screenWidth, screenHeight, outputName = outputGeometry()

  -- Un tamaño mayor que la pantalla (un descuido al escribir el layout)
  -- dejaría la ventana fuera de la vista, así que se recorta.
  width = math.max(100, math.min(math.floor(width), screenWidth))
  height = math.max(50, math.min(math.floor(height), screenHeight))

  local x
  local y

  if custom then
    x = math.floor(dx)
    y = math.floor(dy)
  else
    if anchor ~= nil then
      x, y = layoutLib.anchorPosition(anchor, width, height, screenWidth, screenHeight, cfg.margin)
    else
      x = math.floor(cfg.x)
      y = math.floor(cfg.y)
    end
    x = x + math.floor(dx)
    y = y + math.floor(dy)
  end

  return {
    x = x,
    y = y,
    width = width,
    height = height,
    output = outputName,
    anchor = anchor,
    custom = custom,
    auto = auto,
  }
end

local function layoutText(name)
  local raw = state.layouts[name]
  if type(raw) ~= "string" or util.trim(raw) == "" then
    return tr("layout_global", { width = math.floor(cfg.width), height = math.floor(cfg.height) })
  end

  local spec = layoutLib.parseLayout(raw)
  if spec == nil or not spec.valid then
    return tr("layout_invalid")
  end

  local width = spec.width or math.floor(cfg.width)
  local height = spec.height or math.floor(cfg.height)
  if spec.auto then
    return string.format("%s · %d×%d", tr("layout_auto"), width, height)
  end
  if spec.custom then
    return string.format(
      "%s · %d×%d · %d,%d",
      tr("layout_custom"),
      width,
      height,
      math.floor(spec.dx or 0),
      math.floor(spec.dy or 0)
    )
  end

  return string.format("%s · %d×%d", spec.anchor, width, height)
end

-- ------------------------------------------------------------- ventanas --

local function findByClass(clients, class)
  for _, client in ipairs(clients or {}) do
    if client.class == class then
      return client
    end
  end
  return nil
end

-- Busca una posición aleatoria libre en el monitor para una geometría dada.
-- Solo se usa en modo fallbackMode = "random".
-- Retorna x, y o nil, nil si no hay espacio libre.
local function findRandomFreePosition(geometry)
  local screenWidth, screenHeight = outputGeometry()
  local margin = math.max(0, math.floor(cfg.margin))

  local maxX = screenWidth - geometry.width
  local maxY = screenHeight - geometry.height

  if maxX < margin or maxY < margin then
    return nil, nil  -- Ventana más grande que la pantalla
  end

  -- Obtener rectángulos ocupados por ventanas DEL PLUGIN (para no solapar)
  local occupied = {}
  for _, name in ipairs(widgetNames()) do
    local window = state.windows[name]
    if window ~= nil then
      table.insert(occupied, {
        x = window.x,
        y = window.y,
        w = window.w,
        h = window.h,
      })
    end
  end

  local function fits(x, y)
    if x < margin or y < margin then
      return false
    end
    if x + geometry.width > screenWidth - margin or y + geometry.height > screenHeight - margin then
      return false
    end
    for _, other in ipairs(occupied) do
      local overlapX = math.min(x + geometry.width, other.x + other.w) - math.max(x, other.x)
      local overlapY = math.min(y + geometry.height, other.y + other.h) - math.max(y, other.y)
      if overlapX > 0 and overlapY > 0 then
        return false
      end
    end
    return true
  end

  -- Posiciones completamente aleatorias distribuidas por toda la pantalla,
  -- sin priorizar el centro ni seguir una grilla repetitiva.
  local maxAttempts = 120
  local minX = margin
  local maxX = math.max(minX, screenWidth - geometry.width - margin)
  local minY = margin
  local maxY = math.max(minY, screenHeight - geometry.height - margin)

  for _ = 1, maxAttempts do
    local x = randomRange(minX, maxX)
    local y = randomRange(minY, maxY)
    if fits(x, y) then
      return x, y
    end
  end

  return nil, nil  -- No hay espacio libre
end

-- Aplica el modo fallback "random" a una geometría: elige tamaño aleatorio
-- (si `fallback_random_resize` está activo) y luego una posición libre que
-- respete ese tamaño. Devuelve true si encontró sitio.
local function applyRandomPlacement(geometry)
  local margin = math.max(0, math.floor(cfg.margin))

  if cfg.fallbackRandomResize then
    local screenW, screenH = outputGeometry()
    local minW = math.max(200, math.floor(screenW * 0.15))
    local maxW = math.min(screenW - margin * 2, math.floor(screenW * 0.55))
    local minH = math.max(150, math.floor(screenH * 0.15))
    local maxH = math.min(screenH - margin * 2, math.floor(screenH * 0.65))
    if maxW > minW then
      geometry.width = randomRange(minW, maxW)
    end
    if maxH > minH then
      geometry.height = randomRange(minH, maxH)
    end
  end

  local rx, ry = findRandomFreePosition(geometry)
  if rx == nil then
    return false
  end
  geometry.x, geometry.y = rx, ry
  return true
end

-- Reutiliza el último tamaño conocido de un widget (ventana abierta o la
-- última vez que estuvo abierta) cuando "Cambiar tamaño también" está
-- desactivado. Así, si el usuario ajusta el tamaño a mano y vuelve a pulsar la
-- miniatura para recolocarlo, se conserva ese tamaño en vez de volver al del
-- layout/configuración.
--
-- `source` = la ventana ya abierta (si la hay). Sin ventana abierta solo se
-- aplica a widgets sin layout: si el widget tiene dirección y tamaño
-- definidos, al abrirse se respetan tal cual.
local function applyRememberedSize(geometry, name, source)
  if cfg.fallbackMode ~= "random" or cfg.fallbackRandomResize then
    return
  end

  local size = source
  if type(size) ~= "table" then
    if not geometry.auto then
      -- Tiene dirección y tamaño definidos: mandan sus valores.
      return
    end
    size = state.lastSize[name]
  end
  if type(size) ~= "table" then
    return
  end

  local width = tonumber(size.w)
  local height = tonumber(size.h)
  if (width or 0) > 0 and (height or 0) > 0 then
    geometry.width = math.floor(width)
    geometry.height = math.floor(height)
  end
end

local function addRecentFrame(name, path)
  if path == nil then
    return
  end
  local list = state.recentFrames[name]
  if list == nil then
    list = {}
    state.recentFrames[name] = list
  end
  table.insert(list, 1, path)
  while #list > 8 do
    local dropped = table.remove(list)
    if dropped ~= path then
      pcall(noctalia.removeFile, dropped)
    end
  end
end

-- Capturas recientes del widget, de la más nueva a la más antigua. Se usa
-- para animar tarjetas y para que la vista "en vivo" cambie de archivo (el
-- host no recarga una imagen si la ruta no cambia).
local function captureFrames(name, limit)
  local list = state.recentFrames[name]
  local out = {}
  if list ~= nil then
    for _, path in ipairs(list) do
      if noctalia.fileExists(path) then
        table.insert(out, path)
        if limit ~= nil and #out >= limit then
          return out
        end
      end
    end
  end
  if #out > 0 then
    return out
  end
  return preview.frames(name, limit or 8)
end

captureThumbs = function(force)
  if cfg.cardPreview == "mock" then
    return
  end
  if not preview.toolsAvailable() then
    return
  end
  if state.capturing then
    return
  end

  -- Captura automática (sin force) para modos que deben capturar al abrir ventana:
  -- live, auto, screenshot, gif. El modo mock no captura.
  -- Con force=true (desde update() periódico o apertura manual), siempre captura.
  local shouldCapture = force
  if not shouldCapture then
    if cfg.cardPreview == "live"
       or cfg.cardPreview == "auto"
       or cfg.cardPreview == "screenshot"
       or cfg.cardPreview == "gif" then
      shouldCapture = true
    end
  end
  if not shouldCapture then
    return
  end

  state.capturing = true
  state.lastCapture = noctalia.nowMs()

  local clients = state.clients or {}
  win.layers(function(layers)
    local entries = {}
    local pendingFrames = {}
    for _, client in ipairs(clients) do
      local name = state.classNames[client.class]
      if name ~= nil and client.w > 0 and client.h > 0 then
        local window = state.windows[name]
        if window ~= nil then
          -- Saltar widgets con thumbnail personalizada: no necesitan captura
          local customThumb = state.thumbs[name]
          if customThumb and customThumb ~= "" then
            -- No capturar, ya tenemos la imagen del usuario
          else
            local seq = nil
            if cfg.cardPreview == "live" or cfg.cardPreview == "auto" or cfg.cardPreview == "gif" then
              seq = noctalia.nowMs()
            end
            local entry = {
              name = name,
              address = window.address,
              stable_id = window.stableId,
              x = window.screenX or window.x,
              y = window.screenY or window.y,
              w = window.w,
              h = window.h,
              output = window.monitor.name,
              seq = seq,
            }
            table.insert(entries, entry)
            if seq ~= nil then
              local framePath = preview.thumbPath(name, preview.signature(entry, seq))
              if framePath ~= nil then
                table.insert(pendingFrames, { name = name, path = framePath })
              end
            end
          end
        end
      end
    end
    noctalia.log(string.format("terminal-widgets: captureThumbs: %d entries, capturing=%s", #entries, tostring(state.capturing)))

    local function cleanup()
      -- Rutas en uso: las de las ventanas abiertas y las que el árbol está
      -- pintando ahora mismo (`state.thumbUsed`). La poda solo borra lo que
      -- no está en uso y es antiguo.
      local used = preview.currentPaths(state.windows)
      for path in pairs(state.thumbUsed or {}) do
        used[path] = true
      end
      preview.pruneUnused(used, 1800)
      state.capturing = false
    end

    if #entries == 0 then
      cleanup()
      return
    end

    preview.capture(entries, function()
      -- Las capturas nuevas ya existen: guardarlas como frames recientes para
      -- que la tarjeta pueda actualizarse/animate con una ruta distinta.
      for _, item in ipairs(pendingFrames) do
        if noctalia.fileExists(item.path) then
          addRecentFrame(item.name, item.path)
        end
      end
      cleanup()
      -- Los frames se cargan perezosamente en cardPreview cuando se necesitan.
      -- No los precargamos aquí para evitar exceder el CPU budget con
      -- #entries * fileInfo llamadas.
      if state.open then
        render()
      end
    end)
  end)
end

-- ------------------------------------------------------------- acciones --

local function refresh()
  refreshWindows(function()
    if state.open then
      render()
    end
  end)
end

refreshWindows = function(callback)
  win.list(function(clients)
    win.monitors(function(monitors)
      local map = classMap()
      local windows = win.pluginWindows(clients, monitors, function(class)
        return map[class]
      end)

      state.clients = clients
      state.classNames = map
      state.windows = {}
      for _, window in ipairs(windows) do
        if window.name ~= nil then
          state.windows[window.name] = window
          if (window.w or 0) > 0 and (window.h or 0) > 0 then
            state.lastSize[window.name] = {
              w = math.floor(window.w),
              h = math.floor(window.h),
            }
          end
        end
      end

      -- Defer captureThumbs to avoid CPU budget in onOpen
      noctalia.runAsync({ "sleep", "0.1" }, function()
        if state.open then
          captureThumbs()
        end
        if callback ~= nil then
          callback()
        end
      end)
    end)
  end)
end

-- Abre (o enfoca) un widget. El debounce evita que un doble clic rápido
-- abra dos ventanas iguales.
launch = function(name, opts)
  opts = opts or {}

  -- Si la acción es parte de una cadena (por ejemplo "abrir todo"), hay que
  -- avisar igual de que este widget se salta, o la cadena se quedaría
  -- colgada y los siguientes nunca se abrirían.
  local function skip()
    if opts.onDone ~= nil then
      opts.onDone()
    end
  end

  local command = state.commands[name]
  if type(command) ~= "string" or command == "" then
    noctalia.notifyError(tr("title"), tr("missing_command", { name = tostring(name) }))
    skip()
    return
  end

  local class = util.classFor(name)
  local now = noctalia.nowMs()
  local last = state.lastLaunch[class]
  if last ~= nil and (now - last) < DEBOUNCE_MS then
    skip()
    return
  end
  if state.launching[class] then
    skip()
    return
  end
  state.lastLaunch[class] = now
  state.launching[class] = true

  local geometry = resolveGeometry(name)

  local function finish(doRefresh)
    state.launching[class] = nil
    if opts.onDone ~= nil then
      opts.onDone()
      return
    end
    -- `close_on_launch` cierra el panel al abrir una terminal (salvo que la
    -- acción sea por lotes, como "abrir todos").
    if cfg.closeOnLaunch and not opts.keepOpen then
      panel.close()
      return
    end
    if doRefresh ~= false then
      refresh()
    end
  end

  win.list(function(clients)
    win.monitors(function(monitors)
      local existing = findByClass(clients, class)

      -- Si "Cambiar tamaño también" está desactivado, conservar el último
      -- tamaño real del widget (el que el usuario dejó al ajustarlo a mano).
      applyRememberedSize(geometry, name, existing)

      if existing ~= nil and cfg.reuseExisting then
        -- El widget ya está abierto: en modo random se mueve a un hueco
        -- libre (el layout solo aporta el tamaño), en modo custom vuelve a
        -- su posición configurada.
        if cfg.fallbackMode == "random" then
          if not applyRandomPlacement(geometry) then
            noctalia.notifyError(tr("title"), tr("no_free_space"))
            finish(true)
            return
          end
        end
        win.focusExisting(class, geometry, function()
          finish(true)
        end)
      else
        -- Widget nuevo: si no tiene layout explícito (geometry.auto) se abre
        -- en un hueco libre; si lo tiene, se respetan su dirección y su
        -- tamaño tal y como están definidos.
        if cfg.fallbackMode == "random" and geometry.auto then
          if not applyRandomPlacement(geometry) then
            -- No hay espacio libre
            noctalia.notifyError(tr("title"), tr("no_free_space"))
            finish(true)
            return
          end
        end
        win.spawn({
          terminal = cfg.terminal,
          class = class,
          name = name,
          command = command,
          geometry = geometry,
          monitor = cfg.output ~= "" and cfg.output or nil,
          onError = function()
            noctalia.notifyError(tr("title"), tr("launch_failed"))
          end,
        }, function()
          -- La miniatura se toma cuando la ventana ya está mapeada.
          noctalia.runAsync({ "sleep", "1.2" }, function()
            refresh()
          end)
          finish(false)
        end)
      end
    end)
  end)
end

-- Rota las ventanas abiertas entre sí.
rotateWindows = function()
  if state.rotating or win.rotating then
    return
  end
  state.rotating = true
  win.list(function(clients)
    win.monitors(function(monitors)
      local map = classMap()
      local windows = win.pluginWindows(clients, monitors, function(class)
        return map[class]
      end)

      if #windows < 2 then
        noctalia.notify(tr("title"), tr("nothing_to_rotate"))
        state.rotating = false
        return
      end

      local started = win.rotate(windows, cfg.rotation, cfg.rotationSizes, function()
        state.rotating = false
        refresh()
      end)
      if started == false then
        state.rotating = false
        return
      end
    end)
  end)
end

-- Abre los widgets que falten, uno detrás de otro (así cada uno ve las
-- ventanas que ya están abiertas y no se pisan). Si ya estaban todos
-- abiertos, los rota.
openAll = function()
  win.list(function(clients)
    win.monitors(function(monitors)
      local map = classMap()
      local windows = win.pluginWindows(clients, monitors, function(class)
        return map[class]
      end)

      local open = {}
      for _, window in ipairs(windows) do
        if window.name ~= nil then
          open[window.name] = true
        end
      end

      local missing = {}
      for _, name in ipairs(widgetNames()) do
        if not open[name] then
          table.insert(missing, name)
        end
      end

      if #missing == 0 then
        if #windows >= 2 then
          if state.rotating or win.rotating then
            return
          end
          state.rotating = true
          local started = win.rotate(windows, cfg.rotation, cfg.rotationSizes, function()
            state.rotating = false
            refresh()
          end)
          if started == false then
            state.rotating = false
          end
        else
          noctalia.notify(tr("title"), tr("nothing_to_rotate"))
        end
        return
      end

      -- Lanzamiento paralelo: se calculan las geometrías de una sola vez (con
      -- la lista de ocupadas compartida) y se despachan todos los spawns en un
      -- único lote, en vez de abrirlos uno a uno.
      local paramsList = {}
      local occupied = {}
      -- Semilla las ventanas ya abiertas
      for _, window in ipairs(windows) do
        table.insert(occupied, { x = window.x, y = window.y, w = window.w, h = window.h })
      end

      for _, name in ipairs(missing) do
        local command = state.commands[name]
        if type(command) ~= "string" or command == "" then
          noctalia.notifyError(tr("title"), tr("missing_command", { name = tostring(name) }))
        else
          local geometry = resolveGeometry(name)

          -- Conservar el último tamaño ajustado a mano si el resize aleatorio
          -- está desactivado.
          applyRememberedSize(geometry, name, nil)

          -- Modo fallback random: buscar posición libre (y opcionalmente tamaño
          -- aleatorio) solo si el widget no tiene dirección y tamaño
          -- definidos en su layout.
          if cfg.fallbackMode == "random" and geometry.auto then
            if not applyRandomPlacement(geometry) then
              -- No hay espacio libre, saltar este widget
              noctalia.notifyError(tr("title"), tr("no_free_space", { name = name }))
            end
          end

          table.insert(occupied, { x = geometry.x, y = geometry.y, w = geometry.width, h = geometry.height })
          local class = util.classFor(name)
          state.lastLaunch[class] = noctalia.nowMs()
          state.launching[class] = true
          table.insert(paramsList, {
            terminal = cfg.terminal,
            class = class,
            name = name,
            command = command,
            geometry = geometry,
            monitor = cfg.output ~= "" and cfg.output or nil,
            onError = function()
              noctalia.notifyError(tr("title"), tr("launch_failed"))
            end,
          })
        end
      end

      if #paramsList == 0 then
        refresh()
        return
      end

      win.spawnMany(paramsList, function()
        for _, params in ipairs(paramsList) do
          state.launching[params.class] = nil
        end
        noctalia.runAsync({ "sleep", "1.2" }, function()
          refresh()
        end)
      end)
    end)
  end)
end

closeAllWindows = function()
  win.list(function(clients)
    win.monitors(function(monitors)
      local map = classMap()
      local windows = win.pluginWindows(clients, monitors, function(class)
        return map[class]
      end)
      win.closeAll(windows, function()
        refresh()
      end)
    end)
  end)
end

-- ------------------------------------------------------------- edición --

-- Aplica los cambios de un widget (los usa el formulario del panel y el IPC).
local function applyWidget(name, command, layout, thumb)
  name = util.trim(name)
  command = util.trim(command)
  layout = util.trim(layout)
  thumb = util.trim(thumb)

  if name == "" then
    return false, tr("need_name")
  end

  if state.store == nil then
    loadWidgets()
  end

  -- Un comando vacío en un widget que ya existe no lo deja sin comando (sería
  -- un despiste al editar); en uno nuevo sí se guarda tal cual.
  if command == "" and state.commands[name] ~= nil then
    command = nil
  end

  -- `layout` y `thumb` vacíos SÍ se guardan: significan "quitar el valor"
  -- (volver al layout por defecto / no usar miniatura personalizada).
  storeLib.upsert(state.store, name, command, layout, thumb)
  local saved, err = storeLib.save(state.store)
  if not saved then
    return false, tr("save_failed", { detail = tostring(err or "") })
  end

  loadWidgets()

  -- Si el widget está abierto y cambió su geometría, se reaplica en vez de
  -- cerrar la ventana (así editar tamaño/posición no la mata).
  local window = state.windows[name]
  if window ~= nil then
    local geometry = resolveGeometry(name)
    win.focusExisting(util.classFor(name), geometry, function()
      refresh()
    end)
  end
  return true, nil
end

-- Borra un widget (los usa el panel y el IPC).
local function removeWidget(name)
  if state.store == nil then
    loadWidgets()
  end

  storeLib.remove(state.store, name)
  local saved, err = storeLib.save(state.store)
  if not saved then
    return false, tr("save_failed", { detail = tostring(err or "") })
  end
  -- La tarjeta ya no existe: su entrada en la tabla de animaciones es
  -- basura, y si se queda el panel seguiría pidiendo ticks de frame para
  -- algo que no está.
  state.captureAnim[name] = nil
  loadWidgets()
  return true, nil
end

startEditing = function(name)
  state.editing = true
  state.editTarget = name
  state.editSession = state.editSession + 1
  if name ~= nil then
    state.form = {
      name = name,
      command = state.commands[name] or "",
      layout = state.layouts[name] or "",
      thumb = state.thumbs[name] or "",
    }
  else
    state.form = { name = "", command = "", layout = "", thumb = "" }
  end
  render()
end

local cancelEditing = function()
  state.editing = false
  state.editTarget = nil
  state.editSession = state.editSession + 1
  state.form = { name = "", command = "", layout = "", thumb = "" }
  render()
end

saveForm = function()
  local name = util.trim(state.form.name)
  local command = util.trim(state.form.command)
  local layout = util.trim(state.form.layout)
  local thumb = util.trim(state.form.thumb)

  if name == "" then
    noctalia.notifyError(tr("title"), tr("need_name"))
    return
  end

  -- Validar nombre único (se permite conservar el nombre del widget editado)
  if state.commands[name] ~= nil and name ~= state.editTarget then
    noctalia.notifyError(tr("title"), tr("name_exists"))
    return
  end

  -- Validar comando no vacío
  if command == "" then
    noctalia.notifyError(tr("title"), tr("empty_command"))
    return
  end

  -- Validar formato de layout si se proporciona
  if layout ~= "" then
    local spec = layoutLib.parseLayout(layout)
    if spec == nil or spec.valid == false then
      noctalia.notifyError(tr("title"), tr("invalid_layout"))
      return
    end
  end

  -- La miniatura es opcional; si se indica una ruta, debe existir.
  if thumb ~= "" then
    local info = noctalia.fileInfo(thumb)
    if type(info) ~= "table" or tonumber(info.size or 0) <= 0 then
      noctalia.notifyError(tr("title"), tr("thumb_not_found"))
      return
    end
  end

  local target = state.editTarget
  if target ~= nil and target ~= name then
    local removed, err = removeWidget(target)
    if not removed then
      noctalia.notifyError(tr("title"), err)
      return
    end
  end

  local applied, err = applyWidget(name, command, layout, thumb)
  if not applied then
    noctalia.notifyError(tr("title"), err)
    return
  end

  state.editing = false
  state.editTarget = nil
  state.editSession = state.editSession + 1
  state.form = { name = "", command = "", layout = "", thumb = "" }
  render()
end

deleteWidget = function(name)
  local removed, err = removeWidget(name)
  if not removed then
    noctalia.notifyError(tr("title"), err)
    return
  end

  -- Si la ventana estaba abierta, se cierra para no dejarla huérfana.
  local window = state.windows[name]
  if window ~= nil then
    win.closeWindow(window.address, function()
      refresh()
    end)
  end

  render()
end

-- ---------------------------------------------------------------- vista --

local function cardWidth()
  local columns = cfg.columns
  -- El ancho de la tarjeta (border-box) ya incluye su padding. Repartir el
  -- ancho útil real entre columnas evita el desborde con una sola columna.
  local usable = SCROLL_CONTENT_WIDTH - ((columns - 1) * CARD_GAP)
  return math.max(120, math.floor(usable / columns))
end

local function previewHeight()
  -- En una sola columna la tarjeta es muy ancha: la miniatura se aplana para
  -- que la tarjeta no quede disproportionate.
  return math.min(math.floor(cardWidth() * PREVIEW_RATIO), MAX_PREVIEW_HEIGHT)
end

-- Miniatura sintética: una terminal falsa con el nombre del widget.
local function mockPreview(name)
  local width = cardWidth() - 2 * CARD_PADDING - 12
  local height = previewHeight()
  local children = {}

  append(children, ui.row({ gap = 4, align = "center", padding = 6 }, {
    ui.box({ width = 7, height = 7, radius = 4, fill = "error/0.7" }),
    ui.box({ width = 7, height = 7, radius = 4, fill = "primary/0.7" }),
    ui.box({ width = 7, height = 7, radius = 4, fill = "primary/0.4" }),
  }))
  append(children, ui.row({ paddingH = 8, flexGrow = 1 }, {
    ui.label({
      text = name,
      fontSize = 12,
      fontFamily = "monospace",
      color = "on_surface/0.85",
      maxLines = 2,
      flexGrow = 1,
    }),
  }))

  -- Unas líneas de texto falsas para que la tarjeta parezca una terminal.
  local ratios = { 0.62, 0.44, 0.78 }
  for _, ratio in ipairs(ratios) do
    append(children, ui.row({ paddingH = 12, paddingV = 3 }, {
      ui.box({
        width = math.floor((width - 24) * ratio),
        height = 6,
        radius = 3,
        fill = "on_surface/0.12",
      }),
    }))
  end

  return ui.column({
    width = width,
    height = height,
    fill = "#00000040",
    radius = 8,
    border = "outline_variant/0.25",
    borderWidth = 1,
    justify = "start",
    align = "stretch",
  }, children)
end

local function previewImage(path, width)
  -- La ruta queda marcada como "en uso": la poda de miniaturas no puede
  -- borrar un fichero que el host está pintando.
  if path ~= nil then
    state.thumbUsed[path] = true
  end
  return ui.image({
    path = path,
    width = width,
    height = previewHeight(),
    fit = "cover",
    radius = 8,
    border = "outline_variant/0.25",
    borderWidth = 1,
  })
end

-- GIF animado: `ui.image` solo pinta el primer fotograma, así que se extraen
-- todos a PNG y se intercambian desde `onFrameTick`.
local function gifPreview(path, width)
  local anim = state.gifAnim[path]
  if anim == nil then
    anim = { index = 1, elapsed = 0, started = false, info = nil }
    state.gifAnim[path] = anim
  end

  local info = anim.info or gifLib.frames(path, preview.cacheDir())
  if info ~= nil and #info.frames > 0 then
    anim.info = info
    if anim.index > #info.frames then
      anim.index = 1
    end
    return previewImage(info.frames[anim.index], width)
  end

  if not anim.started then
    anim.started = true
    gifLib.prepare(path, preview.cacheDir(), function(frames)
      anim.info = frames
      if state.open then
        render()
      end
    end)
  end

  -- Mientras se extraen los fotogramas, el host pinta el primero del GIF.
  return previewImage(path, width)
end

local function cardPreview(name)
  -- PRIORIDAD ABSOLUTA: miniatura personalizada SIEMPRE gana, sea cual sea el modo
  local customThumb = state.thumbs[name]
  if customThumb and customThumb ~= "" then
    local info = noctalia.fileInfo(customThumb)
    if info and type(info) == "table" and tonumber(info.size or 0) > 0 then
      local width = cardWidth() - 2 * CARD_PADDING - 12
      if gifLib.isGif(customThumb) then
        return gifPreview(customThumb, width)
      end
      return previewImage(customThumb, width)
    end
    -- Si el archivo personalizado no existe o está vacío, ignorarlo
  end

  if cfg.cardPreview == "mock" then
    return mockPreview(name)
  end

  local window = state.windows[name]

  -- Modo GIF (y Automático con la ventana cerrada): animar las capturas
  -- recientes del widget como si fuese un GIF.
  if cfg.cardPreview == "gif" or (cfg.cardPreview == "auto" and window == nil) then
    local frames = captureFrames(name, 8)
    if #frames > 0 then
      -- La animación va a recorrer todos estos fotogramas, no solo el que se
      -- pinta ahora: se protegen todos para que la poda no borre el
      -- siguiente fotograma de la animación.
      for _, framePath in ipairs(frames) do
        state.thumbUsed[framePath] = true
      end
      local anim = state.captureAnim[name]
      if anim == nil then
        anim = { index = 1, elapsed = 0 }
        state.captureAnim[name] = anim
      end
      -- Con una sola captura no hay animación: no hay fotogramas que
      -- alternar. Se marca aquí, que es donde se sabe cuántos hay, para que
      -- no se pidan ticks de frame para una tarjeta que no puede moverse.
      anim.animatable = #frames > 1
      local index = ((anim.index - 1) % #frames) + 1
      return previewImage(frames[index], cardWidth() - 2 * CARD_PADDING)
    end
  end

  if window ~= nil then
    -- Vista en vivo: usar la captura más reciente por su ruta única. El host
    -- no recarga una imagen cuando se sobrescribe el mismo archivo, así que
    -- reutilizar `current` haría que el intervalo de vista previa no se viera.
    if cfg.cardPreview == "auto" or cfg.cardPreview == "live" then
      local frames = captureFrames(name, 1)
      if #frames > 0 then
        return previewImage(frames[1], cardWidth() - 2 * CARD_PADDING)
      end
    end

    -- Captura "current" (*-current.png) para el resto de modos.
    local capPath = preview.current(name)
    if capPath then
      local info = noctalia.fileInfo(capPath)
      if info and type(info) == "table" and tonumber(info.size or 0) > 0 then
        return previewImage(capPath, cardWidth() - 2 * CARD_PADDING)
      end
    end
  end

  return mockPreview(name)
end

card = function(name)
  local running = state.windows[name] ~= nil
  local command = state.commands[name] or ""
  local layout = layoutText(name)

  local titleRow = {}
  append(titleRow, ui.label({
    text = name,
    fontWeight = "bold",
    color = "on_surface",
    maxLines = 1,
    flexGrow = 1,
  }))
  if running then
    append(titleRow, ui.glyph({ name = "circle-dot", size = 10, color = "primary" }))
    -- Botón de cerrar visible cuando el widget está corriendo (click derecho no soportado en ui.image/column)
    append(titleRow, ui.button({
      key = "close-" .. name,
      glyph = "close",
      variant = "ghost",
      tooltip = tr("close_widget"),
      onClick = function()
        local w = state.windows[name]
        if w ~= nil then
          win.closeWindow(w.address, function()
            refresh()
          end)
        end
      end,
    }))
  end
  if state.editing then
    append(titleRow, ui.button({
      key = "edit-" .. name,
      glyph = "pencil",
      variant = "ghost",
      tooltip = tr("edit_widget"),
      onClick = function()
        startEditing(name)
      end,
    }))
    append(titleRow, ui.button({
      key = "delete-" .. name,
      glyph = "trash",
      variant = "ghost",
      tooltip = tr("delete_widget"),
      onClick = function()
        deleteWidget(name)
      end,
    }))
  end

  local titleNode = ui.row({ gap = 6, align = "center" }, titleRow)

  -- Crear el preview con handlers de click (en la miniatura)
  local previewNode

  -- Ancho real del contenido (cardWidth - 2 * CARD_PADDING)
  local contentWidth = cardWidth() - 2 * CARD_PADDING
  -- Miniaturas más estrechas que el contenido para que no toquen los bordes
  local thumbWidth = contentWidth - 20

  -- Usar cardPreview que maneja custom thumbs y capturas de ventana
  previewNode = cardPreview(name)
  if not previewNode then
    previewNode = mockPreview(name)
  end

  -- Contenedor principal: column con onClick para lanzar
  local cardProps = {
    key = "card-" .. name,
    width = cardWidth(),
    gap = 6,
    padding = CARD_PADDING,
    radius = 12,
    fill = "surface_container/0.35",
    border = "outline_variant/0.2",
    borderWidth = 1,
    tooltip = command ~= ""
        and string.format("%s\n%s", command, layout)
      or tr("missing_command", { name = name }),
  }

  -- En modo edición, no agregar handlers de click en el preview (los botones de editar/borrar están en el titleRow)
  if state.editing then
    return ui.column(cardProps, { previewNode, titleNode })
  end

  -- En modo normal: onClick en el column para lanzar
  cardProps.onClick = function()
    launch(name)
  end
  return ui.column(cardProps, { previewNode, titleNode })
end

editorCard = function(target)
  local session = state.editSession
  local existing = target ~= nil
  local children = {}

  local titleRow = {
    ui.label({
      text = existing and tr("edit_widget") or tr("add_widget"),
      fontWeight = "bold",
      color = "on_surface",
      maxLines = 1,
      flexGrow = 1,
    }),
  }
  if existing then
    append(titleRow, ui.button({
      key = "editor-delete-" .. session,
      glyph = "trash",
      variant = "ghost",
      tooltip = tr("delete_widget"),
      onClick = function()
        deleteWidget(target)
        cancelEditing()
      end,
    }))
  end
  append(titleRow, ui.button({
    key = "editor-cancel-" .. session,
    glyph = "x",
    variant = "ghost",
    tooltip = tr("cancel"),
    onClick = cancelEditing,
  }))
  append(children, ui.row({ gap = 4, align = "center" }, titleRow))

  -- Nombre y comando en la misma fila para que el formulario quepa dentro de
  -- la tarjeta sin estirar demasiado las tarjetas vecinas.
  append(children, ui.row({ gap = 4, align = "center" }, {
    ui.input({
      key = "form-name-" .. session,
      value = state.form.name,
      placeholder = tr("field_name"),
      controlSize = "sm",
      flexGrow = 1,
      onSubmit = saveForm,
      onChange = function(value)
        state.form.name = value
      end,
    }),
    ui.input({
      key = "form-command-" .. session,
      value = state.form.command,
      placeholder = tr("field_command"),
      controlSize = "sm",
      flexGrow = 1,
      onSubmit = saveForm,
      onChange = function(value)
        state.form.command = value
      end,
    }),
  }))

  append(children, ui.row({ gap = 4, align = "center" }, {
    ui.input({
      key = "form-layout-" .. session,
      value = state.form.layout,
      placeholder = tr("field_layout"),
      controlSize = "sm",
      flexGrow = 1,
      onSubmit = saveForm,
      onChange = function(value)
        state.form.layout = value
      end,
    }),
    ui.row({ gap = 2, align = "center", flexGrow = 1 }, {
      ui.input({
        key = "form-thumb-" .. session,
        value = state.form.thumb or "",
        placeholder = tr("field_thumb"),
        controlSize = "sm",
        flexGrow = 1,
        onSubmit = saveForm,
        onChange = function(value)
          state.form.thumb = value
        end,
      }),
      ui.button({
        key = "form-thumb-clear-" .. session,
        glyph = "eraser",
        variant = "ghost",
        tooltip = tr("clear_thumb"),
        onClick = function()
          state.form.thumb = ""
          -- Se cambia la sesión para que el input se reconstruya vacío.
          state.editSession = state.editSession + 1
          render()
        end,
      }),
    }),
  }))

  append(children, ui.row({ gap = 6, align = "center" }, {
    ui.button({
      key = "editor-save-" .. session,
      text = tr("save"),
      glyph = "check",
      variant = "primary",
      onClick = saveForm,
    }),
    ui.label({
      text = tr("editor_hint"),
      fontSize = 10,
      color = "on_surface_variant",
      flexGrow = 1,
      maxLines = 2,
    }),
  }))

  return ui.column({
    key = "editor",
    width = cardWidth(),
    gap = 6,
    padding = CARD_PADDING,
    radius = 12,
    fill = "surface_container/0.35",
    border = "primary/0.5",
    borderWidth = 1,
    align = "stretch",
  }, children)
end

header = function()
  local outputLabel = cfg.output ~= "" and cfg.output or tr("focused_output")
  local subtitle = tr("subtitle", {
    terminal = cfg.terminal,
    margin = math.floor(cfg.margin),
    output = outputLabel,
  })

  local title = ui.row({
    gap = 8,
    align = "center",
    flexGrow = 1,
    tooltip = subtitle,
  }, {
    ui.glyph({ name = "terminal-2", size = 18, color = "primary" }),
    ui.label({ text = tr("title"), fontSize = 16, fontWeight = "bold", color = "on_surface" }),
  })

  local buttons = {}
  append(buttons, ui.button({
    key = "open-all",
    glyph = "layout-grid",
    variant = "ghost",
    tooltip = tr("open_all"),
    onClick = openAll,
  }))
  append(buttons, ui.button({
    key = "rotate",
    glyph = "rotate-clockwise",
    variant = "ghost",
    tooltip = tr("rotate"),
    onClick = rotateWindows,
  }))
  append(buttons, ui.button({
    key = "close-all",
    glyph = "window-off",
    variant = "ghost",
    tooltip = tr("close_all"),
    onClick = closeAllWindows,
  }))
  append(buttons, ui.button({
    key = "edit",
    glyph = state.editing and "check" or "pencil",
    variant = "ghost",
    tooltip = tr("edit_mode"),
    onClick = function()
      if state.editing then
        cancelEditing()
      else
        startEditing(nil)
      end
    end,
  }))
  append(buttons, ui.button({
    key = "open-settings",
    glyph = "settings",
    variant = "ghost",
    tooltip = tr("open_settings"),
    onClick = function()
      noctalia.openSettings()
    end,
  }))
  append(buttons, ui.button({
    key = "close-panel",
    glyph = "x",
    variant = "ghost",
    tooltip = tr("close"),
    onClick = function()
      panel.close()
    end,
  }))

  return ui.row({ gap = 4, align = "center" }, { title, ui.row({ gap = 2, align = "center" }, buttons) })
end

render = function()
  if not state.open then
    return
  end

  -- Las rutas de las miniaturas del árbol se recalculan en cada render: solo
  -- se pueden borrar los ficheros que ninguna tarjeta está usando. Antes se
  -- estimaban a partir de las ventanas abiertas, y eso dejaba fuera a los
  -- widgets cerrados, cuya miniatura ("current" o la animación) seguía
  -- pintándose: la poda la borraba y el host avisaba "image failed to load".
  --
  -- El conjunto se conserva después del render para que la poda no borre un
  -- fichero que el host pueda volver a aplicar al reabrir el panel.
  state.thumbUsed = {}

  local cards = {}
  local names = widgetNames()

  -- El formulario de "nuevo widget" va primero, para que se vea sin desplazar.
  if state.editing and state.editTarget == nil then
    table.insert(cards, editorCard(nil))
  end

  -- Al editar uno existente, el formulario ocupa el sitio de SU tarjeta (así
  -- los campos aparecen junto al widget que se está editando).
  for _, name in ipairs(names) do
    if state.editing and state.editTarget == name then
      table.insert(cards, editorCard(name))
    else
      table.insert(cards, card(name))
    end
  end

  if #cards == 0 then
    table.insert(cards, ui.label({
      text = tr("empty"),
      color = "on_surface_container",
      padding = 12,
      flexGrow = 1,
    }))
  end

  -- Filas de `columns` tarjetas. align="stretch" para que todas las tarjetas
  -- de la fila tengan la misma altura (tamaño uniforme). justify="center" para
  -- centrar las tarjetas horizontalmente cuando el panel es más ancho que la fila.
  local rows = {}
  local row = {}
  local count = 0
  for _, node in ipairs(cards) do
    table.insert(row, node)
    count = count + 1
    if count == cfg.columns then
      table.insert(rows, ui.row({ gap = CARD_GAP, align = "stretch", justify = "center" }, row))
      row = {}
      count = 0
    end
  end
  if count > 0 then
    table.insert(rows, ui.row({ gap = CARD_GAP, align = "stretch", justify = "center" }, row))
  end

  panel.render(ui.column({
    flexGrow = 1,
    gap = 10,
    align = "stretch",
    padding = PANEL_PADDING,
  }, {
    header(),
    ui.scroll({ flexGrow = 1, gap = CARD_GAP, justify = "center" }, rows),
  }))

  -- Las rutas en uso las ha ido rellenando `previewImage` al construir las
  -- tarjetas: son las que el árbol acaba de referenciar.

  -- Ahora se sabe si hay algo que animar (una tarjeta cerrada con capturas en
  -- modo Automático, un GIF): se pide o se quita el tick de frame.
  syncFrameTicks()
end

-- ------------------------------------------------------------- ciclo de vida --

-- ¿Hay algo que animar con ticks de frame? (GIF personalizado, modo GIF o las
-- capturas de una tarjeta cerrada en modo Automático).
local function needsFrameTicks()
  if cfg.cardPreview == "gif" then
    return true
  end
  for _, path in pairs(state.thumbs or {}) do
    if gifLib.isGif(path) then
      return true
    end
  end
  -- Modo Automático: una tarjeta cuya ventana está cerrada muestra sus
  -- capturas como una animación, y esa animación solo avanza con ticks de
  -- frame (los pide `render()`, que es quien sabe si hay capturas).
  --
  -- Solo cuentan las tarjetas que siguen existiendo y que tienen más de un
  -- fotograma: una tarjeta borrada deja su entrada en `captureAnim` (que es
  -- basura) y una tarjeta con una sola captura no tiene nada que animar.
  if cfg.cardPreview == "auto" then
    for name, anim in pairs(state.captureAnim or {}) do
      if anim ~= nil and anim.animatable
        and (state.commands or {})[name] ~= nil
        and state.windows[name] == nil then
        return true
      end
    end
  end
  return false
end

syncFrameTicks = function()
  pcall(panel.setNeedsFrameTick, needsFrameTicks())
end

function onOpen(_context)
  state.open = true
  panel.setWantsSecondTicks(true)
  -- El manifiesto se cachea para no analizarlo en cada callback; al abrir el
  -- panel se relee, por si el plugin se actualizó sin reiniciar Noctalia.
  defaults.reset()
  loadConfig()
  loadWidgets()
  state.editing = false
  state.editTarget = nil
  state.frames = {}
  state.captureAnim = {}
  state.recentFrames = {}
  syncFrameTicks()
  -- NO cargar frames aquí (CPU budget); se cargan perezosamente en render/update
  -- Diferir el primer render para evitar CPU budget en onOpen
  local function delayedOpen()
    if state.open then
      render()
      refreshWindows(function()
        if state.open then
          render()
        end
      end)
    end
  end
  noctalia.runAsync({ "sleep", "0.05" }, delayedOpen)
end

function onClose()
  state.open = false
  panel.setWantsSecondTicks(false)
  pcall(panel.setNeedsFrameTick, false)
end

function onConfigChanged()
  defaults.reset()
  loadConfig()
  loadWidgets(true)
  syncFrameTicks()
  if state.open then
    render()
    -- Los indicadores de "abierta" y las miniaturas se refrescan también, y
    -- si cambió una posición/tamaño en Ajustes se reaplica a la ventana
    -- abierta en vez de dejarla donde estaba.
    refreshWindows(function()
      if state.open then
        for _, name in ipairs(widgetNames()) do
          local window = state.windows[name]
          if window ~= nil then
            local geometry = resolveGeometry(name)
            win.focusExisting(util.classFor(name), geometry, function() end)
          end
        end
        render()
      end
    end)
  end
end

-- Ticks de frame: avanzan los GIF (personalizados y capturas en modo GIF)
-- solo cuando cambia el fotograma visible, para no re-renderizar de más.
function onFrameTick(deltaMs)
  if not state.open then
    return
  end
  deltaMs = tonumber(deltaMs) or 16
  if deltaMs > 250 then
    deltaMs = 250
  end

  local changed = false

  for _, anim in pairs(state.gifAnim) do
    local info = anim.info
    if info ~= nil and #info.frames > 1 then
      anim.elapsed = anim.elapsed + deltaMs
      local duration = info.durations[anim.index] or 100
      while anim.elapsed >= duration do
        anim.elapsed = anim.elapsed - duration
        anim.index = (anim.index % #info.frames) + 1
        duration = info.durations[anim.index] or 100
        changed = true
      end
    end
  end

  local captureInterval = 250
  for name, anim in pairs(state.captureAnim) do
    -- Una tarjeta con una sola captura no tiene nada que animar: se salta
    -- para no releer su lista de fotogramas del disco sin motivo.
    local showFrames = anim.animatable ~= false
      and (cfg.cardPreview == "gif"
        or (cfg.cardPreview == "auto" and state.windows[name] == nil))
    if showFrames then
      anim.elapsed = anim.elapsed + deltaMs
      -- La lista de fotogramas se relee solo cuando toca avanzar la animación:
      -- `captureFrames` consulta el disco, y leerla en cada frame gastaría CPU
      -- sin que cambiara nada.
      if anim.elapsed >= captureInterval then
        local frames = captureFrames(name, 8)
        if #frames > 1 then
          while anim.elapsed >= captureInterval do
            anim.elapsed = anim.elapsed - captureInterval
            anim.index = (anim.index % #frames) + 1
            changed = true
          end
        else
          anim.elapsed = 0
        end
      end
    end
  end

  if changed then
    render()
  end
end

function update()
  if not state.open then
    return
  end
  state.tick = state.tick + 1
  -- Captura periódica para modos live y auto (y gif para mantener frames actualizados)
  -- previewInterval ya está en milisegundos.
  if (cfg.cardPreview == "live" or cfg.cardPreview == "auto" or cfg.cardPreview == "gif") and not state.capturing then
    if (noctalia.nowMs() - (state.lastCapture or 0)) >= cfg.previewInterval then
      captureThumbs(true)
    end
  end
  render()
end

function onIpc(event, payload)
  if event == "launch" then
    loadConfig()
    loadWidgets()
    launch(payload)
  elseif event == "open-all" then
    loadConfig()
    loadWidgets()
    openAll()
  elseif event == "rotate" then
    loadConfig()
    loadWidgets()
    rotateWindows()
  elseif event == "close-all" then
    closeAllWindows()
  elseif event == "add" then
    -- "nombre|comando|posición|thumb" (thumb opcional)
    loadConfig()
    loadWidgets()
    local parts = {}
    for part in tostring(payload or ""):gmatch("[^|]+") do
      parts[#parts + 1] = part
    end
    local applied, err = applyWidget(parts[1] or "", parts[2] or "", parts[3] or "", parts[4] or "")
    if not applied then
      noctalia.notifyError(tr("title"), err)
      return
    end
    if state.open then
      render()
    end
  elseif event == "remove" then
    loadConfig()
    loadWidgets()
    -- Same path as the panel's delete button: the window is closed too.
    deleteWidget(tostring(payload or ""))
  elseif event == "refresh" then
    loadConfig()
    loadWidgets()
    if state.open then
      render()
    end
    refreshWindows(function()
      if state.open then
        render()
      end
    end)
  end
end
