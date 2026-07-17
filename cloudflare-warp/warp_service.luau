--!nonstrict

-- Let's get lost on Luau types and table accessing
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

local TITLE = "Cloudflare WARP"

local config: { update_interval: number, notify_state: boolean } = {
    update_interval = 5,
    notify_state = true,
}

local state: { id: WarpKey, checking: boolean } = {
    id = 0,
    checking = false
} 

local nTr = noctalia.tr
local nNotify = noctalia.notify
local nNotifyError = noctalia.notifyError

local function strContains(s: string, sub: string, i: number?): boolean
    return string.find(s, sub, i or 1, true) ~= nil
end

local function notifyState(msg: string?)
    local body
    if state.id == STATES.error then
        body = if msg and msg ~= "" then `: {msg}` else `: {nTr("strings.unknown_err")}` 
        nNotifyError(TITLE, `{nTr("state.error")}{body}`)
    else
        body = if msg and msg ~= "" then `: {msg}` else ""
        nNotify(TITLE, `{nTr(`state.{STATES[state.id]}`)}{body}`)
    end
end

local function checkInstalled(): boolean
	return noctalia.commandExists("warp-cli")
end

local function checkConnected()
    if state.checking then return end
    state.checking = true
	noctalia.runAsync("warp-cli status", function(result)
		local connection: WarpKey
        local out
        if result.exitCode == 0 then
            out = result.stdout
            if strContains(out, "Connected") then connection = STATES.connected
            elseif strContains(out, "Disconnected") then connection = STATES.disconnected
            elseif strContains(out, "Connecting") then connection = STATES.connecting
            else connection = STATES.error end
            out = ""
		else
            connection = STATES.error
            out = result.stderr
		end
        if connection ~= state.id then
            state.id = connection
            noctalia.state.set("state", connection)
            if config.notify_state then notifyState(out) end
        end
        state.checking = false
   	end)
end

local function setConnection(cmdId: number)
    if state.checking == true then return end
    local targetCmd
    if cmdId == CMDS.toggle_conn then
        targetCmd = if state.id == STATES.connected then CMDS.disconnect else CMDS.connect
    elseif cmdId == CMDS.connect or cmdId == CMDS.disconnect then
        targetCmd = cmdId
    else
        return
    end

	local command = `warp-cli {CMDS[targetCmd]}`
    state.checking = true
	noctalia.runAsync(command, function(result)
        local connection: WarpKey
        local out
		if result.exitCode == 0 and strContains(result.stdout, "Success") then    
            connection = if targetCmd == CMDS.connect then STATES.connected else STATES.disconnected
		else
            connection = STATES.error
            out = result.stderr
        end
        state.id = connection
        noctalia.state.set("state", connection)
        if config.notify_state then notifyState(out) end
        state.checking = false
   	end)
end

noctalia.state.watch("cmd", setConnection)

function update()
    if state.id == STATES.unavailable then
        if not checkInstalled() then return
        else
            nNotify(TITLE, nTr("strings.found"))
        end
        state.id = STATES.connecting
    end

    checkConnected()
end

function onConfigChanged()
    config.update_interval = noctalia.getConfig("update_interval") or config.update_interval
    config.notify_state = noctalia.getConfig("notify_state") or config.notify_state
    noctalia.setUpdateInterval(config.update_interval * 1000)
end

local function init()
    onConfigChanged()

    if checkInstalled() then
        checkConnected()
    else
        state.id = STATES.unavailable
        noctalia.state.set("state", state.id)
        nNotifyError(TITLE, nTr("strings.unavailable"))
    end
end

init()