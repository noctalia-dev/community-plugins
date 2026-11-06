--!nonstrict
-- Audio Reactive Sticker desktop widget.
--
-- Draws the configured image and fades it between idle_opacity and
-- active_opacity. Playback state comes from the plugin's monitor service,
-- which owns the PipeWire helper: this file never starts a process of its own,
-- so several stickers share one monitor.

local ACTIVE_KEY = "audio_sticker.active"
local STATUS_KEY = "audio_sticker.status"

local dataDir = noctalia.pluginDataDir()
if dataDir == nil then
  dataDir = ""
end

local active = noctalia.state.get(ACTIVE_KEY) == true
local status = noctalia.state.get(STATUS_KEY)

local opacity = 0.0
local currentOpacity = 0.0
local targetOpacity = 0.0

-- GIF animation state
local gifPath = nil
local gifFrames = nil
local gifDurations = nil
local gifTotalDuration = 0
local gifStartTime = 0
local gifLoading = false
local gifLoadStart = 0

local function isGif(path)
  return path:lower():match("%.gif$") ~= nil
end

local function gifCacheDir(path)
  local safe = path:gsub("[^a-zA-Z0-9_.-]", "_")
  safe = safe:gsub("%.gif$", "") -- avoid a directory name ending in .gif
  return dataDir .. "/gif-cache/" .. safe
end

local function parseFfmpegDurations(stdout)
  -- ffprobe outputs absolute PTS per frame in seconds.
  -- Convert those into per-frame durations by differencing consecutive PTS values.
  local durations = {}
  local total = 0
  local lastMs = 0
  for line in stdout:gmatch("[^\r\n]+") do
    local sec = tonumber(line)
    if sec then
      local ms = math.floor(sec * 1000)
      local dur = ms - lastMs
      lastMs = ms
      if dur <= 0 then
        dur = 33
      end
      table.insert(durations, dur)
      total = total + dur
    end
  end
  return durations, total
end

local CACHE_VERSION = 1

local function saveGifMetadata(cacheDir, frames, durations, totalDuration, sourceMtime, sourceSize)
  local meta = {
    frames = frames,
    durations = durations,
    totalDuration = totalDuration,
    sourceMtime = sourceMtime,
    sourceSize = sourceSize,
    cacheVersion = CACHE_VERSION,
  }
  local encoded = noctalia.json.encode(meta)
  if encoded ~= nil then
    noctalia.writeFile(cacheDir .. "/metadata.json", encoded)
  end
end

local function loadGifMetadata(cacheDir, path)
  local raw = noctalia.readFile(cacheDir .. "/metadata.json")
  if not raw then
    return false
  end
  local meta = noctalia.json.decode(raw)
  if type(meta) ~= "table" or type(meta.frames) ~= "table" then
    return false
  end

  -- Invalidate the cache when the source file changed or the cache format did.
  if meta.cacheVersion ~= CACHE_VERSION
    or meta.sourceMtime == nil
    or meta.sourceSize == nil then
    return false
  end

  local info = noctalia.fileInfo(path)
  if info then
    if meta.sourceMtime ~= info.mtime or meta.sourceSize ~= info.size then
      return false
    end
  end

  gifFrames = {}
  for _, name in ipairs(meta.frames) do
    table.insert(gifFrames, cacheDir .. "/" .. name)
  end
  gifDurations = meta.durations
  gifTotalDuration = meta.totalDuration or 0
  return true
end

local function finalizeFrames(cacheDir, frameCount, durations, totalDuration, sourceMtime, sourceSize)
  local frames = {}
  for i = 1, frameCount do
    local name = string.format("frame-%03d.png", i)
    table.insert(frames, name)
  end
  saveGifMetadata(cacheDir, frames, durations, totalDuration, sourceMtime, sourceSize)

  gifFrames = {}
  for _, name in ipairs(frames) do
    table.insert(gifFrames, cacheDir .. "/" .. name)
  end
  gifDurations = durations
  gifTotalDuration = totalDuration
  gifStartTime = noctalia.nowMs()
  gifLoading = false
end

local function extractWithFfmpeg(path, cacheDir, sourceMtime, sourceSize)
  noctalia.runAsync({
    "ffprobe", "-v", "error", "-select_streams", "v:0",
    "-show_entries", "frame=pts_time", "-of",
    "csv=p=0", path
  }, function(probe)
    if probe.exitCode ~= 0 then
      noctalia.log("audio-sticker: ffprobe failed: " .. (probe.stderr or ""))
      gifLoading = false
      return
    end

    local durations, totalDuration = parseFfmpegDurations(probe.stdout)
    local frameCount = #durations
    if frameCount == 0 then
      durations = { 100 }
      totalDuration = 100
      frameCount = 1
    end

    -- ffmpeg names frames 1-based.
    local cached = true
    for i = 1, frameCount do
      local framePath = string.format(cacheDir .. "/frame-%03d.png", i)
      if not noctalia.fileExists(framePath) then
        cached = false
        break
      end
    end

    if cached then
      finalizeFrames(cacheDir, frameCount, durations, totalDuration, sourceMtime, sourceSize)
      return
    end

    noctalia.runAsync({
      "ffmpeg", "-y", "-i", path,
      "-vf", "scale=320:-1:flags=lanczos",
      "-pix_fmt", "rgba",
      cacheDir .. "/frame-%03d.png"
    }, function(result)
      if result.exitCode ~= 0 then
        noctalia.log("audio-sticker: ffmpeg extraction failed: " .. (result.stderr or ""))
        gifLoading = false
        return
      end
      finalizeFrames(cacheDir, frameCount, durations, totalDuration, sourceMtime, sourceSize)
    end)
  end)
end

local function extractGifFrames(path)
  if gifLoading then
    -- If loading has been stuck for too long, allow a retry.
    if noctalia.nowMs() - gifLoadStart < 30000 then
      return
    end
    noctalia.log("audio-sticker: GIF extraction timed out, retrying")
  end

  if dataDir == "" then
    noctalia.log("audio-sticker: no plugin data directory, cannot cache GIF frames")
    return
  end

  if not noctalia.commandExists("ffmpeg") or not noctalia.commandExists("ffprobe") then
    noctalia.log("audio-sticker: ffmpeg is required for animated GIFs")
    return
  end

  gifLoading = true
  gifLoadStart = noctalia.nowMs()

  local cacheDir = gifCacheDir(path)
  noctalia.mkdirAll(cacheDir)

  local sourceInfo = noctalia.fileInfo(path)
  local sourceMtime = sourceInfo and sourceInfo.mtime or 0
  local sourceSize = sourceInfo and sourceInfo.size or 0

  -- Use cached metadata if the source file has not changed.
  if loadGifMetadata(cacheDir, path) then
    gifPath = path
    gifStartTime = noctalia.nowMs()
    gifLoading = false
    return
  end

  extractWithFfmpeg(path, cacheDir, sourceMtime, sourceSize)
end

local function currentGifFrame()
  if not gifFrames or #gifFrames == 0 then
    return nil
  end
  if gifTotalDuration <= 0 then
    return gifFrames[1]
  end

  local elapsed = (noctalia.nowMs() - gifStartTime) % gifTotalDuration

  local t = 0
  for i, dur in ipairs(gifDurations) do
    t = t + dur
    if elapsed < t then
      return gifFrames[i]
    end
  end
  return gifFrames[#gifFrames]
end

local function renderImage(path)
  if isGif(path) then
    if gifPath ~= path then
      extractGifFrames(path)
    end

    local frame = currentGifFrame()
    if frame then
      desktopWidget.render(
        ui.image({
          path = frame,
          width = 320,
          height = 320,
          opacity = opacity,
          fit = "contain",
        })
      )
      return
    end

    -- Still extracting frames.
    desktopWidget.render(
      ui.column({ align = "center", justify = "center" }, {
        ui.label({ text = noctalia.tr("widget.loading_gif"), color = "on_surface_variant" }),
      })
    )
    return
  end

  desktopWidget.render(
    ui.image({
      path = path,
      width = 320,
      height = 320,
      opacity = opacity,
      fit = "contain",
    })
  )
end

local function render()
  if status ~= nil and status.state == "error" then
    desktopWidget.render(
      ui.column({ align = "center", justify = "center", gap = 8 }, {
        ui.glyph({ name = "alert-triangle", size = 48, color = "error" }),
        ui.label({ text = status.message or noctalia.tr("widget.build_failed"), color = "on_surface_variant" }),
      })
    )
    return
  end

  local path = noctalia.getConfig("image_path") or ""
  if path == "" then
    desktopWidget.render(
      ui.column({ align = "center", justify = "center", gap = 8 }, {
        ui.glyph({ name = "photo", size = 48, color = "on_surface_variant" }),
        ui.label({ text = noctalia.tr("widget.no_image"), color = "on_surface_variant" }),
      })
    )
    return
  end

  renderImage(path)
end

local function resetGif()
  gifPath = nil
  gifFrames = nil
  gifDurations = nil
  gifTotalDuration = 0
  gifStartTime = 0
  gifLoading = false
  gifLoadStart = 0
end

local function opacityFor(isActive)
  if isActive then
    return noctalia.getConfig("active_opacity") or 1.0
  end
  return noctalia.getConfig("idle_opacity") or 0.0
end

local function setActive(isActive)
  active = isActive
  targetOpacity = opacityFor(isActive)
  -- Restart the GIF loop only when the sticker becomes visible again; config
  -- updates must not rewind it while audio keeps playing.
  if isActive and gifPath then
    gifStartTime = noctalia.nowMs()
  end
end

targetOpacity = opacityFor(active)

function update()
  desktopWidget.setNeedsFrameTick(true)

  local path = noctalia.getConfig("image_path") or ""
  if not isGif(path) then
    resetGif()
  elseif gifPath ~= path then
    extractGifFrames(path)
  end

  render()
end

function onFrameTick(deltaMs)
  -- Follow playback state even when the watch callback landed before this
  -- widget finished loading.
  local nowActive = noctalia.state.get(ACTIVE_KEY) == true
  if nowActive ~= active then
    setActive(nowActive)
  end

  local fadeMs = noctalia.getConfig("fade_ms") or 300
  if fadeMs <= 0 then
    currentOpacity = targetOpacity
  else
    local t = math.min(1.0, deltaMs / fadeMs)
    currentOpacity = currentOpacity + (targetOpacity - currentOpacity) * t
  end

  local needsRender = false
  if math.abs(currentOpacity - opacity) > 0.001 then
    opacity = currentOpacity
    needsRender = true
  end

  -- GIFs need continuous frame updates whenever visible.
  local path = noctalia.getConfig("image_path") or ""
  if isGif(path) and opacity > 0 then
    needsRender = true
  end

  if needsRender then
    render()
  end
end

noctalia.state.watch(ACTIVE_KEY, function(value)
  local isActive = value == true
  if isActive ~= active then
    setActive(isActive)
  end
end)

noctalia.state.watch(STATUS_KEY, function(value)
  status = value
  render()
end)

update()
