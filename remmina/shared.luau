--!nonstrict
-- Profile discovery shared by the launcher, the panel and the bar widget.
--
-- Each entry runs in its own VM, so this module is loaded (and its cache held)
-- once per entry rather than shared between them.

local PROFILE_SUFFIX = ".remmina"
local DEFAULT_PROFILES_PATH = "~/.local/share/remmina"

-- Pinned profiles: the file under pluginDataDir() is the durable copy, the
-- state key is how the panel's toggle reaches the launcher and the widget
-- (each entry runs in its own VM, and state is the only thing they share).
local PINS_FILE = "pinned.json"
local PINS_STATE_KEY = "pins"

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
local loadError = nil

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

-- Remmina writes one lowercase `key=value` per line, no quoting. A profile
-- carries ~100 keys and only five are used here, so each one is looked up with
-- a single anchored match instead of walking every line in Luau: with a few
-- dozen profiles the line walk alone overran the 25 ms callback budget on a
-- slow CPU, and the host disabled the panel.
local function field(content, key)
  local value = content:match("\n" .. key .. "=([^\r\n]*)")
  return value ~= nil and trim(value) or nil
end

local function parseProfile(content)
  -- leading newline so the first line matches the same anchored pattern
  content = "\n" .. content
  return {
    name = field(content, "name"),
    group = field(content, "group"),
    protocol = field(content, "protocol"),
    server = field(content, "server"),
    username = field(content, "username"),
  }
end

-- "user@host", or whichever half exists.
function M.targetOf(profile)
  if profile.username ~= "" and profile.server ~= "" then
    return profile.username .. "@" .. profile.server
  end
  return profile.server ~= "" and profile.server or profile.username
end

local function profileFrom(path, content)
  local fields = parseProfile(content)
  local name = fields.name ~= nil and fields.name or ""
  if name == "" then
    -- Fall back to the file name so a profile is never invisible.
    name = (path:match("([^/]+)$") or path):sub(1, -#PROFILE_SUFFIX - 1)
  end
  return {
    path = path,
    name = name,
    group = fields.group or "",
    protocol = (fields.protocol or ""):upper(),
    server = fields.server or "",
    username = fields.username or "",
  }
end

local function sortProfiles(profiles)
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
end

-- The host allows four outstanding readFileAsync calls per runtime.
local MAX_IN_FLIGHT = 4

-- Reads the profiles with readFileAsync and calls done(profiles) or
-- done(nil, err). Reading them synchronously did not fit the 25 ms callback
-- budget with a few dozen profiles on a slow CPU or an encrypted home
-- (ecryptfs decrypts on every read), and the host disabled the panel. Each
-- completion runs in its own callback, so the work is spread across calls.
local function loadProfiles(directory, done)
  local entries, err = noctalia.listDir(directory)
  if entries == nil then
    done(nil, err)
    return
  end

  local paths = {}
  for _, entry in ipairs(entries) do
    if entry:sub(-#PROFILE_SUFFIX) == PROFILE_SUFFIX then
      -- listDir may hand back bare names or full paths depending on the host;
      -- only prepend the directory when the entry is not already absolute.
      table.insert(paths, entry:sub(1, 1) == "/" and entry or (directory .. "/" .. entry))
    end
  end

  local profiles = {}
  local nextIndex, pending = 1, 0

  local function finishIfDone()
    if pending == 0 and nextIndex > #paths then
      sortProfiles(profiles)
      done(profiles, nil)
    end
  end

  local startNext
  local function accept(path, content)
    if type(content) == "string" and content ~= "" then
      table.insert(profiles, profileFrom(path, content))
    end
  end

  startNext = function()
    while pending < MAX_IN_FLIGHT and nextIndex <= #paths do
      local path = paths[nextIndex]
      nextIndex += 1
      pending += 1
      local queued = noctalia.readFileAsync(path, function(content)
        pending -= 1
        accept(path, content)
        startNext()
        finishIfDone()
      end)
      if not queued then
        -- Queue full despite the cap: read this one inline rather than lose it.
        pending -= 1
        accept(path, noctalia.readFile(path))
      end
    end
  end

  startNext()
  finishIfDone()
end

local loading = false
local waiters = {}

-- Parsed once, then re-read only when the folder's mtime changes, so typing in
-- the launcher and re-rendering the panel do no disk I/O.
--
-- Returns profiles, err, isLoading. While a (re)load is running it returns the
-- previous list (nil on the first load) with isLoading = true, and calls
-- onReady() once the new list is in place, so the caller can redraw.
function M.profiles(configuredPath, onReady)
  local directory = M.profilesPath(configuredPath)
  local info = noctalia.fileInfo(directory)
  local stamp = info ~= nil and tostring(info.mtime) or nil
  if cache ~= nil and stamp == cacheStamp and directory == cacheDir then
    return cache, nil, false
  end

  if onReady ~= nil then
    table.insert(waiters, onReady)
  end
  if not loading then
    loading = true
    loadProfiles(directory, function(loaded, err)
      loading = false
      if loaded ~= nil then
        cache = loaded
        cacheStamp = stamp
        cacheDir = directory
      else
        cache, cacheStamp, cacheDir = nil, nil, nil
        loadError = err
      end
      local ready = waiters
      waiters = {}
      for _, cb in ipairs(ready) do
        cb()
      end
    end)
  end
  if not loading and cache == nil then
    -- listDir failed synchronously: report the error right away.
    return nil, loadError, false
  end
  if not loading then
    return cache, nil, false
  end
  return cache, nil, true
end


-- ── Pinned profiles ─────────────────────────────────────────────────────────

-- Per-VM copy, only consulted when the shared state is empty (a fresh reload).
local pinsCache = nil

local function pinsFile()
  local dir = noctalia.pluginDataDir()
  if dir == nil then
    return nil
  end
  return dir .. "/" .. PINS_FILE
end

-- Stored as an array of profile paths: a JSON object with paths as keys would
-- work too, but the array survives a hand edit more gracefully.
local function readPins()
  local path = pinsFile()
  if path == nil then
    return {}
  end
  local content = noctalia.readFile(path)
  if type(content) ~= "string" or noctalia.string.trim(content) == "" then
    return {}
  end
  local decoded = noctalia.json.decode(content)
  if type(decoded) ~= "table" then
    return {}
  end
  local map = {}
  for _, entry in ipairs(decoded) do
    if type(entry) == "string" and entry ~= "" then
      map[entry] = true
    end
  end
  return map
end

local function writePins(map)
  local path = pinsFile()
  if path == nil then
    return false
  end
  local list = {}
  for profilePath, pinned in pairs(map) do
    if pinned then
      table.insert(list, profilePath)
    end
  end
  table.sort(list)
  local encoded = noctalia.json.encode(list, true)
  if encoded == nil then
    return false
  end
  return noctalia.writeFile(path, encoded)
end

-- The shared state wins when it holds a table: it is the copy the panel just
-- updated. Reading the file happens once per VM, after a reload.
function M.pins()
  local shared = noctalia.state.get(PINS_STATE_KEY)
  if type(shared) == "table" then
    pinsCache = shared
    return pinsCache
  end
  if pinsCache == nil then
    pinsCache = readPins()
  end
  noctalia.state.set(PINS_STATE_KEY, pinsCache)
  return pinsCache
end

function M.isPinned(profilePath)
  return M.pins()[profilePath] == true
end

-- Publishes a fresh table rather than mutating the current one: whoever holds
-- a reference to the old copy keeps a consistent snapshot.
function M.togglePin(profilePath)
  local current = M.pins()
  local updated = {}
  for path, pinned in pairs(current) do
    if pinned and path ~= profilePath then
      updated[path] = true
    end
  end
  local nowPinned = current[profilePath] ~= true
  if nowPinned then
    updated[profilePath] = true
  end
  pinsCache = updated
  noctalia.state.set(PINS_STATE_KEY, updated)
  writePins(updated)
  return nowPinned
end

-- Splits the (already sorted) list in two, keeping the relative order inside
-- each half. A pinned profile shows up at the top and *only* there, so the
-- same connection never appears twice.
function M.partitionPinned(profiles)
  local pins = M.pins()
  local pinned, rest = {}, {}
  for _, profile in ipairs(profiles) do
    if pins[profile.path] then
      table.insert(pinned, profile)
    else
      table.insert(rest, profile)
    end
  end
  return pinned, rest
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
