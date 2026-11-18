--!nonstrict
-- Network Toolkit — Quick settings hotspot shortcut
local state = noctalia.state.get("network_state") or {}
local cmdSeq = 0

local function render()
    local hs = state.hotspot or {}
    local active = (hs.active == true)
    shortcut.setLabel(active and ((hs.ssid and hs.ssid ~= "") and hs.ssid or noctalia.tr("status.hotspot_active")) or noctalia.tr("panel.hotspot"))
    shortcut.setIcon(active and "broadcast" or "broadcast-off", "broadcast")
    shortcut.setActive(active)
end

noctalia.state.watch("network_state", function(s) if type(s) == "table" then state = s; render() end end)
function onClick()
    cmdSeq += 1
    noctalia.state.set("network_command", { domain = "hotspot", action = "toggle", nonce = os.time() .. "_" .. cmdSeq })
end
render()
