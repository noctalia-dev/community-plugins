--!nonstrict
-- widget.luau — bar widget showing running/total VMs; click opens the manager panel.

local PANEL_ID = "tiobaka/vm-manager:manager"

local snapshot = noctalia.state.get("vms") or {
	vms = {},
	running = 0,
	paused = 0,
	total = 0,
	updatedAt = 0,
	busy = {},
	error = nil,
}

local function render()
	if snapshot.error ~= nil then
		barWidget.setGlyph("alert-triangle")
		barWidget.setGlyphColor("error")
		barWidget.setText("err")
		barWidget.setTooltip(noctalia.tr("widget.error") .. "\n" .. snapshot.error)
		return
	end

	barWidget.setGlyph("server-2")
	if snapshot.running > 0 then
		barWidget.setGlyphColor("primary")
	else
		barWidget.setGlyphColor("on_surface")
	end
	barWidget.setText((snapshot.running or 0) .. "/" .. (snapshot.total or 0))
	barWidget.setTooltip(noctalia.tr("widget.tooltip", {
		running = tostring(snapshot.running or 0),
		paused = tostring(snapshot.paused or 0),
		total = tostring(snapshot.total or 0),
	}))
end

noctalia.state.watch("vms", function(value)
	if type(value) == "table" then
		snapshot = value
		render()
	end
end)

function update()
	render()
end

function onClick()
	noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
	noctalia.togglePanel(PANEL_ID)
end

render()