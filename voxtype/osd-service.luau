--!nonstrict
-- Singleton: follow Voxtype, never open a microphone or run inference here.
local PANEL = "gabedunn/voxtype:osd"
local enabled = noctalia.getConfig("osd_enabled") == true
local phase = "idle"
local desiredOpen = false
local appliedOpen = false
local pending = false
local lastLevelAt = 0

-- Serialize IPC so a very short recording cannot leave a late panel-open behind.
local function syncPanel()
  if pending or desiredOpen == appliedOpen then return end
  pending = true
  local opening = desiredOpen
  local accepted = noctalia.runAsync({ "noctalia", "msg", opening and "panel-open" or "panel-close", PANEL }, function(result)
    pending = false
    if result.exitCode == 0 then
      appliedOpen = opening
      syncPanel()
    end
  end)
  if not accepted then pending = false end
end

local function setPhase(value)
  if value ~= "idle" and value ~= "recording" and value ~= "streaming"
      and value ~= "transcribing" and value ~= "stopped" then return end
  phase = value
  noctalia.state.set("osd_phase", phase)
  desiredOpen = phase == "recording" or phase == "streaming" or phase == "transcribing"
  syncPanel()
end

-- Managed process groups are killed by Noctalia on reload/disable/shutdown.
local function follow(command, callback)
  return noctalia.runStream('P=$PPID; while kill -0 "$P" 2>/dev/null; do '
    .. command .. '; sleep 2; done', callback)
end

noctalia.state.set("osd_phase", "idle")
noctalia.state.set("osd_level", 0)

if enabled then
  if not noctalia.commandExists("voxtype") then
    noctalia.log("voxtype OSD: voxtype is unavailable")
  else
    follow("voxtype status --follow --format json", function(line)
      local ok, status = pcall(noctalia.json.decode, line)
      if ok and type(status) == "table" then setPhase(status.class) end
    end)
    if noctalia.commandExists("voxtype-audio-bridge") then
      follow("voxtype-audio-bridge", function(line)
        local ok, frame = pcall(noctalia.json.decode, line)
        if not ok or type(frame) ~= "table" then return end
        if frame.status == "disconnected" then
          noctalia.state.set("osd_level", 0)
          return
        end
        if phase ~= "recording" and phase ~= "streaming" then return end
        local now = noctalia.nowMs()
        if now - lastLevelAt < 45 then return end
        lastLevelAt = now
        -- Match Voxtype's waveform: linear peak amplitude with visual gain 10.
        local peak = tonumber(frame.peak) or 0
        local level = math.clamp(peak * 10, 0, 1)
        noctalia.state.set("osd_level", { value = level, at = now })
      end)
    else
      noctalia.log("voxtype OSD: install voxtype-audio-bridge for live sound bars")
    end
  end
end

function onExit(_signal, _reason)
  if enabled then
    noctalia.state.set("osd_phase", "idle")
    noctalia.runAsync({ "noctalia", "msg", "panel-close", PANEL })
  end
end
