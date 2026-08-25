-- Small host harness for the poller state machine and provider visual metadata.

local function read(path)
    local file = assert(io.open(path, "r"))
    local source = file:read("*a")
    file:close()
    return source
end

local values, watchers = {}, {}
local commands, callbacks = {}, {}
local now = 5000
local intervals = {}

local state = {
    get = function(key) return values[key] end,
    set = function(key, value)
        values[key] = value
        if watchers[key] then watchers[key](value) end
    end,
    watch = function(key, callback) watchers[key] = callback end,
}

local noctalia = {
    state = state,
    nowMs = function() return now end,
    getConfig = function(key) return key == "refresh_minutes" and 5 or nil end,
    setUpdateInterval = function(ms) intervals[#intervals + 1] = ms end,
    runAsync = function(command, callback)
        commands[#commands + 1] = command
        callbacks[#callbacks + 1] = callback
        return true
    end,
    json = { decode = function() return { entries = {} } end },
    string = { trim = function(value) return value end },
}

local env = setmetatable({ noctalia = noctalia }, { __index = _G })
local service = assert(load(read("service.luau"), "service", "t", env))
service()

assert(#callbacks == 1, "service should start one initial refresh")
env.onIpc("refresh")
assert(#callbacks == 1, "refresh while busy should be coalesced")
assert(values.refresh_queued == true, "coalesced refresh should be visible as queued")

now = 7000
callbacks[1]({ exitCode = 0, stdout = "{}", stderr = "" })
assert(#callbacks == 2, "queued refresh should start after the first callback")
assert(values.refresh_queued == false, "queued state should clear when refresh starts")
assert(values.polling == true, "queued refresh should become the active poll")
assert(intervals[#intervals] == 5 * 60 * 1000, "active refresh should restore the configured interval")

local sharedEnv = setmetatable({ noctalia = noctalia }, { __index = _G })
local shared = assert(load(read("shared.luau"), "shared", "t", sharedEnv))()
for _, id in ipairs({
    "anthropic", "openai", "anthropic_api", "zai", "openrouter", "deepseek", "kimi",
    "kilo", "novita", "moonshot", "grok", "supergrok", "antigravity", "cursor",
    "minimax", "kiro",
}) do
    -- "brain" is the fallback, so a provider still on it has no glyph of its own.
    assert(shared.providerGlyph(id) ~= "brain", "missing glyph for " .. id)
end

io.write("ok: refresh queue coalesced, provider visuals complete\n")
