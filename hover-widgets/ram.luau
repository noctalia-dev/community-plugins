--!nonstrict
-- RAM: compact gauge glyph + percent (gauge toggleable in widget settings).
-- Hover adds used/total in GB (total auto-detected, not hardcoded).

local pct = 0.0
local usedGb = 0.0
local totalGb = 0.0

local progress = 0.0 -- 0 = closed, 1 = fully open
local target = 0.0

-- Same tuning as the clock/volume widgets: 0.16 @ 16ms (~60fps).
local EASE = 0.16
local ANIM_INTERVAL = 16
local IDLE_INTERVAL = 1000

-- utf8.len/offset find character boundaries so a partial reveal never cuts a
-- multi-byte character in half.
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

local function update_meminfo()
  local info = noctalia.readFile("/proc/meminfo")
  if not info then
    return
  end
  local totalKb = tonumber(string.match(info, "MemTotal:%s*(%d+)"))
  local availKb = tonumber(string.match(info, "MemAvailable:%s*(%d+)"))
  if not totalKb or not availKb then
    return
  end
  local usedKb = totalKb - availKb
  pct = usedKb / totalKb * 100
  usedGb = usedKb / 1024 / 1024
  totalGb = totalKb / 1024 / 1024
end

-- Real vertical block-element glyphs (▁..█), each one grows from the bottom
-- like an actual gauge -- confirmed present in the system monospace font
-- (Noto Sans Mono), unlike Adwaita Sans which lacks this whole block.
local BLOCKS = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }

local function gaugeChar(v: number): string
  local idx = math.floor(v / 100 * #BLOCKS + 0.5)
  if idx < 1 then
    idx = 1
  elseif idx > #BLOCKS then
    idx = #BLOCKS
  end
  return BLOCKS[idx]
end

-- Vector RAM outline based on the user reference, tinted to the active theme and cached per colour.
local ramIconSource = noctalia.readFile((noctalia.pluginDir() or "") .. "/assets/memory.svg")
local ramIconDir = (noctalia.pluginDataDir() or noctalia.expandPath("~/.cache/noctalia-plugins")) .. "/cache/ram-icons"
noctalia.mkdirAll(ramIconDir)
local ramIconColor, ramIconPath = nil, nil
local function updateRamIcon()
  local color = noctalia.getColor("on_surface") or "#ffffff"
  if color ~= ramIconColor and ramIconSource then
    local path = ramIconDir .. "/ram-dimm-spaced-" .. string.gsub(color, "#", "") .. ".svg"
    if noctalia.writeFile(path, string.gsub(ramIconSource, "currentColor", color)) then
      ramIconColor, ramIconPath = color, path
    end
  end
  if ramIconPath then barWidget.setImage(ramIconPath, false, 20, 18)
  else barWidget.setGlyph("memory") end
end

local function render()
  updateRamIcon()
  local useGauge = noctalia.getConfig("gauge")
  local amountFirst = noctalia.getConfig("amount_first") == true

  if useGauge ~= false then
    barWidget.setFont("monospace")
  else
    barWidget.setFont("Adwaita Sans")
  end

  local pctText = `{math.floor(pct + 0.5)}%`
  local usedText = string.format("%.1f", usedGb)
  local totalText = `{math.floor(totalGb + 0.5)}`

  local text
  if amountFirst then
    -- resting: "6.1GB"  ->  hover: "20% 6.1/31GB"
    -- The percentage grows in on the left and the "/total" on the right,
    -- both anchored around the always-visible used figure.
    local pctPart = `{pctText} `
    local totalPart = `/{totalText}`
    local pShown = utf8Sub(pctPart, math.floor(utf8.len(pctPart) * progress + 0.5))
    local tShown = utf8Sub(totalPart, math.floor(utf8.len(totalPart) * progress + 0.5))
    text = `{pShown}{usedText}{tShown}GB`
  else
    -- resting: "20%"  ->  hover: "20% 6.1/31GB"
    local extra = `{usedText}/{totalText}GB`
    local revealLen = math.floor(utf8.len(extra) * progress + 0.5)
    text = if revealLen > 0 then `{pctText} {utf8Sub(extra, revealLen)}` else pctText
  end

  if useGauge ~= false then
    text = `{gaugeChar(pct)} {text}`
  end
  barWidget.setText(text)
end

local function step()
  if math.abs(progress - target) < 0.01 then
    progress = target
    noctalia.setUpdateInterval(IDLE_INTERVAL)
    update_meminfo()
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
  target = isHovering and 1.0 or 0.0
  step()
end

function onClick()
  noctalia.runAsync("noctalia msg panel-toggle control-center system")
end
