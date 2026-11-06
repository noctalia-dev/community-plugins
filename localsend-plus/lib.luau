--!nonstrict
-- Shared helpers: controller paths, RPC calls and formatting.
--
-- The entries talk through noctalia.state. The service owns the daemon and
-- answers requests; each request carries an increasing seq, so one left over
-- from an earlier run is ignored.
--
--   ls              service -> all     daemon snapshot plus up, phase, vis, autoAcceptChoice
--   controller      service -> all     { path, version } of the controller found
--   favorites       lib -> all         fingerprint -> { alias, type, host, port }
--   hidden          panel, service     transfer ids cleared from the history
--   panel_open      panel -> all       whether the panel is open
--   vis_seen        panel              the visibility change already shown
--   retry_id        service -> panel   transfer that can be retried with a PIN
--   pick            panel, launcher    send request { seq, kind, fingerprint, alias, sha, paths }
--   clip_ask        launcher -> panel  preview the clipboard for a device { seq, fingerprint, at }
--   send_ask        service -> panel   paths from IPC waiting for a device { seq, paths, at }
--   visibility_req  panel, launcher    { seq, mode, temp }
--   pin_req         panel -> service   receive PIN { seq, pin }, cleared once stored
--   pin_retry       panel -> service   PIN for a failed send { seq, id, pin }, cleared at once
--   auto_req        panel -> service   accept from anyone with the PIN { seq, on }
--   poke, restart   any -> service     counters: snapshot now, restart the daemon

local M = {}

-- The plugin id, as in plugin.toml (the API does not expose it). A second
-- copy under another id gets its own socket and runs beside this one.
M.ID = "0rgl/localsend-plus"
M.PANEL = M.ID .. ":panel"
M.PLUGIN_DIR = noctalia.pluginDir() or ""
M.ACTIVE = { preparing = true, transferring = true, cancelling = true }
-- Failed sends the panel can retry with a PIN (pin_locked cannot be).
M.PIN_ERRORS = { pin_required = true, pin_invalid = true }

local runtime = noctalia.getenv("XDG_RUNTIME_DIR")
local RUNTIME_PREFIX = runtime ~= nil and runtime ~= "" and (runtime .. "/" .. M.ID:gsub("/", "-")) or nil
M.SOCK = RUNTIME_PREFIX and (RUNTIME_PREFIX .. ".sock") or nil

-- The plugin data directory, or nil when Noctalia gives none; nothing is
-- stored then.
local dataDir = noctalia.pluginDataDir()
M.DATA_DIR = dataDir ~= nil and dataDir ~= "" and dataDir or nil

function M.dataFile(name)
  return M.DATA_DIR and (M.DATA_DIR .. "/" .. name) or nil
end

-- Controller calls wait up to this long (the controller gives up after 35 s);
-- runAsync would otherwise kill them after 5 s.
local RPC_TIMEOUT_MS = 40000

-- The controller binary the service found (nil until then, or when missing).
function M.bin()
  return (noctalia.state.get("controller") or {}).path
end

-- Writes a PIN for `--pin-file` and returns the path. XDG_RUNTIME_DIR is
-- private to this user and in memory; the controller deletes the file as
-- soon as it has read it, and removeSecret covers a controller that never
-- got that far.
local function secretPath(name)
  return RUNTIME_PREFIX and (RUNTIME_PREFIX .. "-" .. name) or nil
end

function M.writeSecret(name, value)
  local path = secretPath(name)
  if path == nil or not noctalia.writeFile(path, value) then return nil end
  return path
end

function M.removeSecret(name)
  local path = secretPath(name)
  if path ~= nil and noctalia.fileExists(path) then noctalia.removeFile(path) end
end

function M.shq(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

function M.trim(s)
  return (tostring(s):match("^%s*(.-)%s*$"))
end

-- A version as { major, minor, patch }, or nil when `text` holds none.
function M.versionParts(text)
  local major, minor, patch = tostring(text or ""):match("(%d+)%.(%d+)%.(%d+)")
  if major == nil then return nil end
  return { tonumber(major), tonumber(minor), tonumber(patch) }
end

function M.olderThan(a, b)
  for i = 1, 3 do
    if a[i] ~= b[i] then return a[i] < b[i] end
  end
  return false
end

-- From the controllers found ({ path, version }, version nil when one gave
-- none), in order of preference: the first at least `needed`. Otherwise nil
-- and the newest one, for the error. Checking them all keeps an old copy
-- early in PATH from hiding a rebuilt one in ~/.cargo/bin.
function M.pickController(found, needed)
  local newest = nil
  for _, candidate in ipairs(found) do
    if candidate.version ~= nil then
      if needed == nil or not M.olderThan(candidate.version, needed) then return candidate, nil end
      if newest == nil or M.olderThan(newest.version, candidate.version) then newest = candidate end
    end
  end
  return nil, newest
end

-- The command that installs or updates the controller. The script beside
-- its sources checks for Rust and a C compiler, builds it and restarts the
-- service; it is plain sh, so the line works from fish, bash, zsh or nu.
-- `pause` keeps a terminal opened for it until Enter.
function M.updateCommand(pause)
  return "sh " .. M.shq(M.PLUGIN_DIR .. "/controller/update.sh") .. (pause and " --pause" or "")
end

-- Saves `value` as JSON; false and the reason when that fails.
function M.writeJson(path, value)
  local text, err = noctalia.json.encode(value)
  if text == nil then return false, err end
  return noctalia.writeFile(path, text)
end

-- Posts a request to another entry in state `key`. Each one carries the
-- next seq, so the receiver can tell it from one left over from an earlier
-- run.
function M.post(key, fields)
  fields.seq = ((noctalia.state.get(key) or {}).seq or 0) + 1
  noctalia.state.set(key, fields)
end

function M.openPanel()
  if not noctalia.state.get("panel_open") then noctalia.togglePanel(M.PANEL) end
end

-- What to show for a failed controller call.
function M.errorText(err)
  return err and err.message ~= nil and err.message ~= "" and err.message or noctalia.tr("error.unknown")
end

-- Runs the controller with `args` and calls cb(ok, result, err). `err` is
-- the controller's ApiError table ({ code, message }) or a synthetic one.
local function run(args, cb)
  local bin = M.bin()
  if bin == nil then
    if cb then cb(false, nil, { code = "no_controller", message = "localsend-controller was not found" }) end
    return
  end
  noctalia.runAsync(table.move(args, 1, #args, 2, { bin }), function(res)
    if not cb then return end
    local data = noctalia.json.decode(M.trim(res.stdout or ""))
    if type(data) ~= "table" then
      cb(false, nil, { code = "bad_output", message = M.trim(res.stderr or "") })
    elseif data.ok then
      cb(true, data.result, nil)
    else
      cb(false, nil, data.error or { code = "unknown", message = "" })
    end
  end, RPC_TIMEOUT_MS)
end

-- Runs `localsend-controller --socket SOCK <args...>` against the daemon.
function M.rpc(args, cb)
  if M.SOCK == nil then
    if cb then cb(false, nil, { code = "no_runtime_dir", message = "XDG_RUNTIME_DIR is not set" }) end
    return
  end
  run(table.move(args, 1, #args, 3, { "--socket", M.SOCK }), cb)
end

-- Reads the clipboard for a preview: cb(ok, { sha256, preview, truncated }, err).
-- The controller refuses a secret marked by a password manager.
function M.readClipboard(previewChars, cb)
  run({ "read-clipboard", "--preview-chars", tostring(previewChars) }, cb)
end

-- Hands a send to the long-lived service (kind = files | folder | clipboard
-- | paths). Panels and the launcher close as soon as a file dialog takes
-- focus, which would drop any callback they own. A clipboard send carries
-- the SHA-256 of the text the user confirmed; the controller refuses a
-- changed clipboard. A paths send carries the files already chosen.
function M.request(kind, device, sha, paths)
  M.post("pick", { kind = kind, fingerprint = device.fingerprint, alias = device.alias, sha = sha, paths = paths })
end

-- What the controller accepts as a PIN: 1 to 64 characters, no control
-- characters. Accepting files from anyone needs at least 8.
function M.validPin(pin)
  local length = type(pin) == "string" and utf8.len(pin) or nil
  if length == nil or length < 1 or length > 64 then return false end
  -- Control characters as Rust counts them: C0, DEL and C1.
  for _, code in utf8.codes(pin) do
    if code < 0x20 or (code >= 0x7F and code <= 0x9F) then return false end
  end
  return true
end

-- The local path of a file:// URI, percent-decoded; nil for any other URI.
function M.pathFromUri(uri)
  local path = uri:match("^file://localhost(/.*)$") or uri:match("^file://(/.*)$")
  return path and noctalia.string.urlDecode(path) or nil
end

-- The paths in an IPC `send` payload: absolute paths, one per line. Only a
-- carriage return is stripped, since spaces at either end belong to the file
-- name. The file manager entries put the number of paths first; nil when the
-- lines do not add up to it, because a name held a line break and would
-- otherwise read as two paths.
function M.payloadPaths(payload)
  local paths = {}
  for _, line in ipairs(tostring(payload or ""):split("\n")) do
    local path = line:gsub("\r$", "")
    if path ~= "" then table.insert(paths, path) end
  end
  local count = paths[1] and paths[1]:match("^%s*(%d+)%s*$")
  if count == nil then return paths end
  table.remove(paths, 1)
  return #paths == tonumber(count) and paths or nil
end

-- Last path component, for showing file names.
function M.basename(path)
  return (tostring(path):match("([^/]+)/*$")) or tostring(path)
end

-- Up to `max` items of `list` joined with ", ", then "and N more".
function M.summary(list, max)
  local shown = {}
  for i, item in ipairs(list) do
    if i > max then break end
    table.insert(shown, item)
  end
  local text = table.concat(shown, ", ")
  if #list > max then text = text .. " " .. noctalia.tr("panel.more", { count = tostring(#list - max) }) end
  return text
end

-- Asks the panel to confirm a clipboard send to this device (the launcher
-- cannot show a preview itself).
function M.askClipboard(device)
  M.post("clip_ask", { fingerprint = device.fingerprint, at = os.time() })
  M.openPanel()
end

-- Favorites: fingerprint -> { alias, type, host, port }, persisted in the
-- plugin data dir and cached in noctalia.state so every entry sees changes at
-- once. host/port are the last HTTPS address seen: the favorites and hidden
-- modes do not announce, so the controller probes favorites there.
local FAV_FILE = M.dataFile("favorites.json")

-- Makes a data file readable by this user only. writeFile creates new files
-- 0644 and keeps the mode of existing ones; the directory itself is 0700.
function M.restrictFile(path)
  if path ~= nil and noctalia.fileExists(path) then noctalia.runAsync({ "chmod", "600", path }) end
end

local function saveFavorites(fav)
  noctalia.state.set("favorites", fav)
  if FAV_FILE == nil then return end
  local ok, err = M.writeJson(FAV_FILE, fav)
  if not ok then noctalia.log("localsend: could not save favorites: " .. tostring(err)) end
  M.restrictFile(FAV_FILE)
end

function M.favorites()
  local fav = noctalia.state.get("favorites")
  if type(fav) == "table" then return fav end
  fav = {}
  local raw = FAV_FILE and noctalia.readFile(FAV_FILE)
  if raw ~= nil then
    local data = noctalia.json.decode(raw)
    if type(data) == "table" then fav = data end
  end
  noctalia.state.set("favorites", fav)
  return fav
end

function M.setFavorite(device, pinned)
  local fav = M.favorites()
  local entry = nil
  if pinned then
    local previous = fav[device.fingerprint] or {}
    local address = device.address
    entry = {
      alias = device.alias,
      type = device.type,
      host = address and address.host or previous.host,
      port = address and address.port or previous.port,
    }
  end
  fav[device.fingerprint] = entry
  saveFavorites(fav)
end

-- Records where online favorites are now reachable; saves only on a change.
function M.rememberAddresses(devices)
  local fav = M.favorites()
  local changed = false
  for _, d in ipairs(devices or {}) do
    local info = fav[d.fingerprint]
    if
      info ~= nil
      and d.online
      and d.address ~= nil
      and (info.host ~= d.address.host or info.port ~= d.address.port)
    then
      info.host, info.port = d.address.host, d.address.port
      changed = true
    end
  end
  if changed then saveFavorites(fav) end
end

-- `--favorite FP[=HOST:PORT]` arguments for the controller.
function M.favoriteArgs()
  local args = {}
  for fp, info in pairs(M.favorites()) do
    if tostring(fp):match("^%w+$") then
      table.insert(args, "--favorite")
      local port = tonumber(info.port)
      if info.host ~= nil and port ~= nil then
        table.insert(args, string.format("%s=%s:%d", fp, info.host, port))
      else
        table.insert(args, fp)
      end
    end
  end
  return args
end

-- Visibility modes; the temporary one is "everyone" for TEMP_SECONDS.
M.VISIBILITY = { everyone = true, favorites = true, hidden = true }
M.TEMP_SECONDS = 600

-- Asks the service to change the visibility (temp = everyone for a while).
function M.requestVisibility(mode, temp)
  M.post("visibility_req", { mode = mode, temp = temp == true })
end

function M.visibilityGlyph(mode)
  if mode == "hidden" then return "eye-off" end
  if mode == "favorites" then return "star" end
  return "eye"
end

-- Whole minutes left of a temporary visibility, rounded up.
function M.minutesLeft(tempUntil)
  return math.max(1, math.ceil(((tempUntil or 0) - os.time()) / 60))
end

-- Devices for display: favorites first (offline favorites included, from the
-- saved alias), then the controller's order (online first, by alias).
-- Favorites always show the alias saved when they were pinned: a plain HTTP
-- announcement can rename a known device, so a changed name is only
-- reported (reportedAlias), never shown in its place.
function M.sortedDevices(devices)
  local fav = M.favorites()
  local list, seen = {}, {}
  for i, d in ipairs(devices or {}) do
    seen[d.fingerprint] = true
    local info = fav[d.fingerprint]
    if info ~= nil and info.alias ~= nil and info.alias ~= d.alias then
      d = table.clone(d)
      d.reportedAlias = d.alias
      d.alias = info.alias
    end
    table.insert(list, { device = d, pinned = info ~= nil, order = i })
  end
  for fp, info in pairs(fav) do
    if not seen[fp] then
      table.insert(list, {
        device = { fingerprint = fp, alias = info.alias or "?", type = info.type, online = false },
        pinned = true,
        order = math.huge,
      })
    end
  end
  table.sort(list, function(a, b)
    if a.pinned ~= b.pinned then return a.pinned end
    if a.order ~= b.order then return a.order < b.order end
    return tostring(a.device.alias) < tostring(b.device.alias)
  end)
  return list
end

-- The saved favorite with this fingerprint, compared without regard to case
-- as the controller compares them; nil for any other device.
function M.favoriteOf(fingerprint)
  local wanted = tostring(fingerprint or ""):upper()
  for fp, info in pairs(M.favorites()) do
    if tostring(fp):upper() == wanted then return info end
  end
  return nil
end

-- How a sender or receiver is named. A favorite goes by the alias saved when
-- it was pinned. Anyone else goes by the alias it reports plus the start of
-- its fingerprint, since a device can report any name; the second result is
-- true when that name is also a favorite's.
function M.peerLabel(peer)
  if peer == nil then return "?", false end
  local alias = peer.alias or "?"
  local favorite = M.favoriteOf(peer.fingerprint)
  if favorite ~= nil then return favorite.alias or alias, false end
  local impostor = false
  for _, info in pairs(M.favorites()) do
    if type(info.alias) == "string" and info.alias:lower() == alias:lower() then
      impostor = true
      break
    end
  end
  return string.format("%s (%s)", alias, M.shortFingerprint(peer.fingerprint)), impostor
end

-- History cleared in the panel: finished transfer ids hidden for this
-- session (the controller keeps only a few recent ones, in memory).
function M.hiddenTransfers()
  return noctalia.state.get("hidden") or {}
end

-- Rebuilt from the current list, so ids the controller has dropped go too.
function M.clearHistory(transfers)
  local hidden = {}
  for _, t in ipairs(transfers or {}) do
    if not M.ACTIVE[t.state] then hidden[t.id] = true end
  end
  noctalia.state.set("hidden", hidden)
end

-- First characters of a certificate fingerprint, enough to tell devices
-- with the same alias apart.
function M.shortFingerprint(fp)
  return tostring(fp or ""):sub(1, 8)
end

-- Transfer error codes with a message in the user's language.
local TRANSFER_ERROR_KEYS = {
  pin_required = "error.pin_required",
  pin_invalid = "error.pin_invalid",
  pin_locked = "error.pin_locked",
  receive_stalled = "error.receive_stalled",
}

-- The message for a transfer's error, translated when the code is known.
function M.transferError(err)
  if err == nil then return nil end
  local key = TRANSFER_ERROR_KEYS[err.code]
  return key and noctalia.tr(key) or err.message
end

-- Asks the service for an immediate snapshot after an action.
function M.poke()
  noctalia.state.set("poke", (noctalia.state.get("poke") or 0) + 1)
end

function M.formatBytes(n)
  n = tonumber(n) or 0
  local units = { "B", "KB", "MB", "GB", "TB" }
  local i = 1
  while n >= 1024 and i < #units do
    n = n / 1024
    i = i + 1
  end
  if i == 1 then return string.format("%d %s", n, units[i]) end
  return string.format("%.1f %s", n, units[i])
end

function M.dirname(path)
  return (tostring(path):match("^(.*)/[^/]*$")) or path
end

function M.deviceGlyph(t)
  if t == "mobile" then return "device-mobile" end
  if t == "web" then return "world" end
  if t == "server" or t == "headless" then return "server" end
  return "device-desktop"
end

return M
