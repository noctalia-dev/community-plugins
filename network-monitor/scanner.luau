--!nonstrict

local listeners = require("./listeners.luau")

local TICK_MS = 1000
local HISTORY_LENGTH = 60
local ssOutput = ""
local published = nil
local scanPending = false
local nextScanAt = 0
local lastSampleAt = 0
local rxHistory, txHistory = {}, {}

local function publishListeners()
  local list = listeners.parse(ssOutput, {
    includeUdp = noctalia.getConfig("include_udp"),
    hideSystemPorts = noctalia.getConfig("hide_system_ports"),
    onlyOwnProcesses = noctalia.getConfig("only_own_processes"),
  })
  -- Stable lists preserve the panel's row identity and hover state across scans.
  local encoded = noctalia.json.encode(list)
  if encoded ~= published then
    published = encoded
    noctalia.state.set("listeners", list)
  end
end

local function scan()
  if scanPending then
    return
  end
  nextScanAt = noctalia.nowMs() + noctalia.getConfig("refresh_interval") * 1000
  scanPending = noctalia.runAsync({ "ss", "-tulnpH" }, function(result)
    scanPending = false
    if result.exitCode ~= 0 then
      noctalia.log(`ss failed: {result.stderr}`)
      noctalia.state.set("scan_error", true)
      return
    end
    noctalia.state.set("scan_error", false)
    ssOutput = result.stdout
    publishListeners()
  end)
end

local function publishTraffic(rx: number, tx: number)
  table.insert(rxHistory, rx)
  table.insert(txHistory, tx)
  if #rxHistory > HISTORY_LENGTH then
    table.remove(rxHistory, 1)
    table.remove(txHistory, 1)
  end
  noctalia.state.set("traffic", { rx = rx, tx = tx, rxHistory = rxHistory, txHistory = txHistory })
end

local function sampleTraffic(now: number)
  local stats = noctalia.systemStats()
  local pollSeconds = noctalia.getSetting("system.monitor.network_poll_seconds")
  if stats ~= nil and pollSeconds > 0 and now - lastSampleAt >= pollSeconds * 1000 then
    lastSampleAt = now
    publishTraffic(stats.net.rxBytesPerSec, stats.net.txBytesPerSec)
  end
end

function update()
  noctalia.setUpdateInterval(TICK_MS)
  local now = noctalia.nowMs()
  sampleTraffic(now)
  if now >= nextScanAt then
    scan()
  end
end

function onConfigChanged()
  nextScanAt = 0
  publishListeners()
end

noctalia.state.watch("scan", function(delayMs)
  nextScanAt = noctalia.nowMs() + delayMs
  if delayMs == 0 then
    scan()
  else
    noctalia.setUpdateInterval(math.min(delayMs, TICK_MS))
  end
end)

function onIpc(event)
  if event == "refresh" then
    scan()
  elseif event == "selftest" then
    local ok, err = pcall(function()
      require("./tests/listeners_test.luau")(noctalia.log)
      require("./tests/rates_test.luau")(noctalia.log)
    end)
    if not ok then
      noctalia.log(`not ok - {err}`)
    end
  end
end

update()
