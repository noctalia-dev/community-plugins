--!nonstrict
-- Album art cache. ui.image takes local files only, so thumbnailUrl is downloaded into
-- pluginDataDir()/art/, at most 4 downloads at a time, and the oldest files (by mtime) go past ~80 items.
--
-- The URL is fetched as given, as the Sonolith spec asks; Sonolith hands out ~1200 px art. Decoding that
-- for a 32 px queue row stalls the panel, so when ImageMagick is installed each image is scaled down
-- locally into <id>.jpg (512 px, big art) and <id>.t.jpg (128 px, bar and lists). Without it both
-- names point at the original.
--
--   art.fetch(id, url, function(full, thumb) ... end, front)
--   art.cached(id) -> full, thumb (or nil)

local M = {}

local MAX_ITEMS = 80
local MAX_ACTIVE = 4
local PRUNE_EVERY = 10
local FULL_SIZE = "512x512>"
local THUMB_SIZE = "128x128>"

local dir = nil
local queue = {}
local waiting = {} -- id -> { callbacks }
local active = 0
local finished = 0
local magick = nil -- argv prefix, false when absent

local function artDir()
  if not dir then
    local base = noctalia.pluginDataDir()
    if not base then
      return nil
    end
    dir = base .. "/art"
    noctalia.mkdirAll(dir)
  end
  return dir
end

local function magickArgv()
  if magick == nil then
    if noctalia.commandExists("magick") then
      magick = { "magick" }
    elseif noctalia.commandExists("convert") then
      magick = { "convert" }
    else
      magick = false
    end
  end
  return magick
end

local function safeId(id)
  return (string.gsub(id, "[^%w_%-]", "_"))
end

local function paths(id)
  local d = artDir()
  if not d or not id then
    return nil, nil
  end
  local base = `{d}/{safeId(id)}`
  return base .. ".jpg", base .. ".t.jpg"
end

-- full, thumb for a cached item; thumb falls back to full when nothing could scale it.
function M.cached(id)
  local full, thumb = paths(id)
  if not full or not noctalia.fileExists(full) then
    return nil, nil
  end
  if noctalia.fileExists(thumb) then
    return full, thumb
  end
  if magickArgv() then
    return nil, nil -- an older, unscaled file: scale it first
  end
  return full, full
end

function M.prune()
  local d = artDir()
  local names = d and noctalia.listDir(d)
  if not names or #names <= MAX_ITEMS * 2 then
    return
  end
  local files = {}
  for _, name in ipairs(names) do
    local path = `{d}/{name}`
    local info = noctalia.fileInfo(path)
    if info and not info.isDir then
      table.insert(files, { path = path, mtime = info.mtime })
    end
  end
  table.sort(files, function(a, b)
    return a.mtime < b.mtime
  end)
  for i = 1, #files - MAX_ITEMS * 2 do
    noctalia.removeFile(files[i].path)
  end
end

local function finish(id, full, thumb)
  local cbs = waiting[id] or {}
  waiting[id] = nil
  for _, cb in ipairs(cbs) do
    cb(full, thumb)
  end
end

-- Scales `src` into full + thumb; `src` may be `full` itself (an older cache file).
local function scale(src, full, thumb, done)
  local argv = table.clone(magickArgv())
  for _, a in ipairs({
    src, "-strip",
    "(", "+clone", "-resize", THUMB_SIZE, "-quality", "85", "-write", thumb .. ".tmp.jpg", "+delete", ")",
    "-resize", FULL_SIZE, "-quality", "90", full .. ".tmp.jpg",
  }) do
    table.insert(argv, a)
  end
  local started = noctalia.runAsync(argv, function(r)
    if r.exitCode == 0 and noctalia.renameFile(thumb .. ".tmp.jpg", thumb) and noctalia.renameFile(full .. ".tmp.jpg", full) then
      if src ~= full then
        noctalia.removeFile(src)
      end
      done(true)
    else
      noctalia.removeFile(thumb .. ".tmp.jpg")
      noctalia.removeFile(full .. ".tmp.jpg")
      done(false)
    end
  end, 15000)
  if not started then
    done(false)
  end
end

local function pump()
  while active < MAX_ACTIVE and #queue > 0 do
    local job = table.remove(queue, 1)
    local full, thumb = paths(job.id)
    active += 1

    local function done(fullPath, thumbPath)
      active -= 1
      finished += 1
      if finished % PRUNE_EVERY == 0 then
        M.prune()
      end
      finish(job.id, fullPath, thumbPath)
      pump()
    end

    -- When scaling fails, the original still beats nothing.
    local function scaled(ok)
      if ok then
        done(full, thumb)
      else
        done(full, full)
      end
    end

    if noctalia.fileExists(full) then
      scale(full, full, thumb, scaled) -- an unscaled original from before
    else
      -- Download to .part, so a half-written file is never shown or taken for a cached one.
      local part = full .. ".part"
      local started = noctalia.download(job.url, part, function(ok)
        if not ok then
          noctalia.removeFile(part)
          done(nil, nil)
        elseif magickArgv() then
          scale(part, full, thumb, function(scaledOk)
            if not scaledOk then
              noctalia.renameFile(part, full)
            end
            scaled(scaledOk)
          end)
        elseif noctalia.renameFile(part, full) then
          done(full, full)
        else
          done(nil, nil)
        end
      end)
      if not started then
        done(nil, nil)
      end
    end
  end
end

-- cb(full, thumb) - both nil on failure. Calls back at once for a cached item and joins a download already
-- on its way. `front` puts the job ahead of the queue (the current track before list thumbnails).
function M.fetch(id, url, cb, front)
  local full, thumb = M.cached(id)
  if full then
    cb(full, thumb)
    return
  end
  local path = paths(id)
  if not path or (type(url) ~= "string" or url == "") and not noctalia.fileExists(path) then
    cb(nil, nil)
    return
  end
  if waiting[id] then
    table.insert(waiting[id], cb)
    return
  end
  waiting[id] = { cb }
  local job = { id = id, url = url }
  if front then
    table.insert(queue, 1, job)
  else
    table.insert(queue, job)
  end
  pump()
end

-- Drops queued (not started) downloads, e.g. when a panel closes.
function M.clearQueue()
  local dropped = queue
  queue = {}
  for _, job in ipairs(dropped) do
    finish(job.id, nil, nil)
  end
end

return M
