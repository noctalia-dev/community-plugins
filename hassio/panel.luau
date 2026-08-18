--!nonstrict

local haUrlRaw = noctalia.getConfig("ha_url")
local haToken = noctalia.getConfig("ha_token")

local entityStates = {}
local status = "unconfigured"
local expandedEntityId = nil
local sliderDraft = {}
local sliderDirty = {}

local pendingToggle = {}
local pendingSince = {} -- entity_id -> os.clock() when toggle was requested

local PENDING_TIMEOUT_SECONDS = 8

local view = "list" -- "list" | "browser"
local allEntities = {}
local browserLoading = false
local browserLoadingSince = nil
local browserFailed = false

local BROWSER_TIMEOUT_SECONDS = 20
local MAX_BROWSER_ROWS = 200
local searchText = ""
local monitoredEntities = {} -- current monitored list (owned here, saved to file)
local panelOpenCount = 0

local function getCleanUrl()
  if type(haUrlRaw) ~= "string" then return "" end
  return (haUrlRaw:gsub("/$", ""))
end

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
    elseif status == "unreachable" then
        return noctalia.tr("widget.status_unreachable")
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

local function haPost(path, body, onFailure)
    local url = getCleanUrl()
    local cleanToken = getCleanToken()
    if not url or url == "" or cleanToken == "" then
        if onFailure then onFailure() end
        return
    end
    local encodedBody = noctalia.json.encode(body)

    noctalia.http({
        url = url .. path,
        method = "POST",
        headers = {
            "Authorization: Bearer " .. cleanToken,
            "Content-Type: application/json",
        },
        body = encodedBody,
    }, function(response: HttpResponse)
        local httpStatus = response and response.status or 0
        if httpStatus >= 200 and httpStatus < 300 then return end
        noctalia.log("Home Assistant rejected " .. path .. ": status " .. tostring(httpStatus))
        if onFailure then onFailure() end
    end)
end

local function callService(domain, service, entityId, onFailure)
    haPost("/api/services/" .. domain .. "/" .. service, { entity_id = entityId }, onFailure)
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

-- /api/states is megabytes on a large instance and decoding it overruns the host's
-- per-callback CPU budget. The tab and newline outside the {{ }} are the record
-- separators; the ones inside replace() are escapes for Jinja to interpret.
local ENTITY_LIST_TEMPLATE =
    "{% for s in states %}{{ s.entity_id }}\t{{ s.name | replace('\\t',' ') | replace('\\n',' ') }}\n{% endfor %}"

-- Same shape minus the friendly names, for instances that reject the template above.
local ENTITY_ID_TEMPLATE =
    "{% for s in states %}{{ s.entity_id }}\n{% endfor %}"

local MAX_ENTITY_ID_LENGTH = 255
local MAX_FRIENDLY_NAME_LENGTH = 255
-- Comfortably past id + name, so a record is never cut short by it.
local MAX_RECORD_SCAN = 1024

-- Scans with plain string.find only. A Lua pattern such as "([^\t\n]+)\t" backtracks
-- through every separator-free byte and gmatch then restarts one byte later, so a
-- response that lost its tabs costs O(bytes^2) inside a single uninterruptible C call:
-- seconds of CPU, which the host kills for overrunning the callback budget.
local function parseEntityList(body)
    local list = {}
    local len = #body
    -- Without any newline the whole body is one record, so a space is not a separator.
    local splitOnSpace = string.find(body, "\n", 1, true) ~= nil
    local pos = 1
    while pos <= len do
        local eol = string.find(body, "\n", pos, true) or (len + 1)
        local lineEnd = eol - 1
        if string.sub(body, lineEnd, lineEnd) == "\r" then lineEnd -= 1 end

        -- Searching the body itself would re-scan to the far end on every separator-less
        -- line, which is the quadratic behaviour this parser exists to avoid.
        local record = string.sub(body, pos, math.min(lineEnd, pos + MAX_RECORD_SCAN - 1))
        local sep = string.find(record, "\t", 1, true)
        if not sep and splitOnSpace then sep = string.find(record, " ", 1, true) end

        local entityId = sep and string.sub(record, 1, sep - 1) or record
        local dot = string.find(entityId, ".", 1, true)
        if dot and dot > 1 and dot < #entityId and #entityId <= MAX_ENTITY_ID_LENGTH then
            local name = sep and string.sub(record, sep + 1) or ""
            if #name > MAX_FRIENDLY_NAME_LENGTH then name = string.sub(name, 1, MAX_FRIENDLY_NAME_LENGTH) end
            table.insert(list, {
                entity_id     = entityId,
                friendly_name = name ~= "" and name or entityId,
                domain        = string.sub(entityId, 1, dot - 1),
            })
        end
        pos = eol + 1
    end
    return list
end

-- HA iterates `states` in entity_id order, so this is normally just the linear check.
local function sortEntitiesIfNeeded(list)
    for i = 2, #list do
        if list[i].entity_id < list[i - 1].entity_id then
            table.sort(list, function(a, b) return a.entity_id < b.entity_id end)
            return
        end
    end
end

local function finishBrowserLoad(list, failed)
    allEntities = list
    browserLoading = false
    browserLoadingSince = nil
    browserFailed = failed == true
    render()
end

-- /api/states on a large instance decodes for longer than one callback is allowed to
-- run, so the conversion is resumable: whatever is left over is finished by update(),
-- which gets a fresh budget on every tick.
local pendingStates = nil
local pendingList = nil
local pendingCursor = 1
local STATES_PER_TICK = 1000

local function consumePendingStates()
    local states = pendingStates
    if states == nil then return end

    if type(states) ~= "table" then
        pendingStates = nil
        pendingList = nil
        noctalia.log("Could not list entities: /api/states was not decodable")
        finishBrowserLoad({}, true)
        return
    end

    local list = pendingList
    local total = #states
    local i = pendingCursor
    local last = math.min(i + STATES_PER_TICK - 1, total)
    while i <= last do
        local s = states[i]
        local entityId = type(s) == "table" and s.entity_id or nil
        if type(entityId) == "string" then
            local attrs = s.attributes
            local dot = string.find(entityId, ".", 1, true)
            table.insert(list, {
                entity_id     = entityId,
                friendly_name = (type(attrs) == "table" and attrs.friendly_name) or entityId,
                domain        = dot and string.sub(entityId, 1, dot - 1) or entityId,
            })
        end
        i += 1
        -- Kept in step with `list` so an aborted chunk resumes without duplicating.
        pendingCursor = i
    end

    if i > total then
        -- Cleared only once the sort is through, so an abort here retries next tick.
        sortEntitiesIfNeeded(list)
        pendingStates = nil
        pendingList = nil
        finishBrowserLoad(list)
    end
end

-- Continues an already-started load, so it deliberately doesn't re-check browserLoading.
local function fetchAllEntitiesFromStates()
    local cleanToken = getCleanToken()
    local url = getCleanUrl()

    noctalia.http({
        url = url .. "/api/states",
        headers = {
            "Authorization: Bearer " .. cleanToken,
        }
    }, function(response: HttpResponse)
        local httpStatus = response and response.status or 0
        local body = response and response.body or ""
        if httpStatus < 200 or httpStatus >= 300 or body == "" then
            noctalia.log("Could not list entities: /api/states returned " .. tostring(httpStatus))
            finishBrowserLoad({}, true)
            return
        end

        local states = noctalia.json.decode(body)
        -- Nothing but plain assignments may sit between the decode and here. The decode
        -- alone can outlast the budget, and the host only aborts at the next call or
        -- loop instruction, so these stores still commit and update() can take over.
        pendingStates = states
        pendingList = {}
        pendingCursor = 1
        consumePendingStates()
    end)
end

-- Continues an already-started load, so it deliberately doesn't re-check browserLoading.
local function fetchAllEntitiesFromTemplate(template, label, onUnusable)
    local cleanToken = getCleanToken()
    local url = getCleanUrl()

    noctalia.http({
        url = url .. "/api/template",
        method = "POST",
        headers = {
            "Authorization: Bearer " .. cleanToken,
            "Content-Type: application/json",
        },
        body = noctalia.json.encode({ template = template }),
    }, function(response: HttpResponse)
        local httpStatus = response and response.status or 0
        local body = response and response.body or ""

        if httpStatus < 200 or httpStatus >= 300 or body == "" then
            noctalia.log(label .. " template unavailable (status " .. tostring(httpStatus) .. ")")
            onUnusable()
            return
        end

        local list = parseEntityList(body)

        if #list == 0 then
            -- The preview is what tells us how a given instance actually answers.
            local preview = string.gsub(string.sub(body, 1, 120), "%c", ".")
            noctalia.log(label .. " template returned nothing usable (" .. #body
                .. " bytes, starts with: " .. preview .. ")")
            onUnusable()
            return
        end

        sortEntitiesIfNeeded(list)
        finishBrowserLoad(list)
    end)
end

local function fetchAllEntities()
    if browserLoading then return end
    pendingStates = nil
    pendingList = nil
    local cleanToken = getCleanToken()
    local url = getCleanUrl()
    if not url or url == "" or cleanToken == "" then
        allEntities = {}
        browserLoading = false
        browserLoadingSince = nil
        render()
        return
    end

    browserLoading = true
    browserLoadingSince = os.clock()
    browserFailed = false
    render()

    -- Cheapest source first. The id-only template needs no filters and no `name`
    -- attribute, so it still answers on instances where the full one doesn't, and
    -- /api/states is only reached when neither template works.
    fetchAllEntitiesFromTemplate(ENTITY_LIST_TEMPLATE, "Entity list", function()
        fetchAllEntitiesFromTemplate(ENTITY_ID_TEMPLATE, "Entity id", fetchAllEntitiesFromStates)
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

local function actEntity(eid)
    local entity = entityStates[eid]
    if not entity then return end
    local d = entity.domain
    if d == "script" then callService("script", "turn_on", eid)
    elseif d == "automation" then callService("automation", "trigger", eid)
    else
        local newState = entity.state == "on" and "off" or "on"
        pendingToggle[eid] = newState
        pendingSince[eid] = os.clock()
        callService(d, "toggle", eid, function()
            clearPending(eid)
            render()
        end)
        render()
    end
end

local function expandEntity(eid)
    if expandedEntityId == eid then
        expandedEntityId = nil
    else
        sliderDraft[eid] = nil
        sliderDirty[eid] = nil
        expandedEntityId = eid
    end
    render()
end

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
    browserFailed = false
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

local function buildEntityCard(entity)
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
            onClick = function() expandEntity(entity.entity_id) end,
        })
    end

    local isPending = pending ~= nil
    local iconClick = isPending and "onNoop"
        or (isControllable(domain) or isAutomation(domain)) and function() actEntity(entity.entity_id) end or "onNoop"
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

local function getOrderedIds()
    local ids, seen = {}, {}
    for _, eid in ipairs(monitoredEntities) do
        if entityStates[eid] then
            table.insert(ids, eid)
            seen[eid] = true
        end
    end
    for eid in pairs(entityStates) do
        if not seen[eid] then
            table.insert(ids, eid)
        end
    end
    return ids
end

local function buildListBody(ids)
    if not getCleanUrl() or getCleanUrl() == "" or getCleanToken() == "" then
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
    if status == "unreachable" then
        return ui.label({ text = tr("unreachable"), color = "error" })
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
    for _, eid in ipairs(ids) do
        table.insert(cards, buildEntityCard(entityStates[eid]))
    end
    return ui.scroll({ flexGrow = 1, gap = 8 }, cards)
end

local function buildBrowserBody()
    if browserLoading then
        return ui.label({ text = tr("loading_entities"), color = "on_surface_variant" })
    end
    if browserFailed then
        return ui.label({ text = tr("load_entities_failed"), color = "error" })
    end
    if #allEntities == 0 then
        return ui.label({ text = tr("no_entities_found"), color = "on_surface_variant" })
    end

    local q = searchText:lower()
    local filtered = {}
    -- A row is six UI nodes and a closure, so rendering every match on a large instance
    -- overruns the callback budget on each keystroke. Nobody scrolls past a few hundred.
    local truncated = false
    for _, e in ipairs(allEntities) do
        if q == ""
            or e.entity_id:lower():find(q, 1, true)
            or e.friendly_name:lower():find(q, 1, true)
        then
            if #filtered >= MAX_BROWSER_ROWS then
                truncated = true
                break
            end
            table.insert(filtered, e)
        end
    end

    if #filtered == 0 then
        return ui.label({ text = tr("no_entities_match"), color = "on_surface_variant" })
    end

    local rows = {}
    for _, e in ipairs(filtered) do
        local entityId = e.entity_id
        local pinned = isPinned(entityId)
        table.insert(rows, ui.row({ align = "center", gap = 8 }, {
            ui.column({ flexGrow = 1, gap = 2 }, {
                ui.label({ text = e.friendly_name, fontWeight = "medium" }),
                ui.label({ text = e.entity_id, color = "on_surface_variant", fontSize = 12 }),
            }),
            ui.button({ glyph = pinned and "pin-filled" or "pin", onClick = function() toggleBrowserPin(entityId) end }),
        }))
    end

    if truncated then
        table.insert(rows, ui.label({
            text = tr("browser_truncated", { count = MAX_BROWSER_ROWS }),
            color = "on_surface_variant",
            fontSize = 12,
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
        panel.render(ui.column({ flexGrow = 1, gap = 16 }, {
            ui.row({ align = "center", gap = 8 }, {
                ui.glyph({ name = "smart-home", size = 20, color = "primary" }),
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
    local now = os.clock()

    -- A load that is still converting is making progress, so it outranks the timeout.
    if pendingStates ~= nil then
        consumePendingStates()
        return
    end

    if browserLoading and browserLoadingSince and (now - browserLoadingSince) > BROWSER_TIMEOUT_SECONDS then
        browserLoading = false
        browserLoadingSince = nil
        browserFailed = true
        reconcilePending(now)
        render()
        return
    end

    if reconcilePending(now) then
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
