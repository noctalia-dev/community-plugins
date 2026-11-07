--!nonstrict
-- `/sh`: run a command in the default terminal. Logic lives in shell_core.luau.

local shell = require("./shell_core.luau")
shell.init({ background = false })

function onQuery(query)
	shell.onQuery(query)
end

function onActivate(id)
	shell.onActivate(id)
end
