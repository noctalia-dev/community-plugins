--!nonstrict
-- XWayland Indicator service - the only entry that talks to the compositor.
--
--   noctalia.runStream(cmd, onLine)   long-lived child, one callback per line
--   noctalia.state.set("umbriel.state", snapshot)     one snapshot, one re-render

-- Both halves matter: the socket variable proves this is an Umbriel session, the
-- binary is what the service actually runs.
local available = noctalia.getenv("UMBRIEL_SOCKET") ~= nil and noctalia.commandExists("umbriel")

local streaming = false
local workspaces = {}
local windows = {}
local streamError = nil

-- A window's `focused` flag is per workspace. `active` would name the one window
-- holding keyboard focus, but the open panel takes that, so the target is the
-- focused window of the focused workspace.
local function findFocusedWindow(workspace)
  for _, window in ipairs(windows) do
    if window.focused == true and window.workspace == workspace.id then
      return window
    end
  end
  return nil
end

local function publish()
  local focused = nil
  for _, workspace in ipairs(workspaces) do
    if workspace.focused == true then
      focused = workspace
      break
    end
  end

  noctalia.state.set("umbriel.state", {
    available = available,
    focused_window = focused ~= nil and findFocusedWindow(focused) or nil,
    error = streamError,
  })
end

local function onLine(line)
  local decoded = noctalia.json.decode(line)
  if type(decoded) ~= "table" then
    return
  end
  -- The stream reports its own rejection on the first line and then closes;
  -- every other line is one subscribed state snapshot.
  if type(decoded.err) == "string" then
    streamError = decoded.err
    publish()
    return
  end
  if decoded.event == "workspaces" and type(decoded.data) == "table" then
    workspaces = decoded.data
    streamError = nil
    publish()
  elseif decoded.event == "windows" and type(decoded.data) == "table" then
    windows = decoded.data
    streamError = nil
    publish()
  end
end

local function startStream()
  if not available or streaming then
    return
  end
  streaming = noctalia.runStream("umbriel subscribe workspaces,windows", onLine)
  if not streaming then
    streamError = noctalia.tr("error.stream_failed")
    publish()
  end
end

-- runStream never reports its child exiting, and an idle stream is silent, so
-- silence cannot be told from death. Rather than poll for it, re-check when a UI
-- entry asks: if no subscriber survives, arm a new stream.
local function verifyStream()
  if not available then
    return
  end
  local started = noctalia.processMatches(function(matched)
    if not matched then
      streaming = false
      startStream()
    end
  end, "umbriel", "subscribe")
  if not started then
    streaming = false
    startStream()
  end
end

function update()
  verifyStream()
end

publish()
startStream()
noctalia.setUpdateInterval(5000)

