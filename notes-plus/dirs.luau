-- Ported verbatim from noctalia/notes (MIT) by faminec.
-- Do not diverge: the upstream PR reuses this file as-is.
-- Resolves the notes_dir setting. Shared by the launcher and panel entries,
-- which each load their own copy (entries share no Lua memory).

local M = {}

local DEFAULT_NOTES_DIR = "$XDG_DOCUMENTS_DIR/Notes"
-- Default before 1.1.0. Kept when it already exists so upgrading users on a localized system don't lose sight of
-- their notes.
local LEGACY_NOTES_DIR = "~/Documents/Notes"

-- The notes_dir default is "$XDG_DOCUMENTS_DIR/Notes": the variable stands for the user's localized Documents folder
-- (XDG_DOCUMENTS_DIR from user-dirs.dirs, e.g. ~/Documentos on a Spanish system).
local cachedDocumentsDir = nil

local function documentsDir()
  if cachedDocumentsDir ~= nil then
    return cachedDocumentsDir
  end
  local home = noctalia.expandPath("~")
  local configHome = noctalia.getenv("XDG_CONFIG_HOME")
  if configHome == nil or configHome == "" then
    configHome = home .. "/.config"
  end
  local dir = nil
  local raw = noctalia.readFile(configHome .. "/user-dirs.dirs")
  if raw ~= nil then
    for line in raw:gmatch("[^\n]+") do
      local value = line:match('^%s*XDG_DOCUMENTS_DIR%s*=%s*"([^"]*)"')
      if value ~= nil then
        if value:sub(1, 5) == "$HOME" then
          value = home .. value:sub(6)
        end
        value = value:gsub("/+$", "")
        -- An empty value or $HOME itself means the directory is disabled.
        if value ~= "" and value ~= home then
          dir = value
        end
        break
      end
    end
  end
  cachedDocumentsDir = dir or (home .. "/Documents")
  return cachedDocumentsDir
end

local function isDir(path)
  local info = noctalia.fileInfo(path)
  return info ~= nil and info.isDir
end

function M.resolveNotesDir()
  local configured = noctalia.getConfig("notes_dir")
  if configured == "" then
    configured = DEFAULT_NOTES_DIR
  end
  if configured == DEFAULT_NOTES_DIR then
    local resolved = documentsDir() .. "/Notes"
    local legacy = noctalia.expandPath(LEGACY_NOTES_DIR)
    if resolved ~= legacy and not isDir(resolved) and isDir(legacy) then
      return legacy
    end
    return resolved
  end
  local rest = configured:match("^%$XDG_DOCUMENTS_DIR(.*)$")
  if rest ~= nil and (rest == "" or rest:sub(1, 1) == "/") then
    configured = documentsDir() .. rest
  end
  return noctalia.expandPath(configured)
end

return M
