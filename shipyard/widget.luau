--!nonstrict
-- Docker & Podman Shipyard Bar Widget

local PANEL_ID = "ishan0121/shipyard:manager"
local KEY_SNAPSHOT = "shipyard_snapshot"

local snapshot = noctalia.state.get(KEY_SNAPSHOT) or {
  daemon = "docker",
  available = true,
  active = true,
  containers = {},
  globalStats = { cpu = "0%", ram = "0B" },
}

local function render()
  local showStats = noctalia.getConfig("show_stats") ~= false
  local glyphName = noctalia.getConfig("glyph") or "ship"
  local containers = snapshot.containers or {}
  local runningCount = 0

  for _, c in ipairs(containers) do
    if c.state == "running" then
      runningCount += 1
    end
  end

  local stats = snapshot.globalStats or { cpu = "0%", ram = "0B" }

  local children = {
    ui.glyph({
      name = glyphName,
      size = 16,
      color = snapshot.active and "primary" or "on_surface_variant",
    }),
    ui.label({
      text = tostring(runningCount),
      fontWeight = "bold",
      color = "on_surface",
    }),
  }

  if showStats and runningCount > 0 then
    table.insert(children, ui.label({
      text = stats.cpu or "0%",
      fontSize = 11,
      color = "on_surface_variant",
    }))
  end

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 5, align = "center" }, children))
  barWidget.setTooltip(string.format(
    "%s (%s): %d running containers | CPU: %s | RAM: %s",
    noctalia.tr("name"),
    snapshot.daemon or "docker",
    runningCount,
    stats.cpu or "0%",
    stats.ram or "0B"
  ))
end

noctalia.state.watch(KEY_SNAPSHOT, function(val)
  if type(val) == "table" then
    snapshot = val
    render()
  end
end)

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

render()
