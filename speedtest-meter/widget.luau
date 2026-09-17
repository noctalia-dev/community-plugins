--!strict
-- Speedtest Meter — bar widget entry point.
--
-- Mirrors the pattern from nilsonlinux/rss-notifier's widget.luau: the icon
-- is a plugin setting (noctalia.getConfig("glyph")) rendered via
-- ui.glyph + barWidget.render, refreshed on onConfigChanged when the user
-- picks a different icon in the widget's settings screen.

local function tr(key: string): string
	return noctalia.tr(key)
end

local DEFAULT_GLYPH = "brand-speedtest" -- official Tabler Speedtest brand icon

local function render()
	local glyphName = noctalia.getConfig("glyph")
	if not glyphName or glyphName == "" then
		glyphName = DEFAULT_GLYPH
	end

	barWidget.render(ui.glyph({ name = glyphName, size = 16 }))
	barWidget.setTooltip(tr("widget_tooltip"))
end

render()

function update()
	noctalia.setUpdateInterval(5000) -- nothing dynamic to poll; just keeps the widget alive
end

function onConfigChanged()
	render() -- picks up the new glyph when the user changes it in the widget settings
end

function onClick()
	noctalia.togglePanel("nilsonlinux/speedtest-meter:speedtest")
end
