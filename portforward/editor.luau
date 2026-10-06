--!nonstrict
local M = {}
local tr = noctalia.tr

function M.validate(form)
  local errors, used = {}, {}
  if string.match(form.name, "^%s*$") then errors.name = tr("validation.name") end
  if string.match(form.host, "^%s*$") then errors.host = tr("editor.host_required") end
  for _, mapping in ipairs(form.mappings) do
    for _, field in ipairs({ "local_port", "remote_port" }) do
      local value = tonumber(mapping[field])
      if not string.match(mapping[field], "^%d+$") or not value or value < 1 or value > 65535 then
        errors[field .. mapping.key] = tr("validation.port")
      elseif field == "local_port" then
        if used[value] then errors[field .. mapping.key] = tr("validation.duplicate") end
        used[value] = true
      end
    end
    if string.match(mapping.remote_host, "^%s*$") then errors["remote_host" .. mapping.key] = tr("validation.remote_host") end
  end
  form.errors = errors
  form.error = nil
  return next(errors) == nil
end

local function errorLabel(message)
  return ui.label({ text = message or "", visible = message ~= nil, color = "error", fontSize = 12 })
end

function M.render(form, busy, callbacks)
  local errors = form.errors or {}
  local function clearError(key)
    if errors[key] or form.error then
      errors[key], form.error = nil, nil
      callbacks.changed()
    end
  end
  local rows = {
    ui.column({ gap = 6 }, {
      ui.label({ text = tr("editor.name"), fontSize = 12, color = "on_surface_variant" }),
      ui.input({ key = "name-" .. form.session, value = form.name, placeholder = tr("editor.name_hint"),
        focus = true, enabled = not busy, onChange = function(value) form.name = value; clearError("name") end }),
      errorLabel(errors.name),
    }),
    ui.column({ gap = 6 }, {
      ui.label({ text = tr("editor.host"), fontSize = 12, color = "on_surface_variant" }),
      ui.row({ gap = 8 }, {
        ui.input({ key = "host-" .. form.session, value = form.host, placeholder = tr("editor.host_hint"),
          flexGrow = 1, enabled = not busy, onChange = function(value)
            form.host = value
            form.resolved, form.hostError = nil, nil
            clearError("host")
          end }),
        ui.button({ text = tr("editor.check_host"), variant = "outline", enabled = not busy, onClick = callbacks.resolve }),
      }),
      errorLabel(form.hostError or errors.host),
      ui.label({ text = form.resolved or tr("editor.host_help"), fontSize = 12,
        color = form.resolved and "primary" or "on_surface_variant" }),
    }),
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = tr("editor.ports"), flexGrow = 1, fontWeight = "medium" }),
      ui.button({ glyph = "plus", tooltip = tr("editor.add_port"), variant = "ghost", width = 32, controlSize = "sm",
        enabled = not busy and #form.mappings < 32, onClick = callbacks.addPort }),
    }),
  }
  for index, mapping in ipairs(form.mappings) do
    local key = form.session .. "-" .. mapping.key
    table.insert(rows, ui.column({ key = "mapping-" .. key, gap = 8, padding = 12, fill = "surface_variant", radius = 8 }, {
      ui.row({ gap = 8, align = "center" }, {
        ui.label({ text = tr("editor.mapping") .. " " .. index, flexGrow = 1, fontSize = 12, fontWeight = "medium" }),
        ui.button({ glyph = "x", tooltip = tr("editor.remove_port"), width = 28, controlSize = "sm",
          variant = "ghost", enabled = not busy and #form.mappings > 1,
          onClick = function() callbacks.removePort(index) end }),
      }),
      ui.row({ gap = 8 }, {
        ui.column({ width = 82, gap = 5 }, {
          ui.label({ text = tr("editor.local_port"), fontSize = 12, color = "on_surface_variant" }),
          ui.input({ key = "local-" .. key, value = mapping.local_port, placeholder = "3000", controlSize = "sm",
            enabled = not busy, onChange = function(value) mapping.local_port = value; clearError("local_port" .. mapping.key) end }),
          errorLabel(errors["local_port" .. mapping.key]),
        }),
        ui.column({ flexGrow = 1, gap = 5 }, {
          ui.label({ text = tr("editor.remote_host"), fontSize = 12, color = "on_surface_variant" }),
          ui.input({ key = "remote-host-" .. key, value = mapping.remote_host, placeholder = "localhost", controlSize = "sm",
            enabled = not busy, onChange = function(value) mapping.remote_host = value; clearError("remote_host" .. mapping.key) end }),
          errorLabel(errors["remote_host" .. mapping.key]),
        }),
        ui.column({ width = 82, gap = 5 }, {
          ui.label({ text = tr("editor.remote_port"), fontSize = 12, color = "on_surface_variant" }),
          ui.input({ key = "remote-port-" .. key, value = mapping.remote_port, placeholder = "3000", controlSize = "sm",
            enabled = not busy, onChange = function(value) mapping.remote_port = value; clearError("remote_port" .. mapping.key) end }),
          errorLabel(errors["remote_port" .. mapping.key]),
        }),
      }),
      ui.row({ gap = 8, align = "center" }, {
        ui.glyph({ name = "arrow-right", size = 14, color = "on_surface_variant" }),
        ui.label({ text = tr("editor.mapping_help"), fontSize = 12, color = "on_surface_variant", flexGrow = 1 }),
      }),
      ui.row({ gap = 8, align = "center" }, {
        ui.label({ text = tr("editor.browser"), fontSize = 12, color = "on_surface_variant" }),
        ui.select({ key = "scheme-" .. key, width = 104, controlSize = "sm", options = { "HTTP", "HTTPS" },
          selectedIndex = mapping.scheme == "https" and 1 or 0, enabled = not busy,
          onChange = function(value) mapping.scheme = tonumber(value) == 1 and "https" or "http" end }),
      }),
    }))
  end
  table.insert(rows, ui.label({ text = tr(form.live and "editor.live_hint" or "editor.loopback"), color = "on_surface_variant", fontSize = 12 }))
  table.insert(rows, errorLabel(form.error))
  return ui.column({ key = "editor-" .. form.session, flexGrow = 1, gap = 0 }, {
    ui.row({ gap = 8, align = "center", paddingH = 16, paddingV = 12 }, {
      ui.button({ glyph = "arrow-left", tooltip = tr("cancel"), variant = "ghost", width = 32, controlSize = "sm",
        enabled = not busy, onClick = callbacks.cancel }),
      ui.label({ text = form.existing and tr("editor.edit") or tr("editor.new"), fontSize = 17, fontWeight = "medium" }),
    }),
    ui.scroll({ flexGrow = 1 }, { ui.column({ gap = 16, paddingH = 16, paddingV = 8 }, rows) }),
    ui.separator({ color = "outline" }),
    ui.row({ gap = 8, paddingH = 16, paddingV = 12, justify = "end" }, {
      ui.button({ text = tr("cancel"), variant = "ghost", enabled = not busy, onClick = callbacks.cancel }),
      ui.button({ text = tr(form.live and "save_reconnect" or "save"), variant = "default", enabled = not busy, onClick = callbacks.save }),
    }),
  })
end

return M
