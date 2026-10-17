-- Catalog reads stay independent of quota polling and expose only public fields.
local function read(path)
    local file = assert(io.open(path, "r"))
    local source = file:read("*a")
    file:close()
    return source
end

local values, watchers, calls = {}, {}, {}
local now, spawn = 5000, true
local decoded = nil
local env = setmetatable({ noctalia = {
    state = {
        get = function(key) return values[key] end,
        set = function(key, value) values[key] = value end,
        watch = function(key, callback) watchers[key] = callback end,
    },
    nowMs = function() return now end,
    getConfig = function() return 5 end,
    setUpdateInterval = function() end,
    string = { trim = function(value) return tostring(value):match("^%s*(.-)%s*$") end },
    json = { decode = function() return decoded end },
    runAsync = function(command, callback, timeout)
        calls[#calls + 1] = { command = command, callback = callback, timeout = timeout }
        return spawn
    end,
} }, { __index = _G })
env.require = function() return assert(load(read("shared.luau"), "shared", "t", env))() end
assert(load(read("service.luau"), "service", "t", env))()
assert(#calls == 1 and calls[1].command == "ai-usagebar usage --json", "startup only polls usage")
local report, failure = { entries = {} }, { code = "timed_out" }
values.report, values.error = report, failure
watchers.command({ action = "catalog" })
assert(#calls == 2, "catalog request starts its own read")
assert(calls[2].command == "ai-usagebar vendors --json" and calls[2].timeout == 5000)
assert(values.catalog_loading == true and values.polling == true)
env.onIpc("catalog")
assert(#calls == 2, "duplicate requests in flight are ignored")
decoded = { vendors = {
    { id = "openai", name = "Codex api_key=hiddenvalue", enabled = true,
      configured = false, needs_credential = true, login = "bad command", env = "SECRET",
      account = "private", api_key = "private" },
    { id = "antigravity", name = "Antigravity", enabled = true,
      configured = true, needs_credential = false },
} }
calls[2].callback({ exitCode = 0, stdout = "catalog" })
assert(values.catalog_loading == false and values.catalog_error == false)
local catalog = values.catalog
assert(#catalog.vendors == 2 and catalog.vendors[1].name == "Codex api_key=<redacted>")
local count = 0
for _ in pairs(catalog.vendors[1]) do count = count + 1 end
assert(count == 5 and catalog.vendors[1].login == nil and catalog.vendors[1].env == nil,
       "only five typed public fields survive")
assert(values.report == report and values.error == failure and values.polling == true,
       "catalog must not change usage state")
env.onIpc("catalog")
assert(#calls == 2, "rapid requests after completion respect the minimum gap")

local function request(result, document, shouldSpawn)
    now = now + 3000
    spawn = shouldSpawn ~= false
    decoded = document
    local previous = #calls
    env.onIpc("catalog")
    assert(#calls == previous + 1, "later explicit requests can retry")
    if spawn then calls[#calls].callback(result) end
    assert(values.catalog_loading == false and values.catalog_error == true)
    assert(values.catalog == catalog, "failure preserves previous catalog")
    assert(#calls == previous + 1, "catalog failure never retries itself")
    assert(values.report == report and values.error == failure and values.polling == true)
end
request({ exitCode = 2, stderr = "unrecognized subcommand 'vendors'" })
request({ exitCode = 0, timedOut = true }, { vendors = {} })
request(nil, nil, false)
request({ exitCode = 0 }, nil)
request({ exitCode = 0 }, { vendors = "bad" })
request({ exitCode = 0 }, { vendors = { { id = "openai@private", name = "bad",
    enabled = true, configured = true, needs_credential = true } } })
request({ exitCode = 0 }, { vendors = { { id = "openai", name = "bad",
    enabled = "true", configured = true, needs_credential = true } } })
request({ exitCode = 0 }, { vendors = { { id = "opénai", name = "bad",
    enabled = true, configured = true, needs_credential = true } } })
request({ exitCode = 0 }, { vendors = { unexpected = {} } })
request({ exitCode = 0 }, { vendors = {
    [1] = { id = "openai", name = "Codex", enabled = true, configured = true, needs_credential = true },
    [3] = { id = "cursor", name = "Cursor", enabled = true, configured = true, needs_credential = true },
    [4] = { id = "kimi", name = "Kimi", enabled = true, configured = true, needs_credential = true },
} })
now = now + 3000
spawn, decoded = true, { vendors = {} }
env.onIpc("catalog")
calls[#calls].callback({ exitCode = 0 })
assert(values.catalog_error == false and #values.catalog.vendors == 0, "empty catalog is valid")
assert(#calls > 2 and calls[1].command == "ai-usagebar usage --json")
decoded = { entries = {} }
calls[1].callback({ exitCode = 0 })
local beforeTick = #calls
env.update()
assert(#calls == beforeTick + 1 and calls[#calls].command == "ai-usagebar usage --json",
       "periodic polling never requests the catalog")
io.write("ok: on-demand catalog, public whitelist, isolated failures, no retry loops\n")
