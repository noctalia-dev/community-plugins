--!nonstrict
-- The big dial: shutdown time on top, a 60-minute ring with hour/minute fields inside,
-- and start/cancel below. Drag the knob around the ring (it grows while held) or scroll
-- over the dial to change the time. Opened from the bar widget (middle click) and from
-- the Control Center tile.
--
-- Press, drag and wheel reach a panel script only through ui.pixelStream, so a fully
-- transparent stream from companion.py lies over the dial image and reports the pointer.

local timer = require("./timer.luau")

local DIAL = 320
local CENTER = DIAL / 2
-- Height of the row drawn inside the dial: one lg input
local CENTER_ROW = 44
local RING_RADIUS = 140
local KNOB_RADIUS = 15
local KNOB_RADIUS_HELD = 21
-- A press this close to the knob grabs it; a press elsewhere on the ring moves it there
local KNOB_HIT = 26
local RING_HIT_INNER = 100
local RING_HIT_OUTER = 165

local dataDir = timer.dataDir
local pluginDir = noctalia.pluginDir()
local socketPath = dataDir and (dataDir .. "/dial.sock")
local minutes = timer.loadMinutes()
local at = timer.scheduledAt()
local trackImage = timer.imageTracker()

-- Drag state: the minutes while dragging are a float, rounded for display
local dragging = false
local dragValue = 0
local dragAngle = 0

-- ui.input is uncontrolled: it keeps what the user types until it gets a new key.
-- inputRev changes only when the minutes come from elsewhere (drag, wheel, bar, cancel),
-- so typing is never interrupted by a re-render.
local inputRev = 0
local hoursText = ""
local minutesText = ""

local function resetInputs()
  inputRev += 1
  hoursText = tostring(minutes // 60)
  minutesText = string.format("%02d", minutes % 60)
end
resetInputs()

local function startCompanion()
  if pluginDir and socketPath then
    -- Exits by itself a few seconds after the panel closes; a second copy exits at once
    noctalia.runAsync({ "python3", pluginDir .. "/companion.py", socketPath })
  end
end

local function point(radius, angle)
  return CENTER + radius * math.sin(angle), CENTER - radius * math.cos(angle)
end

-- Angle of the filled part's end, as minutes into the lap (0..60)
local function knobMinutes(value)
  return math.ceil(timer.lapStyle(value, "", "").fraction * timer.MINUTES_PER_LAP)
end

local function dialSvg(value, c, held, font)
  local style = timer.lapStyle(value, c.neutral, c.accent)
  local litTicks = knobMinutes(value)
  local parts = { '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 320 320">' }
  local function add(fmt, ...)
    table.insert(parts, string.format(fmt, ...))
  end

  -- Dark track around the face, like the bedtime ring in iOS
  add('<circle cx="160" cy="160" r="%d" fill="none" stroke="%s" stroke-width="36"/>', RING_RADIUS, c.track)
  -- One tick per minute, filled clockwise from 12 o'clock; every 5th is longer
  for tick = 1, 60 do
    local angle = math.rad(tick * 6)
    local long = tick % 5 == 0
    local x1, y1 = point(long and 128 or 131, angle)
    local x2, y2 = point(long and 152 or 149, angle)
    local lit = tick <= litTicks
    add('<line x1="%.2f" y1="%.2f" x2="%.2f" y2="%.2f" stroke="%s" stroke-width="%s" stroke-linecap="round" stroke-opacity="%s"/>',
      x1, y1, x2, y2, lit and style.lit or style.unlit, long and "4" or "3",
      lit and "1" or tostring(style.unlitOpacity))
  end

  -- Face with minute dots and labels
  add('<circle cx="160" cy="160" r="118" fill="%s"/>', c.face)
  for tick = 1, 60 do
    local x, y = point(110, math.rad(tick * 6))
    local major = tick % 5 == 0
    add('<circle cx="%.2f" cy="%.2f" r="%s" fill="%s" fill-opacity="%s"/>',
      x, y, major and "1.8" or "1.1", c.muted, major and "0.9" or "0.5")
  end
  for _, mark in ipairs({ 60, 10, 15, 20, 30, 40, 45, 50 }) do
    local quarter = mark % 15 == 0
    local size = quarter and 17 or 14
    local x, y = point(94, math.rad(mark * 6))
    add('<text x="%.2f" y="%.2f" text-anchor="middle" font-family="%s" font-weight="%s" font-size="%d" fill="%s">%d</text>',
      x, y + size * 0.36, font, quarter and "bold" or "normal", size, quarter and c.neutral or c.muted, mark)
  end

  -- Moon above the fields, power sign below them
  add('<path d="M165 89 A12 12 0 1 0 172 108 A9 9 0 1 1 165 89 Z" fill="%s"/>', c.accent)
  add('<path d="M153.5 211 A9 9 0 1 0 166.5 211" fill="none" stroke="%s" stroke-width="2.5" stroke-linecap="round"/>', c.muted)
  add('<line x1="160" y1="205" x2="160" y2="215" stroke="%s" stroke-width="2.5" stroke-linecap="round"/>', c.muted)

  -- Knob at the end of the filled part, drawn last so it overlaps the ring; bigger while held
  local kx, ky = point(RING_RADIUS, math.rad(litTicks * 6))
  local r = held and KNOB_RADIUS_HELD or KNOB_RADIUS
  add('<circle cx="%.2f" cy="%.2f" r="%d" fill="%s" stroke="%s" stroke-width="3"/>', kx, ky, r, c.face, style.lit)
  add('<circle cx="%.2f" cy="%.2f" r="%.1f" fill="%s"/>', kx, ky, r / 3, style.lit)

  table.insert(parts, "</svg>")
  return table.concat(parts)
end

local function colors()
  local neutral = noctalia.getColor("on_surface") or "#ffffff"
  return {
    neutral = neutral,
    accent = noctalia.getColor("primary") or neutral,
    muted = noctalia.getColor("on_surface_variant") or neutral,
    face = noctalia.getColor("surface_container_high") or "#2b2b2b",
    track = noctalia.getColor("shadow") or "#000000",
  }
end

local function dialImage(value)
  if not dataDir then
    return ui.label({ text = timer.formatClock(value), fontSize = 48, fontWeight = "bold" })
  end
  local c = colors()
  local font = timer.fontFamily()
  -- One file per look: images are cached by path
  local look = { value, dragging and "held" or "idle", c.neutral, c.accent, c.muted, c.face, c.track, font }
  local key = table.concat(look, "-"):gsub("[^%w%-]", "")
  local path = string.format("%s/panel-%s.svg", dataDir, key)
  if not noctalia.fileExists(path) then
    noctalia.writeFile(path, dialSvg(value, c, dragging, font))
  end
  trackImage(path)
  return ui.image({ path = path, width = DIAL, height = DIAL })
end

local function dayLabel(time)
  return noctalia.tr(os.date("%Y%m%d", time) == os.date("%Y%m%d") and "panel.today" or "panel.tomorrow")
end

local function header(glyph, title, value, note, color)
  return ui.column({ gap = 2, align = "center", flexGrow = 1 }, {
    ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = glyph, size = 14, color = color }),
      ui.label({ text = title, fontSize = 12, fontWeight = "bold", color = "on_surface_variant" }),
    }),
    ui.label({ text = value, fontSize = 26, fontWeight = "bold", color = "on_surface" }),
    ui.label({ text = note, fontSize = 12, color = "on_surface_variant" }),
  })
end

local render

-- Minutes chosen by drag or wheel: saved and shared with the bar and the tile
local function pick(value)
  value = math.clamp(math.floor(value + 0.5), 1, timer.MAX_MINUTES)
  if value ~= minutes then
    minutes = timer.setMinutes(value)
    resetInputs()
  end
  render()
end

local function applyTyped()
  local h = tonumber(hoursText ~= "" and hoursText or "0")
  local m = tonumber(minutesText ~= "" and minutesText or "0")
  if not h or not m or h < 0 or m < 0 or h % 1 ~= 0 or m % 1 ~= 0 then
    return
  end
  local total = h * 60 + m
  if total >= 1 and total ~= minutes then
    minutes = timer.setMinutes(total)
    if minutes ~= total then
      -- Clamped to 23:59: show the stored time instead of what was typed
      resetInputs()
    end
    render()
  end
end

local function centerRow()
  if at then
    -- Counting down: the remaining time instead of the fields
    return ui.label({
      text = timer.formatClock(timer.remainingMinutes(at)),
      fontSize = 36, fontWeight = "bold", color = "primary", height = CENTER_ROW,
    })
  end
  local function field(key, text, placeholder, onChange)
    return ui.input({
      key = key .. "-" .. inputRev, value = text, placeholder = placeholder,
      width = 56, controlSize = "lg", fontSize = 20,
      onChange = onChange,
      onSubmit = function()
        timer.start(minutes, render)
      end,
    })
  end
  -- Hours : minutes, narrow enough to stay clear of the 15 and 45 labels
  return ui.row({ gap = 6, align = "center", height = CENTER_ROW }, {
    field("hours", hoursText, noctalia.tr("panel.hours_placeholder"), function(text)
      hoursText = text
      applyTyped()
    end),
    ui.label({ text = ":", fontSize = 22, fontWeight = "bold", color = "on_surface_variant" }),
    field("minutes", minutesText, noctalia.tr("panel.minutes_placeholder"), function(text)
      minutesText = text
      applyTyped()
    end),
  })
end

render = function()
  local value = at and timer.remainingMinutes(at) or minutes
  local shutdownAt = at or (os.time() + minutes * 60)

  local dialLayers = { dialImage(value) }
  if socketPath then
    -- Same box as the image, moved up onto it. Named handlers, not closures: a changed
    -- callback would cancel a drag that is in progress.
    table.insert(dialLayers, ui.pixelStream({
      key = "pointer", path = socketPath, width = DIAL, height = DIAL, fit = "stretch",
      translateY = -DIAL,
      onPointerDown = "onDialDown", onPointerMove = "onDialMove", onPointerUp = "onDialUp",
      onPointerCancel = "onDialCancel", onScroll = "onDialScroll",
    }))
  end
  -- The fields go over the middle of the dial, above the pointer layer so they stay
  -- clickable. The column keeps the dial's height, so the slots of the moved layers
  -- below it stay empty and nothing else shifts.
  local slotTop = DIAL * #dialLayers
  table.insert(dialLayers, ui.column({
    height = CENTER_ROW, align = "center", translateY = CENTER - CENTER_ROW / 2 - slotTop,
  }, { centerRow() }))

  panel.render(ui.column({ gap = 14, align = "stretch" }, {
    ui.row({ align = "start" }, {
      header("clock", noctalia.tr("panel.now"), os.date("%H:%M"), dayLabel(os.time()), "on_surface_variant"),
      header("power", noctalia.tr("panel.shutdown"), os.date("%H:%M", shutdownAt), dayLabel(shutdownAt), "primary"),
    }),

    ui.column({ height = DIAL, gap = 0, align = "center" }, dialLayers),

    ui.column({ gap = 2, align = "center" }, {
      ui.label({ text = timer.formatLong(value), fontSize = 22, fontWeight = "bold", color = "on_surface" }),
      ui.label({
        text = noctalia.tr(at and "panel.hint_active" or "panel.hint_idle"),
        fontSize = 12, color = "on_surface_variant",
      }),
    }),

    at and ui.button({
      text = noctalia.tr("panel.cancel"), glyph = "x", variant = "destructive", controlSize = "lg",
      onClick = function()
        timer.cancel(render)
      end,
    }) or ui.button({
      text = noctalia.tr("panel.start"), glyph = "player-play", variant = "primary", controlSize = "lg",
      onClick = function()
        timer.start(minutes, render)
      end,
    }),
  }))
end

-- Pointer position (strings "0.0000".."1.0000") -> dial coordinates
local function dialPoint(nx, ny)
  return (tonumber(nx) or 0) * DIAL - CENTER, (tonumber(ny) or 0) * DIAL - CENTER
end

-- Clockwise angle from 12 o'clock, as minutes 0..60
local function angleMinutes(dx, dy)
  local turns = math.atan2(dx, -dy) / (2 * math.pi)
  if turns < 0 then
    turns += 1
  end
  return turns * timer.MINUTES_PER_LAP
end

function onDialDown(nx, ny)
  if at then
    return
  end
  local dx, dy = dialPoint(nx, ny)
  local kx, ky = point(RING_RADIUS, math.rad(knobMinutes(minutes) * 6))
  local onKnob = math.sqrt((dx + CENTER - kx) ^ 2 + (dy + CENTER - ky) ^ 2) <= KNOB_HIT
  local distance = math.sqrt(dx * dx + dy * dy)
  if not onKnob and (distance < RING_HIT_INNER or distance > RING_HIT_OUTER) then
    return
  end
  dragging = true
  dragAngle = angleMinutes(dx, dy)
  if onKnob then
    dragValue = minutes
    render()
  else
    -- Pressed elsewhere on the ring: jump there within the current lap
    local lap = math.ceil(minutes / timer.MINUTES_PER_LAP)
    dragValue = math.max(1, (lap - 1) * timer.MINUTES_PER_LAP + dragAngle)
    pick(dragValue)
  end
end

function onDialMove(nx, ny)
  if not dragging then
    return
  end
  local angle = angleMinutes(dialPoint(nx, ny))
  -- Shortest way round, so crossing 12 o'clock adds or removes a lap
  local delta = angle - dragAngle
  if delta > timer.MINUTES_PER_LAP / 2 then
    delta -= timer.MINUTES_PER_LAP
  elseif delta < -timer.MINUTES_PER_LAP / 2 then
    delta += timer.MINUTES_PER_LAP
  end
  dragAngle = angle
  dragValue = math.clamp(dragValue + delta, 1, timer.MAX_MINUTES)
  pick(dragValue)
end

function onDialUp()
  if dragging then
    dragging = false
    render()
  end
end

function onDialCancel()
  onDialUp()
end

function onDialScroll(_dx, dy)
  local steps = tonumber(dy) or 0
  if at or dragging or steps == 0 then
    return
  end
  -- Positive dy is wheel down, like on the bar: up adds time, down removes it
  pick(math.max(timer.STEP_MINUTES, minutes - steps * timer.STEP_MINUTES))
end

local function refresh()
  local was = at
  at = timer.scheduledAt()
  if was and not at then
    -- Cancelled: show the chosen time in the fields again
    resetInputs()
  end
  render()
end

function onOpen(_context)
  startCompanion()
  minutes = timer.loadMinutes()
  resetInputs()
  panel.setWantsSecondTicks(true)
  refresh()
end

function onClose()
  dragging = false
end

function update()
  refresh()
end

noctalia.state.watch("minutes", function(value)
  if type(value) == "number" and value ~= minutes and not dragging then
    minutes = value
    resetInputs()
    render()
  end
end)
noctalia.state.watch("scheduled", function()
  refresh()
end)

-- Drop dial images left from earlier runs and old themes
if dataDir then
  for _, name in ipairs(noctalia.listDir(dataDir) or {}) do
    if name:match("^panel%-.*%.svg$") then
      noctalia.removeFile(dataDir .. "/" .. name)
    end
  end
end

startCompanion()
