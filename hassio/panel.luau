--!nonstrict

local haUrl = noctalia.getConfig("ha_url")
local haToken = noctalia.getConfig("ha_token")

local entityStates = {}
local status = "unconfigured"
local expandedEntityId = nil
local entitySlots = {}
local sliderDraft = {}
local sliderDirty = {}

local pendingToggle = {}
local pendingSince = {} -- entity_id -> os.clock() when toggle was requested

local PENDING_TIMEOUT_SECONDS = 8

local view = "list" -- "list" | "browser"
local allEntities = {}
local browserSlots = {}
local browserLoading = false
local searchText = ""
local monitoredEntities = {} -- current monitored list (owned here, saved to file)
local panelOpenCount = 0

local function tr(key, subst)
      return noctalia.tr("panel." .. key, subst)
end

local function getStatusText()
    if status == "connected" then
        return noctalia.tr("widget.status_connected")
    elseif status == "connecting" then
        return noctalia.tr("widget.status_connecting")
    elseif status == "disconnected" then
        return noctalia.tr("widget.status_disconnected")
    elseif status == "auth_failed" then
        return noctalia.tr("widget.status_auth_failed")
    else
        return noctalia.tr("widget.status_unconfigured")
    end
end

local function getCleanToken()
    if type(haToken) ~= "string" then return "" end
    return haToken:gsub("^%s+", ""):gsub("%s+$", "")
end

local function haPost(path, body)
    if not haUrl or haUrl == "" then return end
    local cleanToken = getCleanToken()
    if cleanToken == "" then return end
    local encodedBody = noctalia.json.encode(body)

    noctalia.http({
        url = haUrl .. path,
        method = "POST",
        headers = {
            "Authorization: Bearer " .. cleanToken,
            "Content-Type: application/json",
        },
        body = encodedBody,
    }, function(response: HttpResponse)end)
end

local function callService(domain, service, entityId)
    haPost("/api/services/" .. domain .. "/" .. service, { entity_id = entityId })
end

local MANAGED_ENTITIES_FILE = "managed_entities.json"

local function managedEntitiesPath()
    local dataDir, dirErr = noctalia.pluginDataDir()
    if not dataDir then
        noctalia.log("Cannot resolve plugin data dir: " .. (dirErr or "unknown"))
        return nil
    end
    return dataDir .. "/" .. MANAGED_ENTITIES_FILE
end

local function loadMonitoredEntities()
    local path = managedEntitiesPath()
    local data = path and noctalia.readFile(path)
    if data and data ~= "" then
        local parsed = noctalia.json.decode(data)
        if type(parsed) == "table" then
            monitoredEntities = parsed
            return
        end
    end
    monitoredEntities = {}
end

local function saveMonitoredEntities()
    local path = managedEntitiesPath()
    if not path then
        noctalia.notifyError(noctalia.tr("shortcut.title"), tr("save_failed_no_data_dir"))
        return
    end

    local encodedEntities = noctalia.json.encode(monitoredEntities)
    local ok, writeErr = noctalia.writeFile(path, encodedEntities)
    if not ok then
        noctalia.log("Failed to save managed entities: " .. (writeErr or "unknown"))
        noctalia.notifyError(noctalia.tr("shortcut.title"), tr("save_failed"))
        return
    end
    noctalia.state.set("entities_override", monitoredEntities)
    noctalia.state.set("command", "reload_entities")
end

local function isPinned(entityId)
    for _, eid in ipairs(monitoredEntities) do
        if eid == entityId then return true end
    end
    return false
end

local function toggleBrowserPin(entityId)
    if not entityId then return end
    local newList, found = {}, false
    for _, eid in ipairs(monitoredEntities) do
        if eid == entityId then found = true
        else table.insert(newList, eid) end
    end
    if not found then table.insert(newList, entityId) end
    monitoredEntities = newList
    saveMonitoredEntities()
    render()
end

local function fetchAllEntities()
    if browserLoading then return end
    local cleanToken = getCleanToken()
    if not haUrl or haUrl == "" or cleanToken == "" then
        allEntities = {}
        browserLoading = false
        render()
        return
    end

    browserLoading = true
    render()

    noctalia.http({
        url = haUrl .. "/api/states",
        headers = {
            "Authorization: Bearer " .. cleanToken,
        }
    }, function(response: HttpResponse)
        browserLoading = false
        if response and response.body and response.body ~= "" then
            local states = noctalia.json.decode(response.body)
            if type(states) == "table" then
                allEntities = {}
                for _, s in ipairs(states) do
                    local attrs = s.attributes or {}
                    table.insert(allEntities, {
                        entity_id    = s.entity_id,
                        friendly_name = attrs.friendly_name or s.entity_id,
                        domain       = s.entity_id:match("^([^.]+)"),
                    })
                end
                table.sort(allEntities, function(a, b) return a.entity_id < b.entity_id end)
            end
        end
        render()
    end)
end

local function initDraft(entityId)
    if sliderDraft[entityId] then return end
    local e = entityStates[entityId]
    local ct = e and e.color_temp or -1
    local ctKelvin
    if ct > 500 then ctKelvin = math.floor(ct + 0.5)
    elseif ct > 0 then ctKelvin = math.floor(1000000 / ct + 0.5)
    else ctKelvin = 4000 end
    sliderDraft[entityId] = {
        brightness = e and (e.brightness > 0 and e.brightness or 255) or 255,
        color_temp = ctKelvin,
        hue        = e and (e.hue or 0) or 0,
    }
end

local function markDirty(key)
    if not expandedEntityId then return end
    if not sliderDirty[expandedEntityId] then sliderDirty[expandedEntityId] = {} end
    sliderDirty[expandedEntityId][key] = true
end

local function clearPending(entityId)
    pendingToggle[entityId] = nil
    pendingSince[entityId] = nil
end

local function isPendingTimedOut(entityId, now)
    local startedAt = pendingSince[entityId]
    if not startedAt then return false end
    return (now or os.clock()) - startedAt >= PENDING_TIMEOUT_SECONDS
end

local function reconcilePending(now)
    local changed = false
    for entityId, expected in pairs(pendingToggle) do
        local real = entityStates[entityId]
        if not real or real.state == expected or isPendingTimedOut(entityId, now) then
            clearPending(entityId)
            changed = true
        end
    end
    return changed
end

-- _actN/_expN are per-slot callback targets referenced by index from the rendered rows below.
-- In list view they act on the entity in that row's slot; in browser view _actN toggles its pin.
local function actSlot(i)
    if view == "browser" then
        toggleBrowserPin(browserSlots[i])
        return
    end
    local eid = entitySlots[i]
    if not eid then return end
    local entity = entityStates[eid]
    if not entity then return end
    local d = entity.domain
    if d == "script" then callService("script", "turn_on", eid)
    elseif d == "automation" then callService("automation", "trigger", eid)
    else
        local newState = entity.state == "on" and "off" or "on"
        pendingToggle[eid] = newState
        pendingSince[eid] = os.clock()
        callService(d, "toggle", eid)
        render()
    end
end

local function expSlot(i)
    local eid = entitySlots[i]
    if not eid then return end
    if expandedEntityId == eid then
        expandedEntityId = nil
    else
        sliderDraft[eid] = nil
        sliderDirty[eid] = nil
        expandedEntityId = eid
    end
    render()
end

function _act1()  actSlot(1)  end;  function _exp1()  expSlot(1)  end
function _act2()  actSlot(2)  end;  function _exp2()  expSlot(2)  end
function _act3()  actSlot(3)  end;  function _exp3()  expSlot(3)  end
function _act4()  actSlot(4)  end;  function _exp4()  expSlot(4)  end
function _act5()  actSlot(5)  end;  function _exp5()  expSlot(5)  end
function _act6()  actSlot(6)  end;  function _exp6()  expSlot(6)  end
function _act7()  actSlot(7)  end;  function _exp7()  expSlot(7)  end
function _act8()  actSlot(8)  end;  function _exp8()  expSlot(8)  end
function _act9()  actSlot(9)  end;  function _exp9()  expSlot(9)  end
function _act10() actSlot(10) end;  function _exp10() expSlot(10) end
function _act11() actSlot(11) end;  function _exp11() expSlot(11) end
function _act12() actSlot(12) end;  function _exp12() expSlot(12) end
function _act13() actSlot(13) end;  function _exp13() expSlot(13) end
function _act14() actSlot(14) end;  function _exp14() expSlot(14) end
function _act15() actSlot(15) end;  function _exp15() expSlot(15) end
function _act16() actSlot(16) end;  function _exp16() expSlot(16) end
function _act17() actSlot(17) end;  function _exp17() expSlot(17) end
function _act18() actSlot(18) end;  function _exp18() expSlot(18) end
function _act19() actSlot(19) end;  function _exp19() expSlot(19) end
function _act20() actSlot(20) end;  function _exp20() expSlot(20) end
function _act21() actSlot(21) end;  function _exp21() expSlot(21) end
function _act22() actSlot(22) end;  function _exp22() expSlot(22) end
function _act23() actSlot(23) end;  function _exp23() expSlot(23) end
function _act24() actSlot(24) end;  function _exp24() expSlot(24) end
function _act25() actSlot(25) end;  function _exp25() expSlot(25) end
function _act26() actSlot(26) end;  function _exp26() expSlot(26) end
function _act27() actSlot(27) end;  function _exp27() expSlot(27) end
function _act28() actSlot(28) end;  function _exp28() expSlot(28) end
function _act29() actSlot(29) end;  function _exp29() expSlot(29) end
function _act30() actSlot(30) end;  function _exp30() expSlot(30) end

function onBrightness(value)
    if not expandedEntityId then return end
    initDraft(expandedEntityId)
    sliderDraft[expandedEntityId].brightness = math.floor((tonumber(value) or 255) + 0.5)
    markDirty("brightness")
    render()
end

function onColorTemp(value)
    if not expandedEntityId then return end
    initDraft(expandedEntityId)
    sliderDraft[expandedEntityId].color_temp = math.floor((tonumber(value) or 4000) + 0.5)
    markDirty("color_temp")
    render()
end

function onHue(value)
    if not expandedEntityId then return end
    initDraft(expandedEntityId)
    sliderDraft[expandedEntityId].hue = math.floor((tonumber(value) or 0) + 0.5)
    markDirty("hue")
    render()
end

function onApplyLight()
    if not expandedEntityId then return end
    local draft = sliderDraft[expandedEntityId]
    local dirty = sliderDirty[expandedEntityId] or {}
    local entity = entityStates[expandedEntityId]
    if not draft or not entity then return end

    local data = { entity_id = expandedEntityId }
    if dirty.hue and entity.supports_rgb then
        data.hs_color = { draft.hue, 100 }
        if dirty.brightness and entity.supports_brightness then
            data.brightness = draft.brightness
        end
    else
        if dirty.brightness and entity.supports_brightness then
            data.brightness = draft.brightness
        end
        if dirty.color_temp and entity.supports_color_temp then
            data.color_temp_kelvin = draft.color_temp
        end
    end

    if dirty.brightness or dirty.color_temp or dirty.hue then
        haPost("/api/services/light/turn_on", data)
        sliderDirty[expandedEntityId] = {}
    end
end

function onNoop() end

function onOpenBrowser()
    view = "browser"
    searchText = ""
    fetchAllEntities()
end

function onBackToList()
    view = "list"
    allEntities = {}
    searchText = ""
    render()
end

function onSearchChange(value)
    searchText = value or ""
    render()
end

local function isControllable(domain)
    return domain == "light" or domain == "switch" or domain == "input_boolean"
        or domain == "fan" or domain == "cover" or domain == "lock"
end

local function isSensor(domain)
    return domain == "sensor" or domain == "binary_sensor" or domain == "weather" or domain == "number"
end

local function isAutomation(domain)
    return domain == "automation" or domain == "script"
end

local function domainGlyph(domain)
    local g = {
        light = "bulb", switch = "toggle-right", input_boolean = "toggle-right",
        sensor = "chart-line", binary_sensor = "activity", climate = "temperature",
        cover = "door", fan = "wind", lock = "lock", media_player = "device-speaker",
        weather = "cloud", automation = "robot", script = "player-play",
    }
    return g[domain] or "smart-home"
end

local function stateGlyph(domain, isOn)
    if domain == "light" then return isOn and "bulb" or "bulb-off"
    elseif domain == "switch" or domain == "input_boolean" then return isOn and "toggle-right" or "toggle-left"
    elseif domain == "fan" then return isOn and "wind" or "wind-off"
    elseif domain == "lock" then return isOn and "lock" or "lock-open"
    elseif domain == "cover" then return isOn and "door-open" or "door"
    end
    return domainGlyph(domain)
end

local function entityStateLabel(entity)
    if isSensor(entity.domain) then
        return entity.state .. (entity.unit ~= "" and " " .. entity.unit or "")
    end
    if entity.domain == "light" and entity.state == "on" and entity.brightness >= 0 then
        local pct = math.floor(entity.brightness / 255 * 100 + 0.5)
        return tr("state_on_brightness", { percent = pct })
    end
    return entity.state
end

local function buildExpandedSection(entity)
    local eid = entity.entity_id
    initDraft(eid)
    local draft = sliderDraft[eid]
    local rows = {}

    if entity.supports_brightness then
        local bv = draft.brightness
        table.insert(rows, ui.row({ align = "center", gap = 8 }, {
            ui.label({ text = tr("brightness"), color = "on_surface_variant" }),
            ui.slider({ min = 1, max = 255, step = 1, value = bv, onChange = "onBrightness", flexGrow = 1 }),
            ui.label({ text = math.floor(bv / 255 * 100 + 0.5) .. "%" }),
        }))
    end

    if entity.supports_color_temp then
        local ctk = draft.color_temp
        table.insert(rows, ui.row({ align = "center", gap = 8 }, {
            ui.label({ text = tr("color_temp"), color = "on_surface_variant" }),
            ui.slider({ min = 2000, max = 6500, step = 50, value = ctk, onChange = "onColorTemp", flexGrow = 1 }),
            ui.label({ text = math.floor(ctk) .. "K" }),
        }))
    end

    if entity.supports_rgb then
        local hv = draft.hue
        table.insert(rows, ui.row({ align = "center", gap = 8 }, {
            ui.label({ text = tr("hue"), color = "on_surface_variant" }),
            ui.slider({ min = 0, max = 360, step = 1, value = hv, onChange = "onHue", flexGrow = 1 }),
            ui.label({ text = math.floor(hv) .. "°" }),
        }))
    end

    if #rows == 0 then return nil end

    table.insert(rows, ui.row({ justify = "end" }, {
        ui.button({ glyph = "check", onClick = "onApplyLight" }),
    }))

    return ui.column({ gap = 8 }, rows)
end

local function buildEntityCard(entity, i)
    local pending = pendingToggle[entity.entity_id]
    local isOn = (pending or entity.state) == "on"
    local domain = entity.domain
    local canExpand = domain == "light"
        and (entity.supports_brightness or entity.supports_color_temp or entity.supports_rgb)
    local isExpanded = expandedEntityId == entity.entity_id

    local expandBtn
    if canExpand then
        expandBtn = ui.button({
            glyph = isExpanded and "chevron-up" or "chevron-down",
            onClick = "_exp" .. i,
        })
    end

    local isPending = pending ~= nil
    local iconClick = isPending and "onNoop"
        or (isControllable(domain) or isAutomation(domain)) and "_act" .. i or "onNoop"
    local iconGlyph = isPending and "loader"
        or isAutomation(domain) and "player-play" or stateGlyph(domain, isOn)

    local rowChildren = {
        ui.button({ glyph = iconGlyph, onClick = iconClick }),
                ui.column({ flexGrow = 1, gap = 2 }, {
            ui.label({ text = entity.friendly_name or entity.entity_id, fontWeight = "medium" }),
            ui.label({ text = entityStateLabel(entity), color = "on_surface_variant", fontSize = 12 }),
        }),
    }
    if expandBtn then table.insert(rowChildren, expandBtn) end

    local cardChildren = { ui.row({ align = "center", gap = 8 }, rowChildren) }

    if isExpanded then
        local expanded = buildExpandedSection(entity)
        if expanded then table.insert(cardChildren, expanded) end
    end

    return ui.column({ gap = 8 }, cardChildren)
end

-- Capped to 30: matches the number of _actN/_expN slot callbacks defined above.
local MAX_SLOTS = 30

local function getOrderedIds()
    local ids, seen = {}, {}
    for _, eid in ipairs(monitoredEntities) do
        if entityStates[eid] then
            table.insert(ids, eid)
            seen[eid] = true
            if #ids >= MAX_SLOTS then return ids end
        end
    end
    for eid in pairs(entityStates) do
        if not seen[eid] then
            table.insert(ids, eid)
            if #ids >= MAX_SLOTS then return ids end
        end
    end
    return ids
end

local function buildListBody(ids)
    if not haUrl or haUrl == "" or getCleanToken() == "" then
        return ui.label({ text = tr("not_configured"), color = "on_surface_variant" })
    end
    if status == "auth_failed" then
        return ui.label({ text = tr("auth_failed"), color = "error" })
    end
    if status == "connecting" then
        return ui.label({ text = tr("connecting"), color = "on_surface_variant" })
    end
    if status == "disconnected" then
        return ui.label({ text = tr("disconnected_reconnecting"), color = "error" })
    end
    if #ids == 0 then
        return ui.label({
            text = status == "connected"
                and tr("no_entities_monitored")
                or tr("status_fallback", { status = status }),
            color = "on_surface_variant",
        })
    end
    local cards = {}
    for i, eid in ipairs(ids) do
        table.insert(cards, buildEntityCard(entityStates[eid], i))
    end
    return ui.scroll({ flexGrow = 1, gap = 8 }, cards)
end

local function buildBrowserBody()
    if browserLoading then
        return ui.label({ text = tr("loading_entities"), color = "on_surface_variant" })
    end
    if #allEntities == 0 then
        return ui.label({ text = tr("no_entities_found"), color = "on_surface_variant" })
    end

    local q = searchText:lower()
    local filtered = {}
    for _, e in ipairs(allEntities) do
        if q == ""
            or e.entity_id:lower():find(q, 1, true)
            or e.friendly_name:lower():find(q, 1, true)
        then
            table.insert(filtered, e)
            if #filtered >= 30 then break end
        end
    end

    if #filtered == 0 then
        return ui.label({ text = tr("no_entities_match"), color = "on_surface_variant" })
    end

    browserSlots = {}
    local rows = {}
    for i, e in ipairs(filtered) do
        browserSlots[i] = e.entity_id
        local pinned = isPinned(e.entity_id)
        table.insert(rows, ui.row({ align = "center", gap = 8 }, {
            ui.column({ flexGrow = 1, gap = 2 }, {
                ui.label({ text = e.friendly_name, fontWeight = "medium" }),
                ui.label({ text = e.entity_id, color = "on_surface_variant", fontSize = 12 }),
            }),
            ui.button({ glyph = pinned and "pin-filled" or "pin", onClick = "_act" .. i }),
        }))
    end

    return ui.scroll({ flexGrow = 1, gap = 4 }, rows)
end

function render()
    reconcilePending(os.clock())

    if view == "browser" then
        panel.render(ui.column({ flexGrow = 1, gap = 16 }, {
            ui.row({ align = "center", gap = 8 }, {
                ui.button({ glyph = "arrow-left", onClick = "onBackToList" }),
                ui.label({ text = tr("manage_entities_title"), fontSize = 16, fontWeight = "bold", color = "primary", flexGrow = 1 }),
                ui.button({ glyph = "close", onClick = "onCloseClicked" }),
            }),
            ui.input({ key = "entity_search", placeholder = tr("search_placeholder"), onChange = "onSearchChange" }),
            buildBrowserBody(),
        }))
    else
        local ids = getOrderedIds()
        entitySlots = {}
        for i, eid in ipairs(ids) do entitySlots[i] = eid end

        panel.render(ui.column({ flexGrow = 1, gap = 16 }, {
            ui.row({ align = "center", gap = 8 }, {
                ui.label({ text = noctalia.tr("shortcut.title"), fontSize = 16, fontWeight = "bold", color = "primary", flexGrow = 1 }),
                ui.label({ text = getStatusText(), color = status == "connected" and "primary" or "on_surface_variant" }),
                ui.button({ glyph = "list-search", onClick = "onOpenBrowser" }),
                ui.button({ glyph = "close", onClick = "onCloseClicked" }),
            }),
            buildListBody(ids),
        }))
    end
end

function onOpen(_context)
    status = noctalia.state.get("connection_status") or "unconfigured"
    entityStates = noctalia.state.get("entities") or {}
    loadMonitoredEntities()
    panelOpenCount = panelOpenCount + 1
    panel.setWantsSecondTicks(true)
    noctalia.state.set("panel_open_signal", panelOpenCount)
    render()
end

function onClose()
    panel.setWantsSecondTicks(false)
end

function update()
    if reconcilePending(os.clock()) then
        render()
    end
end

function onCloseClicked()
    panel.close()
end

noctalia.state.watch("entities", function(value)
    entityStates = value or {}
    reconcilePending(os.clock())
    render()
end)

noctalia.state.watch("connection_status", function(value)
    status = value or "unconfigured"
    render()
end)
