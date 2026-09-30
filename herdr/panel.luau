--!nonstrict
-- HerdR panel. Process I/O lives in service.luau; UI is built by panel_view.luau.

local View = require("./panel_view.luau")

local snapshot = noctalia.state.get("herdr.state") or {
  available = false,
  refreshing = false,
  sessions = {},
  running = 0,
  agents = 0,
}
local pendingDelete = nil
local commandNonce = 0

local function request(action, sessionName, pane)
  commandNonce = commandNonce + 1
  noctalia.state.set("herdr.command", {
    action = action,
    session = sessionName,
    pane = pane,
    nonce = commandNonce,
  })
end

function render()
  panel.render(View.build(snapshot, {
    pendingDelete = pendingDelete,
    setPendingDelete = function(value)
      pendingDelete = value
    end,
    request = request,
    rerender = render,
    onClose = function()
      panel.close()
    end,
  }))
end

function onOpen(_context)
  noctalia.state.set("herdr.panel_open.attached", true)
  request("refresh")
  render()
end

function onClose()
  pendingDelete = nil
  noctalia.state.set("herdr.panel_open.attached", false)
end

noctalia.state.watch("herdr.state", function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

render()
