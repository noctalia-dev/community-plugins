--!nonstrict
-- The one niri subscription mechanism, shared by the bar widget and the navigator panel.
-- Owns: the event-stream process, sentinel handling (connected state), decode-failure
-- resync, and model updates. Callers get a single onChange() callback.
--
-- Process lifetime is the host's: noctalia.runStream has no stop handle, and the host
-- kills the whole process group (sh loop + niri msg) when the entry's runtime is torn
-- down (reload, settings change, widget removal, plugin disable).

local niri = require("./niri.luau")

local S = {}

function S.start(model, onChange)
  local sub = { connected = false, started = false, available = true }

  local function apply(event)
    if model:apply(event) then
      onChange()
    end
  end

  local function onLine(line)
    local event = noctalia.json.decode(line)
    if type(event) ~= "table" then
      -- The host drops lines over 64 KiB and hands over the tail as a fragment.
      noctalia.log("niri-workspace-stack: undecodable event-stream line (" .. tostring(#line) .. " bytes); resyncing")
      niri.resync(model, apply)
      return
    end
    if event[niri.STREAM_START] ~= nil then
      sub.connected = true
      onChange()
    elseif event[niri.STREAM_END] ~= nil then
      sub.connected = false
      onChange()
    else
      apply(event)
    end
  end

  function sub.resync()
    niri.resync(model, apply)
  end

  if noctalia.getenv("NIRI_SOCKET") == nil or not noctalia.commandExists("niri") then
    noctalia.log("niri-workspace-stack: niri not detected (NIRI_SOCKET unset or niri missing)")
    sub.available = false
    return sub
  end
  sub.started = noctalia.runStream(niri.EVENT_STREAM, onLine)
  if not sub.started then
    noctalia.log("niri-workspace-stack: could not start the niri event stream")
  end
  return sub
end

return S
