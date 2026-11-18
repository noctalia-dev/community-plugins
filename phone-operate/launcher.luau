-- launcher.luau
-- launcher_provider：ph 前缀搜 adb 设备，选中即投屏（走 pc.cmd 通道）。
local common = require("./lib/common.luau")

local sendCmd = common.sendCmd

function onQuery(text)
	local devices = noctalia.state.get("pc.devices") or {}
	local order = noctalia.state.get("pc.order") or {}
	local results = {}
	local lower = string.lower(text or "")
	for _, id in ipairs(order) do
		local dev = devices[id]
		-- 只列 adb 设备（launcher 语义 = 选中即投屏）
		if dev and dev.source == "adb"
			and (text == "" or string.find(string.lower(dev.name or id), lower, 1, true)) then
			local online = dev.isReachable == true
			table.insert(results, {
				id = id,
				title = dev.name or id,
				subtitle = (dev.transport or "usb") .. (online and " · online" or " · offline"),
				glyph = dev.transport == "wifi" and "wifi" or "usb",
			})
		end
	end
	if #results == 0 then
		launcher.setResults(text, {
			{ id = "none", title = "No device", glyph = "alert-triangle" },
		})
	else
		launcher.setResults(text, results)
	end
end

function onActivate(id)
	if id == "none" then return end
	-- 选中即投屏：从 id（"adb:<serial>"）取序列号
	local adbId = id:sub(5)
	sendCmd({ op = "select", device = id })
	sendCmd({ op = "cast", device = adbId })
end