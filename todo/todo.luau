--!nonstrict
-- To Do — bar widget that toggles the task panel.
--
-- The glyph is configurable (widget setting). It lights up while the panel is
-- open (shared "todo_open" state, published by panel.luau) and its tooltip
-- shows how many tasks are still to do. The count is read straight from
-- todo.json, so it is correct before the panel is ever opened and reflects
-- edits made to the file outside noctalia.

local PANEL_ID = "nightwatch75/todo:panel"
local FILE_NAME = "todo.json"

local open = false
local pending = 0

local function todoFile()
    local dir = noctalia.getConfig("todo_folder")
    if dir == nil or dir == "" then
        dir = noctalia.expandPath("~/Documents/Todo")
    else
        dir = noctalia.expandPath(dir)
    end
    return (dir:gsub("/+$", "")) .. "/" .. FILE_NAME
end

local function pendingCount()
    local raw = noctalia.readFile(todoFile())
    if raw == nil or raw == "" then
        return 0
    end
    local decoded = noctalia.json.decode(raw)
    if type(decoded) ~= "table" then
        return 0
    end
    -- Object form { version, sort, tasks }; a legacy plain array is read as-is.
    local list = decoded.tasks ~= nil and decoded.tasks or decoded
    if type(list) ~= "table" then
        return 0
    end
    local n = 0
    for _, entry in ipairs(list) do
        if type(entry) == "table" and entry.done ~= true then
            n += 1
        end
    end
    return n
end

local function render()
    barWidget.setGlyph(noctalia.getConfig("glyph"))
    barWidget.setGlyphColor(open and "primary" or "on_surface")
    barWidget.setTooltip(noctalia.tr("tooltip", { count = pending }))
end

noctalia.state.watch("todo_open", function(value)
    open = value == true
    render()
end)

-- Periodic re-read keeps the pending count and glyph in sync with edits and
-- setting changes.
function update()
    pending = pendingCount()
    render()
end

function onClick()
    noctalia.togglePanel(PANEL_ID)
end

noctalia.setUpdateInterval(2000)
pending = pendingCount()
render()
