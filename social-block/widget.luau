--!nonstrict
-- Bar widget: compact ON/OFF shield. Left click opens the panel, right click
-- toggles the block. State comes from the service via noctalia.state.
local PLUGIN = "treeonlinux/social-block"
local SERVICE = PLUGIN .. ":service"

local blocked = noctalia.state.get("blocked") == true
local remaining = noctalia.state.get("remaining") or 0

local function send(event, payload)
  local args = { "noctalia", "msg", "plugin", SERVICE, "all", event }
  if payload then args[#args + 1] = payload end
  local accepted = noctalia.runAsync(args)
  if not accepted then
    noctalia.notifyError("Social Block", "Could not reach the Social Block service.")
  end
end

local function render()
  local role = blocked and "error" or "on_surface_variant"
  local props = { gap = 6, align = "center", paddingH = 7, paddingV = 2 }
  if blocked then
    props.fill = "error/0.16"
    props.radius = 8
  end

  barWidget.render(ui.row(props, {
    ui.glyph({ name = blocked and "shield-lock" or "shield", size = 14, color = role }),
    ui.label({
      text = blocked and (remaining > 0 and (remaining .. "m") or "ON") or "OFF",
      fontSize = 12,
      fontWeight = "bold",
      color = role,
    }),
  }))

  barWidget.setTooltip({
    { key = "Social Block", value = blocked and (remaining > 0 and ("on · " .. remaining .. "m left") or "on") or "off" },
    { key = "Click", value = "open panel" },
    { key = "Right click", value = "toggle" },
  })
end

noctalia.state.watch("blocked", function(value)
  blocked = value == true
  render()
end)

noctalia.state.watch("remaining", function(value)
  remaining = value or 0
  render()
end)

function onClick()
  noctalia.togglePanel(PLUGIN .. ":panel")
end

function onRightClick()
  send("toggle")
end

function onIpc(event)
  if event == "toggle" then send("toggle") end
end

render()
