--!nonstrict
-- The layout table, shared by the poller, the capsule and the panel so a glyph
-- or an order is defined once.
--
-- Keys are umbriel's own layout names, exactly as `umbriel workspaces --json`
-- reports them in `.layout` and as `umbriel msg workspace-set-layout:<name>`
-- accepts them. Keeping them identical means no translation table between what
-- is read and what is written.

local LAYOUTS = {
    scrolling = { glyph = "carousel-horizontal", order = 1 },
    dwindle   = { glyph = "layout-2",            order = 2 },
    master    = { glyph = "layout-sidebar",      order = 3 },
}

-- Panel order. A plain pairs() over LAYOUTS would be arbitrary, and the buttons
-- must not move between renders.
local ORDER = { "scrolling", "dwindle", "master" }

local function showConfigKey(name: string): string
    return "show_" .. name
end

-- Unset means show: a fresh install lists every layout rather than none.
local function isEnabled(name: string): boolean
    local raw = noctalia.getConfig(showConfigKey(name))
    return raw == true or raw == "true" or raw == nil
end

return {
    LAYOUTS = LAYOUTS,
    ORDER = ORDER,
    isEnabled = isEnabled,
}
