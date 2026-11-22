--!nonstrict
-- GIF thumbnail frames for the panel.
--
-- `ui.image` draws only the first frame of a GIF, so here all of them are
-- extracted to PNG (with `bin/gif-frames.py`) and stored in the plugin cache
-- directory. The panel swaps them from `onFrameTick`, honoring each frame's
-- duration.

local util = require("./util.luau")

local M = {}

-- path -> { frames = { paths }, durations = { ms }, dir }
local cache = {}
-- path -> true while extraction is running
local preparing = {}

local function hashText(text)
  local hash = 0
  for i = 1, #text do
    hash = (hash * 31 + text:byte(i)) % 0x1000000
  end
  return string.format("%06x", hash)
end

function M.isGif(path)
  if type(path) ~= "string" then
    return false
  end
  return path:lower():sub(-4) == ".gif"
end

local function frameDir(path, cacheDir, mtime)
  return string.format("%s/gif-%s", cacheDir, hashText(path .. ":" .. tostring(mtime or 0)))
end

-- Return the already-extracted frames, or nil if they do not exist yet.
function M.frames(path, cacheDir)
  if not M.isGif(path) or cacheDir == nil then
    return nil
  end
  if cache[path] ~= nil then
    return cache[path]
  end

  local info = noctalia.fileInfo(path)
  if type(info) ~= "table" or tonumber(info.size or 0) <= 0 then
    return nil
  end

  local dir = frameDir(path, cacheDir, tonumber(info.mtime) or 0)
  local raw = noctalia.readFile(dir .. "/manifest.json")
  if raw == nil or raw == "" then
    return nil
  end

  local ok, decoded = pcall(noctalia.json.decode, raw)
  if not ok or type(decoded) ~= "table" or type(decoded.frames) ~= "table" or #decoded.frames == 0 then
    return nil
  end

  local frames = {}
  for _, name in ipairs(decoded.frames) do
    frames[#frames + 1] = dir .. "/" .. name
  end

  local durations = {}
  local rawDurations = decoded.durations
  for index = 1, #frames do
    local duration = 100
    if type(rawDurations) == "table" then
      duration = tonumber(rawDurations[index]) or 100
    end
    durations[index] = math.max(20, duration)
  end

  local result = { frames = frames, durations = durations, dir = dir }
  cache[path] = result
  return result
end

-- Extract the frames if needed. `callback` receives the frames or nil.
function M.prepare(path, cacheDir, callback)
  if not M.isGif(path) or cacheDir == nil then
    if callback ~= nil then
      callback(nil)
    end
    return
  end

  local ready = M.frames(path, cacheDir)
  if ready ~= nil then
    if callback ~= nil then
      callback(ready)
    end
    return
  end

  if preparing[path] then
    return
  end

  local script = util.pluginPath("bin/gif-frames.py")
  local info = noctalia.fileInfo(path)
  if script == nil or not noctalia.fileExists(script) or type(info) ~= "table" then
    if callback ~= nil then
      callback(nil)
    end
    return
  end

  local dir = frameDir(path, cacheDir, tonumber(info.mtime) or 0)
  pcall(noctalia.mkdirAll, dir)

  preparing[path] = true
  local started = noctalia.runAsync({ "python3", script, path, dir }, function(result)
    preparing[path] = nil
    local frames = nil
    if type(result) == "table" and result.exitCode == 0 then
      cache[path] = nil
      frames = M.frames(path, cacheDir)
    else
      local detail = ""
      local code = "?"
      if type(result) == "table" then
        detail = util.trim(result.stderr or "")
        code = tostring(result.exitCode)
      end
      noctalia.log("terminal-widgets: could not extract the GIF (exit " .. code .. "): " .. detail)
    end
    if callback ~= nil then
      callback(frames)
    end
  end, 60000)

  if not started then
    preparing[path] = nil
    if callback ~= nil then
      callback(nil)
    end
  end
end

-- Forget the extracted data (useful if the thumbnail list changes at runtime).
function M.reset()
  cache = {}
  preparing = {}
end

return M
