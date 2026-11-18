--!nonstrict
-- Bar entry: a dim flower while idle, the CLI spinner while working, and the
-- session limit next to it. Left click opens the panel.

local shared = require("./shared.luau")

local PANEL_ID = "teslaoruz/bloom:panel"
local SPIN_MS = 120
local POLL_MS = 1000

local data = nil
local frame = 1
local sinceRead = POLL_MS

local function render()
  local d = data or {}
  local state = d.state or "idle"
  local colour = shared.colour(state)
  local count = #(d.sessions or {})
  local five = d.limits and d.limits.five_hour and tonumber(d.limits.five_hour.used)

  local glyph = state == "working" and shared.FRAMES[frame] or (state == "waiting" and "✳" or shared.IDLE_GLYPH)
  -- Frames differ in width; a fixed-width row stops the pill from jittering
  -- (a label's own width follows its text).
  local icon = ui.row({ width = 18, justify = "center", align = "center" }, {
    ui.label({ text = glyph, color = colour, fontWeight = "bold" }),
  })

  local children = { icon }
  if count > 1 then
    table.insert(children, ui.label({ text = tostring(count), color = colour, fontSize = 10 }))
  end
  if five then
    table.insert(children, ui.label({ text = math.floor(five + 0.5) .. "%", color = shared.limitColour(five) }))
  end

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 5, align = "center" }, children))

  local tip = { { "Claude Code", shared.label(state) } }
  if count > 0 then
    table.insert(tip, { "Sessions", tostring(count) })
  end
  if five then
    table.insert(tip, { "Session limit", math.floor(five + 0.5) .. "%" })
  end
  local seven = d.limits and d.limits.seven_day and tonumber(d.limits.seven_day.used)
  if seven then
    table.insert(tip, { "Week limit", math.floor(seven + 0.5) .. "%" })
  end
  barWidget.setTooltip(tip)
end

function update()
  local working = data and data.state == "working"
  noctalia.setUpdateInterval(working and SPIN_MS or POLL_MS)
  if working then
    frame = frame % #shared.FRAMES + 1
  else
    frame = 1
  end

  sinceRead = sinceRead + (working and SPIN_MS or POLL_MS)
  if sinceRead >= POLL_MS then
    sinceRead = 0
    shared.read(function(fresh)
      data = fresh
      render()
    end, data)
  elseif data then
    render()
  end
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onIpc(event)
  if event == "open" then
    noctalia.togglePanel(PANEL_ID)
  end
end

render()
