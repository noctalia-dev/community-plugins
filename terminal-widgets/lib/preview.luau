-- Thumbnail captures for the Terminal Widgets panel.
--
-- Handles window captures, thumbnail cache, homemade GIF animation, cleanup
-- of old files and "window only" capture via grim -T.

local util = require("./util.luau")

local M = {}

local CAPTURE_WIDTH = 320
local CAPTURE_HEIGHT = 190
-- Changing the version invalidates old captures (for example, ones that
-- included the panel or other windows above).
local CAPTURE_VERSION = "v3"

local batchCounter = 0

-- Cache directory for thumbnails.
local cachedDir = nil
function M.cacheDir()
  if cachedDir ~= nil then
    if cachedDir == false then
      return nil
    end
    return cachedDir
  end

  local base = noctalia.pluginDataDir()
  if base == nil then
    cachedDir = false
    return nil
  end

  local path = base .. "/thumbs"
  -- Created once per runtime (mkdirAll is idempotent); this way captures also
  -- work on a fresh installation.
  local called, created = pcall(noctalia.mkdirAll, path)
  if not called or created == false then
    noctalia.log("terminal-widgets: could not create " .. path)
    cachedDir = false
    return nil
  end
  cachedDir = path
  return path
end

-- Check whether the required tools (grim, python3) are available.
function M.toolsAvailable()
  local ok1 = pcall(function() return noctalia.commandExists("grim") end)
  local ok2 = pcall(function() return noctalia.commandExists("python3") end)
  if not (ok1 and ok2) then
    return false
  end
  local script = util.pluginPath("bin/snapshot.py")
  return script ~= nil and noctalia.fileExists(script)
end

-- Generate a simple hash for use in file names.
local function hashText(text)
  local hash = 0
  for i = 1, #text do
    hash = (hash * 31 + text:byte(i)) % 0x1000000
  end
  return string.format("%06x", hash)
end

-- Window geometry signature (to detect changes).
function M.signature(window, seq)
  -- Supports both the new format (entry with x,y,w,h) and the old one (window object)
  local x = window.x or 0
  local y = window.y or 0
  local w = window.w or 0
  local h = window.h or 0
  local base = string.format("%d,%d,%d,%d", x, y, w, h)
  if seq ~= nil then
    return base .. "@" .. tostring(seq)
  end
  return base
end

function M.thumbPath(name, signature)
  local dir = M.cacheDir()
  if dir == nil then
    return nil
  end
  return string.format("%s/%s-%s-%s.png", dir, util.slug(name), CAPTURE_VERSION, hashText(signature))
end

-- Path of the "current" thumbnail (without seq) for the main preview
function M.currentThumbPath(name)
  local dir = M.cacheDir()
  if dir == nil then
    return nil
  end
  local base = string.format("%s/%s-%s-current.png", dir, util.slug(name), CAPTURE_VERSION)
  return base
end

function M.cached(name, signature)
  local path = M.thumbPath(name, signature)
  if path == nil then
    return nil
  end
  if noctalia.fileExists(path) then
    return path
  end
  -- Fallback to the current thumbnail
  local currentPath = M.currentThumbPath(name)
  if currentPath and noctalia.fileExists(currentPath) then
    return currentPath
  end
  return nil
end

function M.current(name)
  local path = M.currentThumbPath(name)
  if path and noctalia.fileExists(path) then
    return path
  end
  return nil
end

-- Thumbnail paths the cards are using right now.
-- `windows` accepts a list or a map of open windows (with `name`, `x`, `y`,
-- `w` and `h`).
function M.currentPaths(windows)
  local paths = {}
  for _, window in pairs(windows or {}) do
    if type(window) == "table" and window.name ~= nil then
      local path = M.thumbPath(window.name, M.signature(window))
      if path ~= nil then
        paths[path] = true
      end
      -- Also include the current thumbnail
      local currentPath = M.currentThumbPath(window.name)
      if currentPath ~= nil then
        paths[currentPath] = true
      end
    end
  end
  return paths
end

-- Simple cache for frames (avoids frequent listDir/fileInfo calls)
local framesCache = {}
local framesCacheTime = 0
local FRAMES_CACHE_TTL = 1000  -- 1 second

-- Return the widget's recent thumbnails (newest first), so they can be
-- animated like a homemade GIF when the widget is closed.
function M.frames(name, limit)
  local now = noctalia.nowMs()
  local cacheKey = name .. ":" .. (limit or 8)
  
  -- Check cache
  if framesCache[cacheKey] and (now - framesCacheTime) < FRAMES_CACHE_TTL then
    return framesCache[cacheKey]
  end
  
  local dir = M.cacheDir()
  if dir == nil then
    return {}
  end
  local files = noctalia.listDir(dir)
  if files == nil then
    return {}
  end
  limit = tonumber(limit) or 8
  local slug = util.slug(name)
  local prefix = slug .. "-"
  local suffix = ".png"
  local matches = {}
  local checked = 0
  local maxChecks = 24  -- bounded to stay within the CPU budget
  for _, file in ipairs(files) do
    if checked >= maxChecks then
      break
    end
    if file:sub(1, #prefix) == prefix and file:sub(-4) == suffix then
      local path = dir .. "/" .. file
      local info = noctalia.fileInfo(path)
      local mtime = type(info) == "table" and tonumber(info.mtime) or 0
      table.insert(matches, { path = path, mtime = mtime })
      checked = checked + 1
    end
  end
  table.sort(matches, function(a, b)
    return a.mtime > b.mtime
  end)
  local out = {}
  for index = 1, math.min(limit, #matches) do
    table.insert(out, matches[index].path)
  end
  
  -- Save to cache
  framesCache[cacheKey] = out
  framesCacheTime = now
  return out
end

-- Capture the given windows. `entries` must carry a non-empty `stable_id`:
-- without it there is no isolated toplevel capture, and the card keeps its
-- static or mock preview.
function M.capture(entries, callback)
  if #entries == 0 then
    if callback ~= nil then
      callback()
    end
    return
  end

  local dir = M.cacheDir()
  local script = util.pluginPath("bin/snapshot.py")
  if dir == nil or script == nil then
    if callback ~= nil then
      callback()
    end
    return
  end

  local items = {}
  for _, entry in ipairs(entries) do
    -- Thumbnail with seq (for frames/animation)
    local signature = M.signature(entry, entry.seq)
    local path = M.thumbPath(entry.name, signature)
    -- Current thumbnail (without seq, for the main preview)
    local currentPath = M.currentThumbPath(entry.name)
    
    local stableId = entry.stable_id
    if type(stableId) == "string" and stableId ~= ""
      and path ~= nil and not noctalia.fileExists(path) then
      table.insert(items, {
        name = entry.name,
        address = entry.address,
        stable_id = stableId,
        x = entry.x,
        y = entry.y,
        w = entry.w,
        h = entry.h,
        output = entry.output,
        width = CAPTURE_WIDTH,
        height = CAPTURE_HEIGHT,
        out = path,
        current_out = currentPath,
      })
    end
  end

  if #items == 0 then
    if callback ~= nil then
      callback()
    end
    return
  end

  local ok, encoded = pcall(noctalia.json.encode, items)
  if not ok or encoded == nil then
    if callback ~= nil then
      callback()
    end
    return
  end

  batchCounter = batchCounter + 1
  local batchPath = string.format("%s/batch-%d-%d.json", dir, os.time(), batchCounter)
  if not noctalia.writeFile(batchPath, encoded) then
    if callback ~= nil then
      callback()
    end
    return
  end

  local started = noctalia.runAsync({
    "python3",
    script,
    batchPath,
  }, function(result)
    pcall(noctalia.removeFile, batchPath)
    if result.exitCode ~= 0 then
      local detail = util.trim(result.stderr or "")
      noctalia.log("terminal-widgets: capture: " .. detail)
    end
    if callback ~= nil then
      callback()
    end
  end)
  if not started then
    pcall(noctalia.removeFile, batchPath)
    if callback ~= nil then
      callback()
    end
  end
end

-- Delete thumbnails no card uses anymore and batch files left behind.
--
-- Deletion is by *usage*, not by widget, and only if the file is also old: the
-- host may reapply a saved tree (for example, when reopening the panel) and
-- request an image deleted a moment ago. With the minimum age that file stays
-- around for a while and the "image failed to load" warning does not appear;
-- old files disappear on their own.
--
-- `currentPaths` = paths the cards are using right now.
-- `maxAgeSeconds` = age after which an unused file is considered prunable.
function M.pruneUnused(currentPaths, maxAgeSeconds)
  local dir = M.cacheDir()
  if dir == nil then
    return
  end
  local files = noctalia.listDir(dir)
  if files == nil then
    return
  end

  maxAgeSeconds = tonumber(maxAgeSeconds) or 1800
  local now = os.time()
  local checked = 0
  local maxChecks = 10

  for _, file in ipairs(files) do
    if checked >= maxChecks then
      break
    end
    checked = checked + 1
    if file:sub(1, 6) == "batch-" or file == "batch.json" then
      pcall(noctalia.removeFile, dir .. "/" .. file)
    elseif file:sub(-4) == ".png" and not currentPaths[dir .. "/" .. file] then
      local path = dir .. "/" .. file
      local info = noctalia.fileInfo(path)
      local mtime = type(info) == "table" and tonumber(info.mtime) or nil
      if mtime == nil or (now - mtime) >= maxAgeSeconds then
        pcall(noctalia.removeFile, path)
      end
    end
  end
end

-- Latest available thumbnail for a widget (the most recent one).
function M.latest(name)
  local frames = M.frames(name, 1)
  if #frames > 0 then
    return frames[1]
  end
  return nil
end

return M