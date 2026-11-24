--!nonstrict
-- Ping Monitor bar icon (all online / some offline). Left click opens the panel, right click mutes or unmutes sound.
local shared = require("./shared.luau")
local store = require("./store.luau")

local function render()
  local s = shared.snapshot()
  local overall = shared.overall(s.devices)
  local glyph = overall == "down" and "server-off" or "server"
  barWidget.render(ui.glyph({ name = s.muted and "bell-off" or glyph, color = shared.color(overall) }))
  local rows = {}
  for _, d in s.devices do
    local key = d.status == "up" and "status.up" or (d.status == "down" and "status.down" or "status.checking")
    table.insert(rows, { key = shared.label(d), value = noctalia.tr(key) })
  end
  if s.muted then
    table.insert(rows, { key = noctalia.tr("panel.sound"), value = noctalia.tr("panel.muted") })
  end
  barWidget.setTooltip(rows)
end

function update()
  noctalia.setUpdateInterval(2000)
  render()
end

noctalia.state.watch("snap", function() render() end)

function onClick()
  noctalia.togglePanel("nofiltera1/ping-monitor:panel")
end

function onRightClick()
  local cfg = store.loadConfig()
  cfg.muted = not cfg.muted
  store.saveConfig(cfg)
  noctalia.state.set("cfg_rev", noctalia.nowMs())
  render()
end
