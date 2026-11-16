--!nonstrict
-- Pure panel view: the logonbox.state snapshot in, a ui tree out. No noctalia calls;
-- panel.luau passes `ui`, the translation function and the callbacks.
--
--   view_panel.build(snap, ui, tr, h) -> UiNode
--
-- snap may be nil (no snapshot yet). tr(key, subst) translates. h holds:
--   h.connect(id), h.disconnect(id)   a row's button
--   h.openGui()                       Open LogonBox (footer, sign-in rows, empty state)
--   h.openDownload()                  "How to get the client" (not installed)
--   h.copy(text)                      copies the systemctl hint
--   h.dismiss(key)                    clears the footer error with that key
--
-- Buttons: at most one primary (filled) button per panel, the first Connect row, or Open
-- LogonBox when there are no connections; everything else is outline, secondary or ghost.

local model = require("./model.luau")

local view_panel = {}

local MUTED = "on_surface_variant"
local ROW_FILL = "surface_container_high"
local SERVICE_CMD = "sudo systemctl enable --now logonbox-vpn-service"

local VARIANT = { connect = "primary", disconnect = "outline", open_gui = "secondary" }

local function errorText(tr, err)
  if err.detail ~= nil then
    return tr(err.key, { detail = err.detail })
  end
  return tr(err.key)
end

-- withSubtitle is false where the body already says the same thing as the tooltip.
local function header(ui, tr, snap, withSubtitle)
  local bar = model.barView(snap, true)
  local lines = { ui.label({ text = tr("panel.title"), fontSize = 14, fontWeight = "semibold" }) }
  if withSubtitle then
    lines[#lines + 1] = ui.label({ text = bar.tooltip, fontSize = 11, color = MUTED, maxLines = 2 })
  end
  return ui.row({ key = "header", gap = 8, align = "center" }, {
    ui.glyph({ name = bar.glyph, size = 22, color = bar.color }),
    ui.column({ gap = 0, flexGrow = 1 }, lines),
  })
end

local function message(ui, tr, key)
  return ui.label({ key = "message", text = tr(key), fontSize = 12, color = MUTED, maxLines = 4 })
end

local function guiButton(ui, tr, h, key, variant)
  return ui.button({
    key = key,
    text = tr(model.BUTTON_KEYS.open_gui),
    variant = variant,
    controlSize = "sm",
    onClick = function()
      h.openGui()
    end,
  })
end

local function subtitle(tr, view)
  local parts = { tr(view.statusKey) }
  if view.subtitle ~= nil and view.subtitle ~= "" then
    parts[#parts + 1] = view.subtitle
  end
  return table.concat(parts, " · ")
end

local function row(ui, tr, h, c, snap, primaryId)
  local view = model.rowView(c, snap)
  local id = c.id
  local texts = {
    ui.label({ text = view.title, fontSize = 13, fontWeight = "medium", maxLines = 1 }),
    ui.label({ text = subtitle(tr, view), fontSize = 11, color = MUTED, maxLines = 1 }),
  }
  if view.dns ~= nil then
    texts[#texts + 1] = ui.label({ key = "dns", text = tr(model.DNS_KEY, { servers = view.dns }), fontSize = 11, color = MUTED, maxLines = 2 })
  end
  local line = { ui.column({ gap = 2, flexGrow = 1 }, texts) }
  if view.button ~= nil then
    local variant = VARIANT[view.button]
    if view.button == "connect" and id ~= primaryId then
      variant = "outline"
    end
    local onClick
    if view.button == "connect" then
      onClick = function() h.connect(id) end
    elseif view.button == "disconnect" then
      onClick = function() h.disconnect(id) end
    else
      onClick = function() h.openGui() end
    end
    line[#line + 1] = ui.button({
      key = "btn." .. tostring(id),
      text = tr(model.BUTTON_KEYS[view.button]),
      variant = variant,
      controlSize = "sm",
      -- Open LogonBox is always allowed (the service runs it while busy too).
      enabled = view.button == "open_gui" or not (view.buttonDisabled or snap.busy == true),
      onClick = onClick,
    })
  end
  local children = { ui.row({ gap = 8, align = "center" }, line) }
  if view.error ~= nil then
    children[#children + 1] = ui.label({ key = "err", text = errorText(tr, view.error), fontSize = 11, color = "error", maxLines = 3 })
  end
  return ui.column({ key = "row." .. tostring(id), gap = 4, padding = 10, radius = 8, fill = ROW_FILL }, children)
end

local function footer(ui, tr, h, snap, withGui)
  local children = {}
  if snap.lastError ~= nil then
    children[#children + 1] = ui.row({ key = "last_error", gap = 6, align = "center" }, {
      ui.label({ text = errorText(tr, snap.lastError), fontSize = 12, color = "error", maxLines = 3, flexGrow = 1 }),
      ui.button({
        key = "btn.dismiss_error",
        glyph = "x",
        variant = "ghost",
        controlSize = "sm",
        tooltip = tr("panel.dismiss"),
        onClick = function()
          h.dismiss(snap.lastError.key)
        end,
      }),
    })
  end
  if withGui then
    children[#children + 1] = guiButton(ui, tr, h, "btn.footer_gui", "ghost")
  end
  if snap.simulate ~= nil then
    children[#children + 1] = ui.label({ key = "test_mode", text = tr("panel.test_mode"), fontSize = 11, color = MUTED })
  end
  return children
end

function view_panel.build(snap, ui, tr, h)
  local state = model.panelState(snap)
  local problem = state == "not_installed" or state == "service_down" or state == "no_connections"
    or state == "read_error"
  -- A row already shows the reboot message under its button; the header must not repeat it.
  local rowSaysReboot = false
  if snap ~= nil and snap.rebootNeeded then
    for _, c in ipairs(snap.connections or {}) do
      local err = model.rowView(c, snap).error
      if err ~= nil and err.key == "error.reboot_needed" then
        rowSaysReboot = true
      end
    end
  end
  local children = { header(ui, tr, snap, not problem and not rowSaysReboot) }

  if state == "loading" then
    children[#children + 1] = message(ui, tr, "panel.loading")
    return ui.column({ gap = 10, padding = 12 }, children)
  end

  if state == "not_installed" then
    children[#children + 1] = message(ui, tr, "panel.not_installed")
    children[#children + 1] = ui.button({
      key = "btn.how_to_get",
      text = tr("button.how_to_get"),
      variant = "primary",
      controlSize = "sm",
      onClick = function()
        h.openDownload()
      end,
    })
    if snap.simulate ~= nil then
      children[#children + 1] = ui.label({ key = "test_mode", text = tr("panel.test_mode"), fontSize = 11, color = MUTED })
    end
    return ui.column({ gap = 10, padding = 12 }, children)
  end

  local withGui = true
  if state == "service_down" then
    children[#children + 1] = message(ui, tr, "panel.service_down")
    children[#children + 1] = ui.row({ key = "hint", gap = 6, align = "center", padding = 8, radius = 8, fill = ROW_FILL }, {
      ui.label({ text = tr(model.SERVICE_HINT_KEY), fontSize = 11, maxLines = 3, flexGrow = 1 }),
      ui.button({
        key = "btn.copy",
        text = tr("button.copy"),
        variant = "outline",
        controlSize = "sm",
        onClick = function()
          h.copy(SERVICE_CMD)
        end,
      }),
    })
  elseif state == "read_error" then
    -- the footer below carries the error line, its dismiss button and Open LogonBox
  elseif state == "no_connections" then
    children[#children + 1] = message(ui, tr, "panel.no_connections")
    children[#children + 1] = guiButton(ui, tr, h, "btn.gui", "primary")
    withGui = false -- the primary button above is the same action
  else
    local primaryId = nil
    for _, c in ipairs(snap.connections) do
      if model.rowView(c, snap).button == "connect" then
        primaryId = c.id
        break
      end
    end
    local rows = {}
    for _, c in ipairs(snap.connections) do
      rows[#rows + 1] = row(ui, tr, h, c, snap, primaryId)
    end
    children[#children + 1] = ui.scroll({ key = "list", gap = 6 }, rows)
  end

  for _, node in ipairs(footer(ui, tr, h, snap, withGui)) do
    children[#children + 1] = node
  end
  return ui.column({ gap = 10, padding = 12 }, children)
end

return view_panel
