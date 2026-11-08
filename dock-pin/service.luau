--!nonstrict
-- Polls the target bar's smart_auto_hide state every 2s and publishes it to
-- shared plugin state. pinned = smart_auto_hide is false (bar always visible).

local function configPath()
    local p = noctalia.getConfig("config_path")
    if p == nil or p == "" then
        return "bar.dock.smart_auto_hide"
    end
    return p
end

local function poll()
    noctalia.runAsync("noctalia msg config-get " .. configPath(), function(result)
        if result.exitCode ~= 0 then
            noctalia.state.set("pinned", nil)
            noctalia.state.set("error", (result.stderr or result.stdout or "config-get failed"):sub(1, 120))
            return
        end
        -- smart_auto_hide = true -> smart hiding -> not pinned
        local smart = (result.stdout or ""):find("true", 1, true) ~= nil
        noctalia.state.set("pinned", not smart)
        noctalia.state.set("error", nil)
    end)
end

noctalia.setUpdateInterval(2000)
poll()

function update()
    poll()
end
