--!nonstrict
-- panel.luau - the popup menu surface for amancode22/global-menu
--
-- Renders one menu of the focused application as a ui.* tree: rows with
-- checkmarks, accelerators and submenu chevrons, keyboard navigation via
-- capture_keys, and click-to-enter submenu navigation with a back row.
-- Activation is sent to the companion daemon over its loopback HTTP
-- command endpoint; the daemon talks to the application.
--
-- Besides real application menus the panel hosts three synthetic
-- surfaces picked by reserved openMenu labels:
--   __app__       the macOS-style application menu: About, Minimize,
--                 Maximize, Fullscreen, Resize options and Quit
--   __about__     an information view for the focused application
--   __overflow__  the menu labels that did not fit in the bar (the »
--                 button on the right of the strip)

local PANEL = "amancode22/global-menu:menu"

local MODE_MENU = "menu"
local MODE_APP = "app"
local MODE_ABOUT = "about"
local MODE_OVERFLOW = "overflow"

local data = nil          -- menu snapshot from the state channel
local mode = MODE_MENU    -- which surface is showing
local nav = nil           -- array of child indices from the surface root
local selIndex = 1        -- keyboard selection within the visible items
local depthLabels = {}    -- breadcrumb labels for the nav stack
local hoverIndex = nil    -- pointer-hovered item within the visible items
local specialRoot = nil   -- synthetic item list for app/overflow surfaces

-- defined near the bottom; activate() and view callbacks below call it
local syncFromState

-- pill styling: every row is its own rounded button, floating free of its
-- neighbours so the list never reads as one merged block
local ROW_HEIGHT = 34
local ROW_RADIUS = 8
local ROW_PAD_H = 12
local ROW_GAP = 10
local LIST_GAP = 3
local LABEL_MAX_W = 236

-- ---------------------------------------------------------------- helpers

local function getPort()
    return tonumber(noctalia.state.get("port"))
end

local function getToken()
    return tostring(noctalia.state.get("token") or "")
end

local function appName()
    if data == nil then return nil end
    if data.appName ~= nil and data.appName ~= "" then return data.appName end
    if data.app ~= nil and data.app ~= "" then return data.app end
    return nil
end

local function postCommand(body)
    local port = getPort()
    if port == nil then return end
    noctalia.http({
        url = "http://127.0.0.1:" .. tostring(port) .. "/cmd",
        method = "POST",
        headers = {
            "Content-Type: application/json",
            "X-GlobalMenu-Token: " .. getToken(),
        },
        body = noctalia.json.encode(body),
    }, function() end)
end

local function features()
    local f = noctalia.state.get("features")
    return type(f) == "table" and f or {}
end

local function windowState()
    local w = noctalia.state.get("window")
    return type(w) == "table" and w or {}
end

-- resolve the focused app's desktop icon once per app and size
local iconCache = {}
local function appIcon(sizePx)
    if data == nil or data.app == nil or data.app == "" then return nil end
    local key = tostring(data.app) .. ":" .. tostring(sizePx)
    if iconCache[key] == nil then
        local ok, path = pcall(function()
            return noctalia.appIconPath(tostring(data.app), sizePx)
        end)
        iconCache[key] = (ok and path ~= nil) and path or false
    end
    local cached = iconCache[key]
    return cached ~= false and cached or nil
end

local function formatAccel(raw)
    if raw == nil or raw == "" then return nil end
    local out = tostring(raw):gsub("<([^<>]*)>", function(part)
        return part .. "+"
    end)
    out = out:gsub("+$", "")
    out = out:gsub("_", " ")
    if out == "" then return nil end
    return out
end

local function childItems(node)
    local items = {}
    if node == nil or node.children == nil then return items end
    for _, child in ipairs(node.children) do
        if type(child) == "table" then
            table.insert(items, child)
        end
    end
    return items
end

local function hasRealChildren(node)
    for _, child in ipairs(childItems(node)) do
        if child.separator ~= true then
            return true
        end
    end
    return false
end

-- look for the application's own Quit/Exit item (top-level menus only);
-- activating it quits the app even when it hides to a tray on close
local function findQuitKey()
    if data == nil or data.tree == nil then return nil end
    for _, top in ipairs(data.tree) do
        if type(top) == "table" and top.children ~= nil then
            for _, child in ipairs(top.children) do
                if type(child) == "table" and child.separator ~= true then
                    local lab = tostring(child.label or ""):lower()
                    if lab == "quit" or lab == "exit" or
                            lab:sub(1, 5) == "quit " or lab:sub(1, 5) == "exit " then
                        return child.key or child.label
                    end
                end
            end
        end
    end
    return nil
end

-- --------------------------------------------- synthetic app menu surface

local function buildAppMenu()
    local name = appName() or "Application"
    local feats = features()
    local win = windowState()
    local tl = feats.toplevels == true
    local fs = tl and feats.fullscreen == true
    local maximized = win.maximized == true
    local fullscreenOn = win.fullscreen == true

    local items = {}
    items[#items + 1] = { label = "About " .. name, view = "__about__",
                          fontWeight = "bold" }
    items[#items + 1] = { separator = true }
    items[#items + 1] = { label = "Minimize",
                          action = { cmd = "window", action = "minimize" },
                          enabled = tl and win.minimized ~= true }
    items[#items + 1] = { label = "Maximize",
                          action = { cmd = "window", action = "maximize" },
                          enabled = tl,
                          toggleType = maximized and "check" or "",
                          toggleState = maximized }
    items[#items + 1] = { label = "Fullscreen",
                          action = { cmd = "window", action = "fullscreen" },
                          enabled = fs,
                          toggleType = fullscreenOn and "check" or "",
                          toggleState = fullscreenOn }
    items[#items + 1] = { separator = true }
    -- the resize cluster: everything the foreign-toplevel protocol can
    -- do to a window's geometry, grouped the way the bar cannot show it
    items[#items + 1] = { label = "Resize", children = {
        { label = "Restore Size",
          action = { cmd = "window", action = "restore" },
          enabled = tl and (maximized or fullscreenOn) },
        { label = "Maximize",
          action = { cmd = "window", action = "maximize" },
          enabled = tl,
          toggleType = maximized and "check" or "",
          toggleState = maximized },
        { label = "Fullscreen",
          action = { cmd = "window", action = "fullscreen" },
          enabled = fs,
          toggleType = fullscreenOn and "check" or "",
          toggleState = fullscreenOn },
    } }
    items[#items + 1] = { separator = true }
    local quitKey = findQuitKey()
    if quitKey ~= nil then
        -- let the application quit itself (tray apps, unsaved prompts)
        items[#items + 1] = { label = "Quit " .. name,
                              action = { cmd = "activate", key = quitKey } }
    else
        items[#items + 1] = { label = "Quit " .. name,
                              action = { cmd = "window", action = "quit" },
                              enabled = tl }
    end
    return items
end

local function buildOverflowMenu()
    local list = noctalia.state.get("overflow")
    local items = {}
    if type(list) == "table" then
        for _, label in ipairs(list) do
            if type(label) == "string" and label ~= "" then
                items[#items + 1] = { label = label, openMenuLabel = label }
            end
        end
    end
    return items
end

-- raw position of a top-level menu in the tree, separators included -
-- the same index space the nav stack and the keyboard selection use
local function topIndexForLabel(label)
    if data == nil or data.tree == nil then return 1 end
    if label ~= nil and label ~= "" then
        local seen = 0
        for _, node in ipairs(data.tree) do
            if type(node) == "table" then
                seen = seen + 1
                if node.label == label then
                    return seen
                end
            end
        end
    end
    return 1
end

-- resolve the current nav stack to the list of visible items
local function surfaceRoot()
    if mode == MODE_APP or mode == MODE_OVERFLOW then
        return specialRoot
    end
    return (data ~= nil and data.tree ~= nil) and data.tree or nil
end

local function currentItems()
    local root = surfaceRoot()
    if root == nil then return nil, nil end
    local node = { children = root, label = "" }
    local items = root
    -- nav holds the same raw indices the renderer and the keyboard
    -- selection use: positions in each level's child list, separators
    -- included
    for level, index in ipairs(nav or {}) do
        local chosen = childItems(node)[index]
        if chosen == nil or chosen.separator == true then
            -- the tree changed under us; clamp back to the top level
            nav = nil
            depthLabels = {}
            if mode == MODE_APP then specialRoot = buildAppMenu() end
            if mode == MODE_OVERFLOW then specialRoot = buildOverflowMenu() end
            root = surfaceRoot()
            if root == nil then return nil, nil end
            nav = {}
            return root, ""
        end
        node = chosen
        items = childItems(node)
    end
    local label = depthLabels[#depthLabels] or ""
    return items, label
end

-- ------------------------------------------------------------- activation

local function activate(item, index)
    if item == nil or item.separator == true then return end
    selIndex = index
    if hasRealChildren(item) then
        -- enter the submenu
        table.insert(nav, selIndex)
        table.insert(depthLabels, item.label or "")
        selIndex = 1
        render()
        return
    end
    if item.enabled == false then return end
    if item.view ~= nil then
        -- move to a synthetic surface (the About view)
        noctalia.state.set("openMenu", item.view)
        syncFromState()
        render()
        return
    end
    if item.openMenuLabel ~= nil then
        -- swap the popup to that top-level menu, like a bar click
        noctalia.state.set("openMenu", item.openMenuLabel)
        syncFromState()
        render()
        return
    end
    if item.action ~= nil then
        -- synthetic command: window control or app-menu action
        postCommand(item.action)
        panel.close()
        return
    end
    postCommand({ cmd = "activate", key = item.key or item.label or "" })
    panel.close()
end

-- ----------------------------------------------------------------- render

local function renderRow(item, index, items)
    if item.separator == true then
        return ui.separator({ thickness = 1, spacing = 4,
                              color = "on_surface/0.12",
                              orientation = "horizontal" })
    end

    local enabled = item.enabled ~= false
    local selected = index == selIndex
    local hovered = index == hoverIndex
    local accel = formatAccel(item.accel)
    local navigable = hasRealChildren(item)

    -- quiet pill by default, tinted under the pointer or the keyboard
    -- selection; disabled rows stay faint so they never invite a click
    local fill
    if not enabled then
        fill = "on_surface/0.02"
    elseif selected and hovered then
        fill = "primary/0.26"
    elseif selected or hovered then
        fill = "primary/0.16"
    else
        fill = "on_surface/0.04"
    end
    local textColor = enabled and "on_surface" or "on_surface/0.4"

    local row = {}

    if item.toggleType ~= nil and item.toggleType ~= "" and
            item.toggleState == true then
        table.insert(row, ui.glyph({
            name = "check", size = 14,
            color = enabled and "primary" or "on_surface/0.4",
        }))
    else
        table.insert(row, ui.box({ width = 16 }))
    end

    table.insert(row, ui.label({
        text = item.label or "",
        color = textColor,
        fontWeight = item.fontWeight or
                (navigable and "semibold" or "normal"),
        maxWidth = LABEL_MAX_W,
        maxLines = 1,
    }))

    -- push the accelerator and chevron to the row's right edge
    if accel ~= nil or navigable then
        table.insert(row, ui.box({ flexGrow = 1 }))
    end

    if accel ~= nil then
        table.insert(row, ui.label({
            text = accel,
            color = "on_surface/0.45",
            fontSize = 12,
            maxLines = 1,
        }))
    end

    if navigable then
        table.insert(row, ui.glyph({
            name = "chevron-right", size = 13,
            color = "on_surface/0.45",
        }))
    end

    return ui.row({
        key = "it-" .. tostring(#(nav or {})) .. "-" .. tostring(index),
        height = ROW_HEIGHT,
        gap = ROW_GAP,
        align = "center",
        radius = ROW_RADIUS,
        fill = fill,
        paddingH = ROW_PAD_H,
        onClick = function() activate(item, index) end,
        onHover = function(state)
            if state == "true" then
                if hoverIndex ~= index then
                    hoverIndex = index
                    render()
                end
            elseif hoverIndex == index then
                hoverIndex = nil
                render()
            end
        end,
    }, row)
end

-- the little app-identity strip shown above the synthetic surfaces
local function identityHeader()
    local name = appName() or "Application"
    local row = {}
    local iconPath = appIcon(20)
    if iconPath ~= nil then
        row[#row + 1] = ui.image({ path = iconPath, width = 20, height = 20,
                                   radius = 5, fit = "contain" })
    else
        row[#row + 1] = ui.glyph({ name = "app-window", size = 16,
                                   color = "primary" })
    end
    row[#row + 1] = ui.label({ text = name, fontWeight = "bold",
                               color = "on_surface", maxLines = 1 })
    local title = data ~= nil and data.title or nil
    if title ~= nil and title ~= "" and title ~= name then
        row[#row + 1] = ui.box({ flexGrow = 1 })
        row[#row + 1] = ui.label({ text = title, color = "on_surface/0.45",
                                   fontSize = 11, maxLines = 1,
                                   maxWidth = 150 })
    end
    return ui.row({
        key = "identity",
        height = 36,
        gap = 8,
        align = "center",
        radius = ROW_RADIUS,
        fill = "on_surface/0.04",
        paddingH = 10,
    }, row)
end

local function infoRow(keyText, valueText)
    return ui.row({
        key = "info-" .. keyText,
        height = 30,
        gap = 10,
        align = "center",
        radius = ROW_RADIUS,
        fill = "on_surface/0.04",
        paddingH = ROW_PAD_H,
    }, {
        ui.label({ text = keyText, color = "on_surface/0.5", fontSize = 12 }),
        ui.box({ flexGrow = 1 }),
        ui.label({ text = valueText, color = "on_surface", fontSize = 12,
                   maxLines = 1, maxWidth = 190 }),
    })
end

local function windowStateText()
    local win = windowState()
    if win.fullscreen == true then return "Fullscreen" end
    if win.maximized == true then return "Maximized" end
    if win.minimized == true then return "Minimized" end
    return "Normal"
end

local function sourceText()
    local source = data ~= nil and data.source or nil
    if source == "dbusmenu" then return "Application menu (D-Bus)" end
    if source == "gtk" then return "GTK menu bar" end
    if source == "shortcut" then return "Shortcut mapping" end
    if source == "fallback" then return "Built-in fallback" end
    return "None"
end

-- the App Info view reached from the application menu's About row
local function renderAbout()
    local name = appName() or "Application"

    local column = {}
    table.insert(column, ui.row({
        key = "about-back",
        height = ROW_HEIGHT,
        gap = 8,
        align = "center",
        radius = ROW_RADIUS,
        fill = "primary/0.10",
        paddingH = ROW_PAD_H,
        onClick = function()
            noctalia.state.set("openMenu", "__app__")
            syncFromState()
            render()
        end,
    }, {
        ui.glyph({ name = "chevron-left", size = 14, color = "primary" }),
        ui.label({ text = "About", fontWeight = "semibold",
                   color = "primary", maxLines = 1 }),
        ui.box({ flexGrow = 1 }),
        ui.label({ text = "Back", color = "on_surface/0.45", fontSize = 11 }),
    }))
    table.insert(column, ui.separator({ thickness = 1, spacing = 5,
                                        color = "on_surface/0.12" }))

    local body = {}
    local iconPath = appIcon(56)
    if iconPath ~= nil then
        body[#body + 1] = ui.image({ path = iconPath, width = 56, height = 56,
                                     radius = 12, fit = "contain" })
    else
        body[#body + 1] = ui.glyph({ name = "app-window", size = 40,
                                     color = "primary" })
    end
    body[#body + 1] = ui.label({ text = name, fontWeight = "bold",
                                 color = "on_surface", fontSize = 15,
                                 maxLines = 1 })
    local title = data ~= nil and data.title or nil
    if title ~= nil and title ~= "" and title ~= name then
        body[#body + 1] = ui.label({ text = title, color = "on_surface/0.5",
                                     fontSize = 12, maxLines = 1,
                                     maxWidth = 260 })
    end
    table.insert(column, ui.column({ key = "about-id", gap = 6,
                                     align = "center", padding = 8 }, body))

    table.insert(column, ui.separator({ thickness = 1, spacing = 5,
                                        color = "on_surface/0.12" }))

    local rows = {}
    local appId = data ~= nil and tostring(data.app or "") or ""
    rows[#rows + 1] = infoRow("App ID", appId ~= "" and appId or "-")
    rows[#rows + 1] = infoRow("Menus from", sourceText())
    rows[#rows + 1] = infoRow("Window state", windowStateText())
    rows[#rows + 1] = infoRow("Window control",
            features().toplevels == true and "Available" or "Unavailable")
    table.insert(column, ui.scroll({ flexGrow = 1, width = "fill",
                                     gap = LIST_GAP }, rows))

    panel.render(ui.column({ padding = 8, gap = 4 }, column))
end

-- global so early helpers (activate) and event closures all see one render
function render()
    if mode == MODE_ABOUT then
        renderAbout()
        return
    end

    local items = currentItems()
    if items == nil or #items == 0 or
            (mode == MODE_MENU and (data == nil or data.source == nil or
                    data.source == "none")) then
        local body = {
            ui.glyph({ name = "menu-2", size = 20, color = "on_surface/0.5" }),
        }
        local name = appName()
        if name ~= nil then
            table.insert(body, ui.label({
                text = name,
                fontWeight = "bold",
                color = "on_surface",
                fontSize = 14,
                maxLines = 1,
            }))
        end
        table.insert(body, ui.label({
            text = "No menu for this window",
            color = "on_surface/0.6",
            fontSize = 13,
        }))
        panel.render(ui.column({ padding = 20, gap = 10, align = "center" },
                               body))
        return
    end

    local column = {}

    -- identity strip above the synthetic surfaces
    if mode ~= MODE_MENU and (nav == nil or #nav == 0) then
        table.insert(column, identityHeader())
        table.insert(column, ui.separator({ thickness = 1, spacing = 5,
                                            color = "on_surface/0.12" }))
    end

    -- breadcrumb / back row when inside a submenu
    if nav ~= nil and #nav > 0 then
        local label = depthLabels[#depthLabels] or ""
        local parentLabel = #depthLabels > 1 and depthLabels[#depthLabels - 1]
                or ""
        table.insert(column, ui.row({
            key = "back-row",
            height = ROW_HEIGHT,
            gap = 8,
            align = "center",
            radius = ROW_RADIUS,
            fill = "primary/0.10",
            paddingH = ROW_PAD_H,
            onClick = function()
                table.remove(nav)
                table.remove(depthLabels)
                selIndex = 1
                render()
            end,
        }, {
            ui.glyph({ name = "chevron-left", size = 14, color = "primary" }),
            ui.label({ text = label, fontWeight = "semibold",
                       color = "primary", maxLines = 1 }),
            ui.box({ flexGrow = 1 }),
            ui.label({ text = parentLabel ~= "" and parentLabel or "Back",
                       color = "on_surface/0.45", fontSize = 11 }),
        }))
        table.insert(column, ui.separator({ thickness = 1, spacing = 5,
                                            color = "on_surface/0.12" }))
    end

    local rows = {}
    local maxItems = 400
    for index, item in ipairs(items) do
        if index > maxItems then break end
        rows[#rows + 1] = renderRow(item, index, items)
    end

    table.insert(column, ui.scroll({ flexGrow = 1, width = "fill",
                                     gap = LIST_GAP }, rows))

    panel.render(ui.column({ padding = 8, gap = 4 }, column))
end

-- --------------------------------------------------------- keyboard input

local function itemsOrEmpty()
    local items = currentItems()
    return items or {}
end

function onKey(chord, pressed)
    if not pressed then return end
    if mode == MODE_ABOUT then
        -- the info view has no selectable rows; Left/Return would land on
        -- the real menu tree underneath, so swallow everything
        return
    end
    local items = itemsOrEmpty()
    if chord == "Down" then
        local next = selIndex + 1
        while next <= #items and items[next].separator == true do
            next = next + 1
        end
        if next <= #items then selIndex = next end
        render()
    elseif chord == "Up" then
        local prev = selIndex - 1
        while prev >= 1 and items[prev].separator == true do
            prev = prev - 1
        end
        if prev >= 1 then selIndex = prev end
        render()
    elseif chord == "Return" then
        activate(items[selIndex], selIndex)
    elseif chord == "Right" then
        local item = items[selIndex]
        if item ~= nil and hasRealChildren(item) and item.enabled ~= false then
            activate(item, selIndex)
        end
    elseif chord == "Left" then
        if nav ~= nil and #nav > 0 then
            table.remove(nav)
            table.remove(depthLabels)
            selIndex = 1
            render()
        end
    end
end

-- -------------------------------------------------------------- lifecycle

local function modeForLabel(label)
    if label == "__app__" then return MODE_APP end
    if label == "__about__" then return MODE_ABOUT end
    if label == "__overflow__" then return MODE_OVERFLOW end
    return MODE_MENU
end

-- assigns the forward-declared local above so early helpers see it
function syncFromState()
    data = noctalia.state.get("menu")
    local selection = noctalia.state.get("openMenu")
    local nextMode = modeForLabel(selection)
    if nextMode ~= mode then
        mode = nextMode
        nav = {}
        depthLabels = {}
        selIndex = 1
        hoverIndex = nil
    end
    if mode == MODE_APP then
        specialRoot = buildAppMenu()
        if nav == nil then nav = {}; depthLabels = {}; selIndex = 1 end
    elseif mode == MODE_OVERFLOW then
        specialRoot = buildOverflowMenu()
        if nav == nil then nav = {}; depthLabels = {}; selIndex = 1 end
    else
        specialRoot = nil
        if nav == nil then
            nav = {}
            depthLabels = {}
            selIndex = 1
        end
        if #nav <= 1 then
            -- at the top level the widget's selected menu is authoritative,
            -- so clicking another label in the bar swaps the popup there
            local index = topIndexForLabel(selection)
            if nav[1] ~= index then
                nav = { index }
                depthLabels = {}
                selIndex = 1
                hoverIndex = nil
            end
        end
    end
    -- clamp selection
    local items = currentItems()
    if items ~= nil and selIndex > #items then
        selIndex = math.max(1, #items)
    end
end

function onOpen(_context)
    noctalia.state.set("panelOpen", true)
    nav = nil
    depthLabels = {}
    selIndex = 1
    hoverIndex = nil
    syncFromState()
    render()
end

function onClose()
    noctalia.state.set("panelOpen", false)
    nav = nil
    depthLabels = {}
    hoverIndex = nil
    data = nil
end

noctalia.state.watch("menu", function(_value)
    if data == nil then return end
    syncFromState()
    render()
end)

noctalia.state.watch("openMenu", function(_value)
    if data == nil then return end
    local inSubmenu = nav ~= nil and #nav >= 2
    syncFromState()
    if mode == MODE_MENU and inSubmenu then
        -- an explicit menu switch from the bar resets navigation
        nav = { topIndexForLabel(noctalia.state.get("openMenu")) }
        depthLabels = {}
        selIndex = 1
        hoverIndex = nil
    end
    render()
end)

noctalia.state.watch("window", function(_value)
    -- window state drives the app menu's checkmarks and enabled rows
    if mode == MODE_APP or mode == MODE_ABOUT then
        syncFromState()
        render()
    end
end)
