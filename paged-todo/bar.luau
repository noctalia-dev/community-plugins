--!nonstrict
-- Compact bar tile for Paged Todo List.

local store = require("./data.luau")
local data = store.load()
noctalia.setUpdateInterval(1000)

local function activeCount()
    local count = 0
    if type(data.todos) == "table" then
        for _, todo in ipairs(data.todos) do
            if todo.completed ~= true then
                count += 1
            end
        end
    end
    return count
end

local function render()
    local count = activeCount()
    local key = count == 1 and "bar.todo_count_singular" or "bar.todo_count_plural"
    local label = noctalia.tr(key):gsub("{count}", tostring(count))
    -- Compensate for V5's narrower CJK text metrics so the capsule width
    -- matches the V4 reference while retaining V4's six-pixel icon gap.
    barWidget.render(ui.row({ gap = 6, align = "center", paddingH = 8 }, {
        ui.glyph({ name = "clipboard-check", size = 14, color = "on_surface" }),
        ui.label({ text = label, color = "on_surface", maxLines = 1 }),
    }))
    barWidget.setTooltip(label)
end

noctalia.state.watch("data", function(value)
    if type(value) == "table" then
        data = value
        render()
    end
end)

function update()
    render()
end

function onClick()
    noctalia.togglePanel("baizhu/paged-todo:panel")
end
