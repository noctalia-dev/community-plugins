--!nonstrict
-- Standalone build only: the layer is lazy, so an always-running entry must
-- show it. The community build ships neither this service nor the layer.

local function sync()
    local status = noctalia.state.get("status")
    local recState = type(status) == "table" and status.state or "idle"

    if recState == "recording" or recState == "paused" then
        noctalia.layer.show("recording")
    else
        noctalia.layer.hide("recording")
    end
end

sync()
noctalia.state.watch("status", sync)
