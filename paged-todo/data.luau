--!nonstrict
-- Persistent store for Paged Todo List. Noctalia's shared state is
-- process-local, so the JSON file keeps tasks across Noctalia restarts.

local M = {}
local dataDir = noctalia.pluginDataDir()
local dataPath = dataDir ~= nil and `{dataDir}/todos.json` or nil

local function defaultData()
    return {
        todos = {},
        pages = {{ id = 0, name = "General" }},
        current_page_id = 0,
        show_completed = true,
        export_path = "~/Documents",
        export_format = "markdown",
        export_empty_sections = false,
    }
end

local function validData(value)
    return type(value) == "table" and type(value.todos) == "table"
end

local function decodeFile(path)
    local text = noctalia.readFile(path)
    if text == nil or text == "" then
        return nil
    end
    local value = noctalia.json.decode(text)
    return type(value) == "table" and value or nil
end

local function legacyData()
    -- V4 stores the mutable Todo data in the plugin's own settings file. Read
    -- that first; the global settings fallback supports older installations
    -- that embedded the widget's defaultSettings in settings.json.
    local pluginRoot = decodeFile("~/.config/noctalia/plugins/todo/settings.json")
    if pluginRoot ~= nil and type(pluginRoot.todos) == "table" then
        return {
            todos = pluginRoot.todos,
            pages = pluginRoot.pages or {{ id = 0, name = "General" }},
            current_page_id = pluginRoot.current_page_id or 0,
            show_completed = pluginRoot.showCompleted ~= false,
            export_path = pluginRoot.exportPath or "~/Documents",
            export_format = pluginRoot.exportFormat or "markdown",
            export_empty_sections = pluginRoot.exportEmptySections == true,
        }
    end

    local root = decodeFile("~/.config/noctalia/settings.json")
    if root == nil or root.bar == nil or root.bar.widgets == nil then
        return nil
    end
    local sections = { root.bar.widgets.left, root.bar.widgets.center, root.bar.widgets.right }
    for _, section in ipairs(sections) do
        if type(section) == "table" then
            for _, item in ipairs(section) do
                if type(item) == "table" and item.id == "plugin:todo" and type(item.defaultSettings) == "table" then
                    local old = item.defaultSettings
                    return {
                        todos = old.todos or {},
                        pages = old.pages or {{ id = 0, name = "General" }},
                        current_page_id = old.current_page_id or 0,
                        show_completed = old.showCompleted ~= false,
                        export_path = old.exportPath or "~/Documents",
                        export_format = old.exportFormat or "markdown",
                        export_empty_sections = old.exportEmptySections == true,
                    }
                end
            end
        end
    end
    return nil
end

function M.load()
    local live = noctalia.state.get("data")
    if validData(live) then
        return live
    end

    local saved = dataPath ~= nil and noctalia.readFile(dataPath) or nil
    local parsed = saved ~= nil and saved ~= "" and noctalia.json.decode(saved) or nil
    local data = validData(parsed) and parsed or legacyData() or defaultData()
    -- Preserve V4 records verbatim where possible, only filling fields that
    -- the V5 panel relies on. In particular, keep createdAt/priority/details
    -- so upgrading does not silently discard the user's metadata.
    for _, todo in ipairs(data.todos) do
        if type(todo) == "table" then
            if todo.pageId == nil then todo.pageId = 0 end
            if todo.completed == nil then todo.completed = false end
            if todo.priority ~= "high" and todo.priority ~= "medium" and todo.priority ~= "low" then
                todo.priority = "medium"
            end
            if todo.details == nil then todo.details = "" end
        end
    end
    if type(data.pages) ~= "table" or #data.pages == 0 then
        data.pages = {{ id = 0, name = "General" }}
    end
    if data.current_page_id == nil then
        data.current_page_id = data.pages[1].id or 0
    end
    if data.show_completed == nil then
        data.show_completed = true
    end
    if data.export_path == nil then data.export_path = "~/Documents" end
    if data.export_format == nil then data.export_format = "markdown" end
    if data.export_empty_sections == nil then data.export_empty_sections = false end
    noctalia.state.set("data", data)
    local encoded = noctalia.json.encode(data)
    if dataPath ~= nil and encoded ~= nil then
        noctalia.writeFile(dataPath, encoded)
    end
    return data
end

function M.save(data)
    noctalia.state.set("data", data)
    local encoded = noctalia.json.encode(data)
    if dataPath ~= nil and encoded ~= nil then
        noctalia.writeFile(dataPath, encoded)
    end
end

return M
