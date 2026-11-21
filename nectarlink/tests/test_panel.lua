-- Actual panel code, mocked host. No HTTP or real-phone actions.
dofile("tests/test_runtime.lua")
local watchers, tree, commands, config = {}, nil, {}, {}
config.panel_controls = false
ui = setmetatable({}, {
  __index = function(_, kind)
    return function(props, children)
      return { kind = kind, props = props, children = children or {} }
    end
  end,
})
panel = {
  render = function(node)
    tree = node
  end,
}
local fixture = {
  state = "ready",
  devices = {
    {
      id = "one",
      name = "Phone",
      online = true,
      ringing = false,
      battery = {
        level = 40,
        charging = true,
      },
    },
  },
  timelineState = "ready",
  timeline = {
    { id = "a", deviceId = "one", title = "An event", direction = "incoming" },
    { id = "b", deviceId = "two", title = "Other device event" },
  },
}
noctalia = {
  getConfig = function(key)
    return config[key]
  end,
  openSettings = function() end,
  json = {
    decode = function(raw)
      if raw == "broken" then
        error("invalid")
      end
      return raw
    end,
    encode = function(raw)
      return raw
    end,
  },
  state = {
    watch = function(key, cb)
      watchers[key] = cb
    end,
    get = function()
      return fixture
    end,
    set = function(_, cmd)
      table.insert(commands, cmd)
    end,
  },
}
dofile("panel.luau")
local function nodes(kind)
  local found = {}
  local function walk(n)
    if n.kind == kind then
      table.insert(found, n)
    end
    for _, child in ipairs(n.children) do
      walk(child)
    end
  end
  walk(tree)
  return found
end
local function keyed(key)
  for _, kind in ipairs({ "column", "row" }) do
    for _, n in ipairs(nodes(kind)) do
      if n.props.key == key then
        return n
      end
    end
  end
end
local function update(data)
  watchers["nl.snapshot"](data)
end
onOpen()
local ring = keyed("ring")
assert(ring.props.onClick and ring.props.tooltip == "Find phone")
assert(ring.props.width >= 100 and ring.props.flexGrow == nil)
assert(keyed("camera").props.width == keyed("webcam").props.width)
assert(keyed("typing").props.width == keyed("camera").props.width)
assert(ring.children[2].props.maxLines == 2 and ring.props.height == 68)
assert(keyed("navigation").props.height == 398)
local function contains(parent, key)
  for _, child in ipairs(parent.children) do
    if child.props.key == key then
      return true
    end
  end
  return false
end
assert(contains(keyed("sidebar"), "timeline") and not contains(keyed("content"), "timeline"))
for _, child in ipairs(ring.children) do
  assert(child.kind ~= "button")
end
assert(not keyed("screen").props.onClick)
ring.props.onClick()
assert(commands[#commands].device == "one" and commands[#commands].value == true)
fixture.devices[1].ringing = true
update(fixture)
assert(keyed("ring").props.fill == "primary/0.18")
keyed("ring").props.onClick()
assert(commands[#commands].value == false)
fixture.ringBusy = true
update(fixture)
assert(not keyed("ring").props.onClick)
fixture.ringBusy = false
onTileHover("true", "files")
assert(keyed("files").props.fill == "primary/0.18")
onTileHover("false", "files")
assert(keyed("files").props.fill == "#202020") -- Minimal mock has no palette API.
assert(keyed("event-a") and not keyed("event-b"))
fixture.devices[1].online = false
update(fixture)
assert(not keyed("files").props.onClick and not keyed("clipboard").props.onClick)
assert(not keyed("camera").props.onClick)
fixture.devices[1].online = true
table.insert(fixture.devices, { id = "two", name = "Other", online = true, ringing = false })
update(fixture)
assert(not keyed("files").props.onClick)
nodes("select")[1].props.onChange("1")
keyed("ring").props.onClick()
assert(commands[#commands].device == "two")
keyed("camera").props.onClick()
assert(commands[#commands].action == "camera" and commands[#commands].device == "two")
assert(keyed("event-b") and not keyed("event-a"))
update({ state = "offline", devices = {} })
assert(not keyed("ring").props.onClick)
update("broken")
update({ state = "ready", devices = { { id = "legacy", name = "Legacy", online = true } } })
assert(not keyed("ring").props.onClick)
config.panel_battery = false
config.panel_actions = false
config.panel_timeline = false
config.panel_navigation = false
onConfigChanged()
assert(not keyed("ring") and not keyed("timeline"))
assert(#nodes("progress") == 0)
assert(#nodes("scroll") == 0 and not keyed("navigation"))
config.panel_navigation = true
onConfigChanged()
assert(keyed("navigation") and keyed("navigation").kind == "column")
fixture.devices = { fixture.devices[1] }
fixture.devices[1].online = true
config.panel_actions = true
fixture.notificationsState = "ready"
fixture.notifications = {
  { key = "one", deviceId = "one", title = "Notice", text = "Example" },
  { key = "two", deviceId = "other" },
}
update(fixture)
assert(keyed("notifications") and keyed("notice-one") and not keyed("notice-two"))
assert(contains(keyed("content"), "notifications"))
assert(keyed("ring").props.width >= 100)
assert(keyed("content").props.width == keyed("ring").props.width * 4 + 30)
fixture.notifications = {}
update(fixture)
assert(not keyed("notifications"))
fixture.notifications = { { key = "one", deviceId = "one" } }
config.panel_notifications = false
update(fixture)
assert(not keyed("notifications"))
config.panel_controls = true
fixture.devices[1].controls = {
  state = { dnd = false, wifi = true, flashlight = false, bluetooth = false },
  allowed = { dnd = true, wifi = true, flashlight = true, bluetooth = false, hotspot = true },
}
update(fixture)
assert(keyed("phone-controls") and keyed("ring").props.width >= 100)
assert(not keyed("control-bluetooth").props.onClick)
keyed("control-dnd").props.onClick()
assert(commands[#commands].action == "phone_toggle" and commands[#commands].value.on == true)
local before = #commands
keyed("control-wifi").props.onClick()
assert(#commands == before)
for _, n in ipairs(nodes("button")) do
  if n.props.text == "Turn off" then
    n.props.onClick()
  end
end
assert(
  commands[#commands].value.confirm_disconnect == true and commands[#commands].value.on == false
)
local function ringer(mode)
  for _, n in ipairs(nodes("button")) do
    if n.props.key == "ringer-" .. mode then
      return n.props
    end
  end
end
assert(ringer("ring") and not ringer("ring").enabled)
fixture.devices[1].controls.state.ringer = "vibrate"
fixture.devices[1].controls.allowed.ringer = true
update(fixture)
assert(ringer("vibrate").variant == "secondary" and ringer("silent").enabled)
before = #commands
ringer("vibrate").onClick()
assert(#commands == before)
ringer("silent").onClick()
assert(
  commands[#commands].value.id == "ringer"
    and commands[#commands].value.mode == "silent"
    and commands[#commands].value.on == nil
)
fixture.controlBusy = true
update(fixture)
assert(not ringer("ring").onClick)
fixture.controlBusy = false
fixture.devices[1].online = false
update(fixture)
assert(not ringer("ring").enabled)
fixture.devices[1].online = true
update(fixture)
local rc = keyed("ringer-controls")
assert(rc.props.height == 40 and rc.props.width == 260)
local used = 2 * rc.props.padding + (#rc.children - 1) * rc.props.gap
for _, n in ipairs(rc.children) do
  used = used + n.props.width
end
assert(used == 260)
fixture.sessions = {
  one = {
    pc_audio = "off",
    watch = "off",
    phone_audio = "asking",
    screen = "off",
    webcam = "off",
    keyboard = "off",
    allowed = {
      pc_audio = true,
      watch = false,
      phone_audio = true,
      screen = true,
      webcam = true,
      keyboard = true,
    },
  },
}
update(fixture)
assert(keyed("screen").props.onClick and keyed("webcam").props.onClick)
keyed("screen").props.onClick()
assert(commands[#commands].action == "session" and commands[#commands].value.on == true)
fixture.sessions.one.screen = "asking"
update(fixture)
keyed("screen").props.onClick()
assert(commands[#commands].value.on == false)
local function toggle(key)
  for _, n in ipairs(nodes("toggle")) do
    if n.props.key == key then
      return n.props
    end
  end
end
assert(not toggle("session-watch").enabled)
assert(toggle("session-phone_audio").checked)
toggle("session-phone_audio").onChange("false")
assert(commands[#commands].value.kind == "phone_audio" and commands[#commands].value.on == false)
fixture.sessions.one.keyboard = "enabled"
update(fixture)
assert(keyed("typing-form") and not keyed("typing"))
nodes("input")[1].props.onChange("example")
nodes("input")[1].props.onSubmit()
assert(commands[#commands].action == "type_text" and commands[#commands].value == "example")
fixture.typeDeliveryDevice = "one"
update(fixture)
assert(nodes("input")[1].props.value == "example") -- Transport completion is not application acknowledgement.
fixture.typeSent = 1
fixture.typeSentDevice = "one"
update(fixture)
assert(nodes("input")[1].props.value == "")
nodes("input")[1].props.onChange("before")
nodes("input")[1].props.onSubmit()
nodes("input")[1].props.onChange("new unsent text")
fixture.typeSent = 2
update(fixture)
assert(nodes("input")[1].props.value == "new unsent text") -- Late ack must not discard edits.
-- Reproduce huge multiline clipboard titles and notification bodies without
-- using real clipboard/message content. Previewing must not alter the source.
config.panel_timeline = true
config.panel_notifications = true
config.panel_battery = true
fixture.sessions.one.keyboard = "off"
local huge = string.rep(
  "Команда 🦀\r\n\tследующая строка\226\128\168ещё строка ",
  300
)
fixture.timeline = {
  { id = "long-a", deviceId = "one", title = huge, direction = "incoming" },
  { id = "long-b", deviceId = "one", title = huge, direction = "outgoing" },
}
fixture.notifications =
  { { key = "long", deviceId = "one", appName = "App\nname", title = huge, text = huge } }
fixture.notificationsState = "ready"
update(fixture)
assert(tree.props.clip == nil and tree.props.height == 438 and tree.props.padding == 3)
assert(keyed("dashboard").props.clip == nil and keyed("dashboard").props.height == 398)
assert(keyed("content").props.clip == nil and keyed("sidebar").props.clip == nil)
assert(keyed("timeline").props.clip == nil and keyed("timeline").props.height <= 120)
assert(keyed("event-long-a").props.clip == nil and keyed("event-long-a").props.height == 32)
assert(keyed("notifications").props.clip == nil and keyed("notifications").props.height == 104)
assert(keyed("notice-long").props.clip == nil and keyed("notice-long").props.height == 80)
for _, n in ipairs(nodes("label")) do
  assert(not n.props.text:find("[\r\n\t]"))
  assert(not n.props.text:find("\226\128\168", 1, true))
  assert(utf8.len(n.props.text))
  assert(n.props.maxWidth and n.props.maxWidth > 0 and n.props.maxWidth <= 828)
end
assert(utf8.len(keyed("notice-long").children[3].props.text) <= 97)
assert(utf8.len(keyed("event-long-a").children[2].children[1].children[1].props.text) <= 29)
assert(fixture.notifications[1].text == huge and fixture.timeline[1].title == huge)
local used = 0
for _, child in ipairs(keyed("content").children) do
  if child.props.height then
    used = used + child.props.height
  elseif child.kind == "row" then
    local height = 0
    for _, tile in ipairs(child.children) do
      height = math.max(height, tile.props.height or 0)
    end
    used = used + height
  end
end
used = used + keyed("content").props.gap * (#keyed("content").children - 1)
assert(used <= 398, "dashboard children exceed available vertical space")
assert(keyed("notifications") and used == 398, "notification block must fit the compact home")
for _, pair in ipairs({
  { "content", "notifications", "notifications-spacer" },
  { "sidebar", "timeline", "timeline-spacer" },
}) do
  local col = keyed(pair[1])
  assert(col.props.height == 398)
  assert(col.children[#col.children].props.key == pair[2])
  assert(
    col.children[#col.children - 1].props.key == pair[3]
      and col.children[#col.children - 1].props.flexGrow == 1
  )
end
-- Exact maximum Home sidebar budget: controls 222 + modes 40 + history 112 + gaps 24.
local controls = keyed("phone-controls")
assert(controls.props.padding == 8 and controls.props.gap == 7)
for _, kind in ipairs({ "pc_audio", "watch", "phone_audio" }) do
  assert(keyed("session-row-" .. kind).props.height == 32)
end
assert(16 + 28 + 54 + 3 * 32 + 4 * 7 + 40 + 112 + 3 * 8 == 398)
assert(
  keyed("camera").props.width == keyed("webcam").props.width
    and keyed("camera").props.width == keyed("typing").props.width
)
assert(keyed("device").props.align == "center")
assert(keyed("device").props.width == keyed("content").props.width)
assert(keyed("phone-preview").props.height == 92 and keyed("phone-battery").props.height == 92)
for _, key in ipairs({ "screen", "files", "clipboard", "ring", "camera", "webcam", "typing" }) do
  local card = keyed(key)
  if card then
    local text = card.children[#card.children]
    assert(text.props.maxWidth == card.props.width - 16, "tile text must fit its own padding")
  end
end
assert(keyed("notice-long").children[3].props.maxWidth == keyed("content").props.width - 16)
assert(
  keyed("phone-preview").props.height + 2 * keyed("device").props.padding
    <= keyed("device").props.height
)
assert(
  keyed("phone-preview").props.clip == nil
    and keyed("phone-preview-screen").props.clip == nil
    and keyed("phone-info").props.clip == nil
)
assert(
  keyed("phone-controls").props.width == keyed("timeline").props.width
    and keyed("phone-controls").props.padding == keyed("timeline").props.padding
)
local header = keyed("timeline-header")
assert(
  header.props.clip == nil
    and header.children[1].props.width + header.children[2].props.width + header.props.gap
      == header.props.width
)
for _, id in ipairs({ "long-a", "long-b" }) do
  local row = keyed("event-" .. id)
  local icon, text = row.children[1], row.children[2]
  assert(icon.props.width + row.props.gap + text.props.width == row.props.width)
  assert(text.props.clip == nil and text.props.height == 32)
  assert(text.children[1].props.height + text.children[2].props.height == 32)
  for _, slot in ipairs(text.children) do
    assert(
      slot.props.clip == nil
        and slot.children[1].props.maxWidth == 216
        and slot.children[1].props.maxLines == 1
    )
  end
end
fixture.notifications[1].text = "invalid \255\254 bytes"
update(fixture)
assert(utf8.len(keyed("notice-long").children[3].props.text))
onClose()
print(
  "PASS: actions, sessions, drafts, preferences, multiline/UTF-8 previews, fixed card bounds and dashboard height budget"
)
