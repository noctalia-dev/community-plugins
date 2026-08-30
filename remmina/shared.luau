--!nonstrict
-- Profile discovery shared by the launcher, the panel and the bar widget.
--
-- Each entry runs in its own VM, so this module is loaded (and its cache held)
-- once per entry rather than shared between them.

local PROFILE_SUFFIX = ".remmina"
local DEFAULT_PROFILES_PATH = "~/.local/share/remmina"

local M = {}

-- Tabler icon names, as shipped by the host (Commons/IconsTabler.qml); a name
-- the set does not have renders as nothing and only warns in the log.
-- Every protocol here is a remote session, so each glyph carries the "share"
-- arrow: a plain monitor reads as a local display.
local GLYPHS = {
  RDP = "device-desktop-share",
  VNC = "screen-share",
  SPICE = "device-desktop-share",
  X2GO = "device-desktop-share",
  NX = "device-desktop-share",
  SSH = "terminal",
  TELNET = "terminal-2",
  SFTP = "folder",
  WWW = "world-www",
  EXEC = "terminal-2",
}

local cache = nil
local cacheStamp = nil
local cacheDir = nil

local function trim(s)
  return noctalia.string.trim(s or "")
end

-- The caller passes the `profiles_path` setting rather than this module
-- reading it: each entry then reads its own settings, which is what the plugin
-- linter checks for.
function M.profilesPath(configured)
  if type(configured) == "string" and trim(configured) ~= "" then
    return noctalia.expandPath(trim(configured))
  end
  return noctalia.expandPath(DEFAULT_PROFILES_PATH)
end

function M.glyphFor(protocol)
  return GLYPHS[protocol] or "device-desktop-share"
end

-- Remmina writes one lowercase `key=value` per line, no quoting and no
-- sections that matter here, so a plain split is enough.
local function parseProfile(content)
  local fields = {}
  for line in content:gmatch("[^\r\n]+") do
    local key, value = line:match("^(%w+)=(.*)$")
    if key ~= nil then
      fields[key:lower()] = trim(value)
    end
  end
  return fields
end

-- "user@host", or whichever half exists.
function M.targetOf(profile)
  if profile.username ~= "" and profile.server ~= "" then
    return profile.username .. "@" .. profile.server
  end
  return profile.server ~= "" and profile.server or profile.username
end

local function loadProfiles(directory)
  local entries, err = noctalia.listDir(directory)
  if entries == nil then
    return nil, err
  end

  local profiles = {}
  for _, entry in ipairs(entries) do
    if entry:sub(-#PROFILE_SUFFIX) == PROFILE_SUFFIX then
      -- listDir may hand back bare names or full paths depending on the host;
      -- only prepend the directory when the entry is not already absolute.
      local path = entry:sub(1, 1) == "/" and entry or (directory .. "/" .. entry)
      local content = noctalia.readFile(path)
      if type(content) == "string" and content ~= "" then
        local fields = parseProfile(content)
        local name = fields.name ~= nil and fields.name or ""
        if name == "" then
          -- Fall back to the file name so a profile is never invisible.
          name = (entry:match("([^/]+)$") or entry):sub(1, -#PROFILE_SUFFIX - 1)
        end
        table.insert(profiles, {
          path = path,
          name = name,
          group = fields.group or "",
          protocol = (fields.protocol or ""):upper(),
          server = fields.server or "",
          username = fields.username or "",
        })
      end
    end
  end

  table.sort(profiles, function(a, b)
    if a.group ~= b.group then
      -- Ungrouped profiles sort last rather than first.
      if a.group == "" or b.group == "" then
        return b.group == ""
      end
      return a.group:lower() < b.group:lower()
    end
    return a.name:lower() < b.name:lower()
  end)
  return profiles, nil
end

-- Parsed once, then re-read only when the folder's mtime changes, so typing in
-- the launcher and re-rendering the panel do no disk I/O.
function M.profiles(configuredPath)
  local directory = M.profilesPath(configuredPath)
  local info = noctalia.fileInfo(directory)
  local stamp = info ~= nil and tostring(info.mtime) or nil
  if cache ~= nil and stamp == cacheStamp and directory == cacheDir then
    return cache, nil
  end
  local loaded, err = loadProfiles(directory)
  if loaded == nil then
    return nil, err
  end
  cache = loaded
  cacheStamp = stamp
  cacheDir = directory
  return cache, nil
end

function M.matches(filter, profile)
  if filter == "" then
    return true
  end
  local needle = filter:lower()
  for _, text in ipairs({ profile.name, profile.group, profile.server, profile.protocol }) do
    if text ~= "" and text:lower():find(needle, 1, true) ~= nil then
      return true
    end
  end
  return false
end

-- argv form: a profile path carries spaces, @ and parentheses, and must stay
-- one argument.
function M.open(profilePath)
  return noctalia.runAsync({ "remmina", "-c", profilePath })
end

return M
