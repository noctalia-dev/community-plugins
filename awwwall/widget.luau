--!nonstrict
-- Bar toggle. All the real logic lives in service.luau; this entry only
-- reflects its published state and asks it to flip the toggle.

local function render()
  local enabled = noctalia.state.get("enabled") == true
  local available = noctalia.state.get("available") ~= false

  barWidget.setGlyph(enabled and "photo" or "photo-off")

  if not available then
    barWidget.setColor("on_surface_variant")
    barWidget.setGlyphColor("on_surface_variant")
    barWidget.setTooltip(noctalia.tr("tooltip.not_installed"))
  elseif enabled then
    barWidget.setColor("primary")
    barWidget.setGlyphColor("primary")
    barWidget.setTooltip(noctalia.tr("tooltip.on"))
  else
    barWidget.setColor("on_surface_variant")
    barWidget.setGlyphColor("on_surface_variant")
    barWidget.setTooltip(noctalia.tr("tooltip.off"))
  end
end

function onClick()
  -- A fresh value on every click guarantees the service's watch callback
  -- fires even if two clicks land in the same tick.
  noctalia.state.set("requestToggle", noctalia.nowMs())
end

noctalia.state.watch("enabled", function(_) render() end)
noctalia.state.watch("available", function(_) render() end)

render()
