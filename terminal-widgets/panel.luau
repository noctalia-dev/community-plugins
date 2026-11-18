--!nonstrict
-- Launcher panel: one card per terminal widget.
--
-- Each card opens (or focuses) its floating terminal. The header carries the
-- actions: open all, rotate the windows, close them all and edit the widget
-- list.
--
-- Each window's position and size come from `layouts`; the "open all" button
-- also rotates the already-open windows among themselves.

local util = require("./lib/util.luau")
local defaults = require("./lib/defaults.luau")
local layoutLib = require("./lib/layout.luau")
local storeLib = require("./lib/store.luau")
local win = require("./lib/windows.luau")
local preview = require("./lib/preview.luau")
local gifLib = require("./lib/gif.luau")
local outputLib = require("./lib/output.luau")
local brainLib = require("./lib/brain.luau")

-- Random seed initialized once when the plugin loads.
math.randomseed(noctalia.nowMs() + (os.time() or 0) * 1000)

local DEBOUNCE_MS = 700
-- Real usable width of the scroll area (without the sidebar gutter). The
-- panel is 520 logical px; after subtracting the padding and the gap reserved
-- by the scroll, about 465 px remain. Using this value prevents a single
-- column from overflowing the panel a little.
local SCROLL_CONTENT_WIDTH = 465
local PANEL_PADDING = 8
local CARD_GAP = 6
local CARD_PADDING = 5
-- Thumbnail ratio relative to the card width. A smaller value = more
-- horizontal (more rectangular) cards.
local PREVIEW_RATIO = 0.5
local MAX_PREVIEW_HEIGHT = 120
-- Tolerance margin: two windows that touch (1-2 px) do not count as
-- overlapping, so a configured position is not moved by a slight touch.
local OVERLAP_TOLERANCE = 4

-- Simple random number generator that does not depend on math.random
-- (which may not behave deterministically in Noctalia's Luau environment).
-- It uses nowMs + a counter so each call gives a
-- different value.
local _randCounter = 0
local function randomRange(minVal, maxVal)
  local range = maxVal - minVal + 1
  if range <= 0 then
    return minVal
  end
  _randCounter = _randCounter + 1
  local seed = (noctalia.nowMs() or 0) + _randCounter * 7919
  seed = (seed * 1103515245 + 12345) % 2147483648
  return minVal + (seed % range)
end

local cfg = {
  terminal = "kitty",
  width = 900,
  height = 830,
  x = 120,
  y = 140,
  margin = 16,
  output = "",
  closeOnLaunch = false,
  reuseExisting = true,
  rotation = "clockwise",
  rotationSizes = true,
  columns = 2,
  cardPreview = "auto",
  previewInterval = 3000,
  fallbackMode = "random",
  fallbackRandomResize = false,
}

local state = {
  commands = {},
  layouts = {},
  store = nil,
  windows = {},
  thumbUsed = {},
  clients = {},
  classNames = {},
  frames = {},
  gifAnim = {},
  captureAnim = {},
  -- Last real size of each window (kept when "Change size too" is off).
  -- The size is used when repositioning an open widget.
  lastSize = {},
  -- Paths of each widget's recent captures (GIF-like animation).
  recentFrames = {},
  -- Files dropped from the capture list while the UI tree still used them:
  -- they cannot be deleted until the tree releases them.
  pendingDrop = {},
  capturing = false,
  lastCapture = 0,
  tick = 0,
  editing = false,
  editTarget = nil,
  editSession = 0,
  form = { name = "", command = "", layout = "", thumb = "" },
  lastLaunch = {},
  launching = {},
  rotating = false,
  open = false,
  -- Brain toggle and memory re-read from disk (written by the service).
  brain = false,
  -- ABSOLUTE rectangle the plugin last imposed on each window.
  applied = {},
  -- Widgets whose layout was just written in the form (this edit session):
  -- their layout wins and is not overwritten by live geometry.
  formLayouts = {},
}

-- The functions reference each other (a card calls render() and render()
-- draws the cards), so they are declared before being defined.
local render
local card
local header
local editorCard
local launch
local startEditing
local deleteWidget
local syncFrameTicks
local saveForm
local refreshWindows
local captureThumbs
local openAll
local rotateWindows
local closeAllWindows

local function tr(key, args)
  return noctalia.tr(key, args)
end

local function append(list, node)
  if node ~= nil then
    table.insert(list, node)
  end
  return list
end

-- ---------------------------------------------------------------- settings --

local function loadConfig()
  -- (Re)initialize the random generator so each panel session produces
  -- different positions in fallbackMode = "random".
  math.randomseed(noctalia.nowMs() + (os.time() or 0) * 1000)
  cfg.terminal = tostring(noctalia.getConfig("terminal") or "kitty")
  cfg.width = tonumber(noctalia.getConfig("width")) or 900
  cfg.height = tonumber(noctalia.getConfig("height")) or 520
  cfg.x = tonumber(noctalia.getConfig("x")) or 120
  cfg.y = tonumber(noctalia.getConfig("y")) or 140
  cfg.margin = tonumber(noctalia.getConfig("margin")) or 16

  local output = util.trim(noctalia.getConfig("output") or "")
  if output:lower() == "focused" then
    output = ""
  end
  cfg.output = output

  cfg.closeOnLaunch = noctalia.getConfig("close_on_launch") == true
  cfg.reuseExisting = noctalia.getConfig("reuse_existing") ~= false
  cfg.rotation = tostring(noctalia.getConfig("rotation") or "clockwise")
  cfg.rotationSizes = noctalia.getConfig("rotation_sizes") == true
  cfg.columns = math.floor(util.clamp(tonumber(noctalia.getConfig("columns")) or 2, 1, 3))
  cfg.cardPreview = tostring(noctalia.getConfig("card_preview") or "auto")
  -- preview_interval is stored in milliseconds (the manifest declares it that way).
  cfg.previewInterval = math.floor(util.clamp(tonumber(noctalia.getConfig("preview_interval")) or 3000, 500, 60000))
  cfg.fallbackMode = tostring(noctalia.getConfig("fallback_mode") or "random")
  cfg.fallbackRandomResize = noctalia.getConfig("fallback_random_resize") == true
end

local function widgetNames()
  return util.sortedKeys(state.commands)
end

-- Merge defaults + Settings + own store and apply deletions.
local function loadWidgets()
  local base = defaults.load()
  state.store = state.store or storeLib.load()

  -- Combine defaults + store (no Settings config)
  local combinedRemoved = {}
  local seen = {}
  for _, name in ipairs(state.store.removed or {}) do
    if not seen[name] then
      table.insert(combinedRemoved, name)
      seen[name] = true
    end
  end

  state.commands, state.thumbs = storeLib.merge(
    base.commands,
    nil,  -- no Settings config
    state.store.commands,
    combinedRemoved,
    base.thumbs or {},
    nil,  -- no config thumbs
    state.store.thumbs
  )
  state.layouts = storeLib.merge(
    base.layouts,
    nil,  -- no config
    state.store.layouts,
    combinedRemoved
  )

  -- A custom thumbnail only counts if the file exists. This way an old or
  -- invented path does not appear in the editor or get shown by default.
  local validThumbs = {}
  for name, path in pairs(state.thumbs or {}) do
    if type(path) == "string" and util.trim(path) ~= "" then
      local info = noctalia.fileInfo(path)
      if type(info) == "table" and tonumber(info.size or 0) > 0 then
        validThumbs[name] = path
      end
    end
  end
  state.thumbs = validThumbs

  noctalia.log("terminal-widgets: widgets -> " .. table.concat(widgetNames(), ", "))
end

-- The panel caches the store on startup, but brain memory is written to disk
-- by the service: it is re-read right before use.
local function refreshBrain()
  local data = storeLib.loadBrain()
  state.brain = data.brain == true
  state.store = state.store or {}
  state.store.brainGeometry = data.brainGeometry or {}
end

local function classMap()
  local map = {}
  for _, name in ipairs(widgetNames()) do
    local class = util.classFor(name)
    if map[class] ~= nil then
      -- Two names that normalize to the same class share a class: their
      -- windows would be confused. It is logged, but operation continues.
      noctalia.log(
        string.format(
          "terminal-widgets: '%s' y '%s' comparten la clase %s",
          map[class],
          name,
          class
        )
      )
    end
    map[class] = name
  end
  return map
end

-- --------------------------------------------------------------- geometry --

-- Output box where the widget is placed (single source: lib/output.luau).
local function outputGeometry()
  local box = outputLib.outputBox(cfg)
  return box.width, box.height, box.name
end

local function resolveGeometry(name)
  local spec = layoutLib.parseLayout(state.layouts[name])
  local width = cfg.width
  local height = cfg.height
  local custom = false
  local dx = 0
  local dy = 0
  local anchor = nil
  local auto = false

  if spec ~= nil and spec.valid then
    width = spec.width or width
    height = spec.height or height
    custom = spec.custom == true
    dx = spec.dx or 0
    dy = spec.dy or 0
    anchor = spec.anchor
    auto = spec.auto == true
  else
    -- Without an explicit layout: the widget enters automatic mode, so
    -- fallbackMode "random" can place it in a free position.
    auto = true
  end

  local screenWidth, screenHeight, outputName = outputGeometry()

  -- A size larger than the screen (a mistake when writing the layout) would
  -- leave the window out of view, so it is clipped.
  width = math.max(100, math.min(math.floor(width), screenWidth))
  height = math.max(50, math.min(math.floor(height), screenHeight))

  local x
  local y

  if custom then
    x = math.floor(dx)
    y = math.floor(dy)
  else
    if anchor ~= nil then
      x, y = layoutLib.anchorPosition(anchor, width, height, screenWidth, screenHeight, cfg.margin)
    else
      x = math.floor(cfg.x)
      y = math.floor(cfg.y)
    end
    x = x + math.floor(dx)
    y = y + math.floor(dy)
  end

  return {
    x = x,
    y = y,
    width = width,
    height = height,
    output = outputName,
    anchor = anchor,
    custom = custom,
    auto = auto,
  }
end

-- Effective geometry of a widget: with the brain on, the memory of the last
-- manual position wins over the official layout. Without an entry (or with
-- the brain off) it behaves exactly like `resolveGeometry`.
local function geometryFor(name)
  local geometry = resolveGeometry(name)
  if state.brain ~= true then
    return geometry
  end
  local memory = (state.store and state.store.brainGeometry or {})[util.classFor(name)]
  if type(memory) ~= "string" then
    return geometry
  end
  local box = outputLib.outputBox(cfg)
  local remembered = brainLib.geometryFromMemory(memory, box.width, box.height, cfg.margin)
  if remembered == nil then
    return geometry
  end
  geometry.x = remembered.x
  geometry.y = remembered.y
  geometry.width = math.max(100, math.min(remembered.width, box.width))
  geometry.height = math.max(50, math.min(remembered.height, box.height))
  geometry.anchor = nil
  geometry.auto = false
  geometry.remembered = true
  return geometry
end

-- Publish the rectangle the plugin just imposed (ABSOLUTE coordinates:
-- `hyprctl clients -j` returns absolute `at`/`size` and the service compares
-- against that). This way the service does not memorize what the plugin moved.
local function publishImposed(name, rect)
  state.applied[name] = { x = rect.x, y = rect.y, w = rect.w, h = rect.h }
  local shared = noctalia.state
  if shared == nil then
    return
  end
  local now = noctalia.nowMs()
  local pruned = {}
  local ok, current = pcall(shared.get, "imposed")
  if ok and type(current) == "table" then
    for class, entry in pairs(current) do
      if type(entry) == "table" and (now - (entry.at or 0)) <= brainLib.IMPOSED_TTL_MS then
        pruned[class] = entry
      end
    end
  end
  pruned[util.classFor(name)] = {
    x = math.floor(rect.x),
    y = math.floor(rect.y),
    w = math.floor(rect.w),
    h = math.floor(rect.h),
    at = now,
  }
  pcall(shared.set, "imposed", pruned)
end

-- Same as `publishImposed`, but from a geometry relative to the output box
-- (the format `resolveGeometry` handles).
local function noteImposed(name, geometry)
  local box = outputLib.outputBox(cfg)
  publishImposed(name, {
    x = (box.x or 0) + geometry.x,
    y = (box.y or 0) + geometry.y,
    w = geometry.width,
    h = geometry.height,
  })
end

local function layoutText(name)
  local raw = state.layouts[name]
  if type(raw) ~= "string" or util.trim(raw) == "" then
    return tr("layout_global", { width = math.floor(cfg.width), height = math.floor(cfg.height) })
  end

  local spec = layoutLib.parseLayout(raw)
  if spec == nil or not spec.valid then
    return tr("layout_invalid")
  end

  local width = spec.width or math.floor(cfg.width)
  local height = spec.height or math.floor(cfg.height)
  if spec.auto then
    return string.format("%s · %d×%d", tr("layout_auto"), width, height)
  end
  if spec.custom then
    return string.format(
      "%s · %d×%d · %d,%d",
      tr("layout_custom"),
      width,
      height,
      math.floor(spec.dx or 0),
      math.floor(spec.dy or 0)
    )
  end

  return string.format("%s · %d×%d", spec.anchor, width, height)
end

-- ------------------------------------------------------------- windows --

local function findByClass(clients, class)
  for _, client in ipairs(clients or {}) do
    if client.class == class then
      return client
    end
  end
  return nil
end

-- Find a random free position on the monitor for a given geometry.
-- Only used in fallbackMode = "random".
-- Returns x, y or nil, nil if there is no free space.
local function findRandomFreePosition(geometry)
  local screenWidth, screenHeight = outputGeometry()
  local margin = math.max(0, math.floor(cfg.margin))

  local maxX = screenWidth - geometry.width
  local maxY = screenHeight - geometry.height

  if maxX < margin or maxY < margin then
    return nil, nil  -- Window larger than the screen
  end

  -- Get rectangles occupied by PLUGIN windows (to avoid overlap)
  local occupied = {}
  for _, name in ipairs(widgetNames()) do
    local window = state.windows[name]
    if window ~= nil then
      table.insert(occupied, {
        x = window.x,
        y = window.y,
        w = window.w,
        h = window.h,
      })
    end
  end

  local function fits(x, y)
    if x < margin or y < margin then
      return false
    end
    if x + geometry.width > screenWidth - margin or y + geometry.height > screenHeight - margin then
      return false
    end
    for _, other in ipairs(occupied) do
      local overlapX = math.min(x + geometry.width, other.x + other.w) - math.max(x, other.x)
      local overlapY = math.min(y + geometry.height, other.y + other.h) - math.max(y, other.y)
      if overlapX > 0 and overlapY > 0 then
        return false
      end
    end
    return true
  end

  -- Completely random positions distributed across the whole screen,
  -- without prioritizing the center or following a repetitive grid.
  local maxAttempts = 120
  local minX = margin
  local maxX = math.max(minX, screenWidth - geometry.width - margin)
  local minY = margin
  local maxY = math.max(minY, screenHeight - geometry.height - margin)

  for _ = 1, maxAttempts do
    local x = randomRange(minX, maxX)
    local y = randomRange(minY, maxY)
    if fits(x, y) then
      return x, y
    end
  end

  return nil, nil  -- No free space
end

-- Apply the "random" fallback mode to a geometry: pick a random size (if
-- `fallback_random_resize` is active) and then a free position that respects
-- that size. Returns true if it found room.
local function applyRandomPlacement(geometry)
  local margin = math.max(0, math.floor(cfg.margin))

  if cfg.fallbackRandomResize then
    local screenW, screenH = outputGeometry()
    local minW = math.max(200, math.floor(screenW * 0.15))
    local maxW = math.min(screenW - margin * 2, math.floor(screenW * 0.55))
    local minH = math.max(150, math.floor(screenH * 0.15))
    local maxH = math.min(screenH - margin * 2, math.floor(screenH * 0.65))
    if maxW > minW then
      geometry.width = randomRange(minW, maxW)
    end
    if maxH > minH then
      geometry.height = randomRange(minH, maxH)
    end
  end

  local rx, ry = findRandomFreePosition(geometry)
  if rx == nil then
    return false
  end
  geometry.x, geometry.y = rx, ry
  return true
end

-- Reuse a widget's last known size (open window or the last time it was
-- open) when "Change size too" is off. This way, if the user resizes it by
-- hand and clicks the thumbnail again to reposition it, that size is kept
-- instead of returning to the layout/config size.
--
-- `source` = the already-open window (if any). Without an open window it only
-- applies to widgets without a layout: if the widget has a defined direction
-- and size, they are respected as-is when opening.
local function applyRememberedSize(geometry, name, source)
  if cfg.fallbackMode ~= "random" or cfg.fallbackRandomResize then
    return
  end

  local size = source
  if type(size) ~= "table" then
    if not geometry.auto then
      -- It has a defined direction and size: its values win.
      return
    end
    size = state.lastSize[name]
  end
  if type(size) ~= "table" then
    return
  end

  local width = tonumber(size.w)
  local height = tonumber(size.h)
  if (width or 0) > 0 and (height or 0) > 0 then
    geometry.width = math.floor(width)
    geometry.height = math.floor(height)
  end
end

-- Delete a frame that falls outside the recent list.
--
-- If the UI tree is still using it, it is not deleted: the host saves the
-- last tree and reapplies it when reopening the panel, so it would request
-- that image again and warn "image failed to load" if the file no longer
-- existed. Those files are deleted later, when no card uses them (see
-- `cleanup`).
local function dropFrame(path)
  if (state.thumbUsed or {})[path] then
    state.pendingDrop[path] = true
    return
  end
  pcall(noctalia.removeFile, path)
end

local function addRecentFrame(name, path)
  if path == nil then
    return
  end
  local list = state.recentFrames[name]
  if list == nil then
    list = {}
    state.recentFrames[name] = list
  end
  table.insert(list, 1, path)
  while #list > 8 do
    local dropped = table.remove(list)
    if dropped ~= path then
      dropFrame(dropped)
    end
  end
end

-- Recent captures of the widget, newest to oldest. Used to animate cards and
-- to make the "live" view change files (the host does not reload an image if
-- the path does not change).
local function captureFrames(name, limit)
  local list = state.recentFrames[name]
  local out = {}
  if list ~= nil then
    for _, path in ipairs(list) do
      if noctalia.fileExists(path) then
        table.insert(out, path)
        if limit ~= nil and #out >= limit then
          return out
        end
      end
    end
  end
  if #out > 0 then
    return out
  end
  return preview.frames(name, limit or 8)
end

captureThumbs = function(force)
  if cfg.cardPreview == "mock" then
    return
  end
  if not preview.toolsAvailable() then
    return
  end
  if state.capturing then
    return
  end

  -- Automatic capture (without force) for modes that must capture when a
  -- window opens: live, auto, screenshot, gif. Mock mode does not capture.
  -- With force=true (from periodic update() or manual open), it always captures.
  local shouldCapture = force
  if not shouldCapture then
    if cfg.cardPreview == "live"
       or cfg.cardPreview == "auto"
       or cfg.cardPreview == "screenshot"
       or cfg.cardPreview == "gif" then
      shouldCapture = true
    end
  end
  if not shouldCapture then
    return
  end

  state.capturing = true
  state.lastCapture = noctalia.nowMs()

  local clients = state.clients or {}
  win.layers(function(layers)
    local entries = {}
    local pendingFrames = {}
    for _, client in ipairs(clients) do
      local name = state.classNames[client.class]
      if name ~= nil and client.w > 0 and client.h > 0 then
        local window = state.windows[name]
        if window ~= nil then
          -- Skip widgets with a custom thumbnail: they do not need a capture
          local customThumb = state.thumbs[name]
          if customThumb and customThumb ~= "" then
            -- Do not capture, we already have the user's image
          else
            local seq = nil
            if cfg.cardPreview == "live" or cfg.cardPreview == "auto" or cfg.cardPreview == "gif" then
              seq = noctalia.nowMs()
            end
            local entry = {
              name = name,
              address = window.address,
              stable_id = window.stableId,
              x = window.screenX or window.x,
              y = window.screenY or window.y,
              w = window.w,
              h = window.h,
              output = window.monitor.name,
              seq = seq,
            }
            table.insert(entries, entry)
            if seq ~= nil then
              local framePath = preview.thumbPath(name, preview.signature(entry, seq))
              if framePath ~= nil then
                table.insert(pendingFrames, { name = name, path = framePath })
              end
            end
          end
        end
      end
    end
    noctalia.log(string.format("terminal-widgets: captureThumbs: %d entries, capturing=%s", #entries, tostring(state.capturing)))

    local function cleanup()
      -- Paths in use: those of the open windows and those the tree is drawing
      -- right now (`state.thumbUsed`). Pruning only deletes what is not in
      -- use and is old.
      local used = preview.currentPaths(state.windows)
      for path in pairs(state.thumbUsed or {}) do
        used[path] = true
      end
      preview.pruneUnused(used, 1800)
      -- Frames dropped from the list while the tree used them can now be
      -- deleted: the tree has stopped requesting them.
      for path in pairs(state.pendingDrop or {}) do
        if not used[path] then
          state.pendingDrop[path] = nil
          pcall(noctalia.removeFile, path)
        end
      end
      state.capturing = false
    end

    if #entries == 0 then
      cleanup()
      return
    end

    preview.capture(entries, function()
      -- The new captures exist now: save them as recent frames so the card
      -- can update/animate with a different path.
      for _, item in ipairs(pendingFrames) do
        if noctalia.fileExists(item.path) then
          addRecentFrame(item.name, item.path)
        end
      end
      cleanup()
      -- Frames are loaded lazily in cardPreview when needed. They are not
      -- preloaded here to avoid exceeding the CPU budget with
      -- #entries * fileInfo calls.
      if state.open then
        render()
      end
    end)
  end)
end

-- ------------------------------------------------------------- actions --

local function refresh()
  refreshWindows(function()
    if state.open then
      render()
    end
  end)
end

refreshWindows = function(callback)
  win.list(function(clients)
    win.monitors(function(monitors)
      local map = classMap()
      local windows = win.pluginWindows(clients, monitors, function(class)
        return map[class]
      end)

      state.clients = clients
      state.classNames = map
      state.windows = {}
      for _, window in ipairs(windows) do
        if window.name ~= nil then
          state.windows[window.name] = window
          if (window.w or 0) > 0 and (window.h or 0) > 0 then
            state.lastSize[window.name] = {
              w = math.floor(window.w),
              h = math.floor(window.h),
            }
          end
        end
      end

      -- Defer captureThumbs to avoid CPU budget in onOpen
      noctalia.runAsync({ "sleep", "0.1" }, function()
        if state.open then
          captureThumbs()
        end
        if callback ~= nil then
          callback()
        end
      end)
    end)
  end)
end

-- Open (or focus) a widget. The debounce prevents a quick double click from
-- opening two identical windows.
launch = function(name, opts)
  opts = opts or {}

  -- If the action is part of a chain (for example "open all"), it must still
  -- report that this widget is skipped, or the chain would hang and the
  -- following ones would never open.
  local function skip()
    if opts.onDone ~= nil then
      opts.onDone()
    end
  end

  local command = state.commands[name]
  if type(command) ~= "string" or command == "" then
    noctalia.notifyError(tr("title"), tr("missing_command", { name = tostring(name) }))
    skip()
    return
  end

  local class = util.classFor(name)
  local now = noctalia.nowMs()
  local last = state.lastLaunch[class]
  if last ~= nil and (now - last) < DEBOUNCE_MS then
    skip()
    return
  end
  if state.launching[class] then
    skip()
    return
  end
  state.lastLaunch[class] = now
  state.launching[class] = true

  refreshBrain()
  local geometry = geometryFor(name)

  local function finish(doRefresh)
    state.launching[class] = nil
    if opts.onDone ~= nil then
      opts.onDone()
      return
    end
    -- `close_on_launch` closes the panel when opening a terminal (unless the
    -- action is batched, like "open all").
    if cfg.closeOnLaunch and not opts.keepOpen then
      panel.close()
      return
    end
    if doRefresh ~= false then
      refresh()
    end
  end

  win.list(function(clients)
    win.monitors(function(monitors)
      local existing = findByClass(clients, class)

      if existing ~= nil and cfg.reuseExisting then
        -- With the brain on, clicking an open widget's card only focuses it:
        -- repositioning it would override the manual adjustment that memory
        -- must preserve.
        if state.brain == true then
          win.focusOnly(class, function()
            finish(true)
          end)
          return
        end

        -- If "Change size too" is off, keep the widget's last real size (the
        -- one the user left when resizing it by hand).
        applyRememberedSize(geometry, name, existing)

        -- The widget is already open: in random mode it moves to a free slot
        -- (the layout only contributes the size), in custom mode it returns
        -- to its configured position.
        if cfg.fallbackMode == "random" then
          if not applyRandomPlacement(geometry) then
            noctalia.notifyError(tr("title"), tr("no_free_space"))
            finish(true)
            return
          end
        end
        noteImposed(name, geometry)
        win.focusExisting(class, geometry, function()
          finish(true)
        end)
      else
        -- If "Change size too" is off, keep the widget's last real size (the
        -- one the user left when resizing it by hand).
        applyRememberedSize(geometry, name, existing)

        -- New widget: if it has no explicit layout (geometry.auto) it opens
        -- in a free slot; if it has one, its direction and size are respected
        -- as defined.
        if cfg.fallbackMode == "random" and geometry.auto then
          if not applyRandomPlacement(geometry) then
            -- No free space
            noctalia.notifyError(tr("title"), tr("no_free_space"))
            finish(true)
            return
          end
        end
        noteImposed(name, geometry)
        win.spawn({
          terminal = cfg.terminal,
          class = class,
          name = name,
          command = command,
          geometry = geometry,
          monitor = cfg.output ~= "" and cfg.output or nil,
          onError = function()
            noctalia.notifyError(tr("title"), tr("launch_failed"))
          end,
        }, function()
          -- The thumbnail is taken once the window is mapped.
          noctalia.runAsync({ "sleep", "1.2" }, function()
            refresh()
          end)
          finish(false)
        end)
      end
    end)
  end)
end

-- Rotate the open windows among themselves.
rotateWindows = function()
  if state.rotating or win.rotating then
    return
  end
  state.rotating = true
  win.list(function(clients)
    win.monitors(function(monitors)
      local map = classMap()
      local windows = win.pluginWindows(clients, monitors, function(class)
        return map[class]
      end)

      if #windows < 2 then
        noctalia.notify(tr("title"), tr("nothing_to_rotate"))
        state.rotating = false
        return
      end

      local started = win.rotate(windows, cfg.rotation, cfg.rotationSizes, function(moves)
        state.rotating = false
        -- Rotation also imposes geometries: they are published so the
        -- service does not mistake them for manual moves.
        if moves ~= nil then
          local byAddress = {}
          for _, window in ipairs(windows) do
            byAddress[window.address] = window
          end
          for _, move in ipairs(moves) do
            local window = byAddress[move.address]
            if window ~= nil and window.name ~= nil then
              publishImposed(window.name, {
                x = (window.monitor.x or 0) + move.x,
                y = (window.monitor.y or 0) + move.y,
                w = move.w,
                h = move.h,
              })
            end
          end
        end
        refresh()
      end)
      if started == false then
        state.rotating = false
        return
      end
    end)
  end)
end

-- Open the missing widgets one after another (so each one sees the windows
-- already open and they do not overlap). If they were all open, rotate
-- them.
openAll = function()
  refreshBrain()
  win.list(function(clients)
    win.monitors(function(monitors)
      local map = classMap()
      local windows = win.pluginWindows(clients, monitors, function(class)
        return map[class]
      end)

      local open = {}
      for _, window in ipairs(windows) do
        if window.name ~= nil then
          open[window.name] = true
        end
      end

      local missing = {}
      for _, name in ipairs(widgetNames()) do
        if not open[name] then
          table.insert(missing, name)
        end
      end

      if #missing == 0 then
        if #windows >= 2 then
          if state.rotating or win.rotating then
            return
          end
          state.rotating = true
          local started = win.rotate(windows, cfg.rotation, cfg.rotationSizes, function()
            state.rotating = false
            refresh()
          end)
          if started == false then
            state.rotating = false
          end
        else
          noctalia.notify(tr("title"), tr("nothing_to_rotate"))
        end
        return
      end

      -- Parallel launch: geometries are computed once (with the shared
      -- occupied list) and all spawns are dispatched in a single batch,
      -- instead of opening them one by one.
      local paramsList = {}
      local occupied = {}
      -- Seed with the already-open windows
      for _, window in ipairs(windows) do
        table.insert(occupied, { x = window.x, y = window.y, w = window.w, h = window.h })
      end

      for _, name in ipairs(missing) do
        local command = state.commands[name]
        if type(command) ~= "string" or command == "" then
          noctalia.notifyError(tr("title"), tr("missing_command", { name = tostring(name) }))
        else
          local geometry = geometryFor(name)

          -- Keep the last manually adjusted size if random resize is off.
          -- Otherwise the layout size wins.
          applyRememberedSize(geometry, name, nil)

          -- Random fallback mode: look for a free position (and optionally a
          -- random size) only if the widget has no direction and size defined
          -- in its layout.
          if cfg.fallbackMode == "random" and geometry.auto then
            if not applyRandomPlacement(geometry) then
              -- No free space, skip this widget
              noctalia.notifyError(tr("title"), tr("no_free_space", { name = name }))
            end
          end

          table.insert(occupied, { x = geometry.x, y = geometry.y, w = geometry.width, h = geometry.height })
          local class = util.classFor(name)
          state.lastLaunch[class] = noctalia.nowMs()
          state.launching[class] = true
          table.insert(paramsList, {
            terminal = cfg.terminal,
            class = class,
            name = name,
            command = command,
            geometry = geometry,
            monitor = cfg.output ~= "" and cfg.output or nil,
            onError = function()
              noctalia.notifyError(tr("title"), tr("launch_failed"))
            end,
          })
        end
      end

      if #paramsList == 0 then
        refresh()
        return
      end

      for _, params in ipairs(paramsList) do
        noteImposed(params.name, params.geometry)
      end

      win.spawnMany(paramsList, function()
        for _, params in ipairs(paramsList) do
          state.launching[params.class] = nil
        end
        noctalia.runAsync({ "sleep", "1.2" }, function()
          refresh()
        end)
      end)
    end)
  end)
end

closeAllWindows = function()
  win.list(function(clients)
    win.monitors(function(monitors)
      local map = classMap()
      local windows = win.pluginWindows(clients, monitors, function(class)
        return map[class]
      end)
      win.closeAll(windows, function()
        refresh()
      end)
    end)
  end)
end

-- ------------------------------------------------------------- editing --

-- Apply a widget's changes (used by the panel form and IPC).
local function applyWidget(name, command, layout, thumb)
  name = util.trim(name)
  command = util.trim(command)
  layout = util.trim(layout)
  thumb = util.trim(thumb)

  if name == "" then
    return false, tr("need_name")
  end

  if state.store == nil then
    loadWidgets()
  end

  -- An empty command on an existing widget does not leave it without a
  -- command (that would be an editing mistake); on a new one it is saved as-is.
  if command == "" and state.commands[name] ~= nil then
    command = nil
  end

  -- Empty `layout` and `thumb` ARE saved: they mean "remove the value"
  -- (return to the default layout / stop using a custom thumbnail).
  --
  -- A layout written by the user wins over brain memory: that widget's entry
  -- is discarded so the two layers do not contradict each other.
  -- contradigan.
  if layout ~= "" then
    storeLib.saveBrainForget(util.classFor(name))
  end
  storeLib.upsert(state.store, name, command, layout, thumb)
  local saved, err = storeLib.saveWidgets(state.store)
  if not saved then
    return false, tr("save_failed", { detail = tostring(err or "") })
  end
  -- This widget has a layout decided in the form: when leaving edit mode it
  -- will not be overwritten with the window's live geometry.
  state.formLayouts[name] = true

  loadWidgets()

  -- If the widget is open and its geometry changed, it is reapplied instead of
  -- closing the window (so editing size/position does not kill it).
  local window = state.windows[name]
  if window ~= nil then
    local geometry = resolveGeometry(name)
    noteImposed(name, geometry)
    win.focusExisting(util.classFor(name), geometry, function()
      refresh()
    end)
  end
  return true, nil
end

-- Delete a widget (used by the panel and IPC).
local function removeWidget(name)
  if state.store == nil then
    loadWidgets()
  end

  storeLib.remove(state.store, name)
  local saved, err = storeLib.saveWidgets(state.store)
  if not saved then
    return false, tr("save_failed", { detail = tostring(err or "") })
  end
  -- A deleted widget must not leave orphaned memory in the store.
  storeLib.saveBrainForget(util.classFor(name))
  -- The card no longer exists: its entry in the animations table is garbage,
  -- and if it stayed the panel would keep requesting frame ticks for
  -- something that is not there.
  state.captureAnim[name] = nil
  loadWidgets()
  return true, nil
end

startEditing = function(name)
  state.editing = true
  state.editTarget = name
  state.editSession = state.editSession + 1
  -- Each edit session starts without "form" layouts: this way a previous
  -- edit does not protect a widget that has now been moved by hand.
  state.formLayouts = {}
  if name ~= nil then
    state.form = {
      name = name,
      command = state.commands[name] or "",
      layout = state.layouts[name] or "",
      thumb = state.thumbs[name] or "",
    }
  else
    state.form = { name = "", command = "", layout = "", thumb = "" }
  end
  render()
end

local GEOMETRY_TOLERANCE = 4

local function absoluteOf(geometry, box)
  return {
    x = (box.x or 0) + geometry.x,
    y = (box.y or 0) + geometry.y,
    w = geometry.width,
    h = geometry.height,
  }
end

-- When leaving edit mode, each open window's live geometry is compared with
-- the last one the plugin imposed. If it differs, the user moved (or resized)
-- it and it becomes their permanent layout. Works with the brain on or off.
local function saveEditedGeometry()
  local names = widgetNames()
  if #names == 0 then
    return
  end
  local box = outputLib.outputBox(cfg)
  win.list(function(clients)
    local dirty = false
    for _, name in ipairs(names) do
      if state.formLayouts[name] ~= true then
        local window = findByClass(clients, util.classFor(name))
        if window ~= nil and (window.w or 0) > 0 and (window.h or 0) > 0 then
          local live = { x = window.x, y = window.y, w = window.w, h = window.h }
          -- Reference: what the plugin imposed, or where it would put it if the
          -- window was already open before this panel started.
          local reference = state.applied[name] or absoluteOf(resolveGeometry(name), box)
          local moved = math.abs(live.x - reference.x) > GEOMETRY_TOLERANCE
            or math.abs(live.y - reference.y) > GEOMETRY_TOLERANCE
            or math.abs(live.w - reference.w) > GEOMETRY_TOLERANCE
            or math.abs(live.h - reference.h) > GEOMETRY_TOLERANCE
          if moved then
            local value = brainLib.layoutString(live, box, cfg.margin)
            if state.layouts[name] ~= value then
              storeLib.upsert(state.store, name, nil, value, nil)
              dirty = true
            end
          end
        end
      end
    end
    if dirty then
      storeLib.saveWidgets(state.store)
      loadWidgets()
      render()
    end
  end)
end

local cancelEditing = function()
  -- Leaving edit mode consolidates whatever the user moved by hand.
  saveEditedGeometry()
  state.editing = false
  state.editTarget = nil
  state.editSession = state.editSession + 1
  state.form = { name = "", command = "", layout = "", thumb = "" }
  render()
end

saveForm = function()
  local name = util.trim(state.form.name)
  local command = util.trim(state.form.command)
  local layout = util.trim(state.form.layout)
  local thumb = util.trim(state.form.thumb)

  if name == "" then
    noctalia.notifyError(tr("title"), tr("need_name"))
    return
  end

  -- Validate a unique name (keeping the edited widget's name is allowed)
  if state.commands[name] ~= nil and name ~= state.editTarget then
    noctalia.notifyError(tr("title"), tr("name_exists"))
    return
  end

  -- Validate a non-empty command
  if command == "" then
    noctalia.notifyError(tr("title"), tr("empty_command"))
    return
  end

  -- Validate the layout format if provided
  if layout ~= "" then
    local spec = layoutLib.parseLayout(layout)
    if spec == nil or spec.valid == false then
      noctalia.notifyError(tr("title"), tr("invalid_layout"))
      return
    end
  end

  -- The thumbnail is optional; if a path is given, it must exist.
  if thumb ~= "" then
    local info = noctalia.fileInfo(thumb)
    if type(info) ~= "table" or tonumber(info.size or 0) <= 0 then
      noctalia.notifyError(tr("title"), tr("thumb_not_found"))
      return
    end
  end

  local target = state.editTarget
  if target ~= nil and target ~= name then
    local removed, err = removeWidget(target)
    if not removed then
      noctalia.notifyError(tr("title"), err)
      return
    end
  end

  local applied, err = applyWidget(name, command, layout, thumb)
  if not applied then
    noctalia.notifyError(tr("title"), err)
    return
  end

  state.editing = false
  state.editTarget = nil
  state.editSession = state.editSession + 1
  state.form = { name = "", command = "", layout = "", thumb = "" }
  -- The other open windows also consolidate their live geometry.
  saveEditedGeometry()
  render()
end

deleteWidget = function(name)
  local removed, err = removeWidget(name)
  if not removed then
    noctalia.notifyError(tr("title"), err)
    return
  end

  -- If the window was open, close it so it is not left orphaned.
  local window = state.windows[name]
  if window ~= nil then
    win.closeWindow(window.address, function()
      refresh()
    end)
  end

  render()
end

-- ---------------------------------------------------------------- view --

local function cardWidth()
  local columns = cfg.columns
  -- The card width (border-box) already includes its padding. Splitting the
  -- real usable width across columns prevents overflow with a single column.
  local usable = SCROLL_CONTENT_WIDTH - ((columns - 1) * CARD_GAP)
  return math.max(120, math.floor(usable / columns))
end

local function previewHeight()
  -- In a single column the card is very wide: the thumbnail is flattened so
  -- the card does not look disproportionate.
  return math.min(math.floor(cardWidth() * PREVIEW_RATIO), MAX_PREVIEW_HEIGHT)
end

-- Synthetic thumbnail: a fake terminal with the widget name.
local function mockPreview(name)
  local width = cardWidth() - 2 * CARD_PADDING - 12
  local height = previewHeight()
  local children = {}

  append(children, ui.row({ gap = 4, align = "center", padding = 6 }, {
    ui.box({ width = 7, height = 7, radius = 4, fill = "error/0.7" }),
    ui.box({ width = 7, height = 7, radius = 4, fill = "primary/0.7" }),
    ui.box({ width = 7, height = 7, radius = 4, fill = "primary/0.4" }),
  }))
  append(children, ui.row({ paddingH = 8, flexGrow = 1 }, {
    ui.label({
      text = name,
      fontSize = 12,
      fontFamily = "monospace",
      color = "on_surface/0.85",
      maxLines = 2,
      flexGrow = 1,
    }),
  }))

  -- A few fake text lines so the card looks like a terminal.
  local ratios = { 0.62, 0.44, 0.78 }
  for _, ratio in ipairs(ratios) do
    append(children, ui.row({ paddingH = 12, paddingV = 3 }, {
      ui.box({
        width = math.floor((width - 24) * ratio),
        height = 6,
        radius = 3,
        fill = "on_surface/0.12",
      }),
    }))
  end

  return ui.column({
    width = width,
    height = height,
    fill = "#00000040",
    radius = 8,
    border = "outline_variant/0.25",
    borderWidth = 1,
    justify = "start",
    align = "stretch",
  }, children)
end

local function previewImage(path, width)
  -- The path is marked as "in use": thumbnail pruning cannot delete a file
  -- the host is drawing.
  if path ~= nil then
    state.thumbUsed[path] = true
  end
  return ui.image({
    path = path,
    width = width,
    height = previewHeight(),
    fit = "cover",
    radius = 8,
    border = "outline_variant/0.25",
    borderWidth = 1,
  })
end

-- Animated GIF: `ui.image` draws only the first frame, so all of them are
-- extracted to PNG and swapped from `onFrameTick`.
local function gifPreview(path, width)
  local anim = state.gifAnim[path]
  if anim == nil then
    anim = { index = 1, elapsed = 0, started = false, info = nil }
    state.gifAnim[path] = anim
  end

  local info = anim.info or gifLib.frames(path, preview.cacheDir())
  if info ~= nil and #info.frames > 0 then
    anim.info = info
    if anim.index > #info.frames then
      anim.index = 1
    end
    return previewImage(info.frames[anim.index], width)
  end

  if not anim.started then
    anim.started = true
    gifLib.prepare(path, preview.cacheDir(), function(frames)
      anim.info = frames
      if state.open then
        render()
      end
    end)
  end

  -- While frames are being extracted, the host draws the first GIF frame.
  return previewImage(path, width)
end

local function cardPreview(name)
  -- ABSOLUTE PRIORITY: a custom thumbnail ALWAYS wins, whatever the mode
  local customThumb = state.thumbs[name]
  if customThumb and customThumb ~= "" then
    local info = noctalia.fileInfo(customThumb)
    if info and type(info) == "table" and tonumber(info.size or 0) > 0 then
      local width = cardWidth() - 2 * CARD_PADDING - 12
      if gifLib.isGif(customThumb) then
        return gifPreview(customThumb, width)
      end
      return previewImage(customThumb, width)
    end
    -- If the custom file does not exist or is empty, ignore it
  end

  if cfg.cardPreview == "mock" then
    return mockPreview(name)
  end

  local window = state.windows[name]

  -- GIF mode (and Automatic with the window closed): animate the widget's
  -- recent captures as if it were a GIF.
  if cfg.cardPreview == "gif" or (cfg.cardPreview == "auto" and window == nil) then
    local frames = captureFrames(name, 8)
    if #frames > 0 then
      -- The animation will go through all these frames, not only the one
      -- drawn now: all of them are protected so pruning does not delete the
      -- next animation frame.
      for _, framePath in ipairs(frames) do
        state.thumbUsed[framePath] = true
      end
      local anim = state.captureAnim[name]
      if anim == nil then
        anim = { index = 1, elapsed = 0 }
        state.captureAnim[name] = anim
      end
      -- With a single capture there is no animation: there are no frames to
      -- alternate. It is marked here, where the count is known, so frame
      -- ticks are not requested for a card that cannot move.
      anim.animatable = #frames > 1
      local index = ((anim.index - 1) % #frames) + 1
      return previewImage(frames[index], cardWidth() - 2 * CARD_PADDING)
    end
  end

  if window ~= nil then
    -- Live view: use the most recent capture by its unique path. The host
    -- does not reload an image when the same file is overwritten, so reusing
    -- `current` would make the preview interval invisible.
    if cfg.cardPreview == "auto" or cfg.cardPreview == "live" then
      local frames = captureFrames(name, 1)
      if #frames > 0 then
        return previewImage(frames[1], cardWidth() - 2 * CARD_PADDING)
      end
    end

    -- "current" capture (*-current.png) for the remaining modes.
    local capPath = preview.current(name)
    if capPath then
      local info = noctalia.fileInfo(capPath)
      if info and type(info) == "table" and tonumber(info.size or 0) > 0 then
        return previewImage(capPath, cardWidth() - 2 * CARD_PADDING)
      end
    end
  end

  return mockPreview(name)
end

card = function(name)
  local running = state.windows[name] ~= nil
  local command = state.commands[name] or ""
  local layout = layoutText(name)

  local titleRow = {}
  append(titleRow, ui.label({
    text = name,
    fontWeight = "bold",
    color = "on_surface",
    maxLines = 1,
    flexGrow = 1,
  }))
  if running then
    append(titleRow, ui.glyph({ name = "circle-dot", size = 10, color = "primary" }))
    -- Close button visible while the widget is running (right click not supported in ui.image/column)
    append(titleRow, ui.button({
      key = "close-" .. name,
      glyph = "close",
      variant = "ghost",
      tooltip = tr("close_widget"),
      onClick = function()
        local w = state.windows[name]
        if w ~= nil then
          win.closeWindow(w.address, function()
            refresh()
          end)
        end
      end,
    }))
  end
  if state.editing then
    append(titleRow, ui.button({
      key = "edit-" .. name,
      glyph = "pencil",
      variant = "ghost",
      tooltip = tr("edit_widget"),
      onClick = function()
        startEditing(name)
      end,
    }))
    append(titleRow, ui.button({
      key = "delete-" .. name,
      glyph = "trash",
      variant = "ghost",
      tooltip = tr("delete_widget"),
      onClick = function()
        deleteWidget(name)
      end,
    }))
  end

  local titleNode = ui.row({ gap = 6, align = "center" }, titleRow)

  -- Create the preview with click handlers (on the thumbnail)
  local previewNode

  -- Real content width (cardWidth - 2 * CARD_PADDING)
  local contentWidth = cardWidth() - 2 * CARD_PADDING
  -- Thumbnails narrower than the content so they do not touch the edges
  local thumbWidth = contentWidth - 20

  -- Use cardPreview, which handles custom thumbs and window captures
  previewNode = cardPreview(name)
  if not previewNode then
    previewNode = mockPreview(name)
  end

  -- Main container: column with onClick to launch
  local cardProps = {
    key = "card-" .. name,
    width = cardWidth(),
    gap = 6,
    padding = CARD_PADDING,
    radius = 12,
    fill = "surface_container/0.35",
    border = "outline_variant/0.2",
    borderWidth = 1,
    tooltip = command ~= ""
        and string.format("%s\n%s", command, layout)
      or tr("missing_command", { name = name }),
  }

  -- In edit mode, do not add click handlers on the preview (the edit/delete buttons are in the titleRow)
  if state.editing then
    return ui.column(cardProps, { previewNode, titleNode })
  end

  -- In normal mode: onClick on the column to launch
  cardProps.onClick = function()
    launch(name)
  end
  return ui.column(cardProps, { previewNode, titleNode })
end

editorCard = function(target)
  local session = state.editSession
  local existing = target ~= nil
  local children = {}

  local titleRow = {
    ui.label({
      text = existing and tr("edit_widget") or tr("add_widget"),
      fontWeight = "bold",
      color = "on_surface",
      maxLines = 1,
      flexGrow = 1,
    }),
  }
  if existing then
    append(titleRow, ui.button({
      key = "editor-delete-" .. session,
      glyph = "trash",
      variant = "ghost",
      tooltip = tr("delete_widget"),
      onClick = function()
        deleteWidget(target)
        cancelEditing()
      end,
    }))
  end
  append(titleRow, ui.button({
    key = "editor-cancel-" .. session,
    glyph = "x",
    variant = "ghost",
    tooltip = tr("cancel"),
    onClick = cancelEditing,
  }))
  append(children, ui.row({ gap = 4, align = "center" }, titleRow))

  -- Name and command in the same row so the form fits inside the card without
  -- stretching the neighboring cards too much.
  append(children, ui.row({ gap = 4, align = "center" }, {
    ui.input({
      key = "form-name-" .. session,
      value = state.form.name,
      placeholder = tr("field_name"),
      controlSize = "sm",
      flexGrow = 1,
      onSubmit = saveForm,
      onChange = function(value)
        state.form.name = value
      end,
    }),
    ui.input({
      key = "form-command-" .. session,
      value = state.form.command,
      placeholder = tr("field_command"),
      controlSize = "sm",
      flexGrow = 1,
      onSubmit = saveForm,
      onChange = function(value)
        state.form.command = value
      end,
    }),
  }))

  append(children, ui.row({ gap = 4, align = "center" }, {
    ui.input({
      key = "form-layout-" .. session,
      value = state.form.layout,
      placeholder = tr("field_layout"),
      controlSize = "sm",
      flexGrow = 1,
      onSubmit = saveForm,
      onChange = function(value)
        state.form.layout = value
      end,
    }),
    ui.row({ gap = 2, align = "center", flexGrow = 1 }, {
      ui.input({
        key = "form-thumb-" .. session,
        value = state.form.thumb or "",
        placeholder = tr("field_thumb"),
        controlSize = "sm",
        flexGrow = 1,
        onSubmit = saveForm,
        onChange = function(value)
          state.form.thumb = value
        end,
      }),
      ui.button({
        key = "form-thumb-clear-" .. session,
        glyph = "eraser",
        variant = "ghost",
        tooltip = tr("clear_thumb"),
        onClick = function()
          state.form.thumb = ""
          -- The session is changed so the input is rebuilt empty.
          state.editSession = state.editSession + 1
          render()
        end,
      }),
    }),
  }))

  append(children, ui.row({ gap = 6, align = "center" }, {
    ui.button({
      key = "editor-save-" .. session,
      text = tr("save"),
      glyph = "check",
      variant = "primary",
      onClick = saveForm,
    }),
    ui.label({
      text = tr("editor_hint"),
      fontSize = 10,
      color = "on_surface_variant",
      flexGrow = 1,
      maxLines = 2,
    }),
  }))

  return ui.column({
    key = "editor",
    width = cardWidth(),
    gap = 6,
    padding = CARD_PADDING,
    radius = 12,
    fill = "surface_container/0.35",
    border = "primary/0.5",
    borderWidth = 1,
    align = "stretch",
  }, children)
end

header = function()
  local outputLabel = cfg.output ~= "" and cfg.output or tr("focused_output")
  local subtitle = tr("subtitle", {
    terminal = cfg.terminal,
    margin = math.floor(cfg.margin),
    output = outputLabel,
  })

  local title = ui.row({
    gap = 8,
    align = "center",
    flexGrow = 1,
    tooltip = subtitle,
  }, {
    ui.glyph({ name = "terminal-2", size = 18, color = "primary" }),
    ui.label({ text = tr("title"), fontSize = 16, fontWeight = "bold", color = "on_surface" }),
  })

  local buttons = {}
  append(buttons, ui.button({
    key = "brain",
    glyph = "brain",
    variant = "ghost",
    selected = state.brain == true,
    tooltip = tr(state.brain == true and "brain_on" or "brain_off"),
    onClick = function()
      state.brain = not (state.brain == true)
      storeLib.saveBrainToggle(state.brain)
      render()
    end,
  }))
  append(buttons, ui.button({
    key = "open-all",
    glyph = "layout-grid",
    variant = "ghost",
    tooltip = tr("open_all"),
    onClick = openAll,
  }))
  append(buttons, ui.button({
    key = "rotate",
    glyph = "rotate-clockwise",
    variant = "ghost",
    tooltip = tr("rotate"),
    onClick = rotateWindows,
  }))
  append(buttons, ui.button({
    key = "close-all",
    glyph = "window-off",
    variant = "ghost",
    tooltip = tr("close_all"),
    onClick = closeAllWindows,
  }))
  append(buttons, ui.button({
    key = "edit",
    glyph = state.editing and "check" or "pencil",
    variant = "ghost",
    tooltip = tr("edit_mode"),
    onClick = function()
      if state.editing then
        cancelEditing()
      else
        startEditing(nil)
      end
    end,
  }))
  append(buttons, ui.button({
    key = "open-settings",
    glyph = "settings",
    variant = "ghost",
    tooltip = tr("open_settings"),
    onClick = function()
      if noctalia.openSettings then
        noctalia.openSettings()
      end
    end,
  }))
  append(buttons, ui.button({
    key = "close-panel",
    glyph = "x",
    variant = "ghost",
    tooltip = tr("close"),
    onClick = function()
      panel.close()
    end,
  }))

  return ui.row({ gap = 4, align = "center" }, { title, ui.row({ gap = 2, align = "center" }, buttons) })
end

render = function()
  if not state.open then
    return
  end

  -- Tree thumbnail paths are recomputed on every render: only files no card
  -- is using can be deleted. Previously they were estimated from the open
  -- windows, and that left out the closed widgets, whose thumbnail ("current"
  -- or the animation) was still being drawn: pruning deleted it and the host
  -- warned "image failed to load".
  --
  -- The set is kept after render so pruning does not delete a file the host
  -- may reapply when reopening the panel.
  state.thumbUsed = {}

  local cards = {}
  local names = widgetNames()

  -- When editing an existing one, the form takes the place of ITS card (so
  -- the fields appear next to the widget being edited).
  for _, name in ipairs(names) do
    if state.editing and state.editTarget == name then
      table.insert(cards, editorCard(name))
    else
      table.insert(cards, card(name))
    end
  end

  -- The "new widget" form goes last, so it does not displace the thumbnails
  -- when entering edit mode.
  if state.editing and state.editTarget == nil then
    table.insert(cards, editorCard(nil))
  end

  if #cards == 0 then
    table.insert(cards, ui.label({
      text = tr("empty"),
      color = "on_surface_container",
      padding = 12,
      flexGrow = 1,
    }))
  end

  -- Rows of `columns` cards. align="stretch" so all cards in the row have the
  -- same height (uniform size). justify="center" to center the cards
  -- horizontally when the panel is wider than the row.
  local rows = {}
  local row = {}
  local count = 0
  for _, node in ipairs(cards) do
    table.insert(row, node)
    count = count + 1
    if count == cfg.columns then
      table.insert(rows, ui.row({ gap = CARD_GAP, align = "stretch", justify = "center" }, row))
      row = {}
      count = 0
    end
  end
  if count > 0 then
    table.insert(rows, ui.row({ gap = CARD_GAP, align = "stretch", justify = "center" }, row))
  end

  panel.render(ui.column({
    flexGrow = 1,
    gap = 10,
    align = "stretch",
    padding = PANEL_PADDING,
  }, {
    header(),
    ui.scroll({ flexGrow = 1, gap = CARD_GAP, justify = "center" }, rows),
  }))

  -- The in-use paths have been filled in by `previewImage` while building the
  -- cards: they are the ones the tree just referenced.

  -- Now it is known whether there is anything to animate (a closed card with
  -- captures in Automatic mode, a GIF): the frame tick is requested or removed.
  syncFrameTicks()
end

-- ------------------------------------------------------------- lifecycle --

-- Is there anything to animate with frame ticks? (A custom GIF, GIF mode or
-- the captures of a closed card in Automatic mode.)
local function needsFrameTicks()
  if cfg.cardPreview == "gif" then
    return true
  end
  for _, path in pairs(state.thumbs or {}) do
    if gifLib.isGif(path) then
      return true
    end
  end
  -- Automatic mode: a card whose window is closed shows its captures as an
  -- animation, and that animation only advances with frame ticks (`render()`
  -- requests them, since it knows whether there are captures).
  --
  -- Only cards that still exist and have more than one frame count: a deleted
  -- card leaves its entry in `captureAnim` (which is garbage) and a card with
  -- a single capture has nothing to animate.
  if cfg.cardPreview == "auto" then
    for name, anim in pairs(state.captureAnim or {}) do
      if anim ~= nil and anim.animatable
        and (state.commands or {})[name] ~= nil
        and state.windows[name] == nil then
        return true
      end
    end
  end
  return false
end

syncFrameTicks = function()
  pcall(panel.setNeedsFrameTick, needsFrameTicks())
end

function onOpen(_context)
  state.open = true
  panel.setWantsSecondTicks(true)
  -- The manifest is cached so it is not parsed on every callback; it is
  -- re-read on open in case the plugin was updated without restarting Noctalia.
  defaults.reset()
  loadConfig()
  loadWidgets()
  refreshBrain()
  state.editing = false
  state.editTarget = nil
  state.formLayouts = {}
  state.frames = {}
  state.captureAnim = {}
  state.recentFrames = {}
  syncFrameTicks()
  -- Do NOT load frames here (CPU budget); they are loaded lazily in render/update
  -- Defer the first render to avoid CPU budget in onOpen
  local function delayedOpen()
    if state.open then
      render()
      refreshWindows(function()
        if state.open then
          render()
        end
      end)
    end
  end
  noctalia.runAsync({ "sleep", "0.05" }, delayedOpen)
end

function onClose()
  state.open = false
  panel.setWantsSecondTicks(false)
  pcall(panel.setNeedsFrameTick, false)
end

function onConfigChanged()
  defaults.reset()
  loadConfig()
  loadWidgets(true)
  refreshBrain()
  syncFrameTicks()
  if state.open then
    render()
    -- The "open" indicators and thumbnails are refreshed too, and if a
    -- position/size changed in Settings it is reapplied to the open window
    -- instead of leaving it where it was.
    refreshWindows(function()
      if state.open then
        for _, name in ipairs(widgetNames()) do
          local window = state.windows[name]
          if window ~= nil then
            local geometry = geometryFor(name)
            noteImposed(name, geometry)
            win.focusExisting(util.classFor(name), geometry, function() end)
          end
        end
        render()
      end
    end)
  end
end

-- Frame ticks: advance the GIFs (custom and captures in GIF mode) only when
-- the visible frame changes, to avoid over-rendering.
function onFrameTick(deltaMs)
  if not state.open then
    return
  end
  deltaMs = tonumber(deltaMs) or 16
  if deltaMs > 250 then
    deltaMs = 250
  end

  local changed = false

  for _, anim in pairs(state.gifAnim) do
    local info = anim.info
    if info ~= nil and #info.frames > 1 then
      anim.elapsed = anim.elapsed + deltaMs
      local duration = info.durations[anim.index] or 100
      while anim.elapsed >= duration do
        anim.elapsed = anim.elapsed - duration
        anim.index = (anim.index % #info.frames) + 1
        duration = info.durations[anim.index] or 100
        changed = true
      end
    end
  end

  local captureInterval = 250
  for name, anim in pairs(state.captureAnim) do
    -- A card with a single capture has nothing to animate: it is skipped so
    -- its frame list is not re-read from disk for no reason.
    local showFrames = anim.animatable ~= false
      and (cfg.cardPreview == "gif"
        or (cfg.cardPreview == "auto" and state.windows[name] == nil))
    if showFrames then
      anim.elapsed = anim.elapsed + deltaMs
      -- The frame list is re-read only when it is time to advance the
      -- animation: `captureFrames` queries the disk, and reading it every
      -- frame would waste CPU without anything changing.
      if anim.elapsed >= captureInterval then
        local frames = captureFrames(name, 8)
        if #frames > 1 then
          while anim.elapsed >= captureInterval do
            anim.elapsed = anim.elapsed - captureInterval
            anim.index = (anim.index % #frames) + 1
            changed = true
          end
        else
          anim.elapsed = 0
        end
      end
    end
  end

  if changed then
    render()
  end
end

function update()
  if not state.open then
    return
  end
  state.tick = state.tick + 1
  -- Periodic capture for live and auto modes (and gif to keep frames fresh)
  -- previewInterval is already in milliseconds.
  if (cfg.cardPreview == "live" or cfg.cardPreview == "auto" or cfg.cardPreview == "gif") and not state.capturing then
    if (noctalia.nowMs() - (state.lastCapture or 0)) >= cfg.previewInterval then
      captureThumbs(true)
    end
  end
  render()
end

function onIpc(event, payload)
  if event == "launch" then
    loadConfig()
    loadWidgets()
    launch(payload)
  elseif event == "open-all" then
    loadConfig()
    loadWidgets()
    openAll()
  elseif event == "rotate" then
    loadConfig()
    loadWidgets()
    rotateWindows()
  elseif event == "close-all" then
    closeAllWindows()
  elseif event == "add" then
    -- "name|command|position|thumb" (thumb optional)
    loadConfig()
    loadWidgets()
    local parts = {}
    for part in tostring(payload or ""):gmatch("[^|]+") do
      parts[#parts + 1] = part
    end
    local applied, err = applyWidget(parts[1] or "", parts[2] or "", parts[3] or "", parts[4] or "")
    if not applied then
      noctalia.notifyError(tr("title"), err)
      return
    end
    if state.open then
      render()
    end
  elseif event == "remove" then
    loadConfig()
    loadWidgets()
    -- Same path as the panel's delete button: the window is closed too.
    deleteWidget(tostring(payload or ""))
  elseif event == "refresh" then
    loadConfig()
    loadWidgets()
    if state.open then
      render()
    end
    refreshWindows(function()
      if state.open then
        render()
      end
    end)
  end
end
