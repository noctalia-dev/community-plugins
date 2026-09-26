--!nonstrict
local Store = require("./lib/store.luau")
local Text = require("./lib/text.luau")

local PANEL_ID = "fel/quill:panel"

local snapshot = noctalia.state.get("snapshot")
local scrollIndex = 0
local scrollUntil = 0

local function shellQuote(value)
  return "'" .. string.gsub(tostring(value), "'", "'\\''") .. "'"
end

local function openTodos()
  local out = {}
  if snapshot ~= nil then
    for _, todo in ipairs(snapshot.todos) do
      if not todo.done then
        out[#out + 1] = todo
      end
    end
  end
  return out
end

local function tooltipRows()
  local rows = {}
  if snapshot == nil then
    rows[#rows + 1] = { "Quill", "indexing…" }
    return rows
  end
  local counts = snapshot.counts or { open = 0, done = 0, due_today = 0, overdue = 0, notes = 0 }
  rows[#rows + 1] = { "Open todos", tostring(counts.open) }
  if counts.due_today > 0 then
    rows[#rows + 1] = { "Due today", tostring(counts.due_today) }
  end
  if counts.overdue > 0 then
    rows[#rows + 1] = { "Overdue", tostring(counts.overdue) }
  end
  rows[#rows + 1] = { "Notes", tostring(counts.notes) }

  local shown = 0
  for _, todo in ipairs(snapshot.todos) do
    if not todo.done then
      local due = Text.fmtDue(todo.due, todo.time)
      rows[#rows + 1] = { Text.truncate(todo.text, 42), due or "" }
      shown = shown + 1
      if shown >= 4 then
        break
      end
    end
  end

  rows[#rows + 1] = { "Scroll", "cycle open todos" }
  rows[#rows + 1] = { "Right click", "capture clipboard" }
  rows[#rows + 1] = { "Middle click", "edit " .. Store.inboxName() }
  return rows
end

local function render()
  if snapshot == nil then
    barWidget.setGlyph("notes")
    barWidget.setText("")
    barWidget.setTooltip(tooltipRows())
    return
  end

  local now = noctalia.nowMs()
  if now < scrollUntil then
    local todos = openTodos()
    if #todos > 0 then
      if scrollIndex < 1 then
        scrollIndex = 1
      elseif scrollIndex > #todos then
        scrollIndex = 1
      end
      local todo = todos[scrollIndex]
      local due = Text.fmtDue(todo.due, todo.time)
      barWidget.setGlyph("checkbox")
      barWidget.setText(Text.truncate(todo.text, 26))
      barWidget.setTooltip({
        { "Open todo " .. tostring(scrollIndex) .. "/" .. tostring(#todos), due or "" },
        { Text.truncate(todo.text, 60), "" },
        { "Click", "open the panel" },
      })
      return
    end
  elseif scrollUntil ~= 0 then
    scrollUntil = 0
    scrollIndex = 0
    noctalia.setUpdateInterval(30000)
  end

  local counts = snapshot.counts or { open = 0, done = 0, due_today = 0, overdue = 0, notes = 0 }
  local hideWhenEmpty = noctalia.getConfig("hide_when_empty") == true
  barWidget.setVisible(not (hideWhenEmpty and counts.open == 0 and counts.notes == 0))

  if counts.overdue > 0 then
    barWidget.setGlyph("alert-triangle")
  elseif counts.due_today > 0 then
    barWidget.setGlyph("checkbox")
  else
    barWidget.setGlyph("notes")
  end

  local showLabel = noctalia.getConfig("show_label") ~= false
  if showLabel and counts.open > 0 then
    barWidget.setText(tostring(counts.open))
  else
    barWidget.setText("")
  end

  local color = noctalia.getConfig("icon_color")
  if counts.overdue > 0 then
    barWidget.setGlyphColor("error")
  elseif type(color) == "string" and color ~= "" then
    barWidget.setGlyphColor(color)
  end

  barWidget.setTooltip(tooltipRows())
end

noctalia.state.watch("snapshot", function(value)
  snapshot = value
  render()
end)

noctalia.setUpdateInterval(30000)

function update()
  render()
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onScroll(axis, steps, startsGesture)
  if axis ~= "vertical" or not startsGesture then
    return
  end
  local todos = openTodos()
  if #todos == 0 then
    return
  end
  if scrollUntil == 0 then
    scrollIndex = 0
  end
  scrollIndex = scrollIndex + (steps > 0 and 1 or -1)
  if scrollIndex < 1 then
    scrollIndex = #todos
  elseif scrollIndex > #todos then
    scrollIndex = 1
  end
  scrollUntil = noctalia.nowMs() + 15000
  noctalia.setUpdateInterval(1000)
  render()
end

function onRightClick()
  local clip = noctalia.clipboardText()
  if clip == nil or Text.trim(clip) == "" then
    noctalia.notify("Quill", "Clipboard is empty")
    return
  end
  clip = Text.trim(clip)
  if string.find(clip, "\n", 1, true) ~= nil then
    Store.createNote(Text.firstLine(clip), clip)
    noctalia.notify("Quill", "Saved clipboard as a note")
  else
    Store.appendTodo(clip)
    noctalia.notify("Quill", "Captured: " .. Text.truncate(clip, 60))
  end
  Store.markDirty()
end

function onMiddleClick()
  local editor = noctalia.getenv("EDITOR")
  if editor == nil or Text.trim(editor) == "" then
    editor = "vi"
  end
  local words = {}
  for word in string.gmatch(editor, "%S+") do
    words[#words + 1] = shellQuote(word)
  end
  if #words == 0 then
    words[1] = shellQuote("vi")
  end
  noctalia.runInTerminal(table.concat(words, " ") .. " " .. shellQuote(Store.inboxPath()))
end

render()