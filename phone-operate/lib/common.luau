-- lib/common.luau
-- UI 层公共工具：翻译、命令通道、设备状态辅助。
-- 供 panel / widget / tile / launcher 复用，消除跨文件重复。

local M = {}

-- 本地翻译：读 service 发布的 pc.trTable，运行时切换语言
-- （区别于 noctalia.tr() 跟随系统 locale）
function M.t(key)
	local table = noctalia.state.get("pc.trTable") or {}
	return table[key] or key
end

-- 命令通道：seq 必须严格递增（service 按 seq 丢弃旧命令）。
-- 单一共享 cmdSeq，避免 panel 与 launcher 各自从 0 计数、
-- 在同一秒内发出相同 seq 导致 service 丢弃后到的命令。
local cmdSeq = 0
function M.sendCmd(cmd)
	cmdSeq = cmdSeq + 1
	cmd.seq = os.time() * 1000000 + cmdSeq
	noctalia.state.set("pc.cmd", cmd)
end

-- 面板 id：按 panel_placement 设置选择 attached/floating/部件下方
function M.panelId()
	local mode = noctalia.getConfig("panel_placement")
	if mode == "floating" then
		return "icefish/phone-operate:main_floating"
	elseif mode == "widget" then
		return "icefish/phone-operate:main_widget"
	end
	return "icefish/phone-operate:main"
end

-- 设备类型 → 图标
function M.deviceGlyph(d)
	if not d then return "device-mobile" end
	local tp = d.type
	if tp == "tablet" then return "device-tablet" end
	if tp == "laptop" then return "device-laptop" end
	if tp == "desktop" or tp == "computer" then return "device-desktop" end
	if tp == "tv" then return "device-tv" end
	return "device-mobile"
end

function M.batteryGlyph(charge, charging)
	if charging then return "battery-charging" end
	if type(charge) ~= "number" then return "battery" end
	if charge >= 90 then return "battery" end
	if charge >= 60 then return "battery-3" end
	if charge >= 30 then return "battery-2" end
	if charge > 0 then return "battery-1" end
	return "battery-off"
end

-- wifi 序列号形如 "192.168.1.3:5555"，host 即设备 IP
function M.ipFromSerial(serial)
	return serial:match("^(%d+%.%d+%.%d+%.%d+):%d+$")
end

-- adb 设备是否已被某个 KDE 设备覆盖（IP 匹配关联了同一 adbId）。
-- 被覆盖的 adb 设备不再显示独立卡，统一由 KDE 设备卡管理（投屏/停止）。
function M.adbCoveredByKde(d, devices)
	if not d or d.source ~= "adb" then return false end
	for _, other in pairs(devices) do
		if other.source ~= "adb" and other.adbId and other.adbId == d.adbId then
			return true
		end
	end
	return false
end

-- 选中设备：优先 pc.selected，被覆盖则回退到首个可见设备
function M.selectedDevice()
	local devices = noctalia.state.get("pc.devices") or {}
	local order = noctalia.state.get("pc.order") or {}
	local sel = noctalia.state.get("pc.selected")
	local id = sel
	if not id or not devices[id] or M.adbCoveredByKde(devices[id], devices) then
		id = nil
		for _, oid in ipairs(order) do
			if not M.adbCoveredByKde(devices[oid], devices) then
				id = oid
				break
			end
		end
	end
	if id then return devices[id] end
	return nil
end

return M
