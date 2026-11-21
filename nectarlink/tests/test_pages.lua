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
    assert(n.props.height == 438 and n.props.width == 828, "panel must never resize")
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
onOpen()
assert(key("refresh-home"))
key("plugin-settings").props.onClick()
assert(settingsOpened == 1 and countActions() == 0)
for _, page in ipairs({ "messages", "calls", "photos", "apps", "deck", "guide" }) do
  local before = homeBuilds
  key("nav-" .. page).props.onClick()
  assert(homeBuilds == before, "hidden Home must not be constructed")
  assert(
    key("sidebar-page") and key("sidebar-page").props.height == 398 and tree.props.height == 438
  )
  assert(not key("content") and not key("sidebar"))
  assert(key("nav-" .. page).props.variant == "secondary")
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
  key("guide-tab-" .. i).props.onClick()
  local view = key("sidebar-page")
  local height = 16 + (#view.children - 1) * view.props.gap
  for _, node in ipairs(view.children) do
    height = height + (node.props.height or 0)
  end
  assert(height <= 398)
end
key("nav-messages").props.onClick()
assert(not key("message-toolbar") and key("new-sms"))
key("new-sms").props.onClick()
assert(key("back-to-threads") and not key("message-toolbar") and countActions() == 0)
key("back-to-threads").props.onClick()
respond({
  items = {
    { id = "42", kind = "sms", title = "Alice", addresses = { "123" }, subtitle = "Hello" },
  },
})
key("page-item-42").props.onClick()
assert(last("page").value.limit == 6)
respond({
  items = {
    { id = "m1", title = "Alice", subtitle = string.rep("Текст 🦀\n", 100), date = 9 },
  },
  reply = true,
})
local input = find(function(n)
  return n.kind == "input" and (n.props.key or ""):match("message%-draft")
end)
input.props.onChange("Не отправлять автоматически")
assert(countActions() == 0)
button("Send").props.onClick()
assert(countActions() == 0)
button("Confirm").props.onClick()
assert(countActions() == 1 and last("page_action").value.action == "sms")
assert(
  last("page_action").value.recipients[1] == "123" and #last("page_action").value.request_id == 32
)
assert(find(function(n)
  return n.kind == "input"
    and n.props.value == "Не отправлять автоматически"
end))
key("page-item-m1").props.onClick()
assert(key("pager-next"))
key("pager-next").props.onClick()
button("← Back").props.onClick()
key("nav-calls").props.onClick()
assert(key("new-call") and not key("dial-toolbar") and not key("refresh-home"))
key("new-call").props.onClick()
assert(key("dial-toolbar") and key("back-to-list"))
key("dial-number-one").props.onChange("12345")
key("back-to-list").props.onClick()
assert(not key("dial-toolbar"))
key("new-call").props.onClick()
assert(key("dial-number-one").props.value == "12345")
key("back-to-list").props.onClick()
respond({
  items = { { id = "c1", title = "Alice", number = "123", subtitle = "incoming", date = 100 } },
  dial = true,
  active = { id = "active-call", state = "ringing", name = "Bob" },
  control = true,
})
button("Answer").props.onClick()
assert(countActions() == 1)
button("Confirm").props.onClick()
assert(last("page_action").value.id == "active-call")
key("page-item-c1").props.onClick()
button("Call").props.onClick()
button("Confirm").props.onClick()
assert(last("page_action").value.action == "dial")
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
  key("photo-preview").props.height == 350
    and key("photo-preview").children[1].props.fit == "contain"
)
assert(key("photo-preview").props.height + 32 + 4 + 12 == 398)
assert(not find(function(n)
  return n.kind == "label" and n.props.text == "Фото" and n.props.color == "primary"
end))
assert(key("download-photo").props.width == 28 and not button("Download original"))
key("download-photo").props.onClick()
button("Confirm").props.onClick()
assert(last("page_action").value.action == "photo")
for _, page in ipairs({ "apps", "deck" }) do
  key("nav-" .. page).props.onClick()
  respond({ items = { { id = "known-id", title = "Existing", subtitle = "Configured" } } })
  assert(key("page-grid") and key("page-item-known-id").kind == "column")
  local before = countActions()
  key("page-item-known-id").props.onClick()
  assert(countActions() == before + 1 and not button("Confirm"))
  assert(last("page_action").value.action == (page == "apps" and "app" or "deck"))
  if page == "apps" then
    local count = countActions()
    fixture.pageActionBusy = true
    watchers["nl.snapshot"](fixture)
    key("page-item-known-id").props.onClick()
    assert(countActions() == count)
    fixture.pageActionBusy = false
    fixture.devices[1].online = false
    watchers["nl.snapshot"](fixture)
    key("page-item-known-id").props.onClick()
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
-- Worst-case list pages include both notice and action status, never spill.
fixture.pageActionResult =
  "Запрос принят. Проверьте результат; черновик сохранён."
for _, page in ipairs({ "messages", "calls", "photos", "apps", "deck" }) do
  key("nav-" .. page).props.onClick()
  -- Layout bounds below exercise the list, not the deliberately restored chat.
  if page == "messages" and key("back-to-threads") then
    key("back-to-threads").props.onClick()
  end
  local count = page == "photos" and 8
    or (page == "apps" and 40 or (page == "deck" and 11 or (page == "messages" and 7 or 6)))
  local items = {}
  for i = 1, count do
    items[i] = {
      id = tostring(i),
      title = string.rep("Длинный текст 🦀\n", 100),
      subtitle = "Body",
      date = i,
    }
  end
  respond({ items = items, more = true, notice = "", albums = {} })
  if page == "messages" or page == "calls" then
    local rendered = 0
    for _, node in ipairs(key("sidebar-page").children) do
      if (node.props.key or ""):match("^page%-item") then
        rendered = rendered + 1
      end
    end
    assert(rendered == count and last("page").value.limit == count)
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
        #grid.children == 4 and #grid.children[1].children == 10 and last("page").value.limit == 40
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
          local image = cell.children[1].children[1]
          assert(
            image.props.width == cell.props.width - 8
              and image.props.height == 128
              and #cell.children == 1,
            "photo thumbnail must fill the tile"
          )
        end
      end
      assert(totalWidth <= row.props.width, "grid columns exceed row width")
    end
    assert(totalHeight <= grid.props.height, "grid rows overlap")
  end
  local footer = key("page-pagination")
  if page == "deck" then
    assert(not footer)
  else
    assert(
      footer.props.height == 32
        and footer.children[1].props.glyph == "chevron-left"
        and footer.children[5].props.glyph == "chevron-right"
    )
    assert(footer.children[3].children[1].props.text == "1")
    for _, child in ipairs(footer.children) do
      if child.kind == "button" then
        assert(child.props.height <= footer.props.height)
      end
    end
  end
  local view = key("sidebar-page")
  local height = 12 + (#view.children - 1) * view.props.gap
  for _, node in ipairs(view.children) do
    height = height + (node.props.height or (node.kind == "select" and 28) or 0)
  end
  assert(
    height <= view.props.height and view.props.height == 398 and tree.props.height == 438,
    page .. " exceeds bounds: " .. tostring(height)
  )
  if page ~= "deck" then
    key("pager-next").props.onClick()
    local query = last("page").value
    if page == "photos" or page == "calls" then
      assert(query.before == count and query.before_id == tostring(count))
    else
      assert(query.offset == count)
    end
    respond({ items = items, more = true, albums = {} })
    assert(key("page-number").children[1].props.text == "2")
    key("pager-prev").props.onClick()
    assert(last("page").value.offset == 0 and last("page").value.before == nil)
  end
end
-- The complete core-bounded Deck fits one view, even for unusually large configs.
local actionCount = countActions()
key("nav-apps").props.onClick()
for _, case in ipairs({
  { "icons", true, 70, 48, 14, 5 },
  { "icons_text", true, 40, 64, 10, 4 },
  { "icons", false, 75, 48, 15, 5 },
  { "icons_text", false, 44, 64, 11, 4 },
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
  for _, row in ipairs(grid.children) do
    assert(
      math.abs(#row.children * case[4] + (#row.children - 1) * row.props.gap - row.props.width)
        < 0.001
    )
    for _, cell in ipairs(row.children) do
      assert(cell.props.width == case[4] and cell.props.height == case[4])
      assert(#cell.children == (case[1] == "icons" and 1 or 2))
      local icon = cell.children[1].children[1]
      assert(icon.props.width == 24 and icon.props.height == 24)
      assert(
        cell.props.tooltip == "App name · org.private.package" and cell.props.fill == "transparent"
      )
    end
  end
  assert(not find(function(n)
    return n.kind == "label" and n.props.text == "org.private.package"
  end))
  local used = 12 + (#key("sidebar-page").children - 1) * 4
  for _, node in ipairs(key("sidebar-page").children) do
    used = used + (node.props.height or 0)
  end
  assert(used <= 398)
  local builds = nodeBuilds
  onTileHover("true", "page-item-app-1")
  assert(key("page-item-app-1").props.fill == "#202020") -- Minimal mock has no palette API.
  onTileHover("false", "page-item-app-1")
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
for _, count in ipairs({ 11, 24, 48, 96, 192 }) do
  local items = {}
  for i = 1, count do
    items[i] = { id = "tile-" .. i, title = "Configured tile", subtitle = "Page" }
  end
  respond({ items = items, more = false, complete = true })
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
  assert(rendered == count and used <= 336 and not key("page-pagination"))
end
onClose()
assert(commands[#commands].action == "visible" and commands[#commands].value == false)
onOpen()
assert(commands[#commands].action == "page") -- No refresh/leave overwriting the read in the same frame.
onClose()
print(
  "PASS: all six pages, explicit confirmations, retained drafts, call IDs, photos and late-response isolation"
)
