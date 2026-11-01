--!nonstrict
-- `/shb`: run a command detached in the background, without a terminal window.
-- Logic lives in shell_core.luau.

local shell = require("./shell_core.luau")
shell.init({ background = true })

function onQuery(query)
	shell.onQuery(query)
end

function onActivate(id)
	shell.onActivate(id)
end
