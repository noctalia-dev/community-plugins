--!nonstrict
-- Pure presentation model: kernel check, error wording, tile view, panel state, row views.

local model = {}

local function tr(key, subst)
  if noctalia and noctalia.tr then
    return noctalia.tr(key, subst)
  end
  return key
end

-- noctalia.tr has no plural forms: a count message is a pair <base>_one / <base>_other.
function model.countKey(base, n)
  if n == 1 then
    return base .. "_one"
  end
  return base .. "_other"
end

-- Keys the panel view renders: button label per rowView.button, plus fixed lines.
model.BUTTON_KEYS = {
  connect = "button.connect",
  disconnect = "button.disconnect",
  open_gui = "button.open_gui",
}
model.DNS_KEY = "panel.dns"
-- Glyph colour of a connected tile; a literal hex like the UFW plugin's green.
model.GREEN = "#22c55e"
model.SERVICE_HINT_KEY = "panel.service_hint"

-- ── kernel check (spec §7.3) ─────────────────────────────────────────────────

function model.rebootNeeded(facts)
  if type(facts) ~= "table" or facts.wgLoaded then
    return false
  end
  if not facts.moduleDirExists then
    return true
  end
  for _, name in ipairs(facts.wgModuleFiles or {}) do
    if name:sub(1, 12) == "wireguard.ko" then
      return false
    end
  end
  return true
end

-- ── wording ──────────────────────────────────────────────────────────────────

function model.connectError(outcome, rebootNeeded)
  if rebootNeeded then
    return { key = "error.reboot_needed" }
  end
  local kind = outcome and outcome.kind
  if kind == "signin" then
    return { key = "error.needs_signin" }
  end
  if kind == "timeout" then
    return { key = "error.connect_timeout" }
  end
  if outcome and outcome.detail and outcome.detail ~= "" then
    return { key = "error.connect_failed_detail", detail = outcome.detail }
  end
  return { key = "error.connect_failed" }
end

function model.disconnectError(outcome)
  local kind = outcome and outcome.kind
  if kind == "timeout" then
    return { key = "error.disconnect_timeout" }
  end
  if outcome and outcome.detail and outcome.detail ~= "" then
    return { key = "error.disconnect_failed_detail", detail = outcome.detail }
  end
  return { key = "error.disconnect_failed" }
end

function model.rowTitle(c)
  if c.name ~= nil and c.name ~= "" then
    return c.name
  end
  return c.host
end

local function errorText(err)
  if err.detail ~= nil then
    return tr(err.key, { detail = err.detail })
  end
  return tr(err.key)
end

-- ── panel ────────────────────────────────────────────────────────────────────

-- True until the service has answered once: no snapshot, or an unknown service
-- with nothing to show. Shared by the panel and the bar so they cannot drift.
function model.isLoading(snap)
  if type(snap) ~= "table" then
    return true
  end
  -- A failed first read (lastError set) is an answer: show the error, not "Loading...".
  return snap.installed ~= false and snap.service == "unknown" and #(snap.connections or {}) == 0
    and snap.lastError == nil
end

function model.panelState(snap)
  if model.isLoading(snap) then
    return "loading"
  end
  local connections = snap.connections or {}
  if snap.installed == false then
    return "not_installed"
  end
  if snap.service == "down" then
    return "service_down"
  end
  if snap.service == "unknown" and #connections == 0 and snap.lastError ~= nil then
    return "read_error"
  end
  if #connections == 0 then
    return "no_connections"
  end
  return "list"
end

local STATUS_KEYS = {
  CONNECTED = "status.connected",
  CONNECTING = "status.connecting",
  DISCONNECTING = "status.disconnecting",
  DISCONNECTED = "status.disconnected",
  TEMPORARILY_OFFLINE = "status.offline",
}

function model.rowView(c, snap)
  local key = tostring(c.id)
  local inFlight = type(snap.inFlight) == "table" and snap.inFlight[key] or nil
  local view = {
    title = model.rowTitle(c),
    subtitle = c.host,
    statusKey = STATUS_KEYS[c.status] or "status.unknown",
    button = nil,
    buttonDisabled = false,
    dns = nil,
    error = type(snap.rowErrors) == "table" and snap.rowErrors[key] or nil,
  }
  if c.name == nil or c.name == "" then
    view.subtitle = c.account or ""
  end

  if c.authorized == false or c.status == "AUTHORIZING" then
    view.statusKey = "status.needs_signin"
    view.button = "open_gui"
    return view
  end

  if c.status == "CONNECTED" or c.status == "TEMPORARILY_OFFLINE" or c.status == "DISCONNECTING" then
    view.button = "disconnect"
  elseif c.status == "DISCONNECTED" or c.status == "CONNECTING" then
    view.button = "connect"
  end
  if c.status == "CONNECTED" and c.dns and #c.dns > 0 then
    view.dns = table.concat(c.dns, ", ")
  end

  -- A transition started elsewhere (the LogonBox app) locks the button too.
  if inFlight == nil and c.status == "CONNECTING" then
    inFlight = "connecting"
  elseif inFlight == nil and c.status == "DISCONNECTING" then
    inFlight = "disconnecting"
  end
  if inFlight == "connecting" then
    view.statusKey = "status.connecting"
    view.button = "connect"
    view.buttonDisabled = true
  elseif inFlight == "disconnecting" then
    view.statusKey = "status.disconnecting"
    view.button = "disconnect"
    view.buttonDisabled = true
  end
  return view
end

-- ── bar tile (spec §7.4a) ────────────────────────────────────────────────────

local function problem(tooltip)
  return { glyph = "lock-exclamation", color = "error", label = "!", tooltip = tooltip }
end

local function barFor(snap)
  if snap.installed == false then
    return problem(tr("panel.not_installed"))
  end
  if snap.service == "down" then
    return problem(tr("panel.service_down"))
  end
  if snap.rebootNeeded then
    return problem(tr("error.reboot_needed"))
  end

  local connections = snap.connections or {}
  if snap.service == "unknown" and #connections == 0 and snap.lastError ~= nil then
    return problem(errorText(snap.lastError))
  end
  local inFlight = snap.inFlight or {}
  local connected = {}
  local offline = false
  local working = nil
  local allUnauthorized = #connections > 0
  for _, c in ipairs(connections) do
    if c.status == "CONNECTED" then
      connected[#connected + 1] = c
    end
    local flight = inFlight[tostring(c.id)]
    if working == nil then
      if flight == "disconnecting" or c.status == "DISCONNECTING" then
        working = "status.disconnecting"
      elseif flight == "connecting" or c.status == "CONNECTING" then
        working = "status.connecting"
      elseif c.status == "AUTHORIZING" then
        working = "status.needs_signin"
      end
    end
    if c.status == "TEMPORARILY_OFFLINE" then
      offline = true
    end
    if c.authorized ~= false then
      allUnauthorized = false
    end
  end

  if #connected > 0 then
    local tooltip
    if #connected > 1 then
      tooltip = tr(model.countKey("tooltip.connected_n", #connected), { n = #connected })
    else
      tooltip = tr("tooltip.connected", { host = connected[1].host })
    end
    return { glyph = "lock-filled", color = model.GREEN, label = "On", tooltip = tooltip }
  end

  if working == nil then
    for _, flight in pairs(inFlight) do
      working = flight == "disconnecting" and "status.disconnecting" or "status.connecting"
    end
  end
  if working ~= nil then
    return { glyph = "lock", color = "primary", label = "…", tooltip = tr(working) }
  end
  if offline then
    return { glyph = "lock", color = "primary", label = "…", tooltip = tr("status.offline") }
  end

  for _, c in ipairs(connections) do
    local err = snap.rowErrors and snap.rowErrors[tostring(c.id)]
    if err then
      return problem(errorText(err))
    end
  end
  if #connections == 0 then
    return problem(tr("panel.no_connections"))
  end
  if allUnauthorized then
    return problem(tr("status.needs_signin"))
  end
  return { glyph = "lock", color = "on_surface_variant", label = "Off", tooltip = tr("tooltip.disconnected") }
end

function model.barView(snap, showLabel)
  local view
  if model.isLoading(snap) then
    view = { glyph = "lock", color = "on_surface_variant", label = "", tooltip = tr("tooltip.loading") }
  else
    view = barFor(snap)
  end
  -- The label keeps the glyph's colour, except when connected: it stays default text.
  view.labelColor = view.glyph == "lock-filled" and "on_surface" or view.color
  if showLabel == false then
    view.label = ""
  end
  return view
end

return model
