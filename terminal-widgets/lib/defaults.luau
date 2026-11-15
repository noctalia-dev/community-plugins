--!nonstrict
-- Defaults integrados.
--
-- La lista de widgets vive en el `store.json` del plugin y se edita desde el
-- panel. Estas tablas solo rellenan la lista inicial y sirven de respaldo si
-- el manifiesto no declara `commands`/`layouts`.
--
-- El manifiesto se analiza una sola vez y se guarda en memoria: el parser es
-- relativamente caro y Noctalia da a cada callback solo 25 ms de CPU.
--
-- Si el manifiesto no se puede leer (formato inesperado, plugin copiado sin
-- el .toml) se usa la tabla de respaldo para no dejar al usuario sin widgets.

local util = require("./util.luau")

local M = {}

local FALLBACK_COMMANDS = {
  cava = "cava",
  cbonsai = "cbonsai -l -i",
  unimatrix = "unimatrix -s 96 -l o",
  pipes = "pipes.sh",
  lavat = "lavat -k green -c black",
  btop = "btop",
}

local FALLBACK_LAYOUTS = {
  cava = "bottom-center, 1610x584",
  cbonsai = "top-center, 801x582",
  unimatrix = "right-center, 869x1424",
  pipes = "bottom-right, 900x520",
  btop = "top-left, 928x800",
  lavat = "bottom-left, 802x582",
}

local FALLBACK_THUMBS = {}

local cached = nil

-- Extrae una tabla inline de TOML: { a = "b", c = "d" }
-- Respeta las comillas (un valor puede llevar comas o llaves dentro).
local function parseInlineTable(text)
  local result = {}
  local index = 1
  local length = #text

  while index <= length and text:sub(index, index) ~= "{" do
    index = index + 1
  end
  if index > length then
    return nil
  end
  index = index + 1

  local function skipSpace()
    while index <= length and text:sub(index, index):match("%s") do
      index = index + 1
    end
  end

  local function readQuoted()
    local quote = text:sub(index, index)
    local cursor = index + 1
    local buffer = {}
    while cursor <= length do
      local char = text:sub(cursor, cursor)
      if char == "\\" and quote == '"' then
        cursor = cursor + 1
        buffer[#buffer + 1] = text:sub(cursor, cursor)
      elseif char == quote then
        break
      else
        buffer[#buffer + 1] = char
      end
      cursor = cursor + 1
    end
    index = cursor + 1
    return table.concat(buffer)
  end

  while true do
    skipSpace()
    if index > length then
      return nil
    end
    local char = text:sub(index, index)
    if char == "}" then
      return result
    end

    local key
    if char == '"' or char == "'" then
      key = readQuoted()
    else
      local cursor = index
      local buffer = {}
      while cursor <= length do
        local current = text:sub(cursor, cursor)
        if current:match("[%w_%-]") then
          buffer[#buffer + 1] = current
        else
          break
        end
        cursor = cursor + 1
      end
      key = table.concat(buffer)
      index = cursor
    end

    skipSpace()
    if text:sub(index, index) ~= "=" then
      return nil
    end
    index = index + 1
    skipSpace()

    local value
    local valueChar = text:sub(index, index)
    if valueChar == '"' or valueChar == "'" then
      value = readQuoted()
    else
      local cursor = index
      local buffer = {}
      while cursor <= length do
        local current = text:sub(cursor, cursor)
        if current == "," or current == "}" then
          break
        end
        buffer[#buffer + 1] = current
        cursor = cursor + 1
      end
      value = util.trim(table.concat(buffer))
      index = cursor
    end

    if key ~= "" and value ~= "" then
      result[key] = value
    end

    skipSpace()
    if text:sub(index, index) == "," then
      index = index + 1
    end
  end
end

-- Variación del número de llaves de una línea, ignorando el texto entre
-- comillas.
local function braceDelta(text)
  local delta = 0
  local quote = nil
  local index = 1
  local length = #text
  while index <= length do
    local char = text:sub(index, index)
    if quote ~= nil then
      if char == "\\" and quote == '"' then
        index = index + 1
      elseif char == quote then
        quote = nil
      end
    elseif char == '"' or char == "'" then
      quote = char
    elseif char == "{" then
      delta = delta + 1
    elseif char == "}" then
      delta = delta - 1
    end
    index = index + 1
  end
  return delta
end

-- Corta el texto en líneas (más rápido que gmatch con un patrón perezoso).
local function splitLines(text)
  local lines = {}
  local position = 1
  local length = #text
  while position <= length do
    local newline = string.find(text, "\n", position, true)
    if newline == nil then
      lines[#lines + 1] = string.sub(text, position)
      break
    end
    lines[#lines + 1] = string.sub(text, position, newline - 1)
    position = newline + 1
  end
  return lines
end

-- Lee los `default = { ... }` de los ajustes `commands` y `layouts`.
local function parseManifest(text)
  local result = {}
  local currentKey = nil
  local lines = splitLines(text)

  local index = 1
  while index <= #lines do
    local line = lines[index]
    local declared = line:match('^%s*key%s*=%s*"([^"]*)"')
    if declared ~= nil then
      currentKey = declared
    end

    if (currentKey == "commands" or currentKey == "layouts") and line:find("{", 1, true) ~= nil then
      local start = line:match("^%s*default%s*=%s*{")
      if start ~= nil then
        local buffer = line
        local depth = braceDelta(line)
        while depth > 0 and index < #lines do
          index = index + 1
          buffer = buffer .. " " .. lines[index]
          depth = depth + braceDelta(lines[index])
        end
        local parsed = parseInlineTable(buffer)
        if parsed ~= nil and next(parsed) ~= nil then
          result[currentKey] = parsed
        end
      end
    end

    index = index + 1
  end

  return result
end

-- Olvida el manifiesto cacheado (solo para pruebas o si el manifiesto cambia
-- en caliente).
function M.reset()
  cached = nil
end

function M.load()
  if cached ~= nil then
    return {
      commands = util.copyMap(cached.commands),
      layouts = util.copyMap(cached.layouts),
    }
  end

  local commands = nil
  local layouts = nil

  local manifestPath = util.pluginPath("plugin.toml")
  local raw = nil
  if manifestPath ~= nil then
    raw = noctalia.readFile(manifestPath)
  end
  noctalia.log(string.format(
    "terminal-widgets: manifiesto %s (%s bytes)",
    tostring(manifestPath),
    raw ~= nil and tostring(#raw) or "ilegible"
  ))

  if raw ~= nil and raw ~= "" then
    local parsed = parseManifest(raw)
    commands = parsed.commands
    layouts = parsed.layouts
  end

  if type(commands) ~= "table" or next(commands) == nil then
    commands = util.copyMap(FALLBACK_COMMANDS)
  end
  if type(layouts) ~= "table" or next(layouts) == nil then
    layouts = util.copyMap(FALLBACK_LAYOUTS)
  end

  cached = { commands = commands, layouts = layouts, thumbs = util.copyMap(FALLBACK_THUMBS) }

  return {
    commands = util.copyMap(commands),
    layouts = util.copyMap(layouts),
    thumbs = util.copyMap(FALLBACK_THUMBS),
  }
end

return M
