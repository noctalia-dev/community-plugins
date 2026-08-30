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

local function loadBar(config, report)
    local values = {
        report = report,
        error = { code = "", detail = "" },
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

io.write("ok: account selection and malformed metrics handling\n")
