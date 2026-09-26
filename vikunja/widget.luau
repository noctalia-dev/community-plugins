--!nonstrict
-- Bar widget: how many tasks are due today or overdue.

local PANEL_ID = "omertahaoztop/vikunja:manager"
local STATE_KEY = "vk_snapshot"
local COMMAND_KEY = "vk_command"

local snapshot = noctalia.state.get(STATE_KEY) or {
  configured = false,
  available = false,
  error = "",
  counts = { overdue = 0, today = 0, soon = 0 },
  today = {},
  upcoming = {},
}

local requestId = 0
local render

local function configString(key, fallback)
  local value = noctalia.getConfig(key)
  return type(value) == "string" and value or fallback
end

local function counts()
  return snapshot.counts or { overdue = 0, today = 0, soon = 0 }
end

local function brandIcon(configured, available)
  if not configured or not available then
    return "assets/vikunja-grey.png"
  end
  return "assets/vikunja.png"
end

local function tooltipLines()
  local lines = {}
  for _, task in ipairs(snapshot.today or {}) do
    table.insert(lines, `{task.title} · {task.dueText}`)
    if #lines >= 5 then
      return lines
    end
  end
  for _, task in ipairs(snapshot.upcoming or {}) do
    table.insert(lines, `{task.title} · {task.dueText}`)
    if #lines >= 5 then
      break
    end
  end
  return lines
end

render = function()
  local configured = snapshot.configured == true
  local available = snapshot.available == true
  local stats = counts()
  local overdue = tonumber(stats.overdue) or 0
  local today = tonumber(stats.today) or 0
  local total = overdue + today

  local showLabel = noctalia.getConfig("show_label") ~= false
  local okColor = configString("ok_color", "tertiary")
  local warnColor = configString("warn_color", "error")
  local color = (not configured or not available) and "on_surface_variant"
    or (overdue > 0 and warnColor or okColor)

  local children = {
    ui.image({ path = brandIcon(configured, available), width = 16, height = 16, fit = "contain" }),
  }

  if showLabel then
    if not configured then
      table.insert(children, ui.label({ text = "…", color = "on_surface_variant" }))
    elseif available and total > 0 then
      table.insert(children, ui.label({
        text = noctalia.tr("widget.label_issues", { n = total }),
        fontWeight = "bold",
        color = color,
      }))
    elseif available then
      table.insert(children, ui.label({ text = noctalia.tr("widget.label_ok"), fontWeight = "bold", color = color }))
    end
  end

  if configured and available and total > 0 then
    table.insert(children, ui.box({ width = 7, height = 7, radius = 4, fill = color }))
  end

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 5, align = "center" }, children))

  if not configured then
    barWidget.setTooltip(noctalia.tr("widget.tooltip_missing"))
    return
  end
  if not available then
    barWidget.setTooltip(noctalia.tr("widget.tooltip_unavailable", {
      error = snapshot.error ~= "" and snapshot.error or "unknown",
    }))
    return
  end

  local lines = tooltipLines()
  local head
  if overdue > 0 then
    head = noctalia.tr("widget.tooltip_issues", {
      overdue = overdue,
      today = today,
      list = table.concat(lines, "\n"),
    })
  else
    head = noctalia.tr("widget.tooltip_ok", { today = today, soon = stats.soon or 0 })
    if #lines > 0 then
      head = head .. "\n" .. table.concat(lines, "\n")
    end
  end
  barWidget.setTooltip(head)
end

noctalia.state.watch(STATE_KEY, function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

noctalia.setUpdateInterval(8000)
render()

function update()
  render()
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
  requestId += 1
  noctalia.state.set(COMMAND_KEY, { action = "refresh", requestId = `widget-{requestId}` })
  noctalia.notify(noctalia.tr("title"), noctalia.tr("widget.refresh_requested"))
end
