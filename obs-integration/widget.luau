--!nonstrict

local OSC_CONFIG = noctalia.expandPath("~/.config/osc/oscrc")

local function render()
  local hasOsc = noctalia.commandExists("osc")
  local oscConfigured = noctalia.fileExists(OSC_CONFIG)
  local showLabel = noctalia.getConfig("show_label") ~= false

  barWidget.setGlyph("buildings")

  if not hasOsc then
    barWidget.setGlyphColor("error")
    if showLabel then
      barWidget.setText(noctalia.tr("widget.osc_missing"))
      barWidget.setColor("error")
    end
  elseif not oscConfigured then
    barWidget.setGlyphColor("on_surface_variant")
    if showLabel then
      barWidget.setText(noctalia.tr("widget.configure_obs"))
      barWidget.setColor("on_surface_variant")
    end
  else
    barWidget.setGlyphColor("on_surface")
    if showLabel then
      barWidget.setText(noctalia.tr("widget.obs"))
      barWidget.setColor("on_surface")
    end
  end

  if not showLabel then
    barWidget.setText("")
  end
end

function update()
	render()
end

function onClick()
	noctalia.togglePanel("neyfua/obs-integration:panel")
end

noctalia.setUpdateInterval(5000)
render()
