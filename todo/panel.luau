--!nonstrict
-- To Do — a prioritised task list in an attached panel.
--
-- A task is { id, text, priority, done }. The whole list is persisted to
-- <todo_folder>/todo.json (noctalia.json) as an object { version, sort, tasks }:
-- `tasks` is the array (in on-disk = manual order) and `sort` records the
-- chosen ordering mode. A legacy plain-array file is still read (treated as
-- manual order, sort defaulting to "priority"). Empty (blank-text) tasks are
-- never written: they only exist transiently while being entered.
--
-- Ordering has two modes, switched from a header toggle:
--   * "priority" — a stable sort by priority (important → medium → low).
--     "Stable" means equal-priority rows keep their current relative order, so
--     re-prioritising a row only nudges it into its group and never reshuffles
--     its peers. No drag handles are shown.
--   * "manual" — the on-disk array order is used verbatim. A ☰ grip on each row
--     reorders it (see below); changing a priority only recolours the chip and
--     never moves the row. Because the noctalia plugin UI exposes no pointer
--     drag callbacks (only onClick), the grip works as a two-click grab/drop:
--     click a row's grip to pick it up (it highlights), click another row's
--     grip to drop the held row just above it, or click the held grip to cancel.
--
-- Interaction: a row is a static line by default. Click its text or the pencil
-- button to edit; press Enter or the ✓ button to commit back to the static
-- line. The coloured chip cycles the priority (a legend at the foot of the
-- panel maps each colour to its category). The ☐/☑ button toggles done, which
-- strikes the text through. A header trash button deletes every done row after
-- an inline confirmation strip (confirm/cancel) — the plugin UI has no dialog
-- primitive. No external commands are run.
--
-- The bar widget (todo.luau) lights its glyph while the panel is open via the
-- shared "todo_open" state; it reads todo.json itself for the pending count.

local PRIORITIES = { "important", "medium", "low" }
local RANK = { important = 1, medium = 2, low = 3 }
local COLORS = { important = "#e06c75", medium = "#e5c07b", low = "#98c379" }
local FILE_NAME = "todo.json"
local AUTOSAVE_IDLE_TICKS = 2 -- 1s panel ticks with no edits before a flush

local items = {} -- array, kept in display order (priority sort, or manual)
local nextId = 1 -- monotonic id source (identity only, not a sort key)
local folder = ""
local filePath = ""
local dirty = false -- unsaved inline text edits
local idleTicks = 0
local editingId = nil -- id of the row currently in edit mode (at most one)
local loaded = false -- guard so an early save() can never truncate the file
local sortMode = "priority" -- "priority" (auto sort) or "manual" (grip reorder)
local grabbedId = nil -- id of the row "picked up" by its grip, awaiting a drop
local confirmingClear = false -- header trash pressed, awaiting confirm/cancel

local render

-- Per-row callbacks need distinct global names; the reconciler dispatches
-- callbacks by name only. getfenv() is the script environment lua_getglobal
-- reads from, so assigning into it defines the callback the host will find.
-- Keyed by the stable id, so a callback stays valid as rows reorder.
local env = getfenv()
local function rowCallback(prefix, id, fn)
    local name = prefix .. "_" .. id
    env[name] = fn
    return name
end

local function tr(key, args)
    return noctalia.tr(key, args)
end

local function isBlank(text)
    return noctalia.string.trim(text or "") == ""
end

local function todoFolder()
    local dir = noctalia.getConfig("todo_folder")
    if dir == nil or dir == "" then
        dir = noctalia.expandPath("~/Documents/Todo")
    else
        dir = noctalia.expandPath(dir)
    end
    return (dir:gsub("/+$", ""))
end

-- Overlay every character with U+0336 (combining long stroke) so a plain label
-- renders struck through — labels/buttons have no line-through prop.
local function strike(text)
    if text == "" then
        return ""
    end
    local out = {}
    for _, code in utf8.codes(text) do
        table.insert(out, utf8.char(code))
        table.insert(out, "\u{0336}")
    end
    return table.concat(out)
end

local function normalizePriority(value)
    return RANK[value] ~= nil and value or "medium"
end

-- Stable sort by priority: equal-priority rows keep their current relative
-- order (decorate-by-index makes table.sort stable), and the result becomes the
-- new `items` order. Called after every mutation, so `items` is always the
-- display order and re-prioritising a row only nudges it into its group.
local function sortItems()
    local decorated = {}
    for index, item in ipairs(items) do
        decorated[index] = { item = item, index = index }
    end
    table.sort(decorated, function(a, b)
        local ra, rb = RANK[a.item.priority], RANK[b.item.priority]
        if ra ~= rb then
            return ra < rb
        end
        return a.index < b.index -- stable: keep the current within-priority order
    end)
    local sorted = {}
    for index, entry in ipairs(decorated) do
        sorted[index] = entry.item
    end
    items = sorted
end

local function findItem(id)
    for _, item in ipairs(items) do
        if item.id == id then
            return item
        end
    end
    return nil
end

local function removeItem(id)
    for i, item in ipairs(items) do
        if item.id == id then
            table.remove(items, i)
            return true
        end
    end
    return false
end

local function load()
    items = {}
    nextId = 1
    sortMode = "priority"
    local raw = noctalia.readFile(filePath)
    if raw ~= nil and raw ~= "" then
        local decoded = noctalia.json.decode(raw)
        local list = nil
        if type(decoded) == "table" then
            -- Object form { version, sort, tasks }; a legacy plain array has no
            -- `tasks` key and is read as-is (manual order, priority sort).
            if decoded.tasks ~= nil then
                if decoded.sort == "manual" or decoded.sort == "priority" then
                    sortMode = decoded.sort
                end
                list = decoded.tasks
            else
                list = decoded
            end
        end
        if type(list) == "table" then
            for _, entry in ipairs(list) do
                if type(entry) == "table" then
                    local id = tonumber(entry.id) or nextId
                    table.insert(items, {
                        id = id,
                        text = type(entry.text) == "string" and entry.text or "",
                        priority = normalizePriority(entry.priority),
                        done = entry.done == true,
                    })
                    if id >= nextId then
                        nextId = id + 1
                    end
                end
            end
        end
    end
    -- Manual mode preserves the on-disk order verbatim; only priority mode sorts.
    if sortMode == "priority" then
        sortItems()
    end
    loaded = true
end

local function save()
    if not loaded then
        return -- never write before the first load reads what is on disk
    end
    -- Blank tasks are in-progress placeholders; they never reach disk.
    local toStore = {}
    for _, item in ipairs(items) do
        if not isBlank(item.text) then
            table.insert(toStore, item)
        end
    end
    local encoded = noctalia.json.encode({ version = 2, sort = sortMode, tasks = toStore }, true)
    if encoded == nil then
        return
    end
    local ok, err = noctalia.writeFile(filePath, encoded)
    if not ok then
        noctalia.notifyError(tr("title"), err or tr("save_failed"))
        return
    end
    dirty = false
end

local function addItem()
    local item = { id = nextId, text = "", priority = "medium", done = false }
    nextId += 1
    table.insert(items, item)
    if sortMode == "priority" then
        sortItems() -- manual mode leaves the new task at the foot, unshuffled
    end
    editingId = item.id -- new task opens straight into edit mode
    render()
end

local function deleteItem(id)
    removeItem(id)
    if editingId == id then
        editingId = nil
    end
    if grabbedId == id then
        grabbedId = nil
    end
    save()
    render()
end

local function enterEdit(id)
    -- Leaving a still-blank row behind (e.g. a just-added task) would strand an
    -- empty line; drop it as we move focus elsewhere.
    if editingId ~= nil and editingId ~= id then
        local prev = findItem(editingId)
        if prev ~= nil and isBlank(prev.text) then
            removeItem(editingId)
        end
    end
    editingId = id
    render()
end

local function commitEdit(id, value)
    local item = findItem(id)
    if item == nil then
        return
    end
    item.text = value
    editingId = nil
    if isBlank(item.text) then
        removeItem(id) -- committing a blank task discards it
    end
    save()
    render()
end

local function toggleDone(id)
    local item = findItem(id)
    if item ~= nil then
        item.done = not item.done
        save()
        render()
    end
end

local function cyclePriority(id)
    local item = findItem(id)
    if item ~= nil then
        -- important → medium → low → important
        item.priority = PRIORITIES[(RANK[item.priority] % #PRIORITIES) + 1]
        -- Only priority mode reorders; manual mode just recolours the chip.
        if sortMode == "priority" then
            sortItems()
        end
        save()
        render()
    end
end

-- Switch ordering mode. Entering priority mode re-sorts immediately; either way
-- any half-finished grab is dropped and the choice is persisted.
local function setSortMode(mode)
    if mode ~= "manual" and mode ~= "priority" then
        return
    end
    sortMode = mode
    grabbedId = nil
    if sortMode == "priority" then
        sortItems()
    end
    save()
    render()
end

-- Move the grabbed row to sit just above `targetId` (manual reorder via grips).
-- A drop onto the held row itself, or onto a vanished target, simply cancels.
local function dropGrabbedOn(targetId)
    if grabbedId == nil or grabbedId == targetId then
        grabbedId = nil
        render()
        return
    end
    local grabbed = nil
    for i, item in ipairs(items) do
        if item.id == grabbedId then
            grabbed = table.remove(items, i)
            break
        end
    end
    grabbedId = nil
    if grabbed == nil then
        render()
        return
    end
    local targetIndex = #items + 1
    for i, item in ipairs(items) do
        if item.id == targetId then
            targetIndex = i
            break
        end
    end
    table.insert(items, targetIndex, grabbed)
    save()
    render()
end

local function doneCount()
    local n = 0
    for _, item in ipairs(items) do
        if item.done then
            n += 1
        end
    end
    return n
end

-- Remove every done row (the header trash, after confirmation). Editing or
-- grab state pointing at a removed row is dropped with it.
local function clearDone()
    local kept = {}
    for _, item in ipairs(items) do
        if not item.done then
            table.insert(kept, item)
        end
    end
    if #kept ~= #items then
        items = kept
        if editingId ~= nil and findItem(editingId) == nil then
            editingId = nil
        end
        if grabbedId ~= nil and findItem(grabbedId) == nil then
            grabbedId = nil
        end
        save()
    end
    confirmingClear = false
    render()
end

local function taskRow(item)
    local id = item.id
    local editing = editingId == id
    local grabbed = grabbedId == id

    -- Manual mode only: a ☰ grip that "picks up" the row, or drops the held one
    -- here. Same glyph noctalia's own bar reorder uses ("menu-2"); it lights up
    -- (primary) while this row is the one being held.
    local grip = nil
    if sortMode == "manual" then
        grip = ui.button({
            key = "grip-" .. id .. (grabbed and "-on" or ""),
            glyph = "menu-2",
            variant = grabbed and "primary" or "ghost",
            tooltip = tr(grabbed and "tip_grip_drop" or "tip_grip"),
            onClick = rowCallback("todoGrip", id, function()
                if grabbedId == nil then
                    grabbedId = id
                    render()
                else
                    dropGrabbedOn(id)
                end
            end),
        })
    end

    local chip = ui.box({
        -- priority in the key so the retained box picks up the new fill colour
        key = "chip-" .. id .. "-" .. item.priority,
        width = 16,
        height = 16,
        radius = 4,
        fill = COLORS[item.priority],
        onClick = rowCallback("todoPrio", id, function()
            cyclePriority(id)
        end),
    })
    local children = {}
    if grip ~= nil then
        table.insert(children, grip)
    end
    table.insert(children, chip)

    if editing then
        table.insert(children, ui.input({
            key = "text-" .. id,
            value = item.text,
            placeholder = tr("placeholder"),
            focus = true,
            flexGrow = 1,
            onChange = rowCallback("todoText", id, function(value)
                item.text = value
                dirty = true
                idleTicks = 0
            end),
            onSubmit = rowCallback("todoSubmit", id, function(value)
                commitEdit(id, value)
            end),
        }))
        -- ✓ commits the edit, mirroring Enter.
        table.insert(children, ui.button({
            glyph = "check",
            variant = "primary",
            tooltip = tr("tip_commit"),
            onClick = rowCallback("todoOk", id, function()
                commitEdit(id, item.text)
            end),
        }))
    else
        -- Static text; clicking it re-opens the editor ("press on the text").
        table.insert(children, ui.button({
            key = "view-" .. id,
            text = item.done and strike(item.text) or item.text,
            variant = "ghost",
            contentAlign = "start",
            flexGrow = 1,
            onClick = rowCallback("todoEdit", id, function()
                enterEdit(id)
            end),
        }))
        -- Done toggle: strikes the text through.
        table.insert(children, ui.button({
            glyph = item.done and "square-check" or "square",
            variant = "ghost",
            tooltip = tr(item.done and "tip_undone" or "tip_done"),
            onClick = rowCallback("todoDone", id, function()
                toggleDone(id)
            end),
        }))
        -- Explicit edit affordance next to the row.
        table.insert(children, ui.button({
            glyph = "pencil",
            variant = "ghost",
            tooltip = tr("tip_edit"),
            onClick = rowCallback("todoPencil", id, function()
                enterEdit(id)
            end),
        }))
    end

    table.insert(children, ui.button({
        glyph = "trash",
        variant = "ghost",
        tooltip = tr("tip_delete"),
        onClick = rowCallback("todoDel", id, function()
            deleteItem(id)
        end),
    }))

    return ui.row({
        -- edit/done/mode/grab state flips the row's controls; key it to recreate cleanly
        key = "row-"
            .. id
            .. (editing and "-edit" or "-view")
            .. (item.done and "-done" or "")
            .. (sortMode == "manual" and "-m" or "")
            .. (grabbed and "-grab" or ""),
        gap = 8,
        align = "center",
    }, children)
end

-- A footer legend mapping each chip colour to its category.
local function legendEntry(priority)
    return ui.row({ gap = 6, align = "center" }, {
        ui.box({ width = 12, height = 12, radius = 3, fill = COLORS[priority] }),
        ui.label({ text = tr("prio_" .. priority), fontSize = 11, color = "on_surface_variant" }),
    })
end

render = function()
    -- Ordering toggle: shows the current mode and flips it. "menu-2" (the grip
    -- glyph) for manual, "palette" for the colour/priority sort.
    local sortToggle = ui.button({
        key = "header-sort-" .. sortMode,
        glyph = sortMode == "manual" and "menu-2" or "palette",
        text = sortMode == "manual" and tr("sort_manual") or tr("sort_priority"),
        variant = "ghost",
        tooltip = tr("tip_sort"),
        onClick = "onSortToggle",
    })

    -- With nothing done the trash has nothing to clear; keep it visible but
    -- disabled, and fold away a confirmation left open while the last done
    -- row was toggled back.
    local done = doneCount()
    if done == 0 then
        confirmingClear = false
    end

    local header = ui.row({ align = "center", gap = 8 }, {
        ui.label({ text = tr("title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
        sortToggle,
        ui.button({
            key = "header-clear-done" .. (done == 0 and "-off" or ""),
            glyph = "trash",
            variant = "ghost",
            enabled = done > 0,
            tooltip = tr("tip_clear_done"),
            onClick = "onClearDone",
        }),
        ui.button({ key = "header-add", glyph = "plus", variant = "primary", tooltip = tr("tip_add"), onClick = "onAdd" }),
        ui.button({ key = "header-close", glyph = "close", variant = "ghost", tooltip = tr("tip_close"), onClick = "onClosePanel" }),
    })

    -- Confirmation strip for the header trash: the question plus an explicit
    -- destructive confirm and a cancel, in place of a modal (the plugin UI has
    -- no dialog primitive).
    local confirmStrip = nil
    if confirmingClear then
        confirmStrip = ui.row({ key = "confirm-clear", gap = 8, align = "center" }, {
            ui.label({ text = tr("clear_done_confirm"), color = "on_surface", flexGrow = 1 }),
            ui.button({ text = tr("clear_done_yes"), variant = "destructive", onClick = "onClearDoneConfirm" }),
            ui.button({ text = tr("clear_done_no"), variant = "ghost", onClick = "onClearDoneCancel" }),
        })
    end

    local legend = ui.column({ gap = 8 }, {
        ui.separator({}),
        ui.row({ gap = 16, align = "center", justify = "center" }, {
            legendEntry("important"),
            legendEntry("medium"),
            legendEntry("low"),
        }),
    })

    local body
    if #items == 0 then
        body = ui.column({ flexGrow = 1, align = "center", justify = "center" }, {
            ui.label({ text = tr("empty"), color = "on_surface_variant" }),
        })
    else
        local rows = {}
        for _, item in ipairs(items) do
            table.insert(rows, taskRow(item))
        end
        body = ui.scroll({ flexGrow = 1, gap = 6 }, rows)
    end

    local parts = { header }
    if confirmStrip ~= nil then
        table.insert(parts, confirmStrip)
    end
    table.insert(parts, body)
    table.insert(parts, legend)
    panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, parts))
end

function onOpen(_context)
    folder = todoFolder()
    filePath = folder .. "/" .. FILE_NAME
    local ok, err = noctalia.mkdirAll(folder)
    if not ok then
        noctalia.notifyError(tr("title"), err or "")
    end
    load()
    editingId = nil
    grabbedId = nil
    confirmingClear = false
    dirty = false
    idleTicks = 0
    panel.setWantsSecondTicks(true)
    noctalia.state.set("todo_open", true)
    render()
end

function onClose()
    editingId = nil
    grabbedId = nil
    confirmingClear = false
    if dirty then
        save()
    end
    noctalia.state.set("todo_open", false)
end

function onConfigChanged()
    if dirty then
        save()
    end
    folder = todoFolder()
    filePath = folder .. "/" .. FILE_NAME
    noctalia.mkdirAll(folder)
    editingId = nil
    grabbedId = nil
    confirmingClear = false
    load()
    render()
end

function update()
    if dirty then
        idleTicks += 1
        if idleTicks >= AUTOSAVE_IDLE_TICKS then
            save()
        end
    end
end

function onAdd()
    addItem()
end

function onSortToggle()
    setSortMode(sortMode == "manual" and "priority" or "manual")
end

function onClearDone()
    confirmingClear = true
    render()
end

function onClearDoneConfirm()
    clearDone()
end

function onClearDoneCancel()
    confirmingClear = false
    render()
end

function onClosePanel()
    panel.close()
end
