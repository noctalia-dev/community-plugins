--!nonstrict
-- Command Code usage meters, rendered from cc_usage.py (--json).
-- The host owns tile position/size; this script only renders content.

noctalia.setUpdateInterval(60000)

local state = {
  title = "Command Code",
  description = "carregando…",
}

local function render()
  desktopWidget.render(ui.column({
    gap = 2,
    padding = 10,
    fill = "surface/0.55",
    radius = 12,
    align = "start",
  }, {
    ui.label({
      text = state.title,
      fontSize = 20,
      fontWeight = "bold",
      color = "primary",
    }),
    ui.label({
      text = state.description,
      fontSize = 12,
      color = "on_surface/0.8",
    }),
  }))
end

local function refresh()
  local script = noctalia.pluginDir() .. "/cc_usage.py"
  local plan = noctalia.getConfig("plan") or "GOAT"
  local multiplier = noctalia.getConfig("multiplier") or 2.5
  local billingDay = noctalia.getConfig("billing_day") or 28
  local command = string.format(
    "CC_USAGE_PLAN='%s' CC_USAGE_MULTIPLIER='%s' CC_USAGE_BILLING_DAY='%s' python3 '%s' --json",
    plan, tostring(multiplier), tostring(billingDay), script)
  noctalia.runAsync(command, function(result)
    if result.exitCode ~= 0 or result.stdout == "" then
      return
    end
    local ok, data = pcall(noctalia.json.decode, result.stdout)
    if not ok or data == nil then
      return
    end
    state.title = data.title or state.title
    state.description = data.description or state.description
    render()
  end)
end

function update()
  refresh()
end

render()
refresh()
