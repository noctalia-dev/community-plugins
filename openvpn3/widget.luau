--!nonstrict
-- Bar widget: click opens the panel, right click connects / disconnects.

local status = { state = "checking", available = false, busy = false, message = "", sessions = {}, busyProfile = "" }

local function send(action)
  noctalia.state.set("openvpn3.command", { action = action, nonce = noctalia.nowMs() })
end

local function stateLabel(state)
  local known = {
    checking = true, connected = true, connecting = true, paused = true,
    attention = true, disconnected = true, unavailable = true, error = true,
  }
  return noctalia.tr(if known[state] then `status.{state}` else "status.error")
end

local function activeSession()
  for _, s in ipairs(status.sessions) do
    if s.state == "connected" then
      return s
    end
  end
  return status.sessions[1]
end

local function render()
  local state = status.state
  local glyph = "shield-off"
  local color = "on_surface_variant"

  if state == "connected" then
    glyph = "shield-lock"
    color = "primary"
  elseif state == "connecting" then
    glyph = "loader-2"
    color = "secondary"
  elseif state == "paused" or state == "attention" then
    glyph = "shield-exclamation"
    color = "secondary"
  elseif state == "unavailable" or state == "error" then
    glyph = "shield-x"
    color = "error"
  end

  local session = activeSession()
  local text = ""
  if noctalia.getConfig("display_mode") ~= "icon" then
    if state == "connecting" and status.busyProfile ~= "" then
      text = status.busyProfile
    elseif session ~= nil and state ~= "disconnected" then
      text = session.config
    end
  end

  barWidget.setGlyph(glyph)
  barWidget.setGlyphColor(color)
  barWidget.setText(text)
  barWidget.setColor(color)

  local rows = { { noctalia.tr("title"), stateLabel(state) } }
  if session ~= nil and state ~= "disconnected" then
    table.insert(rows, { noctalia.tr("panel.sessions"), session.config })
    if session.device ~= "" then
      table.insert(rows, { noctalia.tr("panel.device"), session.device })
    end
    if session.remote ~= "" then
      table.insert(rows, { noctalia.tr("panel.server"), session.remote })
    end
  end
  if status.message ~= "" then
    table.insert(rows, { noctalia.tr("status.error"), status.message })
  end
  barWidget.setTooltip(rows)
  barWidget.setVisible(true)
end

local function applyStatus(value)
  if type(value) == "table" then
    status.state = value.state or "checking"
    status.available = value.available == true
    status.busy = value.busy == true
    status.busyProfile = value.busyProfile or ""
    status.message = value.message or ""
    status.sessions = value.sessions or {}
  end
  render()
end

function onClick()
  noctalia.togglePanel("vinioli/openvpn3:panel")
end

function onRightClick()
  if status.state == "connecting" then
    send("cancel-auth")
  elseif status.available and not status.busy then
    send("toggle")
  end
end

applyStatus(noctalia.state.get("openvpn3.status"))
noctalia.state.watch("openvpn3.status", applyStatus)

-- The picker window closes the panel while it is open; it asks the widget to bring
-- the panel back so it appears at the widget again. One bar instance handles each
-- request even when several bars carry the widget.
noctalia.state.watch("openvpn3.command", function(command)
  if type(command) ~= "table" or command.action ~= "reopen-panel" then
    return
  end
  local claim = noctalia.state.get("openvpn3.reopen")
  if type(claim) == "table" and claim.nonce == command.nonce then
    return
  end
  noctalia.state.set("openvpn3.reopen", { nonce = command.nonce })
  noctalia.togglePanel("vinioli/openvpn3:panel")
end)
