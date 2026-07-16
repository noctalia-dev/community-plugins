--!nonstrict

local haUrl = noctalia.getConfig("ha_url")
local haToken = noctalia.getConfig("ha_token")
local configuredEntityId = noctalia.getConfig("shortcut_entity_4") or ""
local SLOT_LABEL = "HA Toggle 4"

local entityStates = {}
local pendingToggle = {}
local pendingAge = {}

local function escapeArg(s)
    return "'" .. s:gsub("'", "'\\''" ) .. "'"
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

local function render()
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
    for eid, expected in pairs(pendingToggle) do
        local age = (pendingAge[eid] or 0) + 1
        pendingAge[eid] = age
        local real = entityStates[eid]
        if not real or real.state == expected or age > 20 then
            pendingToggle[eid] = nil
            pendingAge[eid] = nil
        end
    end
    render()
end)

noctalia.state.watch("connection_status", function() render() end)

function onClick()
    local entity = getEntity()
    if not entity or not haUrl or haUrl == "" or not haToken or haToken == "" then return end

    local eid = entity.entity_id
    if pendingToggle[eid] then return end

    local newState = entity.state == "on" and "off" or "on"
    pendingToggle[eid] = newState
    pendingAge[eid] = 0

    local encoded = noctalia.json.encode({ entity_id = eid })

    local cmd = "curl -s -o /dev/null -X POST"
        .. " -H " .. escapeArg("Authorization: Bearer " .. haToken)
        .. " -H " .. escapeArg("Content-Type: application/json")
        .. " -d " .. escapeArg(encoded)
        .. " " .. escapeArg(haUrl .. "/api/services/" .. entity.domain .. "/toggle")
    noctalia.runAsync(cmd)
    render()
end

entityStates = noctalia.state.get("entities") or {}
render()
