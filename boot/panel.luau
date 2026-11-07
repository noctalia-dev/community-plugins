--!nonstrict
-- Operating-system switcher. Selecting an entry changes nothing; only the
-- explicit confirmation starts the authenticated one-time boot + restart.
local client = require("./client.luau")
local snapshot, message, selected = nil, "Reading boot entries…", 1
local opened, busy, pending, requested = false, false, nil, false
local render, refresh

local function visibleEntries()
    local all = snapshot and snapshot.entries or {}
    if noctalia.getConfig("show_all_generations") == true then return all end
    local result, newestNixos = {}, nil
    for _, entry in ipairs(all) do
        if entry.family == "nixos" and newestNixos == nil then newestNixos = entry.id end
        if entry.family ~= "nixos" or entry.default or entry.current or entry.next or entry.id == newestNixos then
            table.insert(result, entry)
        end
    end
    return result
end

local function selectEntry(entry)
    if busy or requested then return end
    pending = entry
    render()
end

local function confirm()
    if not pending or busy or requested then return end
    local identity = pending.id
    busy, requested, pending = true, true, nil
    message = "Waiting for administrator authentication…"
    render()
    client.request({"start", "--entry", identity, "--confirmed"}, function(_data, err)
        if not opened then return end
        busy = false
        if err then requested = false; message = err; render()
        else
            noctalia.notify("Noctalia Boot", "Complete the administrator prompt to restart. Cancel it to keep working.")
            panel.close()
        end
    end)
end

refresh = function()
    if busy then return end
    busy = true
    client.request({"status"}, function(data, err)
        if not opened then return end
        busy = false
        if err then message = err; snapshot = nil
        else
            snapshot = data
            requested = data.operation and data.operation.state == "authenticating" or false
            message = data.error or (data.operation and data.operation.message) or ""
            if message == "" then message = "Select an operating system for the next restart only." end
        end
        render()
    end)
end

local function glyphFor(entry)
    if entry.family == "windows" then return "brand-windows" end
    if entry.family == "nixos" then return "snowflake" end
    return "brand-debian"
end

local function entryRow(i, entry)
    local labels = {}
    if entry.current then table.insert(labels, "Running now") end
    if entry.default then table.insert(labels, "Normal default") end
    if entry.next then table.insert(labels, snapshot.oneshot_entry and "Next boot · one time" or "Next boot") end
    local isSelected = i == selected
    return ui.row({key = entry.id, gap = 12, padding = 12, radius = 10, align = "center",
        fill = isSelected and "primary/0.14" or "surface_container",
        border = isSelected and "primary/0.6" or "surface_container", borderWidth = 1,
        onClick = function() selected = i; render() end}, {
        ui.glyph({name = glyphFor(entry), size = 26, color = "primary"}),
        ui.column({gap = 4, flexGrow = 1}, {
            ui.label({text = entry.title, fontWeight = "bold", maxLines = 2}),
            ui.label({text = #labels > 0 and table.concat(labels, " · ") or "Available boot entry",
                color = "on_surface_variant", fontSize = 12, maxLines = 2}),
        }),
        ui.button({text = "Select", variant = isSelected and "primary" or "default",
            enabled = snapshot.supported and not busy and not requested, onClick = function() selectEntry(entry) end}),
    })
end

render = function()
    local enabled = client.enabled()
    local rows = {
        ui.row({gap = 12, align = "center"}, {
            ui.glyph({name = "device-desktop", size = 28, color = "primary"}),
            ui.column({gap = 3, flexGrow = 1}, {
                ui.label({text = "Noctalia Boot", fontSize = 22, fontWeight = "bold"}),
                ui.label({text = "One-time boot · your normal default is kept", color = "on_surface_variant", maxLines = 2}),
            }),
            ui.button({glyph = "refresh", tooltip = "Refresh · Ctrl+R", enabled = not busy, onClick = function() refresh() end}),
            ui.button({glyph = "x", tooltip = "Close · Esc", onClick = function() panel.close() end}),
        }),
        ui.label({text = enabled and message or "Operating-system switching is disabled in plugin settings", color = "primary", maxLines = 4}),
    }
    if pending then
        table.insert(rows, ui.column({gap = 14, padding = 18, fill = "surface_container", radius = 12}, {
            ui.glyph({name = "alert-triangle", size = 30, color = "primary"}),
            ui.label({text = "Your computer will restart into", color = "on_surface_variant"}),
            ui.row({gap = 10, align = "center"}, {
                ui.glyph({name = glyphFor(pending), size = 26, color = "primary"}),
                ui.label({text = pending.title, fontSize = 20, fontWeight = "bold", maxLines = 3, flexGrow = 1}),
            }),
            ui.label({text = "Save your work first. Administrator authentication follows. Only the next boot changes; later restarts use the normal default.", maxLines = 4}),
            ui.row({gap = 12}, {
                ui.button({text = "Cancel", onClick = function() pending = nil; render() end}),
                ui.button({text = "Restart now", glyph = "power", variant = "destructive", onClick = confirm}),
            }),
        }))
    elseif snapshot and enabled then
        table.insert(rows, ui.column({gap = 5, padding = 12, fill = "surface_container", radius = 10}, {
            ui.label({text = "Running: " .. tostring(snapshot.running_os or "Linux"), fontWeight = "bold", maxLines = 2}),
            ui.label({text = "Bootloader: " .. tostring(snapshot.bootloader or "Unknown"), color = "on_surface_variant", maxLines = 2}),
        }))
        if snapshot.supported == false then
            table.insert(rows, ui.column({gap = 8, padding = 14, radius = 10, border = "primary/0.5", borderWidth = 1}, {
                ui.glyph({name = "info-circle", size = 24, color = "primary"}),
                ui.label({text = "Switching is not available on this system", fontWeight = "bold"}),
                ui.label({text = tostring(snapshot.error or ""), maxLines = 6}),
            }))
        else
            local entries = visibleEntries()
            selected = math.max(1, math.min(selected, #entries))
            local list = {}
            for i, entry in ipairs(entries) do table.insert(list, entryRow(i, entry)) end
            table.insert(rows, ui.scroll({key = "entries", gap = 10, flexGrow = 1}, list))
            if not snapshot.windows_found then
                table.insert(rows, ui.label({text = "No Windows entry was found in the systemd-boot menu. See the README to add one.",
                    color = "on_surface_variant", fontSize = 12, maxLines = 3}))
            end
            if #entries < #(snapshot.entries or {}) then
                table.insert(rows, ui.label({text = tostring(#snapshot.entries - #entries) .. " older NixOS generations hidden (plugin settings)",
                    color = "on_surface_variant", fontSize = 12}))
            end
        end
    end
    table.insert(rows, ui.label({text = pending and "Ctrl+Enter confirms restart · Esc cancels"
        or "↑ ↓ select · Enter review · Ctrl+R refresh · Esc close", color = "on_surface_variant", fontSize = 12, maxLines = 2}))
    panel.render(ui.column({gap = 12, padding = 8, flexGrow = 1}, rows))
end

function onOpen()
    opened, busy, pending, requested = true, false, nil, false
    render()
    if client.enabled() then refresh() end
end

function onClose() opened = false; pending = nil end

function onKey(chord, pressed)
    if not pressed or busy then return end
    if chord == "ctrl+r" and not pending then refresh(); return end
    if pending then
        if chord == "ctrl+Return" then confirm() end
        return -- Plain Enter never confirms a restart.
    end
    local entries = visibleEntries()
    if chord == "up" then selected = math.max(1, selected - 1); render()
    elseif chord == "down" then selected = math.max(1, math.min(#entries, selected + 1)); render()
    elseif chord == "Return" and entries[selected] and snapshot.supported and not requested then selectEntry(entries[selected]) end
end
