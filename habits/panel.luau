--!nonstrict
-- Habits Panel: clean, essential habit tracking with dedicated viewing & management tabs.

local store = require("./store.luau")

local ICON_ROWS = {
  {
    { id = "none", label = "None", glyph = "circle" },
    { id = "target", label = "Goal", glyph = "target" },
    { id = "book", label = "Read", glyph = "book" },
    { id = "run", label = "Fitness", glyph = "run" },
    { id = "droplet", label = "Water", glyph = "droplet" },
  },
  {
    { id = "code", label = "Code", glyph = "code" },
    { id = "sun", label = "Morning", glyph = "sun" },
    { id = "moon", label = "Night", glyph = "moon" },
    { id = "heart", label = "Health", glyph = "heart" },
    { id = "star", label = "Focus", glyph = "star" },
  },
}

local data = { habits = {} }
local activeTab = "habits" -- "habits" | "add"
local newHabitText = ""
local selectedIcon = "none"
local inputRev = 0
local cornerRadiusScale = 1.0
local pendingDeleteId = nil

local render

local function reload()
  data = store.load()
end

local function toggleHabit(id)
  local today = store.today()
  for _, h in ipairs(data.habits) do
    if h.id == id then
      if type(h.history) ~= "table" then
        h.history = {}
      end
      if h.history[today] == true then
        h.history[today] = nil
      else
        h.history[today] = true
      end
      store.save(data)
      render()
      return
    end
  end
end

local function addHabit(name)
  local trimmed = noctalia.string.trim(name or "")
  if trimmed == "" then
    return
  end
  local id = "h_" .. tostring(os.time()) .. "_" .. tostring(#data.habits + 1)
  local icon = selectedIcon ~= "none" and selectedIcon or nil

  table.insert(data.habits, {
    id = id,
    name = trimmed,
    icon = icon,
    created_at = store.today(),
    history = {},
  })
  store.save(data)
  newHabitText = ""
  selectedIcon = "none"
  inputRev += 1
  activeTab = "habits"
  render()
end

local function deleteHabit(id)
  for i, h in ipairs(data.habits) do
    if h.id == id then
      table.remove(data.habits, i)
      store.save(data)
      pendingDeleteId = nil
      render()
      return
    end
  end
end

function onNewHabitChange(value)
  newHabitText = value
end

function onNewHabitSubmit(value)
  addHabit(value or newHabitText)
end

function onAddClicked()
  addHabit(newHabitText)
end

-- Clean minimal completion metric: numbers above, thin hairline below
local function completionHeader(summary)
  local isComplete = summary.total > 0 and summary.completed == summary.total
  local progressFill = isComplete and "primary" or "on_surface"

  return ui.column({
    key = "completion_header",
    gap = 6,
    align = "stretch",
  }, {
    ui.row({ align = "center" }, {
      ui.label({
        text = "DAILY COMPLETION",
        fontSize = 11,
        fontWeight = "bold",
        color = "on_surface_variant",
        flexGrow = 1,
      }),
      ui.label({
        text = string.format("%d/%d  ·  %d%%", summary.completed, summary.total, summary.percent),
        fontSize = 12,
        fontWeight = "bold",
        color = isComplete and "primary" or "on_surface",
      }),
    }),
    ui.progress({
      progress = summary.total > 0 and (summary.completed / summary.total) or 0,
      height = 2,
      fill = progressFill,
    }),
  })
end

-- Tab 1: Viewing and checking off habits
local function viewingTab(today, cornerRadius)
  if #data.habits == 0 then
    return ui.column({
      key = "empty_habits_view",
      gap = 8,
      align = "center",
      padding = 32,
      flexGrow = 1,
    }, {
      ui.glyph({ name = "circle-check", size = 28, color = "on_surface_variant" }),
      ui.label({
        text = "No habits tracked yet.",
        fontSize = 13,
        fontWeight = "medium",
        color = "on_surface",
      }),
      ui.label({
        text = "Switch to the Add tab to create one.",
        fontSize = 11,
        color = "on_surface_variant",
      }),
    })
  end

  local rows = {}
  for _, h in ipairs(data.habits) do
    local isDone = h.history and h.history[today] == true

    local rowChildren = {
      -- Green icon when completed, muted outline when unfinished
      ui.glyph({
        name = isDone and "circle-check" or "circle",
        size = 18,
        color = isDone and "primary" or "outline_variant",
      }),
    }

    if h.icon and h.icon ~= "" and h.icon ~= "none" then
      table.insert(rowChildren, ui.glyph({
        name = h.icon,
        size = 15,
        color = isDone and "primary" or "on_surface",
      }))
    end

    table.insert(rowChildren, ui.label({
      text = h.name,
      fontSize = 13,
      fontWeight = isDone and "normal" or "medium",
      color = isDone and "on_surface_variant" or "on_surface",
      flexGrow = 1,
      maxLines = 1,
    }))

    table.insert(rows, ui.row({
      key = "habit_view_" .. h.id .. (isDone and "_done" or ""),
      gap = 10,
      align = "center",
      padding = 10,
      paddingH = 12,
      fill = isDone and "surface_container/0.2" or "surface_container/0.4",
      radius = 6 * cornerRadius,
      onClick = function()
        toggleHabit(h.id)
      end,
    }, rowChildren))
  end

  return ui.scroll({
    key = "scroll_habits_list",
    flexGrow = 1,
    gap = 6,
  }, rows)
end

-- Tab 2: Adding and managing habits
local function addTab(cornerRadius)
  local function makeIconRow(options)
    local buttons = {}
    for _, opt in ipairs(options) do
      local isSelected = selectedIcon == opt.id
      table.insert(buttons, ui.button({
        glyph = opt.glyph,
        variant = isSelected and "tonal" or "ghost",
        controlSize = "sm",
        flexGrow = 1,
        tooltip = opt.label,
        onClick = function()
          selectedIcon = opt.id
          render()
        end,
      }))
    end
    return ui.row({ gap = 4, align = "center" }, buttons)
  end

  local manageRows = {}
  for _, h in ipairs(data.habits) do
    local isPendingDelete = pendingDeleteId == h.id
    local itemChildren = {}

    if h.icon and h.icon ~= "" and h.icon ~= "none" then
      table.insert(itemChildren, ui.glyph({
        name = h.icon,
        size = 14,
        color = "on_surface_variant",
      }))
    else
      table.insert(itemChildren, ui.glyph({
        name = "circle",
        size = 12,
        color = "outline_variant",
      }))
    end

    table.insert(itemChildren, ui.label({
      text = h.name,
      fontSize = 13,
      fontWeight = "medium",
      color = "on_surface",
      flexGrow = 1,
      maxLines = 1,
    }))

    if isPendingDelete then
      table.insert(itemChildren, ui.label({ text = "Delete?", color = "error", fontSize = 11 }))
      table.insert(itemChildren, ui.button({
        glyph = "check",
        variant = "tonal",
        controlSize = "sm",
        onClick = function()
          deleteHabit(h.id)
        end,
      }))
      table.insert(itemChildren, ui.button({
        glyph = "x",
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          pendingDeleteId = nil
          render()
        end,
      }))
    else
      table.insert(itemChildren, ui.button({
        glyph = "trash",
        variant = "ghost",
        controlSize = "sm",
        tooltip = "Delete habit",
        onClick = function()
          pendingDeleteId = h.id
          render()
        end,
      }))
    end

    table.insert(manageRows, ui.row({
      key = "manage_" .. h.id,
      gap = 8,
      align = "center",
      padding = 8,
      paddingH = 10,
      fill = "surface_container/0.3",
      radius = 6 * cornerRadius,
    }, itemChildren))
  end

  return ui.column({
    key = "add_tab_column",
    flexGrow = 1,
    gap = 12,
    align = "stretch",
  }, {
    -- New Habit Input Form
    ui.column({ gap = 8, align = "stretch" }, {
      ui.row({ gap = 8, align = "center" }, {
        ui.input({
          key = "new_habit_input_" .. tostring(inputRev),
          value = newHabitText,
          placeholder = "Habit name...",
          flexGrow = 1,
          onChange = "onNewHabitChange",
          onSubmit = "onNewHabitSubmit",
        }),
        ui.button({
          glyph = "plus",
          variant = "tonal",
          tooltip = "Add habit",
          onClick = "onAddClicked",
        }),
      }),
      -- Icon Picker in 2 balanced rows (5 icons each)
      makeIconRow(ICON_ROWS[1]),
      makeIconRow(ICON_ROWS[2]),
    }),

    -- Manage Existing Habits Section
    ui.label({
      text = "MANAGE HABITS",
      fontSize = 11,
      fontWeight = "bold",
      color = "on_surface_variant",
    }),

    #manageRows > 0 and ui.scroll({
      key = "scroll_manage_list",
      flexGrow = 1,
      gap = 6,
    }, manageRows) or ui.label({
      text = "No habits created yet.",
      fontSize = 12,
      color = "on_surface_variant",
    }),
  })
end

render = function()
  local today = store.today()
  local summary = store.summary(data, today)

  local tabBar = ui.row({
    key = "main_tab_bar",
    gap = 3,
    fill = "surface_container/0.5",
    radius = 6 * cornerRadiusScale,
    padding = 3,
    align = "center",
  }, {
    ui.button({
      key = "btn_tab_habits",
      text = "Habits",
      variant = activeTab == "habits" and "tonal" or "ghost",
      controlSize = "sm",
      flexGrow = 1,
      opacity = activeTab == "habits" and 1.0 or 0.45,
      onClick = function()
        activeTab = "habits"
        pendingDeleteId = nil
        render()
      end,
    }),
    ui.button({
      key = "btn_tab_add",
      text = "Add",
      variant = activeTab == "add" and "tonal" or "ghost",
      controlSize = "sm",
      flexGrow = 1,
      opacity = activeTab == "add" and 1.0 or 0.45,
      onClick = function()
        activeTab = "add"
        pendingDeleteId = nil
        render()
      end,
    }),
  })

  local tabBody
  if activeTab == "habits" then
    tabBody = ui.column({
      key = "tab_body_habits",
      flexGrow = 1,
      gap = 12,
      align = "stretch",
    }, {
      completionHeader(summary),
      viewingTab(today, cornerRadiusScale),
    })
  else
    tabBody = ui.column({
      key = "tab_body_add",
      flexGrow = 1,
      gap = 12,
      align = "stretch",
    }, {
      addTab(cornerRadiusScale),
    })
  end

  panel.render(ui.column({
    key = "root_panel_column",
    flexGrow = 1,
    gap = 12,
    align = "stretch",
    padding = 16,
  }, {
    tabBar,
    tabBody,
  }))
end

function onOpen(_context)
  cornerRadiusScale = noctalia.getSetting("shell.corner_radius_scale") or 1.0
  pendingDeleteId = nil
  activeTab = "habits"
  reload()
  render()
end

function onClose()
  pendingDeleteId = nil
end

function update()
  render()
end

reload()
