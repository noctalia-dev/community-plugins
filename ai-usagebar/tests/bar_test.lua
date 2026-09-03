-- Host harness for provider/account selection in bar.luau.

local function read(path)
    local file = assert(io.open(path, "r"))
    local source = file:read("*a")
    file:close()
    return source
end

local function entry(id, displayName, percent)
    return {
        id = id,
        display_name = displayName,
        plan = "Plan",
        status = "ready",
        metrics = {
            {
                label = "Session",
                percent = percent,
                value = tostring(percent) .. "%",
                detail = "",
                severity = "low",
            },
        },
    }
end

local function loadBar(config, report, err)
    local values = {
        report = report,
        error = err or { code = "", detail = "" },
    }
    local rendered, tooltip
    local noctalia = {
        getConfig = function(key) return config[key] end,
        state = {
            get = function(key) return values[key] end,
            set = function(key, value) values[key] = value end,
            watch = function() end,
        },
        setUpdateInterval = function() end,
        togglePanel = function() end,
        tr = function(key, args)
            if key == "ui.not_configured" then
                return tostring(args.vendor) .. " not configured"
            end
            return key
        end,
        string = {
            trim = function(value) return tostring(value):match("^%s*(.-)%s*$") end,
        },
    }
    local ui = setmetatable({}, {
        __index = function(_, kind)
            return function(props, children)
                return { kind = kind, props = props or {}, children = children or {} }
            end
        end,
    })
    local barWidget = {
        render = function(node) rendered = node end,
        setTooltip = function(rows) tooltip = rows end,
    }
    local sharedEnv = setmetatable({ noctalia = noctalia }, { __index = _G })
    local shared = assert(load(read("shared.luau"), "shared", "t", sharedEnv))()
    local env = setmetatable({
        noctalia = noctalia,
        ui = ui,
        barWidget = barWidget,
        require = function(path)
            assert(path == "./shared.luau")
            return shared
        end,
    }, { __index = _G })
    assert(load(read("bar.luau"), "bar", "t", env))()
    return {
        env = env,
        values = values,
        rendered = function() return rendered end,
        tooltip = function() return tooltip end,
    }
end

local function containsText(node, wanted)
    if type(node) ~= "table" then return false end
    if type(node.props) == "table" and node.props.text == wanted then return true end
    for _, child in ipairs(node.children or {}) do
        if containsText(child, wanted) then return true end
    end
    return false
end

local namedReport = {
    primary = "openai",
    entries = {
        entry("openai", "Codex", 90),
        entry("openai@work", "Codex · work", 20),
    },
}

local named = loadBar({
    vendor = "openai", account = "work", extras = "none",
    visualization = "none", show_name = true,
}, namedReport)
assert(named.tooltip()[1].key == "Codex · work", "account should select the matching named entry")
assert(containsText(named.rendered(), "Codex · work"), "show_name should distinguish a named account")
named.env.onClick()
assert(named.values.selected == "openai@work", "panel should open on the named account")

local default = loadBar({
    vendor = "openai", account = "", extras = "none", visualization = "none",
}, namedReport)
assert(default.tooltip()[1].key == "Codex", "an empty account should keep the default provider entry")

local malformedEntry = entry("openai", "Codex", 50)
malformedEntry.metrics = { 42 }
local malformedOk = pcall(loadBar, {
    vendor = "openai", account = "", extras = "none", visualization = "none",
}, { entries = { malformedEntry } })
assert(malformedOk, "malformed metrics should render as an empty reading")

local missing = loadBar({
    vendor = "openai", account = "missing", extras = "none", visualization = "none",
}, namedReport)
assert(missing.tooltip()[1].value == "openai@missing not configured",
    "a missing account should name the full entry id")

local auto = loadBar({
    vendor = "auto", account = "work", extras = "none", visualization = "none",
}, {
    primary = "openai",
    entries = {
        entry("anthropic", "Claude", 10),
        entry("openai@work", "Codex · work", 80),
    },
})
assert(auto.tooltip()[1].key == "Codex · work", "auto should ignore account and keep ranking by usage")

local primary = loadBar({
    vendor = "auto", account = "", extras = "none", visualization = "none",
}, {
    primary = "openai",
    entries = {
        entry("anthropic", "Claude", 50),
        entry("openai@work", "Codex · work", 50),
    },
})
assert(primary.tooltip()[1].key == "Codex · work",
    "primary provider should break a tie for a named account")

local sameProvider = loadBar({
    vendor = "auto", account = "", extras = "none", visualization = "none",
}, {
    primary = "openai",
    entries = {
        entry("openai@alpha", "Codex · alpha", 50),
        entry("openai@zeta", "Codex · zeta", 50),
    },
})
assert(sameProvider.tooltip()[1].key == "Codex · alpha",
    "named accounts of the same primary provider should keep lexical order")

-- A provider whose service is down is dropped from the bar on the first report
-- that says so: the CLI keeps serving what it cached, and a frozen number beside
-- live ones reads as live.
local function downEntry(id, displayName, percent)
    local down = entry(id, displayName, percent)
    down.sections = {
        { type = "text", label = "Warning",
          value = "credentials error: Antigravity: no local server found." },
    }
    return down
end

local dropped = loadBar({
    vendor = "auto", account = "", extras = "none", visualization = "none",
    provider_limit = 3,
}, {
    entries = {
        entry("anthropic", "Claude", 10),
        downEntry("antigravity", "Antigravity", 90),
        entry("openai", "Codex", 20),
    },
})
local names = {}
for _, row in ipairs(dropped.tooltip()) do names[#names + 1] = row.key end
local listed = false
for _, name in ipairs(names) do if name == "Antigravity" then listed = true end end
assert(not listed, "a provider that is down leaves the bar")
-- Ranked first on severity, it would have led the capsule; the rest still show.
-- Each provider contributes its name and then its readings.
assert(names[1] == "Codex" and names[3] == "Claude", "the rest keep their order")
-- And it is not counted as hidden: hidden means there is more to see.
for _, row in ipairs(dropped.tooltip()) do
    assert(row.key ~= "ui.hidden_label", "it is dropped, not hidden behind a +1")
end

local pinnedDown = loadBar({
    vendor = "antigravity", account = "", extras = "none", visualization = "none",
}, { entries = { downEntry("antigravity", "Antigravity", 90) } })
assert(#pinnedDown.tooltip() > 0, "a pinned provider still explains itself in the tooltip")
-- Configured but unreachable is not the same as never configured, and the
-- tooltip may not call one the other. The CLI already worded the failure.
local pinnedRow = pinnedDown.tooltip()[1]
assert(pinnedRow.key == "Antigravity", "a pinned provider that is down keeps its name")
assert(tostring(pinnedRow.value):find("no local server") ~= nil,
    "the tooltip repeats the CLI's own words instead of calling it unconfigured")

-- `[ui] primary` can come back as a full account id, and the tie-break has to
-- recognise it in that form as well as the bare provider one.
local primaryNamed = loadBar({
    vendor = "auto", account = "", extras = "none", visualization = "none",
}, {
    primary = "openai@work",
    entries = {
        entry("anthropic", "Claude", 50),
        entry("openai@work", "Codex · work", 50),
    },
})
assert(primaryNamed.tooltip()[1].key == "Codex · work",
    "a primary reported as a full account id still breaks the tie")

-- A failed read flags the capsule without resizing it: the signal rides on the
-- colour of something already drawn, so the neighbouring widget does not move
-- once per failed cycle.
local function glyphColor(node, name)
    if type(node) ~= "table" then return nil end
    if node.kind == "glyph" and node.props.name == name then return node.props.color end
    for _, child in ipairs(node.children or {}) do
        local found = glyphColor(child, name)
        if found ~= nil then return found end
    end
    return nil
end

local function countNodes(node)
    if type(node) ~= "table" then return 0 end
    local total = 1
    for _, child in ipairs(node.children or {}) do total = total + countNodes(child) end
    return total
end

local steadyConfig = { vendor = "openai", account = "", extras = "none", visualization = "none" }
local steadyReport = { entries = { entry("openai", "Codex", 40) } }
local healthy = loadBar(steadyConfig, steadyReport)
local broken = loadBar(steadyConfig, steadyReport, { code = "timed_out", detail = "" })
assert(countNodes(broken.rendered()) == countNodes(healthy.rendered()),
    "a failed read may not add a node to the capsule")
assert(glyphColor(broken.rendered(), "alert-triangle") == nil,
    "no extra glyph widens the capsule on a failed read")
assert(glyphColor(broken.rendered(), "brand-openai") == "error",
    "the failure rides on the colour of the mark already drawn")
assert(glyphColor(healthy.rendered(), "brand-openai") == "on_surface",
    "a healthy read leaves the mark in its identity colour")

io.write("ok: account selection, malformed metrics, providers that are down, and a steady capsule\n")
