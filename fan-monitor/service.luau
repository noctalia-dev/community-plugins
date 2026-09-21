--!nonstrict

local SNAPSHOT_KEY = "fan_monitor.status"

local status = {
  available = false,
  fans = {},
  primary_rpm = 0,
  max_rpm = 0,
  driver = "none",
  last_updated = 0,
}

local reading = false

local function publish()
  noctalia.state.set(SNAPSHOT_KEY, {
    available = status.available,
    fans = status.fans,
    primary_rpm = status.primary_rpm,
    max_rpm = status.max_rpm,
    driver = status.driver,
    last_updated = status.last_updated,
  })
end

local QUERY_SCRIPT = [[sh -c '
found=0
for f in /sys/class/hwmon/hwmon*/fan*_input; do
  [ -r "$f" ] || continue
  d=$(dirname "$f")
  b=$(basename "$f" _input)
  hname=$(cat "$d/name" 2>/dev/null || echo "hwmon")
  label=$(cat "$d/${b}_label" 2>/dev/null)
  [ -z "$label" ] && label="$b"
  max=$(cat "$d/${b}_max" 2>/dev/null || echo "0")
  min=$(cat "$d/${b}_min" 2>/dev/null || echo "0")
  rpm=$(cat "$f" 2>/dev/null || echo "0")
  echo "FAN:$hname:$label:$rpm:$max:$min"
  found=1
done
if [ "$found" -eq 0 ] && [ -r /proc/acpi/ibm/fan ]; then
  rpm=$(grep "^speed:" /proc/acpi/ibm/fan 2>/dev/null | awk "{print \$2}")
  echo "FAN:thinkpad:fan1:${rpm:-0}:0:0"
fi
']]

local function parseOutput(stdout)
  if not stdout or stdout == "" then
    status.available = false
    return
  end

  local fans = {}
  local primaryRpm = 0
  local maxRpm = 0
  local primaryDriver = "hwmon"

  for line in string.gmatch(stdout, "[^\r\n]+") do
    local drv, lbl, rpmStr, maxStr, minStr = string.match(line, "^FAN:([^:]+):([^:]+):(%d+):(%d+):(%d+)")
    if drv and lbl and rpmStr then
      local rpm = tonumber(rpmStr) or 0
      local fMax = tonumber(maxStr) or 0
      local fMin = tonumber(minStr) or 0
      local pct = 0
      if fMax > 0 and rpm > 0 then
        pct = math.min(100, math.floor(((rpm - fMin) / (fMax - fMin)) * 100 + 0.5))
      end

      table.insert(fans, {
        driver = drv,
        label = lbl,
        rpm = rpm,
        max_rpm = fMax,
        min_rpm = fMin,
        percent = pct,
      })

      if rpm > primaryRpm then
        primaryRpm = rpm
      end
      if fMax > maxRpm then
        maxRpm = fMax
      end
      primaryDriver = drv
    end
  end

  if #fans > 0 then
    status.available = true
    status.fans = fans
    status.primary_rpm = primaryRpm
    status.max_rpm = maxRpm
    status.driver = primaryDriver
    status.last_updated = os.time()
  else
    status.available = false
  end
end

local function refresh()
  if reading then
    return
  end
  reading = true

  local ok = noctalia.runAsync(QUERY_SCRIPT, function(result)
    reading = false
    if result.exitCode == 0 then
      parseOutput(result.stdout or "")
    else
      status.available = false
    end
    publish()
  end, 3000)

  if not ok then
    reading = false
  end
end

function onIpc(event, payload)
  if event == "refresh" then
    refresh()
  end
end

function update()
  refresh()
end

function onConfigChanged()
  local poll = tonumber(noctalia.getConfig("poll_interval_ms")) or 2000
  noctalia.setUpdateInterval(poll)
  refresh()
end

local pollInterval = tonumber(noctalia.getConfig("poll_interval_ms")) or 2000
noctalia.setUpdateInterval(pollInterval)

publish()
refresh()
