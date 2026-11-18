-- lib/scrcpy.luau
-- scrcpy 命令组装 + 进程管理。
-- 插件只是参数组装器 + 进程启动器，视频解码/渲染全在 scrcpy 自己的 SDL 窗口里。
-- runAsync 用字符串形式（数组形式需未发布的 plugin_api=24），用户输入经 shell.quote 转义。
local M = {}
local shell = require("./shell.luau")

-- 组装 scrcpy 命令为 shell 字符串（每个参数经 shell.quote 转义）
function M.buildCommand(device, params)
	local parts = { "scrcpy", "-s", shell.quote(device.id) }

	-- 分辨率上限
	if params.max_size then
		table.insert(parts, "--max-size")
		table.insert(parts, shell.quote(tostring(params.max_size)))
	end

	-- 码率（用户输入 Mbps，转为 "8M" 格式）
	-- scrcpy 3.0+ 将 --bit-rate 重命名为 --video-bit-rate；suffix M=x1000000
	if params.bit_rate then
		table.insert(parts, "--video-bit-rate")
		table.insert(parts, shell.quote(tostring(params.bit_rate) .. "M"))
	end

	-- 帧率上限
	if params.max_fps then
		table.insert(parts, "--max-fps")
		table.insert(parts, shell.quote(tostring(params.max_fps)))
	end

	-- 熄屏投屏
	if params.turn_screen_off then
		table.insert(parts, "--turn-screen-off")
	end

	-- 录屏（文件名带时间戳，存到 pluginDataDir）
	if params.record then
		local dir = noctalia.pluginDataDir()
		local ts = os.date("%Y%m%d_%H%M%S")
		table.insert(parts, "--record")
		table.insert(parts, shell.quote(dir .. "/rec_" .. ts .. ".mp4"))
	end

	return table.concat(parts, " ")
end

-- 启动 scrcpy（fire-and-forget，runAsync 不带 callback 不捕获输出）
-- 注意：runAsync 不返回 PID（已知限制，见开发文档 §11.2）。
-- 进程生命周期由 service 层用 running[device_id]=true 追踪，stop 靠 pkill。
-- 返回 runAsync 的布尔值（是否成功启动 detached 进程）。
function M.start(device, params)
	return noctalia.runAsync(M.buildCommand(device, params))
end

-- 停止指定设备的 scrcpy：pkill 精确匹配命令行里的 "-s <device_id>"
function M.stop(device_id)
	noctalia.runAsync("pkill -f " .. shell.quote("scrcpy.*-s " .. device_id))
end

-- 检查指定设备的 scrcpy 是否仍在运行（pgrep）
function M.isRunning(device_id, cb)
	noctalia.runAsync("pgrep -f " .. shell.quote("scrcpy.*-s " .. device_id), function(result)
		cb(result.exitCode == 0)
	end)
end

return M
