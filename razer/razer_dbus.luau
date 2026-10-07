--!strict
local Razer = {}

export type DeviceInfo = {
  serial: string,
  name: string,
  deviceType: string,
  battery: number,
  isCharging: boolean,
  hasBattery: boolean,
  brightness: number,
  dpi: number,
}

-- Check if OpenRazer daemon is running on session bus
function Razer.checkDaemon(callback: (boolean) -> ())
  noctalia.runAsync({
    "busctl", "--user", "status", "org.razer"
  }, function(res)
    callback(res.exitCode == 0)
  end)
end

-- Get all connected device serial numbers
function Razer.getDevices(callback: ({ string }) -> ())
  noctalia.runAsync({
    "busctl", "--user", "--json=short", "call",
    "org.razer", "/org/razer", "razer.devices", "getDevices"
  }, function(res)
    if res.exitCode ~= 0 or not res.stdout or res.stdout == "" then
      callback({})
      return
    end

    local parsed = noctalia.json.decode(res.stdout)
    if parsed and parsed.data and type(parsed.data[1]) == "table" then
      callback(parsed.data[1])
    else
      callback({})
    end
  end)
end

-- Get detailed info for a single device
local staticCache: { [string]: { name: string, devType: string } } = {}

function Razer.getDeviceInfo(serial: string, callback: (DeviceInfo?) -> ())
  local path = "/org/razer/device/" .. serial

  local function queryDynamic(name: string, devType: string)
    local currentDpi = 1800
    local batteryVal = -1
    local hasBattery = false
    local isCharging = false
    local brightness = 100

    local pending = 3
    local function checkDone()
      pending = pending - 1
      if pending == 0 then
        local info: DeviceInfo = {
          serial = serial,
          name = name,
          deviceType = devType:lower(),
          battery = batteryVal,
          isCharging = isCharging,
          hasBattery = hasBattery and batteryVal >= 0,
          brightness = brightness,
          dpi = currentDpi,
        }
        callback(info)
      end
    end

    -- 1. Get DPI
    noctalia.runAsync({ "busctl", "--user", "--json=short", "call", "org.razer", path, "razer.device.dpi", "getDPI" }, function(dpiRes)
      if dpiRes.exitCode == 0 and dpiRes.stdout and dpiRes.stdout ~= "" then
        local dpiData = noctalia.json.decode(dpiRes.stdout)
        if dpiData and dpiData.data and dpiData.data[1] and dpiData.data[1][1] then
          currentDpi = tonumber(dpiData.data[1][1]) or 1800
        end
      end
      checkDone()
    end)

    -- 2. Get Battery & Charging
    noctalia.runAsync({ "busctl", "--user", "call", "org.razer", path, "razer.device.power", "getBattery" }, function(batRes)
      if batRes.exitCode == 0 then
        hasBattery = true
        local rawBat = batRes.stdout:match('d%s+([%d%.]+)')
        batteryVal = math.floor(tonumber(rawBat) or -1)
        noctalia.runAsync({ "busctl", "--user", "call", "org.razer", path, "razer.device.power", "isCharging" }, function(chgRes)
          isCharging = chgRes.exitCode == 0 and chgRes.stdout:find("true") ~= nil
          checkDone()
        end)
      else
        checkDone()
      end
    end)

    -- 3. Get Brightness
    noctalia.runAsync({ "busctl", "--user", "call", "org.razer", path, "razer.device.lighting.logo", "getLogoBrightness" }, function(brRes)
      if brRes.exitCode == 0 and brRes.stdout then
        local rawBr = brRes.stdout:match('d%s+([%d%.]+)') or "100"
        brightness = math.floor(tonumber(rawBr) or 100)
      end
      checkDone()
    end)
  end

  local cached = staticCache[serial]
  if cached then
    queryDynamic(cached.name, cached.devType)
    return
  end

  -- Initial query for static name & type
  noctalia.runAsync({ "busctl", "--user", "call", "org.razer", path, "razer.device.misc", "getDeviceName" }, function(nameRes)
    if nameRes.exitCode ~= 0 then
      callback(nil)
      return
    end
    local name = nameRes.stdout:match('s%s+"([^"]+)"') or "Razer Device"
    noctalia.runAsync({ "busctl", "--user", "call", "org.razer", path, "razer.device.misc", "getDeviceType" }, function(typeRes)
      local devType = typeRes.stdout:match('s%s+"([^"]+)"') or "device"
      staticCache[serial] = { name = name, devType = devType }
      queryDynamic(name, devType)
    end)
  end)
end

-- Set Static RGB Color (Logo, Scroll, and Chroma)
function Razer.setStatic(serial: string, r: number, g: number, b: number, callback: ((boolean) -> ())?)
  local path = "/org/razer/device/" .. serial
  local rStr, gStr, bStr = tostring(r), tostring(g), tostring(b)
  noctalia.runAsync({ "busctl", "--user", "call", "org.razer", path, "razer.device.lighting.logo", "setLogoStatic", "yyy", rStr, gStr, bStr })
  noctalia.runAsync({ "busctl", "--user", "call", "org.razer", path, "razer.device.lighting.scroll", "setScrollStatic", "yyy", rStr, gStr, bStr })
  noctalia.runAsync({ "busctl", "--user", "call", "org.razer", path, "razer.device.lighting.chroma", "setStatic", "yyy", rStr, gStr, bStr }, function(res)
    if callback then callback(res.exitCode == 0) end
  end)
end

-- Set Spectrum Cycle
function Razer.setSpectrum(serial: string, callback: ((boolean) -> ())?)
  local path = "/org/razer/device/" .. serial
  noctalia.runAsync({ "busctl", "--user", "call", "org.razer", path, "razer.device.lighting.logo", "setLogoSpectrum" })
  noctalia.runAsync({ "busctl", "--user", "call", "org.razer", path, "razer.device.lighting.scroll", "setScrollSpectrum" })
  noctalia.runAsync({ "busctl", "--user", "call", "org.razer", path, "razer.device.lighting.chroma", "setSpectrum" }, function(res)
    if callback then callback(res.exitCode == 0) end
  end)
end

-- Turn off lighting
function Razer.setNone(serial: string, callback: ((boolean) -> ())?)
  local path = "/org/razer/device/" .. serial
  noctalia.runAsync({ "busctl", "--user", "call", "org.razer", path, "razer.device.lighting.logo", "setLogoNone" })
  noctalia.runAsync({ "busctl", "--user", "call", "org.razer", path, "razer.device.lighting.scroll", "setScrollNone" })
  noctalia.runAsync({ "busctl", "--user", "call", "org.razer", path, "razer.device.lighting.chroma", "setNone" }, function(res)
    if callback then callback(res.exitCode == 0) end
  end)
end

-- Set Brightness (0 to 100)
function Razer.setBrightness(serial: string, percent: number, callback: ((boolean) -> ())?)
  local path = "/org/razer/device/" .. serial
  local pStr = tostring(percent)
  noctalia.runAsync({ "busctl", "--user", "call", "org.razer", path, "razer.device.lighting.logo", "setLogoBrightness", "d", pStr })
  noctalia.runAsync({ "busctl", "--user", "call", "org.razer", path, "razer.device.lighting.scroll", "setScrollBrightness", "d", pStr })
  noctalia.runAsync({ "busctl", "--user", "call", "org.razer", path, "razer.device.lighting.brightness", "setBrightness", "d", pStr }, function(res)
    if callback then callback(res.exitCode == 0) end
  end)
end

-- Set DPI (for mice)
function Razer.setDPI(serial: string, dpi: number, callback: ((boolean) -> ())?)
  local path = "/org/razer/device/" .. serial
  local dpiStr = tostring(dpi)
  noctalia.runAsync({ "busctl", "--user", "call", "org.razer", path, "razer.device.dpi", "setDPI", "qq", dpiStr, dpiStr }, function(res)
    if callback then callback(res.exitCode == 0) end
  end)
end

-- Get active theme color directly via Noctalia host API noctalia.getColor(role)
function Razer.getThemeColor(role: string?): (string, boolean)
  local targetRole = role or "primary"
  if type(noctalia.getColor) == "function" then
    local hex = noctalia.getColor(targetRole)
    if hex and type(hex) == "string" and #hex >= 4 then
      return hex:upper(), true
    end
  end

  -- Fallback strictly to Razer Green when theme color is unavailable
  return "#00FF00", false
end

return Razer


