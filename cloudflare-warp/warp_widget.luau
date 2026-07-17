--!nonstrict

type WarpState = "connected" | "disconnected" | "connecting" | "unavailable" | "error"
type WarpCommand = "connect"| "disconnect" | "toggle_conn"
type WarpKey = WarpState | WarpCommand | number

local function createArrayHashTable(arr: { WarpKey }, freeze: boolean?)
    local expanded: { [string|number]: WarpKey } = table.create(#arr)
    for i, s in ipairs(arr) do
        expanded[s] = i :: number
        expanded[i] = s :: WarpKey 
    end
    if freeze then
        table.freeze(expanded)
    end
    return expanded
end

local STATES = createArrayHashTable({
    "connected",
    "disconnected",
    "connecting",
    "unavailable",
    "error"
} :: {WarpState}, true)

local CMDS = createArrayHashTable({
    "connect",
    "disconnect",
    "toggle_conn"
} :: {WarpCommand}, true)

local state: { id: number, client_available: boolean } = {
    id = noctalia.state.get("state") or STATES.unavailable,
    client_available = false
}

local tooltip: {{ key: string, value: string }} = table.create(3)

local nTr = noctalia.tr

local function updateUi(stateId: number)
    state.id = stateId
	local color = if stateId == STATES.connected then "on_surface" else "error"
    tooltip[1].value = nTr(`state.{STATES[stateId]}`)

	barWidget.setGlyphColor(color)
    barWidget.setTooltip(tooltip)
end

noctalia.state.watch("state", updateUi)

local function toggle_client(isRunning: boolean)
    if isRunning then
        noctalia.runAsync("pkill -15 warp-taskbar")
    else
        noctalia.runAsync("warp-taskbar --show")
    end
end

function onClick()
    if state.id == STATES.unavailable then return end
    noctalia.state.set("cmd", CMDS.toggle_conn)
end

function onRightClick()
    if not state.client_available then
        if not noctalia.commandExists("warp-taskbar") then return end
        state.client_available = true
    end
    noctalia.processMatches(toggle_client, "warp-taskbar")
end

local function init()
    local glyph = noctalia.getConfig("glyph") or "brand-cloudflare"
    barWidget.setGlyph(glyph)

    state.client_available = noctalia.commandExists("warp-taskbar")

    tooltip[1] = { key = nTr("status"), value = ""}
    tooltip[2] = { key = nTr("actions.left_click"), value = nTr("commands.toggle_conn") }
    tooltip[3] = { key = nTr("actions.right_click"), value = nTr("commands.toggle_client") }

    updateUi(state.id)
end


init()
