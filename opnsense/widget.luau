--!nonstrict
-- Bar widget: aggregate health of every firewall, or one firewall when the
-- widget instance setting names it.

local PANEL_ID = "davemhammer/opnsense:manager"
local STATE_KEY = "opn_snapshot"
local COMMAND_KEY = "opn_command"

local snapshot = noctalia.state.get(STATE_KEY) or {
  available = false,
  configured = false,
  issueCount = 0,
  host = "",
  error = "",
  resources = {},
  interfaces = {},
  instances = {},
}

local requestId = 0
local render

local function configString(key, fallback)
  local value = noctalia.getConfig(key)
  return type(value) == "string" and value or fallback
end

local function lower(s)
  return string.lower(tostring(s or ""))
end

local function instances()
  return type(snapshot.instances) == "table" and snapshot.instances or {}
end

-- nil = aggregate of every firewall.
local function targetedInstance()
  local wanted = configString("instance", "")
  if wanted == "" then
    return nil
  end
  for _, inst in ipairs(instances()) do
    if lower(inst.id) == lower(wanted) or lower(inst.name) == lower(wanted) or lower(inst.host) == lower(wanted) then
      return inst
    end
  end
  return nil
end

-- An unreachable firewall counts as an issue on the bar.
local function issueCount(inst, reachable)
  local n = tonumber(inst.issueCount) or 0
  if not reachable then
    n += 1
  end
  return n
end

local function brandIcon(configured, available, healthy)
  -- Real OPNsense mark (Simple Icons); tinted for state.
  if not configured or not available then
    return "assets/opnsense-grey.png"
  end
  if healthy then
    return "assets/opnsense-orange.png" -- brand orange when healthy
  end
  return "assets/opnsense-red.png" -- issues
end

render = function()
  local configured = snapshot.configured == true
  local showLabel = noctalia.getConfig("show_label") ~= false
  local okColor = configString("ok_color", "tertiary")
  local warnColor = configString("warn_color", "error")

  local target = targetedInstance()
  local list = instances()
  local issues, available = 0, false

  for _, inst in ipairs(list) do
    local reachable = inst.available == true
    if target == nil then
      issues += issueCount(inst, reachable)
    end
    available = available or reachable
  end
  if target ~= nil then
    available = target.available == true
    issues = issueCount(target, available)
  end
  if configured and target == nil and #list == 0 then
    available = false
  end

  local healthy = configured and available and issues == 0
  local color = (not configured or not available) and "on_surface_variant"
    or (healthy and okColor or warnColor)

  local children = {
    ui.image({
      path = brandIcon(configured, available, healthy),
      width = 16,
      height = 16,
      fit = "contain",
    }),
  }

  if showLabel then
    if not configured then
      table.insert(children, ui.label({ text = "…", color = "on_surface_variant" }))
    elseif available then
      table.insert(children, ui.label({
        text = healthy and noctalia.tr("widget.label_ok")
          or noctalia.tr("widget.label_issues", { n = issues }),
        fontWeight = "bold",
        color = color,
      }))
    end
  end

  if configured and available then
    table.insert(children, ui.box({
      width = 7,
      height = 7,
      radius = 4,
      fill = healthy and okColor or warnColor,
    }))
  end

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 5, align = "center" }, children))

  -- Tooltip
  if not configured then
    barWidget.setTooltip(noctalia.tr("widget.tooltip_missing"))
    return
  end

  if target == nil and configString("instance", "") ~= "" then
    barWidget.setTooltip(noctalia.tr("widget.tooltip_unknown_instance", { name = configString("instance", "") }))
    return
  end

  local down = 0
  for _, inst in ipairs(list) do
    if inst.available ~= true then
      down += 1
    end
  end

  if target == nil and #list > 1 then
    local lines = {
      noctalia.tr("widget.tooltip_aggregate", {
        n = #list,
        issues = issues,
        down = down,
      }),
    }
    for _, inst in ipairs(list) do
      local reachable = inst.available == true
      local detail
      if not reachable then
        detail = noctalia.tr("widget.instance_down", {
          error = inst.error ~= "" and inst.error or "unknown",
        })
      else
        detail = noctalia.tr("widget.instance_issues", { n = tonumber(inst.issueCount) or 0 })
      end
      table.insert(lines, inst.name .. " · " .. detail)
    end
    barWidget.setTooltip(table.concat(lines, "\n"))
    return
  end

  local inst = target or list[1]
  if inst == nil then
    barWidget.setTooltip(noctalia.tr("widget.tooltip_down", {
      error = snapshot.error ~= "" and snapshot.error or "unknown",
    }))
    return
  end

  local reachable = inst.available == true
  if not reachable then
    barWidget.setTooltip(noctalia.tr("widget.tooltip_down", {
      error = inst.error ~= "" and inst.error or "unknown",
    }))
  elseif issues > 0 then
    barWidget.setTooltip(noctalia.tr("widget.tooltip_issues", {
      host = inst.host ~= "" and inst.host or "opnsense",
      issues = issues,
      detail = inst.error ~= "" and inst.error or "see panel",
    }))
  else
    local load = ""
    if type(inst.resources) == "table" then
      load = tostring(inst.resources.load or "")
    end
    barWidget.setTooltip(noctalia.tr("widget.tooltip_ok", {
      host = inst.host ~= "" and inst.host or "opnsense",
      ifaces = #(inst.interfaces or {}),
      load = load ~= "" and load or "—",
    }))
  end
end

noctalia.state.watch(STATE_KEY, function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

noctalia.setUpdateInterval(8000)
render()

function update()
  render()
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
  requestId += 1
  local command = { action = "refresh", requestId = `widget-{requestId}` }
  local target = configString("instance", "")
  if target ~= "" and targetedInstance() ~= nil then
    command.instance = target
  end
  noctalia.state.set(COMMAND_KEY, command)
  noctalia.notify(noctalia.tr("title"), noctalia.tr("widget.refresh_requested"))
end