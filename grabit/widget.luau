--!nonstrict
-- Grabit Launcher - bar widget (thin presentation client).
-- The service owns grabit tracking; this widget mirrors the published "status"
-- and drives grabit by writing to the "command" channel.

-- The status channel only changes on transitions, so tick while recording to
-- keep the tooltip's elapsed time advancing.
noctalia.setUpdateInterval(1000)

local state = "idle" -- idle | pending | recording | paused
local available = false
local recordingSince = 0

local function send(action, extra)
    local payload = { action = action }
    if extra then
        for k, v in pairs(extra) do payload[k] = v end
    end
    noctalia.state.set("command", payload)
end

local function formatDuration(seconds)
    if not seconds or seconds <= 0 then return "00:00" end
    local mins = math.floor(seconds / 60)
    local secs = seconds % 60
    return string.format("%d:%02d", mins, secs)
end

local function applyStatus(status)
    if type(status) == "table" then
        state = status.state or "idle"
        available = if status.available then true else false
        recordingSince = status.recordingSince or 0
    end

    local hideInactive = noctalia.getConfig("hide_inactive")

    if not available then
        barWidget.setGlyph("screenshot")
        barWidget.setGlyphColor("on_surface_variant")
        barWidget.setTooltip({
            { label = "Grabit", value = "not installed" },
        })
        barWidget.setVisible(not hideInactive)
        return
    end

    if state == "recording" then
        barWidget.setGlyph("video-filled")
        barWidget.setGlyphColor("error")
        barWidget.setColor("error")
        barWidget.setTooltip({
            { label = "Recording", value = formatDuration(os.time() - recordingSince) },
            { label = "Left click", value = "Stop" },
            { label = "Right click", value = "Pause" },
        })
        barWidget.setVisible(true)

    elseif state == "paused" then
        barWidget.setGlyph("player-pause-filled")
        barWidget.setGlyphColor("warning")
        barWidget.setColor("warning")
        barWidget.setTooltip({
            { label = "Paused", value = formatDuration(os.time() - recordingSince) },
            { label = "Left click", value = "Resume" },
            { label = "Right click", value = "Stop" },
        })
        barWidget.setVisible(true)

    elseif state == "pending" then
        barWidget.setGlyph("video")
        barWidget.setGlyphColor("primary")
        barWidget.setColor("primary")
        barWidget.setTooltip({
            { label = "Starting recording..." },
        })
        barWidget.setVisible(true)

    else
        barWidget.setGlyph("screenshot")
        barWidget.setGlyphColor("on_surface")
        barWidget.setTooltip("Grabit")
        barWidget.setVisible(not hideInactive)
    end
end

-- ── Pointer callbacks ────────────────────────────────────────────

function onClick()
    if not available then return end

    if state == "recording" then
        send("stop")
    elseif state == "paused" then
        send("resume")
    elseif state == "pending" then
        send("stop")
    else
        -- default capture action from config
        send("capture", { mode = noctalia.getConfig("default_action") })
    end
end

function onRightClick()
    if not available then return end

    if state == "recording" then
        send("pause")
        return
    elseif state == "paused" then
        send("stop")
        return
    end

    -- open mode menu
    send("menu")
end

function onMiddleClick()
    if not available or state ~= "idle" then return end
    send("capture", { mode = "last" })
end

function onScroll(axis, steps, startsGesture)
    if not available or state ~= "idle" then return end
    if not startsGesture then return end

    if axis == "vertical" then
        if steps > 0 then
            send("capture", { mode = "window" })
        else
            send("capture", { mode = "fullscreen" })
        end
    end
end

-- ── Init ─────────────────────────────────────────────────────────

function update()
    if state == "recording" or state == "paused" then
        applyStatus(noctalia.state.get("status"))
    end
end

applyStatus(noctalia.state.get("status"))
noctalia.state.watch("status", applyStatus)
