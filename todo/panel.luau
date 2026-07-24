--!nonstrict
-- To Do — a prioritised task list in an attached panel.
--
-- A task is { id, text, priority, done }. The whole list is persisted to
-- <todo_folder>/todo.json (noctalia.json) as an object { version, sort, tasks }:
-- `tasks` is the array — ALWAYS in manual order — and `sort` records the chosen
-- display mode. A legacy plain-array file is still read (treated as manual
-- order, sort defaulting to "priority"). Empty (blank-text) tasks are never
-- written: they only exist transiently while being entered.
--
-- Ordering has two modes, switched from a header toggle. `items` (and the disk
-- array) hold the manual order in both; priority mode is a VIEW — a stable sort
-- applied at render time only — so switching modes never rewrites the user's
-- manual order:
--   * "priority" — rows display sorted important → medium → low; equal-priority
--     rows keep their manual relative order. No drag handles are shown.
--   * "manual" — the stored order is shown verbatim. A ☰ grip on each row
--     drags it to a new position (declarative drag-and-drop, plugin_api >= 5):
--     grab the grip and drop onto one of the thin insertion zones between rows.
--     Changing a priority only recolours the chip and never moves the row.
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
local DRAG_TYPE = "todo-row" -- drag identifier matched by the row drop zones

local items = {} -- array, ALWAYS in manual order (priority mode sorts a copy for display)
local nextId = 1 -- monotonic id source (identity only, not a sort key)
local folder = ""
local filePath = ""
local dirty = false -- unsaved inline text edits
local idleTicks = 0
local editingId = nil -- id of the row currently in edit mode (at most one)
local loaded = false -- guard so an early save() can never truncate the file
local sortMode = "priority" -- "priority" (auto sort) or "manual" (drag reorder)
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
-- utf8.codes THROWS on invalid UTF-8, and render() would re-raise it on every
-- frame until the host disables the plugin; utf8.len returns nil instead, so
-- gate on it and fall back to the plain text (the ☑ still marks it done).
local function strike(text)
    if text == "" or utf8.len(text) == nil then
        return text
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

-- The rows to render, in display order. `items` itself is never reordered by
-- priority mode: it sorts a COPY (stable by priority via decorate-by-index, so
-- equal-priority rows keep their manual relative order). Keeping the sort out
-- of the model is what preserves the manual order across mode switches.
local function displayItems()
    if sortMode ~= "priority" then
        return items
    end
    local decorated = {}
    for index, item in ipairs(items) do
        decorated[index] = { item = item, index = index }
    end
    table.sort(decorated, function(a, b)
        local ra, rb = RANK[a.item.priority], RANK[b.item.priority]
        if ra ~= rb then
            return ra < rb
        end
        return a.index < b.index -- stable: keep the manual within-priority order
    end)
    local sorted = {}
    for index, entry in ipairs(decorated) do
        sorted[index] = entry.item
    end
    return sorted
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
    -- The on-disk order IS the manual order; priority mode sorts at render time.
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
    -- Appended at the foot of the manual order; the priority view shows it at
    -- the foot of its group.
    table.insert(items, item)
    editingId = item.id -- new task opens straight into edit mode
    render()
end

local function deleteItem(id)
    removeItem(id)
    if editingId == id then
        editingId = nil
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
        -- important → medium → low → important. The manual position is
        -- untouched; the priority view re-sorts on render.
        item.priority = PRIORITIES[(RANK[item.priority] % #PRIORITIES) + 1]
        save()
        render()
    end
end

-- Switch ordering mode. Only the `sort` choice is persisted — the task array
-- is never rewritten, so the manual order survives any number of round trips
-- through priority mode.
local function setSortMode(mode)
    if mode ~= "manual" and mode ~= "priority" then
        return
    end
    sortMode = mode
    save()
    render()
end

-- Move task `id` to sit at manual position `insertAt` (1-based, in `items`).
-- The insertion zones number the gaps 1..#items+1, so `insertAt` is where the
-- row lands before removing itself; drop onto its own gap is a no-op. Only
-- reachable in manual mode, where the render order IS the `items` order.
local function moveItemTo(id, insertAt)
    local fromIndex = nil
    for i, item in ipairs(items) do
        if item.id == id then
            fromIndex = i
            break
        end
    end
    if fromIndex == nil or type(insertAt) ~= "number" then
        return
    end
    local moved = table.remove(items, fromIndex)
    -- Removing the row shifts every later gap down by one.
    if fromIndex < insertAt then
        insertAt -= 1
    end
    insertAt = math.max(1, math.min(insertAt, #items + 1))
    table.insert(items, insertAt, moved)
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

-- Remove every done row (the header trash, after confirmation). Editing state
-- pointing at a removed row is dropped with it.
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
        save()
    end
    confirmingClear = false
    render()
end

local function taskRow(item)
    local id = item.id
    local editing = editingId == id

    -- Manual mode only: a ☰ grip that drags the whole row to a new position.
    -- The grip is a drag source holding the glyph, but previewAncestor = 1
    -- makes the drag ghost the whole row and liftFromLayout pulls the row out
    -- of the list while it moves; the thin insertion zones between rows are the
    -- drop targets. Same glyph noctalia's own bar reorder uses ("menu-2").
    local grip = nil
    if sortMode == "manual" then
        grip = ui.dragSource({
            key = "grip-" .. id,
            dragType = DRAG_TYPE,
            payload = tostring(id),
            previewAncestor = 1,
            liftFromLayout = true,
            width = 24,
            height = 24,
            align = "center",
            justify = "center",
            tooltip = tr("tip_grip"),
        }, {
            ui.glyph({ name = "menu-2", size = 14, color = "on_surface_variant" }),
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
        -- edit/done/mode state flips the row's controls; key it to recreate cleanly
        key = "row-"
            .. id
            .. (editing and "-edit" or "-view")
            .. (item.done and "-done" or "")
            .. (sortMode == "manual" and "-m" or ""),
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

-- A thin drop target in the gap before manual-order row `index` (and one past
-- the end, at #items+1). expandOnDrag opens a row-height gap where the dragged
-- row will land; hitSlop makes the 3px line reachable from the rows around it.
local function insertionZone(index)
    return ui.dropZone({
        key = "gap-" .. index,
        accepts = { DRAG_TYPE },
        value = tostring(index),
        onDrop = "onTodoDrop",
        height = 3,
        radius = 6,
        expandOnDrag = true,
        hitSlop = 28,
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
        -- Manual mode interleaves an insertion zone before each row (and one
        -- after the last) so a drag can land in any gap. In manual mode the
        -- render order IS the items order, so gap N targets items index N.
        local manual = sortMode == "manual"
        for index, item in ipairs(displayItems()) do
            if manual then
                table.insert(rows, insertionZone(index))
            end
            table.insert(rows, taskRow(item))
        end
        if manual then
            table.insert(rows, insertionZone(#items + 1))
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
    confirmingClear = false
    dirty = false
    idleTicks = 0
    panel.setWantsSecondTicks(true)
    noctalia.state.set("todo_open", true)
    render()
end

function onClose()
    editingId = nil
    confirmingClear = false
    if dirty then
        save()
    end
    noctalia.state.set("todo_open", false)
end

-- Fires on every teardown (shutdown and reload), even paths that skip onClose;
-- flush a pending inline edit so it is never lost.
function onExit()
    if dirty then
        save()
    end
end

function onConfigChanged()
    if dirty then
        save()
    end
    folder = todoFolder()
    filePath = folder .. "/" .. FILE_NAME
    noctalia.mkdirAll(folder)
    editingId = nil
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

-- Drop callback for the insertion zones (declarative drag-and-drop). payload is
-- the dragged row's id as text, value the target gap index as text.
function onTodoDrop(payload, value)
    moveItemTo(tonumber(payload), tonumber(value))
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
