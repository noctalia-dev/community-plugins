--!nonstrict
-- widget.luau - the bar menu bar for amancode22/global-menu
--
-- Renders the focused application's name plus one label per top-level
-- menu, the way a native macOS menu bar behaves. Clicking the app name
-- opens the application menu (About / window controls / Quit); clicking
-- a label opens (or switches, or closes) the shared popup panel, which
-- reads the selection from the plugin state channel.

local PANEL_ID = "amancode22/global-menu:menu"

-- reserved openMenu labels the popup panel understands
local APP_MENU = "__app__"
local OVERFLOW_MENU = "__overflow__"

local data = nil        -- last published menu snapshot
local openMenu = nil    -- what the panel shows: a menu label or a reserved one

-- a close+reopen round in flight (re-anchoring the popup under a newly
-- clicked label); if the reopen gets lost, update() tries once more
local pendingReopenSince = nil
local REOPEN_GRACE_MS = 800
local TICK_MS = 250

-- bar fitting: a bar widget has no width to read, so the strip is
-- budgeted from the output's logical width and the pills are measured
-- with conservative per-character estimates. Labels that would overflow
-- move under a » button instead of being cut off by the bar edge.
local PILL_PAD_H = 7        -- matches the pill padding below
local PILL_GAP = 8          -- matches the row gap below
local CHAR_NARROW = 7.4     -- average px per Latin character
local CHAR_WIDE = 13.0      -- CJK / fullwidth codepoints
local lastOverflowKey = nil

-- ---------------------------------------------------------------- helpers

local function visibleMenus()
    if data == nil or data.tree == nil then return {} end
    local labels = {}
    for _, node in ipairs(data.tree) do
        if type(node) == "table" and node.separator ~= true and
                node.label ~= nil and node.label ~= "" then
            table.insert(labels, node.label)
        end
    end
    -- 0 (the default) shows every top-level menu; the width budget below
    -- decides what fits, so labels are only dropped when a cap is set on
    -- purpose
    local maxMenus = tonumber(noctalia.getConfig("max_menus")) or 0
    if maxMenus > 0 then
        while #labels > maxMenus do
            table.remove(labels)
        end
    end
    return labels
end

local function appName()
    if data == nil then return nil end
    if data.appName ~= nil and data.appName ~= "" then return data.appName end
    if data.app ~= nil and data.app ~= "" then return data.app end
    if data.title ~= nil and data.title ~= "" then return data.title end
    return nil
end

local function showAppName()
    if noctalia.getConfig("show_app_name") == false then return false end
    return appName() ~= nil
end

-- text width in logical px; utf8 codepoint aware (CJK reads wider), with
-- a plain byte-count fallback when utf8 is unavailable
local function textWidth(text, bold)
    local w = 0
    local counted = false
    if utf8 ~= nil and utf8.codes ~= nil then
        pcall(function()
            for _, code in utf8.codes(text or "") do
                if code >= 0x2E80 then
                    w = w + CHAR_WIDE
                else
                    w = w + CHAR_NARROW
                end
            end
            counted = true
        end)
    end
    if not counted then w = #(text or "") * CHAR_NARROW end
    if bold then w = w * 1.08 end
    return w
end

local function pillWidth(text, bold)
    return PILL_PAD_H * 2 + textWidth(text, bold)
end

-- the width the menu strip may occupy: an explicit bar_max_width wins;
-- otherwise half of this bar's output width in logical px, clamped
local function barBudget()
    if barWidget.isVertical() then return nil end
    local cfg = tonumber(noctalia.getConfig("bar_max_width")) or 0
    if cfg > 0 then return cfg end

    local logical = nil
    local outName = nil
    pcall(function() outName = barWidget.outputName() end)
    local outputs = nil
    pcall(function() outputs = noctalia.outputs() end)
    if type(outputs) == "table" then
        for _, output in ipairs(outputs) do
            if type(output) == "table" and output.width ~= nil and
                    (outName == nil or output.name == outName) then
                local scale = tonumber(output.scale) or 1
                if scale < 1 then scale = 1 end
                logical = (tonumber(output.width) or 0) / scale
                break
            end
        end
    end
    if logical == nil or logical <= 0 then return 640 end
    return math.clamp(logical * 0.5, 300, 1000)
end

-- split the menus into labels that fit and labels that overflow
local function layoutLabels()
    local menus = visibleMenus()
    local budget = barBudget()
    if budget == nil then return menus, {} end

    local used = 0
    if showAppName() and appName() ~= nil then
        used = pillWidth(appName(), true) + PILL_GAP
    end

    local visible = {}
    local overflow = {}
    for index, label in ipairs(menus) do
        local w = pillWidth(label, false) + PILL_GAP
        if #visible > 0 and used + w > budget then
            for tail = index, #menus do
                table.insert(overflow, menus[tail])
            end
            break
        end
        used = used + w
        table.insert(visible, label)
    end
    return visible, overflow
end

-- point the popup at a menu and make sure it is open. When it is already
-- open we close it and reopen right away, so the shell re-anchors it under
-- the freshly clicked label instead of leaving it where it was standing
local function showMenu(label)
    if pendingReopenSince ~= nil then
        -- a reopen is still in flight; it will land showing this menu
        openMenu = label
        noctalia.state.set("openMenu", label)
        return
    end
    local panelOpen = noctalia.state.get("panelOpen") == true
    openMenu = label
    noctalia.state.set("openMenu", label)
    if not panelOpen then
        noctalia.togglePanel(PANEL_ID)
        return
    end
    pendingReopenSince = noctalia.nowMs()
    noctalia.togglePanel(PANEL_ID)     -- close it where it stands...
    noctalia.togglePanel(PANEL_ID)     -- ...and reopen anchored at this click
end

-- clicking a label: open the panel, switch its menu, or close it again
local function onMenuClick(label)
    local panelOpen = noctalia.state.get("panelOpen") == true
    if panelOpen and openMenu == label then
        noctalia.togglePanel(PANEL_ID)          -- closes the popup
        return
    end
    showMenu(label)
end

-- clicking the app name behaves like macOS: it opens the application's
-- own menu (About, Minimize, Maximize, Resize, Quit), or closes the popup
-- when that menu is already showing
local function openOrToggle()
    local panelOpen = noctalia.state.get("panelOpen") == true
    if panelOpen and openMenu == APP_MENU then
        noctalia.togglePanel(PANEL_ID)          -- closes the popup
        return
    end
    showMenu(APP_MENU)
end

function onClick()
    openOrToggle()
end

-- ----------------------------------------------------------------- render

local function render()
    local name = appName()
    if data == nil or (name == nil and #visibleMenus() == 0) then
        barWidget.setVisible(false)
        return
    end

    local container = barWidget.isVertical() and ui.column or ui.row
    local panelOpen = noctalia.state.get("panelOpen") == true
    local visible, overflow = layoutLabels()
    local children = {}

    if showAppName() then
        local tooltip = data.title
        if tooltip == nil or tooltip == "" then tooltip = name end
        -- macOS style: the app name lights up while its own menu (or the
        -- About view reached from it) is open
        local appActive = panelOpen and
                (openMenu == APP_MENU or openMenu == "__about__")
        table.insert(children, ui.row({
            key = "app-name",
            gap = 0,
            align = "center",
            paddingH = PILL_PAD_H,
            radius = 6,
            fill = appActive and "primary/0.16" or nil,
            onClick = function() openOrToggle() end,
            tooltip = tooltip,
        }, {
            ui.label({
                text = name,
                fontWeight = "bold",
                color = "primary",
            }),
        }))
    end

    for index, label in ipairs(visible) do
        -- the menu whose popup is open gets its own lit pill, so the bar
        -- always shows which dropdown belongs to which label
        local active = panelOpen and openMenu == label
        table.insert(children, ui.row({
            key = "menu-" .. tostring(index) .. "-" .. label,
            gap = 0,
            align = "center",
            paddingH = PILL_PAD_H,
            radius = 6,
            fill = active and "primary/0.16" or nil,
            onClick = function() onMenuClick(label) end,
            tooltip = label,
        }, {
            ui.label({ text = label,
                       color = active and "primary" or nil }),
        }))
    end

    if #overflow > 0 then
        -- everything that did not fit stays reachable under »
        local moreActive = panelOpen and openMenu == OVERFLOW_MENU
        table.insert(children, ui.row({
            key = "menu-more",
            gap = 0,
            align = "center",
            paddingH = PILL_PAD_H,
            radius = 6,
            fill = moreActive and "primary/0.16" or nil,
            onClick = function() onMenuClick(OVERFLOW_MENU) end,
            tooltip = "More menus",
        }, {
            ui.glyph({
                name = "chevrons-right", size = 14,
                color = moreActive and "primary" or "on_surface/0.6",
            }),
        }))
    end

    -- publish the overflowed labels for the panel's » surface
    local overflowKey = table.concat(overflow, "\n")
    if overflowKey ~= lastOverflowKey then
        lastOverflowKey = overflowKey
        noctalia.state.set("overflow", #overflow > 0 and overflow or nil)
    end

    barWidget.setVisible(true)
    barWidget.render(container({ gap = PILL_GAP, align = "center" }, children))
end

-- ------------------------------------------------------------- wiring

noctalia.state.watch("menu", function(value)
    data = value
    if data ~= nil then
        -- a fresh application may not contain the remembered selection;
        -- follow macOS and land on the application menu instead
        if openMenu ~= APP_MENU then
            local known = false
            for _, label in ipairs(visibleMenus()) do
                if label == openMenu then
                    known = true
                    break
                end
            end
            if not known then
                openMenu = APP_MENU
                noctalia.state.set("openMenu", APP_MENU)
            end
        end
    end
    render()
end)

noctalia.state.watch("openMenu", function(value)
    if value ~= nil then openMenu = value end
    -- re-render so the lit pill follows what the popup now shows
    render()
end)

-- opening/closing the popup lights or dims the active label's pill; the
-- open event also settles a close+reopen round
noctalia.state.watch("panelOpen", function(value)
    if value == true then
        pendingReopenSince = nil
    end
    render()
end)

-- self-healing for the close+reopen round: if the reopen request was lost
-- the popup would stay closed, so try exactly once more after a grace period
function update()
    if pendingReopenSince == nil then return end
    if noctalia.state.get("panelOpen") == true then
        pendingReopenSince = nil
        return
    end
    if noctalia.nowMs() - pendingReopenSince > REOPEN_GRACE_MS then
        pendingReopenSince = nil
        noctalia.togglePanel(PANEL_ID)
    end
end

noctalia.setUpdateInterval(TICK_MS)

render()
