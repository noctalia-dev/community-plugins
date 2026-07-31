-- widget.luau
-- Phone Connect - bar widget (thin UI entry).
--
-- Renders a bar pill reflecting the selected device: device glyph + battery
-- percent, colored by state (charging -> primary, low -> error, offline ->
-- dimmed). Left-click opens the details panel; right-click opens settings.
-- Reads state from the service entry; no DBus logic here.

-- Local translation: reads from pc.trTable (published by service) so users
-- can switch language at runtime, unlike noctalia.tr() which follows system locale.
local function t(key)
	local table = noctalia.state.get("pc.trTable") or {}
	return table[key] or key
end

local function panelId()
	local mode = noctalia.getConfig("panel_placement")
	if mode == "floating" then
		return "icefish/phone-connect:details_floating"
	elseif mode == "widget" then
		return "icefish/phone-connect:details_widget"
	end
	return "icefish/phone-connect:details"
end

local function glyphFor(d)
	if not d or not d.isReachable then return "phone-off" end
	local t = d.type
	if t == "tablet" then return "device-tablet" end
	if t == "laptop" then return "device-laptop" end
	if t == "desktop" or t == "computer" then return "device-desktop" end
	if t == "tv" then return "device-tv" end
	return "device-mobile"
end

local function batteryGlyph(charge, charging)
	if charging then return "battery-charging" end
	if type(charge) ~= "number" then return "battery" end
	if charge >= 90 then return "battery" end
	if charge >= 60 then return "battery-3" end
	if charge >= 30 then return "battery-2" end
	if charge > 0 then return "battery-1" end
	return "battery-off"
end

local function selectedDevice()
	local devices = noctalia.state.get("pc.devices") or {}
	local order = noctalia.state.get("pc.order") or {}
	local sel = noctalia.state.get("pc.selected")
	local id = sel
	if not id or not devices[id] then id = order[1] end
	if id then return devices[id] end
	return nil
end

local function render()
	local backend = noctalia.state.get("pc.backend") or { available = false }
	local d = selectedDevice()
	local enableCharging = noctalia.getConfig("enable_charging_animation")

	local children
	if not backend.available then
		-- no backend: dim phone-off glyph + localized status
		children = {
			ui.glyph({ name = "phone-off", size = 14, color = "on_surface/0.4" }),
			ui.label({ text = t("status.no_backend"), fontSize = 10,
				color = "on_surface/0.5" }),
		}
	elseif not d then
		children = {
			ui.glyph({ name = "phone-off", size = 14, color = "on_surface/0.4" }),
			ui.label({ text = t("status.no_devices"), fontSize = 10,
				color = "on_surface/0.5" }),
		}
	else
		local reachable = d.isReachable == true
		local charge = d.batteryCharge
		local charging = d.batteryCharging == true
		local hasCharge = type(charge) == "number" and charge >= 0

		-- device glyph: primary when charging, dim when offline, normal otherwise
		local glyphColor = "on_surface"
		if reachable and charging and enableCharging then
			glyphColor = "primary"
		elseif not reachable then
			glyphColor = "on_surface/0.4"
		end

		local kids = { ui.glyph({ name = glyphFor(d), size = 14, color = glyphColor }) }

		if reachable and hasCharge then
			-- battery glyph + percent, colored by level
			local batColor = "on_surface"
			if charge <= 20 then batColor = "error"
			elseif charging then batColor = "primary" end
			table.insert(kids, ui.glyph({ name = batteryGlyph(charge, charging),
				size = 12, color = batColor }))
			table.insert(kids, ui.label({
				text = tostring(charge) .. "%", fontSize = 11,
				fontWeight = "medium", color = batColor,
			}))
		elseif not reachable and d.isPaired then
			-- offline but paired: show a small dimmed "offline" tag
			table.insert(kids, ui.label({ text = t("status.offline"),
				fontSize = 10, color = "on_surface/0.5" }))
		end
		children = kids
	end

	local container = barWidget.isVertical() and ui.column or ui.row
	barWidget.render(container({ gap = 5, align = "center" }, children))
end

function update()
	noctalia.setUpdateInterval(2000)
	render()
end

function onClick()
	noctalia.togglePanel(panelId())
end

function onRightClick()
	noctalia.openSettings()
end

noctalia.state.watch("pc.devices", render)
noctalia.state.watch("pc.order", render)
noctalia.state.watch("pc.selected", render)
noctalia.state.watch("pc.backend", render)
noctalia.state.watch("pc.trTable", render)

render()
