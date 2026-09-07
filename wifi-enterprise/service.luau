--!nonstrict
-- WiFi Enterprise service: owns every nmcli call. Creates, edits, deletes and
-- connects 802.1X Wi-Fi profiles. Panel and shortcut only read published state
-- and send commands through noctalia.state.set("eapwifi.cmd", ...).
--
-- This plugin is a stopgap for a real gap in Noctalia's own Wi-Fi widget: it
-- only ever builds wifi-sec.key-mgmt of wpa-psk/sae, so 802.1X networks
-- (eduroam, corporate WPA2/WPA3-Enterprise) cannot be configured from it.
-- Tracked upstream: https://github.com/noctalia-dev/noctalia/issues/3216
-- Once a profile exists (created here, or with nmtui/nm-connection-editor),
-- Noctalia's own Wi-Fi list already activates it correctly - this plugin's
-- only job is creation/editing, not day-to-day connecting.

noctalia.setUpdateInterval(1000)

-- ── small helpers ────────────────────────────────────────────────────────

local function log(msg)
  noctalia.log(`wifi-enterprise: {msg}`)
end

local function trim(s)
  return noctalia.string.trim(s or "")
end

local function firstLine(s)
  s = trim(s)
  local nl = s:find("\n")
  if nl ~= nil then
    return s:sub(1, nl - 1)
  end
  return s
end

local function cfgBool(key, default)
  local v = noctalia.getConfig(key)
  if type(v) == "boolean" then
    return v
  end
  return default
end

local function run(argv, onDone, timeoutMs)
  local accepted = noctalia.runAsync(argv, onDone, timeoutMs or 15000)
  if not accepted then
    log("failed to start: " .. table.concat(argv, " "))
    if onDone ~= nil then
      onDone({ exitCode = -1, stdout = "", stderr = "failed to start process", timedOut = false })
    end
  end
end

-- Sequentially maps items through an async fn(item, done), then calls onDone(results).
local function mapAsync(items, fn, onDone)
  local results = {}
  local i = 0
  local function step()
    i += 1
    if i > #items then
      onDone(results)
      return
    end
    fn(items[i], function(result)
      results[i] = result
      step()
    end)
  end
  step()
end

-- NetworkManager UUIDs are hex and dashes. Validated before a UUID is ever
-- used, even though every command here builds an argv list rather than a
-- shell string.
local function isUuid(value)
  return type(value) == "string" and value:match("^[0-9a-fA-F%-]+$") ~= nil and #value >= 8
end

-- ── live state ───────────────────────────────────────────────────────────

local lastProfileRows = {}
local lastScanRows = {}
local refreshInFlight = false
local opInFlight = {} -- uuid -> true while a connect/delete/save is running

local function publishProfiles()
  local rows = {}
  for _, row in ipairs(lastProfileRows) do
    table.insert(rows, {
      uuid = row.uuid,
      name = row.name,
      ssid = row.ssid,
      eap = row.eap,
      phase2 = row.phase2,
      active = row.active,
      busy = opInFlight[row.uuid] == true,
    })
  end
  table.sort(rows, function(a, b)
    return a.name:lower() < b.name:lower()
  end)
  noctalia.state.set("eapwifi.profiles", rows)
end

local function publishScan()
  noctalia.state.set("eapwifi.scanResults", lastScanRows)
end

local function reportError(message)
  noctalia.state.set("eapwifi.lastError", { message = message, at = os.time() })
  noctalia.notifyError(noctalia.tr("title"), message)
end

-- ── scan for nearby enterprise networks ─────────────────────────────────

local function scanWifi()
  run({ "nmcli", "-t", "-f", "SSID,SECURITY,IN-USE", "--escape", "no", "dev", "wifi", "list", "--rescan", "yes" }, function(result)
    if result.exitCode ~= 0 then
      log("wifi list failed: " .. firstLine(result.stderr))
      return
    end
    local seen = {}
    local rows = {}
    for line in result.stdout:gmatch("[^\n]+") do
      local ssid, security, inUse = line:match("^(.*):([^:]*):([^:]*)$")
      if ssid ~= nil and ssid ~= "" and security ~= nil and security:find("802%.1[Xx]") ~= nil and seen[ssid] == nil then
        seen[ssid] = true
        table.insert(rows, { ssid = ssid, inUse = trim(inUse) == "*" })
      end
    end
    table.sort(rows, function(a, b)
      return a.ssid:lower() < b.ssid:lower()
    end)
    lastScanRows = rows
    publishScan()
  end, 20000)
end

-- ── list existing 802.1X profiles ───────────────────────────────────────

-- 802-11-wireless-security.key-mgmt and the other per-connection fields below
-- are only valid in single-connection detail mode ("connection show <id>"),
-- not in the list mode used to enumerate all connections - so key-mgmt is
-- fetched here too, and a row is kept only once it comes back "wpa-eap".
local function enrichRow(row, done)
  run({ "nmcli", "-g", "802-11-wireless-security.key-mgmt", "connection", "show", row.uuid }, function(r0)
    if trim(r0.stdout) ~= "wpa-eap" then
      done(nil)
      return
    end
    run({ "nmcli", "-g", "802-11-wireless.ssid", "connection", "show", row.uuid }, function(r1)
      row.ssid = trim(r1.stdout)
      run({ "nmcli", "-g", "802-1x.eap", "connection", "show", row.uuid }, function(r2)
        row.eap = trim(r2.stdout):gsub(",.*$", "") -- nmcli may report a list; first entry is the active one
        run({ "nmcli", "-g", "802-1x.phase2-auth", "connection", "show", row.uuid }, function(r3)
          row.phase2 = trim(r3.stdout)
          done(row)
        end)
      end)
    end)
  end)
end

local function refreshAll()
  if refreshInFlight then
    return
  end
  refreshInFlight = true

  run({ "nmcli", "-t", "-f", "NAME,UUID,TYPE,ACTIVE", "--escape", "no", "connection", "show" }, function(result)
    if result.exitCode ~= 0 then
      log("connection show failed: " .. firstLine(result.stderr))
      refreshInFlight = false
      return
    end

    local candidates = {}
    for line in result.stdout:gmatch("[^\n]+") do
      local name, uuid, ctype, active = line:match("^(.*):([^:]*):([^:]*):([^:]*)$")
      if uuid ~= nil and uuid ~= "" and ctype == "802-11-wireless" then
        table.insert(candidates, { name = name, uuid = uuid, active = active == "yes" })
      end
    end

    mapAsync(candidates, enrichRow, function(rows)
      local kept = {}
      for _, row in ipairs(rows) do
        if row ~= nil then
          table.insert(kept, row)
        end
      end
      lastProfileRows = kept
      publishProfiles()
      refreshInFlight = false
    end)
  end)

  scanWifi()
end

-- ── create / update / delete / connect ──────────────────────────────────

-- Builds the shared 802-1x.* argv tail from a form-fields table. `password`
-- is included only when non-empty, so editing without retyping the password
-- never clears it on the connection.
local function eapArgs(fields)
  local args = {
    "wifi-sec.key-mgmt", "wpa-eap",
    "802-1x.eap", fields.eap,
    "802-1x.phase2-auth", fields.phase2,
    "802-1x.identity", fields.identity,
  }
  if fields.anonymousIdentity ~= nil and fields.anonymousIdentity ~= "" then
    table.insert(args, "802-1x.anonymous-identity")
    table.insert(args, fields.anonymousIdentity)
  end
  if fields.password ~= nil and fields.password ~= "" then
    table.insert(args, "802-1x.password")
    table.insert(args, fields.password)
  end
  if fields.useSystemCa == true then
    table.insert(args, "802-1x.system-ca-certs")
    table.insert(args, "yes")
  elseif fields.caCertPath ~= nil and fields.caCertPath ~= "" then
    table.insert(args, "802-1x.ca-cert")
    table.insert(args, "file://" .. fields.caCertPath)
  end
  if fields.domainSuffixMatch ~= nil and fields.domainSuffixMatch ~= "" then
    table.insert(args, "802-1x.domain-suffix-match")
    table.insert(args, fields.domainSuffixMatch)
  end
  return args
end

local function connectUuid(uuid)
  if not isUuid(uuid) or opInFlight[uuid] then
    return
  end
  opInFlight[uuid] = true
  publishProfiles()
  run({ "nmcli", "connection", "up", "uuid", uuid }, function(result)
    opInFlight[uuid] = nil
    if result.exitCode ~= 0 then
      reportError(noctalia.tr("notifications.connect_failed", { reason = firstLine(result.stderr) }))
    end
    refreshAll()
  end, 25000)
end

local function createProfile(fields)
  local ssid = trim(fields.ssid)
  if ssid == "" then
    reportError(noctalia.tr("notifications.no_ssid"))
    return
  end
  if trim(fields.identity) == "" then
    reportError(noctalia.tr("notifications.no_identity"))
    return
  end

  local argv = { "nmcli", "connection", "add", "type", "wifi", "con-name", ssid, "ifname", "*", "ssid", ssid }
  for _, a in ipairs(eapArgs(fields)) do
    table.insert(argv, a)
  end

  run(argv, function(result)
    if result.exitCode ~= 0 then
      reportError(noctalia.tr("notifications.create_failed", { reason = firstLine(result.stderr) }))
      refreshAll()
      return
    end
    noctalia.notify(noctalia.tr("title"), noctalia.tr("notifications.created", { ssid = ssid }))
    local newUuid = result.stdout:match("%(([%w%-]+)%)")
    if newUuid ~= nil and cfgBool("auto_connect_after_create", true) then
      connectUuid(newUuid)
    else
      refreshAll()
    end
  end, 20000)
end

local function updateProfile(uuid, fields)
  if not isUuid(uuid) then
    return
  end
  local argv = { "nmcli", "connection", "modify", "uuid", uuid }
  for _, a in ipairs(eapArgs(fields)) do
    table.insert(argv, a)
  end
  run(argv, function(result)
    if result.exitCode ~= 0 then
      reportError(noctalia.tr("notifications.update_failed", { reason = firstLine(result.stderr) }))
    else
      noctalia.notify(noctalia.tr("title"), noctalia.tr("notifications.updated"))
    end
    refreshAll()
  end, 20000)
end

local function deleteUuid(uuid)
  if not isUuid(uuid) then
    return
  end
  run({ "nmcli", "connection", "delete", "uuid", uuid }, function(result)
    if result.exitCode ~= 0 then
      reportError(noctalia.tr("notifications.delete_failed", { reason = firstLine(result.stderr) }))
    end
    refreshAll()
  end)
end

-- ── CA certificate file picker ───────────────────────────────────────────
-- A GUI picker outlives the runAsync call that spawns it, so it is launched
-- detached and its output is polled from a temp file, the same pattern the
-- sibling vpn-manager plugin uses for its config picker. Opening it closes
-- the panel (a layer-shell surface can't coexist with a focused picker
-- window), so the chosen path is handed back through state and the panel
-- restores its in-progress form from eapwifi.formDraft on reopen.

local pendingPick = nil -- { path = <tmp file>, started = <epoch seconds> }

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function startCaCertPicker()
  if pendingPick ~= nil then
    reportError(noctalia.tr("notifications.pick_in_progress"))
    return
  end

  local picker, pickerBinary, pickerNeedle
  if noctalia.commandExists("kdialog") then
    picker = "kdialog --getopenfilename ~ '*.pem *.crt *.cer|CA certificates'"
    pickerBinary, pickerNeedle = "kdialog", "--getopenfilename"
  elseif noctalia.commandExists("zenity") then
    picker = "zenity --file-selection --title='Select a CA certificate'"
    pickerBinary, pickerNeedle = "zenity", "--file-selection"
  else
    reportError(noctalia.tr("notifications.no_picker"))
    return
  end

  local dir = noctalia.pluginDataDir()
  if dir == nil then
    reportError(noctalia.tr("notifications.no_data_dir"))
    return
  end

  local tmp = `{dir}/pick.tmp`
  noctalia.removeFile(tmp)
  pendingPick = { path = tmp, started = os.time(), binary = pickerBinary, needle = pickerNeedle, checking = false }
  noctalia.state.set("eapwifi.picking", true)
  noctalia.runAsync(`{picker} > {shellQuote(tmp)} 2>/dev/null &`)
end

local function clearPick()
  if pendingPick ~= nil then
    noctalia.removeFile(pendingPick.path)
    pendingPick = nil
  end
  noctalia.state.set("eapwifi.picking", false)
end

local function pollFilePicker()
  if pendingPick == nil then
    return
  end

  local raw = noctalia.readFile(pendingPick.path)
  if raw ~= nil and trim(raw) ~= "" then
    local path = trim(raw)
    clearPick()
    noctalia.state.set("eapwifi.pickedCaCert", { path = path, at = os.time() })
    return
  end

  -- Cancelling writes nothing, so waiting for output alone would leave the
  -- picker "in progress" until the timeout. Watch for the process going away
  -- instead, and treat that as a cancel.
  if not pendingPick.checking and os.time() - pendingPick.started >= 2 then
    pendingPick.checking = true
    local binary, needle = pendingPick.binary, pendingPick.needle
    noctalia.processMatches(function(stillRunning)
      if pendingPick ~= nil then
        if stillRunning then
          pendingPick.checking = false
        else
          clearPick()
        end
      end
    end, binary, needle)
  end

  if os.time() - pendingPick.started > 120 then
    clearPick()
  end
end

-- ── commands from panel / shortcut ──────────────────────────────────────

local function handleCommand(cmd)
  if type(cmd) ~= "table" then
    return
  end
  local op = cmd.op
  if op == "create" then
    createProfile(cmd.fields or {})
  elseif op == "update" then
    updateProfile(cmd.uuid, cmd.fields or {})
  elseif op == "delete" then
    deleteUuid(cmd.uuid)
  elseif op == "connect" then
    connectUuid(cmd.uuid)
  elseif op == "pickCaCert" then
    startCaCertPicker()
  elseif op == "refresh" then
    refreshAll()
  end
end

noctalia.state.watch("eapwifi.cmd", function(cmd)
  if cmd ~= nil then
    handleCommand(cmd)
    noctalia.state.set("eapwifi.cmd", nil)
  end
end)

function onIpc(event, payload)
  if event == "refresh" then
    refreshAll()
  elseif event == "connect" then
    connectUuid(payload)
  elseif event == "list" then
    for _, row in ipairs(lastProfileRows) do
      log(`profile name={row.name} ssid={row.ssid} eap={row.eap} phase2={row.phase2} uuid={row.uuid} active={tostring(row.active)}`)
    end
  end
end

function onEnable()
  refreshAll()
end

function update()
  pollFilePicker()
end

noctalia.state.set("eapwifi.profiles", {})
noctalia.state.set("eapwifi.scanResults", {})
noctalia.state.set("eapwifi.lastError", { message = "", at = 0 })
noctalia.state.set("eapwifi.picking", false)
noctalia.state.set("eapwifi.pickedCaCert", { path = "", at = 0 })
refreshAll()
