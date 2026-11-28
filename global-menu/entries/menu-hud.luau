--!nonstrict
-- menu-hud.luau - browse the focused application's menus as a tree
--
-- A launcher provider (default prefix /menu-hud). With an empty query it
-- lists the top-level menus ("File ›", "Edit ›", ...). Choosing a menu
-- (Enter or click) opens it by setting the query to its path
-- ("File › "), which lists that menu's items and submenus, and so on
-- down. A "‹ Back" row goes up one level. Typing text searches: at the
-- top level it searches every item, like /hud; inside a menu
-- ("File › sav") it searches only that menu.

local hud = require("./entries/hudlib.luau")
local SEP = hud.SEP
local ARROW = "›"

-- ids of rows that open a menu instead of activating an item
local OPEN = "\1open:"

local function pathString(segments)
    return table.concat(segments, SEP)
end

-- the usable child of nodes that is a submenu labelled label
local function submenu(nodes, label)
    label = label:lower()
    for _, node in ipairs(nodes or {}) do
        if hud.usable(node) and hud.hasChildren(node) and
                hud.label(node):lower() == label then
            return node
        end
    end
    return nil
end

-- "File › Recent › nov" -> nodes of File › Recent, the path {"File",
-- "Recent"} and the filter "nov"; nil when the path names no submenu
local function resolve(tree, text)
    -- split on the arrow itself: the launcher trims the trailing space,
    -- so "File › " arrives as "File ›"
    local parts, start = {}, 1
    while true do
        local at = text:find(ARROW, start, true)
        if at == nil then break end
        table.insert(parts, noctalia.string.trim(text:sub(start, at - 1)))
        start = at + #ARROW
    end
    table.insert(parts, noctalia.string.trim(text:sub(start)))
    local filter = table.remove(parts)
    local nodes, path = tree, {}
    for _, segment in ipairs(parts) do
        local node = submenu(nodes, segment)
        if node == nil then return nil end
        nodes = node.children
        table.insert(path, hud.label(node))
    end
    return nodes, path, filter or ""
end

-- one level of the tree: submenus first-class ("Edit ›"), items with
-- their accelerators, and a back row below the top level
local function browse(query, menu, nodes, path)
    local rows = {}
    if #path > 0 then
        local parent = table.clone(path)
        table.remove(parent)
        table.insert(rows, {
            id = OPEN .. pathString(parent),
            title = "‹ Back",
            glyph = "chevron-left",
        })
    end
    for _, node in ipairs(nodes or {}) do
        if hud.usable(node) then
            local label = hud.label(node)
            if hud.hasChildren(node) then
                local sub = table.clone(path)
                table.insert(sub, label)
                table.insert(rows, {
                    id = OPEN .. pathString(sub),
                    title = label .. " ›",
                    icon = menu.app,
                    glyph = "chevron-right",
                })
            elseif label ~= "" then
                local item = hud.leaf(node, path)
                if item ~= nil then
                    table.insert(rows, hud.leafRow(menu, item, false))
                end
            end
        end
    end
    if #rows == 0 then
        hud.message(query, "This menu is empty", pathString(path))
        return
    end
    launcher.setResults(query, rows)
end

function onQuery(query)
    local menu = hud.currentMenu(query)
    if menu == nil then return end
    local text = noctalia.string.trim(query)

    if text == "" then
        browse(query, menu, menu.tree, {})
        return
    end
    if text:find(ARROW, 1, true) then     -- a "›" path was typed
        local nodes, path, filter = resolve(menu.tree, text)
        if nodes ~= nil then
            if filter == "" then
                browse(query, menu, nodes, path)
            else
                hud.search(query, menu, nodes, path, filter)
            end
            return
        end
    end
    -- plain text, or a path that names no menu: search everything
    hud.search(query, menu, menu.tree, {}, text)
end

function onActivate(id)
    if id == nil or id == "" then return end
    if id:sub(1, #OPEN) == OPEN then
        local path = id:sub(#OPEN + 1)
        -- stay in this provider: the host re-adds the prefix
        launcher.setQuery(path == "" and " " or (path .. SEP))
        return
    end
    hud.activate(id)
end
