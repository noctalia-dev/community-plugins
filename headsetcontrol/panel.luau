--!nonstrict
-- Device details panel: one card per headset reported by the service, or an
-- explanation when headsetcontrol is missing, finds nothing, or failed.
-- Pure renderer of the service's "snapshot" state.

local STATE_KEY = "snapshot"
local REQUEST_KEY = "refresh_request"

local snapshot = noctalia.state.get(STATE_KEY)

local function tr(key, args)
    return noctalia.tr(key, args)
end

local function request()
    local prev = noctalia.state.get(REQUEST_KEY)
    local nonce = (type(prev) == "table" and tonumber(prev.nonce) or 0) + 1
    noctalia.state.set(REQUEST_KEY, { nonce = nonce })
end

-- Same mapping as the bar widget (entries share no Lua memory).
local function batteryGlyph(device)
    local battery = device.battery
    if battery ~= nil and battery.status == "charging" then
        return "battery-charging", "primary"
    end
    -- A "partial" device can still report a valid level; only the level matters here.
    if battery == nil or battery.level == nil
        or battery.status == "unavailable" or battery.status == "unknown" then
        return "battery-exclamation", "on_surface_variant"
    end
    local level = battery.level
    if level < 10 then
        return "battery-0", "error"
    elseif level < 30 then
        return "battery-1", "warning"
    elseif level < 55 then
        return "battery-2", "on_surface"
    elseif level < 80 then
        return "battery-3", "on_surface"
    end
    return "battery-4", "on_surface"
end

local function muted(text, key)
    return ui.label({ key = key, text = text, color = "on_surface_variant", maxLines = 4 })
end

local function batterySection(device)
    local battery = device.battery
    local glyph, color = batteryGlyph(device)
    local children = {
        ui.row({ gap = 10, align = "center" }, {
            ui.glyph({ name = glyph, size = 28, color = color }),
            ui.column({ gap = 2, flexGrow = 1 }, {
                ui.label({
                    text = battery.level ~= nil and tr("battery.level", { level = battery.level }) or tr("panel.battery"),
                    fontSize = 18,
                    fontWeight = "bold",
                    color = "on_surface",
                }),
                muted(tr(`battery.status.{battery.status}`)),
            }),
        }),
    }
    if battery.level ~= nil then
        table.insert(children, ui.progress({ progress = math.clamp(battery.level / 100, 0, 1) }))
    end
    return ui.column({ gap = 8 }, children)
end

local function deviceCard(device, index)
    local heading = { ui.label({ text = device.name, fontWeight = "bold", color = "on_surface", maxLines = 2 }) }
    local subtitle = device.product or device.vendor
    if subtitle ~= nil and subtitle ~= device.name then
        table.insert(heading, muted(subtitle))
    end
    table.insert(heading, muted(tr("panel.usb_id", { id = device.id })))
    local children = { ui.column({ gap = 2 }, heading) }
    if not device.ok then
        table.insert(children, ui.label({
            text = tr("panel.device_error", { error = device.error or "" }),
            color = "error",
            maxLines = 4,
        }))
    end
    if device.battery ~= nil then
        table.insert(children, batterySection(device))
    end
    if device.chatmix ~= nil then
        table.insert(children, ui.row({ justify = "space_between" }, {
            ui.label({ text = tr("panel.chatmix"), color = "on_surface" }),
            ui.label({ text = tostring(device.chatmix), color = "on_surface" }),
        }))
    end
    if #device.capabilities > 0 then
        table.insert(children, ui.column({ gap = 4 }, {
            ui.label({ text = tr("panel.features"), fontWeight = "medium", color = "on_surface_variant" }),
            ui.label({ text = table.concat(device.capabilities, ", "), color = "on_surface", maxLines = 6 }),
        }))
    end
    return ui.column({
        key = `device-{index}-{device.id}`,
        gap = 12,
        padding = 12,
        radius = 12,
        fill = "surface_variant/0.4",
    }, children)
end

local function stateView(state, detail)
    local hintKey = `state.{state}.hint`
    if state == "error" and (snapshot.devices == nil or #snapshot.devices == 0) then
        hintKey = "state.error.hint_no_data"
    end
    local children = {
        ui.label({ text = tr(`state.{state}.title`), fontWeight = "bold", color = state == "error" and "error" or "on_surface" }),
        muted(tr(hintKey)),
    }
    if detail ~= nil and detail ~= "" then
        table.insert(children, ui.label({ text = detail, color = "on_surface", maxLines = 4 }))
    end
    return ui.column({ key = `state-{state}`, gap = 6 }, children)
end

local function body()
    if snapshot == nil then
        return {}
    end
    local items = {}
    local state = snapshot.state
    if state == "missing_dependency" or state == "no_devices" or state == "error" then
        table.insert(items, stateView(state, state == "error" and snapshot.error or nil))
    end
    if state == "ok" or state == "error" then
        for index, device in ipairs(snapshot.devices or {}) do
            table.insert(items, deviceCard(device, index))
        end
    end
    return items
end

local function render()
    local footer = ""
    if snapshot ~= nil and snapshot.updatedAt ~= nil then
        footer = tr("panel.updated", { time = os.date("%H:%M:%S", snapshot.updatedAt) })
    end
    panel.render(ui.column({ flexGrow = 1, gap = 16 }, {
        ui.row({ align = "center", justify = "space_between", gap = 8 }, {
            ui.label({ text = tr("title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
            ui.button({ glyph = "refresh", variant = "ghost", tooltip = tr("panel.refresh"), onClick = request }),
            ui.button({ glyph = "close", variant = "ghost", tooltip = tr("panel.close"), onClick = function()
                panel.close()
            end }),
        }),
        ui.scroll({ flexGrow = 1, gap = 12 }, body()),
        muted(footer, "footer"),
    }))
end

noctalia.state.watch(STATE_KEY, function(value)
    if type(value) == "table" then
        snapshot = value
        render()
    end
end)

function onOpen(_ctx)
    snapshot = noctalia.state.get(STATE_KEY)
    render()
    request()
end
