--!nonstrict
-- Claude Cockpit — "needs you" badge (a [[layer]] entry, plugin_api 36).
--
-- a small overlay pill in the top-right corner of every output showing how
-- many Claude Code sessions wait for input, so it stays visible above
-- fullscreen windows where the bar is hidden. service.luau owns it: it calls
-- noctalia.layer.show("badge") when the waiting count goes above 0 and hide()
-- when it drops to 0 (setting `waiting_badge`). Hiding destroys this runtime,
-- so state is re-read from the shared "live" key on load.
--
--   noctalia.state.get("live")  -- { groups = { waiting = {...}, ... }, error }
--
-- The surface is click-through: it is an indicator, never in the way.

local function waitingCount(live)
    local groups = type(live) == "table" and live.groups or nil
    return type(groups) == "table" and #(groups.waiting or {}) or 0
end

local function render()
    local n = waitingCount(noctalia.state.get("live"))
    layer.render(ui.row({ gap = 6, align = "center", fill = "error", radius = 14, paddingH = 12, paddingV = 6 }, {
        ui.glyph({ name = "bell-ringing", size = 16, color = "on_error" }),
        ui.label({ text = tostring(n), fontSize = 14, fontWeight = "bold", color = "on_error" }),
    }))
end

noctalia.state.watch("live", render)
render()
