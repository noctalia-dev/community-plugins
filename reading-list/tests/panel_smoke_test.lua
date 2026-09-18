local panelPath = assert(arg[1], "expected transformed panel path")
local watchers = {}
local rendered = nil
local sentCommands = {}

ui = setmetatable({}, {
  __index = function(_, nodeType)
    return function(props, children)
      return { type = nodeType, props = props or {}, children = children or {} }
    end
  end,
})

panel = {
  render = function(tree) rendered = tree end,
  close = function() end,
}

noctalia = {
  tr = function(key) return key end,
  state = {
    watch = function(key, callback) watchers[key] = callback end,
    set = function(key, value)
      if key == "reading_list.cmd" and value ~= nil then table.insert(sentCommands, value) end
    end,
  },
  clipboardText = function() return "" end,
  fileExists = function() return false end,
  runAsync = function() return true end,
  pluginDir = function() return "/plugin" end,
  togglePanel = function() end,
  openSettings = function() end,
  copyToClipboard = function() return true end,
  notify = function() end,
  notifyError = function() end,
}

local function visit(node, predicate)
  if type(node) ~= "table" then return nil end
  if predicate(node) then return node end
  for _, child in ipairs(node.children or {}) do
    local found = visit(child, predicate)
    if found ~= nil then return found end
  end
  return nil
end

local function byKey(key)
  return visit(rendered, function(node) return node.props.key == key end)
end

local function byTooltip(tooltip)
  return visit(rendered, function(node) return node.props.tooltip == tooltip end)
end

dofile(panelPath)
assert(rendered ~= nil, "panel should render its loading state")

watchers["reading_list.collections"]({ "Research", "Later" })
watchers["reading_list.items"]({
  {
    id = "one", type = "article", title = "First article", url = "https://example.com/first",
    source = "Example", author = "Writer", description = "Description", topics = { "testing" },
    collections = { "Research" }, status = "unread", favorite = false, progress = 25,
    rating = 4, queueOrder = 1, createdAt = 1789200000, icon = "", image = "",
    notes = "Notes", review = "Review", currentPage = 0, totalPages = 0, estimatedMinutes = 10,
    notePath = "/library/Items/one.md",
  },
  {
    id = "two", type = "book", title = "Second item", url = "", source = "Local",
    author = "", description = "", topics = { "books" }, collections = { "Later" }, status = "read",
    favorite = true, progress = 100, rating = 5, queueOrder = 2, createdAt = 1789200100,
    icon = "", image = "", notes = "", review = "", currentPage = 50, totalPages = 100,
    estimatedMinutes = 45, finishedAt = os.time(), notePath = "/library/Items/two.md",
  },
})
watchers["reading_list.ready"](true)
assert(byKey("search") ~= nil, "ready list should include search")
assert(byTooltip("Edit") ~= nil, "item cards should render edit actions")
local statusButton = assert(visit(rendered, function(node)
  return node.type == "button" and node.props.glyph == "circle" and node.props.width == 94
end), "unread cards should render a status control")
statusButton.props.onClick()
local statusCommand = sentCommands[#sentCommands]
assert(statusCommand.op == "set_status" and statusCommand.status == "reading",
  "the card status control should cycle from unread to reading")
local readStatusButton = assert(visit(rendered, function(node)
  return node.type == "button" and node.props.glyph == "circle-check-filled" and node.props.width == 94
end), "read cards should render a status control")
readStatusButton.props.onClick()
statusCommand = sentCommands[#sentCommands]
assert(statusCommand.op == "set_status" and statusCommand.status == "unread",
  "the card status control should cycle from read to unread instead of archived")

byTooltip("Edit").props.onClick()
assert(byKey("collection-1") ~= nil, "editor should render the managed collection selector")
local moreDetails = assert(visit(rendered, function(node) return node.props.text == "More details" end),
  "editor should keep optional fields collapsed")
moreDetails.props.onClick()
assert(visit(rendered, function(node) return node.props.text == "Choose image" end) ~= nil,
  "expanded editor should render the image chooser")

onOpen()
local sort = assert(byKey("sort-mode"), "list should render the sort selector")
sort.props.onChange("1", "Queue order")
assert(byTooltip("Move down in queue") ~= nil, "queue mode should render move controls")

onOpen()
byTooltip("Reports").props.onClick()
assert(byKey("report-range") ~= nil, "reports view should render its period selector")
assert(visit(rendered, function(node) return node.props.text == "Library overview" end) ~= nil,
  "reports view should render the library summary")
assert(visit(rendered, function(node) return node.props.text == "Recent completions" end) ~= nil,
  "reports view should render completion history")
assert(visit(rendered, function(node) return node.props.text == "Second item" end) ~= nil,
  "reports view should list recently completed items")

onOpen()
byTooltip("Share and export").props.onClick()
assert(byKey("share-format") ~= nil, "share view should render its format selector")
assert(visit(rendered, function(node) return node.props.text == "Import file" end) ~= nil,
  "share view should provide import without crowding the main header")
assert(visit(rendered, function(node) return node.props.text == "Export file" end) ~= nil,
  "share view should render export actions")

print("reading-list panel smoke tests: ok")
