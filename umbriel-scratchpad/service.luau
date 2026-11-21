--!nonstrict
-- Scratchpad service - the only entry that talks to the compositor.
--
-- noctalia.compositor.subscribe opens this service's own connection to Umbriel's
-- IPC event stream; Umbriel answers with the full window list and sends it again
-- on every change. The service republishes the scratchpad windows on
-- "scratchpad.state" for every bar instance, and runs the actions bars request on
-- "scratchpad.request" as typed IPC requests.
--
--   noctalia.compositor.subscribe(options, onEvent)    the event stream, no child
--   noctalia.umbriel.action(request, cb)               one typed action, no child

local available = false
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

local function onWindows(data)
  -- Bars only care about scratchpad windows; keep the shared snapshot small.
  local list = {}
  local present = {}
  focusedOutput = nil
  for _, window in ipairs(data) do
    -- The output holding keyboard focus, for "highlight focused monitor only".
    if window.active == true then
      focusedOutput = window.output
    end
    if type(window.scratchpad) == "string" and window.scratchpad ~= "" and window.id ~= nil then
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
end

local function onEvent(event, data)
  -- The connection dropped: forget every window so bars stop showing (and
  -- clicking) stale ones. The shell reconnects on its own and Umbriel sends a
  -- fresh snapshot once the stream is back.
  if event == "reset" then
    available = false
    windows = {}
    focusedOutput = nil
    firstSeen = {}
    nextSeen = 0
    if streamError == nil then
      streamError = noctalia.tr("error.stream_closed")
    end
    publish()
    return
  end
  -- Umbriel rejected the subscription; a "reset" follows and the retry sends the
  -- same request.
  if event == "error" then
    streamError = if type(data) == "string" and data ~= "" then data else noctalia.tr("error.stream_closed")
    publish()
    return
  end
  if event ~= "windows" or type(data) ~= "table" then
    return
  end
  onWindows(data)
  available = true
  streamError = nil
  publish()
end

-- `request` is Umbriel's typed action request without `cmd`, for example
-- { action = "scratchpad-toggle", scratchpad = "M" }. Nothing to refresh on
-- success: the resulting window changes arrive on the stream by themselves.
local function runAction(request)
  local accepted = noctalia.umbriel.action(request, function(ok, err)
    if not ok then
      noctalia.notifyError(noctalia.tr("notify.action_failed", { action = request.action }), err)
    end
  end)
  if not accepted then
    noctalia.notifyError(noctalia.tr("notify.action_failed", { action = request.action }))
  end
end

noctalia.state.watch("scratchpad.request", function(value)
  if type(value) ~= "table" then
    return
  end
  if available and type(value.request) == "table" and type(value.request.action) == "string" then
    runAction(value.request)
  end
end)

publish()
-- Other compositors have event streams too, with their own event names, so only
-- Umbriel's is read.
if noctalia.compositor.name() == "umbriel" then
  noctalia.compositor.subscribe({ events = { "windows" } }, onEvent)
end
