--!nonstrict

local common = require("./common.luau")

local snapshot = noctalia.state.get(common.SNAPSHOT_KEY) or { status = "starting" }
local action = noctalia.state.get(common.ACTION_KEY) or { status = "idle" }

local function configured(key, fallback)
  local value = noctalia.getConfig(key)
  if value == nil then return fallback end
  return value
end

local function task_colors(task)
  if type(task) ~= "table" then
    local color = snapshot.status == "ready" and "on_surface_variant" or "error"
    return color, color, color
  end
  local tracked = type(snapshot.currentTask) == "table" and snapshot.currentTask.id == task.id
  local due_at = common.task_due_at(task)
  if due_at ~= nil and due_at < noctalia.nowMs() then
    local text_color = configured("overdue_text_color", "error")
    return tracked and "primary" or "error", text_color, text_color
  end
  if tracked then return "primary", "primary", "on_surface_variant" end
  return "on_surface", "on_surface", "on_surface_variant"
end

local function tooltip(task)
  local lines = { noctalia.tr("title") }
  if type(task) == "table" then
    table.insert(lines, task.title or noctalia.tr("task.untitled"))
    table.insert(lines, common.relative_due(task))
    if task.project and task.project ~= "" then
      table.insert(lines, noctalia.tr("task.project", { value = task.project }))
    end
    if type(task.tags) == "table" and #task.tags > 0 then
      table.insert(lines, noctalia.tr("task.tags", { value = table.concat(task.tags, ", ") }))
    end
    local view = snapshot.view
    if type(view) == "table" and (view.count or 0) > 1 then
      table.insert(lines, noctalia.tr("bar.position", {
        index = view.index or 1,
        count = view.count or 1,
      }))
    end
    table.insert(lines, noctalia.tr("bar.gestures"))
  elseif snapshot.status ~= "ready" then
    table.insert(lines, noctalia.tr("status." .. tostring(snapshot.status or "starting")))
  else
    table.insert(lines, noctalia.tr("task.none_due"))
  end
  return table.concat(lines, "\n")
end

local function render()
  local task = snapshot.view and snapshot.view.task or nil
  local busy = common.action_busy(action)
  local glyph = busy and "loader-2" or configured("glyph", "checks")
  local glyph_color, text_color, due_color = task_colors(task)
  local children = {
    ui.glyph({ key = "icon", name = glyph, size = 15, color = glyph_color }),
  }

  if type(task) == "table" then
    local maximum = tonumber(configured("max_title_chars", 36)) or 36
    table.insert(children, ui.label({
      key = "title",
      text = common.truncate(task.title or noctalia.tr("task.untitled"), maximum),
      color = text_color,
      maxLines = 1,
    }))
    if configured("show_due_text", true) then
      table.insert(children, ui.label({
        key = "due",
        text = common.relative_due(task),
        color = due_color,
        fontSize = 10,
      }))
    end
  elseif snapshot.status == "ready" then
    table.insert(children, ui.label({ key = "empty", text = noctalia.tr("bar.no_due"), color = "on_surface_variant" }))
  else
    table.insert(children, ui.label({ key = "status", text = noctalia.tr("bar.unavailable"), color = "error" }))
  end

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 5, align = "center" }, children))
  barWidget.setTooltip(tooltip(task))
end

noctalia.state.watch(common.SNAPSHOT_KEY, function(value)
  snapshot = type(value) == "table" and value or snapshot
  render()
end)

noctalia.state.watch(common.ACTION_KEY, function(value)
  action = type(value) == "table" and value or action
  render()
end)

function onClick()
  noctalia.togglePanel(common.PANEL_ID)
end

function onRightClick()
  local task = snapshot.view and snapshot.view.task or nil
  if type(task) == "table" and not common.action_busy(action) then
    common.send_intent("complete", { taskId = task.id })
  end
end

function onMiddleClick()
  local task = snapshot.view and snapshot.view.task or nil
  if type(task) == "table" then
    common.send_intent("open", { taskId = task.id })
  else
    common.send_intent("launch")
  end
end

function onScroll(axis, steps, starts_gesture)
  if axis ~= "vertical" or not starts_gesture then return end
  local delta = tonumber(steps) or 0
  if delta == 0 then return end
  common.send_intent("browse", { delta = delta > 0 and 1 or -1 })
end

noctalia.setUpdateInterval(600000)
render()
