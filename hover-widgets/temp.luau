--!nonstrict
-- CPU package temperature always shown. Hover can also reveal GPU (nvidia-smi),
-- hottest NVMe, RAM (DIMM), and hottest CPU core -- each toggleable in the
-- widget's settings. All hwmon paths are resolved dynamically once (hwmon
-- numbering can shift across reboots) rather than hardcoded.

local hovering = false
local resolved = false

local progress = 0.0 -- 0 = closed, 1 = fully open
local target = 0.0

-- Same tuning as the clock/volume widgets: 0.16 @ 16ms (~60fps).
local EASE = 0.16
local ANIM_INTERVAL = 16
local IDLE_INTERVAL = 2000

-- utf8.len/offset find character boundaries so a partial reveal never cuts a
-- multi-byte character (e.g. "°") in half.
local function utf8Sub(s: string, charCount: number): string
  if charCount <= 0 then
    return ""
  end
  local len = utf8.len(s)
  if not len or charCount >= len then
    return s
  end
  local offset = utf8.offset(s, charCount + 1)
  if not offset then
    return s
  end
  return s:sub(1, offset - 1)
end

local packagePath = nil
local corePaths = {}
local nvmePaths = {}
local ramPaths = {}

local tempC = nil
local gpuC = nil

local function readMilliC(path: string): number?
  local raw = noctalia.readFile(path)
  if not raw then
    return nil
  end
  local milli = tonumber(string.match(raw, "%-?%d+"))
  if not milli then
    return nil
  end
  return milli / 1000
end

local function maxOf(paths: { string }): number?
  local best = nil
  for _, p in ipairs(paths) do
    local v = readMilliC(p)
    if v and (not best or v > best) then
      best = v
    end
  end
  return best
end

local function resolve()
  resolved = true
  local dirs = noctalia.listDir("/sys/class/hwmon")
  if not dirs then
    return
  end
  for _, dir in ipairs(dirs) do
    local base = `/sys/class/hwmon/{dir}`
    local name = noctalia.readFile(`{base}/name`)
    if name then
      name = noctalia.string.trim(name)
    end

    if name == "coretemp" then
      local files = noctalia.listDir(base)
      if files then
        for _, file in ipairs(files) do
          local n = string.match(file, "^temp(%d+)_label$")
          if n then
            local label = noctalia.readFile(`{base}/temp{n}_label`)
            if label then
              label = noctalia.string.trim(label)
              if label == "Package id 0" then
                packagePath = `{base}/temp{n}_input`
              elseif string.match(label, "^Core %d+$") then
                corePaths[#corePaths + 1] = `{base}/temp{n}_input`
              end
            end
          end
        end
      end
    elseif name == "nvme" then
      local files = noctalia.listDir(base)
      local compositePath = nil
      local fallbackPath = nil
      if files then
        for _, file in ipairs(files) do
          local n = string.match(file, "^temp(%d+)_label$")
          if n then
            local label = noctalia.readFile(`{base}/temp{n}_label`)
            if label and noctalia.string.trim(label) == "Composite" then
              compositePath = `{base}/temp{n}_input`
            end
          elseif string.match(file, "^temp1_input$") then
            fallbackPath = `{base}/temp1_input`
          end
        end
      end
      nvmePaths[#nvmePaths + 1] = compositePath or fallbackPath
    elseif name == "spd5118" then
      ramPaths[#ramPaths + 1] = `{base}/temp1_input`
    end
  end
end

local function updateGpu()
  noctalia.runAsync("nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits", function(result)
    local v = tonumber(string.match(result.stdout or "", "%d+"))
    if v then
      gpuC = v
    end
  end, 2000)
end

local function render()
  barWidget.setFont("Adwaita Sans")
  barWidget.setGlyph("cpu-temperature")

  if not tempC then
    barWidget.setText("--°C")
    return
  end

  local base = `CPU {math.floor(tempC + 0.5)}°C`

  local extraParts = {}
  if noctalia.getConfig("show_gpu") ~= false and gpuC then
    extraParts[#extraParts + 1] = `GPU {math.floor(gpuC + 0.5)}°C`
  end
  if noctalia.getConfig("show_nvme") == true then
    local v = maxOf(nvmePaths)
    if v then
      extraParts[#extraParts + 1] = `NVMe {math.floor(v + 0.5)}°C`
    end
  end
  if noctalia.getConfig("show_ram") == true then
    local v = maxOf(ramPaths)
    if v then
      extraParts[#extraParts + 1] = `RAM {math.floor(v + 0.5)}°C`
    end
  end
  if noctalia.getConfig("show_hottest_core") == true then
    local v = maxOf(corePaths)
    if v then
      extraParts[#extraParts + 1] = `Core {math.floor(v + 0.5)}°C`
    end
  end
  local extra = table.concat(extraParts, "  ")

  local revealLen = math.floor(utf8.len(extra) * progress + 0.5)
  if revealLen > 0 then
    barWidget.setText(`{base}  {utf8Sub(extra, revealLen)}`)
  else
    barWidget.setText(base)
  end
end

local function step()
  if math.abs(progress - target) < 0.01 then
    progress = target
    noctalia.setUpdateInterval(IDLE_INTERVAL)
    if not resolved then
      resolve()
    end
    if packagePath then
      tempC = readMilliC(packagePath)
    end
  else
    progress = progress + (target - progress) * EASE
    noctalia.setUpdateInterval(ANIM_INTERVAL)
  end
  render()
end

function update()
  step()
end

function onHover(isHovering: boolean)
  hovering = isHovering
  target = isHovering and 1.0 or 0.0
  if hovering and noctalia.getConfig("show_gpu") ~= false then
    updateGpu()
  end
  step()
end

function onClick()
  noctalia.runAsync("noctalia msg panel-toggle control-center system")
end
