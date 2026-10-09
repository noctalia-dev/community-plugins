--!nonstrict

local busy = false
local actions = {
    status = true, launch = true, ["open-videos"] = true, ["save-replay"] = true,
    ["toggle-record"] = true, ["toggle-replay"] = true, ["toggle-stream"] = true,
}

local function run(action)
    if busy or not actions[action] then return end
    busy = true
    noctalia.state.set("busy", true)
    local argv = {
        noctalia.expandPath(noctalia.getConfig("python_executable")),
        noctalia.pluginDir() .. "/obs_control.py", action,
    }
    if noctalia.getConfig("auto_close_managed_obs") then table.insert(argv, "--auto-close") end
    if noctalia.getConfig("open_videos_after_stop") then table.insert(argv, "--open-videos") end
    local accepted = noctalia.runAsync(argv, function(result)
        busy = false
        noctalia.state.set("busy", false)
        local data = noctalia.json.decode(result.stdout or "")
        if type(data) ~= "table" then
            data = { connected = false, error = noctalia.tr("helper-failed") }
        end
        noctalia.state.set("status", data)
        if action ~= "status" then
            noctalia.notify("OBS Control", data.error or data.message or noctalia.tr("done"))
        end
    end, 30000)
    if not accepted then
        busy = false
        noctalia.state.set("busy", false)
        noctalia.state.set("status", { connected = false, error = noctalia.tr("helper-failed") })
    end
end

noctalia.setUpdateInterval(noctalia.getConfig("poll_interval_ms"))
noctalia.state.watch("action", run)

function update() run("status") end
function onIpc(event, _payload) run(event) end

run("status")
