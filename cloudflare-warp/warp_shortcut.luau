--!nonstrict

-- Simple and lazy
local CONNECTED_ID = 1
local UNAVAILABLE_ID = 4
local TOGGLE_CMD_ID = 3

local function updateButton(stateId: number)
    local connected = stateId == CONNECTED_ID
    shortcut.setActive(connected)
    local enabled = stateId ~= UNAVAILABLE_ID
    shortcut.setEnabled(enabled)
end

noctalia.state.watch("state", updateButton)

function onClick()
    noctalia.state.set("cmd", TOGGLE_CMD_ID) -- Id for toggle_conn
end

local function init()
    shortcut.setIcon("brand-cloudflare")
    shortcut.setLabel("WARP")
    local state = noctalia.state.get("state") or UNAVAILABLE_ID
    updateButton(state)
end

init()
