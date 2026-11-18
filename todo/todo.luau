--!nonstrict
-- To Do — bar widget that toggles the task panel.
--
-- The glyph is configurable (widget setting). It lights up while the panel is
-- open (shared "todo_open" state, published by panel.luau). An optional bar
-- label can include the total task count unless the panel's header hash toggle
-- turned that off; the tooltip shows how many tasks are still to do. Everything
-- is read straight from todo.json, so it is
-- correct before the panel is ever opened and reflects edits made to the file
-- outside noctalia.
--
-- Overdue: a task whose due date has passed (dates.isOverdue, the one shared
-- rule) turns the glyph into an alarm that blinks error/normal each tick, with
-- "N overdue" as the label. The widget derives this from the file and the
-- clock alone and never writes to it.
-- The optional overdue sound plays when the count rises (not for what was
-- already overdue at load). With several bars every instance sees the same
-- rise, so the first to chime stamps "todo_overdue_chime" in the shared plugin
-- state and the others stay quiet for a few seconds.
--
-- Left click is NOT wired here: plugin.toml declares it as a [widget.actions]
-- default (`left = "panel-toggle nightwatch75/todo:panel"`, plugin_api >= 14),
-- which lets the user remap the gesture from the bar's own settings. A bound
-- gesture is taken off this widget's own input area entirely, so an onClick()
-- here would simply never run.

local dates = require("./dates.luau")

local FILE_NAME = "todo.json"
local OVERDUE_SOUND = "todo-overdue" -- name registered with noctalia.sound.load
local TICK_MS, BLINK_TICK_MS = 2000, 1000
local CHIME_QUIET_S = 5 -- another instance's chime this recent silences ours
local MAX_FAILED_READS = 3 -- consecutive nil reads before the file counts as gone

local open = false
local pending = 0
local total = 0
local showCount = true
local reading = false -- a readFileAsync is in flight
local overdue = 0 -- tasks past their due date
local blinkOn = false -- current phase of the overdue blink
local lastOverdue = nil -- overdue count of the previous read; nil until the first read
local soundReady = false
local tickMs = TICK_MS
local failedReads = 0 -- consecutive reads that returned no data
local watchedFile = nil -- the file lastOverdue refers to

local function todoFile()
    local dir = noctalia.getConfig("todo_folder")
    if dir == nil or dir == "" then
        dir = noctalia.expandPath("~/Documents/Todo")
    else
        dir = noctalia.expandPath(dir)
    end
    return (dir:gsub("/+$", "")) .. "/" .. FILE_NAME
end

-- Returns pending (not-done), total, showCount, overdue. Counts are 0 on a
-- missing/empty/malformed file; showCount defaults true (the panel header's
-- hash toggle, off only when explicitly turned off).
local function counts(raw)
    if raw == nil or raw == "" then
        return 0, 0, true, 0
    end
    local decoded = noctalia.json.decode(raw)
    if type(decoded) ~= "table" then
        return 0, 0, true, 0
    end
    -- Object form { version, sort, showCount, tasks }; a legacy plain array
    -- is read as-is, with showCount defaulting to true.
    local list = decoded.tasks ~= nil and decoded.tasks or decoded
    if type(list) ~= "table" then
        return 0, 0, true, 0
    end
    local pendingN, totalN, overdueN = 0, 0, 0
    local now = os.time()
    for _, entry in ipairs(list) do
        if type(entry) == "table" then
            totalN += 1
            if entry.done ~= true then
                pendingN += 1
            end
            local due, allDay = dates.normalizeDue(entry)
            if dates.isOverdue({ done = entry.done == true, due = due, allDay = allDay }, now) then
                overdueN += 1
            end
        end
    end
    return pendingN, totalN, decoded.showCount ~= false, overdueN
end

-- Renders the "· N todos" suffix per the count_mode widget setting: "total"
-- (default, matches 1.2.1) shows the full list size, "pending" shows only
-- not-done tasks, "both" shows "pending/total todos" (community-plugins#867).
local function countSuffix()
    local mode = noctalia.getConfig("count_mode") or "total"
    if mode == "pending" then
        local key = pending == 1 and "bar_count_singular" or "bar_count_plural"
        return noctalia.tr(key, { count = pending })
    elseif mode == "both" then
        return noctalia.tr("bar_count_both", { pending = pending, total = total })
    else
        local key = total == 1 and "bar_count_singular" or "bar_count_plural"
        return noctalia.tr(key, { count = total })
    end
end

local function render()
    if overdue > 0 then
        -- Overdue replaces the glyph and label, even with show_label off.
        barWidget.setGlyph("alarm")
        barWidget.setGlyphColor(blinkOn and "error" or "on_surface")
        barWidget.setText(noctalia.tr("bar_overdue", { count = overdue }))
        barWidget.setTooltip(noctalia.tr("tooltip_overdue", { count = overdue }))
        return
    end
    barWidget.setGlyph(noctalia.getConfig("glyph"))
    barWidget.setGlyphColor(open and "primary" or "on_surface")
    if noctalia.getConfig("show_label") == false then
        barWidget.setText("")
    else
        local label = noctalia.getConfig("label") or "To Do"
        if showCount then
            local count = countSuffix()
            label = label ~= "" and label .. " · " .. count or count
        end
        barWidget.setText(label)
    end
    barWidget.setTooltip(noctalia.tr("tooltip", { count = pending }))
end

-- Re-read the count off disk, off the UI thread (noctalia.readFileAsync,
-- plugin_api >= 23). This runs every 2 seconds forever, and the synchronous
-- readFile it replaces blocked the bar for the whole read — unnoticeable on a
-- warm local file, not on a todo.json that lives on a sleeping disk or a
-- network share, which is exactly the setup a shared task list invites.
--
-- One read at a time: the host allows 4 in flight per plugin, and a read
-- slower than the tick would otherwise stack them until it starts refusing.
-- A refused or failed read leaves the last known counts on screen rather than
-- flashing a 0 — except when the file genuinely reads as empty or unparseable,
-- which counts() answers with 0, 0, true as before.
local function refreshPending()
    if reading then
        return
    end
    reading = true
    local file = todoFile()
    local ok = noctalia.readFileAsync(file, function(data, err)
        reading = false
        if data == nil then
            -- A missing file keeps the last counts; MAX_FAILED_READS failures
            -- in a row count it as empty.
            local _ = err
            failedReads += 1
            if failedReads == MAX_FAILED_READS and overdue > 0 then
                pending, total, overdue = 0, 0, 0
                render()
            end
            return
        end
        failedReads = 0
        local pendingN, totalN, showCountN, overdueN = counts(data)
        -- A different file resets the sound baseline.
        if file ~= watchedFile then
            watchedFile = file
            lastOverdue = nil
        end
        if lastOverdue ~= nil and overdueN > lastOverdue and soundReady and noctalia.getConfig("sound_on_overdue") then
            local last = noctalia.state.get("todo_overdue_chime")
            if type(last) ~= "number" or os.time() - last >= CHIME_QUIET_S then
                noctalia.state.set("todo_overdue_chime", os.time())
                noctalia.sound.play(OVERDUE_SOUND)
            end
        end
        lastOverdue = overdueN
        if pendingN ~= pending or totalN ~= total or showCountN ~= showCount or overdueN ~= overdue then
            pending = pendingN
            total = totalN
            showCount = showCountN
            overdue = overdueN
            render()
        end
        -- Blink needs a faster tick; drop back once nothing is overdue.
        local want = overdue > 0 and BLINK_TICK_MS or TICK_MS
        if want ~= tickMs then
            tickMs = want
            noctalia.setUpdateInterval(want)
        end
    end)
    if not ok then
        reading = false
    end
end

noctalia.state.watch("todo_open", function(value)
    open = value == true
    render()
end)

-- Periodic re-read keeps the pending count and glyph in sync with edits and
-- setting changes.
function update()
    refreshPending()
    blinkOn = overdue > 0 and not blinkOn
    render()
end

noctalia.sound.load(OVERDUE_SOUND, "sounds/task-complete.wav", function(ok)
    soundReady = ok == true
end)
noctalia.setUpdateInterval(TICK_MS)
refreshPending()
render()
