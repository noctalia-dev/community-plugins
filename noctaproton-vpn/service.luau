--!nonstrict
-- Proton VPN Background Service for Noctalia Shell
-- Manages protonvpn CLI execution, NetworkManager link tracking, NAT-PMP port forwarding,
-- live throughput sampling, split-tunneling configuration, and published state.

noctalia.setUpdateInterval(1000)

local refreshIntervalSec = tonumber(noctalia.getConfig("refresh_interval")) or 5
if refreshIntervalSec < 2 then refreshIntervalSec = 2 end

local STATE_KEY = "protonvpn.status"
local COMMAND_KEY = "protonvpn.cmd"

local PLUGIN_DIR = (function()
  local dir = noctalia.pluginDir and noctalia.pluginDir()
  if dir and dir ~= "" then return dir end
  return noctalia.expandPath("~/.config/noctalia/plugins/noctaproton-vpn")
end)()
local PROTON_SETTINGS_PATH = noctalia.expandPath("~/.config/Proton/VPN/settings.json")

-- Snapshot representing current VPN state
local snapshot = {
  available = true,
  installed = true,
  connected = false,
  connecting = false,
  busy = false,
  server = "",
  country = "",
  city = "",
  ip = "",
  protocol = "WireGuard",
  device = "",
  signedIn = false,
  account = {
    username = "",
    plan = "",
  },
  config = {
    killSwitch = "off",     -- "off" | "standard"
    netshield = "off",      -- "off" | "malware-only" | "malware-ads-trackers"
    portForwarding = "off", -- "off" | "on"
  },
  forwardedPort = nil,
  traffic = {
    rxRate = 0,
    txRate = 0,
    sessionRx = 0,
    sessionTx = 0,
    uptimeSec = 0,
  },
  splitTunneling = {
    available = false,
    enabled = false,
    apps = {},
    candidates = {},
  },
  countries = {},
  lastError = "",
  statusText = "Disconnected",
  updatedAt = 0,
}

-- Default country list fallback
local DEFAULT_COUNTRIES = {
  { code = "US", name = "United States", count = 120, load = 42 },
  { code = "NL", name = "Netherlands", count = 85, load = 38 },
  { code = "JP", name = "Japan", count = 45, load = 51 },
  { code = "DE", name = "Germany", count = 70, load = 35 },
  { code = "GB", name = "United Kingdom", count = 65, load = 44 },
  { code = "CH", name = "Switzerland", count = 50, load = 28 },
  { code = "CA", name = "Canada", count = 48, load = 39 },
  { code = "FR", name = "France", count = 40, load = 41 },
  { code = "SE", name = "Sweden", count = 30, load = 32 },
  { code = "AU", name = "Australia", count = 35, load = 49 },
  { code = "SG", name = "Singapore", count = 28, load = 46 },
  { code = "IS", name = "Iceland", count = 15, load = 25 },
}

local lastRxBytes = -1
local lastTxBytes = -1
local lastSampleMs = 0
local connectStartMs = 0

local pollCounter = 0
local portPollCounter = 0
local isPolling = false

local function publishState()
  snapshot.updatedAt = os.time()
  noctalia.state.set(STATE_KEY, snapshot)
end

local function parseJsonSafe(raw)
  if not raw or raw == "" then return nil end
  local ok, data = pcall(function()
    return noctalia.json.decode(raw)
  end)
  if ok and type(data) == "table" then
    return data
  end
  return nil
end

local function encodeJsonSafe(data)
  local ok, str = pcall(function()
    return noctalia.json.encode(data)
  end)
  if ok and str then
    return str
  end
  return nil
end

-- ── Split Tunneling Helpers ───────────────────────────────────────────────

local function loadSplitTunneling()
  local content = noctalia.readFile(PROTON_SETTINGS_PATH)
  if not content then
    snapshot.splitTunneling.available = false
    return
  end
  local parsed = parseJsonSafe(content)
  if parsed and type(parsed.features) == "table" then
    snapshot.splitTunneling.available = true
    local st = parsed.features.split_tunneling or {}
    snapshot.splitTunneling.enabled = (st.enabled == true)
    local appList = {}
    if type(st.apps) == "table" then
      for _, appPath in ipairs(st.apps) do
        table.insert(appList, tostring(appPath))
      end
    end
    snapshot.splitTunneling.apps = appList
  end
end

local function saveSplitTunneling(enabled, apps)
  local content = noctalia.readFile(PROTON_SETTINGS_PATH)
  if not content then return end
  local parsed = parseJsonSafe(content)
  if not parsed or type(parsed.features) ~= "table" then return end
  if type(parsed.features.split_tunneling) ~= "table" then
    parsed.features.split_tunneling = {}
  end
  parsed.features.split_tunneling.enabled = (enabled == true)
  parsed.features.split_tunneling.apps = apps or {}
  local encoded = encodeJsonSafe(parsed)
  if encoded then
    noctalia.writeFile(PROTON_SETTINGS_PATH, encoded)
    loadSplitTunneling()
    publishState()
  end
end

-- Load candidate apps from apps.py
local function loadCandidateApps()
  local script = `{PLUGIN_DIR}/apps.py`
  noctalia.runAsync(`python3 '{script}'`, function(result)
    if result.exitCode == 0 and result.stdout and result.stdout ~= "" then
      local candidates = parseJsonSafe(result.stdout)
      if type(candidates) == "table" then
        snapshot.splitTunneling.candidates = candidates
        publishState()
      end
    end
  end, 10000)
end

-- ── Servers and Countries Cache ───────────────────────────────────────────

local function loadServersAndCities()
  local script = `{PLUGIN_DIR}/servers.py`
  noctalia.runAsync(`python3 '{script}' --cities`, function(result)
    if result.exitCode == 0 and result.stdout and result.stdout ~= "" then
      local cities = parseJsonSafe(result.stdout)
      if type(cities) == "table" and #cities > 0 then
        -- Aggregate by country
        local countriesMap = {}
        for _, item in ipairs(cities) do
          local cc = tostring(item.code or ""):upper()
          if cc ~= "" then
            if not countriesMap[cc] then
              countriesMap[cc] = {
                code = cc,
                name = item.country or cc,
                count = 0,
                load = item.load or 50,
                cities = {},
              }
            end
            countriesMap[cc].count += 1
            table.insert(countriesMap[cc].cities, item.city)
          end
        end
        local list = {}
        for _, c in pairs(countriesMap) do
          table.insert(list, c)
        end
        table.sort(list, function(a, b) return a.count > b.count end)
        snapshot.countries = list
        publishState()
        return
      end
    end
    -- Fallback to default country list
    if #snapshot.countries == 0 then
      snapshot.countries = DEFAULT_COUNTRIES
      publishState()
    end
  end, 10000)
end

-- ── NAT-PMP Port Forwarding Renewal ───────────────────────────────────────

local function renewPortForwarding()
  if not snapshot.connected or snapshot.config.portForwarding ~= "on" then
    snapshot.forwardedPort = nil
    return
  end
  local script = `{PLUGIN_DIR}/port.py`
  noctalia.runAsync(`python3 '{script}'`, function(result)
    if result.exitCode == 0 and result.stdout and result.stdout ~= "" then
      local data = parseJsonSafe(result.stdout)
      if type(data) == "table" and data.port then
        snapshot.forwardedPort = tonumber(data.port)
        publishState()
      end
    end
  end, 6000)
end

-- ── Throughput Traffic Sampling ───────────────────────────────────────────

local function sampleTraffic()
  if not snapshot.connected then
    snapshot.traffic.rxRate = 0
    snapshot.traffic.txRate = 0
    return
  end
  local dev = snapshot.device ~= "" and snapshot.device or "proton0"
  local rxPath = `/sys/class/net/{dev}/statistics/rx_bytes`
  local txPath = `/sys/class/net/{dev}/statistics/tx_bytes`

  local rxRaw = noctalia.readFile(rxPath)
  local txRaw = noctalia.readFile(txPath)
  if not rxRaw or not txRaw then return end

  local rx = tonumber(noctalia.string.trim(rxRaw)) or 0
  local tx = tonumber(noctalia.string.trim(txRaw)) or 0
  local now = os.time() * 1000

  if lastRxBytes >= 0 and lastSampleMs > 0 then
    local dt = math.max(0.5, (now - lastSampleMs) / 1000)
    local drx = math.max(0, rx - lastRxBytes)
    local dtx = math.max(0, tx - lastTxBytes)
    snapshot.traffic.rxRate = math.floor(drx / dt)
    snapshot.traffic.txRate = math.floor(dtx / dt)
    snapshot.traffic.sessionRx += drx
    snapshot.traffic.sessionTx += dtx
    snapshot.traffic.uptimeSec = math.floor((now - connectStartMs) / 1000)
  end

  lastRxBytes = rx
  lastTxBytes = tx
  lastSampleMs = now
end

-- ── Fast NetworkManager Link Check ────────────────────────────────────────

local function checkNmcliLink()
  noctalia.runAsync("nmcli -t -f NAME,TYPE,DEVICE,STATE connection show --active", function(result)
    if result.exitCode == 0 and result.stdout then
      local found = false
      local serverName = ""
      local dev = ""
      for line in result.stdout:gmatch("[^\r\n]+") do
        local parts = {}
        for p in line:gmatch("[^:]+") do
          table.insert(parts, p)
        end
        local name = parts[1] or ""
        local connType = parts[2] or ""
        local device = parts[3] or ""
        if name:find("^ProtonVPN") or device == "proton0" or connType == "wireguard" then
          found = true
          dev = device
          local s = name:match("^ProtonVPN%s+(.+)")
          if s then serverName = s end
          break
        end
      end

      local wasConnected = snapshot.connected
      snapshot.connected = found
      if found then
        snapshot.connecting = false
        if serverName ~= "" then snapshot.server = serverName end
        snapshot.device = (dev ~= "" and dev or "proton0")
        snapshot.statusText = "Connected"
        if not wasConnected then
          connectStartMs = os.time() * 1000
          lastRxBytes = -1
          lastTxBytes = -1
          lastSampleMs = 0
          snapshot.traffic.sessionRx = 0
          snapshot.traffic.sessionTx = 0
          if noctalia.getConfig("notify_on_connect") ~= false then
            noctalia.notify(noctalia.tr("title"), `Connected to {snapshot.server ~= "" and snapshot.server or "Proton VPN"}`)
          end
        end
      else
        if wasConnected then
          snapshot.statusText = "Disconnected"
          snapshot.forwardedPort = nil
          snapshot.traffic.rxRate = 0
          snapshot.traffic.txRate = 0
          if noctalia.getConfig("notify_on_connect") ~= false then
            noctalia.notify(noctalia.tr("title"), "Disconnected from Proton VPN")
          end
        elseif not snapshot.connecting then
          snapshot.statusText = "Disconnected"
        end
      end
      publishState()
    end
  end, 4000)
end

-- ── Slower Proton VPN CLI Status Check ────────────────────────────────────

local function pollProtonStatus()
  if isPolling then return end
  isPolling = true

  -- Check account authentication first via protonvpn info
  noctalia.runAsync("protonvpn info", function(resInfo)
    local infoOut = (resInfo.stdout or "") .. "\n" .. (resInfo.stderr or "")
    local authenticatedUser = nil

    for line in infoOut:gmatch("[^\r\n]+") do
      local acc = line:match("^Account:%s*'([^']*)'") or line:match("^Account:%s*(.*)$")
      if acc then
        local clean = noctalia.string.trim(acc):gsub("^'", ""):gsub("'$", "")
        if clean ~= "None" and clean ~= "" then
          authenticatedUser = clean
        end
      end
    end

    if authenticatedUser then
      snapshot.signedIn = true
      snapshot.account.username = authenticatedUser
    else
      snapshot.signedIn = false
      snapshot.account.username = ""
      snapshot.account.plan = ""
      if not snapshot.connected and not snapshot.connecting then
        snapshot.statusText = "Not signed in"
      end
    end

    -- Query status
    noctalia.runAsync("protonvpn status", function(resStatus)
      local out = resStatus.stdout or ""
      local err = resStatus.stderr or ""
      local fullText = out .. "\n" .. err

      if fullText:find("Authentication required") or fullText:find("Please sign in") or not snapshot.signedIn then
        snapshot.signedIn = false
        snapshot.account.username = ""
        if not snapshot.connected and not snapshot.connecting then
          snapshot.statusText = "Not signed in"
        end
      else
        for line in fullText:gmatch("[^\r\n]+") do
          local k, v = line:match("^([^:]+):%s*(.*)$")
          if k and v then
            k = noctalia.string.trim(k):lower()
            v = noctalia.string.trim(v)
            if k == "status" then
              snapshot.statusText = v
            elseif k == "server" and v ~= "" then
              snapshot.server = v
            elseif k == "country" and v ~= "" then
              snapshot.country = v
            elseif k == "city" and v ~= "" then
              snapshot.city = v
            elseif k == "ip" and v ~= "" then
              snapshot.ip = v
            elseif k == "protocol" and v ~= "" then
              snapshot.protocol = v
            elseif k == "kill switch" then
              snapshot.config.killSwitch = v:lower()
            elseif k == "netshield" then
              snapshot.config.netshield = v:lower()
            elseif k == "port forwarding" then
              snapshot.config.portForwarding = v:lower()
            end
          end
        end
      end

      -- If signed in, also query config list
      if snapshot.signedIn then
        noctalia.runAsync("protonvpn config list", function(resConfig)
          if resConfig.exitCode == 0 and resConfig.stdout then
            for line in resConfig.stdout:gmatch("[^\r\n]+") do
              local k, v = line:match("^([^:]+):%s*(.*)$")
              if k and v then
                k = noctalia.string.trim(k):lower()
                v = noctalia.string.trim(v):lower()
                if k == "kill-switch" or k == "kill switch" then
                  snapshot.config.killSwitch = v
                elseif k == "netshield" then
                  snapshot.config.netshield = v
                elseif k == "port-forwarding" or k == "port forwarding" then
                  snapshot.config.portForwarding = v
                end
              end
            end
          end
          isPolling = false
          publishState()
        end, 5000)
      else
        isPolling = false
        publishState()
      end
    end, 6000)
  end, 5000)
end

-- ── Command Dispatcher ───────────────────────────────────────────────────

noctalia.state.watch(COMMAND_KEY, function(cmd)
  if type(cmd) ~= "table" or not cmd.op then return end
  local op = cmd.op

  if op == "connect" then
    snapshot.busy = true
    snapshot.connecting = true
    snapshot.statusText = "Connecting..."
    publishState()

    local args = ""
    local target = cmd.target
    if not target or target == "" or target == "fastest" then
      args = ""
    elseif target == "random" then
      args = "--random"
    elseif target == "p2p" then
      args = "--p2p"
    elseif target == "tor" then
      args = "--tor"
    elseif target == "securecore" or target == "sc" then
      args = "--securecore"
    elseif #target == 2 and target:match("^%a%a$") then
      args = `--country {target:upper()}`
    else
      args = `'` .. tostring(target):gsub("'", "'\\''") .. `'`
    end

    noctalia.runAsync(`protonvpn connect {args}`, function(result)
      snapshot.busy = false
      if result.exitCode ~= 0 then
        snapshot.connecting = false
        snapshot.lastError = result.stderr ~= "" and result.stderr or result.stdout
        noctalia.notify(noctalia.tr("title"), `Connection failed: {snapshot.lastError}`)
      else
        snapshot.lastError = ""
      end
      checkNmcliLink()
      pollProtonStatus()
    end, 40000)

  elseif op == "disconnect" then
    snapshot.busy = true
    snapshot.statusText = "Disconnecting..."
    publishState()

    noctalia.runAsync("protonvpn disconnect", function(result)
      snapshot.busy = false
      snapshot.connected = false
      snapshot.connecting = false
      snapshot.statusText = "Disconnected"
      checkNmcliLink()
      pollProtonStatus()
    end, 15000)

  elseif op == "set_killswitch" then
    local val = (cmd.value == "standard") and "standard" or "off"
    noctalia.runAsync(`protonvpn config set kill-switch {val}`, function(res)
      if res.exitCode == 0 then
        snapshot.config.killSwitch = val
      end
      publishState()
    end, 10000)

  elseif op == "set_netshield" then
    local val = cmd.value
    if val ~= "off" and val ~= "malware-only" and val ~= "malware-ads-trackers" then
      val = "off"
    end
    noctalia.runAsync(`protonvpn config set netshield {val}`, function(res)
      if res.exitCode == 0 then
        snapshot.config.netshield = val
      end
      publishState()
    end, 10000)

  elseif op == "set_port_forwarding" then
    local val = (cmd.value == "on") and "on" or "off"
    noctalia.runAsync(`protonvpn config set port-forwarding {val}`, function(res)
      if res.exitCode == 0 then
        snapshot.config.portForwarding = val
        if val == "on" then
          renewPortForwarding()
        else
          snapshot.forwardedPort = nil
        end
      end
      publishState()
    end, 10000)

  elseif op == "toggle_split" then
    local nextState = not snapshot.splitTunneling.enabled
    saveSplitTunneling(nextState, snapshot.splitTunneling.apps)

  elseif op == "add_split_app" then
    local path = cmd.path
    if path and path ~= "" then
      local exists = false
      for _, p in ipairs(snapshot.splitTunneling.apps) do
        if p == path then exists = true; break end
      end
      if not exists then
        local copy = {}
        for _, p in ipairs(snapshot.splitTunneling.apps) do table.insert(copy, p) end
        table.insert(copy, path)
        saveSplitTunneling(snapshot.splitTunneling.enabled, copy)
      end
    end

  elseif op == "remove_split_app" then
    local path = cmd.path
    if path and path ~= "" then
      local copy = {}
      for _, p in ipairs(snapshot.splitTunneling.apps) do
        if p ~= path then table.insert(copy, p) end
      end
      saveSplitTunneling(snapshot.splitTunneling.enabled, copy)
    end

  elseif op == "signin" then
    local targetUser = ""
    if type(cmd.username) == "string" then
      targetUser = noctalia.string.trim(cmd.username)
    end
    local quotedUser = targetUser:gsub("'", "'\\''")
    local cmdStr = `bash '{PLUGIN_DIR}/signin.sh' '{quotedUser}'`

    if type(noctalia.runInTerminal) == "function" then
      noctalia.runInTerminal(cmdStr)
    end

  elseif op == "signout" then
    noctalia.runAsync("protonvpn signout", function()
      snapshot.signedIn = false
      snapshot.connected = false
      snapshot.account.username = ""
      checkNmcliLink()
      pollProtonStatus()
    end, 10000)

  elseif op == "refresh" then
    checkNmcliLink()
    pollProtonStatus()
    loadSplitTunneling()
    loadServersAndCities()
  end
end)

-- ── Main Loop ─────────────────────────────────────────────────────────────

function update()
  pollCounter += 1
  portPollCounter += 1

  -- Sample traffic statistics every 1s
  if noctalia.getConfig("traffic_monitoring") ~= false then
    sampleTraffic()
  end

  -- Fast link check every 2s
  if pollCounter % 2 == 0 then
    checkNmcliLink()
  end

  -- Proton CLI status check on configured interval
  if pollCounter % refreshIntervalSec == 0 then
    pollProtonStatus()
  end

  -- Port forwarding renewal every 45s when enabled
  if portPollCounter >= 45 then
    portPollCounter = 0
    renewPortForwarding()
  end
end

-- Initialize
loadServersAndCities()
loadSplitTunneling()
loadCandidateApps()
checkNmcliLink()
pollProtonStatus()
publishState()
