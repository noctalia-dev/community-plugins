--!nonstrict
-- Left click: start the timer, right click: cancel it, wheel: N +/- 15 minutes,
-- middle click: the panel with the big dial.
-- While the timer runs the dial counts down and the wheel and left click do nothing.
-- While its state is unknown (systemd could not be asked yet) the dial shows "?" and both
-- clicks work: Start is safe because systemd refuses a second timer of ours.

local timer = require("./timer.luau")

local MINUTES_PER_TICK = 5
-- Default fits a capsule of bar thickness 30 * capsule_thickness 0.9. The widget API cannot
-- read the bar thickness, so other bars set the size in the plugin settings.
local DEFAULT_DIAL_SIZE = 27

local function dialSize()
  local size = tonumber(noctalia.getConfig("dial_size"))
  if not size then
    return DEFAULT_DIAL_SIZE
  end
  return math.clamp(math.floor(size), 12, 64)
end

-- The script re-runs whenever the bar rebuilds its widgets, so nothing can live only in
-- variables: the timer and the chosen minutes are read through timer.luau.
local dataDir = timer.dataDir
local minutes = timer.loadMinutes()
local lastTooltip = nil
local trackImage = timer.imageTracker()

local function dialSvg(value, neutral, accent, textColor, font, label)
  local style = timer.lapStyle(value, neutral, accent)
  local litTicks = math.ceil(style.fraction * timer.MINUTES_PER_LAP / MINUTES_PER_TICK)

  local parts = { '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">' }
  -- Fills clockwise from the 1 o'clock mark, so 15 minutes ends exactly on the 3 o'clock mark
  for tick = 1, 12 do
    local angle = math.rad(tick * 30)
    -- Longer marks at 12, 3, 6 and 9, like on a real clock
    local inner = tick % 3 == 0 and 24 or 26
    local lit = tick <= litTicks
    table.insert(parts, string.format(
      '<line x1="%.2f" y1="%.2f" x2="%.2f" y2="%.2f" stroke="%s" stroke-width="5.5" stroke-linecap="round" stroke-opacity="%s"/>',
      32 + inner * math.sin(angle), 32 - inner * math.cos(angle),
      32 + 29 * math.sin(angle), 32 - 29 * math.cos(angle),
      lit and style.lit or style.unlit, lit and "1" or tostring(style.unlitOpacity)
    ))
  end
  local text = label or tostring(value)
  local fontSize = #text > 2 and 21 or 27
  table.insert(parts, string.format(
    '<text x="32" y="%.2f" text-anchor="middle" font-family="%s" font-weight="bold" font-size="%d" fill="%s">%s</text>',
    32 + fontSize * 0.36, font, fontSize, textColor, text
  ))
  table.insert(parts, "</svg>")
  return table.concat(parts)
end

local function drawDial(value, neutral, accent, textColor, label)
  if not dataDir then
    barWidget.setText(label or tostring(value))
    return
  end
  local font = timer.fontFamily()
  -- One file per look: the image is cached by path, so a rewritten file would not show up
  local look = table.concat({ value, label and "unknown" or "known", neutral, accent, textColor, font }, "-")
    :gsub("[^%w%-]", "")
  local path = string.format("%s/dial-%s.svg", dataDir, look)
  if not noctalia.fileExists(path) then
    noctalia.writeFile(path, dialSvg(value, neutral, accent, textColor, font, label))
  end
  local size = dialSize()
  barWidget.setImage(path, false, size, size)
  trackImage(path)
end

local function render()
  local status, at = timer.status()
  local value = minutes
  local label = nil
  local tooltip = noctalia.tr("widget.tooltip_idle", { time = timer.formatLong(minutes) })
  if at then
    value = timer.remainingMinutes(at)
    tooltip = noctalia.tr("widget.tooltip_active", { clock = os.date("%H:%M", at) })
  elseif status == "unknown" then
    label = "?"
    tooltip = noctalia.tr("widget.tooltip_unknown", { time = timer.formatLong(minutes) })
  end
  local neutral = noctalia.getColor("on_surface") or "#ffffff"
  local accent = noctalia.getColor("primary") or neutral
  drawDial(value, neutral, accent, at and accent or neutral, label)
  if tooltip ~= lastTooltip then
    barWidget.setTooltip(tooltip)
    lastTooltip = tooltip
  end
end

function update()
  timer.poll(render)
  render()
end

function onConfigChanged()
  render()
end

function onClick()
  timer.start(minutes, render)
end

function onRightClick()
  timer.cancel(render)
end

function onMiddleClick()
  noctalia.togglePanel(timer.PANEL_ID)
end

function onScroll(axis, steps)
  if axis ~= "vertical" or timer.scheduledAt() then
    return
  end
  -- steps is negative for wheel up. Never below one step: +0 would shut down immediately
  minutes = timer.setMinutes(math.max(timer.STEP_MINUTES, minutes - steps * timer.STEP_MINUTES))
  render()
end

-- The panel changes the minutes and starts/cancels the timer too
noctalia.state.watch("minutes", function(value)
  if type(value) == "number" and value ~= minutes then
    minutes = value
    render()
  end
end)
noctalia.state.watch("scheduled", function()
  render()
end)

-- Dial files are cheap to regenerate; drop the ones left from earlier runs and old themes
if dataDir then
  for _, name in ipairs(noctalia.listDir(dataDir) or {}) do
    if name:match("^dial%-.*%.svg$") then
      noctalia.removeFile(dataDir .. "/" .. name)
    end
  end
end

noctalia.setUpdateInterval(1000)
timer.verify(render)
render()
