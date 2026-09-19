--!nonstrict
-- Left click: toggles the OwnTone control panel.
-- Right click: quick play/pause toggle.
-- Scroll: adjusts volume.

local function baseUrl()
  local host = noctalia.getConfig("host") or "127.0.0.1:3689"
  return "http://" .. host
end

local function put(path)
  local headers = {}
  local user = noctalia.getConfig("username") or ""
  local req = {
    url = baseUrl() .. path,
    method = "PUT",
    headers = headers
  }
  if user ~= "" then
    req.basic_username = user
    req.basic_password = noctalia.getConfig("password") or ""
  end
  noctalia.http(req, function(_res)
    noctalia.state.set("owntone.refresh", noctalia.nowMs())
  end)
end

local function render()
  barWidget.setGlyph(noctalia.getConfig("glyph") or "music")
  barWidget.setText("")
  barWidget.setTooltip(noctalia.tr("widget_tooltip"))
end

function onClick()
  noctalia.togglePanel("danielel/owntone-control:panel")
end

function onRightClick()
  put("/api/player/toggle")
end

-- Scroll up increases volume, scroll down decreases it (5% per detent).
function onScroll(axis, steps)
  if axis ~= "vertical" then
    return
  end
  local step = -steps * 5
  put(string.format("/api/player/volume?step=%d", step))
end

-- For compositor keybinds:
--   noctalia msg plugin danielel/owntone-control:owntone focused toggle
--   noctalia msg plugin danielel/owntone-control:owntone focused next
--   noctalia msg plugin danielel/owntone-control:owntone focused previous
--   noctalia msg plugin danielel/owntone-control:owntone focused volume_up
--   noctalia msg plugin danielel/owntone-control:owntone focused volume_down
function onIpc(event, _payload)
  if event == "toggle" then
    put("/api/player/toggle")
  elseif event == "next" then
    put("/api/player/next")
  elseif event == "previous" then
    put("/api/player/previous")
  elseif event == "volume_up" then
    put("/api/player/volume?step=5")
  elseif event == "volume_down" then
    put("/api/player/volume?step=-5")
  end
end

render()
