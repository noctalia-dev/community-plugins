local M = {}

local function detect()
    if noctalia.getenv("HYPRLAND_INSTANCE_SIGNATURE") then return "hyprland" end
    if noctalia.getenv("UMBRIEL_SOCKET") then return "umbriel" end
    if noctalia.getenv("SWAYSOCK") then return "sway" end
    if noctalia.getenv("NIRI_SOCKET") then return "niri" end
    if noctalia.getenv("MANGO_INSTANCE_SIGNATURE") then return "mango" end
    if noctalia.getenv("LABWC_PID") then return "labwc" end

    local desktop = (noctalia.getenv("XDG_CURRENT_DESKTOP") or ""):lower()
    if noctalia.getenv("KWIN_WAYLAND") or string.find(desktop, "kde") then return "kwin" end
    if string.find(desktop, "hypr") then return "hyprland" end
    if string.find(desktop, "sway") then return "sway" end
    if string.find(desktop, "niri") then return "niri" end
    if string.find(desktop, "labwc") then return "labwc" end
    if string.find(desktop, "mango") then return "mango" end
    if string.find(desktop, "umbriel") then return "umbriel" end

    return "generic"
end

local compName = detect()
noctalia.log(string.format("[Adapters] Detected compositor: %s", compName))

local adapter = nil
if compName == "hyprland" then
    adapter = require("./hyprland.luau")
elseif compName == "sway" then
    adapter = require("./sway.luau")
elseif compName == "kwin" then
    adapter = require("./kwin.luau")
elseif compName == "umbriel" then
    adapter = require("./umbriel.luau")
elseif compName == "mango" then
    adapter = require("./mango.luau")
elseif compName == "niri" then
    adapter = require("./niri.luau")
elseif compName == "labwc" then
    adapter = require("./labwc.luau")
else
    adapter = require("./generic.luau")
end

function M.getCompositor()
    return compName
end

function M.enable(opts)
    if adapter and adapter.enable then
        adapter.enable(opts or {})
    end
end

function M.disable(opts)
    if adapter and adapter.disable then
        adapter.disable(opts or {})
    end
end

return M
