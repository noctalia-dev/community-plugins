--!nonstrict
-- Screen Capture — pre-recording menu.
--
-- The Omarchy-style "ask first" surface, built with Noctalia's declarative ui.*
-- vocabulary. It owns no backend: it asks for the capture source, the audio
-- source and whether to overlay the webcam, then publishes the choice to the
-- service and closes itself so nothing of the menu is captured.
--
-- Open it from the bar widget / Control Center tile (left click), or with
-- `noctalia msg panel-toggle amaurisd97/screen-capture:menu`.

-- Values are stable ids, matched to the localized labels by index; the service
-- validates them again. Never derive a value from the displayed text.
local SOURCES = { "region", "window", "fullscreen" }
local AUDIOS = { "none", "default_output", "default_input", "both" }

local sourceIndex = 0 -- zero-based, as ui.select wants
local audioIndex = 3 -- "both"
local webcam = false
local hasWebcam = false

local function tr(key)
  return noctalia.tr(key)
end

local function indexOf(list, value)
  for i, entry in ipairs(list) do
    if entry == value then
      return i - 1
    end
  end
  return nil
end

local function section(title, control)
  return ui.column({ gap = 8 }, {
    ui.label({ text = title, fontWeight = "medium", color = "on_surface_variant" }),
    control,
  })
end

local function render()
  local rows = {
    ui.label({ text = tr("panel.title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),

    section(tr("panel.source.label"), ui.select({
      options = {
        tr("panel.source.region"),
        tr("panel.source.window"),
        tr("panel.source.fullscreen"),
      },
      selectedIndex = sourceIndex,
      onChange = "onSource",
    })),

    section(tr("panel.audio.label"), ui.select({
      options = {
        tr("settings.audio_source.options.none"),
        tr("settings.audio_source.options.default_output"),
        tr("settings.audio_source.options.default_input"),
        tr("settings.audio_source.options.both"),
      },
      selectedIndex = audioIndex,
      onChange = "onAudio",
    })),
  }

  -- Only offered when a camera actually exists, like Omarchy's webcam entry.
  if hasWebcam then
    table.insert(rows, ui.row({ gap = 12, align = "center" }, {
      ui.toggle({ checked = webcam, onChange = "onWebcam" }),
      ui.label({ text = tr("panel.webcam.label"), flexGrow = 1 }),
    }))
  end

  table.insert(rows, ui.row({ gap = 8, justify = "end" }, {
    ui.button({ text = tr("panel.cancel"), variant = "ghost", onClick = "onCancel" }),
    ui.button({ text = tr("panel.record"), variant = "primary", onClick = "onRecord" }),
  }))

  panel.render(ui.column({ flexGrow = 1, gap = 16, padding = 4 }, rows))
end

local function detectWebcam()
  local dir = noctalia.pluginDir()
  if not dir then
    return
  end
  noctalia.runAsync({ dir .. "/scripts/webcam-list.sh" }, function(result)
    hasWebcam = (result.stdout or ""):match("%S") ~= nil
    render()
  end)
end

function onOpen()
  -- Seed from the last run when there is one, otherwise from the plugin
  -- settings; the user's in-panel tweaks live only while the panel is open.
  local status = noctalia.state.get("status")
  local remembered = type(status) == "table" and status.choice or nil

  if type(remembered) == "table" then
    sourceIndex = indexOf(SOURCES, remembered.source) or 0
    audioIndex = indexOf(AUDIOS, remembered.audio)
      or indexOf(AUDIOS, noctalia.getConfig("audio_source") or "both") or 3
    webcam = remembered.webcam == true
  else
    sourceIndex = indexOf(SOURCES, "region") or 0
    audioIndex = indexOf(AUDIOS, noctalia.getConfig("audio_source") or "both") or 3
    webcam = false
  end

  hasWebcam = false
  render()
  detectWebcam()
end

function onSource(index, _text)
  sourceIndex = tonumber(index) or 0
  render()
end

function onAudio(index, _text)
  audioIndex = tonumber(index) or 0
  render()
end

function onWebcam(value)
  webcam = value == true or tostring(value) == "true"
  render()
end

function onRecord()
  noctalia.state.set("command", {
    action = "start",
    source = SOURCES[sourceIndex + 1] or "region",
    audio = AUDIOS[audioIndex + 1] or "both",
    webcam = hasWebcam and webcam or false,
    nonce = os.time(),
  })
  panel.close()
end

function onCancel()
  panel.close()
end
