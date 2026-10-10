--!nonstrict
-- Bar capsule: a flag and the short countdown to the next session. While a
-- session is live the flag takes the attention colour and the pill reads LIVE.
-- All data comes from the poller through noctalia.state; this entry only
-- computes what to show. Clicking opens the panel.

local shared = require("./shared.luau")

local PANEL_ID = "gcap0n1/f1:panel"
local GLYPH = "flag"

local race = noctalia.state.get("race")
local live = noctalia.state.get("live")

local function currentRace()
    if type(race) == "table" and type(race.sessions) == "table" then return race end
    return nil
end

local function forceTabs()
    return noctalia.getConfig("debug_force_tabs") == true
end

-- The instant the pill counts down to: the race, or the next session.
local function targetTs(now)
    local r = currentRace()
    if r == nil then return nil end
    if noctalia.getConfig("countdown_target") == "session" then
        local nextSession = shared.nextSession(r.sessions, now)
        if nextSession ~= nil then return nextSession.ts end
    end
    return shared.sessionTs(r.sessions, "race")
end

local function render()
    local now = shared.nowSec()
    local r = currentRace()
    local isLive = r ~= nil and shared.liveActive(live, r.sessions, now, forceTabs())

    barWidget.setGlyph(GLYPH)

    if isLive then
        barWidget.setGlyphColor("primary")
        barWidget.setText(noctalia.tr("bar.live"))
        local leader = live.rows[1] and live.rows[1].code or ""
        local rows = { { key = noctalia.tr("bar.live"), value = r.name } }
        if leader ~= "" then
            rows[#rows + 1] = { key = noctalia.tr("tooltip.leader"), value = leader }
        end
        local flag = shared.friendlyFlag(live.flag)
        if flag ~= "" then
            rows[#rows + 1] = { key = noctalia.tr("tooltip.flag"), value = flag }
        end
        barWidget.setTooltip(rows)
        return
    end

    barWidget.setGlyphColor("on_surface")
    local target = targetTs(now)
    if r == nil or target == nil then
        barWidget.setText("")
        barWidget.setTooltip(noctalia.tr("tooltip.title"))
        return
    end

    barWidget.setText(shared.fmtShort(target - now))
    local raceTs = shared.sessionTs(r.sessions, "race")
    barWidget.setTooltip({
        { key = r.name, value = raceTs and shared.fmtDateTime(raceTs, true) or "" },
        { key = r.circuitName, value = shared.fmtLong((raceTs or target) - now) },
    })
end

noctalia.state.watch("race", function(value)
    race = value
    render()
end)

noctalia.state.watch("live", function(value)
    live = value
    render()
end)

function onClick()
    noctalia.togglePanel(PANEL_ID)
end

-- Countdowns move in whole minutes, so a few seconds of lag is invisible.
function update()
    render()
end

noctalia.setUpdateInterval(5000)
render()
