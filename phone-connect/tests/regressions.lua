-- The plugin uses the Lua-compatible subset of Luau. No processes are spawned.
local directory, mode = arg[1], arg[2]
local values, queue, commands = {}, {}, {}
local function noop() end
local api = {
    state = {
        get = function(key) return values[key] end,
        set = function(key, value) values[key] = value end,
        watch = noop,
    },
    getConfig = function(key)
        return ({language = "en", state_update_interval = 30, enable_clipboard_action = true})[key]
    end,
    pluginDataDir = function() return "/mock" end,
    pluginDir = function() return "/mock" end,
    readFile = function() return nil end,
    writeFile = noop,
    fileExists = function() return false end,
    commandExists = function() return true end,
    setUpdateInterval = noop,
    runStream = function() return true end,
    log = noop,
    notifyError = function(message) error(message) end,
    json = {encode = function() return "{}" end},
    runAsync = function(command, callback)
        table.insert(commands, command)
        if callback then table.insert(queue, {command = command, callback = callback}) end
    end,
}
local env = setmetatable({noctalia = api}, {__index = _G})

if mode == "service" then
    assert(loadfile(directory .. "/service.luau", "t", env))()
    local index = 1
    while queue[index] do
        assert(index < 30, "Unexpected refresh loop")
        local item = queue[index]
        local response = "()"
        if item.command:find("NameHasOwner", 1, true) then
            response = "(true,)"
        elseif item.command:find(".devices false false", 1, true) then
            response = "(['test_phone'],)"
        elseif item.command:find("device.battery", 1, true) then
            response = "({'charge': <45>, 'isCharging': <false>},)"
        elseif item.command:find("device.connectivity_report", 1, true) then
            response = "({'cellularNetworkType': <''>, 'cellularNetworkStrength': <-1>},)"
        elseif item.command:find("device.mprisremote", 1, true) then
            response = "({},)"
        elseif item.command:find("Properties.GetAll", 1, true) then
            response = "({'name': <'Test phone'>, 'type': <'phone'>, 'isPaired': <true>, 'isReachable': <true>},)"
        end
        item.callback({stdout = response})
        index = index + 1
    end
    assert(values['pc.devices'].test_phone.batteryCharge == 45)
    local refreshed = false
    for _, command in ipairs(commands) do
        if command:find("kdeconnect-cli --refresh", 1, true) then refreshed = true end
    end
    assert(refreshed, "Missing cellular report must use the defined CLI helper")
elseif mode == "panel" then
    local device = {id = "test_phone", name = "Test phone", type = "phone", isPaired = true, isReachable = true}
    values['pc.devices'] = {test_phone = device}
    values['pc.order'] = {"test_phone"}
    values['pc.backend'] = {available = true}
    env.ui = setmetatable({}, {__index = function(_, kind)
        return function(props, children)
            -- Model Noctalia's child-list requirement, including holes before later nodes.
            local maximum = 0
            for key in pairs(children or {}) do
                if type(key) == "number" then maximum = math.max(maximum, key) end
            end
            for index = 1, maximum do
                assert(type(children[index]) == "table", "UI child is missing or not a table")
            end
            return {kind = kind, props = props, children = children}
        end
    end})
    local renders = 0
    env.panel = {render = function() renders = renders + 1 end, close = noop}
    assert(loadfile(directory .. "/panel.luau", "t", env))()
    env.render()
    device.mediavolume = 50
    env.render()
    device.isReachable = false
    device.mediavolume = nil
    env.render()
    assert(renders == 3)
else
    error("Unknown test case")
end
