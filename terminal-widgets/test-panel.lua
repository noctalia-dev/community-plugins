-- Banco de pruebas del plugin `faminec/terminal-widgets`.
--
--   lua5.4 test-panel.lua                       # prueba la copia de este repo
--   lua5.4 test-panel.lua /ruta/otras          # prueba otra copia (la instalada)
--
-- Dos partes:
--
--   1. Módulos de `lib/`: con un API de Noctalia simulado se comprueban la
--      fusión de la lista de widgets, los tombstones, el parser del manifiesto,
--      el parser de posiciones, las zonas ocupadas, la limpieza de miniaturas y
--      las cinco permutaciones de la rotación.
--
--   2. Panel (`panel.luau`): se carga con la UI simulada y se comprueba que
--      las tarjetas, la rejilla, el modo edición y los handlers del IPC hacen
--      lo que deben. Esta parte es la que atrapa los "attempt to call a nil
--      value" (en Luau un `local` solo existe desde su declaración).
--
-- Sale con código distinto de 0 si algún caso falla.

-- El runtime real es Luau, que sí trae `math.atan2`; Lua 5.4 no lo trae (solo
-- desde 5.4.9). `math.atan(y, x)` de Lua 5.4 es atan2, así que se usa como
-- sustituto cuando falta, para que el comando documentado funcione en
-- cualquier Lua 5.4 (5.4.4 de Ubuntu, 5.4.8 de otros sistemas) sin tocar el
-- runtime del plugin.
if type(math.atan2) ~= "function" then
  math.atan2 = math.atan
end

local function scriptDir()
  local self = arg and arg[0] or ""
  return self:match("^(.*)[/\\][^/\\]+$") or "."
end

local DIR = (arg and arg[1]) or (scriptDir() .. "/")
if DIR:sub(-1) ~= "/" then
  DIR = DIR .. "/"
end

local FAILED = 0
local PASSED = 0

local function check(name, expected, got)
  if expected == got then
    PASSED = PASSED + 1
    print(string.format("  ok   %-58s %s", name, tostring(got)))
  else
    FAILED = FAILED + 1
    print(string.format("  FALLA %-58s esperado=%s obtenido=%s", name, tostring(expected), tostring(got)))
  end
end

-- Una comprobación que no aplica en esta ejecución (no cuenta ni como
-- fallo ni como buena): se informa, pero no se puntúa.
local function skip(name, reason)
  print(string.format("  --   %-58s %s", name, tostring(reason or "omitida")))
end

-- --------------------------------------------------------------- simulador --

local files = {}
local TESTDATA = os.tmpname()
local config = {
  terminal = "kitty",
  width = 900,
  height = 520,
  x = 120,
  y = 140,
  margin = 16,
  output = "",
  close_on_launch = false,
  reuse_existing = true,
  rotation = "clockwise",
  rotation_sizes = false,
  columns = 2,
  card_preview = "auto",
  avoid_collisions = true,
  commands = {},
  layouts = {},
}

local clients = {}
local notifications = {}
local rendered = 0
local clock = 0

local function jsonQuote(value)
  return '"' .. tostring(value):gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
end

local function jsonEncode(value)
  if type(value) ~= "table" then
    return tostring(value)
  end
  local parts = {}
  for key, item in pairs(value) do
    if type(item) == "table" then
      local inner = {}
      for k2, v2 in pairs(item) do
        inner[#inner + 1] = jsonQuote(k2) .. ":" .. jsonQuote(v2)
      end
      parts[#parts + 1] = jsonQuote(key) .. ":{" .. table.concat(inner, ",") .. "}"
    else
      parts[#parts + 1] = jsonQuote(key) .. ":" .. jsonQuote(item)
    end
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local mock = {
  getConfig = function(key)
    return config[key]
  end,
  pluginDir = function()
    return DIR
  end,
  pluginDataDir = function()
    -- Ruta temporal: el simulador no escribe nada de verdad en disco.
    return TESTDATA
  end,
  readFile = function(path)
    return files[path]
  end,
  writeFile = function(path, content)
    files[path] = content
    return true
  end,
  mkdirAll = function()
    return true
  end,
  listDir = function()
    local names = {}
    for name in pairs(files) do
      names[#names + 1] = name
    end
    return names
  end,
  removeFile = function(path)
    files[path] = nil
    return true
  end,
  fileExists = function(path)
    return files[path] ~= nil
  end,
  fileInfo = function()
    return { size = 10, mtime = os.time(), isDir = false }
  end,
  json = {
    encode = jsonEncode,
    decode = function(text)
      -- Solo hace falta el formato que produce el simulador: una lista de
      -- objetos con cadenas y números, y el mapa plano del store.
      local trimmed = text:match("^%s*(.-)%s*$")
      if trimmed:sub(1, 1) == "[" then
        local out = {}
        for object in trimmed:gmatch("{(.-)}") do
          local item = {}
          -- En los patrones de Lua la alternancia "|" solo existe al nivel
          -- superior: dentro de un grupo no funciona. Por eso se hace una
          -- pasada para los textos y otra para los números.
          for key, value in object:gmatch('"([^"]+)":"([^"]*)"') do
            item[key] = value
          end
          for key, value in object:gmatch('"([^"]+)":(-?%d+)') do
            if item[key] == nil then
              item[key] = tonumber(value)
            end
          end
          -- Arrays numéricos ("at":[x,y], "size":[w,h]): sin esto el
          -- simulador no vería la geometría de las ventanas.
          for key, array in object:gmatch('"([^"]+)":%[([^%]]*)%]') do
            local numbers = {}
            for number in array:gmatch("-?%d+") do
              numbers[#numbers + 1] = tonumber(number)
            end
            item[key] = numbers
          end
          out[#out + 1] = item
        end
        return out
      end
      local out = {}
      for key, value in trimmed:gmatch('"([^"]+)":"([^"]*)"') do
        out[key] = value
      end
      return out
    end,
  },
  log = function() end,
  tr = function(key, args)
    local out = tostring(key)
    if type(args) == "table" then
      for name, value in pairs(args) do
        out = out:gsub("{" .. name .. "}", tostring(value))
      end
    end
    return out
  end,
  notify = function(title, body)
    notifications[#notifications + 1] = { title = title, body = body }
  end,
  notifyError = function(title, body)
    notifications[#notifications + 1] = { title = title, body = body, error = true }
  end,
  -- Reloj controlado por el test: el debounce de 700 ms depende de él.
  nowMs = function()
    return clock
  end,
  outputs = function()
    return { { name = "DP-1", width = 3440, height = 1440, x = 0, y = 0, scale = 1, focused = true } }
  end,
  commandExists = function()
    return true
  end,
  runInTerminal = function()
    return true
  end,
  runAsync = function(argv, callback)
    local command = table.concat(argv, " ")
    if command:find("hyprctl clients", 1, true) then
      local parts = {}
      for _, client in ipairs(clients) do
        parts[#parts + 1] = string.format(
          '{"address":"%s","class":"%s","title":"%s","at":[%d,%d],"size":[%d,%d],"monitor":"%s"}',
          client.address or "0x0",
          client.class or "",
          client.title or "",
          client.x or 0,
          client.y or 0,
          client.w or 0,
          client.h or 0,
          client.monitor or "1"
        )
      end
      if callback ~= nil then
        callback({ exitCode = 0, stdout = "[" .. table.concat(parts, ",") .. "]", stderr = "" })
      end
      return true
    end
    if command:find("hyprctl monitors", 1, true) then
      if callback ~= nil then
        callback({
          exitCode = 0,
          stdout = '[{"id":1,"name":"DP-1","x":0,"y":0,"width":3440,"height":1440,"scale":1}]',
          stderr = "",
        })
      end
      return true
    end
    if callback ~= nil then
      callback({ exitCode = 0, stdout = "", stderr = "" })
    end
    return true
  end,
}

local function makeNode(kind)
  return function(props, children)
    return { type = kind, props = props or {}, children = children or {} }
  end
end

local uiMock = {
  column = makeNode("column"),
  row = makeNode("row"),
  label = makeNode("label"),
  glyph = makeNode("glyph"),
  image = makeNode("image"),
  box = makeNode("box"),
  button = makeNode("button"),
  input = makeNode("input"),
  scroll = makeNode("scroll"),
  separator = makeNode("separator"),
  spacer = makeNode("spacer"),
}

local lastTree = nil
local panelMock = {
  render = function(tree)
    rendered = rendered + 1
    lastTree = tree
  end,
  close = function() end,
  openContextMenu = function()
    return true
  end,
  setNeedsFrameTick = function() end,
  setWantsSecondTicks = function() end,
}

-- Las expresiones despachadas se recogen aquí (la comparten la sección de
-- rotación y la del panel).
local dispatched = {}

-- ----------------------------------------------------------------- entorno --

local env = setmetatable({
  noctalia = mock,
  panel = panelMock,
  ui = uiMock,
}, { __index = _G })

env.require = function(path)
  local name = path:match("([^/]+)$")
  local chunk = assert(loadfile(DIR .. "lib/" .. name, "t", env))
  return chunk()
end

local function loadModule(name)
  local chunk = assert(loadfile(DIR .. "lib/" .. name, "t", env))
  return chunk()
end

local util = loadModule("util.luau")
local store = loadModule("store.luau")
local layout = loadModule("layout.luau")
local defaults = loadModule("defaults.luau")
local win = loadModule("windows.luau")
local preview = loadModule("preview.luau")

-- --------------------------------------------------------------- utilidades --

print("== utilidades ==")
check("slug", util.slug("Mi Widget!"), "mi-widget")
check("slug vacío", util.slug("!!!"), "app")
check("clase", util.classFor("Cava"), "noctalia-term-cava")
check("trim", util.trim("  hola  "), "hola")

-- ------------------------------------------------------------ fusión de widgets --

print("\n== fusión de widgets ==")
local base = { a = "a-cmd", b = "b-cmd" }
local configMap = { b = "b-cmd-editado", c = "c-cmd" }
local storeMap = { d = "d-cmd" }
local removed = { "a" }

local merged = store.merge(base, configMap, storeMap, removed)
check("la config pisa al default", merged.b, "b-cmd-editado")
check("entrada nueva de la config", merged.c, "c-cmd")
check("entrada nueva del store", merged.d, "d-cmd")
check("el tombstone borra el default", merged.a, nil)
check("sin tombstone se conserva el default", store.merge({ a = "x" }, {}, {}, {}).a, "x")
check("valor vacío de Ajustes se ignora", store.merge({ a = "x" }, { a = "" }, {}, {}).a, "x")
check("valor vacío del store se respeta", store.merge({ a = "x" }, {}, { a = "" }, {}).a, "")
check("el store pisa al default", store.merge({ a = "x" }, {}, { a = "y" }, {}).a, "y")

-- -------------------------------------------------------------- store --

print("\n== store: añadir y borrar ==")
local st = { commands = {}, layouts = {}, removed = {} }
store.upsert(st, "nuevo", "echo hola", "center, 800x400")
check("widget añadido", st.commands.nuevo, "echo hola")
check("posición añadida", st.layouts.nuevo, "center, 800x400")
store.remove(st, "nuevo")
check("widget borrado", st.commands.nuevo, nil)
check("tombstone creado", st.removed[1], "nuevo")
store.upsert(st, "nuevo", "echo hola")
check("tombstone limpiado al volver a añadir", #st.removed, 0)

local stClear = { commands = {}, layouts = {}, thumbs = {}, removed = {} }
store.upsert(stClear, "x", "cmd", "center, 800x400", "/tmp/miniatura.png")
store.upsert(stClear, "x", nil, "", "")
check("layout vacío quita la posición", stClear.layouts.x, nil)
check("thumb vacío quita la miniatura", stClear.thumbs.x, nil)

-- -------------------------------------------------------------- posiciones --

print("\n== posiciones ==")
local spec = layout.parseLayout("bottom-center, 1610x584")
check("ancla", spec.anchor, "bottom-center")
check("ancho", spec.width, 1610)
check("alto", spec.height, 584)

spec = layout.parseLayout("right-center 869x1424")
check("ancla sin coma", spec.anchor, "right-center")
check("ancho sin coma", spec.width, 869)

spec = layout.parseLayout("bottom-left, 802x582, 0, -24")
check("desplazamiento x", spec.dx, 0)
check("desplazamiento y", spec.dy, -24)

spec = layout.parseLayout("custom, 900x520, 120, 140")
check("absoluta", spec.custom, true)
check("absoluta x", spec.dx, 120)
check("absoluta y", spec.dy, 140)

spec = layout.parseLayout("x=120 y=140 w=900 h=520")
check("clave=valor x", spec.dx, 120)
check("clave=valor ancho", spec.width, 900)

spec = layout.parseLayout("auto, 900x520")
check("auto", spec.auto, true)
check("ancla en español", layout.parseLayout("abajo-izquierda, 100x100").anchor, "bottom-left")
check("inválido", layout.parseLayout("no es una posición").valid, false)
check("vacío", layout.parseLayout(""), nil)
check("solo ancla", layout.parseLayout("center").anchor, "center")
check("espacios de más", layout.parseLayout("bottom-center , 1610x584").anchor, "bottom-center")
check("tamaño con espacios", layout.parseLayout("bottom-center , 1610x584").width, 1610)
check("custom sin coordenadas", layout.parseLayout("custom, 900x520").valid, false)
check("auto sin tamaño", layout.parseLayout("auto").auto, true)
check("ancla con guion bajo", layout.parseLayout("bottom_center").anchor, "bottom-center")
check("tamaño negativo", layout.parseLayout("bottom-center, -10x-10").width, nil)

local ax, ay = layout.anchorPosition("bottom-right", 900, 520, 3440, 1440, 16)
check("ancla abajo-derecha x", ax, 3440 - 900 - 16)
check("ancla abajo-derecha y", ay, 1440 - 520 - 16)

-- -------------------------------------------------------------- manifiesto --

print("\n== manifiesto ==")
files[DIR .. "plugin.toml"] = [==[
[[setting]]
key = "commands"
type = "string_map"
label_key = "settings.commands.label"
description_key = "settings.commands.description"
default = { cava = "cava", cbonsai = "cbonsai -l -i", unimatrix = "unimatrix -s 96 -l o" }

[[setting]]
key = "layouts"
type = "string_map"
label_key = "settings.layouts.label"
description_key = "settings.layouts.description"
default = { cava = "bottom-center, 1610x584", cbonsai = "top-center, 801x582" }
]==]
defaults.reset()
local base2 = defaults.load()
check("comandos del manifiesto", base2.commands.cava, "cava")
check("comando con espacios", base2.commands.cbonsai, "cbonsai -l -i")
check("comando con guiones", base2.commands.unimatrix, "unimatrix -s 96 -l o")
check("posición del manifiesto", base2.layouts.cava, "bottom-center, 1610x584")
check("posición con comas", base2.layouts.cbonsai, "top-center, 801x582")

files[DIR .. "plugin.toml"] = "[[setting]]\nkey = \"commands\"\ndefault = { a = \"x\" }\n"
defaults.reset()
local base3 = defaults.load()
check("manifiesto mínimo", base3.commands.a, "x")
check("respaldo de posiciones", base3.layouts.cava, "bottom-center, 1610x584")

files[DIR .. "plugin.toml"] = nil
defaults.reset()
local base4 = defaults.load()
check("sin manifiesto: respaldo", base4.commands.cava, "cava")
check("sin manifiesto: respaldo de posiciones", base4.layouts.unimatrix, "right-center, 869x1424")

-- El manifiesto tiene que declarar todo lo que el plugin lanza: el revisor del
-- upstream lo comprueba contra `dependencies` y contra el README. Se lee el
-- `plugin.toml` real del disco (el simulador solo intercepta `noctalia.readFile`).
local function readRealFile(path)
  local handle = io.open(path, "r")
  if handle == nil then
    return nil
  end
  local content = handle:read("*a")
  handle:close()
  return content
end

local manifestText = readRealFile(DIR .. "plugin.toml")
if manifestText == nil then
  -- El README documenta ejecutar el arnés contra otra copia
  -- (`lua5.4 test-panel.lua /ruta/otra`), y esa copia puede no traer
  -- `plugin.toml`: entonces no hay manifiesto que validar y las
  -- comprobaciones se omiten en vez de fallar.
  skip("las dependencias declaradas", "esta copia no tiene plugin.toml")
else
  local declared = {}
  local block = manifestText:match("dependencies%s*=%s*%[(.-)%]")
  if block ~= nil then
    for name in block:gmatch('"([^"]+)"') do
      declared[name] = true
    end
  end

  check("el manifiesto declara dependencias", true, next(declared) ~= nil)
  check("declara hyprctl", true, declared["hyprctl"] == true)

  -- Cada comando de las tarjetas por defecto tiene que estar declarado: el
  -- ejecutable es la primera palabra del comando. La lista es la de los
  -- valores de fábrica de `lib/defaults.luau` (`base4`, el respaldo que se
  -- usa cuando no hay manifiesto): el manifiesto no define comandos, así que
  -- es la lista de las tarjetas que se instalan de serie.
  for name, command in pairs(base4.commands) do
    local executable = tostring(command):match("^(%S+)")
    check(
      "el comando por defecto '" .. name .. "' está declarado en dependencies",
      true,
      executable ~= nil and declared[executable] == true
    )
  end
end

-- ------------------------------------------------------------ zonas ocupadas --

print("\n== zonas ocupadas ==")
local clientList = {
  { address = "0xa", class = "noctalia-term-cava", x = 915, y = 840, w = 1610, h = 584, monitor = "1" },
  { address = "0xb", class = "noctalia-term-btop", x = 16, y = 16, w = 928, h = 800, monitor = "1" },
  { address = "0xc", class = "kitty", x = 0, y = 0, w = 800, h = 600, monitor = "1" },
}
local monitors = {
  ["1"] = { id = "1", name = "DP-1", x = 0, y = 0, width = 3440, height = 1440 },
}
local occupied = win.occupiedRects(clientList, monitors, "DP-1", nil)
check("solo cuenta las ventanas del plugin", #occupied, 2)
check("la primera zona", occupied[1].x, 915)
check("la segunda zona", occupied[2].y, 16)
local without = win.occupiedRects(clientList, monitors, "DP-1", "0xa")
check("excluye la ventana que se recoloca", #without, 1)
check("la que queda es la otra", without[1].x, 16)

-- --------------------------------------------------------------- miniaturas --

print("\n== miniaturas ==")
local fs = {
  ["btop-aaa.png"] = true,
  ["btop-bbb.png"] = true,
  ["cava-ccc.png"] = true,
  ["batch-1.json"] = true,
}
mock.listDir = function()
  local names = {}
  for name in pairs(fs) do
    names[#names + 1] = name
  end
  return names
end
mock.removeFile = function(path)
  local name = path:match("([^/]+)$")
  fs[name] = nil
  return true
end
mock.fileInfo = function()
  return { size = 10, mtime = os.time() - 7200, isDir = false }
end

local used = preview.currentPaths({
  { name = "btop", x = 10, y = 20, w = 300, h = 200 },
})
local usedCount = 0
for _ in pairs(used) do
  usedCount = usedCount + 1
end
check("currentPaths devuelve dos rutas por ventana (frame + current)", usedCount, 2)
local framePath = nil
for path in pairs(used) do
  if path:match("btop%-v2%-[0-9a-f]+%.png$") then
    framePath = path
    break
  end
end
check("una ruta lleva el nombre y la firma (frame)", framePath ~= nil, true)

local fromMap = preview.currentPaths({ btop = { name = "btop", x = 10, y = 20, w = 300, h = 200 } })
local mapCount = 0
for _ in pairs(fromMap) do
  mapCount = mapCount + 1
end
check("currentPaths acepta un mapa", mapCount, 2)

preview.pruneUnused({ [TESTDATA .. "/thumbs/btop-aaa.png"] = true })
check("conserva la miniatura en uso", fs["btop-aaa.png"], true)
check("borra la que no se usa", fs["btop-bbb.png"], nil)
check("borra la de otro widget", fs["cava-ccc.png"], nil)
check("borra los lotes viejos", fs["batch-1.json"], nil)

fs["btop-bbb.png"] = true
fs["btop-ccc.png"] = true
mock.fileInfo = function(path)
  local name = path:match("([^/]+)$")
  if name == "btop-ccc.png" then
    return { size = 10, mtime = os.time() - 7200, isDir = false }
  end
  return { size = 10, mtime = os.time(), isDir = false }
end
preview.pruneUnused({ [TESTDATA .. "/thumbs/btop-bbb.png"] = true }, 1800)
check("conserva la miniatura en uso", fs["btop-aaa.png"], true)
check("conserva la reciente aunque no se use", fs["btop-bbb.png"], true)
check("borra la antigua que no se usa", fs["btop-ccc.png"], nil)

-- ----------------------------------------------------------------- rotación --

print("\n== rotación: permutaciones ==")
local function fakeWindow(name, x, y, w, h)
  return {
    address = "0x" .. name,
    class = "noctalia-term-" .. name,
    name = name,
    x = x,
    y = y,
    w = w,
    h = h,
    monitor = { id = "1", name = "DP-1", x = 0, y = 0, width = 3440, height = 1440 },
  }
end

local group = {
  fakeWindow("arriba-izq", 16, 16, 900, 800),
  fakeWindow("arriba-der", 2524, 16, 900, 800),
  fakeWindow("abajo-izq", 16, 624, 900, 800),
  fakeWindow("abajo-der", 2524, 624, 900, 800),
}

-- El simulador de procesos: devuelve la lista de ventanas cuando la piden,
-- registra las expresiones despachadas y completa las llamadas de inmediato.
mock.runAsync = function(argv, callback)
  local command = table.concat(argv, " ")
  if command:find("hyprctl dispatch", 1, true) then
    dispatched[#dispatched + 1] = argv[3]
  end
  if command:find("hyprctl clients", 1, true) then
    local parts = {}
    for _, client in ipairs(clients) do
      parts[#parts + 1] = string.format(
        '{"address":"%s","class":"%s","title":"%s","at":[%d,%d],"size":[%d,%d],"monitor":"%s"}',
        client.address or "0x0",
        client.class or "",
        client.title or "",
        client.x or 0,
        client.y or 0,
        client.w or 0,
        client.h or 0,
        client.monitor or "1"
      )
    end
    if callback ~= nil then
      callback({ exitCode = 0, stdout = "[" .. table.concat(parts, ",") .. "]", stderr = "" })
    end
    return true
  end
  if command:find("hyprctl monitors", 1, true) then
    if callback ~= nil then
      callback({
        exitCode = 0,
        stdout = '[{"id":1,"name":"DP-1","x":0,"y":0,"width":3440,"height":1440,"scale":1}]',
        stderr = "",
      })
    end
    return true
  end
  if callback ~= nil then
    callback({ exitCode = 0, stdout = "", stderr = "" })
  end
  return true
end

local function movedTo(address)
  for _, expression in ipairs(dispatched) do
    if expression:find("address:" .. address, 1, true) then
      local mx, my = expression:match("x = (%-?%d+), y = (%-?%d+)")
      return tonumber(mx), tonumber(my)
    end
  end
  return nil, nil
end

win.rotate(group, "clockwise", false, function() end)
local mx, my = movedTo("0xarriba-izq")
check("horario: arriba-izq toma arriba-der", mx, 2524)
check("horario: arriba-izq toma arriba-der (y)", my, 16)
mx, my = movedTo("0xabajo-der")
check("horario: abajo-der toma abajo-izq", mx, 16)
check("horario: abajo-der toma abajo-izq (y)", my, 624)

dispatched = {}
win.rotate(group, "counterclockwise", false, function() end)
mx, my = movedTo("0xarriba-izq")
check("antihorario: arriba-izq toma abajo-izq", mx, 16)
check("antihorario: arriba-izq toma abajo-izq (y)", my, 624)

dispatched = {}
win.rotate(group, "pairs", false, function() end)
mx, my = movedTo("0xarriba-izq")
check("parejas: arriba-izq toma arriba-der", mx, 2524)
check("parejas: arriba-izq toma arriba-der (y)", my, 16)

dispatched = {}
win.rotate(group, "opposite", false, function() end)
mx, my = movedTo("0xarriba-izq")
check("opuesto: arriba-izq toma abajo-der", mx, 2524)
check("opuesto: arriba-izq toma abajo-der (y)", my, 624)

-- Rotación "opposite" geométricamente correcta en cualquier disposición:
-- un cuadrado formado en una sola esquina debe girar por diagonales.
local corner = {
  fakeWindow("c1", 10, 10, 100, 100),
  fakeWindow("c2", 10, 200, 100, 100),
  fakeWindow("c3", 200, 10, 100, 100),
  fakeWindow("c4", 200, 200, 100, 100),
}
dispatched = {}
win.rotate(corner, "opposite", false, function() end)
mx, my = movedTo("0xc1")
check("opuesto en esquina: c1 toma c4 (x)", mx, 200)
check("opuesto en esquina: c1 toma c4 (y)", my, 200)
mx, my = movedTo("0xc2")
check("opuesto en esquina: c2 toma c3 (x)", mx, 200)
check("opuesto en esquina: c2 toma c3 (y)", my, 10)

dispatched = {}
win.rotate(group, "shuffle", false, function() end)
local targets = {}
for _, expression in ipairs(dispatched) do
  local tx, ty = expression:match("x = (%-?%d+), y = (%-?%d+)")
  if tx ~= nil then
    targets[tx .. "," .. ty] = (targets[tx .. "," .. ty] or 0) + 1
  end
end
local unique = 0
for _, count in pairs(targets) do
  if count == 1 then
    unique = unique + 1
  end
end
check("aleatorio: cada destino se usa una vez", unique, #group)

local odd = {
  fakeWindow("arriba-izq", 16, 16, 900, 800),
  fakeWindow("arriba-der", 2524, 16, 900, 800),
  fakeWindow("abajo-izq", 16, 624, 900, 800),
}
dispatched = {}
win.rotate(odd, "pairs", false, function() end)
mx, my = movedTo("0xarriba-izq")
check("parejas impar: arriba-izq toma arriba-der", mx, 2524)
mx, my = movedTo("0xabajo-izq")
check("parejas impar: el que sobra se queda", mx, 16)
check("parejas impar: el que sobra no se mueve (y)", my, 624)

dispatched = {}
win.rotate({ fakeWindow("solo", 16, 16, 900, 800) }, "clockwise", false, function() end)
check("una ventana no se mueve", #dispatched, 0)

dispatched = {}
win.rotate(group, "clockwise", true, function() end)
local resized = false
for _, expression in ipairs(dispatched) do
  if expression:find("resize", 1, true) then
    resized = true
  end
end
check("con tamaños se redimensiona", resized, true)

dispatched = {}
win.rotate(group, "clockwise", false, function() end)
resized = false
for _, expression in ipairs(dispatched) do
  if expression:find("resize", 1, true) then
    resized = true
  end
end
check("sin tamaños no se redimensiona", resized, false)

-- Bloqueo atómico de la rotación.
win.rotating = true
local locked = win.rotate(group, "clockwise", false, function() end)
check("rotación bloqueada mientras gira", false, locked)
win.rotating = false

-- -------------------------------------------------------------------- panel --

print("\n== panel ==")

-- Se carga el panel con la UI simulada. Si usa un global que no existe
-- (un `local` declarado más abajo, por ejemplo), aquí se rompe.
local panelChunk, panelErr = loadfile(DIR .. "panel.luau", "t", env)
if not panelChunk then
  print("  FALLA no se pudo cargar panel.luau: " .. tostring(panelErr))
  os.exit(1)
end
local loaded, loadErr = pcall(panelChunk)
check("el panel se carga sin errores", true, loaded == true)
if not loaded then
  print("  " .. tostring(loadErr))
  os.exit(1)
end

-- Contar nodos del árbol renderizado.
local function countKeys(tree, prefix)
  local total = 0
  local function walk(node)
    if type(node) ~= "table" then
      return
    end
    if type(node.props) == "table" and type(node.props.key) == "string" then
      if node.props.key:sub(1, #prefix) == prefix then
        total = total + 1
      end
    end
    for _, child in ipairs(node.children or {}) do
      walk(child)
    end
  end
  walk(tree)
  return total
end

local function findNode(tree, key)
  local found = nil
  local function walk(node)
    if found ~= nil or type(node) ~= "table" then
      return
    end
    if type(node.props) == "table" and node.props.key == key then
      found = node
      return
    end
    for _, child in ipairs(node.children or {}) do
      walk(child)
    end
  end
  walk(tree)
  return found
end

local function findByPrefix(tree, prefix)
  local found = nil
  local function walk(node)
    if found ~= nil or type(node) ~= "table" then
      return
    end
    if type(node.props) == "table" and type(node.props.key) == "string"
      and node.props.key:sub(1, #prefix) == prefix then
      found = node
      return
    end
    for _, child in ipairs(node.children or {}) do
      walk(child)
    end
  end
  walk(tree)
  return found
end

-- Widgets de prueba: los del manifiesto del propio plugin.
config.commands = {}
config.layouts = {}
local manifestDefaults = defaults.load()
for name, command in pairs(manifestDefaults.commands) do
  config.commands[name] = command
end
for name, position in pairs(manifestDefaults.layouts) do
  config.layouts[name] = position
end
local widgetCount = 0
for _ in pairs(config.commands) do
  widgetCount = widgetCount + 1
end

-- Para que el simulador pueda ejecutar la ruta de captura (y con ella la
-- poda de miniaturas) hace falta que las herramientas estén disponibles:
-- `preview.toolsAvailable()` comprueba el script de captura.
files[(DIR:gsub("/+$", "")) .. "/bin/snapshot.py"] = "#!/usr/bin/env python3\n"

-- Regresión: la poda no puede borrar el fichero que una tarjeta está
-- pintando. Con el widget cerrado la tarjeta muestra su miniatura "current",
-- y si la poda la borra el host avisa "image failed to load" y sale en negro.
fs["cava-v2-current.png"] = true
mock.fileInfo = function(path)
  local name = path:match("([^/]+)$")
  if name == "cava-v2-current.png" or name == "btop-ccc.png" then
    return { size = 10, mtime = os.time() - 7200, isDir = false }
  end
  return { size = 10, mtime = os.time(), isDir = false }
end

env.onOpen("")
check("el panel abre y renderiza", true, rendered > 0)
check("hay una tarjeta por widget", widgetCount, countKeys(lastTree, "card-"))
check("la poda no borra la miniatura que se está pintando", true, fs["cava-v2-current.png"])

-- El manifiesto se analiza una vez, pero al abrir el panel se relee: si el
-- .toml cambia en caliente y no hay config de usuario, se usan los nuevos defaults.
local manifestFixture = files[DIR .. "plugin.toml"]
files[DIR .. "plugin.toml"] = [==[
[[setting]]
key = "commands"
default = { nuevo = "un-comando --nuevo" }
]==]
-- Simular que el usuario no tiene config en Settings (config vacío)
local oldConfig = config
config = {}
defaults.reset()
env.onOpen("")
local freshCard = findNode(lastTree, "card-nuevo")
check(
  "al abrir se relee el manifiesto (sin config usuario)",
  true,
  freshCard ~= nil and tostring(freshCard.props.tooltip):find("un-comando --nuevo", 1, true) ~= nil
)
files[DIR .. "plugin.toml"] = manifestFixture
config = oldConfig
defaults.reset()
env.onOpen("")
check("la cabecera tiene el botón de abrir todo", true, findNode(lastTree, "open-all") ~= nil)
check("la cabecera tiene el botón de rotar", true, findNode(lastTree, "rotate") ~= nil)
check("la cabecera tiene el botón de cerrar todo", true, findNode(lastTree, "close-all") ~= nil)
check("la cabecera tiene el botón de editar", true, findNode(lastTree, "edit") ~= nil)
check("la cabecera tiene el botón de ajustes", true, findNode(lastTree, "open-settings") ~= nil)
check("la cabecera tiene el botón de cerrar", true, findNode(lastTree, "close-panel") ~= nil)

local cardNode = findNode(lastTree, "card-" .. (config.commands and "btop" or "btop"))
if cardNode == nil then
  -- Se busca la primera tarjeta por el orden alfabético.
  local names = {}
  for name in pairs(config.commands) do
    names[#names + 1] = name
  end
  table.sort(names)
  cardNode = findNode(lastTree, "card-" .. names[1])
end
check("la tarjeta lleva el comando en el tooltip", true, cardNode ~= nil and cardNode.props.tooltip ~= nil and cardNode.props.tooltip:len() > 0)
check("la tarjeta se puede pulsar", true, cardNode ~= nil and cardNode.props.onClick ~= nil)
check("la tarjeta tiene ancho fijo (tamaño uniforme)", true, cardNode ~= nil and cardNode.props.width ~= nil)
check("la tarjeta no crece en filas parciales", nil, cardNode ~= nil and cardNode.props.flexGrow)

-- Modo edición: aparecen el formulario y los botones de borrar.
local editButton = findNode(lastTree, "edit")
check("el botón de editar tiene manejador", true, editButton ~= nil and editButton.props.onClick ~= nil)
if editButton ~= nil and editButton.props.onClick ~= nil then
  editButton.props.onClick()
  check("en modo edición aparece el formulario", true, findNode(lastTree, "editor") ~= nil)
  check("en modo edición hay un botón de borrar", true, countKeys(lastTree, "delete-") > 0)

  -- El editor de un widget existente se coloca en el sitio de su tarjeta.
  local firstName = nil
  do
    local names = {}
    for name in pairs(config.commands) do
      names[#names + 1] = name
    end
    table.sort(names)
    firstName = names[1]
  end
  local editWidget = findByPrefix(lastTree, "edit-" .. firstName)
  check("la tarjeta tiene botón de editar", true, editWidget ~= nil)
  if editWidget ~= nil and editWidget.props.onClick ~= nil then
    editWidget.props.onClick()
    check("el editor sustituye a la tarjeta editada", nil, findNode(lastTree, "card-" .. firstName))
    check("el editor sigue visible al editar", true, findNode(lastTree, "editor") ~= nil)
    local thumbField = findByPrefix(lastTree, "form-thumb-")
    check(
      "el campo de miniatura empieza vacío",
      "",
      thumbField ~= nil and thumbField.props.value or "sin campo"
    )
    local headerEdit = findNode(lastTree, "edit")
    if headerEdit ~= nil and headerEdit.props.onClick ~= nil then
      headerEdit.props.onClick()
    end
    check("al cancelar vuelve la tarjeta", true, findNode(lastTree, "card-" .. firstName) ~= nil)

    -- Renombrar a otro widget existente se rechaza (no se pisa el otro).
    local names = {}
    for name in pairs(config.commands) do
      names[#names + 1] = name
    end
    table.sort(names)
    if names[2] ~= nil then
      editWidget.props.onClick()
      local nameField = findByPrefix(lastTree, "form-name-")
      local saveButton = findByPrefix(lastTree, "editor-save-")
      if nameField ~= nil and saveButton ~= nil then
        nameField.props.onChange(names[2])
        saveButton.props.onClick()
        check(
          "renombrar a un widget existente se rechaza",
          "name_exists",
          notifications[#notifications] ~= nil and notifications[#notifications].body or "sin aviso"
        )
        if headerEdit ~= nil and headerEdit.props.onClick ~= nil then
          headerEdit.props.onClick()
        end
      end
    end
  end
end

-- Los handlers del IPC no deben romperse.
local before = rendered
env.onIpc("refresh", "")
check("el IPC refresh no falla", true, rendered >= before)
env.onIpc("rotate", "")
check("el IPC rotate no falla", true, true)
env.onIpc("open-all", "")
check("el IPC open-all no falla", true, true)
env.onIpc("close-all", "")
check("el IPC close-all no falla", true, true)
env.onIpc("add", "prueba|echo hola|center, 500x300")
check("el IPC add no falla", true, true)
env.onIpc("remove", "prueba")
check("el IPC remove no falla", true, true)
env.onIpc("launch", "cava")
check("el IPC launch no falla", true, true)

-- ------------------------------------------------------------- la rejilla --

-- Cuenta las filas de tarjetas del árbol renderizado.
local function cardRows(tree)
  local rows = 0
  local function walk(node)
    if type(node) ~= "table" then
      return
    end
    local isRow = false
    for _, child in ipairs(node.children or {}) do
      if type(child) == "table" and type(child.props) == "table"
        and type(child.props.key) == "string" and child.props.key:sub(1, 5) == "card-" then
        isRow = true
      end
    end
    if isRow then
      rows = rows + 1
    end
    for _, child in ipairs(node.children or {}) do
      walk(child)
    end
  end
  walk(tree)
  return rows
end

env.onOpen("")
config.columns = 2
env.onIpc("refresh", "")
check("rejilla de 2 columnas: 6 widgets = 3 filas", 3, cardRows(lastTree))
config.columns = 3
env.onIpc("refresh", "")
check("rejilla de 3 columnas: 6 widgets = 2 filas", 2, cardRows(lastTree))
config.columns = 1
env.onIpc("refresh", "")
check("rejilla de 1 columna: 6 widgets = 6 filas", 6, cardRows(lastTree))
config.columns = 2
env.onIpc("refresh", "")

-- ------------------------------------------------- lanzar y recolocar --

local function dispatchText()
  return table.concat(dispatched, "\n")
end

local function clickCard(name)
  local node = findNode(lastTree, "card-" .. name)
  if node ~= nil and node.props.onClick ~= nil then
    node.props.onClick()
  end
end

-- El debounce ignora un segundo clic seguido.
clock = clock + 5000
dispatched = {}
clickCard("btop")
local firstLaunch = dispatchText():find("noctalia%-term%-btop") ~= nil
dispatched = {}
clickCard("btop")
check("pulsar una tarjeta lanza su widget", true, firstLaunch)
check("un segundo clic seguido no lanza otra ventana", false, dispatchText():find("exec_cmd") ~= nil)

clock = clock + 5000
dispatched = {}
clickCard("btop")
check("pasado el debounce se vuelve a lanzar", true, dispatchText():find("exec_cmd") ~= nil)
check("la ventana se coloca en su posición configurada", true, dispatchText():find("move%({ x = 16, y = 16") ~= nil)

-- Si el widget ya está abierto, al volver a pulsarlo tiene que volver a su
-- sitio (no a un hueco cualquiera): la evitación de colisiones no puede
-- contarse a sí misma. En modo "custom" debe volver a su posición configurada.
config.fallback_mode = "custom"
clients = {
  { address = "0x1", class = "noctalia-term-btop", x = 2000, y = 900, w = 928, h = 800, monitor = "1" },
}
env.onOpen("")
clock = clock + 5000
dispatched = {}
clickCard("btop")
check("un widget ya abierto vuelve a su posición", true, dispatchText():find("move%({ x = 16, y = 16") ~= nil)
check("y no se lanza una segunda ventana", true, dispatchText():find("exec_cmd") == nil)
check("botón de cerrar en widget abierto", true, (function()
    local closeBtn = findNode(lastTree, "close-btop")
    return closeBtn ~= nil and closeBtn.props and closeBtn.props.onClick ~= nil
  end)())
clients = {}

-- ------------------------------------------------- borrar desde el panel --

env.onOpen("")
local editButton2 = findNode(lastTree, "edit")
if editButton2 ~= nil and editButton2.props.onClick ~= nil then
  editButton2.props.onClick()
end
local deleteButton = findNode(lastTree, "delete-btop")
check("hay un botón de borrar por tarjeta", true, deleteButton ~= nil)
if deleteButton ~= nil and deleteButton.props.onClick ~= nil then
  deleteButton.props.onClick()
end
check("al borrar, la tarjeta desaparece", false, findNode(lastTree, "card-btop") ~= nil)
check("y el widget ya no está en la lista", false, (lastTree ~= nil) and findNode(lastTree, "card-btop") ~= nil)

-- ------------------------------------------- fallback: layout y aleatorio --

-- El layout de un widget se respeta al abrirlo (dirección y tamaño), pero
-- cuando ya está abierto y se pulsa su miniatura en modo "random", se mueve a
-- un hueco libre conservando el tamaño que tiene.
config.fallback_mode = "random"
config.fallback_random_resize = false
clients = {}
env.onIpc("add", "suelto|echo hola|")
env.onIpc("add", "anclado|echo hola|top-left, 928x800")
env.onOpen("")

-- "suelto" no tiene layout: se abre en un hueco libre con el tamaño de
-- respaldo.
clock = clock + 5000
dispatched = {}
clickCard("suelto")
local spawnText = dispatchText()
local openedSize = spawnText:match("size = { (%d+, %d+) }")
check("un widget sin layout se abre con el tamaño de respaldo", "900, 520", openedSize)
check("y en una posición libre (no la de respaldo)", false, spawnText:find("move = { 120, 140") ~= nil)

-- "anclado" tiene layout: al abrirlo se respetan su dirección y su tamaño.
clock = clock + 5000
dispatched = {}
clickCard("anclado")
local anchoredText = dispatchText()
check("un widget con layout se abre en su posición", true, anchoredText:find("move = { 16, 16") ~= nil)
check("con su tamaño definido", true, anchoredText:find("size = { 928, 800") ~= nil)

-- Si ya está abierto y se vuelve a pulsar, en modo random se recoloca a un
-- hueco libre, pero conserva el tamaño que tiene ahora (no el del layout).
clients = {
  { address = "0x1", class = "noctalia-term-anclado", x = 2000, y = 900, w = 600, h = 400, monitor = "1" },
}
env.onOpen("")
clock = clock + 5000
dispatched = {}
clickCard("anclado")
local movedText = dispatchText()
check("un widget abierto se recoloca en modo random", false, movedText:find("move = { 16, 16") ~= nil)
check("y conserva su tamaño actual", true, movedText:find("resize%({ x = 600, y = 400") ~= nil)

-- Con "cambiar tamaño también" activo, el tamaño también se sortea.
config.fallback_random_resize = true
env.onOpen("")
clock = clock + 5000
dispatched = {}
clickCard("anclado")
local resizedText = dispatchText()
local randomSize = resizedText:match("resize%({ x = (%d+), y = (%d+)")
local sameSize = resizedText:find("resize%({ x = 600, y = 400") ~= nil
check("con resize activo el tamaño se vuelve a sortear", false, sameSize)
check("y el tamaño aleatorio está dentro del rango", true, randomSize ~= nil)

config.fallback_random_resize = false
config.fallback_mode = "custom"
clients = {}


-- ------------------------------------------------------------- ticks de frame --

print("\n== ticks de frame ==")

-- El host solo entrega `onFrameTick` cuando se le pide con
-- `panel.setNeedsFrameTick(true)`. En modo automático las tarjetas cerradas
-- animan sus capturas, así que tienen que pedir ticks: sin ellos la
-- animación se queda congelada en el primer fotograma.
local frameTicks = {}
panelMock.setNeedsFrameTick = function(value)
  frameTicks[#frameTicks + 1] = value
end

-- Un widget con dos capturas y sin ventana abierta. La lista de widgets vive
-- en el store, así que se añade por el IPC (el camino real del plugin).
-- Las capturas se.existían antes: la lista de fotogramas se cachea, y el
-- reloj del simulador no avanza.
fs["anim-1.png"] = true
fs["anim-2.png"] = true
local frameReads = 0
local previousFileInfo = mock.fileInfo
mock.fileInfo = function(path)
  local name = path:match("([^/]+)$")
  -- Cada relectura de la lista de fotogramas llama a `fileInfo` una vez por
  -- fotograma: contando estas llamadas se sabe cuántas veces se ha releído
  -- el disco para este widget.
  if name:match("^anim%-") then
    frameReads = frameReads + 1
  end
  -- Mtimes distintos: el orden de los fotogramas no depende del desempate
  -- del `table.sort` (que no es estable).
  if name == "anim-1.png" then
    return { size = 10, mtime = os.time() - 10, isDir = false }
  end
  if name == "anim-2.png" then
    return { size = 10, mtime = os.time(), isDir = false }
  end
  return previousFileInfo(path)
end

-- Los casos de los ticks necesitan saber exactamente qué widgets hay: se
-- vacían los que dejaron las secciones anteriores.
local function cardNames()
  local names = {}
  local function walk(node)
    if type(node) ~= "table" then
      return
    end
    if type(node.props) == "table" and type(node.props.key) == "string"
      and node.props.key:sub(1, 5) == "card-" then
      names[#names + 1] = node.props.key:sub(6)
    end
    for _, child in ipairs(node.children or {}) do
      walk(child)
    end
  end
  walk(lastTree)
  return names
end
for _, name in ipairs(cardNames()) do
  env.onIpc("remove", name)
end

frameTicks = {}
env.onOpen("")
check("sin tarjetas no se piden ticks de frame", false, frameTicks[#frameTicks])

-- Una tarjeta con una sola captura no tiene nada que animar: no hay
-- fotogramas que alternar, así que pedir ticks sería un bucle vacío.
fs["uno-1.png"] = true
env.onIpc("add", "uno|uno|center, 500x300")
check("una tarjeta con una sola captura no pide ticks de frame", false, frameTicks[#frameTicks])

env.onIpc("add", "anim|anim|center, 500x300")

frameTicks = {}
env.onOpen("")
local lastTick = frameTicks[#frameTicks]
check("en modo auto con capturas se piden ticks de frame", true, lastTick == true)

-- La imagen que pinta una tarjeta (para ver qué fotograma se muestra).
local function cardImage(name)
  local card = findNode(lastTree, "card-" .. name)
  if card == nil then
    return nil
  end
  local found = nil
  local function walk(node)
    if found ~= nil or type(node) ~= "table" then
      return
    end
    if node.type == "image" and type(node.props) == "table" and node.props.path ~= nil then
      found = node.props.path
      return
    end
    for _, child in ipairs(node.children or {}) do
      walk(child)
    end
  end
  walk(card)
  return found
end

local frameBefore = cardImage("anim")
check("la tarjeta con capturas pinta un fotograma", true, frameBefore ~= nil)
env.onFrameTick(300)
local frameAfter = cardImage("anim")
check(
  "la animación de la tarjeta cerrada avanza",
  true,
  frameAfter ~= nil and frameBefore ~= nil and frameAfter ~= frameBefore
)

-- Los ticks no pueden releer el disco en cada frame: la lista de fotogramas
-- se relee solo cuando toca avanzar (cada 250 ms). Con 60 ticks de 16 ms
-- (casi un segundo) hay como mucho cuatro ventanas de 250 ms, así que las
-- lecturas del disco tienen a ser unas pocas, no una por tick.
--
-- El reloj del simulador avanza con cada tick a propósito: si no, la caché
-- de un segundo de `preview.frames` taparía las lecturas que se cuentan.
frameReads = 0
for _ = 1, 60 do
  clock = clock + 1000
  env.onFrameTick(16)
end
check(
  "los ticks no releen el disco en cada frame",
  true,
  frameReads <= 24
)

-- Al borrar una tarjeta su entrada en la tabla de animaciones es basura:
-- si se queda, el panel seguiría pidiendo ticks para algo que ya no existe.
env.onIpc("remove", "anim")
check("al borrar una tarjeta animada se apagan los ticks de frame", false, frameTicks[#frameTicks])
env.onIpc("remove", "uno")
check("al borrar la última tarjeta se apagan los ticks de frame", false, frameTicks[#frameTicks])

-- En modo mock no hay nada que animar: los ticks se apagan.
config.card_preview = "mock"
frameTicks = {}
env.onOpen("")
check("en modo mock no se piden ticks de frame", false, frameTicks[#frameTicks])
config.card_preview = "auto"
mock.fileInfo = previousFileInfo

print(string.format("\n%d comprobaciones, %d fallos", PASSED + FAILED, FAILED))
os.exit(FAILED == 0 and 0 or 1)
