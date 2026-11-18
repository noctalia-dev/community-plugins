--!nonstrict
-- The one compositor subscription mechanism, shared by the bar widget and the navigator
-- panel. Owns: the event-stream process, sentinel handling (connected state),
-- decode-failure resync, and model updates. Callers get a single onChange() callback.
--
-- Process lifetime is the host's: noctalia.runStream has no stop handle, and the host
-- kills the whole process group (sh loop + compositor CLI) when the entry's runtime is
-- torn down (reload, settings change, widget removal, plugin disable).

local ipc = require("./backend.luau")

local S = {}

-- Long-lived event stream with reconnect + backoff. The sentinel lines let the widget
-- show a disconnected state; both compositors re-send their full state on every new
-- connection, so no explicit resync is needed after a reconnect.
S.STREAM_START = "NwsStreamStart"
S.STREAM_END = "NwsStreamEnd"

function S.loopScript(subscribe)
  return string.format([[
delay=1
while :; do
  printf '{"NwsStreamStart":{}}\n'
  if %s; then delay=1; fi
  printf '{"NwsStreamEnd":{}}\n'
  sleep "$delay"
  if [ "$delay" -lt 16 ]; then delay=$((delay * 2)); fi
done
]], subscribe)
end

-- Resync after a lost stream line (lines over 64 KiB are dropped by the host).
--
-- Events carry absolute values (ids, full records or full snapshots), so re-applying an
-- event that a snapshot already reflects is harmless. The only hazard is the reverse:
-- events applied while the two snapshot commands run would be overwritten by the older
-- snapshot. So both replies are collected and applied together only if the model saw no
-- event in the meantime; otherwise the snapshot is retaken (at most 3 attempts).
local resyncActive = false

function S.resync(model, backend, apply, attempt)
  attempt = attempt or 1
  if resyncActive and attempt == 1 then
    return
  end
  resyncActive = true
  local startCount = model.eventCount
  local replies, pending = {}, 2
  local function finish()
    pending = pending - 1
    if pending > 0 then
      return
    end
    if replies.workspaces == nil or replies.windows == nil then
      resyncActive = false
      noctalia.log("niri-workspace-stack: resync failed (" .. backend.COMMAND .. " error)")
      return
    end
    if model.eventCount ~= startCount then
      if attempt < 3 then
        S.resync(model, backend, apply, attempt + 1)
      else
        resyncActive = false
        noctalia.log("niri-workspace-stack: resync skipped; event stream too busy, stream state kept")
      end
      return
    end
    resyncActive = false
    apply(backend.snapshotEvent("workspaces", replies.workspaces))
    apply(backend.snapshotEvent("windows", replies.windows))
  end
  local function fetch(kind)
    local ok = noctalia.runAsync(backend.SNAPSHOT[kind], function(result)
      local list = result.exitCode == 0 and noctalia.json.decode(result.stdout) or nil
      replies[kind] = type(list) == "table" and list or nil
      finish()
    end, 3000)
    if not ok then
      finish()
    end
  end
  fetch("workspaces")
  fetch("windows")
end

function S.start(model, onChange)
  local sub = { connected = false, started = false, available = true }

  if not ipc or not noctalia.commandExists(ipc.COMMAND) then
    noctalia.log("niri-workspace-stack: no supported compositor (UMBRIEL_SOCKET / NIRI_SOCKET unset, or its CLI missing)")
    sub.available = false
    sub.resync = function() end -- the `resync` IPC event still reaches a hidden widget
    return sub
  end

  local decode = ipc.decoder()

  local function apply(event)
    local changed = false
    for _, e in ipairs(decode(event)) do
      if model:apply(e) then
        changed = true
      end
    end
    if changed then
      onChange()
    end
  end

  local function onLine(line)
    local event = noctalia.json.decode(line)
    if type(event) ~= "table" then
      -- The host drops lines over 64 KiB and hands over the tail as a fragment.
      noctalia.log("niri-workspace-stack: undecodable event-stream line (" .. tostring(#line) .. " bytes); resyncing")
      S.resync(model, ipc, apply)
      return
    end
    if event[S.STREAM_START] ~= nil then
      sub.connected = true
      onChange()
    elseif event[S.STREAM_END] ~= nil then
      sub.connected = false
      onChange()
    else
      apply(event)
    end
  end

  function sub.resync()
    S.resync(model, ipc, apply)
  end

  sub.started = noctalia.runStream(S.loopScript(ipc.SUBSCRIBE), onLine)
  if not sub.started then
    noctalia.log("niri-workspace-stack: could not start the " .. ipc.COMMAND .. " event stream")
  end
  return sub
end

return S
