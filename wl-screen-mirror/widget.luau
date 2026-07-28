--!nonstrict

local PANEL_ID = "elijaharch/wl-screen-mirror:controls"

local status = noctalia.state.get("mirror_status") or {
	phase = "stopped",
	running = false,
}

local function tr(key, values)
	return noctalia.tr(key, values)
end

local function render()
	local phase = status.phase or "stopped"
	barWidget.setText("")

	if phase == "running" then
		barWidget.setGlyph("screen-share")
		barWidget.setGlyphColor("primary")
		barWidget.setTooltip(tr("widget.running", {
			source = status.source or "?",
			destination = status.destination or "?",
		}))
	elseif phase == "starting" then
		barWidget.setGlyph("loader-2")
		barWidget.setGlyphColor("on_surface_variant")
		barWidget.setTooltip(tr("widget.starting"))
	elseif phase == "stopping" then
		barWidget.setGlyph("loader-2")
		barWidget.setGlyphColor("on_surface_variant")
		barWidget.setTooltip(tr("widget.stopping"))
	elseif phase == "error" then
		barWidget.setGlyph("screen-share-off")
		barWidget.setGlyphColor("error")
		barWidget.setTooltip(status.message ~= nil and status.message ~= "" and status.message or tr("widget.error"))
	else
		barWidget.setGlyph("screen-share")
		barWidget.setGlyphColor("on_surface")
		barWidget.setTooltip(tr("widget.ready"))
	end
end

noctalia.state.watch("mirror_status", function(value)
	if type(value) == "table" then
		status = value
		render()
	end
end)

function update()
	local current = noctalia.state.get("mirror_status")
	if type(current) == "table" then
		status = current
	end
	render()
end

function onClick()
	noctalia.togglePanel(PANEL_ID)
end

noctalia.setUpdateInterval(1000)
render()
