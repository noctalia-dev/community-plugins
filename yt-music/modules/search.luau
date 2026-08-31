local store = require("./store.luau")
local api = require("../api.luau")

local state = store.state

local Search = {}

function Search.run(query, stype)
    if not (api and api.search) then return end
    stype = (stype == "playlists" or stype == "top") and stype or "songs"
    state.search.pending = true
    state.search.query = tostring(query or "")
    state.search.type = stype
    store.publish()
    api.search(state.search.query, 25, function(results)
        state.search.pending = false
        state.search.results = results or {}
        store.publish()
        if api and api.ensure_thumbnails then
            noctalia.runAsync("true", function()
                api.ensure_thumbnails(state.search.results, store.publish, "search")
            end)
        end
    end, stype)
end

return Search