--!nonstrict
-- Keyboard bar widget: the short name of the language you type in, such as EN, TR or KO.
-- A click opens the panel, a right click or scroll switches to the next one. Renders
-- "keyboard.model" from service.luau.

local PANEL = "omerfuyar/keyboard:panel"

local model = nil

local function send(command)
  command.n = noctalia.nowMs()
  noctalia.state.set("keyboard.command", command)
end

local function render()
  if model == nil then
    return
  end
  -- Nothing to switch between: the widget hides.
  barWidget.setVisible(model.ready)
  if not model.ready then
    return
  end
  local current = nil
  for _, entry in ipairs(model.entries) do
    if entry.key == model.current then
      current = entry
    end
  end
  barWidget.render(ui.label({ text = current and current.short or "?" }))
  local rows = {}
  for _, entry in ipairs(model.entries) do
    table.insert(rows, { key = entry.short, value = entry.key == model.current and "● " .. entry.name or entry.name })
  end
  barWidget.setTooltip(rows)
end

noctalia.state.watch("keyboard.model", function(value)
  model = value
  render()
end)

function update()
  noctalia.setUpdateInterval(60000)
  model = model or noctalia.state.get("keyboard.model")
  render()
end

function onClick()
  noctalia.togglePanel(PANEL)
end

function onRightClick()
  send({ action = "next" })
end

-- steps is negative for up.
function onScroll(_axis, steps)
  send({ action = steps < 0 and "previous" or "next" })
end
