--!nonstrict
-- Recording indicator layer: shown by the `indicator` service while a
-- recording is active or paused. Click-through so it doesn't interfere with
-- grabit's own recording control bar.

-- The published status only changes on state transitions, so tick here to
-- advance the elapsed time while the layer is shown.
noctalia.setUpdateInterval(1000)

local RED    = "error"
local AMBER  = "warning"
local DIM    = "#00000040"

local function render()
    local status = noctalia.state.get("status")
    local recState = type(status) == "table" and status.state or "idle"

    if recState ~= "recording" and recState ~= "paused" then
        layer.render(ui.column({}))
        return
    end

    local isPaused = recState == "paused"
    local color    = isPaused and AMBER or RED
    local glyph    = isPaused and "player-pause-filled" or "player-record-filled"
    local label    = isPaused and "Paused" or "Recording"

    local elapsed = ""
    if status.recordingSince and status.recordingSince > 0 then
        local secs = os.time() - status.recordingSince
        local mins = math.floor(secs / 60)
        local s    = secs % 60
        elapsed    = string.format(" %d:%02d", mins, s)
    end

    layer.render(ui.column({
        fill   = DIM,
        height = 32,
    }, {
        ui.row({
            height  = 32,
            padding = { left = 12, right = 12 },
            align   = "center",
            gap     = 8,
        }, {
            ui.glyph({ name = glyph, size = 12, color = color }),
            ui.label({
                text       = label .. elapsed,
                color      = "on_surface",
                fontWeight = "bold",
                fontSize   = 13,
            }),
        }),
    }))
end

function update()
    render()
end

noctalia.state.watch("status", render)
render()