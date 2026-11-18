--!nonstrict

local SNAPSHOT = "fan.snapshot"
local COMMAND = "fan.command"

local FAN_PATH = "/proc/acpi/ibm/fan"
local POLL_MS = 2500
local READ_TIMEOUT_MS = 4000
local WRITE_TIMEOUT_MS = 4000
local SEP = "__NTF_SEP__"

local VALID_LEVEL = {
  auto = true,
  disengaged = true,
  ["0"] = true,
  ["1"] = true,
  ["2"] = true,
  ["3"] = true,
  ["4"] = true,
  ["5"] = true,
  ["6"] = true,
  ["7"] = true,
}

local snapshot = {
  rpm = 0,
  level = "auto", -- auto / disengaged / 0..7
  temp = 0, -- °C
  available = false, -- /proc/acpi/ibm/fan readable
}

local reading = false

local function shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function thermalPath()
  local z = noctalia.getConfig("thermal_zone")
  if type(z) ~= "string" or z == "" then
    z = "thermal_zone0"
  end
  z = noctalia.string.trim(z):gsub("/+$", ""):match("[^/]+$") or "thermal_zone0"
  return "/sys/class/thermal/" .. z .. "/temp"
end

local function publish()
  noctalia.state.set(SNAPSHOT, {
    rpm = snapshot.rpm,
    level = snapshot.level,
    temp = snapshot.temp,
    available = snapshot.available,
  })
end

local function parseFan(content)
  if not content or content == "" then
    snapshot.available = false
    return
  end
  snapshot.available = true
  for line in content:gmatch("[^\n]+") do
    local rpm = line:match("^speed:%s*(%d+)")
    if rpm then
      snapshot.rpm = tonumber(rpm) or 0
    end
    local level = line:match("^level:%s*(%S+)")
    if level then
      snapshot.level = noctalia.string.trim(level):lower()
    end
  end
end

local function parseTemp(content)
  local raw = content and tonumber(noctalia.string.trim(content))
  if raw then
    snapshot.temp = math.floor(raw / 1000 + 0.5)
  end
end

local function readSysfs()
  if reading then
    return
  end
  reading = true
  local cmd = "cat " .. shellQuote(FAN_PATH) .. " 2>/dev/null; echo " .. SEP
    .. "; cat " .. shellQuote(thermalPath()) .. " 2>/dev/null"
  local launched = noctalia.runAsync(cmd, function(res)
    reading = false
    local out = res.stdout or ""
    local sepAt = out:find(SEP, 1, true)
    parseFan(sepAt and out:sub(1, sepAt - 1) or out)
    parseTemp(sepAt and out:sub(sepAt + #SEP) or "")
    publish()
  end, READ_TIMEOUT_MS)
  if not launched then
    reading = false
  end
end

noctalia.state.watch(COMMAND, function(cmd)
  if type(cmd) ~= "table" or cmd.action ~= "set_level" then
    return
  end
  local lvl = noctalia.string.trim(tostring(cmd.value or "")):lower()
  if not VALID_LEVEL[lvl] then
    return
  end
  snapshot.level = lvl -- optimistic; confirmed by the next read
  publish()
  noctalia.runAsync("echo level " .. lvl .. " > " .. shellQuote(FAN_PATH), function(res)
    if res.exitCode ~= 0 then
      noctalia.notifyError(
        noctalia.tr("notify.fan_error_title"),
        noctalia.tr("notify.fan_error_body")
      )
      noctalia.log("fan level write failed: " .. (res.stderr or ""))
    end
    readSysfs()
  end, WRITE_TIMEOUT_MS)
end)

function update()
  readSysfs()
end

function onConfigChanged()
  reading = false
  readSysfs()
end

noctalia.setUpdateInterval(POLL_MS)

publish()
readSysfs()
