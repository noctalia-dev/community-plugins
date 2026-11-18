--!nonstrict
-- Bar widget: episode state, opens the browser on click,
-- toggles play/stop on right-click, volume on scroll.

local PANEL_ID = "fel/podcasts:browser"

local rss = require("./lib/rss.luau")

local status = noctalia.state.get("pod_status")
if type(status) ~= "table" then
  status = { playing = false, podcast = "", episode = "", url = "", volume = 70, pos = 0, dur = 0 }
end

local function request(action, extra)
  local prev = noctalia.state.get("pod_request")
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
  noctalia.state.set("pod_request", req)
end

local function render()
  local showName = noctalia.getConfig("show_name")
  if showName == nil then
    showName = true
  end
  local maxLen = math.clamp(math.floor(tonumber(noctalia.getConfig("max_length")) or 24), 5, 60)
  local label = status.episode ~= "" and status.episode or "Podcasts"
  local paused = status.playing and status.paused
  if paused then
    barWidget.setGlyph("player-play")
    if showName then
      barWidget.setText(string.sub(label, 1, maxLen))
    else
      barWidget.setText("")
    end
    barWidget.setTooltip({
      { key = "Podcast", value = status.podcast },
      { key = "Episode", value = status.episode },
      { key = "Position", value = rss.clock(status.pos) .. " / " .. rss.clock(status.dur) },
      { key = "Status", value = "Paused" },
      { key = "Click", value = "Open browser" },
      { key = "Right-click", value = "Resume" },
    })
  elseif status.playing then
    barWidget.setGlyph("player-stop")
    if showName then
      barWidget.setText(string.sub(label, 1, maxLen))
    else
      barWidget.setText("")
    end
    barWidget.setTooltip({
      { key = "Podcast", value = status.podcast },
      { key = "Episode", value = status.episode },
      { key = "Position", value = rss.clock(status.pos) .. " / " .. rss.clock(status.dur) },
      { key = "Volume", value = tostring(status.volume) .. "%" },
      { key = "Click", value = "Open browser" },
      { key = "Right-click", value = "Pause" },
    })
  else
    barWidget.setGlyph("rss")
    if showName then
      barWidget.setText(string.sub(label, 1, maxLen))
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

noctalia.state.watch("pod_status", function(value)
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
  if status.playing and not status.paused then
    request("pause")
  elseif status.playing and status.paused then
    request("resume")
  elseif status.url ~= "" then
    request("play", { podcast = status.podcast, episode = status.episode, url = status.url })
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
  noctalia.log("[podcast] widget onIpc: event=" .. tostring(event))
  if event == "stop" then
    request("stop")
  elseif event == "toggle" then
    onRightClick()
  elseif event == "play" and payload and payload ~= "" then
    local ok, data = pcall(function()
      return noctalia.json.decode(payload)
    end)
    if ok and type(data) == "table" and data.url then
      request("play", { podcast = data.podcast, episode = data.episode, url = data.url })
    end
  elseif event == "toggle-browser" then
    noctalia.togglePanel(PANEL_ID)
  end
end
