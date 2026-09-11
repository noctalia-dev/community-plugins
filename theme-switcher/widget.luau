--!nonstrict
-- Bar widget: shows the name of the currently applied theme. Click the glyph to
-- open the Theme Switcher carousel.

local themes = require("./themes.luau")

local function render()
	barWidget.setGlyph("palette")
	local current = themes.byId(themes.lastAppliedId())
	barWidget.setText((current and current.title) or noctalia.tr("widget.label"))
end

render()
noctalia.state.watch("lastAppliedId", render)
noctalia.state.watch("themes", render)

function onClick()
	noctalia.togglePanel("theblackdon/theme-switcher:carousel")
end
