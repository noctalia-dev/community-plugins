--[[
  credentials.luau - reading API keys out of OpenCode's `auth.json`.

  Pure module: it takes an already-decoded table, so tests drive it with plain
  Lua tables and the CLI needs no JSON library.

  OpenCode stores one entry per provider:

    {
      "cheaper-inference":  { type = "api", key = "..." },
      "opencode-omniroute": { type = "api", key = "...", metadata = { apiKey = "" } },
    }

  Entries have been seen in several shapes as OpenCode grew, so every plausible
  field is tried (including `metadata.apiKey`, which is what a provider package
  writes when it registers its own credential) instead of insisting on one.

  Keys live in tables this module returns. It never logs, echoes or formats
  one, and the error messages it produces list *names*, never values.
]]

local M = {}

local function trim(s: string?): string
  if type(s) ~= "string" then
    return ""
  end
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end

M.trim = trim

local FIELDS = { "key", "api_key", "apiKey", "token", "access", "refresh" }
local METADATA_FIELDS = { "apiKey", "api_key", "key", "token", "access" }

-- Pull the usable secret out of one entry, one field shape at a time.
function M.extract(entry): string?
  if type(entry) ~= "table" then
    return nil
  end
  for _, field in ipairs(FIELDS) do
    local value = entry[field]
    if type(value) == "string" and trim(value) ~= "" then
      return trim(value)
    end
  end
  local metadata = entry.metadata
  if type(metadata) == "table" then
    for _, field in ipairs(METADATA_FIELDS) do
      local value = metadata[field]
      if type(value) == "string" and trim(value) ~= "" then
        return trim(value)
      end
    end
  end
  if type(entry.env) == "string" and trim(entry.env) ~= "" then
    -- the file only points at an environment variable in this shape
    return nil
  end
  return nil
end

-- Sorted list of provider names that have a usable credential.
function M.names(auth)
  local names = {}
  if type(auth) ~= "table" then
    return names
  end
  for name, entry in pairs(auth) do
    if type(name) == "string" and M.extract(entry) ~= nil then
      table.insert(names, name)
    end
  end
  table.sort(names)
  return names
end

-- Every provider name present in the file, usable or not: the panel shows them
-- so a user can tell "wrong name" from "no credential here".
function M.all_names(auth)
  local names = {}
  if type(auth) ~= "table" then
    return names
  end
  for name, entry in pairs(auth) do
    if type(name) == "string" and type(entry) == "table" then
      table.insert(names, name)
    end
  end
  table.sort(names)
  return names
end

--[[
  Resolve a credential by provider name:

    * a name selects exactly that entry (case-insensitive);
    * an empty name auto-selects, but only when exactly one usable credential
      exists - guessing between several would silently bill the wrong account.
]]
function M.pick(auth, name: string?): (string?, string?, string?)
  if type(auth) ~= "table" then
    return nil, nil, "auth.json no contiene un objeto de proveedores."
  end
  local wanted = trim(name or "")
  local present = M.all_names(auth)

  if wanted ~= "" then
    local lowered = wanted:lower()
    for _, candidate in ipairs(present) do
      if candidate:lower() == lowered then
        local key = M.extract(auth[candidate])
        if key ~= nil then
          return key, candidate
        end
        return nil, nil, "La credencial '" .. candidate .. "' en auth.json no tiene una clave usable."
      end
    end
    return nil, nil, "auth.json no tiene ninguna credencial llamada '" .. wanted .. "'."
      .. (#present > 0 and (" Disponibles: " .. table.concat(present, ", ") .. ".") or "")
  end

  local usable = M.names(auth)
  if #usable == 1 then
    return M.extract(auth[usable[1]]), usable[1]
  end
  if #usable == 0 then
    local hint = #present > 0 and (" Entradas sin clave usable: " .. table.concat(present, ", ") .. ".") or " El fichero está vacío."
    return nil, nil, "auth.json no tiene ninguna credencial usable." .. hint
  end
  return nil, nil, "Hay varias credenciales en auth.json (" .. table.concat(usable, ", ")
    .. "): indica cuál usar en 'Credencial de auth.json'."
end

--[[
  Path of OpenCode's credential file, resolved from the environment so a user
  with `XDG_DATA_HOME` set somewhere else still gets found.
]]
function M.auth_path(xdg_data_home: string?, home: string?): string
  local base = trim(xdg_data_home or "")
  if base == "" then
    base = trim(home or "") .. "/.local/share"
  end
  return base .. "/opencode/auth.json"
end

return M
