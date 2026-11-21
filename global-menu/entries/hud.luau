--!nonstrict
-- hud.luau - HUD-style search of the focused application's menus
--
-- A launcher provider: type its prefix (default /hud) in the launcher, or
-- bind a key to `noctalia msg panel-toggle launcher /hud`. Every enabled
-- item of the focused application's menus becomes one row that reads like
-- the menu itself ("File › Export   (Ctrl+E)"), so any item can be found by
-- typing a few letters of it. Choosing a row sends the same activate
-- command the popup panel uses.
--
-- The menu tree comes from the "menu" state key, which the service keeps
-- current for the focused window; this entry never talks to D-Bus itself.
-- See menu-hud.luau for the variant that browses the menus as a tree.

local hud = require("./entries/hudlib.luau")

function onQuery(query)
    local menu = hud.currentMenu(query)
    if menu == nil then return end
    hud.search(query, menu, menu.tree, {}, query)
end

function onActivate(id)
    hud.activate(id)
end
