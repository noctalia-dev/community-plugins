-- service.luau
-- Headless service: runs monitor.sh (a dbus-monitor pipeline) and, for every
-- notification whose app_name/summary/body contains one of the configured
-- contact names, plays that contact's assigned OGG sound.
--
-- Contacts can be a single sound file or a folder of sounds:
--   * file   -> the sound is loaded and played as-is.
--   * folder -> folder_sounds["<name>"] picks one file; when empty a random
--               member plays, so a folder means "any of these sounds".
-- Every contact also has a kind (contact|group|app): "app" entries match the
-- notification's app name only, the others match summary/body/app-name like
-- before. contact_images only matters to the panel.
--
-- The sounds live in this runtime's sound bank (API 20). Contacts are loaded
-- one per update() tick so we stay under the 8-pending-loads cap, and the
-- "loaded" map is published to noctalia.state for the panel to render.

--!nonstrict

local SEP = string.char(0x1e)
local FS = string.char(0x1f)

local SOUND_EXTS = { ogg = true, mp3 = true, wav = true }

local sounds = {}   -- [slug] = { loaded = bool, name = string, path = string }
local pending = {}  -- queue of { name, path, slug } drained one per tick
local loading = false

-- Suppression-filter re-sync bookkeeping. requestFilterSync is assigned below
-- (after the suppression helpers) and publishLoaded already needs it, so it is
-- declared up here; by the time queueContacts() runs at the end of this module
-- the assignment has happened.
local filterDirty = false
local requestFilterSync

local function tr(key)
  return noctalia.tr(key)
end

local function shellQuote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- Stable sound-bank name per contact: survives reloads and avoids collisions.
local function slug(name)
  local s = name:lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  if s == "" then
    s = "contact"
  end
  if #s > 40 then
    s = s:sub(1, 40)
  end
  return "contact_" .. s
end

-- ---------------------------------------------------------------------------
-- Config + sound resolution
-- ---------------------------------------------------------------------------

local function cfgMap(key)
  local v = noctalia.getConfig(key) or {}
  local out = {}
  for k, val in pairs(v) do
    out[tostring(k)] = tostring(val)
  end
  return out
end

local function expandPath(p)
  if p:sub(1, 1) == "~" then
    return noctalia.expandPath(p)
  end
  return p
end

local function fileExt(p)
  local ext = p:match("%.([^./]+)$")
  return ext and ext:lower() or ""
end

local function listSounds(dir)
  local out = {}
  local names = noctalia.listDir(dir)
  if names then
    for _, n in ipairs(names) do
      if SOUND_EXTS[fileExt(n)] then
        out[#out + 1] = n
      end
    end
  end
  table.sort(out)
  return out
end

-- The sound file that should play for `name` right now. A folder entry
-- resolves to the chosen sound (folder_sounds), or a random member so a
-- folder means "any of these sounds".
local function resolveSoundFile(name)
  local contacts = noctalia.getConfig("contacts") or {}
  local raw = contacts[name]
  if not raw then
    return nil
  end
  local p = expandPath(tostring(raw))
  local info = noctalia.fileInfo(p)
  if info and info.isDir then
    local files = listSounds(p)
    if #files == 0 then
      return nil
    end
    local chosen = cfgMap("folder_sounds")[name]
    if chosen and chosen ~= "" then
      for _, f in ipairs(files) do
        if f == chosen then
          return p .. "/" .. f
        end
      end
    end
    return p .. "/" .. files[math.random(#files)]
  end
  return p
end

-- ---------------------------------------------------------------------------
-- Publishing loaded state
-- ---------------------------------------------------------------------------

-- Publishes every contact so the panel always has a row: warm/loaded entries
-- come from `sounds`, everything else is a not-loaded placeholder (the panel
-- turns that into its spinner/error glyph instead of dropping the row).
local function publishLoaded()
  local contacts = noctalia.getConfig("contacts") or {}
  local merged = {}
  for s, entry in pairs(sounds) do
    if contacts[entry.name] ~= nil then
      merged[s] = entry
    end
  end
  for name, rawPath in pairs(contacts) do
    local n = tostring(name)
    if n ~= "" then
      local s = slug(n)
      if not merged[s] then
        merged[s] = { loaded = false, name = n, path = tostring(rawPath) }
      end
    end
  end
  local ok, encoded = pcall(noctalia.json.encode, merged)
  if ok and type(encoded) == "string" then
    noctalia.state.set("loaded", encoded)
  end
  requestFilterSync()
end

-- Re-reads the contacts map into the pending queue (sorted, deterministic)
-- and drops warm entries that stopped resolving (deleted or empty folder).
local function queueContacts()
  pending = {}
  local contacts = noctalia.getConfig("contacts") or {}
  local resolvable = {}
  for name, rawPath in pairs(contacts) do
    local n = tostring(name)
    if n ~= "" and noctalia.string.trim(tostring(rawPath)) ~= "" then
      local s = slug(n)
      local resolved = resolveSoundFile(n)
      if resolved then
        resolvable[s] = true
        local entry = sounds[s]
        if not (entry and entry.loaded and entry.path == resolved) then
          table.insert(pending, { name = n, path = resolved, slug = s })
        end
      end
    end
  end
  for s in pairs(sounds) do
    if not resolvable[s] then
      sounds[s] = nil
    end
  end
  table.sort(pending, function(a, b)
    return a.name < b.name
  end)
  publishLoaded()
end

-- Loads one contact's sound. Sound names are scoped to this runtime, and
-- requesting a name that already has a pending load is rejected, so the queue
-- is drained serially (one per update() tick).
local function pumpLoads()
  if loading then
    return
  end
  local job = table.remove(pending, 1)
  if not job then
    return
  end
  loading = true
  local accepted = noctalia.sound.load(job.slug, job.path, function(ok, err)
    sounds[job.slug] = { loaded = ok, name = job.name, path = job.path }
    if not ok then
      noctalia.log(string.format("contact-sounds: failed to load %s (%s): %s", job.slug, job.path, tostring(err)))
    else
      noctalia.log("contact-sounds: loaded " .. job.name .. " (" .. job.path .. ")")
    end
    publishLoaded()
    loading = false
  end)
  if not accepted then
    -- rejected (shouldn't happen when draining serially) - retry next tick
    loading = false
  end
end

-- Loads a sound on demand and plays it once ready. Re-loads the slug whenever
-- the resolved file differs from what is warm, so a folder contact always
-- plays its currently-selected (or fresh random) file. startBusy/finishBusy
-- are function()/nil guards set by callers.
local function playNamed(name, startBusy, finishBusy)
  local resolved = resolveSoundFile(name)
  if not resolved then
    if finishBusy then
      finishBusy()
    end
    return
  end
  local s = slug(name)
  local entry = sounds[s]

  local function fire(ok)
    if finishBusy then
      finishBusy()
    end
    if ok then
      noctalia.sound.play(s)
    end
  end

  if entry and entry.loaded and entry.path == resolved then
    fire(true)
    return
  end

  if startBusy then
    startBusy()
  end
  local accepted = noctalia.sound.load(s, resolved, function(ok, err)
    sounds[s] = { loaded = ok, name = name, path = resolved }
    publishLoaded()
    if not ok then
      noctalia.log(string.format("contact-sounds: failed to load %s (%s): %s", s, resolved, tostring(err)))
    end
    fire(ok)
  end)
  if not accepted then
    fire(false)
  end
end

-- ---------------------------------------------------------------------------
-- Matching
-- ---------------------------------------------------------------------------

local function lower(s)
  if not s then
    return ""
  end
  return s:lower()
end

-- "app" contacts match the notification's app name only (they exist for
-- "this app made a sound"), while contacts/groups match summary + body + app
-- name like before.
local function matchContact(appName, title, body)
  local contacts = noctalia.getConfig("contacts") or {}
  local kinds = noctalia.getConfig("contact_kinds") or {}
  local sensitive = noctalia.getConfig("match_case_sensitive") == true

  for name, _ in pairs(contacts) do
    local n = tostring(name)
    local needle = sensitive and n or lower(n)
    if needle ~= "" then
      local kind = kinds[n] or "contact"
      local hay
      if kind == "app" then
        hay = appName
      else
        hay = title .. " " .. body .. " " .. appName
      end
      local search = sensitive and hay or lower(hay)
      if search:find(needle, 1, true) then
        return n
      end
    end
  end
end

local function appAllowed(appName)
  local apps = noctalia.getConfig("only_apps") or {}
  if #apps == 0 then
    return true
  end
  for _, app in ipairs(apps) do
    if tostring(app) == appName then
      return true
    end
  end
  return false
end

local function handleLine(line)
  if not line or line == "" then
    return
  end
  local fields = {}
  for part in line:gmatch("[^" .. SEP .. "]+") do
    fields[#fields + 1] = part
  end
  local appName = fields[1] or ""
  local title = fields[2] or ""
  local body = fields[3] or ""

  if not appAllowed(appName) then
    return
  end

  local contact = matchContact(appName, title, body)
  if not contact then
    return
  end

  local resolved = resolveSoundFile(contact)
  if not resolved then
    return
  end
  local s = slug(contact)
  local entry = sounds[s]

  local function played()
    noctalia.log("contact-sounds: playing " .. contact .. " (from " .. appName .. ")")
    noctalia.sound.play(s)
    noctalia.state.set("last_hit", contact)
    noctalia.state.set("last_hit_at", noctalia.nowMs() / 1000)
  end

  if entry and entry.loaded and entry.path == resolved then
    played()
    return
  end

  -- Folder contacts resolve to a (possibly random) file per hit: load that
  -- file into the same slug, then play. A name already pending here is rare
  -- (one in-flight hit); the queue drains it one tick later.
  local accepted = noctalia.sound.load(s, resolved, function(ok, err)
    sounds[s] = { loaded = ok, name = contact, path = resolved }
    publishLoaded()
    if not ok then
      noctalia.log(string.format("contact-sounds: failed to load %s (%s): %s", s, resolved, tostring(err)))
      return
    end
    played()
  end)
  if not accepted then
    noctalia.log("contact-sounds: hit while " .. s .. " was already loading; retrying next tick")
    table.insert(pending, { name = contact, path = resolved, slug = s })
  end
end

-- ---------------------------------------------------------------------------
-- System sound suppression
-- ---------------------------------------------------------------------------

local function escapeRegex(s)
  return s:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
end

local function loadedContactNames()
  local contacts = noctalia.getConfig("contacts") or {}
  local out = {}
  for _, entry in pairs(sounds) do
    if entry.loaded and contacts[entry.name] ~= nil then
      out[#out + 1] = entry.name
    end
  end
  table.sort(out)
  return out
end

local function buildContentRegex(names)
  local parts = {}
  for _, n in ipairs(names) do
    parts[#parts + 1] = escapeRegex(n)
  end
  if #parts == 0 then
    return ""
  end
  return "(?:" .. table.concat(parts, "|") .. ")"
end

local function syncSystemSoundFilter()
  local sensitive = noctalia.getConfig("match_case_sensitive") == true
  local apps = noctalia.getConfig("only_apps") or {}
  local names = loadedContactNames()

  local dir = noctalia.pluginDir()
  if not dir then
    return
  end
  local script = dir .. "/scripts/sync_filter.sh"

  local function run(verb)
    noctalia.runAsync("bash " .. shellQuote(script) .. " " .. verb, function(result)
      if result and result.exitCode ~= 0 then
        noctalia.log("contact-sounds: sync_filter.sh failed: " .. tostring(result.stderr))
      end
    end)
    noctalia.runAsync("noctalia msg config-reload")
  end

  if sensitive or #names == 0 then
    run("off")
    return
  end

  local verb = "on " .. shellQuote(buildContentRegex(names))
  if #apps > 0 then
    local listed = {}
    for _, app in ipairs(apps) do
      local a = tostring(app)
      if a ~= "" then
        listed[#listed + 1] = a
      end
    end
    if #listed > 0 then
      verb = verb .. " --apps " .. shellQuote(table.concat(listed, FS))
    end
  else
    verb = verb .. " --names " .. shellQuote(table.concat(names, FS))
  end
  run(verb)
end

requestFilterSync = function()
  filterDirty = true
end

-- ---------------------------------------------------------------------------
-- Monitor lifecycle
-- ---------------------------------------------------------------------------

local function startMonitor()
  local dir = noctalia.pluginDir()
  if not dir then
    return false
  end
  local script = dir .. "/scripts/monitor.sh"
  noctalia.runAsync("chmod +x " .. shellQuote(script))

  return noctalia.runStream(shellQuote(script), handleLine)
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

queueContacts()
local monitorStarted = startMonitor()
if not monitorStarted then
  noctalia.log("contact-sounds: could not start dbus-monitor stream")
end

function update()
  noctalia.setUpdateInterval(1000)
  pumpLoads()
  if filterDirty then
    filterDirty = false
    syncSystemSoundFilter()
  end
end

function onConfigChanged()
  queueContacts()
  requestFilterSync()
end

function onIpc(_event, payload)
  if _event == "play" and payload then
    playNamed(payload)
  elseif _event == "reload" then
    queueContacts()
  end
end

-- Removes the helper filter file when the plugin is disabled or uninstalled.
function onExit(_signal, reason)
  if reason == "disable" or reason == "uninstall" then
    local base = noctalia.getenv("NOCTALIA_CONFIG_HOME")
    if not base or base == "" then
      base = noctalia.getenv("XDG_CONFIG_HOME")
      if not base or base == "" then
        base = noctalia.expandPath("~/.config")
      end
    end
    noctalia.removeFile(base .. "/noctalia/contact-sounds.toml")
  end
end