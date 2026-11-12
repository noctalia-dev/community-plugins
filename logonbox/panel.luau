--!nonstrict
-- LogonBox panel: a thin client like the bar widget. It renders the service's
-- logonbox.state snapshot through view_panel.build and turns clicks into one
-- logonbox.request each; it runs no process.

local view_panel = require("./view_panel.luau")

local REQUEST_KEY = "logonbox.request"
local STATE_KEY = "logonbox.state"

local snapshot = nil
-- Every request gets a fresh id, so two identical clicks are two requests.
local requestId = 0

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function send(request)
  requestId = requestId + 1
  request.requestId = requestId
  noctalia.state.set(REQUEST_KEY, request)
end

local h = {}

function h.connect(id)
  send({ action = "connect", id = id })
end

function h.disconnect(id)
  send({ action = "disconnect", id = id })
end

function h.openGui()
  send({ action = "open_gui" })
end

function h.openDownload()
  send({ action = "open_download" })
end

function h.dismiss(key)
  send({ action = "dismiss_error", key = key })
end

function h.copy(text)
  noctalia.copyToClipboard(text, "text/plain")
end

local function render()
  panel.render(view_panel.build(snapshot, ui, tr, h))
end

function onOpen(_context)
  local value = noctalia.state.get(STATE_KEY)
  if type(value) == "table" then
    snapshot = value
  end
  render()
  -- state.watch does not replay an old value; ask for a fresh snapshot
  send({ action = "refresh" })
end

noctalia.state.watch(STATE_KEY, function(value)
  if type(value) ~= "table" then
    return
  end
  snapshot = value
  render()
end)

render()
