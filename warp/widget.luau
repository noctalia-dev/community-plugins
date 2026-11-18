--!nonstrict
-- Bar widget: left click opens the status panel; right click toggles WARP.

local status = {
  state = "checking",
  available = false,
  busy = false,
  message = "",
}

local function send(action)
  noctalia.state.set("warp.command", { action = action })
end

local function stateLabel(state)
  local known = {
    checking = true,
    connected = true,
    connecting = true,
    disconnecting = true,
    disconnected = true,
    unavailable = true,
    error = true,
  }
  return noctalia.tr(if known[state] then `status.{state}` else "status.error")
end

local function render()
  local state = status.state
  local glyph = "cloud-question"
  local color = "on_surface_variant"

  if state == "connected" then
    glyph = "cloud-lock"
    color = "primary"
  elseif state == "connecting" or state == "disconnecting" then
    glyph = "loader-2"
    color = "secondary"
  elseif state == "disconnected" then
    glyph = "cloud-off"
  elseif state == "unavailable" or state == "error" then
    glyph = "cloud-exclamation"
    color = "error"
  end

  local tooltip = `{noctalia.tr("title")}: {stateLabel(state)}`
  if status.message ~= "" then
    tooltip ..= `\n{status.message}`
  end

  barWidget.setGlyph(glyph)
  barWidget.setGlyphColor(color)
  barWidget.setTooltip(tooltip)
  barWidget.setVisible(true)
end

local function applyStatus(value)
  if type(value) == "table" then
    status.state = value.state or "checking"
    status.available = value.available == true
    status.busy = value.busy == true
    status.message = value.message or ""
  end
  render()
end

function onClick()
  noctalia.togglePanel("levi/warp:panel")
end

function onRightClick()
  if not status.busy then
    send("toggle")
  end
end

function onIpc(event, _payload)
  if event == "toggle" or event == "refresh" then
    send(event)
  end
end

applyStatus(noctalia.state.get("warp.status"))
noctalia.state.watch("warp.status", applyStatus)
