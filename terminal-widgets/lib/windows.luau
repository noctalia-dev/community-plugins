--!nonstrict
-- Puente con Hyprland: listar ventanas, abrirlas, moverlas, rotarlas y
-- cerrarlas.
--
-- Todo pasa por `hyprctl dispatch` con la API Lua de Hyprland 0.56:
--   hl.dsp.window.move({ x = 120, y = 140, window = "class:^noctalia-term-cava$" })
--   hl.dsp.window.resize({ x = 900, y = 520, window = "..." })
--   hl.dsp.window.close({ window = "address:0x55d1..." })

local util = require("./util.luau")
local layoutLib = require("./layout.luau")

local spawnExpression

local M = {}

M.CLASS_PREFIX = "noctalia-term-"

function M.dispatch(expression, callback)
  local started = noctalia.runAsync({ "hyprctl", "dispatch", expression }, function(result)
    if result.exitCode ~= 0 then
      local detail = util.trim(result.stderr or result.stdout or "")
      if detail ~= "" then
        noctalia.log("terminal-widgets: " .. detail)
      end
    end
    if callback ~= nil then
      callback(result.exitCode == 0)
    end
  end)
  if not started and callback ~= nil then
    callback(false)
  end
end

function M.selectorFor(class)
  return "class:^" .. class .. "$"
end

function M.addressSelector(address)
  return "address:" .. tostring(address)
end

-- Ventanas abiertas con su geometría en coordenadas globales.
function M.list(callback)
  local started = noctalia.runAsync({ "hyprctl", "clients", "-j" }, function(result)
    local clients = {}
    if result.exitCode == 0 and type(result.stdout) == "string" and result.stdout ~= "" then
      local ok, decoded = pcall(noctalia.json.decode, result.stdout)
      if ok and type(decoded) == "table" then
        for _, client in ipairs(decoded) do
          local at = client.at or {}
          local size = client.size or {}
          local workspace = client.workspace
          local workspaceId = nil
          if type(workspace) == "table" then
            workspaceId = workspace.id
          elseif workspace ~= nil then
            workspaceId = workspace
          end
          table.insert(clients, {
            address = tostring(client.address or ""),
            -- Hyprland >= 0.5x: identificador estable del toplevel. grim -T lo
            -- usa para capturar SOLO esa ventana, aunque haya capas encima.
            stableId = tostring(client.stableId or ""),
            class = tostring(client.class or ""),
            title = tostring(client.title or ""),
            x = tonumber(at[1]) or 0,
            y = tonumber(at[2]) or 0,
            w = tonumber(size[1]) or 0,
            h = tonumber(size[2]) or 0,
            monitor = tostring(client.monitor or ""),
            workspace = workspaceId,
            hidden = client.hidden == true,
            mapped = client.mapped ~= false,
          })
        end
      end
    end
    callback(clients)
  end)
  if not started then
    callback({})
  end
end

-- Monitores por id, con su origen para traducir a coordenadas locales.
function M.monitors(callback)
  local started = noctalia.runAsync({ "hyprctl", "monitors", "-j" }, function(result)
    local map = {}
    if result.exitCode == 0 and type(result.stdout) == "string" and result.stdout ~= "" then
      local ok, decoded = pcall(noctalia.json.decode, result.stdout)
      if ok and type(decoded) == "table" then
        for _, monitor in ipairs(decoded) do
          map[tostring(monitor.id)] = {
            id = tostring(monitor.id),
            name = tostring(monitor.name or ""),
            x = tonumber(monitor.x) or 0,
            y = tonumber(monitor.y) or 0,
            width = tonumber(monitor.width) or 1920,
            height = tonumber(monitor.height) or 1080,
          }
        end
      end
    end
    callback(map)
  end)
  if not started then
    callback({})
  end
end

function M.isPluginClass(class)
  return class:sub(1, #M.CLASS_PREFIX) == M.CLASS_PREFIX
end

-- Ventanas del plugin que están abiertas, con su nombre (deducido de la
-- clase) y su posición relativa al monitor.
function M.pluginWindows(clients, monitors, nameForClass)
  local windows = {}
  for _, client in ipairs(clients or {}) do
    if M.isPluginClass(client.class) then
      local monitor = (monitors or {})[client.monitor]
      if monitor == nil then
        monitor = { id = client.monitor, name = "", x = 0, y = 0, width = 1920, height = 1080 }
      end
      table.insert(windows, {
        address = client.address,
        stableId = client.stableId,
        class = client.class,
        name = nameForClass(client.class),
        x = client.x - monitor.x,
        y = client.y - monitor.y,
        -- Coordenadas globales (grim -g trabaja en coordenadas de escritorio,
        -- no del monitor).
        screenX = client.x,
        screenY = client.y,
        w = client.w,
        h = client.h,
        monitor = monitor,
      })
    end
  end
  return windows
end

-- Zonas ocupadas por las ventanas del plugin en el monitor de destino.
-- `excludeAddress` deja fuera una ventana (la que se va a recolocar: si no,
-- se taparía a sí misma y acabaría en un hueco cualquiera).
function M.occupiedRects(clients, monitors, targetOutput, excludeAddress)
  local occupied = {}
  for _, client in ipairs(clients or {}) do
    if M.isPluginClass(client.class) and client.address ~= excludeAddress then
      local monitor = (monitors or {})[client.monitor]
      if monitor ~= nil and (targetOutput == "" or monitor.name == targetOutput) then
        table.insert(occupied, {
          x = client.x - monitor.x,
          y = client.y - monitor.y,
          w = client.w,
          h = client.h,
        })
      end
    end
  end
  return occupied
end

local function moveExpression(selector, x, y)
  return string.format(
    "hl.dsp.window.move({ x = %d, y = %d, window = %s })",
    math.floor(x),
    math.floor(y),
    util.luaQuote(selector)
  )
end

local function resizeExpression(selector, w, h)
  return string.format(
    "hl.dsp.window.resize({ x = %d, y = %d, window = %s })",
    math.floor(w),
    math.floor(h),
    util.luaQuote(selector)
  )
end

local function focusExpression(selector)
  return string.format("hl.dsp.focus({ window = %s })", util.luaQuote(selector))
end

local function closeExpression(selector)
  return string.format("hl.dsp.window.close({ window = %s })", util.luaQuote(selector))
end

-- Aplica una lista de movimientos: { address, selector, x, y, w, h, resize }
function M.applyGeometry(entries, callback)
  local index = 0
  local total = #entries

  local function finish()
    if callback ~= nil then
      callback()
    end
  end

  local function step()
    index = index + 1
    local entry = entries[index]
    if entry == nil then
      finish()
      return
    end

    local selector = entry.selector or M.addressSelector(entry.address)
    local function doMove()
      M.dispatch(moveExpression(selector, entry.x, entry.y), function()
        if index >= total then
          finish()
        else
          step()
        end
      end)
    end

    if entry.resize and entry.w ~= nil and entry.h ~= nil then
      M.dispatch(resizeExpression(selector, entry.w, entry.h), doMove)
    else
      doMove()
    end
  end

  if total == 0 then
    finish()
    return
  end
  step()
end

-- Enfoca (y recoloca) una ventana que ya existe.
function M.focusExisting(class, geometry, callback)
  local selector = M.selectorFor(class)
  M.dispatch(resizeExpression(selector, geometry.width, geometry.height), function()
    M.dispatch(moveExpression(selector, geometry.x, geometry.y), function()
      M.dispatch(focusExpression(selector), function()
        if callback ~= nil then
          callback()
        end
      end)
    end)
  end)
end

-- Crea la ventana. `persistent_size` de Hyprland puede pisar el tamaño al
-- mapear, así que la geometría se reaplica un instante después.
function M.spawn(params, callback)
  local expression = spawnExpression(params)
  M.dispatch(expression, function(success)
    if not success and params.onError ~= nil then
      params.onError()
    end
    local started = noctalia.runAsync({ "sleep", "0.6" }, function()
      M.focusExisting(params.class, params.geometry, function()
        if callback ~= nil then
          callback()
        end
      end)
    end)
    if not started and callback ~= nil then
      callback()
    end
  end)
end

-- Expresión de lanzamiento reutilizable por `spawn` y `spawnMany`.
spawnExpression = function(params)
  local terminal = params.terminal or "kitty"
  local closeOpt = ""
  if terminal:find("kitty", 1, true) ~= nil then
    closeOpt = " -o confirm_os_window_close=0"
  end

  local full = string.format(
    "%s%s --class %s --title %s -e sh -lc %s",
    terminal,
    closeOpt,
    util.shellQuote(params.class),
    util.shellQuote(params.name),
    util.shellQuote(params.command)
  )

  local monitorRule = ""
  if params.monitor ~= nil and params.monitor ~= "" then
    monitorRule = string.format(", monitor = %s", util.luaQuote(params.monitor))
  end

  return string.format(
    "hl.dsp.exec_cmd(%s, { float = true%s, move = { %d, %d }, size = { %d, %d } })",
    util.luaQuote(full),
    monitorRule,
    math.floor(params.geometry.x),
    math.floor(params.geometry.y),
    math.floor(params.geometry.width),
    math.floor(params.geometry.height)
  )
end

-- Lanza una lista de ventanas en paralelo (una sola espera de 0.6 s).
function M.spawnMany(paramsList, callback)
  if #paramsList == 0 then
    if callback ~= nil then
      callback(true)
    end
    return true
  end

  local pending = #paramsList
  local allOk = true
  local function finishOne(success)
    if not success then
      allOk = false
    end
    pending = pending - 1
    if pending == 0 then
      local started = noctalia.runAsync({ "sleep", "0.6" }, function()
        if callback ~= nil then
          callback(allOk)
        end
      end)
      if not started then
        if callback ~= nil then
          callback(allOk)
        end
      end
    end
  end

  for _, params in ipairs(paramsList) do
    local expression = spawnExpression(params)
    M.dispatch(expression, function(success)
      if not success and params.onError ~= nil then
        params.onError()
      end
      finishOne(success)
    end)
  end
  return true
end

function M.layers(callback)
  local started = noctalia.runAsync({ "hyprctl", "layers", "-j" }, function(result)
    local layers = {}
    if result.exitCode == 0 and type(result.stdout) == "string" and result.stdout ~= "" then
      local ok, decoded = pcall(noctalia.json.decode, result.stdout)
      if ok and type(decoded) == "table" then
        for _, output in pairs(decoded) do
          if type(output) == "table" and type(output.levels) == "table" then
            for level, items in pairs(output.levels) do
              if type(items) == "table" then
                for _, item in ipairs(items) do
                  table.insert(layers, {
                    level = tonumber(level) or 0,
                    x = tonumber(item.x) or 0,
                    y = tonumber(item.y) or 0,
                    w = tonumber(item.w) or 0,
                    h = tonumber(item.h) or 0,
                    namespace = tostring(item.namespace or ""),
                  })
                end
              end
            end
          end
        end
      end
    end
    callback(layers)
  end)
  if not started then
    callback({})
  end
end

function M.closeWindow(address, callback)
  M.dispatch(closeExpression(M.addressSelector(address)), function()
    if callback ~= nil then
      callback()
    end
  end)
end

function M.closeAll(windows, callback)
  if #windows == 0 then
    if callback ~= nil then
      callback()
    end
    return
  end

  local index = 0
  local total = #windows

  local function step()
    index = index + 1
    local window = windows[index]
    if window == nil then
      if callback ~= nil then
        callback()
      end
      return
    end
    M.closeWindow(window.address, function()
      if index >= total then
        if callback ~= nil then
          callback()
        end
      else
        step()
      end
    end)
  end

  step()
end

-- Orden circular de las ventanas alrededor del centro del monitor.
-- En pantalla `y` crece hacia abajo, así que ordenar por ángulo ascendente es
-- el sentido horario.
local function sortByAngle(windows)
  local sorted = {}
  for _, window in ipairs(windows) do
    table.insert(sorted, window)
  end
  table.sort(sorted, function(a, b)
    local centerX = a.monitor.width / 2
    local centerY = a.monitor.height / 2
    local angleA = math.atan2((a.y + a.h / 2) - centerY, (a.x + a.w / 2) - centerX)
    local angleB = math.atan2((b.y + b.h / 2) - centerY, (b.x + b.w / 2) - centerX)
    if angleA == angleB then
      return a.x < b.x
    end
    return angleA < angleB
  end)
  return sorted
end

-- Devuelve, para cada índice, el índice de la ventana que le cede el sitio.
local function permutation(sorted, mode)
  local count = #sorted
  local result = {}
  for index = 1, count do
    result[index] = index
  end
  if count < 2 then
    return result
  end

  if mode == "counterclockwise" then
    for index = 1, count do
      result[index] = ((index - 2) % count) + 1
    end
  elseif mode == "opposite" then
    local mapping = layoutLib.oppositePairs(sorted)
    for index = 1, count do
      result[index] = mapping[index] or index
    end
  elseif mode == "pairs" then
    local index = 1
    while index <= count do
      if index + 1 <= count then
        result[index] = index + 1
        result[index + 1] = index
        index = index + 2
      else
        result[index] = index
        index = index + 1
      end
    end
  elseif mode == "shuffle" then
    local pool = {}
    for index = 1, count do
      table.insert(pool, index)
    end
    for index = #pool, 2, -1 do
      local swap = math.random(index)
      pool[index], pool[swap] = pool[swap], pool[index]
    end
    for index = 1, count do
      result[index] = pool[index]
    end
  else
    -- clockwise (por defecto)
    for index = 1, count do
      result[index] = (index % count) + 1
    end
  end

  return result
end

-- Bloqueo de rotación para evitar pisadas por pulsaciones rápidas.
M.rotating = false

-- Rota las ventanas del plugin: cada una se va al sitio de otra.
function M.rotate(windows, mode, swapSizes, callback)
  if M.rotating then
    return false
  end
  local groups = {}
  local order = {}
  for _, window in ipairs(windows) do
    local key = window.monitor.name or window.monitor.id
    if groups[key] == nil then
      groups[key] = {}
      order[#order + 1] = key
    end
    table.insert(groups[key], window)
  end

  local moves = {}
  for _, key in ipairs(order) do
    local group = sortByAngle(groups[key])
    -- Un grupo de una sola ventana no tiene con quién rotar.
    if #group > 1 then
      local mapping = permutation(group, mode)
      for index = 1, #group do
        local source = group[index]
        local target = group[mapping[index]]
        table.insert(moves, {
          address = source.address,
          selector = M.addressSelector(source.address),
          x = target.x,
          y = target.y,
          w = target.w,
          h = target.h,
          resize = swapSizes == true,
        })
      end
    end
  end

  if #moves == 0 then
    if callback ~= nil then
      callback()
    end
    return true
  end

  M.rotating = true
  M.applyGeometry(moves, function()
    M.rotating = false
    if callback ~= nil then
      callback()
    end
  end)
  return true
end

return M
