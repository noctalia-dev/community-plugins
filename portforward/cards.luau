--!nonstrict
-- Native profile presentation; all connection controls belong to the panel/backend.
local M = {}
local tr = noctalia.tr

function M.failure(profile)
  local kind = profile.issue and profile.issue.kind or "connection"
  if kind == "port_conflict" then
    local parts = {}
    for _, conflict in ipairs(profile.issue.conflicts or {}) do
      local names = {}
      for _, name in ipairs(conflict.processes or {}) do
        table.insert(names, name == "code" and "VS Code" or name == "ssh" and "SSH" or name)
      end
      table.insert(parts, tostring(conflict.port) .. (#names > 0 and " · " .. table.concat(names, ", ") or ""))
    end
    return tr("issue.port_conflict"), #parts > 0 and table.concat(parts, "  /  ") or tr("issue.port_unavailable"), tr("issue.port_hint")
  end
  return tr("issue." .. kind), nil, tr("issue." .. kind .. "_hint")
end

function M.render(profile, state, actions)
  local active = profile.state == "connected" or profile.state == "connecting" or profile.state == "reconnecting"
  local failed = profile.state == "error"
  local color = failed and "error" or profile.state == "connected" and "primary" or "on_surface_variant"
  local title, problem, hint = M.failure(profile)
  local glyph = failed and "alert-circle" or profile.state == "connected" and "circle-check"
    or active and "refresh" or "circle"
  local rows = {
    ui.row({ gap = 6, align = "center", paddingH = 12, paddingV = 12 }, {
      ui.row({ flexGrow = 1, gap = 10, align = "center", onClick = actions.expand }, {
        ui.glyph({ name = state.expanded and "chevron-down" or "chevron-right", size = 16, color = "on_surface_variant" }),
        ui.column({ flexGrow = 1, gap = 5 }, {
          ui.label({ text = profile.name, fontSize = 15, fontWeight = "semibold" }),
          ui.label({ text = profile.host .. " · " .. #profile.mappings .. " " .. tr(#profile.mappings == 1 and "port" or "ports"),
            fontSize = 12, color = "on_surface_variant" }),
          ui.row({ gap = 5, align = "center" }, {
            ui.glyph({ name = glyph, size = 13, color = color }),
            ui.label({ text = failed and title or tr("state." .. profile.state), fontSize = 12, color = color }),
          }),
        }),
      }),
      ui.button({ text = active and tr("disconnect") or failed and tr("retry") or tr("connect"),
        controlSize = "sm", variant = active and "outline" or "default", enabled = not state.busy, onClick = actions.control }),
      ui.select({ key = "actions-" .. profile.id, controlSize = "sm", width = 94,
        options = { tr("actions"), tr("edit"), tr("details"), tr("delete") },
        selectedIndex = 0, enabled = not state.busy, onChange = function(value)
          local index = tonumber(value)
          if index == 1 then actions.edit()
          elseif index == 2 then actions.details()
          elseif index == 3 then actions.delete() end
        end }),
    }),
  }
  if state.pendingDelete then
    table.insert(rows, ui.column({ key = "delete-confirmation", paddingH = 14, paddingV = 12, gap = 10 }, {
      ui.label({ text = tr(active and "delete_live_hint" or "delete_hint"), fontSize = 12 }),
      ui.row({ gap = 8, justify = "end" }, {
        ui.button({ text = tr("cancel"), variant = "ghost", controlSize = "sm", onClick = actions.cancelDelete }),
        ui.button({ text = tr(active and "disconnect_delete" or "confirm_delete"), variant = "destructive",
          controlSize = "sm", enabled = not state.busy, onClick = actions.confirmDelete }),
      }),
    }))
  end
  if failed then
    table.insert(rows, ui.column({ key = "failure", paddingH = 14, paddingV = 10, gap = 6 }, {
      ui.label({ text = problem or hint, fontSize = 12, color = "on_surface" }),
      ui.label({ text = hint, fontSize = 12, color = "on_surface_variant", visible = problem ~= nil }),
      ui.row({ gap = 6 }, {
        ui.button({ text = tr("edit_ports"), variant = "ghost", controlSize = "sm", visible = profile.issue ~= nil and profile.issue.kind == "port_conflict",
          enabled = not state.busy, onClick = actions.edit }),
        ui.button({ text = tr("details"), variant = "ghost", controlSize = "sm", enabled = not state.busy, onClick = actions.details }),
      }),
    }))
  elseif profile.state == "reconnecting" then
    table.insert(rows, ui.column({ key = "reconnecting", paddingH = 14, paddingV = 8 }, {
      ui.label({ text = tr("reconnecting_hint"), color = "on_surface_variant", fontSize = 12 }),
    }))
  elseif profile.error ~= "" then
    table.insert(rows, ui.row({ key = "warning", paddingH = 14, paddingV = 8, gap = 6, align = "center" }, {
      ui.label({ text = tr("destination_warning"), color = "on_surface_variant", fontSize = 12, flexGrow = 1 }),
      ui.button({ text = tr("details"), variant = "ghost", controlSize = "sm", onClick = actions.details }),
    }))
  end
  if state.expanded then
    table.insert(rows, ui.separator({ color = "outline" }))
    local ports = {}
    for _, mapping in ipairs(profile.mappings) do
      local address = "127.0.0.1:" .. mapping.local_port
      local copied = state.copied == profile.id .. ":" .. mapping.local_port
      table.insert(ports, ui.row({ key = profile.id .. ":" .. mapping.local_port, gap = 8, align = "center", paddingV = 6 }, {
        ui.column({ flexGrow = 1, gap = 4 }, {
          ui.label({ text = address, fontSize = 14, fontWeight = "medium" }),
          ui.label({ text = "→ " .. mapping.remote_host .. ":" .. mapping.remote_port, color = "on_surface_variant", fontSize = 12 }),
        }),
        ui.button({ glyph = "external-link", tooltip = tr("open"), variant = "ghost", controlSize = "sm", width = 32,
          enabled = not state.busy and profile.state == "connected", onClick = function() actions.open(mapping.local_port) end }),
        ui.button({ glyph = copied and "check" or "copy", tooltip = tr(copied and "copied" or "copy"), variant = "ghost", controlSize = "sm", width = 32,
          onClick = function() actions.copy(mapping.local_port, address) end }),
      }))
    end
    table.insert(rows, ui.column({ key = "ports", paddingH = 14, paddingV = 8, gap = 2 }, ports))
  end
  return ui.column({ key = profile.id, gap = 0, fill = "surface_variant", radius = 8 }, rows)
end

return M
