-- tile.luau
-- 控制中心 tile：连接数或选中设备电量。点击打开面板。

local common = require("./lib/common.luau")

local t = common.t

local function countReachable()
	local devices = noctalia.state.get("pc.devices") or {}
	local order = noctalia.state.get("pc.order") or {}
	local n = 0
	for _, id in ipairs(order) do
		local d = devices[id]
		if d and not common.adbCoveredByKde(d, devices)
			and d.isPaired and d.isReachable == true then n = n + 1 end
	end
	return n
end

local function render()
	local backend = noctalia.state.get("pc.backend") or { available = false }
	if not backend.available then
		shortcut.setIcon("phone-off")
		shortcut.setLabel(t("status.no_backend"))
		shortcut.setActive(false)
		shortcut.setEnabled(false)
		return
	end

	local n = countReachable()
	local d = common.selectedDevice()
	shortcut.setEnabled(true)
	shortcut.setIcon("device-mobile")

	-- connected = paired AND reachable；显示选中设备电量，否则显示连接数
	if d and d.source ~= "adb" and d.isPaired and d.isReachable
		and type(d.batteryCharge) == "number" and d.batteryCharge >= 0 then
		shortcut.setLabel(tostring(d.batteryCharge) .. "%")
		shortcut.setActive(true)
	else
		shortcut.setLabel(n > 0 and (tostring(n) .. " " .. t("status.connected"))
			or t("status.no_devices"))
		shortcut.setActive(n > 0)
	end
end

function update()
	noctalia.setUpdateInterval(3000)
	render()
end

function onClick()
	noctalia.togglePanel(common.panelId())
end

noctalia.state.watch("pc.devices", render)
noctalia.state.watch("pc.order", render)
noctalia.state.watch("pc.selected", render)
noctalia.state.watch("pc.backend", render)
noctalia.state.watch("pc.trTable", render)

render()
