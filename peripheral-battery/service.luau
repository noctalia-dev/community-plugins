--!nonstrict
-- Peripheral Battery service: polls UPower for wireless peripheral batteries
-- (mice, keyboards, headsets, gamepads, etc.) and publishes a snapshot.

local KEY_SNAPSHOT = "snapshot"

local settings = {
  refresh_seconds = 60,
}

local refreshing = false
local lastSignature = nil
local upowerChecked = false
local upowerAvailable = false

local function trim(s)
  if type(s) ~= "string" then return "" end
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function readSettings()
  local v = tonumber(noctalia.getConfig("refresh_seconds"))
  if v == nil then v = 60 end
  v = math.floor(v)
  if v < 10 then v = 10 end
  settings.refresh_seconds = v
end

local function glyphForKind(kind)
  if kind == "mouse" then return "mouse" end
  if kind == "keyboard" then return "keyboard" end
  if kind == "headphones" or kind == "headset" then return "headphones" end
  if kind == "gaming-input" or kind == "gamepad" then return "device-gamepad" end
  if kind == "phone" then return "device-mobile" end
  if kind == "tablet" then return "device-tablet" end
  if kind == "touchpad" then return "hand-finger" end
  if kind == "pencil" then return "pencil" end
  if kind == "speaker" then return "volume" end
  return "battery"
end

local function kindLabel(kind)
  if kind == "mouse" then return "Mouse" end
  if kind == "keyboard" then return "Keyboard" end
  if kind == "headphones" or kind == "headset" then return "Headset" end
  if kind == "gaming-input" or kind == "gamepad" then return "Controller" end
  if kind == "phone" then return "Phone" end
  if kind == "tablet" then return "Tablet" end
  if kind == "touchpad" then return "Touchpad" end
  if kind == "pencil" then return "Stylus" end
  if kind == "speaker" then return "Speaker" end
  if kind == "media-player" then return "Media player" end
  return "Peripheral"
end

local function normalizeKind(raw)
  local k = trim(raw or ""):lower()
  if k == "gaming_input" or k == "gaming input" then return "gaming-input" end
  if k == "computer" then return "computer" end
  if k == "line-power" or k == "line_power" then return "line-power" end
  return k
end

local function parsePercentage(value)
  if type(value) ~= "string" then return nil end
  local n = value:match("([%d%.]+)%%")
  if n == nil then return nil end
  local num = tonumber(n)
  if num == nil then return nil end
  if num < 0 then num = 0 end
  if num > 100 then num = 100 end
  return math.floor(num + 0.5)
end

local function isPeripheral(dev)
  local path = dev.path
  if path == nil or path == "" then return false end
  local p = path:lower()
  if p:find("displaydevice", 1, true) or p:find("line_power", 1, true) or p:find("line-power", 1, true) then
    return false
  end

  local kind = dev.kind or ""
  if kind == "line-power" or kind == "battery" then
    return false
  end

  local hasBatteryData = (dev.percentage ~= nil)
    or (dev.state ~= nil and dev.state ~= "")
    or (dev.batteryLevel ~= nil and dev.batteryLevel ~= "")

  if kind == "computer" or kind == "ups" or kind == "monitor" or kind == "unknown" or kind == "" then
    if dev.powerSupply == "no" and hasBatteryData then
      local modelLower = (dev.model or ""):lower()
      local nativeLower = (dev.nativePath or ""):lower()
      if nativeLower:find("hidpp", 1, true) or p:find("hidpp", 1, true)
        or nativeLower:find("bluez", 1, true) or p:find("bluez", 1, true)
        or modelLower:find("mouse", 1, true) or nativeLower:find("mouse", 1, true)
        or modelLower:find("keyboard", 1, true) or nativeLower:find("keyboard", 1, true)
        or modelLower:find("headset", 1, true) or modelLower:find("headphone", 1, true)
        or modelLower:find("gamepad", 1, true) or modelLower:find("controller", 1, true)
        or modelLower:find("airpod", 1, true) or modelLower:find("buds", 1, true) then
        return true
      end
    end
    return false
  end

  if dev.powerSupply == "yes" then
    return false
  end
  return hasBatteryData
end

local function finalizeDevice(dev)
  local name = trim(dev.model or "")
  if name == "" then name = trim(dev.nativePath or "") end
  if name == "" then
    name = ((dev.path or ""):match("([^/]+)$") or dev.path or "Peripheral")
  end

  local kind = normalizeKind(dev.kind)
  if kind == "" or kind == "unknown" then
    local hint = ((dev.nativePath or "") .. " " .. name):lower()
    if hint:find("mouse", 1, true) or hint:find("hidpp", 1, true) then
      kind = "mouse"
    elseif hint:find("keyboard", 1, true) then
      kind = "keyboard"
    elseif hint:find("headset", 1, true) or hint:find("headphone", 1, true) then
      kind = "headphones"
    elseif hint:find("gamepad", 1, true) or hint:find("controller", 1, true) or hint:find("gaming", 1, true) then
      kind = "gaming-input"
    else
      kind = "peripheral"
    end
  end

  local state = trim(dev.state or "")
  if state == "" then state = "unknown" end
  local charging = (state == "charging" or state == "pending-charge")
  local full = (state == "fully-charged")
  local discharging = (state == "discharging" or state == "pending-discharge")

  local detailParts = {}
  local batteryLevel = dev.batteryLevel or ""
  local warningLevel = dev.warningLevel or ""
  local serial = dev.serial or ""
  if batteryLevel ~= "" then table.insert(detailParts, "level: " .. batteryLevel) end
  if warningLevel ~= "" and warningLevel ~= "none" then table.insert(detailParts, "warning: " .. warningLevel) end
  if serial ~= "" then table.insert(detailParts, "serial: " .. serial) end

  return {
    key = dev.path,
    path = dev.path,
    name = name,
    model = dev.model or "",
    kind = kind,
    kindLabel = kindLabel(kind),
    glyph = glyphForKind(kind),
    percentage = dev.percentage,
    percentageText = dev.percentageText or "",
    state = state,
    charging = charging,
    full = full,
    discharging = discharging,
    batteryLevel = batteryLevel,
    warningLevel = warningLevel,
    nativePath = dev.nativePath or "",
    serial = serial,
    detail = table.concat(detailParts, " · "),
  }
end

local function parseUpowerDump(text)
  local devices = {}
  local current = nil
  local inDevice = false

  local function flush()
    if current ~= nil and isPeripheral(current) then
      devices[#devices + 1] = finalizeDevice(current)
    end
    current = nil
    inDevice = false
  end

  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local devPath = line:match("^Device:%s*(.+)$")
    if devPath then
      flush()
      current = {
        path = trim(devPath),
        model = "",
        nativePath = "",
        serial = "",
        powerSupply = "",
        state = "",
        percentage = nil,
        percentageText = "",
        batteryLevel = "",
        warningLevel = "",
        kind = "",
      }
      inDevice = true
    elseif inDevice and current ~= nil then
      local key, value = line:match("^%s%s([%w%-]+):%s*(.*)$")
      if key then
        value = trim(value)
        local lk = key:lower()
        if lk == "model" then
          current.model = value
        elseif lk == "native-path" then
          current.nativePath = value
        elseif lk == "serial" then
          current.serial = value
        elseif lk == "power supply" then
          current.powerSupply = value:lower()
        elseif lk == "state" then
          current.state = value
        elseif lk == "percentage" then
          current.percentageText = value
          current.percentage = parsePercentage(value)
        elseif lk == "warning-level" then
          current.warningLevel = value
        elseif lk == "battery-level" then
          current.batteryLevel = value
        elseif lk == "icon-name" then
          current.iconName = value
        end
      else
        local sec = line:match("^%s%s([%w%-]+)%s*$")
        if sec then
          local s = sec:lower()
          if s == "line-power" then
            current.kind = "line-power"
          elseif s == "battery" then
            if current.kind == "" then current.kind = "battery" end
          elseif current.kind == "" or current.kind == "unknown" then
            current.kind = normalizeKind(sec)
          end
        else
          local nestedKey, nestedVal = line:match("^%s%s%s%s([%w%-]+):%s*(.*)$")
          if nestedKey then
            nestedVal = trim(nestedVal)
            local lk = nestedKey:lower()
            if lk == "state" and current.state == "" then
              current.state = nestedVal
            elseif lk == "percentage" and current.percentage == nil then
              current.percentageText = nestedVal
              current.percentage = parsePercentage(nestedVal)
            elseif lk == "warning-level" and current.warningLevel == "" then
              current.warningLevel = nestedVal
            elseif lk == "battery-level" and current.batteryLevel == "" then
              current.batteryLevel = nestedVal
            end
          end
        end
      end
    end
  end
  flush()

  table.sort(devices, function(a, b)
    local ak, bk = a.kindLabel or "", b.kindLabel or ""
    if ak ~= bk then return ak < bk end
    local an, bn = a.name or "", b.name or ""
    if an ~= bn then return an < bn end
    return (a.key or "") < (b.key or "")
  end)
  return devices
end

local function buildSnapshot(devices, err)
  local total = #devices
  local withPct = 0
  local lowest = nil
  local sigParts = { err or "", "#", tostring(total) }
  for i = 1, total do
    local d = devices[i]
    local p = d.percentage
    if type(p) == "number" then
      withPct = withPct + 1
      if lowest == nil or p < lowest then lowest = p end
    end
    sigParts[#sigParts + 1] = table.concat({
      d.key or "",
      d.name or "",
      d.kind or "",
      tostring(p ~= nil and p or ""),
      d.state or "",
      d.batteryLevel or "",
      d.warningLevel or "",
      d.charging and "1" or "0",
      d.full and "1" or "0",
    }, "|")
  end

  local sig = table.concat(sigParts, "\n")
  return {
    devices = devices,
    total = total,
    withPct = withPct,
    lowest = lowest,
    error = err,
    updatedAt = os.time(),
  }, sig
end

local function publishSnapshot(devices, err)
  local snap, sig = buildSnapshot(devices, err)
  if sig == lastSignature then
    return
  end
  lastSignature = sig
  noctalia.state.set(KEY_SNAPSHOT, snap)
end

local function setErrorSnapshot(msg)
  publishSnapshot({}, msg)
end

local function refresh()
  if refreshing then return end

  if not upowerChecked then
    upowerChecked = true
    upowerAvailable = noctalia.commandExists("upower")
  end
  if not upowerAvailable then
    setErrorSnapshot("upower not found")
    return
  end

  refreshing = true
  noctalia.runAsync("upower -d 2>&1", function(result)
    refreshing = false
    if result == nil or result.exitCode ~= 0 then
      local msg = "failed to query upower"
      if result ~= nil then
        local stderr = trim(result.stderr or "")
        local stdout = trim(result.stdout or "")
        if stderr ~= "" then
          msg = stderr
        elseif stdout ~= "" then
          msg = stdout
        end
        if stderr:find("not found", 1, true) or stdout:find("not found", 1, true) then
          upowerAvailable = false
        end
      end
      setErrorSnapshot(msg)
      return
    end

    local devices = parseUpowerDump(result.stdout or "")
    publishSnapshot(devices, nil)
  end)
end

local function applyUpdateInterval()
  noctalia.setUpdateInterval(settings.refresh_seconds * 1000)
end

readSettings()
applyUpdateInterval()

function update()
  refresh()
end

function onConfigChanged()
  local prev = settings.refresh_seconds
  readSettings()
  if settings.refresh_seconds ~= prev then
    applyUpdateInterval()
  end
  refresh()
end

function onIpc(event, _payload)
  if event == "refresh" then
    refresh()
  end
end

refresh()
