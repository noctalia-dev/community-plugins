--!nonstrict
-- ROG Control service: the only entry that talks to asusd and supergfxd.
--
-- Graphics mode: asusd's firmware switches (gpu_mux_mode, dgpu_disable) take
-- effect at the next restart, which is what upstream asusctl recommends now that
-- supergfxd is deprecated. If supergfxd is running it is used instead, as before.
--
-- Cost model: nothing polls the hardware. One `gdbus monitor` stream per daemon
-- reports property changes; each change triggers a single snapshot read
-- (asusd: one GetManagedObjects call, ~6 KB), and bursts collapse into at most
-- one follow-up read. Writes are direct D-Bus property sets, made only when the
-- user acts. The once-every-20-seconds tick only retries a dropped stream and
-- checks whether the theme accent moved (for the keyboard colour); both are
-- in-process and spawn nothing unless something changed.
--
--   noctalia.state "rog.state"    snapshot for the bar, panel and tile
--   noctalia.state "rog.request"  actions from the bar, panel and tile

local model = require("./lib/model.luau")

local ASUSD = "xyz.ljones.Asusd"
local PLATFORM_PATH = "/xyz/ljones"
local PLATFORM = "xyz.ljones.Platform"
local ARMOURY = "xyz.ljones.AsusArmoury"
local AURA = "xyz.ljones.Aura"
local SLASH = "xyz.ljones.Slash"
local GFX = "org.supergfxctl.Daemon"
local GFX_PATH = "/org/supergfxctl/Gfx"
-- UPower owns the battery charge limit: Noctalia's own battery controls use it, and
-- asusd follows whatever UPower sets (it mirrors the threshold and saves it).
local UPOWER = "org.freedesktop.UPower"
local UPOWER_DEVICE = "org.freedesktop.UPower.Device"

local CALL_TIMEOUT_MS = 4000
local TICK_MS = 20000
local CLOSED = "@@rog-control-stream-closed"
local GFX_QUERY = [[for m in Mode PendingMode PendingUserAction Supported; do busctl --system --json=short call org.supergfxctl.Daemon /org/supergfxctl/Gfx org.supergfxctl.Daemon "$m" 2>/dev/null || echo null; done]]

local state = {
  asusd = nil, -- normalised asusd state, nil while asusd is unreachable
  gpu = nil, -- graphics mode from supergfxd, or else from asusd's firmware switches
  charge = nil, -- UPower charge-limit state, nil when the battery has none
  prefs = { followTheme = true, colour = nil },
  error = nil,
}

local streams = { asusd = false, gfx = false, upower = false }
local busy = { asusd = false, gfx = false, upower = false }
local again = { asusd = false, gfx = false, upower = false }
local batteryPath = nil -- UPower object path of the system battery
local gfxPresent = nil -- nil = not probed yet
local lastProfile = nil
local lastAppliedLed = nil

-- Preferences -------------------------------------------------------------

local function prefsPath()
  local dir = noctalia.pluginDataDir()
  return dir ~= nil and `{dir}/prefs.json` or nil
end

local function loadPrefs()
  local path = prefsPath()
  if path == nil then
    return
  end
  local text = noctalia.readFile(path)
  local decoded = text ~= nil and noctalia.json.decode(text) or nil
  if type(decoded) == "table" then
    if type(decoded.followTheme) == "boolean" then
      state.prefs.followTheme = decoded.followTheme
    end
    if type(decoded.colour) == "string" then
      state.prefs.colour = decoded.colour
    end
  end
end

local function savePrefs()
  local path = prefsPath()
  if path ~= nil then
    noctalia.writeFile(path, noctalia.json.encode(state.prefs) or "{}")
  end
end

-- Publishing --------------------------------------------------------------

local function publish()
  noctalia.state.set(model.STATE, {
    available = state.asusd ~= nil,
    error = state.error,
    asusd = state.asusd,
    gpu = state.gpu,
    charge = state.charge,
    prefs = state.prefs,
  })
end

local function fail(action, result)
  local reason = result ~= nil and noctalia.string.trim(result.stderr or "") or ""
  noctalia.notifyError(noctalia.tr("notify.failed", { action = noctalia.tr(action) }), reason)
end

-- asusd -------------------------------------------------------------------

-- busctl --json=short wraps every variant as { type, data }; keep the data.
local function props(objects, path, iface)
  local object = objects[path]
  local raw = object ~= nil and object[iface] or nil
  if raw == nil then
    return nil
  end
  local out = {}
  for key, value in pairs(raw) do
    out[key] = type(value) == "table" and value.data or value
  end
  return out
end

local function findPath(objects, prefix, iface)
  for path, ifaces in pairs(objects) do
    if string.sub(path, 1, #prefix) == prefix and ifaces[iface] ~= nil then
      return path
    end
  end
  return nil
end

local applyThemeColour -- defined below; needs the fresh snapshot
local startStreams -- defined below; supergfxd's stream starts once it answers

-- Without supergfxd, the graphics mode is asusd's two firmware switches, the way
-- upstream asusctl does it now. asusd queues a change (QueuedGpuValue) and its
-- asus-shutdown service applies it while the machine shuts down, after preparing
-- the NVIDIA driver, so every mode is safe to pick here. CurrentValue stays the
-- mode this boot runs; a queued value is a pending switch, shown with Restart
-- and Cancel. Upstream's pairs: Eco = dGPU off + MUX hybrid, Standard = dGPU on +
-- MUX hybrid, Ultimate = dGPU on + MUX discrete.
local function gpuModeOf(dgpuOff, discrete)
  if dgpuOff then
    return model.GPU_ECO
  end
  return discrete and model.GPU_ULTIMATE or model.GPU_STANDARD
end

local function firmwareGpu()
  local fw = state.asusd ~= nil and state.asusd.gpuFirmware or nil
  if fw == nil then
    return nil
  end
  local running = gpuModeOf(fw.dgpuDisabled, fw.muxDiscrete)
  local nextDgpuOff, nextDiscrete = fw.dgpuDisabled, fw.muxDiscrete
  if fw.dgpuQueued ~= nil then
    nextDgpuOff = fw.dgpuQueued == 1
  end
  if fw.muxQueued ~= nil then
    nextDiscrete = fw.muxQueued == 0
  end
  local configured = gpuModeOf(nextDgpuOff, nextDiscrete)

  local supported = { model.GPU_STANDARD }
  if fw.hasDgpu then
    table.insert(supported, model.GPU_ECO)
  end
  if fw.hasMux then
    table.insert(supported, model.GPU_ULTIMATE)
  end
  local pending = configured ~= running and configured or nil
  return {
    source = "asusd",
    mode = running,
    pending = pending,
    action = pending ~= nil and model.GPU_ACTION_REBOOT or model.GPU_ACTION_NONE,
    supported = supported,
  }
end

-- asusd's QueuedGpuValue is -1 when nothing is waiting for the next boot.
local function queuedGpuValue(attribute)
  local q = attribute ~= nil and attribute.QueuedGpuValue or nil
  return (type(q) == "number" and q >= 0) and q or nil
end

local function applyAsusd(objects)
  local platform = props(objects, PLATFORM_PATH, PLATFORM)
  if platform == nil then
    state.asusd = nil
    state.error = noctalia.tr("error.no_platform")
    publish()
    return
  end

  local overdrive = props(objects, "/xyz/ljones/asus_armoury/panel_overdrive", ARMOURY)
  local dgpu = props(objects, "/xyz/ljones/asus_armoury/dgpu_disable", ARMOURY)
  local mux = props(objects, "/xyz/ljones/asus_armoury/gpu_mux_mode", ARMOURY)

  local auraPath = findPath(objects, "/xyz/ljones/aura/", AURA)
  local slashPath = findPath(objects, "/xyz/ljones/aura/", SLASH)
  local aura = auraPath ~= nil and props(objects, auraPath, AURA) or nil
  local slash = slashPath ~= nil and props(objects, slashPath, SLASH) or nil

  local fresh = {
    profile = platform.PlatformProfile,
    profileOnAc = platform.PlatformProfileOnAc,
    profileOnBattery = platform.PlatformProfileOnBattery,
    profileChoices = platform.PlatformProfileChoices or {},
    chargeLimit = platform.ChargeControlEndThreshold,
    overdrive = overdrive ~= nil and overdrive.CurrentValue or nil,
    -- The firmware graphics switches (what the next boot will use).
    gpuFirmware = (dgpu ~= nil or mux ~= nil) and {
      hasDgpu = dgpu ~= nil,
      hasMux = mux ~= nil,
      dgpuDisabled = dgpu ~= nil and dgpu.CurrentValue == 1,
      muxDiscrete = mux ~= nil and mux.CurrentValue == 0,
      dgpuQueued = queuedGpuValue(dgpu),
      muxQueued = queuedGpuValue(mux),
    } or nil,
    aura = aura ~= nil and {
      path = auraPath,
      brightness = aura.Brightness,
      brightnessChoices = aura.SupportedBrightness or {},
      mode = aura.LedMode,
      modes = aura.SupportedBasicModes or {},
      -- LedModeData: (mode, zone, colour1, colour2, speed, direction)
      data = aura.LedModeData,
    } or nil,
    slash = slash ~= nil and {
      path = slashPath,
      enabled = slash.Enabled,
      mode = slash.Mode,
    } or nil,
  }

  -- The ROG key (Fn+F5) and the panel both land here, so one place gives every
  -- profile change the same native on-screen confirmation.
  if lastProfile ~= nil and fresh.profile ~= lastProfile and noctalia.getConfig("show_osd") ~= false then
    local p = model.profile(fresh.profile)
    if p ~= nil then
      noctalia.osd.show(p.glyph, noctalia.tr(p.key))
    end
  end
  lastProfile = fresh.profile

  state.asusd = fresh
  state.error = nil
  if gfxPresent == false then
    state.gpu = firmwareGpu()
  end
  publish()
  applyThemeColour()
end

local function refreshAsusd()
  if busy.asusd then
    again.asusd = true
    return
  end
  busy.asusd = true
  noctalia.runAsync({
    "busctl", "--system", "--json=short", "call", ASUSD, "/",
    "org.freedesktop.DBus.ObjectManager", "GetManagedObjects",
  }, function(result)
    busy.asusd = false
    local decoded = nil
    if result.exitCode == 0 and not result.timedOut then
      decoded = noctalia.json.decode(result.stdout)
    end
    if type(decoded) == "table" and type(decoded.data) == "table" and type(decoded.data[1]) == "table" then
      applyAsusd(decoded.data[1])
    else
      state.asusd = nil
      state.error = noctalia.tr("error.no_asusd")
      publish()
    end
    if again.asusd then
      again.asusd = false
      refreshAsusd()
    end
  end, CALL_TIMEOUT_MS)
end

-- supergfxd ---------------------------------------------------------------

local function refreshGfx()
  if busy.gfx then
    again.gfx = true
    return
  end
  busy.gfx = true
  noctalia.runAsync({ "sh", "-c", GFX_QUERY }, function(result)
    busy.gfx = false
    local values = {}
    for line in string.gmatch(result.stdout or "", "[^\n]+") do
      local decoded = noctalia.json.decode(line)
      table.insert(values, type(decoded) == "table" and decoded.data or false)
    end
    local mode, pending, action, supported = values[1], values[2], values[3], values[4]
    if type(mode) == "table" and type(supported) == "table" then
      local first = gfxPresent ~= true
      gfxPresent = true
      if first then
        startStreams()
      end
      state.gpu = {
        source = "supergfxd",
        mode = mode[1],
        pending = type(pending) == "table" and pending[1] or nil,
        action = type(action) == "table" and action[1] or model.GPU_ACTION_NONE,
        supported = supported[1] or {},
      }
    else
      gfxPresent = false
      state.gpu = firmwareGpu()
    end
    publish()
    if again.gfx then
      again.gfx = false
      refreshGfx()
    end
  end, CALL_TIMEOUT_MS)
end

-- UPower charge limit ----------------------------------------------------

local function refreshCharge()
  if batteryPath == nil then
    return
  end
  if busy.upower then
    again.upower = true
    return
  end
  busy.upower = true
  noctalia.runAsync({
    "busctl", "--system", "--json=short", "call", UPOWER, batteryPath,
    "org.freedesktop.DBus.Properties", "GetAll", "s", UPOWER_DEVICE,
  }, function(result)
    busy.upower = false
    local decoded = result.exitCode == 0 and noctalia.json.decode(result.stdout) or nil
    local p = type(decoded) == "table" and type(decoded.data) == "table" and decoded.data[1] or nil
    local function value(key)
      local v = type(p) == "table" and p[key] or nil
      return type(v) == "table" and v.data or nil
    end
    if value("ChargeThresholdSupported") == true then
      state.charge = {
        enabled = value("ChargeThresholdEnabled") == true,
        limit = value("ChargeEndThreshold"),
      }
    else
      state.charge = nil
    end
    publish()
    if again.upower then
      again.upower = false
      refreshCharge()
    end
  end, CALL_TIMEOUT_MS)
end

local function findBattery()
  noctalia.runAsync({ "busctl", "--system", "--json=short", "call", UPOWER, "/org/freedesktop/UPower", UPOWER, "EnumerateDevices" }, function(result)
    local decoded = result.exitCode == 0 and noctalia.json.decode(result.stdout) or nil
    local devices = type(decoded) == "table" and type(decoded.data) == "table" and decoded.data[1] or {}
    for _, path in ipairs(devices) do
      if string.find(path, "/battery_", 1, true) then
        batteryPath = path
        break
      end
    end
    if batteryPath ~= nil then
      refreshCharge()
      startStreams()
    end
  end, CALL_TIMEOUT_MS)
end

-- Streams -----------------------------------------------------------------

local function onAsusdLine(line)
  if line == CLOSED then
    streams.asusd = false
    return
  end
  -- Property changes, and asusd (re)appearing on the bus after a restart.
  if string.find(line, "PropertiesChanged", 1, true) or string.find(line, " is owned by ", 1, true) then
    refreshAsusd()
  end
end

local function onGfxLine(line)
  if line == CLOSED then
    streams.gfx = false
    return
  end
  if string.find(line, ".Notify", 1, true) or string.find(line, " is owned by ", 1, true) then
    refreshGfx()
  end
end

local function onUpowerLine(line)
  if line == CLOSED then
    streams.upower = false
    return
  end
  -- UPower reports charge level changes all the time; only threshold changes matter.
  if string.find(line, "ChargeThreshold", 1, true) or string.find(line, "ChargeEndThreshold", 1, true) then
    refreshCharge()
  end
end

startStreams = function()
  if not noctalia.commandExists("gdbus") or not noctalia.commandExists("busctl") then
    state.error = noctalia.tr("error.no_tools")
    publish()
    return
  end
  if not streams.asusd then
    streams.asusd = noctalia.runStream(`gdbus monitor --system --dest {ASUSD}; echo '{CLOSED}'`, onAsusdLine)
  end
  if gfxPresent and not streams.gfx then
    streams.gfx = noctalia.runStream(`gdbus monitor --system --dest {GFX}; echo '{CLOSED}'`, onGfxLine)
  end
  if batteryPath ~= nil and not streams.upower then
    streams.upower = noctalia.runStream(
      `gdbus monitor --system --dest {UPOWER} --object-path {batteryPath}; echo '{CLOSED}'`,
      onUpowerLine
    )
  end
end

-- Keyboard colour follows the theme ---------------------------------------

local function ledData()
  local aura = state.asusd ~= nil and state.asusd.aura or nil
  if aura == nil or type(aura.data) ~= "table" then
    return nil
  end
  return aura
end

local function setLedColour(r, g, b)
  local aura = ledData()
  if aura == nil then
    return
  end
  local d = aura.data
  local second = type(d[4]) == "table" and d[4] or { 0, 0, 0 }
  noctalia.runAsync({
    "busctl", "--system", "set-property", ASUSD, aura.path, AURA, "LedModeData", "(uu(yyy)(yyy)ss)",
    tostring(d[1] or 0), tostring(d[2] or 0), tostring(r), tostring(g), tostring(b),
    tostring(second[1]), tostring(second[2]), tostring(second[3]),
    tostring(d[5] or "Med"), tostring(d[6] or "Right"),
  }, function(result)
    if result.exitCode ~= 0 or result.timedOut then
      fail("action.keyboard_colour", result)
    end
  end, CALL_TIMEOUT_MS)
end

-- Only single-colour effects take a colour; a rainbow keeps its own.
local COLOUR_MODES = { [0] = true, [1] = true, [10] = true }

applyThemeColour = function()
  local aura = ledData()
  if aura == nil or not state.prefs.followTheme or not COLOUR_MODES[aura.mode] then
    return
  end
  local r, g, b = model.ledColour(noctalia.getColor("primary"))
  if r == nil then
    return
  end
  local target = model.hex(r, g, b)
  local live = type(aura.data[3]) == "table" and model.hex(aura.data[3][1], aura.data[3][2], aura.data[3][3]) or nil
  if target ~= live and target ~= lastAppliedLed then
    lastAppliedLed = target
    setLedColour(r, g, b)
  end
end

-- Actions -----------------------------------------------------------------

local function pluggedIn()
  local supplies = noctalia.listDir("/sys/class/power_supply") or {}
  for _, name in ipairs(supplies) do
    local base = `/sys/class/power_supply/{name}`
    if noctalia.string.trim(noctalia.readFile(`{base}/type`) or "") == "Mains" then
      return noctalia.string.trim(noctalia.readFile(`{base}/online`) or "") == "1"
    end
  end
  return true
end

local function run(argv, actionKey, after)
  noctalia.runAsync(argv, function(result)
    if result.exitCode ~= 0 or result.timedOut then
      fail(actionKey, result)
    end
    if after ~= nil then
      after(result)
    end
  end, CALL_TIMEOUT_MS)
end

local function setProperty(path, iface, prop, signature, value, actionKey)
  run({ "busctl", "--system", "set-property", ASUSD, path, iface, prop, signature, tostring(value) }, actionKey)
end

local ACTIONS = {}

-- Choosing a mode also makes it the default for the current power source, so it
-- sticks the way it does in Armoury Crate and G-Helper: asusd switches between the
-- charger and battery defaults by itself when the power source changes.
function ACTIONS.profile(value)
  setProperty(PLATFORM_PATH, PLATFORM, "PlatformProfile", "u", value, "action.profile")
  local perSource = pluggedIn() and "PlatformProfileOnAc" or "PlatformProfileOnBattery"
  setProperty(PLATFORM_PATH, PLATFORM, perSource, "u", value, "action.profile")
end

function ACTIONS.cycleProfile(delta)
  local a = state.asusd
  if a == nil then
    return
  end
  local target = model.stepProfile(a.profile, a.profileChoices, delta or 1)
  if target ~= nil then
    ACTIONS.profile(target)
  end
end

function ACTIONS.chargeLimit(on)
  if batteryPath == nil then
    return
  end
  run({ "busctl", "--system", "call", UPOWER, batteryPath, UPOWER_DEVICE, "EnableChargeThreshold", "b", on and "true" or "false" },
    "action.charge_limit", function()
      refreshCharge()
    end)
end

function ACTIONS.fullCharge()
  run({ "busctl", "--system", "call", ASUSD, PLATFORM_PATH, PLATFORM, "OneShotFullCharge" }, "action.full_charge")
end

function ACTIONS.overdrive(on)
  setProperty("/xyz/ljones/asus_armoury/panel_overdrive", ARMOURY, "CurrentValue", "i", on and 1 or 0, "action.overdrive")
end

local function setGpuSwitch(attribute, value)
  run({
    "busctl", "--system", "set-property", ASUSD, `/xyz/ljones/asus_armoury/{attribute}`, ARMOURY,
    "CurrentValue", "i", tostring(value),
  }, "action.gpu_mode", function()
    refreshAsusd()
  end)
end

function ACTIONS.gpuMode(value)
  if gfxPresent then
    run({ "busctl", "--system", "call", GFX, GFX_PATH, GFX, "SetMode", "u", tostring(value) }, "action.gpu_mode", function()
      refreshGfx()
    end)
    return
  end
  -- asusd: set the firmware switches for the next boot. Setting a switch back to
  -- its running value clears asusd's queue, which is how Cancel works.
  local fw = state.asusd ~= nil and state.asusd.gpuFirmware or nil
  local gpu = state.gpu
  if fw == nil or gpu == nil or gpu.source ~= "asusd" then
    return
  end
  if (value == model.GPU_ULTIMATE and not fw.hasMux) or (value == model.GPU_ECO and not fw.hasDgpu) then
    return
  end
  local wantDgpuOff = value == model.GPU_ECO
  local wantDiscrete = value == model.GPU_ULTIMATE
  local nextDgpuOff = fw.dgpuQueued ~= nil and fw.dgpuQueued == 1 or (fw.dgpuQueued == nil and fw.dgpuDisabled)
  local nextDiscrete = fw.muxQueued ~= nil and fw.muxQueued == 0 or (fw.muxQueued == nil and fw.muxDiscrete)
  if fw.hasDgpu and nextDgpuOff ~= wantDgpuOff then
    setGpuSwitch("dgpu_disable", wantDgpuOff and 1 or 0)
  end
  if fw.hasMux and nextDiscrete ~= wantDiscrete then
    setGpuSwitch("gpu_mux_mode", wantDiscrete and 0 or 1)
  end
end

function ACTIONS.keyboardBrightness(value)
  local aura = ledData()
  if aura ~= nil then
    setProperty(aura.path, AURA, "Brightness", "u", value, "action.keyboard")
  end
end

function ACTIONS.keyboardMode(value)
  local aura = ledData()
  if aura ~= nil then
    setProperty(aura.path, AURA, "LedMode", "u", value, "action.keyboard")
  end
end

function ACTIONS.followTheme(on)
  state.prefs.followTheme = on
  savePrefs()
  publish()
  if on then
    lastAppliedLed = nil
    applyThemeColour()
  elseif state.prefs.colour ~= nil then
    ACTIONS.keyboardColour(state.prefs.colour)
  end
end

function ACTIONS.keyboardColour(hex)
  local h = string.match(hex or "", "^#?(%x%x%x%x%x%x)")
  if h == nil then
    return
  end
  state.prefs.colour = `#{h}`
  state.prefs.followTheme = false
  savePrefs()
  publish()
  setLedColour(tonumber(string.sub(h, 1, 2), 16), tonumber(string.sub(h, 3, 4), 16), tonumber(string.sub(h, 5, 6), 16))
end

function ACTIONS.slash(on)
  local s = state.asusd ~= nil and state.asusd.slash or nil
  if s ~= nil then
    setProperty(s.path, SLASH, "Enabled", "b", on and "true" or "false", "action.slash")
  end
end

function ACTIONS.slashMode(value)
  local s = state.asusd ~= nil and state.asusd.slash or nil
  if s ~= nil then
    setProperty(s.path, SLASH, "Mode", "y", value, "action.slash")
  end
end

noctalia.state.watch(model.REQUEST, function(request)
  if type(request) ~= "table" or type(request.action) ~= "string" then
    return
  end
  local handler = ACTIONS[request.action]
  if handler ~= nil then
    handler(request.value)
  end
end)

-- Lifecycle ---------------------------------------------------------------

function update()
  startStreams()
  if gfxPresent == nil then
    refreshGfx()
  end
  applyThemeColour()
end

function onIpc(event)
  if event == "refresh" then
    refreshAsusd()
    refreshGfx()
    refreshCharge()
  elseif event == "next-profile" then
    ACTIONS.cycleProfile(1)
  end
end

noctalia.setUpdateInterval(TICK_MS)
loadPrefs()
publish()
refreshAsusd()
refreshGfx()
findBattery()
startStreams()
