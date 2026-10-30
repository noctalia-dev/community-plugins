--!nonstrict
-- IPC entry point for key bindings plus event-driven taskbar restore.
-- One idle niri event-stream client; no periodic polling.
local client = require("./client.luau")
local root = noctalia.getenv("XDG_STATE_HOME") or ""
if root == "" then root = noctalia.expandPath("~/.local/state") end
local statePath = root .. "/noctalia-minimizer/windows.json"

local function watchLine(line)
    if not client.enabled() or noctalia.getConfig("auto_restore") == false then return end
    if not string.find(line, '"WindowFocusChanged"', 1, true) then return end
    local event = noctalia.json.decode(line)
    local identity = type(event) == "table" and type(event.WindowFocusChanged) == "table" and event.WindowFocusChanged.id or nil
    if type(identity) ~= "number" then return end
    noctalia.readFileAsync(statePath, function(raw, _err)
        if not raw then return end
        local state = noctalia.json.decode(raw)
        if type(state) ~= "table" or type(state.windows) ~= "table" or state.windows[tostring(identity)] == nil then return end
        client.request({"restore-focused", "--id", tostring(identity)}, function(_data, err)
            if err then noctalia.log("Automatic restore: " .. err) end
        end)
    end)
end

if client.enabled() and noctalia.getConfig("auto_restore") ~= false
    and noctalia.commandExists("niri") and noctalia.getenv("NIRI_SOCKET") then
    -- Static command; no titles, settings or user text are interpolated.
    noctalia.runStream("exec niri msg --json event-stream", watchLine)
end

function onIpc(event, _payload)
    if event == "minimize" then client.minimize()
    elseif event == "minimize-all" then client.minimizeAll()
    elseif event == "restore-all" then client.restoreAll()
    elseif event == "restore-last" then client.restoreLast()
    elseif (event == "windows" or event == "panel") and client.enabled() then
        noctalia.togglePanel("swashx-dev/minimize:windows")
    end
end
