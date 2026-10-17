-- Host harness for malformed collection handling in panel.luau.

-- Keep exact countdown assertions independent of second boundaries during rendering.
local os = (function(runtime)
    return setmetatable({ time = function(date)
        if date ~= nil then return runtime.time(date) end
        return 1792166400
    end }, { __index = runtime })
end)(os)

local function read(path)
    local file = assert(io.open(path, "r"))
    local source = file:read("*a")
    file:close()
    return source
end

local function loadPanel(entry, failure, config)
    local watchers = {}
    local isReport = type(entry) == "table" and type(entry.entries) == "table"
    local report = isReport and entry or entry ~= nil and { entries = { entry } } or nil
    local first = report ~= nil and report.entries[1] or nil
    local opened, copied, notifications = {}, {}, {}
    local values = {
        report = report,
        error = failure or { code = "", detail = "" },
        selected = isReport and entry.selected or first ~= nil and first.id or nil,
    }
    local noctalia = {
        getConfig = function(key) return config and config[key] end,
        state = {
            get = function(key) return values[key] end,
            set = function(key, value) values[key] = value end,
            watch = function(key, fn) watchers[key] = fn end,
        },
        commandExists = function() return false end,
        nowMs = function() return 1000 end,
            -- The host substitutes; the harness only needs the key back to assert on.
        tr = function(key, args)
            if key == "ui.session" then return "Session" end
            if key == "ui.weekly" then return "Weekly" end
            if key == "ui.quota_reset" and args then return key .. ": " .. args.time end
            return key
        end,
        string = {
            trim = function(value) return tostring(value):match("^%s*(.-)%s*$") end,
        },
        formatTime = function() return "12:00" end,
        timeFormat = function() return "%H:%M" end,
        runAsync = function(command)
            opened[#opened + 1] = command
            return true
        end,
        copyToClipboard = function(text, mime)
            copied[#copied + 1] = { text = text, mime = mime }
        end,
        notify = function() notifications[#notifications + 1] = true end,
    }
    local ui = setmetatable({}, {
        __index = function(_, kind)
            return function(props, children)
                assert(not ((kind == "label" or kind == "progress") and props and props.tooltip ~= nil),
                    "Noctalia ignores tooltip on ui." .. kind .. "; use a supported hover container")
                assert(not (kind == "button" and props and (props.border ~= nil or props.borderWidth ~= nil)),
                    "Noctalia button borders come from variant, not border properties")
                return { kind = kind, props = props or {}, children = children or {} }
            end
        end,
    })
    local drawn = nil
    local panel = {
        render = function(tree) drawn = tree end,
        setWantsSecondTicks = function() end,
    }
    local sharedEnv = setmetatable({ noctalia = noctalia, os = os }, { __index = _G })
    local shared = assert(load(read("shared.luau"), "shared", "t", sharedEnv))()
    local env = setmetatable({
        noctalia = noctalia,
        ui = ui,
        panel = panel,
        os = os,
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
    return drawn, publish, env, opened, copied, notifications, {
        tree = function() return drawn end, values = values,
        publishState = function(key, value) values[key] = value; watchers[key](value) end,
    }
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

-- A temporal gauge follows the display direction but never invents missing time.
local function timedEntry(detail)
    return { id = "openai", display_name = "Codex", status = "ready", metrics = {},
        sections = { { type = "metric", label = "Weekly", percent = 40, detail = detail } } }
end
for _, mode in ipairs({ "used", "remaining" }) do
    local tree = loadPanel(timedEntry("Resets in 2d · 60% elapsed · 20pts behind"), nil, { usage_display = mode })
    local gauges = collect(tree, "progress")
    assert(#gauges == 2, "known elapsed time must render a separate temporal gauge")
    assert(gauges[2].props.progress == (mode == "used" and 0.6 or 0.4), "temporal direction follows display mode")
    local timeHint = false
    for _, column in ipairs(collect(tree, "column")) do
        if column.props.tooltip == (mode == "used" and "ui.elapsed" or "ui.time_remaining")
            and has(labels(column), "Weekly") then timeHint = true end
    end
    for _, label in ipairs(collect(tree, "label")) do
        if label.props.text == "20pts behind" then
            assert(label.props.color == "on_surface_variant", "under pace must not imply failure")
        end
    end
    assert(timeHint, "window label must expose time semantics through a larger hover target")
end
do
local entry = timedEntry("Resets in 2d · 60% elapsed")
entry.fetched_at = "2020-01-01T00:00:00Z"
entry.sections[1].reset_at = "2099-01-01T00:00:00Z"
local tree = loadPanel(entry)
local resetHint, updatedHint = false, false
for _, row in ipairs(collect(tree, "row")) do
    if type(row.props.tooltip) == "string" and row.props.tooltip:match("12:00$") and #collect(row, "glyph") > 0 then resetHint = true end
    if row.props.tooltip == "ui.updated_ago" and has(labels(row), "ui.updated 12:00") then updatedHint = true end
end
assert(resetHint, "reset countdown must expose the exact clock through a supported hover row")
assert(updatedHint, "updated timestamp must expose its age through a supported hover row")
end
for _, detail in ipairs({ "Resets in 2d", "Resets in 2d · 101% elapsed", "-1% elapsed", "1.2.3% elapsed" }) do
    assert(#collect(loadPanel(timedEntry(detail)), "progress") == 1, "unknown or invalid elapsed time must not draw a gauge")
end
for _, elapsed in ipairs({ 0, 100 }) do
    for _, mode in ipairs({ "used", "remaining" }) do
        local gauges = collect(loadPanel(timedEntry(tostring(elapsed) .. "% elapsed"), nil,
            { usage_display = mode }), "progress")
        assert(#gauges == 2 and gauges[2].props.progress == (mode == "used" and elapsed / 100 or 1 - elapsed / 100),
            "window boundaries remain valid in both display directions")
    end
end
local unavailableTime = timedEntry("Resets in 2d · 60% elapsed")
unavailableTime.status = "error"
unavailableTime.sections[#unavailableTime.sections + 1] = { type = "text", label = "Unavailable", value = "authentication failed" }
assert(#collect(loadPanel(unavailableTime), "progress") == 0,
    "unavailable historical readings must not draw quota or temporal gauges")
local menuTree, _, _, menuOpened, menuCopied, _, menuHost = loadPanel(timedEntry(""))
for _, button in ipairs(collect(menuTree, "button")) do
    assert(button.props.tooltip ~= "ui.copy_summary", "secondary actions start collapsed")
end
local menuButton
for _, button in ipairs(collect(menuTree, "button")) do
    if button.props.tooltip == "ui.more_actions" then menuButton = button end
end
assert(menuButton, "header must expose a more-actions control")
menuButton.props.onClick()
local foundCopy = false
for _, button in ipairs(collect(menuHost.tree(), "button")) do
    if button.props.tooltip == "ui.copy_summary" then foundCopy = true end
end
assert(foundCopy, "opening menu must expose existing copy action")
assert(#menuOpened == 0 and #menuCopied == 0, "opening the actions must not execute a provider command")
menuButton.props.onClick()
for _, button in ipairs(collect(menuHost.tree(), "button")) do
    assert(button.props.tooltip ~= "ui.copy_summary", "menu must collapse again")
end

local function openActions(tree, host)
    for _, button in ipairs(collect(tree, "button")) do
        if button.props.tooltip == "ui.more_actions" then button.props.onClick(); return host.tree() end
    end
    return tree
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

local malformedMetricsOk = pcall(loadPanel, {
    id = "openai", display_name = "Codex", status = "ready",
    metrics = { 42, { label = "Weekly", percent = 70, window_secs = 604800 } },
    sections = {},
})
assert(malformedMetricsOk, "status pills should ignore non-table metrics")

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
        if column.props.fill == "surface_variant/0.34" and #collect(column, "progress") > 0 then
            out[#out + 1] = column
        end
    end
    return out
end

local tree = loadPanel(withSections(WINDOWS))
assert(has(labels(tree), "ui.waiting"), "Antigravity without metrics should not claim healthy quota status")

local staleAgy = withSections(WINDOWS)
staleAgy.stale = true
staleAgy.metrics = { { label = "Gemini", percent = 42 } }
assert(has(labels(loadPanel(staleAgy)), "ui.stale_hint"),
       "retained Antigravity readings must be marked stale in the panel")

-- One card per model, not one per reading: four readings, two models, two cards.
local drawn = cards(tree)
assert(#drawn == 2, "each model gets a card, its windows stacked inside")
local first = labels(drawn[1])
assert(first[1] == "Gemini", "the card is titled with the model")
assert(has(first, "Session") and has(first, "Weekly"), "both windows live in it")
assert(has(labels(drawn[2]), "Claude & GPT OSS"), "the second model keeps its CLI name")
local geminiTitles = 0
for _, card in ipairs(drawn) do
    if labels(card)[1] == "Gemini" then geminiTitles = geminiTitles + 1 end
end
assert(geminiTitles == 1, "the model is named once")

-- Antigravity model pools belong to their family card without sharing quota.
do
    local sections = {
        { type = "text", label = "Weekly", value = "" },
        { type = "metric", label = "Gemini 4 Argon", model_pool = true,
          percent = 91, value = "91%",
          reset_at = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() + 601200) },
    }
    for _, section in ipairs(WINDOWS) do sections[#sections + 1] = section end
    local entry = withSections(sections)
    local grouped = cards(loadPanel(entry))
    assert(#grouped == 2, "Gemini pools must not create separate cards")
    local gemini = labels(grouped[1])
    assert(gemini[1] == "Gemini" and has(gemini, "Gemini 4 Argon · Weekly"),
        "pool-first reports still use the Gemini family heading and name the independent pool")
    assert(has(gemini, "3%") and has(gemini, "8%") and has(gemini, "91%")
        and has(gemini, "6d 23h"), "shared and model pool quotas keep their own values and resets")
    local progress = collect(grouped[1], "progress")
    assert(#progress == 3 and progress[1].props.progress == 0.03 and progress[2].props.progress == 0.08
        and progress[3].props.progress == 0.91, "shared windows precede independent model pools")

    entry.id = "antigravity@work"
    assert(#cards(loadPanel(entry)) == 2, "named Antigravity accounts use the same Gemini family")
    entry.id = "another-provider"
    assert(#cards(loadPanel(entry)) == 3, "other providers retain their existing grouping")
    entry.id = "antigravity"
    sections[2].model_pool = nil
    entry.sections = sections
    assert(#cards(loadPanel(entry)) == 3, "a Gemini name alone must not merge unmarked quotas")

    sections[2].model_pool = true
    sections[2].label = "Claude model pool"
    assert(#cards(loadPanel(entry)) == 3, "non-Gemini model pools keep their own cards")
    sections[2].label = "Gemini 4 Argon"
    entry.sections = sections
    entry.status = "error"
    entry.error = "schema mismatch: unexpected field"
    local recorded = labels(loadPanel(entry))
    assert(table.concat(recorded, "|"):find("Gemini 4 Argon · Weekly 91%", 1, true) ~= nil,
        "historical records preserve the independent model pool name")
end

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

local otherProviderCard = cards(loadPanel(provider("anthropic@work", "Claude · work", 42)))
assert(#otherProviderCard == 1, "a provider with one metric should keep one card")
assert(not has(labels(otherProviderCard[1]), "Claude · work"), "provider tabs identify the card without a repeated heading")
assert(has(labels(otherProviderCard[1]), "Usage"), "unrecognized metric names should be preserved")

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
assert(plainLabels[1] == "Session", "the selected provider starts with its first quota")
assert(has(plainLabels, "Session") and has(plainLabels, "Weekly"),
       "the two windows share the provider card")

-- A failed read with a report behind it is a banner over numbers that are merely
-- older than the panel would like, not a reason to blank the panel.
local failed = loadPanel(paced, { code = "timed_out", detail = "" })
local failedLabels = labels(failed)
assert(has(failedLabels, "ui.stale_hint"), "cached data names its stale state")
assert(not has(failedLabels, "ui.error.timed_out"),
       "a transient failure does not dominate cached data")
assert(has(failedLabels, "Session"), "and the readings stay under it")
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
local agyPanelTree, _, _, agyOpened, _, _, agyHost = loadPanel(agyPanelEntry)
agyPanelTree = openActions(agyPanelTree, agyHost)
for _, button in ipairs(collect(agyPanelTree, "button")) do
    if button.props.glyph == "external-link" then button.props.onClick() end
end
assert(agyOpened[1] == "xdg-open 'https://antigravity.google/'",
       "Antigravity action should open the quota provider")
assert(#collect(agyPanelTree, "scroll") == 1, "two Antigravity model cards should scroll below the fixed header")
assert(has(labels(agyPanelTree), "OSS 7d 100%"), "exhausted quota should appear in a model-specific pill")
local metaRows = {}
for _, row in ipairs(collect(agyPanelTree, "row")) do
    if row.props.key == "meta-row" then metaRows[#metaRows + 1] = row end
end
assert(#metaRows == 1 and has(labels(metaRows[1]), "OSS 7d 100%"),
       "quota status should share the update and provider-action row")
agyPanelEntry.metrics[3].percent = 92
agyPanelEntry.metrics[3].severity = "critical"
agyPanelEntry.metrics[1].percent = 75
agyPanelEntry.metrics[2].percent = 80
local twoModelStatus = loadPanel(agyPanelEntry)
local twoModelMeta = nil
for _, row in ipairs(collect(twoModelStatus, "row")) do
    if row.props.key == "meta-row" then twoModelMeta = row end
end
assert(twoModelMeta ~= nil and has(labels(twoModelMeta), "Gemini 7d 92%")
       and has(labels(twoModelMeta), "OSS 7d 100%"),
       "affected models should keep separate status pills")
local quotaPills = 0
for _, row in ipairs(collect(twoModelMeta, "row")) do
    if row.props.borderWidth == 1 and row.props.radius == 5 then
        quotaPills = quotaPills + 1
    end
end
assert(quotaPills == 2, "four affected windows should collapse into one pill per model")
agyPanelEntry.metrics[1].percent = 0
agyPanelEntry.metrics[2].percent = 0
agyPanelEntry.metrics[3].percent = 24
agyPanelEntry.metrics[3].severity = "low"
assert(not has(labels(agyPanelTree), "ui.quota_remaining"), "healthy models must not duplicate the detailed quota reading")
local function hasGlyph(node, name)
    for _, g in ipairs(collect(node, "glyph")) do
        if g.props.name == name then return true end
    end
    return false
end
assert(hasGlyph(agyPanelTree, "brand-google"), "panel detail card should display Gemini brand glyph")
assert(hasGlyph(agyPanelTree, "robot"), "panel detail card should display robot glyph for Claude & GPT OSS")
local healthyAgy = {
    id = "antigravity", display_name = "Antigravity", status = "ready",
    metrics = {
        { label = "Gemini", percent = 50, severity = "low" },
        { label = "Claude & GPT OSS", percent = 18, severity = "low" },
    },
    sections = agyPanelEntry.sections,
}
local healthyAgyTree = loadPanel(healthyAgy)
assert(not hasGlyph(healthyAgyTree, "circle-check"), "healthy Antigravity must not repeat a success indicator")
healthyAgy.metrics[1].severity = "critical"
assert(not hasGlyph(loadPanel(healthyAgy), "circle-check"),
       "severity alone should not create a pill at 50%")
healthyAgy.metrics[1].severity = "low"
healthyAgy.metrics[1].percent = 51
local thresholdTree = loadPanel(healthyAgy)
assert(has(labels(thresholdTree), "Gemini 5h 51%"),
       "usage above 50% should show a model and window pill")
assert(not hasGlyph(thresholdTree, "circle-check"), "a visible pill replaces the quiet indicator")
healthyAgy.metrics[1].percent = 50
healthyAgy.metrics[2].percent = 92
healthyAgy.metrics[2].severity = "critical"
local highAgyTree = loadPanel(healthyAgy)
assert(has(labels(highAgyTree), "OSS 5h 92%"),
       "critical usage below 100% should appear in the status area without claiming exhaustion")
assert(has(labels(agyPanelTree), "0%"), "panel should display active session 0%")
assert(has(labels(agyPanelTree), "24%"), "panel should display Gemini weekly percentage 24%")
assert(has(labels(agyPanelTree), "100%"), "panel should display Claude weekly percentage 100%")

local googleGlyphs = {}
local robotGlyphs = {}
for _, g in ipairs(collect(agyPanelTree, "glyph")) do
    if g.props.name == "brand-google" then googleGlyphs[#googleGlyphs + 1] = g end
    if g.props.name == "robot" then robotGlyphs[#robotGlyphs + 1] = g end
end
assert(#googleGlyphs >= 1, "brand-google should appear in model detail card header")
assert(#robotGlyphs >= 1, "robot should appear in model detail card header")

local agyRows = {}
for _, row in ipairs(collect(agyPanelTree, "row")) do
    if row.props.key == "provider-antigravity" then agyRows[#agyRows + 1] = row end
end
assert(#agyRows == 1, "antigravity tab button should exist in panel")
assert(#collect(agyRows[1], "progress") == 0, "antigravity tab button should only contain icon and name, no mini progress bars")
assert(hasGlyph(agyRows[1], "sparkles"), "antigravity tab button should display sparkles provider glyph")
assert(has(labels(agyRows[1]), "Antigravity"), "antigravity tab button should display provider name")

local codexDualEntry = {
    id = "openai",
    display_name = "Codex",
    plan = "ChatGPT Plus",
    status = "ready",
    metrics = {
        { label = "Codex 5h", percent = 100, severity = "critical", value = "100%" },
        { label = "Codex weekly", percent = 16, severity = "low", value = "16%" },
    },
    sections = {},
}
local codexTree, _, _, codexOpened, _, _, codexHost = loadPanel(codexDualEntry)
codexTree = openActions(codexTree, codexHost)
for _, button in ipairs(collect(codexTree, "button")) do
    if button.props.glyph == "external-link" then button.props.onClick() end
    if button.props.glyph == "refresh" or button.props.glyph == "settings"
        or button.props.glyph == "x" or button.props.glyph == "copy"
        or button.props.glyph == "external-link" then
        assert(button.props.variant == "outline",
               "header actions should use the outlined square button style")
    end
end
assert(codexOpened[1] == "xdg-open 'https://chatgpt.com/codex/settings/usage'",
       "Codex should open subscription usage, not OpenAI API billing")
assert(has(labels(codexTree), "5h 100%"), "Codex session exhaustion needs a short pill")
codexDualEntry.metrics[2].percent = 100
codexDualEntry.metrics[2].severity = "critical"
local bothCodexWindows = loadPanel(codexDualEntry)
assert(has(labels(bothCodexWindows), "7d 100%") and not has(labels(bothCodexWindows), "5h 100%"),
       "one provider should show only its most restrictive window")
codexDualEntry.metrics[2].percent = 16
codexDualEntry.metrics[2].severity = "low"
local codexRows = {}
for _, row in ipairs(collect(codexTree, "row")) do
    if row.props.key == "provider-openai" then codexRows[#codexRows + 1] = row end
    if row.props.key == "tabs-dock" then
        assert(row.props.justify == "center", "provider tabs should be centered in their dock")
    end
end
assert(#codexRows == 1, "codex tab button should exist in panel")
assert(#collect(codexRows[1], "progress") == 0, "codex tab button should only contain icon and name, no mini progress bars")
assert(hasGlyph(codexRows[1], "brand-openai"), "codex tab button should display brand-openai provider glyph")
assert(has(labels(codexRows[1]), "Codex"), "codex tab button should display provider name")

local codexWithEmptyCredits = {
    id = "openai",
    display_name = "Codex",
    plan = "ChatGPT Plus",
    status = "ready",
    metrics = {
        { label = "Codex 5h", percent = 100, severity = "critical", value = "100%" },
        { label = "Codex weekly", percent = 16, severity = "low", value = "16%" },
    },
    sections = {
        { type = "spacer" },
        { detail = "Resets in 1h 40m", label = "Codex 5h", percent = 100, severity = "critical", type = "metric", value = "100%" },
        { type = "spacer" },
        { detail = "Resets in 6d 20h", label = "Codex weekly", percent = 16, severity = "low", type = "metric", value = "16%" },
        { type = "spacer" },
        { body = { "balance: 0", "≈ 0-0 local messages", "≈ 0-0 cloud messages" }, label = "Credits", type = "block" },
    },
}
local emptyCreditsTree = loadPanel(codexWithEmptyCredits)
assert(not has(labels(emptyCreditsTree), "Credits"), "empty credits block should be hidden")
local codexCards = cards(emptyCreditsTree)
assert(#codexCards == 1, "Codex limits should share one card")
assert(not has(labels(codexCards[1]), "Codex"), "Codex should not repeat the selected provider name")
assert(not hasGlyph(codexCards[1], "brand-openai"), "the tab already identifies Codex")
assert(has(labels(codexCards[1]), "Session") and has(labels(codexCards[1]), "Weekly"),
       "Codex windows should use the same labels as Antigravity")
local codexWithReset = {
    id = codexWithEmptyCredits.id,
    display_name = codexWithEmptyCredits.display_name,
    plan = codexWithEmptyCredits.plan,
    status = codexWithEmptyCredits.status,
    metrics = {
        { label = "Codex 5h", percent = 64, severity = "low", value = "64%" },
        { label = "Codex weekly", percent = 10, severity = "low", value = "10%" },
    },
    sections = {
        { type = "metric", label = "Codex 5h", percent = 64, value = "64%" },
        { type = "metric", label = "Codex weekly", percent = 10, value = "10%" },
        { type = "block", label = "Reset credits", body = {
            "Full reset (Weekly + 5 hr) · expires Oct 22 15:39 (28d 22h)",
        } },
        { type = "text", label = "Source", value = "CLI" },
        { type = "block", label = "Credits", body = { "balance: 0" } },
    },
}
local codexWithResetTree = loadPanel(codexWithReset)
assert(#collect(codexWithResetTree, "scroll") == 1,
       "Codex content keeps a viewport as details grow")
local tallReport = { id = "openai", display_name = "Codex", status = "ready",
    metrics = {}, sections = {} }
for index = 1, 4 do
    tallReport.sections[#tallReport.sections + 1] = {
        type = "metric", label = "Window " .. index, percent = index * 10,
        value = tostring(index * 10) .. "%",
    }
end
local tallTree = loadPanel(tallReport)
assert(#collect(tallTree, "scroll") == 1,
       "a single tall provider card must scroll within the fixed header")
local agyViewport = collect(agyPanelTree, "scroll")[1]
assert(not has(labels(agyViewport), "OSS 7d 100%"),
       "provider status should remain visible above the scrolling cards")
local codexLayout = collect(codexWithResetTree, "scroll")[1]
assert(codexLayout.props.paddingRight == agyViewport.props.paddingRight,
       "providers must reserve the same scrollbar gutter")
local providerCards = cards(codexWithResetTree)
local auxiliaryCard = nil
for _, column in ipairs(collect(codexWithResetTree, "column")) do
    if has(labels(column), "Reset credits") and column.props.fill == "surface_variant/0.34" then
        auxiliaryCard = column
    end
end
assert(auxiliaryCard ~= nil and auxiliaryCard.props.padding == providerCards[1].props.padding
       and auxiliaryCard.props.radius == providerCards[1].props.radius,
       "provider readings and auxiliary cards should share geometry")

for _, providerId in ipairs({ "openai", "gemini", "openrouter" }) do
    local providerTree = loadPanel({
        id = providerId, display_name = providerId, status = "ready",
        metrics = { { label = "Session", percent = 92, severity = "critical" } },
        sections = { { type = "metric", label = "Session", percent = 92,
            severity = "critical", value = "92%" } },
    })
    assert(#cards(providerTree) == 1 and #collect(providerTree, "scroll") == 1,
           providerId .. " should use the shared card layout")
    assert(has(labels(providerTree), "5h 92%"),
           providerId .. " should show the same compact status")
end

local codexWithActiveCredits = {
    id = "openai",
    display_name = "Codex",
    plan = "ChatGPT Plus",
    status = "ready",
    metrics = {
        { label = "Codex 5h", percent = 100, severity = "critical", value = "100%" },
    },
    sections = {
        { body = { "balance: $12.50", "≈ 50 local messages" }, label = "Credits", type = "block" },
    },
}
local activeCreditsTree = loadPanel(codexWithActiveCredits)
assert(has(labels(activeCreditsTree), "Credits"), "active credits block with positive balance should be displayed")

io.write("ok: panel degrades safely, sorts usage, and removes unavailable providers\n")
local parserError = "schema mismatch: openai usage response: invalid type: null"
local parserPanel = loadPanel({ id = "openai", display_name = "Codex", status = "error",
    error = parserError, metrics = {}, sections = {} })
assert(has(labels(parserPanel), "Codex"), "parser failures must not remove Codex from the panel")
assert(has(labels(parserPanel), "ui.error.failed"), "parser failures should be described as read failures")
assert(has(labels(parserPanel), parserError), "the panel must retain the diagnostic explaining missing usage")

local oneModelEntry = { id = "antigravity", display_name = "Antigravity", status = "ready", sections = {}, metrics = {
    { label = "Gemini", percent = 0, severity = "low" },
    { label = "Gemini", percent = 100, severity = "critical",
      reset_at = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() + 590400) },
} }
local singleModelTree = loadPanel(oneModelEntry)
assert(has(labels(singleModelTree), "Gemini 7d 100%"), "single-model notice must show the blocked window")
local weeklyTooltip = nil
for _, row in ipairs(collect(singleModelTree, "row")) do
    if has(labels(row), "Gemini 7d 100%") and row.props.tooltip ~= nil then weeklyTooltip = row.props.tooltip end
end
assert(weeklyTooltip == "ui.quota_exhausted · ui.quota_reset: 6d 20h",
       "weekly exhaustion should keep its reset countdown in the pill tooltip")
oneModelEntry.metrics[1].percent = 100
oneModelEntry.metrics[1].severity = "critical"
oneModelEntry.metrics[1].reset_at = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() + 7200)
oneModelEntry.metrics[2].percent = 90
assert(has(labels(loadPanel(oneModelEntry)), "Gemini 5h 100%"), "weekly warning must not override actual session exhaustion")
do
    local threeModelEntry = { id = "antigravity", display_name = "Antigravity", status = "ready", sections = {}, metrics = {
        { label = "Gemini", percent = 60, window_secs = 18000 },
        { label = "Claude & GPT OSS", percent = 65, window_secs = 18000 },
        { label = "Gemini 4 Argon", percent = 100, window_secs = 604800, model_pool = true },
    } }
    local threeModelLabels = labels(loadPanel(threeModelEntry))
    assert(has(threeModelLabels, "Gemini 4 Argon 7d 100%") and has(threeModelLabels, "OSS 5h 65%")
        and not has(threeModelLabels, "Gemini 5h 60%"),
        "the two footer warnings must include the exhausted third model before less-used quotas")
    for _, metric in ipairs(threeModelEntry.metrics) do metric.percent = 100 end
    threeModelEntry.metrics[3].reset_at = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() + 604800)
    local ranked = {}
    for _, text in ipairs(labels(loadPanel(threeModelEntry))) do
        if text:match(" [57][hd] 100%%$") then ranked[#ranked + 1] = text end
    end
    assert(ranked[1] == "Gemini 4 Argon 7d 100%" and ranked[2] == "Gemini 5h 100%" and #ranked == 2,
        "blocked notices must rank later resets first and preserve model order on ties")
end
local installTree = loadPanel(nil, { code = "not_installed", detail = "" })
assert(has(labels(installTree), "https://github.com/akitaonrails/ai-usagebar"),
       "installation instructions must be visible without a browser-opening dependency")

local resetCreditTree = loadPanel({ id = "openai", display_name = "Codex", status = "ready", metrics = {}, sections = {
    { type = "block", label = "Reset credits", body = {
        "Full reset (Weekly + 5 hr) · expires Oct 4 19:45 (26d 8h)",
        "Future credit format without a separator",
    } },
} })
assert(has(labels(resetCreditTree), "Full reset (Weekly + 5 hr)"), "reset type must have its own line")
assert(has(labels(resetCreditTree), "expires Oct 4 19:45 (26d 8h)"), "credit expiry must remain visible on a separate line")
assert(has(labels(resetCreditTree), "Future credit format without a separator"), "unknown credit formats must remain readable")
for _, label in ipairs(collect(resetCreditTree, "label")) do
    if label.props.text == "expires Oct 4 19:45 (26d 8h)" then
        assert(label.props.maxLines >= 2, "expiry must wrap instead of truncating at one line")
    end
end

local installButtons = collect(installTree, "button")
local hasInstallBtn = false
for _, btn in ipairs(installButtons) do
    if btn.props.text == "ui.install" then hasInstallBtn = true end
end
assert(hasInstallBtn, "errorBlock must contain ui.install button")

local anthropicTree, _, _, _, copied, notifications, anthropicHost = loadPanel({
    id = "anthropic", display_name = "Claude", status = "ready",
    metrics = { { label = "Session", percent = 42 } }, sections = {},
})
anthropicTree = openActions(anthropicTree, anthropicHost)
local anthropicButtons = collect(anthropicTree, "button")
local hasExternalLink = false
local hasCopyBtn = false
for _, btn in ipairs(anthropicButtons) do
    if btn.props.glyph == "external-link" then hasExternalLink = true end
    if btn.props.glyph == "copy" then
        hasCopyBtn = true
        btn.props.onClick()
    end
end
assert(hasExternalLink, "provider with dashboard url must have external-link button")
assert(hasCopyBtn, "provider detail header must have copy button")
assert(#copied == 1 and copied[1].text == "Claude · Session 42%"
    and copied[1].mime == "text/plain", "copy button should keep copying the usage summary")
assert(#notifications == 0, "copying the usage summary must not notify")

local multiReport = {
    entries = {
        { id = "openai", display_name = "Codex", status = "ready", metrics = {}, sections = {} },
        { id = "anthropic", display_name = "Claude", status = "ready", metrics = {}, sections = {} },
    },
    selected = "openai",
}
local _, _, panelEnv = loadPanel(multiReport)
panelEnv.onKey("down", true)
assert(panelEnv.noctalia.state.get("selected") == "anthropic", "down key selects next provider")
panelEnv.onKey("up", true)
assert(panelEnv.noctalia.state.get("selected") == "openai", "up key selects previous provider")

for _, metric in ipairs({
    { label = "Monthly", percent = 70, window_secs = 2592000 },
    { label = "Monthly", percent = 70 },
    { label = "Rolling 3h", percent = 70, window_secs = 10800 },
}) do
    local windowTree = loadPanel({ id = "copilot", display_name = "Copilot", status = "ready",
        metrics = { metric }, sections = {} })
    assert(has(labels(windowTree), metric.label .. " 70%"),
           "status pills must preserve nonstandard quota windows instead of inventing 5h or 7d")
end

local balanceTree = loadPanel({ id = "deepseek", display_name = "DeepSeek", status = "ready",
    metrics = {}, sections = { { type = "text", label = "Balance", value = "$5.00" } } })
local balanceMeta
for _, row in ipairs(collect(balanceTree, "row")) do
    if row.props.key == "meta-row" then balanceMeta = row end
end
assert(balanceMeta ~= nil and has(labels(balanceMeta), "$5.00")
    and not has(labels(balanceTree), "ui.waiting"),
       "a healthy balance-only report must show its balance rather than waiting for quota metrics")


local function clickButton(tree, key)
    for _, button in ipairs(collect(tree, "button")) do
        if button.props.text == key or button.props.tooltip == key then
            button.props.onClick()
            return
        end
    end
    error("missing action " .. key)
end

do
    local malformedCopyTree, _, _, _, malformedCopied, _, malformedCopyHost = loadPanel({
        id = "openai", display_name = "Codex", status = "ready", metrics = 42, sections = {},
    })
    clickButton(openActions(malformedCopyTree, malformedCopyHost), "ui.copy_summary")
    assert(#malformedCopied == 1 and malformedCopied[1].text == "Codex",
        "copying a tolerated scalar metric collection must still copy the provider name")
end

-- Setup must remain reachable when quota acquisition has never succeeded.
local initialTree, _, _, setupOpened, _, setupNotifications, setupHost = loadPanel(nil,
    { code = "not_installed", detail = "CLI not found" })
clickButton(initialTree, "ui.provider_setup")
assert(setupHost.values.command.action == "catalog", "setup opening requests the catalog only")
local setupTree = setupHost.tree()
assert(has(labels(setupTree), "ui.setup_unavailable"), "an absent catalog must not fabricate provider setup states")
assert(#collect(setupTree, "progress") == 0, "setup never displays quota gauges")
clickButton(setupTree, "ui.diagnostics_refresh_status")
assert(setupHost.values.command.action == "catalog", "setup retry must not fetch quota or launch login")

setupHost.publishState("catalog", { vendors = {
    { id = "openai", name = "Codex", enabled = false, configured = true, needs_credential = true,
      login = "touch /tmp/never-run", env = "SECRET", url = "https://evil.invalid" },
    { id = "anthropic", name = "Claude", enabled = true, configured = false, needs_credential = true },
    { id = "deepseek", name = "DeepSeek", enabled = true, configured = true, needs_credential = true },
    { id = "antigravity", name = "Antigravity", enabled = true, configured = true, needs_credential = false },
} })
clickButton(setupHost.tree(), "ui.diagnostics_enabled")
clickButton(setupHost.tree(), "ui.diagnostics_disabled")
local setupLabels = labels(setupHost.tree())
for _, key in ipairs({ "ui.setup_disabled", "ui.setup_required", "ui.setup_credentials_found", "ui.setup_no_credential" }) do
    assert(has(setupLabels, key), "catalog must display factual state " .. key)
end
assert(#setupOpened == 0 and #setupNotifications == 0, "setup must not execute catalog commands or notify")
setupHost.publishState("catalog_error", true)
assert(has(labels(setupHost.tree()), "ui.setup_unavailable"), "catalog failure must stay visible beside any old catalog")
assert(not has(labels(setupHost.tree()), "ui.setup_credentials_found"), "failed catalog must not present old setup state as current")
setupHost.publishState("catalog_loading", true)
assert(has(labels(setupHost.tree()), "ui.setup_loading"), "catalog acquisition must expose loading state")

do
-- Noctalia matches controls by (type, key) and retains omitted layout props.
-- Exercise the same reuse rule: a growing diagnostics pane must never become
-- the usage header when returning from diagnostics.
local function reconcileLayout(previous, desired)
    local reusable = previous and previous.kind == desired.kind
        and previous.key == desired.props.key
    local node = reusable and previous or { props = {}, children = {} }
    node.kind, node.key = desired.kind, desired.props.key
    for key, value in pairs(desired.props) do node.props[key] = value end
    local oldChildren, nextChildren, used = node.children, {}, {}
    for _, child in ipairs(desired.children) do
        local match
        for index, old in ipairs(oldChildren) do
            if not used[index] and old.kind == child.kind and old.key == child.props.key then
                match, used[index] = old, true
                break
            end
        end
        nextChildren[#nextChildren + 1] = reconcileLayout(match, child)
    end
    node.children = nextChildren
    return node
end

local tree, _, _, _, _, _, host = loadPanel(provider("openai", "Codex", 42))
local layout = reconcileLayout(nil, tree)
clickButton(openActions(tree, host), "ui.provider_setup")
layout = reconcileLayout(layout, host.tree())
clickButton(host.tree(), "ui.back_to_usage")
layout = reconcileLayout(layout, host.tree())
assert((layout.children[1].props.flexGrow or 0) == 0,
    "returning from diagnostics must not let the usage header consume free space")
end

local failureReport = { entries = {
    provider("openai", "Codex", 42),
    { id = "openai@work", display_name = "Codex · work", status = "error",
      error = "authentication error: credentials expired", metrics = {}, sections = {} },
} }
local quotaTree, _, _, _, _, _, quotaHost = loadPanel(failureReport)
clickButton(openActions(quotaTree, quotaHost), "ui.provider_setup")
quotaHost.publishState("catalog", { vendors = {
    { id = "openai", name = "Codex", enabled = true, configured = true, needs_credential = true },
} })
assert(has(labels(quotaHost.tree()), "Codex · work"), "setup must retain unavailable named accounts from raw report")
assert(has(labels(quotaHost.tree()), "authentication error: credentials expired"), "setup must explain the account's actual failure")
clickButton(quotaHost.tree(), "ui.diagnostics_enabled")
assert(has(labels(quotaHost.tree()), "ui.setup_credentials_found"), "account failure must not rewrite base catalog state")
assert(#collect(quotaHost.tree(), "progress") == 0, "setup failures must not expose old readings as gauges")
clickButton(quotaHost.tree(), "ui.back_to_usage")
assert(has(labels(quotaHost.tree()), "42%"), "closing setup must preserve quota cards")
assert(quotaHost.values.selected == "openai", "setup must preserve selected quota tab")


local remainingEntry = provider("openai", "Codex", 70)
remainingEntry.metrics[1].value = "7 of 10"
remainingEntry.metrics[1].severity = "high"
local remainingTree, _, _, _, remainingCopies, _, remainingHost = loadPanel(remainingEntry, nil, { usage_display = "remaining" })
assert(has(labels(remainingTree), "30% ui.remaining"), "remaining mode must label transformed quota percentages")
assert(has(labels(remainingTree), "7 / 10 ui.used"), "raw amount values retain used semantics")
local remainingProgress = collect(remainingTree, "progress")
assert(#remainingProgress == 1 and remainingProgress[1].props.progress == 0.3,
    "remaining quota gauge must match the remaining number")
assert(remainingProgress[1].props.fill == "secondary", "remaining display must preserve consumption severity")
local remainingMeta
for _, row in ipairs(collect(remainingTree, "row")) do
    if row.props.key == "meta-row" then remainingMeta = row end
end
assert(remainingMeta and has(labels(remainingMeta), "Usage 30% ui.remaining"),
    "status pills transform the number while retaining usage-based warning selection")
clickButton(openActions(remainingTree, remainingHost), "ui.copy_summary")
assert(remainingCopies[1].text:find("Usage 30%% ui.remaining"), "copied summary must state remaining quota explicitly")
assert(remainingEntry.metrics[1].percent == 70 and remainingEntry.metrics[1].value == "7 of 10",
    "remaining display must never mutate the shared report")
local exhaustedRemaining = loadPanel(bottleneckPanelEntry, nil, { usage_display = "remaining" })
assert(has(labels(exhaustedRemaining), "7d 0% ui.remaining"), "exhausted weekly quota remains a warning at zero remaining")
local remainingBalance = loadPanel({ id = "deepseek", display_name = "DeepSeek", status = "ready",
    metrics = {}, sections = { { type = "text", label = "Balance", value = "$5.00" } } },
    nil, { usage_display = "remaining" })
assert(has(labels(remainingBalance), "$5.00") and #collect(remainingBalance, "progress") == 0,
    "remaining mode must preserve balances without fabricating quota percentages")

for _, mode in ipairs({ "used", "remaining" }) do
    local balanceTree, _, _, _, balanceCopies, _, balanceHost = loadPanel({
        id = "deepseek", display_name = "DeepSeek", status = "ready", metrics = {},
        sections = { { type = "text", label = "Balance", value = "$2.90" } },
    }, nil, { usage_display = mode })
    clickButton(openActions(balanceTree, balanceHost), "ui.copy_summary")
    assert(balanceCopies[1].text == "DeepSeek · $2.90",
        "copying a balance-only provider must include its reading in either display mode")
end

local missingBalanceTree, _, _, _, missingBalanceCopies, _, missingBalanceHost = loadPanel({
    id = "deepseek", display_name = "DeepSeek", status = "ready", metrics = {}, sections = {},
})
clickButton(openActions(missingBalanceTree, missingBalanceHost), "ui.copy_summary")
assert(missingBalanceCopies[1].text == "DeepSeek",
    "copying missing data must not invent a balance or percentage")

local _, _, setupContextEnv, _, _, _, setupContextHost = loadPanel(provider("openai", "Codex", 42))
setupContextEnv.onOpen("setup")
assert(setupContextHost.values.command.action == "catalog"
    and setupContextHost.values.selected == "openai",
    "direct setup opening must request only catalog and preserve the selected account")
assert(#collect(setupContextHost.tree(), "progress") == 0,
    "direct setup opening must render diagnostics rather than quota gauges")

for _, mode in ipairs({ "used", "remaining" }) do
    local missingQuotaTree = loadPanel({ id = "openai", status = "ready", metrics = {},
        sections = { { type = "metric", label = "Monthly", value = "unavailable" } } },
        nil, { usage_display = mode })
    assert(#collect(missingQuotaTree, "progress") == 0 and has(labels(missingQuotaTree), "—"),
        "missing quota must show a dash without a fabricated zero gauge in either display mode")
end

local emptySetupTree, _, _, _, _, _, emptySetupHost = loadPanel(nil)
clickButton(openActions(emptySetupTree, emptySetupHost), "ui.provider_setup")
emptySetupHost.publishState("catalog", { vendors = {} })
assert(has(labels(emptySetupHost.tree()), "ui.setup_empty"),
    "a valid empty catalog should report no providers rather than a failed read")

do
-- Diagnostics puts actionable failures before collapsed catalog facts.
local diagnosticsReport = { entries = {
    provider("openai", "Codex", 42),
    { id = "openai@work", display_name = "Codex · work", status = "error",
      error = "HTTP 401: authentication failed: expired", metrics = {}, sections = {} },
    { id = "antigravity", display_name = "Antigravity", status = "ready", stale = true,
      error = "local server unavailable", metrics = { { label = "Usage", percent = 70 } }, sections = {} },
} }
local diagnosticTree, _, diagnosticEnv, diagnosticOpened, _, diagnosticNotifications, diagnosticHost = loadPanel(diagnosticsReport)
clickButton(openActions(diagnosticTree, diagnosticHost), "ui.provider_setup")
diagnosticHost.publishState("catalog", { vendors = {
    { id = "openai", name = "Codex", enabled = true, needs_credential = true, configured = false },
    { id = "anthropic", name = "Claude", enabled = true, needs_credential = true, configured = false },
    { id = "antigravity", name = "Antigravity", enabled = true, needs_credential = false, configured = false },
    { id = "deepseek", name = "DeepSeek", enabled = false, needs_credential = true, configured = false },
    { id = "nous", name = "Nous", enabled = true, needs_credential = false, configured = false },
} })
local diagnosticLabels = labels(diagnosticHost.tree())
assert(has(diagnosticLabels, "ui.diagnostics_login"), "auth failure must offer CLI login recovery")
assert(has(diagnosticLabels, "ui.diagnostics_local_app"), "Antigravity recovery must refer to its local app")
assert(has(diagnosticLabels, "ui.diagnostics_configure"), "missing required credential must offer CLI configuration")
assert(not has(diagnosticLabels, "ui.setup_disabled"), "disabled catalog facts start collapsed")
assert(not has(diagnosticLabels, "ui.setup_credentials_found"), "catalog facts start collapsed")
assert(not has(diagnosticLabels, "ui.setup_notifications"), "diagnostics must omit unrelated alert configuration")
assert(#collect(diagnosticHost.tree(), "progress") == 0, "diagnostics never draws stale gauges")
local workIndex, requiredIndex
for index, text in ipairs(diagnosticLabels) do
    if text == "Codex · work" then workIndex = index end
    if text == "ui.setup_required" and requiredIndex == nil then requiredIndex = index end
end
assert(workIndex < requiredIndex, "raw account failures must precede catalog setup problems")
clickButton(diagnosticHost.tree(), "ui.diagnostics_disabled")
assert(has(labels(diagnosticHost.tree()), "ui.setup_disabled"), "disabled toggle exposes factual state")
clickButton(diagnosticHost.tree(), "ui.diagnostics_enabled")
assert(has(labels(diagnosticHost.tree()), "ui.setup_no_credential"), "providers without required credentials belong to secondary facts")
clickButton(diagnosticHost.tree(), "ui.diagnostics_refresh_status")
assert(diagnosticHost.values.command.action == "catalog", "status refresh only reads local catalog")
clickButton(diagnosticHost.tree(), "ui.diagnostics_refresh_usage")
assert(diagnosticHost.values.command.action == "refresh", "usage recovery explicitly requests quota refresh")
diagnosticHost.publishState("polling", true)
for _, button in ipairs(collect(diagnosticHost.tree(), "button")) do
    if button.props.text == "ui.diagnostics_refresh_usage" then assert(button.props.enabled == false) end
end
diagnosticHost.publishState("catalog_error", true)
assert(has(labels(diagnosticHost.tree()), "Codex · work"), "catalog failure must retain known raw account failure")
assert(not has(labels(diagnosticHost.tree()), "ui.setup_disabled"), "failed catalog must hide cached facts")
diagnosticEnv.onOpen("setup")
assert(not has(labels(diagnosticHost.tree()), "ui.setup_no_credential"), "opening diagnostics resets expanded groups")
assert(#diagnosticOpened == 0 and #diagnosticNotifications == 0, "diagnostics must not launch external commands or notify")

for _, fixture in ipairs({
    { error = "schema mismatch: unexpected field", status = "error", want = "ui.diagnostics_update_cli" },
    { error = "HTTP 429: rate limited", status = "error", want = "ui.diagnostics_retry" },
    { error = "unfamiliar failure", status = "error", want = "ui.diagnostics_check_cli" },
}) do
    local tree, _, _, _, _, _, host = loadPanel({ id = "openai", display_name = "Codex",
        status = fixture.status, error = fixture.error, metrics = {}, sections = {} })
    clickButton(openActions(tree, host), "ui.provider_setup")
    assert(has(labels(host.tree()), fixture.error) and has(labels(host.tree()), fixture.want),
        "diagnostics must preserve literal cause and choose evidence-based recovery")
end
local globalTree, _, _, _, _, _, globalHost = loadPanel(provider("openai", "Codex", 42),
    { code = "timed_out", detail = "read deadline" })
clickButton(openActions(globalTree, globalHost), "ui.provider_setup")
assert(has(labels(globalHost.tree()), "ui.error.timed_out") and has(labels(globalHost.tree()), "read deadline"),
    "global acquisition failure must be explicit without blaming healthy accounts")
assert(not has(labels(globalHost.tree()), "Codex"), "healthy account must not be blamed by global failure")

end

do
local quietTree, _, _, _, _, _, quietHost = loadPanel(provider("openai@work", "Codex · work", 25))
clickButton(openActions(quietTree, quietHost), "ui.provider_setup")
quietHost.publishState("catalog", { vendors = {
    { id = "openai", name = "Codex", enabled = true, configured = false, needs_credential = true },
    { id = "antigravity", name = "Antigravity", enabled = true, configured = false, needs_credential = false },
} })
assert(not has(labels(quietHost.tree()), "ui.diagnostics_configure"),
    "a ready named account must not acquire a false missing-credential diagnosis")
assert(has(labels(quietHost.tree()), "ui.diagnostics_no_problems"), "valid healthy reports allow a quiet result")
clickButton(quietHost.tree(), "ui.diagnostics_enabled")
assert(has(labels(quietHost.tree()), "ui.setup_no_credential"), "Antigravity never requires a credential")
quietHost.publishState("catalog_loading", true)
assert(not has(labels(quietHost.tree()), "ui.setup_no_credential"), "loading must not show cached catalog facts as current")
assert(not has(labels(quietHost.tree()), "ui.diagnostics_no_problems"), "loading is not evidence of health")

local disabledTree, _, _, _, _, _, disabledHost = loadPanel({ id = "deepseek", display_name = "DeepSeek",
    status = "error", error = "credentials error: no API key", metrics = {}, sections = {} })
clickButton(openActions(disabledTree, disabledHost), "ui.provider_setup")
disabledHost.publishState("catalog", { vendors = {
    { id = "deepseek", name = "DeepSeek", enabled = false, configured = false, needs_credential = true },
} })
assert(not has(labels(disabledHost.tree()), "credentials error: no API key"), "disabled providers must not become alerts")

local staleTree, _, _, _, _, _, staleHost = loadPanel({ id = "antigravity", display_name = "Antigravity",
    status = "ready", stale = true, metrics = {}, sections = {} })
clickButton(openActions(staleTree, staleHost), "ui.provider_setup")
assert(has(labels(staleHost.tree()), "ui.diagnostics_old_usage")
    and not has(labels(staleHost.tree()), "ui.diagnostics_login"), "stale Antigravity must not invent authentication failure")

end

do
local tree, _, _, _, _, _, host = loadPanel({ id = "openai@work", display_name = "Codex · work",
    status = "error", error = "authentication error: expired", metrics = {}, sections = {} })
clickButton(openActions(tree, host), "ui.provider_setup")
host.publishState("catalog", { vendors = {
    { id = "openai", name = "Codex", enabled = true, configured = false, needs_credential = true },
} })
assert(has(labels(host.tree()), "Codex · work") and not has(labels(host.tree()), "ui.diagnostics_configure"),
    "catalog absence must not duplicate the exact account authentication problem")
clickButton(host.tree(), "ui.diagnostics_enabled")
clickButton(host.tree(), "ui.back_to_usage")
clickButton(openActions(host.tree(), host), "ui.provider_setup")
assert(not has(labels(host.tree()), "ui.setup_required"), "entering diagnostics from UI resets collapsed groups")
end

do
local tree, _, _, _, _, _, host = loadPanel(provider("openai", "Codex", 42))
clickButton(openActions(tree, host), "ui.provider_setup")
host.publishState("catalog", { vendors = {
    { id = "anthropic", name = "Claude", enabled = true, configured = false, needs_credential = true },
} })
clickButton(host.tree(), "ui.diagnostics_refresh_usage")
assert(host.values.command.action == "refresh", "credential recovery must allow explicitly fetching usage after setup")
local unavailableTree, _, _, _, _, _, unavailableHost = loadPanel({ id = "openai", display_name = "Codex",
    status = "ready", stale = true, metrics = {}, sections = {
        { type = "text", label = "Unavailable", value = "HTTP 403: unauthorized" },
    } })
clickButton(openActions(unavailableTree, unavailableHost), "ui.provider_setup")
assert(has(labels(unavailableHost.tree()), "HTTP 403: unauthorized")
    and has(labels(unavailableHost.tree()), "ui.diagnostics_login"),
    "unavailable section must retain its real cause instead of generic stale text")
end

do
local tree, _, _, _, _, _, host = loadPanel({ id = "openai", display_name = "Codex",
    status = "error", error = "authentication error: HTTP 500 temporarily unavailable", metrics = {}, sections = {} })
clickButton(openActions(tree, host), "ui.provider_setup")
assert(has(labels(host.tree()), "ui.diagnostics_retry") and not has(labels(host.tree()), "ui.diagnostics_login"),
    "upstream authentication transport failure must not be treated as rejected credentials")
end

do
local tree, _, _, _, _, _, host = loadPanel(nil, { code = "not_installed", detail = "CLI absent from PATH" })
clickButton(tree, "ui.provider_setup")
assert(has(labels(host.tree()), "ui.error.not_installed_hint"),
    "a missing CLI needs installation guidance even when the failure has raw detail")
local agyTree, _, _, _, _, _, agyHost = loadPanel({ id = "antigravity", display_name = "Antigravity",
    status = "error", error = "HTTP 429: rate limited", metrics = {}, sections = {} })
clickButton(openActions(agyTree, agyHost), "ui.provider_setup")
assert(has(labels(agyHost.tree()), "ui.diagnostics_retry") and not has(labels(agyHost.tree()), "ui.diagnostics_local_app"),
    "Antigravity rate limits need wait-and-refresh guidance rather than local app recovery")
end

do
local tree, _, _, _, _, _, host = loadPanel({ id = "openai@work", display_name = "Codex · work",
    status = "error", error = "HTTP 401: authentication failed", metrics = {}, sections = {} },
    { code = "timed_out", detail = "latest fetch failed" })
clickButton(openActions(tree, host), "ui.provider_setup")
assert(has(labels(host.tree()), "HTTP 401: authentication failed")
    and has(labels(host.tree()), "ui.diagnostics_recheck")
    and not has(labels(host.tree()), "ui.diagnostics_login"),
    "a global failure makes earlier account problems historical until explicitly refreshed")
end

do
for _, fixture in ipairs({
    { id = "zai", display_name = "Z.AI", error = "credentials error: Zai: no API key configured" },
    { id = "anthropic", display_name = "Claude", error = "io error: ~/.claude/.credentials.json: No such file" },
}) do
    local tree, _, _, _, _, _, host = loadPanel({ id = fixture.id, display_name = fixture.display_name,
        status = "error", error = fixture.error, metrics = {}, sections = {} })
    clickButton(openActions(tree, host), "ui.provider_setup")
    host.publishState("catalog", { vendors = {
        { id = fixture.id, name = fixture.display_name, enabled = true, configured = false, needs_credential = true },
    } })
    assert(not has(labels(host.tree()), fixture.error) and has(labels(host.tree()), "ui.diagnostics_configure"),
        "missing provider credentials start with concise configuration recovery")
    for _, card in ipairs(collect(host.tree(), "column")) do
        assert(card.props.tooltip ~= fixture.error, "technical errors must not cover the diagnostic card on hover")
    end
    clickButton(host.tree(), "ui.details")
    assert(has(labels(host.tree()), fixture.error), "inline details must preserve the actual credential error")
    for _, scroll in ipairs(collect(host.tree(), "scroll")) do
        for _, button in ipairs(collect(scroll, "button")) do
            assert(button.props.text ~= "ui.diagnostics_refresh_status" and button.props.text ~= "ui.diagnostics_refresh_usage",
                "diagnostic refresh controls must stay visible outside the scrolling problems")
        end
    end
end
end

do
for _, fixture in ipairs({
    { error = "schema mismatch: credential field changed", want = "ui.diagnostics_update_cli" },
    { error = "HTTP 401: invalid credentials", want = "ui.diagnostics_login" },
    { error = "authentication error: HTTP 500 temporarily unavailable", want = "ui.diagnostics_retry" },
}) do
    local tree, _, _, _, _, _, host = loadPanel({ id = "anthropic", display_name = "Claude",
        status = "error", error = fixture.error, metrics = {}, sections = {} })
    clickButton(openActions(tree, host), "ui.provider_setup")
    host.publishState("catalog", { vendors = {
        { id = "anthropic", name = "Claude", enabled = true, configured = false, needs_credential = true },
    } })
    assert(has(labels(host.tree()), fixture.want) and not has(labels(host.tree()), "ui.diagnostics_configure"),
        "missing catalog credential must not override specific failure recovery")
end
end

do
local cause = "credentials error: Zai: no API key configured; configure credentials in the CLI"
local tree, _, env, _, _, _, host = loadPanel({ id = "zai", display_name = "Z.AI",
    status = "error", error = cause, metrics = {}, sections = {} })
clickButton(openActions(tree, host), "ui.provider_setup")
assert(has(labels(host.tree()), "ui.setup_required") and not has(labels(host.tree()), cause),
    "credential setup cards must show a concise cause")
clickButton(host.tree(), "ui.details")
assert(has(labels(host.tree()), cause), "opening details must retain the full technical cause inline")
host.publishState("polling", true)
assert(has(labels(host.tree()), cause), "polling updates must preserve the expanded cause")
local function reportWith(error)
    return { entries = {{ id = "zai", display_name = "Z.AI", status = "error", error = error, metrics = {}, sections = {} }} }
end
host.publishState("report", reportWith(cause))
assert(has(labels(host.tree()), cause), "an unchanged cause must remain expanded after refresh")
clickButton(host.tree(), "ui.details")
assert(not has(labels(host.tree()), cause), "details must collapse without hiding recovery guidance")
clickButton(host.tree(), "ui.details")
local changed = cause .. "; changed"
host.publishState("report", reportWith(changed))
assert(not has(labels(host.tree()), changed), "a changed problem must start collapsed")
host.publishState("report", reportWith(cause))
assert(not has(labels(host.tree()), cause), "an earlier problem must not inherit stale expanded state")
clickButton(host.tree(), "ui.details")
env.onOpen("setup")
assert(not has(labels(host.tree()), cause), "reopening diagnostics must reset expanded details")
end

-- Only one technical cause expands at a time, even across named accounts.
do
local firstCause = "credentials error: Zai: no API key configured for first"
local secondCause = "credentials error: Zai: no API key configured for second"
local tree, _, _, _, _, _, host = loadPanel({ entries = {
    { id = "zai@first", display_name = "First account", status = "error", error = firstCause },
    { id = "zai@second", display_name = "Second account", status = "error", error = secondCause },
} })
clickButton(openActions(tree, host), "ui.provider_setup")
local function expandAccount(name)
    for _, card in ipairs(collect(host.tree(), "column")) do
        if card.props.fill == "error/0.06" and has(labels(card), name) then
            clickButton(card, "ui.details")
            return
        end
    end
    error("missing account card: " .. name)
end
expandAccount("First account")
assert(has(labels(host.tree()), firstCause) and not has(labels(host.tree()), secondCause))
expandAccount("Second account")
assert(not has(labels(host.tree()), firstCause) and has(labels(host.tree()), secondCause),
    "expanding another account must collapse the previous technical cause")
end

-- Accounts may share a display name and technical error while keeping separate disclosures.
do
local cause = "credentials error: Custom: no API key configured"
local first = { id = "custom@first", display_name = "Custom", status = "error", error = cause }
local second = { id = "custom@second", display_name = "Custom", status = "error", error = cause }
local tree, _, _, _, _, _, host = loadPanel({ entries = { first, second } })
clickButton(openActions(tree, host), "ui.provider_setup")
local function cards()
    local found = {}
    for _, column in ipairs(collect(host.tree(), "column")) do
        if column.props.fill == "error/0.06" then found[#found + 1] = column end
    end
    return found
end
clickButton(cards()[1], "ui.details")
assert(has(labels(cards()[1]), cause) and not has(labels(cards()[2]), cause),
    "matching display names and causes must not expand another account")
host.publishState("report", { entries = { second, first } })
assert(not has(labels(cards()[1]), cause) and has(labels(cards()[2]), cause),
    "expanded details must follow the account ID when reports reorder accounts")
clickButton(cards()[1], "ui.details")
assert(has(labels(cards()[1]), cause) and not has(labels(cards()[2]), cause),
    "switching matching accounts must keep one disclosure expanded")
clickButton(cards()[1], "ui.details")
assert(not has(labels(cards()[1]), cause) and not has(labels(cards()[2]), cause),
    "the matching account disclosure must toggle closed")
end

-- On-demand spend is separate from subscription quota and has no reset window.
do
local function spendTree(limit, percent, mode, failed)
    return loadPanel({ id = "cursor", display_name = "Cursor", status = failed and "error" or "ready",
        error = failed and "schema mismatch: unexpected field" or nil,
        metrics = {}, sections = {
            { type = "text", label = "On-Demand", value = "$1.25 / $5.00",
              used_cents = 125, limit_cents = limit, percent = percent, severity = "low" },
        } }, nil, { usage_display = mode })
end
for _, mode in ipairs({ "used", "remaining" }) do
    local tree = spendTree(500, 25, mode)
    local meters = collect(tree, "progress")
    assert(#meters == 1 and meters[1].props.progress == 0.25,
        "on-demand spend must show the used fraction even in remaining quota mode")
    assert(has(labels(tree), "$1.25 / $5.00") and has(labels(tree), "On-Demand"),
        "the CLI's money text must survive metering unchanged")
    assert(not hasGlyph(tree, "clock"), "on-demand spend must not invent a reset window")
end
for _, invalid in ipairs({ { percent = 25 }, { limit = 0, percent = 25 },
    { limit = -1, percent = 25 }, { limit = math.huge, percent = 25 },
    { limit = 500 }, { limit = 500, percent = "25" }, { limit = 500, percent = 0 / 0 },
    { limit = 500, percent = math.huge }, { limit = 500, percent = -math.huge } }) do
    local tree = spendTree(invalid.limit, invalid.percent)
    assert(#collect(tree, "progress") == 0 and has(labels(tree), "$1.25 / $5.00"),
        "missing or invalid spend limits and percentages must keep the money text without a meter")
end
local stale = spendTree(500, 25, "used", true)
assert(#collect(stale, "progress") == 0 and has(labels(stale), "$1.25 / $5.00"),
    "failed providers must preserve old spend text without a live meter")
end
