--!nonstrict
-- Bar widget for the CMF Buds Pro 2.
-- Click: opens the panel. Wheel: volume. Right click: cycles ANC.

local C = require("./lib/common.luau")

local glyph = noctalia.getConfig("glyph") or "headphones"
local volumeStep = tonumber(noctalia.getConfig("volume_step")) or 5

local statePath = nil
local socketPath = nil
local logPath = nil
local pluginPath = noctalia.pluginDir() or ""
local lastRaw = nil
local lastState = nil

local render

local function ensurePaths()
  local dir = noctalia.pluginDataDir()
  if dir ~= nil then
    statePath = dir .. "/state.json"
    socketPath = dir .. "/daemon.sock"
    logPath = dir .. "/daemon.log"
  end
end

local function readState()
  if statePath == nil then
    ensurePaths()
  end
  if statePath == nil then
    return nil
  end
  local raw = noctalia.readFile(statePath)
  if raw == nil or raw == lastRaw then
    return lastState
  end
  local ok, data = pcall(noctalia.json.decode, raw)
  if not ok or type(data) ~= "table" then
    return lastState
  end
  lastRaw = raw
  lastState = data
  return data
end

-- The daemon can take a while: a full query of the earbuds is about 15 s
-- and a reconnection up to a minute (the Bluetooth connect plus the wait
-- for BlueZ). The host clamps the timeout to 60 s, so the request is not
-- killed in the middle and the real answer is not lost.
local RPC_TIMEOUT_MS = 60000

local function rpc(req, cb, silent)
  ensurePaths()
  if statePath == nil then
    if not silent then
      noctalia.notifyError(C.tr("title"), C.error_text("daemon_failed"))
    end
    return false
  end
  local encoded = noctalia.json.encode(req)
  if encoded == nil then
    noctalia.log("cmf-buds: could not serialize the request")
    if not silent then
      noctalia.notifyError(C.tr("title"), C.error_text("generic"))
    end
    if cb ~= nil then
      cb(nil)
    end
    return false
  end
  local argv = {
    "python3",
    pluginPath .. "/bin/budsctl.py",
    "rpc",
    encoded,
    "--socket",
    socketPath,
    "--state",
    statePath,
    "--log",
    logPath,
    -- The same arguments as the panel: if the widget is the one that has
    -- to start the daemon, it must start it with the settings of the user.
    "--poll",
    tostring(C.poll_seconds()),
    "--device-mac",
    noctalia.getConfig("device_mac") or "",
    "--device-name",
    noctalia.getConfig("device_name") or "",
  }
  local launched = noctalia.runAsync(argv, function(result)
    local ok, data = pcall(noctalia.json.decode, result.stdout or "")
    if not ok or type(data) ~= "table" then
      if not silent then
        -- An empty answer means the process was killed: the daemon needs
        -- more time than the host gave it.
        local detail = ""
        if result.timedOut then
          detail = "timeout"
        else
          detail = (result.stderr or ""):gsub("%s+$", "")
        end
        noctalia.notifyError(C.tr("title"), C.error_text("daemon_failed", detail))
      end
      if cb ~= nil then
        cb(nil)
      end
      render()
      return
    end
    if data.state ~= nil then
      lastState = data.state
    end
    if data.ok ~= true and not silent then
      -- The daemon sends a stable code and the technical detail apart:
      -- the text is resolved here, in the language of the user.
      noctalia.notifyError(C.tr("title"), C.error_text(data.error, data.error_detail))
    end
    if cb ~= nil then
      cb(data)
    end
    render()
  end, RPC_TIMEOUT_MS)
  if not launched then
    -- The host did not start the process and never calls the callback: the
    -- failure has to be reported here or the widget would wait forever.
    if not silent then
      noctalia.notifyError(C.tr("title"), C.error_text("daemon_failed"))
    end
    if cb ~= nil then
      cb(nil)
    end
    return false
  end
  return true
end

render = function()
  local st = lastState
  local connected = st ~= nil and st.connected == true
  local ancMode = st and st.anc and st.anc.mode or "unknown"

  local rows = {
    { C.tr("tooltip.connection"), connected and C.tr("tooltip.connected") or C.tr("tooltip.disconnected") },
    { C.tr("tooltip.anc"), C.anc_label(ancMode, st and st.anc and st.anc.level or nil) },
    { C.tr("tooltip.battery"), C.battery_detail(st) },
    { C.tr("tooltip.eq"), C.eq_label(st and st.eq and st.eq.preset or nil) },
    { C.tr("tooltip.volume"), C.volume_text(st) },
  }
  if st ~= nil and st.error ~= nil and st.error ~= "" then
    table.insert(rows, {
      C.tr("tooltip.error"),
      C.error_text(st.error, st.error_detail),
    })
  end

  -- The tooltip goes on the node under the pointer: with the declarative
  -- tree, the hover area is the child (not the widget), so the widget's
  -- setTooltip would not be shown.
  local parts = {}
  for _, row in ipairs(rows) do
    table.insert(parts, tostring(row[1]) .. ": " .. tostring(row[2]))
  end

  -- Icon only: it inherits the bar color (like the other widgets).
  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({
    gap = 0,
    align = "center",
    justify = "center",
    tooltip = table.concat(parts, "\n"),
  }, {
    ui.glyph({ name = glyph, size = 15 }),
  }))

  barWidget.setTooltip(rows)
end

function update()
  readState()
  render()
end

function onClick()
  noctalia.togglePanel(C.panel_id())
end

function onRightClick()
  local st = lastState
  local mode = st and st.anc and st.anc.mode or "off"
  local req
  if mode == "off" then
    req = { cmd = "anc", mode = "transparency" }
  elseif mode == "transparency" then
    req = { cmd = "anc", mode = "anc", level = st and st.anc and st.anc.level or "high" }
  else
    req = { cmd = "anc", mode = "off" }
  end
  if st ~= nil then
    st.anc = st.anc or {}
    st.anc.mode = req.mode
    if req.level ~= nil then
      st.anc.level = req.level
    end
    render()
  end
  rpc(req, nil, false)
end

-- The wheel sends one event per notch: sending a request for each of them
-- would write the volume several times, and the last write to reach the
-- daemon would not be the last one the user asked for. Only one request is
-- in flight and the target of the last event wins.
local volumeInFlight = false
local pendingVolumeTarget = nil

local function applyVolume(target)
  pendingVolumeTarget = nil
  volumeInFlight = true
  rpc({ cmd = "volume", percent = target, mute = "off" }, function()
    volumeInFlight = false
    local next = pendingVolumeTarget
    if next ~= nil then
      applyVolume(next)
    end
  end, true)
end

function onScroll(axis, steps)
  if axis ~= "vertical" then
    return
  end
  -- The panel sliders are native controls and always take the wheel; this
  -- setting is about scrolling the bar widget, so it is read here.
  if noctalia.getConfig("wheel_adjust") == false then
    return
  end
  local st = lastState
  local current = st and st.volume and st.volume.percent
  if current == nil then
    current = 50
  end
  local delta = -steps * volumeStep
  local target = math.max(0, math.min(100, current + delta))
  if st ~= nil then
    st.volume = st.volume or {}
    st.volume.percent = target
    st.volume.muted = false
    render()
  end
  if volumeInFlight then
    -- A request is already running: the target waits for it.
    pendingVolumeTarget = target
    return
  end
  applyVolume(target)
end

function onIpc(event, payload)
  if event == "toggle" then
    noctalia.togglePanel(C.panel_id())
  elseif event == "refresh" then
    update()
  elseif event == "anc" then
    if payload == "off" or payload == "transparency" or payload == "anc" then
      rpc({ cmd = "anc", mode = payload, level = lastState and lastState.anc and lastState.anc.level or "high" })
    end
  elseif event == "connect" then
    rpc({ cmd = "connect" })
  end
end

function onConfigChanged()
  glyph = noctalia.getConfig("glyph") or "headphones"
  volumeStep = tonumber(noctalia.getConfig("volume_step")) or 5
  render()
end

ensurePaths()
C.loadTranslations()
-- The panel polls the state every 500 ms and the daemon publishes external
-- changes (phone volume, ANC, battery) as soon as it sees them: with a 1 s
-- interval the bar tooltip stays live.
noctalia.setUpdateInterval(1000)
update()
