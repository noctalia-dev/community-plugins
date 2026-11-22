--!nonstrict
-- Dynamic translation resolver that adapts immediately to Noctalia's active shell.lang setting

local cache = {}

local function loadLangTable(lang)
  if cache[lang] ~= nil then
    return cache[lang]
  end

  local content = noctalia.readFile("translations/" .. lang .. ".json")
  if content and content ~= "" then
    local decoded = noctalia.json.decode(content)
    if type(decoded) == "table" then
      cache[lang] = decoded
      return decoded
    end
  end

  cache[lang] = false
  return nil
end

local function lookupKey(tbl, dottedKey)
  if type(tbl) ~= "table" then
    return nil
  end
  local cur = tbl
  for part in string.gmatch(dottedKey, "[^%.]+") do
    if type(cur) ~= "table" then
      return nil
    end
    cur = cur[part]
  end
  if type(cur) == "string" then
    return cur
  end
  return nil
end

local function resolveActiveLang()
  local lang = noctalia.getSetting("shell.lang")
  if type(lang) == "string" and lang ~= "" then
    if string.sub(lang, 1, 2) == "pt" then
      return "pt-BR"
    end
    return lang
  end

  local envLang = noctalia.getenv("LANG") or noctalia.getenv("LC_MESSAGES") or ""
  if string.find(string.lower(envLang), "^pt") then
    return "pt-BR"
  end

  return "en"
end

local M = {}

function M.lang()
  return resolveActiveLang()
end

function M.tr(key)
  local lang = resolveActiveLang()
  if lang ~= "en" then
    local langTbl = loadLangTable(lang)
    local val = lookupKey(langTbl, key)
    if val then
      return val
    end
  end

  local enTbl = loadLangTable("en")
  local enVal = lookupKey(enTbl, key)
  if enVal then
    return enVal
  end

  return noctalia.tr(key)
end

return M
