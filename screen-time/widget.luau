--!nonstrict
-- Screen Time bar widget: an hourglass and today's screen time; the tooltip lists the most
-- used apps. A click opens Noctalia's control center at Screen time: the manifest's left
-- action, which the user can rebind. Renders "screen-time.model" from service.luau.

local model = nil

-- "3h 12m", or "42m" under an hour.
local function duration(seconds)
  local minutes = math.floor(seconds / 60)
  if minutes >= 60 then
    return noctalia.tr("time.hours", { hours = math.floor(minutes / 60), minutes = minutes % 60 })
  end
  return noctalia.tr("time.minutes", { minutes = minutes })
end

-- An app's name from its id: the last part of a reverse domain name, such as Claude for
-- com.anthropic.Claude.
local function appName(id)
  if id:match("^%a+%.[%w-]+%.") then
    return id:match("([^.]+)$")
  end
  return id
end

local function render()
  if model == nil then
    return
  end
  -- Nothing to show until Noctalia records something.
  barWidget.setVisible(model.recording and model.found)
  if not (model.recording and model.found) then
    return
  end
  local children = { ui.glyph({ name = "hourglass" }) }
  if noctalia.getConfig("show_text") ~= false and not barWidget.isVertical() then
    table.insert(children, ui.label({ text = duration(model.total) }))
  end
  barWidget.render(ui.row({ gap = 4, align = "center" }, children))

  local rows = { { key = noctalia.tr("widget.today"), value = duration(model.total) } }
  for _, app in ipairs(model.apps) do
    table.insert(rows, { key = appName(app.id), value = duration(app.seconds) })
  end
  barWidget.setTooltip(rows)
end

noctalia.state.watch("screen-time.model", function(value)
  model = value
  render()
end)

function update()
  noctalia.setUpdateInterval(60000)
  model = model or noctalia.state.get("screen-time.model")
  render()
end

function onConfigChanged()
  render()
end
