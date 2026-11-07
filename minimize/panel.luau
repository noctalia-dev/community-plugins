--!nonstrict
-- Minimized-windows panel: list, restore one, restore all, minimize all.
local client = require("./client.luau")
local snapshot, message, selected = nil, "Loading windows…", 1
local opened, busy, pending = false, false, false
local render, refresh
-- appIconPath() is synchronous; spread new lookups across frames to stay
-- within Noctalia's per-callback CPU budget.
local icons, iconLookups, iconsPending = {}, 0, false
local PAGE = 6

local function operate(action, id)
    if busy then return end
    busy, pending, message = true, false, "Updating windows…"
    local args = {action}
    if id then table.insert(args, "--id"); table.insert(args, tostring(id)) end
    client.request(args, function(data, err)
        if not opened then return end
        busy = false
        if err then message = err
        else
            snapshot = data
            message = data.warning or data.result or data.message or ""
            if action == "restore" then panel.close(); return end
        end
        render()
    end)
    render()
end

local function askMinimizeAll()
    if noctalia.getConfig("confirm_minimize_all") == false then operate("minimize-all")
    else pending = true; render() end
end

refresh = function()
    if busy then return end
    busy = true
    client.request({"status"}, function(data, err)
        if not opened then return end
        busy = false
        if err then message = err; snapshot = nil
        else snapshot = data; message = data.message or "" end
        render()
    end)
end

local function iconFor(appId)
    if appId == nil or appId == "" then return nil end
    if icons[appId] == nil then
        if iconLookups >= 2 then iconsPending = true; return nil end
        iconLookups += 1
        icons[appId] = noctalia.appIconPath(appId, 32) or false
    end
    return icons[appId] or nil
end

local function row(i, item)
    local icon = iconFor(item.app_id)
    local isSelected = i == selected
    return ui.row({key = "w" .. tostring(item.id), gap = 12, padding = 10, radius = 10, align = "center",
        fill = isSelected and "primary/0.14" or "surface_container",
        border = isSelected and "primary/0.6" or "surface_container", borderWidth = 1,
        onClick = function() selected = i; render() end}, {
        icon and ui.image({path = icon, width = 28, height = 28})
            or ui.glyph({name = "app-window", size = 24, color = "primary"}),
        ui.column({gap = 3, flexGrow = 1}, {
            ui.label({text = item.title, fontWeight = "bold", maxLines = 1}),
            ui.label({text = (item.app_id ~= "" and item.app_id .. " · " or "") .. "returns to " .. tostring(item.origin),
                color = "on_surface_variant", fontSize = 12, maxLines = 1}),
        }),
        ui.button({text = "Restore", glyph = "arrow-up-right", variant = isSelected and "primary" or "default",
            enabled = not busy, onClick = function() operate("restore", item.id) end}),
    })
end

render = function()
    iconLookups, iconsPending = 0, false
    local enabled = client.enabled()
    local minimized = snapshot and snapshot.minimized or {}
    selected = math.max(1, math.min(selected, #minimized))
    local rows = {
        ui.row({gap = 12, align = "center"}, {
            ui.glyph({name = "window-minimize", size = 28, color = "primary"}),
            ui.column({gap = 3, flexGrow = 1}, {
                ui.label({text = "Noctalia Minimize", fontSize = 22, fontWeight = "bold"}),
                ui.label({text = "Niri workspace parking · apps keep running", color = "on_surface_variant"}),
            }),
            ui.button({glyph = "refresh", tooltip = "Refresh · Ctrl+R", enabled = not busy, onClick = function() refresh() end}),
            ui.button({glyph = "x", tooltip = "Close · Esc", onClick = function() panel.close() end}),
        }),
        ui.label({text = enabled and message or "Noctalia Minimize is disabled in plugin settings", color = "primary", maxLines = 3}),
    }
    if snapshot and enabled then
        local active = snapshot.focused
        table.insert(rows, ui.row({gap = 10}, {
            ui.button({text = "Minimize active", glyph = "window-minimize", variant = "primary",
                enabled = active ~= nil and not busy, onClick = function() operate("minimize", active.id) end}),
            ui.button({text = "Minimize all", glyph = "layout-bottombar-collapse",
                enabled = #snapshot.windows > 0 and not busy, onClick = askMinimizeAll}),
            ui.button({text = "Restore all", glyph = "layout-bottombar-expand",
                tooltip = "Restore every window · Ctrl+A",
                enabled = #minimized > 0 and not busy, onClick = function() operate("restore-all") end}),
        }))
        if active then
            table.insert(rows, ui.label({text = "Active: " .. active.title, color = "on_surface_variant", maxLines = 1}))
        end
        if pending then
            table.insert(rows, ui.column({gap = 10, padding = 14, fill = "surface_container", radius = 12}, {
                ui.glyph({name = "alert-circle", size = 26, color = "primary"}),
                ui.label({text = "Minimize all " .. tostring(#snapshot.windows) .. " application windows?", fontWeight = "bold"}),
                ui.label({text = "They stay running in a parking workspace and can be restored here.", maxLines = 2}),
                ui.row({gap = 10}, {
                    ui.button({text = "Cancel", onClick = function() pending = false; render() end}),
                    ui.button({text = "Minimize all", variant = "primary", onClick = function() operate("minimize-all") end}),
                }),
            }))
            panel.render(ui.column({gap = 12, padding = 8}, rows))
            return
        end
        table.insert(rows, ui.separator({}))
        table.insert(rows, ui.label({text = "Minimized · " .. tostring(#minimized), fontWeight = "bold"}))
        local list = {}
        local start = math.floor((selected - 1) / PAGE) * PAGE + 1
        for i = start, math.min(start + PAGE - 1, #minimized) do
            table.insert(list, row(i, minimized[i]))
        end
        if #list == 0 then
            table.insert(list, ui.column({gap = 6, padding = 24, align = "center"}, {
                ui.glyph({name = "checks", size = 30, color = "on_surface_variant"}),
                ui.label({text = "No minimized windows", color = "on_surface_variant"}),
                ui.label({text = "Super+M minimizes the active window", color = "on_surface_variant", fontSize = 12}),
            }))
        end
        table.insert(rows, ui.scroll({key = "list", gap = 8, flexGrow = 1}, list))
        if #minimized > PAGE then
            table.insert(rows, ui.row({gap = 8, align = "center"}, {
                ui.button({text = "Previous", enabled = start > 1, onClick = function() selected = math.max(1, start - PAGE); render() end}),
                ui.label({text = tostring(start) .. "–" .. tostring(math.min(start + PAGE - 1, #minimized)) .. " of " .. tostring(#minimized), flexGrow = 1, textAlign = "center"}),
                ui.button({text = "Next", enabled = start + PAGE <= #minimized, onClick = function() selected = math.min(#minimized, start + PAGE); render() end}),
            }))
        end
    end
    table.insert(rows, ui.label({text = "↑ ↓ select · Enter restore · Ctrl+A restore all · Ctrl+R refresh · Esc close",
        color = "on_surface_variant", fontSize = 12, maxLines = 2}))
    panel.render(ui.column({gap = 12, padding = 8, flexGrow = 1}, rows))
    if iconsPending then panel.setNeedsFrameTick(true) end
end

function onFrameTick(_deltaMs)
    if iconsPending and opened then render() else panel.setNeedsFrameTick(false) end
end

function onOpen()
    opened, busy, pending = true, false, false
    panel.setWantsSecondTicks(true)
    render()
    if client.enabled() then refresh() end
end

function onClose() opened = false end

local ticks = 0
function update()
    ticks += 1
    if ticks % 3 == 0 and not pending and client.enabled() then refresh() end
end

function onKey(chord, pressed)
    if not pressed or busy then return end
    local items = snapshot and snapshot.minimized or {}
    if chord == "up" then selected = math.max(1, selected - 1); render()
    elseif chord == "down" then selected = math.max(1, math.min(#items, selected + 1)); render()
    elseif chord == "Return" and not pending and items[selected] then operate("restore", items[selected].id)
    elseif chord == "ctrl+a" and #items > 0 and not pending then operate("restore-all")
    elseif chord == "ctrl+r" then refresh() end
end
