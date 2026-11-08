--!nonstrict
-- Bar widget: a shield for Proton VPN and a network glyph while any
-- WireGuard tunnel is up. Left click opens the panel; right click toggles
-- Proton (fastest server).

local STATE_KEY = "pw.state"
local CMD_KEY = "pw.cmd"
local PANEL_ID = "gitgxldf1sh/proton-wireguard:panel"

local s = noctalia.state.get(STATE_KEY) or {}
local showServer = noctalia.getConfig("show_server") == true

local function send(op, value)
	noctalia.state.set(CMD_KEY, { op = op, value = value, n = noctalia.nowMs() })
end

local function render()
	local p = s.proton or {}
	local conns = (s.wg and s.wg.connections) or {}

	local active, busy = {}, false
	for _, c in ipairs(conns) do
		if c.state == "activated" then
			table.insert(active, c.name)
		end
		if c.busy or c.state == "activating" then
			busy = true
		end
	end

	local glyph, color = "shield", "on_surface_variant"
	if p.busy then
		color = "tertiary"
	elseif p.up then
		glyph, color = "shield-check", "primary"
	end

	local children = { ui.glyph({ name = glyph, size = 16, color = color }) }
	if p.up and showServer and (p.server or "") ~= "" and not barWidget.isVertical() then
		table.insert(children, ui.label({ text = p.server, fontSize = 11, fontWeight = "semibold", color = "primary" }))
	end
	if #active > 0 or busy then
		table.insert(children, ui.glyph({ name = "network", size = 14, color = if busy then "tertiary" else "secondary" }))
	end

	local container = if barWidget.isVertical() then ui.column else ui.row
	barWidget.render(container({ gap = 4, align = "center" }, children))

	local rows = {}
	if p.installed and p.signedIn then
		local value
		if p.busy then
			value = noctalia.tr(if p.action == "disconnecting" then "status.disconnecting" else "status.connecting")
		elseif p.up then
			value = p.server or ""
			if (p.location or "") ~= "" then
				value = `{value} · {p.location}`
			end
			if value == "" then
				value = noctalia.tr("status.connected")
			end
		else
			value = noctalia.tr("status.disconnected")
		end
		table.insert(rows, { key = noctalia.tr("proton.title"), value = value })
		if p.up and (p.ip or "") ~= "" then
			table.insert(rows, { key = "IP", value = p.ip })
		end
	end
	if #conns > 0 then
		table.insert(rows, {
			key = "WireGuard",
			value = if #active > 0 then table.concat(active, ", ") else noctalia.tr("status.none_active"),
		})
	end
	if #rows == 0 then
		barWidget.setTooltip(noctalia.tr("panel.nothing_configured"))
	else
		barWidget.setTooltip(rows)
	end
end

noctalia.state.watch(STATE_KEY, function(value)
	if type(value) == "table" then
		s = value
		render()
	end
end)

function onClick()
	noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
	local p = s.proton or {}
	if p.installed and p.signedIn then
		send("toggle_proton")
	else
		noctalia.togglePanel(PANEL_ID)
	end
end

render()
