--!nonstrict
local showName = noctalia.getConfig("show_name")
local maxLength = tonumber(noctalia.getConfig("max_length")) or 24
local status = noctalia.state.get("quran_status") or { playing = false, name = "", reciterId = "", surahId = 1, volume = 65, url = "" }

noctalia.state.watch("quran_status", function(v)
  status = v or status
  render()
end)

local function req(action, extra)
  local prev = noctalia.state.get("quran_request")
  local seq = 0
  if type(prev) == "table" and tonumber(prev.seq) then seq = tonumber(prev.seq) end
  local r = { seq = seq + 1, action = action }
  if type(extra) == "table" then for k,v in pairs(extra) do r[k]=v end end
  noctalia.state.set("quran_request", r)
end

local function shortName()
  local n = status.name or ""
  if #n > maxLength then n = string.sub(n, 1, maxLength - 1) .. "…" end
  return n
end

function render()
  local active = status.playing == true and status.paused ~= true
  barWidget.setGlyph(active and "player-pause-filled" or "player-play-filled")
  if showName then
    barWidget.setText(shortName() ~= "" and shortName() or "Quran")
  else
    barWidget.setText("")
  end
  local label = status.playing and (status.paused and "Paused: " or "Playing: ") or "Stopped: "
  barWidget.setTooltip(label .. (status.name or ""))
end

function update()
  noctalia.setUpdateInterval(1000)
  render()
end

function onClick()
  req("toggle")
end

function onRightClick()
  noctalia.togglePanel("abuamar142/murattal:browser")
end

function onScroll(axis, steps, startsGesture)
  if axis == "vertical" then
    local v = (status.volume or 65) - steps * 5
    v = math.clamp(v, 0, 100)
    req("volume", { volume = v })
  end
end

function onIpc(event, payload)
  if event == "toggle" then req("toggle")
  elseif event == "play" then req("play")
  elseif event == "stop" then req("stop")
  elseif event == "next" then req("next")
  elseif event == "prev" then req("prev")
  end
end
