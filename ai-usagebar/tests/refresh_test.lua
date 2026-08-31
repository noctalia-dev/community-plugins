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

callbacks[2]({ timedOut = true, exitCode = 0, stdout = '{"entries":[]}', stderr = "" })
assert(values.error.code == "timed_out", "a timed-out command must not publish valid-looking stdout")

local sharedEnv = setmetatable({ noctalia = noctalia }, { __index = _G })
local shared = assert(load(read("shared.luau"), "shared", "t", sharedEnv))()
local incompleteFailure = shared.asFailure({})
assert(incompleteFailure.code == "" and incompleteFailure.detail == "",
    "an incomplete failure table should behave as no failure")
-- Read the offered providers out of the manifest rather than listing them again
-- here: a copy of the dropdown is a third place to keep the same set current, and
-- the one that silently stops matching. What is worth asserting is the relation
-- between the two -- every provider the settings editor offers has a glyph of its
-- own -- and that only holds if the list comes from the manifest itself.
local manifest = read("plugin.toml")
local vendorSetting = manifest:match('key = "vendor".-\n%s*\n') or manifest:match('key = "vendor".*')
local offered = {}
for value in vendorSetting:gmatch('{ value = "([^"]+)"') do
    if value ~= "auto" then offered[#offered + 1] = value end
end
assert(#offered > 10, "the vendor dropdown should have been read from the manifest")
for _, id in ipairs(offered) do
    -- "brain" is the fallback, so a provider still on it has no glyph of its own.
    assert(shared.providerGlyph(id) ~= "brain", "missing glyph for " .. id)
end

-- A named account is drawn with its provider's glyph, not the fallback.
assert(shared.providerGlyph("anthropic@gmail") == shared.providerGlyph("anthropic"),
    "an account should inherit the provider's glyph")
assert(shared.providerGlyph("unknown") == "brain", "an unknown provider falls back")

io.write("ok: refresh queue coalesced, timeouts rejected, provider visuals complete\n")
