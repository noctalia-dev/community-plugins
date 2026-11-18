-- ShareDND service: watches niri screencasts and toggles notification
-- Do Not Disturb while the screen is being shared.
--
-- Detection is event-driven: a persistent `niri msg -j event-stream` runs
-- under runStream, wrapped in a shell retry loop because the stream API has
-- no exit notification. Any Cast* event triggers a re-query of
-- `niri msg -j casts`, which is the authoritative state, so no per-event
-- bookkeeping is needed and reconnects re-sync for free (the stream sends
-- the full current state, including CastsChanged, on connect).
--
-- Stop transitions are debounced by STOP_DEBOUNCE seconds. Switching what is
-- being shared surfaces as a stop/start event pair; acting on the stop
-- immediately would race the follow-up status query (the async `off` can
-- land after the query already read DND as on), dropping ownership and
-- leaving DND off for the rest of the new sharing session. The debounce
-- collapses the pair into no transition, and also keeps DND from flapping.

local STOP_DEBOUNCE = 1.0

local function cfg(key)
  return noctalia.getConfig(key)
end

-- debounced sharing state that the DND logic acts on
local sharingActive = false
-- true when this plugin enabled DND (and therefore owns turning it off)
local dndSetByUs = false

-- raw state from the last casts query + pending debounced stop deadline
local rawActive = false
local stopDeadline = nil -- os.clock() timestamp, nil when no stop is pending

local queryInFlight = false
local queryDirty = false

local function countCasts(json)
  local needle = cfg("only_active") and '"is_active":true' or '"session_id":'
  local n = 0
  local pos = 1
  while true do
    local s, e = json:find(needle, pos, true)
    if not s then
      break
    end
    n = n + 1
    pos = e + 1
  end
  return n
end

local function setDnd(on, cb)
  noctalia.runAsync("noctalia msg notification-dnd-set " .. (on and "on" or "off"), function(res)
    local ok = res ~= nil and res.exitCode == 0
    if not ok then
      noctalia.log("sharednd: notification-dnd-set failed")
    end
    if cb then
      cb(ok)
    end
  end)
end

local function onSharingStarted()
  noctalia.runAsync("noctalia msg notification-dnd-status", function(res)
    if not sharingActive then
      return -- sharing already ended while the status query was in flight
    end
    if res == nil or res.exitCode ~= 0 then
      noctalia.log("sharednd: notification-dnd-status failed")
      return
    end
    if (res.stdout or ""):match("^%s*on") then
      -- DND was already on (enabled manually) — don't take ownership.
      dndSetByUs = false
      noctalia.log("sharednd: sharing started, DND already on")
    else
      setDnd(true, function(ok)
        dndSetByUs = ok
        if ok then
          noctalia.log("sharednd: sharing started, DND enabled")
          if not sharingActive then
            -- sharing ended while the set was in flight — undo
            setDnd(false)
            dndSetByUs = false
          end
        end
      end)
    end
  end)
end

local function onSharingStopped()
  if dndSetByUs or cfg("always_off_after") then
    setDnd(false)
    noctalia.log("sharednd: sharing stopped, DND disabled")
  else
    noctalia.log("sharednd: sharing stopped, DND left as-is")
  end
  dndSetByUs = false
end

local function applyState(activeCount)
  rawActive = activeCount > 0
  if rawActive then
    -- A restart within the debounce window cancels the pending stop, so a
    -- stop/start pair from switching casts is no transition at all.
    stopDeadline = nil
    if not sharingActive then
      sharingActive = true
      onSharingStarted()
    end
  elseif sharingActive and stopDeadline == nil then
    stopDeadline = os.clock() + STOP_DEBOUNCE
  end
end

local function queryCasts()
  if queryInFlight then
    queryDirty = true
    return
  end
  queryInFlight = true
  noctalia.runAsync("niri msg -j casts", function(res)
    queryInFlight = false
    if res ~= nil and res.exitCode == 0 and res.stdout ~= nil then
      applyState(countCasts(res.stdout))
    end
    if queryDirty then
      queryDirty = false
      queryCasts()
    end
  end)
end

local function onEventLine(line)
  -- Matches CastsChanged / CastStartedOrChanged / CastStopped. The casts
  -- query is authoritative, so a rare false positive (a window title
  -- containing '"Cast') only costs one extra query.
  if line:find('"Cast', 1, true) then
    queryCasts()
  end
end

-- Host-driven tick (~250 ms): commits a pending stop once the debounce
-- window has passed without sharing resuming.
function update()
  if stopDeadline ~= nil and os.clock() >= stopDeadline then
    stopDeadline = nil
    if sharingActive and not rawActive then
      sharingActive = false
      onSharingStopped()
    end
  end
end

-- Called by the host on plugin disable/reload. The callback-less runAsync
-- spawns a detached process, so it survives the VM teardown.
function onExit()
  if dndSetByUs then
    noctalia.runAsync("noctalia msg notification-dnd-set off")
  end
end

-- Boot. `niri msg` needs the niri binary and NIRI_SOCKET (set only inside a
-- niri session), so gate detection on both instead of spawning a retry loop
-- that can never succeed on other compositors.
local niriSocket = noctalia.getenv("NIRI_SOCKET")
if niriSocket == nil or niriSocket == "" then
  -- Expected on other compositors: stay silent and spawn nothing.
  noctalia.log("sharednd: no NIRI_SOCKET, not a niri session — detection disabled")
elseif not noctalia.commandExists("niri") then
  -- Inside a niri session but the binary is unreachable — worth a warning.
  noctalia.notifyError(noctalia.tr("notify.no_niri_title"), noctalia.tr("notify.no_niri_body"))
  noctalia.log("sharednd: NIRI_SOCKET set but niri not in PATH — detection disabled")
else
  -- The process group is killed on plugin disable, taking the shell loop and
  -- the stream down with it. That cleanup does not run when the host dies
  -- hard (crash, session logout), so the loop also exits on its own once the
  -- parent is gone or the niri socket disappears — otherwise orphaned loops
  -- would keep respawning `niri msg` every 3 s across sessions.
  local loop = 'P=$PPID; while kill -0 "$P" 2>/dev/null && [ -S "$NIRI_SOCKET" ]; do'
    .. " niri msg -j event-stream 2>/dev/null; sleep 3; done"
  if not noctalia.runStream(loop, onEventLine) then
    noctalia.log("sharednd: failed to start niri event-stream")
  end
  -- Safety net in case the initial CastsChanged is ever missed.
  queryCasts()
end
