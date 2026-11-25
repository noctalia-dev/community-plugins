-- Actual panel code, mocked host. No HTTP or real-phone actions.
dofile("tests/test_runtime.lua")
local watchers, tree, commands, config = {}, nil, {}, {}
local closeRequests = 0
config.panel_controls = false
ui = setmetatable({}, {
  __index = function(_, kind)
    return function(props, children)
      return { kind = kind, props = props, children = children or {} }
    end
  end,
})
panel = {
  close = function() closeRequests = closeRequests + 1 end,
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
  local function walk(node)
    if node.props.key == key then
      return node
    end
    for _, child in ipairs(node.children) do
      local found = walk(child)
      if found then return found end
    end
  end
  return walk(tree)
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
assert(ring.children[2].props.maxLines == 1 and ring.props.height == 100)
assert(keyed("navigation").props.height == 520)
local function contains(parent, key)
  for _, child in ipairs(parent.children) do
    if child.props.key == key then
      return true
    end
  end
  return false
end
assert(contains(keyed("sidebar"), "timeline") and not contains(keyed("content"), "timeline"))
assert(contains(keyed("sidebar"), "notifications"))
assert(contains(keyed("phone-battery").children[1], "refresh-home"))
local function batteryStatus()
  local power = keyed("phone-battery").children
  return power[#power].props.text
end
local battery = fixture.devices[1].battery
assert(batteryStatus() == "Charging")
battery.fullInMinutes = 75
update(fixture)
assert(batteryStatus() == "≈ 1 h 15 min to full")
fixture.devices[1].online = false
update(fixture)
assert(batteryStatus() == "Last known")
fixture.devices[1].online, battery.fullInMinutes = true, 0
update(fixture)
assert(batteryStatus() == "Charging")
battery.fullInMinutes = nil
local countBeforeRefresh = #commands
keyed("refresh-home").props.onClick()
assert(#commands == countBeforeRefresh + 1 and commands[#commands].action == "refresh")
assert(#tree.children == 1 and tree.children[1].props.key == "dashboard", "Home has no title bar")
for _, child in ipairs(ring.children) do
  assert(child.kind ~= "button")
end
assert(not keyed("screen").props.onClick)
ring.props.onClick()
assert(commands[#commands].device == "one" and commands[#commands].value == true)
fixture.devices[1].ringing = true
update(fixture)
assert(keyed("ring").props.fill == "primary/0.16")
keyed("ring").props.onClick()
assert(commands[#commands].value == false)
fixture.ringBusy = true
update(fixture)
assert(not keyed("ring").props.onClick)
fixture.ringBusy = false
onTileHover("true", "files")
assert(keyed("files").props.fill == "primary/0.16")
onTileHover("false", "files")
assert(keyed("files").props.fill == "surface") -- Minimal mock has no palette API.
assert(keyed("event-a") and not keyed("event-b"))
do
  local times = {}
  noctalia.formatTime = function(_, seconds)
    times[#times + 1] = seconds
    return "12:00"
  end
  fixture.timeline[1].timestamp = 1795541400
  fixture.notificationsState = "ready"
  fixture.notifications = { { deviceId = "one", key = "clock", timestamp = 1795541401000 } }
  update(fixture)
  assert(times[1] == 1795541401 and times[2] == 1795541400)
  fixture.timeline[1].timestamp, fixture.notifications, fixture.notificationsState = nil, nil, nil
  noctalia.formatTime = nil
end
local files = keyed("files").props.onClick
local beforeFiles = #commands
files()
files()
assert(closeRequests == 1 and #commands == beforeFiles)
onClose()
assert(#commands == beforeFiles + 1 and commands[#commands].action == "files_after_close")
assert(commands[#commands].device == "one" and commands[#commands].value == false)
files()
assert(closeRequests == 1)
onOpen()
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
assert(contains(keyed("sidebar"), "notifications") and not keyed("timeline"))
assert(keyed("ring").props.width >= 100)
assert(keyed("content").props.width == keyed("ring").props.width * 4 + 24)
fixture.notifications = {}
update(fixture)
assert(keyed("notifications") and not keyed("notice-one"))
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
local function finishControl(command, busy)
  fixture.controlRequestId = command.value.request_id
  fixture.controlBusy = busy == true
  update(fixture)
end
keyed("control-dnd").props.onClick()
assert(commands[#commands].action == "phone_toggle" and commands[#commands].value.on == true)
finishControl(commands[#commands])
local before = #commands
local wifiOff = keyed("control-wifi").props.onClick
wifiOff()
local wifiCommand = commands[#commands]
assert(
  #commands == before + 1 and wifiCommand.device == "one" and wifiCommand.value.id == "wifi"
    and wifiCommand.value.confirm_disconnect == true and wifiCommand.value.on == false
)
assert(keyed("session-strip") and not keyed("control-prompt") and not keyed("control-wifi").props.onClick)
wifiOff()
assert(#commands == before + 1)
finishControl(wifiCommand, true)
assert(not keyed("control-wifi").props.onClick and keyed("control-wifi").props.fill == "primary/0.20")
fixture.devices[1].controls.state.wifi = false
finishControl(wifiCommand)
wifiOff()
assert(#commands == before + 1)
keyed("control-wifi").props.onClick()
assert(commands[#commands].value.on == true and commands[#commands].value.confirm_disconnect == nil)
finishControl(commands[#commands])
local staleWifi = keyed("control-wifi").props.onClick
fixture.devices[2] = { id = "another", name = "Other", online = true, controls = fixture.devices[1].controls }
update(fixture)
keyed("device-picker").props.onChange(1)
local beforeSwitch = #commands
staleWifi()
assert(#commands == beforeSwitch, "a stale Wi-Fi button must not act after changing phones")
keyed("device-picker").props.onChange(0)
fixture.devices[2] = nil
update(fixture)
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
assert(ringer("vibrate").variant == "primary" and ringer("silent").enabled)
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
fixture.controlRequestId = commands[#commands].value.request_id
update(fixture)
assert(not ringer("ring").onClick)
fixture.controlBusy = false
fixture.devices[1].online = false
update(fixture)
assert(not ringer("ring").enabled)
fixture.devices[1].online = true
update(fixture)
local rc = keyed("ringer-controls")
assert(rc.props.height == 36)
local used = 2 * rc.props.padding + (#rc.children - 1) * rc.props.gap
for _, n in ipairs(rc.children) do
  used = used + n.props.width
end
assert(used == rc.props.width)
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
assert(keyed("phone-controls"))
local function heightUsed(column)
  local p = column.props
  local height = 2 * (p.padding or 0) + (#column.children - 1) * (p.gap or 0)
  for _, child in ipairs(column.children) do
    height = height + (child.props.height or 0)
  end
  return height
end
assert(heightUsed(keyed("content")) <= keyed("content").props.height)
assert(heightUsed(keyed("phone-controls")) <= keyed("phone-controls").props.height)
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
assert(tree.props.clip == nil and tree.props.height == 528 and tree.props.padding == 4)
assert(keyed("dashboard").props.clip == nil and keyed("dashboard").props.height == 520)
assert(keyed("content").props.clip == nil and keyed("sidebar").props.clip == nil)
assert(not keyed("home-tabs"))
assert(contains(keyed("content"), "phone-controls") and contains(keyed("sidebar"), "timeline"))
assert(contains(keyed("sidebar"), "notifications") and not contains(keyed("sidebar"), "phone-controls"))
for _, id in ipairs({ "long-a", "long-b" }) do
  local row = keyed("event-" .. id)
  local marker, card = row.children[1], row.children[2]
  assert(marker.props.width + row.props.gap + card.props.width == row.props.width)
  assert(card.props.height == row.props.height and row.props.clip == nil)
  local heading = card.children[2].children[1]
  assert(utf8.len(heading.children[1].props.text) <= 61)
end
assert(keyed("notice-long").props.clip == nil and keyed("notice-long").props.height == 62)
for _, n in ipairs(nodes("label")) do
  assert(not n.props.text:find("[\r\n\t]"))
  assert(not n.props.text:find("\226\128\168", 1, true))
  assert(utf8.len(n.props.text))
  assert(n.props.maxWidth and n.props.maxWidth > 0 and n.props.maxWidth <= 1072)
end
local function noticePreview()
  return keyed("notice-long").children[3].children[3].props.text
end
assert(utf8.len(noticePreview()) <= 97)
assert(fixture.notifications[1].text == huge and fixture.timeline[1].title == huge)
assert(heightUsed(keyed("content")) == keyed("content").props.height)
fixture.notifications[1].text = "invalid \255\254 bytes"
update(fixture)
assert(utf8.len(noticePreview()))
for i = 2, 4 do
  fixture.notifications[i] = { key = tostring(i), deviceId = "one", title = "Alert " .. i }
  fixture.timeline[i] = { id = tostring(i), deviceId = "one", title = "Event " .. i }
end
update(fixture)
assert(keyed("notice-3") and not keyed("notice-4"))
assert(keyed("event-3") and not keyed("event-4"))
for _, key in ipairs({ "sidebar", "notifications", "timeline", "phone-controls" }) do
  local column = keyed(key)
  assert(heightUsed(column) <= column.props.height)
end
local controls = keyed("phone-controls")
assert(controls.props.width == keyed("device").props.width)
for _, kind in ipairs({ "pc_audio", "watch", "phone_audio" }) do
  assert(keyed("session-row-" .. kind).props.height == 46)
end
before = #commands
keyed("control-hotspot").props.onClick()
assert(keyed("hotspot-choices") and not keyed("session-strip") and #commands == before)
assert(heightUsed(keyed("phone-controls")) <= keyed("phone-controls").props.height)
local oldHotspot = keyed("hotspot-off").props.onClick
onNavigate("guide")
onNavigate("home")
before = #commands
oldHotspot()
assert(#commands == before and not keyed("hotspot-choices") and keyed("session-strip"))
keyed("control-hotspot").props.onClick()
keyed("hotspot-off").props.onClick()
assert(#commands == before + 1 and commands[#commands].value.id == "hotspot" and commands[#commands].value.on == false)
assert(not keyed("hotspot-choices") and keyed("session-strip"))
finishControl(commands[#commands])
assert(
  keyed("camera").props.width == keyed("webcam").props.width
    and keyed("camera").props.width == keyed("typing").props.width
)
assert(keyed("device").props.align == "center")
assert(keyed("device").props.width == keyed("content").props.width)
assert(keyed("phone-preview").props.height == 120 and keyed("phone-battery").props.height == 120)
for _, key in ipairs({ "screen", "files", "clipboard", "ring", "camera", "webcam", "typing" }) do
  local card = keyed(key)
  if card then
    local compact = card.kind == "row"
    local caption = compact and card.children[2].children[2] or card.children[3]
    assert(caption.props.text ~= "" and caption.props.maxLines == 1)
    assert(caption.props.maxWidth == card.props.width - (compact and 53 or 20))
  end
end
assert(
  keyed("phone-preview").props.height + 2 * keyed("device").props.padding
    <= keyed("device").props.height
)
assert(
  keyed("phone-preview").props.clip == nil
    and keyed("phone-preview-screen").props.clip == nil
    and keyed("phone-info").props.clip == nil
)
onClose()
print(
  "PASS: actions, sessions, drafts, preferences, multiline/UTF-8 previews, fixed card bounds and dashboard height budget"
)
