--[[
Sticker display router, shared by the trigger service and the bar tile.

The sticker is drawn by a companion process (bin/reaction-overlay.py) that
creates a transparent layer-shell surface: no theme card behind the image, it
floats above fullscreen windows and ignores input completely. This module owns
the whole show/hide path:

* It probes the companion once (python3 + GTK3 + gtk-layer-shell). The probe is
  optimistic until it answers.
* With the overlay, `show` picks a sticker from the configured folder (or the
  single fallback file), plays the sound and (re)spawns the sticker; a second
  trigger while it is on screen replaces the running instance, which restarts
  the animation.
* Without it, everything falls back to the `miixz/reaction:sticker` panel: a
  shell-native surface that always paints the theme card. The panel plays its
  own sound and tracks its own visibility, so this module only toggles it.

Each entry script runs in its own Luau runtime (the service and the bar tile),
so every caller gets its own instance of this module. The shared frame cache on
 disk keeps that cheap, and we keep one Gif instance per source path so changing
from one trigger to the next does not force a re-extraction.
]]

local Gif = require("./gif.luau")

local PANEL_ID = "miixz/reaction:sticker"
local TAG = "miixz-reaction"

-- The overlay fades out over this long during its last moments on screen.
local FADE_MS = 250
local DEFAULT_HOLD_MS = 2500

-- Very short GIFs loop until they have been on screen at least this long.
local MIN_GIF_HOLD_MS = 1500

-- Distance from the screen edge, in Noctalia logical pixels. Matches the
-- shell's floating-offset so the sticker is placed like other floating panels.
local MARGIN = 8

local dataDir = noctalia.pluginDataDir() or ("/tmp/noctalia-reaction-" .. tostring(os.time()))

-- One Gif extractor per source path. Keeps each animation ready after the first
-- extraction, even as the active sticker changes on every trigger.
local clips = {}

-- nil = not probed yet, true/false = companion usable or not.
local overlay = nil

-- Sound bank: one loaded sound per configured path.
local sound = { path = nil, name = nil, ready = false, pending = false }

local Sticker = {}

local SUPPORTED_EXTS = {
  ["png"] = true,
  ["jpg"] = true,
  ["jpeg"] = true,
  ["webp"] = true,
  ["svg"] = true,
  ["gif"] = true,
}

local function setting(key, fallback)
  local value = noctalia.getConfig(key)
  if value == nil then
    return fallback
  end
  return value
end

local function stickerPath()
  return setting("sticker_path", "")
end

local function stickerDir()
  return setting("sticker_dir", "")
end

local function selectionMode()
  return setting("sticker_selection", "random")
end

local function sizePx()
  return math.max(64, math.floor(setting("size_px", 420)))
end

local function scriptPath()
  local dir = noctalia.pluginDir()
  if dir == nil or dir == "" then
    return nil
  end
  return dir .. "/bin/reaction-overlay.py"
end

local function soundPath()
  return setting("sound_path", "")
end

local function ensureSound()
  local path = soundPath()
  if path == "" or sound.path == path then
    return
  end

  sound.path = path
  sound.name = path:match("([^/]+)$") or "sticker"
  sound.ready = false
  sound.pending = false

  local accepted = noctalia.sound.load(sound.name, path, function(ok, err)
    if not ok then
      noctalia.log("reaction: could not load sound: " .. tostring(err))
      return
    end
    sound.ready = true
    if sound.pending then
      sound.pending = false
      noctalia.sound.play(sound.name)
    end
  end)

  if not accepted then
    noctalia.log("reaction: sound load request was rejected")
  end
end

local function playSound()
  local path = soundPath()
  if path == "" then
    return
  end

  ensureSound()

  -- The configured sound changed since it was loaded: the load callback plays
  -- the new sample instead of playing the wrong one now.
  if sound.path ~= path then
    return
  end

  if sound.ready then
    noctalia.sound.play(sound.name)
  else
    sound.pending = true
  end
end

local function getClip(path)
  if clips[path] == nil then
    clips[path] = Gif.new({ dataDir = dataDir, onLog = noctalia.log })
  end
  return clips[path]
end

-- Resolve all supported images in the configured folder, or fall back to the
-- single sticker_path file.
function Sticker.candidates()
  local dir = stickerDir()
  local candidates = {}

  if dir ~= "" then
    dir = noctalia.expandPath(dir) or dir
    local entries = noctalia.listDir(dir)
    if entries then
      for _, name in ipairs(entries) do
        local ext = name:lower():match("%.([^.]+)$")
        if ext and SUPPORTED_EXTS[ext] then
          table.insert(candidates, dir .. "/" .. name)
        end
      end
      table.sort(candidates)
    end
  end

  if #candidates == 0 then
    local single = stickerPath()
    if single ~= "" then
      table.insert(candidates, single)
    end
  end

  return candidates
end

local function pick(candidates)
  local n = #candidates
  if n == 0 then
    return nil
  end
  if n == 1 then
    return candidates[1]
  end

  if selectionMode() == "sequential" then
    local last = noctalia.state.get("seq_index") or 0
    local idx = (last % n) + 1
    noctalia.state.set("seq_index", idx)
    return candidates[idx]
  end

  return candidates[math.random(1, n)]
end

-- One-off check that the companion can run. A missing python3 or a failed
-- import flips the whole module to the panel fallback.
local function probe()
  if overlay ~= nil then
    return overlay
  end

  local script = scriptPath()
  if script == nil or not noctalia.commandExists("python3") then
    overlay = false
    return false
  end

  overlay = true
  noctalia.runAsync({ "python3", script, "--probe" }, function(result)
    if result.exitCode ~= 0 then
      overlay = false
      noctalia.log("reaction: overlay unavailable, using the panel: " .. tostring(result.stderr))
    end
  end)
  return true
end

-- How long the sticker stays on screen: the GIF's measured duration plus
-- extra_ms, looped if needed to reach MIN_GIF_HOLD_MS, or hold_ms for still
-- images and while the frames are extracting.
local function holdMs(path)
  if path and Gif.isGif(path) then
    local clip = getClip(path)
    clip:setSource(path, sizePx())
    if clip:ready() then
      local ms = clip:durationMs() + math.max(0, math.floor(setting("extra_ms", 250)))
      return math.max(MIN_GIF_HOLD_MS, ms)
    end
  end
  return math.max(200, math.floor(setting("hold_ms", DEFAULT_HOLD_MS)))
end

-- Directory of pre-extracted PNG frames for an animated GIF, or nil when they
-- are not ready (still extracting) or the sticker is a still image. The
-- overlay plays these static frames instead of decoding the GIF: same look,
-- but its memory stays flat instead of growing frame by frame.
local function framesDir(path)
  if not path or not Gif.isGif(path) then
    return nil
  end
  local clip = getClip(path)
  clip:setSource(path, sizePx())
  if not clip:ready() then
    return nil
  end
  return clip:framesDir(path, sizePx())
end

function Sticker.isVisible()
  return noctalia.state.get("visible") == true
end

-- True only while the sticker is expected to be on screen. The panel also
-- flips `visible` by itself on open/close; when that happens without this
-- module recording an expiry, the panel's own state is trusted.
local function visibleNow()
  if not Sticker.isVisible() then
    return false
  end
  local untilMs = noctalia.state.get("visible_until") or 0
  return untilMs == 0 or noctalia.nowMs() <= untilMs
end

local function rememberVisible(hold)
  noctalia.state.set("visible", true)
  noctalia.state.set("visible_until", noctalia.nowMs() + hold)
end

-- Pre-extract frames for every candidate GIF so the first trigger is instant.
function Sticker.warm()
  for _, path in ipairs(Sticker.candidates()) do
    if Gif.isGif(path) then
      local clip = getClip(path)
      clip:setSource(path, sizePx())
    end
  end
end

function Sticker.isReady(path)
  if not path or path == "" then
    return false
  end
  if not Gif.isGif(path) then
    return true
  end
  local clip = getClip(path)
  clip:setSource(path, sizePx())
  return clip:ready()
end

function Sticker.show()
  local candidates = Sticker.candidates()
  local path = pick(candidates)

  if path == nil or path == "" then
    -- Nothing configured: the panel shows the setup hint (with its card).
    noctalia.togglePanel(PANEL_ID)
    return
  end

  -- Publish the chosen path so the panel fallback (a separate runtime) shows
  -- the same sticker instead of reading the config again.
  noctalia.state.set("current_path", path)

  local hold = holdMs(path)

  if probe() then
    playSound()
    local args = {
      "python3", scriptPath(),
      "--path", path,
      "--position", tostring(setting("sticker_position", "center")),
      "--size", tostring(sizePx()),
      "--duration", tostring(hold),
      "--fade", tostring(FADE_MS),
      "--opacity", tostring(setting("opacity", 1.0)),
      "--margin", tostring(MARGIN),
      "--tag", TAG,
    }
    local dir = framesDir(path)
    if dir then
      table.insert(args, "--frames-dir")
      table.insert(args, dir)
    end
    local launched = noctalia.runAsync(args)
    if not launched then
      noctalia.log("reaction: could not launch the overlay")
      return
    end

    rememberVisible(hold)
    return
  end

  -- Panel fallback: the panel plays the sound and flips `visible` itself.
  if visibleNow() then
    noctalia.state.set("restart", (noctalia.state.get("restart") or 0) + 1)
  else
    noctalia.togglePanel(PANEL_ID)
  end
  rememberVisible(hold)
end

function Sticker.hide()
  if probe() then
    if Sticker.isVisible() then
      noctalia.runAsync({ "python3", scriptPath(), "--hide", "--tag", TAG })
    end
  elseif visibleNow() then
    noctalia.togglePanel(PANEL_ID)
  end

  noctalia.state.set("visible", false)
  noctalia.state.set("visible_until", 0)
end

-- Called from the service's update loop. Clears the bookkeeping this module
-- set once the sticker's time is over; the panel clears its own state when it
-- closes and the overlay simply stops existing.
function Sticker.tick()
  if not Sticker.isVisible() then
    return
  end

  local untilMs = noctalia.state.get("visible_until") or 0
  if untilMs > 0 and noctalia.nowMs() > untilMs then
    noctalia.state.set("visible", false)
    noctalia.state.set("visible_until", 0)
  end
end

-- Seed once so random selection is actually varied across triggers.
math.randomseed(noctalia.nowMs())

return Sticker
