-- Small host harness for the poller state machine and provider visual metadata.

local function read(path)
    local file = assert(io.open(path, "r"))
    local source = file:read("*a")
    file:close()
    return source
end

local values, watchers = {}, {}
local commands, callbacks = {}, {}
local notifications = {}
local decodedReport = { entries = {} }
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
    json = { decode = function() return decodedReport end },
    notify = function(title, message)
        notifications[#notifications + 1] = { title = title, message = message }
    end,
    tr = function(key) return key end,
    string = { trim = function(value) return value end },
}

local env = setmetatable({ noctalia = noctalia }, { __index = _G })
env.require = function(path)
    assert(path == "./shared.luau")
    return assert(load(read("shared.luau"), "shared", "t", env))()
end
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

decodedReport = { entries = { { id = "antigravity", status = "error",
    error = "credentials error: Antigravity: no local server found.", metrics = {} } } }
now = 9000
env.onIpc("refresh")
callbacks[3]({ exitCode = 0, stdout = "{}", stderr = "" })
assert(values.report.entries[1].status == "error"
    and values.report.entries[1].stale ~= true,
    "Antigravity without an earlier reading must stay unavailable")

decodedReport = { entries = { { id = "openai", display_name = "Codex api_key=topsecret123", status = "ready",
    metrics = { { label = "Session", percent = 10 },
        { label = "Weekly", percent = 100 } } } } }
now = 11000
env.onIpc("refresh")
callbacks[4]({ exitCode = 0, stdout = "{}", stderr = "" })
assert(#notifications == 0, "quota changes must not send notifications")

decodedReport = { entries = {
    { id = "antigravity", display_name = "Antigravity", status = "ready",
      fetched_at = "2026-09-24T12:00:00Z", metrics = { { label = "Gemini", percent = 42 } } },
    { id = "openai", display_name = "Codex", status = "ready", metrics = {} },
} }
now = 13000
env.onIpc("refresh")
callbacks[5]({ exitCode = 0, stdout = "{}", stderr = "" })

decodedReport = { entries = {
    { id = "antigravity", display_name = "Antigravity", status = "error",
      error = "credentials error: Antigravity: no local server found.", metrics = {} },
    { id = "openai", display_name = "Codex", status = "ready", metrics = {} },
} }
now = 15000
env.onIpc("refresh")
callbacks[6]({ exitCode = 0, stdout = "{}", stderr = "" })
local cached = values.report.entries[1]
assert(cached.id == "antigravity" and cached.metrics[1].percent == 42
    and cached.fetched_at == "2026-09-24T12:00:00Z" and cached.stale == true,
    "a transient Antigravity failure should retain the dated last reading")
assert(values.report.entries[2].id == "openai", "other providers should keep fresh readings")

decodedReport = { entries = { { id = "antigravity", status = "error",
    error = "credentials error: Antigravity: no local server found.", metrics = {} } } }
now = 17000
env.onIpc("refresh")
callbacks[7]({ exitCode = 0, stdout = "{}", stderr = "" })
assert(values.report.entries[1].metrics[1].percent == 42
    and values.report.entries[1].stale == true,
    "consecutive local-server failures should not make Antigravity disappear")

decodedReport = { entries = {
    { id = "antigravity", display_name = "Antigravity", status = "ready",
      fetched_at = "2026-09-24T12:05:00Z", metrics = { { label = "Gemini", percent = 35 } } },
} }
now = 19000
env.onIpc("refresh")
callbacks[8]({ exitCode = 0, stdout = "{}", stderr = "" })
assert(values.report.entries[1].metrics[1].percent == 35
    and values.report.entries[1].stale ~= true,
    "the next healthy Antigravity reading should replace the cached one")

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
    assert(shared.providerDashboard(id) ~= nil, "missing quota service link for " .. id)
end

-- A named account is drawn with its provider's glyph, not the fallback.
assert(shared.providerGlyph("anthropic@gmail") == shared.providerGlyph("anthropic"),
    "an account should inherit the provider's glyph")
assert(shared.providerGlyph("unknown") == "brain", "an unknown provider falls back")

io.write("ok: refresh queue coalesced, timeouts rejected, provider visuals complete\n")
