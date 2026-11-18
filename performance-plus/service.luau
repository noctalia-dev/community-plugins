local core = require("./core.luau")

function onIpc(event, payload)
    if event == "toggle" then
        local current = noctalia.state.get("performance") == true
        local newMode = not current
        noctalia.state.set("performance", newMode)
        core.toggle(newMode)
        noctalia.log(string.format("[Service] IPC toggled Performance Plus: %s", tostring(newMode)))
    elseif event == "enable" then
        local current = noctalia.state.get("performance") == true
        if not current then
            noctalia.state.set("performance", true)
            core.toggle(true)
            noctalia.log("[Service] IPC enabled Performance Plus")
        else
            noctalia.log("[Service] IPC enable ignored: already active")
        end
    elseif event == "disable" then
        local current = noctalia.state.get("performance") == true
        if current then
            noctalia.state.set("performance", false)
            core.toggle(false)
            noctalia.log("[Service] IPC disabled Performance Plus")
        else
            noctalia.log("[Service] IPC disable ignored: already inactive")
        end
    end
end

function onExit(_signal, _reason)
    if noctalia.state.get("performance") == true then
        noctalia.state.set("performance", false)
        core.toggle(false)
    end
end
