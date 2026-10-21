--!nonstrict
-- Screen Capture — bar widget.
--
-- A thin client. Left click opens the pre-recording panel (source, audio,
-- webcam); right click records again with the last choice, or stops whatever is
-- running. It sends commands and renders whatever the service publishes as
-- "status".

local state = "idle"
local available = true
local outputPath = ""

local PANEL_ID = "amaurisd97/screen-capture:menu"

local function send(action)
  noctalia.state.set("command", {
    action = action,
    nonce = os.time(),
    focusedOutputName = noctalia.focusedOutputName(),
  })
end

local function applyStatus(status)
  if type(status) == "table" then
    state = status.state or "idle"
    if status.available ~= nil then
      available = status.available
    end
    outputPath = status.outputPath or ""
  end

  local hideInactive = noctalia.getConfig("hide_inactive") == true

  local config = {
    idle = {
      glyph = "video",
      color = "on_surface",
      active = false,
      visible = true,
      tip = noctalia.tr("widget.idle"),
    },
    selecting = {
      glyph = "crop",
      color = "primary",
      active = true,
      visible = true,
      tip = noctalia.tr("widget.selecting"),
    },
    starting = {
      glyph = "crosshair",
      color = "primary",
      active = true,
      visible = true,
      tip = noctalia.tr("widget.starting"),
    },
    stopping = {
      glyph = "crosshair",
      color = "primary",
      active = true,
      visible = true,
      tip = noctalia.tr("widget.stopping"),
    },
    recording = {
      glyph = "disc",
      color = "error",
      active = true,
      visible = true,
      tip = noctalia.tr("widget.recording"),
    },
  }

  if not available then
    barWidget.setGlyph("video-off")
    barWidget.setGlyphColor("on_surface_variant")
    barWidget.setTooltip(noctalia.tr("widget.unavailable"))
    barWidget.setVisible(not hideInactive)
    return
  end

  local entry = config[state] or config.idle

  barWidget.setGlyph(entry.glyph)
  barWidget.setGlyphColor(entry.color)
  if type(barWidget.setColor) == "function" then
    barWidget.setColor(entry.color)
  end
  if type(barWidget.setActive) == "function" then
    barWidget.setActive(entry.active)
  end
  barWidget.setTooltip(entry.tip)
  barWidget.setVisible(entry.visible and not (hideInactive and state == "idle"))
end

function onClick()
  if not available then
    return
  end
  if state == "idle" then
    noctalia.togglePanel(PANEL_ID)
  else
    send("stop")
  end
end

function onRightClick()
  if not available then
    return
  end
  if state == "idle" then
    send("record-last")
  else
    send("stop")
  end
end

function onConfigChanged()
  applyStatus(noctalia.state.get("status"))
end

applyStatus(noctalia.state.get("status"))
noctalia.state.watch("status", applyStatus)
