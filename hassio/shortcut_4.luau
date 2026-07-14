--!nonstrict

local haUrl = noctalia.getConfig("ha_url")
local haToken = noctalia.getConfig("ha_token")
local configuredEntityId = noctalia.getConfig("shortcut_entity_4") or ""
local SLOT_LABEL = noctalia.tr("shortcut.label_4")

local entityStates = {}
local pendingToggle = {}
local pendingSince = {}
local pendingTimerToken = {}
local pendingTimerSeq = 0

local PENDING_TIMEOUT_SECONDS = 8
local render

local function getCleanUrl()
    if type(haUrl) ~= "string" then return "" end
    return (haUrl:gsub("/$", ""))
end

local function getCleanToken()
    if type(haToken) ~= "string" then return "" end
    return haToken:gsub("^%s+", ""):gsub("%s+$", "")
end

local function stateGlyph(domain, isOn)
    if domain == "light" then return isOn and "bulb" or "bulb-off"
    elseif domain == "switch" or domain == "input_boolean" then return isOn and "toggle-right" or "toggle-left"
    elseif domain == "fan" then return isOn and "wind" or "wind-off"
    elseif domain == "lock" then return isOn and "lock" or "lock-open"
    elseif domain == "cover" then return isOn and "door-open" or "door"
    end
    return "smart-home"
end

local function getEntity()
    if configuredEntityId == "" then return nil end
    return entityStates[configuredEntityId]
end

local function clearPending(entityId)
    pendingToggle[entityId] = nil
    pendingSince[entityId] = nil
    pendingTimerToken[entityId] = nil
end

local function isPendingTimedOut(entityId, now)
    local startedAt = pendingSince[entityId]
    if not startedAt then return false end
    return (now or os.clock()) - startedAt >= PENDING_TIMEOUT_SECONDS
end

local function reconcilePending(now)
    for entityId, expected in pairs(pendingToggle) do
        local real = entityStates[entityId]
        if not real or real.state == expected or isPendingTimedOut(entityId, now) then
            clearPending(entityId)
        end
    end
end

local function schedulePendingTimeout(entityId)
    pendingTimerSeq = pendingTimerSeq + 1
    local token = pendingTimerSeq
    pendingSince[entityId] = os.clock()
    pendingTimerToken[entityId] = token

    noctalia.runAsync("sleep " .. tostring(PENDING_TIMEOUT_SECONDS), function(_result)
        if pendingTimerToken[entityId] ~= token then return end
        if pendingToggle[entityId] and isPendingTimedOut(entityId) then
            clearPending(entityId)
            render()
        end
    end)
end

render = function()
    reconcilePending(os.clock())

    local entity = getEntity()

    if not entity then
        shortcut.setLabel(configuredEntityId ~= "" and configuredEntityId or SLOT_LABEL)
        shortcut.setIcon("smart-home")
        shortcut.setActive(false)
        shortcut.setEnabled(false)
        return
    end

    local eid = entity.entity_id
    local pending = pendingToggle[eid]

    if pending then
        shortcut.setLabel(entity.friendly_name or eid)
        shortcut.setIcon("loader")
        shortcut.setActive(pending == "on")
        shortcut.setEnabled(false)
        return
    end

    local isOn = entity.state == "on"
    shortcut.setLabel(entity.friendly_name or eid)
    shortcut.setIcon(stateGlyph(entity.domain, true), stateGlyph(entity.domain, false))
    shortcut.setActive(isOn)
    shortcut.setEnabled(true)
end

noctalia.state.watch("entities", function(value)
    entityStates = value or {}
    reconcilePending(os.clock())
    render()
end)

noctalia.state.watch("connection_status", function(_value)
    render()
end)

function onClick()
    reconcilePending(os.clock())

    local entity = getEntity()
    local cleanToken = getCleanToken()
    if not entity or getCleanUrl() == "" or cleanToken == "" then return end

    local eid = entity.entity_id
    if pendingToggle[eid] then return end

    local newState = entity.state == "on" and "off" or "on"
    pendingToggle[eid] = newState
    schedulePendingTimeout(eid)

    local encoded = noctalia.json.encode({ entity_id = eid })

    noctalia.http({
        url = getCleanUrl() .. "/api/services/" .. entity.domain .. "/toggle",
        method = "POST",
        headers = {
            "Authorization: Bearer " .. cleanToken,
            "Content-Type: application/json",
        },
        body = encoded,
    }, function(response)end)

    render()
end

entityStates = noctalia.state.get("entities") or {}
render()
