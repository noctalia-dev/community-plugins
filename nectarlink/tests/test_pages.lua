-- Execute the actual UI with a host mock. Never dispatch to a real phone.
dofile("tests/test_runtime.lua")
local watchers, tree, commands = {}, {}, {}
local settingsOpened, homeBuilds = 0, 0
local nodeBuilds = 0
local config = {}
local fixture =
  { state = "ready", devices = { { id = "one", name = "Phone", online = true, ringing = false } } }
ui = setmetatable({}, {
  __index = function(_, kind)
    return function(props, children)
      nodeBuilds = nodeBuilds + 1
      if props.key == "device" then
        homeBuilds = homeBuilds + 1
      end
      return { kind = kind, props = props, children = children or {} }
    end
  end,
})
panel = {
  render = function(n)
    assert(n.props.height == 528 and n.props.width == 1072, "panel must never resize")
    tree = n
  end,
}
noctalia = {
  getConfig = function(k)
    return config[k]
  end,
  openSettings = function()
    settingsOpened = settingsOpened + 1
  end,
  formatTime = function()
    return "14.11 17:45"
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
    watch = function(k, cb)
      watchers[k] = cb
    end,
    set = function(_, v)
      commands[#commands + 1] = v
    end,
  },
}
dofile("panel.luau")
local function find(predicate)
  local function walk(n)
    if predicate(n) then
      return n
    end
    for _, child in ipairs(n.children) do
      local result = walk(child)
      if result then
        return result
      end
    end
  end
  return walk(tree)
end
local function key(k)
  return find(function(n)
    return n.props.key == k
  end)
end
local function button(text)
  return find(function(n)
    return n.kind == "button" and n.props.text == text
  end)
end
local function last(action)
  for i = #commands, 1, -1 do
    if commands[i].action == action then
      return commands[i]
    end
  end
end
local function respond(data)
  fixture.page = { key = last("page").value.key, status = "ready", data = data }
  watchers["nl.snapshot"](fixture)
end
local function countActions()
  local count = 0
  for _, cmd in ipairs(commands) do
    if cmd.action == "page_action" then
      count = count + 1
    end
  end
  return count
end
local function finishAction(command, busy)
  fixture.pageActionRequestId = command.value.request_id
  fixture.pageActionBusy = busy == true
  watchers["nl.snapshot"](fixture)
end
local function clickAction(callback, action, id)
  local before = countActions()
  callback()
  local cmd = last("page_action")
  assert(countActions() == before + 1 and cmd.device == "one")
  assert(cmd.value.action == action and cmd.value.id == id and cmd.value.confirm == true)
  assert(#cmd.value.request_id == 32 and not key("action-confirmation"))
  callback()
  assert(countActions() == before + 1, "old click must not dispatch a second request")
  return cmd
end
local function assertColumnFits(column)
  local p = column.props
  local used = 2 * (p.padding or 0) + math.max(0, #column.children - 1) * (p.gap or 0)
  for _, child in ipairs(column.children) do
    used = used + (child.props.height or 0)
  end
  assert(used <= p.height, (p.key or column.kind) .. " exceeds its budget: " .. used)
end
local function assertPageFits()
  assert(key("sidebar-page").props.height == key("dashboard").props.height)
  assertColumnFits(key("sidebar-page"))
  assertColumnFits(key("page-body"))
  if key("page-list") then assertColumnFits(key("page-list")) end
  for _, name in ipairs({ "message-threads", "message-thread", "thread-list", "call-history", "dial-form", "dial-keypad" }) do
    if key(name) then assertColumnFits(key(name)) end
  end
end
onOpen()
assert(key("refresh-home"))
key("plugin-settings").props.onClick()
assert(settingsOpened == 1 and countActions() == 0)
for _, page in ipairs({ "messages", "calls", "photos", "apps", "deck", "guide" }) do
  local before = homeBuilds
  key("nav-" .. page).props.onClick()
  assert(homeBuilds == before, "hidden Home must not be constructed")
  assertPageFits()
  assert(key("page-heading") and key("sidebar-page").props.height == 520)
  assert(not key("content") and not key("sidebar"))
  assert(key("nav-" .. page).props.variant == "primary")
  local refreshes = 0
  find(function(n)
    if n.kind == "button" and n.props.glyph == "refresh" then
      refreshes = refreshes + 1
    end
    return false
  end)
  assert(refreshes == (page == "guide" and 0 or 1), "duplicate refresh buttons")
end
assert(countActions() == 0)
for i = 1, 5 do
  local before = #commands
  key("guide-tab-" .. i).props.onClick()
  assert(#commands == before and key("guide-tab-" .. i).props.variant == "primary")
  assert(key("guide-tab-" .. i).props.contentAlign == "start")
  assertPageFits()
  assertColumnFits(key("guide-topics"))
  assertColumnFits(key("guide-notes"))
  assert(#key("guide-notes").children == 4)
  assert(key("guide-layout").props.height <= key("page-body").props.height)
end
assert(key("help-fork").props.contentAlign == "start")
key("help-fork").props.onClick()
assert(last("open_fork"))
key("nav-messages").props.onClick()
assert(not key("message-toolbar") and key("new-sms"))
key("new-sms").props.onClick()
assert(key("back-to-threads") and not key("message-toolbar") and countActions() == 0)
local newDraft = key("message-draft-one|new-0")
newDraft.props.onChange("Hello, demo")
assert(not button("Send").props.enabled)
key("sms-recipient-one").props.onChange(" ")
assert(not button("Send").props.enabled)
key("sms-recipient-one").props.onChange("2025550100")
assert(button("Send").props.enabled and countActions() == 0)
assertPageFits()
assert(key("message-threads") and key("message-thread"))
local newSms = clickAction(button("Send").props.onClick, "sms", "")
assert(newSms.value.text == "Hello, demo" and newSms.value.recipients[1] == "2025550100")
assert(key("message-composer") and not button("Sending…").props.enabled)
finishAction(newSms) -- Completion may be the first snapshot observed by the UI.
assert(key("message-draft-one|new-0").props.value == "Hello, demo")
key("back-to-threads").props.onClick()
respond({
  items = {
    { id = "42", kind = "sms", title = "Alice", addresses = { "123" }, subtitle = "Hello" },
  },
})
key("thread-item-42").props.onClick()
assert(last("page").value.limit == 6)
assert(key("thread-item-42").props.fill == "primary/0.19")
local lines = {}
for i = 1, 100 do lines[i] = ("Строка %03d 🦀\n"):format(i) end
local chat = {
  { id = "m1", title = "Alice", subtitle = table.concat(lines), date = 9 },
  { id = "m2", title = "Me", subtitle = "Hi", date = 8, outgoing = true },
}
for i = 3, 6 do chat[i] = { id = "m" .. i, date = 10 - i } end
respond({ items = chat, reply = true, notice = "Read and reply permissions are separate" })
assert(key("page-item-m2").props.fill == "primary/0.15" and key("page-item-m1").props.fill ~= "primary/0.15")
assert(key("message-composer") and key("page-notice") and #key("page-list").children == 6)
assertPageFits()
local input = find(function(n)
  return n.kind == "input" and (n.props.key or ""):match("message%-draft")
end)
input.props.onChange("Не отправлять автоматически")
assert(countActions() == 1)
local beforeOffline = button("Send").props.onClick
fixture.devices[1].online = false
watchers["nl.snapshot"](fixture)
assert(not button("Send").props.enabled)
beforeOffline()
assert(countActions() == 1, "a queued send must not reach an offline phone")
fixture.devices[1].online = true
watchers["nl.snapshot"](fixture)
local sms = clickAction(button("Send").props.onClick, "sms", "42")
assert(sms.value.text == "Не отправлять автоматически" and sms.value.recipients[1] == "123")
finishAction(sms)
assert(find(function(n)
  return n.kind == "input"
    and n.props.value == "Не отправлять автоматически"
end))
key("page-item-m1").props.onClick()
assert(key("message-detail").children[1].props.text == table.concat(lines, "", 1, 12))
key("pager-next").props.onClick()
assert(key("message-detail").children[1].props.text == table.concat(lines, "", 13, 24))
key("back-to-message").props.onClick()
assert(key("thread-item-42") and key("page-item-m1"))
button("Clear").props.onClick()
assert(key("message-draft-one|42-1").props.value == "" and not button("Send").props.enabled)
key("back-to-threads").props.onClick()
respond({ items = {
  { id = "chat:m", kind = "chat", title = "Demo notifications", subtitle = "One saved message" },
} })
key("thread-item-chat:m").props.onClick()
respond({ items = { { id = "n1", title = "Demo", subtitle = "A reply", outgoing = true } }, reply = false })
assert(key("page-notice") and key("page-item-n1").props.width == key("page-list").props.width)
assert(key("page-item-n1").props.fill ~= "primary/0.15" and not button("Send").props.enabled)
assertPageFits()
respond({ items = {}, reply = true })
key("message-draft-one|chat:m-0").props.onChange("Demo reply")
local oldReply = button("Send").props.onClick
respond({ items = {}, reply = false })
oldReply()
assert(countActions() == 2, "a now-unavailable reply must not be dispatched")
respond({ items = {}, reply = true })
local reply = clickAction(button("Send").props.onClick, "reply", "chat:m")
assert(reply.value.text == "Demo reply" and reply.value.recipients == nil)
finishAction(reply)

key("nav-calls").props.onClick()
assert(key("dial-toolbar") and key("call-history") and not key("refresh-home"))
local function dialInput()
  return find(function(n)
    return n.kind == "input" and (n.props.key or ""):match("^dial%-number%-one%-")
  end)
end
local beforeDial = #commands
local originalInput = dialInput()
originalInput.props.onChange("12345")
assert(dialInput().props.key == originalInput.props.key, "physical typing must preserve input focus")
key("dial-key-6").props.onClick()
assert(dialInput().props.value == "123456" and dialInput().props.key ~= originalInput.props.key)
originalInput.props.onChange("0")
assert(dialInput().props.value == "123456", "a stale input must not overwrite a keypad edit")
key("dial-erase").props.onClick()
assert(dialInput().props.value == "12345" and #commands == beforeDial)
assert(not key("dial-submit").props.enabled, "no dial permission until the page arrives")
respond({
  items = { { id = "c1", title = "Alice", number = "123", subtitle = "incoming", date = 100 } },
  dial = true,
  active = { id = "active-call", state = "ringing", name = "Bob" },
  control = true,
})
assertPageFits()
assert(key("page-item-c1") and key("active-call-toolbar") and key("dial-keypad"))
dialInput().props.onChange("invalid")
assert(not key("dial-submit").props.enabled)
dialInput().props.onChange("+1 (202) 555-0100")
assert(key("dial-submit").props.enabled)
local function callState(id, state)
  respond({
    items = { { id = "c1", title = "Alice", number = "123", subtitle = "incoming", date = 100 } },
    dial = true, active = { id = id, state = state, name = "Bob" }, control = true,
  })
end
local oldAnswer = key("active-answer").props.onClick
callState("next-call", "ringing")
oldAnswer()
assert(countActions() == 3, "a replaced incoming call cannot be answered by a stale button")
for _, action in ipairs({ "answer", "silence", "decline" }) do
  if action == "decline" then callState("next-call", "active") end
  local cmd = clickAction(key("active-" .. action).props.onClick, action, "next-call")
  assert(key("call-history") and key("dial-form") and not key("active-" .. action).props.enabled)
  assert(key("dial-submit").props.text == "Call")
  finishAction(cmd)
end
key("page-item-c1").props.onClick()
assert(dialInput().props.value == "123" and key("page-item-c1") and countActions() == 6)
local firstDial = key("dial-submit").props.onClick
local dial = clickAction(firstDial, "dial")
assert(dial.value.text == "123" and key("page-item-c1"))
assert(not key("dial-submit").props.enabled and key("dial-submit").props.text == "Sending…")
watchers["nl.snapshot"](fixture) -- An unrelated poll cannot release the click lock.
assert(countActions() == 7 and not key("dial-submit").props.enabled)
finishAction(dial, true)
assert(not key("dial-submit").props.enabled and key("dial-submit").props.text == "Sending…")
finishAction(dial)
assert(key("dial-submit").props.enabled)
firstDial()
assert(countActions() == 7, "a callback from before the request must not dial again")
key("nav-photos").props.onClick()
respond({
  items = {
    {
      id = "p1",
      title = "Фото",
      thumbnailPath = "/private/preview.jpg",
      date = 100,
      size = 1024,
    },
  },
  albums = { { id = "a1", name = "Camera" } },
})
assert(key("page-grid") and key("page-item-p1").kind == "column")
assert(find(function(n)
  return n.kind == "image" and n.props.path == "/private/preview.jpg"
end))
key("page-item-p1").props.onClick()
assert(
  key("photo-preview").props.height == key("page-body").props.height
    and key("photo-preview").children[1].props.fit == "contain"
)
assertPageFits()
assert(not find(function(n)
  return n.kind == "label" and n.props.text == "Фото" and n.props.color == "primary"
end))
local closedPhoto = key("download-photo").props.onClick
key("back-to-list").props.onClick()
closedPhoto()
assert(countActions() == 7, "a closed photo preview must not start a download")
key("page-item-p1").props.onClick()
local photo = clickAction(key("download-photo").props.onClick, "photo", "p1")
assert(key("photo-preview") and not key("download-photo").props.enabled)
finishAction(photo)
for _, page in ipairs({ "apps", "deck" }) do
  key("nav-" .. page).props.onClick()
  respond({ items = { { id = "known-id", title = "Existing", subtitle = "Configured" } } })
  assert(key("page-grid") and key("page-item-known-id").kind == "column")
  local before = countActions()
  key("page-item-known-id").props.onClick()
  assert(countActions() == before + 1 and not key("action-confirmation"))
  assert(last("page_action").value.action == (page == "apps" and "app" or "deck"))
  finishAction(last("page_action"))
  if page == "apps" then
    local count = countActions()
    fixture.pageActionBusy = true
    watchers["nl.snapshot"](fixture)
    assert(not key("page-item-known-id").props.onClick)
    assert(countActions() == count)
    fixture.pageActionBusy = false
    fixture.devices[1].online = false
    watchers["nl.snapshot"](fixture)
    assert(not key("page-item-known-id").props.onClick)
    assert(countActions() == count)
    fixture.devices[1].online = true
    watchers["nl.snapshot"](fixture)
  end
end
-- A late answer for the old page must never paint rows into another page.
local old = {
  key = fixture.page.key,
  status = "ready",
  data = { items = {
    { id = "late-deck", title = "Wrong page" },
  } },
}
key("nav-apps").props.onClick()
fixture.page = old
watchers["nl.snapshot"](fixture)
assert(
  not key("page-item-late-deck") and key("page-item-known-id"),
  "keep cached apps visible, but never accept a late Deck response"
)
respond({ items = { { id = "cached-app", title = "Cached", subtitle = "pkg" } } })
key("refresh-page").props.onClick()
assert(last("page").value.force == true and key("page-item-cached-app"))
local before = #commands
key("app-search").props.onChange("Camera")
watchers["nl.snapshot"](fixture)
assert(#commands == before, "typing a search must not refetch on an unrelated snapshot")
button("Search").props.onClick()
assert(last("page").value.search == "Camera" and not last("page").value.force)
-- Full pages, including toolbars and a notice, must fit the same panel.
fixture.pageActionResult =
  "Запрос принят. Проверьте результат; черновик сохранён."
for _, page in ipairs({ "messages", "calls", "photos", "apps", "deck" }) do
  key("nav-" .. page).props.onClick()
  -- Layout bounds below exercise the list, not the deliberately restored chat.
  if page == "messages" and key("back-to-threads") then
    key("back-to-threads").props.onClick()
  end
  local count = page == "photos" and 8
    or (page == "apps" and 36 or (page == "deck" and 11 or (page == "messages" and 7 or 6)))
  local items = {}
  for i = 1, count do
    items[i] = {
      id = tostring(i),
      title = string.rep("Длинный текст 🦀\n", 100),
      subtitle = "Body",
      date = i,
    }
  end
  respond({
    items = items, more = true, notice = "An informational notice from the app", albums = {},
    active = page == "calls" and { id = "active-call", state = "ringing", name = "Caller" } or nil,
  })
  assert(key(page == "messages" and "threads-notice" or "page-notice"))
  if page == "calls" then assert(key("active-call-toolbar")) end
  if page == "messages" or page == "calls" then
    assert(#key(page == "messages" and "thread-list" or "page-list").children == count
      and last("page").value.limit == count)
  end
  assert(not find(function(n)
    return n.kind == "label"
      and (n.props.text or ""):find(
        "Запрос принят. Проверьте результат",
        1,
        true
      )
  end), "old cross-page status must not render")
  local grid = key("page-grid")
  if grid then
    if page == "photos" then
      assert(
        #grid.children == 2 and #grid.children[1].children == 4 and #grid.children[2].children == 4
      )
    end
    if page == "apps" then
      assert(
        #grid.children == 4 and #grid.children[1].children == 9 and last("page").value.limit == count
      )
    end
    local totalHeight = (#grid.children - 1) * grid.props.gap
    for _, row in ipairs(grid.children) do
      local totalWidth = (#row.children - 1) * row.props.gap
      totalHeight = totalHeight + row.props.height
      for _, cell in ipairs(row.children) do
        totalWidth = totalWidth + cell.props.width
        assert(
          cell.props.height == row.props.height
            and cell.props.clip == nil
            and not cell.props.borderWidth
        )
        local used = 2 * cell.props.padding + (#cell.children - 1) * cell.props.gap
        for _, child in ipairs(cell.children) do
          used = used + child.props.height
        end
        assert(used <= cell.props.height, "grid children exceed the cell")
        if page == "photos" then
          local image, caption = cell.children[1], cell.children[2]
          assert(
            image.props.width == cell.props.width - 2 * cell.props.padding
              and caption.children[1].props.maxLines == 1
              and image.props.height + caption.props.height + cell.props.gap + 2 * cell.props.padding
                == cell.props.height,
            "photo thumbnail and filename must fit the tile"
          )
        end
      end
      assert(totalWidth <= row.props.width, "grid columns exceed row width")
    end
    assert(totalHeight <= grid.props.height, "grid rows overlap")
  end
  local footer = key(page == "messages" and "thread-list-pagination" or "page-pagination")
  if page == "deck" then
    assert(not footer)
  else
    assert(
      footer.props.height == 32
        and footer.children[1].props.glyph == "chevron-left"
        and footer.children[3].props.glyph == "chevron-right"
    )
    local pageNumber = page == "messages" and "threads-pager-number" or "page-number"
    assert(key(pageNumber).children[1].props.text == "1")
    for _, child in ipairs(footer.children) do
      if child.kind == "button" then
        assert(child.props.height <= footer.props.height)
      end
    end
  end
  assertPageFits()
  if page ~= "deck" then
    local prefix = page == "messages" and "threads-pager" or "pager"
    key(prefix .. "-next").props.onClick()
    local query = last("page").value
    if page == "photos" or page == "calls" then
      assert(query.before == count and query.before_id == tostring(count))
    else
      assert(query.offset == count)
    end
    respond({ items = items, more = true, albums = {} })
    assert(key(page == "messages" and "threads-pager-number" or "page-number").children[1].props.text == "2")
    key(prefix .. "-prev").props.onClick()
    assert(last("page").value.offset == 0 and last("page").value.before == nil)
  end
end
-- Both app display modes must fit with or without the navigation rail.
local actionCount = countActions()
key("nav-apps").props.onClick()
for _, case in ipairs({
  { "icons", true, 96, 52, 17, 6, 56 },
  { "icons_text", true, 36, 103, 9, 4, 88 },
  { "icons", false, 96, 52, 18, 6, 56 },
  { "icons_text", false, 40, 99, 10, 4, 88 },
}) do
  config.apps_display = case[1]
  config.panel_navigation = case[2]
  onConfigChanged()
  local query = last("page").value
  assert(query.limit == case[3] and query.offset == 0)
  local items = {}
  for i = 1, query.limit do
    items[i] = {
      id = "app-" .. i,
      title = "App name",
      subtitle = "org.private.package",
      iconPath = "/private/icon.png",
    }
  end
  respond({ items = items, more = true })
  local grid = key("page-grid")
  assert(#grid.children == case[6] and #grid.children[1].children == case[5])
  local toolbar = key("app-toolbar")
  assert(toolbar.children[#toolbar.children] == key("page-pagination"))
  for _, row in ipairs(grid.children) do
    local usedWidth = #row.children * case[4] + (#row.children - 1) * row.props.gap
    assert(usedWidth <= row.props.width + 0.001)
    if #row.children == case[5] then assert(math.abs(usedWidth - row.props.width) < 0.001) end
    for _, cell in ipairs(row.children) do
      assert(cell.props.width == case[4] and cell.props.height == case[7])
      assert(#cell.children == (case[1] == "icons" and 1 or 2))
      local icon = cell.children[1].children[1]
      local iconSide = case[1] == "icons" and 26 or 34
      assert(icon.props.width == iconSide and icon.props.height == iconSide)
      if case[1] == "icons_text" then assert(cell.children[2].children[1].props.maxLines == 2) end
      assert(
        cell.props.tooltip == "App name · org.private.package" and cell.props.fill == "surface/0.72"
      )
    end
  end
  assert(not find(function(n)
    return n.kind == "label" and n.props.text == "org.private.package"
  end))
  assertPageFits()
  assert((key("navigation") ~= nil) == case[2] and key("plugin-settings"))
  local builds = nodeBuilds
  onTileHover("true", "page-item-app-1")
  assert(key("page-item-app-1").props.fill == "primary/0.16")
  onTileHover("false", "page-item-app-1")
  assert(key("page-item-app-1").props.fill == "surface/0.72") -- Minimal mock has no palette API.
  assert(nodeBuilds == builds, "app hover must reuse the existing tree")
  key("pager-next").props.onClick()
  assert(last("page").value.offset == case[3])
end
assert(countActions() == actionCount, "layout/settings/hover must never launch apps")
config.panel_navigation = true
config.apps_display = "icons_text"
onConfigChanged()
onNavigate("guide")
assert(not button("Plugin settings") and key("plugin-settings"))
assert(not find(function(n)
  return n.kind == "label" and (n.props.text or ""):find("плагин Noctalia", 1, true)
end))
key("nav-deck").props.onClick()
-- The complete core-bounded Deck fits one view even with a notice.
for _, count in ipairs({ 11, 24, 48, 96, 192 }) do
  local items = {}
  for i = 1, count do
    items[i] = { id = "tile-" .. i, title = "Configured tile", subtitle = "Page" }
  end
  respond({ items = items, more = false, complete = true, notice = "Read-only notice" })
  local grid = key("page-grid")
  local rendered = 0
  local used = (#grid.children - 1) * grid.props.gap
  for _, row in ipairs(grid.children) do
    used = used + row.props.height
    rendered = rendered + #row.children
    for _, cell in ipairs(row.children) do
      local occupied = 2 * cell.props.padding + (#cell.children - 1) * cell.props.gap
      for _, child in ipairs(cell.children) do
        occupied = occupied + child.props.height
      end
      assert(occupied <= cell.props.height)
    end
  end
  assert(rendered == count and used == grid.props.height and not key("page-pagination"))
  assertPageFits()
end
onClose()
assert(commands[#commands].action == "visible" and commands[#commands].value == false)
onOpen()
assert(commands[#commands].action == "page") -- No refresh/leave overwriting the read in the same frame.
onClose()
print(
  "PASS: all six pages, one-click actions, duplicate guards, retained drafts, call IDs and late-response isolation"
)
