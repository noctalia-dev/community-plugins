local status = noctalia.state.get("mimir.status") or "idle"

local glyphs = {
  idle = "brain",
  thinking = "loader",
  tool = "terminal-2",
  error = "alert-circle",
}

local colors = {
  idle = "on_surface",
  thinking = "primary",
  tool = "tertiary",
  error = "error",
}

function update()
  status = noctalia.state.get("mimir.status") or "idle"
  barWidget.setGlyph(glyphs[status] or "brain")
  barWidget.setGlyphColor(colors[status] or "on_surface")
  local tooltip = status == "idle" and "Mimir — Ready" or "Mimir — " .. status
  barWidget.setTooltip(tooltip)
end

function onClick()
  noctalia.togglePanel("alexander/mimir:chat")
end

noctalia.state.watch("mimir.status", function(newStatus)
  status = newStatus or "idle"
  barWidget.setGlyph(glyphs[status] or "brain")
  barWidget.setGlyphColor(colors[status] or "on_surface")
  local tooltip = status == "idle" and "Mimir — Ready" or "Mimir — " .. status
  barWidget.setTooltip(tooltip)
end)
