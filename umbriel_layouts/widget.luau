--!nonstrict
-- Bar capsule. Draws what the watcher published; it never spawns a process of
-- its own, so a bar on each monitor costs nothing extra.
--
-- Each capsule reports ITS OWN output, not the focused one: the bar on eDP-1
-- shows eDP-1's current workspace layout even while focus is on HDMI-A-1.

local shared = require("./shared.luau")
local LAYOUTS = shared.LAYOUTS

local showGlyph = noctalia.getConfig("show_glyph") ~= false
local showText = noctalia.getConfig("show_text") == true
local customColor = noctalia.getConfig("custom_color")

-- Resolved ONCE, at load, and that timing is the whole trick.
-- barWidget.outputName() answers while the script is being evaluated for a given
-- capsule, but returns nil from inside a state.watch callback -- there is no
-- current-instance context there. Calling it lazily from draw() yields nil on
-- every redraw, the capsule falls back to the focused monitor, and the result
-- looks exactly like per-output lookup being unsupported. A bar never moves
-- between outputs, so caching costs nothing and is the correct shape anyway.
local OWN_OUTPUT: string? = (function(): string?
    local reported = barWidget.outputName()
    return if reported ~= nil and reported ~= "" then reported else nil
end)()

-- Which layout this capsule shows: its own output's, falling back to the focused
-- workspace only when the host cannot name this bar's output at all.
local function layoutForThisBar(): string?
    if OWN_OUTPUT ~= nil then
        local byOutput = noctalia.state.get("layouts")
        if type(byOutput) == "table" then
            local found = byOutput[OWN_OUTPUT]
            if type(found) == "string" and found ~= "" then
                return found
            end
        end
        -- Output known but absent from the map: the compositor reports no active
        -- workspace there. Showing the focused layout would be a lie about this
        -- monitor, so show nothing.
        return nil
    end

    local focused = noctalia.state.get("layout")
    return if type(focused) == "string" then focused else nil
end

local function draw()
    local layout = layoutForThisBar()
    local entry = if type(layout) == "string" then LAYOUTS[layout] else nil

    if showGlyph then
        barWidget.setGlyph(if entry ~= nil then entry.glyph else "layout")
    end

    if showText then
        barWidget.setText(if entry ~= nil then noctalia.tr("name_" .. layout) else noctalia.tr("name_unknown"))
    else
        barWidget.setText("")
    end

    if customColor ~= nil and customColor ~= "" then
        barWidget.setColor(customColor)
        barWidget.setGlyphColor(customColor)
    end
end

noctalia.state.watch("layouts", function() draw() end)
noctalia.state.watch("layout", function() draw() end)

function onClick()
    -- One panel entry is shared by every capsule, so it cannot tell which bar
    -- opened it. Publish that here, the way ai-usagebar points its panel at the
    -- provider the clicked capsule tracks.
    noctalia.state.set("panel_output", if OWN_OUTPUT ~= nil then OWN_OUTPUT else "")

    -- Two panel entries, one per shape. A panel's size is fixed in the manifest
    -- and nothing in the panel API resizes it, so the grid and the list -- three
    -- icons across versus three stacked buttons -- cannot share one box without
    -- either wasting space or scrolling. Read the mode here rather than in the
    -- panel: by the time the panel script runs, which panel to open is settled.
    local listRaw = noctalia.getConfig("list_mode")
    local isList = listRaw == true or listRaw == "true"
    noctalia.togglePanel(
        if isList
            then "soheil7799/umbriel_layouts:panel_list"
            else "soheil7799/umbriel_layouts:panel_grid"
    )
end

draw()
