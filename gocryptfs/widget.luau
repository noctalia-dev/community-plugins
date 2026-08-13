--!nonstrict

local PANEL_ID = "davemhammer/gocryptfs:manager"
local STATE_KEY = "gocrypt_snapshot"
local COMMAND_KEY = "gocrypt_command"

local snapshot = noctalia.state.get(STATE_KEY) or {
  available = false,
  loading = true,
  mountedCount = 0,
  totalCount = 0,
}

local requestId = 0

local function configString(key, fallback)
  local value = noctalia.getConfig(key)
  return type(value) == "string" and value or fallback
end

local function render()
  local mounted = tonumber(snapshot.mountedCount) or 0
  local total = tonumber(snapshot.totalCount) or 0
  local available = snapshot.available == true
  local showCount = noctalia.getConfig("show_count") ~= false
  local anyMounted = mounted > 0

  local glyphName = anyMounted and "lock-open" or "lock"
  local glyphColor = available and configString("glyph_color", "on_surface") or "on_surface_variant"
  if anyMounted then
    glyphColor = configString("mounted_color", "tertiary")
  end

  local children = {
    ui.glyph({
      name = glyphName,
      size = 16,
      color = glyphColor,
    }),
  }

  if showCount and available and total > 0 then
    table.insert(children, ui.label({
      text = `{mounted}/{total}`,
      fontWeight = "bold",
      color = "on_surface",
    }))
  end

  if available and total > 0 then
    table.insert(children, ui.box({
      width = 7,
      height = 7,
      radius = 4,
      fill = anyMounted and configString("mounted_color", "tertiary") or configString("unmounted_color", "on_surface_variant"),
    }))
  end

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 5, align = "center" }, children))

  if not available then
    barWidget.setTooltip(noctalia.tr("widget.unavailable"))
  elseif total == 0 then
    barWidget.setTooltip(noctalia.tr("widget.tooltip_none"))
  else
    barWidget.setTooltip(noctalia.tr("widget.tooltip", { mounted = mounted, total = total }))
  end
end

noctalia.state.watch(STATE_KEY, function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

noctalia.setUpdateInterval(5000)
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
