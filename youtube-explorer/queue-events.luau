-- Forward player updates to the launcher through the plugin's shared state.
local deadline
local function arm(value)
    deadline = type(value) == "number" and value or nil
    noctalia.setUpdateInterval(deadline and math.max(16, math.min(1000, deadline - noctalia.nowMs())) or 60000)
end
noctalia.state.watch("work_deadline", arm)
arm(noctalia.state.get("work_deadline"))
function update()
    if deadline and noctalia.nowMs() >= deadline then
        arm(nil)
        noctalia.state.set("work_tick", noctalia.nowMs())
    end
end
function onIpc(event, token)
    if event == "queue-changed" then noctalia.state.set("queue_revision", token)
    elseif event == "playback-error" then
        noctalia.notifyError(noctalia.tr("queue.video_failed"))
    elseif event == "autoplay-error" then
        noctalia.notifyError(token == "empty" and noctalia.tr("autoplay.empty")
            or token == "network" and noctalia.tr("autoplay.network_failed")
            or noctalia.tr("autoplay.failed"))
    end
end
