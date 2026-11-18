--!nonstrict
local shared = require("./shared.luau")

local ICON_SIZE = 16

local function barText(mode, tracked)
  local first = tracked[1]
  if mode == "next_goal_countdown" then
    return first and `{first.slug} · {shared.formatCountdown(first.losedate)}` or nil
  elseif mode == "next_goal_requirement" then
    return first and `{first.slug} {first.limsum}` or nil
  elseif mode == "countdown" then
    return first and shared.formatCountdown(first.losedate) or nil
  end

  local due, atRisk, minBuffer = 0, 0, nil
  for _, goal in ipairs(tracked) do
    if shared.isDue(goal) then
      due += 1
      atRisk += goal.pledge
    end
    minBuffer = minBuffer and math.min(minBuffer, goal.safebuf) or goal.safebuf
  end

  if mode == "beemergencies" then
    return noctalia.tr("bar.due", { count = due })
  elseif mode == "at_risk" then
    return shared.formatMoney(atRisk)
  elseif mode == "min_buffer" then
    return minBuffer and noctalia.tr("bar.days", { days = minBuffer }) or nil
  end
  return nil
end

local function anyDue(tracked)
  for _, goal in ipairs(tracked) do
    if shared.isDue(goal) then
      return true
    end
  end
  return false
end

local function render()
  local report = shared.report()
  local failed = report ~= nil and report.status ~= "ok"
  local tracked = report and report.status == "ok" and shared.trackedGoals(report) or {}

  local icon
  if report == nil then
    icon = shared.ICON_LOADING
  elseif failed then
    icon = shared.ICON_ERROR
  else
    icon = shared.iconFor(tracked[1] and tracked[1].colorkey)
  end

  local text = nil
  if not failed and not (noctalia.getConfig("quiet_until_due") and not anyDue(tracked)) then
    text = barText(noctalia.getConfig("bar_text"), tracked)
  end

  -- An error must never be invisible, and the widget must never render empty.
  local showBee = noctalia.getConfig("show_bee") or failed or text == nil

  local children = {}
  if showBee then
    table.insert(children, ui.image({ path = icon, width = ICON_SIZE, height = ICON_SIZE }))
  end
  if text ~= nil then
    table.insert(children, ui.label({ text = text }))
  end

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 6, align = "center" }, children))
end

noctalia.state.watch("report", function(_)
  render()
end)

-- Countdowns are derived from losedate locally, so the text stays current between polls.
noctalia.setUpdateInterval(30 * 1000)
render()

function update()
  render()
end

function onClick()
  local report = shared.report()
  if report ~= nil and report.status == "no_token" then
    noctalia.openSettings()
  else
    noctalia.togglePanel(`{shared.PLUGIN_ID}:goals`)
  end
end

function onRightClick()
  noctalia.togglePanel(`{shared.PLUGIN_ID}:menu`)
end
