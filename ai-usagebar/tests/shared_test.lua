-- Regression tests for shared date parsing. Run with a timezone that observes DST:
--
--   TZ=America/New_York lua tests/shared_test.lua

assert(os.getenv("TZ") == "America/New_York", "run with TZ=America/New_York")

local function read(path)
    local file = assert(io.open(path, "r"))
    local source = file:read("*a")
    file:close()
    return source
end

local noctalia = {
    string = {
        trim = function(value) return tostring(value):match("^%s*(.-)%s*$") end,
    },
}
local env = setmetatable({ noctalia = noctalia }, { __index = _G })
local shared = assert(load(read("shared.luau"), "shared", "t", env))()

local cases = {
    { "winter", "2024-01-10T12:00:00Z", 1704888000 },
    { "summer", "2024-07-10T12:00:00Z", 1720612800 },
    { "before spring transition", "2024-03-10T06:30:00Z", 1710052200 },
    { "after spring transition", "2024-03-10T07:30:00Z", 1710055800 },
}

for _, case in ipairs(cases) do
    local name, input, expected = case[1], case[2], case[3]
    local actual = shared.parseIso(input)
    assert(actual == expected,
        string.format("%s: expected %d for %s, got %s", name, expected, input, tostring(actual)))
end

assert(type(shared.terminalAuth) == "function", "terminal authentication classifier should exist")
assert(type(shared.transportError) == "function", "transport error classifier should exist")

local retired = {
    id = "anthropic",
    error = "",
    sections = {
        { type = "text", label = "HTTP 403", value = "authentication rejected" },
    },
}
assert(shared.terminalAuth(retired), "403 authentication rejection should be terminal")
assert(shared.terminalAuth({ error = "HTTP 401: authorization token expired" }),
       "401 expired authorization should be terminal")
assert(not shared.terminalAuth({ error = "HTTP 429 authentication rate limited" }),
       "rate limiting should stay transient")
assert(not shared.terminalAuth({ error = "HTTP 500 authentication service unavailable" }),
       "server errors should stay transient")
assert(not shared.terminalAuth({ error = "authentication rejected by local configuration" }),
       "authentication wording without HTTP 401 or 403 should stay visible")
assert(shared.transportError("HTTP 500: internal error"), "HTTP failures should be transport details")
assert(not shared.transportError("The weekly window resets soon"), "ordinary prose should remain content")

local filtered = shared.entries({ entries = {
    retired,
    { id = "openai", sections = {} },
} })
assert(#filtered == 1 and filtered[1].id == "openai",
       "terminal providers should be filtered from shared entries")

local function usageEntry(id, percent)
    return {
        id = id,
        status = "ready",
        stale = false,
        metrics = { { percent = percent } },
        sections = {},
    }
end

local unavailable = usageEntry("anthropic", 0)
unavailable.stale = true
unavailable.sections = {
    { type = "text", label = "HTTP 429", value = "Rate limited" },
}
local ordered = shared.entries({ entries = {
    unavailable,
    usageEntry("openai", 32),
    usageEntry("antigravity", 99),
} })
assert(#ordered == 2, "providers with their own refresh failure should be removed")
assert(ordered[1].id == "antigravity" and ordered[2].id == "openai",
       "working providers should be ordered by highest usage")

io.write("ok: shared timestamps, availability, and provider order\n")
