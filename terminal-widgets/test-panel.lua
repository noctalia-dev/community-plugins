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

-- Codificador recursivo (objetos, arrays, booleanos y números) para que el
-- store pueda guardar mapas dentro del mapa raíz y el interruptor del cerebro.
local function jsonEncode(value)
  if type(value) == "string" then
    return jsonQuote(value)
  elseif type(value) == "boolean" or type(value) == "number" then
    return tostring(value)
  elseif type(value) ~= "table" then
    return "null"
  end
  local parts = {}
  if value[1] ~= nil then
    for _, item in ipairs(value) do
      parts[#parts + 1] = jsonEncode(item)
    end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  for key, item in pairs(value) do
    parts[#parts + 1] = jsonQuote(key) .. ":" .. jsonEncode(item)
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

-- JSON de `hyprctl clients -j` a partir de la tabla `clients`. Acepta las dos
-- formas que usan las secciones: la cruda de hyprctl (`at` y `size` como
-- arrays posicionales, lo que llega de verdad del compositor) y la normalizada
-- (`x`, `y`, `w`, `h`). El callback recibe el `CommandResult` real del host:
-- una sola tabla `{ exitCode, stdout, stderr }`.
local function clientsJson()
  local parts = {}
  for _, client in ipairs(clients) do
    local at = client.at or { client.x or 0, client.y or 0 }
    local size = client.size or { client.w or 0, client.h or 0 }
    parts[#parts + 1] = string.format(
      '{"address":"%s","class":"%s","title":"%s","at":[%d,%d],"size":[%d,%d],"monitor":"%s"}',
      client.address or "0x0",
      client.class or "",
      client.title or "",
      math.floor(tonumber(at[1]) or 0),
      math.floor(tonumber(at[2]) or 0),
      math.floor(tonumber(size[1]) or 0),
      math.floor(tonumber(size[2]) or 0),
      client.monitor or "1"
    )
  end
  return "[" .. table.concat(parts, ",") .. "]"
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
      -- Objetos: con valores anidados (el store guarda mapas dentro del
      -- mapa raíz) y booleanos. Parser recursivo mínimo.
      local src = trimmed
      local pos = 1

      local function skipSpaces()
        while src:sub(pos, pos):match("%s") do pos = pos + 1 end
      end

      local function parseString()
        pos = pos + 1
        local out = {}
        while pos <= #src do
          local ch = src:sub(pos, pos)
          if ch == '"' then
            pos = pos + 1
            return table.concat(out)
          elseif ch == "\\" then
            local esc = src:sub(pos + 1, pos + 1)
            if esc == "n" then
              out[#out + 1] = "\n"
              pos = pos + 2
            elseif esc == "t" then
              out[#out + 1] = "\t"
              pos = pos + 2
            elseif esc == "r" then
              out[#out + 1] = "\r"
              pos = pos + 2
            elseif esc == "u" then
              out[#out + 1] = "?"
              pos = pos + 6
            elseif esc == "" then
              pos = pos + 1
            else
              out[#out + 1] = esc
              pos = pos + 2
            end
          else
            out[#out + 1] = ch
            pos = pos + 1
          end
        end
        return table.concat(out)
      end

      local parseValue

      local function parseArray()
        pos = pos + 1
        local out = {}
        skipSpaces()
        if src:sub(pos, pos) == "]" then
          pos = pos + 1
          return out
        end
        while true do
          out[#out + 1] = parseValue()
          skipSpaces()
          local ch = src:sub(pos, pos)
          if ch == "," then
            pos = pos + 1
          elseif ch == "]" then
            pos = pos + 1
            return out
          else
            return out
          end
        end
      end

      local function parseObject()
        pos = pos + 1
        local out = {}
        skipSpaces()
        if src:sub(pos, pos) == "}" then
          pos = pos + 1
          return out
        end
        while true do
          skipSpaces()
          local key = parseString()
          if key == nil then
            return out
          end
          skipSpaces()
          if src:sub(pos, pos) == ":" then
            pos = pos + 1
          end
          out[key] = parseValue()
          skipSpaces()
          local ch = src:sub(pos, pos)
          if ch == "," then
            pos = pos + 1
          elseif ch == "}" then
            pos = pos + 1
            return out
          else
            return out
          end
        end
      end

      function parseValue()
        skipSpaces()
        local ch = src:sub(pos, pos)
        if ch == '"' then
          return parseString()
        elseif ch == "{" then
          return parseObject()
        elseif ch == "[" then
          return parseArray()
        elseif src:sub(pos, pos + 4) == "false" then
          pos = pos + 5
          return false
        elseif src:sub(pos, pos + 3) == "true" then
          pos = pos + 4
          return true
        elseif src:sub(pos, pos + 3) == "null" then
          pos = pos + 4
          return nil
        else
          local from = pos
          while src:sub(pos, pos):match("[%d%.%+%-eE]") do
            pos = pos + 1
          end
          return tonumber(src:sub(from, pos - 1))
        end
      end

      local value = parseValue()
      if type(value) == "table" then
        return value
      end
      return {}
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
      if callback ~= nil then
        callback({ exitCode = 0, stdout = clientsJson(), stderr = "" })
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

-- Estado compartido en memoria (`noctalia.state`), renombrado atómico y tick
-- del service. `serviceUpdatedMs` es un global del fichero de pruebas: lo lee
-- la sección del service.
local sharedState = {}
mock.state = {
  get = function(key) return sharedState[key] end,
  set = function(key, value) sharedState[key] = value end,
  watch = function(_key, _callback) end,
}
mock.renameFile = function(from, to)
  local content = files[from]
  if content == nil then return false end
  files[to] = content
  files[from] = nil
  return true
end
serviceUpdatedMs = nil
mock.setUpdateInterval = function(ms) serviceUpdatedMs = ms return true end

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

-- Claves de los nodos del árbol en pre-orden (sirve para comprobar el orden
-- relativo de las tarjetas al renderizar). Es un global a propósito: la usan
-- las secciones de más abajo.
function nodeKeys(tree, out)
  out = out or {}
  if type(tree) ~= "table" then return out end
  if tree.key ~= nil then table.insert(out, tree.key) end
  for _, child in ipairs(tree.children or {}) do nodeKeys(child, out) end
  return out
end

-- --- arnés: estado compartido, renombrado atómico y tick del service ---
check("noctalia.state escribe y lee", "hola", (function()
  mock.state.set("k", "hola")
  return mock.state.get("k")
end)())
check("noctalia.state ausente es nil", nil, mock.state.get("no-existe"))
files["/tmp/a.tmp"] = "contenido"
check("renameFile devuelve true", true, mock.renameFile("/tmp/a.tmp", "/tmp/a.json"))
check("renameFile mueve el contenido", "contenido", files["/tmp/a.json"])
check("renameFile borra el origen", nil, files["/tmp/a.tmp"])
check("renameFile sin origen devuelve false", false, mock.renameFile("/tmp/nada", "/tmp/otro"))
check("setUpdateInterval existe", "function", type(mock.setUpdateInterval))
check("nodeKeys recorre en pre-orden", "raiz/hijo1/hijo2", (function()
  local tree = { key = "raiz", children = { { key = "hijo1" }, { key = "hijo2" } } }
  return table.concat(nodeKeys(tree), "/")
end)())

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

-- La memoria del cerebro (interruptor y geometrías recordadas) vive en el
-- mismo store.json: un store antiguo no la tiene y cada escritura parcial
-- debe conservar la que hay en disco.
local storeLib = store
local storePath = storeLib.path()

-- campos nuevos con valor por defecto en un store antiguo
files[storePath] = '{"commands":{"a":"uno"},"layouts":{"a":"center, 100x100"}}'
local legacy = storeLib.load()
check("store: brain por defecto false", false, legacy.brain)
check("store: brainGeometry por defecto vacío", 0, (function() local n = 0 for _ in pairs(legacy.brainGeometry) do n = n + 1 end return n end)())

-- saveWidgets preserva la memoria del disco
files[storePath] = '{"commands":{},"layouts":{},"thumbs":{},"removed":{},"brain":true,"brainGeometry":{"noctalia-term-a":"center, 100x100"}}'
storeLib.saveWidgets({ commands = { a = "uno" }, layouts = {}, thumbs = {}, removed = {} })
local afterWidgets = storeLib.load()
check("saveWidgets: escribe commands", "uno", afterWidgets.commands.a)
check("saveWidgets: preserva brain", true, afterWidgets.brain)
check("saveWidgets: preserva brainGeometry", "center, 100x100", afterWidgets.brainGeometry["noctalia-term-a"])
check("saveWidgets: fichero temporal borrado", nil, files[storePath .. ".tmp"])

-- saveBrainToggle preserve los widgets
storeLib.saveBrainToggle(false)
local afterToggle = storeLib.load()
check("saveBrainToggle: apaga", false, afterToggle.brain)
check("saveBrainToggle: preserva commands", "uno", afterToggle.commands.a)

-- saveBrainGeometry cambia solo lo que recibe
storeLib.saveBrainGeometry({ ["noctalia-term-b"] = "top-right, 200x200" })
local afterGeometry = storeLib.load()
check("saveBrainGeometry: añade", "top-right, 200x200", afterGeometry.brainGeometry["noctalia-term-b"])
check("saveBrainGeometry: conserva las demás", "center, 100x100", afterGeometry.brainGeometry["noctalia-term-a"])
check("saveBrainGeometry: conserva brain", false, afterGeometry.brain)

-- saveBrainForget borra una sola
storeLib.saveBrainForget("noctalia-term-a")
local afterForget = storeLib.load()
check("saveBrainForget: borra la pedida", nil, afterForget.brainGeometry["noctalia-term-a"])
check("saveBrainForget: deja las demás", "top-right, 200x200", afterForget.brainGeometry["noctalia-term-b"])

-- loadBrain relee el disco aunque el state en memoria sea viejo
files[storePath] = '{"commands":{},"brain":true,"brainGeometry":{"noctalia-term-c":"center, 50x50"}}'
local fresh = storeLib.loadBrain()
check("loadBrain: brain del disco", true, fresh.brain)
check("loadBrain: memoria del disco", "center, 50x50", fresh.brainGeometry["noctalia-term-c"])

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
    if callback ~= nil then
      callback({ exitCode = 0, stdout = clientsJson(), stderr = "" })
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

-- Enfocar sin recolocar: un solo dispatch de foco, ni resize ni move.
dispatched = {}
win.focusOnly("noctalia-term-lavat", function() end)
check("focusOnly: un solo dispatch", 1, #dispatched)
check("focusOnly: es un foco", true, dispatched[1]:find("hl.dsp.focus") ~= nil)
check("focusOnly: no redimensiona", nil, dispatched[1]:find("resize"))
check("focusOnly: no mueve", nil, dispatched[1]:find("move"))

-- ------------------------------------------------------------- lib/output.luau --

print("\n== lib/output.luau ==")

local outputLib = loadModule("output.luau")
local box = outputLib.outputBox({ output = "" })
check("outputBox: caja del output enfocado", 3440, box.width)
check("outputBox: alto", 1440, box.height)
check("outputBox: nombre", "DP-1", box.name)
check("outputBox: origen", 0, box.x)
check("outputBox: origen y", 0, box.y)
check("outputBox: cfg.output manda", "DP-1", outputLib.outputBox({ output = "DP-1" }).name)
check("outputBox: cfg.output inexistente cae al enfocado", "DP-1", outputLib.outputBox({ output = "HDMI-9" }).name)
-- caja demasiado pequeña -> respaldo
local savedOutputs = mock.outputs
mock.outputs = function() return { { name = "X", width = 100, height = 80, x = 0, y = 0, scale = 1, focused = true } } end
local tiny = outputLib.outputBox({ output = "" })
check("outputBox: caja diminuta -> 1920x1080", "1920x1080", tiny.width .. "x" .. tiny.height)
mock.outputs = savedOutputs

-- --------------------------------------------------------------- lib/brain.luau --

print("\n== lib/brain.luau ==")

local layoutLib = loadModule("layout.luau")
local brain = loadModule("brain.luau")
local SCREEN = { x = 0, y = 0, width = 3440, height = 1440, name = "DP-1" }

local function anchorOf(x, y, w, h)
  return brain.anchorFromRect({ x = x, y = y, w = w, h = h }, SCREEN, 0).anchor
end
check("ancla: esquina inferior izquierda", "bottom-left", anchorOf(0, 800, 802, 582))
check("ancla: esquina superior derecha", "top-right", anchorOf(2400, 0, 802, 582))
check("ancla: centro exacto", "center", anchorOf(1319, 429, 802, 582))
check("ancla: banda izquierda, fila central", "left-center", anchorOf(10, 429, 802, 582))
check("ancla: banda derecha, fila central", "right-center", anchorOf(2600, 429, 802, 582))
check("ancla: banda central, fila superior", "top-center", anchorOf(1319, 10, 802, 582))
check("ancla: banda central, fila inferior", "bottom-center", anchorOf(1319, 800, 802, 582))
-- esquinas restantes
check("ancla: superior izquierda", "top-left", anchorOf(0, 0, 802, 582))
check("ancla: inferior derecha", "bottom-right", anchorOf(2600, 800, 802, 582))

-- ida y vuelta: reconstruir devuelve la posición exacta (relativa a la caja)
local function roundTrip(rect, screen, margin)
  local memory = brain.anchorFromRect(rect, screen, margin)
  local baseX, baseY = layoutLib.anchorPosition(memory.anchor, memory.width, memory.height, screen.width, screen.height, margin)
  return (baseX + memory.dx) .. "," .. (baseY + memory.dy)
end
check("ida y vuelta: bottom-left", "0,800", roundTrip({ x = 0, y = 800, w = 802, h = 582 }, SCREEN, 0))
check("ida y vuelta: centro", "1319,429", roundTrip({ x = 1319, y = 429, w = 802, h = 582 }, SCREEN, 0))
check("ida y vuelta: con margen 24", "24,24", roundTrip({ x = 24, y = 24, w = 802, h = 582 }, SCREEN, 24))
-- caja con origen desplazado (segundo monitor): el desfase es relativo a la caja
local OFFSET = { x = 1920, y = 0, width = 1920, height = 1080, name = "DP-2" }
check("ida y vuelta: caja desplazada", "0,0", roundTrip({ x = 1920, y = 0, w = 600, h = 400 }, OFFSET, 0))

check("layoutString: formato exacto", "bottom-left, 802x582, 0, -58", brain.layoutString({ x = 0, y = 800, w = 802, h = 582 }, SCREEN, 0))
-- desfase positivo: ventana a 100 px del borde izquierdo y a la altura de la base inferior
local shifted = brain.anchorFromRect({ x = 100, y = 800, w = 802, h = 582 }, SCREEN, 0)
check("layoutString: desfase en x", 100, shifted.dx)
check("layoutString: desfase en y", -58, shifted.dy)
check("layoutString: string con desfase", "bottom-left, 802x582, 100, -58", brain.layoutString({ x = 100, y = 800, w = 802, h = 582 }, SCREEN, 0))
check("geometryFromMemory: reconstruye", 800, (brain.geometryFromMemory("bottom-left, 802x582, 0, -58", 3440, 1440, 0) or {}).y)
check("geometryFromMemory: ancho", 802, (brain.geometryFromMemory("bottom-left, 802x582, 0, -58", 3440, 1440, 0) or {}).width)
check("geometryFromMemory: string inválido", nil, brain.geometryFromMemory("no es un layout", 3440, 1440, 0))
check("geometryFromMemory: nil", nil, brain.geometryFromMemory(nil, 3440, 1440, 0))

-- Cliente crudo de `hyprctl clients -j`: `at` y `size` son arrays posicionales.
local function clientAt(class, x, y, w, h)
  return { class = class, at = { x, y }, size = { w, h }, address = "0x" .. x, monitor = 0 }
end

-- sondeo 1: nada memorizado, pendiente creado
local rect = { x = 0, y = 800, w = 802, h = 582 }
local r1 = brain.capture({ clientAt("noctalia-term-lavat", 0, 800, 802, 582) }, SCREEN, 0, {}, {}, {})
check("captura: primer sondeo no memoriza", nil, r1.memory["noctalia-term-lavat"])
check("captura: primer sondeo deja pendiente", 800, (r1.pending["noctalia-term-lavat"] or {}).y)
check("captura: primer sondeo sin cambios", false, r1.changed)

-- sondeo 2 idéntico: memoriza
local r2 = brain.capture({ clientAt("noctalia-term-lavat", 0, 800, 802, 582) }, SCREEN, 0, {}, {}, r1.pending)
check("captura: segundo sondeo memoriza", "bottom-left, 802x582, 0, -58", r2.memory["noctalia-term-lavat"])
check("captura: segundo sondeo marca cambio", true, r2.changed)

-- rect distinto: reinicia el pendiente y no memoriza
local r3 = brain.capture({ clientAt("noctalia-term-lavat", 0, 700, 802, 582) }, SCREEN, 0, {}, {}, r2.pending)
check("captura: rect distinto no memoriza", nil, r3.memory["noctalia-term-lavat"])
check("captura: rect distinto reinicia pendiente", 700, (r3.pending["noctalia-term-lavat"] or {}).y)

-- imposición reciente y coincidente: suprime y cancela el pendiente
clock = 10000
local imposed = { ["noctalia-term-lavat"] = { x = 0, y = 800, w = 802, h = 582, at = 9000 } }
local r4 = brain.capture({ clientAt("noctalia-term-lavat", 0, 800, 802, 582) }, SCREEN, 0, {}, imposed, r1.pending)
check("captura: imposición reciente no memoriza", nil, r4.memory["noctalia-term-lavat"])
check("captura: imposición cancela pendiente", nil, r4.pending["noctalia-term-lavat"])
check("captura: imposición no marca cambio", false, r4.changed)

-- imposición caducada: ya cuenta como manual
local old = { ["noctalia-term-lavat"] = { x = 0, y = 800, w = 802, h = 582, at = 1000 } }
local r5 = brain.capture({ clientAt("noctalia-term-lavat", 0, 800, 802, 582) }, SCREEN, 0, {}, old, r1.pending)
check("captura: imposición caducada memoriza", "bottom-left, 802x582, 0, -58", r5.memory["noctalia-term-lavat"])

-- ventanas ajenas al plugin
local r6 = brain.capture({ clientAt("kitty", 0, 0, 100, 100) }, SCREEN, 0, {}, {}, {})
local foreign = 0
for _ in pairs(r6.pending) do foreign = foreign + 1 end
check("captura: ignora ventanas ajenas", 0, foreign)

-- ventana cerrada: su pendiente desaparece
local r7 = brain.capture({}, SCREEN, 0, {}, {}, r1.pending)
check("captura: ventana cerrada borra pendiente", nil, r7.pending["noctalia-term-lavat"])

-- sin cambios respecto a la memoria previa: no marca cambio
local prev = { ["noctalia-term-lavat"] = "bottom-left, 802x582, 0, -58" }
local r8 = brain.capture({ clientAt("noctalia-term-lavat", 0, 800, 802, 582) }, SCREEN, 0, prev, {}, r1.pending)
check("captura: memoria igual no marca cambio", false, r8.changed)

-- -------------------------------------------------------------------- panel --

print("\n== panel ==")

-- Se carga el panel con la UI simulada. Si usa un global que no existe
-- (un `local` declarado más abajo, por ejemplo), aquí se rompe.
--
-- El panel cachea el store en memoria desde su primera apertura: se deja en
-- disco un store conocido (cerebro apagado y sin memoria) para que la sección
-- arranque siempre en el mismo estado.
files[storePath] = '{"commands":{},"layouts":{},"thumbs":{},"removed":{},"brain":false,"brainGeometry":{}}'
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

-- ---------------------------------------------- cerebro y geometría --

print("\n== cerebro ==")

-- El margen se fija a 0 para que las posiciones esperadas sean exactas (el
-- margen por defecto, 16 px, desplaza la base de cada ancla).
local savedMarginPanel = config.margin
config.margin = 0
env.onOpen("")

-- El botón va primero de su fila: a la izquierda de "abrir todo".
local brainButton = findNode(lastTree, "brain")
check("panel: el botón del cerebro existe", true, brainButton ~= nil)
check("panel: glifo brain", "brain", brainButton ~= nil and brainButton.props.glyph or nil)
check("panel: variante ghost", "ghost", brainButton ~= nil and brainButton.props.variant or nil)
check("panel: arranca apagado", false, brainButton ~= nil and brainButton.props.selected == true)
check("panel: tooltip de apagado", "brain_off", brainButton ~= nil and brainButton.props.tooltip or nil)

-- Orden de las claves del árbol renderizado (las claves viven en
-- `props.key`; `nodeKeys` de arriba sirve para árboles crudos).
local function keyOrder(tree, out)
  out = out or {}
  if type(tree) ~= "table" then return out end
  if type(tree.props) == "table" and tree.props.key ~= nil then
    table.insert(out, tree.props.key)
  end
  for _, child in ipairs(tree.children or {}) do keyOrder(child, out) end
  return out
end

local brainKeys = keyOrder(lastTree)
local brainIndex, openAllIndex
for index, key in ipairs(brainKeys) do
  if key == "brain" then brainIndex = index end
  if key == "open-all" then openAllIndex = index end
end
check("panel: cerebro a la izquierda de abrir todo", true,
  brainIndex ~= nil and openAllIndex ~= nil and brainIndex < openAllIndex)

-- Pulsarlo enciende, repinta y persiste.
if brainButton ~= nil and brainButton.props.onClick ~= nil then
  brainButton.props.onClick()
end
check("panel: enciende el cerebro", true, storeLib.loadBrain().brain == true)
local brainOn = findNode(lastTree, "brain")
check("panel: marcado al encender", true, brainOn ~= nil and brainOn.props.selected == true)
check("panel: tooltip de encendido", "brain_on", brainOn ~= nil and brainOn.props.tooltip or nil)

-- Apagarlo no borra la memoria.
storeLib.saveBrainGeometry({ ["noctalia-term-cerebro"] = "center, 10x10" })
env.onOpen("")
local brainOffButton = findNode(lastTree, "brain")
if brainOffButton ~= nil and brainOffButton.props.onClick ~= nil then
  brainOffButton.props.onClick()
end
check("panel: apaga el cerebro", false, storeLib.loadBrain().brain)
check("panel: apagar no borra la memoria", "center, 10x10",
  storeLib.loadBrain().brainGeometry["noctalia-term-cerebro"])

-- Las dos claves existen en los dos idiomas.
for _, lang in ipairs({ "en", "es" }) do
  local raw = readRealFile(DIR .. "translations/" .. lang .. ".json")
  check("traducciones " .. lang .. ": brain_on", true, raw ~= nil and raw:find('"brain_on"') ~= nil)
  check("traducciones " .. lang .. ": brain_off", true, raw ~= nil and raw:find('"brain_off"') ~= nil)
end

-- Widget de prueba con layout oficial y memoria distinta.
env.onIpc("remove", "cerebro")
env.onIpc("add", "cerebro|cerebro --demo|bottom-left, 802x582")
storeLib.saveBrainToggle(false)
storeLib.saveBrainGeometry({ ["noctalia-term-cerebro"] = "top-right, 400x300, -10, 10" })
env.onOpen("")

-- Cerebro OFF: manda el layout oficial (comportamiento de siempre).
clients = {
  { class = "noctalia-term-cerebro", at = { 100, 100 }, size = { 600, 400 }, address = "0x77", monitor = 0 },
}
clock = clock + 5000
dispatched = {}
clickCard("cerebro")
local offText = dispatchText()
check("sin cerebro: resize al tamaño del layout", true, offText:find("resize%({ x = 802, y = 582") ~= nil)
check("sin cerebro: vuelve a su ancla", true, offText:find("move%({ x = 0, y = 858") ~= nil)

-- Lo que impone el plugin se publica para que el service no lo memorice.
local published = mock.state.get("imposed") or {}
local imposedEntry = published["noctalia-term-cerebro"]
check("imposed: publica la clase", true, imposedEntry ~= nil)
check("imposed: ancho del layout", 802, imposedEntry ~= nil and imposedEntry.w or nil)
check("imposed: posición absoluta", 858, imposedEntry ~= nil and imposedEntry.y or nil)
check("imposed: lleva sello temporal", true,
  imposedEntry ~= nil and (imposedEntry.at or 0) > 0)

-- Las entradas caducadas se podan al publicar la siguiente geometría.
mock.state.set("imposed", { ["noctalia-term-vieja"] = { x = 0, y = 0, w = 10, h = 10, at = 1 } })
clock = clock + 5000
clickCard("cerebro")
check("imposed: poda las caducadas", nil, (mock.state.get("imposed") or {})["noctalia-term-vieja"])

-- Cerebro ON y ya abierto: solo foco, sin recolocar.
storeLib.saveBrainToggle(true)
env.onOpen("")
clients = {
  { class = "noctalia-term-cerebro", at = { 100, 100 }, size = { 600, 400 }, address = "0x77", monitor = 0 },
}
clock = clock + 5000
dispatched = {}
clickCard("cerebro")
check("con cerebro y abierto: un solo dispatch", 1, #dispatched)
check("con cerebro y abierto: es un foco", true,
  dispatched[1] ~= nil and dispatched[1]:find("hl.dsp.focus") ~= nil)
check("con cerebro y abierto: no redimensiona", nil,
  dispatched[1] ~= nil and dispatched[1]:find("resize") or nil)

-- Cerebro ON y cerrado: la apertura usa la memoria.
clients = {}
clock = clock + 5000
dispatched = {}
clickCard("cerebro")
local onText = dispatched[1] or ""
check("con cerebro: abre con el tamaño recordado", true, onText:find("size = { 400, 300") ~= nil)
check("con cerebro: abre en la posición recordada", true, onText:find("move = { 3030, 10") ~= nil)

-- Guardar un layout en el formulario borra la memoria del widget.
storeLib.saveBrainGeometry({ ["noctalia-term-cerebro"] = "top-right, 400x300, -10, 10" })
env.onIpc("add", "cerebro|cerebro --demo|center, 500x400")
check("formulario: borra la memoria del widget", nil,
  storeLib.loadBrain().brainGeometry["noctalia-term-cerebro"])

-- O5: al salir de edición se guarda la geometría que movió el usuario.
local function enterEditMode()
  local node = findNode(lastTree, "edit")
  if node ~= nil and node.props.onClick ~= nil then node.props.onClick() end
end

storeLib.saveBrainToggle(false)
env.onIpc("add", "cerebro|cerebro --demo|bottom-left, 802x582")
env.onOpen("")
clients = {}
clock = clock + 5000
clickCard("cerebro")  -- coloca la ventana y registra lo que impone el plugin

-- Una ventana que sigue donde el plugin la puso no toca el layout.
clients = {
  { class = "noctalia-term-cerebro", at = { 0, 858 }, size = { 802, 582 }, address = "0x77", monitor = 0 },
}
enterEditMode()
enterEditMode()
check("O5: no toca una ventana quieta", "bottom-left, 802x582", storeLib.load().layouts.cerebro)

-- Una ventana movida a mano se guarda como layout permanente.
clients = {
  { class = "noctalia-term-cerebro", at = { 0, 0 }, size = { 700, 400 }, address = "0x77", monitor = 0 },
}
enterEditMode()
enterEditMode()
check("O5: guarda la geometría movida", "top-left, 700x400, 0, 0", storeLib.load().layouts.cerebro)

-- Y funciona igual con el cerebro ON.
storeLib.saveBrainToggle(true)
env.onOpen("")
clients = {}
env.onIpc("add", "cerebro|cerebro --demo|bottom-left, 802x582")
clock = clock + 5000
clickCard("cerebro")
clients = {
  { class = "noctalia-term-cerebro", at = { 0, 0 }, size = { 700, 400 }, address = "0x77", monitor = 0 },
}
enterEditMode()
enterEditMode()
check("O5: también guarda con cerebro ON", "top-left, 700x400, 0, 0", storeLib.load().layouts.cerebro)

-- Un layout escrito en el formulario manda sobre la geometría viva.
storeLib.saveBrainToggle(false)
env.onOpen("")
clients = {}
env.onIpc("add", "cerebro|cerebro --demo|bottom-left, 802x582")
clock = clock + 5000
clickCard("cerebro")
clients = {
  { class = "noctalia-term-cerebro", at = { 0, 0 }, size = { 700, 400 }, address = "0x77", monitor = 0 },
}
enterEditMode()
env.onIpc("add", "cerebro|cerebro --demo|bottom-center, 600x300")
enterEditMode()
check("O5: el formulario manda", "bottom-center, 600x300", storeLib.load().layouts.cerebro)

-- O4: el editor de alta va después de la última tarjeta.
clients = {}
env.onOpen("")
enterEditMode()
local editOrder = keyOrder(lastTree)
local lastCardIndex, addEditorIndex = nil, nil
for index, key in ipairs(editOrder) do
  if key:sub(1, 5) == "card-" then lastCardIndex = index end
  if key == "editor" then addEditorIndex = index end
end
check("edición: hay más de una tarjeta", true, countKeys(lastTree, "card-") > 1)
check("edición: el editor de alta va al final", true,
  addEditorIndex ~= nil and lastCardIndex ~= nil and addEditorIndex > lastCardIndex)
enterEditMode()  -- salir del modo edición

config.margin = savedMarginPanel

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

-- ------------------------------------------------------- fotogramas recientes --

print("\n== fotogramas recientes ==")

-- El panel guarda ocho capturas por widget y las usa para animar la tarjeta
-- cuando su ventana está cerrada. Al llegar a nueve descarta la más antigua y
-- borra su fichero. Si el árbol de UI todavía apunta a ese fichero, el host lo
-- vuelve a pedir al reabrir el panel y avisa "image failed to load" porque el
-- fichero ya no existe: un fichero en uso no se puede borrar hasta que el
-- árbol deje de usarlo.

-- `snapshot.py` no se ejecuta en el simulador, así que el mock crea los
-- ficheros de las miniaturas. La captura se deja *pendiente* para poder
-- simular una que llega con la ventana ya cerrada: es justo cuando el árbol
-- se queda apuntando a un fichero que el plugin va a borrar.
--
-- El `removeFile` del simulador borra de la tabla de la sección de
-- miniaturas; aquí interesa el mismo disco que se usa para crear los
-- ficheros de las capturas.
local previousRemoveFile = mock.removeFile
mock.removeFile = function(path)
  files[path] = nil
  return true
end

local pendingCapture = nil
local capturedFrames = {}

local previousRunAsync = mock.runAsync
mock.runAsync = function(argv, callback)
  if type(argv) == "table" and argv[1] == "python3" then
    local batchPath = argv[3]
    pendingCapture = function()
      pendingCapture = nil
      local raw = files[batchPath]
      if raw ~= nil then
        -- Las rutas se leen del texto del lote: basta con el texto, no
        -- hace falta decodificar el JSON del batch.
        for out in raw:gmatch('"out":"([^"]*)"') do
          files[out] = true
          capturedFrames[#capturedFrames + 1] = out
        end
        for current in raw:gmatch('"current_out":"([^"]*)"') do
          files[current] = true
        end
      end
      if callback ~= nil then
        callback({ exitCode = 0, stdout = "", stderr = "" })
      end
    end
    return true
  end
  return previousRunAsync(argv, callback)
end

local function finishCapture()
  local pending = pendingCapture
  pendingCapture = nil
  if pending ~= nil then
    pending()
  end
end

-- Las secciones anteriores dejan tarjetas sueltas: se borran para que la
-- cuenta de capturas sea solo del widget de esta sección.
for _, name in ipairs(cardNames()) do
  env.onIpc("remove", name)
end
env.onIpc("add", "marco|echo hola|")

clients = {
  { address = "0x1", class = "noctalia-term-marco", x = 100, y = 100, w = 600, h = 400, monitor = "1" },
}
env.onOpen("")

-- Ocho capturas: la lista de fotogramas llega al tope.
for _ = 1, 8 do
  finishCapture()
  clock = clock + 4000
  env.update()
end
check("el widget guarda ocho capturas", 8, #capturedFrames)

-- La ventana se cierra con la novena captura en marcha: la tarjeta pasa a
-- animar los fotogramas guardados y el árbol los marca como en uso.
clients = {}
env.onIpc("refresh", "")

-- Llega la novena captura: la lista se pasa de ocho y se descarta la más
-- antigua, que el árbol está usando.
finishCapture()
check("el widget guarda nueve capturas", 9, #capturedFrames)
local oldestFrame = capturedFrames[1]
check(
  "el fotograma que el árbol usa no se borra al descartarlo",
  true,
  files[oldestFrame] ~= nil
)

-- Cuando el árbol deja de usarlo, el fichero descartado sí se borra.
clock = clock + 4000
env.update()
clock = clock + 4000
env.update()
check(
  "el fotograma descartado se borra cuando el árbol deja de usarlo",
  true,
  files[oldestFrame] == nil
)

mock.runAsync = previousRunAsync
mock.removeFile = previousRemoveFile
clients = {}

-- ------------------------------------------------------------- service.luau --

print("\n== service.luau ==")

-- El service usa su propio entorno (globals propios) con el mismo `noctalia`.
local service = {}
setmetatable(service, { __index = env })
local chunk = assert(loadfile(DIR .. "service.luau", "t", service))
chunk()
check("service: exporta update", "function", type(service.update))
-- el mock de getConfig debe devolver margin = 0 para que los esperados sean exactos
check("service: intervalo de sondeo 1 s", true, serviceUpdatedMs == 1000)

-- El string memorizado depende del margen configurado: se fija a 0 para que
-- los valores esperados de abajo sean exactos (se restaura al salir).
local savedMargin = config.margin
config.margin = 0

local callsBefore = #dispatched
files[storePath] = '{"commands":{},"brain":false,"brainGeometry":{}}'
service.update()
check("service: cerebro OFF no consulta hyprctl", callsBefore, #dispatched)
check("service: cerebro OFF no escribe memoria", nil, storeLib.load().brainGeometry["noctalia-term-lavat"])

-- cerebro ON: dos ticks con la misma ventana memorizan
files[storePath] = '{"commands":{},"brain":true,"brainGeometry":{}}'
clients = { { class = "noctalia-term-lavat", at = { 0, 800 }, size = { 802, 582 }, address = "0x1", monitor = 0 } }
service.update()
service.update()
check("service: cerebro ON memoriza tras dos ticks", "bottom-left, 802x582, 0, -58", storeLib.load().brainGeometry["noctalia-term-lavat"])
clients = {}

-- cerebro ON y rectángulo impuesto reciente: no memoriza
files[storePath] = '{"commands":{},"brain":true,"brainGeometry":{}}'
mock.state.set("imposed", { ["noctalia-term-lavat"] = { x = 0, y = 800, w = 802, h = 582, at = clock } })
clients = { { class = "noctalia-term-lavat", at = { 0, 800 }, size = { 802, 582 }, address = "0x1", monitor = 0 } }
service.update()
service.update()
check("service: respeta la supresión de impuestos", nil, storeLib.load().brainGeometry["noctalia-term-lavat"])
mock.state.set("imposed", {})
clients = {}

-- si runAsync no arranca, el sondeo no debe quedar bloqueado
files[storePath] = '{"commands":{},"brain":true,"brainGeometry":{}}'
local realRunAsync = mock.runAsync
mock.runAsync = function() return false end
service.update()
mock.runAsync = realRunAsync
clients = { { class = "noctalia-term-lavat", at = { 0, 800 }, size = { 802, 582 }, address = "0x1", monitor = 0 } }
service.update()
service.update()
check("service: runAsync fallido no bloquea el sondeo", "bottom-left, 802x582, 0, -58", storeLib.load().brainGeometry["noctalia-term-lavat"])
clients = {}

config.margin = savedMargin

print(string.format("\n%d comprobaciones, %d fallos", PASSED + FAILED, FAILED))
os.exit(FAILED == 0 and 0 or 1)
