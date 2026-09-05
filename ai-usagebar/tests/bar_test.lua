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

local function containsGlyph(node, wanted)
    if type(node) ~= "table" then return false end
    if type(node.props) == "table" and node.props.name == wanted then return true end
    for _, child in ipairs(node.children or {}) do
        if containsGlyph(child, wanted) then return true end
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
assert(names[1] == "Codex" and names[2] == "Claude", "the rest keep their order")
-- And it is not counted as hidden: hidden means there is more to see.
for _, row in ipairs(dropped.tooltip()) do
    assert(row.key ~= "ui.hidden_label", "it is dropped, not hidden behind a +1")
end

local rejected = entry("anthropic", "Claude", 90)
rejected.sections = {
    { type = "text", label = "HTTP 403", value = "authentication rejected" },
}
local withoutRejected = loadBar({
    vendor = "auto", account = "", extras = "none", visualization = "none",
    provider_limit = 2,
}, { entries = { rejected, entry("openai", "Codex", 20) } })
local rejectedRows = withoutRejected.tooltip()
assert(rejectedRows[1].key == "Codex" and #rejectedRows == 1,
       "a terminal provider should leave the bar immediately")

local pinnedDown = loadBar({
    vendor = "antigravity", account = "", extras = "none", visualization = "none",
}, { entries = { downEntry("antigravity", "Antigravity", 90) } })
local pinnedRow = pinnedDown.tooltip()[1]
assert(pinnedRow.value == "antigravity not configured",
       "a pinned provider with its own failure should leave the bar")

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

local bottleneckBar = loadBar({
    vendor = "openai", account = "", extras = "none", visualization = "none",
}, {
    entries = {
        {
            id = "openai",
            display_name = "Codex",
            plan = "ChatGPT Plus",
            status = "ready",
            metrics = {
                { label = "Codex 5h", percent = 0, severity = "low", value = "0%" },
                { label = "Codex weekly", percent = 100, severity = "critical", value = "100%" },
            },
        },
    },
})
assert(containsText(bottleneckBar.rendered(), "100%"),
       "capsule should show the 100% weekly bottleneck when session is 0%")
assert(not containsText(bottleneckBar.rendered(), "0%"),
       "capsule should not show 0% when weekly limit is 100%")
local bottleneckRows = bottleneckBar.tooltip()
assert(#bottleneckRows == 1 and bottleneckRows[1].key == "Codex" and bottleneckRows[1].value == "0% / 100%",
       "bottleneckBar tooltip should combine dual metrics into a single row")

local agyBar = loadBar({
    vendor = "antigravity", account = "", extras = "none", visualization = "none",
}, {
    entries = {
        {
            id = "antigravity",
            display_name = "Antigravity",
            plan = "Google AI Pro",
            status = "ready",
            metrics = {
                { label = "Gemini", percent = 0, severity = "low", value = "0%" },
                { label = "Claude & GPT OSS", percent = 0, severity = "low", value = "0%" },
                { label = "Gemini", percent = 24, severity = "low", value = "24%" },
                { label = "Claude & GPT OSS", percent = 100, severity = "critical", value = "100%" },
            },
        },
    },
})
assert(containsGlyph(agyBar.rendered(), "brand-google"), "capsule should show Gemini brand glyph")
assert(containsGlyph(agyBar.rendered(), "asterisk-simple"), "capsule should show Claude brand glyph")
assert(glyphColor(agyBar.rendered(), "asterisk-simple") == "on_surface", "model glyph should remain neutral on_surface")
assert(containsText(agyBar.rendered(), "0%"), "capsule should show active session 0%")
local agyTooltip = agyBar.tooltip()
assert(#agyTooltip == 2, "antigravity tooltip should have 2 submodel rows")
assert(agyTooltip[1].key == "Gemini" and agyTooltip[1].value == "0% / 24%",
       "antigravity tooltip first row should be Gemini dual metrics")
assert(agyTooltip[2].key == "Claude" and agyTooltip[2].value == "0% / 100%",
       "antigravity tooltip second row should be Claude dual metrics")

local normalAgyBar = loadBar({
    vendor = "antigravity", account = "", extras = "none", visualization = "none",
}, {
    entries = {
        {
            id = "antigravity",
            display_name = "Antigravity",
            plan = "Google AI Pro",
            status = "ready",
            metrics = {
                { label = "Gemini", percent = 11, severity = "low", value = "11%" },
                { label = "Claude & GPT OSS", percent = 0, severity = "low", value = "0%" },
                { label = "Gemini", percent = 43, severity = "low", value = "43%" },
                { label = "Claude & GPT OSS", percent = 78, severity = "high", value = "78%" },
            },
        },
    },
})
assert(containsGlyph(normalAgyBar.rendered(), "brand-google"), "capsule should show Gemini brand glyph")
assert(containsGlyph(normalAgyBar.rendered(), "asterisk-simple"), "capsule should show Claude brand glyph")
assert(containsText(normalAgyBar.rendered(), "11%"), "capsule should show active session percentage (11%)")
assert(containsText(normalAgyBar.rendered(), "0%"), "capsule should show active session percentage (0%)")
assert(not containsText(normalAgyBar.rendered(), "78%"), "capsule should not stick to weekly percentage (78%)")

local countdownBar = loadBar({
    vendor = "antigravity", account = "", extras = "countdown", visualization = "none",
}, {
    entries = {
        {
            id = "antigravity",
            display_name = "Antigravity",
            plan = "Google AI Pro",
            status = "ready",
            metrics = {
                { label = "Gemini", percent = 64, reset_at = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() + 3240), severity = "low", value = "64%" },
                { label = "Claude & GPT OSS", percent = 69, reset_at = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() + 7200), severity = "low", value = "69%" },
            },
        },
    },
})
assert(containsText(countdownBar.rendered(), "54m"), "capsule should show Gemini countdown when extras=countdown")
assert(containsText(countdownBar.rendered(), "2h 0m"), "capsule should show Claude countdown when extras=countdown")
local countdownTooltip = countdownBar.tooltip()
assert(countdownTooltip[1].value == "64% · 0h 54m", "tooltip should show 0h 54m for minutes-only reset")
assert(countdownTooltip[2].value == "69% · 2h 00m", "tooltip should show fixed hours and minutes")

io.write("ok: account selection, unavailable providers, and a steady capsule\n")
