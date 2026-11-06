--[[
Reaction panel: the sticker itself.

Draws the sticker (static image or animated GIF) centered on the focused output,
plays a sound and closes itself when the animation ends. The manifest declares
it floating + overlay + keyboard_focus = "none", so it sits above fullscreen
windows without taking the keyboard away from the application in use.

The panel runtime only exists while the panel is open, so the trigger logic
lives in service.luau: the service opens this panel, and restarts it over the
plugin state channel when the sticker is already on screen. The active sticker
path is published by the service as `current_path`; this panel reads that first
and only falls back to the configured folder/file if it is missing.
]]

local PANEL_ID = "miixz/reaction:sticker"

-- Fallbacks used before the first setting read, or when a sticker has no
-- measurable duration (static images, failed extraction).
local DEFAULT_HOLD_MS = 2500
local FADE_MS = 250

-- Very short GIFs loop until they have been on screen at least this long.
local MIN_GIF_HOLD_MS = 1500

-- How long to keep waiting for a still-loading GIF before giving up on it.
local LOAD_GRACE_MS = 8000

local dataDir = noctalia.pluginDataDir() or ("/tmp/noctalia-reaction-" .. tostring(os.time()))

local Gif = require("./lib/gif.luau")

local clip = Gif.new({ dataDir = dataDir, onLog = noctalia.log })

-- Panel state.
local visible = false
local elapsedMs = 0

-- Sound bank: one loaded sound per configured path.
local sound = { path = nil, name = nil, ready = false, pending = false }

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

local function firstCandidate()
  local dir = setting("sticker_dir", "")
  if dir ~= "" then
    dir = noctalia.expandPath(dir) or dir
    local entries = noctalia.listDir(dir)
    if entries then
      table.sort(entries)
      for _, name in ipairs(entries) do
        local ext = name:lower():match("%.([^.]+)$")
        if ext and SUPPORTED_EXTS[ext] then
          return dir .. "/" .. name
        end
      end
    end
  end
  return setting("sticker_path", "")
end

local function stickerPath()
  local active = noctalia.state.get("current_path")
  if active and active ~= "" then
    return active
  end
  return firstCandidate()
end

local function boxPx()
  return math.max(64, math.floor(setting("size_px", 420)))
end

local function soundPath()
  return setting("sound_path", "")
end

local function isAnimated()
  return Gif.isGif(stickerPath())
end

-- How long the sticker stays on screen. Short GIFs loop to reach the minimum.
local function holdMs()
  if isAnimated() and clip:ready() then
    local ms = clip:durationMs() + math.max(0, math.floor(setting("extra_ms", 250)))
    return math.max(MIN_GIF_HOLD_MS, ms)
  end
  return math.max(200, math.floor(setting("hold_ms", DEFAULT_HOLD_MS)))
end

-- Group opacity for the current frame, fading out at the end of the hold.
local function alpha()
  local base = setting("opacity", 1.0)
  local remaining = holdMs() - elapsedMs
  if remaining <= 0 then
    return 0
  end
  if remaining < FADE_MS then
    return base * (remaining / FADE_MS)
  end
  return base
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

local function render()
  local path = stickerPath()
  local px = boxPx()

  if path == "" then
    -- Setup hint: only reachable while no sticker is configured, and it closes
    -- itself like any other sticker.
    panel.render(ui.column({ align = "center", justify = "center", gap = 8, fill = "#00000000" }, {
      ui.glyph({ name = "photo", size = 48, color = "on_surface_variant", opacity = alpha() }),
      ui.label({ text = noctalia.tr("panel.no_sticker"), color = "on_surface_variant", opacity = alpha() }),
    }))
    return
  end

  local frame = path
  if Gif.isGif(path) then
    clip:setSource(path, px)
    frame = clip:frameAt(elapsedMs)
  end

  if frame == nil then
    -- Frames are still being extracted: keep the surface empty rather than
    -- showing a spinner that would look broken over the desktop.
    panel.render(ui.box({ width = px, height = px, fill = "#00000000" }))
    return
  end

  panel.render(ui.column({
    align = "center",
    justify = "center",
    fill = "#00000000",
    opacity = alpha(),
  }, {
    ui.image({ path = frame, width = px, height = px, fit = "contain" }),
  }))
end

local function start()
  elapsedMs = 0
  panel.setNeedsFrameTick(true)
  playSound()
  render()
end

function onOpen(_context)
  visible = true
  noctalia.state.set("visible", true)
  start()
end

function onClose()
  visible = false
  noctalia.state.set("visible", false)
  panel.setNeedsFrameTick(false)
end

function onFrameTick(deltaMs)
  if not visible then
    return
  end

  local path = stickerPath()
  if path ~= "" and Gif.isGif(path) then
    clip:setSource(path, boxPx())
  end

  elapsedMs = elapsedMs + (deltaMs or 0)

  -- Do not cut a slow first extraction short: wait for the frames while
  -- staying on screen, but give up after the grace period.
  if clip:isLoading() and not clip:ready() and elapsedMs < LOAD_GRACE_MS then
    render()
    return
  end

  if elapsedMs >= holdMs() then
    visible = false
    panel.close()
    return
  end

  render()
end

function onIpc(event, _payload)
  if event == "show" or event == "trigger" then
    if visible then
      -- Already on screen: restart the animation instead of closing it.
      start()
    else
      noctalia.togglePanel(PANEL_ID)
    end
  elseif event == "hide" then
    visible = false
    panel.close()
  end
end

-- The trigger service asks for a restart when a trigger arrives while the
-- sticker is already on screen.
noctalia.state.watch("restart", function()
  if visible then
    start()
  end
end)
