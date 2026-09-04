-- Host harness for malformed collection handling in panel.luau.

local function read(path)
    local file = assert(io.open(path, "r"))
    local source = file:read("*a")
    file:close()
    return source
end

local function loadPanel(entry, failure)
    local watchers = {}
    local isReport = type(entry) == "table" and type(entry.entries) == "table"
    local report = isReport and entry or entry ~= nil and { entries = { entry } } or nil
    local first = report ~= nil and report.entries[1] or nil
    local values = {
        report = report,
        error = failure or { code = "", detail = "" },
        selected = isReport and entry.selected or first ~= nil and first.id or nil,
    }
    local noctalia = {
        state = {
            get = function(key) return values[key] end,
            set = function(key, value) values[key] = value end,
            watch = function(key, fn) watchers[key] = fn end,
        },
        commandExists = function() return false end,
        nowMs = function() return 1000 end,
            -- The host substitutes; the harness only needs the key back to assert on.
        tr = function(key) return key end,
        string = {
            trim = function(value) return tostring(value):match("^%s*(.-)%s*$") end,
        },
        formatTime = function() return "12:00" end,
        timeFormat = function() return "%H:%M" end,
    }
    local ui = setmetatable({}, {
        __index = function(_, kind)
            return function(props, children)
                return { kind = kind, props = props or {}, children = children or {} }
            end
        end,
    })
    local drawn = nil
    local panel = {
        render = function(tree) drawn = tree end,
        setWantsSecondTicks = function() end,
    }
    local sharedEnv = setmetatable({ noctalia = noctalia }, { __index = _G })
    local shared = assert(load(read("shared.luau"), "shared", "t", sharedEnv))()
    local env = setmetatable({
        noctalia = noctalia,
        ui = ui,
        panel = panel,
        require = function(path)
            assert(path == "./shared.luau")
            return shared
        end,
    }, { __index = _G })
    assert(load(read("panel.luau"), "panel", "t", env))()
    env.onOpen()
    -- Publishing a second report exercises what the panel carries between reads.
    local function publish(nextEntry)
        values.report = { entries = { nextEntry } }
        values.selected = nextEntry.id
        watchers.report(values.report)
        return drawn
    end
    return drawn, publish
end

-- Walk the drawn tree; the harness records every ui.* call as {kind, props, children}.
local function collect(node, kind, found)
    found = found or {}
    if type(node) ~= "table" then return found end
    if node.kind == kind then found[#found + 1] = node end
    for _, child in ipairs(node.children or {}) do collect(child, kind, found) end
    for _, child in ipairs(node) do collect(child, kind, found) end
    return found
end

local function labels(node)
    local out = {}
    for _, label in ipairs(collect(node, "label")) do out[#out + 1] = tostring(label.props.text or "") end
    return out
end

local function has(list, wanted)
    for _, value in ipairs(list) do if value == wanted then return true end end
    return false
end

local malformedSections = {
    id = "openai",
    display_name = "Codex",
    plan = "Plan",
    status = "ready",
    metrics = {},
    sections = 42,
}
local sectionsOk = pcall(loadPanel, malformedSections)
assert(sectionsOk, "malformed sections should render as no usage")

local malformedSectionEntry = {
    id = "openai",
    display_name = "Codex",
    plan = "Plan",
    status = "ready",
    metrics = {},
    sections = { 42 },
}
local sectionEntryOk = pcall(loadPanel, malformedSectionEntry)
assert(sectionEntryOk, "malformed section entries should be ignored")

local malformedBody = {
    id = "openai",
    display_name = "Codex",
    plan = "Plan",
    status = "ready",
    metrics = {},
    sections = { { type = "block", label = "Credits", body = 42 } },
}
local bodyOk = pcall(loadPanel, malformedBody)
assert(bodyOk, "malformed block body should render as an empty block")

local rejectedProvider = {
    id = "anthropic",
    display_name = "Claude",
    plan = "Claude Pro",
    status = "ready",
    metrics = {},
    sections = {
        { type = "text", label = "HTTP 403", value = "authentication rejected" },
    },
}
local rejectedLabels = labels(loadPanel(rejectedProvider))
assert(not has(rejectedLabels, "Claude"),
       "a terminal provider should leave the panel immediately")

-- Antigravity reports each model once per window, under "Session"/"Weekly"
-- headings the CLI sends as text sections with no value. Claude and Codex send
-- neither.
local WINDOWS = {
    { type = "spacer" },
    { type = "text", label = "Session", value = "" },
    { type = "spacer" },
    { type = "metric", label = "Gemini", percent = 3, value = "3%",
      detail = "Resets in 0h 01m" },
    { type = "metric", label = "Claude & GPT OSS", percent = 0, value = "0%",
      detail = "Resets in 1h 41m" },
    { type = "spacer" },
    { type = "text", label = "Weekly", value = "" },
    { type = "spacer" },
    { type = "metric", label = "Gemini", percent = 8, value = "8%",
      detail = "Resets in 3d 19h" },
    { type = "metric", label = "Claude & GPT OSS", percent = 0, value = "0%",
      detail = "Resets in 6d 20h" },
}

local function withSections(sections, plan)
    local copy = {}
    for index, section in ipairs(sections) do copy[index] = section end
    return {
        id = "antigravity",
        display_name = "Antigravity",
        plan = plan or "Google AI Pro",
        status = "ready",
        metrics = {},
        -- Dated well in the past: the header only dates a report it has a stamp
        -- for, so leaving this out would let the header's own assertions pass by
        -- never drawing the line they are about.
        fetched_at = "2020-01-01T00:00:00Z",
        sections = copy,
    }
end

-- The cards that gauge. Every card in the panel is filled the same way, so what
-- tells a reading's card from a record of one is the bar inside it.
local function cards(node)
    local out = {}
    for _, column in ipairs(collect(node, "column")) do
        if column.props.fill == "surface_variant/0.40" and #collect(column, "progress") > 0 then
            out[#out + 1] = column
        end
    end
    return out
end

local tree = loadPanel(withSections(WINDOWS))

-- One card per model, not one per reading: four readings, two models, two cards.
local drawn = cards(tree)
assert(#drawn == 2, "each model gets a card, its windows stacked inside")
local first = labels(drawn[1])
assert(first[1] == "Gemini", "the card is titled with the model")
assert(has(first, "Session") and has(first, "Weekly"), "both windows live in it")
assert(has(labels(drawn[2]), "Claude & GPT OSS"), "the second model follows below")
local geminiTitles = 0
for _, card in ipairs(drawn) do
    if labels(card)[1] == "Gemini" then geminiTitles = geminiTitles + 1 end
end
assert(geminiTitles == 1, "the model is named once")

-- The windows of one model are divided the same way readings of equal weight are.
for _, card in ipairs(drawn) do
    local ruled = false
    for _, child in ipairs(card.children) do
        if child.kind == "box" then ruled = true end
    end
    assert(ruled, "the two windows of a model are ruled apart")
end

-- A reading the CLI dated with nothing but a reset takes the room it needs.
for _, card in ipairs(drawn) do
    for _, child in ipairs(card.children) do
        -- 4 is the breath around the rule; anything taller would be room held open
        -- for a reading the CLI never sent.
        assert(child.kind ~= "spacer" or (tonumber(child.props.height) or 0) <= 4,
               "no height is held open for readings the CLI did not send")
    end
end

-- A provider with its own failure leaves the panel until it reports healthy.
local DOWN = {}
for index, section in ipairs(WINDOWS) do DOWN[index] = section end
DOWN[#DOWN + 1] = { type = "text", label = "Warning",
                    value = "credentials error: Antigravity: no local server found." }

local downTree = loadPanel(withSections(DOWN))
local downLabels = labels(downTree)
assert(not has(downLabels, "Antigravity"), "an unavailable provider should leave the panel")

-- A provider that sends no headings keeps one card, its readings heading
-- themselves: the panel's own header already names Codex.
local paced = {
    id = "openai",
    display_name = "Codex",
    plan = "ChatGPT Plus",
    status = "ready",
    metrics = {},
    sections = {
        { type = "metric", label = "Codex 5h", percent = 3, value = "3%",
          detail = "Resets in 0h 01m · 40% elapsed · 10pts ahead" },
        { type = "metric", label = "Codex weekly", percent = 16, value = "16%",
          detail = "Resets in 6d 18h · 3% elapsed · 13pts ahead" },
    },
}

local function provider(id, name, percent)
    local metric = {
        type = "metric", label = "Usage", percent = percent,
        value = tostring(percent) .. "%", detail = "", severity = "low",
    }
    return {
        id = id,
        display_name = name,
        plan = "Plan",
        status = "ready",
        stale = false,
        metrics = { metric },
        sections = { metric },
    }
end

local claude = provider("anthropic", "Claude", 0)
claude.stale = true
claude.sections[#claude.sections + 1] = {
    type = "text", label = "HTTP 429", value = "Rate limited",
}
local sorted = loadPanel({
    selected = "anthropic",
    entries = {
        claude,
        provider("openai", "Codex", 32),
        provider("antigravity", "Antigravity", 99),
    },
})
local providerOrder = {}
for _, row in ipairs(collect(sorted, "row")) do
    local key = tostring(row.props.key or "")
    local id = key:match("^provider%-(.+)$")
    if id ~= nil then providerOrder[#providerOrder + 1] = id end
end
assert(#providerOrder == 2, "providers with their own failures should leave the list")
assert(providerOrder[1] == "antigravity" and providerOrder[2] == "openai",
       "the most-used working provider should lead the list")

local plain = cards(loadPanel(paced))
assert(#plain == 1, "the session and the week share one card here too")
local plainLabels = labels(plain[1])
assert(plainLabels[1] == "Codex 5h", "the reading heads itself")
assert(has(plainLabels, "Codex weekly"), "the week sits under the session")

-- A failed read with a report behind it is a banner over numbers that are merely
-- older than the panel would like, not a reason to blank the panel.
local failed = loadPanel(paced, { code = "timed_out", detail = "" })
local failedLabels = labels(failed)
assert(has(failedLabels, "ui.stale_hint"), "cached data names its stale state")
assert(not has(failedLabels, "ui.error.timed_out"),
       "a transient failure does not dominate cached data")
assert(has(failedLabels, "Codex 5h"), "and the readings stay under it")
assert(#cards(failed) == 1, "the cards are not dropped")
local retry = false
for _, button in ipairs(collect(failed, "button")) do
    if button.props.text == "ui.retry" then retry = true end
end
assert(retry, "cached data keeps the retry action")
local staleGlyph = false
for _, glyph in ipairs(collect(failed, "glyph")) do
    if glyph.props.name == "clock-exclamation" and glyph.props.color ~= "error" then
        staleGlyph = true
    end
end
assert(staleGlyph, "cached data uses a subdued stale glyph")

local rateLimited = {
    id = "openai",
    display_name = "Codex",
    plan = "ChatGPT Plus",
    status = "ready",
    metrics = paced.metrics,
    sections = {
        paced.sections[1],
        { type = "text", label = "HTTP 429", value = "Rate limited" },
    },
}
local rateLimitedTree = loadPanel(rateLimited)
local rateLimitedLabels = labels(rateLimitedTree)
assert(not has(rateLimitedLabels, "HTTP 429") and not has(rateLimitedLabels, "Rate limited"),
       "raw transport details should not become loose content")
assert(#cards(rateLimitedTree) == 1, "transient provider failures keep cached readings")

local emptyFailure = loadPanel(nil, { code = "timed_out", detail = "" })
assert(has(labels(emptyFailure), "ui.error.timed_out_hint"),
       "a failure without cached data keeps the full error state")

-- Every row can be dropped -- a vendor with no key at all is not listed -- and a
-- report is still a report. The failure is a banner over the panel it arrived
-- in; only a panel with no report behind it at all gives itself over to one.
local unlisted = {
    id = "zai",
    display_name = "Z.AI",
    plan = "",
    status = "error",
    error = "credentials error: no api key found for zai",
    metrics = {},
    sections = {},
}
local dropped = loadPanel(unlisted, { code = "timed_out", detail = "" })
assert(#collect(dropped, "separator") == 1, "the panel keeps its two panes")
assert(not has(labels(dropped), "ui.error.timed_out_hint"),
       "and says the failure once, in the pane, not across the whole panel")

local bottleneckPanelEntry = {
    id = "openai",
    display_name = "Codex",
    plan = "ChatGPT Plus",
    status = "ready",
    metrics = {
        { label = "Codex 5h", percent = 0, severity = "low", value = "0%" },
        { label = "Codex weekly", percent = 100, severity = "critical", value = "100%" },
    },
    sections = {
        { label = "Codex 5h", percent = 0, severity = "low", type = "metric", value = "0%" },
        { label = "Codex weekly", percent = 100, severity = "critical", type = "metric", value = "100%" },
    },
}
local bottleneckPanelTree = loadPanel(bottleneckPanelEntry)
assert(has(labels(bottleneckPanelTree), "100%"),
       "panel sidebar should display the 100% bottleneck reading")

local agyPanelEntry = {
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
    sections = {
        { type = "text", label = "Session", value = "" },
        { label = "Gemini", percent = 0, severity = "low", type = "metric", value = "0%" },
        { label = "Claude & GPT OSS", percent = 0, severity = "low", type = "metric", value = "0%" },
        { type = "text", label = "Weekly", value = "" },
        { label = "Gemini", percent = 24, severity = "low", type = "metric", value = "24%" },
        { label = "Claude & GPT OSS", percent = 100, severity = "critical", type = "metric", value = "100%" },
    },
}
local agyPanelTree = loadPanel(agyPanelEntry)
local function hasGlyph(node, name)
    for _, g in ipairs(collect(node, "glyph")) do
        if g.props.name == name then return true end
    end
    return false
end
assert(hasGlyph(agyPanelTree, "brand-google"), "panel sidebar should display Gemini brand glyph")
assert(hasGlyph(agyPanelTree, "asterisk-simple"), "panel sidebar should display Claude brand glyph")
assert(has(labels(agyPanelTree), "0%"), "panel sidebar should display active session 0%")

io.write("ok: panel degrades safely, sorts usage, and removes unavailable providers\n")
