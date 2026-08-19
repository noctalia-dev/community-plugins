-- widget.luau
-- bar widget：设备图标 + 可选名称 + 电池状态，颜色按状态
-- （充电 primary / 低电 error / 离线暗）。点击打开面板，右键开设置。

local common = require("./lib/common.luau")

local t = common.t

local function render()
	local backend = noctalia.state.get("pc.backend") or { available = false }
	local d = common.selectedDevice()
	local enableCharging = noctalia.getConfig("enable_charging_animation")
	local showDeviceName = noctalia.getConfig("show_device_name") == true
	local batteryDisplay = noctalia.getConfig("battery_display") or "icon_and_percent"

	local children
	if not d then
		-- 无设备（无论后端是否可用）：离线图标 + 提示
		children = {
			ui.glyph({ name = "phone-off", size = 14, color = "on_surface/0.4" }),
			ui.label({ text = t("status.no_devices"), fontSize = 10,
				color = "on_surface/0.5" }),
		}
	elseif d.source == "adb" then
		-- adb 设备：usb/wifi 图标 + 名称（无电池）
		local glyphColor = d.isReachable and "on_surface" or "on_surface/0.4"
		local kids = {
			ui.glyph({ name = d.transport == "wifi" and "wifi" or "usb", size = 14, color = glyphColor }),
		}
		if showDeviceName then
			table.insert(kids, ui.label({ text = d.name, fontSize = 11, color = glyphColor }))
		end
		if not d.isReachable then
			table.insert(kids, ui.label({ text = t("status.offline"),
				fontSize = 10, color = "on_surface/0.5" }))
		end
		children = kids
	else
		local reachable = d.isPaired == true and d.isReachable == true
		local charge = d.batteryCharge
		local charging = d.batteryCharging == true
		local hasCharge = type(charge) == "number" and charge >= 0

		local glyphColor = "on_surface"
		if reachable and charging and enableCharging then
			glyphColor = "primary"
		elseif not reachable then
			glyphColor = "on_surface/0.4"
		end

		local kids = { ui.glyph({ name = common.deviceGlyph(d), size = 14, color = glyphColor }) }
		if showDeviceName then
			local aliasMap = noctalia.state.get("pc.aliasMap") or {}
			local name = aliasMap[d.id] or d.name or "Your-Phone"
			table.insert(kids, ui.label({ text = name, fontSize = 11, color = glyphColor }))
		end

		if reachable and hasCharge then
			local batColor = "on_surface"
			if charging then batColor = "primary"
			elseif charge <= 20 then batColor = "error" end

			if batteryDisplay == "icon_and_percent" or batteryDisplay == "icon" then
				table.insert(kids, ui.glyph({ name = common.batteryGlyph(charge, charging),
					size = 12, color = batColor }))
			end
			if batteryDisplay == "icon_and_percent" or batteryDisplay == "percent" then
				table.insert(kids, ui.label({
					text = tostring(charge) .. "%", fontSize = 11,
					fontWeight = "medium", color = batColor,
				}))
			end
		elseif not reachable and d.isPaired then
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
	noctalia.togglePanel(common.panelId())
end

function onRightClick()
	noctalia.openSettings()
end

noctalia.state.watch("pc.devices", render)
noctalia.state.watch("pc.order", render)
noctalia.state.watch("pc.selected", render)
noctalia.state.watch("pc.backend", render)
noctalia.state.watch("pc.aliasMap", render)
noctalia.state.watch("pc.trTable", render)

render()
