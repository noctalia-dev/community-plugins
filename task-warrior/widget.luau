--!nonstrict
-- Task Warrior bar widget: pending-task count, red when something is overdue or
-- due today (mirroring taskwarrior's own color.overdue / color.due.today).
-- A pure view over the service's "summary" state; left click toggles the panel,
-- right click asks the service for an immediate refresh.

local summary = noctalia.state.get("summary")

local function render()
  local pendingCount = 0
  local overdue = 0
  local dueToday = 0
  if type(summary) == "table" then
    pendingCount = summary.pending or 0
    overdue = summary.overdue or 0
    dueToday = summary.dueToday or 0
  end

  barWidget.setGlyph("swords")
  barWidget.setText(barWidget.isVertical() and "" or tostring(pendingCount))

  local role = (overdue > 0 or dueToday > 0) and "error" or "on_surface"
  barWidget.setColor(role)
  barWidget.setGlyphColor(role)

  local rows = { { noctalia.tr("bar.pending"), tostring(pendingCount) } }
  if overdue > 0 then
    table.insert(rows, { noctalia.tr("bar.overdue"), tostring(overdue) })
  end
  if dueToday > 0 then
    table.insert(rows, { noctalia.tr("bar.due-today"), tostring(dueToday) })
  end
  barWidget.setTooltip(rows)
end

noctalia.state.watch("summary", function(value)
  summary = value
  render()
end)

function onClick()
  noctalia.togglePanel("asj/task-warrior:panel")
end

local requestSeq = 0
function onRightClick()
  requestSeq += 1
  noctalia.state.set("request", { seq = "bar-" .. requestSeq, kind = "refresh" })
end

function update()
  render()
end

-- The service polls taskwarrior; the widget only needs a slow tick to pick up
-- orientation changes.
noctalia.setUpdateInterval(60000)
