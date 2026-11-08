--!nonstrict
-- Pure flavor table, auto choice, open argv and path-box parsing. No noctalia.* here.
local uris = require("./uris.luau")

local flavors = {}

-- configDir keeps a leading "~"; the service expands it.
flavors.LIST = {
  {
    id = "code",
    name = "VS Code",
    cmd = { "code" },
    configDir = "~/.config/Code",
    iconIds = { "vscode", "code", "com.visualstudio.code", "com.microsoft.VSCode" },
  },
  {
    id = "insiders",
    name = "VS Code Insiders",
    cmd = { "code-insiders" },
    configDir = "~/.config/Code - Insiders",
    iconIds = { "com.microsoft.VSCodeInsiders", "vscode-insiders", "code-insiders" },
  },
  {
    id = "codium",
    name = "VSCodium",
    cmd = { "codium" },
    configDir = "~/.config/VSCodium",
    iconIds = { "vscodium", "codium" },
  },
  {
    id = "oss",
    name = "Code - OSS",
    cmd = { "code-oss" },
    configDir = "~/.config/Code - OSS",
    iconIds = { "com.visualstudio.code.oss", "code-oss" },
  },
  {
    id = "cursor",
    name = "Cursor",
    cmd = { "cursor" },
    configDir = "~/.config/Cursor",
    iconIds = { "cursor", "co.anysphere.cursor" },
  },
  {
    id = "flatpak",
    name = "VS Code (Flatpak)",
    cmd = { "flatpak", "run", "com.visualstudio.code" },
    configDir = "~/.var/app/com.visualstudio.code/config/Code",
    iconIds = { "com.visualstudio.code" },
  },
}

-- A flavor is installed when its command (the first argv word; "flatpak" for
-- the Flatpak flavor) exists and its config dir exists.
function flavors.installed(commandExists, dirExists)
  local out = {}
  for _, f in ipairs(flavors.LIST) do
    if commandExists(f.cmd[1]) and dirExists(f.configDir) then
      out[#out + 1] = f
    end
  end
  return out
end

-- hasHistory(flavor) -> bool is optional; nil keeps the plain newest-mtime rule.
function flavors.choose(setting, installedList, storageMtime, hasHistory)
  if installedList == nil or #installedList == 0 then
    return nil
  end
  if setting ~= nil and setting ~= "auto" then
    for _, f in ipairs(installedList) do
      if f.id == setting then
        return f
      end
    end
  end
  -- Under auto, flavors with workspaceStorage history compete first, so a freshly
  -- installed editor that was run once doesn't win with no recents.
  local pool = installedList
  if hasHistory ~= nil then
    local withHistory = {}
    for _, f in ipairs(installedList) do
      if hasHistory(f) then
        withHistory[#withHistory + 1] = f
      end
    end
    if #withHistory > 0 then
      pool = withHistory
    end
  end
  local best = pool[1]
  local bestM = storageMtime(best)
  for i = 2, #pool do
    local f = pool[i]
    local m = storageMtime(f)
    if m ~= nil and (bestM == nil or m > bestM) then
      best = f
      bestM = m
    end
  end
  return best
end

function flavors.openArgv(flavor, entry)
  local argv = {}
  for i, word in ipairs(flavor.cmd) do
    argv[i] = word
  end
  local isLocal = entry.remote == nil and (entry.uri == nil or entry.uri:sub(1, 7) == "file://")
  if isLocal then
    argv[#argv + 1] = entry.path
  elseif entry.kind == "workspace" then
    argv[#argv + 1] = "--file-uri"
    argv[#argv + 1] = entry.uri
  else
    argv[#argv + 1] = "--folder-uri"
    argv[#argv + 1] = entry.uri
  end
  return argv
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Host folders a Flatpak app cannot see even with filesystem=host: its /tmp is
-- private and these are reserved (checked live against com.visualstudio.code).
-- Opening such a path makes the editor open a blank new file instead.
local FLATPAK_HIDDEN = { "/tmp", "/var/tmp", "/usr", "/etc", "/proc", "/sys", "/dev", "/run/user", "/app", "/bin", "/sbin", "/lib", "/lib32", "/lib64" }

function flavors.sandboxHides(flavor, path)
  if flavor == nil or flavor.id ~= "flatpak" or type(path) ~= "string" then
    return false
  end
  for _, root in ipairs(FLATPAK_HIDDEN) do
    if path == root or path:sub(1, #root + 1) == root .. "/" then
      return true
    end
  end
  return false
end

function flavors.parsePathInput(text, home, info)
  local s = trim(tostring(text or ""))
  local q = s:sub(1, 1)
  if #s >= 2 and (q == "'" or q == '"') and s:sub(-1) == q then
    s = s:sub(2, -2)
  end
  if s:sub(1, 7) == "file://" then
    s = uris.decode(s:sub(8))
  end
  if s == "" then
    return { ok = false, err = "path.empty" }
  end
  if home ~= nil and home ~= "" and (s == "~" or s:sub(1, 2) == "~/") then
    s = home .. s:sub(2)
  end
  s = s:gsub("/+$", "")
  if s == "" then
    s = "/"
  end
  if s:sub(1, 1) ~= "/" then
    return { ok = false, err = "path.missing" }
  end
  local st = info(s)
  if st == nil then
    return { ok = false, err = "path.missing" }
  end
  if st.isDir then
    return { ok = true, path = s, kind = "folder" }
  end
  if s:sub(-15) == ".code-workspace" then
    return { ok = true, path = s, kind = "workspace" }
  end
  return { ok = false, err = "path.not_project" }
end

return flavors
