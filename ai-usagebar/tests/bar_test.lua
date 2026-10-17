-- Host harness for provider/account selection in bar.luau.

-- Keep exact countdown assertions independent of second boundaries during rendering.
local realTime = os.time
local os = setmetatable({
    time = function(date)
        if date ~= nil then return realTime(date) end
        return 1792166400
    end,
}, { __index = os })

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
    local watchers = {}
    local noctalia = {
        getConfig = function(key) return config[key] end,
        state = {
            get = function(key) return values[key] end,
            set = function(key, value) values[key] = value end,
            watch = function(key, callback) watchers[key] = callback end,
        },
        setUpdateInterval = function() end,
        togglePanel = function() end,
        tr = function(key, args)
            if key == "ui.reset" then return "Reset" end
            if key == "ui.hidden_value" then return tostring(args.count) .. " provider(s)" end
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
        isVertical = function() return config.vertical == true end,
    }
    local sharedEnv = setmetatable({ noctalia = noctalia, os = os }, { __index = _G })
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
        publish = function(nextReport)
            values.report = nextReport
            watchers.report(nextReport)
        end,
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

local function containsGlyph(node, wanted, color)
    if type(node) ~= "table" then return false end
    if type(node.props) == "table" and node.props.name == wanted
        and (color == nil or node.props.color == color) then return true end
    for _, child in ipairs(node.children or {}) do
        if containsGlyph(child, wanted, color) then return true end
    end
    return false
end

local agyFailureReport = { entries = { {
    id = "antigravity", status = "ready",
    metrics = { { label = "Gemini", percent = 40, window_secs = 18000 } },
} } }
local healthyModel = loadBar({ extras = "none" }, agyFailureReport)
local failedModel = loadBar({ extras = "none" }, agyFailureReport, { code = "timed_out", detail = "" })
assert(containsGlyph(healthyModel.rendered(), "brand-google", "on_surface"),
       "a healthy Antigravity model should keep its normal glyph color")
assert(containsGlyph(failedModel.rendered(), "brand-google", "error"),
       "a whole-report failure must flag the existing Antigravity model glyph")

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
assert(rejectedRows[1].key == "Codex" and #rejectedRows == 2,
       "a terminal provider should leave the bar immediately")

local pinnedDown = loadBar({
    vendor = "antigravity", account = "", extras = "none", visualization = "none",
}, { entries = { downEntry("antigravity", "Antigravity", 90) } })
local pinnedRow = pinnedDown.tooltip()[1]
assert(pinnedRow.key == "Antigravity"
    and pinnedRow.value == "ui.unavailable",
       "a down provider should give a short state; the panel keeps its diagnostic")
assert(not containsText(pinnedDown.rendered(), "90%"),
       "a pinned provider that is down must still withhold its reading")

local namedDown = loadBar({
    vendor = "openai", account = "work", extras = "none", visualization = "none",
}, { entries = { downEntry("openai@work", "Codex · work", 90) } })
assert(namedDown.tooltip()[1].key == "Codex · work",
       "a pinned named account should retain its own failure diagnostic")

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
                { label = "Codex 5h", percent = 0, reset_at = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() + 7200), severity = "low", value = "0%" },
                { label = "Codex weekly", percent = 100, reset_at = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() + 590400), severity = "critical", value = "100%" },
            },
        },
    },
})
assert(containsText(bottleneckBar.rendered(), "100%"),
       "capsule should show the 100% weekly bottleneck when session is 0%")
assert(not containsText(bottleneckBar.rendered(), "0%"),
       "capsule should not show 0% when weekly limit is 100%")
local bottleneckRows = bottleneckBar.tooltip()
assert(#bottleneckRows == 3
       and bottleneckRows[1].key == "Codex 5h" and bottleneckRows[1].value == "0% · 2h 00m"
       and bottleneckRows[2].key == "Codex 7d" and bottleneckRows[2].value == "100% · 6d 20h",
       "the tooltip shows each quota window with its own percentage and reset countdown")

local agyBar = loadBar({
    vendor = "antigravity", account = "", extras = "countdown", visualization = "none",
}, {
    entries = {
        {
            id = "antigravity",
            display_name = "Antigravity",
            plan = "Google AI Pro",
            status = "ready",
            metrics = {
                { label = "Gemini", percent = 11, reset_at = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() + 7200), severity = "low", value = "11%" },
                { label = "Claude & GPT OSS", percent = 0, reset_at = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() + 3600), severity = "low", value = "0%" },
                { label = "Gemini", percent = 24, severity = "low", value = "24%" },
                { label = "Claude & GPT OSS", percent = 100, reset_at = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() + 590400), severity = "critical", value = "100%" },
            },
        },
    },
})
assert(containsGlyph(agyBar.rendered(), "brand-google"), "capsule should show Gemini brand glyph")
assert(containsGlyph(agyBar.rendered(), "robot"), "capsule should show robot glyph for Claude & GPT OSS")
assert(glyphColor(agyBar.rendered(), "robot") == "on_surface", "model glyph should remain neutral on_surface")
assert(containsText(agyBar.rendered(), "11%"), "available model should keep its active session percentage")
assert(containsText(agyBar.rendered(), "100%"), "blocked model should show its exhausted long-window percentage")
assert(not containsText(agyBar.rendered(), "0%"), "blocked model should hide its irrelevant active session percentage")
assert(containsText(agyBar.rendered(), "6d 20h"), "blocked model should show its long-window unlock time")
local agyTooltip = agyBar.tooltip()
assert(#agyTooltip == 5, "each dual-window model gets 5h and 7d rows plus the mode row")
assert(agyTooltip[1].key == "Gemini 5h" and agyTooltip[1].value == "11% · 2h 00m"
       and agyTooltip[2].key == "Gemini 7d" and agyTooltip[2].value == "24%",
       "Gemini 5h and 7d quotas and resets are shown on their own rows")
assert(agyTooltip[3].key == "Claude & GPT OSS 5h" and agyTooltip[3].value == "0% · 1h 00m"
       and agyTooltip[4].key == "Claude & GPT OSS 7d" and agyTooltip[4].value == "100% · 6d 20h",
       "the full model name and both window resets survive without eliding")

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
assert(containsGlyph(normalAgyBar.rendered(), "robot"), "capsule should show robot glyph for Claude & GPT OSS")
assert(containsText(normalAgyBar.rendered(), "11%"), "capsule should show active session percentage (11%)")
assert(containsText(normalAgyBar.rendered(), "0%"), "capsule should show active session percentage (0%)")
assert(not containsText(normalAgyBar.rendered(), "78%"), "capsule should not stick to weekly percentage (78%)")
assert(#normalAgyBar.tooltip() == 5, "models without reset times keep one row per window plus mode")

local reorderedAgyBar = loadBar({ vendor = "antigravity", visualization = "gauge" }, { entries = {
    { id = "antigravity", display_name = "Antigravity", status = "ready", metrics = {
        { label = "Gemini", percent = 90, window_secs = 604800, severity = "high" },
        { label = "Gemini", percent = 20, window_secs = 18000, severity = "low" },
    } },
} })
assert(containsText(reorderedAgyBar.rendered(), "20%") and not containsText(reorderedAgyBar.rendered(), "90%"),
    "Antigravity capsule should show the session percentage when weekly arrives first")

local malformedGauge = loadBar({ vendor = "openai", visualization = "gauge" }, { entries = {
    { id = "openai", display_name = "Codex", status = "ready", metrics = { 42 } },
} })
assert(malformedGauge.rendered() ~= nil, "gauge should survive a non-table metric")

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
                { label = "Claude & GPT OSS", percent = 69, reset_at = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() + 83100), severity = "low", value = "69%" },
            },
        },
    },
})
assert(containsText(countdownBar.rendered(), "0h 54m"), "capsule should retain hours below one hour")
assert(containsText(countdownBar.rendered(), "23h 05m"), "capsule should show hours and minutes below 24 hours")
assert(containsText(countdownBar.rendered(), "·"), "capsule should show dot separator between submodels")
local countdownTooltip = countdownBar.tooltip()
assert(countdownTooltip[1].value == "64% · 0h 54m", "reset stays with the corresponding model")
assert(countdownTooltip[2].value == "69% · 23h 05m", "fixed hours and minutes stay visible")

io.write("ok: account selection, unavailable providers, and a steady capsule\n")
local parserFailure = loadBar({ vendor = "openai", extras = "countdown" }, { entries = {
    { id = "openai", display_name = "Codex", status = "error", metrics = {}, sections = {},
      error = "schema mismatch: openai usage response: invalid type: null" },
} })
assert(containsGlyph(parserFailure.rendered(), "brand-openai"), "Codex must remain identifiable when its parser fails")
assert(containsText(parserFailure.rendered(), "—"), "a parser failure must show missing data, not zero usage")

local resetSoon = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() + 7200)
local resetLater = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() + 590400)
local quotaEntry = entry("openai", "Codex", 100)
quotaEntry.metrics = {
    { label = "Gemini", percent = 100, severity = "critical", reset_at = resetSoon },
    { label = "Gemini", percent = 100, severity = "critical", reset_at = resetLater },
}
local bothBlocked = loadBar({ vendor = "openai", extras = "countdown" }, { entries = { quotaEntry } })
assert(containsText(bothBlocked.rendered(), "6d 20h"), "two exhausted quotas must display the later reset")
assert(bothBlocked.tooltip()[1].value == "100% · 2h 00m"
    and bothBlocked.tooltip()[2].value == "100% · 6d 20h",
    "tooltip shows each exhausted window's own reset")
quotaEntry.id = "antigravity"
quotaEntry.metrics[1].percent = 0
local singleModel = loadBar({ vendor = "antigravity" }, { entries = { quotaEntry } })
assert(containsText(singleModel.rendered(), "100%"), "a single Antigravity model must show weekly exhaustion")
quotaEntry.metrics[#quotaEntry.metrics + 1] = { label = "Claude & GPT OSS", percent = 95, severity = "critical" }
local hiddenGlyphs = loadBar({ vendor = "antigravity", show_glyph = false }, { entries = { quotaEntry } })
assert(not containsGlyph(hiddenGlyphs.rendered(), "brand-google") and not containsGlyph(hiddenGlyphs.rendered(), "robot"),
       "show_glyph=false must hide every model glyph")
local function findNode(node, predicate)
    if predicate(node) then return node end
    for _, child in ipairs(node.children or {}) do
        local found = findNode(child, predicate)
        if found then return found end
    end
end
local uncolored = loadBar({ vendor = "antigravity", color_by_usage = false }, { entries = { quotaEntry } })
assert(findNode(uncolored.rendered(), function(n) return n.props.text == "100%" end).props.color == "on_surface",
       "color_by_usage=false must suppress exhausted model tint")
local after = loadBar({ vendor = "antigravity", glyph_position = "after", extras = "none", visualization = "none" }, { entries = { quotaEntry } })
local modelRow = findNode(after.rendered(), function(n)
    return n.kind == "row" and n.children[1] and n.children[1].props.text == "100%"
end)
assert(modelRow and modelRow.children[#modelRow.children].props.name == "brand-google",
       "glyph_position=after must place the model glyph after its reading")
local afterGauge = loadBar({ vendor = "antigravity", glyph_position = "after", extras = "none" }, { entries = { quotaEntry } })
local gaugeRow = findNode(afterGauge.rendered(), function(n)
    return n.kind == "row" and n.children[#n.children] and n.children[#n.children].props.name == "brand-google"
end)
assert(gaugeRow and gaugeRow.children[1].kind == "column" and gaugeRow.children[2].props.text == "100%",
       "moving the model glyph must preserve the gauge-before-value layout used by other providers")
local poolReport = { entries = { {
    id = "antigravity", display_name = "Antigravity", status = "ready",
    metrics = {
        { label = "Gemini", percent = 10 },
        { label = "Gemini 4 Argon", percent = 35, model_pool = true },
    },
} } }
local namedPools = loadBar({ vendor = "antigravity", show_name = true }, poolReport)
assert(containsText(namedPools.rendered(), "Gemini") and not containsText(namedPools.rendered(), "Gemini 4 Argon"),
       "a model pool stays under its family in the panel, without a separate bar reading")
assert(containsText(namedPools.rendered(), "10%") and not containsText(namedPools.rendered(), "35%"),
       "the Gemini reading must retain its shared quota")
assert(not containsText(namedPools.rendered(), "Antigravity"), "model names replace the aggregate provider name")
local quietPools = loadBar({ vendor = "antigravity", show_name = false }, poolReport)
assert(not containsText(quietPools.rendered(), "Gemini") and not containsText(quietPools.rendered(), "Gemini 4 Argon"),
       "model names stay hidden by default")
local verticalPools = loadBar({ vendor = "antigravity", show_name = true, vertical = true }, poolReport)
assert(not containsText(verticalPools.rendered(), "Gemini 4 Argon"), "model names must not widen a vertical bar")
assert(namedPools.tooltip()[2].key == "Gemini 4 Argon", "the tooltip preserves the full model pool name")
local poolEntry = poolReport.entries[1]
poolEntry.metrics[2].percent = 100
poolEntry.metrics[2].severity = "critical"
poolEntry.metrics[2].reset_at = resetLater
poolEntry.metrics[1].reset_at = resetSoon
local blockedPool = loadBar({ vendor = "antigravity", extras = "countdown" }, poolReport)
assert(containsText(blockedPool.rendered(), "10%") and containsText(blockedPool.rendered(), "2h 00m"),
       "an exhausted model pool must not replace the Gemini quota or reset")
assert(not containsText(blockedPool.rendered(), "100%") and not containsText(blockedPool.rendered(), "6d 20h"),
       "model pool exhaustion must not add a bar reading")
assert(blockedPool.tooltip()[2].key == "Gemini 4 Argon" and blockedPool.tooltip()[2].value == "100% · 6d 20h",
       "an exhausted pool remains available in the tooltip")
local poolWindow = loadBar({ vendor = "antigravity", quota_window = "weekly" }, poolReport)
assert(containsText(poolWindow.rendered(), "—") and not containsText(poolWindow.rendered(), "100%"),
       "a pool cannot substitute for a missing shared quota window")
poolEntry.metrics[3] = { label = "Claude & GPT OSS", percent = 25 }
local sharedFamilies = loadBar({ vendor = "antigravity", show_name = true }, poolReport)
assert(containsText(sharedFamilies.rendered(), "Gemini") and containsText(sharedFamilies.rendered(), "10%")
       and containsText(sharedFamilies.rendered(), "Claude & GPT OSS") and containsText(sharedFamilies.rendered(), "25%")
       and not containsText(sharedFamilies.rendered(), "100%"),
       "hiding a pool must preserve both shared family readings")
local poolOnly = { id = "antigravity", status = "ready", metrics = { poolEntry.metrics[2] } }
local onlyPool = loadBar({ vendor = "antigravity", show_name = true }, { entries = { poolOnly } })
assert(containsText(onlyPool.rendered(), "—") and not containsText(onlyPool.rendered(), "100%")
       and not containsText(onlyPool.rendered(), "Gemini 4 Argon"),
       "pool-only reports must not invent a shared quota or standalone model reading")
local autoPool = loadBar({ extras = "none" }, {
    entries = { poolOnly, entry("openai", "Codex", 30) },
})
assert(containsGlyph(autoPool.rendered(), "brand-openai"),
       "an exhausted model-only quota must not rank Antigravity as globally exhausted")

local iconOnly = loadBar({ vendor = "antigravity", show_value = false, extras = "none" }, { entries = { quotaEntry } })
assert(containsGlyph(iconOnly.rendered(), "brand-google") and not containsText(iconOnly.rendered(), "100%"),
       "show_value=false must preserve enabled model glyphs")
local quietFailure = loadBar({ vendor = "openai", show_glyph = false }, parserFailure.values.report)
assert(containsText(quietFailure.rendered(), "—"), "hidden glyph must not create a hole before the parser error label")

local vertBar = loadBar({ vendor = "openai", vertical = true }, { entries = { quotaEntry } })
assert(vertBar.rendered().kind == "column", "vertical bar must render a column")

for _, provider in ipairs({ "openai", "antigravity" }) do
    for _, stale in ipairs({ false, true }) do
        for _, showGlyph in ipairs({ false, true }) do
            for _, position in ipairs({ "before", "after" }) do
                local reading = entry(provider, provider, 40)
                reading.stale = stale
                if provider == "antigravity" then
                    reading.metrics = {
                        { label = "Gemini", percent = 40, window_secs = 18000 },
                        { label = "Claude & GPT OSS", percent = 20, window_secs = 18000 },
                    }
                end
                local vertical = loadBar({
                    vendor = provider, vertical = true, extras = "none",
                    show_glyph = showGlyph, glyph_position = position,
                }, { entries = { reading } })
                assert(containsGlyph(vertical.rendered(), "clock-exclamation", "secondary") == stale,
                       "vertical stale indicator must follow reading age, independently of provider glyph settings")
                assert(containsText(vertical.rendered(), "40%"),
                       "vertical stale readings must retain their cached percentage")
                local expectedGlyph = provider == "antigravity" and "brand-google" or "brand-openai"
                assert(containsGlyph(vertical.rendered(), expectedGlyph) == showGlyph,
                       "vertical provider and model glyphs must respect show_glyph")
                if provider == "antigravity" then
                    assert(containsGlyph(vertical.rendered(), "robot") == showGlyph,
                           "vertical secondary model glyph must respect show_glyph")
                end
            end
        end
    end
end

local multiReport = {
    entries = {
        entry("openai", "Codex", 50),
        entry("anthropic", "Claude", 20),
    }
}
local scrollBar = loadBar({ vendor = "auto" }, multiReport)
assert(containsText(scrollBar.rendered(), "50%"), "initial auto shows first entry")
scrollBar.env.onScroll("vertical", 1, true)
assert(containsText(scrollBar.rendered(), "20%"), "scrolling down rotates to next entry")
scrollBar.publish({ entries = {
    entry("openai", "Codex", 50),
    entry("anthropic", "Claude", 90),
} })
assert(containsText(scrollBar.rendered(), "90%"),
       "refresh should preserve the selected provider even when usage reorders it")
scrollBar.env.onScroll("vertical", -1, true)
assert(containsText(scrollBar.rendered(), "50%"), "scrolling up returns to first entry")

local vertGaugeBar = loadBar({ vendor = "openai", vertical = true, visualization = "gauge" }, { entries = { entry("openai", "Codex", 65) } })
local miniGaugeNode = findNode(vertGaugeBar.rendered(), function(n) return n.props.key == "mini-gauge" end)
assert(miniGaugeNode ~= nil, "vertical bar with gauge visualization should render mini-gauge")

local fastEntry = entry("openai", "Codex", 80)
fastEntry.metrics[1].detail = "Resets in 4h 00m · 20% elapsed · 60pts ahead"
local pacingBar = loadBar({ vendor = "openai", extras = "none" }, { entries = { fastEntry } })
assert(not containsGlyph(pacingBar.rendered(), "arrow-up"), "extras=none should not add an unexplained pace arrow")

local function findAllNodes(node, predicate, acc)
    acc = acc or {}
    if type(node) ~= "table" then return acc end
    if predicate(node) then acc[#acc + 1] = node end
    for _, child in ipairs(node.children or {}) do
        findAllNodes(child, predicate, acc)
    end
    return acc
end

local dualBarTest = loadBar({ vendor = "openai", visualization = "gauge" }, {
    entries = {
        {
            id = "openai",
            display_name = "Codex",
            status = "ready",
            metrics = {
                { label = "Codex 5h", percent = 10, window_secs = 18000 },
                { label = "Codex weekly", percent = 95, window_secs = 604800 },
            },
        },
    },
})
local progressBars = findAllNodes(dualBarTest.rendered(), function(n) return n.kind == "progress" end)
assert(#progressBars == 2, "dual metric provider should render 2 progress bars")
assert(progressBars[1].props.height == 6 and progressBars[1].props.progress == 0.10,
       "top bar must be the 5h limit with height 6")
assert(progressBars[2].props.height == 3 and progressBars[2].props.progress == 0.95,
       "bottom bar must be the weekly limit with height 3")

local agyDualBar = loadBar({ vendor = "antigravity", visualization = "gauge" }, {
    entries = {
        {
            id = "antigravity",
            display_name = "Antigravity",
            status = "ready",
            metrics = {
                { label = "Gemini", percent = 15, window_secs = 18000 },
                { label = "Claude & GPT OSS", percent = 40, window_secs = 18000 },
                { label = "Gemini", percent = 80, window_secs = 604800 },
                { label = "Claude & GPT OSS", percent = 100, window_secs = 604800 },
            },
        },
    },
})
local agyBars = findAllNodes(agyDualBar.rendered(), function(n) return n.kind == "progress" end)
assert(#agyBars == 4, "antigravity with 2 models should render 4 progress bars (2 per model)")
assert(agyBars[1].props.height == 6 and agyBars[1].props.progress == 0.15, "Gemini top bar is 5h")
assert(agyBars[2].props.height == 3 and agyBars[2].props.progress == 0.80, "Gemini bottom bar is weekly")
assert(agyBars[3].props.height == 6 and agyBars[3].props.progress == 0.40, "Claude top bar is 5h")
assert(agyBars[4].props.height == 3 and agyBars[4].props.progress == 1.0, "Claude bottom bar is weekly")

-- A balance-only provider has no percentage to draw: the capsule prints its
-- balance where a quota vendor prints a percentage, and keeps its identity mark.
local balanceBar = loadBar({ vendor = "deepseek", extras = "countdown", visualization = "gauge" }, {
    entries = {
        { id = "deepseek", display_name = "DeepSeek", plan = "DeepSeek", status = "ready",
          metrics = {}, sections = {
            { type = "text", label = "Balance", value = "$2.90" },
        } },
    },
})
assert(containsGlyph(balanceBar.rendered(), "fish"), "a balance provider keeps its provider mark")
assert(containsText(balanceBar.rendered(), "$2.90"), "a balance-only provider should show its balance")
assert(not containsText(balanceBar.rendered(), "—"),
    "a balance-only provider should not fall back to the missing-data dash")

local nousBalanceBar = loadBar({ vendor = "nous", extras = "none", visualization = "none" }, {
    entries = {
        { id = "nous", display_name = "Nous Research", status = "ready", metrics = {}, sections = {
            { type = "text", label = "Subscription credits", value = "0.00 remaining" },
            { type = "text", label = "Total usable credits", value = "8.19" },
            { type = "text", label = "Renews", value = "25d 20h" },
        } },
    },
})
assert(containsText(nousBalanceBar.rendered(), "8.19"),
    "the capsule should prefer the usable total over zero credits or the renewal")
assert(not containsText(nousBalanceBar.rendered(), "0.00 remaining"),
    "subscription credits should not win when a total is present")

-- The tooltip must agree with the capsule: a balance provider's hover shows the
-- same figure, not its plan name and not a no-usage line.
local balanceRows = balanceBar.tooltip()
assert(#balanceRows == 1 and balanceRows[1].key == "DeepSeek" and balanceRows[1].value == "$2.90",
    "a balance provider's tooltip should show its balance where the capsule does")
local nousRows = nousBalanceBar.tooltip()
assert(#nousRows == 1 and nousRows[1].key == "Nous Research" and nousRows[1].value == "8.19",
    "a balance provider's tooltip should not report no usage")


local threeWindows = { id = "opencode-go", display_name = "Go", status = "ready", metrics = {
    { label = "Session", percent = 20, window_secs = 18000, severity = "low" },
    { label = "Weekly", percent = 60, window_secs = 604800, severity = "high" },
    { label = "Monthly", percent = 80, window_secs = 2592000, severity = "high" },
} }
local pinnedMonth = loadBar({ vendor = "opencode-go", quota_window = "monthly", usage_display = "remaining" }, { entries = { threeWindows } })
assert(containsText(pinnedMonth.rendered(), "20%"), "monthly remaining must use the actual monthly quota")
local pinnedBars = findAllNodes(pinnedMonth.rendered(), function(n) return n.kind == "progress" end)
assert(#pinnedBars == 1 and pinnedBars[1].props.progress == 0.2, "pin renders one matching remaining bar")
local absentMonth = loadBar({ vendor = "openai", quota_window = "monthly", usage_display = "remaining" }, { entries = { entry("openai", "Codex", 25) } })
assert(containsText(absentMonth.rendered(), "—"), "missing pinned quota must show dash")
assert(#findAllNodes(absentMonth.rendered(), function(n) return n.kind == "progress" end) == 0, "missing pinned quota has no gauge")
local subsetReport = { entries = { entry("openai@work", "Work", 90), entry("openai@home", "Home", 70), entry("anthropic", "Claude", 99) } }
local subset = loadBar({ auto_providers = { "openai@home" } }, subsetReport)
assert(subset.tooltip()[1].key == "Home", "exact account filter must exclude other accounts")
subset.env.onScroll("vertical", 1, true)
assert(subset.tooltip()[1].key == "Home", "scroll stays within automatic subset")
local providerSubset = loadBar({ auto_providers = { "openai" }, provider_limit = 4 }, subsetReport)
assert(providerSubset.tooltip()[1].key == "Work" and providerSubset.tooltip()[2].key == "Home", "base provider includes all its accounts")
local invalidSubset = loadBar({ auto_providers = { false, 42, "unknown" } }, subsetReport)
assert(not containsText(invalidSubset.rendered(), "99%"), "invalid nonempty filter must never include all providers")
local remainingAuto = loadBar({ usage_display = "remaining" }, subsetReport)
assert(remainingAuto.tooltip()[1].key == "Claude" and containsText(remainingAuto.rendered(), "1%"), "remaining must preserve consumed ranking")
local remainingBalance = loadBar({ vendor = "deepseek", quota_window = "monthly", usage_display = "remaining" }, { entries = {
    { id = "deepseek", status = "ready", metrics = {}, sections = { { type = "text", label = "Balance", value = "$2.90" } } },
} })
assert(containsText(remainingBalance.rendered(), "$2.90"), "window and direction settings must preserve balances")

assert(pinnedMonth.tooltip()[1].value == "Monthly: 20%", "pinned tooltip identifies actual quota and direction")
assert(pinnedMonth.tooltip()[#pinnedMonth.tooltip()].key == "ui.remaining", "tooltip explicitly names remaining mode")
assert(absentMonth.tooltip()[1].value == "ui.window_unavailable", "tooltip explains an absent pinned window")
local blockedPinEntry = { id = "openai", status = "ready", metrics = {
    { label = "Session", percent = 20, window_secs = 18000 },
    { label = "Weekly", percent = 100, severity = "critical", window_secs = 604800, reset_at = "2026-10-23T12:00:00Z" },
    { label = "Monthly", percent = 100, severity = "critical", window_secs = 2592000, reset_at = "2026-10-26T12:00:00Z" },
} }
local blockedPin = loadBar({ vendor = "openai", quota_window = "session", usage_display = "remaining" }, { entries = { blockedPinEntry } })
assert(containsText(blockedPin.rendered(), "0%"), "pinned session cannot hide exhausted long quota")
assert(blockedPin.tooltip()[1].value:find("Monthly: 0% · ", 1, true) == 1, "latest exhausted window overrides pin in tooltip")
local blockedBars = findAllNodes(blockedPin.rendered(), function(n) return n.kind == "progress" end)
assert(#blockedBars == 1 and blockedBars[1].props.progress == 0 and blockedBars[1].props.fill == "error", "zero remaining keeps exhausted consumption severity")
local agyPin = loadBar({ vendor = "antigravity", quota_window = "session", usage_display = "remaining" }, { entries = {
    { id = "antigravity", status = "ready", metrics = {
        { label = "Gemini", percent = 90, window_secs = 604800 },
        { label = "Claude", percent = 100, severity = "critical", window_secs = 604800 },
        { label = "Gemini", percent = 30, window_secs = 18000 },
        { label = "Claude", percent = 10, window_secs = 18000 },
    } },
} })
assert(containsText(agyPin.rendered(), "70%") and containsText(agyPin.rendered(), "0%"), "AGY selects session and blocking quota independently per model")
local agyPinnedBars = findAllNodes(agyPin.rendered(), function(n) return n.kind == "progress" end)
assert(#agyPinnedBars == 2 and agyPinnedBars[1].props.progress == 0.7 and agyPinnedBars[2].props.progress == 0, "AGY pin draws one remaining gauge per model")
local agyMissing = loadBar({ vendor = "antigravity", quota_window = "monthly", usage_display = "remaining" }, { entries = {
    { id = "antigravity", status = "ready", metrics = { { label = "Gemini", percent = 20, window_secs = 18000 } } },
} })
assert(containsText(agyMissing.rendered(), "—"), "AGY absent pinned quota never becomes zero or 100 remaining")
local invalidPercent = loadBar({ vendor = "antigravity", usage_display = "remaining" }, { entries = {
    { id = "antigravity", status = "ready", metrics = { { label = "Gemini", window_secs = 18000 } } },
} })
assert(containsText(invalidPercent.rendered(), "—"), "AGY missing percent must remain unknown")
local inverseAuto = loadBar({ vendor = "opencode-go", usage_display = "remaining" }, { entries = { threeWindows } })
local inverseBars = findAllNodes(inverseAuto.rendered(), function(n) return n.kind == "progress" end)
assert(#inverseBars == 2 and inverseBars[1].props.progress == 0.8 and inverseBars[2].props.progress == 0.4, "automatic gauges invert both windows")
assert(inverseBars[2].props.fill == "secondary", "remaining bars retain consumed severity")
local verticalRemaining = loadBar({ vendor = "opencode-go", quota_window = "weekly", usage_display = "remaining", vertical = true }, { entries = { threeWindows } })
assert(containsText(verticalRemaining.rendered(), "40%"), "vertical capsule applies remaining to its number")
local verticalLevel = findNode(verticalRemaining.rendered(), function(n) return n.props.key == "level" end)
assert(verticalLevel ~= nil and verticalLevel.props.height == 6, "vertical remaining gauge uses selected quota")
local pinnedIgnoresFilter = loadBar({ vendor = "anthropic", auto_providers = { "openai" } }, subsetReport)
assert(containsText(pinnedIgnoresFilter.rendered(), "99%"), "automatic filter cannot hide explicit provider pin")
local emptySubset = loadBar({ auto_providers = {} }, subsetReport)
assert(containsText(emptySubset.rendered(), "99%"), "empty automatic filter preserves all providers")
local subsetHidden = loadBar({ auto_providers = { "openai" }, provider_limit = 2 }, subsetReport)
assert(not containsText(subsetHidden.rendered(), "+1"), "hidden count excludes providers outside subset")

local unmatchedFilter = loadBar({ vendor = "auto", auto_providers = { "missing-provider" } }, namedReport)
assert(unmatchedFilter.tooltip()[1].value == "ui.no_matching_providers",
    "an unmatched automatic filter should explain the empty selection")

local amountEntry = entry("custom", "Custom credits", 75)
amountEntry.brand = "openai"
amountEntry.metrics[1].headline = "value"
amountEntry.metrics[1].value = "$12.50"
for _, mode in ipairs({ "used", "remaining" }) do
    local amountBar = loadBar({ vendor = "custom", quota_window = "session", usage_display = mode, visualization = "none" },
        { entries = { amountEntry } })
    assert(containsText(amountBar.rendered(), "$12.50") and not containsText(amountBar.rendered(), "75%"),
        "bar amount headlines preserve the reported currency in " .. mode .. " mode")
    assert(findNode(amountBar.rendered(), function(node)
        return node.kind == "glyph" and node.props.name == "brand-openai"
    end), "a custom bar entry can use its known local brand mark")
end
amountEntry.metrics[1].value = nil
local missingAmount = loadBar({ vendor = "custom", visualization = "none" }, { entries = { amountEntry } })
assert(containsText(missingAmount.rendered(), "—") and not containsText(missingAmount.rendered(), "75%"),
    "a missing amount does not substitute a believable percentage")

-- Tooltips summarize the capsule; the panel owns the full report.
local crowdedEntries = {}
for i = 1, 4 do
    local accountEntry = entry("antigravity@account" .. i, "Antigravity · conta " .. i, 80 - i)
    accountEntry.metrics = {
        { label = "Gemini", percent = 80 - i, window_secs = 18000, reset_at = resetSoon },
        { label = "Gemini 4 Argon", percent = 35, model_pool = true, window_secs = 604800 },
        { label = "Claude & GPT OSS", percent = 20, window_secs = 18000 },
    }
    crowdedEntries[#crowdedEntries + 1] = accountEntry
end
crowdedEntries[#crowdedEntries + 1] = entry("openai", "Codex", 10)
local crowded = loadBar({ provider_limit = 4, usage_display = "remaining" }, { entries = crowdedEntries })
local crowdedRows = crowded.tooltip()
assert(#crowdedRows == 10, "the ten-row budget includes readings, mode, hidden providers and the panel hint")
assert(crowdedRows[1].key == "Antigravity · conta 1 · Gemini"
    and crowdedRows[1].value == "21% · 2h 00m", "named accounts and remaining mode survive compaction")
assert(crowdedRows[2].key == "Antigravity · conta 1 · Gemini 4 Argon",
    "model pool details remain in the hover when there is room")
assert(crowdedRows[8].key == "ui.remaining" and crowdedRows[8].value == "settings.quota_window.option.auto",
    "the mode and selected window are never displaced by model rows")
assert(crowdedRows[9].key == "ui.hidden_label" and crowdedRows[9].value == "1 provider(s)",
    "hidden counts providers outside the capsule, not omitted model rows")
assert(crowdedRows[10].value == "ui.tooltip_more", "overflow directs the user to the full panel")

local codexAndAgy = loadBar({ provider_limit = 2 }, {
    entries = {
        {
            id = "openai",
            display_name = "Codex",
            status = "ready",
            metrics = {
                { label = "Codex 5h", percent = 94, window_secs = 18000, reset_at = resetSoon, severity = "high" },
                { label = "Codex weekly", percent = 15, window_secs = 604800, reset_at = resetLater, severity = "low" },
            },
        },
        {
            id = "antigravity",
            display_name = "Antigravity",
            status = "ready",
            metrics = {
                { label = "Gemini", percent = 0, window_secs = 18000, reset_at = resetSoon, severity = "low" },
                { label = "Gemini", percent = 0, window_secs = 604800, reset_at = resetLater, severity = "low" },
                { label = "Claude & GPT OSS", percent = 0, window_secs = 18000, reset_at = resetSoon, severity = "low" },
                { label = "Claude & GPT OSS", percent = 0, window_secs = 604800, reset_at = resetLater, severity = "low" },
                { label = "Gemini 4 Argon", percent = 2, model_pool = true, window_secs = 604800, reset_at = resetLater, severity = "low" },
            },
        },
    },
})
local codexAndAgyRows = codexAndAgy.tooltip()
assert(#codexAndAgyRows == 8,
    "Codex and Antigravity dual windows plus pool and mode fit without dropping models")
assert(codexAndAgyRows[1].key == "Codex 5h" and codexAndAgyRows[1].value == "94% · 2h 00m"
    and codexAndAgyRows[2].key == "Codex 7d" and codexAndAgyRows[2].value == "15% · 6d 20h"
    and codexAndAgyRows[3].key == "Gemini 5h" and codexAndAgyRows[3].value == "0% · 2h 00m"
    and codexAndAgyRows[4].key == "Gemini 7d" and codexAndAgyRows[4].value == "0% · 6d 20h"
    and codexAndAgyRows[5].key == "Claude & GPT OSS 5h" and codexAndAgyRows[5].value == "0% · 2h 00m"
    and codexAndAgyRows[6].key == "Claude & GPT OSS 7d" and codexAndAgyRows[6].value == "0% · 6d 20h"
    and codexAndAgyRows[7].key == "Gemini 4 Argon" and codexAndAgyRows[7].value == "2% · 6d 20h",
    "every window and model pool displays its own percentage and reset countdown")
for i = 1, 7 do
    assert(#codexAndAgyRows[i].key <= 19 and #codexAndAgyRows[i].value <= 14,
        "reading rows stay within Noctalia's non-truncating peer column budget")
end

local ordinary = loadBar({ provider_limit = 4 }, { entries = {
    entry("openai", "Codex", 80), entry("claude", "Claude", 70),
    entry("cursor", "Cursor", 60), entry("amp", "Amp", 50),
} })
assert(#ordinary.tooltip() == 5 and ordinary.tooltip()[4].key == "Amp",
    "four simple providers remain visible together with their mode")

local rawError = string.rep("sensitive raw diagnostic\n", 200)
local failed = loadBar({}, nil, { code = "cli_failed", detail = rawError })
assert(#failed.tooltip() == 2 and failed.tooltip()[1].value == "ui.error.cli_failed"
    and failed.tooltip()[2].value == "ui.tooltip_more", "global raw errors stay out of the hover")
local accountError = entry("openai", "Codex", 50)
accountError.status, accountError.error = "error", rawError
local failedAccount = loadBar({ vendor = "openai" }, { entries = { accountError } })
for _, row in ipairs(failedAccount.tooltip()) do
    assert(not row.value:find("sensitive", 1, true), "account diagnostics are also kept in the panel")
end

local unicodeAccount = entry("openai@ação", "  Codex\n·\tAção 日本語  ", 30)
local unicodeBar = loadBar({ vendor = "openai", account = "ação" }, { entries = { unicodeAccount } })
assert(unicodeBar.tooltip()[1].key == "Codex · Ação 日本語", "whitespace normalization preserves full Unicode names")
for _, row in ipairs(unicodeBar.tooltip()) do
    assert(not row.key:find("[\n\r\t]") and not row.value:find("[\n\r\t]"), "each structured row occupies one line")
end

amountEntry.metrics[1].value = "€12.50"
for _, mode in ipairs({ "used", "remaining" }) do
    local amountHover = loadBar({ vendor = "custom", usage_display = mode }, { entries = { amountEntry } })
    assert(amountHover.tooltip()[1].value == "€12.50", "tooltip honors monetary headlines in either display mode")
end
