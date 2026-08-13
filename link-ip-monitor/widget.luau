--!nonstrict
-- widget.luau
-- Bar widget: configurable icon (setting "glyph"); turns green when
-- everything responds, red with a count badge when something is down.
-- Click opens the panel with the full list.

local downCount = 0
local statuses = {}

local COLOR_DOWN = "#e05252"
local COLOR_UP   = "#2e7d32"

local function downList()
  local list = {}
  for _, s in ipairs(statuses) do
    if s.status == "down" then
      local text = (s.label ~= nil and s.label ~= "") and (s.label .. " (" .. s.ip .. ")") or s.ip
      table.insert(list, text)
    end
  end
  return list
end

local function render()
  local children = {}
  local glyphName = noctalia.getConfig("glyph") or "activity"
  local hasHosts = #statuses > 0

  if downCount > 0 then
    table.insert(children, ui.row({
      fill     = COLOR_DOWN,
      radius   = 8,
      paddingH = 5,
      paddingV = 1,
      align    = "center",
      justify  = "center",
    }, {
      ui.label({ text = tostring(downCount), fontSize = 10, fontWeight = "bold", color = "#ffffff" }),
    }))
    table.insert(children, ui.glyph({ name = glyphName, size = 14, color = COLOR_DOWN }))
  elseif hasHosts then
    -- everything responding: green icon, no badge
    table.insert(children, ui.glyph({ name = glyphName, size = 14, color = COLOR_UP }))
  else
    -- no hosts configured yet: neutral color (neither green nor red)
    table.insert(children, ui.glyph({ name = glyphName, size = 14 }))
  end

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 4, align = "center" }, children))

  local down = downList()
  if #down > 0 then
    barWidget.setTooltip(noctalia.tr("widget.tooltip_down_prefix") .. "\n" .. table.concat(down, "\n"))
  else
    barWidget.setTooltip(noctalia.tr("widget.tooltip_all_up"))
  end
end

noctalia.state.watch("link_ip_monitor.down_count", function(value)
  downCount = value or 0
  render()
end)

noctalia.state.watch("link_ip_monitor.statuses", function(value)
  statuses = (type(value) == "table") and value or {}
  render()
end)

render()

function update()
  noctalia.setUpdateInterval(5000) -- just keeps the widget "alive"; the real data comes from state
end

function onConfigChanged()
  render() -- pick up the new icon when the user changes it in the widget settings
end

function onClick()
  noctalia.togglePanel("nilsonlinux/link-ip-monitor:panel")
end

function onRightClick()
  noctalia.state.set("link_ip_monitor.cmd", { op = "refresh" })
  noctalia.notify(noctalia.tr("title"), noctalia.tr("widget.checking_now"))
end
