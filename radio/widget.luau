--!nonstrict
-- Bar widget: shows playback state, opens the browser panel on click,
-- toggles play/stop on right-click, volume on scroll.

local PANEL_ID = "fel/radio:browser"

local status = noctalia.state.get("radio_status")
if type(status) ~= "table" then
  status = { playing = false, name = "", url = "", volume = 70 }
end

local function request(action, extra)
  local prev = noctalia.state.get("radio_request")
  local seq = 0
  if type(prev) == "table" and tonumber(prev.seq) then
    seq = tonumber(prev.seq)
  end
  local req = { seq = seq + 1, action = action }
  if type(extra) == "table" then
    for k, v in extra do
      req[k] = v
    end
  end
  noctalia.state.set("radio_request", req)
end

local function render()
  local showName = noctalia.getConfig("show_name")
  if showName == nil then
    showName = true
  end
  local maxLen = math.clamp(math.floor(tonumber(noctalia.getConfig("max_length")) or 24), 5, 60)
  if status.playing then
    barWidget.setGlyph("player-stop")
    local name = status.name ~= "" and status.name or "Playing"
    if showName then
      barWidget.setText(string.sub(name, 1, maxLen))
    else
      barWidget.setText("")
    end
    barWidget.setTooltip({
      { key = "Station", value = status.name },
      { key = "Volume", value = tostring(status.volume) .. "%" },
      { key = "Click", value = "Open browser" },
      { key = "Right-click", value = "Stop" },
    })
  else
    barWidget.setGlyph("radio")
    if showName and status.name ~= "" then
      barWidget.setText(string.sub(status.name, 1, maxLen))
    elseif showName then
      barWidget.setText("Radio")
    else
      barWidget.setText("")
    end
    barWidget.setTooltip({
      { key = "Status", value = "Stopped" },
      { key = "Click", value = "Open browser" },
      { key = "Right-click", value = "Resume" },
    })
  end
end

noctalia.state.watch("radio_status", function(value)
  if type(value) == "table" then
    status = value
    render()
  end
end)

function update()
  noctalia.setUpdateInterval(5000)
  render()
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
  if status.playing then
    request("stop")
  elseif status.url ~= "" then
    request("play", { name = status.name, url = status.url })
  else
    noctalia.togglePanel(PANEL_ID)
  end
end

function onScroll(axis, steps, _startsGesture)
  if axis ~= "vertical" then
    return
  end
  local vol = math.clamp((tonumber(status.volume) or 70) - steps * 5, 0, 100)
  status.volume = vol
  request("volume", { volume = vol })
  render()
end

function onIpc(event, payload)
  noctalia.log("[radio] widget onIpc: event=" .. tostring(event))
  if event == "stop" then
    request("stop")
  elseif event == "toggle" then
    onRightClick()
  elseif event == "toggle-browser" then
    noctalia.togglePanel(PANEL_ID)
  elseif event == "play" and payload and payload ~= "" then
    local ok, data = pcall(function()
      return noctalia.json.decode(payload)
    end)
    if ok and type(data) == "table" and data.url then
      request("play", { name = data.name, url = data.url, uuid = data.uuid })
    end
  end
end
