--!nonstrict
-- Typing Stats - interactive heatmap panel.
--
-- A month calendar in the style of the control-center calendar. Every day is
-- filled with the theme accent at an intensity based on that day's typed
-- characters; hovering a day shows the date and the exact count. Month changes
-- crossfade (the declarative UI has no transforms, so the grid fades out and the
-- new month fades in) and hovering a day animates its fill and outline.

local viewYear = tonumber(os.date("%Y")) or 2026
local viewMonth = tonumber(os.date("%m")) or 1

local days = {}
local totalChars = 0
local todayChars = 0
local fileMtime = 0
local loadedOnce = false
local lastSignature = nil

local DEFAULT_THRESHOLDS = { 500, 1000, 2000, 5000 }
local function parseThresholds(raw)
  local values = {}
  if type(raw) == "string" then
    for part in string.gmatch(raw, "[^,;%s]+") do
      local value = tonumber(part)
      if value ~= nil and value > 0 then
        values[#values + 1] = math.floor(value + 0.5)
      end
    end
  end
  if #values < 4 then
    return { DEFAULT_THRESHOLDS[1], DEFAULT_THRESHOLDS[2], DEFAULT_THRESHOLDS[3], DEFAULT_THRESHOLDS[4] }
  end
  table.sort(values)
  return { values[1], values[2], values[3], values[4] }
end

local thresholds = parseThresholds(noctalia.getConfig("thresholds"))

local MONTH_MS = 180
local HOVER_MS = 120

local monthAnim = nil
local gridOpacity = 1
local hoverDate = nil
local hoverAmount = 0
local hoverTarget = 0

local function todayKey()
  return os.date("%Y-%m-%d")
end

local function clamp01(value)
  if value < 0 then
    return 0
  end
  if value > 1 then
    return 1
  end
  return value
end

local function smoothstep(value)
  local t = clamp01(value)
  return t * t * (3 - 2 * t)
end

local function numberText(value)
  local text = tostring(math.floor(value))
  local out = ""
  while #text > 3 do
    out = "," .. text:sub(-3) .. out
    text = text:sub(1, -4)
  end
  return text .. out
end

local function hexToRgb(hex)
  local value = string.gsub(hex or "", "#", "")
  if #value < 6 then
    return 0, 0, 0
  end
  return tonumber(value:sub(1, 2), 16) or 0,
    tonumber(value:sub(3, 4), 16) or 0,
    tonumber(value:sub(5, 6), 16) or 0
end

local function rgbToHex(r, g, b)
  local function part(value)
    local v = math.max(0, math.min(255, math.floor(value + 0.5)))
    return string.format("%02X", v)
  end
  return "#" .. part(r) .. part(g) .. part(b)
end

local function mixHex(a, b, t)
  local ar, ag, ab = hexToRgb(a)
  local br, bg, bb = hexToRgb(b)
  local k = clamp01(t)
  return rgbToHex(ar + (br - ar) * k, ag + (bg - ag) * k, ab + (bb - ab) * k)
end

local function withAlpha(hex, alpha)
  local r, g, b = hexToRgb(hex)
  local a = math.max(0, math.min(255, math.floor(clamp01(alpha) * 255 + 0.5)))
  return string.format("#%02X%02X%02X%02X", r, g, b, a)
end

-- Theme colors are read once per panel runtime; the theme rarely changes while
-- the panel is open, and the panel reloads on a shell theme change anyway.
local surfaceHex = noctalia.getColor("surface") or "#1e1e2e"
local primaryHex = noctalia.getColor("primary") or "#89b4fa"
local containerHex = noctalia.getColor("surface_container") or "#313244"
local onSurfaceHex = noctalia.getColor("on_surface") or "#cdd6f4"

local BASE = {
  containerHex,
  mixHex(surfaceHex, primaryHex, 0.20),
  mixHex(surfaceHex, primaryHex, 0.40),
  mixHex(surfaceHex, primaryHex, 0.65),
  primaryHex,
}
local TEXT = {
  "on_surface_variant",
  "on_surface",
  "on_surface",
  "on_primary",
  "on_primary",
}

local function dataPath()
  local dir = noctalia.pluginDataDir()
  if dir == nil or dir == "" then
    return nil
  end
  return dir .. "/stats.json"
end

local function dataSignature()
  local path = dataPath()
  local info = path ~= nil and noctalia.fileInfo(path) or nil
  local summary = noctalia.state.get("stats")
  local mtime = info ~= nil and info.mtime or 0
  local today = type(summary) == "table" and tonumber(summary.today_chars) or -1
  local total = type(summary) == "table" and tonumber(summary.total_chars) or -1
  return tostring(mtime) .. ":" .. tostring(today) .. ":" .. tostring(total)
end

local function loadData()
  local path = dataPath()
  local info = path ~= nil and noctalia.fileInfo(path) or nil
  local mtime = info ~= nil and info.mtime or 0

  if path ~= nil and (mtime ~= fileMtime or not loadedOnce) then
    local text = noctalia.readFile(path)
    if text ~= nil then
      local ok, data = pcall(noctalia.json.decode, text)
      if ok and type(data) == "table" then
        local loaded = {}
        if type(data.days) == "table" then
          for date, count in pairs(data.days) do
            if type(date) == "string" and type(count) == "number" and count > 0 then
              loaded[date] = math.floor(count + 0.5)
            end
          end
        end
        days = loaded
        totalChars = math.floor((tonumber(data.chars) or 0) + 0.5)
      end
    end
    fileMtime = mtime
    loadedOnce = true
  end

  local summary = noctalia.state.get("stats")
  if type(summary) == "table" then
    totalChars = math.floor((tonumber(summary.total_chars) or totalChars) + 0.5)
    if type(summary.thresholds) == "table" then
      local t1 = tonumber(summary.thresholds[1])
      local t2 = tonumber(summary.thresholds[2])
      local t3 = tonumber(summary.thresholds[3])
      local t4 = tonumber(summary.thresholds[4])
      if t1 ~= nil and t2 ~= nil and t3 ~= nil and t4 ~= nil then
        thresholds = { t1, t2, t3, t4 }
      end
    end
    local today = todayKey()
    local live = tonumber(summary.today_chars)
    if live ~= nil then
      days[today] = math.floor(live + 0.5)
    end
  end

  todayChars = days[todayKey()] or 0
end

local function levelOf(count)
  if count <= 0 or count < thresholds[1] then
    return 0
  elseif count < thresholds[2] then
    return 1
  elseif count < thresholds[3] then
    return 2
  elseif count < thresholds[4] then
    return 3
  end
  return 4
end

local beginHover
local endHover
local buildTree

beginHover = function(date)
  if hoverDate == date then
    hoverTarget = 1
    return
  end
  hoverDate = date
  hoverAmount = 0
  hoverTarget = 1
  panel.setNeedsFrameTick(true)
end

endHover = function(date)
  if hoverDate ~= date then
    return
  end
  hoverTarget = 0
  panel.setNeedsFrameTick(true)
end

local function startMonth(delta)
  if monthAnim ~= nil then
    return
  end
  local year = viewYear
  local month = viewMonth + delta
  if month < 1 then
    month = 12
    year = year - 1
  elseif month > 12 then
    month = 1
    year = year + 1
  end
  monthAnim = {
    start = noctalia.nowMs(),
    year = year,
    month = month,
    switched = false,
  }
  panel.setNeedsFrameTick(true)
end

buildTree = function()
  local first = os.time({ year = viewYear, month = viewMonth, day = 1, hour = 12 })
  local firstInfo = os.date("*t", first)
  local offset = ((tonumber(firstInfo.wday) or 1) + 5) % 7
  local gridStart = first - offset * 86400
  local monthDays = os.date("*t", os.time({ year = viewYear, month = viewMonth + 1, day = 0, hour = 12 })).day
  local today = todayKey()

  local monthTotal = 0
  for index = 0, monthDays - 1 do
    local date = os.date("%Y-%m-%d", first + index * 86400)
    monthTotal = monthTotal + (days[date] or 0)
  end

  local weekdayCells = {}
  for column = 0, 6 do
    weekdayCells[#weekdayCells + 1] = ui.label({
      key = "wd-" .. tostring(column),
      text = os.date("%a", gridStart + column * 86400),
      flexGrow = 1,
      textAlign = "center",
      fontSize = 11,
      color = "on_surface_variant",
      fontWeight = "medium",
    })
  end

  local hoverEase = smoothstep(hoverAmount)
  local weekRows = {}
  for week = 0, 5 do
    local cells = {}
    for column = 0, 6 do
      local cellTime = gridStart + (week * 7 + column) * 86400
      local info = os.date("*t", cellTime)
      local date = os.date("%Y-%m-%d", cellTime)
      local count = days[date] or 0
      local inMonth = info.year == viewYear and info.month == viewMonth
      local level = levelOf(count)
      local isToday = date == today
      local amount = date == hoverDate and hoverEase or 0

      local textColor = TEXT[level + 1]
      if not inMonth then
        textColor = level >= 3 and "on_primary/0.55" or "on_surface_variant/0.55"
      end

      local fill = BASE[level + 1]
      if amount > 0 then
        fill = mixHex(fill, onSurfaceHex, 0.12 * amount)
      end
      local border = isToday and onSurfaceHex or withAlpha(onSurfaceHex, 0.55 * amount)
      local borderWidth = isToday and 1 or (1.2 * amount)

      cells[#cells + 1] = ui.column({
        key = date,
        flexGrow = 1,
        height = 38,
        fill = fill,
        radius = 8,
        align = "center",
        justify = "center",
        border = border,
        borderWidth = borderWidth,
        tooltip = noctalia.tr("panel.day_tooltip", {
          date = date,
          count = numberText(count),
        }),
        onHover = function(state, key)
          if state == "true" then
            beginHover(key)
          else
            endHover(key)
          end
        end,
      }, {
        ui.label({
          text = tostring(info.day),
          fontSize = 12,
          fontWeight = "medium",
          color = textColor,
        }),
      })
    end
    weekRows[#weekRows + 1] = ui.row({
      key = "week-" .. tostring(week),
      height = 38,
      gap = 4,
    }, cells)
  end

  local legend = {
    ui.label({ text = noctalia.tr("panel.less"), fontSize = 10, color = "on_surface_variant" }),
  }
  for index = 1, 5 do
    legend[#legend + 1] = ui.box({
      width = 10,
      height = 10,
      radius = 2,
      fill = BASE[index],
    })
  end
  legend[#legend + 1] = ui.label({ text = noctalia.tr("panel.more"), fontSize = 10, color = "on_surface_variant" })

  local children = {
    ui.row({ align = "center", height = 28 }, {
      ui.label({
        text = noctalia.tr("panel.title"),
        fontSize = 16,
        fontWeight = "bold",
        flexGrow = 1,
      }),
      ui.button({
        glyph = "x",
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          panel.close()
        end,
      }),
    }),
    ui.label({
      text = noctalia.formatTime(noctalia.dateFormat(), os.time()),
      fontSize = 11,
      color = "on_surface_variant",
    }),
    ui.row({ align = "center", height = 32 }, {
      ui.button({
        glyph = "chevron-left",
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          startMonth(-1)
        end,
      }),
      ui.label({
        text = os.date("%B %Y", first),
        opacity = gridOpacity,
        flexGrow = 1,
        textAlign = "center",
        fontSize = 16,
        fontWeight = "bold",
      }),
      ui.button({
        glyph = "chevron-right",
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          startMonth(1)
        end,
      }),
    }),
    ui.row({ height = 16, gap = 4 }, weekdayCells),
    ui.column({ key = "grid", gap = 4, opacity = gridOpacity }, weekRows),
    ui.label({
      text = noctalia.tr("panel.summary", {
        month = numberText(monthTotal),
        today = numberText(todayChars),
      }),
      opacity = gridOpacity,
      fontSize = 11,
      color = "on_surface_variant",
    }),
    ui.row({ align = "center", height = 30, gap = 4 }, legend),
  }

  panel.render(ui.column({ gap = 6, padding = 16 }, children))
end

local function render()
  loadData()
  buildTree()
  lastSignature = dataSignature()
end

function onOpen(_context)
  local now = os.date("*t")
  viewYear = tonumber(now.year) or viewYear
  viewMonth = tonumber(now.month) or viewMonth
  loadedOnce = false
  fileMtime = 0
  monthAnim = nil
  gridOpacity = 1
  hoverDate = nil
  hoverAmount = 0
  hoverTarget = 0
  loadData()
  buildTree()
  lastSignature = dataSignature()
  panel.setWantsSecondTicks(true)
end

function update()
  local signature = dataSignature()
  if signature ~= lastSignature then
    render()
  end
end

function onFrameTick(deltaMs)
  local dt = tonumber(deltaMs) or 16
  local now = noctalia.nowMs()
  local hadAnimation = monthAnim ~= nil or hoverDate ~= nil

  if monthAnim ~= nil then
    local t = (now - monthAnim.start) / MONTH_MS
    if t < 0.5 then
      gridOpacity = 1 - smoothstep(t / 0.5)
    else
      if not monthAnim.switched then
        viewYear = monthAnim.year
        viewMonth = monthAnim.month
        monthAnim.switched = true
      end
      gridOpacity = smoothstep((t - 0.5) / 0.5)
    end
    if t >= 1 then
      monthAnim = nil
      gridOpacity = 1
    end
  end

  if hoverDate ~= nil then
    if hoverAmount < hoverTarget then
      hoverAmount = math.min(hoverTarget, hoverAmount + dt / HOVER_MS)
    elseif hoverAmount > hoverTarget then
      hoverAmount = math.max(hoverTarget, hoverAmount - dt / HOVER_MS)
    end
    if hoverAmount == hoverTarget and hoverTarget == 0 then
      hoverDate = nil
    end
  end

  if hadAnimation then
    buildTree()
  end

  if monthAnim == nil and hoverDate == nil then
    panel.setNeedsFrameTick(false)
  end
end
