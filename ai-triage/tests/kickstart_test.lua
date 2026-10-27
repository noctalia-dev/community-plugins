-- Tests for 5h rolling session initiation identification and ai-kickstart button.

local function read(path)
    local file = assert(io.open(path, "r"))
    local source = file:read("*a")
    file:close()
    return source
end

local mockState = {}
local mockNoctalia = {
    state = {
        get = function(key) return mockState[key] end,
        set = function(key, val) mockState[key] = val end,
        watch = function() end,
    },
    tr = function(key, args)
        if key == "ui.quota_reset" and args then return key .. ": " .. args.time end
        if key == "ui.now" then return "now" end
        return key
    end,
    string = {
        trim = function(value) return tostring(value):match("^%s*(.-)%s*$") end,
    },
    formatTime = function(fmt, timestamp)
        return os.date(fmt or "%H:%M", timestamp)
    end,
    timeFormat = function() return "%H:%M" end,
    nowMs = function() return 1000 end,
    commandExists = function() return false end,
    runAsync = function() return true end,
    openSettings = function() end,
}

local sharedEnv = setmetatable({ noctalia = mockNoctalia }, { __index = _G })
local shared = assert(load(read("shared.luau"), "shared", "t", sharedEnv))()

-- 1. Unit tests for shared.isSessionStarted
local now = os.time()
local futureIso = os.date("!%Y-%m-%dT%H:%M:%SZ", now + 7200)
local pastIso = os.date("!%Y-%m-%dT%H:%M:%SZ", now - 3600)
local fullWindowIso = os.date("!%Y-%m-%dT%H:%M:%SZ", now + 17950)
local claudeSlotIso = os.date("!%Y-%m-%dT%H:%M:%SZ", now + 17100)
local activeCountdownIso = os.date("!%Y-%m-%dT%H:%M:%SZ", now + 6480)

assert(shared.isSessionStarted({ percent = 5 }) == true,
    "percent > 0 must mean session is started")

assert(shared.isSessionStarted({ percent = 0, reset_at = futureIso }) == true,
    "percent == 0 with 2h left (60% elapsed) must mean session is started")

assert(shared.isSessionStarted({ percent = 0, reset_at = pastIso }) == false,
    "percent == 0 with past reset_at must mean session is not started")

assert(shared.isSessionStarted({ percent = 0, reset_at = nil }) == false,
    "percent == 0 without reset_at must mean session is not started")

assert(shared.isSessionStarted({ percent = 0, detail = "Resets in 2h 17m · 54% elapsed" }) == true,
    "detail with active countdown (< 4h 30m remaining) must mean session is started")

assert(shared.isSessionStarted({ percent = 0, reset_at = activeCountdownIso, detail = "Resets in 1h 48m · 63% elapsed · 63pts under" }) == true,
    "Codex active session with 1h 48m left must mean session is started")

assert(shared.isSessionStarted({ percent = 0, reset_at = fullWindowIso, detail = "Resets in 4h 59m · 0% elapsed · on track" }) == false,
    "Codex fresh session (4h 59m left, 0% elapsed) must mean session is not started")

assert(shared.isSessionStarted({ percent = 0, reset_at = claudeSlotIso, detail = "Resets in 4h 45m · 4% elapsed · 4pts under" }) == false,
    "Claude fresh session (4h 45m left, 4% elapsed) must mean session is not started")

assert(shared.isSessionStarted({ percent = 0, reset_at = fullWindowIso, detail = "Resets in 4h 59m" }) == false,
    "Antigravity Claude & GPT OSS fresh session (4h 59m left) must mean session is not started")

assert(shared.isSessionStarted({ percent = 0, started = true, reset_at = fullWindowIso }) == true,
    "metric with started == true must mean session is started even at 0% and full window")

assert(shared.isSessionStarted({ percent = 1, reset_at = fullWindowIso }) == true,
    "metric with percent = 1 must mean session is started even with full window")

assert(shared.isSessionStarted(nil) == false,
    "nil metric must return false")

-- 2. Panel component tests for Start 5h button visibility
local function collect(node, kind, found)
    found = found or {}
    if type(node) ~= "table" then return found end
    if node.kind == kind then found[#found + 1] = node end
    for _, child in ipairs(node.children or {}) do collect(child, kind, found) end
    for _, child in ipairs(node) do collect(child, kind, found) end
    return found
end

local function buttonsWithText(tree, text)
    local out = {}
    for _, btn in ipairs(collect(tree, "button")) do
        if btn.props and btn.props.text == text then
            out[#out + 1] = btn
        end
    end
    return out
end

local function hasLabel(tree, text)
    for _, lbl in ipairs(collect(tree, "label")) do
        if lbl.props and lbl.props.text == text then
            return true
        end
    end
    return false
end

local function loadPanelWithReport(report, extraState)
    local prevKickstart = mockState and mockState.kickstarted_at
    mockState = {
        report = report,
        error = { code = "", detail = "" },
        selected = report.entries and report.entries[1] and report.entries[1].id or nil,
        kickstarted_at = extraState and extraState.kickstarted_at or prevKickstart,
    }
    local panelDrawn = nil
    local panelObj = {
        render = function(tree) panelDrawn = tree end,
        setWantsSecondTicks = function() end,
    }
    local ui = setmetatable({}, {
        __index = function(_, kind)
            return function(props, children)
                return { kind = kind, props = props or {}, children = children or {} }
            end
        end,
    })
    local env = setmetatable({
        noctalia = mockNoctalia,
        ui = ui,
        panel = panelObj,
        require = function(path)
            assert(path == "./shared.luau")
            return shared
        end,
    }, { __index = _G })
    assert(load(read("panel.luau"), "panel", "t", env))()
    env.onOpen()
    return panelDrawn
end

-- Test scenario: 2 providers in 3-column layout:
-- Codex: 0% usage, but 5h period has ALREADY started (future reset_at, e.g. resets in 2h 17m).
-- Claude: 0% usage, 5h period NOT started (no reset_at).
local testReport = {
    entries = {
        {
            id = "openai",
            display_name = "Codex",
            status = "ready",
            metrics = {
                {
                    label = "Codex 5h",
                    percent = 0,
                    value = "0%",
                    reset_at = futureIso,
                    detail = "Resets in 2h 17m · 54% elapsed",
                    window_secs = 18000,
                },
                {
                    label = "Codex weekly",
                    percent = 28,
                    value = "28%",
                    reset_at = os.date("!%Y-%m-%dT%H:%M:%SZ", now + 400000),
                    window_secs = 604800,
                },
            },
        },
        {
            id = "anthropic",
            display_name = "Claude",
            status = "ready",
            metrics = {
                {
                    label = "Session (5h)",
                    percent = 0,
                    value = "0%",
                    reset_at = nil,
                    detail = "",
                    window_secs = 18000,
                },
                {
                    label = "Weekly (7d)",
                    percent = 10,
                    value = "10%",
                    reset_at = os.date("!%Y-%m-%dT%H:%M:%SZ", now + 400000),
                    window_secs = 604800,
                },
            },
        },
    },
}

local panelTree = loadPanelWithReport(testReport)
local startButtons = buttonsWithText(panelTree, "Start 5h")

assert(#startButtons == 1,
    "Expected exactly 1 'Start 5h' button (only for unstarted Claude, NOT for active Codex). Got: " .. #startButtons)

-- Verify Codex (started with <2h left) has NO kickstart button and its triage badge is NOT 'Fresh'
assert(not hasLabel(panelTree, "session not started"),
    "Codex must not be labeled as session not started")

-- Test scenario 2: Both Codex and Claude are unstarted at start of day
-- (Codex reports synthetic 4h 59m · 0% elapsed; Claude reports slot 4h 45m · 4% elapsed, both 0% used)
testReport.entries[1].metrics[1].reset_at = fullWindowIso
testReport.entries[1].metrics[1].detail = "Resets in 4h 59m · 0% elapsed · on track"
testReport.entries[1].metrics[1].percent = 0
testReport.entries[1].metrics[1].value = "0%"
testReport.entries[2].metrics[1].reset_at = claudeSlotIso
testReport.entries[2].metrics[1].detail = "Resets in 4h 45m · 4% elapsed · 4pts under"
testReport.entries[2].metrics[1].percent = 0
testReport.entries[2].metrics[1].value = "0%"
local panelTree2 = loadPanelWithReport(testReport)
local startButtons2 = buttonsWithText(panelTree2, "Start 5h")
assert(#startButtons2 == 2,
    "When both Codex and Claude 5h windows are unstarted at start of day, both should show 'Start 5h'. Got: " .. #startButtons2)
assert(hasLabel(panelTree2, "--:--"),
    "Unstarted sessions must display '--:--' clock placeholder to maintain card alignment")

-- Test scenario 3: Claude is actively consumed (>0%) while Codex remains unstarted
testReport.entries[2].metrics[1].percent = 15
testReport.entries[2].metrics[1].value = "15%"
testReport.entries[2].metrics[1].reset_at = claudeSlotIso
testReport.entries[2].metrics[1].detail = "Resets in 4h 45m · 4% elapsed · 4pts under"
local panelTree3 = loadPanelWithReport(testReport)
local startButtons3 = buttonsWithText(panelTree3, "Start 5h")
assert(#startButtons3 == 1,
    "When Claude is actively started, only unstarted Codex should show Start 5h. Got: " .. #startButtons3)
assert(hasLabel(panelTree3, "--:--"),
    "Unstarted Codex must display '--:--' while active Claude displays its clock")

-- Test scenario 3b: Codex has 0% usage, remaining > 90% (4h 53m left), but was just kickstarted!
-- It must display its reset clock (NOT '--:--'), show '5h rolling', and hide 'Start 5h'.
testReport.entries[1].metrics[1].percent = 0
testReport.entries[1].metrics[1].value = "0%"
testReport.entries[1].metrics[1].reset_at = fullWindowIso
testReport.entries[1].metrics[1].detail = "Resets in 4h 53m · 2% elapsed · 2pts under"
mockState.kickstarted_at = { codex = now - 420 }
local panelTree3b = loadPanelWithReport(testReport)
local startButtons3b = buttonsWithText(panelTree3b, "Start 5h")
assert(#startButtons3b == 0,
    "When Codex was kickstarted and Claude is active, 0 Start 5h buttons should appear. Got: " .. #startButtons3b)
assert(not hasLabel(panelTree3b, "--:--"),
    "Kickstarted Codex with 0% usage must display its clock time, NOT '--:--'")
assert(hasLabel(panelTree3b, "5h rolling"),
    "Kickstarted Codex must display '5h rolling' pill")
mockState.kickstarted_at = nil

-- Test scenario 4: Both are active (Codex also consumed quota)
testReport.entries[1].metrics[1].percent = 5
testReport.entries[1].metrics[1].value = "5%"
local panelTree4 = loadPanelWithReport(testReport)
local startButtons4 = buttonsWithText(panelTree4, "Start 5h")
assert(#startButtons4 == 0,
    "When both are active, 0 'Start 5h' buttons should appear. Got: " .. #startButtons4)
assert(not hasLabel(panelTree4, "--:--"),
    "When both are active, no '--:--' placeholder should appear")
assert(hasLabel(panelTree4, "5h rolling"),
    "Active sessions should display '5h rolling' pill for alignment with 7d gearing")

-- Test scenario 5: Provider without kickstart target (e.g. openrouter) at 0%
local nonKickstartReport = {
    entries = {
        {
            id = "openrouter",
            display_name = "OpenRouter",
            status = "ready",
            metrics = {
                { label = "Session", percent = 0, value = "0%", reset_at = nil, window_secs = 18000 },
            },
        },
        {
            id = "openai",
            display_name = "Codex",
            status = "ready",
            metrics = {
                { label = "Session", percent = 0, value = "0%", reset_at = futureIso, window_secs = 18000 },
            },
        },
    },
}
local panelTree5 = loadPanelWithReport(nonKickstartReport)
local startButtons5 = buttonsWithText(panelTree5, "Start 5h")
assert(#startButtons5 == 0,
    "Non-kickstart provider (openrouter) must not display Start 5h button. Got: " .. #startButtons5)

-- Test scenario 6: Host refuses launch (runAsync returns false)
-- Verifies that kickstarting[target] is cleared and a second click is permitted
testReport.entries[1].metrics[1].percent = 0
testReport.entries[1].metrics[1].value = "0%"
testReport.entries[1].metrics[1].reset_at = nil
testReport.entries[1].metrics[1].detail = ""
local runAsyncCalls = 0
mockNoctalia.runAsync = function(cmd, cb, timeout)
    runAsyncCalls = runAsyncCalls + 1
    return false
end
local panelTree6 = loadPanelWithReport(testReport)
local startBtns6 = buttonsWithText(panelTree6, "Start 5h")
assert(#startBtns6 == 1, "Expected 1 'Start 5h' button initially")
startBtns6[1].props.onClick()
assert(runAsyncCalls == 1, "runAsync should have been called once on first click")
startBtns6[1].props.onClick()
assert(runAsyncCalls == 2, "Second click must produce a second launch attempt when runAsync returned false")

-- Test scenario 7: Antigravity with Gemini and Claude & GPT OSS unstarted
local antigravityReport = {
    entries = {
        {
            id = "openai",
            display_name = "Codex",
            status = "ready",
            metrics = {
                { label = "Session", percent = 20, value = "20%", reset_at = futureIso, window_secs = 18000 },
            },
        },
        {
            id = "antigravity",
            display_name = "Antigravity",
            status = "ready",
            metrics = {
                { label = "Gemini", percent = 0, value = "0%", reset_at = nil, window_secs = 18000 },
                { label = "Claude & GPT OSS", percent = 0, value = "0%", reset_at = nil, window_secs = 18000 },
                { label = "Gemini", percent = 10, value = "10%", reset_at = os.date("!%Y-%m-%dT%H:%M:%SZ", now + 400000), window_secs = 604800 },
                { label = "Claude & GPT OSS", percent = 15, value = "15%", reset_at = os.date("!%Y-%m-%dT%H:%M:%SZ", now + 400000), window_secs = 604800 },
            },
        },
    },
}
local lastCmdRun = nil
mockNoctalia.runAsync = function(cmd, cb)
    lastCmdRun = cmd
    return true
end
local agyPanelTree = loadPanelWithReport(antigravityReport)
local agyStartBtns = buttonsWithText(agyPanelTree, "Start 5h")
assert(#agyStartBtns == 2, "Both Gemini and Claude & GPT OSS should have Start 5h buttons when unstarted. Got: " .. #agyStartBtns)
assert(not hasLabel(agyPanelTree, "Antigravity"), "Gemini and Claude & GPT OSS should not have an [Antigravity] badge")

-- Click both and verify their targets (Gemini has better triage score with 10% weekly vs 15%)
agyStartBtns[1].props.onClick()
assert(lastCmdRun:find("gemini"), "First button (Gemini) should target gemini. Got: " .. tostring(lastCmdRun))
agyStartBtns[2].props.onClick()
assert(lastCmdRun:find("claude%-oss"), "Second button (Claude & GPT OSS) should target claude-oss. Got: " .. tostring(lastCmdRun))

-- Test scenario 8: Provider with weekly quota 100% exhausted must NOT show 'Start 5h'
-- even if session is 0% / unstarted.
antigravityReport.entries[2].metrics[4].percent = 100 -- Claude & GPT OSS weekly is now 100%
antigravityReport.entries[2].metrics[4].value = "100%"
local agyPanelTreeExhausted = loadPanelWithReport(antigravityReport)
local agyStartBtnsExhausted = buttonsWithText(agyPanelTreeExhausted, "Start 5h")
assert(#agyStartBtnsExhausted == 1,
    "When Claude & GPT OSS weekly is 100% exhausted, only Gemini (10% weekly) should show Start 5h. Got: " .. #agyStartBtnsExhausted)

io.write("ok: all 5h session initiation scenarios and kickstart button tests passed!\n")
