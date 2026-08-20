local store = require("./store.luau")
local api = require("../api.luau")

local state = store.state

local Home = {}

function Home.refresh_quick_picks()
    if not (api and api.fetch_quick_picks) then return end
    if state.refreshing_quick_picks then return end
    state.refreshing_quick_picks = true
    store.publish()
    api.fetch_quick_picks(function(qp, mixes)
        state.refreshing_quick_picks = false
        if type(qp) == "table" and #qp > 0 then
            state.quick_picks = qp
        end
        if type(mixes) == "table" and #mixes > 0 then
            state.home_mixes = mixes
        end
        store.publish()
        Home.fetch_home_thumbs()
    end)
end

function Home.fetch_home_thumbs()
    if not (api and api.ensure_thumbnails) then return end
    local combined = {}
    if type(state.quick_picks) == "table" then
        for _, item in ipairs(state.quick_picks) do table.insert(combined, item) end
    end
    if type(state.home_mixes) == "table" then
        for _, item in ipairs(state.home_mixes) do table.insert(combined, item) end
    end
    if #combined > 0 then
        noctalia.runAsync("true", function()
            api.ensure_thumbnails(combined, store.publish, "home")
        end)
    end
end

return Home