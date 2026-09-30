--!nonstrict
-- Device discovery for ambient-light panel brightness.
--
-- The service calls discover() exactly ONCE, at start, before it reads a profile,
-- builds a curve or touches the panel. Which iio device carries the sensor, which
-- backlight exists, which DRM connector the panel sits behind, whether a lid
-- switch is present -- every one of those is answered here and nowhere else, so
-- the rest of the plugin never guesses a path and never hardcodes a device number.
--
-- The environment is injected (listDir / readFile / outputs / getenv), so tests
-- substitute a fake machine; this module performs no reads of its own outside
-- what env provides. Hotplug is deliberately NOT handled: re-probing costs CPU
-- for a rare case, so the remedy for changed hardware is a plugin restart.

local M = {}

local IIO_DIR = "/sys/bus/iio/devices/"
local BL_DIR = "/sys/class/backlight/"
local DRM_DIR = "/sys/class/drm/"
local LID_DIR = "/proc/acpi/button/lid/"
local SETTINGS_SUFFIX = "/.local/state/noctalia/settings.toml"

local function trim(s)
  if s == nil then return nil end
  return (tostring(s):gsub("%s+$", ""))
end

local function exists(env, path)
  return env.readFile(path) ~= nil
end

--- Directory entries, sorted: listDir order is filesystem order, and a probe
--- must pick the same device on every boot.
local function sorted_dir(env, path)
  local out = {}
  for _, name in ipairs(env.listDir(path) or {}) do
    out[#out + 1] = tostring(name)
  end
  table.sort(out)
  return out
end

--- First iio device exposing `attr`, as (path, device, sensor-name).
local function find_iio(env, attr)
  for _, device in ipairs(sorted_dir(env, IIO_DIR)) do
    if device:match("^iio:device%d+$") then
      local path = IIO_DIR .. device .. "/" .. attr
      if exists(env, path) then
        local sensor = trim(env.readFile(IIO_DIR .. device .. "/name")) or device
        return path, device, sensor
      end
    end
  end
  return nil
end

--- The ambient sensor: prefers `in_illuminance_raw` (what the shipped curve was
--- measured against), falling back to the processed `in_illuminance_input` some
--- sensors expose instead. Returns (path, device, sensor-name) or nil.
local function find_illuminance(env)
  for _, attr in ipairs({ "in_illuminance_raw", "in_illuminance_input" }) do
    local path, device, sensor = find_iio(env, attr)
    if path ~= nil then return path, device, sensor end
  end
  return nil
end

--- The panel output to drive, validated against what Noctalia actually reports:
--- an explicit setting must exist among the outputs; empty picks the focused
--- output, else the alphabetically first. Returns (name, err), exactly one set.
local function find_connector(env, requested)
  local outputs = {}
  if type(env.outputs) == "function" then
    local ok, list = pcall(env.outputs)
    if ok and type(list) == "table" then outputs = list end
  end
  local known, focused = {}, nil
  for _, output in ipairs(outputs) do
    if type(output) == "table" and type(output.name) == "string" then
      known[output.name] = true
      if output.focused and focused == nil then focused = output.name end
    end
  end
  if requested ~= nil and requested ~= "" then
    if known[requested] then return requested, nil end
    return nil, string.format("connector '%s' is not reported by Noctalia", tostring(requested))
  end
  if next(known) == nil then
    return nil, "Noctalia reports no outputs to drive"
  end
  if focused ~= nil then return focused, nil end
  local first
  for name in pairs(known) do
    if first == nil or name < first then first = name end
  end
  return first, nil
end

--- DRM entry backing a connector ("card1-eDP-1" or plain "eDP-1"), or nil.
local function find_drm_entry(env, connector)
  local suffix = "-" .. connector
  for _, entry in ipairs(sorted_dir(env, DRM_DIR)) do
    if entry == connector or entry:sub(-#suffix) == suffix then
      return entry
    end
  end
  return nil
end

--- Discover the hardware the service needs. Returns a report:
---   paths           resolved paths; each is nil when unavailable
---   devices         human-readable names, for the startup log
---   required_missing  reasons the service must not start (list of strings)
---   degraded          reasons a feature/guard is unavailable (list of strings)
---   guard_state(env)  adapter: the runtime guards this probe discovered, in
---                     policy.guard's vocabulary (see below)
---
--- opts.backlight  raw `backlight` setting ("" = auto-detect)
--- opts.connector  raw `connector` setting ("" = auto-detect)
---
--- The contract: anything in required_missing means "do not touch the panel";
--- anything in degraded means "carry on without that feature or guard".
function M.discover(env, opts)
  opts = opts or {}
  local report = {
    paths = {},
    devices = {},
    required_missing = {},
    degraded = {},
  }
  local paths, devices = report.paths, report.devices
  local req, deg = report.required_missing, report.degraded

  -- Ambient light sensor (required): the whole plugin exists for it.
  local path, device, sensor = find_illuminance(env)
  if path ~= nil then
    paths.als_raw = path
    devices.als = device .. " (" .. sensor .. ")"
  else
    req[#req + 1] = "no ambient light sensor found under " .. IIO_DIR
        .. " (need in_illuminance_raw or in_illuminance_input)"
  end

  -- Colour-temperature sensor (optional): colour temperature degrades without it.
  local ct_path, ct_device, ct_sensor = find_iio(env, "in_colortemp_raw")
  if ct_path ~= nil then
    paths.als_ct = ct_path
    devices.colortemp = ct_device .. " (" .. ct_sensor .. ")"
  else
    deg[#deg + 1] = "no colour-temp sensor (in_colortemp_raw) under " .. IIO_DIR
        .. "; colour temperature unavailable"
  end

  -- Backlight device (required): the actuator for every brightness write.
  local forced_bl = opts.backlight
  local bl = nil
  if forced_bl ~= nil and forced_bl ~= "" then
    for _, name in ipairs(sorted_dir(env, BL_DIR)) do
      if name == forced_bl then bl = name end
    end
    if bl == nil then
      req[#req + 1] = "backlight '" .. forced_bl .. "' not found under " .. BL_DIR
    end
  else
    bl = sorted_dir(env, BL_DIR)[1]
    if bl == nil then
      req[#req + 1] = "no backlight device found under " .. BL_DIR
    end
  end
  if bl ~= nil then
    devices.backlight = bl
    local cur, max = BL_DIR .. bl .. "/brightness", BL_DIR .. bl .. "/max_brightness"
    if exists(env, cur) and exists(env, max) then
      paths.bl_cur, paths.bl_max = cur, max
    else
      paths.bl_cur, paths.bl_max = nil, nil
      req[#req + 1] = "backlight '" .. bl .. "' is not readable under " .. BL_DIR
    end
  end

  -- Connector (required): every brightness write is addressed to it, and an
  -- unvalidated name would silently write to the wrong output.
  local connector, conn_err = find_connector(env, opts.connector)
  if connector ~= nil then
    devices.connector = connector
  else
    req[#req + 1] = conn_err
  end

  -- DPMS node for the resolved connector (optional guard).
  if connector ~= nil then
    local entry = find_drm_entry(env, connector)
    if entry ~= nil and exists(env, DRM_DIR .. entry .. "/dpms") then
      paths.dpms = DRM_DIR .. entry .. "/dpms"
    else
      deg[#deg + 1] = "no DPMS node for connector '" .. connector
          .. "'; the screen-off guard is unavailable"
    end
  end

  -- Lid switch (optional guard).
  local lid = nil
  for _, name in ipairs(sorted_dir(env, LID_DIR)) do
    if exists(env, LID_DIR .. name .. "/state") then
      lid = name
      break
    end
  end
  if lid ~= nil then
    paths.lid = LID_DIR .. lid .. "/state"
    devices.lid = lid
  else
    deg[#deg + 1] = "no lid switch under " .. LID_DIR .. "; the lid guard is unavailable"
  end

  -- HOME (optional): the colour-temperature splice target. Never guessed --
  -- there is no sensible fallback for someone else's home directory.
  local home = nil
  if type(env.getenv) == "function" then
    home = trim(env.getenv("HOME"))
  end
  if home ~= nil and home ~= "" then
    paths.settings_path = home .. SETTINGS_SUFFIX
  else
    deg[#deg + 1] = "HOME is unset; the colour-temperature settings splice is unavailable"
  end

  -- Runtime guard inputs, in policy.guard's vocabulary ({dpms=, lid_closed=}).
  -- The locked decision "an UNAVAILABLE guard PASSES" lives HERE, next to the
  -- probe that decided the device is missing: a machine without a DPMS node
  -- reads as dpms="On", a machine without a lid switch reads as open, so a
  -- guard for hardware this machine does not have can never block adaptation.
  -- The service never re-derives that from nil paths.
  --
  -- A device that WAS probed but fails to read at runtime is not unavailability
  -- and keeps its raw result, matching the service's historical behaviour:
  -- dpms=nil blocks (policy.guard reports "dpms=nil"), a failed lid read stays
  -- open. Availability was decided once, at the probe.
  --
  -- env is injected in the same shape discover() takes; only readFile is
  -- needed. Fields this probe does not own (idle_engaged, locked,
  -- override_active) are service state and stay with the caller.
  report.guard_state = function(env)
    local state = { dpms = "On", lid_closed = false }
    if paths.dpms ~= nil then
      state.dpms = trim(env.readFile(paths.dpms))
    end
    if paths.lid ~= nil then
      state.lid_closed = (trim(env.readFile(paths.lid)) or ""):find("closed") ~= nil
    end
    return state
  end

  return report
end

return M
