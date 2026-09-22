--!nonstrict
-- To Do — bar widget that toggles the task panel.
--
-- The glyph is configurable (widget setting). It lights up while the panel is
-- open (shared "todo_open" state, published by panel.luau), carries the total
-- task count as a "N todo(s)" label next to it (barWidget.setText) unless the
-- panel's header hash toggle turned that off, and its tooltip shows how many
-- tasks are still to do. Everything is read straight from todo.json, so it is
-- correct before the panel is ever opened and reflects edits made to the file
-- outside noctalia.
--
-- Left click is NOT wired here: plugin.toml declares it as a [widget.actions]
-- default (`left = "panel-toggle nightwatch75/todo:panel"`, plugin_api >= 14),
-- which lets the user remap the gesture from the bar's own settings. A bound
-- gesture is taken off this widget's own input area entirely, so an onClick()
-- here would simply never run.

local FILE_NAME = "todo.json"

local open = false
local pending = 0
local total = 0
local showCount = true
local reading = false -- a readFileAsync is in flight

local function todoFile()
    local dir = noctalia.getConfig("todo_folder")
    if dir == nil or dir == "" then
        dir = noctalia.expandPath("~/Documents/Todo")
    else
        dir = noctalia.expandPath(dir)
    end
    return (dir:gsub("/+$", "")) .. "/" .. FILE_NAME
end

-- Returns pending (not-done), total, showCount. Counts are 0 on a
-- missing/empty/malformed file; showCount defaults true (the panel header's
-- hash toggle, off only when explicitly turned off).
local function counts(raw)
    if raw == nil or raw == "" then
        return 0, 0, true
    end
    local decoded = noctalia.json.decode(raw)
    if type(decoded) ~= "table" then
        return 0, 0, true
    end
    -- Object form { version, sort, showCount, tasks }; a legacy plain array
    -- is read as-is, with showCount defaulting to true.
    local list = decoded.tasks ~= nil and decoded.tasks or decoded
    if type(list) ~= "table" then
        return 0, 0, true
    end
    local pendingN, totalN = 0, 0
    for _, entry in ipairs(list) do
        if type(entry) == "table" then
            totalN += 1
            if entry.done ~= true then
                pendingN += 1
            end
        end
    end
    return pendingN, totalN, decoded.showCount ~= false
end

local function render()
    barWidget.setGlyph(noctalia.getConfig("glyph"))
    barWidget.setGlyphColor(open and "primary" or "on_surface")
    if showCount then
        local key = total == 1 and "bar_count_singular" or "bar_count_plural"
        barWidget.setText(noctalia.tr(key, { count = total }))
    else
        barWidget.setText("")
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
    local ok = noctalia.readFileAsync(todoFile(), function(data, err)
        reading = false
        if data == nil then
            -- No file yet is the normal state before the first task, so this
            -- is not worth a log line; the count simply stays where it was.
            local _ = err
            return
        end
        local pendingN, totalN, showCountN = counts(data)
        if pendingN ~= pending or totalN ~= total or showCountN ~= showCount then
            pending = pendingN
            total = totalN
            showCount = showCountN
            render()
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
    render()
end

noctalia.setUpdateInterval(2000)
refreshPending()
render()
