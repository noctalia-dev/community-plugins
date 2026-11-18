-- lib/shell.luau
-- shell 字符串转义工具。
-- runAsync 的数组形式需 plugin_api=24（direct-argv，未发布），字符串形式走 /bin/sh -c（level 3 起支持）。
-- 用户输入拼进 shell 字符串时必须转义，避免注入/破坏。
local M = {}

-- 单引号包裹并转义内嵌单引号：' -> '\''
function M.quote(s)
	s = tostring(s)
	return "'" .. s:gsub("'", "'\\''") .. "'"
end

return M
