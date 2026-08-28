--!nonstrict
-- Control Center tile backed by the same service as the bar widget.

local status = {
  state = "checking",
  available = false,
  busy = false,
}

local function render()
  local state = status.state
  local label = noctalia.tr("shortcut.off")

  if state == "connected" then
    label = noctalia.tr("shortcut.on")
  elseif state == "connecting" then
    label = noctalia.tr("status.connecting")
  elseif state == "disconnecting" then
    label = noctalia.tr("status.disconnecting")
  elseif state == "error" then
    label = noctalia.tr("shortcut.error")
  elseif state == "unavailable" then
    label = noctalia.tr("shortcut.unavailable")
  end

  shortcut.setLabel(label)
  shortcut.setIcon("cloud-lock", "cloud-off")
  shortcut.setActive(state == "connected" or state == "connecting")
  shortcut.setEnabled(status.available and not status.busy)
end

local function applyStatus(value)
  if type(value) == "table" then
    status.state = value.state or "checking"
    status.available = value.available == true
    status.busy = value.busy == true
  end
  render()
end

function onClick()
  if status.available and not status.busy then
    noctalia.state.set("warp.command", { action = "toggle" })
  end
end

function onRightClick()
  noctalia.state.set("warp.command", { action = "refresh" })
end

applyStatus(noctalia.state.get("warp.status"))
noctalia.state.watch("warp.status", applyStatus)
