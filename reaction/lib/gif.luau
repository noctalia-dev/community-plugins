--[[
Animated GIF frame loader, shared by the plugins in this repository.

`ui.image` only renders static images, so animated GIFs are unpacked into PNG
frames once and cached on disk. Extraction prefers ffmpeg (much faster) and
falls back to ImageMagick. Frame delays come from ffprobe, or from
`magick identify` when ffmpeg is unavailable.

Usage:

    local Gif = require("./lib/gif.luau")
    local clip = Gif.new({ dataDir = dir, onLog = noctalia.log })

    clip:setSource(path, sizePx)   -- (re)starts extraction when needed
    if clip:ready() then
      local frame = clip:frameAt(elapsedMs)
    end

`setSource` is cheap to call on every update: it only does work when the source
path, the requested size or the source file's mtime/size changed.
]]

-- Bump when the cache layout or the transparency handling changes, so stale
-- caches on disk are ignored instead of being reused.
local CACHE_VERSION = 6

local Gif = {}
Gif.__index = Gif

local function trim(s)
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end

local function isGif(path)
  return path:lower():match("%.gif$") ~= nil
end

function Gif.isGif(path)
  return isGif(path)
end

function Gif.new(opts)
  opts = opts or {}
  return setmetatable({
    dataDir = opts.dataDir or "/tmp/noctalia-gif",
    log = opts.onLog or function() end,

    -- Loaded animation.
    source = nil,
    size = nil,
    frames = nil,
    durations = nil,
    totalMs = 0,

    -- Extraction bookkeeping.
    loading = false,
    loadingSince = 0,
    lastError = nil,
  }, Gif)
end

function Gif:ready()
  return self.frames ~= nil and #self.frames > 0
end

function Gif:durationMs()
  return self.totalMs
end

function Gif:isLoading()
  return self.loading
end

function Gif:errorMessage()
  return self.lastError
end

-- Cache directory for one source file at one display size. The size is part of
-- the name because the extracted frames are pre-scaled to the display box.
function Gif:cacheDir(path, size)
  local safe = path:gsub("[^%w_.-]", "_"):gsub("%.gif$", "")
  return string.format("%s/gif-cache/%s-%dpx", self.dataDir, safe, size)
end

-- Directory holding the extracted frames for a source at a size. A companion
-- process can play those static frames directly instead of decoding the
-- animated GIF, which keeps its memory flat during playback.
function Gif:framesDir(path, size)
  return self:cacheDir(path, size)
end

function Gif:reset()
  self.frames = nil
  self.durations = nil
  self.totalMs = 0
  self.lastError = nil
end

-- Reads cached metadata, returning false when the cache is missing, stale or
-- written by an older cache version.
function Gif:_loadMetadata(cacheDir, path)
  local raw = noctalia.readFile(cacheDir .. "/metadata.json")
  if not raw then
    return false
  end

  local ok, meta = pcall(noctalia.json.decode, raw)
  if not ok or type(meta) ~= "table" or not meta.frames then
    return false
  end
  if meta.cacheVersion ~= CACHE_VERSION then
    return false
  end

  -- A changed source file invalidates the cache, and so does a cache from
  -- before source metadata was recorded at all.
  if meta.sourceMtime == nil or meta.sourceSize == nil then
    return false
  end
  local info = noctalia.fileInfo(path)
  if info then
    if meta.sourceMtime ~= info.mtime or meta.sourceSize ~= info.size then
      return false
    end
  end

  self.frames = {}
  for _, name in ipairs(meta.frames) do
    table.insert(self.frames, cacheDir .. "/" .. name)
  end
  self.durations = meta.durations
  self.totalMs = meta.totalDuration or 0
  return true
end

function Gif:_saveMetadata(cacheDir, frames, durations, totalMs, extractor, sourceMtime, sourceSize)
  local ok, encoded = pcall(noctalia.json.encode, {
    frames = frames,
    durations = durations,
    totalDuration = totalMs,
    extractor = extractor or "unknown",
    sourceMtime = sourceMtime,
    sourceSize = sourceSize,
    cacheVersion = CACHE_VERSION,
  })
  if ok then
    noctalia.writeFile(cacheDir .. "/metadata.json", encoded)
  end
end

function Gif:_finish(cacheDir, names, durations, totalMs, extractor, sourceMtime, sourceSize)
  self:_saveMetadata(cacheDir, names, durations, totalMs, extractor, sourceMtime, sourceSize)
  self.frames = {}
  for _, name in ipairs(names) do
    table.insert(self.frames, cacheDir .. "/" .. name)
  end
  self.durations = durations
  self.totalMs = totalMs
  self.loading = false
end

-- ImageMagick reports frame delay in hundredths of a second by default.
local function parseMagickDurations(stdout)
  local durations, total = {}, 0
  for line in stdout:gmatch("[^\r\n]+") do
    local ticks = tonumber(line) or 10
    local ms = math.floor(ticks * 10)
    if ms <= 0 then
      ms = 100
    end
    table.insert(durations, ms)
    total = total + ms
  end
  return durations, total
end

-- ffprobe prints absolute presentation timestamps. Frame i's delay is the gap
-- to frame i+1; the last frame keeps the previous delay so looping stays smooth.
local function parseFfmpegDurations(stdout)
  local pts = {}
  for line in stdout:gmatch("[^\r\n]+") do
    local sec = tonumber(line)
    if sec then
      table.insert(pts, math.floor(sec * 1000))
    end
  end

  local durations, total = {}, 0
  for i = 1, #pts - 1 do
    local delta = pts[i + 1] - pts[i]
    if delta <= 0 then
      delta = 33
    end
    table.insert(durations, delta)
    total = total + delta
  end

  -- Last frame: ffprobe does not give a following timestamp, so reuse the
  -- previous delay (or a sane default if there is only one frame).
  local lastDelta = (#durations > 0 and durations[#durations]) or 100
  table.insert(durations, lastDelta)
  total = total + lastDelta

  return durations, total
end

local function framesPresent(cacheDir, count, firstIndex)
  for i = 0, count - 1 do
    local name = string.format("%s/frame-%03d.png", cacheDir, firstIndex + i)
    if not noctalia.fileExists(name) then
      return false
    end
  end
  return true
end

local function frameNames(count, firstIndex)
  local names = {}
  for i = 0, count - 1 do
    table.insert(names, string.format("frame-%03d.png", firstIndex + i))
  end
  return names
end

-- How many frame-XXX.png files are actually present in the cache directory.
local function countExtractedFrames(cacheDir)
  local entries = noctalia.listDir(cacheDir)
  if not entries then
    return 0
  end
  local n = 0
  for _, name in ipairs(entries) do
    if name:match("^frame%-%d%d%d%.png$") then
      n = n + 1
    end
  end
  return n
end

local function clearFrames(cacheDir)
  local entries = noctalia.listDir(cacheDir)
  if not entries then
    return
  end
  for _, name in ipairs(entries) do
    if name:match("^frame%-%d%d%d%.png$") then
      noctalia.removeFile(cacheDir .. "/" .. name)
    end
  end
end

function Gif:_extractWithMagick(path, cacheDir, size, sourceMtime, sourceSize)
  self.log("gif: extracting with ImageMagick (" .. size .. "px)")

  noctalia.runAsync({ "magick", "identify", "-format", "%T\n", path }, function(identify)
    if identify.exitCode ~= 0 then
      self.lastError = "magick identify failed: " .. trim(identify.stderr or "")
      self.log("gif: " .. self.lastError)
      self.loading = false
      return
    end

    local durations, totalMs = parseMagickDurations(identify.stdout)
    local count = #durations
    if count == 0 then
      durations, totalMs, count = { 100 }, 100, 1
    end

    if framesPresent(cacheDir, count, 0) and countExtractedFrames(cacheDir) == count then
      self:_finish(cacheDir, frameNames(count, 0), durations, totalMs, "magick", sourceMtime, sourceSize)
      return
    end

    noctalia.runAsync({
      "magick", path, "-coalesce", "-resize", size .. "x" .. size .. ">",
      cacheDir .. "/frame-%03d.png",
    }, function(result)
      if result.exitCode ~= 0 then
        self.lastError = "magick extraction failed: " .. trim(result.stderr or "")
        self.log("gif: " .. self.lastError)
        self.loading = false
        return
      end
      self:_finish(cacheDir, frameNames(count, 0), durations, totalMs, "magick", sourceMtime, sourceSize)
    end)
  end)
end

function Gif:_extractWithFfmpeg(path, cacheDir, size, sourceMtime, sourceSize)
  self.log("gif: extracting with ffmpeg (" .. size .. "px)")

  noctalia.runAsync({
    "ffprobe", "-v", "error", "-select_streams", "v:0",
    "-show_entries", "frame=pts_time", "-of", "csv=p=0", path,
  }, function(probe)
    if probe.exitCode ~= 0 then
      self.log("gif: ffprobe failed, falling back to ImageMagick")
      self:_extractWithMagick(path, cacheDir, size, sourceMtime, sourceSize)
      return
    end

    local durations, totalMs = parseFfmpegDurations(probe.stdout)
    local count = #durations
    if count == 0 then
      durations, totalMs, count = { 100 }, 100, 1
    end

    -- ffmpeg numbers output frames from 1, ImageMagick from 0.
    if framesPresent(cacheDir, count, 1) and countExtractedFrames(cacheDir) == count then
      self:_finish(cacheDir, frameNames(count, 1), durations, totalMs, "ffmpeg", sourceMtime, sourceSize)
      return
    end

    noctalia.runAsync({
      "ffmpeg", "-y", "-i", path,
      "-vf", string.format("scale=%d:-1:flags=lanczos", size),
      "-pix_fmt", "rgba",
      cacheDir .. "/frame-%03d.png",
    }, function(result)
      if result.exitCode ~= 0 then
        self.log("gif: ffmpeg extraction failed, falling back to ImageMagick")
        self:_extractWithMagick(path, cacheDir, size, sourceMtime, sourceSize)
        return
      end

      -- ffmpeg sometimes emits intermediate/tween frames for transparent or
      -- blended GIFs, while ffprobe only reports the logical frames. Playing
      -- only the logical subset against the tween frames produces incomplete or
      -- choppy animations, so fall back to ImageMagick when the counts disagree.
      local actualCount = countExtractedFrames(cacheDir)
      if actualCount ~= count then
        self.log(string.format(
          "gif: ffmpeg extracted %d frames but ffprobe reported %d, using ImageMagick",
          actualCount, count
        ))
        clearFrames(cacheDir)
        self:_extractWithMagick(path, cacheDir, size, sourceMtime, sourceSize)
        return
      end

      self:_finish(cacheDir, frameNames(count, 1), durations, totalMs, "ffmpeg", sourceMtime, sourceSize)
    end)
  end)
end

function Gif:_startExtraction(path, cacheDir, size)
  self.loading = true
  self.loadingSince = noctalia.nowMs()

  noctalia.mkdirAll(cacheDir)

  local info = noctalia.fileInfo(path)
  local mtime = info and info.mtime or 0
  local bytes = info and info.size or 0

  if self:_loadMetadata(cacheDir, path) then
    self.loading = false
    return
  end

  -- Stale or missing metadata: wipe any leftover PNGs so the next extraction
  -- starts from a clean directory and cannot accidentally reuse a partial or
  -- mismatched old frame set.
  clearFrames(cacheDir)

  if noctalia.commandExists("ffmpeg") and noctalia.commandExists("ffprobe") then
    self:_extractWithFfmpeg(path, cacheDir, size, mtime, bytes)
  elseif noctalia.commandExists("magick") then
    self:_extractWithMagick(path, cacheDir, size, mtime, bytes)
  else
    self.lastError = "ffmpeg or ImageMagick is required for GIF support"
    self.log("gif: " .. self.lastError)
    self.loading = false
  end
end

-- Prepares `path` at `size` pixels. Static images are ignored on purpose: the
-- caller renders those directly. Returns true when frames are ready.
function Gif:setSource(path, size)
  if path == nil or path == "" or not isGif(path) then
    if self.source ~= nil then
      self.source, self.size = nil, nil
      self:reset()
    end
    return false
  end

  if self.source ~= path or self.size ~= size then
    self.source, self.size = path, size
    self:reset()
    self.loading = false
  end

  if self:ready() then
    return true
  end

  -- Allow a retry when a previous extraction got stuck.
  if self.loading and (noctalia.nowMs() - self.loadingSince) < 30000 then
    return false
  end

  self:_startExtraction(path, self:cacheDir(path, size), size)
  return false
end

-- Frame for an elapsed time, looping over the animation.
function Gif:frameAt(elapsedMs)
  if not self:ready() then
    return nil
  end
  if self.totalMs <= 0 then
    return self.frames[1]
  end

  local position = elapsedMs % self.totalMs
  local acc = 0
  for i, duration in ipairs(self.durations) do
    acc = acc + duration
    if position < acc then
      return self.frames[i]
    end
  end
  return self.frames[#self.frames]
end

return Gif
