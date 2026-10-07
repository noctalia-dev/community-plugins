--!nonstrict
-- Paged Todo List panel, preserving the legacy V4 page-oriented workflow:
-- pages, priorities, completion ordering, details, drag reorder, copy, and
-- Markdown/JSON export.

local store = require("./data.luau")
local data = store.load()
local configuredShowCompleted = noctalia.getConfig("show_completed")
local showCompleted = type(configuredShowCompleted) == "boolean"
    and configuredShowCompleted or data.show_completed ~= false
local priority = "medium"
local editingId = nil
local editDrafts = {}
local pageMode = ""
local pageDraft = ""
local inputGeneration = 0
local nextId = math.floor(noctalia.nowMs())

for _, todo in ipairs(data.todos) do
    local numericId = tonumber(todo.id)
    if numericId ~= nil and numericId >= nextId then
        nextId = math.floor(numericId) + 1
    end
end

local function sameId(a, b)
    return tostring(a) == tostring(b)
end

local function save()
    data.show_completed = showCompleted
    store.save(data)
end

local function findTodo(id)
    for _, todo in ipairs(data.todos) do
        if sameId(todo.id, id) then return todo end
    end
    return nil
end

local function findTodoIndex(id)
    for index, todo in ipairs(data.todos) do
        if sameId(todo.id, id) then return index end
    end
    return nil
end

local function activeCount()
    local count = 0
    for _, todo in ipairs(data.todos) do
        if todo.completed ~= true then count += 1 end
    end
    return count
end

local function completedCount()
    local count = 0
    for _, todo in ipairs(data.todos) do
        if todo.completed == true then count += 1 end
    end
    return count
end

local function currentPageTodos()
    local result = {}
    for _, todo in ipairs(data.todos) do
        local pageId = todo.pageId or 0
        if sameId(pageId, data.current_page_id or 0)
            and (showCompleted or todo.completed ~= true) then
            table.insert(result, todo)
        end
    end
    return result
end

local function currentPageIndex()
    for index, page in ipairs(data.pages) do
        if sameId(page.id or 0, data.current_page_id or 0) then
            return index
        end
    end
    return 1
end

local function pageNames()
    local result = {}
    for _, page in ipairs(data.pages) do
        table.insert(result, page.name or "General")
    end
    return result
end

local function priorityColor(value)
    if noctalia.getConfig("use_custom_colors") == true then
        if value == "high" then return noctalia.getConfig("priority_high_color") or "#F44336" end
        if value == "low" then return noctalia.getConfig("priority_low_color") or "#9E9E9E" end
        return noctalia.getConfig("priority_medium_color") or "#2196F3"
    end
    if value == "high" then return "error" end
    if value == "low" then return "on_surface_variant" end
    return "primary"
end

local function priorityLabel(value)
    if value == "high" then return "High" end
    if value == "low" then return "Low" end
    return "Medium"
end

local function reorderCompletion(todo)
    local index = findTodoIndex(todo.id)
    if index == nil then return end
    table.remove(data.todos, index)

    local targetPage = todo.pageId or 0
    local insertIndex = #data.todos + 1
    if todo.completed == true then
        -- Completed items follow all items on their page.
        for i, other in ipairs(data.todos) do
            if sameId(other.pageId or 0, targetPage) then
                insertIndex = i + 1
            end
        end
    else
        -- Active items stay before the first completed item on their page.
        insertIndex = #data.todos + 1
        local lastPageItem = nil
        for i, other in ipairs(data.todos) do
            if sameId(other.pageId or 0, targetPage) then
                lastPageItem = i
                if other.completed == true then
                    insertIndex = i
                    break
                end
            end
        end
        if insertIndex == #data.todos + 1 and lastPageItem ~= nil then
            insertIndex = lastPageItem + 1
        end
    end
    table.insert(data.todos, insertIndex, todo)
end

local function addTodo(text)
    text = noctalia.string.trim(text or "")
    if text == "" then return end
    nextId += 1
    local todo = {
        id = nextId,
        text = text,
        completed = false,
        priority = priority,
        details = "",
        pageId = data.current_page_id or 0,
        createdAt = noctalia.formatTime("%Y-%m-%dT%H:%M:%S%z"),
    }

    -- Match V4's insertion behavior: a new item is placed at the top of its
    -- page, before existing records from that page.
    local insertIndex = #data.todos + 1
    for index, other in ipairs(data.todos) do
        if sameId(other.pageId or 0, todo.pageId) then
            insertIndex = index
            break
        end
    end
    table.insert(data.todos, insertIndex, todo)
    priority = "medium"
    inputGeneration += 1
    save()
    render()
end

local function toggleTodo(id, value)
    local todo = findTodo(id)
    if todo == nil then return end
    todo.completed = value == "true"
    reorderCompletion(todo)
    save()
    render()
end

local function cyclePriority(id)
    local todo = findTodo(id)
    if todo == nil then return end
    todo.priority = todo.priority == "high" and "medium"
        or (todo.priority == "medium" and "low" or "high")
    save()
    render()
end

local function removeTodo(id)
    local index = findTodoIndex(id)
    if index ~= nil then table.remove(data.todos, index) end
    if sameId(editingId, id) then editingId = nil end
    editDrafts[tostring(id)] = nil
    save()
    render()
end

local function clearCompleted()
    local remaining = {}
    for _, todo in ipairs(data.todos) do
        if todo.completed ~= true then table.insert(remaining, todo) end
    end
    data.todos = remaining
    editingId = nil
    editDrafts = {}
    save()
    render()
end

local function beginEdit(id)
    local todo = findTodo(id)
    if todo == nil then return end
    editingId = id
    editDrafts[tostring(id)] = {
        text = todo.text or "",
        details = todo.details or "",
    }
    render()
end

local function commitEdit(id, submittedText)
    local todo = findTodo(id)
    local key = tostring(id)
    local draft = editDrafts[key] or {}
    local text = noctalia.string.trim(submittedText or draft.text or "")
    if todo ~= nil and text ~= "" then
        todo.text = text
        todo.details = draft.details or todo.details or ""
        save()
    end
    editDrafts[key] = nil
    editingId = nil
    render()
end

local function createPage()
    local name = noctalia.string.trim(pageDraft)
    if name == "" then return end
    for _, page in ipairs(data.pages) do
        if (page.name or ""):lower() == name:lower() then return end
    end
    local maxId = 0
    for _, page in ipairs(data.pages) do
        maxId = math.max(maxId, tonumber(page.id) or 0)
    end
    local page = { id = maxId + 1, name = name }
    table.insert(data.pages, page)
    data.current_page_id = page.id
    pageMode = ""
    pageDraft = ""
    save()
    render()
end

local function renamePage()
    local name = noctalia.string.trim(pageDraft)
    if name == "" then return end
    local current = nil
    for _, page in ipairs(data.pages) do
        if sameId(page.id or 0, data.current_page_id or 0) then current = page end
        if not sameId(page.id or 0, data.current_page_id or 0)
            and (page.name or ""):lower() == name:lower() then return end
    end
    if current ~= nil then current.name = name end
    pageMode = ""
    pageDraft = ""
    save()
    render()
end

local function deletePage()
    local currentId = data.current_page_id or 0
    if sameId(currentId, 0) or #data.pages <= 1 then return end
    local remaining = {}
    for _, page in ipairs(data.pages) do
        if not sameId(page.id or 0, currentId) then table.insert(remaining, page) end
    end
    for _, todo in ipairs(data.todos) do
        if sameId(todo.pageId or 0, currentId) then todo.pageId = 0 end
    end
    data.pages = remaining
    data.current_page_id = 0
    pageMode = ""
    save()
    render()
end

local function moveTodo(sourceId, target)
    local sourceIndex = findTodoIndex(sourceId)
    local source = findTodo(sourceId)
    if sourceIndex == nil or source == nil then return end
    table.remove(data.todos, sourceIndex)

    local insertIndex = #data.todos + 1
    if target == "end" then
        for index, todo in ipairs(data.todos) do
            if sameId(todo.pageId or 0, source.pageId or 0) then
                insertIndex = index + 1
            end
        end
    else
        for index, todo in ipairs(data.todos) do
            if sameId(todo.id, target) then
                insertIndex = index
                break
            end
        end
    end
    table.insert(data.todos, insertIndex, source)
    save()
    render()
end

function onDrop(payload, target)
    if type(payload) == "string" and type(target) == "string" then
        moveTodo(payload, target)
    end
end

local function exportTodos()
    local format = noctalia.getConfig("export_format") or data.export_format or "markdown"
    local base = noctalia.expandPath(noctalia.getConfig("export_path") or data.export_path or "~/Documents")
    if not noctalia.mkdirAll(base) then
        noctalia.notifyError("Paged Todo List", `Unable to create export directory: {base}`)
        return
    end
    local filename = `todo_{noctalia.formatTime("%Y%m%d_%H%M%S")}`
    if format == "json" then
        local encoded = noctalia.json.encode(data, true)
        if encoded ~= nil and noctalia.writeFile(`{base}/{filename}.json`, encoded) then
            noctalia.notify("Paged Todo List", `Exported to {base}/{filename}.json`)
        end
        return
    end

    local lines = {
        "---",
        `export_date: {noctalia.formatTime("%Y-%m-%dT%H:%M:%S%z")}`,
        `total: {#data.todos}`,
        `active: {activeCount()}`,
        `completed: {completedCount()}`,
        "---",
        "",
        "# Paged Todo List",
        "",
    }
    for _, page in ipairs(data.pages) do
        local pageTodos = {}
        for _, todo in ipairs(data.todos) do
            if sameId(todo.pageId or 0, page.id or 0) then table.insert(pageTodos, todo) end
        end
        if #pageTodos > 0 or noctalia.getConfig("export_empty_sections") == true or data.export_empty_sections == true then
            table.insert(lines, `## {page.name or "General"}`)
            table.insert(lines, "")
            for _, todo in ipairs(pageTodos) do
                local mark = todo.completed == true and "x" or " "
                table.insert(lines, `- [{mark}] {todo.text or ""}`)
                table.insert(lines, `  - Priority: {priorityLabel(todo.priority)}`)
                if todo.createdAt ~= nil and todo.createdAt ~= "" then
                    table.insert(lines, `  - Created: {todo.createdAt}`)
                end
                if todo.details ~= nil and todo.details ~= "" then
                    for detail in todo.details:gmatch("[^\n]+") do
                        table.insert(lines, `  - {detail}`)
                    end
                end
            end
            table.insert(lines, "")
        end
    end
    local path = `{base}/{filename}.md`
    if noctalia.writeFile(path, table.concat(lines, "\n")) then
        noctalia.notify("Paged Todo List", `Exported to {path}`)
    else
        noctalia.notifyError("Paged Todo List", "Unable to write the export file")
    end
end

function render()
    local todoRows = {}
    local visibleTodos = currentPageTodos()
    for index, todo in ipairs(visibleTodos) do
        local id = todo.id
        local isEditing = sameId(editingId, id)
        local editorChildren = {}
        if isEditing then
            local draftKey = tostring(id)
            local draft = editDrafts[draftKey] or { text = todo.text or "", details = todo.details or "" }
            editDrafts[draftKey] = draft
            table.insert(editorChildren, ui.input({
                key = `text-{id}`,
                value = draft.text,
                placeholder = "Todo",
                submitOnEnter = true,
                onChange = function(value) draft.text = value end,
                onSubmit = function(value) commitEdit(id, value) end,
            }))
            table.insert(editorChildren, ui.input({
                key = `details-{id}`,
                value = draft.details,
                placeholder = "Details (optional)",
                multiline = true,
                height = 52,
                onChange = function(value) draft.details = value end,
            }))
        else
            table.insert(editorChildren, ui.label({
                text = todo.completed == true and `✓ {todo.text or ""}` or (todo.text or ""),
                color = todo.completed == true and "on_surface_variant" or "on_surface",
                fontWeight = todo.completed == true and "regular" or "medium",
                flexGrow = 1,
                maxLines = 2,
            }))
            if todo.details ~= nil and todo.details ~= "" then
                table.insert(editorChildren, ui.label({ text = todo.details, color = "on_surface_variant", maxLines = 2 }))
            end
        end

        local row = ui.row({ key = `todo-{id}`, gap = 8, align = "center", padding = 8, fill = "surface_variant/0.45", radius = 6 }, {
            ui.dragSource({
                key = `grip-{id}`,
                dragType = "todo",
                payload = tostring(id),
                previewAncestor = 1,
                liftFromLayout = true,
                width = 22,
                height = 24,
                tooltip = "Drag to reorder",
            }, { ui.glyph({ name = "grip-vertical", size = 15, color = "on_surface_variant" }) }),
            ui.row({ fill = priorityColor(todo.priority), width = 4, height = 34, radius = 2 }, {}),
            ui.toggle({ checked = todo.completed == true, onChange = function(value) toggleTodo(id, value) end }),
            ui.column({ gap = 4, flexGrow = 1, align = "stretch" }, editorChildren),
            ui.button({ glyph = "flag", tooltip = `Priority: {priorityLabel(todo.priority)}`, variant = "ghost", onClick = function() cyclePriority(id) end }),
            ui.button({ glyph = isEditing and "check" or "pencil", variant = "ghost", onClick = function()
                if isEditing then
                    commitEdit(id, nil)
                else
                    beginEdit(id)
                end
            end }),
            ui.button({ glyph = "copy", variant = "ghost", onClick = function() noctalia.copyToClipboard(todo.text or "", "text/plain") end }),
            ui.button({ glyph = "trash", variant = "ghost", onClick = function() removeTodo(id) end }),
        })

        table.insert(todoRows, ui.dropZone({
            key = `before-{id}`,
            accepts = { "todo" },
            value = tostring(id),
            onDrop = "onDrop",
            height = 3,
            expandOnDrag = true,
            hitSlop = 12,
        }))
        table.insert(todoRows, row)
        if index == #visibleTodos then
            table.insert(todoRows, ui.dropZone({
                key = "end",
                accepts = { "todo" },
                value = "end",
                onDrop = "onDrop",
                height = 3,
                expandOnDrag = true,
                hitSlop = 12,
            }))
        end
    end

    if #todoRows == 0 then
        table.insert(todoRows, ui.label({
            text = showCompleted and "No todos on this page" or "No active todos on this page",
            color = "on_surface_variant",
            fontSize = 15,
        }))
    end

    local pageControls = {
        ui.select({ options = pageNames(), selectedIndex = currentPageIndex() - 1, onChange = function(index)
            local selected = data.pages[(tonumber(index) or 0) + 1]
            if selected ~= nil then
                data.current_page_id = selected.id or 0
                pageMode = ""
                save()
                render()
            end
        end }),
        ui.button({ glyph = "plus", tooltip = "New page", onClick = function()
            pageMode = "add"
            pageDraft = ""
            render()
        end }),
        ui.button({ glyph = "pencil", tooltip = "Rename page", onClick = function()
            pageMode = "rename"
            for _, page in ipairs(data.pages) do
                if sameId(page.id or 0, data.current_page_id or 0) then pageDraft = page.name or "" end
            end
            render()
        end }),
        ui.button({ glyph = "trash", tooltip = "Delete page", enabled = #data.pages > 1 and not sameId(data.current_page_id or 0, 0), onClick = deletePage }),
        ui.select({ options = { "High", "Medium", "Low" }, selectedIndex = priority == "high" and 0 or (priority == "low" and 2 or 1), onChange = function(index)
            local i = tonumber(index) or 1
            priority = i == 0 and "high" or (i == 2 and "low" or "medium")
        end }),
        ui.toggle({ checked = showCompleted, onChange = function(value) showCompleted = value == "true"; save(); render() end }),
        ui.label({ text = "Show completed", color = "on_surface_variant", flexGrow = 1 }),
    }

    local children = {
        ui.row({ gap = 8, align = "center" }, {
            ui.glyph({ name = "clipboard-check", size = 22, color = "primary" }),
            ui.label({ text = `Paged Todo List  ·  {activeCount()} active`, fontSize = 17, fontWeight = "bold", flexGrow = 1 }),
            ui.button({ glyph = "download", tooltip = "Export", onClick = exportTodos }),
            ui.button({ glyph = "trash", tooltip = "Clear completed", enabled = completedCount() > 0, onClick = clearCompleted }),
            ui.button({ glyph = "x", onClick = "onClose" }),
        }),
        ui.row({ gap = 6, align = "center" }, pageControls),
    }

    if pageMode ~= "" then
        table.insert(children, ui.row({ gap = 8, align = "center" }, {
            ui.input({ key = `page-draft-{pageMode}`, value = pageDraft, placeholder = pageMode == "add" and "New page name" or "Page name", submitOnEnter = true, onChange = function(value) pageDraft = value end, onSubmit = function() if pageMode == "add" then createPage() else renamePage() end end, flexGrow = 1 }),
            ui.button({ glyph = "check", onClick = function() if pageMode == "add" then createPage() else renamePage() end end }),
            ui.button({ glyph = "x", onClick = function() pageMode = ""; pageDraft = ""; render() end }),
        }))
    end

    table.insert(children, ui.input({
        key = `new-todo-{inputGeneration}`,
        placeholder = `Add a todo ({priorityLabel(priority)}) and press Enter…`,
        submitOnEnter = true,
        onSubmit = addTodo,
    }))
    table.insert(children, ui.scroll({ flexGrow = 1, gap = 4, align = "stretch", fill = "surface_variant/0.25", radius = 8, padding = 8 }, todoRows))
    panel.render(ui.column({ gap = 12, flexGrow = 1, align = "stretch" }, children))
end

noctalia.state.watch("data", function(value)
    if type(value) == "table" and type(value.todos) == "table" then
        data = value
        showCompleted = data.show_completed ~= false
        render()
    end
end)

function onOpen(_context)
    render()
end

function onClose()
    panel.close()
end

render()
