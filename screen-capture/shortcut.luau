--!nonstrict
-- Screen Capture — control-center tile.
--
-- Mirrors the bar widget: left click opens the pre-recording panel, right click
-- records again with the last choice or stops. State comes from the service
-- through shared plugin state, so the tile is correct even with no widget placed
-- on a bar.

local state = "idle"
local available = true

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
  end

  local labels = {
    idle = noctalia.tr("shortcut.idle"),
    selecting = noctalia.tr("shortcut.selecting"),
    starting = noctalia.tr("shortcut.starting"),
    stopping = noctalia.tr("shortcut.stopping"),
    recording = noctalia.tr("shortcut.recording"),
  }

  local icons = {
    idle = "crop",
    selecting = "crosshair",
    starting = "crosshair",
    stopping = "crosshair",
    recording = "disc",
  }

  shortcut.setLabel(labels[state] or labels.idle)
  shortcut.setIcon(icons[state] or icons.idle)
  shortcut.setActive(state == "recording" or state == "selecting" or
    state == "starting" or state == "stopping")
  shortcut.setEnabled(available)
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

applyStatus(noctalia.state.get("status"))
noctalia.state.watch("status", applyStatus)
