--!nonstrict
-- To Do — a prioritised task list in an attached panel.
--
-- A task is { id, text, priority, done, due?, allDay? }; `due` is unix seconds
-- (local time) and `allDay` marks a whole-day deadline — see dates.luau. The
-- whole list is persisted to
-- <todo_folder>/todo.json (noctalia.json) as an object
-- { version, sort, hideCompleted, tasks }: `tasks` is the array — ALWAYS in
-- manual order — `sort` records the chosen display mode and `hideCompleted`
-- the header eye toggle (priority mode only, see render's `manual` guard). A
-- legacy plain-array file is still read (treated as manual order, sort
-- defaulting to "priority", hideCompleted to false). Empty (blank-text) tasks
-- are never written: they only exist transiently while being entered.
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
-- Interaction: a row is a static line by default. Click its text, its pencil
-- button, or press Enter/✓ while editing to move between the two. The coloured
-- chip cycles the priority (a legend at the foot of the panel maps each colour
-- to its category, and each entry's glyph button sets every task to it). The
-- ☐/☑ button toggles done, which strikes the text through, and the trash
-- button deletes that one task. Right-clicking the text raises a native
-- context menu (plugin_api >= 28) with the same actions plus an explicit
-- priority pick — see openRowMenu. The footer also carries two glyph buttons
-- that mark every task done/undone (setAllDone). The header + adds a task at
-- the head of the manual order, not the foot; its trash button deletes every
-- done row after an inline confirmation strip (confirm/cancel) — the plugin
-- UI has no dialog primitive. No external commands are run.
--
-- The bar widget (todo.luau) lights its glyph while the panel is open via the
-- shared "todo_open" state; it reads todo.json itself for the pending count
-- and for the overdue blink.
--
-- Due dates: each row has a calendar glyph (alarm once overdue) that opens the
-- date picker. The picker is a second VIEW of the same panel — while `pickerId`
-- is set, render() draws pickerView() instead of the list; each view's root has
-- its own key. update() re-renders when the overdue count changes.

-- Row width budget. A Button constrains its label only when it has an explicit
-- width (the host derives the label's max width from it); flexGrow alone lets a
-- long task overrun the buttons to its right instead of shrinking. So the text
-- button is given whatever the fixed parts of the row leave over.
--
-- The constrained label WRAPS, it does not ellipsize: Button sets the label's
-- maxWidth and TextEllipsize::End but never a maxLines, and the text renderer
-- only ellipsizes against an explicit line budget — with maxLines 0 Pango is
-- given the full 500-line backstop and wraps freely. Wrapping is what we want
-- here (the whole task stays readable), and the row grows to fit because
-- Button pins only a minimum height.
-- Every constant below mirrors one in noctalia's Style, named so the sum can be
-- re-checked against the host rather than re-measured by eye.
local PANEL_WIDTH = 700 -- keep in sync with [[panel]] width in plugin.toml
local PANEL_PADDING = 14 -- Style::panelPadding, applied left and right
local SCROLLBAR_GUTTER = 14 -- Style::scrollbarWidth (6) + Style::scrollbarGap (8)
local ROW_GAP = 8 -- the task row's own gap
local CHIP_W = 16 -- the priority chip
local GRIP_W = 24 -- the ☰ drag grip, manual mode only
local GLYPH_BTN_W = 32 -- a glyph-only button is a square of Style::controlHeightSm
local ROW_CONTENT_W = PANEL_WIDTH - (2 * PANEL_PADDING) - SCROLLBAR_GUTTER

-- Width left for the task text once the chip, the optional grip, the leading
-- ☐/☑ done toggle (sits right after the chip) and the other glyph buttons (each
-- followed by a gap) have taken their share. `glyphButtons` counts those other
-- buttons: the calendar (left of the text, after the done toggle) and the
-- pencil and trash (right of it), so 3.
local function taskTextWidth(withGrip, glyphButtons)
    local width = ROW_CONTENT_W - CHIP_W - ROW_GAP - (GLYPH_BTN_W + ROW_GAP) - (glyphButtons * (GLYPH_BTN_W + ROW_GAP))
    if withGrip then
        width -= GRIP_W + ROW_GAP
    end
    return width
end

local storage = require("./storage.luau")
local dates = require("./dates.luau")

-- Read out of the plugin's own manifest (readFile resolves a relative path
-- against the plugin directory), so the header cannot drift from the version
-- the store shows. Empty when unreadable — a missing version is not worth an
-- error line in the panel.
local pluginVersion = (function()
    local text = noctalia.readFile("plugin.toml")
    if type(text) ~= "string" then
        return ""
    end
    return ("\n" .. text):match('\nversion%s*=%s*"([^"]+)"') or ""
end)()

local PRIORITIES = { "important", "medium", "low" }
local RANK = { important = 1, medium = 2, low = 3 }
local COLORS = { important = "#e06c75", medium = "#e5c07b", low = "#98c379" }
local FILE_NAME = "todo.json"
local AUTOSAVE_IDLE_TICKS = 2 -- 1s panel ticks with no edits before a flush
local DRAG_TYPE = "todo-row" -- drag identifier matched by the row drop zones
local DUE_LABEL_W = 96 -- width of the "20 Nov 18:30" label on a row that has a due date
local COMPLETE_SOUND = "todo-complete" -- name registered with noctalia.sound.load

local items = {} -- array, ALWAYS in manual order (priority mode sorts a copy for display)
local nextId = 1 -- monotonic id source (identity only, not a sort key)
local folder = ""
local filePath = ""
local dirty = false -- unsaved inline text edits
local idleTicks = 0
local editingId = nil -- id of the row currently in edit mode (at most one)
local loaded = false -- guard so an early save() can never truncate the file
local sortMode = "priority" -- "priority" (auto sort) or "manual" (drag reorder)
local hideCompleted = false -- header eye toggle: hide done rows from the list
local showCount = true -- header hash toggle: show the task count on the bar widget
local confirmingClear = false -- header trash pressed, awaiting confirm/cancel
local soundReady = false -- true once COMPLETE_SOUND has finished loading
-- Date picker (a full-panel view that replaces the list while pickerId is set):
local pickerId = nil -- id of the task being dated
local pickY, pickM, pickD, pickH, pickMin = 0, 0, 0, 0, 0 -- the draft date/time
local pickAllDay = false
local pickError = nil -- text shown above the buttons, nil when fine
local shownOverdue = 0 -- overdue rows in the last render; update() re-renders when it changes

local render

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

local function overdueCount()
    local count, now = 0, os.time()
    for _, item in ipairs(items) do
        if dates.isOverdue(item, now) then
            count += 1
        end
    end
    return count
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
    local state = storage.load(filePath)
    items = state.items
    nextId = state.nextId
    sortMode = state.sortMode
    hideCompleted = state.hideCompleted
    showCount = state.showCount
    -- The on-disk order IS the manual order; priority mode sorts at render time.
    loaded = true
end

local function save()
    if not loaded then
        return -- never write before the first load reads what is on disk
    end
    local ok, err = storage.save(filePath, items, sortMode, hideCompleted, showCount)
    if not ok then
        noctalia.notifyError(tr("title"), err or tr("save_failed"))
        return
    end
    dirty = false
end

local function addItem()
    local item = { id = nextId, text = "", priority = "medium", done = false }
    nextId += 1
    -- Inserted at the head of the manual order, so a new task is visible
    -- right away instead of scrolled off the bottom.
    table.insert(items, 1, item)
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
        local wasDone = item.done
        item.done = not item.done
        -- Chime only on the false->true transition (completing, not
        -- un-completing), and only when the setting is on and the sound
        -- finished loading.
        if item.done and not wasDone and soundReady and noctalia.getConfig("sound_on_complete") then
            noctalia.sound.play(COMPLETE_SOUND)
        end
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

-- Set an explicit priority (the context menu picks one directly, where the
-- chip only cycles). Same rule as cyclePriority: the manual position is
-- untouched, the priority view re-sorts on render.
local function setPriority(id, priority)
    local item = findItem(id)
    if item ~= nil and RANK[priority] ~= nil and item.priority ~= priority then
        item.priority = priority
        save()
        render()
    end
end

-- Mark every task done/undone (the header's bulk glyphs). Chimes once on a
-- bulk-complete, same rule as toggleDone: only when something actually
-- flips to done and the sound setting is on.
local function setAllDone(doneValue)
    if #items == 0 then
        return
    end
    local anyNewlyDone = false
    for _, item in ipairs(items) do
        if doneValue and not item.done then
            anyNewlyDone = true
        end
        item.done = doneValue
    end
    if anyNewlyDone and soundReady and noctalia.getConfig("sound_on_complete") then
        noctalia.sound.play(COMPLETE_SOUND)
    end
    save()
    render()
end

-- Set every task to `priority` (the legend's bulk glyphs). Manual positions
-- are untouched, same as cyclePriority/setPriority.
local function setAllPriority(priority)
    if RANK[priority] == nil or #items == 0 then
        return
    end
    for _, item in ipairs(items) do
        item.priority = priority
    end
    save()
    render()
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

-- Flip the header eye toggle. Only the flag is persisted — `items` is never
-- touched, so toggling never loses or reorders a done task, it just hides
-- its row.
local function setHideCompleted(value)
    hideCompleted = value
    save()
    render()
end

-- Flip the header hash toggle. The bar widget (todo.luau) reads this straight
-- out of todo.json, same as the pending/total counts, so no extra state
-- channel is needed — see "Widgets re-read the source of truth themselves".
local function setShowCount(value)
    showCount = value
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

-- Menu header label: the task itself, cut to about one line. utf8.offset keeps
-- the cut off a multi-byte boundary; text that is not valid UTF-8 (utf8.len
-- returns nil rather than throwing) falls through unchanged.
local MENU_HEADER_CHARS = 42
local function menuHeader(text)
    local length = utf8.len(text)
    if length == nil or length <= MENU_HEADER_CHARS then
        return text
    end
    return text:sub(1, (utf8.offset(text, MENU_HEADER_CHARS + 1) or 0) - 1) .. "…"
end

-- The row's right-click menu (plugin_api >= 28). Only a ui.button's
-- onRightClick carries the pointer serial openContextMenu needs, so the row's
-- text button is the one node that can raise this.
-- `onActivate` must NAME a global (openContextMenu is a raw binding, not a UI
-- tree prop, so closures are not registered for it); the row id rides along in
-- `context` and comes back as the callback's second argument.
local function openRowMenu(item)
    local entries = {}
    if not isBlank(item.text) then
        table.insert(entries, { kind = "header", label = menuHeader(item.text) })
    end
    table.insert(entries, { id = "edit", label = tr("menu_edit") })
    table.insert(entries, { id = "done", label = tr(item.done and "menu_undone" or "menu_done") })
    table.insert(entries, { id = "due", label = tr("menu_due") })
    table.insert(entries, { kind = "separator" })
    table.insert(entries, { kind = "header", label = tr("menu_priority") })
    for _, priority in ipairs(PRIORITIES) do
        -- A bullet on the current one rather than enabled = false: greyed out
        -- reads as "unavailable", and picking the priority a task already has
        -- is a harmless no-op anyway.
        table.insert(entries, {
            id = "prio-" .. priority,
            label = (item.priority == priority and "● " or "") .. tr("prio_" .. priority),
        })
    end
    table.insert(entries, { kind = "separator" })
    table.insert(entries, { id = "delete", label = tr("menu_delete") })
    panel.openContextMenu({ onActivate = "onRowMenu", context = tostring(item.id), items = entries })
end

-- Opens the picker seeded from the task's due date, or 15 minutes from now.
local function openPicker(id)
    local item = findItem(id)
    if item == nil then
        return
    end
    local stamp = item.due or (os.time() + 900)
    local y, m, d, h, mi = noctalia.formatTime("%Y %m %d %H %M", stamp):match("(%d+) (%d+) (%d+) (%d+) (%d+)")
    pickY, pickM, pickD, pickH = tonumber(y), tonumber(m), tonumber(d), tonumber(h)
    pickMin = tonumber(mi)
    pickAllDay = item.allDay == true
    pickError = nil
    pickerId = id
    render()
end

local function resetPicker()
    pickerId = nil
    pickError = nil
end

local function closePicker()
    resetPicker()
    render()
end

-- Any edit of the draft clears the error and redraws.
local function pickerChanged()
    pickError = nil
    render()
end

local function pickerShift(delta)
    pickY, pickM = dates.shiftMonth(pickY, pickM, delta)
    pickD = math.min(pickD, dates.daysInMonth(pickY, pickM))
    render()
end

-- Saves the draft; a deadline that has already passed is refused.
local function pickerSave()
    local item = findItem(pickerId)
    if item == nil then
        closePicker()
        return
    end
    local due = dates.makeDue(pickY, pickM, pickD, pickH, pickMin, pickAllDay)
    if dates.isOverdue({ due = due, allDay = pickAllDay }, os.time()) then
        pickError = tr("picker_past")
        render()
        return
    end
    item.due = due
    item.allDay = pickAllDay or nil
    save()
    closePicker()
end

local function pickerClear()
    local item = findItem(pickerId)
    if item ~= nil then
        item.due = nil
        item.allDay = nil
        save()
    end
    closePicker()
end

-- "20 Nov 18:30", or "20 Nov" for an all-day task.
local function dueText(item)
    return noctalia.formatTime(item.allDay and "%d %b" or "%d %b %H:%M", item.due)
end

local function taskRow(item)
    local id = item.id
    local editing = editingId == id
    local overdue = dates.isOverdue(item, os.time())

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
        onClick = function()
            cyclePriority(id)
        end,
    })
    local children = {}
    if grip ~= nil then
        table.insert(children, grip)
    end
    table.insert(children, chip)
    if not editing then
        -- Done toggle sits right after the priority chip, before the task
        -- text: strikes the text through when checked.
        table.insert(children, ui.button({
            glyph = item.done and "square-check" or "square",
            variant = "ghost",
            tooltip = tr(item.done and "tip_undone" or "tip_done"),
            onClick = function()
                toggleDone(id)
            end,
        }))
    end

    if editing then
        table.insert(children, ui.input({
            key = "text-" .. id,
            value = item.text,
            placeholder = tr("placeholder"),
            focus = true,
            flexGrow = 1,
            onChange = function(value)
                item.text = value
                dirty = true
                idleTicks = 0
            end,
            onSubmit = function(value)
                commitEdit(id, value)
            end,
        }))
        -- ✓ commits the edit, mirroring Enter.
        table.insert(children, ui.button({
            glyph = "check",
            variant = "primary",
            tooltip = tr("tip_commit"),
            onClick = function()
                commitEdit(id, item.text)
            end,
        }))
    else
        -- Due date: calendar when unset, calendar-event when set, a red alarm
        -- once overdue. All three open the picker (set, change or postpone).
        local dueState = overdue and "overdue" or (item.due ~= nil and "set" or "none")
        table.insert(children, ui.button({
            key = "due-" .. id .. "-" .. dueState,
            glyph = overdue and "alarm" or (item.due ~= nil and "calendar-event" or "calendar"),
            variant = overdue and "destructive" or "ghost",
            tooltip = tr(overdue and "tip_overdue" or (item.due ~= nil and "tip_due_edit" or "tip_due_set")),
            onClick = function()
                openPicker(id)
            end,
        }))
        -- Static text; clicking it re-opens the editor ("press on the text"),
        -- right-clicking it raises the row menu. The explicit width is what
        -- makes a long task wrap onto another line instead of running under the
        -- button that follows it.
        table.insert(children, ui.button({
            key = "view-" .. id,
            text = item.done and strike(item.text) or item.text,
            variant = "ghost",
            contentAlign = "start",
            width = taskTextWidth(grip ~= nil, 3) - (item.due ~= nil and DUE_LABEL_W + ROW_GAP or 0),
            onClick = function()
                enterEdit(id)
            end,
            onRightClick = function()
                openRowMenu(item)
            end,
        }))
        if item.due ~= nil then
            table.insert(children, ui.label({
                key = "duetext-" .. id,
                text = dueText(item),
                fontSize = 11,
                width = DUE_LABEL_W,
                color = overdue and "error" or "on_surface_variant",
            }))
        end
        -- Explicit edit affordance next to the row, same action as clicking
        -- the text or picking "Edit task" from the row menu.
        table.insert(children, ui.button({
            glyph = "pencil",
            variant = "ghost",
            tooltip = tr("tip_edit"),
            onClick = function()
                enterEdit(id)
            end,
        }))
        table.insert(children, ui.button({
            glyph = "trash",
            variant = "ghost",
            tooltip = tr("tip_delete"),
            onClick = function()
                deleteItem(id)
            end,
        }))
    end

    return ui.row({
        -- edit/done/mode state flips the row's controls; key it to recreate cleanly
        key = "row-"
            .. id
            .. (editing and "-edit" or "-view")
            .. (item.done and "-done" or "")
            .. (overdue and "-od" or "")
            .. (sortMode == "manual" and "-m" or ""),
        gap = 8,
        align = "center",
    }, children)
end

-- A footer legend mapping each chip colour to its category. The trailing
-- glyph button applies that priority to every task (setAllPriority).
local BULK_GLYPH = { important = "chevrons-up", medium = "equal", low = "chevrons-down" }
local function legendEntry(priority)
    return ui.row({ gap = 6, align = "center" }, {
        ui.box({ width = 12, height = 12, radius = 3, fill = COLORS[priority] }),
        ui.label({ text = tr("prio_" .. priority), fontSize = 11, color = "on_surface_variant" }),
        ui.button({
            key = "set-all-" .. priority,
            glyph = BULK_GLYPH[priority],
            variant = "ghost",
            tooltip = tr("tip_set_all_" .. priority),
            onClick = function()
                setAllPriority(priority)
            end,
        }),
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

-- The picker view: title, month arrows, Monday-first day grid, all-day toggle,
-- hour/minute selects (minute precision), then Save / Cancel / Remove date.
local CELL_W, CELL_H = 44, 36
local function pickerView(item)
    local anchor = dates.makeDue(pickY, pickM, 1, 12, 0, false)
    local weekdays = {}
    for i = 1, 7 do
        -- 1 Jan 2024 was a Monday, so days 1..7 of it are Monday..Sunday
        weekdays[i] = ui.label({
            text = noctalia.formatTime("%a", dates.makeDue(2024, 1, i, 12, 0, false)),
            width = CELL_W,
            textAlign = "center",
            fontSize = 11,
            color = "on_surface_variant",
        })
    end
    local weeks = {}
    for r, week in ipairs(dates.monthGrid(pickY, pickM)) do
        local cells = {}
        for c, day in ipairs(week) do
            if day == 0 then
                cells[c] = ui.box({ key = "blank-" .. r .. "-" .. c, width = CELL_W, height = CELL_H })
            else
                cells[c] = ui.button({
                    key = "day-" .. day,
                    text = tostring(day),
                    width = CELL_W,
                    height = CELL_H,
                    variant = day == pickD and "primary" or "ghost",
                    onClick = function()
                        pickD = day
                        pickerChanged()
                    end,
                })
            end
        end
        weeks[r] = ui.row({ key = "week-" .. r, gap = 4, justify = "center" }, cells)
    end

    local hours, minutes = {}, {}
    for h = 0, 23 do
        hours[h + 1] = string.format("%02d", h)
    end
    for m = 0, 59 do
        minutes[m + 1] = string.format("%02d", m)
    end
    local timeRow = { ui.toggle({
        key = "pick-allday",
        checked = pickAllDay,
        onChange = function(value)
            pickAllDay = value == "true"
            pickerChanged()
        end,
    }), ui.label({ text = tr("picker_all_day"), color = "on_surface", flexGrow = 1 }) }
    if not pickAllDay then
        table.insert(timeRow, ui.select({
            key = "pick-hour",
            width = 84,
            options = hours,
            selectedIndex = pickH,
            onChange = function(index)
                pickH = tonumber(index) or 0
                pickerChanged()
            end,
        }))
        table.insert(timeRow, ui.label({ text = ":", color = "on_surface" }))
        table.insert(timeRow, ui.select({
            key = "pick-min",
            width = 84,
            options = minutes,
            selectedIndex = pickMin,
            onChange = function(index)
                pickMin = tonumber(index) or 0
                pickerChanged()
            end,
        }))
    end

    local buttons = {
        ui.button({ key = "pick-save", text = tr("picker_save"), variant = "primary", onClick = pickerSave }),
        ui.button({ key = "pick-cancel", text = tr("picker_cancel"), variant = "ghost", onClick = closePicker }),
    }
    if item.due ~= nil then
        table.insert(buttons, ui.button({
            key = "pick-clear",
            text = tr("picker_clear"),
            variant = "destructive",
            onClick = pickerClear,
        }))
    end

    local parts = {
        ui.row({ gap = 8, align = "center" }, {
            ui.button({ glyph = "arrow-left", variant = "ghost", tooltip = tr("tip_picker_back"), onClick = closePicker }),
            ui.label({ text = menuHeader(item.text), color = "on_surface", flexGrow = 1 }),
        }),
        ui.row({ gap = 8, align = "center" }, {
            ui.button({
                glyph = "chevron-left",
                variant = "ghost",
                tooltip = tr("tip_picker_prev"),
                onClick = function()
                    pickerShift(-1)
                end,
            }),
            ui.label({
                text = noctalia.formatTime("%B %Y", anchor),
                color = "on_surface",
                flexGrow = 1,
                textAlign = "center",
            }),
            ui.button({
                glyph = "chevron-right",
                variant = "ghost",
                tooltip = tr("tip_picker_next"),
                onClick = function()
                    pickerShift(1)
                end,
            }),
        }),
        ui.row({ gap = 4, justify = "center" }, weekdays),
        ui.column({ gap = 4, align = "center" }, weeks),
        ui.row({ gap = 8, align = "center" }, timeRow),
    }
    if pickError ~= nil then
        table.insert(parts, ui.label({ text = pickError, color = "error" }))
    end
    table.insert(parts, ui.row({ gap = 8, justify = "end" }, buttons))
    return ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, parts)
end

render = function()
    shownOverdue = overdueCount()
    -- The picker replaces the list; it closes when its task is gone.
    if pickerId ~= nil then
        local pickerItem = findItem(pickerId)
        if pickerItem ~= nil then
            panel.render(ui.column({ key = "view-picker", flexGrow = 1, gap = 12, align = "stretch" }, { pickerView(pickerItem) }))
            return
        end
        resetPicker()
    end
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
        ui.label({ key = "title", text = tr("title"), fontSize = 16, fontWeight = "bold", color = "on_surface" }),
        -- Version off the manifest, small and dimmed: it answers "which
        -- build am I running" without competing with the title. The spacer
        -- rather than a flexGrow title keeps the two together on the left.
        ui.label({ key = "version", text = pluginVersion, fontSize = 10, color = "on_surface_variant" }),
        ui.spacer({ key = "gap", flexGrow = 1 }),
        sortToggle,
        ui.button({
            key = "header-hide-completed-" .. tostring(hideCompleted),
            glyph = hideCompleted and "eye-off" or "eye",
            text = tr(hideCompleted and "show_completed" or "hide_completed"),
            variant = "ghost",
            selected = hideCompleted,
            enabled = sortMode ~= "manual",
            tooltip = sortMode == "manual" and tr("tip_hide_completed_manual")
                or tr(hideCompleted and "tip_show_completed" or "tip_hide_completed"),
            onClick = "onHideCompletedToggle",
        }),
        ui.button({
            key = "header-show-count-" .. tostring(showCount),
            glyph = "hash",
            text = tr(showCount and "hide_count" or "show_count"),
            variant = "ghost",
            selected = showCount,
            tooltip = tr(showCount and "tip_hide_count" or "tip_show_count"),
            onClick = "onShowCountToggle",
        }),
        ui.button({
            key = "header-clear-done" .. (done == 0 and "-off" or ""),
            glyph = "trash",
            variant = "ghost",
            enabled = done > 0,
            tooltip = tr("tip_clear_done"),
            onClick = "onClearDone",
        }),
        ui.button({ key = "header-add", glyph = "plus", variant = "primary", tooltip = tr("tip_add"), onClick = "onAdd" }),
        ui.button({ key = "header-settings", glyph = "settings", variant = "ghost", tooltip = tr("tip_settings"), onClick = "onOpenSettings" }),
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

    -- Bulk done/undone glyphs. Kept in the footer, not the header — the
    -- header is already full (title, version, sort toggle, clear-done, add,
    -- settings, close), and this pairs naturally with the bulk-priority
    -- glyphs on the legend right below it.
    local bulkDone = ui.row({ gap = 16, align = "center", justify = "center" }, {
        ui.button({
            key = "footer-all-done",
            glyph = "checks",
            variant = "ghost",
            enabled = done < #items,
            tooltip = tr("tip_all_done"),
            onClick = "onAllDone",
        }),
        ui.button({
            key = "footer-all-undone",
            glyph = "square",
            variant = "ghost",
            enabled = done > 0,
            tooltip = tr("tip_all_undone"),
            onClick = "onAllUndone",
        }),
    })

    local legend = ui.column({ gap = 8 }, {
        ui.separator({}),
        bulkDone,
        ui.row({ gap = 16, align = "center", justify = "center" }, {
            legendEntry("important"),
            legendEntry("medium"),
            legendEntry("low"),
        }),
    })

    -- Manual mode's insertion zones number gaps against `items`, so filtering
    -- hidden-done rows out of the drop targets would desync the gap index
    -- from moveItemTo's insertAt. The eye toggle is therefore only honoured
    -- in priority mode (and disabled in manual mode, see sortToggle above).
    local manual = sortMode == "manual"
    local visible = displayItems()
    if hideCompleted and not manual then
        local kept = {}
        for _, item in ipairs(visible) do
            if not item.done then
                table.insert(kept, item)
            end
        end
        visible = kept
    end

    local body
    if #visible == 0 then
        -- minimum height of the empty-state message
        body = ui.column({ height = 120, flexGrow = 1, align = "center", justify = "center" }, {
            ui.label({ text = (#items == 0 and tr("empty")) or tr("all_hidden"), color = "on_surface_variant" }),
        })
    else
        local rows = {}
        -- Manual mode interleaves an insertion zone before each row (and one
        -- after the last) so a drag can land in any gap. In manual mode the
        -- render order IS the items order, so gap N targets items index N.
        for index, item in ipairs(visible) do
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
    panel.render(ui.column({ key = "view-list", flexGrow = 1, gap = 12, align = "stretch" }, parts))
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
    resetPicker()
    confirmingClear = false
    dirty = false
    idleTicks = 0
    panel.setWantsSecondTicks(true)
    noctalia.state.set("todo_open", true)
    render()
end

function onClose()
    editingId = nil
    resetPicker()
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
    resetPicker()
    confirmingClear = false
    load()
    render()
end

function update()
    if loaded and overdueCount() ~= shownOverdue then
        render() -- a deadline passed while the panel was open
    end
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

function onHideCompletedToggle()
    setHideCompleted(not hideCompleted)
end

function onShowCountToggle()
    setShowCount(not showCount)
end

-- plugin_api >= 13, declared as capture_keys = ["n", "s"] in plugin.toml. The
-- host only delivers a chord here when no ui.input has focus (a focused text
-- field reserves every printable key for itself first), but editingId is
-- checked too as a second, script-level guard in case that ever changes.
-- Return/Escape are deliberately NOT bound: Return already reaches the
-- editing input's onSubmit, and a panel can never capture Escape at all.
function onKey(chord, pressed)
    if not pressed or editingId ~= nil or pickerId ~= nil then
        return
    end
    if chord == "n" then
        onAdd()
    elseif chord == "s" then
        onSortToggle()
    end
end

-- Dispatch for the row context menu. `action` is the id of the entry that was
-- picked, `context` the row id the menu was opened with, as text. The row can
-- be gone by the time a menu entry is chosen (a reload, or the header trash
-- clearing it), so re-resolve the id before acting on it.
function onRowMenu(action, context)
    local id = tonumber(context)
    if id == nil or findItem(id) == nil then
        return
    end
    if action == "edit" then
        enterEdit(id)
    elseif action == "done" then
        toggleDone(id)
    elseif action == "due" then
        openPicker(id)
    elseif action == "delete" then
        deleteItem(id)
    else
        local priority = action:match("^prio%-(%l+)$")
        if priority ~= nil then
            setPriority(id, priority)
        end
    end
end

-- Drop callback for the insertion zones (declarative drag-and-drop). payload is
-- the dragged row's id as text, value the target gap index as text.
function onTodoDrop(payload, value)
    moveItemTo(tonumber(payload), tonumber(value))
end

function onAllDone()
    setAllDone(true)
end

function onAllUndone()
    setAllDone(false)
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

-- Opens the settings window on this plugin's own page (the host supplies the
-- plugin id, so a plugin can only ever open its own). It closes the panel on
-- the way, so onClose flushes any pending edit first.
function onOpenSettings()
    noctalia.openSettings()
end

function onClosePanel()
    panel.close()
end

-- Loaded once when the script starts (and again on hot reload); playing is a
-- no-op until this callback flips soundReady, so a slow/failed load just
-- means the very first completion after a reload stays silent.
noctalia.sound.load(COMPLETE_SOUND, "sounds/task-complete.wav", function(ok)
    soundReady = ok == true
end)
