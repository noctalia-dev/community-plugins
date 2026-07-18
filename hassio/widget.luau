--!nonstrict

local haUrl = noctalia.getConfig("ha_url")
local showEntityCount = noctalia.getConfig("show_entity_count")

local status = "unconfigured"
local entityCount = 0

local render

local function tr(key, subst)
  return noctalia.tr("widget." .. key, subst)
end

noctalia.state.watch("connection_status", function(value)
  status = value or "unconfigured"
  if render then render() end
end)

noctalia.state.watch("entity_count", function(value)
  entityCount = value or 0
  if render then render() end
end)

local function getStatusText()
  if status == "connected" then
    return tr("status_connected")
  elseif status == "connecting" then
    return tr("status_connecting")
  elseif status == "disconnected" then
    return tr("status_disconnected")
  elseif status == "auth_failed" then
    return tr("status_auth_failed")
  else
    return tr("status_unconfigured")
  end
end

local function getStatusColor()
  if status == "connected" then
    return "primary"
  elseif status == "connecting" then
    return "on_error"
  elseif status == "disconnected" or status == "auth_failed" then
    return "error"
  else
    return "on_surface_variant"
  end
end

render = function()
  barWidget.setGlyph("smart-home")
  barWidget.setGlyphColor(getStatusColor())

  if showEntityCount and entityCount > 0 then
    barWidget.setText(tostring(entityCount))
    barWidget.setTooltip(tr("tooltip_entities", {
      status = getStatusText(),
      count = entityCount
    }))
  else
    barWidget.setTooltip(tr("tooltip", {
      status = getStatusText()
    }))
  end
end

function update()
  noctalia.setUpdateInterval(5000)

  if status == "unconfigured" then
    local serviceStatus = noctalia.state.get("connection_status")
    if serviceStatus then
      status = serviceStatus
    end
  end

  render()
end

function onClick()
  noctalia.togglePanel("pozzoo/hassio:entity_manager")
end

function onRightClick()
  if haUrl and haUrl ~= "" then
    noctalia.runAsync("xdg-open " .. ("'" .. haUrl:gsub("'", "'\\''") .. "'"))
  end
end

function onIpc(event, payload)
  if event == "refresh" then
    noctalia.state.set("command", "refresh")
    noctalia.notify(noctalia.tr("shortcut.title"), tr("refreshing_connection"))
  end
end
