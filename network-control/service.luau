--!nonstrict
-- Network Control service - the only entry that talks to NetworkManager.
--
-- Reads through `nmcli -t`: the connection inventory, the selected profile's
-- stored properties, the live addresses on the device, the radio state and the
-- caller's polkit permissions.
--
-- Writes go through a confirm window, because a wrong static address on the
-- interface carrying the default route is exactly the mistake that locks you out
-- of your own network. Every write saves the previous profile first, re-activates
-- the connection, and then arms a countdown: kept -> the new profile stands,
-- anything else (the countdown, Revert, or a shell restart in between) -> the
-- saved profile is restored property by property and the connection brought back
-- up. The backup is on disk, so `restore` in the panel recovers it later too.
--
--   noctalia.state.set("network.state", snapshot)     UI entries render this
--   noctalia.state.watch("network.request", handler)  actions from bar/panel
--
-- Only NetworkManager is supported: systemd-networkd and netplan have no profile
-- API that can be safely round-tripped from a shell plugin, and this box runs NM
-- for both Wi-Fi and Ethernet.

local net = require("./net.luau")

local CMD_TIMEOUT_MS = 12000
local UP_TIMEOUT_MS = 45000
-- A `--rescan yes` runs a fresh scan on the radio: ~6s here, so a scan is not
-- allowed to share the ordinary command timeout.
local SCAN_TIMEOUT_MS = 30000
local TICK_MS = 1000
-- Probing with the resolver address the profile itself uses keeps the route
-- lookup honest on a box that has several default routes.
local PROBE_ADDRESS = "1.1.1.1"
local BACKUP_FILE = "last-profile.json"

local available = noctalia.commandExists("nmcli")
-- `ip` lives in /usr/sbin on this box and may not be on the shell's PATH.
local ipCommand = noctalia.commandExists("ip") and "ip" or "/usr/sbin/ip"
local ipAvailable = noctalia.commandExists("ip") or noctalia.fileExists("/usr/sbin/ip")

local function numberSetting(key, fallback, min, max)
  local value = tonumber(noctalia.getConfig(key))
  if value == nil then
    return fallback
  end
  value = math.floor(value)
  if value < min then
    return min
  end
  if value > max then
    return max
  end
  return value
end

local confirmSeconds = numberSetting("confirm_seconds", 45, 0, 600)
local refreshSeconds = numberSetting("refresh_seconds", 15, 5, 600)

-- ── state ────────────────────────────────────────────────────────────────────

local connections = {}
local selected = nil -- uuid
local networks = {} -- last scan, one entry per SSID
local savedSsids = {} -- ssid -> uuid of the profile that already knows it
local scanning = false
local pendingSelectSsid = nil -- connect target, selected once the scan catches up
local profile = nil -- normalized stored properties of `selected`
local live = nil -- runtime state of the selected connection's device
local primary = nil -- device carrying the default route, plus its live state
local deviceStatus = {}
local permissions = nil
local radios = {}
local busy = false
local errorMessage = nil
local lastScanMs = 0
local pending = nil -- { uuid, name, deadline_ms }
local lastRecord = nil -- last saved profile (restore point)
local lastRefreshMs = 0

local function firstLine(stderr, stdout)
  for _, text in ipairs({ stderr, stdout }) do
    if type(text) == "string" then
      for line in text:gmatch("[^\n]+") do
        local trimmed = noctalia.string.trim(line)
        if trimmed ~= "" then
          return trimmed
        end
      end
    end
  end
  return nil
end

-- Naming the network matters when a few joins are attempted in a row: "could not
-- be found" on its own does not say which one could not be found.
local function namedError(name, result)
  local detail = firstLine(result.stderr, result.stdout)
  if detail == "" then
    return name
  end
  return name .. ": " .. detail
end

-- A result for a process that could not be started at all. noctalia.runAsync
-- returns false and never calls back in that case, so without this a caller that
-- only reacts in its callback stays busy forever.
local function startFailure(program)
  return { exitCode = 127, stdout = "", stderr = program .. ": could not be started", timedOut = false }
end

-- `nmcli <args>`: the program is prepended here. Every program that is NOT nmcli
-- must go through runTool - handing this function {"install", ...} runs
-- `nmcli install`, which fails silently and leaves the real work undone.
local function run(args, timeoutMs, onResult)
  local argv = { "nmcli" }
  for _, arg in ipairs(args) do
    table.insert(argv, arg)
  end
  if noctalia.runAsync(argv, onResult, timeoutMs) == false then
    onResult(startFailure("nmcli"))
  end
end

-- A program other than nmcli, argv[1] included.
local function runTool(argv, timeoutMs, onResult)
  if noctalia.runAsync(argv, onResult, timeoutMs) == false then
    onResult(startFailure(argv[1] or "command"))
  end
end


-- `ip -j route get 1.1.1.1`, for the widget: the interface the kernel would
-- actually use, not the first entry in the routing table.
local function probeRoute(onResult)
  runTool({ ipCommand, "-j", "route", "get", PROBE_ADDRESS }, CMD_TIMEOUT_MS, onResult)
end

local function connectionByUuid(uuid)
  for _, connection in ipairs(connections) do
    if connection.uuid == uuid then
      return connection
    end
  end
  return nil
end

local function editableConnections()
  local out = {}
  for _, connection in ipairs(connections) do
    if connection.editable then
      table.insert(out, connection)
    end
  end
  return out
end

local function networkBySsid(ssid)
  for _, network in ipairs(networks) do
    if network.ssid == ssid then
      return network
    end
  end
  return nil
end

local function lastScanAgeMs()
  if lastScanMs == 0 then
    return nil
  end
  return noctalia.nowMs() - lastScanMs
end

local function defaultSelection()
  local editable = editableConnections()
  for _, connection in ipairs(editable) do
    if connection.active then
      return connection.uuid
    end
  end
  return editable[1] ~= nil and editable[1].uuid or nil
end

-- Fail closed: until a probe has said `yes`, no write is offered. Assuming
-- permission and letting nmcli refuse later contradicts the documented behaviour
-- and shows the user an Apply button that cannot work.
local function permissionOk()
  if permissions == nil then
    return false
  end
  return permissions["org.freedesktop.NetworkManager.settings.modify.system"] == "yes"
end

-- A callback that never fires (its process killed, the shell interrupted mid-run)
-- would otherwise leave `busy` set for the rest of the session, and every later
-- action is refused by the busy guard: the panel just looks dead. The tick
-- notices instead of waiting forever.
local busySinceMs = 0
local busyWasSet = false
local BUSY_LIMIT_MS = math.max(CMD_TIMEOUT_MS, UP_TIMEOUT_MS) + 20000

local function publish()
  if errorMessage ~= lastPublishedError then
    lastPublishedError = errorMessage
  end
  noctalia.state.set("network.state", {
    available = available,
    permission_ok = permissionOk(),
    permission_known = permissions ~= nil,
    connections = connections,
    devices = deviceStatus,
    networks = networks,
    scanning = scanning,
    saved_ssids = savedSsids,
    scanned_age_ms = lastScanAgeMs(),
    selected = selected,
    profile = profile,
    live = live,
    primary = primary,
    radio = radios,
    busy = busy,
    error = errorMessage,
    pending = pending,
    -- Only advertise a restore point that belongs to the connection on screen.
    backup = (lastRecord ~= nil and lastRecord.uuid == selected) and {
      name = lastRecord.name,
      at = lastRecord.at,
      summary = net.summarize(lastRecord.fields),
    } or nil,
    now_ms = noctalia.nowMs(),
    -- Monotonic like now_ms: the panel uses the difference, never the value.
    refreshed_at_ms = lastRefreshMs,
    confirm_seconds = confirmSeconds,
    refresh_seconds = refreshSeconds,
  })
end

-- ── backup file ──────────────────────────────────────────────────────────────

local function dataFile(name)
  local dir = noctalia.pluginDataDir()
  if dir == nil then
    return nil
  end
  return dir .. "/" .. name
end

local function backupPath()
  return dataFile(BACKUP_FILE)
end

local function writeBackup(record)
  local path = backupPath()
  if path == nil then
    return false
  end
  local encoded = noctalia.json.encode(record, true)
  if encoded == nil then
    return false
  end
  return noctalia.writeFile(path, encoded) == true
end

local function readBackup()
  local path = backupPath()
  if path == nil or not noctalia.fileExists(path) then
    return nil
  end
  local text = noctalia.readFile(path)
  if text == nil then
    return nil
  end
  local decoded = noctalia.json.decode(text)
  if type(decoded) ~= "table" or type(decoded.fields) ~= "table" or type(decoded.uuid) ~= "string" then
    return nil
  end
  return decoded
end

-- ── reads ────────────────────────────────────────────────────────────────────

local function refreshPrimary(next)
  if not ipAvailable then
    primary = nil
    return next()
  end
  probeRoute(function(result)
    local probed = result.exitCode == 0 and net.primaryFromRouteJson(result.stdout, noctalia.json.decode) or nil
    if probed == nil then
      -- No route to anywhere: the widget's offline state.
      primary = nil
      return next()
    end
    if live ~= nil and live.device == probed.device then
      primary = { device = probed.device, address = probed.address, live = live }
      return next()
    end
    run({ "-t", "-f", net.DEVICE_FIELDS, "dev", "show", probed.device }, CMD_TIMEOUT_MS, function(detail)
      primary = {
        device = probed.device,
        address = probed.address,
        live = detail.exitCode == 0 and net.liveFromText(detail.stdout) or nil,
      }
      next()
    end)
  end)
end

-- Every result is bound to the uuid this refresh started with. Selecting another
-- connection while nmcli is in flight must not write the old profile into the new
-- selection: commit() compares uuid == selected, so it would happily write one
-- profile's values to another.
local function refreshDetails(next)
  local target = selected
  local connection = connectionByUuid(target)
  if connection == nil then
    if selected == target then
      profile, live = nil, nil
    end
    return next()
  end
  run({ "-t", "-f", net.PROFILE_FIELDS, "con", "show", target }, CMD_TIMEOUT_MS, function(result)
    if selected ~= target then
      return next() -- stale: a newer refresh owns `profile`
    end
    profile = result.exitCode == 0 and net.profileFromText(result.stdout) or nil
    local device = connection.device
    if device == nil or device == "" then
      live = nil
      return next()
    end
    run({ "-t", "-f", net.DEVICE_FIELDS, "dev", "show", device }, CMD_TIMEOUT_MS, function(detail)
      if selected ~= target then
        return next()
      end
      live = detail.exitCode == 0 and net.liveFromText(detail.stdout) or nil
      next()
    end)
  end)
end

local function refreshMeta(next)
  run({ "-t", "-f", net.STATUS_FIELDS, "dev", "status" }, CMD_TIMEOUT_MS, function(status)
    deviceStatus = status.exitCode == 0 and net.deviceStatusFromText(status.stdout) or {}
    run({ "radio" }, CMD_TIMEOUT_MS, function(radio)
      radios = radio.exitCode == 0 and net.radioFromText(radio.stdout) or {}
      if permissions ~= nil then
        return next()
      end
      run({ "-t", "general", "permissions" }, CMD_TIMEOUT_MS, function(perms)
        permissions = perms.exitCode == 0 and net.permissionsFromText(perms.stdout) or nil
        next()
      end)
    end)
  end)
end

-- Which SSIDs already have a profile. `nmcli dev wifi connect` creates a new one,
-- so knowing this is what lets a saved network connect without a password prompt.
-- Which SSIDs already have a profile. One `nmcli con show` per saved Wi-Fi
-- profile, issued together rather than one after another (a serial chain grows
-- with the number of saved networks and can outlast the refresh interval), and
-- reused until the set of Wi-Fi profiles actually changes.
local ssidCache, ssidCacheKey = {}, ""

local function refreshSsids(next)
  local wifi = {}
  for _, connection in ipairs(connections) do
    if connection.kind == "wifi" then
      table.insert(wifi, connection)
    end
  end
  local uuids = {}
  for _, connection in ipairs(wifi) do
    table.insert(uuids, connection.uuid)
  end
  local key = table.concat(uuids, ",")
  if key == ssidCacheKey then
    savedSsids = ssidCache
    return next()
  end
  if #wifi == 0 then
    ssidCache, ssidCacheKey, savedSsids = {}, "", {}
    return next()
  end
  local found, remaining = {}, #wifi
  for _, connection in ipairs(wifi) do
    run({ "-t", "-f", "802-11-wireless.ssid", "con", "show", connection.uuid }, CMD_TIMEOUT_MS, function(result)
      local ssid = result.exitCode == 0 and net.profileSsid(result.stdout) or nil
      if ssid ~= nil and ssid ~= "" then
        found[ssid] = connection.uuid
      end
      remaining = remaining - 1
      if remaining == 0 then
        ssidCache, ssidCacheKey, savedSsids = found, key, found
        next()
      end
    end)
  end
end

-- A completed connect should leave the panel pointed at what just came up.
local function resolvePendingSelect(next)
  if pendingSelectSsid == nil then
    return next()
  end
  for _, connection in ipairs(connections) do
    if connection.kind == "wifi"
      and (savedSsids[pendingSelectSsid] == connection.uuid or connection.name == pendingSelectSsid) then
      selected = connection.uuid
      pendingSelectSsid = nil
      break
    end
  end
  next()
end

local function refresh()
  if not available then
    publish()
    return
  end
  lastRefreshMs = noctalia.nowMs()
  run({ "-t", "-f", net.INVENTORY_FIELDS, "con", "show" }, CMD_TIMEOUT_MS, function(result)
    if result.exitCode ~= 0 or result.timedOut then
      errorMessage = firstLine(result.stderr, result.stdout)
      publish()
      return
    end
    connections = net.connectionsFromText(result.stdout)
    if selected == nil or connectionByUuid(selected) == nil then
      selected = defaultSelection()
    end
    refreshDetails(function()
      refreshMeta(function()
        refreshSsids(function()
          resolvePendingSelect(function()
            refreshPrimary(function()
              -- Deliberately NOT clearing errorMessage here: a failed join or a
              -- refused write sets it and then refreshes, and a periodic refresh
              -- landing a second later would wipe the only explanation the panel
              -- has. Every action clears it at its own start instead.
              publish()
            end)
          end)
        end)
      end)
    end)
  end)
end

-- ── Wi-Fi scan ───────────────────────────────────────────────────────────────

-- `rescan` runs a fresh radio scan (~6s) instead of reading NetworkManager's
-- cached list. The panel opens with the cached one and offers Scan for fresh
-- results, so opening it never blocks on the radio.
local function scan(rescan)
  if scanning or busy then
    return
  end
  -- `radios.wifi == nil` means the radio state has not been read yet, which is not
  -- the same as off: proceed and let nmcli report the real error if it is.
  if radios.wifi == "disabled" then
    errorMessage = noctalia.tr("wifi.radio_off")
    publish()
    noctalia.notifyError(noctalia.tr("notify.scan_failed"), errorMessage)
    return
  end
  scanning = true
  -- A scan asks for the current list; it does not resolve whatever went wrong
  -- last. An automatic rescan (the panel opening, the follow-up after a join)
  -- used to wipe the message explaining a failure the user was still reading.
  -- Only the Scan button, which asks for a rescan, clears it.
  if rescan == true then
    errorMessage = nil
  end
  publish()
  run({ "-t", "-f", net.WIFI_FIELDS, "dev", "wifi", "list", "--rescan", rescan and "yes" or "no" },
    SCAN_TIMEOUT_MS, function(result)
      scanning = false
      if result.exitCode ~= 0 or result.timedOut then
        errorMessage = firstLine(result.stderr, result.stdout)
        publish()
        noctalia.notifyError(noctalia.tr("notify.scan_failed"), errorMessage)
        return
      end
      networks = net.networksFromText(result.stdout)
      lastScanMs = noctalia.nowMs()
      publish()
    end)
end

-- ── writes ───────────────────────────────────────────────────────────────────

-- A settled action that did not fail clears the last failure. Failures keep
-- their message on screen until the next success, and background refreshes clear
-- nothing at all (see refresh()).
local function settle(messageKey, name)
  busy = false
  pending = nil
  if messageKey == nil or string.find(messageKey, "_failed", 1, true) == nil then
    errorMessage = nil
  end
  publish()
  if messageKey ~= nil then
    noctalia.notify(noctalia.tr(messageKey), name)
  end
  refresh()
end

-- Bring the profile up so the new addressing is live. A failure here is the
-- point of the confirm window: the caller reverts.
local function activate(uuid, next)
  busy = true
  publish()
  run({ "con", "up", uuid }, UP_TIMEOUT_MS, function(result)
    if result.exitCode ~= 0 or result.timedOut then
      noctalia.notifyError(noctalia.tr("notify.up_failed"), firstLine(result.stderr, result.stdout))
      return next(false)
    end
    next(true)
  end)
end

local function restoreRecord(record, reasonKey, next)
  local args = net.restoreArgs(record.uuid, record.fields)
  run(args, CMD_TIMEOUT_MS, function(result)
    if result.exitCode ~= 0 or result.timedOut then
      busy = false
      errorMessage = firstLine(result.stderr, result.stdout)
      publish()
      noctalia.notifyError(noctalia.tr("notify.revert_failed"), errorMessage)
      return next(false)
    end
    if record.was_active ~= true then
      return next(true)
    end
    activate(record.uuid, function(ok)
      next(ok)
    end)
  end)
end

local function revert(reasonKey)
  local record = lastRecord
  if pending == nil then
    return
  end
  pending = nil
  if record == nil then
    return settle("notify.revert_failed")
  end
  busy = true
  publish()
  noctalia.notify(noctalia.tr("notify.reverting"), record.name)
  restoreRecord(record, reasonKey, function(ok)
    -- A failed restore has already set the message and notified; settling with no
    -- message key keeps both, and still clears the busy flag.
    settle(ok and reasonKey or nil, record.name)
  end)
end

local function commit(uuid, desired, current)
  local connection = connectionByUuid(uuid)
  if connection == nil or profile == nil or uuid ~= selected then
    noctalia.notifyError(noctalia.tr("notify.stale"))
    refresh()
    return
  end
  local changes = net.diff(current, desired)
  if #changes == 0 then
    noctalia.notify(noctalia.tr("notify.no_changes"), label)
    return
  end

  local record = {
    uuid = uuid,
    name = connection.name,
    device = connection.device,
    was_active = connection.active == true,
    fields = current,
    at = os.time(),
    confirmed = false,
    -- Epoch rather than the monotonic clock, so the confirm window survives a
    -- shell restart: the service resumes the countdown when it loads.
    deadline_at = (connection.active == true and confirmSeconds > 0) and (os.time() + confirmSeconds) or nil,
  }

  -- Persisted *before* the write. A crash in between would otherwise leave a
  -- changed profile with no rollback point on disk, and nothing to recover from.
  if not writeBackup(record) then
    errorMessage = noctalia.tr("notify.backup_failed")
    publish()
    noctalia.notifyError(noctalia.tr("notify.backup_failed"))
    return
  end
  lastRecord = record

  busy = true
  errorMessage = nil
  publish()

  run(net.buildModArgs(uuid, desired, current), CMD_TIMEOUT_MS, function(result)
    if result.exitCode ~= 0 or result.timedOut then
      -- Nothing was written, so nothing is owed: retire the rollback point
      -- rather than leaving a window that would re-activate the connection.
      record.confirmed = true
      record.deadline_at = nil
      writeBackup(record)
      busy = false
      errorMessage = firstLine(result.stderr, result.stdout)
      publish()
      noctalia.notifyError(noctalia.tr("notify.mod_failed"), errorMessage)
      return
    end

    local function afterActivation(activated)
      if not activated then
        -- The profile went in but the link did not come up: undo immediately
        -- rather than leaving a half-applied connection behind.
        busy = true
        publish()
        restoreRecord(record, "notify.revert_failed", function()
          settle("notify.reverted_failed", record.name)
        end)
        return
      end
      if record.was_active and confirmSeconds > 0 then
        pending = {
          uuid = uuid,
          name = record.name,
          deadline_ms = noctalia.nowMs() + confirmSeconds * 1000,
        }
        busy = false
        publish()
        noctalia.notify(noctalia.tr("notify.confirm_title"), noctalia.tr("notify.confirm_body", {
          name = record.name,
          seconds = confirmSeconds,
        }))
        refresh()
        return
      end
      settle("notify.applied", record.name)
    end

    if record.was_active then
      activate(uuid, afterActivation)
    else
      afterActivation(true)
    end
  end)
end

local function apply(uuid, form)
  if busy or pending ~= nil then
    return
  end
  local desired, reasonKey, item = net.validateForm(form)
  if desired == nil then
    local message = noctalia.tr(reasonKey, { value = tostring(item or "") })
    errorMessage = message
    publish()
    noctalia.notifyError(noctalia.tr("notify.invalid"), message)
    return
  end
  commit(uuid, desired, profile or {})
end

local function keep()
  if pending == nil then
    return
  end
  local record = lastRecord
  if record ~= nil then
    record.confirmed = true
    writeBackup(record)
    lastRecord = record
  end
  pending = nil
  publish()
  noctalia.notify(noctalia.tr("notify.kept"), record ~= nil and record.name or nil)
end

-- The panel's "restore": puts the recorded profile back on the selected
-- connection, through the same window.
local function restoreFromBackup()
  local record = lastRecord
  if busy or pending ~= nil or record == nil or record.uuid ~= selected then
    return
  end
  local desired = net.validateForm(record.fields)
  if desired == nil then
    noctalia.notifyError(noctalia.tr("notify.invalid"), record.name)
    return
  end
  commit(record.uuid, desired, profile or {})
end

local function selectConnection(uuid)
  if uuid ~= selected then
    selected = uuid
    profile, live = nil, nil
    publish()
    refresh()
  end
end

local function setRadio(kind, on)
  if busy or pending ~= nil or (kind ~= "wifi" and kind ~= "wwan") then
    return
  end
  busy = true
  publish()
  run({ "radio", kind, on and "on" or "off" }, CMD_TIMEOUT_MS, function(result)
    busy = false
    if result.exitCode ~= 0 or result.timedOut then
      errorMessage = firstLine(result.stderr, result.stdout)
      publish()
      noctalia.notifyError(noctalia.tr("notify.radio_failed"), errorMessage)
      return
    end
    errorMessage = nil
    publish()
    refresh()
  end)
end

local function setConnectionState(uuid, up)
  if busy or pending ~= nil then
    return
  end
  busy = true
  publish()
  run({ "con", up and "up" or "down", uuid }, UP_TIMEOUT_MS, function(result)
    busy = false
    if result.exitCode ~= 0 or result.timedOut then
      errorMessage = firstLine(result.stderr, result.stdout)
      publish()
      noctalia.notifyError(noctalia.tr(up and "notify.up_failed" or "notify.down_failed"), errorMessage)
      return
    end
    errorMessage = nil
    publish()
    refresh()
  end)
end

-- Support path: dumps what the service currently believes to
-- <plugin data dir>/state.json and a one-line summary to the shell log. Used when
-- a panel shows something that does not match nmcli:
--   noctalia msg plugin muhammadessam/network-control:service all request '{"action":"diagnose"}'
local function diagnose()
  local connection = connectionByUuid(selected)
  local dump = {
    at = os.time(),
    available = available,
    permission_ok = permissionOk(),
    permission_known = permissions ~= nil,
    permissions = permissions,
    error = errorMessage,
    selected = selected,
    selected_name = connection ~= nil and connection.name or nil,
    connections = connections,
    devices = deviceStatus,
    networks = networks,
    scanning = scanning,
    saved_ssids = savedSsids,
    scanned_age_ms = lastScanAgeMs(),
    profile = profile,
    live = live,
    primary = primary,
    radio = radios,
    pending = pending,
    backup = lastRecord,
    -- A dump without these two cannot answer "is it still working?", which is the
    -- first question anyone reading one has.
    busy = busy,
    scanning = scanning,
    -- Age, not timestamp: noctalia.nowMs() is monotonic, so a raw value in a dump
    -- is meaningless next to os.time().
    refreshed_age_ms = noctalia.nowMs() - lastRefreshMs,
    confirm_seconds = confirmSeconds,
    refresh_seconds = refreshSeconds,
  }
  local path = dataFile("state.json")
  if path ~= nil then
    local encoded = noctalia.json.encode(dump, true)
    if encoded ~= nil then
      noctalia.writeFile(path, encoded)
    end
  end
  noctalia.log("[network-control] diagnose: "
    .. tostring(#connections) .. " connections, selected="
    .. tostring(connection ~= nil and connection.name or "none")
    .. ", profile=" .. (profile ~= nil and net.summarize(profile) or "none")
    .. ", live=" .. tostring(live ~= nil and #live.ipv4_addresses or 0) .. " ipv4"
    .. ", pending=" .. tostring(pending ~= nil and pending.name or "none")
    .. ", error=" .. tostring(errorMessage or "none")
    .. (path ~= nil and (" -> " .. path) or ""))
end

-- Join a network from the scan list.
--
-- Three routes, chosen by what is actually known:
--   * a saved profile joins with `con up` - NetworkManager already holds the secret
--   * an open network joins with `dev wifi connect` - no secret exists to place
--   * anything else gets an explicit profile, then `con up --passwd-file`, so the
--     passphrase never sits in a process command line (world-readable in /proc)
--     the way `dev wifi connect <ssid> password <psk>` would leave it
--
-- No confirm window here: the window guards edits to the addressing of a
-- connection already carrying traffic. A failed join leaves the previous profile
-- intact and selectable, so there is nothing to roll back to.
-- Creates the passphrase file 0600 *before* the secret is written into it.
-- `noctalia.writeFile` keeps the mode of an existing file (verified on this
-- shell), so an empty file created by `install -m 600` stays private while the
-- secret goes in. Calls onReady(path) or onReady(nil) - and onReady(nil) means
-- "refuse", never "carry on without it".
local function withSecretFile(password, onReady)
  local path = dataFile("secret.tmp")
  if path == nil then
    return onReady(nil)
  end
  -- runTool, not run: `run` prepends nmcli, so run({ "install", ... }) would run
  -- `nmcli install` and leave the real file uncreated and the secret unprotected.
  runTool({ "install", "-m", "600", "/dev/null", path }, CMD_TIMEOUT_MS, function(created)
    if created.exitCode ~= 0 or created.timedOut then
      noctalia.removeFile(path)
      return onReady(nil)
    end
    if not noctalia.writeFile(path, net.passwdFileContents(password)) then
      noctalia.removeFile(path)
      return onReady(nil)
    end
    onReady(path)
  end)
end

-- Brings a profile up with a passphrase that is never part of a command line:
-- `nmcli con up <uuid> passwd-file <path>` reads it from a 0600 file that exists
-- only for the duration of the activation. Without a passphrase the plain
-- `con up` is used, which is how a saved profile joins.
local function activateWithSecret(uuid, password, onResult)
  if password == nil or password == "" then
    return run({ "con", "up", uuid }, UP_TIMEOUT_MS, onResult)
  end
  withSecretFile(password, function(path)
    if path == nil then
      -- Fail closed. Activating without the passphrase the user supplied would
      -- silently reuse an older stored secret on an existing profile and report
      -- success - worse than refusing.
      return onResult({ exitCode = 1, stdout = "", stderr = noctalia.tr("error.secret_file"), timedOut = false })
    end
    run({ "con", "up", uuid, "passwd-file", path }, UP_TIMEOUT_MS, function(result)
      noctalia.removeFile(path)
      onResult(result)
    end)
  end)
end

local function failWifi(messageKey)
  errorMessage = noctalia.tr(messageKey)
  publish()
  noctalia.notifyError(noctalia.tr("notify.wifi_failed"), errorMessage)
end

local function finishWifi(result, name, conName)
  busy = false
  if result.exitCode == 0 and not result.timedOut then
    selected = savedSsids[name] or nil
    errorMessage = nil
    noctalia.notify(noctalia.tr("notify.wifi_connected"), name)
  else
    errorMessage = namedError(name, result)
    noctalia.notifyError(noctalia.tr("notify.wifi_failed"), errorMessage)
  end
  publish()
  -- 1.5 s so the panel can show the outcome before the list is rebuilt from the
  -- (possibly still stale) inventory.
  local timer = noctalia.setTimeout(function()
    timer = nil
    refresh()
  end, 1500)
  timers[#timers + 1] = timer
end

-- nmcli names a Wi-Fi profile after the SSID, which is what the scan's "saved"
-- marking matches on. If that name is taken by a profile this join did not create,
-- a suffixed name keeps the join from writing over somebody else's connection.
local function uniqueConnectionName(ssid)
  local taken = {}
  for _, connection in ipairs(connections) do
    taken[connection.name] = true
  end
  if taken[ssid] ~= true then
    return ssid
  end
  for index = 2, 99 do
    local candidate = ssid .. " " .. tostring(index)
    if taken[candidate] ~= true then
      return candidate
    end
  end
  return ssid .. " " .. tostring(os.time())
end

-- The uuid of the profile just created, read back by name: `con add` prints the
-- path it wrote, not the uuid, in the versions that matter here.
local function createdUuid(conName, next)
  run({ "-t", "-f", "connection.uuid", "con", "show", conName }, CMD_TIMEOUT_MS, function(result)
    if result.exitCode ~= 0 or result.timedOut then
      return next(nil)
    end
    next(net.get(net.parseFields(result.stdout), "connection.uuid"))
  end)
end

local function deleteOwnProfile(uuid, next)
  run({ "con", "delete", uuid }, CMD_TIMEOUT_MS, function(result)
    next(result.exitCode == 0 and not result.timedOut, firstLine(result.stderr, result.stdout))
  end)
end

local function wifiConnect(ssid, password, hidden)
  -- A join changes the active link, so it must not run while a rollback window is
  -- still deciding what that link should be.
  if busy or scanning or pending ~= nil then
    return
  end
  -- The SSID is bytes, not text: leading and trailing spaces are legal and a
  -- trimmed copy would name a different network. Only an all-space manual entry
  -- is rejected.
  if type(ssid) ~= "string" or net.trim(ssid) == "" then
    return failWifi("error.ssid")
  end
  local name = ssid
  if radios.wifi == "disabled" then
    return failWifi("wifi.radio_off")
  end

  -- Same reasoning for the passphrase: spaces inside it are significant, so it is
  -- never trimmed - only an empty one counts as "not given".
  local secret = type(password) == "string" and password or ""
  local saved = savedSsids[name]
  local network = networkBySsid(name)

  if saved ~= nil and secret == "" then
    -- Known network: NetworkManager already holds the secret.
    setConnectionState(saved, true)
    return
  end
  if network ~= nil and net.isEnterprise(network.security) then
    return failWifi("wifi.enterprise")
  end
  if network ~= nil and net.isWep(network.security) then
    return failWifi("wifi.wep")
  end
  if secret == "" and network ~= nil and net.needsPassword(network.security) then
    return failWifi("wifi.needs_password")
  end

  busy = true
  errorMessage = nil
  publish()

  if secret == "" then
    -- Open network and nothing secret involved: nmcli builds the profile itself.
    -- It creates one as part of the join, so a failure has to clean up after it -
    -- but only when this attempt was the one that created it.
    run(net.wifiConnectArgs(name, hidden), UP_TIMEOUT_MS, function(result)
      if result.exitCode == 0 and not result.timedOut then
        return finishWifi(result, name, name)
      end
      if saved == nil then
        run({ "-t", "-f", "connection.uuid", "con", "show", name }, CMD_TIMEOUT_MS, function(shown)
          local created = shown.exitCode == 0 and net.get(net.parseFields(shown.stdout), "connection.uuid") or nil
          if created == nil then
            return finishWifi(result, name, name)
          end
          deleteOwnProfile(created, function()
            finishWifi(result, name, name)
          end)
        end)
        return
      end
      finishWifi(result, name, name)
    end)
    return
  end

  if saved ~= nil then
    -- Saved, but a passphrase came along again (a replaced one): keep the
    -- existing profile and its name.
    local connection = connectionByUuid(saved)
    activateWithSecret(saved, secret, function(result)
      finishWifi(result, name, connection ~= nil and connection.name or name)
    end)
    return
  end

  local security = network ~= nil and network.security or ""
  -- A passphrase implies WPA: an unknown or stale scan row still gets a PSK
  -- profile rather than an open one.
  local keyMgmt = net.keyMgmtFor(security) or "wpa-psk"
  local conName = uniqueConnectionName(name)
  run(net.wifiProfileArgs(conName, name, keyMgmt, hidden), CMD_TIMEOUT_MS, function(created)
    if created.exitCode ~= 0 or created.timedOut then
      busy = false
      errorMessage = namedError(name, created)
      publish()
      noctalia.notifyError(noctalia.tr("notify.wifi_failed"), errorMessage)
      return
    end
    createdUuid(conName, function(uuid)
      if uuid == nil then
        -- `con add` succeeded and the lookup did not: the profile exists, so it
        -- has to go, or the SSID would look saved without a usable secret.
        run({ "con", "delete", conName }, CMD_TIMEOUT_MS, function()
          busy = false
          errorMessage = noctalia.tr("notify.wifi_failed")
          publish()
          noctalia.notifyError(noctalia.tr("notify.wifi_failed"), conName)
        end)
        return
      end
      activateWithSecret(uuid, secret, function(result)
        if result.exitCode ~= 0 or result.timedOut then
          -- Created by this very attempt and never carried traffic. Leaving it
          -- behind would make the panel treat the SSID as saved and offer a
          -- one-click join that cannot work without the passphrase.
          deleteOwnProfile(uuid, function(removed, why)
            if not removed then
              -- Say so rather than claiming a clean failure: the profile is still
              -- there and the next scan will call the network saved.
              noctalia.notifyError(noctalia.tr("notify.cleanup_failed"), why)
            end
            finishWifi(result, name, conName)
          end)
          return
        end
        finishWifi(result, name, conName)
      end)
    end)
  end)
end

-- ── requests ─────────────────────────────────────────────────────────────────

local function handleRequest(value)
  if type(value) ~= "table" or not available then
    return
  end
  local action = value.action
  if action == "refresh" then
    permissions = nil
    refresh()
  elseif action == "diagnose" then
    diagnose()
  elseif action == "select" and type(value.uuid) == "string" then
    selectConnection(value.uuid)
  elseif action == "apply" and type(value.uuid) == "string" and type(value.form) == "table" then
    apply(value.uuid, value.form)
  elseif action == "keep" then
    keep()
  elseif action == "revert" then
    revert("notify.reverted")
  elseif action == "restore" then
    restoreFromBackup()
  elseif action == "scan" then
    scan(value.rescan == true)
  elseif action == "wifi-connect" and type(value.ssid) == "string" then
    wifiConnect(value.ssid, value.password, value.hidden == true)
  elseif action == "radio" then
    setRadio(value.kind, value.on == true)
  elseif action == "up" and type(value.uuid) == "string" then
    setConnectionState(value.uuid, true)
  elseif action == "down" and type(value.uuid) == "string" then
    setConnectionState(value.uuid, false)
  end
end

noctalia.state.watch("network.request", handleRequest)

-- CLI surface, mirroring the state channel so every action is testable without
-- the panel:
--   noctalia msg plugin muhammadessam/network-control:service all request '<json>'
function onIpc(event, payload)
  if event ~= "request" or type(payload) ~= "string" then
    return
  end
  local value = noctalia.json.decode(payload)
  if type(value) == "table" then
    handleRequest(value)
  end
end

function onConfigChanged()
  confirmSeconds = numberSetting("confirm_seconds", 45, 0, 600)
  refreshSeconds = numberSetting("refresh_seconds", 15, 5, 600)
  publish()
end

-- Two jobs on one tick: the confirm countdown (a revert needs whole seconds, and
-- state.watch does not replay to a late-attaching panel), and the periodic
-- re-read for live addresses.
function update()
  local nowMs = noctalia.nowMs()
  if busy and not busyWasSet then
    busyWasSet, busySinceMs = true, nowMs
  elseif not busy then
    busyWasSet = false
  elseif nowMs - busySinceMs > BUSY_LIMIT_MS then
    -- The operation this flag belonged to is gone. Clearing it is the honest
    -- reading: whatever it was doing either finished without reporting or never
    -- ran, and either way the panel must be usable again.
    busy, busyWasSet = false, false
    errorMessage = noctalia.tr("error.stuck")
    publish()
    noctalia.notifyError(noctalia.tr("notify.stuck"), errorMessage)
  end
  if pending ~= nil and nowMs >= pending.deadline_ms then
    revert("notify.reverted_timeout")
    return
  end
  if not busy and nowMs - lastRefreshMs >= refreshSeconds * 1000 then
    refresh()
  end
end

noctalia.setUpdateInterval(TICK_MS)

-- A passphrase file left behind by a shell that died mid-join is a plaintext
-- credential sitting in the data directory: remove it before anything else runs.
local staleSecret = dataFile("secret.tmp")
if staleSecret ~= nil and noctalia.fileExists(staleSecret) then
  noctalia.removeFile(staleSecret)
end

-- An unconfirmed backup means the shell went away inside a confirm window. The
-- window is *resumed* rather than dropped - the documented promise is that an
-- unkept change rolls back - and a deadline that already passed reverts on the
-- first tick, because update() fires as soon as now >= deadline.
lastRecord = readBackup()
if lastRecord ~= nil and lastRecord.confirmed ~= true and lastRecord.deadline_at ~= nil and confirmSeconds > 0 then
  local remaining = lastRecord.deadline_at - os.time()
  pending = {
    uuid = lastRecord.uuid,
    name = lastRecord.name,
    deadline_ms = noctalia.nowMs() + (remaining > 0 and remaining * 1000 or 0),
  }
  noctalia.notify(noctalia.tr("notify.resumed"), lastRecord.name)
end
publish()
refresh()
