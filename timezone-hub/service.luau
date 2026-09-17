--!nonstrict
-- Timezone Hub service — owns the device timezone, the comparison-city
-- list, and the bar-widget zone choices. Publishes computed rows every
-- second so the bar widget and panel stay thin clients of this state.
--
-- Persistence: pluginDataDir()/data.json ->
--   { comparisons = {...}, barTzs = { "__device__", "Area/City", ... } }
-- State:
--   timezone_hub.device_tz          -> string
--   timezone_hub.changing_device_tz -> bool
--   timezone_hub.rows               -> { { key, label, tz, isDevice, index,
--                                          timeText, dateText, offsetMinutes,
--                                          abbrev }, ... }
--   timezone_hub.bar_tzs            -> up to three zone keys; "__device__" follows the device zone
--   timezone_hub.all_zones          -> { "Area/City", ... }
--   timezone_hub.all_zones_loaded   -> bool
-- Commands (timezone_hub.cmd):
--   { op = "add"|"remove"|"reorder"|"set_device"|"toggle_bar_zone"|"load_zones", ... }

noctalia.setUpdateInterval(1000)

local FALLBACK_ZONES = {
  "America/New_York", "America/Chicago", "America/Denver", "America/Los_Angeles",
  "America/Sao_Paulo", "America/Mexico_City", "America/Toronto", "America/Vancouver",
  "America/Bogota", "America/Lima", "America/Argentina/Buenos_Aires",
  "Europe/London", "Europe/Paris", "Europe/Berlin", "Europe/Madrid", "Europe/Rome",
  "Europe/Amsterdam", "Europe/Zurich", "Europe/Stockholm", "Europe/Athens",
  "Europe/Istanbul", "Europe/Moscow", "Europe/Warsaw", "Europe/Dublin",
  "Africa/Cairo", "Africa/Johannesburg", "Africa/Lagos", "Africa/Nairobi",
  "Asia/Dubai", "Asia/Karachi", "Asia/Kolkata", "Asia/Dhaka", "Asia/Bangkok",
  "Asia/Jakarta", "Asia/Singapore", "Asia/Hong_Kong", "Asia/Shanghai",
  "Asia/Manila", "Asia/Seoul", "Asia/Tokyo",
  "Australia/Perth", "Australia/Brisbane", "Australia/Sydney", "Australia/Melbourne",
  "Pacific/Auckland", "Pacific/Honolulu", "UTC",
}

local deviceTz = ""
local changingDeviceTz = false
local comparisons = {} -- ordered { { tz, label }, ... }
local DEVICE_BAR_KEY = "__device__"
local MAX_BAR_ZONES = 3
local barTzs = { DEVICE_BAR_KEY }
local allZones = {}
local allZonesLoaded = false
local allZonesLoading = false
local allZonesLoadStartedMs = nil
local ZONES_LOAD_TIMEOUT_MS = 8000

-- ---------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------
local function dataPath()
  local dir = noctalia.pluginDataDir()
  if dir == nil then
    return nil
  end
  return dir .. "/data.json"
end

local function saveData()
  local path = dataPath()
  if path == nil then
    return
  end
  local encoded = noctalia.json.encode({ comparisons = comparisons, barTzs = barTzs })
  if encoded ~= nil then
    noctalia.writeFile(path, encoded)
  end
end

local function loadData()
  comparisons = {}
  barTzs = { DEVICE_BAR_KEY }
  local path = dataPath()
  if path ~= nil then
    local raw = noctalia.readFile(path)
    if raw ~= nil then
      local decoded = noctalia.json.decode(raw)
      if type(decoded) == "table" then
        if type(decoded.comparisons) == "table" then
          for _, entry in ipairs(decoded.comparisons) do
            if type(entry) == "table" and type(entry.tz) == "string" and entry.tz ~= "" then
              table.insert(comparisons, { tz = entry.tz, label = entry.label or entry.tz })
            end
          end
        end
        if type(decoded.barTzs) == "table" then
          local restored = {}
          local seen = {}
          for _, zone in ipairs(decoded.barTzs) do
            if type(zone) == "string" and zone ~= "" and not seen[zone] and #restored < MAX_BAR_ZONES then
              table.insert(restored, zone)
              seen[zone] = true
            end
          end
          if #restored > 0 then barTzs = restored end
        elseif type(decoded.barTz) == "string" then
          -- Migrate the v2.0 single-zone selection. An empty string used to
          -- mean "follow the device timezone".
          barTzs = { decoded.barTz == "" and DEVICE_BAR_KEY or decoded.barTz }
        end
      end
    end
  end
end

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------
local function shortLabel(zone)
  local slash = zone:match(".*/(.*)$")
  if slash ~= nil then
    return (slash:gsub("_", " "))
  end
  return zone
end

local function indexOfComparison(zone)
  for i, entry in ipairs(comparisons) do
    if entry.tz == zone then
      return i
    end
  end
  return nil
end

-- "+0200" -> 120, "-0930" -> -570
local function parseOffsetMinutes(z)
  if type(z) ~= "string" or #z < 5 then
    return nil
  end
  local sign = z:sub(1, 1) == "-" and -1 or 1
  local hh = tonumber(z:sub(2, 3)) or 0
  local mm = tonumber(z:sub(4, 5)) or 0
  return sign * (hh * 60 + mm)
end

local function timeText(zone)
  local raw = noctalia.formatTime("%H|%M", nil, zone)
  local hh, mm = raw:match("(%d+)|(%d+)")
  if hh == nil then
    return "--:--"
  end
  if noctalia.getConfig("time_format") == "12h" then
    local h12 = tonumber(hh) % 12
    if h12 == 0 then
      h12 = 12
    end
    return string.format("%d:%s %s", h12, mm, tonumber(hh) < 12 and "AM" or "PM")
  end
  return hh .. ":" .. mm
end

local function clockTextFromHours(hours)
  local totalMinutes = math.floor(hours * 60 + 0.5) % (24 * 60)
  local hh = math.floor(totalMinutes / 60)
  local mm = totalMinutes % 60
  if noctalia.getConfig("time_format") == "12h" then
    local h12 = hh % 12
    if h12 == 0 then h12 = 12 end
    return string.format("%d:%02d %s", h12, mm, hh < 12 and "AM" or "PM")
  end
  return string.format("%02d:%02d", hh, mm)
end

local function dateText(zone)
  local style = noctalia.getConfig("date_format") or "weekday"
  local format = "%a, %b %d"
  if style == "short" then
    format = "%b %d"
  elseif style == "iso" then
    format = "%Y-%m-%d"
  end
  return noctalia.formatTime(format, nil, zone)
end

-- ---------------------------------------------------------------------
-- Sunrise/sunset (local calculation; no network)
-- ---------------------------------------------------------------------
local zoneCoordinates = {}

local function decodeCoordinate(value, degreeDigits)
  if type(value) ~= "string" or #value < degreeDigits + 3 then return nil end
  local sign = value:sub(1, 1) == "-" and -1 or 1
  local digits = value:sub(2)
  local degrees = tonumber(digits:sub(1, degreeDigits))
  local minutes = tonumber(digits:sub(degreeDigits + 1, degreeDigits + 2))
  local seconds = #digits >= degreeDigits + 4 and tonumber(digits:sub(degreeDigits + 3, degreeDigits + 4)) or 0
  if degrees == nil or minutes == nil or seconds == nil then return nil end
  return sign * (degrees + minutes / 60 + seconds / 3600)
end

local function loadZoneCoordinates(path)
  local raw = noctalia.readFile(path)
  if type(raw) ~= "string" then return end
  for line in raw:gmatch("[^\r\n]+") do
    if line:sub(1, 1) ~= "#" then
      local coordinate, zone = line:match("^[^\t]+\t([^\t]+)\t([^\t]+)")
      if coordinate ~= nil and zone ~= nil and zoneCoordinates[zone] == nil then
        local latitudePart, longitudePart = coordinate:match("^([%+%-]%d+)([%+%-]%d+)$")
        local latitude = decodeCoordinate(latitudePart, 2)
        local longitude = decodeCoordinate(longitudePart, 3)
        if latitude ~= nil and longitude ~= nil then
          zoneCoordinates[zone] = { latitude = latitude, longitude = longitude }
        end
      end
    end
  end
end

local function normalizeDegrees(value)
  return ((value % 360) + 360) % 360
end

local function radians(value)
  return value * math.pi / 180
end

local function degrees(value)
  return value * 180 / math.pi
end

-- NOAA's sunrise equation, returning UTC decimal hours. The standard
-- 90.833-degree zenith accounts for atmospheric refraction and the sun's
-- apparent radius.
local function sunUtcHour(dayOfYear, latitude, longitude, sunrise)
  local longitudeHour = longitude / 15
  local approximate = dayOfYear + ((sunrise and 6 or 18) - longitudeHour) / 24
  local meanAnomaly = 0.9856 * approximate - 3.289
  local trueLongitude = normalizeDegrees(
    meanAnomaly
      + 1.916 * math.sin(radians(meanAnomaly))
      + 0.020 * math.sin(radians(2 * meanAnomaly))
      + 282.634
  )
  local rightAscension = normalizeDegrees(degrees(math.atan(0.91764 * math.tan(radians(trueLongitude)))))
  local longitudeQuadrant = math.floor(trueLongitude / 90) * 90
  local ascensionQuadrant = math.floor(rightAscension / 90) * 90
  rightAscension = (rightAscension + longitudeQuadrant - ascensionQuadrant) / 15

  local sinDeclination = 0.39782 * math.sin(radians(trueLongitude))
  local cosDeclination = math.cos(math.asin(sinDeclination))
  local cosHour = (
    math.cos(radians(90.833)) - sinDeclination * math.sin(radians(latitude))
  ) / (cosDeclination * math.cos(radians(latitude)))
  if cosHour < -1 or cosHour > 1 then return nil end

  local hourAngle = degrees(math.acos(cosHour))
  if sunrise then hourAngle = 360 - hourAngle end
  hourAngle /= 15
  local localMeanTime = hourAngle + rightAscension - 0.06571 * approximate - 6.622
  return normalizeDegrees((localMeanTime - longitudeHour) * 15) / 15
end

local function sunTimes(zone, offsetMinutes)
  if noctalia.getConfig("show_sun_times") ~= true then return nil, nil end
  local coordinate = zoneCoordinates[zone]
  if coordinate == nil or offsetMinutes == nil then return nil, nil end
  local dayOfYear = tonumber(noctalia.formatTime("%j", nil, zone))
  if dayOfYear == nil then return nil, nil end
  local sunriseUtc = sunUtcHour(dayOfYear, coordinate.latitude, coordinate.longitude, true)
  local sunsetUtc = sunUtcHour(dayOfYear, coordinate.latitude, coordinate.longitude, false)
  if sunriseUtc == nil or sunsetUtc == nil then return nil, nil end
  local offsetHours = offsetMinutes / 60
  return clockTextFromHours(sunriseUtc + offsetHours), clockTextFromHours(sunsetUtc + offsetHours)
end

-- ---------------------------------------------------------------------
-- Row computation + publish
-- ---------------------------------------------------------------------
local function computeRows()
  local rows = {}
  local deviceOffset = deviceTz ~= "" and parseOffsetMinutes(noctalia.formatTime("%z", nil, deviceTz)) or nil
  local deviceSunrise, deviceSunset = sunTimes(deviceTz, deviceOffset)
  table.insert(rows, {
    key = "__device__",
    label = noctalia.tr("device.label"),
    tz = deviceTz,
    isDevice = true,
    index = -1,
    timeText = deviceTz ~= "" and timeText(deviceTz) or "--:--",
    dateText = deviceTz ~= "" and dateText(deviceTz) or "",
    offsetMinutes = deviceOffset,
    abbrev = deviceTz ~= "" and noctalia.formatTime("%Z", nil, deviceTz) or "",
    sunriseText = deviceSunrise,
    sunsetText = deviceSunset,
  })

  for i, entry in ipairs(comparisons) do
    if entry.tz ~= deviceTz then
      local offset = parseOffsetMinutes(noctalia.formatTime("%z", nil, entry.tz))
      local sunrise, sunset = sunTimes(entry.tz, offset)
      table.insert(rows, {
        key = entry.tz .. "#" .. i,
        label = entry.label or entry.tz,
        tz = entry.tz,
        isDevice = false,
        index = i,
        timeText = timeText(entry.tz),
        dateText = dateText(entry.tz),
        offsetMinutes = offset,
        abbrev = noctalia.formatTime("%Z", nil, entry.tz),
        sunriseText = sunrise,
        sunsetText = sunset,
      })
    end
  end
  return rows
end

local function publish()
  noctalia.state.set("timezone_hub.device_tz", deviceTz)
  noctalia.state.set("timezone_hub.changing_device_tz", changingDeviceTz)
  noctalia.state.set("timezone_hub.bar_tzs", barTzs)
  noctalia.state.set("timezone_hub.rows", computeRows())
  -- Raw ordered comparison list (distinct from `rows`, which hides an
  -- entry that currently matches the device zone) so the panel can index
  -- drag-reorder positions and dedupe against the real underlying list.
  noctalia.state.set("timezone_hub.comparisons", comparisons)
end

-- ---------------------------------------------------------------------
-- Device timezone: detect + change
-- ---------------------------------------------------------------------
local function detectDeviceTimezone()
  noctalia.runAsync({ "timedatectl", "show", "-p", "Timezone", "--value" }, function(result)
    local tz = result.stdout and noctalia.string.trim(result.stdout) or ""
    if tz == "" then
      noctalia.runAsync(
        { "sh", "-c", "readlink -f /etc/localtime | sed 's#.*/zoneinfo/##'" },
        function(fallback)
          local fbTz = fallback.stdout and noctalia.string.trim(fallback.stdout) or ""
          if fbTz ~= "" then
            deviceTz = fbTz
            publish()
          else
            noctalia.log("TimezoneHub: could not detect the device timezone")
          end
        end
      )
      return
    end
    deviceTz = tz
    publish()
  end)
end

local function setDeviceTimezone(tz)
  if tz == nil or tz == "" or changingDeviceTz or tz == deviceTz then
    return
  end
  changingDeviceTz = true
  publish()
  noctalia.runAsync({ "pkexec", "timedatectl", "set-timezone", tz }, function(result)
    changingDeviceTz = false
    if result.exitCode == 0 then
      -- Swap, don't just overwrite: drop the newly-promoted zone out of the
      -- comparison list (it's about to be the device row, not a comparison
      -- row) and put the outgoing device zone back into the list in its
      -- place, so switching devices never silently loses or duplicates a
      -- zone.
      local oldDeviceTz = deviceTz
      local promotedIdx = indexOfComparison(tz)
      if promotedIdx ~= nil then
        table.remove(comparisons, promotedIdx)
        if oldDeviceTz ~= "" then
          table.insert(comparisons, promotedIdx, { tz = oldDeviceTz, label = shortLabel(oldDeviceTz) })
        end
      elseif oldDeviceTz ~= "" and indexOfComparison(oldDeviceTz) == nil then
        table.insert(comparisons, 1, { tz = oldDeviceTz, label = shortLabel(oldDeviceTz) })
      end
      -- Keep both selected clocks when the device zone and a comparison zone
      -- trade places. The special device key follows the promoted zone while
      -- the old device zone becomes an ordinary comparison selection.
      for i, selected in ipairs(barTzs) do
        if selected == tz then
          barTzs[i] = DEVICE_BAR_KEY
        elseif selected == DEVICE_BAR_KEY and oldDeviceTz ~= "" then
          barTzs[i] = oldDeviceTz
        end
      end
      deviceTz = tz
      saveData()
      publish()
      noctalia.notify(noctalia.tr("toast.title"), noctalia.tr("toast.device-changed") .. " " .. tz)
    else
      publish()
      noctalia.notifyError(noctalia.tr("toast.title"), noctalia.tr("toast.device-change-failed"))
    end
  end)
end

-- ---------------------------------------------------------------------
-- Full IANA zone list (lazy, for the picker)
-- ---------------------------------------------------------------------
local function loadAllZones()
  if allZonesLoaded or allZonesLoading then
    return
  end
  allZonesLoading = true
  allZonesLoadStartedMs = noctalia.nowMs()
  noctalia.runAsync({ "timedatectl", "list-timezones" }, function(result)
    allZonesLoading = false
    allZonesLoadStartedMs = nil
    local list = {}
    if result.exitCode == 0 and result.stdout then
      for line in result.stdout:gmatch("[^\r\n]+") do
        local trimmed = noctalia.string.trim(line)
        if trimmed ~= "" then
          table.insert(list, trimmed)
        end
      end
    end
    allZones = #list > 0 and list or FALLBACK_ZONES
    allZonesLoaded = true
    noctalia.state.set("timezone_hub.all_zones", allZones)
    noctalia.state.set("timezone_hub.all_zones_loaded", true)
  end)
end

-- ---------------------------------------------------------------------
-- Comparison list mutations
-- ---------------------------------------------------------------------
local function addComparison(tz, label)
  tz = noctalia.string.trim(tz or "")
  if tz == "" or tz == deviceTz then
    return false, "invalid"
  end
  if not noctalia.isValidTimezone(tz) then
    return false, "invalid"
  end
  if indexOfComparison(tz) ~= nil then
    return false, "duplicate"
  end
  table.insert(comparisons, { tz = tz, label = (label and label ~= "") and label or shortLabel(tz) })
  saveData()
  publish()
  return true
end

local function removeComparison(tz)
  local idx = indexOfComparison(tz)
  if idx == nil then
    return false
  end
  table.remove(comparisons, idx)
  for i = #barTzs, 1, -1 do
    if barTzs[i] == tz then table.remove(barTzs, i) end
  end
  if #barTzs == 0 then table.insert(barTzs, DEVICE_BAR_KEY) end
  saveData()
  publish()
  return true
end

-- Move `tz` so it ends up at 1-based `index` in the final list.
local function reorderComparison(tz, index)
  local fromIdx = indexOfComparison(tz)
  local insertAt = tonumber(index)
  if fromIdx == nil or insertAt == nil then
    return false
  end
  local entry = table.remove(comparisons, fromIdx)
  if fromIdx < insertAt then
    insertAt -= 1
  end
  insertAt = math.max(1, math.min(insertAt, #comparisons + 1))
  table.insert(comparisons, insertAt, entry)
  saveData()
  publish()
  return true
end

local function toggleBarZone(tz)
  local key = (tz == nil or tz == "") and DEVICE_BAR_KEY or tz
  for i, selected in ipairs(barTzs) do
    if selected == key then
      if #barTzs > 1 then table.remove(barTzs, i) end
      saveData()
      publish()
      return
    end
  end
  if #barTzs >= MAX_BAR_ZONES then
    noctalia.notifyError(noctalia.tr("toast.title"), noctalia.tr("toast.max-bar-zones"))
    return
  end
  table.insert(barTzs, key)
  saveData()
  publish()
end

-- ---------------------------------------------------------------------
-- Commands from the panel
-- ---------------------------------------------------------------------
noctalia.state.watch("timezone_hub.cmd", function(cmd)
  if type(cmd) ~= "table" then
    return
  end
  local op = cmd.op
  if op == "add" then
    local ok, reason = addComparison(cmd.tz, cmd.label)
    if not ok then
      if reason == "invalid" then
        noctalia.notifyError(noctalia.tr("toast.title"), noctalia.tr("ipc.invalid-zone", { zone = cmd.tz or "" }))
      elseif reason == "duplicate" then
        noctalia.notifyError(noctalia.tr("toast.title"), noctalia.tr("ipc.duplicate-zone", { zone = cmd.tz or "" }))
      end
    end
  elseif op == "remove" then
    removeComparison(cmd.tz)
  elseif op == "reorder" then
    reorderComparison(cmd.tz, cmd.index)
  elseif op == "set_device" then
    setDeviceTimezone(cmd.tz)
  elseif op == "toggle_bar_zone" or op == "set_bar_zone" then
    toggleBarZone(cmd.tz)
  elseif op == "load_zones" then
    loadAllZones()
  end
  noctalia.state.set("timezone_hub.cmd", nil)
end)

function onIpc(event, payload)
  if event == "add" then
    addComparison(payload or "")
  elseif event == "remove" then
    removeComparison(payload or "")
  elseif event == "list" then
    local names = {}
    for _, entry in ipairs(comparisons) do
      table.insert(names, entry.tz)
    end
    local body = table.concat(names, "\n")
    noctalia.notify(noctalia.tr("toast.title"), body ~= "" and body or noctalia.tr("ipc.empty-list"))
  end
end

function update()
  -- Self-heal: if the zone-list fetch never came back (its runAsync
  -- callback silently never fired), don't stay stuck forever - clear the
  -- in-flight flag and retry so a picker left open on "Loading..." recovers
  -- on its own instead of needing the plugin restarted.
  if allZonesLoading and allZonesLoadStartedMs ~= nil and (noctalia.nowMs() - allZonesLoadStartedMs) > ZONES_LOAD_TIMEOUT_MS then
    noctalia.log("TimezoneHub: zone list load timed out, retrying")
    allZonesLoading = false
    allZonesLoadStartedMs = nil
    loadAllZones()
  end
  publish()
end

loadZoneCoordinates("/usr/share/zoneinfo/zone1970.tab")
loadZoneCoordinates("/usr/share/zoneinfo/zone.tab")
loadData()
detectDeviceTimezone()
publish()
