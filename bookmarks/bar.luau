local shared = require("./shared.luau")

local open = false

local function render()
	barWidget.setGlyph(noctalia.getConfig("glyph"))
	if open then
		barWidget.setGlyphColor("primary")
		barWidget.setColor("primary")
	else
		barWidget.setGlyphColor("on_surface")
		barWidget.setColor("on_surface")
	end

	barWidget.setTooltip(noctalia.getConfig("tooltip"))
	barWidget.setText(noctalia.getConfig("text"))
end

noctalia.state.watch(shared.STATE_OPEN, function(value)
	open = value == true
	render()
end)

function update()
	render()
end

function onClick()
	noctalia.togglePanel(shared.PANEL_ID)
end
