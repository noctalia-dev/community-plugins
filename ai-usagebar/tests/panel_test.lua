-- Host harness for malformed collection handling in panel.luau.

local function read(path)
    local file = assert(io.open(path, "r"))
    local source = file:read("*a")
    file:close()
    return source
end

local function loadPanel(entry, failure)
    local watchers = {}
    local values = {
        report = { entries = { entry } },
        error = failure or { code = "", detail = "" },
        selected = entry.id,
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
        if column.props.fill == "surface_variant/0.45" and #collect(column, "progress") > 0 then
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

-- Down: the CLI keeps serving what it cached and says why it stopped moving.
local DOWN = {}
for index, section in ipairs(WINDOWS) do DOWN[index] = section end
DOWN[#DOWN + 1] = { type = "title", value = "Account" }
DOWN[#DOWN + 1] = { type = "text", label = "Balance", value = "$4.20" }
DOWN[#DOWN + 1] = { type = "block", label = "Credits", body = { "granted: 100" } }
DOWN[#DOWN + 1] = { type = "text", label = "Warning",
                    value = "credentials error: Antigravity: no local server found." }

local downTree = loadPanel(withSections(DOWN))
assert(#cards(downTree) == 0, "a provider that is down draws no gauges")
assert(#collect(downTree, "progress") == 0, "and no bars either")
local warned = false
for _, glyph in ipairs(collect(downTree, "glyph")) do
    if glyph.props.name == "alert-triangle" then warned = true end
end
assert(warned, "the warning takes their place")
local downLabels = labels(downTree)
assert(not has(downLabels, "credentials error: Antigravity: no local server found."),
       "the CLI's log prefix is dropped")
assert(has(downLabels, "Antigravity: no local server found."), "the warning itself survives")
-- The numbers survive as a record, in text.
assert(has(downLabels, "ui.last_reading_now") or has(downLabels, "ui.last_reading"),
       "the last reading is kept")
assert(has(downLabels, "Session 3% · Weekly 8%"), "set as text, not as a gauge")
-- Dropping the gauges is not dropping the report. Everything the CLI said
-- besides the readings is still the CLI talking about this provider.
assert(has(downLabels, "Account"), "a heading the CLI sent survives")
assert(has(downLabels, "Balance") and has(downLabels, "$4.20"), "so does its free text")
assert(has(downLabels, "Credits") and has(downLabels, "granted: 100"), "and its blocks")
local warnings = 0
for _, label in ipairs(downLabels) do
    if label == "Antigravity: no local server found." then warnings = warnings + 1 end
end
assert(warnings == 1, "the warning itself is said once, at the top")

-- One fetch, one date. The record already says how old the numbers are, so the
-- header must not date the same fetch again in the other tense.
for _, label in ipairs(downLabels) do
    -- The header concatenates the age with a clock time, so match on the key.
    assert(label:find("ui.updated", 1, true) == nil,
           "a provider that is down is dated once, by its record")
end

-- A plan carries the limits every percentage is measured against, so readings
-- taken under the previous one are dropped rather than shown under the new name.
local _, publish = loadPanel(withSections(WINDOWS, "Google AI Pro"))
local switched = labels(publish(withSections(DOWN, "Google AI Ultra")))
assert(has(switched, "ui.plan_changed"), "the change is said out loud")
assert(not has(switched, "ui.last_reading_now") and not has(switched, "ui.last_reading"),
       "and the old readings are not kept")

-- Same provider, same plan: the record stands.
local _, again = loadPanel(withSections(WINDOWS, "Google AI Pro"))
local kept = labels(again(withSections(DOWN, "Google AI Pro")))
assert(has(kept, "ui.last_reading_now") or has(kept, "ui.last_reading"),
       "an unchanged plan keeps its record")

-- A provider that falls over can stop naming its plan at all. Silence is not a
-- new plan, and the reading it was last seen with is still worth keeping.
local _, silenced = loadPanel(withSections(WINDOWS, "Google AI Pro"))
local nameless = withSections(DOWN, "Google AI Pro")
nameless.plan = nil
local quiet = labels(silenced(nameless))
assert(not has(quiet, "ui.plan_changed"), "an omitted plan is not a plan change")
assert(has(quiet, "ui.last_reading_now") or has(quiet, "ui.last_reading"),
       "so the record it was last seen with stands")

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
local plain = cards(loadPanel(paced))
assert(#plain == 1, "the session and the week share one card here too")
local plainLabels = labels(plain[1])
assert(plainLabels[1] == "Codex 5h", "the reading heads itself")
assert(has(plainLabels, "Codex weekly"), "the week sits under the session")

-- The panel outlives every report it draws, so what it remembers between them is
-- only the providers the current one carries. A provider the user removed and
-- added back is met like any other first reading, not accused of a change.
local _, sequence = loadPanel(withSections(WINDOWS, "Google AI Pro"))
sequence(paced)
local returned = labels(sequence(withSections(DOWN, "Google AI Ultra")))
assert(not has(returned, "ui.plan_changed"), "a provider gone from the report is forgotten")
assert(has(returned, "ui.last_reading_now") or has(returned, "ui.last_reading"),
       "and what it does report is kept")

-- A failed read with a report behind it is a banner over numbers that are merely
-- older than the panel would like, not a reason to blank the panel.
local failed = loadPanel(paced, { code = "timed_out", detail = "" })
local failedLabels = labels(failed)
assert(has(failedLabels, "ui.error.timed_out"), "the failure is named")
assert(has(failedLabels, "Codex 5h"), "and the readings stay under it")
assert(#cards(failed) == 1, "the cards are not dropped")

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

io.write("ok: panel degrades safely, groups by model, and stops gauging what is down\n")
