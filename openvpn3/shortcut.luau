--!nonstrict
-- Control Center tile backed by the same service as the bar widget.

local status = { state = "checking", available = false, busy = false }

local function render()
  local state = status.state
  local label = noctalia.tr("shortcut.off")

  if state == "connected" then
    label = noctalia.tr("shortcut.on")
  elseif state == "connecting" then
    label = noctalia.tr("status.connecting")
  elseif state == "paused" then
    label = noctalia.tr("status.paused")
  elseif state == "attention" then
    label = noctalia.tr("status.attention")
  elseif state == "error" then
    label = noctalia.tr("status.error")
  elseif state == "unavailable" then
    label = noctalia.tr("shortcut.unavailable")
  end

  shortcut.setLabel(label)
  shortcut.setIcon("shield-lock", "shield-off")
  shortcut.setActive(state == "connected" or state == "connecting")
  shortcut.setEnabled(status.available and (not status.busy or state == "connecting"))
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
  if status.state == "connecting" then
    noctalia.state.set("openvpn3.command", { action = "cancel-auth", nonce = noctalia.nowMs() })
  elseif status.available and not status.busy then
    noctalia.state.set("openvpn3.command", { action = "toggle", nonce = noctalia.nowMs() })
  end
end

function onRightClick()
  noctalia.state.set("openvpn3.command", { action = "refresh", nonce = noctalia.nowMs() })
end

applyStatus(noctalia.state.get("openvpn3.status"))
noctalia.state.watch("openvpn3.status", applyStatus)
