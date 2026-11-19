--!nonstrict
-- Scratchpad service - the only entry that talks to the compositor.
--
-- `umbriel subscribe windows` pushes the full window list, one JSON object per
-- line. The service republishes it on "scratchpad.state" for every bar
-- instance, and runs the actions bars request on "scratchpad.request".

local COMMAND_TIMEOUT_MS = 2000

local available = noctalia.getenv("UMBRIEL_SOCKET") ~= nil and noctalia.commandExists("umbriel")

local streaming = false
local windows = {}
local focusedOutput = nil
local streamError = nil

-- Umbriel lists windows in focus order, so icons would jump on every click.
-- Number each window the first time it is seen and sort by that instead.
local firstSeen = {}
local nextSeen = 0

local function publish()
  noctalia.state.set("scratchpad.state", {
    available = available,
    windows = windows,
    focused_output = focusedOutput,
    error = streamError,
  })
end

local function onLine(line)
  local decoded = noctalia.json.decode(line)
  if type(decoded) ~= "table" then
    return
  end
  if type(decoded.err) == "string" then
    streamError = decoded.err
    publish()
    return
  end
  if decoded.event ~= "windows" or type(decoded.data) ~= "table" then
    return
  end
  -- Bars only care about scratchpad windows; keep the shared snapshot small.
  local list = {}
  local present = {}
  focusedOutput = nil
  for _, window in ipairs(decoded.data) do
    -- The output holding keyboard focus, for "highlight focused monitor only".
    if window.active == true then
      focusedOutput = window.output
    end
    if type(window.scratchpad) == "string" and window.scratchpad ~= "" then
      if firstSeen[window.id] == nil then
        nextSeen += 1
        firstSeen[window.id] = nextSeen
      end
      present[window.id] = true
      table.insert(list, window)
    end
  end
  -- Forget windows that closed or left their scratchpad; one re-added later goes last.
  for id in pairs(firstSeen) do
    if not present[id] then
      firstSeen[id] = nil
    end
  end
  table.sort(list, function(a, b)
    return firstSeen[a.id] < firstSeen[b.id]
  end)
  windows = list
  streamError = nil
  publish()
end

local function startStream()
  if not available or streaming then
    return
  end
  streaming = noctalia.runStream("umbriel subscribe windows", onLine)
  if not streaming then
    streamError = noctalia.tr("error.stream_failed")
    publish()
  end
end

-- runStream never reports its child exiting, so re-check when a bar asks.
local function verifyStream()
  if not available then
    return
  end
  local started = noctalia.processMatches(function(matched)
    if not matched then
      streaming = false
      startStream()
    end
  end, "umbriel", "subscribe", "windows")
  if not started then
    streaming = false
    startStream()
  end
end

local function runAction(action)
  noctalia.runAsync({ "umbriel", "msg", action }, function(result)
    if result.exitCode ~= 0 or result.timedOut then
      noctalia.notifyError(noctalia.tr("notify.action_failed", { action = action }), noctalia.string.trim(result.stderr))
    end
  end, COMMAND_TIMEOUT_MS)
end

noctalia.state.watch("scratchpad.request", function(value)
  if not available or type(value) ~= "table" then
    return
  end
  if type(value.action) == "string" and value.action ~= "" then
    runAction(value.action)
  else
    verifyStream()
  end
end)

publish()
startStream()
