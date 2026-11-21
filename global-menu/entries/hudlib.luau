--!nonstrict
-- hudlib.luau - shared by the two HUD launcher providers (hud.luau and
-- menu-hud.luau): reads the focused application's menu tree from the
-- "menu" state key, flattens and searches it, formats result rows and
-- sends activations to the daemon.
--
-- Labels arrive without mnemonic markers and accelerators arrive
-- formatted (accelLabel), so the HUD and the panel always agree.

local M = {}

M.SEP = " › "
local MAX_RESULTS = 200

local function postCommand(body)
    local port = tonumber(noctalia.state.get("port"))
    if port == nil then return end
    noctalia.http({
        url = "http://127.0.0.1:" .. tostring(port) .. "/cmd",
        method = "POST",
        headers = {
            "Content-Type: application/json",
            "X-GlobalMenu-Token: " .. tostring(noctalia.state.get("token") or ""),
        },
        body = noctalia.json.encode(body),
    }, function() end)
end

function M.label(node)
    return noctalia.string.trim(tostring(node.label or ""))
end

-- a node the HUD can show: not a separator, not disabled, has a label
-- or children
function M.usable(node)
    return type(node) == "table" and node.separator ~= true and
            node.enabled ~= false
end

function M.hasChildren(node)
    return type(node.children) == "table" and #node.children > 0
end

-- every enabled leaf below nodes, in menu order
local function flatten(nodes, path, out)
    for _, node in ipairs(nodes or {}) do
        if M.usable(node) then
            local label = M.label(node)
            if M.hasChildren(node) then
                local sub = table.clone(path)
                if label ~= "" then table.insert(sub, label) end
                flatten(node.children, sub, out)
            elseif label ~= "" then
                table.insert(out, {
                    label = label,
                    path = table.concat(path, M.SEP),
                    key = tostring(node.key or node.label or ""),
                    accel = node.accelLabel,
                    checked = node.toggleState == true and
                            node.toggleType ~= nil and node.toggleType ~= "",
                })
            end
        end
    end
    return out
end

-- every word of the query must appear in the label or the path; matches
-- in the label rank above matches only in the path
local function score(item, words, query)
    local label = item.label:lower()
    local hay = label .. " " .. item.path:lower()
    for _, word in ipairs(words) do
        if hay:find(word, 1, true) == nil then return nil end
    end
    if query == "" then return 0 end
    if label:sub(1, #query) == query then return 3 end
    if label:find(query, 1, true) then return 2 end
    if label:find(words[1], 1, true) then return 1 end
    return 0
end

-- one launcher row for a leaf; the activation key itself is the row id,
-- so a re-query while the launcher is open can never shift which item
-- runs. showPath: prefix the menu path ("File › Export   (Ctrl+E)")
function M.leafRow(menu, item, showPath)
    local title = item.label
    if showPath and item.path ~= "" then
        title = item.path .. M.SEP .. item.label
    end
    if item.checked then title = "✓ " .. title end
    if item.accel ~= nil and item.accel ~= "" then
        title = title .. "   (" .. item.accel .. ")"
    end
    return { id = item.key, title = title, icon = menu.app, glyph = "menu-2" }
end

-- the leaf item record for a single tree node
function M.leaf(node, path)
    return flatten({ node }, path, {})[1]
end

function M.message(query, title, subtitle)
    launcher.setResults(query, { {
        id = "", title = title, subtitle = subtitle, glyph = "menu-2",
    } })
end

-- the focused app's menu snapshot, or nil after showing why there is none
function M.currentMenu(query)
    local menu = noctalia.state.get("menu")
    local app = type(menu) == "table" and (menu.appName or menu.app) or nil
    if type(menu) ~= "table" or type(menu.tree) ~= "table" or
            menu.source == nil or menu.source == "none" then
        M.message(query, "No menu for this window", app)
        return nil
    end
    return menu
end

-- the search results for text over nodes (whose own path is basePath),
-- best match first; shows a message when nothing matches
function M.search(query, menu, nodes, basePath, text)
    text = noctalia.string.trim(text or ""):lower()
    local words = {}
    for word in text:gmatch("%S+") do table.insert(words, word) end

    local matches = {}
    for index, item in ipairs(flatten(nodes, basePath or {}, {})) do
        local s = score(item, words, text)
        if s ~= nil then
            table.insert(matches, { item = item, score = s, order = index })
        end
    end
    -- stable: best score first, then menu order
    table.sort(matches, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return a.order < b.order
    end)

    local rows = {}
    for i, match in ipairs(matches) do
        if i > MAX_RESULTS then break end
        table.insert(rows, M.leafRow(menu, match.item, true))
    end
    if #rows == 0 then
        M.message(query, "No matching menu item", menu.appName or menu.app)
        return
    end
    launcher.setResults(query, rows)
end

function M.activate(key)
    if key ~= nil and key ~= "" then
        postCommand({ cmd = "activate", key = key })
    end
end

return M
