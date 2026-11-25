--!nonstrict
-- Ping Monitor bar icon (all online / some offline). Left click opens the panel, right click checks all devices now.
local shared = require("./shared.luau")
local store = require("./store.luau")

local function render()
  local s = shared.snapshot()
  local overall = shared.overall(s.devices)
  local glyph = overall == "down" and "server-off" or (noctalia.getConfig("glyph") or "server")
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

-- Estimated height of the compact panel's content: section headers plus card rows, against the 640 px limit.
local function needsTallPanel()
  local s = shared.snapshot()
  local cols = tonumber(noctalia.getConfig("columns")) or 2
  local known, count = {}, {}
  for _, g in s.groups or {} do known[g.name] = true; count[g.name] = 0 end
  local loose = 0
  for _, d in s.devices do
    if d.group and d.group ~= "" and known[d.group] then count[d.group] = count[d.group] + 1 else loose = loose + 1 end
  end
  local est = 28 + 90
  for _, g in s.groups or {} do
    est = est + 34
    if g.collapsed ~= true then
      est = est + (count[g.name] == 0 and 44 or math.ceil(count[g.name] / cols) * 168)
    end
  end
  if loose > 0 then est = est + ((#(s.groups or {}) > 0) and 34 or 0) + math.ceil(loose / cols) * 168 end
  return est > 640
end

function onClick()
  noctalia.togglePanel(needsTallPanel() and "nofiltera1/ping-monitor:panel_tall" or "nofiltera1/ping-monitor:panel")
end

function onRightClick()
  -- Right click: check every device now (muting is in the panel)
  noctalia.state.set("refresh_rev", noctalia.nowMs())
end
