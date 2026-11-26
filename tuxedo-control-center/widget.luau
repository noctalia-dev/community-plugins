--!nonstrict

local STATE = "tuxedo_control_center.profiles"
local PANEL = "detluck/tuxedo-control-center:profiles"
local snap = noctalia.state.get(STATE) or { loading = true, profiles = {} }

local function activeLabel()
    for _, profile in ipairs(snap.profiles or {}) do
        if profile.id == snap.activeId then
            return tostring(profile.name or profile.displayName or profile.id)
        end
    end

    if snap.loading then
        return "TUXEDO profiles"
    end

    if not snap.available then
        return "TUXEDO profiles unavailable"
    end

    if snap.activeId then
        return "Active profile hidden"
    end

    return "No active profile"
end

local function render()
  barWidget.setGlyph("cpu")
  barWidget.setGlyphColor(snap.available and "primary" or "on_surface_variant")
  barWidget.setTooltip({ { key = "TUXEDO Control Center", value = activeLabel() } })
end

noctalia.state.watch(STATE, function(value)
  if type(value) == "table" then
    snap = value
    render()
  end
end)

function onClick()
  noctalia.togglePanel(PANEL)
end

render()
