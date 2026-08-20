local API = {}

local const = require("./api/constants.luau")
local COOKIE_PATH = const.COOKIE_PATH

local REQUIRED_MODULES = {
    "./api/search.luau",
    "./api/stats.luau",
    "./api/thumbnails.luau",
    "./api/likes.luau",
    "./api/cache.luau",
    "./api/browse.luau",
    "./api/resolve.luau",
}

for _, path in ipairs(REQUIRED_MODULES) do
    for k, v in pairs(require(path)) do
        API[k] = v
    end
end

function API.cookies_available(cb)
    cb(noctalia.fileExists(COOKIE_PATH))
end

return API