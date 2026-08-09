--!nonstrict

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
}

local requestId = 0

local function configString(key, fallback)
  local value = noctalia.getConfig(key)
  return type(value) == "string" and value or fallback
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

local function render()
  local available = snapshot.available == true
  local configured = snapshot.configured == true
  local issues = tonumber(snapshot.issueCount) or 0
  local healthy = available and issues == 0
  local showLabel = noctalia.getConfig("show_label") ~= false
  local okColor = configString("ok_color", "tertiary")
  local warnColor = configString("warn_color", "error")
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

  if not configured then
    barWidget.setTooltip(noctalia.tr("widget.tooltip_missing"))
  elseif not available then
    barWidget.setTooltip(noctalia.tr("widget.tooltip_down", {
      error = snapshot.error ~= "" and snapshot.error or "unknown",
    }))
  elseif healthy then
    local load = ""
    if type(snapshot.resources) == "table" then
      load = tostring(snapshot.resources.load or "")
    end
    barWidget.setTooltip(noctalia.tr("widget.tooltip_ok", {
      host = snapshot.host ~= "" and snapshot.host or "opnsense",
      ifaces = #(snapshot.interfaces or {}),
      load = load ~= "" and load or "—",
    }))
  else
    barWidget.setTooltip(noctalia.tr("widget.tooltip_issues", {
      host = snapshot.host ~= "" and snapshot.host or "opnsense",
      issues = issues,
      detail = snapshot.error ~= "" and snapshot.error or "see panel",
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
  noctalia.state.set(COMMAND_KEY, { action = "refresh", requestId = `widget-{requestId}` })
  noctalia.notify(noctalia.tr("title"), noctalia.tr("widget.refresh_requested"))
end
