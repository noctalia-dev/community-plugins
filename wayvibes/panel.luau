--!nonstrict
-- WayVibes — panel entry point.
-- Browse soundpack libraries, control playback volume, and configure keyboard input devices.

local activeTab = "packs"
local searchFilter = ""
-- Watches only deliver future changes; the service may already be initialized.
local currentVolume = tonumber(noctalia.state.get("wayvibes_volume")) or 3
local activePack = tostring(noctalia.state.get("wayvibes_pack") or "")
local isPlaying = noctalia.state.get("wayvibes_playing") == true
local currentDevice = tostring(noctalia.state.get("wayvibes_device") or "")
local packs = noctalia.state.get("wayvibes_packs") or {}
local devices = noctalia.state.get("wayvibes_devices") or {}

local render

local function sendCmd(payload)
    noctalia.state.set("wayvibes_cmd", payload)
end

local function triggerPlay(pack)
    activePack = pack.name
    sendCmd({
        action = "play",
        packName = pack.name,
        packPath = pack.path,
        volume = currentVolume,
    })
    render()
end

local function triggerStop()
    activePack = ""
    sendCmd({ action = "stop" })
    render()
end

local function triggerRandom()
    local candidates = {}
    for _, item in ipairs(packs) do
        if searchFilter == "" or item.name:lower():find(searchFilter:lower(), 1, true) then
            table.insert(candidates, item)
        end
    end
    if #candidates > 0 then
        local chosen = candidates[math.random(1, #candidates)]
        triggerPlay(chosen)
    end
end

-- Soundpacks Tab View
local function buildPacksTab()
    local children = {}

    -- Search, Random, Turn Off Bar
    table.insert(children, ui.row({ gap = 8, align = "center" }, {
        ui.input({
            key = "pack_search",
            placeholder = noctalia.tr("search_placeholder"),
            text = searchFilter,
            flexGrow = 1,
            onChange = function(val)
                searchFilter = val or ""
                render()
            end,
        }),
        ui.button({
            key = "btn_random",
            glyph = "shuffle",
            tooltip = noctalia.tr("btn_random"),
            variant = "outline",
            onClick = triggerRandom,
        }),
        ui.button({
            key = "btn_off",
            glyph = "power",
            tooltip = noctalia.tr("btn_turn_off"),
            variant = isPlaying and "error" or "ghost",
            onClick = triggerStop,
        }),
        ui.button({
            key = "btn_rescan",
            glyph = "refresh",
            tooltip = noctalia.tr("refresh"),
            variant = "ghost",
            onClick = function()
                sendCmd({ action = "scan" })
            end,
        }),
    }))

    -- Volume Slider Row
    table.insert(children, ui.row({ gap = 12, align = "center", padding = 4 }, {
        ui.glyph({ name = "volume-2", size = 18, color = "on_surface_variant" }),
        ui.slider({
            key = "volume_slider",
            min = 1,
            max = 10,
            step = 1,
            value = currentVolume,
            flexGrow = 1,
            controlSize = "sm",
            onChange = function(val)
                currentVolume = tonumber(val) or 3
                sendCmd({ action = "volume", volume = currentVolume })
                render()
            end,
        }),
        ui.label({ text = tostring(currentVolume), fontSize = 12, color = "primary", width = 24, textAlign = "end" }),
    }))

    table.insert(children, ui.separator({ thickness = 1 }))

    -- Soundpacks Grid / List
    if #packs == 0 then
        table.insert(children, ui.column({
            gap = 8,
            padding = 24,
            radius = 12,
            fill = "surface_container",
            align = "center",
        }, {
            ui.glyph({ name = "folder-open", size = 32, color = "primary" }),
            ui.label({ text = noctalia.tr("no_packs_title"), fontWeight = "bold", fontSize = 15 }),
            ui.label({
                text = noctalia.tr("no_packs_desc"),
                color = "on_surface_variant",
                fontSize = 12,
                textAlign = "center",
            }),
        }))
    else
        local cards = {}
        for _, item in ipairs(packs) do
            if searchFilter == "" or item.name:lower():find(searchFilter:lower(), 1, true) then
                local isSelected = isPlaying and (activePack == item.name)
                table.insert(cards, ui.row({
                    key = "pack_" .. item.folder,
                    gap = 10,
                    align = "center",
                    padding = 8,
                    radius = 8,
                    fill = isSelected and "surface_container" or "surface",
                    border = isSelected and "primary" or "outline_variant/0.3",
                    borderWidth = 1,
                }, {
                    ui.glyph({
                        name = isSelected and "disc" or "circle",
                        color = isSelected and "primary" or "outline_variant",
                        size = 16,
                    }),
                    ui.label({
                        text = item.name,
                        fontWeight = isSelected and "bold" or "normal",
                        color = isSelected and "primary" or "on_surface",
                        flexGrow = 1,
                    }),
                    ui.button({
                        key = "play_" .. item.folder,
                        glyph = isSelected and "check" or "play",
                        variant = isSelected and "primary" or "ghost",
                        controlSize = "sm",
                        onClick = function()
                            triggerPlay(item)
                        end,
                    }),
                }))
            end
        end

        table.insert(children, ui.scroll({ key = "pack_scroll", flexGrow = 1, gap = 6 }, cards))
    end

    return children
end

-- Devices Tab View
local function buildDevicesTab()
    local children = {}

    -- Active Device Banner
    local hasDevice = currentDevice ~= ""
    table.insert(children, ui.column({
        gap = 6,
        padding = 12,
        radius = 8,
        fill = "surface_container",
    }, {
        ui.label({ text = noctalia.tr("current_device"), fontSize = 11, color = "on_surface_variant" }),
        ui.label({
            text = hasDevice and currentDevice or noctalia.tr("no_device_warning"),
            fontSize = 13,
            fontWeight = "bold",
            color = hasDevice and "primary" or "error",
        }),
    }))

    table.insert(children, ui.row({ justify = "space_between", align = "center" }, {
        ui.label({ text = "Detected Keyboards", fontSize = 14, fontWeight = "bold" }),
        ui.button({
            key = "btn_rescan_devs",
            glyph = "refresh",
            variant = "ghost",
            tooltip = noctalia.tr("refresh"),
            onClick = function()
                sendCmd({ action = "scan" })
            end,
        }),
    }))

    local devRows = {}
    for index, dev in ipairs(devices) do
        local isCurrent = (currentDevice ~= "" and (
            dev.path == currentDevice
            or dev.name == currentDevice
            or currentDevice == "NAME:" .. dev.name
            or currentDevice == "PATH:" .. dev.path
        ))
        table.insert(devRows, ui.row({
            key = "dev_" .. tostring(index),
            gap = 10,
            align = "center",
            padding = 10,
            radius = 8,
            fill = isCurrent and "surface_container" or "surface",
            border = isCurrent and "primary" or "outline_variant/0.3",
            borderWidth = 1,
        }, {
            ui.glyph({
                name = "keyboard",
                color = isCurrent and "primary" or "on_surface_variant",
                size = 18,
            }),
            ui.column({ flexGrow = 1, gap = 2 }, {
                ui.label({ text = dev.name, fontWeight = "bold", fontSize = 13 }),
                ui.label({ text = dev.path, color = "on_surface_variant", fontSize = 11 }),
            }),
            ui.button({
                key = "sel_" .. tostring(index),
                text = isCurrent and noctalia.tr("active") or noctalia.tr("select_device"),
                variant = isCurrent and "primary" or "outline",
                controlSize = "sm",
                onClick = function()
                    sendCmd({ action = "select_device", devicePath = dev.path, deviceName = dev.name })
                end,
            }),
        }))
    end

    table.insert(children, ui.scroll({ key = "dev_scroll", flexGrow = 1, gap = 6 }, devRows))
    return children
end

render = function()
    local tabs = {
        { id = "packs", glyph = "music", label = noctalia.tr("tab_packs"), build = buildPacksTab },
        { id = "devices", glyph = "keyboard", label = noctalia.tr("tab_devices"), build = buildDevicesTab },
    }

    local tabButtons = {}
    for _, t in ipairs(tabs) do
        table.insert(tabButtons, ui.button({
            key = "tab_" .. t.id,
            text = t.label,
            glyph = t.glyph,
            variant = (activeTab == t.id) and "primary" or "ghost",
            flexGrow = 1,
            onClick = function()
                activeTab = t.id
                render()
            end,
        }))
    end

    local tabContent
    for _, t in ipairs(tabs) do
        if t.id == activeTab then
            tabContent = t.build()
            break
        end
    end

    local children = {
        ui.row({ gap = 8, align = "center" }, {
            ui.glyph({ name = "keyboard", size = 20, color = "primary" }),
            ui.label({ text = noctalia.tr("title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
            ui.button({
                key = "btn_settings",
                glyph = "settings",
                variant = "ghost",
                onClick = function()
                    noctalia.openSettings()
                end,
            }),
            ui.button({
                key = "btn_close",
                glyph = "close",
                variant = "ghost",
                onClick = function()
                    panel.close()
                end,
            }),
        }),
        ui.row({ gap = 6 }, tabButtons),
        ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, tabContent),
    }

    panel.render(ui.column({ flexGrow = 1, gap = 12, padding = 16, align = "stretch" }, children))
end

noctalia.state.watch("wayvibes_playing", function(val)
    isPlaying = (val == true)
    render()
end)

noctalia.state.watch("wayvibes_pack", function(val)
    activePack = tostring(val or "")
    render()
end)

noctalia.state.watch("wayvibes_volume", function(val)
    if val then
        currentVolume = tonumber(val) or currentVolume
        render()
    end
end)

noctalia.state.watch("wayvibes_device", function(val)
    currentDevice = tostring(val or "")
    render()
end)

noctalia.state.watch("wayvibes_packs", function(val)
    if type(val) == "table" then
        packs = val
        render()
    end
end)

noctalia.state.watch("wayvibes_devices", function(val)
    if type(val) == "table" then
        devices = val
        render()
    end
end)

function onOpen()
    sendCmd({ action = "scan" })
    render()
end

function onClose()
end
