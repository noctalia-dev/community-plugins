--!nonstrict
-- Native, non-focusable panel. Semantic colors resolve against the live theme.
local COUNT = 13
local history = table.create(COUNT + 1, 0)
local phase = "idle"
local level = 0
local levelAt = 0
local elapsed = 0
local historyBudget = 0
local opened = false

local function render()
  local processing = phase == "transcribing"
  local bars = {}
  local fraction = historyBudget / 120
  for i = 1, COUNT do
    local height
    if processing then
      -- A travelling wave distinguishes processing from the real audio envelope.
      height = 3 + 11 * (0.5 + 0.5 * math.sin(elapsed * 5 - i * 0.65)) ^ 3
    else
      -- Interpolate neighboring samples instead of jumping one column at a time.
      local amplitude = history[i] + (history[i + 1] - history[i]) * fraction
      height = 2 + 14 * amplitude
    end
    table.insert(bars, ui.box({
      key = "bar-" .. i, width = 4, height = height, radius = 2,
      fill = "primary",
    }))
  end
  panel.render(ui.row({ align = "center", justify = "center", gap = 8, flexGrow = 1 }, {
    ui.glyph({ name = processing and "hourglass" or "microphone-2", size = 16, width = 12, height = 16, color = "primary" }),
    ui.row({ align = "center", justify = "center", gap = 3, width = 88, height = 18 }, bars),
  }))
end

noctalia.state.watch("osd_phase", function(value)
  if type(value) ~= "string" then return end
  phase = value
  if opened and phase ~= "recording" and phase ~= "streaming" and phase ~= "transcribing" then
    panel.close()
  end
end)
noctalia.state.watch("osd_level", function(value)
  if type(value) ~= "table" then return end
  level = tonumber(value.value) or 0
  levelAt = tonumber(value.at) or 0
end)

function onOpen(_context)
  phase = noctalia.state.get("osd_phase") or "idle"
  if phase ~= "recording" and phase ~= "streaming" and phase ~= "transcribing" then
    panel.close()
    return
  end
  opened = true
  elapsed, historyBudget = 0, 0
  history = table.create(COUNT + 1, 0)
  panel.setNeedsFrameTick(true)
  render()
end

function onFrameTick(deltaMs)
  local dt = math.min(tonumber(deltaMs) or 16, 100)
  elapsed += dt / 1000
  historyBudget += dt
  if historyBudget >= 120 then
    historyBudget %= 120
    table.remove(history, 1)
    local fresh = noctalia.nowMs() - levelAt < 200
    table.insert(history, fresh and level or 0)
  end
  render()
end

function onClose()
  opened = false
  panel.setNeedsFrameTick(false)
end
