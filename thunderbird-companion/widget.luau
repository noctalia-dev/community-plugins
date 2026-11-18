--!nonstrict
-- Thunderbird Companion — unread badge and panel launcher.

local PLUGIN_ID = "mdj2812/thunderbird-companion"
local snapshot = {
  status = "starting",
  unreadCount = 0,
}
local command_seq = 0

local function send_command(op)
  command_seq += 1
  noctalia.state.set("thunderbird.command", {
    op = op,
    seq = tostring(os.time()) .. "-widget-" .. tostring(command_seq),
  })
end

local function status_tooltip()
  local status = snapshot.status
  if status == "online" then
    local count = math.max(0, math.floor(tonumber(snapshot.unreadCount) or 0))
    return count > 0
      and noctalia.trp("widget.unread", count)
      or noctalia.tr("widget.no_unread")
  end
  if status == "setup_required" then
    return noctalia.tr("widget.setup_required")
  end
  if status == "bridge_incompatible" then
    return noctalia.tr("widget.bridge_incompatible")
  end
  if status == "thunderbird_missing" then
    return noctalia.tr("widget.thunderbird_missing")
  end
  return noctalia.tr("widget.offline")
end

local function render()
  local unread = math.max(0, math.floor(tonumber(snapshot.unreadCount) or 0))
  local online = snapshot.status == "online"
  local glyph_color = online and "on_surface" or "on_surface_variant"
  local children = {
    ui.glyph({
      name = noctalia.getConfig("glyph") or "mail",
      size = 15,
      color = glyph_color,
    }),
  }

  if unread > 0 then
    table.insert(children, ui.row({
      fill = "primary",
      radius = 8,
      paddingH = 5,
      paddingV = 1,
      align = "center",
      justify = "center",
    }, {
      ui.label({
        text = unread > 99 and "99+" or tostring(unread),
        fontSize = 10,
        fontWeight = "bold",
        color = "on_primary",
      }),
    }))
  elseif not online then
    local warning = snapshot.status == "setup_required"
      or snapshot.status == "bridge_incompatible"
    table.insert(children, ui.box({
      width = 6,
      height = 6,
      radius = 3,
      fill = warning and "warning" or "error",
    }))
  end

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 4, align = "center" }, children))
  barWidget.setTooltip(status_tooltip())
end

noctalia.state.watch("thunderbird.snapshot", function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

function update()
  noctalia.setUpdateInterval(5000)
end

function onConfigChanged()
  render()
end

function onClick()
  noctalia.togglePanel(PLUGIN_ID .. ":inbox")
end

function onRightClick()
  send_command("compose")
end

local current = noctalia.state.get("thunderbird.snapshot")
if type(current) == "table" then
  snapshot = current
end
render()
