local CARD_W = 360
local CARD_H = 202
local STEP = 376
local VIEW_W = 2140
local VIEW_H = 260
local SPAN = 6
local FADE_W = 420
local CENTER_SCALE = 1.12
-- The visual carousel lives in this layer, while the panel position setting
-- ("keys • Позиция") belongs to the invisible keyboard panel. Map the panel
-- position token onto layer-shell anchors: an axis with no anchor is centered
-- by the compositor, so "top_center" is just the "top" anchor.
local POSITION_ANCHORS = {
  auto = {},
  center = {},
  top_left = { "top", "left" },
  top_center = { "top" },
  top_right = { "top", "right" },
  center_left = { "left" },
  center_right = { "right" },
  bottom_left = { "bottom", "left" },
  bottom_center = { "bottom" },
  bottom_right = { "bottom", "right" },
}

local PLUGIN_ID = "type3demo/wallpaper-carousel"
local POSITION_SETTING = "plugin_settings." .. PLUGIN_ID .. ".keys_position"

local function currentPosition()
  -- The shell stores the panel position per plugin, so read it from the global
  -- config snapshot: the panel entry settings are not visible from this layer.
  local ok, position = pcall(noctalia.getSetting, POSITION_SETTING)
  if ok and type(position) == "string" and position ~= "" then
    return position
  end
  local fallback = noctalia.state.get("carousel.position")
  if type(fallback) == "string" and fallback ~= "" then
    return fallback
  end
  return "center"
end

local function isVertical()
  local ok, orientation = pcall(noctalia.getConfig, "orientation")
  return ok and orientation == "vertical"
end

local function applyPosition()
  local position = currentPosition()
  local anchors = POSITION_ANCHORS[position] or POSITION_ANCHORS.center

  if noctalia.layer and noctalia.layer.configure then
    pcall(noctalia.layer.configure, "carousel", {
      anchors = anchors,
    })
  end
end

local function configureLayout()
  local outW, outH = nil, nil
  if layer and layer.outputName then
    local ok, name = pcall(layer.outputName)
    if ok and type(name) == "string" and noctalia.outputs then
      local ok2, list = pcall(noctalia.outputs)
      if ok2 and type(list) == "table" then
        for _, o in ipairs(list) do
          if o.name == name then
            if tonumber(o.width) then outW = tonumber(o.width) end
            if tonumber(o.height) then outH = tonumber(o.height) end
          end
        end
      end
    end
  end

  local avail = (outW or 2560) - 100
  if avail > 2140 then avail = 2140 end
  if avail < 700 then avail = 700 end

  local s = avail / 2140
  local gap = math.max(10, math.floor(16 * s))
  CARD_W = math.floor(360 * s)
  CARD_H = math.floor(202 * s)

  if isVertical() then
    -- A column of cards that uses the whole output height; the viewport is only
    -- as wide as the enlarged center card needs, so as many cards fit as the
    -- screen is tall.
    local availH = (outH or 1440) - 100
    if availH < 400 then availH = 400 end
    VIEW_W = math.floor(CARD_W * CENTER_SCALE) + 16
    VIEW_H = availH
    STEP = CARD_H + gap
    -- Fade towards the top and bottom edges instead of the strip ends.
    FADE_W = math.floor(VIEW_H * 0.4)
  else
    VIEW_W = math.floor(2140 * s)
    VIEW_H = math.floor(260 * s)
    STEP = CARD_W + gap
    FADE_W = 420
  end

  if noctalia.layer and noctalia.layer.configure then
    pcall(noctalia.layer.configure, "carousel", {
      width = VIEW_W + 48,
      -- Only as tall as the carousel plus its vertical padding: with a bottom
      -- anchor the carousel then sits right at the screen edge instead of
      -- floating a hundred pixels above it.
      height = VIEW_H + 48,
    })
  end
end

local items = {}
local selected = 1
local pos = 1.0
local anim = nil
local currentPath = ""
local lastDir = ""
local scanning = false
local isOpen = false
local lastScroll = 0
local cacheDir = nil
local thumbBin = nil
local thumbPending = {}

-- Show/hide animation: the whole surface slides in from the screen edge it is
-- anchored to while fading in, and slides back out the same edge on close. A
-- Wayland surface is clipped to its own buffer, so content still outside the
-- layer box is simply not drawn - it looks like it slides out of the edge
-- instead of flying over the bar. One motion struct drives both directions.
local MOTION_MS = 160
local motion = nil
local closing = false
local hidden = false

-- Forward declarations: the motion helpers below call these, while the helpers
-- themselves are defined after the state block.
local requestClose

local function edgeOffset()
  local position = currentPosition()
  -- Short travel: the surface is clipped to its own box, so a small offset plus
  -- the fade already reads as "slides out of the edge" without the content
  -- spending the first frames invisible outside the layer.
  local dx = math.floor(VIEW_W * 0.22) + 16
  local dy = math.floor(VIEW_H * 0.22) + 16

  if isVertical() then
    -- A vertical column is anchored to a side, so it enters from that side.
    if position:find("_left$") then return -dx, 0 end
    return dx, 0
  end

  if position:find("^top_") then return 0, -dy end
  if position:find("^bottom_") then return 0, dy end
  -- A horizontally anchored strip slides in from the side it hugs.
  if position:find("_left$") then return -dx, 0 end
  if position:find("_right$") then return dx, 0 end
  return 0, dy
end

local function motionProps()
  if not motion then return 0, 0, 1 end
  local p = math.max(0, math.min(1, motion.t / motion.duration))
  local eased = 1 - (1 - p) ^ 3
  if motion.out then
    return math.floor(motion.fromX * eased), math.floor(motion.fromY * eased), 1 - eased
  end
  -- Start partly opaque so the very first frame is already on screen; a fade
  -- from zero is what makes the open feel like it lags.
  return math.floor(motion.fromX * (1 - eased)), math.floor(motion.fromY * (1 - eased)),
    0.35 + 0.65 * eased
end

local function finishHide()
  -- Mark the surface gone before closing the panel: the panel's onClose bumps
  -- hideSeq, which must not start a second slide-out on a hidden layer.
  hidden = true
  closing = false
  noctalia.state.set("carousel.visible", false)
  requestClose()
  if noctalia.layer and noctalia.layer.hide then
    pcall(noctalia.layer.hide, "carousel")
  end
end

local function startMotion(out)
  if out and (closing or hidden) then return end
  if not out then
    closing = false
    hidden = false
  end
  local x, y = edgeOffset()
  motion = { t = 0, duration = MOTION_MS, fromX = x, fromY = y, out = out }
  if out then closing = true end
  layer.setNeedsFrameTick(true)
end

local render

math.randomseed(os.time())

local function tr(key)
  return noctalia.tr(key)
end

requestClose = function()
  local seq = tonumber(noctalia.state.get("carousel.closeSeq")) or 0
  noctalia.state.set("carousel.closeSeq", seq + 1)
end

local function hideSelf()
  -- Animate out; finishHide() releases the panel and the layer afterwards.
  startMotion(true)
end

local function isImage(name)
  local lower = name:lower()
  return lower:match("%.png$") ~= nil
      or lower:match("%.jpg$") ~= nil
      or lower:match("%.jpeg$") ~= nil
      or lower:match("%.webp$") ~= nil
end

local function naturalKey(s)
  return (s:lower():gsub("%d+", function(n)
    return string.format("%08d", tonumber(n) or 0)
  end))
end

local function initCache()
  if cacheDir then return end
  local base = nil
  if noctalia.pluginDataDir then
    local ok, dir = pcall(noctalia.pluginDataDir)
    if ok and type(dir) == "string" and dir ~= "" then base = dir end
  end
  if not base then
    local home = noctalia.getenv("HOME") or "/tmp"
    base = home .. "/.cache/noctalia/wallpaper-carousel"
  end
  cacheDir = base .. "/thumbnails"
  noctalia.mkdirAll(cacheDir)

  if noctalia.commandExists("magick") then
    thumbBin = "magick"
  elseif noctalia.commandExists("convert") then
    thumbBin = "convert"
  elseif noctalia.commandExists("ffmpeg") then
    thumbBin = "ffmpeg"
  end
end

local function hashPath(path)
  local h = 2166136261
  for i = 1, #path do
    h = bit32.bxor(h, string.byte(path, i))
    local lo = bit32.band(h, 0xFFFF) * 16777619
    local hi = bit32.band(bit32.rshift(h, 16), 0xFFFF) * 16777619
    h = bit32.band(lo + bit32.lshift(hi, 16), 0xFFFFFFFF)
  end
  return string.format("%08x", h)
end

local function thumbPath(path)
  local base = path:match("([^/]+)%.[^.]+$") or "wp"
  base = base:gsub("[^%w_%-]", "_"):sub(1, 24)
  return string.format("%s/%s_%s.jpg", cacheDir, base, hashPath(path))
end

local function displayPath(item)
  initCache()
  local thumb = thumbPath(item.path)
  if noctalia.fileExists(thumb) then return thumb end
  if thumbPending[item.path] or not thumbBin then return item.path end

  thumbPending[item.path] = true
  local argv
  if thumbBin == "ffmpeg" then
    argv = {
      "ffmpeg", "-y", "-loglevel", "error", "-i", item.path,
      "-frames:v", "1",
      "-vf", "scale=640:360:force_original_aspect_ratio=decrease",
      thumb,
    }
  else
    argv = { thumbBin, item.path, "-thumbnail", "640x360>", "-quality", "85", thumb }
  end

  noctalia.runAsync(argv, function()
    thumbPending[item.path] = nil
    if isOpen then render() end
  end)

  return item.path
end

local function resolveDir()
  local configured = noctalia.getConfig("wallpaper_dir")
  if type(configured) == "string" and configured ~= "" then
    local ok, expanded = pcall(noctalia.expandPath, configured)
    if ok and type(expanded) == "string" and expanded ~= "" then return expanded end
    return configured
  end

  if noctalia.wallpaperDirectory then
    local ok, dir = pcall(noctalia.wallpaperDirectory)
    if ok and type(dir) == "string" and dir ~= "" then return dir end
  end

  if noctalia.getSetting then
    local ok, dir = pcall(noctalia.getSetting, "wallpaper.directory")
    if ok and type(dir) == "string" and dir ~= "" then
      return noctalia.expandPath(dir)
    end
  end

  local home = noctalia.getenv("HOME") or "~"
  return home .. "/Pictures/Wallpapers"
end

local function getCurrentWallpaper()
  if not noctalia.wallpaperPath then return nil end
  local outputs = {}
  if noctalia.outputs then
    local ok, list = pcall(noctalia.outputs)
    if ok and type(list) == "table" then outputs = list end
  end

  local function pathOf(output)
    if not output or not output.name then return nil end
    local ok, path = pcall(noctalia.wallpaperPath, output.name)
    if ok and type(path) == "string" and path ~= "" then return path end
    return nil
  end

  for _, output in ipairs(outputs) do
    if output.focused then
      local path = pathOf(output)
      if path then return path end
    end
  end

  for _, output in ipairs(outputs) do
    local path = pathOf(output)
    if path then return path end
  end

  local ok, path = pcall(noctalia.wallpaperPath)
  if ok and type(path) == "string" and path ~= "" then return path end
  return nil
end

local function scanDir(dir, list, depth)
  if depth > 2 then return end
  local entries = noctalia.listDir(dir)
  if not entries then return end

  for _, name in ipairs(entries) do
    if name ~= "." and name ~= ".." and name:sub(1, 1) ~= "." then
      local full = dir .. "/" .. name
      if isImage(name) then
        local clean = name:gsub("%.%w+$", "")
        list[#list + 1] = {
          path = full,
          filename = name,
          name = clean,
          sortKey = naturalKey(clean),
        }
      else
        local info = noctalia.fileInfo(full)
        if info and info.isDir then
          scanDir(full, list, depth + 1)
        end
      end
    end
  end
end

local function normalize()
  local n = #items
  if n == 0 then
    selected = 1
    pos = 1.0
    return
  end
  local shift = math.floor((selected - 1) / n) * n
  if shift ~= 0 then
    selected = selected - shift
    pos = pos - shift
  end
end

local function syncToCurrent()
  currentPath = getCurrentWallpaper() or currentPath
  anim = nil
  if #items == 0 then
    selected = 1
    pos = 1.0
    return
  end
  for i, item in ipairs(items) do
    if item.path == currentPath then
      selected = i
      pos = i
      return
    end
  end
  selected = 1
  pos = 1.0
end

local function renderIfOpen()
  if isOpen then render() end
end

local function scan(force)
  if not force and #items > 0 then
    syncToCurrent()
    renderIfOpen()
    return
  end

  scanning = true
  local dir = resolveDir()
  local list = {}
  scanDir(dir, list, 0)

  table.sort(list, function(a, b)
    if a.sortKey == b.sortKey then return a.filename < b.filename end
    return a.sortKey < b.sortKey
  end)

  items = list
  lastDir = dir
  scanning = false
  syncToCurrent()
  renderIfOpen()
end

local function animateTo(target)
  if #items == 0 then return end
  local duration = tonumber(noctalia.getConfig("animation_ms")) or 320
  if duration < 80 then duration = 80 end
  selected = target
  anim = { from = pos, to = target, t = 0, duration = duration }
  layer.setNeedsFrameTick(true)
  render()
end

local function step(delta)
  if #items == 0 then return end
  animateTo(selected + delta)
end

local function applyItem(item)
  if not item then return end
  noctalia.setWallpaper(item.path)
  currentPath = item.path

  if noctalia.getConfig("notify_on_change") ~= false then
    noctalia.notify(tr("notify.title"), tr("notify.switched") .. ": " .. item.filename)
  end

  if noctalia.getConfig("close_on_apply") == true then
    hideSelf()
  else
    render()
  end
end

local function selectedItem()
  if #items == 0 then return nil end
  return items[((selected - 1) % #items) + 1]
end

local function applySelected()
  applyItem(selectedItem())
end

local function applyRandom()
  local n = #items
  if n == 0 then return end
  if n == 1 then
    applyItem(items[1])
    return
  end

  local offset = math.random(1, n - 1)
  local targetIndex = ((selected - 1 + offset) % n) + 1
  animateTo(selected + offset)
  applyItem(items[targetIndex])
end

local function trim(text)
  return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- realpath(1) resolves symlinks, which the host API does not expose. Resolve
-- every path in one call so the answers belong to the same moment.
local function realPaths(paths, cb)
  if not noctalia.commandExists or not noctalia.commandExists("realpath") then
    cb(nil, tr("notify.no_realpath"))
    return
  end

  local argv = { "realpath", "-e", "--" }
  for _, path in ipairs(paths) do argv[#argv + 1] = path end

  local started = noctalia.runAsync(argv, function(result)
    if result.exitCode ~= 0 then
      local message = trim(result.stderr)
      cb(nil, message ~= "" and message or "realpath failed")
      return
    end
    local resolved = {}
    for line in (result.stdout or ""):gmatch("[^\r\n]+") do
      resolved[#resolved + 1] = line
    end
    if #resolved < #paths then
      cb(nil, "realpath failed")
      return
    end
    cb(resolved)
  end)

  if not started then cb(nil, "realpath failed") end
end

local function insideRoot(target, root)
  if target == root then return true end
  local prefix = root:sub(-1) == "/" and root or (root .. "/")
  return target:sub(1, #prefix) == prefix
end

local function trashFile(path, root, cb)
  -- Deletion acts on the file a path resolves to: a scanned subfolder can be a
  -- symlink pointing anywhere, and gio or a rename would then move a wallpaper
  -- that lives outside the configured folder (and one the carousel only lists
  -- by its link path). Refuse anything whose real path leaves the root.
  realPaths({ path, root }, function(resolved, err)
    if not resolved then
      cb(false, err)
      return
    end
    if not insideRoot(resolved[1], resolved[2]) then
      cb(false, tr("notify.delete_outside"))
      return
    end

    -- gio moves the file to the XDG trash, so Alt+D stays undoable from the
    -- file manager.
    if noctalia.commandExists and noctalia.commandExists("gio") then
      noctalia.runAsync({ "gio", "trash", path }, function(result)
        cb(result.exitCode == 0, trim(result.stderr))
      end)
      return
    end

    -- Without gio the file is parked next to the original instead of being
    -- deleted for good. renameFile replaces an existing destination, so the
    -- first free suffix is used and an earlier parked copy is never lost.
    local parked = path .. ".trashed"
    local n = 1
    while noctalia.fileExists(parked) do
      parked = string.format("%s.trashed.%d", path, n)
      n = n + 1
    end
    local ok, renameErr = noctalia.renameFile(path, parked)
    cb(ok, renameErr)
  end)
end

local function deleteSelected()
  local count = #items
  if count == 0 then return end

  local item = items[((selected - 1) % count) + 1]
  if not item then return end

  trashFile(item.path, lastDir ~= "" and lastDir or resolveDir(), function(ok, err)
    if not ok then
      noctalia.notify(tr("notify.title"), tr("notify.delete_failed") .. ": " .. tostring(err))
      return
    end

    initCache()
    local thumb = thumbPath(item.path)
    if noctalia.fileExists(thumb) then pcall(noctalia.removeFile, thumb) end

    for i, candidate in ipairs(items) do
      if candidate.path == item.path then
        table.remove(items, i)
        break
      end
    end

    local wasCurrent = item.path == currentPath
    if #items == 0 then
      selected = 1
      pos = 1.0
      currentPath = ""
    else
      if selected > #items then selected = #items end
      normalize()
      pos = selected
      -- Do not leave the desktop pointing at a file that just went to the trash.
      if wasCurrent then
        local nextItem = items[((selected - 1) % #items) + 1]
        if nextItem then
          noctalia.setWallpaper(nextItem.path)
          currentPath = nextItem.path
        end
      end
    end

    noctalia.notify(tr("notify.title"), tr("notify.deleted") .. ": " .. item.filename)
    renderIfOpen()
  end)
end

render = function()
  local shiftX, shiftY, appearOpacity = motionProps()

  if scanning then
    layer.render(ui.column({
      align = "center",
      justify = "center",
      flexGrow = 1,
      gap = 14,
      padding = 40,
      translateX = shiftX,
      translateY = shiftY,
      opacity = appearOpacity,
    }, {
      ui.glyph({ name = "loader-2", size = 36, color = "primary" }),
    }))
    return
  end

  if #items == 0 then
    layer.render(ui.column({
      padding = 24,
      gap = 10,
      align = "center",
      justify = "center",
      flexGrow = 1,
      translateX = shiftX,
      translateY = shiftY,
      opacity = appearOpacity,
    }, {
      ui.glyph({ name = "photo-off", size = 52, color = "on_surface_variant" }),
    }))
    return
  end

  local n = #items
  local base = math.floor(pos)
  local cards = {}
  -- The same carousel, laid out along one axis: a row for horizontal, a column
  -- for vertical. Everything below works in that axis' pixels.
  local vertical = isVertical()
  local along = vertical and CARD_H or CARD_W
  local span = vertical and VIEW_H or VIEW_W

  for k = base - SPAN, base + SPAN do
    local idx = ((k - 1) % n + n) % n + 1
    local item = items[idx]
    local delta = k - pos
    local distance = math.min(math.abs(delta), SPAN)
    -- The focused card is slightly larger than its neighbours; the size falls
    -- off smoothly with the distance from the center.
    local scale = 1.0 - 0.10 * distance + (CENTER_SCALE - 1.0) * math.max(0, 1 - distance)
    scale = math.max(0.55, scale)
    local layoutOffset = (k - (base - SPAN)) * along
    local offset = span / 2 + delta * STEP - along / 2
    local isCenter = math.abs(delta) < 0.5
    local isCurrent = item.path == currentPath

    -- Fade the previews towards the edges of the carousel by lowering the
    -- opacity of the whole card. A single node per card keeps the render
    -- cheap (no slicing/clipping, which used to cause noticeable lag).
    local centerPos = offset + along / 2
    local d
    if centerPos < span / 2 then
      d = centerPos
    else
      d = span - centerPos
    end
    local opacity = 1
    if d < FADE_W then
      local t = math.max(0, math.min(1, d / FADE_W))
      opacity = t * t * (3 - 2 * t)
    end

    local children = {
      ui.image({
        key = "img-" .. k,
        path = displayPath(item),
        width = CARD_W,
        height = CARD_H,
        fit = "cover",
        radius = 16,
        border = isCenter and "primary" or (isCurrent and "primary/0.6" or "outline_variant/0.5"),
        borderWidth = isCenter and 3 or (isCurrent and 2 or 1),
      }),
    }

    cards[#cards + 1] = ui.column({
      key = "card-" .. k,
      width = CARD_W,
      height = CARD_H,
      align = "center",
      gap = 8,
      -- Paint-only offsets: cards keep their flex slot and are shifted onto the
      -- arc, so hit-testing follows the painted position.
      translateX = vertical and 0 or (offset - layoutOffset),
      translateY = vertical and (offset - layoutOffset) or 0,
      scale = scale,
      opacity = opacity,
      onClick = function()
        if isCenter then
          applyItem(item)
        else
          animateTo(k)
        end
      end,
    }, children)
  end

  local viewport
  if vertical then
    viewport = ui.column({
      key = "viewport-v",
      width = VIEW_W,
      height = VIEW_H,
      align = "center",
      justify = "start",
      clip = true,
    }, cards)
  else
    viewport = ui.row({
      key = "viewport-h",
      width = VIEW_W,
      height = VIEW_H,
      align = "center",
      justify = "start",
      clip = true,
    }, cards)
  end
  layer.render(ui.column({
    padding = 24,
    align = "center",
    justify = "center",
    width = "fill",
    height = "fill",
    translateX = shiftX,
    translateY = shiftY,
    opacity = appearOpacity,
  }, {
    viewport,
  }))
end

function onFrameTick(deltaMs)
  local dt = tonumber(deltaMs) or 16
  local dirty = false
  local hideNow = false

  if motion then
    motion.t = motion.t + dt
    if motion.t >= motion.duration then
      if motion.out then
        motion = nil
        hideNow = true
      else
        motion = nil
      end
    end
    dirty = true
  end

  if anim then
    anim.t = anim.t + dt
    local progress = anim.t / anim.duration

    if progress >= 1 then
      pos = anim.to
      anim = nil
      normalize()
    else
      local eased = 1 - (1 - progress) ^ 3
      pos = anim.from + (anim.to - anim.from) * eased
    end
    dirty = true
  end

  if dirty then render() end
  if hideNow then finishHide() end
end

local lastPosition = noctalia.state.get("carousel.position")

noctalia.state.watch("carousel.position", function(value)
  if value == lastPosition then return end
  lastPosition = value
  applyPosition()
end)

local lastSeq = tonumber(noctalia.state.get("carousel.seq")) or 0
noctalia.state.watch("carousel.seq", function(value)
  local seq = tonumber(value) or 0
  if seq == lastSeq then return end
  lastSeq = seq
  local action = noctalia.state.get("carousel.action")
  if action == "prev" then
    step(-1)
  elseif action == "next" then
    step(1)
  elseif action == "apply" then
    applySelected()
  elseif action == "random" then
    applyRandom()
  elseif action == "delete" then
    deleteSelected()
  end
end)

-- The panel entry cannot animate a layer it does not own, so it asks for a hide
-- by bumping this counter; the slide-out runs here and hides the layer itself.
local lastHideSeq = tonumber(noctalia.state.get("carousel.hideSeq")) or 0
noctalia.state.watch("carousel.hideSeq", function(value)
  local seq = tonumber(value) or 0
  if seq == lastHideSeq then return end
  lastHideSeq = seq
  startMotion(true)
end)

function onScroll(axis, steps)
  if axis ~= "vertical" or #items == 0 then return end
  local now = noctalia.nowMs()
  if now - lastScroll < 90 then return end
  lastScroll = now
  step((steps or 0) > 0 and 1 or -1)
end

function onConfigChanged()
  -- Orientation changes the viewport axis and the layer box, so re-derive the
  -- geometry before the next render.
  configureLayout()
  applyPosition()
  scan(true)
end

isOpen = true
configureLayout()
applyPosition()
-- The layer runtime is recreated on every show, so this top-level assignment is
-- what replays the slide-in each time the panel opens.
startMotion(false)
scan(true)
layer.setNeedsFrameTick(true)
