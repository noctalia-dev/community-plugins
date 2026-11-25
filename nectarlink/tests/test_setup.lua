-- First-run UI only: no real profile, network, processes or phone actions.
dofile("tests/test_runtime.lua")
local fixture = { state = "unconfigured", error = "credentials_missing", devices = {} }
local tree, watcher
local commands = {}
local clipboard, copies, clipboardAvailable = nil, 0, true
ui = setmetatable({}, {
  __index = function(_, kind)
    return function(props, children)
      return { kind = kind, props = props, children = children or {} }
    end
  end,
})
panel = {
  render = function(value)
    tree = value
  end,
}
noctalia = {
  copyToClipboard = function(text, mime)
    assert(mime == "text/plain")
    copies = copies + 1
    clipboard = text
    return clipboardAvailable
  end,
  getConfig = function()
    return nil
  end,
  json = {
    encode = function(v)
      return v
    end,
    decode = function(v)
      return v
    end,
  },
  state = {
    get = function()
      return fixture
    end,
    watch = function(_, cb)
      watcher = cb
    end,
    set = function(_, value)
      commands[#commands + 1] = value
    end,
  },
}
dofile("panel.luau")
local function find(prop, value, node)
  node = node or tree
  if node.props[prop] == value then
    return node
  end
  for _, child in ipairs(node.children) do
    local result = find(prop, value, child)
    if result then
      return result
    end
  end
end
onOpen()
assert(find("key", "connection-setup") and not find("key", "ring"))
local card = find("key", "connection-setup")
local used = card.props.padding * 2 + (#card.children - 1) * card.props.gap
for _, child in ipairs(card.children) do
  used = used + (child.props.height or (child.kind == "label" and 14 or 0))
end
assert(used <= card.props.height, "setup content exceeds fixed panel height")
assert(tree.props.width == 1072 and tree.props.height == 528)
assert(copies == 0, "rendering the command must not modify the clipboard")
local install = "curl -fsSL https://github.com/vladikchi/nectarlink-noctalia/releases/latest/download/install.sh | sh"
assert(find("text", install))
local beforeCopy = #commands
find("key", "copy-install-command").props.onClick()
assert(copies == 1 and clipboard == install and #commands == beforeCopy)
assert(find("key", "copy-install-command").props.tooltip == "Copied")
clipboardAvailable = false
find("key", "copy-install-command").props.onClick()
assert(find("key", "copy-install-command").props.tooltip == "Could not copy the command")
for _, action in ipairs({
  { "How to install", "open_fork" },
  { "Open application", "open" },
  { "Check connection", "refresh" },
}) do
  local before = #commands
  find("text", action[1]).props.onClick()
  assert(#commands == before + 1 and commands[#commands].action == action[2])
end
local before = #commands
for _, reason in ipairs({
  "credentials_missing",
  "credentials_invalid",
  "loopback_proxy",
  "api_unavailable",
  "unauthorized",
  "auth_changed",
  "unsupported",
  "invalid_response",
  "permission",
  "timeout",
}) do
  fixture.error = reason
  watcher(fixture)
  assert(find("key", "setup-status").props.text == noctalia.tr("setup." .. reason))
end
assert(#commands == before, "rendering diagnostics must not send commands")
fixture = { state = "ready", devices = {} }
watcher(fixture)
assert(find("key", "setup-status").props.text == noctalia.tr("setup.no_devices"))
fixture.devices = { { id = "phone", name = "Phone", online = false } }
watcher(fixture)
assert(not find("key", "connection-setup") and find("key", "ring"))
fixture.devices[1].online = true
watcher(fixture)
assert(not find("key", "connection-setup"))
fixture = { state = "offline", error = "api_unavailable", devices = {} }
watcher(fixture)
assert(
  not find("key", "connection-setup") and find("key", "connection-error"),
  "a temporary outage must not restart first-run setup"
)
onClose()
print(
  "PASS: setup reasons, explicit buttons, no render actions, fixed bounds and recovery/offline behavior"
)
