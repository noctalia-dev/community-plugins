-- Test-only analogue of Noctalia's relative require, with isolated module globals.
-- Tests run from the project root so production module paths stay unchanged.
-- Runtime entry scripts use Noctalia's native require; they never load this file.
local modules = {}

-- Read the nested string/object translation catalog without a test dependency.
-- This intentionally accepts only the JSON subset used by en.json; the community
-- validator independently checks JSON syntax and translation-key rules.
local translationFile = assert(io.open("translations/en.json", "r"))
local translationSource = translationFile:read("*a")
translationFile:close()
local translations = {}
local position = 1
local function peek()
  position = translationSource:find("%S", position) or (#translationSource + 1)
  return translationSource:sub(position, position)
end
local function consume(expected)
  assert(peek() == expected, "expected " .. expected .. " at translation byte " .. position)
  position = position + 1
end
local function readString()
  consume('"')
  local parts = {}
  local escapes =
    { n = "\n", r = "\r", t = "\t", b = "\b", f = "\f", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
  while position <= #translationSource do
    local char = translationSource:sub(position, position)
    position = position + 1
    if char == '"' then
      return table.concat(parts)
    end
    if char == "\\" then
      local escape = translationSource:sub(position, position)
      position = position + 1
      if escape == "u" then
        local hex = translationSource:sub(position, position + 3)
        assert(hex:match("^%x%x%x%x$"), "invalid Unicode escape")
        local codepoint = tonumber(hex, 16)
        assert(
          codepoint < 0xD800 or codepoint > 0xDFFF,
          "use literal UTF-8 for supplementary characters"
        )
        char = utf8.char(codepoint)
        position = position + 4
      else
        char = assert(escapes[escape], "unsupported translation escape: " .. escape)
      end
    end
    parts[#parts + 1] = char
  end
  error("unterminated translation string")
end
local function readObject(prefix)
  consume("{")
  while peek() ~= "}" do
    local key = prefix .. readString()
    consume(":")
    if peek() == "{" then
      readObject(key .. ".")
    else
      assert(translations[key] == nil, "duplicate translation key: " .. key)
      translations[key] = readString()
    end
    if peek() ~= "," then
      break
    end
    consume(",")
  end
  consume("}")
end
readObject("")
assert(peek() == "", "trailing translation data")
local function translate(key, substitutions)
  local text = assert(translations[key], "missing English translation: " .. key)
  return (
    text:gsub("{([%w_]+)}", function(name)
      assert(substitutions and substitutions[name] ~= nil, "missing substitution: " .. name)
      return tostring(substitutions[name])
    end)
  )
end
local function installTranslations()
  if noctalia and not noctalia.tr then
    noctalia.tr = translate
  end
end
local originalDofile = dofile
dofile = function(path)
  installTranslations()
  return originalDofile(path)
end

local function normalize(path)
  local parts = {}
  for part in path:gmatch("[^/]+") do
    if part == ".." then
      assert(#parts > 0, "test import outside the plugin")
      table.remove(parts)
    elseif part ~= "." then
      parts[#parts + 1] = part
    end
  end
  return table.concat(parts, "/")
end

local function loadModule(path, directory)
  assert(type(path) == "string" and path:match("^%.%.?/") and path:match("%.luau$"))
  local file = normalize(directory .. path)
  assert(modules[file] ~= false, "circular import: " .. file)
  if modules[file] then
    return modules[file]
  end
  local environment = setmetatable({}, { __index = _G })
  environment._G = environment
  environment.require = function(relative)
    return loadModule(relative, file:match("^(.*/)") or "")
  end
  modules[file] = false
  local chunk = assert(loadfile(file, "t", environment))
  local values = table.pack(chunk())
  assert(values.n == 1 and values[1] ~= nil, "module must return one non-nil value")
  modules[file] = values[1]
  return values[1]
end

require = function(path)
  installTranslations()
  return loadModule(path, "")
end
