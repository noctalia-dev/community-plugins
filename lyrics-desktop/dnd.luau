--!nonstrict
-- Reference [[panel]] entry for drag and drop (plugin_api >= 5).
--
-- Demonstrates the full DnD vocabulary:
--   * ui.dragSource - a grip handle with previewAncestor = 1 (the ghost shows
--     the whole row) and liftFromLayout (the row leaves the list while dragged)
--   * ui.dropZone - thin insertion zones between rows; expandOnDrag + hitSlop
--     make them easy to hit without adding idle whitespace
--   * a catch-all zone per column, so an empty column stays a valid target
--   * cross-container moves - both columns accept the same dragType
--   * a rejected zone - accepts a different type, so it never highlights
--
-- The host owns pointer capture, the ghost, and target highlighting; this
-- script owns the data: onTaskDropped(payload, value) mutates the model and
-- re-renders. Nothing moves without the callback.
-- Open it with: noctalia msg panel-toggle noctalia/example:dnd

local DRAG_TYPE = "example-task"

local columns = {
  { id = "today", title = "Today", items = { "Write release notes", "Review the panel PR", "Water the cactus" } },
  { id = "later", title = "Later", items = { "Refactor tray menus", "Sort wallpapers" } },
}
local status = "Drag a row by its grip."

local function findTask(text)
  for c, column in ipairs(columns) do
    for i, item in ipairs(column.items) do
      if item == text then
        return c, i
      end
    end
  end
  return nil, nil
end

local function findColumn(id)
  for c, column in ipairs(columns) do
    if column.id == id then
      return c
    end
  end
  return nil
end

-- value is either "<columnId>" (catch-all: append) or "<columnId>:<index>"
-- (insertion zone: insert at that position).
function onTaskDropped(payload, value)
  local colId, indexText = string.match(value, "^(%a+):(%d+)$")
  if colId == nil then
    colId = value
  end
  local fromCol, fromIdx = findTask(payload)
  local toCol = findColumn(colId)
  if fromCol == nil or toCol == nil then
    return
  end

  table.remove(columns[fromCol].items, fromIdx)
  local insertAt = indexText ~= nil and tonumber(indexText) or (#columns[toCol].items + 1)
  if fromCol == toCol and fromIdx < insertAt then
    insertAt -= 1
  end
  insertAt = math.max(1, math.min(insertAt, #columns[toCol].items + 1))
  table.insert(columns[toCol].items, insertAt, payload)

  status = string.format('Moved "%s" to %s', payload, value)
  render()
end

function onResetClicked()
  columns = {
    { id = "today", title = "Today", items = { "Write release notes", "Review the panel PR", "Water the cactus" } },
    { id = "later", title = "Later", items = { "Refactor tray menus", "Sort wallpapers" } },
  }
  status = "Drag a row by its grip."
  render()
end

function onCloseClicked()
  panel.close()
end

local function taskRow(item)
  return ui.row({
    key = "task-" .. item,
    gap = 8,
    align = "center",
    padding = 6,
    fill = "surface_variant/0.4",
    radius = 10,
  }, {
    ui.dragSource({
      key = "grip-" .. item,
      dragType = DRAG_TYPE,
      payload = item,
      previewAncestor = 1, -- ghost shows the whole row, not just the grip
      liftFromLayout = true, -- the row leaves the list while dragged
      width = 24,
      height = 24,
      align = "center",
      justify = "center",
      tooltip = "Drag to move",
    }, {
      ui.glyph({ name = "menu-2", size = 14, color = "on_surface_variant" }),
    }),
    ui.label({ text = item, flexGrow = 1 }),
  })
end

local function insertionZone(column, index)
  return ui.dropZone({
    key = string.format("gap-%s-%d", column.id, index),
    accepts = { DRAG_TYPE },
    value = string.format("%s:%d", column.id, index),
    onDrop = "onTaskDropped",
    height = 3,
    radius = 6,
    expandOnDrag = true, -- grows to the dragged row's height while targeted
    hitSlop = 28, -- reachable from the neighboring rows without idle space
  })
end

local function columnCard(column)
  local children = {
    ui.label({ text = column.title, fontWeight = "bold", color = "on_surface_variant" }),
  }
  for i, item in ipairs(column.items) do
    children[#children + 1] = insertionZone(column, i)
    children[#children + 1] = taskRow(item)
  end
  children[#children + 1] = insertionZone(column, #column.items + 1)
  return ui.dropZone({
    key = "column-" .. column.id,
    accepts = { DRAG_TYPE },
    value = column.id,
    onDrop = "onTaskDropped",
    gap = 4,
    padding = 8,
    radius = 12,
    fill = "surface_variant/0.15",
    flexGrow = 1,
  }, children)
end

function render()
  panel.render(ui.column({ flexGrow = 1, gap = 12 }, {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.label({ text = "Drag & Drop", fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
      ui.button({ glyph = "refresh", tooltip = "Reset the lists", onClick = "onResetClicked" }),
      ui.button({ glyph = "close", onClick = "onCloseClicked" }),
    }),

    ui.row({ gap = 12, align = "stretch", flexGrow = 1 }, {
      columnCard(columns[1]),
      columnCard(columns[2]),
    }),

    -- Accepts a different dragType, so dragging a task over it never
    -- highlights and releasing on it cancels silently.
    ui.dropZone({
      key = "rejected",
      accepts = { "something-else" },
      value = "rejected",
      onDrop = "onTaskDropped",
      padding = 8,
      radius = 10,
      border = "outline/0.5",
    }, {
      ui.label({ text = "Rejects tasks (different dragType) - never highlights", fontSize = 12, color = "on_surface_variant" }),
    }),

    ui.label({ text = status, fontSize = 12, color = "on_surface_variant" }),
  }))
end

function onOpen(_context)
  render()
end
