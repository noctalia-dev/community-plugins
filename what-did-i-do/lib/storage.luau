-- lib/storage.luau — local persistence for activity sessions.
--
-- Everything is written inside noctalia.pluginDataDir() (per-plugin, survives
-- updates, honors NOCTALIA_STATE_HOME). No data ever leaves the machine.
--
-- Format: { version = 1, sessions = { ... } } as pretty JSON.
--
-- Recovery rules (spec §18–§20):
--   * The write is temp-file + rename, so a crash mid-write can only lose the
--     very last flush, never corrupt the previously stored history.
--   * If the stored file is malformed, it is preserved once as
--     history.corrupt-<unixtime>.json and an empty dataset starts; a bounded
--     number of such backups is kept.
--   * Unknown schema versions are NOT silently discarded — the file is
--     preserved as history.unknown-<version>.json and the plugin starts
--     empty (upgrades keep the old file intact).

local M = {}

M.SCHEMA_VERSION = 1
M.MAX_CORRUPT_BACKUPS = 3

-- Shell-exclusion filter: rows for excluded applications (the Noctalia shell
-- itself) must never re-enter tracking state from disk — not as closed
-- history and especially not as an "open" session to be recovered (a shell
-- session must never survive a plugin restart). NOTE: require must run inside
-- a closure; pcall(require, ...) breaks the host's lexical path resolution.
local exclusion
local ok_exclusion, exclusionMod = pcall(function()
  return require("./exclusion.luau")
end)
if ok_exclusion and type(exclusionMod) == "table" and type(exclusionMod.isExcludedApplication) == "function" then
  exclusion = exclusionMod
else
  exclusion = { isExcludedApplication = function() return false end }
end

-- Codec selection — the host's native noctalia.json runs outside the Luau
-- CPU budget and handles multi-megabyte histories without breaking a sweat;
-- the pure-Luau lib/json.luau decoder/encoder measurably exceeded the host's
-- per-callback CPU budget once history grew ("exceeded its CPU budget" during
-- persistence), so it is the FALLBACK here, used only where the host API is
-- missing (older hosts, test harnesses).
--
-- Conventions differ and are normalized to storage's internal (ok, value|err):
--   * NoctaliaJson (API docs): decode(str) -> (value, err?), encode(v, pretty?)
--     -> (string?, string?)
--   * lib/json.luau: decode(s) -> (ok, value|err), encode(v, pretty?) -> (ok, str|err)
-- NOTE: require must be called from inside a Lua closure, not passed to pcall
-- as a value — the host resolves relative paths from the calling file, and
-- pcall(require, ...) breaks that.
local encodeFn, decodeFn

if type(noctalia) == "table"
  and type(noctalia.json) == "table"
  and type(noctalia.json.encode) == "function"
  and type(noctalia.json.decode) == "function"
then
  encodeFn = function(value, pretty)
    local out, err = noctalia.json.encode(value, pretty)
    if out ~= nil then
      return true, out
    end
    return false, err or "host encode failed"
  end
  decodeFn = function(s)
    local value, err = noctalia.json.decode(s)
    if value ~= nil then
      return true, value
    end
    return false, err or "host decode failed"
  end
else
  local ok_json, json = pcall(function()
    return require("./json.luau")
  end)
  if ok_json
    and type(json) == "table"
    and type(json.encode) == "function"
    and type(json.decode) == "function"
  then
    encodeFn, decodeFn = json.encode, json.decode
  else
    encodeFn = function()
      return false, "no json codec available"
    end
    decodeFn = function()
      return false, "no json codec available"
    end
    if type(noctalia) == "table" and type(noctalia.log) == "function" then
      noctalia.log("what-did-i-do/storage: no json codec available (host API and lib/json.luau both missing)")
    end
  end
end

-- host abstraction: inject for tests; defaults to the Noctalia filesystem API.
function M.newStorage(opts)
  opts = opts or {}
  local host = opts.host or {
    dataDir = function()
      local dir, err = noctalia.pluginDataDir()
      if not dir then
        return nil, err
      end
      return dir .. "/activity"
    end,
    mkdirAll = function(path)
      return noctalia.mkdirAll(path)
    end,
    readFile = function(path)
      return noctalia.readFile(path)
    end,
    writeFile = function(path, contents)
      return noctalia.writeFile(path, contents)
    end,
    renameFile = function(from, to)
      return noctalia.renameFile(from, to)
    end,
    removeFile = function(path)
      return noctalia.removeFile(path)
    end,
    listDir = function(path)
      return noctalia.listDir(path)
    end,
    fileExists = function(path)
      return noctalia.fileExists(path)
    end,
    log = function(msg)
      noctalia.log(msg)
    end,
  }

  local encodeFn = opts.encode or encodeFn
  local decodeFn = opts.decode or decodeFn

  local self = {
    path = nil,
    _loaded = false,
    sessions = {},
    _dirty = false,
  }

  local function ensureDir()
    local dir = host.dataDir()
    if not dir then
      return nil, "no data dir"
    end
    local ok, err = host.mkdirAll(dir)
    if not ok then
      return nil, err
    end
    self.path = dir .. "/history.json"
    return dir
  end

  -- load() -> ok, err. Populates self.sessions. Never throws.
  function self:load()
    self._loaded = true
    local dir = ensureDir()
    if not dir then
      self.sessions = {}
      return false, "cannot create data directory"
    end
    if not host.fileExists(self.path) then
      self.sessions = {}
      return true
    end
    local raw, rerr = host.readFile(self.path)
    if raw == nil then
      self.sessions = {}
      return false, rerr or "unreadable history"
    end
    -- json codec convention: (ok, value | err)
    local okDec, decoded = decodeFn(raw)
    if not okDec then
      self:backupCorrupt(raw, "corrupt")
      self.sessions = {}
      return false, "malformed history: " .. tostring(decoded)
    end
    if type(decoded) ~= "table" or type(decoded.sessions) ~= "table" then
      self:backupCorrupt(raw, "corrupt")
      self.sessions = {}
      return false, "history has wrong shape"
    end
    local version = tonumber(decoded.version) or 0
    if version ~= M.SCHEMA_VERSION then
      -- Unknown (newer or older) schema: keep the file untouched on disk.
      self:backupCorrupt(raw, "unknown-" .. tostring(version))
      self.sessions = {}
      return false, "unknown schema version " .. tostring(version)
    end
    -- Sanitize rows: drop anything that is not a plausible session, and drop
    -- every row belonging to an excluded application (shell sessions are
    -- never legitimate history, and an open one must not be recovered).
    local rows = {}
    local droppedExcluded = 0
    for _, row in ipairs(decoded.sessions) do
      if type(row) == "table"
        and type(row.id) == "string"
        and type(row.dateKey) == "string"
        and type(row.startedAtMs) == "number" then
        if row.title ~= nil and type(row.title) ~= "string" then
          -- wrong title type: not a plausible session
        elseif exclusion.isExcludedApplication(row) then
          droppedExcluded = droppedExcluded + 1
        else
          rows[#rows + 1] = row
        end
      end
    end
    if droppedExcluded > 0 and type(host.log) == "function" then
      host.log("what-did-i-do: excluded " .. droppedExcluded .. " shell session row(s) from loaded history")
    end
    self.sessions = rows
    return true
  end

  -- save(closedSessionsOnly) -> ok, err. Writes temp + atomic rename.
  -- The open (in-progress) session is persisted too, marked open, so a crash
  -- keeps its partial data; on load, open sessions are simply treated as
  -- closed-at-loaded-time by the caller (see loadOpenAsClosed).
  function self:save(sessions)
    if self.path == nil then
      local dir = ensureDir()
      if not dir then
        return false, "no data dir"
      end
    end
    local payload = {
      version = M.SCHEMA_VERSION,
      sessions = sessions or self.sessions,
    }
    -- json codec convention: (ok, text | err)
    local okEnc, encoded = encodeFn(payload, true)
    if not okEnc then
      return false, "encode failed: " .. tostring(encoded)
    end
    local tmp = self.path .. ".tmp"
    local ok, werr = host.writeFile(tmp, encoded)
    if not ok then
      return false, werr or "write failed"
    end
    local okRename, rerr = host.renameFile(tmp, self.path)
    if not okRename then
      host.removeFile(tmp)
      return false, rerr or "rename failed"
    end
    return true
  end

  -- backupCorrupt(raw, label) — preserve bad data once, bounded.
  function self:backupCorrupt(raw, label)
    local dir = host.dataDir()
    if not dir then
      return
    end
    local stamp = tostring(os.time())
    local backupPath = dir .. "/history." .. label .. "-" .. stamp .. ".json"
    -- Never overwrite an existing backup from the same second.
    if host.fileExists(backupPath) then
      backupPath = backupPath .. "." .. tostring(math.random(1000, 9999))
    end
    host.writeFile(backupPath, raw)
    -- Bound the number of backups per label prefix.
    local names = host.listDir(dir)
    if names then
      local prefix = "history." .. label .. "-"
      local found = {}
      for _, name in ipairs(names) do
        if string.sub(name, 1, #prefix) == prefix then
          found[#found + 1] = name
        end
      end
      table.sort(found)
      while #found > M.MAX_CORRUPT_BACKUPS do
        host.removeFile(dir .. "/" .. table.remove(found, 1))
      end
    end
    host.log("what-did-i-do: preserved unreadable history as " .. backupPath)
  end

  -- clear() -> removes the history file and empties memory.
  function self:clear()
    self.sessions = {}
    if self.path and host.fileExists(self.path) then
      host.removeFile(self.path)
    end
    return true
  end

  return self
end

return M
