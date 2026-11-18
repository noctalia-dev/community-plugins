--!nonstrict

local vaults = require("./vaults.luau")

function onQuery(query)
    vaults.onQuery(query, false)
end

function onActivate(id)
    vaults.onActivate(id)
end
