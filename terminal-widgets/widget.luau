--!nonstrict
-- Icono de barra: abre/cierra el panel de lanzamiento.

local glyph = noctalia.getConfig("glyph") or "terminal-2"

local function render()
  barWidget.setGlyph(glyph)
  barWidget.setTooltip(noctalia.tr("tooltip"))
end

function update()
  glyph = noctalia.getConfig("glyph") or "terminal-2"
  render()
end

function onClick()
  noctalia.togglePanel("faminec/terminal-widgets:panel")
end

function onConfigChanged()
  update()
end
